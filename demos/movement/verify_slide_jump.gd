extends SceneTree
## Headless acceptance run for the slide, the slide-jump and the chain.
##
## The three numbers this exists to produce are the three the feature is judged on:
## how far a run-jump carries you, how far a slide-jump carries you, and how far the
## third jump of a chain down a slope carries you. They are measured the only honest
## way — drive the real `PlayerController` over real colliders with the real input
## actions, take the feet position on the tick the ground is left and again on the
## tick it is regained, and difference the XZ.
##
## Everything else here is a guard rail around those three: that flat-ground spam
## bleeds instead of compounding, that the cap is real, that air control steers
## without paying speed, that the roll and FOV response stay inside the bounds that
## keep it from being nauseating.
##
## Run:
##   godot --headless --path <project> --script res://demos/movement/verify_slide_jump.gd
## Exits 0 when every case passes, 1 otherwise. `--baseline` skips the assertions and
## only prints the measurements, which is how the target numbers were chosen.

const HZ: float = 60.0
const DT: float = 1.0 / HZ
const FLOOR_MAX_ANGLE: float = 0.8029
## Loaded at run time, never named as a class. See `_case_camera_response_bounded`.
const CAMERA_SCRIPT: String = "res://systems/player/player_camera.gd"
const DEMO_SCENE: String = "res://demos/movement/movement.tscn"
## Clear west apron of the movement yard: outboard of the ledge bank's westmost block at
## x -31.75 and of its sign post at x -34, with forty metres of nothing toward -Z.
const APRON: Vector3 = Vector3(-36.5, 0.2, 18.0)
## The slide run's deck, at the head of its 8 m, 23-degree descent.
const RUN_DECK: Vector3 = Vector3(33.0, 3.6, -7.0)
const ALL_ACTIONS: PackedStringArray = [
	"move_forward", "move_back", "move_left", "move_right", "jump", "crouch", "sprint"
]

var _world: Node3D = null
var _player: PlayerController = null
var _failures: int = 0
var _cases: int = 0
var _baseline: bool = false
## The three headline distances, kept so the summary can print them together.
var _run_jump: float = 0.0
var _slide_jump: float = 0.0
var _chain_jump: float = 0.0


func _initialize() -> void:
	_baseline = OS.get_cmdline_user_args().has("--baseline")
	Engine.physics_ticks_per_second = int(HZ)
	Engine.max_fps = 0
	await _run_all()
	print("")
	print(
		(
			"DISTANCES  run-jump %.3f m   slide-jump %.3f m   chained slide-jump %.3f m"
			% [_run_jump, _slide_jump, _chain_jump]
		)
	)
	print("")
	if _failures == 0:
		print("PASS - %d/%d cases" % [_cases, _cases])
		quit(0)
	else:
		print("FAIL - %d of %d cases failed" % [_failures, _cases])
		quit(1)


func _run_all() -> void:
	await _case_run_jump()
	await _case_slide_jump()
	await _case_chain_downslope()
	await _case_flat_spam_bleeds()
	await _case_downhill_builds()
	await _case_uphill_bleeds()
	await _case_air_control_keeps_speed()
	await _case_speed_cap()
	await _case_landing_into_slide_keeps_speed()
	await _case_camera_response_bounded()
	await _case_demo_course()
	_teardown()


# --- the three headline numbers ------------------------------------------------------


## Sprint to terminal, jump, measure the arc. This is the yardstick everything else is
## compared against, so it is taken at the top of a clean sprint with nothing else on.
func _case_run_jump() -> void:
	_spawn(_flat_world(), Vector3(0.0, 0.4, 0.0))
	await _hold(["move_forward", "sprint"], 3.0)
	Input.action_press(&"move_forward")
	Input.action_press(&"sprint")
	var take_speed: float = _player.speed
	var arc: Dictionary = await _jump_arc(2.5)
	_run_jump = float(arc[&"distance"])
	_release()
	print(
		(
			"      run-jump: takeoff %.2f m/s, air %.3f s, %.3f m"
			% [take_speed, float(arc[&"air"]), _run_jump]
		)
	)
	_report("run-jump leaves the ground", float(arc[&"air"]) > 0.3, "%.3f s" % float(arc[&"air"]))
	_report("run-jump lands again", bool(arc[&"landed"]), str(arc[&"landed"]))


## Sprint, crouch into the slide, let it settle for a beat, jump out of it. The beat is
## deliberate: jumping on the entry frame measures the entry boost, not the slide-jump.
func _case_slide_jump() -> void:
	_spawn(_flat_world(), Vector3(0.0, 0.4, 0.0))
	await _hold(["move_forward", "sprint"], 3.0)
	Input.action_press(&"move_forward")
	Input.action_press(&"crouch")
	for _i: int in int(HZ * 0.18):
		await physics_frame
	var take_speed: float = _player.speed
	var arc: Dictionary = await _jump_arc(2.5)
	_slide_jump = float(arc[&"distance"])
	_release()
	print(
		(
			"      slide-jump: takeoff %.2f m/s, air %.3f s, %.3f m"
			% [take_speed, float(arc[&"air"]), _slide_jump]
		)
	)
	_report(
		"slide-jump beats run-jump",
		_slide_jump > _run_jump * 1.10 or _baseline,
		"%.3f m vs %.3f m (want > %.3f)" % [_slide_jump, _run_jump, _run_jump * 1.10]
	)


## Three jumps down a 16-degree slope, holding crouch the whole way so every landing
## drops straight back into a slide. The measured arc is the THIRD, which is the only
## one that can show whether the chain compounds or merely repeats.
func _case_chain_downslope() -> void:
	# 400 m of face. Three links carry about 110 m and the last arc alone is over twenty,
	# so a 200 m slab ran the body off the end and reported a 60 m "jump" that was really
	# a fall into the catch slab. The air-time assertion below is the guard against that
	# happening again quietly.
	_spawn(_slope_world(deg_to_rad(16.0), 400.0), Vector3(0.0, 1.2, 0.0))
	await _hold(["move_forward", "sprint"], 2.2)
	Input.action_press(&"move_forward")
	Input.action_press(&"crouch")
	for _i: int in int(HZ * 0.35):
		await physics_frame
	var speeds := PackedFloat32Array()
	var arc: Dictionary = {}
	for hop: int in 3:
		arc = await _jump_arc(3.0)
		speeds.append(float(arc[&"takeoff"]))
		print(
			(
				"      link %d: takeoff %.2f, air %.3f s, %.2f m, landed %s, y %.1f"
				% [
					hop,
					float(arc[&"takeoff"]),
					float(arc[&"air"]),
					float(arc[&"distance"]),
					arc[&"landed"],
					_player.global_position.y,
				]
			)
		)
		if hop < 2:
			# Land, let the slide re-take, then go again. Crouch is never released.
			for _i: int in int(HZ * 0.30):
				await physics_frame
	_chain_jump = float(arc[&"distance"])
	_release()
	print(
		(
			"      chain: takeoff %.2f / %.2f / %.2f m/s, third arc %.3f s, %.3f m"
			% [speeds[0], speeds[1], speeds[2], float(arc[&"air"]), _chain_jump]
		)
	)
	_report(
		"chain compounds down the slope",
		speeds[2] > speeds[0] or _baseline,
		"third takeoff %.2f vs first %.2f m/s" % [speeds[2], speeds[0]]
	)
	_report(
		"chained slide-jump beats a flat slide-jump",
		_chain_jump > _slide_jump or _baseline,
		"%.3f m vs %.3f m" % [_chain_jump, _slide_jump]
	)
	# A jump, not a fall. Anything past two seconds means the body left the test face and
	# the distance above is measuring the drop off the end of it.
	_report(
		"the third arc is a jump and not a fall",
		float(arc[&"air"]) < 2.0 and bool(arc[&"landed"]),
		"%.3f s, landed %s" % [float(arc[&"air"]), arc[&"landed"]]
	)


# --- the guard rails -----------------------------------------------------------------


## Six slide-jumps on the flat with crouch held. Speed must be lower at the end than at
## the start, or flat-ground spam is a free speed generator and the whole economy is off.
func _case_flat_spam_bleeds() -> void:
	_spawn(_flat_world(), Vector3(0.0, 0.4, 0.0))
	await _hold(["move_forward", "sprint"], 3.0)
	Input.action_press(&"move_forward")
	Input.action_press(&"crouch")
	for _i: int in int(HZ * 0.18):
		await physics_frame
	var first: float = 0.0
	var last: float = 0.0
	for hop: int in 6:
		var arc: Dictionary = await _jump_arc(2.5)
		if hop == 0:
			first = float(arc[&"takeoff"])
		last = float(arc[&"takeoff"])
		for _i: int in int(HZ * 0.30):
			await physics_frame
	_release()
	print("      flat spam: first takeoff %.2f m/s, sixth %.2f m/s" % [first, last])
	_report(
		"flat-ground spam bleeds",
		last < first or _baseline,
		"sixth takeoff %.2f vs first %.2f m/s (want lower)" % [last, first]
	)


## A long shallow descent held in one slide. Speed at the bottom must be well above the
## sprint it was entered from, and it must not run away past the cap.
func _case_downhill_builds() -> void:
	_spawn(_slope_world(deg_to_rad(20.0), 200.0), Vector3(0.0, 1.2, 0.0))
	await _hold(["move_forward", "sprint"], 2.0)
	Input.action_press(&"move_forward")
	Input.action_press(&"crouch")
	var peak: float = 0.0
	for _i: int in int(HZ * 4.0):
		await physics_frame
		peak = maxf(peak, _player.speed)
	var n: Vector3 = _player.ground_normal
	_release()
	print(
		(
			"      downhill: peak %.2f m/s over 4 s of 20-degree descent, normal (%.3f %.3f %.3f)"
			% [peak, n.x, n.y, n.z]
		)
	)
	_report("downhill slide builds", peak > 12.0 or _baseline, "%.2f m/s (want > 12)" % peak)


## The same descent taken backwards. Uphill has to kill a slide, and quickly.
func _case_uphill_bleeds() -> void:
	_spawn(_slope_world(deg_to_rad(20.0), 200.0), Vector3(0.0, 1.2, 0.0))
	_player.yaw = PI
	await _hold(["move_forward", "sprint"], 2.0)
	Input.action_press(&"move_forward")
	Input.action_press(&"crouch")
	await physics_frame
	var entry: float = _player.speed
	for _i: int in int(HZ * 1.2):
		await physics_frame
	var after: float = _player.speed
	_release()
	print("      uphill: %.2f -> %.2f m/s over 1.2 s" % [entry, after])
	_report(
		"uphill slide bleeds",
		after < entry * 0.6 or _baseline,
		"%.2f -> %.2f m/s (want under %.2f)" % [entry, after, entry * 0.6]
	)


## Steer 35 degrees off the launch heading during a slide-jump. The heading must move
## and the speed must not collapse: air control that costs speed is not air control.
func _case_air_control_keeps_speed() -> void:
	_spawn(_flat_world(), Vector3(0.0, 0.4, 0.0))
	await _hold(["move_forward", "sprint"], 3.0)
	Input.action_press(&"move_forward")
	Input.action_press(&"crouch")
	for _i: int in int(HZ * 0.18):
		await physics_frame
	Input.action_press(&"jump")
	await physics_frame
	Input.action_release(&"jump")
	Input.action_release(&"crouch")
	var v0 := Vector2(_player.velocity.x, _player.velocity.z)
	# Full sideways stick, which is the hardest case for a steer that must not cost speed.
	Input.action_press(&"move_right")
	for _i: int in int(HZ * 0.45):
		await physics_frame
	var v1 := Vector2(_player.velocity.x, _player.velocity.z)
	_release()
	var turned: float = rad_to_deg(absf(v0.angle_to(v1)))
	var kept: float = v1.length() / maxf(v0.length(), 0.001)
	print("      air control: turned %.1f deg, kept %.1f%% of speed" % [turned, kept * 100.0])
	_report("air control steers", turned > 8.0 or _baseline, "%.1f deg (want > 8)" % turned)
	_report("air control keeps speed", kept > 0.95 or _baseline, "kept %.1f%%" % (kept * 100.0))


## Five seconds down a 30-degree face — long enough that the terminal speed the grade
## implies is far past the ceiling. Nothing may exceed the cap, ever, on any tick.
##
## The face is 220 m and no longer, and the run no longer than five seconds, because
## 19.5 m/s down 30 degrees loses 10 m of height a second and `void_y` is -80: a longer
## run respawns the body mid-measurement and the peak it reports is from before that.
func _case_speed_cap() -> void:
	_spawn(_slope_world(deg_to_rad(30.0), 220.0), Vector3(0.0, 1.2, 0.0))
	await _hold(["move_forward", "sprint"], 1.5)
	Input.action_press(&"move_forward")
	Input.action_press(&"crouch")
	var peak: float = 0.0
	for _i: int in int(HZ * 5.0):
		await physics_frame
		peak = maxf(peak, _player.speed)
	var cap: float = _player.slide.max_speed
	_release()
	print("      cap: peak %.2f m/s against a %.2f m/s ceiling" % [peak, cap])
	_report("slide cap holds", peak <= cap + 0.35, "%.2f m/s vs %.2f" % [peak, cap])
	_report(
		"cap is generous",
		peak > cap * 0.85 or _baseline,
		"reached %.0f%% of it" % (peak / cap * 100.0)
	)


## Land out of a slide-jump onto a downslope with crouch still held. The slide must
## re-take on contact and the speed must survive the landing.
func _case_landing_into_slide_keeps_speed() -> void:
	_spawn(_slope_world(deg_to_rad(16.0), 200.0), Vector3(0.0, 1.2, 0.0))
	await _hold(["move_forward", "sprint"], 2.2)
	Input.action_press(&"move_forward")
	Input.action_press(&"crouch")
	for _i: int in int(HZ * 0.35):
		await physics_frame
	var arc: Dictionary = await _jump_arc(3.0)
	var on_land: float = float(arc[&"land_speed"])
	var took: bool = false
	for _i: int in int(HZ * 0.25):
		await physics_frame
		took = took or _player.sliding
	var after: float = _player.speed
	_release()
	print(
		(
			"      relanding: takeoff %.2f, on contact %.2f, 0.25 s later %.2f m/s, re-slid %s"
			% [float(arc[&"takeoff"]), on_land, after, took]
		)
	)
	_report("slide re-takes on landing", took, str(took))
	_report(
		"landing keeps the speed",
		after > on_land * 0.90 or _baseline,
		"%.2f -> %.2f m/s" % [on_land, after]
	)


## The camera's slide response, read off the rig's own exports rather than off a frame.
## Roll and FOV are the two ways a speed feature makes people ill; both get a ceiling.
##
## The script is loaded here rather than named at the top of the file on purpose:
## `player_camera.gd` reads the `GameSettings` autoload, which does not exist while
## `--script` is compiling this file. Naming the class would fail the whole compile.
func _case_camera_response_bounded() -> void:
	var script: GDScript = load(CAMERA_SCRIPT)
	if script == null:
		_report("camera script loads", false, CAMERA_SCRIPT)
		return
	var rig: Object = script.new()
	# Worst case in one number: banked into the slide AND carrying 8 m/s of sideways
	# velocity, which is about as much strafe as the steer will give you.
	var roll_deg: float = rad_to_deg(
		(
			_prop(rig, &"strafe_roll", 0.0) * _prop(rig, &"slide_roll_mul", 1.0) * 8.0
			+ _prop(rig, &"slide_roll_bank", 0.0)
		)
	)
	# Sliding at the cap AND mid-launch, which is the widest the view ever opens.
	var fov_span: float = (
		_prop(rig, &"fov_slide_bonus", 0.0)
		+ _prop(rig, &"fov_slide_speed_gain", 0.0) * _prop(rig, &"fov_slide_speed_span", 0.0)
		+ _prop(rig, &"fov_slide_jump_kick", 0.0)
	)
	var rate: float = _prop(rig, &"fov_max_rate", 1e9)
	rig.free()
	print(
		(
			"      camera: %.2f deg of roll at 8 m/s sideways, %.1f deg of slide FOV, %.0f deg/s cap"
			% [roll_deg, fov_span, rate]
		)
	)
	_report("slide roll stays readable", roll_deg <= 10.0, "%.2f deg (want <= 10)" % roll_deg)
	_report("slide FOV stays readable", fov_span <= 26.0, "%.1f deg (want <= 26)" % fov_span)
	_report("FOV cannot swing fast", rate <= 140.0, "%.0f deg/s (want <= 140)" % rate)


## The same three questions asked of the REAL course instead of a purpose-built slab,
## because a slab has no lips, no seams and no ramp ends and every one of those is where
## a slide breaks. This case is the one that caught the slide skimming: over the slide
## run's 6 cm crest lip the body left the face and free-fell the whole 3.4 m descent at
## a dead-constant speed while still reporting `slide`.
func _case_demo_course() -> void:
	_teardown()
	var packed: PackedScene = load(DEMO_SCENE) as PackedScene
	if packed == null:
		_report("demo course loads", false, DEMO_SCENE)
		return
	_world = packed.instantiate() as Node3D
	root.add_child(_world)
	for _i: int in 60:
		await physics_frame
	_player = _world.get_node_or_null(^"Player") as PlayerController
	if _player == null:
		_report("demo course has a player", false, "no Player node")
		return

	var run: float = await _course_jump(false)
	var slid: float = await _course_jump(true)
	print("      on the course: run-jump %.3f m, slide-jump %.3f m" % [run, slid])
	_report(
		"slide-jump beats run-jump on the course",
		slid > run * 1.15,
		"%.3f m vs %.3f m" % [slid, run]
	)

	# The slide run's own 8 m, 23-degree descent, entered off its deck.
	_player.teleport(RUN_DECK, 0.0)
	await _hold(["move_forward", "sprint"], 0.55)
	Input.action_press(&"move_forward")
	Input.action_press(&"crouch")
	var entry: float = 0.0
	var peak: float = 0.0
	var airborne: int = 0
	for i: int in int(HZ * 0.85):
		await physics_frame
		if i == 2:
			entry = _player.speed
		peak = maxf(peak, _player.speed)
		if _player.sliding and not _player.grounded:
			airborne += 1
	_release()
	print(
		(
			"      slide run: entry %.2f m/s, peak %.2f m/s, %d airborne ticks"
			% [entry, peak, airborne]
		)
	)
	_report(
		"the descent actually builds",
		peak > entry * 1.15,
		"%.2f -> %.2f m/s down 23 degrees" % [entry, peak]
	)
	_report(
		"the descent is slid, not skimmed",
		airborne < int(HZ * 0.25),
		"%d of %d ticks off the face" % [airborne, int(HZ * 0.85)]
	)


## Sprint the clear west apron and jump, optionally out of a slide.
func _course_jump(slid: bool) -> float:
	_player.teleport(APRON, 0.0)
	_release()
	await _hold(["move_forward", "sprint"], 2.6)
	Input.action_press(&"move_forward")
	if slid:
		Input.action_press(&"crouch")
		for _i: int in int(HZ * 0.18):
			await physics_frame
	else:
		Input.action_press(&"sprint")
	var arc: Dictionary = await _jump_arc(3.0)
	_release()
	return float(arc[&"distance"])


# --- arc measurement -----------------------------------------------------------------


## Press jump, follow the body until the feet return to the ground, and report the arc.
## The take-off sample is the LAST grounded tick rather than the first airborne one:
## the jump tick still resolves against the floor, and starting the ruler one tick late
## loses a whole tick of travel — 0.16 m at 10 m/s, which is 4 % of a slide-jump.
func _jump_arc(timeout: float) -> Dictionary:
	Input.action_press(&"jump")
	var from: Vector3 = _player.global_position
	var takeoff: float = _player.speed
	var left: bool = false
	var air: float = 0.0
	var landed: bool = false
	var land_speed: float = 0.0
	var to: Vector3 = from
	for _i: int in int(timeout * HZ):
		await physics_frame
		Input.action_release(&"jump")
		if not left:
			if _player.grounded:
				from = _player.global_position
				takeoff = _player.speed
				continue
			left = true
			air = 0.0
			continue
		air += DT
		if not _player.grounded:
			continue
		landed = true
		to = _player.global_position
		land_speed = _player.speed
		break
	if not landed:
		to = _player.global_position
		land_speed = _player.speed
	return {
		&"distance": Vector2(to.x - from.x, to.z - from.z).length(),
		&"air": air,
		&"takeoff": takeoff,
		&"land_speed": land_speed,
		&"landed": landed,
	}


# --- world builders ------------------------------------------------------------------


static func _slab(size: Vector3, at: Vector3) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.collision_layer = GameLayers.WORLD
	body.position = at
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	body.add_child(shape)
	return body


static func _flat_world() -> Node3D:
	var w := Node3D.new()
	w.add_child(_slab(Vector3(400.0, 2.0, 400.0), Vector3(0.0, -1.0, 0.0)))
	return w


## One long face tilted about X so that running toward -Z runs DOWNHILL, plus a catch
## slab far below. The slab is rotated about its own centre, so the origin is on it.
##
## The sign matters and it is easy to get backwards. A -angle rotation about X takes the
## up normal to (0, cos a, -sin a); the plane through it is `y = z*tan(a) + c`, so height
## RISES with z and the downhill gradient points at -Z, which is where yaw 0 faces. Get
## it the other way round and every case here measures the uphill behaviour and reports
## it under the downhill name — which is exactly what happened on the first run, and it
## is why the ground normal is printed in the downhill case rather than assumed.
static func _slope_world(angle: float, length: float) -> Node3D:
	var w := Node3D.new()
	var body: StaticBody3D = _slab(Vector3(60.0, 2.0, length), Vector3(0.0, 0.0, 0.0))
	body.rotation = Vector3(-angle, 0.0, 0.0)
	w.add_child(body)
	w.add_child(_slab(Vector3(600.0, 2.0, 600.0), Vector3(0.0, -160.0, 0.0)))
	return w


# --- harness -------------------------------------------------------------------------


func _spawn(world: Node3D, at: Vector3) -> void:
	_teardown()
	_world = world
	root.add_child(_world)
	_player = _make_player()
	_world.add_child(_player)
	_player.global_position = at
	_player.yaw = 0.0


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


func _hold(actions: Array, seconds: float) -> void:
	for a: String in actions:
		Input.action_press(StringName(a))
	for _i: int in int(seconds * HZ):
		await physics_frame
	for a: String in actions:
		Input.action_release(StringName(a))


func _release() -> void:
	for a: String in ALL_ACTIONS:
		Input.action_release(StringName(a))


func _report(label: String, ok: bool, detail: String) -> void:
	_cases += 1
	if not ok:
		_failures += 1
	print("%s  %-40s %s" % ["ok  " if ok else "FAIL", label, detail])


## Read a float export that may not exist on an older build of the rig, so a baseline
## run against the pre-feature controller still produces its numbers instead of dying.
static func _prop(obj: Object, key: StringName, fallback: float) -> float:
	var v: Variant = obj.get(key)
	return fallback if v == null else float(v)
