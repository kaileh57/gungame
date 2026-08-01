class_name AIBlackboard
extends RefCounted
## What one faction collectively knows. One of these per faction, owned by the
## director, written by every agent in it.
##
## The blackboard is the only channel through which knowledge crosses between
## agents, and it is deliberately lossy: a report arrives with a confidence, and
## confidence decays on its own clock whether or not anybody is still looking.
## That single rule produces most of the behaviour that reads as competence — a
## squad converging on a callout, a squad still sweeping a corner two minutes
## after the player left it, and a marksman shooting at something it cannot see
## because a spotter can.
##
## IT IS NOT A HIVE MIND ANY MORE. A sighting of something the faction is not
## already tracking does not land here. It lands in `sightings`, where it waits
## for a squad to notice it has a man looking at it; that squad SAYS SO, on
## `net`, and the words take time to arrive and carry a position that is wrong by
## more the further away the caller was. Only then does it appear here, and at
## first only for the squad that called it — `best_for` will not hand a contact to
## a squad that has not been told. The rest of the faction hears the relay a
## second or two later, if the faction has radios at all.
##
## Refreshing something the faction is ALREADY tracking is a different act and
## goes straight in. Once everyone is looking at the same man, watching him is not
## a callout.
##
## It also carries the scarce things a faction has to ration: how many bodies are
## already shooting at a given contact, who has permission to throw the one grenade
## nobody wants landing in their own squad, and which squads have shouted for help.

## Capacity of the contact table. A faction that is tracking more than this many
## separate enemies has already lost.
const MAX_CONTACTS: int = 16
## Seconds a contact survives with nobody refreshing it.
const CONTACT_LIFETIME: float = 45.0

## Bodies this faction has lost since the scene started.
var casualties: int = 0
## Bodies still standing. The director refreshes this on its slow tick.
var strength: int = 0
## Which faction this is. Written by the first squad to tick against it, because
## a blackboard is constructed before anybody knows whose it is.
var faction: int = Factions.NEUTRAL_ID
## Shared squad doctrine, adopted from the first squad to tick against it. Read by
## the command layer for its thresholds.
var doctrine: AIRoles = null
## Who is in the field and what they are doing. Squads publish into it once per
## slow tick; the command layer reads it to decide who gets which job.
var roster: Roster = Roster.new()
## This faction's accumulated weight on each zone, fused across every squad and
## flushed to the global ledger in one write per zone.
var interest: ZoneInterest = ZoneInterest.new()
## The radio and the raised voice. Everything one squad learns from another
## crosses this, with a delay and an error.
var net: AIComms = AIComms.new()
## Faction command: what each squad has been told to do about the ledger.
var command: AIOrders = AIOrders.new()
## Squads that have shouted for help and are still waiting.
var support: Support = Support.new()
## Sightings nobody has called out yet.
var sightings: Sightings = Sightings.new()

var _id: PackedInt32Array = PackedInt32Array()
var _pos: PackedVector3Array = PackedVector3Array()
var _vel: PackedVector3Array = PackedVector3Array()
var _confidence: PackedFloat32Array = PackedFloat32Array()
var _threat: PackedFloat32Array = PackedFloat32Array()
var _reported_at: PackedFloat32Array = PackedFloat32Array()
var _engaged: PackedInt32Array = PackedInt32Array()
## Squad that called this contact and is so far the only one that knows about it.
## Empty once the relay has gone out and it belongs to the whole faction.
var _owner: Array[StringName] = []
var _used: int = 0
var _now: float = 0.0
var _grenade_holder: int = -1
var _grenade_until: float = 0.0
var _hearsay_cursor: int = 0


func _init() -> void:
	_id.resize(MAX_CONTACTS)
	_pos.resize(MAX_CONTACTS)
	_vel.resize(MAX_CONTACTS)
	_confidence.resize(MAX_CONTACTS)
	_threat.resize(MAX_CONTACTS)
	_reported_at.resize(MAX_CONTACTS)
	_engaged.resize(MAX_CONTACTS)
	_owner.resize(MAX_CONTACTS)
	reset()
	Factions.body_lost.connect(_on_body_lost)


func reset() -> void:
	_used = 0
	casualties = 0
	strength = 0
	_grenade_holder = -1
	_now = 0.0
	_hearsay_cursor = 0
	roster.clear()
	interest.clear()
	support.clear()
	sightings.clear()
	net.clear()
	command.clear()
	for i: int in MAX_CONTACTS:
		_id[i] = -1
		_engaged[i] = 0
		_owner[i] = &""


## File a sighting.
##
## Something the faction is already tracking is refreshed in place: a weaker
## report never overwrites a stronger recent one, which is what stops a distant
## agent's guess from moving a contact somebody else has in their sights.
##
## Something NEW goes into `sightings` instead and waits to be called out. That
## delay is the whole difference between a squad and a swarm, and it is deliberate
## that this function cannot tell the caller apart from any other: the agent API
## carries no observer id, so the squads work out whose sighting it is from which
## of their own members has eyes on it. See `AISquad.tick`.
func report(target_id: int, p: Vector3, v: Vector3, confidence: float, threat: float) -> void:
	var i: int = slot_of(target_id)
	if i < 0:
		sightings.file(target_id, p, v, confidence, threat, _now)
		return
	if confidence >= _confidence[i] - 0.05 or _now - _reported_at[i] > 1.5:
		_pos[i] = p
		_vel[i] = v
		_confidence[i] = maxf(confidence, _confidence[i] * 0.5)
		_reported_at[i] = _now
	_threat[i] = maxf(_threat[i], threat)


## Advance the clock and bleed every contact. `rate` is confidence lost per
## second — the director scales it so a faction that is standing still in the open
## forgets faster than one actively hunting.
##
## This is also where the faction thinks. The name is what every director already
## calls, so the rest of the slow tick lives behind it: the net is served, anything
## that has arrived is written down, dead support calls are struck off, and command
## re-reads the board and re-issues orders. All of it is O(zones + squads + queue)
## and none of it is per body.
func decay(delta: float, rate: float) -> void:
	_now += delta
	var i: int = 0
	while i < _used:
		_confidence[i] = maxf(_confidence[i] - rate * delta, 0.0)
		if _confidence[i] <= 0.01 or _now - _reported_at[i] > CONTACT_LIFETIME:
			_drop(i)
			continue
		i += 1
	if _grenade_holder != -1 and _now > _grenade_until:
		_grenade_holder = -1
	sightings.expire(_now)
	support.expire(_now)
	net.advance(delta)
	_absorb_hearsay()
	_run_command(delta)


func count() -> int:
	return _used


func slot_of(target_id: int) -> int:
	for i: int in _used:
		if _id[i] == target_id:
			return i
	return -1


func contact_id(i: int) -> int:
	return _id[i]


func contact_position(i: int) -> Vector3:
	return _pos[i]


func contact_velocity(i: int) -> Vector3:
	return _vel[i]


func contact_confidence(i: int) -> float:
	return _confidence[i]


func contact_threat(i: int) -> float:
	return _threat[i]


func contact_age(i: int) -> float:
	return _now - _reported_at[i]


## Where a contact probably is, extrapolated along its last velocity and faded out
## by how stale the report is.
func predicted_position(i: int) -> Vector3:
	return _pos[i] + _vel[i] * minf(contact_age(i), 2.0) * _confidence[i]


## The contact a body at `from` should be worrying about: near, confident,
## dangerous, and not already being shot at by half the faction.
##
## `listener_squad` is who is asking. A contact one squad has called and the relay
## has not yet carried is invisible to everybody else, which is the point of the
## whole net — pass `&""` and you get only what the faction as a whole knows.
##
## `incumbent` is the target the asker is ALREADY shooting at, and `keep_bonus` is
## how much it is worth to carry on. Two things happen to it: it gets the bonus,
## and its crowd penalty is discounted by the asker's own claim, because a squad
## should not talk itself off a target on the grounds that somebody is engaging it
## when that somebody is itself. Together they are what turns a squad that sprays
## its fire across three contacts into one that finishes one and moves on.
func best_for(
	from: Vector3,
	max_range: float,
	listener_squad: StringName = &"",
	incumbent: int = -1,
	keep_bonus: float = 0.0
) -> int:
	var best: int = -1
	var best_score: float = 0.0
	var r2: float = max_range * max_range
	for i: int in _used:
		if _owner[i] != &"" and _owner[i] != listener_squad:
			continue
		var d2: float = from.distance_squared_to(_pos[i])
		if d2 > r2:
			continue
		var mine: bool = _id[i] == incumbent
		var crowd_n: int = maxi(_engaged[i] - 1, 0) if mine else _engaged[i]
		var near: float = 1.0 - sqrt(d2) / maxf(max_range, 1.0)
		var crowd: float = 1.0 / (1.0 + float(crowd_n) * 0.35)
		var s: float = _confidence[i] * _threat[i] * (0.35 + 0.65 * near) * crowd
		if mine:
			s *= 1.0 + keep_bonus
		if s > best_score:
			best_score = s
			best = i
	return best


## Take or drop a share of a contact. Purely a counter — it spreads fire across
## targets instead of stacking a whole squad onto one body.
func mark_engaged(target_id: int, engaging: bool) -> void:
	var i: int = slot_of(target_id)
	if i < 0:
		return
	_engaged[i] = maxi(_engaged[i] + (1 if engaging else -1), 0)


func engaged_count(target_id: int) -> int:
	var i: int = slot_of(target_id)
	return 0 if i < 0 else _engaged[i]


## One grenade in the air per faction at a time. Everything else in a firefight is
## recoverable; two agents cooking off frags in the same doorway is not.
func request_grenade(agent_id: int, hold_seconds: float) -> bool:
	if _grenade_holder != -1 and _grenade_holder != agent_id and _now <= _grenade_until:
		return false
	_grenade_holder = agent_id
	_grenade_until = _now + hold_seconds
	return true


func release_grenade(agent_id: int) -> void:
	if _grenade_holder == agent_id:
		_grenade_holder = -1


## A body of this faction was killed. Counts the casualty and tells the rest of
## the world, so the faction that shot it stops holding a contact and a fire order
## on a corpse.
func note_body_lost(target_id: int, position: Vector3) -> void:
	casualties += 1
	Factions.report_body_lost(faction, target_id, position)


## The board's own clock, in seconds since `reset`. Squads and the command layer
## share it so every age and every timer in a faction is measured the same way.
func clock() -> float:
	return _now


## Somebody, somewhere, stopped existing. Only interesting when it is somebody we
## were tracking — then the contact goes, and the squads that were engaging it
## find out on their next tick and say so.
func _on_body_lost(lost_faction: int, target_id: int, _position: Vector3) -> void:
	if lost_faction == faction:
		return
	var i: int = slot_of(target_id)
	if i >= 0:
		_drop(i)
	sightings.forget(target_id)


## Write down everything that has arrived on the net since the last look.
##
## A squad-scope delivery is knowledge one squad has and the faction does not, so
## it lands owned. A faction-scope delivery is the relay catching up, and it
## clears the owner: from then on anybody may act on it.
func _absorb_hearsay() -> void:
	_hearsay_cursor = maxi(_hearsay_cursor, net.oldest())
	while _hearsay_cursor < net.head():
		var seq: int = _hearsay_cursor
		_hearsay_cursor += 1
		if net.kind_at(seq) != AIComms.CONTACT:
			continue
		var target_id: int = net.target_at(seq)
		if target_id < 0:
			continue
		var faction_wide: bool = net.scope_at(seq) == AIComms.SCOPE_FACTION
		var i: int = slot_of(target_id)
		if i < 0:
			i = _slot(target_id)
			_owner[i] = &"" if faction_wide else net.squad_at(seq)
		elif faction_wide:
			_owner[i] = &""
		var conf: float = net.confidence_at(seq)
		if conf >= _confidence[i] - 0.05 or _now - _reported_at[i] > 1.5:
			_pos[i] = net.position_at(seq)
			_vel[i] = Vector3.ZERO
			_confidence[i] = maxf(conf, _confidence[i] * 0.5)
			_reported_at[i] = _now
		_threat[i] = maxf(_threat[i], 1.0)


## Hand the board to the command layer and take a set of orders back.
func _run_command(delta: float) -> void:
	command.begin(delta, faction, strength, doctrine)
	for i: int in roster.count():
		command.observe_squad(
			roster.id_at(i),
			roster.strength_at(i),
			roster.objective_at(i),
			roster.centroid_at(i),
			roster.distress_at(i)
		)
	for i: int in support.count():
		command.observe_support(support.id_at(i), support.position_at(i), support.severity_at(i))
	command.resolve()


func _slot(target_id: int) -> int:
	var i: int = slot_of(target_id)
	if i >= 0:
		return i
	if _used < MAX_CONTACTS:
		i = _used
		_used += 1
	else:
		i = 0
		var worst: float = INF
		for k: int in _used:
			if _confidence[k] < worst:
				worst = _confidence[k]
				i = k
	_id[i] = target_id
	_confidence[i] = 0.0
	_threat[i] = 1.0
	_engaged[i] = 0
	_reported_at[i] = _now
	_vel[i] = Vector3.ZERO
	_owner[i] = &""
	return i


func _drop(i: int) -> void:
	var last: int = _used - 1
	if i != last:
		_id[i] = _id[last]
		_pos[i] = _pos[last]
		_vel[i] = _vel[last]
		_confidence[i] = _confidence[last]
		_threat[i] = _threat[last]
		_reported_at[i] = _reported_at[last]
		_engaged[i] = _engaged[last]
		_owner[i] = _owner[last]
	_id[last] = -1
	_engaged[last] = 0
	_owner[last] = &""
	_used = last


## Sightings nobody has said out loud yet.
##
## An agent that sees something the faction is not already tracking files it here
## and walks on. On its next tick each squad looks through the pile for anything
## one of ITS members could plausibly be the one looking at — a body with line of
## sight, close enough to see that far — claims it, and calls it out. Whoever
## claims it is who says it, and who says it decides who hears it first.
##
## Sightings nobody claims are not lost. They time out into a faction-wide call
## from nobody in particular, which is what a body with no squad — an arena
## straggler, a lone sentry — amounts to.
class Sightings:
	extends RefCounted

	## Seconds an unclaimed sighting waits for a squad to own it before it goes out
	## as an anonymous report.
	const ORPHAN_DELAY: float = 1.4
	## Seconds a sighting stays on the pile at all.
	const LIFETIME: float = 4.0
	## Sightings waiting to be called out. Small on purpose: a faction with twelve
	## unreported contacts is not short of table space, it is short of survivors.
	const CAPACITY: int = 12

	var _target: PackedInt32Array = PackedInt32Array()
	var _pos: PackedVector3Array = PackedVector3Array()
	var _vel: PackedVector3Array = PackedVector3Array()
	var _conf: PackedFloat32Array = PackedFloat32Array()
	var _threat: PackedFloat32Array = PackedFloat32Array()
	var _at: PackedFloat32Array = PackedFloat32Array()
	var _used: int = 0

	## Note something seen. Re-filing the same target keeps the better report, so a
	## body that has been staring at a contact for a second calls a good position
	## rather than the first glimpse of it.
	func file(
		target_id: int, p: Vector3, v: Vector3, confidence: float, threat: float, now: float
	) -> void:
		for i: int in _used:
			if _target[i] != target_id:
				continue
			if confidence >= _conf[i]:
				_pos[i] = p
				_vel[i] = v
				_conf[i] = confidence
			_threat[i] = maxf(_threat[i], threat)
			return
		if _used >= CAPACITY:
			return
		if _used >= _target.size():
			_target.append(0)
			_pos.append(Vector3.ZERO)
			_vel.append(Vector3.ZERO)
			_conf.append(0.0)
			_threat.append(0.0)
			_at.append(0.0)
		_target[_used] = target_id
		_pos[_used] = p
		_vel[_used] = v
		_conf[_used] = confidence
		_threat[_used] = threat
		_at[_used] = now
		_used += 1

	func count() -> int:
		return _used

	func target_at(i: int) -> int:
		return _target[i]

	func position_at(i: int) -> Vector3:
		return _pos[i]

	func velocity_at(i: int) -> Vector3:
		return _vel[i]

	func confidence_at(i: int) -> float:
		return _conf[i]

	func threat_at(i: int) -> float:
		return _threat[i]

	## Seconds this sighting has been sitting unreported.
	func age_at(i: int, now: float) -> float:
		return now - _at[i]

	## Whether nobody has claimed it in time and it should go out anonymously.
	func is_orphan(i: int, now: float) -> bool:
		return now - _at[i] >= ORPHAN_DELAY

	## Strike a sighting off, because somebody has now said it out loud.
	func take(i: int) -> void:
		var last: int = _used - 1
		if i != last:
			_target[i] = _target[last]
			_pos[i] = _pos[last]
			_vel[i] = _vel[last]
			_conf[i] = _conf[last]
			_threat[i] = _threat[last]
			_at[i] = _at[last]
		_used = last

	func forget(target_id: int) -> void:
		for i: int in _used:
			if _target[i] == target_id:
				take(i)
				return

	func expire(now: float) -> void:
		var i: int = 0
		while i < _used:
			if now - _at[i] > LIFETIME:
				take(i)
				continue
			i += 1

	func clear() -> void:
		_used = 0


## Squads that have shouted for help and are still waiting for it.
##
## A request is a standing thing rather than an event: it stays up until the squad
## stops needing it or it times out, so the command layer sees the same call on
## several consecutive ticks and can hand it to whoever is nearest without having
## to have been listening at the exact moment it was made.
class Support:
	extends RefCounted

	const MAX_OPEN: int = 8

	var _sid: Array[StringName] = []
	var _at: PackedVector3Array = PackedVector3Array()
	var _severity: PackedFloat32Array = PackedFloat32Array()
	var _until: PackedFloat32Array = PackedFloat32Array()

	## Raise or refresh a squad's call for help. One open request per squad — a
	## squad in trouble twice over is still one squad in trouble.
	func raise_call(
		squad_id: StringName, position: Vector3, severity: float, now: float, ttl: float
	) -> void:
		var i: int = _sid.find(squad_id)
		if i < 0:
			if _sid.size() >= MAX_OPEN:
				return
			_sid.append(squad_id)
			_at.append(position)
			_severity.append(severity)
			_until.append(now + ttl)
			return
		_at[i] = position
		_severity[i] = maxf(_severity[i], severity)
		_until[i] = now + ttl

	func stand_down(squad_id: StringName) -> void:
		var i: int = _sid.find(squad_id)
		if i >= 0:
			_remove(i)

	func expire(now: float) -> void:
		var i: int = 0
		while i < _sid.size():
			if now >= _until[i]:
				_remove(i)
				continue
			i += 1

	func count() -> int:
		return _sid.size()

	func id_at(i: int) -> StringName:
		return _sid[i]

	func position_at(i: int) -> Vector3:
		return _at[i]

	func severity_at(i: int) -> float:
		return _severity[i]

	func is_open(squad_id: StringName) -> bool:
		return _sid.has(squad_id)

	func clear() -> void:
		_sid.clear()
		_at.clear()
		_severity.clear()
		_until.clear()

	func _remove(i: int) -> void:
		var last: int = _sid.size() - 1
		if i != last:
			_sid[i] = _sid[last]
			_at[i] = _at[last]
			_severity[i] = _severity[last]
			_until[i] = _until[last]
		_sid.resize(last)
		_at.resize(last)
		_severity.resize(last)
		_until.resize(last)


## Which squads this faction has in the field, where they are, and what they are
## doing about it. Deliberately data and not objects: a squad publishes a row and
## the director reads rows, so nothing here can keep a dead squad alive.
class Roster:
	extends RefCounted

	var _ids: Array[StringName] = []
	var _strength: PackedInt32Array = PackedInt32Array()
	var _objective: Array[StringName] = []
	var _centroid: PackedVector3Array = PackedVector3Array()
	var _state: PackedInt32Array = PackedInt32Array()
	var _distress: PackedFloat32Array = PackedFloat32Array()

	## Write a squad's row, inserting it on first sight. One call per squad per
	## slow tick. `distress` is how close to useless the squad reckons it is, which
	## only the squad can know and which command sorts by.
	func publish(
		squad_id: StringName,
		strength: int,
		objective: StringName,
		centroid: Vector3,
		state: int,
		distress: float = 0.0
	) -> void:
		var i: int = _ids.find(squad_id)
		if i < 0:
			i = _ids.size()
			_ids.append(squad_id)
			_strength.append(0)
			_objective.append(&"")
			_centroid.append(Vector3.ZERO)
			_state.append(0)
			_distress.append(0.0)
		_strength[i] = strength
		_objective[i] = objective
		_centroid[i] = centroid
		_state[i] = state
		_distress[i] = distress

	func drop(squad_id: StringName) -> void:
		var i: int = _ids.find(squad_id)
		if i < 0:
			return
		var last: int = _ids.size() - 1
		if i != last:
			_ids[i] = _ids[last]
			_strength[i] = _strength[last]
			_objective[i] = _objective[last]
			_centroid[i] = _centroid[last]
			_state[i] = _state[last]
			_distress[i] = _distress[last]
		_ids.resize(last)
		_strength.resize(last)
		_objective.resize(last)
		_centroid.resize(last)
		_state.resize(last)
		_distress.resize(last)

	func clear() -> void:
		_ids.clear()
		_strength.clear()
		_objective.clear()
		_centroid.clear()
		_state.clear()
		_distress.clear()

	func count() -> int:
		return _ids.size()

	func id_at(i: int) -> StringName:
		return _ids[i]

	func strength_at(i: int) -> int:
		return _strength[i]

	func objective_at(i: int) -> StringName:
		return _objective[i]

	func centroid_at(i: int) -> Vector3:
		return _centroid[i]

	func state_at(i: int) -> int:
		return _state[i]

	func distress_at(i: int) -> float:
		return _distress[i]

	func total_strength() -> int:
		var n: int = 0
		for s: int in _strength:
			n += s
		return n

	## How many bodies this faction already has committed to a zone. The director
	## reads this before it sends another squad somewhere that is already covered.
	func committed_to(zone_id: StringName) -> int:
		var n: int = 0
		for i: int in _ids.size():
			if _objective[i] == zone_id:
				n += _strength[i]
		return n

	## Index of the squad closest to a point, or -1 when the faction has none in
	## the field. Used to answer "who is nearest the alarm".
	func nearest_to(p: Vector3) -> int:
		var best: int = -1
		var best_d: float = INF
		for i: int in _ids.size():
			var d: float = _centroid[i].distance_squared_to(p)
			if d < best_d:
				best_d = d
				best = i
		return best


## One faction's accumulated pressure on the zones it is standing in, between
## flushes. Squads add into it every tick; the director flushes it into the
## global ledger on its own slower clock, which turns a hundred tiny writes into
## one per zone and lets the director scale the whole faction's push at once.
class ZoneInterest:
	extends RefCounted

	var _ids: Array[StringName] = []
	var _value: PackedFloat32Array = PackedFloat32Array()

	func add(zone_id: StringName, amount: float) -> void:
		if zone_id == &"" or amount <= 0.0:
			return
		var i: int = _ids.find(zone_id)
		if i < 0:
			_ids.append(zone_id)
			_value.append(amount)
			return
		_value[i] += amount

	func count() -> int:
		return _ids.size()

	func id_at(i: int) -> StringName:
		return _ids[i]

	func value_at(i: int) -> float:
		return _value[i]

	func clear() -> void:
		_ids.clear()
		_value.clear()

	## Push everything accumulated into the global ledger on `faction`'s behalf
	## and start again from zero. `scale` is the director's thumb on the scale.
	func flush(faction: int, scale: float = 1.0) -> void:
		for i: int in _ids.size():
			Factions.territory.add_pressure(_ids[i], faction, _value[i] * scale)
		clear()
