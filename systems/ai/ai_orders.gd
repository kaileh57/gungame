class_name AIOrders
extends RefCounted
## Faction command. Turns the territory ledger and the squads' own reports into a
## verb for each squad: hold, probe, assault, reinforce, withdraw.
##
## The ledger already models the war — who owns what, how hard everyone is leaning
## on it, who is over-extended. What it did not do was TELL ANYBODY. Squads read
## pressure only as a tiebreak inside their own objective score, so three factions
## produced a brawl in which every squad independently walked at the nearest fight
## and nothing on screen read as intent. This is the missing layer: one place per
## faction that looks at the whole board once per command tick and hands out jobs.
##
## It is deliberately a VERB and not only a place. A squad told to HOLD digs into
## the threatened face of its zone and stops chasing; a squad told to PROBE moves
## with its scouts out and commits to nothing; a squad told to REINFORCE abandons
## what it was doing and runs at a squadmate's support call; a squad told to
## WITHDRAW breaks contact. Those read differently from a spectator's seat even
## when the destination happens to be the same, which is the whole point.
##
## WHAT IT DOES NOT DO. It does not replace a director's own objective scoring for
## the two intents that mean "go and fight somewhere" — `PROBE` and `ASSAULT` set
## posture and leave the ground to whoever is already choosing it, because a
## director knows things this does not, such as which capitals are unwinnable by
## construction. The three intents that mean "stop what you are doing" — `HOLD`,
## `REINFORCE`, `WITHDRAW` — name their own ground and override, because the whole
## point of them is that they interrupt.
##
## IT KNOWS NOTHING ABOUT SQUADS. A squad is reported to it as five plain values,
## one of which is a distress fraction the squad works out for itself. That is not
## fastidiousness: `AISquad` reads its orders back out of here, and if this file
## named `AISquad` in return the two would be mutually recursive and neither would
## parse.
##
## USAGE. Report, then resolve, then read:
##
##     command.begin(delta, faction, strength, doctrine)
##     command.observe_squad(id, size, objective, centroid, distress)   # per squad
##     command.observe_support(id, position, severity)                  # per call
##     command.resolve()
##     var row := command.order_for(squad_id)
##
## `AIBlackboard.decay` already does all of that; nothing else has to.
##
## COST. O(zones × squads) with no allocation after the first resize, on the
## faction's slow tick. Seven zones and three squads is twenty-one comparisons
## four times a second.

## A squad was given a new verb. `point` is where it applies, which for `PROBE`
## and `ASSAULT` is the zone centre and for the rest is specific ground.
signal order_issued(squad_id: StringName, intent: int, zone_id: StringName, point: Vector3)

enum Intent { HOLD, PROBE, ASSAULT, REINFORCE, WITHDRAW }

const INTENT_NAMES: PackedStringArray = ["HOLD", "PROBE", "ASSAULT", "REINFORCE", "WITHDRAW"]

## How interrupting each verb is. A more urgent order may replace a less urgent
## one before its dwell time is up; the reverse has to wait.
const INTENT_URGENCY: PackedFloat32Array = [0.55, 0.20, 0.35, 0.80, 1.00]

## Intents that name their own ground and take a squad off whatever it was doing.
## The other two set posture and leave the destination alone.
const INTENT_OVERRIDES: PackedInt32Array = [1, 0, 0, 1, 1]

## Distress at or above which a squad counts as broken rather than merely hurt.
const BROKEN_DISTRESS: float = 0.85

## Squads one faction may be commanding. Past this the board is not a war.
const MAX_SQUADS: int = 12
## Outstanding support calls tracked at once.
const MAX_SUPPORT: int = 8

const FALLBACK_DWELL: float = 6.0
const FALLBACK_WITHDRAW: float = 0.34
const FALLBACK_ASSAULT: float = 0.62
const FALLBACK_HOLD: float = 0.65
const FALLBACK_SUPPORT_RADIUS: float = 70.0
const FALLBACK_HOLD_SQUADS: int = 1
const FALLBACK_REINFORCE_SQUADS: int = 1
const FALLBACK_STANDOFF: float = 0.62
const FALLBACK_SWEEP_MEMORY: float = 26.0
const FALLBACK_SWEEP_DISCOUNT: float = 0.35
const FALLBACK_PEAK_BLEED: float = 0.010

## Which faction this commands.
var faction: int = 0

var _sid: Array[StringName] = []
var _intent: PackedInt32Array = PackedInt32Array()
var _zone: Array[StringName] = []
var _point: PackedVector3Array = PackedVector3Array()
var _priority: PackedFloat32Array = PackedFloat32Array()
var _held_for: PackedFloat32Array = PackedFloat32Array()

var _obs_id: Array[StringName] = []
var _obs_size: PackedInt32Array = PackedInt32Array()
var _obs_zone: Array[StringName] = []
var _obs_at: PackedVector3Array = PackedVector3Array()
var _obs_distress: PackedFloat32Array = PackedFloat32Array()
var _obs_used: int = 0

var _sup_id: Array[StringName] = []
var _sup_at: PackedVector3Array = PackedVector3Array()
var _sup_severity: PackedFloat32Array = PackedFloat32Array()
var _sup_used: int = 0

var _swept_id: Array[StringName] = []
var _swept_at: PackedFloat32Array = PackedFloat32Array()

var _zscore: PackedFloat32Array = PackedFloat32Array()
var _zthreat: PackedFloat32Array = PackedFloat32Array()
var _zclaimed: PackedInt32Array = PackedInt32Array()

var _doctrine: AIRoles = null
var _strength: int = 0
var _peak_strength: float = 1.0
var _delta: float = 0.0
var _now: float = 0.0
## Squads already committed to standing still, and to turning round, this resolve.
## Seeded from the standing orders so an incumbent counts against its own cap.
var _held: int = 0
var _reinforcing: int = 0


func _init(orders_faction: int = 0) -> void:
	faction = orders_faction


## Open a command tick. Clears last tick's observations; the caller then reports
## its squads and its outstanding support calls and finishes with `resolve`.
func begin(delta: float, command_faction: int, strength: int, doctrine: AIRoles) -> void:
	faction = command_faction
	_doctrine = doctrine
	_delta = delta
	_now += delta
	_strength = strength
	_obs_used = 0
	_sup_used = 0
	# Peak strength bleeds, so a faction that was once large and has been ground
	# down stops reading as catastrophically hurt forever and starts reading as
	# simply smaller. Without the bleed, one bad opening leaves a faction timid for
	# the rest of the run and it never attacks anything again.
	var bleed: float = FALLBACK_PEAK_BLEED if _doctrine == null else _doctrine.peak_bleed
	_peak_strength = maxf(float(strength), _peak_strength - _peak_strength * bleed * delta)
	_peak_strength = maxf(_peak_strength, 1.0)


## One squad's situation. `distress` is `[0, 1]` — how close it is to useless,
## worked out by the squad itself and reported like everything else.
func observe_squad(
	squad_id: StringName, size: int, objective: StringName, centroid: Vector3, distress: float
) -> void:
	if _obs_used >= MAX_SQUADS or squad_id == &"":
		return
	if _obs_used >= _obs_id.size():
		_obs_id.append(&"")
		_obs_size.append(0)
		_obs_zone.append(&"")
		_obs_at.append(Vector3.ZERO)
		_obs_distress.append(0.0)
	_obs_id[_obs_used] = squad_id
	_obs_size[_obs_used] = size
	_obs_zone[_obs_used] = objective
	_obs_at[_obs_used] = centroid
	_obs_distress[_obs_used] = clampf(distress, 0.0, 1.0)
	_obs_used += 1


## Somebody asked for help. `severity` in `[0, 1]` — how badly.
func observe_support(squad_id: StringName, position: Vector3, severity: float) -> void:
	if _sup_used >= MAX_SUPPORT:
		return
	if _sup_used >= _sup_id.size():
		_sup_id.append(&"")
		_sup_at.append(Vector3.ZERO)
		_sup_severity.append(0.0)
	_sup_id[_sup_used] = squad_id
	_sup_at[_sup_used] = position
	_sup_severity[_sup_used] = clampf(severity, 0.0, 1.0)
	_sup_used += 1


## Work out what everybody should be doing and publish it.
func resolve() -> void:
	_score_zones()
	_held = 0
	_reinforcing = 0
	for i: int in _obs_used:
		var row: int = _row_for(_obs_id[i])
		_held_for[row] += _delta
		if _intent[row] == Intent.HOLD:
			_held += 1
		elif _intent[row] == Intent.REINFORCE:
			_reinforcing += 1
	# Worst off first, so the squad best placed to save a zone is claimed for it
	# before somebody else is sent to probe with it.
	var order: PackedInt32Array = _by_need()
	for n: int in order.size():
		_assign(order[n])


## Row of a squad's order, or -1 when it has never been given one.
func order_for(squad_id: StringName) -> int:
	return _sid.find(squad_id)


func intent_at(row: int) -> int:
	return Intent.PROBE if row < 0 or row >= _intent.size() else _intent[row]


func zone_at(row: int) -> StringName:
	return &"" if row < 0 or row >= _zone.size() else _zone[row]


func point_at(row: int) -> Vector3:
	return Vector3.ZERO if row < 0 or row >= _point.size() else _point[row]


## How hard this order is being pressed, in `[0, 1]`. A squad weighs it against
## what it can actually see.
func priority_at(row: int) -> float:
	return 0.0 if row < 0 or row >= _priority.size() else _priority[row]


## Whether this order takes the squad off whatever ground it was already on.
func overrides_at(row: int) -> bool:
	return INTENT_OVERRIDES[intent_at(row)] != 0


func count() -> int:
	return _sid.size()


func id_at(row: int) -> StringName:
	return _sid[row]


## A squad reports it swept a zone and found nothing. Holds the zone's probe score
## down for a while, so the faction spreads out instead of walking the same empty
## ground three times.
func note_area_clear(zone_id: StringName) -> void:
	if zone_id == &"":
		return
	var i: int = _swept_id.find(zone_id)
	if i < 0:
		_swept_id.append(zone_id)
		_swept_at.append(_now)
		return
	_swept_at[i] = _now


## How much of its peak this faction is still standing, in `[0, 1]`. Below the
## doctrine's withdraw threshold it stops attacking and consolidates.
func manpower() -> float:
	# Nobody having reported a strength is not the same as having no bodies. A
	# director that does not keep `AIBlackboard.strength` up to date would otherwise
	# read as annihilated and every squad it owns would be ordered to withdraw.
	if _strength <= 0:
		return 1.0
	return clampf(float(_strength) / _peak_strength, 0.0, 1.0)


func clear() -> void:
	_sid.clear()
	_intent.clear()
	_zone.clear()
	_point.clear()
	_priority.clear()
	_held_for.clear()
	_swept_id.clear()
	_swept_at.clear()
	_obs_used = 0
	_sup_used = 0
	_peak_strength = 1.0
	_now = 0.0


## Value every zone once, so the per-squad pass is a scan of a float array.
##
## `_zscore` is what the ground is worth to this faction as somewhere to GO;
## `_zthreat` is how close the faction is to losing it, and is zero for anything
## it does not own. A zone it owns and is about to lose scores nothing as a
## destination and everything as a threat, which is exactly the split that lets
## HOLD and PROBE be decided in one pass over one array.
##
## THIS FUNCTION WAS THE PRIME SUSPECT FOR THE FIREFIGHT LOCKING AND IT WAS NOT
## THE CAUSE — recorded because the next person to read a frozen map will suspect
## it again. Both halves of it read the ledger's pressure, and the ledger used to
## pin every holder at the 1.0 clamp: an enemy zone therefore always scored its
## floor, `aggro * value * 0.55`, and an owned one always read as unthreatened
## because `mine` was already at the top. The scoring was answering the questions
## correctly about a board where every number was saturated. `Factions.Territory`
## now caps a holder at its garrison ceiling, so `1.0 - pressure_at(i, own)` is
## about 0.65 on held ground instead of 0.0 and an enemy zone scores roughly twice
## what it did, with no change here at all. Measured after that one fix and with
## nothing in this file touched: uncapturable zone-samples 90% -> 0%.
func _score_zones() -> void:
	var ledger: Factions.Territory = Factions.territory
	var n: int = ledger.count()
	if _zscore.size() != n:
		_zscore.resize(n)
		_zthreat.resize(n)
		_zclaimed.resize(n)
	var aggro: float = Factions.aggression(faction)
	var margin: float = maxf(Factions.capture_margin, 0.01)
	for i: int in n:
		_zclaimed[i] = 0
		var id: StringName = ledger.id_at(i)
		var own: int = ledger.owner_at(i)
		var mine: float = ledger.pressure_at(i, faction)
		var rival: float = 0.0
		for f: int in Factions.COUNT:
			if f != faction:
				rival = maxf(rival, ledger.pressure_at(i, f))
		var value: float = float(ledger.shape(id)[3])
		if own == faction:
			# How far from being taken off us, in units of the capture margin — but
			# only while somebody is actually taking it.
			#
			# THE `rival` GUARD IS LOAD-BEARING. Without it an owned zone that this
			# faction is simply not standing on reads as maximally threatened, because
			# `mine` is zero and the margin alone clears the trigger. Measured over a
			# fifteen-minute headless war with the guard missing: every faction pinned
			# a squad on every empty holding it had, nobody probed anything, the map
			# stopped changing hands at t=420 s and finished the run 5/3/1 with zero
			# contested zones. A zone nobody is pushing on is not in danger.
			if rival <= Factions.contest_threshold:
				_zthreat[i] = 0.0
			else:
				_zthreat[i] = clampf((rival - mine + margin) / margin, 0.0, 2.0) * value
			_zscore[i] = 0.08 * value
		elif own < 0:
			_zthreat[i] = 0.0
			_zscore[i] = aggro * value * 1.20
		else:
			_zthreat[i] = 0.0
			_zscore[i] = aggro * value * (0.55 + 1.00 * (1.0 - ledger.pressure_at(i, own)))
		_zscore[i] *= 1.0 + 0.8 * mine
		_zscore[i] *= _sweep_scale(id)


## Ground swept and found empty is worth less for a while. Decays back linearly,
## so a zone the faction cleared half a minute ago is a normal target again.
func _sweep_scale(zone_id: StringName) -> float:
	var i: int = _swept_id.find(zone_id)
	if i < 0:
		return 1.0
	var memory: float = FALLBACK_SWEEP_MEMORY if _doctrine == null else _doctrine.sweep_memory
	var age: float = _now - _swept_at[i]
	if age >= memory:
		_swept_id.remove_at(i)
		_swept_at.remove_at(i)
		return 1.0
	var floor_value: float = (
		FALLBACK_SWEEP_DISCOUNT if _doctrine == null else _doctrine.sweep_discount
	)
	return lerpf(floor_value, 1.0, age / maxf(memory, 0.01))


## Squad indices, worst off first. A broken squad is dealt with before a healthy
## one, because the healthy one's job may be to go and get it.
func _by_need() -> PackedInt32Array:
	var out: PackedInt32Array = PackedInt32Array()
	out.resize(_obs_used)
	for i: int in _obs_used:
		out[i] = i
	for i: int in range(1, _obs_used):
		var k: int = out[i]
		var v: float = _obs_distress[k]
		var j: int = i - 1
		while j >= 0 and _obs_distress[out[j]] < v:
			out[j + 1] = out[j]
			j -= 1
		out[j + 1] = k
	return out


## The one decision. Every branch below is a verb a spectator can name.
func _assign(i: int) -> void:
	var here: Vector3 = _obs_at[i]
	var row: int = _row_for(_obs_id[i])
	if _obs_size[i] <= 0:
		_issue(row, Intent.PROBE, _obs_zone[i], here, 0.0)
		return
	if _try_withdraw(i, row, here):
		return
	if _try_reinforce(i, row, here):
		return
	if _try_hold(row, here):
		return
	_press(i, row, here)


## Break contact. A broken squad, or one that has lost enough of the faction with
## it that there is nothing left to attack with.
func _try_withdraw(i: int, row: int, here: Vector3) -> bool:
	var floor_manpower: float = (
		FALLBACK_WITHDRAW if _doctrine == null else _doctrine.withdraw_manpower
	)
	var broken: bool = _obs_distress[i] >= BROKEN_DISTRESS
	if not broken and manpower() > floor_manpower:
		return false
	var best: int = _nearest_owned(here)
	if best < 0:
		return false
	var urgency: float = 1.0
	if not broken:
		urgency = 1.0 - manpower() / maxf(floor_manpower, 0.01)
	var ledger: Factions.Territory = Factions.territory
	_issue(
		row, Intent.WITHDRAW, ledger.id_at(best), ledger.center_at(best), clampf(urgency, 0.4, 1.0)
	)
	return true


## Run at a squadmate's support call. Taken by the nearest squad that is not the
## one calling, and only inside a radius — a call from the far side of the valley
## is somebody else's problem, and answering it empties the map.
func _try_reinforce(i: int, row: int, here: Vector3) -> bool:
	var cap: int = (
		FALLBACK_REINFORCE_SQUADS if _doctrine == null else _doctrine.reinforce_squads_max
	)
	if _intent[row] != Intent.REINFORCE and _reinforcing >= cap:
		return false
	var radius: float = FALLBACK_SUPPORT_RADIUS if _doctrine == null else _doctrine.support_radius
	var best: int = -1
	var best_d: float = radius * radius
	for s: int in _sup_used:
		if _sup_id[s] == _obs_id[i] or not _nearest_to_call(i, s):
			continue
		var d: float = here.distance_squared_to(_sup_at[s])
		if d < best_d:
			best_d = d
			best = s
	if best < 0:
		return false
	if _intent[row] != Intent.REINFORCE:
		_reinforcing += 1
	var ledger: Factions.Territory = Factions.territory
	_issue(
		row,
		Intent.REINFORCE,
		ledger.zone_at(_sup_at[best]),
		_sup_at[best],
		maxf(_sup_severity[best], 0.3)
	)
	return true


## Whether squad `i` is the closest of everyone reported to support call `s`. The
## whole faction does not turn round for one man.
func _nearest_to_call(i: int, s: int) -> bool:
	var mine: float = _obs_at[i].distance_squared_to(_sup_at[s])
	for k: int in _obs_used:
		if k == i or _obs_id[k] == _sup_id[s] or _obs_size[k] <= 0:
			continue
		if _obs_at[k].distance_squared_to(_sup_at[s]) < mine:
			return false
	return true


## Stand on ground we are about to lose. Claims the zone so a second squad is not
## sent to the same one, and puts the squad on the face the pressure is coming
## from rather than in the middle of the circle.
func _try_hold(row: int, here: Vector3) -> bool:
	var cap: int = FALLBACK_HOLD_SQUADS if _doctrine == null else _doctrine.hold_squads_max
	var incumbent: bool = _intent[row] == Intent.HOLD
	if not incumbent and _held >= cap:
		return false
	var trigger: float = FALLBACK_HOLD if _doctrine == null else _doctrine.hold_threat
	var ledger: Factions.Territory = Factions.territory
	var best: int = -1
	var best_s: float = trigger
	for z: int in _zthreat.size():
		if _zclaimed[z] != 0 or _zthreat[z] < trigger:
			continue
		var s: float = _zthreat[z] / (1.0 + here.distance_to(ledger.center_at(z)) * 0.02)
		if s > best_s:
			best_s = s
			best = z
	if best < 0:
		return false
	_zclaimed[best] = 1
	if not incumbent:
		_held += 1
	_issue(
		row,
		Intent.HOLD,
		ledger.id_at(best),
		_garrison_point(best),
		clampf(_zthreat[best] * 0.5, 0.3, 1.0)
	)
	return true


## Attack, or feel the way forward. The difference is whether the faction can
## afford to lose the bodies: above the doctrine's threshold it presses, below it
## probes and keeps its scouts out.
func _press(i: int, row: int, here: Vector3) -> void:
	var ledger: Factions.Territory = Factions.territory
	var best: int = -1
	var best_s: float = -INF
	for z: int in _zscore.size():
		if _zclaimed[z] != 0:
			continue
		var s: float = _zscore[z] / (1.0 + here.distance_to(ledger.center_at(z)) * 0.014)
		if s > best_s:
			best_s = s
			best = z
	if best < 0:
		_issue(row, Intent.PROBE, _obs_zone[i], here, 0.0)
		return
	_zclaimed[best] = 1
	var floor_manpower: float = (
		FALLBACK_ASSAULT if _doctrine == null else _doctrine.assault_manpower
	)
	var verb: int = Intent.ASSAULT if manpower() >= floor_manpower else Intent.PROBE
	_issue(row, verb, ledger.id_at(best), ledger.center_at(best), clampf(best_s, 0.1, 1.0))


## The defensible face of a zone: out from its centre toward whoever is pushing
## hardest on it. Standing in the middle of a circle is how a garrison gets shot
## from three sides at once.
func _garrison_point(z: int) -> Vector3:
	var ledger: Factions.Territory = Factions.territory
	var centre: Vector3 = ledger.center_at(z)
	var rival: int = -1
	var rival_p: float = 0.0
	for f: int in Factions.COUNT:
		if f != faction and ledger.pressure_at(z, f) > rival_p:
			rival_p = ledger.pressure_at(z, f)
			rival = f
	if rival < 0:
		return centre
	var toward: Vector3 = Vector3.ZERO
	for i: int in ledger.count():
		if i == z or ledger.owner_at(i) != rival:
			continue
		var d: Vector3 = ledger.center_at(i) - centre
		d.y = 0.0
		if d.length_squared() < 1.0:
			continue
		toward += d.normalized() / d.length()
	if toward.length_squared() < 1e-6:
		return centre
	var radius: float = float(ledger.shape(ledger.id_at(z))[1])
	var standoff: float = FALLBACK_STANDOFF if _doctrine == null else _doctrine.garrison_standoff
	return centre + toward.normalized() * radius * standoff


func _nearest_owned(from: Vector3) -> int:
	var ledger: Factions.Territory = Factions.territory
	var best: int = -1
	var best_d: float = INF
	for i: int in ledger.count():
		if ledger.owner_at(i) != faction:
			continue
		var d: float = from.distance_squared_to(ledger.center_at(i))
		if d < best_d:
			best_d = d
			best = i
	return best


## Write an order, unless the standing one is more urgent and has not sat long
## enough. This is the anti-thrash rule, and it is the same rule a director's
## retarget period is: without it a squad on the boundary between two verbs flips
## between them every command tick and walks nowhere. A kept order keeps its
## ground too — a squad holding a zone does not stop holding it because somewhere
## else briefly scored higher — only its priority moves.
func _issue(row: int, intent: int, zone_id: StringName, point: Vector3, priority: float) -> void:
	var dwell: float = FALLBACK_DWELL if _doctrine == null else _doctrine.order_dwell
	if _intent[row] != intent:
		var standing: float = INTENT_URGENCY[_intent[row]]
		if INTENT_URGENCY[intent] <= standing and _held_for[row] < dwell:
			_priority[row] = priority
			return
		_intent[row] = intent
		_held_for[row] = 0.0
		order_issued.emit(_sid[row], intent, zone_id, point)
	_zone[row] = zone_id
	_point[row] = point
	_priority[row] = priority


func _row_for(squad_id: StringName) -> int:
	var i: int = _sid.find(squad_id)
	if i >= 0:
		return i
	_sid.append(squad_id)
	_intent.append(Intent.PROBE)
	_zone.append(&"")
	_point.append(Vector3.ZERO)
	_priority.append(0.0)
	_held_for.append(0.0)
	return _sid.size() - 1


## Who is crossing, who is watching them, and whether that pairing has ever
## silently lapsed. A separate object so the pairing can be ASSERTED rather than
## assumed: a harness reads `mover_at`/`coverer_at` and checks for itself that the
## named coverer is a live squadmate with eyes on, and `breaches` counts the times
## a coverer stopped qualifying while somebody was still out in the open.
class Overwatch:
	extends RefCounted

	## Bodies that may be crossing at once, whatever doctrine asks for. Two is what
	## a squad that intends to arrive actually does; four is a charge.
	const MAX_MOVERS: int = 4

	var _mover: PackedInt32Array = PackedInt32Array()
	var _coverer: PackedInt32Array = PackedInt32Array()
	var _until: PackedFloat32Array = PackedFloat32Array()
	var _breaches: int = 0

	## Pair a mover with the body watching it. Both are agent ids.
	func issue(mover_id: int, coverer_id: int, until: float) -> void:
		if _mover.size() >= MAX_MOVERS or mover_id == coverer_id:
			return
		_mover.append(mover_id)
		_coverer.append(coverer_id)
		_until.append(until)

	func release(agent_id: int) -> void:
		var i: int = _mover.find(agent_id)
		if i >= 0:
			revoke_at(i)

	func expire(now: float) -> void:
		var i: int = 0
		while i < _mover.size():
			if now >= _until[i]:
				revoke_at(i)
				continue
			i += 1

	func revoke_at(i: int) -> void:
		var last: int = _mover.size() - 1
		if i != last:
			_mover[i] = _mover[last]
			_coverer[i] = _coverer[last]
			_until[i] = _until[last]
		_mover.resize(last)
		_coverer.resize(last)
		_until.resize(last)

	func clear() -> void:
		_mover.clear()
		_coverer.clear()
		_until.clear()

	func count() -> int:
		return _mover.size()

	func mover_at(i: int) -> int:
		return _mover[i]

	func coverer_at(i: int) -> int:
		return _coverer[i]

	func is_covering(agent_id: int) -> bool:
		return _coverer.has(agent_id)

	## Which body is watching `agent_id` across, or -1 when it is not moving. Also
	## the "is this body crossing" test, which is why nothing else needs one.
	func coverer_of(agent_id: int) -> int:
		var i: int = _mover.find(agent_id)
		return -1 if i < 0 else _coverer[i]

	## A pairing lapsed while the mover was still out there. Counted rather than
	## hidden, because the number is the only honest evidence the invariant holds.
	func note_breach() -> void:
		_breaches += 1

	func breaches() -> int:
		return _breaches
