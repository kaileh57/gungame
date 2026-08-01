@tool
extends SceneTree
## Headless stress harness for the VFX hub. Fires tens of thousands of effects
## through the real `res://data/vfx/vfx.tscn`, then reports peak pool occupancy,
## object-count drift per shot and whether every cap held.
##
## It runs on the dummy renderer, so it proves the CPU half: ring reuse, pool
## caps, the shell integrator, the light and flash decay, and — the number that
## matters most — that a shot allocates nothing. The GPU half (particle
## integration, billboarding, the shaders) is not exercised here and is not
## claimed to be.
##
## Run headless:
##   godot --headless --path <project> --script res://tools/vfx/vfx_stress.gd

const HUB_SCENE: String = "res://data/vfx/vfx.tscn"

## Frames of settling before anything is measured or fired.
const WARMUP_FRAMES: int = 8
const TEST_FRAMES: int = 600
## Shots per frame. At 600 frames that is 7,200 rounds — a belt-fed gun held down
## for two solid minutes of game time.
const SHOTS_PER_FRAME: int = 12
## Frames between blasts.
const BLAST_EVERY: int = 20
## Frames spent watching four cases fly, bounce and lie down once the gunfire
## stops. At 60 Hz that is four seconds, which is longer than any arc takes.
const SETTLE_FRAMES: int = 240
const FRAME_DELTA: float = 1.0 / 60.0

var _hub: VfxService = null
var _muzzle: Node3D = null
var _frame: int = 0
var _shots: int = 0
var _blasts: int = 0
var _particles_asked: int = 0
var _objects_at_start: int = 0
var _memory_at_start: int = 0
var _rng := RandomNumberGenerator.new()


func _initialize() -> void:
	_rng.seed = 0x57_1e55
	var packed: PackedScene = load(HUB_SCENE)
	if packed == null:
		push_error("vfx_stress: %s is missing. Run res://tools/build_vfx_assets.gd." % HUB_SCENE)
		quit(1)
		return
	_hub = packed.instantiate() as VfxService
	if _hub == null:
		push_error("vfx_stress: the hub scene did not instantiate as a VfxService.")
		quit(1)
		return
	root.add_child(_hub)

	var camera := Camera3D.new()
	camera.name = "StressCamera"
	camera.position = Vector3(0.0, 1.65, 8.0)
	camera.current = true
	root.add_child(camera)

	_muzzle = Node3D.new()
	_muzzle.name = "StressMuzzle"
	_muzzle.position = Vector3(0.3, 1.5, 7.4)
	root.add_child(_muzzle)
	process_frame.connect(_on_frame)


## The hub is stepped by hand at a fixed 60 Hz rather than at whatever rate the
## dummy renderer happens to spin at, so the shell arcs, the flash decay and the
## light falloff are all measured against the frame budget they will really see.
func _on_frame() -> void:
	if _hub.is_processing():
		_hub.set_process(false)
	_frame += 1
	if _frame <= WARMUP_FRAMES:
		_hub._process(FRAME_DELTA)
		return
	if _frame == WARMUP_FRAMES + 1:
		_objects_at_start = int(Performance.get_monitor(Performance.OBJECT_COUNT))
		_memory_at_start = int(Performance.get_monitor(Performance.MEMORY_STATIC))
	if _frame == WARMUP_FRAMES + TEST_FRAMES + 1:
		_begin_settle()
	if _frame > WARMUP_FRAMES + TEST_FRAMES:
		if _frame > WARMUP_FRAMES + TEST_FRAMES + SETTLE_FRAMES:
			_report()
			quit()
			return
		_hub._process(FRAME_DELTA)
		return
	_fire_frame()
	_hub._process(FRAME_DELTA)


## Stop shooting, drop four cases at known velocities and let them run. Their
## resting height is the one thing the arc has to get right: a case that comes to
## rest below the floor has fallen through it, and one above is hovering.
func _begin_settle() -> void:
	var shells: VfxShellEject = _hub.get_node(^"Shells") as VfxShellEject
	shells.clear()
	VfxService.set_ground_y(0.0)
	_muzzle.position = Vector3(0.0, 1.5, 0.0)
	VfxService.spawn_shell(_muzzle, Vector3(2.4, 1.6, 0.4))
	VfxService.spawn_shell(_muzzle, Vector3(-1.1, 3.2, 0.0))
	VfxService.spawn_shell(_muzzle, Vector3(0.0, 0.0, 0.0))
	VfxService.spawn_shell(_muzzle, Vector3(4.5, 0.4, -2.0))


## One frame's worth of gunfire: a burst of shots, each with a flash, a case, a
## tracer and an impact on a rotating surface, plus a blast every twentieth frame.
func _fire_frame() -> void:
	for _i: int in SHOTS_PER_FRAME:
		var yaw: float = _rng.randf() * TAU
		var target := Vector3(sin(yaw) * 24.0, _rng.randf() * 3.0, -cos(yaw) * 24.0)
		var muzzle_pos: Vector3 = _muzzle.global_position
		var kind: int = _rng.randi_range(0, VFXSurface.COUNT - 1)

		VfxService.spawn_muzzle_flash(_muzzle, _rng.randf_range(0.05, 0.34))
		VfxService.spawn_shell(_muzzle, Vector3(2.4, 1.6, 0.4))
		VfxService.spawn_tracer(muzzle_pos, target, 900.0)
		VfxService.spawn_impact(target, (muzzle_pos - target).normalized(), kind)
		_particles_asked += VFXSurface.SPARK_COUNT[kind]
		_shots += 1

	if _frame % BLAST_EVERY == 0:
		var yaw: float = _rng.randf() * TAU
		VfxService.spawn_explosion(Vector3(sin(yaw) * 18.0, 0.4, -cos(yaw) * 18.0), 4.1)
		_particles_asked += 112
		_blasts += 1
	if _frame % 3 == 0:
		VfxService.spawn_puff(Vector3(0.0, 1.0, -14.0), 3, 0.34, 0.9, 3.4, true)


func _report() -> void:
	var objects: int = int(Performance.get_monitor(Performance.OBJECT_COUNT))
	var memory: int = int(Performance.get_monitor(Performance.MEMORY_STATIC))
	var counters: PackedInt32Array = _hub.counters()
	var decals: VFXDecalPool = _hub.get_node(^"Decals") as VFXDecalPool
	var tracers: VFXTracerPool = _hub.get_node(^"Tracers") as VFXTracerPool
	var sparks: VFXSparkField = _hub.get_node(^"Sparks") as VFXSparkField
	var spray: VFXSparkField = _hub.get_node(^"Spray") as VFXSparkField
	var fine: VFXSmokeField = _hub.get_node(^"SmokeFine") as VFXSmokeField
	var heavy: VFXSmokeField = _hub.get_node(^"SmokeHeavy") as VFXSmokeField
	var shells: VfxShellEject = _hub.get_node(^"Shells") as VfxShellEject
	var muzzles: VfxMuzzle = _hub.get_node(^"Muzzles") as VfxMuzzle
	var blasts: VfxExplosion = _hub.get_node(^"Blasts") as VfxExplosion

	print("--- vfx_stress ---")
	print("frames %d, shots %d, blasts %d" % [_frame - WARMUP_FRAMES - 1, _shots, _blasts])
	print(
		(
			"objects %d -> %d (delta %d over %d shots = %.6f per shot)"
			% [
				_objects_at_start,
				objects,
				objects - _objects_at_start,
				_shots,
				float(objects - _objects_at_start) / maxf(float(_shots), 1.0)
			]
		)
	)
	print(
		(
			"static memory %d -> %d bytes (delta %d = %.3f bytes per shot)"
			% [
				_memory_at_start,
				memory,
				memory - _memory_at_start,
				float(memory - _memory_at_start) / maxf(float(_shots), 1.0)
			]
		)
	)
	print(
		(
			"tracers written %d into %d slots; decals written %d into %d slots"
			% [
				counters[0],
				tracers.multimesh.instance_count,
				counters[1],
				decals.multimesh.instance_count
			]
		)
	)
	print("impacts %d, flashes %d" % [counters[2], counters[3]])
	print(
		(
			"shells live %d, peak %d of %d slots"
			% [counters[4], counters[5], shells.multimesh.instance_count]
		)
	)
	print("muzzle flashes peak %d of %d slots" % [counters[6], muzzles.budget])
	print(
		(
			"blast lights peak %d of %d, heat quads peak %d of %d"
			% [counters[7], blasts.light_budget, counters[8], blasts.shimmer_budget]
		)
	)
	print(
		(
			"particles asked %d against pools sparks %d, spray %d, smoke %d + %d"
			% [_particles_asked, sparks.amount, spray.amount, fine.amount, heavy.amount]
		)
	)
	var caps_hold: bool = (
		counters[5] <= shells.multimesh.instance_count
		and counters[6] <= muzzles.budget
		and counters[7] <= blasts.light_budget
		and counters[8] <= blasts.shimmer_budget
	)
	var rest_height: float = shells.multimesh.mesh.get_aabb().size.x * 0.5 * shells.casing_scale
	var settled: int = 0
	for i: int in 4:
		var y: float = shells.origin_of(i).y
		if absf(y - rest_height) < 0.0005:
			settled += 1
		print(
			(
				"settle case %d: rest y %.6f m, expected %.6f m, moving %s"
				% [i, y, rest_height, shells.is_moving(i)]
			)
		)
	print("caps hold: %s; cases settled: %d of 4" % ["yes" if caps_hold else "NO", settled])
