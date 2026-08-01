extends SceneTree
## Acceptance run for the movement playground. Loads the baked scene and proves,
## against the live physics world, that it is what the builder claims it is.
##
## Four things get checked, in the order they can fail:
##   STRUCTURE — the scene has a player, a console, six full desks, three ladders
##               and five gates, and every knob found a `MovementTuning` row.
##   GEOMETRY  — a ray down at every stencilled number lands at that number. This
##               is the check that catches a mesh and a collider drifting apart,
##               and it is why every station's heights are read back rather than
##               assumed.
##   SEAL      — a grid of rays over the whole yard. Any miss is a hole in the
##               apron, which is the one defect a playground cannot have.
##
## Everything is stated in world coordinates because the LAYOUT is what changes:
## the course was re-anchored so it sits in front of the bench rather than around
## the rim of the yard, and this file is the second opinion on where it landed.
##   TRAVERSAL — the player is actually driven at the ledge bank and stood on the
##               slope fan, with real input, and the results are reported as the
##               measured bands rather than as a pass/fail.
##
## Run headless for the assertions:
##   godot --headless --path <project> --script res://demos/movement/verify_movement.gd
## Run windowed for the frame rate, which headless cannot tell you:
##   godot --path <project> --script res://demos/movement/verify_movement.gd -- fps

const SCENE_PATH: String = "res://demos/movement/movement.tscn"
## Physics frames given to each traversal attempt. At 60 Hz that is two seconds,
## comfortably more than a run-up and a vault.
const RUN_FRAMES: int = 120
## Frames of frame-rate history sampled per viewpoint, and the frames discarded
## before sampling starts.
const FPS_FRAMES: int = 600
const WARMUP_FRAMES: int = 300
## Quality preset the frame-rate pass forces before it measures anything.
const FPS_PRESET: String = "High"
## Yard the seal test sweeps, and its spacing in metres. The apron is pushed north
## of the origin, so the z band is not symmetric.
const SEAL_HX: float = 38.0
const SEAL_Z0: float = -34.0
const SEAL_Z1: float = 26.0
const SEAL_STEP: float = 2.5
## Where the demo puts you, re-derived. The frame-rate pass stands here, and every
## traversal run starts from a teleport rather than from the spawn.
const SPAWN: Vector3 = Vector3(0.0, 1.65, 16.8)
## Tolerance on a read-back height, metres. Ten times the physics skin.
const HEIGHT_EPS: float = 0.02

var _root: Node3D = null
var _player: PlayerController = null
var _space: PhysicsDirectSpaceState3D = null
var _query: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.new()
var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0


func _initialize() -> void:
	_query.collision_mask = GameLayers.WORLD
	_run()


func _run() -> void:
	await process_frame
	var scene: PackedScene = load(SCENE_PATH) as PackedScene
	if scene == null:
		printerr("verify_movement: %s does not exist. Run the builder." % SCENE_PATH)
		quit(1)
		return
	_root = scene.instantiate() as Node3D
	root.add_child(_root)
	await process_frame
	await physics_frame

	_player = _root.get_node_or_null(^"Player") as PlayerController
	_space = _root.get_world_3d().direct_space_state

	_check_structure()
	_check_geometry()
	_check_seal()
	# Driving the body takes about a minute of real time and is the same result
	# with or without a window, so a frame-rate run skips it.
	if not OS.get_cmdline_user_args().has("fps"):
		await _check_ledges()
		await _check_slopes()
		await _check_ladder()
	await _measure_fps()

	print("")
	if _failures.is_empty():
		print("verify_movement: PASS — %d checks." % _checks)
		quit(0)
		return
	for line: String in _failures:
		printerr("verify_movement: %s" % line)
	print("verify_movement: FAIL — %d of %d checks." % [_failures.size(), _checks])
	quit(1)


# ---------------------------------------------------------------- assertions


func _ok(condition: bool, what: String) -> void:
	_checks += 1
	if not condition:
		_failures.append(what)


## Height of the topmost solid over (x, z), or NAN. Same question the controller's
## own `PlayerProbe.top_at` asks, asked the same way.
func _top(x: float, z: float, from_y: float = 40.0) -> float:
	_query.from = Vector3(x, from_y, z)
	_query.to = Vector3(x, -20.0, z)
	var hit: Dictionary = _space.intersect_ray(_query)
	if hit.is_empty():
		return NAN
	return (hit["position"] as Vector3).y


func _at(x: float, z: float, expected: float, what: String, from_y: float = 40.0) -> void:
	var got: float = _top(x, z, from_y)
	var good: bool = not is_nan(got) and absf(got - expected) <= HEIGHT_EPS
	_ok(good, "%s: expected %.3f m, read %.3f m" % [what, expected, got])


# ----------------------------------------------------------------- structure


func _check_structure() -> void:
	_ok(_player != null, "no Player in the scene")
	_ok(_root.get_node_or_null(^"ScavWorld") != null, "no ScavWorld instance")
	_ok(_root.get_node_or_null(^"Course/CourseMesh") != null, "no course mesh")
	_ok(_root.get_node_or_null(^"Hands") != null, "no interactor")

	var console := _root.get_node_or_null(^"Console") as MovementConsole
	_ok(console != null, "no MovementConsole")
	if console != null:
		var bound: Dictionary = console.get(&"_sliders")
		var rows: int = MovementTuning.rows().size()
		_ok(bound.size() == rows, "%d sliders bound, expected %d" % [bound.size(), rows])
		_ok(console.get(&"_preset") != null, "preset dial not bound")
		_ok(console.get(&"_slowmo") != null, "slow-motion lever not bound")
		_ok(console.get(&"_readout") != null, "readout not resolved")

	_ok(
		PlayerLadder.registry().size() == 3,
		"expected 3 ladders, found %d" % PlayerLadder.registry().size()
	)
	var gates: int = 0
	for child: Node in _root.get_node(^"SpeedLoop").get_children():
		if child is SplitGate:
			gates += 1
	_ok(gates == 5, "expected 5 split gates, found %d" % gates)
	print(
		(
			"verify_movement: structure — %d ladders, %d gates"
			% [PlayerLadder.registry().size(), gates]
		)
	)


# ------------------------------------------------------------------ geometry


## Every stencilled number, read back off the collision world. The builder's
## constants are re-derived here rather than imported, so a typo in one of them
## has to be made twice to get through.
func _check_geometry() -> void:
	var ledges: PackedFloat32Array = _ledges()
	for i: int in ledges.size():
		_at(_ledge_x(i), -15.0, ledges[i], "ledge %d" % i)
		# Between two blocks is apron, or the bank is one wall with paint on it.
		if i > 0:
			_at(_ledge_x(i) + 1.3, -15.0, 0.0, "ledge %d gap" % i)

	var gaps: PackedFloat32Array = _gaps()
	for j: int in gaps.size():
		var x: float = _gap_x(j)
		var d: float = gaps[j]
		_at(x, 2.5 - 1.6, 1.2, "gap lane %d take-off" % j)
		_at(x, -0.7 - d - 1.8, 1.2, "gap lane %d landing" % j)
		# The gap itself must be empty all the way to the apron.
		_at(x, -0.7 - d * 0.5, 0.0, "gap lane %d void" % j)

	var angles: PackedFloat32Array = _slopes()
	for j: int in angles.size():
		var a: float = deg_to_rad(angles[j])
		var run: float = clampf(2.6 / tan(a), 1.2, 9.0)
		var x: float = 5.0 + 2.5 * float(angles.size() - 1 - j)
		_at(x, -13.0 - run - 1.6, run * tan(a), "slope %d deck" % int(angles[j]))
		# Halfway up the ramp the surface must be exactly on the plane the angle
		# describes — this is the check that a rotated collider and a rotated mesh
		# box agree, and since the lanes were turned to face the bench it is also
		# the check that `CourseKit.ramp` yaws without shearing.
		_at(x, -13.0 - run * 0.5, run * 0.5 * tan(a), "slope %d midpoint" % int(angles[j]))

	var rises := PackedFloat32Array([0.12, 0.22, 0.34, 0.46])
	var counts := PackedInt32Array([21, 12, 8, 6])
	for f: int in rises.size():
		var x: float = 15.0 + 4.2 * float(f)
		var top: float = rises[f] * float(counts[f])
		_at(x, 0.5 - 0.32 * float(counts[f]) - 1.5, top, "stair %d landing" % f)
		_at(x, 0.5 - 0.32 * 0.5, rises[f], "stair %d first tread" % f)

	# Each deck is read from just above itself; a ray from the sky would only ever
	# find the top one. The decks run north of the wall the ladders are bolted to.
	for y: float in [3.0, 6.0, 9.0]:
		_at(0.0, -23.0, y, "tower deck %.0f" % y, y + 0.6)

	var clears := PackedFloat32Array([1.70, 1.40, 1.22])
	for c: int in clears.size():
		var mid: float = -16.3 - 5.6 * (float(c) + 0.5)
		# From under the roof, or the ray finds the roof instead of the floor.
		_at(33.0, mid, 0.0, "tunnel %d floor" % c, 1.0)
		_ok(_ceiling(33.0, mid, clears[c]), "tunnel %d roof is not at %.2f m" % [c, clears[c]])

	# The bench itself. The overlook has to be exactly 1.15 m over the apron or the
	# step back onto it stops being the auto vault the layout claims it is.
	_at(0.0, 16.8, 1.60, "overlook top")
	_at(0.0, 9.9, 0.45, "console apron")
	print("verify_movement: geometry — %d height probes" % _checks)


## Roof height over a point, found by shooting up from the floor.
func _ceiling(x: float, z: float, expected: float) -> bool:
	_query.from = Vector3(x, 0.05, z)
	_query.to = Vector3(x, 12.0, z)
	var hit: Dictionary = _space.intersect_ray(_query)
	if hit.is_empty():
		return false
	return absf((hit["position"] as Vector3).y - expected) <= HEIGHT_EPS


## A grid of rays over the whole yard. Every one must land on something, or there
## is a hole in the floor.
func _check_seal() -> void:
	var holes: int = 0
	var probes: int = 0
	var x: float = -SEAL_HX
	while x <= SEAL_HX:
		var z: float = SEAL_Z0
		while z <= SEAL_Z1:
			probes += 1
			if is_nan(_top(x, z, 60.0)):
				holes += 1
			z += SEAL_STEP
		x += SEAL_STEP
	_ok(holes == 0, "%d of %d yard probes found no floor" % [holes, probes])
	print("verify_movement: seal — %d probes, %d holes" % [probes, holes])


# ----------------------------------------------------------------- traversal


## The layout, re-derived rather than imported so a typo in the builder has to be
## made twice to get through.
func _ledges() -> PackedFloat32Array:
	return PackedFloat32Array([0.20, 0.40, 0.58, 0.75, 0.90, 1.07, 1.32, 1.60, 2.05, 2.80, 3.40])


func _gaps() -> PackedFloat32Array:
	return PackedFloat32Array([1.5, 2.0, 2.5, 3.0, 3.5, 4.0, 4.5, 5.0, 5.5])


func _slopes() -> PackedFloat32Array:
	return PackedFloat32Array([10.0, 18.0, 26.0, 32.0, 38.0, 43.0, 46.0, 50.0, 55.0, 62.0])


## Tallest block inboard, the rank running west from it.
func _ledge_x(i: int) -> float:
	return -4.6 - 2.6 * float(10 - i)


## Longest gap west, so the lanes descend left to right across the frame.
func _gap_x(j: int) -> float:
	return 2.9 * 4.0 - 2.9 * float(j)


## Drive the player at every ledge, twice: once running, once running with jump
## held. The first pass measures the auto-vault band, the second measures the
## held vault taken from the top of a jump, which is the true ceiling.
func _check_ledges() -> void:
	var heights: PackedFloat32Array = _ledges()
	var auto_top: float = 0.0
	var held_top: float = 0.0
	for i: int in heights.size():
		var x: float = _ledge_x(i)
		if await _charge_ledge(x, heights[i], false):
			auto_top = heights[i]
		if await _charge_ledge(x, heights[i], true):
			held_top = heights[i]
	print(
		(
			"verify_movement: traversal — running stands on %.2f m, holding jump stands on %.2f m"
			% [auto_top, held_top]
		)
	)
	# `mantle_auto_rise` is 1.32 and `mantle_manual_rise` 2.05 from standing; the
	# held vault taken at the 1.07 m apex reaches into the high twenties. Anything
	# else means the stencilled bands are lying.
	_ok(
		auto_top >= 1.32 - 0.01,
		(
			"running only reached %.2f m, expected 1.32 — the auto vault never fires. " % auto_top
			+ "PlayerController._vault_triggers gates on `_speed_now`, which is sampled at "
			+ "the top of the tick, one tick AFTER `_resolve_xz` set `_bumped` and clipped "
			+ "the velocity into the wall. It is therefore always ~0 when the gate is read. "
			+ "The bump's own speed has to be recorded where `_bumped` is set."
		)
	)
	_ok(held_top >= 2.80 - 0.01, "holding jump only reached %.2f m, expected 2.80" % held_top)
	_ok(held_top < 3.40, "3.40 m was reached, and nothing on this course should reach it")


## True if the player ever stood ON the block. Standing is the test, not height:
## a 1.07 m jump passes THROUGH the height of a 0.90 m ledge without ever being
## on it, and a course that counted that would grade itself far too generously.
##
## The bank is charged from the SOUTH now, which is the side the bench is on and
## the direction the demo opens facing: forward is (-sin yaw, 0, -cos yaw), so yaw
## zero runs at -Z.
##
## THE RUN-UP IS 2.30 m AND THAT IS NOT ARBITRARY. Holding jump makes the body hop
## the whole way in, and the held vault is only worth 2.80 m when the wall is hit
## near the apex; from four metres out the same run arrives on the way down and
## grades the bank at 1.32. The block's south face is at -13.45, so the mark is
## -11.15.
func _charge_ledge(x: float, height: float, hold_jump: bool) -> bool:
	_player.teleport(Vector3(x, 0.05, -11.15), 0.0)
	Input.action_press(&"move_forward")
	Input.action_press(&"sprint")
	if hold_jump:
		Input.action_press(&"jump")
	var stood: bool = false
	for _f: int in RUN_FRAMES:
		await physics_frame
		if _player.grounded and _player.global_position.y >= height - 0.08:
			stood = true
		# Past the far face of the block; nothing after this is about the ledge.
		if _player.global_position.z < -16.9:
			break
	Input.action_release(&"move_forward")
	Input.action_release(&"sprint")
	Input.action_release(&"jump")
	for _f: int in 8:
		await physics_frame
	return stood


## Stand on each lane of the fan and see whether it holds you. `floor_max_angle`
## is 46 degrees, so the fan should hold to 46 and shed you from 50.
func _check_slopes() -> void:
	var angles: PackedFloat32Array = _slopes()
	var held := PackedStringArray()
	var shed := PackedStringArray()
	for j: int in angles.size():
		var a: float = deg_to_rad(angles[j])
		var run: float = clampf(2.6 / tan(a), 1.2, 9.0)
		var x: float = 5.0 + 2.5 * float(angles.size() - 1 - j)
		var z: float = -13.0 - run * 0.5
		var y: float = run * 0.5 * tan(a)
		_player.teleport(Vector3(x, y + 0.06, z), 0.0)
		for _f: int in 60:
			await physics_frame
		if _player.global_position.y > y - 0.25:
			held.append("%d" % int(angles[j]))
		else:
			shed.append("%d" % int(angles[j]))
	print("verify_movement: slopes — held %s, shed %s" % [", ".join(held), ", ".join(shed)])
	_ok(held.has("46"), "the 46-degree lane did not hold, but floor_max_angle is 46")
	_ok(shed.has("50"), "the 50-degree lane held, and it should not")


## Climb the bottom flight. The tower's clearances are the tightest thing on the
## course — the deck edge stops 0.55 m short of the rung plane, and the climber is
## 0.34 m of radius held 0.20 m off the ladder's origin — so this is the one piece
## of geometry that has to be proved by climbing it rather than by measuring it.
func _check_ladder() -> void:
	# Facing -Z, into the wall the ladder is bolted to. The climb face is the south
	# one now: it is what the aisle looks at, so it is what the ladders are on.
	_player.teleport(Vector3(0.0, 0.05, -19.25), 0.0)
	Input.action_press(&"move_forward")
	var peak: float = 0.0
	var attached: bool = false
	for _f: int in 300:
		await physics_frame
		peak = maxf(peak, _player.global_position.y)
		attached = attached or _player.ladder != null
	Input.action_release(&"move_forward")
	var landed: Vector3 = _player.global_position
	for _f: int in 20:
		await physics_frame
	print(
		(
			"verify_movement: ladder — attached %s, peak %.2f m, ended at %.2f m"
			% [attached, peak, landed.y]
		)
	)
	_ok(attached, "the player never attached to the bottom ladder")
	_ok(peak >= 3.0, "the climb only reached %.2f m, and the first deck is at 3.00" % peak)
	_ok(landed.y >= 2.9, "the climber did not top out onto the deck, ending at %.2f m" % landed.y)


## Frame rate, twice: standing at the console, which is the only place all
## thirty-six sliders and the live screen are on screen at once, and standing in
## the north-west corner looking across the whole yard, which is the widest view
## the demo has. V-sync is switched off so the number is the cost of the frame and
## not the refresh rate of whatever monitor this ran on.
func _measure_fps() -> void:
	if DisplayServer.get_name() == "headless":
		print("verify_movement: frame rate — skipped, this run is headless")
		return
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	# Measured at High rather than at whatever the machine last saved, so the number
	# means something to somebody else.
	var settings: Node = root.get_node_or_null(^"GameSettings")
	if settings != null:
		settings.call(&"apply_preset", FPS_PRESET)
		await process_frame
		print(
			(
				"verify_movement: quality %s, render scale %.2f, %dx%d"
				% [
					FPS_PRESET,
					float(settings.get(&"render_scale")),
					DisplayServer.window_get_size().x,
					DisplayServer.window_get_size().y,
				]
			)
		)
	await _sample_fps("console", SPAWN, 0.0)
	await _sample_fps("whole yard", Vector3(-34.0, 0.1, 22.0), -2.5)
	# Everything this demo added, switched off. The difference between this and the
	# line above is the course's own cost; the rest belongs to the environment.
	(_root.get_node(^"Course") as Node3D).visible = false
	(_root.get_node(^"Console") as Node3D).visible = false
	(_root.get_node(^"SpeedLoop") as Node3D).visible = false
	await _sample_fps("empty world", Vector3(-34.0, 0.1, 22.0), -2.5)
	(_root.get_node(^"Course") as Node3D).visible = true
	(_root.get_node(^"Console") as Node3D).visible = true
	(_root.get_node(^"SpeedLoop") as Node3D).visible = true


func _sample_fps(what: String, at: Vector3, yaw: float) -> void:
	_player.teleport(at, yaw)
	# Long warm-up. The first frame that draws a Label3D compiles its font atlas and
	# the first frame that draws the readout compiles the CRT shader; both are
	# one-off costs of arriving somewhere, and neither is a frame rate.
	for _f: int in WARMUP_FRAMES:
		await process_frame
	var samples := PackedFloat32Array()
	samples.resize(FPS_FRAMES)
	var total: float = 0.0
	for f: int in FPS_FRAMES:
		await process_frame
		var fps: float = Engine.get_frames_per_second()
		samples[f] = fps
		total += fps
	# The one per cent low, not the single worst frame: one 500 ms stall while a
	# shader compiles says nothing about how the demo runs.
	samples.sort()
	var worst: float = samples[maxi(1, FPS_FRAMES / 100) - 1]
	var draws: int = RenderingServer.get_rendering_info(
		RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME
	)
	var prims: int = RenderingServer.get_rendering_info(
		RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME
	)
	print(
		(
			"verify_movement: %s — mean %.0f fps, 1%% low %.0f fps, %d draws, %d prims"
			% [what, total / float(FPS_FRAMES), worst, draws, prims]
		)
	)
