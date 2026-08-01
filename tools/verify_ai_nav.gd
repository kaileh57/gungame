extends SceneTree
## Headless soak for AI-NAV: bake a real navmesh, run 100 agents on it through
## the scheduler and the path service, and report frame cost plus the achieved
## tick distribution.

const AGENTS: int = 100
const FRAMES: int = 1800
## Fixed step, so the measured tick rates are per simulated second at 60 fps
## rather than per uncapped headless frame.
const STEP: float = 1.0 / 60.0
const HALF: float = 60.0
const PILLARS: int = 24

var _root3d: Node3D = null
var _region: NavigationRegion3D = null
var _scheduler: AITickScheduler = null
var _service: AIPathService = null
var _ctx: AITickContext = null
var _bodies: Array[Node3D] = []
var _navs: Array[AINavigator] = []
var _handles: PackedInt32Array = PackedInt32Array()
var _dirs: PackedVector3Array = PackedVector3Array()
var _rng: XorShift32 = null
var _frame: int = 0
var _warm: int = 0
var _cost_us: PackedFloat32Array = PackedFloat32Array()
var _submits: int = 0
var _viewer: Vector3 = Vector3.ZERO
var _facing: Vector3 = Vector3.FORWARD
var _stuck_seen: int = 0
var _pop_sum: PackedInt64Array = PackedInt64Array([0, 0, 0, 0])
var _queue_peak: int = 0
var _queue_total: int = 0
var _frozen_stuck: int = 0
var _detours: int = 0
var _ready: bool = false


func _setup() -> void:
	_rng = XorShift32.new(20260728)
	_root3d = Node3D.new()
	get_root().add_child(_root3d)
	_build_world()
	_scheduler = AITickScheduler.new()
	_service = AIPathService.new()
	_root3d.add_child(_scheduler)
	_root3d.add_child(_service)
	_ctx = AITickContext.new()
	# Deliberately starved: three queries a frame for a hundred hunting agents.
	_service.requests_per_frame = 3
	# Tight radii so all four buckets carry a real population on a 120 m field.
	_scheduler.near_radius = 14.0
	_scheduler.mid_radius = 32.0
	_scheduler.far_radius = 62.0
	_spawn()
	print("bake: polygons=", _region.navigation_mesh.get_polygon_count(), " agents=", AGENTS)


func _process(_real_delta: float) -> bool:
	var delta: float = STEP
	if not _ready:
		_warm += 1
		if _warm == 1:
			_setup()
			return false
		if _warm < 14:
			return false
		_ready = true
		_unit_checks()
		return false
	_frame += 1
	_viewer = Vector3(sin(float(_frame) * 0.004) * 30.0, 0.0, cos(float(_frame) * 0.004) * 30.0)
	_facing = -_viewer.normalized()
	var t0: int = Time.get_ticks_usec()
	_ai_frame(delta)
	_cost_us.append(float(Time.get_ticks_usec() - t0))
	if _frame >= FRAMES:
		_report()
		_service.flush()
		_navs.clear()
		_bodies.clear()
		_root3d.free()
		quit()
		return true
	return false


func _ai_frame(delta: float) -> void:
	for i: int in AGENTS:
		_scheduler.set_agent_position(_handles[i], _bodies[i].global_position)
	_scheduler.begin_frame(delta, _viewer, _facing)
	_scheduler.begin_context(_ctx)
	for d: int in _scheduler.due_count():
		_think(_scheduler.due_agent(d) as Node3D, _scheduler.due_delta(d), _scheduler.due_kind(d))
	_service.service(delta)
	_queue_peak = maxi(_queue_peak, _service.queued())
	_queue_total += _service.queued()
	for b: int in AITickScheduler.BUCKET_COUNT:
		_pop_sum[b] += _scheduler.bucket_population(b)
	for i: int in AGENTS:
		_move(i, delta)


func _think(body: Node3D, agent_delta: float, kind: int) -> void:
	var i: int = body.get_meta(&"row")
	var nav: AINavigator = _navs[i]
	var p: Vector3 = body.global_position
	nav.advance(agent_delta, p)
	if nav.is_stuck():
		_stuck_seen += 1
		if i == 0:
			_frozen_stuck += 1
		nav.unstick(_rng)
		_detours += 1
	else:
		# Every agent hunts the moving viewer from its own slot on a ring, which is
		# the worst case for the budget: a hundred goals that move every frame.
		var a: float = TAU * float(i) / float(AGENTS)
		var slot: Vector3 = Vector3(cos(a), 0.0, sin(a)) * (3.0 + 0.06 * float(i))
		nav.set_goal(nav.snap_to_mesh(_viewer + slot))
	var fighting: bool = kind == AITickScheduler.KIND_FULL
	if nav.wants_path(fighting) and _ctx.take_path():
		_submits += 1
		_service.submit(i, nav.path_urgency())
	_dirs[i] = nav.steer_direction(p)


func _move(i: int, delta: float) -> void:
	if i == 0:
		return  # Wedged on purpose, to prove the no-progress detector fires.
	var body: Node3D = _bodies[i]
	var dir: Vector3 = _dirs[i]
	if dir.length_squared() < 1e-6:
		return
	var nav: AINavigator = _navs[i]
	var facing: Vector3 = -body.global_transform.basis.z
	var speed: float = 3.4 * nav.speed_scale(facing, dir)
	var v: Vector3 = nav.avoid(dir * speed)
	if v.length_squared() < 1e-8:
		v = dir * speed
	body.global_position += v * delta
	body.look_at(body.global_position + dir, Vector3.UP)


func _random_point() -> Vector3:
	var x: float = _rng.next_range(-HALF + 4.0, HALF - 4.0)
	var z: float = _rng.next_range(-HALF + 4.0, HALF - 4.0)
	return Vector3(x, 0.0, z)


func _spawn() -> void:
	_dirs.resize(AGENTS)
	for i: int in AGENTS:
		var body: Node3D = Node3D.new()
		body.set_meta(&"row", i)
		_root3d.add_child(body)
		body.global_position = _random_point()
		var agent: NavigationAgent3D = NavigationAgent3D.new()
		body.add_child(agent)
		var profile: AISpeciesProfile = AISpeciesProfile.new()
		profile.body_radius = 0.4
		profile.height = 1.8
		profile.run_speed = 3.4
		var nav: AINavigator = AINavigator.new()
		nav.setup(agent, profile, true)
		_service.register(i, nav)
		nav.set_goal(_random_point(), true)
		_navs.append(nav)
		_bodies.append(body)
		_handles.append(_scheduler.add_agent(body, body.global_position))


## Direct checks of the pieces that a soak run cannot prove on its own.
func _unit_checks() -> void:
	var svc: AIPathService = AIPathService.new()
	svc.requests_per_frame = 8
	var made: Array[AINavigator] = []
	for i: int in 40:
		var n: AINavigator = AINavigator.new()
		made.append(n)
		svc.register(1000 + i, n)
		svc.submit(1000 + i, 1.0)
		svc.submit(1000 + i, 2.0)
	print("coalesce: 80 submits over 40 agents -> queued=", svc.queued())
	var committed: int = svc.service(0.016)
	print("budget: service granted=", committed, " remaining=", svc.queued())
	svc.free()

	var probe: AINavigator = AINavigator.new()
	probe.setup(null, null, false)
	probe.set_goal(Vector3(10, 0, 0))
	print(
		"no-agent navigator: wants_path=",
		probe.wants_path(false),
		" steer=",
		probe.steer_direction(Vector3.ZERO)
	)

	var sc: AINavigator = _navs[0]
	print(
		"speed_scale straight=",
		snappedf(sc.speed_scale(Vector3.FORWARD, Vector3.FORWARD), 0.001),
		" 90deg=",
		snappedf(sc.speed_scale(Vector3.FORWARD, Vector3.RIGHT), 0.001),
		" reverse=",
		snappedf(sc.speed_scale(Vector3.FORWARD, Vector3.BACK), 0.001)
	)

	var ctx: AITickContext = AITickContext.new()
	for i: int in 10:
		ctx.queue_noise(Vector3(0.2 * float(i), 0, 0), 20.0, 0.4 + 0.05 * float(i), 1, 7)
	ctx.queue_noise(Vector3(40, 0, 0), 20.0, 1.0, 1, 8)
	ctx.queue_noise(Vector3(0, 0, 0), 20.0, 1.0, 1, 9, AITickContext.EVENT_CRACK)
	print(
		"noise merge: 12 reports -> ",
		ctx.noise_count(),
		" events, loudest=",
		ctx.noise_loudness(0),
		" kinds=",
		[ctx.noise_kind(0), ctx.noise_kind(1), ctx.noise_kind(2)]
	)
	_churn_check()


## Add and remove agents under the scheduler's nose and check the row/handle/
## bucket bookkeeping survives it. `remove_agent` swaps the last row down and has
## to repair three different indices, which is exactly the sort of thing that
## works for a thousand frames and then does not.
func _churn_check() -> void:
	var sc: AITickScheduler = AITickScheduler.new()
	sc.agents_per_frame = 64
	var live: Array[int] = []
	var owner_of: Dictionary = {}
	var rng: XorShift32 = XorShift32.new(99)
	for i: int in 200:
		var marker: RefCounted = RefCounted.new()
		var h: int = sc.add_agent(
			marker, Vector3(rng.next_range(-60, 60), 0, rng.next_range(-60, 60))
		)
		live.append(h)
		owner_of[h] = marker
	var mismatches: int = 0
	for step: int in 120:
		sc.begin_frame(
			1.0 / 60.0,
			Vector3(rng.next_range(-40, 40), 0, rng.next_range(-40, 40)),
			Vector3.FORWARD
		)
		for d: int in sc.due_count():
			if sc.due_agent(d) != owner_of.get(sc.due_handle(d), null):
				mismatches += 1
		for k: int in 3:
			if live.size() > 20 and rng.chance(0.5):
				var victim: int = live[rng.next_int(0, live.size() - 1)]
				live.erase(victim)
				owner_of.erase(victim)
				sc.remove_agent(victim)
			else:
				var m: RefCounted = RefCounted.new()
				var nh: int = sc.add_agent(
					m, Vector3(rng.next_range(-60, 60), 0, rng.next_range(-60, 60))
				)
				live.append(nh)
				owner_of[nh] = m
	var pop: int = 0
	for b: int in AITickScheduler.BUCKET_COUNT:
		pop += sc.bucket_population(b)
	print(
		"churn: live=",
		live.size(),
		" scheduler agents=",
		sc.agent_count(),
		" bucket sum=",
		pop,
		" handle/agent mismatches=",
		mismatches
	)
	sc.free()


func _report() -> void:
	var n: int = _cost_us.size()
	var sorted: Array = Array(_cost_us)
	sorted.sort()
	var total: float = 0.0
	for v: float in _cost_us:
		total += v
	var ticks: int = 0
	for b: int in AITickScheduler.BUCKET_COUNT:
		ticks += _scheduler.bucket_ticks(b)
	var secs: float = _scheduler.clock()
	print("--- frames=", n, " simulated=", snappedf(secs, 0.01), "s agents=", AGENTS, " ---")
	print(
		"ai cost per frame: mean=",
		snappedf(total / float(n) / 1000.0, 0.001),
		"ms  median=",
		snappedf(float(sorted[n / 2]) / 1000.0, 0.001),
		"ms  p95=",
		snappedf(float(sorted[int(float(n) * 0.95)]) / 1000.0, 0.001),
		"ms  max=",
		snappedf(float(sorted[n - 1]) / 1000.0, 0.001),
		"ms"
	)
	print("total agent ticks=", ticks, "  mean per frame=", snappedf(float(ticks) / float(n), 0.01))
	var names: PackedStringArray = ["NEAR", "MID", "FAR", "DORMANT"]
	for b: int in AITickScheduler.BUCKET_COUNT:
		var bt: int = _scheduler.bucket_ticks(b)
		var mean_pop: float = float(_pop_sum[b]) / float(n)
		print(
			"  ",
			names[b],
			" mean pop=",
			snappedf(mean_pop, 0.1),
			" ticks=",
			bt,
			" (",
			snappedf(100.0 * float(bt) / float(maxi(ticks, 1)), 0.1),
			"%)  hz/agent=",
			snappedf(float(bt) / secs / maxf(mean_pop, 0.001), 0.01)
		)
	print(
		"paths: submitted=",
		_submits,
		" committed=",
		_service.committed_total(),
		" dropped=",
		_service.dropped_total(),
		" queued=",
		_service.queued(),
		" per frame=",
		snappedf(float(_service.committed_total()) / float(n), 0.01),
		" queue mean=",
		snappedf(float(_queue_total) / float(n), 0.01),
		" peak=",
		_queue_peak
	)
	print(
		"recovery: stuck detections=",
		_stuck_seen,
		" detours=",
		_detours,
		"  frozen agent 0: detections=",
		_frozen_stuck,
		" streak=",
		_navs[0].stuck_streak,
		" detouring=",
		_navs[0].detouring
	)
	var moving: int = 0
	var pathed: int = 0
	for i: int in AGENTS:
		if _dirs[i].length_squared() > 1e-6:
			moving += 1
		if _navs[i].path_points().size() > 1:
			pathed += 1
	print("agents with a live corridor=", pathed, " steering=", moving)


func _build_world() -> void:
	var src: NavigationMeshSourceGeometryData3D = NavigationMeshSourceGeometryData3D.new()
	src.add_faces(_quad(HALF), Transform3D.IDENTITY)
	for i: int in PILLARS:
		var x: float = _rng.next_range(-HALF + 8.0, HALF - 8.0)
		var z: float = _rng.next_range(-HALF + 8.0, HALF - 8.0)
		var w: float = _rng.next_range(2.0, 7.0)
		src.add_faces(_box(Vector3(w, 4.0, w)), Transform3D(Basis.IDENTITY, Vector3(x, 0.0, z)))
	var mesh: NavigationMesh = NavigationMesh.new()
	mesh.cell_size = 0.25
	mesh.cell_height = 0.2
	mesh.agent_radius = 0.45
	mesh.agent_height = 1.8
	mesh.agent_max_climb = 0.4
	NavigationServer3D.bake_from_source_geometry_data(mesh, src)
	_region = NavigationRegion3D.new()
	_region.navigation_mesh = mesh
	_root3d.add_child(_region)


func _quad(h: float) -> PackedVector3Array:
	return PackedVector3Array(
		[
			Vector3(-h, 0, -h),
			Vector3(-h, 0, h),
			Vector3(h, 0, h),
			Vector3(-h, 0, -h),
			Vector3(h, 0, h),
			Vector3(h, 0, -h)
		]
	)


func _box(size: Vector3) -> PackedVector3Array:
	var m: BoxMesh = BoxMesh.new()
	m.size = size
	var arr: Array = m.get_mesh_arrays()
	var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
	var out: PackedVector3Array = PackedVector3Array()
	for i: int in idx.size():
		out.append(verts[idx[i]] + Vector3(0.0, size.y * 0.5, 0.0))
	return out
