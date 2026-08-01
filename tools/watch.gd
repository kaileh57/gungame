extends Node
## Plays ONE demo live, for as long as you ask, and reports what happened — as a
## per-second trace and as a strip of PNGs you can open and look at.
##
## `tools/capture.tscn` answers "what does the frame look like". It cannot answer
## "does the war work", because a still taken 150 frames in shows three factions
## still walking. Everything the AI does — climbing, taking a roof, bounding,
## routing, talking, dying and being replaced — happens over tens of seconds, and
## the only honest way to check it is to run the thing and watch. This is that,
## made repeatable.
##
##   "<godot>" --path <proj> --resolution 1600x900 res://tools/watch.tscn -- \
##       --demo=firefight --seconds=90 --shots=6
##
## Options (after a bare `--`):
##   --demo=<id>     one of the ids in `TARGETS`. Default firefight.
##   --seconds=N     wall-clock seconds to run. Default 60.
##   --shots=K       PNGs, spread evenly over the run. Default 6. 0 for none.
##   --spawn=N       throw the arena's spawn lever once warmed up. N is the COUNT
##                   dial's DETENT INDEX, not a body count — the arena's detents
##                   read 1/2/3/4/6/8/12/16, so --spawn=5 is eight bodies. Past
##                   the last detent it is clamped and says so; see `_pull_lever`.
##   --fire          hold the player's trigger down. Only means anything in a demo
##                   that has a player; it drives the real mouse button, so the
##                   whole weapon chain runs rather than a poked flag.
##   --eye=x,y,z     park the demo's active camera here for the whole run, and
##                   --look=x,y,z aims it. See PARKING THE CAMERA.
##   --out=<dir>     where the PNGs and the trace go. Default res://_shots/watch.
##
## PARKING THE CAMERA. Every level in this project authors its spectator view for
## the whole battle — the firefight's sits 176 m up — and at that range a body is
## four pixels and "is it behind the container" is not a question a frame can
## answer. `--eye` puts the eye where you ask and holds it there, which is the
## only way to confirm by sight the things the instruments claim: a body tucked
## against a crate, a marksman on a deck, two squads bounding past each other.
## The camera is stood DOWN first where it answers `set_active` — a
## `FreecamController` runs its own `_process` and would otherwise drift the
## transform back out from under this — and then re-stamped every frame, so
## nothing in the demo can reclaim the view mid-run.
##
## Runs as a SCENE, not via `--script`, because every director in the project
## reaches for the autoloads and `--script` compiles before they exist.
##
## READS NOTHING PRIVATE. Every number below comes off a public method, resolved
## by `has_method` rather than by class, so this file does not have to be edited
## when a demo grows a new director.

const OUT_DEFAULT: String = "res://_shots/watch"
## Frames the scene is allowed to stall in before the clock starts. Mesh upload,
## shader compilation and the navigation bake all land inside this, and the
## opening deployment waits on the navigation map answering queries.
const WARM_FRAMES: int = 120
## Seconds between trace lines.
const SAMPLE_PERIOD: float = 1.0
## Metres above the world origin a body has to stand to count as off the ground.
## Both levels with links in them sit their ground plane below 1 m — the arena's
## navmesh spans -0.3 to 6.4 and the firefight pad 0.5 to 8.0 — so this separates
## a body on a container or a roof from one in the street.
const ALOFT: float = 2.0

const TARGETS: Dictionary = {
	"main_menu": "res://ui/main_menu.tscn",
	"visuals": "res://demos/visuals/visuals.tscn",
	"range": "res://demos/range/range.tscn",
	"gunbench": "res://demos/gunbench/gunbench.tscn",
	"bestiary": "res://demos/bestiary/bestiary.tscn",
	"arena": "res://demos/arena/arena.tscn",
	"firefight": "res://demos/firefight/firefight.tscn",
	"ash_flats": "res://demos/ash_flats/ash_flats.tscn",
	"movement": "res://demos/movement/movement.tscn",
}

var _demo: String = "firefight"
var _seconds: float = 60.0
var _shots: int = 6
var _fire: bool = false
var _spawn: int = 0
var _out: String = OUT_DEFAULT
## Where `--eye` asks the camera to stand, and what `--look` asks it to face.
## `_parked` is what says the option was given at all, because the origin is a
## legitimate place to stand.
var _parked: bool = false
var _eye: Vector3 = Vector3.ZERO
var _look: Vector3 = Vector3.ZERO
var _park_cam: Camera3D = null

var _scene: Node = null
var _frame: int = 0
var _clock: float = 0.0
var _next_sample: float = 0.0
var _next_shot: float = 0.0
var _shot_index: int = 0
var _trace: PackedStringArray = []
var _fps_accum: float = 0.0
var _fps_frames: int = 0
var _firing: bool = false
var _weapon: Node = null
var _player_shots: int = 0
var _player_hits: int = 0
var _player_damage: float = 0.0


func _ready() -> void:
	_parse_args(OS.get_cmdline_user_args())
	if not TARGETS.has(_demo):
		printerr("watch: unknown demo '%s'. Known: %s" % [_demo, ", ".join(TARGETS.keys())])
		get_tree().quit(1)
		return
	DirAccess.make_dir_recursive_absolute(_out)
	var path: String = str(TARGETS[_demo])
	var packed := load(path) as PackedScene
	if packed == null:
		printerr("watch: %s did not load." % path)
		get_tree().quit(1)
		return
	_scene = packed.instantiate()
	add_child(_scene)
	_install_links()
	_next_shot = 0.0
	print("watch: %s for %.0f s, %d shot(s) -> %s" % [_demo, _seconds, _shots, _out])


## Hand the level its off-mesh links.
##
## `AIPathService` finds its own link set from `SceneTree.current_scene`'s file
## name, and here the demo is a CHILD of this tool rather than the current scene,
## so that lookup asks for `watch_links.res` and comes back empty. Left alone the
## whole traversal layer is silently absent from anything watched through this
## harness — measured, 80 s of arena with 268 baked links installed and not one
## body off the ground — and the tool would report a level failing at something it
## was never given. `tools/capture.tscn` instances demos the same way and has the
## same blind spot.
func _install_links() -> void:
	var svc: Node = _find_with(&"install_link_set")
	if svc == null or int(svc.call(&"link_count")) > 0:
		return
	var path: String = "res://data/ai/links/%s_links.res" % _demo
	if not ResourceLoader.exists(path):
		print("watch: no link set at %s" % path)
		return
	print(
		"watch: installed %d links from %s" % [int(svc.call(&"install_link_set", load(path))), path]
	)


func _process(delta: float) -> void:
	if _scene == null:
		return
	_frame += 1
	if _frame <= WARM_FRAMES:
		return
	if _frame == WARM_FRAMES + 1:
		if _spawn > 0:
			_pull_lever()
		if _fire:
			_click(true)
			_firing = true
	if _parked:
		_park()
	_clock += delta
	_fps_accum += delta
	_fps_frames += 1
	if _shots > 0 and _clock >= _next_shot and _shot_index < _shots:
		_shoot()
	if _clock >= _next_sample:
		_next_sample += SAMPLE_PERIOD
		_sample()
	if _clock >= _seconds:
		_finish()


# --- observation --------------------------------------------------------------


## One trace line. Everything is duck-typed: a demo that grows a new director gets
## picked up without this file changing, and one that loses a method is skipped
## rather than crashing the run.
func _sample() -> void:
	var parts: PackedStringArray = ["t=%5.1f" % _clock]
	parts.append("fps %5.1f" % (float(_fps_frames) / maxf(_fps_accum, 1e-4)))
	_fps_accum = 0.0
	_fps_frames = 0
	var ff: Node = _find_with(&"callouts")
	if ff != null:
		parts.append(_firefight_line(ff))
	var arena: Node = _find_with(&"describe_agents")
	if arena != null and ff == null:
		parts.append(_arena_line(arena))
	parts.append(_aloft())
	var weapon: Node = _find_player_weapon()
	if weapon != null:
		parts.append(_weapon_line(weapon))
	_trace.append(" | ".join(parts))
	print(_trace[_trace.size() - 1])


func _firefight_line(d: Node) -> String:
	var bodies: PackedStringArray = []
	var zones: PackedStringArray = []
	for f: int in Factions.COUNT:
		bodies.append(str(int(d.call(&"body_count", f))))
		zones.append(str(int(d.call(&"zones_owned", f))))
	var claims: Vector2i = d.call(&"cover_claims")
	var calls: PackedInt32Array = d.call(&"callouts")
	var total: int = 0
	for k: int in calls.size():
		total += calls[k]
	var paths: Node = d.call(&"path_service")
	var crossings: int = 0 if paths == null else int(paths.call(&"crossings_total"))
	var crossing_now: int = 0 if paths == null else int(paths.call(&"traversing"))
	return (
		"bodies %s  zones %s  vantage %d  cover %d  climbing %d  crossed %d  said %d  [%s]"
		% [
			"/".join(bodies),
			"/".join(zones),
			claims.x,
			claims.y,
			crossing_now,
			crossings,
			total,
			" ".join(d.call(&"callout_log")),
		]
	)


func _arena_line(d: Node) -> String:
	return "arena %d alive  %s" % [int(d.call(&"alive_count")), str(d.call(&"summary"))]


## Live bodies standing more than `ALOFT` above the ground plane — on a container,
## a roof or a gantry. This is the acceptance test for the traversal work that a
## still frame cannot answer and a log of link crossings only half answers: a body
## that climbed and then stayed up there stops crossing links but is still up
## there. Counted off the `ai_target` group, so it needs nothing from the demo.
func _aloft() -> String:
	var up: int = 0
	var live: int = 0
	for n: Node in get_tree().get_nodes_in_group(&"ai_target"):
		var t := n as Node3D
		if t == null or not bool(t.get(&"alive")):
			continue
		live += 1
		if t.global_position.y > ALOFT:
			up += 1
	return "aloft %d/%d" % [up, live]


## The player's gun, if this demo has one. `Weapon` is the only class in the
## project that answers to both of these, and it is found once and cached.
func _find_player_weapon() -> Node:
	if _weapon != null and is_instance_valid(_weapon):
		return _weapon
	_weapon = _find_with(&"is_ready_to_fire")
	if _weapon != null:
		_weapon.connect(&"fired", _on_player_fired)
		_weapon.connect(&"hit", _on_player_hit)
	return _weapon


func _weapon_line(w: Node) -> String:
	var spec: GunSpec = w.call(&"spec")
	var ammo: Variant = w.call(&"ammo")
	return (
		"gun %s  %d loaded  state %s  %d fired  %d hits  %.0f dmg"
		% [
			"-" if spec == null else spec.weapon_name,
			0 if ammo == null else int(ammo.call(&"loaded")),
			String(w.call(&"state")),
			_player_shots,
			_player_hits,
			_player_damage,
		]
	)


func _on_player_fired(_origin: Vector3, _direction: Vector3, _spec: GunSpec) -> void:
	_player_shots += 1


func _on_player_hit(collider: Object, _at: Vector3, _normal: Vector3, damage: float) -> void:
	if collider == null:
		return
	_player_hits += 1
	_player_damage += damage


## Hold the view where `--eye` asked for it. Resolved on first use rather than in
## `_ready`, because the demo's own director picks its camera during its first
## frames and the one current after the warm-up is the one worth overriding.
func _park() -> void:
	if _park_cam == null:
		_park_cam = get_viewport().get_camera_3d()
		if _park_cam == null:
			printerr("watch: --eye asked for, but this demo has no current Camera3D.")
			_parked = false
			return
		if _park_cam.has_method(&"set_active"):
			_park_cam.call(&"set_active", false)
		print("watch: camera parked at %v looking at %v" % [_eye, _look])
	var to: Vector3 = _look - _eye
	if to.length_squared() < 1e-6:
		to = Vector3.FORWARD
	_park_cam.global_transform = Transform3D(Basis.looking_at(to, Vector3.UP), _eye)


## First node under the running scene that answers to `method`. Breadth-first, so
## a director hung directly off the demo root is found before anything deep.
func _find_with(method: StringName) -> Node:
	var queue: Array[Node] = [_scene]
	while not queue.is_empty():
		var n: Node = queue.pop_front()
		if n.has_method(method):
			return n
		for c: Node in n.get_children():
			queue.push_back(c)
	return null


# --- output -------------------------------------------------------------------


func _shoot() -> void:
	_next_shot = _seconds * float(_shot_index + 1) / float(_shots)
	var image: Image = get_viewport().get_texture().get_image()
	var file: String = "%s/%s_%02d.png" % [_out, _demo, _shot_index]
	if image.save_png(file) != OK:
		printerr("watch: could not write %s" % file)
	else:
		print("watch: shot %s at t=%.1f" % [file, _clock])
	_shot_index += 1


func _finish() -> void:
	if _firing:
		_click(false)
	var report: String = "%s/%s_trace.txt" % [_out, _demo]
	var f: FileAccess = FileAccess.open(report, FileAccess.WRITE)
	if f != null:
		f.store_string("watch %s — %.0f s\n" % [_demo, _seconds])
		f.store_string("\n".join(_trace) + "\n")
		f.close()
		print("watch: trace -> %s" % report)
	get_tree().quit(0)


## Throw the arena's own spawn lever, the way a player's hand would. The demo
## deliberately spawns nothing on its own — see `ArenaController` — so without
## this the compound is empty and there is nothing to watch. Found by node name
## rather than by class, so the tool stays ignorant of the demo.
##
## `--spawn` IS A DETENT INDEX AND NOT A BODY COUNT, and it is clamped here
## because the dial itself does not clamp. `DiegeticDial.wraps` is true, so
## `set_value` runs the raw index through `posmod`: measured, `--spawn=8` on the
## arena's eight-detent COUNT dial wrapped to detent 0 and spawned ONE body while
## the console cheerfully reported "thrown for 8", and eighty seconds of arena
## went by with nothing to watch and no error anywhere. The detent labels are read
## back and printed, so what actually got asked for is on the record.
func _pull_lever() -> void:
	var asked: int = _spawn
	var dial: Node = _find_named(&"CountDial", &"set_value")
	if dial != null:
		var detents: int = (dial.get(&"options") as PackedStringArray).size()
		if detents > 0:
			asked = clampi(_spawn, 0, detents - 1)
			if asked != _spawn:
				printerr(
					(
						"watch: --spawn=%d is past the last detent (%d); using %d."
						% [_spawn, detents - 1, asked]
					)
				)
		dial.call(&"set_value", float(asked))
	var lever: Node = _find_named(&"SpawnLever", &"set_on")
	if lever == null:
		printerr("watch: --spawn asked for, but this demo has no SpawnLever.")
		return
	lever.call(&"set_on", true)
	var label: String = str(dial.call(&"selected_text")) if dial != null else "?"
	print("watch: spawn lever thrown, COUNT detent %d reads '%s'" % [asked, label])


func _find_named(node_name: StringName, method: StringName) -> Node:
	var queue: Array[Node] = [_scene]
	while not queue.is_empty():
		var n: Node = queue.pop_front()
		if n.name == node_name and n.has_method(method):
			return n
		for c: Node in n.get_children():
			queue.push_back(c)
	return null


## A real left mouse button, which is what `fire` is bound to in `project.godot`.
## `Input.action_press` moves the polled action state without ever raising an
## `InputEvent`, so a rig reading its trigger in `_unhandled_input` never sees it.
func _click(down: bool) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = down
	event.position = Vector2(get_viewport().get_visible_rect().size) * 0.5
	Input.parse_input_event(event)


func _parse_args(args: PackedStringArray) -> void:
	for a: String in args:
		if a.begins_with("--demo="):
			_demo = a.substr(7)
		elif a.begins_with("--seconds="):
			_seconds = maxf(a.substr(10).to_float(), 1.0)
		elif a.begins_with("--shots="):
			_shots = maxi(a.substr(8).to_int(), 0)
		elif a.begins_with("--out="):
			_out = a.substr(6)
		elif a.begins_with("--spawn="):
			_spawn = maxi(a.substr(8).to_int(), 0)
		elif a.begins_with("--eye="):
			_eye = _vec(a.substr(6))
			_parked = true
		elif a.begins_with("--look="):
			_look = _vec(a.substr(7))
		elif a == "--fire":
			_fire = true
		else:
			printerr("watch: unknown option %s" % a)


## `x,y,z` off the command line. A malformed component reads as zero rather than
## aborting the run, which is the right trade for an observation tool.
func _vec(text: String) -> Vector3:
	var parts: PackedStringArray = text.split(",", false)
	var out := Vector3.ZERO
	for i: int in mini(parts.size(), 3):
		out[i] = parts[i].to_float()
	return out
