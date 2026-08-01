class_name AIAlertness
extends RefCounted
## The alert state machine: Idle, Suspicious, Searching, Engaged, Losing.
##
## Every threshold is a pair — one to get in, a lower one to get out — and every
## state has a minimum dwell time it must serve before it is allowed to leave.
## Without both, an agent standing at the edge of a doorway flickers between
## Suspicious and Engaged twice a second and reads as broken. The dwell times are
## short enough that nothing ever feels sticky; the hysteresis gap does the work.
##
## The machine reads two inputs and writes one output. It does not move anybody.
##
## Two things stop a line of bodies behaving as one animal. The first is that the
## dwell and the stare are JITTERED per instance, by up to `VARIATION`, so twelve
## agents that all saw the same thing on the same frame do not all decide to go
## and look on the same frame. The second is that the search WRAPS: after
## `sweep_points` places have been checked the step returns to the first one and
## `search_cycle` increments, so an agent that has swept a room walks back through
## it once more rather than spiralling off into the desert until the timeout saves
## it. Coming back for a second look is what a person does and it is what makes a
## search read as a search.

## Old and new state, both `State` values. Fired once per transition.
signal state_changed(previous: int, current: int)

enum State { IDLE, SUSPICIOUS, SEARCHING, ENGAGED, LOSING }
## Coarser than `State`, and what an animator or an overlay actually wants: how
## this body is carrying itself, rather than which branch of the machine it is in.
enum Posture { RELAXED, WATCHFUL, HUNTING, COMBAT }

const STATE_NAMES: PackedStringArray = ["IDLE", "SUSPICIOUS", "SEARCHING", "ENGAGED", "LOSING"]
const POSTURE_NAMES: PackedStringArray = ["RELAXED", "WATCHFUL", "HUNTING", "COMBAT"]
## Fraction by which per-instance timings are spread. Applied only to the stare
## and the minimum dwell: the grace before a target counts as lost and the search
## cadence are contracts other systems measure against and must not wander.
const VARIATION: float = 0.22

## Awareness that promotes Idle to Suspicious.
var suspicious_enter: float = 0.30
## Awareness that drops Suspicious back to Idle. The gap is the hysteresis.
var suspicious_exit: float = 0.14
## Awareness that commits to Engaged. A confirmed sighting reaches 1.0.
var engage_enter: float = 0.95
## Seconds of no sighting before Engaged concedes it has lost the target.
var lose_grace: float = 2.2
## Seconds spent in Losing before it gives up and starts searching properly.
var losing_time: float = 5.0
## Seconds of a fruitless search before standing down.
var search_timeout: float = 22.0
## Minimum time in any state before a transition out of it is considered.
var min_dwell: float = 0.55
## Seconds Suspicious will stare before it decides to go and look.
var investigate_delay: float = 1.4
## Seconds an agent stands at one search point before asking for the next.
var search_dwell: float = 1.8
## Places checked before the sweep wraps back to the first one for another pass.
var sweep_points: int = 7

var state: int = State.IDLE
var time_in_state: float = 0.0
## Seconds since the agent last had eyes on anything hostile. Starts large so a
## fresh agent is not treated as having just lost a target.
var time_since_seen: float = 999.0
## How far into the search spiral this agent has walked. Feeds
## `AIMemory.search_point`; reset every time a search begins.
var search_step: int = 0
## How many full sweeps of the plausible space have been walked. Nothing in the
## machine branches on it; it is what the overlay shows as "second pass".
var search_cycle: int = 0

var _pending: int = -1
var _dwell_timer: float = 0.0
## Per-instance spread in [-1, 1], from the object's own identity. Two machines
## built in the same frame get different values, which is the entire point.
var _spread: float = 0.0


## Drive one tick. `awareness` is the best contact's awareness, `visible` is
## whether that contact is in sight right now, and `has_lead` is whether the agent
## has anywhere to go and look — a remembered position or a heard noise.
## Copy the global feel settings in. Called once when the agent is bound.
##
## The stare and the minimum dwell come out of here spread across the population.
## Everything else is copied exactly: `lose_grace` and `search_dwell` are measured
## by `tools/verify_ai_perception.gd` against the tuning asset to the frame, and a
## machine that wandered off them would be untestable as well as unpredictable.
func apply_tuning(t: AIPerceptionTuning) -> void:
	suspicious_enter = t.suspicious_enter
	suspicious_exit = minf(t.suspicious_exit, t.suspicious_enter - 0.01)
	engage_enter = maxf(t.engage_enter, t.suspicious_enter + 0.02)
	lose_grace = t.lose_grace
	losing_time = t.losing_time
	search_timeout = t.search_timeout
	search_dwell = t.search_dwell
	_spread = _identity_spread()
	min_dwell = t.min_dwell * (1.0 + VARIATION * _spread)
	investigate_delay = t.investigate_delay * (1.0 - VARIATION * _spread)


func tick(delta: float, awareness: float, visible: bool, has_lead: bool) -> int:
	time_in_state += delta
	time_since_seen = 0.0 if visible else time_since_seen + delta
	_pending = state
	match state:
		State.IDLE:
			_from_idle(awareness, visible)
		State.SUSPICIOUS:
			_from_suspicious(awareness, visible, has_lead)
		State.SEARCHING:
			_from_searching(delta, awareness, visible, has_lead)
		State.ENGAGED:
			_from_engaged()
		State.LOSING:
			_from_losing(awareness, visible, has_lead)
	if _pending != state and time_in_state >= min_dwell:
		_transition(_pending)
	return state


## Force a state, bypassing hysteresis. Used when a squadmate calls out a
## confirmed contact or when an agent takes a hit from somewhere it cannot see —
## being shot is not a thing you talk yourself into gradually.
func force(new_state: int) -> void:
	if new_state != state:
		_transition(new_state)


func is_fighting() -> bool:
	return state == State.ENGAGED or state == State.LOSING


func is_alerted() -> bool:
	return state != State.IDLE


func state_name() -> String:
	return STATE_NAMES[state]


## How the body is carrying itself. Coarser than the state and stable across the
## states that look the same from outside — SEARCHING and LOSING are one posture,
## because a body hunting for something it has lost moves the same way either way.
func posture() -> int:
	match state:
		State.SUSPICIOUS:
			return Posture.WATCHFUL
		State.SEARCHING, State.LOSING:
			return Posture.HUNTING
		State.ENGAGED:
			return Posture.COMBAT
	return Posture.RELAXED


func posture_name() -> String:
	return POSTURE_NAMES[posture()]


func reset() -> void:
	_transition(State.IDLE)
	time_since_seen = 999.0
	search_cycle = 0


## Engaging straight out of Idle needs eyes on. Repeated gunfire alone can push
## awareness past `engage_enter`, and a body that snaps to Engaged on a sound it
## has not looked at yet will shoot at a wall.
func _from_idle(awareness: float, visible: bool) -> void:
	if awareness >= engage_enter and visible:
		_pending = State.ENGAGED
	elif awareness >= suspicious_enter:
		_pending = State.SUSPICIOUS


func _from_suspicious(awareness: float, visible: bool, has_lead: bool) -> void:
	if awareness >= engage_enter and visible:
		_pending = State.ENGAGED
	elif awareness < suspicious_exit:
		_pending = State.IDLE
	elif time_in_state >= investigate_delay and has_lead:
		_pending = State.SEARCHING


func _from_searching(delta: float, awareness: float, visible: bool, has_lead: bool) -> void:
	_dwell_timer += delta
	if _dwell_timer >= search_dwell:
		_dwell_timer = 0.0
		search_step += 1
		# Wrap rather than spiral away for ever. The spiral is capped in metres by
		# `AIMemory.search_radius_max` anyway, so past this point every further
		# step is another lap of the same ring at a slightly different angle —
		# which is worse than walking the useful points again.
		if sweep_points > 0 and search_step >= sweep_points:
			search_step = 0
			search_cycle += 1
	if awareness >= engage_enter and visible:
		_pending = State.ENGAGED
	elif time_in_state >= search_timeout or (not has_lead and awareness < suspicious_exit):
		_pending = State.IDLE


func _from_engaged() -> void:
	if time_since_seen >= lose_grace:
		_pending = State.LOSING


func _from_losing(awareness: float, visible: bool, has_lead: bool) -> void:
	if visible and awareness >= suspicious_enter:
		_pending = State.ENGAGED
	elif time_in_state >= losing_time:
		_pending = State.SEARCHING if has_lead else State.IDLE


func _transition(new_state: int) -> void:
	var previous: int = state
	state = new_state
	_pending = new_state
	time_in_state = 0.0
	if new_state == State.SEARCHING and previous != State.SEARCHING:
		search_step = 0
		search_cycle = 0
		_dwell_timer = 0.0
	state_changed.emit(previous, new_state)


## A number in [-1, 1] that is this object's and nobody else's. Derived from the
## instance id rather than a seed because both call sites construct this machine
## with no arguments, and a de-synchronised population is worth more here than a
## reproducible one — nothing downstream measures the jitter, it only sees that
## twelve bodies stopped moving in lockstep.
func _identity_spread() -> float:
	var h: int = int(get_instance_id()) & 0x7FFFFFFF
	h = (h ^ (h >> 15)) * 668265261 & 0x7FFFFFFF
	return float(h & 0xFFFF) / 32767.5 - 1.0
