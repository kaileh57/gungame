extends Node
## Headless three-faction war, run over simulated time to prove the territory
## rules produce a war rather than an outcome.
##
## Loaded and driven by `sim_factions.gd`, which is the thing you actually run:
##
##     godot --headless --path <project> --script res://systems/ai/verify/sim_factions.gd
##
## It lives in a separate file from that runner because a script handed to
## `--script` is compiled before the autoloads exist, and every line below leans
## on `Factions`.
##
## Nothing here is shipped. It drives the real `Factions.territory` ledger, the
## real `AIBlackboard`, the real `AISquad` and the real `AIRoles` solver — only
## the bodies are fake, and they are fake only in that they move in straight lines
## and shoot without raycasting. Everything that decides who owns what is
## production code.
##
## It fails loudly on the two ways this system can be wrong: a stalemate, where
## the map stops changing hands, and a wipe, where somebody is eliminated and the
## level has nothing left to spawn.

## The whole run, in one line, once it is over.
signal finished(report: String)

const DT: float = 0.25
const DURATION: float = 900.0
const REPORT_EVERY: float = 60.0
const GRID: int = 3
const SPACING: float = 70.0
const ZONE_RADIUS: float = 26.0
const ZONE_HEIGHT: float = 30.0
const SQUADS_PER_FACTION: int = 3
const SQUAD_SIZE: int = 5
const PINNED_SPEED_SCALE: float = 0.15
const ENGAGE_DISTANCE: float = 28.0
const SIGHT_DISTANCE: float = 55.0
const REINFORCE_PERIOD: float = 22.0
const RETARGET_PERIOD: float = 12.0
const SAMPLE_PERIOD: float = 10.0
## Captures below this over the whole run means the map has set, whatever the
## last five minutes happened to do.
const MIN_CAPTURES: int = 8
const SEED: int = 0x5CA71E

## Overridden by the runner from the command line, for a different war.
var seed_value: int = SEED


class Body:
	extends RefCounted

	var id: int = 0
	var faction: int = 0
	var squad: int = 0
	var pos: Vector3 = Vector3.ZERO
	var health: float = 100.0
	var ammo: float = 1.0
	var alive: bool = true


var _rng: XorShift32 = null
var _ledger: Factions.Territory = null
var _boards: Array[AIBlackboard] = []
var _squads: Array = []
var _bodies: Array[Body] = []
var _profiles: Array[AISpeciesProfile] = []
var _doctrine: AIRoles = null
var _home: PackedInt32Array = PackedInt32Array()
var _retarget: PackedFloat32Array = PackedFloat32Array()
var _reinforce: PackedFloat32Array = PackedFloat32Array()
var _next_id: int = 1
var _clock: float = 0.0
var _min_zones: PackedInt32Array = PackedInt32Array()
var _max_zones: PackedInt32Array = PackedInt32Array()
var _history: Array[PackedInt32Array] = []
var _callouts: PackedInt32Array = PackedInt32Array()
var _role_hist: PackedInt32Array = PackedInt32Array()


func _ready() -> void:
	_run_all.call_deferred()


func _run_all() -> void:
	_rng = XorShift32.new(seed_value)
	_doctrine = AIRoles.new()
	_ledger = Factions.territory
	Factions.territory_auto_tick = false
	_callouts.resize(AISquad.CALL_COUNT)
	_role_hist.resize(AIRoles.ROLE_COUNT)
	_min_zones.resize(Factions.COUNT)
	_max_zones.resize(Factions.COUNT)
	_retarget.resize(Factions.COUNT * SQUADS_PER_FACTION)
	_reinforce.resize(Factions.COUNT)
	for f: int in Factions.COUNT:
		_min_zones[f] = 99
		_max_zones[f] = 0
	_build_map()
	_build_profiles()
	_build_squads()
	_run()


func _build_map() -> void:
	_home.resize(Factions.COUNT)
	_home[Factions.F.SCAV] = 0
	_home[Factions.F.FOUNDRY] = 2
	_home[Factions.F.CHOIR] = 7
	for i: int in GRID * GRID:
		var owner_faction: int = Factions.NEUTRAL_ID
		for f: int in Factions.COUNT:
			if _home[f] == i:
				owner_faction = f
		var value: float = 1.0 if i != 4 else 1.6
		_ledger.register_zone(
			_zone_name(i), _zone_center(i), ZONE_RADIUS, ZONE_HEIGHT, owner_faction, value
		)


func _zone_name(i: int) -> StringName:
	return StringName("zone_%d" % i)


func _zone_center(i: int) -> Vector3:
	var x: float = float(i % GRID) - float(GRID - 1) * 0.5
	var z: float = float(i / GRID) - float(GRID - 1) * 0.5
	return Vector3(x * SPACING, 0.0, z * SPACING)


## Three troop types that fight three different ways, so the role solver has
## something to actually choose between.
func _build_profiles() -> void:
	_profiles.resize(Factions.COUNT)
	_profiles[Factions.F.SCAV] = _profile(&"rag", 6.2, 34.0, 32, 22.0, 1.5, 1.3, 0.9, 0.55)
	_profiles[Factions.F.FOUNDRY] = _profile(&"founder", 4.0, 62.0, 100, 22.0, 0.7, 0.6, 1.8, 0.85)
	_profiles[Factions.F.CHOIR] = _profile(&"cantor", 5.1, 108.0, 10, 22.0, 1.1, 1.2, 0.8, 0.70)


func _profile(
	id: StringName,
	run: float,
	reach: float,
	mag: int,
	dps: float,
	advancer: float,
	flanker: float,
	suppressor: float,
	rout: float
) -> AISpeciesProfile:
	var p: AISpeciesProfile = AISpeciesProfile.new()
	p.species_id = id
	p.display_name = String(id)
	p.run_speed = run
	p.walk_speed = run * 0.42
	p.weapon_range = reach
	p.magazine = mag
	p.damage = dps
	p.rpm = 420.0
	p.sight_range = SIGHT_DISTANCE
	if mag > 20:
		p.weapon = AISpeciesProfile.Weapon.AUTO
	else:
		p.weapon = AISpeciesProfile.Weapon.RIFLE
	p.bias_advancer = advancer
	p.bias_flanker = flanker
	p.bias_suppressor = suppressor
	p.bias_scout = 0.8
	p.rout_fraction = rout
	p.flee_health = 0.2
	return p


func _build_squads() -> void:
	_boards.resize(Factions.COUNT)
	for f: int in Factions.COUNT:
		_boards[f] = AIBlackboard.new()
		var home: Vector3 = _zone_center(_home[f])
		for s: int in SQUADS_PER_FACTION:
			var id: StringName = StringName("%s_%d" % [Factions.NAMES[f], s])
			var squad: AISquad = AISquad.new(id, f, _doctrine, _boards[f])
			squad.callout_made.connect(_on_callout)
			squad.set_objective(_zone_name(_home[f]), home, home)
			_squads.append(squad)
			for m: int in SQUAD_SIZE:
				_spawn(f, _squads.size() - 1, home)


func _squad_at(faction: int, s: int) -> AISquad:
	return _squads[faction * SQUADS_PER_FACTION + s]


func _spawn(faction: int, squad_index: int, near: Vector3) -> void:
	var b: Body = Body.new()
	b.id = _next_id
	_next_id += 1
	b.faction = faction
	b.squad = squad_index
	b.pos = near + Vector3(_rng.next_range(-6.0, 6.0), 0.0, _rng.next_range(-6.0, 6.0))
	_bodies.append(b)
	(_squads[squad_index] as AISquad).add_member(b.id, _profiles[faction])


func _on_callout(kind: int, _p: Vector3, _target_id: int) -> void:
	_callouts[kind] += 1


func _run() -> void:
	var next_report: float = REPORT_EVERY
	print(
		(
			"t(s)  %-8s %-8s %-8s  neutral contested captures  bodies"
			% [Factions.NAMES[0], Factions.NAMES[1], Factions.NAMES[2]]
		)
	)
	_report()
	var next_sample: float = SAMPLE_PERIOD
	while _clock < DURATION:
		_step()
		_clock += DT
		if _clock >= next_sample:
			next_sample += SAMPLE_PERIOD
			_history.append(_owned())
		if _clock >= next_report:
			next_report += REPORT_EVERY
			_report()
	_verdict()


func _step() -> void:
	_sense()
	_think()
	_move()
	_fight()
	_reinforce_step()
	for f: int in Factions.COUNT:
		_boards[f].decay(DT, 0.06)
		_boards[f].interest.flush(f, 1.0)
	Factions.tick_territory(DT)


## Everybody looks. A sighting goes on the looker's faction blackboard, which is
## the only way the squads ever learn where anything is.
func _sense() -> void:
	var sight2: float = SIGHT_DISTANCE * SIGHT_DISTANCE
	for a: Body in _bodies:
		if not a.alive:
			continue
		for b: Body in _bodies:
			if not b.alive or not Factions.hostile(a.faction, b.faction):
				continue
			var d2: float = a.pos.distance_squared_to(b.pos)
			if d2 > sight2:
				continue
			var conf: float = clampf(1.0 - sqrt(d2) / SIGHT_DISTANCE, 0.15, 1.0)
			_boards[a.faction].report(b.id, b.pos, Vector3.ZERO, conf, 1.0)


func _think() -> void:
	for f: int in Factions.COUNT:
		_boards[f].strength = _count_bodies(f)
		for s: int in SQUADS_PER_FACTION:
			var squad: AISquad = _squad_at(f, s)
			var k: int = f * SQUADS_PER_FACTION + s
			_retarget[k] -= DT
			if _retarget[k] <= 0.0 or squad.objective() == &"":
				_retarget[k] = RETARGET_PERIOD
				_choose_objective(f, squad)
			_report_members(squad)
			squad.tick(DT)


func _report_members(squad: AISquad) -> void:
	for b: Body in _bodies:
		if not b.alive or _squads[b.squad] != squad:
			continue
		var near: int = _hostiles_within(b, ENGAGE_DISTANCE)
		squad.report(
			b.id,
			b.pos,
			b.health / 100.0,
			b.ammo,
			_hostiles_within(b, SIGHT_DISTANCE) > 0,
			_rng.chance(0.35),
			minf(float(near) * 0.22, 1.0)
		)


## Where a squad goes next: enemy and unclaimed ground first, its own contested
## ground when it is being taken off it, and never where its own faction already
## has bodies enough.
func _choose_objective(faction: int, squad: AISquad) -> void:
	var from: Vector3 = squad.centroid()
	var best: int = -1
	var best_s: float = -INF
	var aggro: float = Factions.aggression(faction)
	for i: int in _ledger.count():
		var id: StringName = _ledger.id_at(i)
		var owner_faction: int = _ledger.owner_at(i)
		var dist: float = from.distance_to(_ledger.center_at(i))
		var s: float = 0.0
		if owner_faction == faction:
			s = 1.5 if _ledger.is_contested(id) else 0.10
		elif owner_faction < 0:
			s = 1.2 * aggro
		else:
			# Probe the weak point. A zone whose holder is not standing on it is
			# worth three of a zone that is properly garrisoned.
			s = aggro * (0.35 + 1.30 * (1.0 - _ledger.pressure_at(i, owner_faction)))
		s *= 1.0 + 0.8 * _ledger.pressure_at(i, faction)
		s *= float(_ledger.shape(id)[3])
		s /= 1.0 + dist / SPACING
		s /= 1.0 + float(_boards[faction].roster.committed_to(id)) * 0.45
		if s > best_s:
			best_s = s
			best = i
	if best < 0:
		return
	squad.set_objective(_ledger.id_at(best), _ledger.center_at(best), _rally_for(faction, from))


## A squad falls back to the nearest ground its own faction actually holds, not
## all the way home. Rallying to the capital is how a faction stops fighting.
func _rally_for(faction: int, from: Vector3) -> Vector3:
	var best: Vector3 = _zone_center(_home[faction])
	var best_d: float = INF
	for i: int in _ledger.count():
		if _ledger.owner_at(i) != faction:
			continue
		var d: float = from.distance_squared_to(_ledger.center_at(i))
		if d < best_d:
			best_d = d
			best = _ledger.center_at(i)
	return best


func _move() -> void:
	for b: Body in _bodies:
		if not b.alive:
			continue
		var squad: AISquad = _squads[b.squad]
		var goal: Vector3 = _goal_for(squad, b)
		var to: Vector3 = goal - b.pos
		var dist: float = to.length()
		if dist < 1.0:
			squad.report_arrived(b.id)
			continue
		var speed: float = _profiles[b.faction].run_speed
		if not squad.may_advance(b.id):
			speed *= PINNED_SPEED_SCALE
		b.pos += to / dist * minf(speed * DT, dist)


func _goal_for(squad: AISquad, b: Body) -> Vector3:
	var state: int = squad.state()
	if state == AISquad.State.REGROUP or state == AISquad.State.ROUT:
		return squad.rally_point()
	if state == AISquad.State.ASSAULT and squad.role_of(b.id) != AIRoles.Role.ANCHOR:
		return squad.focus_position()
	return squad.objective_point()


func _fight() -> void:
	for a: Body in _bodies:
		if not a.alive:
			continue
		var victim: Body = _nearest_hostile(a, ENGAGE_DISTANCE)
		if victim == null:
			continue
		a.ammo = maxf(a.ammo - DT * 0.05, 0.0)
		if a.ammo <= 0.0:
			a.ammo = 1.0
			continue
		if not _rng.chance(0.30):
			continue
		victim.health -= _profiles[a.faction].damage * DT
		if victim.health > 0.0:
			continue
		victim.alive = false
		(_squads[victim.squad] as AISquad).remove_member(victim.id, true)


## Reinforcement scales with holdings — ground is where bodies come from — but
## it scales harder with how badly a faction has been hurt. Without that second
## term the body economy runs away on its own and no ledger rule can catch it:
## the winner simply fields three times the rifles and the war is over.
func _reinforce_step() -> void:
	var full: float = float(SQUADS_PER_FACTION * SQUAD_SIZE)
	for f: int in Factions.COUNT:
		var holdings: float = 0.6 * _ledger.share(f) * float(Factions.COUNT)
		var deficit: float = 1.0 - float(_count_bodies(f)) / full
		_reinforce[f] -= DT * (0.7 + holdings + 1.2 * deficit)
		if _reinforce[f] > 0.0:
			continue
		_reinforce[f] = REINFORCE_PERIOD
		var wave: int = 1 + int(deficit * 2.0)
		var where: Vector3 = _spawn_point(f)
		for _n: int in wave:
			var weakest: int = _weakest_squad(f)
			if weakest < 0:
				break
			var squad: AISquad = _squads[weakest]
			if squad.state() == AISquad.State.ROUT or squad.size() == 0:
				squad.reform(where)
			_spawn(f, weakest, where)
		_prune()


func _weakest_squad(faction: int) -> int:
	var weakest: int = -1
	var fewest: int = SQUAD_SIZE
	for s: int in SQUADS_PER_FACTION:
		var squad: AISquad = _squad_at(faction, s)
		if squad.size() < fewest:
			fewest = squad.size()
			weakest = faction * SQUADS_PER_FACTION + s
	return weakest


## Reinforcements come in on the quietest ground the faction still holds. A wave
## that lands on top of the enemy is not a reinforcement, it is a queue.
func _spawn_point(faction: int) -> Vector3:
	var best: Vector3 = _zone_center(_home[faction])
	var best_d: float = -1.0
	for i: int in _ledger.count():
		if _ledger.owner_at(i) != faction:
			continue
		var c: Vector3 = _ledger.center_at(i)
		var nearest: float = INF
		for b: Body in _bodies:
			if b.alive and Factions.hostile(faction, b.faction):
				nearest = minf(nearest, c.distance_squared_to(b.pos))
		if nearest > best_d:
			best_d = nearest
			best = c
	return best


## Drop the dead out of the body list so the O(n²) sense and fight loops stay
## proportional to what is actually standing.
func _prune() -> void:
	var live: Array[Body] = []
	for b: Body in _bodies:
		if b.alive:
			live.append(b)
	_bodies = live


func _nearest_hostile(a: Body, radius: float) -> Body:
	var best: Body = null
	var best_d: float = radius * radius
	for b: Body in _bodies:
		if not b.alive or not Factions.hostile(a.faction, b.faction):
			continue
		var d: float = a.pos.distance_squared_to(b.pos)
		if d < best_d:
			best_d = d
			best = b
	return best


func _hostiles_within(a: Body, radius: float) -> int:
	var n: int = 0
	var r2: float = radius * radius
	for b: Body in _bodies:
		if not b.alive or not Factions.hostile(a.faction, b.faction):
			continue
		if a.pos.distance_squared_to(b.pos) < r2:
			n += 1
	return n


func _count_bodies(faction: int) -> int:
	var n: int = 0
	for b: Body in _bodies:
		if b.alive and b.faction == faction:
			n += 1
	return n


func _owned() -> PackedInt32Array:
	var out: PackedInt32Array = PackedInt32Array()
	out.resize(Factions.COUNT)
	for i: int in _ledger.count():
		var f: int = _ledger.owner_at(i)
		if f >= 0:
			out[f] += 1
	return out


func _report() -> void:
	var owned: PackedInt32Array = _owned()
	var neutral: int = _ledger.count() - owned[0] - owned[1] - owned[2]
	var contested: int = 0
	for i: int in _ledger.count():
		if _ledger.is_contested(_ledger.id_at(i)):
			contested += 1
	for f: int in Factions.COUNT:
		_min_zones[f] = mini(_min_zones[f], owned[f])
		_max_zones[f] = maxi(_max_zones[f], owned[f])
		for s: int in SQUADS_PER_FACTION:
			var squad: AISquad = _squad_at(f, s)
			for b: Body in _bodies:
				if b.alive and _squads[b.squad] == squad:
					_role_hist[squad.role_of(b.id)] += 1
	_history.append(owned)
	print(
		(
			"%4d  %-8d %-8d %-8d  %-7d %-9d %-9d %d/%d/%d"
			% [
				int(_clock),
				owned[0],
				owned[1],
				owned[2],
				neutral,
				contested,
				_ledger.captures(),
				_count_bodies(0),
				_count_bodies(1),
				_count_bodies(2),
			]
		)
	)


func _verdict() -> void:
	print("")
	for f: int in Factions.COUNT:
		print(
			(
				"%-8s zones min %d max %d  final %d"
				% [Factions.NAMES[f], _min_zones[f], _max_zones[f], _owned()[f]]
			)
		)
	print("captures total: %d" % _ledger.captures())
	var roles: String = ""
	for r: int in AIRoles.ROLE_COUNT:
		roles += "%s=%d " % [_doctrine.role_name(r), _role_hist[r]]
	print("role-tick histogram: %s" % roles.strip_edges())
	var calls: String = ""
	for k: int in AISquad.CALL_COUNT:
		calls += "%s=%d " % [AISquad.CALL_NAMES[k], _callouts[k]]
	print("callouts: %s" % calls.strip_edges())

	var wiped: bool = false
	for f: int in Factions.COUNT:
		if _min_zones[f] <= 0:
			wiped = true
	var late_changes: int = 0
	var third: int = _history.size() * 2 / 3
	for i: int in range(third + 1, _history.size()):
		if _history[i] != _history[i - 1]:
			late_changes += 1
	# A war has not settled if ground is still moving at the end of it, and if it
	# moved often enough over the whole run that the one late flip was not luck.
	var late_change: bool = late_changes >= 1 and _ledger.captures() >= MIN_CAPTURES
	var monopoly: bool = false
	for f: int in Factions.COUNT:
		if _max_zones[f] >= _ledger.count():
			monopoly = true
	print("")
	print("NO WIPE      : %s" % ("PASS" if not wiped else "FAIL"))
	print(
		(
			"NO STALEMATE : %s (%d ownership shifts in the final third)"
			% ["PASS" if late_change else "FAIL", late_changes]
		)
	)
	print("NO MONOPOLY  : %s" % ("PASS" if not monopoly else "FAIL"))
	print("ROLES USED   : %s" % ("PASS" if _roles_all_used() else "FAIL"))
	var ok: bool = not wiped and not monopoly and late_change and _roles_all_used()
	(
		finished
		. emit(
			(
				"VERDICT %s — %d captures, zone floors %d/%d/%d over %d s"
				% [
					"PASS" if ok else "FAIL",
					_ledger.captures(),
					_min_zones[0],
					_min_zones[1],
					_min_zones[2],
					int(DURATION),
				]
			)
		)
	)


func _roles_all_used() -> bool:
	for r: int in AIRoles.ROLE_COUNT:
		if _role_hist[r] <= 0:
			return false
	return true
