class_name AIMorale
extends RefCounted
## Whether this body is still willing to be here.
##
## Four states and one float. `morale` runs from 1 down to 0 and is integrated
## from the gap between everything pressing on the body — wounds, suppression,
## being outnumbered, watching the man next to it fall — and everything holding it
## together: its own nerve, its species' tier, its discipline, and how many
## friends are still standing within shouting distance.
##
## The states exist because a float is not readable. A player cannot see 0.34; a
## player can see a rat turn and run while the machine beside it does not move.
## The thresholds carry hysteresis and a minimum dwell for the same reason the
## alert machine does — a body that flickers between holding and fleeing twice a
## second reads as broken, not as frightened.
##
## Routing has a floor on its duration. A body that breaks and then rallies
## fifteen frames later has not broken, it has stuttered; once it goes it commits
## to `rout_minimum` seconds of running before it will listen to anything.
##
## This class decides nothing about where the feet go. It answers "would this body
## rather be somewhere else", and hands out the scalars — speed, accuracy,
## willingness to push — that whatever owns the feet should be multiplying by.

## Morale crossed a threshold. Both values are `State`.
signal state_changed(previous: int, current: int)

enum State { STEADY, WAVERING, SHAKEN, ROUTING }

const STATE_NAMES: PackedStringArray = ["STEADY", "WAVERING", "SHAKEN", "ROUTING"]
## Friends within earshot at which a body stops feeling alone. Above this the
## isolation term is zero; at zero friends it is at full weight.
const COMPANY: float = 3.0
## Ceiling on the shock pool, so nine simultaneous casualties are not nine times
## worse than three. Shock is a jolt, not an accumulator.
const SHOCK_CEILING: float = 1.4

## Morale below which STEADY gives way, and above which it is recovered. The gap
## between each pair is the hysteresis and is what stops the flicker.
var wavering_at: float = 0.62
var shaken_at: float = 0.36
var routing_at: float = 0.14
var recover_margin: float = 0.09
## Seconds any state must be held before it may be left.
var min_dwell: float = 0.9
## Seconds a rout runs before the body will even consider stopping.
var rout_minimum: float = 3.5
## How fast morale moves, in units per second at unit pressure.
var rate: float = 0.5
## Weights on the four pressures. Health is squared-ish on the way in, so the last
## quarter of a health bar is worth far more than the first.
var weight_wounds: float = 1.15
var weight_suppression: float = 0.62
var weight_isolation: float = 0.5
var weight_odds: float = 0.34
## Shock bled off per second.
var shock_decay: float = 0.75
## Multiplier on speed while routing, and the accuracy left to a shaken body.
var rout_speed: float = 1.0
var shaken_accuracy: float = 0.62

var state: int = State.STEADY
## 1 composed, 0 gone. Integrated, never written directly from outside.
var morale: float = 1.0
var time_in_state: float = 0.0
## Last frame's computed pressure and resolve, kept for the overlay: a body that
## is holding at 0.4 and one that is holding at 0.95 look identical without them.
var pressure: float = 0.0
var resolve: float = 1.0

var _shock: float = 0.0
var _threat: Vector3 = Vector3.ZERO
var _has_threat: bool = false
var _rout_clock: float = 0.0
var _flee_bias: float = 0.0


func _init(profile: AISpeciesProfile = null, personality: AIPersonality = null) -> void:
	configure(profile, personality)


## Read the species' courage block and the body's own nerve. Safe to call again on
## a pooled body; it resets morale to full, which is what a fresh spawn wants.
func configure(profile: AISpeciesProfile, personality: AIPersonality) -> void:
	var nerve: float = 0.5 if personality == null else personality.nerve
	var drilled: float = 0.5 if personality == null else personality.discipline
	_flee_bias = 0.0 if personality == null else (personality.phase - PI) * 0.12
	if profile != null:
		rate = profile.morale_rate
		rout_minimum = profile.rout_minimum
		rout_speed = profile.rout_speed_scale
		weight_suppression = profile.morale_suppression_weight
		# The species' own flee threshold moves the whole ladder rather than acting
		# as a separate trigger. A thing with flee_health 0 never reaches WAVERING
		# from wounds alone; a thing with 0.6 is halfway out of the fight at 60 %.
		var floor_shift: float = clampf(profile.flee_health, 0.0, 1.0) * 0.34
		wavering_at = clampf(0.42 + floor_shift, 0.05, 0.95)
		shaken_at = clampf(wavering_at - 0.26, 0.03, 0.9)
		routing_at = clampf(shaken_at - 0.22, 0.0, 0.85)
	resolve = 0.35 + 0.75 * nerve + 0.25 * drilled
	reset()


## Back to composed. Spawn, revive, and the end of a wave.
func reset() -> void:
	var previous: int = state
	state = State.STEADY
	morale = 1.0
	time_in_state = 0.0
	pressure = 0.0
	_shock = 0.0
	_rout_clock = 0.0
	_has_threat = false
	if previous != State.STEADY:
		state_changed.emit(previous, state)


## One step. `health` and `suppression` are fractions in [0, 1]; `allies` and
## `hostiles` are bodies within earshot, not the whole map. Returns the state.
func tick(delta: float, health: float, suppression: float, allies: int, hostiles: int) -> int:
	time_in_state += delta
	_shock = maxf(_shock - shock_decay * delta, 0.0)
	if state == State.ROUTING:
		_rout_clock += delta
	var wounds: float = pow(clampf(1.0 - health, 0.0, 1.0), 1.55)
	var alone: float = clampf(1.0 - float(allies) / COMPANY, 0.0, 1.0)
	var odds: float = clampf(float(hostiles) / maxf(float(allies) + 1.0, 1.0) - 1.0, 0.0, 2.5)
	pressure = (
		wounds * weight_wounds
		+ clampf(suppression, 0.0, 1.0) * weight_suppression
		+ alone * weight_isolation
		+ odds * weight_odds
		+ _shock
	)
	morale = clampf(morale + (resolve - pressure) * rate * delta, 0.0, 1.0)
	_settle()
	return state


## Something happened that no amount of steadiness absorbs smoothly: a round
## landed, a squadmate died within sight, a grenade went off underfoot. `amount`
## is roughly "fraction of this body's composure", so a killing blow is near 1.
func shock(amount: float, from_position: Vector3) -> void:
	_shock = minf(_shock + maxf(amount, 0.0), SHOCK_CEILING)
	if from_position != Vector3.ZERO:
		_threat = from_position
		_has_threat = true


## Somebody senior said hold. Buys back composure without clearing the pressure
## that caused it, so a rally into the same fire breaks again.
func rally() -> void:
	if state == State.ROUTING and _rout_clock < rout_minimum:
		return
	morale = maxf(morale, wavering_at + recover_margin)
	_shock *= 0.4
	_settle()


func is_routing() -> bool:
	return state == State.ROUTING


## Whether this body will stand where it was told to stand. False once shaken:
## a shaken body still fights, but it fights from wherever it feels safer.
func holds_ground() -> bool:
	return state == State.STEADY or state == State.WAVERING


## Whether it will pull a trigger at all. A routing body does not stop to shoot.
func may_shoot() -> bool:
	return state != State.ROUTING


## Multiplier on top speed. A rout is the one time a body moves flat out.
func speed_scale() -> float:
	if state == State.ROUTING:
		return rout_speed
	if state == State.SHAKEN:
		return 1.0
	return 1.0


## Multiplier on the aim cone: above 1 is a wider, worse cone. Fear spoils aim
## before it stops the trigger.
func spread_scale() -> float:
	match state:
		State.WAVERING:
			return 1.0 + (1.0 - shaken_accuracy) * 0.5
		State.SHAKEN:
			return 1.0 / maxf(shaken_accuracy, 0.2)
		State.ROUTING:
			return 2.2
	return 1.0


## Multiplier on how far this body is willing to push. Zero once it is running.
func push_scale() -> float:
	match state:
		State.WAVERING:
			return 0.78
		State.SHAKEN:
			return 0.4
		State.ROUTING:
			return 0.0
	return 1.0


## Which way to run: away from the last thing that hurt it, flattened, and turned
## a little by the body's own bias so a broken squad scatters instead of forming
## a retreating line. Falls back to `here`'s own heading when nothing is known.
func flee_direction(here: Vector3, fallback: Vector3) -> Vector3:
	var away: Vector3 = fallback
	if _has_threat:
		away = here - _threat
	away.y = 0.0
	if away.length_squared() < 1e-4:
		return Vector3.ZERO
	return away.normalized().rotated(Vector3.UP, _flee_bias)


## Where the pressure is coming from, for the overlay and for the flee solver.
func threat_position() -> Vector3:
	return _threat


func state_name() -> String:
	return STATE_NAMES[state]


## Promote or demote, honouring the dwell and the recovery margin. Recovery uses
## the higher threshold on the way back up, which is the whole hysteresis.
func _settle() -> void:
	var want: int = State.STEADY
	if morale <= routing_at:
		want = State.ROUTING
	elif morale <= shaken_at:
		want = State.SHAKEN
	elif morale <= wavering_at:
		want = State.WAVERING
	if want < state:
		# Climbing back out costs the extra margin, so a body sitting exactly on a
		# threshold does not oscillate across it.
		var need: float = recover_margin
		if state == State.ROUTING and _rout_clock < rout_minimum:
			return
		if morale < _floor_of(state) + need:
			return
	if want == state or time_in_state < min_dwell:
		return
	var previous: int = state
	state = want
	time_in_state = 0.0
	if want == State.ROUTING:
		_rout_clock = 0.0
	state_changed.emit(previous, want)


## The morale value at which a state begins, used by the recovery margin.
func _floor_of(which: int) -> float:
	match which:
		State.ROUTING:
			return routing_at
		State.SHAKEN:
			return shaken_at
		State.WAVERING:
			return wavering_at
	return 1.0
