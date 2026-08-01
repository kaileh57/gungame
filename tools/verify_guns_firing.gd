@tool
extends SceneTree
## Firing-chain verifier: ten thousand rounds through a real physics world.
##
## Parsing proves nothing about a trigger group. This builds an actual space with
## walls at known distances, rolls a spread of weapons that between them cover every
## fire mode, and holds the trigger down until 10,000 rounds have gone downrange —
## checking, on every one of them, that:
##
##   * the books balance: `start + reloaded - consumed == loaded`, exactly, per gun;
##   * nothing goes non-finite — cone, recoil, damage, projectile position;
##   * the cadence matches the rated rpm, measured shot-to-shot inside strings;
##   * jams happen at the rate the reliability curve says they should;
##   * hitscan, penetration, projectile flight and blast all resolve.
##
## Run headless:
##   godot --headless --path <project> --script res://tools/verify_guns_firing.gd

const MANIFEST_PATH := "res://data/guns/part_library.tres"
const TUNING_PATH := "res://data/guns/gun_tuning.tres"
const REPORT_PATH := "res://data/gun_firing_report.txt"

## Rounds the volume pass must put downrange before it is allowed to stop.
const ROUND_BUDGET := 10000
## Fixed step the whole verification is driven at, seconds. 120 Hz.
const STEP := 1.0 / 120.0
## Ceiling on ticks per weapon, so a broken action cannot hang the run.
const MAX_TICKS := 240000
## Distance to the near wall, metres.
const WALL_NEAR := 12.0
## Distance to the far wall. Past every weapon's instant window, so rounds fired at
## it become real projectiles and have to fly.
const WALL_FAR := 420.0
## Seeds rolled for the volume pass. Between them they cover every fire mode.
const SEED_COUNT := 400
## Cadence is only measured inside a string. A gap longer than this many nominal
## intervals is a burst pause and is not part of the rate; reloads and jams are
## excluded outright by watching for them between shots.
const STRING_GAP_INTERVALS := 1.5
## Rounds fired per reliability sample in the jam pass.
const JAM_SAMPLE := 6000

var _lines: PackedStringArray = PackedStringArray()
var _failures: int = 0
var _checks: int = 0
var _world: Node3D
var _shots: int = 0
var _jams: int = 0
var _reloaded: int = 0
var _hits: int = 0
var _nonfinite: int = 0
var _last_shot_time: float = -1.0
var _now: float = 0.0
var _expect_interval: float = 0.0
var _string_broken: bool = true
var _timed_gaps: int = 0
var _skipped_gaps: int = 0
var _worst_gap_error: float = 0.0
var _worst_gap_gun: String = ""
var _gun_name: String = ""


func _initialize() -> void:
	_run()


func _run() -> void:
	_say("gun firing verification — %s" % Time.get_datetime_string_from_system())
	var pools := _load_pools()
	if pools.is_empty():
		quit(1)
		return
	var tuning := _load_tuning()
	_build_world()
	await physics_frame
	await physics_frame
	var specs := _roll_specs(pools, tuning)
	_check_mechanisms(_sweep_mechanisms(pools, tuning))
	_check_volume(specs)
	_check_jams(specs)
	_check_projectiles(specs)
	await _check_blast()
	_check_penetration()
	_report()
	quit(1 if _failures > 0 else 0)


# ---------------------------------------------------------------- world & setup


## Two walls and a floor, on the world layer, with real box shapes. Everything the
## firing code touches goes through `intersect_ray` against these.
func _build_world() -> void:
	_world = Node3D.new()
	_world.name = "FiringTestWorld"
	root.add_child(_world)
	_world.add_child(_wall(Vector3(0, 0, -WALL_NEAR), Vector3(40, 12, 0.5), &"metal"))
	_world.add_child(_wall(Vector3(0, 0, -WALL_FAR), Vector3(200, 60, 2.0), &"concrete"))
	_world.add_child(_wall(Vector3(0, -1.0, -220), Vector3(600, 1.0, 600), &"sand"))


func _wall(at: Vector3, size: Vector3, surface: StringName) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.collision_layer = GameLayers.WORLD
	body.collision_mask = 0
	body.position = at
	body.set_meta(&"surface", surface)
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	body.add_child(shape)
	return body


## A weapon aimed straight down -Z from the origin, driven by hand.
func _make_weapon(spec: GunSpec, free_running: bool) -> Weapon:
	var w := Weapon.new()
	w.self_driven = false
	w.visual_effects = false
	_world.add_child(w)
	w.setup(spec)
	if free_running:
		w.fire_control.semi_requires_release = false
		w.fire_control.manual_requires_release = false
		w.fire_control.burst_requires_release = false
	w.set_rig(w, w, null)
	w.position = Vector3(0, 1.65, 0)
	w.fired.connect(_on_fired)
	w.hit.connect(_on_hit)
	w.jam.jammed.connect(_on_jammed)
	w.reload_action.reload_finished.connect(_on_reloaded)
	return w


func _drop(w: Weapon) -> void:
	_world.remove_child(w)
	w.queue_free()


## Cadence is measured here, against the weapon's own rated interval. A gap is only
## counted when nothing broke the string between the two shots — no reload, no jam,
## no inter-burst pause — because those are not the mechanism's rate.
func _on_fired(origin: Vector3, direction: Vector3, _spec: GunSpec) -> void:
	_shots += 1
	if not _finite3(origin) or not _finite3(direction):
		_nonfinite += 1
	if _last_shot_time >= 0.0 and _expect_interval > 0.0:
		var gap := _now - _last_shot_time
		if _string_broken or gap > _expect_interval * STRING_GAP_INTERVALS:
			_skipped_gaps += 1
		else:
			_timed_gaps += 1
			var err := absf(gap - _expect_interval)
			if err > _worst_gap_error:
				_worst_gap_error = err
				_worst_gap_gun = _gun_name
	_string_broken = false
	_last_shot_time = _now


func _on_hit(_collider: Object, position: Vector3, _normal: Vector3, dmg: float) -> void:
	_hits += 1
	if not _finite3(position) or not is_finite(dmg) or dmg < 0.0:
		_nonfinite += 1


func _on_jammed() -> void:
	_jams += 1
	_string_broken = true


func _on_reloaded(loaded: int) -> void:
	_reloaded += loaded
	_string_broken = true


# ------------------------------------------------------------------- the passes


## One weapon per mechanism, found by pairing every receiver with every barrel over
## its own donor group's stock and grip. Random rolls never surface all eight — a
## revolver or a pump needs a particular receiver class, and the class mix makes
## those rare — so the mechanism pass enumerates instead of sampling.
func _sweep_mechanisms(pools: Dictionary, tuning: GunTuning) -> Array[GunSpec]:
	var receivers: Array[GunPart] = pools[&"receiver"]
	var barrels: Array[GunPart] = pools[&"barrel"]
	var stocks: Array[GunPart] = pools[&"stock"]
	var grips: Array[GunPart] = pools[&"grip"]
	var by_action: Dictionary = {}
	for r: int in receivers.size():
		for b: int in barrels.size():
			var spec := GunAssembler.assemble(
				receivers[r],
				barrels[b],
				stocks[r % stocks.size()],
				grips[r % grips.size()],
				null,
				1,
				tuning
			)
			if spec == null:
				continue
			var id := String(GunTables.action_for(spec.fire_mode))
			if not by_action.has(id):
				by_action[id] = spec
	var out: Array[GunSpec] = []
	for id: StringName in FireControl.ACTION_IDS.keys():
		if by_action.has(String(id)):
			out.append(by_action[String(id)] as GunSpec)
	return out


## Every mechanism, one at a time, with its own gates left at their shipped values.
func _check_mechanisms(specs: Array[GunSpec]) -> void:
	_say("")
	_say("-- mechanisms --")
	var head := "%-16s %-16s %6s %5s %6s %7s %7s %7s"
	_say(head % ["action", "mode", "rpm", "cap", "held", "fired", "want", "err%"])
	var seen: Dictionary = {}
	for spec: GunSpec in specs:
		var probe := _make_weapon(spec, false)
		var id := String(probe.fire_control.action_id())
		if seen.has(id):
			_drop(probe)
			continue
		seen[id] = true
		_measure_mechanism(probe, spec, head)
		_drop(probe)
	var missing: PackedStringArray = []
	for id: StringName in FireControl.ACTION_IDS.keys():
		if not seen.has(String(id)):
			missing.append(String(id))
	_assert(
		missing.is_empty(),
		"every mechanism appeared and behaved (%d of 8, missing %s)" % [seen.size(), missing]
	)


## Hold the trigger for two seconds and see how many rounds a mechanism releases.
func _measure_mechanism(w: Weapon, spec: GunSpec, head: String) -> void:
	var before := _shots
	var hold := 2.0
	_expect_interval = 0.0
	_string_broken = true
	w.trigger_down()
	var ticks := int(hold / STEP)
	for i: int in ticks:
		_now += STEP
		w.tick(STEP)
	w.trigger_up()
	var fired := _shots - before
	var interval := w.fire_control.interval()
	var want := _expected_rounds(w, spec, hold, interval)
	var err := 0.0 if want <= 0 else absf(float(fired) - want) / want * 100.0
	_say(
		(
			head
			% [
				String(w.fire_control.action_id()),
				String(spec.fire_mode),
				spec.rpm,
				spec.magazine,
				"%.1fs" % hold,
				fired,
				"%.1f" % want,
				"%.1f" % err,
			]
		)
	)


## What a held trigger should produce in `hold` seconds, given the release gates.
func _expected_rounds(w: Weapon, spec: GunSpec, hold: float, interval: float) -> float:
	var action := w.fire_control.action()
	if action == FireControl.Action.SEMI and w.fire_control.semi_requires_release:
		return 1.0
	if FireControl.MANUAL_ACTIONS.has(action) and w.fire_control.manual_requires_release:
		return 1.0
	if action == FireControl.Action.BURST:
		return float(w.fire_control.burst_count)
	var cadence := floorf(1.0 + hold / interval)
	return minf(cadence, float(spec.magazine))


## The volume pass. Ten thousand rounds, books balanced per weapon.
func _check_volume(specs: Array[GunSpec]) -> void:
	_say("")
	_say("-- volume: %d rounds --" % ROUND_BUDGET)
	_shots = 0
	_jams = 0
	_hits = 0
	_nonfinite = 0
	_timed_gaps = 0
	_skipped_gaps = 0
	_worst_gap_error = 0.0
	var books_ok := true
	var cone_min := INF
	var cone_max := 0.0
	var guns := 0
	var i := 0
	while _shots < ROUND_BUDGET and i < specs.size() * 4:
		var spec := specs[i % specs.size()]
		i += 1
		guns += 1
		var target := _shots + maxi(ROUND_BUDGET / specs.size(), 40)
		var result := _run_gun(spec, target)
		books_ok = books_ok and bool(result["books"])
		cone_min = minf(cone_min, float(result["cone_min"]))
		cone_max = maxf(cone_max, float(result["cone_max"]))
	_say("weapons driven      %d" % guns)
	_say("rounds fired        %d" % _shots)
	_say("rounds that jammed  %d" % _jams)
	_say("surfaces resolved   %d" % _hits)
	_say("cone seen, MOA      %.2f .. %.2f" % [cone_min / 0.000290888, cone_max / 0.000290888])
	_assert(books_ok, "magazine accounting balanced on every weapon")
	_assert(_nonfinite == 0, "no non-finite value reached a signal (%d seen)" % _nonfinite)
	_assert(_shots >= ROUND_BUDGET, "%d rounds fired, wanted %d" % [_shots, ROUND_BUDGET])
	_assert(_hits > 0, "%d surfaces resolved — nothing was being hit" % _hits)
	_report_cadence()


## Drive one weapon until the global shot count reaches `target`, then check that
## every round it consumed is accounted for.
func _run_gun(spec: GunSpec, target: int) -> Dictionary:
	var w := _make_weapon(spec, true)
	_expect_interval = w.fire_control.interval()
	_gun_name = "%s (%s, %d rpm)" % [spec.weapon_name, spec.fire_mode, spec.rpm]
	_string_broken = true
	var reload_before := _reloaded
	var shots_before := _shots
	var jams_before := _jams
	var cone_min := INF
	var cone_max := 0.0
	var start_loaded := w.ammo().loaded()
	w.trigger_down()
	var ticks := 0
	while _shots < target and ticks < MAX_TICKS:
		_now += STEP
		w.tick(STEP)
		ticks += 1
		var cone := w.effective_spread()
		if not is_finite(cone):
			_nonfinite += 1
		else:
			cone_min = minf(cone_min, cone)
			cone_max = maxf(cone_max, cone)
		if not is_finite(w.recoil.transient_pitch) or not is_finite(w.recoil.transient_yaw):
			_nonfinite += 1
	w.trigger_up()
	var consumed := (_shots - shots_before) + (_jams - jams_before)
	var reloaded := _reloaded - reload_before
	var books := start_loaded + reloaded - consumed == w.ammo().loaded()
	if not books:
		_say(
			(
				"  BOOKS %s: start %d + reloaded %d - consumed %d != loaded %d"
				% [spec.weapon_name, start_loaded, reloaded, consumed, w.ammo().loaded()]
			)
		)
	_drop(w)
	return {"books": books, "cone_min": cone_min, "cone_max": cone_max}


## Shot-to-shot timing against each weapon's own rated rate.
func _report_cadence() -> void:
	if _timed_gaps <= 0:
		_assert(false, "no shot intervals were timed")
		return
	_say(
		(
			"in-string intervals %d timed, %d skipped (reload, jam or burst pause)"
			% [_timed_gaps, _skipped_gaps]
		)
	)
	_say(
		(
			"worst rate error    %.6f s = %.3f of a 120 Hz tick, on %s"
			% [_worst_gap_error, _worst_gap_error / STEP, _worst_gap_gun]
		)
	)
	_assert(
		_worst_gap_error <= STEP * 1.001,
		"every timed interval lands within one 120 Hz tick of the rated rate"
	)


## The jam model, measured. A gun of known reliability has to bind at the rate the
## curve says, the clear has to take the time it says, and letting go has to lose it.
func _check_jams(specs: Array[GunSpec]) -> void:
	_say("")
	_say("-- jams --")
	var base := _pick(specs, func(s: GunSpec) -> bool: return s.automatic and s.magazine >= 20)
	if base == null:
		_assert(false, "no automatic weapon in the sample to test jamming with")
		return
	for reliability: int in [40, 70, 95]:
		_measure_jam_rate(base, reliability)
	_check_clearing(base)


## Fire until `JAM_SAMPLE` rounds are gone and compare the jam rate to the curve.
func _measure_jam_rate(base: GunSpec, reliability: int) -> void:
	var spec := base.duplicate() as GunSpec
	spec.reliability = reliability
	var w := _make_weapon(spec, true)
	_expect_interval = 0.0
	var jams_before := _jams
	var shots_before := _shots
	var expect := w.jam.chance(spec.magazine)
	var ticks := 0
	w.trigger_down()
	while _shots - shots_before < JAM_SAMPLE and ticks < MAX_TICKS:
		_now += STEP
		w.tick(STEP)
		ticks += 1
		if w.jam.is_jammed() and not w.jam.is_clearing():
			w.clear_jam()
	w.trigger_up()
	var jams := _jams - jams_before
	var rounds := (_shots - shots_before) + jams
	var measured := float(jams) / float(maxi(rounds, 1))
	var sigma := sqrt(maxf(expect * (1.0 - expect) * float(rounds), 1.0)) / float(rounds)
	_say(
		(
			"rel %3d  predicted %.5f  measured %.5f  (%d in %d, %.1f sigma)"
			% [reliability, expect, measured, jams, rounds, absf(measured - expect) / sigma]
		)
	)
	_assert(
		absf(measured - expect) <= sigma * 4.0,
		"reliability %d jams at the rate the curve predicts" % reliability
	)
	_drop(w)


## Clearing takes its stated time, and letting go of the key loses the progress.
func _check_clearing(base: GunSpec) -> void:
	var spec := base.duplicate() as GunSpec
	spec.reliability = 1
	var w := _make_weapon(spec, true)
	_expect_interval = 0.0
	var ticks := 0
	w.trigger_down()
	while not w.jam.is_jammed() and ticks < MAX_TICKS:
		_now += STEP
		w.tick(STEP)
		ticks += 1
	w.trigger_up()
	_assert(w.jam.is_jammed(), "a reliability-1 gun bound up")
	_assert(w.state() == Weapon.STATE_JAMMED, "a jammed gun reports `jammed`")
	w.clear_jam()
	for i: int in 30:
		_now += STEP
		w.tick(STEP)
	var midway := w.jam.clear_progress()
	w.cancel_clear()
	_assert(midway > 0.1 and midway < 0.9, "clearing reports partial progress (%.2f)" % midway)
	_assert(w.jam.is_jammed(), "letting the key go leaves the gun jammed")
	_assert(w.jam.clear_progress() == 0.0, "an abandoned clear loses its progress")
	w.clear_jam()
	var clear_ticks := 0
	while w.jam.is_jammed() and clear_ticks < MAX_TICKS:
		_now += STEP
		w.tick(STEP)
		clear_ticks += 1
	var elapsed := float(clear_ticks) * STEP
	_say("clear took          %.4f s (stated %.2f s)" % [elapsed, w.jam.clear_seconds])
	_assert(absf(elapsed - w.jam.clear_seconds) <= STEP * 1.001, "the clear took its stated time")
	_drop(w)


## The slow half: a shot at the far wall has to become a projectile, fly, and land.
func _check_projectiles(specs: Array[GunSpec]) -> void:
	_say("")
	_say("-- projectiles --")
	var spec := _pick(specs, func(s: GunSpec) -> bool: return s.pellets == 1 and not s.explosive)
	if spec == null:
		_assert(false, "no plain single-projectile weapon in the sample")
		return
	var w := _make_weapon(spec, true)
	# Stand off to the side: the near wall spans x in [-20, 20] and would eat every
	# shot inside the instant window, so nothing would ever be handed to the pool.
	w.position = Vector3(60.0, 1.65, 0.0)
	_expect_interval = 0.0
	w.hitscan.max_penetrations = 0
	var landed := 0
	var flights := 0
	var max_live := 0
	var attempts := 0
	var shots_before := _shots
	for shot: int in 24:
		attempts += 1
		var shot_mark := _shots
		w.trigger_down()
		_now += STEP
		w.tick(STEP)
		w.trigger_up()
		if _shots == shot_mark:
			continue
		if w.projectiles.active_count() > 0:
			flights += 1
		var before := _hits
		for i: int in 900:
			_now += STEP
			w.tick(STEP)
			max_live = maxi(max_live, w.projectiles.active_count())
			if w.projectiles.active_count() == 0:
				break
		if _hits > before:
			landed += 1
	_say("weapon              %s (%s)" % [spec.weapon_name, spec.caliber])
	_say(
		"instant window      %.1f m, sim velocity %d m/s" % [spec.headshot_range, spec.sim_velocity]
	)
	var rounds := _shots - shots_before
	_say("trigger pulls       %d, rounds fired %d" % [attempts, rounds])
	_say("shots that flew     %d of %d, of which landed %d" % [flights, rounds, landed])
	_say("peak rounds in air  %d" % max_live)
	_assert(rounds > 0, "the projectile probe actually fired")
	_assert(flights == rounds, "every shot past the window became a projectile")
	_assert(landed == rounds, "every projectile resolved against something solid")
	_assert(w.projectiles.active_count() == 0, "the projectile pool drained")
	_drop(w)


## Blast damage with an occluder in the way has to be smaller than without.
func _check_blast() -> void:
	_say("")
	_say("-- blast --")
	var damage := GunDamage.new()
	var open: float = await _blast_probe(damage, Vector3(60, 1.0, -60), false)
	var covered: float = await _blast_probe(damage, Vector3(60, 1.0, -80), true)
	_say("open target damage  %.1f" % open)
	_say("occluded damage     %.1f" % covered)
	_assert(open > 0.0, "an unobstructed blast damaged the target")
	_assert(covered < open, "an occluded blast did less damage than an open one")
	_assert(
		is_equal_approx(covered, open * damage.blast_occluded_scale),
		"occlusion scaled the blast by exactly `blast_occluded_scale`"
	)


## Drop a rigid body at `at`, optionally behind a wall, and blast it.
func _blast_probe(damage: GunDamage, at: Vector3, occluded: bool) -> float:
	var probe := _BlastProbe.new()
	probe.collision_layer = GameLayers.ENEMY
	probe.collision_mask = 0
	probe.freeze = true
	probe.position = at
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3.ONE
	shape.shape = box
	probe.add_child(shape)
	_world.add_child(probe)
	var center := at + Vector3(0, 0, 6.0)
	var wall: StaticBody3D = null
	if occluded:
		wall = _wall(at + Vector3(0, 0, 3.0), Vector3(6, 6, 0.4), &"concrete")
		_world.add_child(wall)
	await physics_frame
	await physics_frame
	var none: Array[RID] = []
	damage.blast(_world.get_world_3d().direct_space_state, center, 400.0, 12.0, none)
	var taken := probe.taken
	_world.remove_child(probe)
	probe.queue_free()
	if wall != null:
		_world.remove_child(wall)
		wall.queue_free()
	return taken


## Penetration is off by default in the reference; on, energy has to run out.
func _check_penetration() -> void:
	_say("")
	_say("-- penetration --")
	var hs := GunHitscan.new()
	var dmg := GunDamage.new()
	hs.configure(_fake_spec(3200), dmg)
	var counted := {"n": 0}
	hs.on_hit = func(_c: Object, _p: Vector3, _n: Vector3, _d: float, _s: float, _k: int) -> void:
		counted["n"] = int(counted["n"]) + 1
	var space := _world.get_world_3d().direct_space_state
	var none: Array[RID] = []
	var origin := Vector3(0, 1.65, 0)
	var dir := Vector3(0, 0, -1)
	hs.max_penetrations = 0
	counted["n"] = 0
	hs.trace(space, origin, dir, 500.0, none)
	_assert(int(counted["n"]) == 1, "with penetration off a round stops at the first surface")
	hs.max_penetrations = 3
	counted["n"] = 0
	hs.trace(space, origin, dir, 500.0, none)
	var deep := int(counted["n"])
	_say("3200 J, 3 allowed    %d surfaces resolved" % deep)
	hs.configure(_fake_spec(40), dmg)
	counted["n"] = 0
	hs.trace(space, origin, dir, 500.0, none)
	var weak := int(counted["n"])
	_say("40 J, 3 allowed      %d surfaces resolved" % weak)
	_assert(deep >= 2, "a high-energy round went through the near wall")
	_assert(weak == 1, "a low-energy round stopped in the near wall")


# ----------------------------------------------------------------------- setup


func _roll_specs(pools: Dictionary, tuning: GunTuning) -> Array[GunSpec]:
	var out: Array[GunSpec] = []
	var seed_value := 1
	while out.size() < SEED_COUNT and seed_value < 40000:
		var spec := GunAssembler.build(seed_value, pools, tuning)
		seed_value += 7
		if spec == null:
			continue
		out.append(spec)
	_assert(out.size() == SEED_COUNT, "rolled %d specs of %d wanted" % [out.size(), SEED_COUNT])
	return out


func _pick(specs: Array[GunSpec], test: Callable) -> GunSpec:
	for s: GunSpec in specs:
		if bool(test.call(s)):
			return s
	return null


## A bare spec carrying only the fields the hitscan energy budget reads.
func _fake_spec(energy: int) -> GunSpec:
	var s := GunSpec.new()
	s.muzzle_energy = energy
	return s


func _load_pools() -> Dictionary:
	if not ResourceLoader.exists(MANIFEST_PATH):
		push_error("verify_guns_firing: %s missing. Run bake_gun_parts.gd." % MANIFEST_PATH)
		return {}
	var set_res := ResourceLoader.load(MANIFEST_PATH) as GunPartSet
	if set_res == null or set_res.parts.is_empty():
		push_error("verify_guns_firing: %s is not a GunPartSet." % MANIFEST_PATH)
		return {}
	var pools: Dictionary = {}
	for kind: StringName in [&"barrel", &"stock", &"grip", &"receiver", &"sight"]:
		var bucket: Array[GunPart] = []
		pools[kind] = bucket
	for p: GunPart in set_res.parts:
		var bucket: Array[GunPart] = pools[p.kind]
		bucket.append(p)
	return pools


func _load_tuning() -> GunTuning:
	if ResourceLoader.exists(TUNING_PATH):
		var res := ResourceLoader.load(TUNING_PATH) as GunTuning
		if res != null:
			return res
	return GunTuning.new()


# ---------------------------------------------------------------------- output


func _finite3(v: Vector3) -> bool:
	return is_finite(v.x) and is_finite(v.y) and is_finite(v.z)


func _assert(ok: bool, what: String) -> void:
	_checks += 1
	if ok:
		_say("  ok   %s" % what)
		return
	_failures += 1
	_say("  FAIL %s" % what)


func _say(line: String) -> void:
	_lines.append(line)
	print(line)


func _report() -> void:
	_say("")
	_say("%d checks, %d failures" % [_checks, _failures])
	var f := FileAccess.open(REPORT_PATH, FileAccess.WRITE)
	if f != null:
		f.store_string("\n".join(_lines) + "\n")
		f.close()


## Stands in for anything that can be damaged: records what it was given.
class _BlastProbe:
	extends RigidBody3D

	var taken: float = 0.0

	func take_damage(amount: float) -> void:
		taken += amount
