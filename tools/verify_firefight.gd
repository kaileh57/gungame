extends SceneTree
## Runs the firefight demo for real and asks the only question a still frame
## cannot answer: does the war sustain itself?
##
## Run headless (about twenty minutes of wall clock at the default):
##   godot --headless --path <project> --script res://tools/verify_firefight.gd
##   ... -- --runs=5 --seconds=240 --sample=10
##
## Options (after a bare `--`):
##   --runs=N      trials to play before the verdict. Default 5. See WHY THIS
##                 RUNS MORE THAN ONCE.
##   --seconds=N   simulated seconds per trial before it is scored. Default 240.
##                 THE BARS BELOW ARE CALIBRATED AGAINST 240 WITH A 30 s SETTLE,
##                 which is a 210 s graded window. Shorten it and the ownership
##                 bar fails on a healthy build, because the map turns over about
##                 once every thirty-five seconds and the bar is a count, not a
##                 rate. Use a short window to watch, not to judge.
##   --sample=N    seconds between rows of the time series. Default 10.
##   --settle=N    seconds skipped before the floor assertions start biting, so
##                 the opening deployment and the first exchange are not judged.
##                 Default 30.
##   --trace=N     seconds between diagnostic blocks: every zone's owner and
##                 pressure vector, every squad's state, verb and objective, and
##                 how many bodies are actually within thirty metres of an enemy.
##                 Zero, which is off, is the default.
##   --knob=K=V    override a float export for the whole invocation, on the
##                 `Factions` autoload by default or on the demo's own director
##                 when the name is prefixed `director.` — so
##                 `--knob=contest_attrition=1.6` and
##                 `--knob=director.objective_crowding=0.18` are both a run. The
##                 territory dials are what decide whether the war moves, and
##                 sweeping one of them means five trials per value; editing the
##                 autoload between sweeps is how a measurement gets attributed
##                 to the wrong number. Repeatable. Reported in the header, so a
##                 report can never claim to be the shipping configuration when
##                 it is not.
##   --report=P    where the time series is written. Defaults to
##                 `res://demos/firefight/firefight_population.txt`.
##
## WHY IT IS A SCENE AND NOT A SIMULATION. `systems/ai/verify/faction_war_harness`
## already proves the territory rules with no bodies in the world. What that
## cannot see is the body economy: pool ceilings, corpse linger eating the live
## cap, reinforcement landing on ground it cannot reach. Those only exist once
## real actors are being spawned, killed and recycled, so this boots the shipped
## `.tscn` unmodified and reads the director's own counters.
##
## WHY THIS RUNS MORE THAN ONCE. `FirefightDirector.seed_value` fixes the species
## draw, the spawn scatter and the picket offsets. It does not fix the war.
## Measured on this build: two runs of the same binary, same seed, same machine,
## back to back, diverge inside the first ten seconds and finish tens of kills
## apart — see `_determinism` in the report footer, which is measured rather than
## asserted, and reprinted every run.
##
## The divergence is not one loose `randf()` that could be seeded away — every RNG
## the AI touches is already seeded off a body id. It is the clocks. Bodies think
## on a scheduler budget spread over physics frames, the navigation server merges
## its regions on its own thread, and the path service answers a fixed number of
## queries per frame; how those interleave is a property of the machine and not of
## the build, and each of them moves a body a few centimetres, which is the
## difference between a shot connecting and not. One of the four was worth fixing
## rather than measuring and has been — `Factions` used to advance the territory
## ledger from the free-running IDLE frame while everything feeding it ran on the
## physics frame — but the rest are the engine, and pinning them is not on the
## table. So one run is one sample from a distribution, and a gate on one sample
## is a coin flip: this harness's own bar of "more than two ownership changes" was
## measured returning 2, 4 and 5 on identical code and an identical seed.
##
## The answer is to gate on the DISTRIBUTION. Every trial is played and reported;
## the ownership bar is asked of the MEDIAN trial, so a gate cannot be passed by
## re-rolling, and the body-economy assertions — which are stable run to run — are
## asked of every trial.
##
## Nothing here names a `class_name` that reaches an autoload. A script handed to
## `--script` compiles before the autoloads exist, so `FirefightDirector`,
## `EnemySpawner` and `Factions` are all reached dynamically; the scene itself is
## loaded at run time, by which point the autoloads are up and its scripts
## compile normally.

const SCENE: String = "res://demos/firefight/firefight.tscn"
const DEFAULT_REPORT: String = "res://demos/firefight/firefight_population.txt"
const FACTION_NAMES: PackedStringArray = ["SCAV", "FOUNDRY", "CHOIR"]
const FACTION_COUNT: int = 3

## Fraction of the director's own target a faction has to average over the graded
## window. Below this the demo is decaying rather than sustaining.
const FLOOR_FRACTION: float = 0.72
## A faction at or under this many bodies at any graded sample is a collapse,
## whatever the average says.
const COLLAPSE_BODIES: int = 6
## Zone flips the MEDIAN trial has to score over its graded window. Fewer is a
## stalemate: the map has stopped changing hands.
##
## Asked of the median rather than of one run, and set under a measured floor
## rather than at a hoped-for target. Ten trials of 210 graded seconds on the build
## this was written for returned 4/4/4/5/5/6/6/6/6/8 — a median of 5 and a worst of
## 4 — so four is under everything observed, and it is against a build that could
## not be made to move at all on six of its seven zones.
const MIN_OWNERSHIP_CHANGES: int = 4
## Share of the trials that have to produce at least one flip in the LATE half of
## their window. A war that settles its borders in the first minute and then never
## moves again clears a bare total and is exactly the failure this is looking for.
##
## Counted as trials-that-moved rather than as a count of late flips, because the
## count is small and lumpy where the total is not: measured over ten trials of
## 210 graded seconds, late-half flips came out 0/0/1/1/1/1/1/1/2/2 against totals
## of 4 to 8. Eight of the ten moved late; a bar of half is under that with room,
## and it says the thing that matters out loud.
const MIN_LATE_TRIAL_SHARE: float = 0.5
## And the floor no single trial may go under, however good the median is. This is
## the anti-lock assertion: one run in five setting like concrete is the exact
## failure mode this harness exists to catch, so it is graded per trial. Worst of
## ten measured: 4.
const MIN_WORST_CHANGES: int = 2
## Distinct zones that have to change hands in every trial. The total on its own
## cannot tell a war from one border zone flapping between two owners while the
## other six sit untouched, and those read nothing like each other. Measured over
## ten trials: three in nine of them and four in the tenth.
const MIN_ZONES_MOVED: int = 2
## Share of a trial's flips that may come back on the same ground within a quarter
## over `Factions.capture_dwell` of the previous one.
##
## THIS IS THE GATE THAT TELLS A WAR FROM A METRONOME, and it exists because the
## count alone said the two were the same thing. `capture_dwell` refuses to
## relabel ground twice inside ten seconds; if both sides are saturating the
## ledger, every flip then happens the instant that timer runs out and the capture
## count is measuring the timer. Measured with `Factions.contest_attrition` at
## 1.0: `tank_farm` changed hands at 126.0, 136.0 and 146.0 s — exactly one dwell
## apart — and sweeping the dwell from 4 to 20 s moved the count from 9-33 to 3-6
## while nothing about the fighting changed. That is a clock with a banner on it.
const MAX_DWELL_LIMITED_SHARE: float = 0.34
## Rebounds a trial has to show before that share is judged at all. Two flips
## landing on the same ground inside a dwell is a coincidence a healthy war
## produces now and then — measured, 0 to 2 per trial over sixteen trials, never
## more — and dividing two by a low total crosses any share you like. The
## metronome this is aimed at produced five of twelve.
const MIN_REBOUNDS_TO_JUDGE: int = 3
## Bodies of each faction the authored spectator view has to have in shot, on
## average. This is the "I only see two factions" gate: the framing is only right
## if every side is actually in the opening frame.
const MIN_IN_FRAME: float = 3.0
## And as a share of that faction's standing bodies, so a faction cannot pass by
## being enormous and mostly off screen.
##
## Eighteen per cent is set where it separates the two builds rather than where
## it would be nice: measured at 150 s, the old view held 14% of the Scavs and 5%
## of the Choir and this fails it twice; the shipped view averages 24, 56 and 29
## over six and a half minutes. It is a floor on "this faction is on screen at
## all", not a target.
const MIN_IN_FRAME_SHARE: float = 0.15
## Share of the graded zone-samples that may be UNCAPTURABLE — held at a pressure
## no attacker could ever beat, because pressure clamps at one and the capture
## test asks for the defender's pressure plus a margin. See `_locked_share`.
##
## THIS IS THE ONE THAT WOULD HAVE CAUGHT THE ORIGINAL BUG, and it is the reason
## the flakiness was never really about the harness. Before the garrison ceiling
## was applied to pushed pressure, six or seven of this map's seven zones were
## uncapturable at any given moment — 90% of all graded zone-samples — so whether
## a run scored 2 or 5 flips was decided by which zone happened to be off the
## clamp that minute. Measured after: zero, in every trial, and it cannot be
## otherwise since `Territory._garrison_hold_for` derives the cap from the same
## margin the capture test uses.
const MAX_LOCKED_SHARE: float = 0.05

var _runs: int = 5
var _seconds: float = 240.0
var _sample: float = 10.0
var _settle: float = 30.0
var _report_path: String = DEFAULT_REPORT
var _trace: float = 0.0
var _knobs: Dictionary = {}

var _scene: Node = null
var _director: Node = null
var _spawners: Array[Node] = []
## Simulated seconds this trial has run, taken from the PHYSICS frame counter and
## not from `_process` deltas. Bodies move, shoot and are scheduled on the physics
## frame; the idle frame is free-running under `--headless` and is not the clock
## the war keeps. They agree on an unloaded machine — `_drift` is how far they did
## not, and it is printed rather than assumed.
var _elapsed: float = 0.0
var _frames_at_start: int = 0
var _wall: float = 0.0
var _next_sample: float = 0.0
var _next_trace: float = 0.0
var _lines: PackedStringArray = PackedStringArray()
var _spawned: PackedInt32Array = PackedInt32Array()
var _died: PackedInt32Array = PackedInt32Array()
## One row per graded sample, per faction: bodies standing.
var _series: Array[PackedInt32Array] = []
var _graded_rows: int = 0
var _spawned_at_settle: PackedInt32Array = PackedInt32Array()
var _died_at_settle: PackedInt32Array = PackedInt32Array()
var _min_bodies: PackedInt32Array = PackedInt32Array()
var _max_bodies: PackedInt32Array = PackedInt32Array()
var _ownership_changes: int = 0
var _late_changes: int = 0
var _target_population: int = 0
var _failures: PackedStringArray = PackedStringArray()
## The spectator camera, left exactly where the bake authored it — nothing in a
## headless run moves it, so what it can see is the opening frame.
var _cam: Camera3D = null
var _seen: PackedFloat32Array = PackedFloat32Array()
var _standing: PackedFloat32Array = PackedFloat32Array()
## Zone-samples taken, and how many of them were mathematically uncapturable.
var _zone_samples: int = 0
var _locked_samples: int = 0
## Flips per zone id this trial. A war in which one border zone flaps a hundred
## times scores the same TOTAL as one in which the whole board moves, and reads
## nothing like it, so the two are counted apart.
var _flips: Dictionary = {}
var _flip_log: PackedStringArray = PackedStringArray()
## When each zone last changed hands, and how many flips came back so soon after
## the previous one on the same ground that the settle timer, rather than the
## fighting, is what decided when. See `MAX_DWELL_LIMITED_SHARE`.
var _last_flip: Dictionary = {}
var _rebound: int = 0
var _hooked: bool = false

var _run: int = 0
var _changes_per_run: PackedInt32Array = PackedInt32Array()
var _late_per_run: PackedInt32Array = PackedInt32Array()
var _kills_per_run: PackedInt32Array = PackedInt32Array()
var _zones_moved_per_run: PackedInt32Array = PackedInt32Array()
var _rebound_per_run: PackedFloat32Array = PackedFloat32Array()
var _locked_per_run: PackedFloat32Array = PackedFloat32Array()
## Kill total of run 1, kept so runs 2..N can be compared against it. Two runs of
## identical code that finish on a different number is the evidence that a single
## run cannot be a gate.
var _first_kills: int = -1
var _determinism: String = "not measured"


func _initialize() -> void:
	_parse_args(OS.get_cmdline_user_args())
	_lines.push_back("verify_firefight — %s" % Time.get_datetime_string_from_system())
	_lines.push_back(
		(
			"%d trial(s) of %.0f s, sampled every %.0f s, graded after %.0f s"
			% [_runs, _seconds, _sample, _settle]
		)
	)
	_lines.push_back("rows marked ~ are inside the settle window and are not graded")
	for line: String in _lines:
		print(line)
	if not _begin_run():
		quit(1)


func _process(delta: float) -> bool:
	if _director == null:
		return true
	_hook_ledger()
	_wall += delta
	_elapsed = (
		float(Engine.get_physics_frames() - _frames_at_start)
		/ float(maxi(Engine.physics_ticks_per_second, 1))
	)
	if _trace > 0.0 and _elapsed >= _next_trace:
		_next_trace += _trace
		_trace_block()
	if _elapsed < _next_sample:
		return false
	_next_sample += _sample
	_row()
	if _elapsed < _seconds:
		return false
	_end_run()
	if _run < _runs:
		if not _begin_run():
			quit(1)
		return false
	_verdict()
	return true


# ------------------------------------------------------------------- wiring


## Stand a fresh copy of the demo up and zero every per-trial counter. Trials share
## one engine boot: the scene is torn down and re-instanced, which re-registers the
## zones with the ledger from scratch, so nothing but the autoloads survives.
func _begin_run() -> bool:
	_run += 1
	var packed: PackedScene = ResourceLoader.load(SCENE, "PackedScene") as PackedScene
	if packed == null:
		printerr("verify_firefight: cannot load %s" % SCENE)
		return false
	_scene = packed.instantiate()
	root.add_child(_scene)
	_director = _scene.get_node_or_null(^"Director")
	if _director == null:
		printerr("verify_firefight: the scene has no Director.")
		return false
	_cam = _scene.get_node_or_null(^"Freecam") as Camera3D
	_target_population = int(_director.get(&"target_population"))
	_spawners.clear()
	_spawned = _zeroed()
	_died = _zeroed()
	_spawned_at_settle = _zeroed()
	_died_at_settle = _zeroed()
	_min_bodies = _zeroed()
	_max_bodies = _zeroed()
	_seen = PackedFloat32Array()
	_standing = PackedFloat32Array()
	_seen.resize(FACTION_COUNT)
	_standing.resize(FACTION_COUNT)
	for f: int in FACTION_COUNT:
		_min_bodies[f] = 1 << 30
		_max_bodies[f] = 0
	_series.clear()
	_graded_rows = 0
	_ownership_changes = 0
	_late_changes = 0
	_zone_samples = 0
	_locked_samples = 0
	_elapsed = 0.0
	_frames_at_start = Engine.get_physics_frames()
	_wall = 0.0
	_next_sample = 0.0
	_next_trace = 0.0
	_flips = {}
	_flip_log = PackedStringArray()
	_last_flip = {}
	_rebound = 0
	_bind_spawners()
	if _hooked:
		_apply_knobs()
	_lines.push_back("")
	_lines.push_back("--- trial %d of %d, target population %d" % [_run, _runs, _target_population])
	print("")
	print("--- trial %d of %d, target population %d" % [_run, _runs, _target_population])
	return true


## Listen to the ledger's own flip signal, the first frame there is a ledger to
## listen to.
##
## NOT in `_begin_run`, and this is a trap worth recording: inside `_initialize`
## the autoloads have not been instantiated yet and a scene added to `root` there
## does not run `_ready` until the first frame — measured, `/root/Factions`
## answers null and `Node.is_node_ready()` answers false — so `FirefightDirector`
## has not yet cached the ledger it is about to spend the run pushing. Everything
## the old harness read at that point was an export default, which is why nothing
## ever noticed. The ledger itself outlives every trial, so one connection covers
## all of them.
func _hook_ledger() -> void:
	if _hooked:
		return
	var ledger: Object = _director.get(&"_ledger")
	if ledger == null:
		return
	ledger.connect(&"owner_changed", _on_owner_changed)
	_hooked = true
	_apply_knobs()


## Push the command line's dial overrides onto the live objects. Called once the
## autoloads exist, and again at the top of every trial for the director's own
## exports, because each trial instances a fresh copy of the demo.
func _apply_knobs() -> void:
	for key: String in _knobs:
		var node: Object = root.get_node_or_null(^"/root/Factions")
		var name := StringName(key)
		var owner_name: String = "Factions"
		if key.begins_with("director."):
			node = _director
			name = StringName(key.substr(9))
			owner_name = "Director"
		if node == null or node.get(name) == null:
			printerr("verify_firefight: %s has no export '%s'" % [owner_name, name])
			continue
		node.set(name, float(_knobs[key]))
		_say("knob             %s.%s = %s" % [owner_name, name, _knobs[key]])


func _zeroed() -> PackedInt32Array:
	var out := PackedInt32Array()
	out.resize(FACTION_COUNT)
	return out


## Connect to every spawner so the cumulative body flow is counted at the source
## rather than inferred from a difference between samples, which cannot tell a
## quiet minute from a minute where thirty died and thirty arrived.
func _bind_spawners() -> void:
	var paths: Array = _director.get(&"spawner_paths")
	for f: int in mini(paths.size(), FACTION_COUNT):
		var s: Node = _director.get_node_or_null(paths[f])
		_spawners.append(s)
		if s == null:
			continue
		s.connect(&"spawned", _on_spawned.bind(f))


## Actors are pooled and come back, so the death hook is attached once per actor
## rather than once per spawn.
func _on_spawned(actor: Object, faction: int) -> void:
	_spawned[faction] += 1
	if actor == null or not actor.has_signal(&"died"):
		return
	var hook: Callable = _on_died.bind(faction)
	if not actor.is_connected(&"died", hook):
		actor.connect(&"died", hook)


func _on_died(_actor: Object, faction: int) -> void:
	_died[faction] += 1


## Every zone flip as it happens, off the ledger's own signal. This is the whole
## of the ownership measurement — how many, which ground, and when.
##
## IT USED TO BE SAMPLED, AND THE SAMPLING WAS IN THE ANSWER. Differencing
## `Territory.captures()` at each row means the first graded row only establishes
## a baseline, so everything between the settle mark and that row is thrown away
## and the counting window is `--sample` seconds shorter than the graded window.
## Measured: the same build scored a median of 6 at `--sample=30` and 2 at
## `--sample=60`, because the map does much of its early sorting-out in the first
## thirty seconds after the settle mark. A gate whose reading moves when you
## change how often you look at it is not measuring the demo.
func _on_owner_changed(zone_id: StringName, previous: int, current: int) -> void:
	if _elapsed < _settle:
		return
	var gap: float = _elapsed - float(_last_flip.get(zone_id, -1000.0))
	_last_flip[zone_id] = _elapsed
	if gap < _faction_export(&"capture_dwell", 10.0) * 1.25:
		_rebound += 1
	_flips[zone_id] = int(_flips.get(zone_id, 0)) + 1
	_ownership_changes += 1
	if _elapsed >= _settle + (_seconds - _settle) * 0.5:
		_late_changes += 1
	(
		_flip_log
		. append(
			(
				"%6.1f (+%5.1f)  %-13s %s -> %s"
				% [
					_elapsed,
					minf(gap, 999.9),
					zone_id,
					"-" if previous < 0 or previous >= FACTION_COUNT else FACTION_NAMES[previous],
					"-" if current < 0 or current >= FACTION_COUNT else FACTION_NAMES[current],
				]
			)
		)
	)


# -------------------------------------------------------------- measurement


func _row() -> void:
	var bodies := PackedInt32Array()
	bodies.resize(FACTION_COUNT)
	var owned := PackedInt32Array()
	owned.resize(FACTION_COUNT)
	var pooled: int = 0
	for f: int in FACTION_COUNT:
		bodies[f] = int(_director.call(&"body_count", f))
		owned[f] = int(_director.call(&"zones_owned", f))
		if f < _spawners.size() and _spawners[f] != null:
			pooled += int(_spawners[f].call(&"alive_count"))
	var shot: PackedInt32Array = _in_shot()
	var graded: bool = _elapsed >= _settle
	var locked: Vector2i = _locked_share()
	if graded:
		if _graded_rows == 0:
			for f: int in FACTION_COUNT:
				_spawned_at_settle[f] = _spawned[f]
				_died_at_settle[f] = _died[f]
		_graded_rows += 1
		_series.append(bodies)
		for f: int in FACTION_COUNT:
			_min_bodies[f] = mini(_min_bodies[f], bodies[f])
			_max_bodies[f] = maxi(_max_bodies[f], bodies[f])
			_seen[f] += float(shot[f])
			_standing[f] += float(bodies[f])
		_zone_samples += locked.y
		_locked_samples += locked.x
	var line: String = (
		(
			"%s t=%5.0fs  bodies %2d/%2d/%2d  in shot %2d/%2d/%2d  zones %d/%d/%d"
			+ "  locked %d/%d  actors %2d  spawned %3d/%3d/%3d  killed %3d"
		)
		% [
			" " if graded else "~",
			_elapsed,
			bodies[0],
			bodies[1],
			bodies[2],
			shot[0],
			shot[1],
			shot[2],
			owned[0],
			owned[1],
			owned[2],
			locked.x,
			locked.y,
			pooled,
			_spawned[0],
			_spawned[1],
			_spawned[2],
			_died[0] + _died[1] + _died[2],
		]
	)
	_lines.push_back(line)
	print(line)


## Bodies of each faction inside the spectator's authored opening frame. This is
## the framing gate, measured rather than eyeballed: a faction that is fighting
## behind the camera does not exist as far as anyone watching is concerned.
func _in_shot() -> PackedInt32Array:
	var out := PackedInt32Array()
	out.resize(FACTION_COUNT)
	if _cam == null:
		return out
	var rect: Vector2 = root.get_visible_rect().size
	for f: int in _spawners.size():
		if _spawners[f] == null:
			continue
		for actor: Node3D in _spawners[f].call(&"live_actors"):
			if not bool(actor.get(&"alive")):
				continue
			var p: Vector3 = actor.global_position + Vector3(0.0, 0.8, 0.0)
			if _cam.is_position_behind(p):
				continue
			var s: Vector2 = _cam.unproject_position(p)
			if s.x >= 0.0 and s.y >= 0.0 and s.x <= rect.x and s.y <= rect.y:
				out[f] += 1
	return out


## Zones nobody could take however hard they pushed, and zones in total.
##
## The capture test is `attacker > defender + margin` and pressure clamps at one,
## so a zone whose owner sits at or above `1 - margin` is off the board: it cannot
## change hands by any amount of fighting. That is not a slow war, it is a removed
## one, and counting it is the difference between "the map did not move" and "the
## map COULD not move".
func _locked_share() -> Vector2i:
	var ledger: Object = _director.get(&"_ledger")
	if ledger == null:
		return Vector2i.ZERO
	var margin: float = _faction_export(&"capture_margin", 0.18)
	var home_scale: float = _faction_export(&"home_margin_scale", 2.10)
	var locked: int = 0
	var n: int = int(ledger.call(&"count"))
	for i: int in n:
		var own: int = int(ledger.call(&"owner_at", i))
		if own < 0 or own >= FACTION_COUNT:
			continue
		var shape: Array = ledger.call(&"shape", ledger.call(&"id_at", i))
		var value: float = 1.0 if shape.is_empty() else float(shape[3])
		var m: float = margin * value
		if int(ledger.call(&"home_at", i)) == own:
			m *= home_scale
		if float(ledger.call(&"pressure_at", i, own)) + m >= 1.0:
			locked += 1
	return Vector2i(locked, n)


## An export off the `Factions` autoload, reached by name because this script
## compiles before the autoloads exist. See the file header.
func _faction_export(key: StringName, fallback: float) -> float:
	var node: Object = root.get_node_or_null(^"/root/Factions")
	if node == null:
		return fallback
	return float(node.get(key))


# ---------------------------------------------------------------- diagnosis


## Everything the ownership counter cannot say: which zone is whose, how hard each
## faction is leaning on it, what every squad has been told to do, and whether the
## bodies are anywhere near each other. Off unless `--trace=N` asks for it.
func _trace_block() -> void:
	var ledger: Object = _director.get(&"_ledger")
	if ledger == null:
		return
	print("TRACE t=%6.1f  wall %7.1f s  frame %d" % [_elapsed, _wall, Engine.get_process_frames()])
	var margin: float = _faction_export(&"capture_margin", 0.18)
	var home_scale: float = _faction_export(&"home_margin_scale", 2.10)
	for i: int in int(ledger.call(&"count")):
		var id: StringName = ledger.call(&"id_at", i)
		var own: int = int(ledger.call(&"owner_at", i))
		var p := PackedFloat32Array()
		for f: int in FACTION_COUNT:
			p.append(float(ledger.call(&"pressure_at", i, f)))
		var m: float = margin * float(ledger.call(&"shape", id)[3])
		if own >= 0 and int(ledger.call(&"home_at", i)) == own:
			m *= home_scale
		var lock: String = ""
		if own >= 0 and own < FACTION_COUNT and p[own] + m >= 1.0:
			lock = "LOCKED"
		var here: PackedInt32Array = _bodies_in(ledger, i)
		print(
			(
				"   zone %-13s own %-8s  p %.2f/%.2f/%.2f  need %.2f  bodies %d/%d/%d  %s%s"
				% [
					id,
					"-" if own < 0 or own >= FACTION_COUNT else FACTION_NAMES[own],
					p[0],
					p[1],
					p[2],
					(0.0 if own < 0 or own >= FACTION_COUNT else p[own]) + m,
					here[0],
					here[1],
					here[2],
					"CONTESTED " if bool(ledger.call(&"is_contested", id)) else "",
					lock,
				]
			)
		)
	var squads: Array = _director.get(&"_squads")
	var states: PackedStringArray = ["FORM_UP", "ADVANCE", "ASSAULT", "HOLD", "REGROUP", "ROUT"]
	var intents: PackedStringArray = ["HOLD", "PROBE", "ASSAULT", "REINFORCE", "WITHDRAW"]
	for s: Object in squads:
		var obj: StringName = s.call(&"objective")
		var mine: bool = int(ledger.call(&"zone_owner", obj)) == int(s.get(&"faction"))
		print(
			(
				"   squad %-10s n=%d  %-8s %-10s obj %-13s %s"
				% [
					s.get(&"squad_id"),
					int(s.call(&"size")),
					states[clampi(int(s.call(&"state")), 0, 5)],
					intents[clampi(int(s.call(&"intent")), 0, 4)],
					obj if obj != &"" else "-",
					"DEFEND" if mine else "attack",
				]
			)
		)
	print("   contact %s" % _contact_line())


## Live bodies of each faction standing inside zone `i`. Pressure is generated by
## bodies inside the cylinder and by nothing else, so this is the answer to "is
## this a ledger problem or a nobody-goes-there problem" — and those want
## completely different fixes.
func _bodies_in(ledger: Object, i: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	out.resize(FACTION_COUNT)
	var shape: Array = ledger.call(&"shape", ledger.call(&"id_at", i))
	if shape.is_empty():
		return out
	var centre: Vector3 = shape[0]
	var r2: float = float(shape[1]) * float(shape[1])
	var half_h: float = float(shape[2]) * 0.5
	for f: int in _spawners.size():
		if _spawners[f] == null:
			continue
		for actor: Node3D in _spawners[f].call(&"live_actors"):
			if not bool(actor.get(&"alive")):
				continue
			var q: Vector3 = actor.global_position
			if absf(q.y - centre.y) > half_h:
				continue
			if Vector2(q.x - centre.x, q.z - centre.z).length_squared() <= r2:
				out[f] += 1
	return out


## How many bodies of each faction have a hostile inside thirty metres. A war in
## which nobody can reach anybody is a different failure from one in which
## everybody is standing next to somebody and not shooting, and the ownership
## counter cannot tell them apart.
func _contact_line() -> String:
	var pos: Array[PackedVector3Array] = []
	for f: int in FACTION_COUNT:
		pos.append(PackedVector3Array())
		if f >= _spawners.size() or _spawners[f] == null:
			continue
		for actor: Node3D in _spawners[f].call(&"live_actors"):
			if bool(actor.get(&"alive")):
				pos[f].append(actor.global_position)
	var out := PackedStringArray()
	for f: int in FACTION_COUNT:
		var near: int = 0
		for a: Vector3 in pos[f]:
			for g: int in FACTION_COUNT:
				if g == f:
					continue
				var hit: bool = false
				for b: Vector3 in pos[g]:
					if a.distance_squared_to(b) < 900.0:
						hit = true
						break
				if hit:
					near += 1
					break
		out.append("%s %d/%d" % [FACTION_NAMES[f], near, pos[f].size()])
	return " ".join(out)


# ------------------------------------------------------------------ verdict


## Score one trial, record what it returned for the distribution, and take the
## scene down so the next trial starts on fresh ground.
func _end_run() -> void:
	var floor_bodies: float = float(_target_population) * FLOOR_FRACTION
	var rows: float = float(maxi(_graded_rows, 1))
	var kills: int = _died[0] + _died[1] + _died[2]
	for f: int in FACTION_COUNT:
		var mean: float = _mean(f)
		var late: int = _spawned[f] - _spawned_at_settle[f]
		var seen: float = _seen[f] / rows
		var share: float = _seen[f] / maxf(_standing[f], 1.0)
		_say(
			(
				"%-8s mean %5.1f  min %2d  max %2d  lost %3d  replaced %3d  in frame %4.1f (%.0f%%)"
				% [
					FACTION_NAMES[f],
					mean,
					_min_bodies[f],
					_max_bodies[f],
					_died[f] - _died_at_settle[f],
					late,
					seen,
					share * 100.0,
				]
			)
		)
		if seen < MIN_IN_FRAME or share < MIN_IN_FRAME_SHARE:
			_fail(
				(
					"trial %d: %s is not in the opening frame: %.1f bodies (%.0f%% of standing)"
					% [_run, FACTION_NAMES[f], seen, share * 100.0]
				)
			)
		if mean < floor_bodies:
			_fail(
				(
					"trial %d: %s averaged %.1f bodies against a floor of %.1f (target %d)"
					% [_run, FACTION_NAMES[f], mean, floor_bodies, _target_population]
				)
			)
		if _min_bodies[f] <= COLLAPSE_BODIES:
			_fail("trial %d: %s fell to %d bodies" % [_run, FACTION_NAMES[f], _min_bodies[f]])
		# Reinforcement is judged against LOSSES, not against zero. A faction that
		# has not been hurt does not need replacing, and asserting otherwise
		# fails the demo for the Foundry being hard to kill rather than for the
		# body economy being broken.
		# Five, not one: a faction that lost a single body over the whole graded
		# window has a replacement ratio of 0 or 1 and nothing in between, and
		# failing the demo on that is failing it for rounding.
		var lost: int = _died[f] - _died_at_settle[f]
		if lost >= 5 and float(late) < float(lost) * 0.8:
			_fail(
				(
					"trial %d: %s lost %d bodies after the settle window and replaced only %d"
					% [_run, FACTION_NAMES[f], lost, late]
				)
			)
	var locked: float = float(_locked_samples) / float(maxi(_zone_samples, 1))
	_changes_per_run.append(_ownership_changes)
	_late_per_run.append(_late_changes)
	_kills_per_run.append(kills)
	_locked_per_run.append(locked)
	_zones_moved_per_run.append(_flips.size())
	var spread := PackedStringArray()
	for id: StringName in _flips:
		spread.append("%s x%d" % [id, int(_flips[id])])
	_say("ground that changed hands: %s" % (" ".join(spread) if spread.size() > 0 else "none"))
	if _trace > 0.0:
		for line: String in _flip_log:
			print("   flip %s" % line)
	# The harness's own honesty check, printed rather than trusted. `_elapsed` is
	# physics time and `_wall` is idle time; they part company the moment the
	# machine cannot serve 60 physics ticks a second, and a trial that quietly ran
	# short of simulated seconds would look like a quiet war.
	_say(
		(
			"clock: %.0f simulated s in %.0f wall s (%.2fx)"
			% [_elapsed, _wall, _wall / maxf(_elapsed, 0.001)]
		)
	)
	_say(
		(
			(
				"trial %d: %d ownership changes (%d late) over %d zones, %d kills, "
				+ "%d rebound, %.0f%% locked"
			)
			% [
				_run,
				_ownership_changes,
				_late_changes,
				_flips.size(),
				kills,
				_rebound,
				locked * 100.0,
			]
		)
	)
	var rebound_share: float = float(_rebound) / float(maxi(_ownership_changes, 1))
	_rebound_per_run.append(rebound_share)
	if _rebound >= MIN_REBOUNDS_TO_JUDGE and rebound_share > MAX_DWELL_LIMITED_SHARE:
		_fail(
			(
				(
					"trial %d: %d of %d flips came back inside the settle window — the map is "
					+ "keeping time with `capture_dwell`, not with the fighting"
				)
				% [_run, _rebound, _ownership_changes]
			)
		)
	if _flips.size() < MIN_ZONES_MOVED:
		_fail(
			(
				(
					"trial %d: only %d of the %d zones ever changed hands — the rest of the map "
					+ "is scenery"
				)
				% [_run, _flips.size(), _zone_samples / maxi(_graded_rows, 1)]
			)
		)
	if locked > MAX_LOCKED_SHARE:
		_fail(
			(
				(
					"trial %d: %.0f%% of graded zone-samples were uncapturable — the ledger, "
					+ "not the fighting, decided the map"
				)
				% [_run, locked * 100.0]
			)
		)
	if _ownership_changes < MIN_WORST_CHANGES:
		_fail(
			(
				"trial %d: the map changed hands %d times in %.0f s — it set like concrete"
				% [_run, _ownership_changes, _elapsed - _settle]
			)
		)
	if _first_kills < 0:
		_first_kills = kills
	elif _determinism == "not measured":
		_determinism = (
			"trial 1 and trial 2 finished %d and %d kills apart-from-identical inputs"
			% [_first_kills, kills]
		)
	# Freed here and now rather than queued: the next trial is instanced in the
	# same call, and two copies of the demo alive at once would both register the
	# same zone ids with the ledger — which `Territory.register_zone` answers by
	# re-owning the existing row, counting a capture that never happened.
	_scene.free()
	_scene = null
	_director = null
	_cam = null


func _verdict() -> void:
	var mid_changes: int = _median(_changes_per_run)
	var late_trials: int = 0
	for n: int in _late_per_run:
		if n > 0:
			late_trials += 1
	_say("")
	var header := PackedStringArray()
	for n: int in _runs:
		header.append("%4d" % (n + 1))
	_say("trial       " + " ".join(header))
	_say("ownership   " + _row_of(_changes_per_run))
	_say("late half   " + _row_of(_late_per_run))
	_say("zones moved " + _row_of(_zones_moved_per_run))
	_say("kills       " + _row_of(_kills_per_run))
	_say("")
	_say(
		(
			"ownership changes  median %d  min %d  max %d  (bar: median %d, worst %d)"
			% [
				mid_changes,
				_min_of(_changes_per_run),
				_max_of(_changes_per_run),
				MIN_OWNERSHIP_CHANGES,
				MIN_WORST_CHANGES,
			]
		)
	)
	_say(
		(
			"late-half changes  %d of %d trials moved late  (bar: %d)"
			% [late_trials, _runs, int(ceil(float(_runs) * MIN_LATE_TRIAL_SHARE))]
		)
	)
	_say("reproducibility    %s" % _determinism)
	if mid_changes < MIN_OWNERSHIP_CHANGES:
		_fail(
			(
				"the median trial changed hands %d times in %.0f graded seconds — stalemate"
				% [mid_changes, _seconds - _settle]
			)
		)
	if float(late_trials) < float(_runs) * MIN_LATE_TRIAL_SHARE:
		_fail(
			(
				(
					"only %d of %d trials changed hands at all in the late half — the war is "
					+ "settling its borders early and then stopping"
				)
				% [late_trials, _runs]
			)
		)
	_say("")
	for problem: String in _failures:
		_lines.push_back("FAIL  %s" % problem)
	_say("VERDICT          : %s" % ("PASS" if _failures.is_empty() else "FAIL"))
	_write_report()
	quit(0 if _failures.is_empty() else 1)


func _say(line: String) -> void:
	_lines.push_back(line)
	print(line)


func _row_of(v: PackedInt32Array) -> String:
	var out := PackedStringArray()
	for x: int in v:
		out.append("%4d" % x)
	return " ".join(out)


func _median(v: PackedInt32Array) -> int:
	if v.is_empty():
		return 0
	var s: PackedInt32Array = v.duplicate()
	s.sort()
	return s[s.size() / 2] if s.size() % 2 == 1 else mini(s[s.size() / 2 - 1], s[s.size() / 2])


func _min_of(v: PackedInt32Array) -> int:
	var m: int = 1 << 30
	for x: int in v:
		m = mini(m, x)
	return 0 if v.is_empty() else m


func _max_of(v: PackedInt32Array) -> int:
	var m: int = 0
	for x: int in v:
		m = maxi(m, x)
	return m


func _mean(faction: int) -> float:
	if _series.is_empty():
		return 0.0
	var sum: float = 0.0
	for row: PackedInt32Array in _series:
		sum += float(row[faction])
	return sum / float(_series.size())


func _fail(message: String) -> void:
	_failures.push_back(message)
	printerr("verify_firefight: %s" % message)


# ------------------------------------------------------------------- output


func _write_report() -> void:
	DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path(_report_path.get_base_dir())
	)
	var f: FileAccess = FileAccess.open(_report_path, FileAccess.WRITE)
	if f == null:
		printerr("verify_firefight: cannot write %s" % _report_path)
		return
	f.store_string("\n".join(_lines) + "\n")
	f.close()


func _parse_args(args: PackedStringArray) -> void:
	for a: String in args:
		if a.begins_with("--runs="):
			_runs = clampi(a.substr(7).to_int(), 1, 10)
		elif a.begins_with("--seconds="):
			_seconds = maxf(1.0, a.substr(10).to_float())
		elif a.begins_with("--sample="):
			_sample = maxf(0.5, a.substr(9).to_float())
		elif a.begins_with("--settle="):
			_settle = maxf(0.0, a.substr(9).to_float())
		elif a.begins_with("--report="):
			_report_path = a.substr(9)
		elif a.begins_with("--trace="):
			_trace = maxf(0.0, a.substr(8).to_float())
		elif a.begins_with("--knob="):
			var kv: PackedStringArray = a.substr(7).split("=", true, 1)
			if kv.size() == 2:
				_knobs[kv[0]] = kv[1].to_float()
			else:
				printerr("verify_firefight: --knob wants name=value, got %s" % a)
		else:
			printerr("verify_firefight: unknown option %s" % a)
