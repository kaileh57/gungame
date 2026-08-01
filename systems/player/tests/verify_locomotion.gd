extends SceneTree
## Headless acceptance run for the player controller. Ten cases over purpose-built
## collision geometry, each asserting a number rather than "it did not crash".
##
## The point of the physics cases is the three failure modes a hand-rolled kinematic
## controller actually dies of: tunnelling through thin floors at terminal velocity,
## sticking in an inside corner, and hanging on a slope too steep to stand on. The
## remaining cases pin the feel constants — terminal walk and sprint speed, jump apex,
## coyote window, slide boost, stair climb — so a tuning pass that breaks one of them
## says so instead of being discovered by hand three demos later.
##
## Run:
##   godot --headless --path <project> --script res://systems/player/tests/verify_locomotion.gd
## Exits 0 when every case passes, 1 otherwise.

const HZ: float = 60.0
const DT: float = 1.0 / HZ
const FLOOR_MAX_ANGLE: float = 0.8029
const ALL_ACTIONS: PackedStringArray = [
	"move_forward", "move_back", "move_left", "move_right", "jump", "crouch", "sprint"
]

var _world: Node3D = null
var _player: PlayerController = null
var _failures: int = 0
var _cases: int = 0


func _initialize() -> void:
	Engine.physics_ticks_per_second = int(HZ)
	Engine.max_fps = 0
	await _run_all()
	print("")
	if _failures == 0:
		print("PASS — %d/%d cases" % [_cases, _cases])
		quit(0)
	else:
		print("FAIL — %d of %d cases failed" % [_failures, _cases])
		quit(1)


func _run_all() -> void:
	_math_cases()
	await _case_walk_terminal_speed()
	await _case_sprint_terminal_speed()
	await _case_stop_distance()
	await _case_jump_apex()
	await _case_coyote_jump()
	await _case_stairs()
	await _case_steep_slope_slides_off()
	await _case_inside_corner()
	await _case_thin_floor_no_tunnel()
	await _case_slide_boost()
	_teardown()


# --- pure math -----------------------------------------------------------------------


## The locomotion math needs no world, so it is checked against closed forms rather than
## against itself: the fixed point of accelerate/friction, and the strafe gain.
func _math_cases() -> void:
	var v := Vector3.ZERO
	for _i: int in 600:
		v = PlayerLocomotion.apply_friction(v, 10.5, 3.0, DT)
		v = PlayerLocomotion.accelerate(v, 0.0, -1.0, 4.35, 13.5, DT)
	_check("math/walk fixed point", PlayerLocomotion.planar_speed(v), 4.35, 0.01, "m/s")

	v = Vector3(0.0, 0.0, -4.35)
	for _i: int in 300:
		v = PlayerLocomotion.apply_friction(v, 10.5 * 1.45, 3.0, DT)
	_check("math/idle brake to rest", PlayerLocomotion.planar_speed(v), 0.0, 1e-6, "m/s")

	# Air-strafe: 1.15 m/s wish at 92 accel, wish held perpendicular to velocity. Speed
	# must climb, because that is the whole trick and any total-speed clamp kills it.
	v = Vector3(0.0, 0.0, -8.0)
	for _i: int in 60:
		var s: float = PlayerLocomotion.planar_speed(v)
		var perp := Vector2(-v.z / s, v.x / s)
		v = PlayerLocomotion.accelerate(v, perp.x, perp.y, 1.15, 92.0, DT)
	var gain: float = PlayerLocomotion.planar_speed(v) - 8.0
	_report("math/air-strafe gain over 1 s", gain > 0.35, "%.3f m/s (want > 0.35)" % gain)

	var boosted: Vector3 = PlayerLocomotion.slide_entry_velocity(
		Vector3(0.0, 0.0, -5.1), 1.30, 8.2, 19.5
	)
	_check("math/slide floor at 5.1 in", PlayerLocomotion.planar_speed(boosted), 8.2, 1e-4, "m/s")

	var slope := Vector3(0.3, 0.9539392, 0.0).normalized()
	var p: Vector2 = PlayerLocomotion.project_on_slope(1.0, 0.0, slope)
	_check("math/slope projection unit", p.length(), 1.0, 1e-5, "")

	var term := Vector3.ZERO
	for _i: int in 600:
		term = PlayerLocomotion.apply_gravity(term, 21.5, -60.0, DT)
	_check("math/terminal velocity", term.y, -60.0, 1e-4, "m/s")


# --- physics cases -------------------------------------------------------------------


func _case_walk_terminal_speed() -> void:
	_spawn(_flat_world(), Vector3(0.0, 0.4, 0.0))
	await _hold(["move_forward"], 3.0)
	_check("walk terminal speed", _player.speed, 4.35, 0.06, "m/s")
	_report("walk stays grounded", _player.grounded, str(_player.grounded))
	_check("walk feet stay on floor", _player.global_position.y, 0.0, 0.02, "m")
	_release()


func _case_sprint_terminal_speed() -> void:
	_spawn(_flat_world(), Vector3(0.0, 0.4, 0.0))
	await _hold(["move_forward", "sprint"], 3.0)
	_check("sprint terminal speed", _player.speed, 7.5, 0.08, "m/s")
	_release()


func _case_stop_distance() -> void:
	_spawn(_flat_world(), Vector3(0.0, 0.4, 0.0))
	await _hold(["move_forward"], 2.0)
	var from: Vector3 = _player.global_position
	await _hold([], 1.5)
	var slid: float = (
		Vector2(_player.global_position.x - from.x, _player.global_position.z - from.z).length()
	)
	_report("stop distance from walk", slid < 0.75, "%.3f m (want < 0.75)" % slid)
	_check("comes fully to rest", _player.speed, 0.0, 1e-6, "m/s")
	_release()


func _case_jump_apex() -> void:
	_spawn(_flat_world(), Vector3(0.0, 0.4, 0.0))
	await _hold([], 0.5)
	var base: float = _player.global_position.y
	Input.action_press(&"jump")
	var apex: float = base
	for _i: int in int(HZ * 1.2):
		await physics_frame
		apex = maxf(apex, _player.global_position.y)
		Input.action_release(&"jump")
	# v^2 / 2g = 6.8^2 / 43 = 1.0754 m, minus the half-tick of gravity applied on the
	# jump frame itself.
	_check("jump apex", apex - base, 1.0754, 0.06, "m")
	_report("lands again", _player.grounded, str(_player.grounded))
	_release()


func _case_coyote_jump() -> void:
	# Walk off the end of a 4 m platform and press jump 0.05 s after the feet leave it —
	# inside the 0.11 s window, so it must still launch.
	_spawn(_platform_world(6.0, 6.0, 4.0), Vector3(0.0, 4.1, 2.0))
	await _hold([], 0.5)
	Input.action_press(&"move_back")
	var left_at: int = -1
	var pressed: bool = false
	var launched: float = 0.0
	for i: int in int(HZ * 1.5):
		await physics_frame
		if left_at < 0:
			if not _player.grounded:
				left_at = i
			continue
		if not pressed and float(i - left_at) * DT >= 0.05:
			pressed = true
			Input.action_release(&"move_back")
			Input.action_press(&"jump")
			continue
		if pressed:
			Input.action_release(&"jump")
			launched = maxf(launched, _player.velocity.y)
	_report("coyote jump fires", launched > 5.0, "vy = %.2f m/s (want > 5)" % launched)
	_release()


func _case_stairs() -> void:
	# Sixteen 0.22 m risers on a 0.36 m run — a 31-degree flight, steeper than anything a
	# demo will build, taken at a sprint. What is being measured is not "does it get up
	# there" but whether it gets up there without losing height, losing speed, or throwing
	# the camera.
	var top: float = 16.0 * 0.22
	_spawn(_stair_world(16, 0.22, 0.36), Vector3(0.0, 0.4, 1.2))
	var prev_y: float = 0.0
	var max_drop: float = 0.0
	var max_cam: float = 0.0
	var min_speed: float = 99.0
	var climbed: bool = false
	for i: int in int(HZ * 5.0):
		Input.action_press(&"move_forward")
		Input.action_press(&"sprint")
		await physics_frame
		var y: float = _player.global_position.y
		if i < int(HZ * 0.5):
			prev_y = y
			continue
		max_drop = maxf(max_drop, prev_y - y)
		prev_y = y
		max_cam = maxf(max_cam, absf(_player.cam_y))
		min_speed = minf(min_speed, _player.speed)
		if y >= top - 0.03:
			climbed = true
			break
	_report("stair climb reaches top", climbed, "%.3f m of %.2f" % [_player.global_position.y, top])
	_report("no backslide on stairs", max_drop < 0.02, "max per-tick drop %.4f m" % max_drop)
	_report("stair smoother bounded", max_cam < 0.40, "max cam_y %.3f m (want < 0.40)" % max_cam)
	_report("keeps pace on stairs", min_speed > 4.0, "min speed %.2f m/s (want > 4.0)" % min_speed)
	_release()


func _case_steep_slope_slides_off() -> void:
	# A 65-degree face, well past the 46-degree floor limit. Landing on it must convert
	# into downhill motion — never a standable surface, and never a body pinned to it
	# while gravity piles into a velocity that has nowhere to go.
	_spawn(_ramp_world(deg_to_rad(65.0)), Vector3(0.0, 6.0, 0.0))
	var stood: int = 0
	var stalled: int = 0
	var last: Vector3 = _player.global_position
	for i: int in int(HZ * 2.0):
		await physics_frame
		var p: Vector3 = _player.global_position
		if p.y > -20.0 and i > int(HZ * 0.5):
			if _player.grounded:
				stood += 1
			if p.distance_to(last) < 0.004:
				stalled += 1
		last = p
	var moved: float = absf(_player.global_position.x)
	_report("steep face never standable", stood == 0, "%d grounded ticks on the face" % stood)
	_report("slides off steep face", moved > 1.0, "%.2f m downhill (want > 1.0)" % moved)
	_report("never pins to the face", stalled == 0, "%d stalled ticks" % stalled)
	_release()


func _case_inside_corner() -> void:
	# Sprint diagonally into a 90-degree inside corner for two seconds, then walk out.
	# Getting wedged shows up as either penetration or as being unable to leave.
	_spawn(_corner_world(), Vector3(-2.0, 0.4, -2.0))
	_player.yaw = deg_to_rad(-135.0)
	await _hold(["move_forward", "sprint"], 2.0)
	var p: Vector3 = _player.global_position
	var pen_x: float = maxf(0.0, p.x - (-_player.radius))
	var pen_z: float = maxf(0.0, p.z - (-_player.radius))
	_report(
		"no corner penetration",
		pen_x < 0.02 and pen_z < 0.02,
		"x %.4f z %.4f past the wall faces" % [pen_x, pen_z]
	)
	_release()
	_player.yaw = deg_to_rad(45.0)
	await _hold(["move_forward"], 1.0)
	var escaped: float = _player.global_position.distance_to(p)
	_report("can leave the corner", escaped > 2.0, "%.2f m (want > 2.0)" % escaped)
	_release()


func _case_thin_floor_no_tunnel() -> void:
	# 5 cm slab, dropped onto from 60 m. Impact speed is the -60 m/s terminal, which at
	# 60 Hz is a full metre of travel per tick — eight times the slab thickness.
	_spawn(_thin_floor_world(0.05), Vector3(0.0, 60.0, 0.0))
	var min_y: float = 60.0
	for _i: int in int(HZ * 6.0):
		await physics_frame
		min_y = minf(min_y, _player.global_position.y)
		if _player.grounded:
			break
	_report(
		"terminal drop does not tunnel",
		_player.grounded and min_y > -0.05,
		"grounded %s, lowest y %.4f m" % [_player.grounded, min_y]
	)
	_check("rests on the slab", _player.global_position.y, 0.05, 0.03, "m")
	_release()


func _case_slide_boost() -> void:
	_spawn(_flat_world(), Vector3(0.0, 0.4, 0.0))
	await _hold(["move_forward", "sprint"], 3.0)
	var entry: float = _player.speed
	Input.action_press(&"crouch")
	await physics_frame
	_report("slide engages", _player.sliding, str(_player.sliding))
	_check("slide boost", _player.speed, clampf(entry * 1.30, 8.2, 19.5), 0.15, "m/s")
	_report(
		"slide state exposed",
		_player.state.kind == PlayerState.Kind.SLIDE,
		PlayerState.name_of(_player.state.kind)
	)
	await _hold([], 2.0)
	_report("slide ends", not _player.sliding, str(_player.sliding))
	_release()


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
	w.add_child(_slab(Vector3(80.0, 2.0, 80.0), Vector3(0.0, -1.0, 0.0)))
	return w


static func _platform_world(size_x: float, size_z: float, height: float) -> Node3D:
	var w := Node3D.new()
	w.add_child(_slab(Vector3(size_x, 2.0, size_z), Vector3(0.0, height - 1.0, 0.0)))
	w.add_child(_slab(Vector3(80.0, 2.0, 80.0), Vector3(0.0, -21.0, 0.0)))
	return w


## Steps are 1.2 m deep in Y and overlap the one below, so the flight is a solid mass
## with no seam a foot can catch in — the same rule the world builders follow.
static func _stair_world(count: int, rise: float, run: float) -> Node3D:
	var w := Node3D.new()
	w.add_child(_slab(Vector3(80.0, 2.0, 80.0), Vector3(0.0, -1.0, 0.0)))
	for i: int in count:
		var top: float = float(i + 1) * rise
		var depth: float = 2.0 + top
		w.add_child(
			_slab(
				Vector3(6.0, depth, run + 0.6),
				Vector3(0.0, top - depth * 0.5, -float(i) * run - run * 0.5)
			)
		)
	var landing: float = float(count) * rise
	w.add_child(
		_slab(
			Vector3(6.0, 2.0 + landing, 8.0),
			Vector3(0.0, landing - (2.0 + landing) * 0.5, -float(count) * run - 4.0)
		)
	)
	return w


static func _ramp_world(angle: float) -> Node3D:
	var w := Node3D.new()
	var body: StaticBody3D = _slab(Vector3(20.0, 2.0, 20.0), Vector3(0.0, 0.0, 0.0))
	body.rotation = Vector3(0.0, 0.0, angle)
	w.add_child(body)
	w.add_child(_slab(Vector3(200.0, 2.0, 200.0), Vector3(0.0, -30.0, 0.0)))
	return w


static func _corner_world() -> Node3D:
	var w := Node3D.new()
	w.add_child(_slab(Vector3(80.0, 2.0, 80.0), Vector3(0.0, -1.0, 0.0)))
	w.add_child(_slab(Vector3(40.0, 6.0, 2.0), Vector3(0.0, 3.0, 1.0)))
	w.add_child(_slab(Vector3(2.0, 6.0, 40.0), Vector3(1.0, 3.0, 0.0)))
	return w


static func _thin_floor_world(thickness: float) -> Node3D:
	var w := Node3D.new()
	w.add_child(_slab(Vector3(60.0, thickness, 60.0), Vector3(0.0, thickness * 0.5, 0.0)))
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


func _check(label: String, got: float, want: float, tol: float, unit: String) -> void:
	_report(label, absf(got - want) <= tol, "%.4f %s (want %.4f +/- %.4f)" % [got, unit, want, tol])


func _report(label: String, ok: bool, detail: String) -> void:
	_cases += 1
	if not ok:
		_failures += 1
	print("%s  %-34s %s" % ["ok  " if ok else "FAIL", label, detail])
