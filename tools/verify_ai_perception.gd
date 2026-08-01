extends SceneTree
## Correctness and cost harness for AI-PERCEPTION.
##
## Two halves. The first asserts the things that are easy to get quietly wrong —
## the broad phase handing back a duplicate row from a colliding hash bucket, the
## alert machine flickering across a threshold, a heard contact reaching a
## confidence it is not allowed to reach. The second stands N agents in a field of
## occluders and times a full perception tick at 10 through 200 bodies. The broad
## phase is measured on its own, both ways, back to back inside one tick — timing
## it across two separate runs put the two arms in different halves of the
## process and the ordering bias swamped the effect being measured.
##
## Every class under test is loaded by path at run time and held untyped, and the
## file names none of them statically. That is not stylistic: `--script` installs
## this main loop before the engine registers the project's autoloads, so a static
## reference to anything that transitively names `Factions` fails to compile, and
## the broken script is what stays in the resource cache for the rest of the
## process. Loading on the first physics frame, after startup has finished, is the
## only way to measure the real code. Shipping code never sees this — it is loaded
## from a scene, long after the autoloads exist.
##
## Run headless:
##   godot --headless --path <project> --script res://tools/verify_ai_perception.gd

const AGENT_COUNTS: PackedInt32Array = [10, 30, 60, 100, 200]
## Timed ticks per configuration, after the warmup.
const TICKS: int = 300
const WARMUP: int = 30
## Half-width of the square the bodies are scattered over, metres. Sized so a
## hundred bodies sit at roughly the density the ash flats run at, which is what
## decides whether the broad phase has anything to cull.
const FIELD: float = 200.0
const OCCLUDERS: int = 64
## `AIAlertness.State`, restated because the enum cannot be named from here.
const S_SUSPICIOUS: int = 1
const S_SEARCHING: int = 2
const S_ENGAGED: int = 3
const S_LOSING: int = 4
const TICK: float = 1.0 / 60.0

var _tuning: Object = null
var _bus: GDScript = null
var _grid_script: GDScript = null
var _memory_script: GDScript = null
var _alert_script: GDScript = null
var _index_script: GDScript = null
var _perception_script: GDScript = null
var _target_script: GDScript = null
var _species_script: GDScript = null
var _rng_script: GDScript = null
var _world_layer: int = 1
var _world: Node3D = null
var _index: Object = null
var _perception: Array = []
var _memory: Array = []
var _alert: Array = []
var _eye: PackedVector3Array = PackedVector3Array()
var _forward: PackedVector3Array = PackedVector3Array()
var _cursor: PackedInt32Array = PackedInt32Array()
var _rng: Object = null
var _config: int = 0
var _tick: int = 0
var _us_index: int = 0
var _us_look: int = 0
var _us_listen: int = 0
var _us_state: int = 0
var _us_bp_grid: int = 0
var _us_bp_scan: int = 0
var _rays: int = 0
var _seen: int = 0
var _failures: int = 0


## Timed work lives in the physics callback: `intersect_ray` is only legal while
## the physics server is stepped, and a raycast measured outside that window is
## measuring an error message.
func _physics_process(delta: float) -> bool:
	if _bus == null:
		_boot()
		return false
	if _config >= AGENT_COUNTS.size():
		_teardown()
		quit()
		return true
	_run_tick(delta)
	_tick += 1
	if _tick < WARMUP + TICKS:
		return false
	_report()
	_config += 1
	if _config >= AGENT_COUNTS.size():
		return false
	_setup(AGENT_COUNTS[_config])
	return false


func _boot() -> void:
	_bus = load("res://systems/ai/perception/ai_noise_bus.gd")
	_grid_script = load("res://systems/ai/perception/ai_target_grid.gd")
	_memory_script = load("res://systems/ai/ai_memory.gd")
	_alert_script = load("res://systems/ai/ai_alertness.gd")
	_index_script = load("res://systems/ai/ai_target_index.gd")
	_perception_script = load("res://systems/ai/ai_perception.gd")
	_target_script = load("res://systems/ai/ai_target.gd")
	_species_script = load("res://systems/ai/ai_species_profile.gd")
	_rng_script = load("res://core/xorshift32.gd")
	_world_layer = load("res://core/game_layers.gd").WORLD
	# Through `shared`, so the baked res://data/ai/perception_tuning.tres is what
	# is actually measured rather than a private copy of the code defaults.
	_tuning = load("res://systems/ai/perception/ai_perception_tuning.gd").shared()
	_rng = _rng_script.new(0x5EED)
	print("=== AI-PERCEPTION VERIFY ===")
	_check_noise_bus()
	_check_grid()
	_check_alertness()
	_check_memory()
	print("--- correctness: %s ---" % ("PASS" if _failures == 0 else "%d FAILURES" % _failures))
	print("")
	print(
		(
			"agents  index_us  look_us  listen_us  fsm_us  total_us  us/agent"
			+ "   bp_grid_us  bp_scan_us  rays   seen"
		)
	)
	_build_world()
	_setup(AGENT_COUNTS[0])


# --- correctness ----------------------------------------------------------


func _expect(ok: bool, what: String) -> void:
	if not ok:
		_failures += 1
		printerr("FAIL: ", what)


func _check_noise_bus() -> void:
	_bus.reset()
	var e: float = _tuning.report_reference_energy
	_expect(
		is_equal_approx(_bus.radius_for_energy(e), _tuning.report_reference_radius),
		"reference energy must give the reference radius"
	)
	_expect(
		absf(_bus.radius_for_energy(e * 4.0) - _tuning.report_reference_radius * 2.0) < 0.01,
		"four times the energy must double the radius"
	)
	var decade: float = _bus.loudness_for_energy(e * 10.0) - _bus.loudness_for_energy(e)
	_expect(
		absf(decade - _tuning.report_loudness_per_decade) < 0.01,
		"one decade of energy must add one decade of loudness, got %.4f" % decade
	)
	var a: int = _bus.emit_gunshot(Vector3.ZERO, 1500.0, 0, 7, false)
	var b: int = _bus.emit_gunshot(Vector3(0.4, 0.0, 0.0), 1500.0, 0, 7, false)
	_expect(a == b, "two shots inside the merge distance must collapse into one event")
	var c: int = _bus.emit_gunshot(Vector3(40.0, 0.0, 0.0), 1500.0, 0, 7, false)
	_expect(c == a + 1, "a shot outside the merge distance must be its own event")
	_expect(_bus.event_source(c) == 7, "event source must survive the ring")
	var quiet: float = _bus.radius_for_energy(1500.0) * _tuning.report_suppressed_scale
	_bus.emit_gunshot(Vector3(0.0, 0.0, 90.0), 1500.0, 0, 7, true)
	_expect(
		absf(_bus.event_radius(_bus.cursor() - 1) - quiet) < 0.01,
		"a suppressed report must be scaled down"
	)
	var capacity: int = _bus.CAPACITY
	var base: int = _bus.cursor()
	for i: int in capacity + 8:
		_bus.emit_gunshot(Vector3(float(i) * 9.0, 0.0, 500.0), 900.0, 1, i, false)
	_expect(not _bus.has(base), "an event pushed out of the ring must stop being readable")
	_expect(_bus.has(_bus.cursor() - 1), "the newest event must still be readable")
	_expect(
		_bus.oldest() == _bus.cursor() - capacity,
		"the oldest sequence must trail the head by exactly the ring depth"
	)
	_bus.reset()
	_expect(_bus.cursor() == 0, "reset must rewind the sequence")


func _check_grid() -> void:
	var grid: Object = _grid_script.new(_tuning.grid_cell_size)
	var pos: PackedVector3Array = PackedVector3Array()
	var r: Object = _rng_script.new(99)
	for i: int in 400:
		pos.append(Vector3(r.next_range(-400.0, 400.0), 0.0, r.next_range(-400.0, 400.0)))
	grid.build(pos, pos.size())
	var out: PackedInt32Array = PackedInt32Array()
	var mismatches: int = 0
	var duplicates: int = 0
	for probe: int in 60:
		var c: Vector3 = Vector3(r.next_range(-400.0, 400.0), 0.0, r.next_range(-400.0, 400.0))
		var radius: float = r.next_range(3.0, 60.0)
		grid.query_sphere(c, radius, out)
		var got: Dictionary = {}
		for k: int in out.size():
			if got.has(out[k]):
				duplicates += 1
			got[out[k]] = true
		for row: int in pos.size():
			var inside: bool = absf(pos[row].x - c.x) <= radius and absf(pos[row].z - c.z) <= radius
			if inside and not got.has(row):
				mismatches += 1
	_expect(duplicates == 0, "the grid returned %d duplicate rows" % duplicates)
	_expect(mismatches == 0, "the grid missed %d rows a brute-force sweep found" % mismatches)
	grid.build(pos, 0)
	_expect(grid.query_sphere(Vector3.ZERO, 10.0, out) == 0, "an empty grid must return nothing")


func _check_alertness() -> void:
	var fsm: Object = _alert_script.new()
	fsm.apply_tuning(_tuning)
	# Park awareness on the promotion threshold and jitter it by a hair for twenty
	# seconds. A machine without hysteresis flips on every other tick. The counter
	# lives in a packed array because lambdas capture by value.
	var flips: PackedInt32Array = PackedInt32Array([0])
	fsm.state_changed.connect(func(_a: int, _b: int) -> void: flips[0] += 1)
	var r: Object = _rng_script.new(4242)
	for i: int in 1200:
		fsm.tick(TICK, _tuning.suspicious_enter + (r.next() - 0.5) * 0.02, false, false)
	_expect(
		flips[0] <= 2,
		"threshold jitter produced %d transitions; hysteresis is not holding" % flips[0]
	)
	_expect(fsm.state == S_SUSPICIOUS, "jitter at the threshold must settle alert")

	var fsm2: Object = _alert_script.new()
	fsm2.apply_tuning(_tuning)
	for i: int in 60:
		fsm2.tick(TICK, 1.3, false, true)
	_expect(
		fsm2.state != S_ENGAGED,
		"awareness from hearing alone must never reach Engaged without eyes on"
	)
	for i: int in 60:
		fsm2.tick(TICK, 1.3, true, true)
	_expect(fsm2.state == S_ENGAGED, "a confirmed sighting must engage")
	var lost: float = 0.0
	while fsm2.state == S_ENGAGED and lost < 30.0:
		fsm2.tick(TICK, 0.9, false, true)
		lost += TICK
	_expect(fsm2.state == S_LOSING, "losing sight must fall through to Losing")
	_expect(
		absf(lost - _tuning.lose_grace) < 0.1,
		"Losing came at %.2f s, expected the %.2f s grace" % [lost, _tuning.lose_grace]
	)
	var guard: int = 0
	while fsm2.state != S_SEARCHING and guard < 4000:
		fsm2.tick(TICK, 0.4, false, true)
		guard += 1
	_expect(fsm2.state == S_SEARCHING, "Losing must give up into Searching")
	var step_at_entry: int = fsm2.search_step
	for i: int in int(_tuning.search_dwell * 60.0) + 2:
		fsm2.tick(TICK, 0.4, false, true)
	_expect(fsm2.search_step == step_at_entry + 1, "the search must advance one point per dwell")


func _check_memory() -> void:
	var mem: Object = _memory_script.new(_tuning.memory_slots)
	mem.apply_tuning(_tuning)
	mem.report(11, Vector3(10.0, 0.0, 0.0), _tuning.heard_confidence_cap, 1.0)
	var slot: int = mem.slot_of(11)
	_expect(
		mem.slot_confidence(slot) <= _tuning.heard_confidence_cap + 1e-5,
		"a heard contact must not exceed the heard confidence cap"
	)
	mem.observe(11, Vector3(12.0, 0.0, 0.0), Vector3(4.0, 0.0, 0.0), 1.0, 1.0)
	slot = mem.slot_of(11)
	_expect(mem.slot_confidence(slot) >= 0.999, "a sighting must restore full confidence")
	mem.fade(1.0, 0.0)
	_expect(mem.predicted_position(slot).x > 12.0, "dead reckoning must lead a moving contact")
	mem.fade(30.0, 0.0)
	_expect(
		mem.predicted_position(slot).distance_to(Vector3(12.0, 0.0, 0.0)) < 0.01,
		"dead reckoning must stop once confidence has bled to nothing"
	)

	# Overfill the table: the weakest contact goes, the strongest stays.
	var mem2: Object = _memory_script.new(4)
	mem2.apply_tuning(_tuning)
	mem2.observe(1, Vector3.ZERO, Vector3.ZERO, 1.2, 2.0)
	for i: int in 8:
		mem2.observe(100 + i, Vector3(float(i), 0.0, 0.0), Vector3.ZERO, 0.05, 1.0)
	_expect(mem2.count() == 4, "memory must hold exactly its capacity")
	_expect(mem2.slot_of(1) >= 0, "the strongest contact must survive eviction")

	var seen: Dictionary = {}
	var far: float = 0.0
	for step: int in 12:
		var p: Vector3 = mem.search_point(slot, step, 0.7)
		var key: String = "%.2f_%.2f" % [p.x, p.z]
		_expect(not seen.has(key), "search point %d repeated an earlier one" % step)
		seen[key] = true
		far = maxf(far, p.distance_to(Vector3(12.0, 0.0, 0.0)))
	_expect(
		far <= _tuning.search_radius_max + 0.01,
		(
			"the search spiral wandered to %.1f m, past its %.1f m cap"
			% [far, _tuning.search_radius_max]
		)
	)


# --- cost -----------------------------------------------------------------


func _build_world() -> void:
	_world = Node3D.new()
	_world.name = "PerceptionField"
	root.add_child(_world)
	var shape: BoxShape3D = BoxShape3D.new()
	shape.size = Vector3(6.0, 4.0, 6.0)
	var r: Object = _rng_script.new(1337)
	for i: int in OCCLUDERS:
		var body: StaticBody3D = StaticBody3D.new()
		body.collision_layer = _world_layer
		body.collision_mask = 0
		body.position = Vector3(r.next_range(-FIELD, FIELD), 2.0, r.next_range(-FIELD, FIELD))
		var col: CollisionShape3D = CollisionShape3D.new()
		col.shape = shape
		body.add_child(col)
		_world.add_child(body)


func _setup(count: int) -> void:
	for child: Node in _world.get_children():
		if child is StaticBody3D:
			continue
		_world.remove_child(child)
		child.queue_free()
	# Reseeded every configuration so the grid pass and the linear pass measure the
	# same field. Without this the two passes are different scenes and the
	# comparison is worthless.
	_rng = _rng_script.new(0x5EED)
	_index = _index_script.new()
	_index.grid.cell_size = _tuning.grid_cell_size
	_perception.clear()
	_memory.clear()
	_alert.clear()
	_eye.clear()
	_forward.clear()
	_cursor.clear()
	_bus.reset()
	var species: Resource = _species_script.new()
	species.sight_range = 55.0
	species.fov_degrees = 130.0
	species.peripheral_range = 4.0
	for i: int in count:
		var host: Node3D = Node3D.new()
		host.position = Vector3(_rng.next_range(-FIELD, FIELD), 0.0, _rng.next_range(-FIELD, FIELD))
		var t: Node3D = _target_script.new()
		# Factions.F.SCAV and Factions.F.FOUNDRY, which are hostile to each other.
		t.faction = 0 if (i & 1) == 0 else 1
		host.add_child(t)
		_world.add_child(host)
		_index.add(t)
		var p: Object = _perception_script.new(species, t.faction, i + 1)
		p.configure(species, t.faction, _tuning)
		var m: Object = _memory_script.new(_tuning.memory_slots)
		m.apply_tuning(_tuning)
		var a: Object = _alert_script.new()
		a.apply_tuning(_tuning)
		_perception.append(p)
		_memory.append(m)
		_alert.append(a)
		_eye.append(host.position + Vector3(0.0, 1.62, 0.0))
		_forward.append(
			Vector3(_rng.next_range(-1.0, 1.0), 0.0, _rng.next_range(-1.0, 1.0)).normalized()
		)
		_cursor.append(0)
	_tick = 0
	_us_index = 0
	_us_look = 0
	_us_listen = 0
	_us_state = 0
	_us_bp_grid = 0
	_us_bp_scan = 0
	_rays = 0
	_seen = 0


func _run_tick(delta: float) -> void:
	var n: int = _perception.size()
	var space: PhysicsDirectSpaceState3D = _world.get_world_3d().direct_space_state
	# Two reports per tick — a hundred and twenty rounds a second across the whole
	# field, which is a heavy firefight and the load the bus has to absorb.
	for k: int in 2:
		var shooter: int = (_tick * 2 + k) % n
		var row: int = _index.row_of(shooter + 1)
		if row >= 0:
			_bus.emit_gunshot(_eye[shooter], 1500.0, _index.faction(row), shooter + 1, false)
	var t0: int = Time.get_ticks_usec()
	_index.refresh_budgeted(delta, _tuning.index_rows_per_tick)
	var t1: int = Time.get_ticks_usec()
	var pool: int = n * _tuning.ray_budget_per_tick
	for i: int in n:
		var p: Object = _perception[i]
		p.set_space(space)
		var spent: int = p.look(delta, _eye[i], _forward[i], _index, _memory[i], pool, 1.0)
		pool -= spent
		_rays += spent
		_seen += p.visible_ids.size()
	var t2: int = Time.get_ticks_usec()
	for i: int in n:
		_cursor[i] = _perception[i].listen(_memory[i], _eye[i], _cursor[i])
	var t3: int = Time.get_ticks_usec()
	for i: int in n:
		var mem: Object = _memory[i]
		mem.fade(delta, 0.42)
		var best: int = mem.best_slot()
		var awareness: float = 0.0 if best < 0 else mem.slot_awareness(best)
		var visible: bool = best >= 0 and mem.slot_visible(best)
		_alert[i].tick(delta, awareness, visible, best >= 0)
	var t4: int = Time.get_ticks_usec()
	if _tick < WARMUP:
		return
	_us_index += t1 - t0
	_us_look += t2 - t1
	_us_listen += t3 - t2
	_us_state += t4 - t3
	_measure_broad_phase(n)


## The broad phase alone, both ways, one immediately after the other so neither
## arm can be charged for the other's allocation history. This is extra work on
## top of the tick and is reported separately, not folded into the totals.
func _measure_broad_phase(n: int) -> void:
	var out: PackedInt32Array = PackedInt32Array()
	var g0: int = Time.get_ticks_usec()
	for i: int in n:
		_index.hostiles_near(_eye[i], 55.0, i & 1, out)
	var g1: int = Time.get_ticks_usec()
	_index.grid.enabled = false
	for i: int in n:
		_index.hostiles_near(_eye[i], 55.0, i & 1, out)
	var g2: int = Time.get_ticks_usec()
	_index.grid.enabled = true
	_us_bp_grid += g1 - g0
	_us_bp_scan += g2 - g1


func _report() -> void:
	var n: int = _perception.size()
	var total: float = float(_us_index + _us_look + _us_listen + _us_state) / float(TICKS)
	var alerted: int = 0
	for a: Object in _alert:
		if a.is_alerted():
			alerted += 1
	print(
		(
			"%6d  %8.1f  %7.1f  %9.1f  %6.1f  %8.1f  %8.2f  %11.1f  %10.1f  %5.1f  %5.1f  (%d/%d alerted)"
			% [
				n,
				float(_us_index) / float(TICKS),
				float(_us_look) / float(TICKS),
				float(_us_listen) / float(TICKS),
				float(_us_state) / float(TICKS),
				total,
				total / float(maxi(n, 1)),
				float(_us_bp_grid) / float(TICKS),
				float(_us_bp_scan) / float(TICKS),
				float(_rays) / float(TICKS),
				float(_seen) / float(TICKS),
				alerted,
				n
			]
		)
	)


func _teardown() -> void:
	if _world != null and is_instance_valid(_world):
		root.remove_child(_world)
		_world.queue_free()
		_world = null
	_bus.reset()
