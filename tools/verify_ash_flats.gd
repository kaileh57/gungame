extends SceneTree
## Headless acceptance run for THE ASH LINE, the traversal course in `demos/ash_flats`.
##
## The course is a claim about two numbers — how far you get off a pitched roof
## sliding, and how far you get off it running — and every gap in it is cut to sit
## between them. This harness is what makes that claim checkable: it takes the
## collider set `tools/build_ash_flats.gd` actually emits, drops the real
## `PlayerController` on it, drives it with the real input actions, and measures.
##
## It is not a model of the course. `Builder.course_colliders()` is the same
## `_frame` math, the same box sizes and the same surfaces the bake writes into
## `ash_flats.tscn`; move a deck by ten centimetres and this moves with it.
##
## FOUR THINGS ARE ASSERTED, in the order they matter:
##   1. Every gap is CROSSED IN THE AIR on a slide off the pitch that feeds it.
##   2. No gap is crossed by a plain sprint, and none is reached at all — the sprint
##      attempt holds jump the whole way, so the manual vault gets its chance and
##      still comes up short. A gap a runner can take is not a gap, it is a step.
##   3. The slider therefore arrives at thirteen metres a second and the runner
##      arrives on the street below. That difference is the level.
##   4. The whole line runs end to end in one continuous input, which is the only
##      test of whether it flows rather than merely fits — and missing a gap drops
##      you somewhere you can stand up, not into the void.
##
## THE GAPS ARE CUT TO BEAT THE VAULT, not just the arc. Holding jump arms the
## manual vault, which probes 1.18 m FORWARD for a ledge up to 2.05 m above the
## feet: about 2.4 m of free reach on top of a 6.5 m run-jump arc. So a gap has to
## be past 9 m before a runner is honestly out of options, and every gap here is.
##
## Run:
##   godot --headless --path <project> --script res://tools/verify_ash_flats.gd
## Exits 0 when every case passes, 1 otherwise. `--baseline` prints the measurements
## and asserts nothing, which is how the gap lengths were chosen.

## The course tables and the collider set cut from them.
const Builder := preload("res://tools/ash_flats/ash_flats_line.gd")

const HZ: float = 60.0
const FLOOR_MAX_ANGLE: float = 0.8029
const ALL_ACTIONS: PackedStringArray = [
	"move_forward", "move_back", "move_left", "move_right", "jump", "crouch", "sprint"
]
## Where the ground goes in the harness world. Well below the lowest deck (-2.20) so
## it never catches a jump, and high enough that a miss lands instead of falling
## forever. In the demo this is the street and the riverbed.
const CATCH_Y: float = -8.0
## Seconds any single driven attempt is given before it is called a failure.
const ATTEMPT_SECONDS: float = 14.0
## Metres before the lip the jump is pressed. It has to be pressed while the feet are
## still ON the roof: crest the lip first and the controller cancels the slide, the
## buffered jump is read by the coyote branch, and what you get is a hop.
const JUMP_LEAD: float = 0.9

var _world: Node3D = null
var _player: PlayerController = null
var _failures: int = 0
var _cases: int = 0
var _baseline: bool = false


func _initialize() -> void:
	_baseline = OS.get_cmdline_user_args().has("--baseline")
	Engine.physics_ticks_per_second = int(HZ)
	Engine.max_fps = 0
	await _run_all()
	print("")
	if _failures == 0:
		print("PASS - %d/%d cases" % [_cases, _cases])
		quit(0)
	else:
		print("FAIL - %d of %d cases failed" % [_failures, _cases])
		quit(1)


func _run_all() -> void:
	_case_table_rules()
	for i: int in Builder.GAPS.size():
		await _case_gap(i)
	await _case_full_line()
	await _case_miss_is_survivable()
	_teardown()


# --- the tables ------------------------------------------------------------------------


## What can be checked without moving anything. The vault rule is the important one:
## a landing above its take-off is a wall, and a wall with jump held is 7.4 m of free
## reach that makes the gap meaningless.
func _case_table_rules() -> void:
	for gap: Array in Builder.GAPS:
		var name: String = gap[Builder.G_NAME]
		var drop: float = float(gap[Builder.G_Y0]) - float(gap[Builder.G_Y1])
		_report("%s lands at or below its lip" % name, drop >= -0.001, "%.2f m below" % drop)
		var lip: Array = _row_ending_at(float(gap[Builder.G_Z0]))
		var land: Array = _row_starting_at(float(gap[Builder.G_Z1]))
		_report("%s has a run into it" % name, not lip.is_empty(), _describe(lip))
		_report("%s has a deck out of it" % name, not land.is_empty(), _describe(land))
		if lip.is_empty():
			continue
		_report(
			"%s takes off downhill" % name,
			float(lip[Builder.P_Y1]) < float(lip[Builder.P_Y0]) - 0.5,
			"%.2f m of fall over the run in" % (float(lip[Builder.P_Y0]) - float(lip[Builder.P_Y1]))
		)


func _row_ending_at(z: float) -> Array:
	for row: Array in Builder.LINE:
		if absf(float(row[Builder.P_Z1]) - z) < 0.01 and absf(float(row[Builder.P_X]) + 8.0) < 0.01:
			return row
	return []


func _row_starting_at(z: float) -> Array:
	for row: Array in Builder.LINE:
		if absf(float(row[Builder.P_Z0]) - z) < 0.01 and absf(float(row[Builder.P_X]) + 8.0) < 0.01:
			return row
	return []


func _describe(row: Array) -> String:
	if row.is_empty():
		return "none"
	return (
		"z %.1f..%.1f  y %.2f..%.2f"
		% [row[Builder.P_Z0], row[Builder.P_Z1], row[Builder.P_Y0], row[Builder.P_Y1]]
	)


# --- one gap at a time -----------------------------------------------------------------


func _case_gap(index: int) -> void:
	var gap: Array = Builder.GAPS[index]
	var name: String = gap[Builder.G_NAME]
	var slid: Dictionary = await _attempt(index, true)
	var ran: Dictionary = await _attempt(index, false)
	var shape: String = (
		"      %-10s %4.2f m across, %4.2f m down"
		% [
			name,
			float(gap[Builder.G_Z1]) - float(gap[Builder.G_Z0]),
			float(gap[Builder.G_Y0]) - float(gap[Builder.G_Y1])
		]
	)
	print(
		(
			shape
			+ (
				"   slide %5.2f -> %5.2f m (vy %4.2f, vxz %5.2f)   sprint %5.2f -> %5.2f m (vy %4.2f)"
				% [
					slid["lip_speed"],
					slid["flew"],
					slid["vy"],
					slid["vxz"],
					ran["lip_speed"],
					ran["flew"],
					ran["vy"]
				]
			)
		)
	)
	var span: float = float(gap[Builder.G_Z1]) - float(gap[Builder.G_Z0])
	_report(
		"%s is crossed in the air on a slide" % name,
		(bool(slid["cleared"]) and float(slid["flew"]) >= span) or _baseline,
		(
			"flew %.2f m over %.2f m, landed at z %.2f y %.2f"
			% [slid["flew"], span, slid["z"], slid["y"]]
		)
	)
	_report(
		"%s refuses a sprint outright" % name,
		not bool(ran["cleared"]) or _baseline,
		(
			"a runner ended at z %.2f y %.2f (the deck is z %.1f)"
			% [ran["z"], ran["y"], gap[Builder.G_Z1]]
		)
	)
	_report(
		"%s is out of reach of a plain jump" % name,
		float(ran["flew"]) + 0.35 < span or _baseline,
		"a runner's arc is %.2f m against %.2f m of gap" % [ran["flew"], span]
	)
	# The vault exits at `exit_speed_scale` (0.62) of carry, so a grabbed gap always
	# puts the runner on the deck at about 4.6 m/s against a slider's ten-plus. The
	# ratio is what is asserted rather than either number, so this stays meaningful
	# when the slide-jump gets longer.
	_report(
		"%s costs a runner the line" % name,
		(
			(float(slid["arrive"]) > 8.0 and float(ran["arrive"]) < float(slid["arrive"]) * 0.55)
			or _baseline
		),
		"arrive: slide %.2f m/s, sprint %.2f m/s" % [slid["arrive"], ran["arrive"]]
	)


## One approach at one gap. `use_slide` picks between the two techniques the level is
## built to separate: crouch on the pitch and ride it, or just run down it.
##
## The sprint attempt HOLDS jump all the way through, which is deliberate — that is
## the manual vault armed, and it is the strongest thing a runner can do. If a gap
## survives that it survives anything short of a slide.
func _attempt(index: int, use_slide: bool) -> Dictionary:
	var gap: Array = Builder.GAPS[index]
	var lip_z: float = gap[Builder.G_Z0]
	var land_z: float = gap[Builder.G_Z1]
	var land_y: float = gap[Builder.G_Y1]
	var pitch: Array = _row_ending_at(lip_z)
	var approach: Array = _row_ending_at(float(pitch[Builder.P_Z0]))
	var from := Vector3(
		float(pitch[Builder.P_X]),
		float(approach[Builder.P_Y0]) + 0.25,
		float(approach[Builder.P_Z0]) + 0.8
	)
	await _spawn(from)
	Input.action_press(&"move_forward")
	Input.action_press(&"sprint")
	var fired: bool = false
	var left_ground: bool = false
	var touched_down: bool = false
	var lip_speed: float = 0.0
	var launch := Vector3.ZERO
	var out: Dictionary = {
		"cleared": false,
		"z": from.z,
		"y": from.y,
		"lip_speed": 0.0,
		"flew": 0.0,
		"arrive": 0.0,
		"vy": 0.0,
		"vxz": 0.0
	}
	for _i: int in int(HZ * ATTEMPT_SECONDS):
		await physics_frame
		var p: Vector3 = _player.global_position
		out["z"] = p.z
		out["y"] = p.y
		if not fired:
			if use_slide and p.z > float(pitch[Builder.P_Z0]) + 0.4:
				Input.action_press(&"crouch")
			if p.z >= lip_z - JUMP_LEAD:
				Input.action_press(&"jump")
				fired = true
				lip_speed = _player.speed
				launch = p
		else:
			# Reach is measured from the tick the feet leave to the tick they touch
			# anything, and only above the landing plane. Either end carried further
			# stops being the length of the jump: below the plane it is the length of
			# the fall, and after the first touch it can be a vault dragging the body
			# up a wall it never cleared.
			if not left_ground:
				left_ground = not _player.grounded
				if left_ground:
					out["vy"] = _player.velocity.y
					out["vxz"] = _player.speed
			elif not touched_down:
				if _player.grounded or p.y < land_y - 0.05:
					touched_down = true
				else:
					out["flew"] = maxf(float(out["flew"]), p.z - launch.z)
			# CROUCH STAYS DOWN. `SceneTree.physics_frame` is emitted at the TOP of the
			# physics step, before any node's `_physics_process` — so anything released
			# here lands on the SAME tick that reads the buffered jump. Letting go of
			# crouch here ended the slide before `_ground_move` saw it, and every
			# measurement in this file was of a plain hop taken from a slide's speed
			# until that was found. It is also what a chaining player does: you hold
			# crouch through the arc so the landing re-takes the slide.
			#
			# Jump is released the moment the feet are off, so no vault can rescue a
			# slide attempt that falls short.
			if use_slide and left_ground:
				Input.action_release(&"jump")
		if not _player.grounded:
			continue
		if fired and p.z > land_z - 0.10 and absf(p.y - land_y) < 1.4:
			out["cleared"] = true
			out["arrive"] = _player.speed
			break
		if p.y < CATCH_Y + 1.5:
			break
	out["lip_speed"] = lip_speed
	_release()
	return out


# --- the whole line --------------------------------------------------------------------


## One continuous input from the foot of the berm to the far bank: forward and sprint
## held throughout, crouch held on every pitch and released on every deck, jump tapped
## at every lip. If the line does not flow, this is where it shows — a chain that only
## works when each piece is attempted cold is a set of exercises, not a run.
func _case_full_line() -> void:
	var spine: Array[Array] = _spine()
	var first: Array = spine[0]
	# On the toe of the berm, not in front of it: the street the run really starts on
	# is the town's, and the town is not in this world.
	var toe: float = float(first[Builder.P_Z0]) + 1.0
	await _spawn(Vector3(float(first[Builder.P_X]), Builder.top_at(first, toe) + 0.3, toe))
	var last: Array = spine[spine.size() - 1]
	var finish_z: float = last[Builder.P_Z1]
	Input.action_press(&"move_forward")
	Input.action_press(&"sprint")
	var lips: PackedFloat32Array = PackedFloat32Array()
	for gap: Array in Builder.GAPS:
		lips.push_back(gap[Builder.G_Z0])
	var next_lip: int = 0
	var seconds: float = 0.0
	var top: float = 0.0
	var reached: float = -1000.0
	var fell: bool = false
	for _i: int in int(HZ * 40.0):
		await physics_frame
		seconds += 1.0 / HZ
		var p: Vector3 = _player.global_position
		top = maxf(top, _player.speed)
		reached = maxf(reached, p.z)
		if p.y < CATCH_Y + 1.5:
			fell = true
			break
		if p.z > finish_z:
			break
		# Crouch on every pitch and through every arc, off on every deck. That is the
		# input the level is designed around: the pitch is where the slide earns its
		# speed and the deck is where you would rather be running.
		if _pitch_at(p.z) or not _player.grounded:
			Input.action_press(&"crouch")
		else:
			Input.action_release(&"crouch")
		if next_lip < lips.size() and p.z >= lips[next_lip] - 0.35:
			Input.action_press(&"jump")
			next_lip += 1
		else:
			Input.action_release(&"jump")
	_release()
	print(
		(
			"      full line: reached z %.1f of %.1f in %.2f s, top speed %.2f m/s, %d of %d lips taken"
			% [reached, finish_z, seconds, top, next_lip, lips.size()]
		)
	)
	_report(
		"the line runs end to end",
		reached > finish_z - 1.0 and not fell or _baseline,
		"z %.1f of %.1f%s" % [reached, finish_z, "  (fell off)" if fell else ""]
	)
	_report(
		"the run is a run, not a walk",
		top > 11.0 or _baseline,
		"top speed %.2f m/s (want > 11, a sprint is 7.50)" % top
	)


func _spine() -> Array[Array]:
	var out: Array[Array] = []
	for row: Array in Builder.LINE:
		if absf(float(row[Builder.P_X]) + 8.0) < 0.01:
			out.append(row)
	out.sort_custom(func(a: Array, b: Array) -> bool: return float(a[1]) < float(b[1]))
	return out


func _pitch_at(z: float) -> bool:
	for row: Array in Builder.LINE:
		if int(row[Builder.P_KIND]) != Builder.L.PITCH:
			continue
		if z > float(row[Builder.P_Z0]) - 0.5 and z < float(row[Builder.P_Z1]) + 0.5:
			return true
	return false


# --- what a miss costs -----------------------------------------------------------------


## Falling off the line has to cost you the run and nothing else. The demo has no fall
## damage and no kill plane above the void, so this only has to prove the geometry does
## not trap you: run the second gap at a walk, miss it, and be standing again.
func _case_miss_is_survivable() -> void:
	var gap: Array = Builder.GAPS[1]
	var pitch: Array = _row_ending_at(float(gap[Builder.G_Z0]))
	await _spawn(
		Vector3(
			float(pitch[Builder.P_X]),
			float(pitch[Builder.P_Y0]) + 0.3,
			float(pitch[Builder.P_Z0]) + 0.5
		)
	)
	Input.action_press(&"move_forward")
	var landed: bool = false
	var low: float = 100.0
	for _i: int in int(HZ * 8.0):
		await physics_frame
		var p: Vector3 = _player.global_position
		low = minf(low, p.y)
		if p.y < float(gap[Builder.G_Y1]) - 1.0 and _player.grounded:
			landed = true
			break
	_release()
	_report(
		"a missed gap ends on your feet",
		landed,
		"stood up at y %.2f after falling to %.2f" % [_player.global_position.y, low]
	)


# --- harness ---------------------------------------------------------------------------


## Build the world, drop the player in it, and give it one physics frame. The frame
## is not optional: a node added to the tree root inside `_initialize` is not
## `is_inside_tree()` until the tree has stepped once, and until then every read of
## `global_position` comes back as the origin. Reading a position that is silently
## (0, 0, 0) is exactly how the first version of this harness pressed crouch on the
## opening tick of every attempt and then measured a man crawling.
func _spawn(at: Vector3) -> void:
	_teardown()
	_world = Node3D.new()
	_world.add_child(Builder.course_colliders())
	_world.add_child(_catch())
	root.add_child(_world)
	_player = _make_player()
	_world.add_child(_player)
	_player.position = at
	# Yaw PI is +Z, which is the direction the whole line runs.
	_player.yaw = PI
	await physics_frame


## The street and the riverbed, flattened into one slab. Nothing on the line is within
## five metres of it, so it catches a miss without ever being part of a jump.
static func _catch() -> StaticBody3D:
	var body := StaticBody3D.new()
	body.collision_layer = GameLayers.WORLD
	body.position = Vector3(-8.0, CATCH_Y - 1.0, -50.0)
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(60.0, 2.0, 200.0)
	shape.shape = box
	body.add_child(shape)
	return body


static func _make_player() -> PlayerController:
	var p := PlayerController.new()
	p.collision_layer = GameLayers.PLAYER
	p.collision_mask = GameLayers.MASK_PLAYER_MOVE
	p.floor_max_angle = FLOOR_MAX_ANGLE
	p.safe_margin = p.collision_margin
	p.body_shape_path = NodePath("Body")
	var shape := CylinderShape3D.new()
	shape.radius = p.radius
	shape.height = p.stand_height
	shape.resource_local_to_scene = true
	var body := CollisionShape3D.new()
	body.name = "Body"
	body.shape = shape
	body.position = Vector3(0.0, p.stand_height * 0.5, 0.0)
	p.add_child(body)
	return p


func _teardown() -> void:
	_release()
	if _world == null:
		return
	root.remove_child(_world)
	_world.free()
	_world = null
	_player = null


func _release() -> void:
	for a: String in ALL_ACTIONS:
		Input.action_release(StringName(a))


func _report(label: String, ok: bool, detail: String) -> void:
	_cases += 1
	if not ok:
		_failures += 1
	print("%s %-40s %s" % ["ok  " if ok else "FAIL", label, detail])
