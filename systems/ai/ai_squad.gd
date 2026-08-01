class_name AISquad
extends RefCounted
## Four to eight bodies that have agreed to die in roughly the same place.
##
## The squad holds no node references and never reaches into a body. Agents push
## their state in with `report` and pull four answers back: their job (`role_of`),
## whether they may move (`may_advance`), where the squad is going
## (`objective_point`, `focus_position`, `rally_point`), and what it is trying to do
## (`intent`).
##
## IT TALKS. Every decision another body would need to know about is SAID, on
## `AIComms`, and the words take time to arrive and carry a position that is wrong
## by more the further away the speaker was. The squad is also the ear: a man
## calling "reloading" gets a squadmate told off to cover him; a squad calling for
## support collapses onto whoever called it while command sends the nearest other
## squad; a target called down is dropped and another picked. The callouts are the
## mechanism, not a garnish on one.
##
## IT IS ALSO THE FACTION'S EARS. An agent that sees something new drops it in
## `AIBlackboard.sightings`, not on the board, and each tick the squad claims from
## that pile whatever one of its own members could be the body looking at, and calls
## it out — the agent-facing report API carries no observer id and is frozen, and
## the squad is the only thing here that knows who has eyes on what.
##
## BOUNDING OVERWATCH IS AN INVARIANT, NOT A HABIT. Every moving body's token is
## issued against a NAMED covering body with line of sight, a loaded weapon, its
## head up and a clear lane; the pairing is re-checked every tick and revoked the
## moment it stops holding. `overwatch` exposes it so a harness can assert it.

## Somebody said something out loud. `kind` is one of the `CALL_*` constants —
## `AIComms`' kinds under their old names. Fires at the MOMENT OF SPEAKING, for
## voice lines and overlays; listeners take it off `AIComms.heard`, later and lossier.
signal callout_made(kind: int, position: Vector3, target_id: int)
signal state_changed(previous: int, current: int)
signal role_changed(agent_id: int, role: int)

enum State { FORM_UP, ADVANCE, ASSAULT, HOLD, REGROUP, ROUT }

## "Contact, bearing —." A target the squad had not been tracking.
const CALL_CONTACT: int = AIComms.CONTACT
## "Moving!" The bound token just changed hands.
const CALL_MOVING: int = AIComms.MOVING
## "Man down." A member was removed dead.
const CALL_MAN_DOWN: int = AIComms.MAN_DOWN
## "Pushing." The squad committed to an assault.
const CALL_PUSH: int = AIComms.PUSH
## "Fall back." Losses crossed the regroup threshold.
const CALL_REGROUP: int = AIComms.REGROUP
## "Frag out." Somebody took the faction's one grenade slot.
const CALL_GRENADE: int = AIComms.GRENADE
## "Flanking." A flanker started the long way round.
const CALL_FLANKING: int = AIComms.FLANKING
## "Taking fire!" Rounds are landing on the squad.
const CALL_TAKING_FIRE: int = AIComms.TAKING_FIRE
## "Reloading — cover me."
const CALL_RELOADING: int = AIComms.RELOADING
## "Need support."
const CALL_NEED_SUPPORT: int = AIComms.NEED_SUPPORT
## "Target down."
const CALL_TARGET_DOWN: int = AIComms.TARGET_DOWN
## "Area clear."
const CALL_AREA_CLEAR: int = AIComms.AREA_CLEAR
const CALL_COUNT: int = AIComms.KIND_COUNT

const CALL_NAMES: PackedStringArray = AIComms.KIND_NAMES

## Hard ceiling on members. Past this the role quotas stop meaning anything and
## the squad stops reading as a squad.
const MAX_MEMBERS: int = 8
## Seconds a squad's own support call stays up on the faction board: long enough for
## command to route somebody, short enough that a recovered squad is not still being
## reinforced a minute later.
const SUPPORT_TTL: float = 12.0

var squad_id: StringName = &""
var faction: int = 0
## Never null. A squad built without one gets the defaults: half the squad behaviour
## lives in this resource, and a null check on every read is how a threshold quietly
## stops being tunable.
var doctrine: AIRoles = null
var blackboard: AIBlackboard = null
## Who is crossing, and who is covering them. Public so a harness can assert the
## pairing instead of taking the squad's word for it. It lives on `AIOrders` because
## it is a coordination contract rather than squad bookkeeping, and because this
## file is at its line budget.
var overwatch: AIOrders.Overwatch = AIOrders.Overwatch.new()

var _agent: PackedInt32Array = PackedInt32Array()
var _profile: Array[AISpeciesProfile] = []
var _pos: PackedVector3Array = PackedVector3Array()
var _health: PackedFloat32Array = PackedFloat32Array()
var _ammo: PackedFloat32Array = PackedFloat32Array()
var _supp: PackedFloat32Array = PackedFloat32Array()
var _los: PackedInt32Array = PackedInt32Array()
var _cover: PackedInt32Array = PackedInt32Array()
var _dist: PackedFloat32Array = PackedFloat32Array()
var _role: PackedInt32Array = PackedInt32Array()
var _reloading: PackedInt32Array = PackedInt32Array()
## Clock time this member's cover duty runs out. While it is in the future the
## body holds still and keeps its weapon up whatever else the squad is doing.
var _cover_until: PackedFloat32Array = PackedFloat32Array()
var _last_call: PackedFloat32Array = PackedFloat32Array()

var _state: int = State.FORM_UP
var _clock: float = 0.0
var _reassign_in: float = 0.0
var _centroid: Vector3 = Vector3.ZERO
var _focus_id: int = -1
var _focus_pos: Vector3 = Vector3.ZERO
var _focus_conf: float = 0.0
var _objective: StringName = &""
var _objective_point: Vector3 = Vector3.ZERO
var _rally: Vector3 = Vector3.ZERO
var _peak_size: int = 0
var _losses: int = 0

var _intent: int = AIOrders.Intent.PROBE
var _order_zone: StringName = &""
var _order_point: Vector3 = Vector3.ZERO
var _order_priority: float = 0.0
var _order_overrides: bool = false
## Whether faction command has ever spoken to this squad. A squad nobody commands
## — the arena's, or any director that does not run a command layer — keeps the
## doctrine's own thresholds rather than silently inheriting a posture.
var _commanded: bool = false
var _support_point: Vector3 = Vector3.ZERO
var _support_until: float = -1.0
var _quiet_for: float = 0.0
var _inbox: int = 0
## Per-member "can cover a move right now", recomputed once per tick. The test is
## O(members) on its own because of the lane scan and is asked for every candidate
## coverer of every candidate mover; caching it takes the tick's worst term from
## O(members cubed) to O(members squared).
var _fit: PackedInt32Array = PackedInt32Array()
## Agent ids that called a reload this tick, waiting for a coverer.
var _reload_calls: PackedInt32Array = PackedInt32Array()


func _init(id: StringName, squad_faction: int, roles: AIRoles, board: AIBlackboard) -> void:
	squad_id = id
	faction = squad_faction
	doctrine = roles if roles != null else AIRoles.new()
	blackboard = board
	_last_call.resize(CALL_COUNT)
	for i: int in CALL_COUNT:
		_last_call[i] = -1000.0
	Factions.body_lost.connect(_on_body_lost)


## Enrol a body. Returns its slot, or -1 if the squad is full. The slot is only
## valid until somebody leaves; everything durable keys off `agent_id`.
func add_member(agent_id: int, profile: AISpeciesProfile) -> int:
	if _agent.size() >= MAX_MEMBERS or _slot_of(agent_id) >= 0:
		return -1
	_agent.append(agent_id)
	_profile.append(profile)
	_pos.append(_centroid)
	_health.append(1.0)
	_ammo.append(1.0)
	_supp.append(0.0)
	_los.append(0)
	_cover.append(0)
	_dist.append(0.0)
	_role.append(AIRoles.Role.ANCHOR)
	_reloading.append(0)
	_cover_until.append(-1.0)
	_peak_size = maxi(_peak_size, _agent.size() + _losses)
	_reassign_in = 0.0
	return _agent.size() - 1


## Strike a body off. `killed` distinguishes a casualty, which counts toward the
## squad breaking and is announced to the rest of the world, from a body that
## merely left.
func remove_member(agent_id: int, killed: bool) -> void:
	var i: int = _slot_of(agent_id)
	if i < 0:
		return
	var where: Vector3 = _pos[i]
	var last: int = _agent.size() - 1
	if i != last:
		_agent[i] = _agent[last]
		_profile[i] = _profile[last]
		_pos[i] = _pos[last]
		_health[i] = _health[last]
		_ammo[i] = _ammo[last]
		_supp[i] = _supp[last]
		_los[i] = _los[last]
		_cover[i] = _cover[last]
		_dist[i] = _dist[last]
		_role[i] = _role[last]
		_reloading[i] = _reloading[last]
		_cover_until[i] = _cover_until[last]
	_agent.resize(last)
	_profile.resize(last)
	_pos.resize(last)
	_health.resize(last)
	_ammo.resize(last)
	_supp.resize(last)
	_los.resize(last)
	_cover.resize(last)
	_dist.resize(last)
	_role.resize(last)
	_reloading.resize(last)
	_cover_until.resize(last)
	overwatch.release(agent_id)
	if killed:
		_losses += 1
		if blackboard != null:
			blackboard.note_body_lost(agent_id, where)
		callout(CALL_MAN_DOWN, where, -1)
	_reassign_in = 0.0


## One body's state for this tick. Cheap — a slot lookup and nine writes — and it
## is the only thing an agent has to do to stay in the squad.
func report(
	agent_id: int,
	p: Vector3,
	health_frac: float,
	ammo_frac: float,
	has_los: bool,
	in_cover: bool,
	suppression: float
) -> void:
	var i: int = _slot_of(agent_id)
	if i < 0:
		return
	_pos[i] = p
	_health[i] = health_frac
	_ammo[i] = ammo_frac
	_los[i] = 1 if has_los else 0
	_cover[i] = 1 if in_cover else 0
	_supp[i] = suppression
	_dist[i] = p.distance_to(_focus_pos) if _focus_id >= 0 else INF


## Advance the squad. Run this on the director's slow tick, not per frame — every
## number in here moves on a scale of seconds.
func tick(delta: float) -> void:
	_clock += delta
	_bind_board()
	_update_centroid()
	_listen()
	_claim_sightings()
	_watch_members(delta)
	_update_focus()
	_pull_orders()
	_refresh_fitness()
	_service_cover_calls()
	_reassign_in -= delta
	if _reassign_in <= 0.0:
		_reassign_in = doctrine.reassign_interval
		_reassign()
	_update_state()
	_update_bound()
	_publish(delta)


func size() -> int:
	return _agent.size()


func state() -> int:
	return _state


func centroid() -> Vector3:
	return _centroid


## What is left of the squad, as a fraction of the most bodies it ever had.
func strength_fraction() -> float:
	if _peak_size <= 0:
		return 0.0
	return float(_agent.size()) / float(_peak_size)


func role_of(agent_id: int) -> int:
	var i: int = _slot_of(agent_id)
	return AIRoles.Role.ANCHOR if i < 0 else _role[i]


## What faction command has told this squad to do: an `AIOrders.Intent`. Steady
## through a crossing, so an overlay can label a squad with it.
func intent() -> int:
	return _intent


## Bounding overwatch, from the moving body's point of view. False means stay where
## you are and keep shooting: somebody else is crossing, or you are covering them.
##
## The range gate is not a flourish. Bounding applies only once the squad is in
## contact at fighting distance — march up to it, bound across it. Without it a
## squad that commits to a contact it cannot yet reach hands out no tokens (nobody
## has eyes on to cover with), everybody creeps, and it never closes far enough to
## get the line of sight that would release it.
func may_advance(agent_id: int) -> bool:
	var i: int = _slot_of(agent_id)
	if i < 0:
		return false
	if _clock < _cover_until[i]:
		return false
	if _state != State.ASSAULT:
		return _state != State.HOLD
	if _focus_id < 0 or _dist[i] > doctrine.bound_range:
		return true
	if _role[i] == AIRoles.Role.ANCHOR:
		return false
	return overwatch.coverer_of(agent_id) >= 0


## Hand the bound back early, the moment the mover reaches cover. Without this a
## squad crosses one body per `bound_duration` however short the sprint was.
func report_arrived(agent_id: int) -> void:
	overwatch.release(agent_id)


## Stand the squad back up around whoever is left. A broken squad never recovers
## on its own — losses are measured against the most bodies it ever had, so a
## routed squad stays routed until the director reinforces it and calls this.
func reform(rally: Vector3) -> void:
	_losses = 0
	_peak_size = _agent.size()
	overwatch.clear()
	_rally = rally
	_reassign_in = 0.0
	_support_until = -1.0
	if blackboard != null:
		blackboard.support.stand_down(squad_id)
	var previous: int = _state
	_state = State.FORM_UP
	if previous != _state:
		state_changed.emit(previous, _state)


func set_objective(zone_id: StringName, point: Vector3, rally: Vector3) -> void:
	_objective = zone_id
	_objective_point = point
	_rally = rally


## The ground this squad is working, which is faction command's when command has
## interrupted and the director's otherwise.
func objective() -> StringName:
	return _order_zone if _order_overrides else _objective


## Where the feet go when there is nothing to shoot at. A live support call from
## one of its own beats everything: a squad collapses onto its casualty first,
## takes its orders second, and does what it was already doing last.
func objective_point() -> Vector3:
	if _clock < _support_until:
		return _support_point
	return _order_point if _order_overrides else _objective_point


func rally_point() -> Vector3:
	return _rally


## Where the squad believes the fight is. Falls back to the objective when it has
## no contact, so an agent can steer off this one call in every state.
func focus_position() -> Vector3:
	return _focus_pos if _focus_id >= 0 else objective_point()


func focus_target() -> int:
	return _focus_id


## Say something, at most once per `callout_cooldown` per kind. Returns false when
## it was swallowed, so a caller can tell a suppressed callout from a made one.
func callout(kind: int, p: Vector3, target_id: int) -> bool:
	return _say(kind, -1, p, target_id, _focus_conf if target_id >= 0 else 1.0, false)


## The one place words come out. `speaker_id` is the body talking, or -1 when it is
## the squad as a whole — a listener needs it to know WHO is reloading, and passing
## the squad instead of the man is how "cover me" covers nobody. The local signal
## fires now because it is the ACT of speaking; the net carries the content, and the
## content arrives later and wrong.
func _say(
	kind: int, speaker_id: int, p: Vector3, target_id: int, confidence: float, bypass: bool
) -> bool:
	if kind < 0 or kind >= CALL_COUNT:
		return false
	if not bypass and _clock - _last_call[kind] < doctrine.callout_cooldown:
		return false
	_last_call[kind] = _clock
	if blackboard != null:
		var origin: Vector3 = _centroid
		var i: int = _slot_of(speaker_id)
		if i >= 0:
			origin = _pos[i]
		blackboard.net.speak(kind, speaker_id, squad_id, origin, p, target_id, confidence)
	callout_made.emit(kind, p, target_id)
	return true


## Adopt the faction the first time this squad runs against a blackboard, which is
## built before anybody knows whose it is. Its comms and command both need it.
func _bind_board() -> void:
	if blackboard == null:
		return
	if blackboard.faction != faction:
		blackboard.faction = faction
		blackboard.net.faction = faction
	if blackboard.doctrine == null:
		blackboard.doctrine = doctrine


## Read the net and act on it. The cursor is a sequence number rather than a
## timestamp, so a squad that ticked late sees everything it missed exactly once,
## and one that has fallen further behind than the ring is deep loses the oldest -
## which is the right answer, because it was not listening.
func _listen() -> void:
	if blackboard == null:
		return
	var net: AIComms = blackboard.net
	_inbox = maxi(_inbox, net.oldest())
	while _inbox < net.head():
		var seq: int = _inbox
		_inbox += 1
		if not net.reaches(seq, _centroid, squad_id):
			continue
		_react(seq, net)


## What hearing something makes this squad do. Every branch is a behaviour a
## spectator can see happen a beat after the call.
func _react(seq: int, net: AIComms) -> void:
	var kind: int = net.kind_at(seq)
	match kind:
		AIComms.RELOADING:
			if _reload_calls.size() < MAX_MEMBERS:
				_reload_calls.append(net.speaker_at(seq))
		AIComms.NEED_SUPPORT:
			if net.squad_at(seq) == squad_id:
				_support_point = net.position_at(seq)
				_support_until = _clock + doctrine.support_hold
				_bump_reassign()
		AIComms.TARGET_DOWN:
			if net.target_at(seq) == _focus_id:
				_release_focus()
				_bump_reassign()
		AIComms.MAN_DOWN:
			# Only calls that change WHO is available or WHAT the squad is doing bring
			# the solve forward. "Contact" and "taking fire" arrive several times a
			# second in a real fight and change neither: the focus solve has already
			# moved, and re-solving the roles on each of them cost 40 per cent of the
			# command tick to arrive at the same answer.
			_bump_reassign()


## Bring the role solve forward without letting it run every tick. A squad in a
## firefight hears something worth reacting to several times a second; solving the
## roles on each costs six times what the doctrine asks for and makes the squad
## visibly twitch.
func _bump_reassign() -> void:
	_reassign_in = minf(_reassign_in, doctrine.reassign_interval * 0.4)


## Tell somebody off to cover each man who called a reload. The pick wants eyes on
## the contact, ammunition and its head up, not merely proximity; a body already
## covering somebody else is left alone, because one reload at a time is a squad
## and two is a queue.
func _service_cover_calls() -> void:
	for n: int in _reload_calls.size():
		var subject: int = _slot_of(_reload_calls[n])
		if subject < 0:
			continue
		var best: int = -1
		var best_s: float = -INF
		for k: int in _agent.size():
			if k == subject or _fit[k] == 0 or _clock < _cover_until[k]:
				continue
			var s: float = _ammo[k] - _supp[k] * 1.5
			s -= _pos[k].distance_to(_pos[subject]) * 0.03
			if s > best_s:
				best_s = s
				best = k
		if best >= 0:
			_cover_until[best] = _clock + doctrine.cover_hold
			_bump_reassign()
	_reload_calls.clear()


## Something died. If it was what this squad was shooting at, say so.
func _on_body_lost(lost_faction: int, target_id: int, position: Vector3) -> void:
	if target_id != _focus_id or not Factions.hostile(faction, lost_faction):
		return
	_say(CALL_TARGET_DOWN, -1, position, target_id, 1.0, true)
	_release_focus()
	_bump_reassign()


## Take ownership of sightings this squad is plausibly the one making, and call them.
## A member with line of sight, within its own sight range of the reported point, is
## evidence this squad saw it — the closest thing to an observer id the frozen agent
## API leaves, and not a guess. One claim per tick bounds net traffic by squad count
## rather than by how many enemies came round a corner at once.
func _claim_sightings() -> void:
	if blackboard == null or _agent.is_empty():
		return
	var pile: AIBlackboard.Sightings = blackboard.sightings
	var now: float = blackboard.clock()
	for i: int in pile.count():
		var p: Vector3 = pile.position_at(i)
		var spotter: int = _spotter_for(p)
		if spotter < 0 and not pile.is_orphan(i, now):
			continue
		# `_say` takes the origin off the speaker's own slot, so an anonymous
		# report is called from the squad centroid and a spotted one from the body
		# that is actually looking — and it is that range which sets the error.
		var speaker: int = -1 if spotter < 0 else _agent[spotter]
		_say(CALL_CONTACT, speaker, p, pile.target_at(i), pile.confidence_at(i), true)
		pile.take(i)
		return


## Index of a member that could be the one looking at `p`, or -1.
func _spotter_for(p: Vector3) -> int:
	for k: int in _agent.size():
		if _los[k] == 0 or _profile[k] == null:
			continue
		if _pos[k].distance_to(p) <= _profile[k].sight_range:
			return k
	return -1


## Everything the squad notices about itself and says out loud. Reloading is
## INFERRED: the agent API hands over an ammunition fraction and nothing else, so a
## dry magazine is the edge this watches and `reload_ammo_floor` has to sit above
## whatever a body runs down to between bursts.
func _watch_members(delta: float) -> void:
	if _agent.is_empty():
		return
	var health: float = 0.0
	var floor_ammo: float = doctrine.reload_ammo_floor
	for k: int in _agent.size():
		health += _health[k]
		# Taking fire is measured on the BODY, not the squad. Averaged over seven or
		# eight men it is always near zero — measured in the live firefight, squad
		# mean suppression averages 0.002 and peaks at 0.146, so a squad-mean test
		# never fires at any threshold anyone would call "pinned". One man with
		# rounds landing on him is who shouts, and he shouts from where he is.
		if _supp[k] >= doctrine.taking_fire_level:
			_say(CALL_TAKING_FIRE, _agent[k], _pos[k], _focus_id, _focus_conf, false)
		if _ammo[k] <= floor_ammo:
			if _reloading[k] == 0:
				_reloading[k] = 1
				_say(CALL_RELOADING, _agent[k], _pos[k], _agent[k], 1.0, false)
		elif _ammo[k] > floor_ammo * 1.6:
			_reloading[k] = 0
	_check_support(health / float(_agent.size()))
	_check_area_clear(delta)


## Whether the squad is in enough trouble to ask for help, and the standing request
## that goes with it. Refreshed while the trouble lasts and struck off the moment it
## stops, so command routes one squad to it rather than everybody in turn.
func _check_support(mean_health: float) -> void:
	if blackboard == null:
		return
	# Being hurt only counts while somebody is doing the hurting. A squad merely
	# carrying its wounds is not asking for anything, and treating it as if it were
	# turns a war into a faction of ambulances.
	var hurt: float = 0.0
	if _focus_id >= 0:
		hurt = 1.0 - mean_health / maxf(doctrine.support_health, 0.01)
	var thin: float = 1.0 - strength_fraction() / maxf(1.0 - doctrine.regroup_fraction, 0.05)
	var severity: float = clampf(maxf(hurt, thin), 0.0, 1.0)
	if severity <= 0.0 or _agent.is_empty():
		blackboard.support.stand_down(squad_id)
		return
	blackboard.support.raise_call(squad_id, _centroid, severity, blackboard.clock(), SUPPORT_TTL)
	_say(CALL_NEED_SUPPORT, -1, _centroid, -1, severity, false)


## Ground held, watched and empty gets said so, and faction command drops its
## value for a while. Stops three squads sweeping the same empty zone in turn, and
## is the only callout that changes what the FACTION does rather than the squad.
func _check_area_clear(delta: float) -> void:
	if _focus_id >= 0 or _state != State.HOLD:
		_quiet_for = 0.0
		return
	_quiet_for += delta
	if _quiet_for < doctrine.clear_dwell:
		return
	_quiet_for = 0.0
	var zone: StringName = objective()
	if _say(CALL_AREA_CLEAR, -1, _centroid, -1, 1.0, false) and blackboard != null:
		blackboard.command.note_area_clear(zone)


func _slot_of(agent_id: int) -> int:
	for i: int in _agent.size():
		if _agent[i] == agent_id:
			return i
	return -1


func _update_centroid() -> void:
	var n: int = _agent.size()
	if n == 0:
		return
	var sum: Vector3 = Vector3.ZERO
	for i: int in n:
		sum += _pos[i]
	_centroid = sum / float(n)


## Take the faction's best contact near the squad and adopt it — but only what the
## squad has been TOLD about, and only if it beats what it is already shooting at.
##
## Both halves matter. `best_for` gets this squad's id, so a contact another squad
## called and the relay has not carried is invisible here; and it gets the incumbent
## with a keep bonus, so eight rifles stay on one body until it is down instead of
## spreading eight kills' worth of damage over eight targets that all survive.
func _update_focus() -> void:
	if blackboard == null or _agent.is_empty():
		_release_focus()
		return
	var reach: float = doctrine.engage_range * Factions.aggression(faction)
	var slot: int = blackboard.best_for(
		_centroid, reach, squad_id, _focus_id, doctrine.focus_switch_margin
	)
	if slot < 0:
		_release_focus()
		return
	var id: int = blackboard.contact_id(slot)
	var conf: float = blackboard.contact_confidence(slot)
	if conf < doctrine.push_confidence * 0.5:
		_release_focus()
		return
	if id != _focus_id:
		_release_focus()
		_focus_id = id
		blackboard.mark_engaged(id, true)
		_say(CALL_CONTACT, -1, blackboard.contact_position(slot), id, conf, false)
	_focus_conf = conf
	_focus_pos = blackboard.predicted_position(slot)


## Drop the squad's claim on whatever it was shooting at. Every path out of a
## focus goes through here so the blackboard's engaged counter — which is what
## spreads fire ACROSS squads while the keep bonus concentrates it WITHIN one —
## cannot leak.
func _release_focus() -> void:
	if _focus_id >= 0 and blackboard != null:
		blackboard.mark_engaged(_focus_id, false)
	_focus_id = -1
	_focus_conf = 0.0


## Take this tick's orders off faction command.
func _pull_orders() -> void:
	if blackboard == null:
		return
	var cmd: AIOrders = blackboard.command
	var row: int = cmd.order_for(squad_id)
	if row < 0:
		return
	_commanded = true
	_intent = cmd.intent_at(row)
	_order_priority = cmd.priority_at(row)
	_order_overrides = cmd.overrides_at(row)
	if not _order_overrides:
		return
	_order_zone = cmd.zone_at(row)
	_order_point = cmd.point_at(row)
	if _intent == AIOrders.Intent.WITHDRAW:
		_rally = _order_point


func _reassign() -> void:
	if _agent.is_empty():
		return
	var next: PackedInt32Array = doctrine.assign(
		_profile, _dist, _health, _ammo, _los, _cover, _supp, _role
	)
	for i: int in _agent.size():
		# A body on cover duty is a suppressor for as long as the duty lasts,
		# whatever the solver thinks. That is the entire content of "cover me".
		if _clock < _cover_until[i]:
			next[i] = AIRoles.Role.SUPPRESSOR
		if next[i] == _role[i]:
			continue
		_role[i] = next[i]
		role_changed.emit(_agent[i], next[i])
		if next[i] == AIRoles.Role.FLANKER:
			callout(CALL_FLANKING, _pos[i], _focus_id)


## The squad's own rout threshold: the average of what its bodies will put up
## with, scaled by doctrine. A squad of machines does not break where a squad of
## rats would.
func _rout_threshold() -> float:
	if _profile.is_empty():
		return 1.0
	var sum: float = 0.0
	var n: int = 0
	for p: AISpeciesProfile in _profile:
		if p == null:
			continue
		sum += p.rout_fraction
		n += 1
	if n == 0:
		return 1.0
	return clampf(sum / float(n) * doctrine.rout_scale, 0.05, 1.0)


## Metres of the squad's own spread — the distance of the body furthest from the
## centroid. This is what "scattered" means.
func _spread() -> float:
	var worst: float = 0.0
	for i: int in _agent.size():
		worst = maxf(worst, _pos[i].distance_to(_centroid))
	return worst


func _update_state() -> void:
	var previous: int = _state
	_state = _next_state()
	if _state == previous:
		return
	state_changed.emit(previous, _state)
	if _state == State.REGROUP or _state == State.ROUT:
		callout(CALL_REGROUP, _rally, -1)
		overwatch.clear()
	elif _state == State.ASSAULT:
		callout(CALL_PUSH, _focus_pos, _focus_id)


## How sure of a contact the squad has to be before it commits. Faction command's
## verb moves it: a squad told to probe wants to be much surer than one told to
## assault, which is what makes the same bodies read as cautious or as committed.
func _commit_threshold() -> float:
	var commit: float = doctrine.push_confidence
	if not _commanded:
		return commit
	match _intent:
		AIOrders.Intent.PROBE:
			return commit * 1.45
		AIOrders.Intent.ASSAULT:
			return commit * 0.75
		AIOrders.Intent.HOLD:
			return commit * 1.15
	return commit


func _next_state() -> int:
	var lost: float = 1.0 - strength_fraction()
	if _agent.is_empty() or lost >= _rout_threshold():
		return State.ROUT
	if _commanded and _intent == AIOrders.Intent.WITHDRAW:
		return State.REGROUP
	var cohesion: float = doctrine.cohesion_radius / maxf(Factions.cohesion(faction), 0.1)
	var scattered: bool = _spread() > cohesion
	if lost >= doctrine.regroup_fraction or (_state == State.REGROUP and scattered):
		return State.REGROUP
	if _state == State.FORM_UP and scattered:
		return State.FORM_UP
	if _focus_id >= 0 and _focus_conf >= _commit_threshold():
		return State.ASSAULT
	var zone: StringName = objective()
	var holding: bool = (
		zone != &""
		and Factions.territory.zone_owner(zone) == faction
		and _centroid.distance_to(objective_point()) <= cohesion
	)
	return State.HOLD if holding else State.ADVANCE


## Whether member `k` can actually cover a move right now: eyes on, loaded, head up,
## standing still by role, and with a clear line to the contact.
##
## THAT LAST CLAUSE IS THE "DO NOT SHOOT THROUGH YOUR OWN" RULE AT THE SQUAD LEVEL.
## `AICombat` refuses the trigger pull when a friendly is in the corridor, which
## stops the bullet; but a body whose lane is blocked cannot fire at all, and
## counting it as cover is how a squad sends a man across a street nobody is
## watching. Blocked, it is not cover, so no token is issued off it.
func _is_cover(k: int) -> bool:
	var fit: bool = (
		_los[k] != 0
		and _reloading[k] == 0
		and _supp[k] <= doctrine.coverer_suppression_cap
		and _ammo[k] >= doctrine.coverer_ammo_floor
		and (_role[k] == AIRoles.Role.SUPPRESSOR or _role[k] == AIRoles.Role.ANCHOR)
	)
	if not fit:
		return false
	# The lane scan inlined, with the ray hoisted out of the loop and the distance
	# compared squared. `_in_lane` is the same test for one pair; this is the same
	# test for all of them, and it is the squad tick's hottest term — eight members
	# against eight lanes, four times a second, per squad.
	if _focus_id < 0:
		return true
	var along: Vector3 = _focus_pos - _pos[k]
	var length: float = along.length()
	if length < 0.5:
		return true
	var dir: Vector3 = along / length
	var clear2: float = doctrine.lane_clearance * doctrine.lane_clearance
	for j: int in _agent.size():
		if j == k:
			continue
		var rel: Vector3 = _pos[j] - _pos[k]
		var t: float = rel.dot(dir)
		if t <= 0.5 or t >= length:
			continue
		if (rel - dir * t).length_squared() < clear2:
			return false
	return true


## Whether body `j` is standing inside member `k`'s line to the contact, with
## `slack` multiplying the doctrine's lane clearance. Point-to-segment, exact and
## allocation-free — the same test `AICombat` runs before a trigger pull, applied
## here to who is allowed to move rather than to who is allowed to shoot.
func _in_lane(j: int, k: int, slack: float) -> bool:
	if _focus_id < 0:
		return false
	var along: Vector3 = _focus_pos - _pos[k]
	var length: float = along.length()
	if length < 0.5:
		return false
	var dir: Vector3 = along / length
	var rel: Vector3 = _pos[j] - _pos[k]
	var t: float = rel.dot(dir)
	if t <= 0.5 or t >= length:
		return false
	return (rel - dir * t).length() < doctrine.lane_clearance * slack


## One O(members squared) pass answering "can this body cover a move" for the whole
## squad. Roles are last solve's — a quarter-second stale at worst, and re-checked
## next tick anyway.
func _refresh_fitness() -> void:
	if _fit.size() != _agent.size():
		_fit.resize(_agent.size())
	for k: int in _agent.size():
		_fit[k] = 1 if _is_cover(k) else 0


func _covering() -> int:
	var n: int = 0
	for i: int in _fit.size():
		n += _fit[i]
	return n


## Hand out the moving tokens, each against a NAMED coverer. Expired and orphaned
## bounds go first, then every surviving pairing is re-checked against this tick's
## report — a coverer that has been suppressed, run dry, lost sight or had a
## squadmate wander into its lane loses its charge immediately, and that counts as
## a breach. Only then are new tokens issued, and only while enough of the squad is
## still looking down the street.
func _update_bound() -> void:
	if _state != State.ASSAULT:
		overwatch.clear()
		return
	overwatch.expire(_clock)
	var i: int = 0
	while i < overwatch.count():
		var coverer: int = _slot_of(overwatch.coverer_at(i))
		if _slot_of(overwatch.mover_at(i)) >= 0 and coverer >= 0 and _fit[coverer] != 0:
			i += 1
			continue
		overwatch.note_breach()
		overwatch.revoke_at(i)
	if _covering() < doctrine.bound_min_coverers:
		return
	while overwatch.count() < doctrine.bound_max_movers:
		var before: int = overwatch.count()
		if not _issue_bound() or overwatch.count() == before:
			return


## Send one more body across, if there is one worth sending and somebody free to
## watch it. False when there is not, which ends the round of issuing.
func _issue_bound() -> bool:
	# Best mover first, THEN one search for its coverer. Scoring a coverer for every
	# candidate before choosing costs a lane scan per pair and the answer is thrown
	# away for all but one of them; three attempts is plenty and bounds the tick.
	var tried: int = 0
	var skip: PackedInt32Array = PackedInt32Array()
	while tried < 3:
		tried += 1
		var best: int = -1
		var best_s: float = -INF
		for k: int in _agent.size():
			if _role[k] != AIRoles.Role.ADVANCER and _role[k] != AIRoles.Role.FLANKER:
				continue
			if _dist[k] > doctrine.bound_range or skip.has(k):
				continue
			if overwatch.coverer_of(_agent[k]) >= 0 or _clock < _cover_until[k]:
				continue
			var s: float = _health[k] - _supp[k] + (0.4 if _cover[k] != 0 else 0.0)
			if s > best_s:
				best_s = s
				best = k
		if best < 0:
			return false
		var guard: int = _pick_coverer(best)
		if guard < 0:
			skip.append(best)
			continue
		overwatch.issue(_agent[best], _agent[guard], _clock + doctrine.bound_duration)
		callout(CALL_MOVING, _pos[best], _focus_id)
		return true
	return false


## Who watches member `mover` across: the best-placed body that can actually fire,
## is not already watching somebody else, and would not have the mover walk through
## its own line. The extra half of clearance on that last test is deliberate — a
## mover downrange of its own overwatch is not being covered, it is being shot at
## by its own side, and the margin is where it gets the benefit of the doubt.
func _pick_coverer(mover: int) -> int:
	var best: int = -1
	var best_s: float = -INF
	for k: int in _agent.size():
		if k == mover or _fit[k] == 0 or overwatch.is_covering(_agent[k]):
			continue
		if _in_lane(mover, k, 1.5):
			continue
		var s: float = _ammo[k] - _supp[k] * 1.5 + (0.5 if _cover[k] != 0 else 0.0)
		if s > best_s:
			best_s = s
			best = k
	return best


## How close to useless this squad reckons it is, in `[0, 1]`. Faction command
## sorts by it, so it decides who gets rescued and who is sent to do the rescuing.
func _distress() -> float:
	if _agent.is_empty():
		return 1.0
	var health: float = 0.0
	var supp: float = 0.0
	for k: int in _agent.size():
		health += _health[k]
		supp += _supp[k]
	var n: float = float(_agent.size())
	var d: float = 0.60 * (1.0 - strength_fraction())
	d += 0.25 * (1.0 - health / n)
	d += 0.15 * clampf(supp / n, 0.0, 1.0)
	if _state == State.ROUT:
		d = maxf(d, 0.9)
	elif _state == State.REGROUP:
		d = maxf(d, 0.6)
	return clampf(d, 0.0, 1.0)


## Publish the roster and this tick's territorial weight to the faction. The
## squad never touches the global ledger itself — the blackboard fuses every
## squad's contribution and flushes once, so one faction is one write per zone.
func _publish(delta: float) -> void:
	if blackboard == null:
		return
	blackboard.roster.publish(squad_id, _agent.size(), objective(), _centroid, _state, _distress())
	if _agent.is_empty():
		return
	var rate: float = doctrine.body_pressure_rate * Factions.expansion(faction) * delta
	# A squad told to hold leans harder on the ground it is standing on than one
	# passing through: holding is the act of pushing the ledger, not walking.
	if _intent == AIOrders.Intent.HOLD:
		rate *= 1.0 + _order_priority
	var ledger: Factions.Territory = Factions.territory
	for i: int in _agent.size():
		var zone: StringName = ledger.zone_at(_pos[i])
		if zone != &"":
			blackboard.interest.add(zone, rate)
