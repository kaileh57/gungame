class_name FireControl
extends Resource
## The trigger group: what a pull does, and how often it may do it.
##
## Range spec 4.6 rolls a display fire mode; `GunTables.ACTION` folds that onto one
## of eight mechanisms. This turns a held trigger into a stream of discrete shots at
## the weapon's rated rpm, and it does it by carrying the remainder forward rather
## than resetting a cooldown each shot. A 1,850 rpm auto fires 30.83 rounds per
## second whether the game is running at 30 fps or 240, and a string of a hundred
## rounds ends within one interval of where a stopwatch says it should.
##
## The mechanism does not fire the gun. It calls `shoot`, which returns true only if
## a round actually left the barrel; anything else — dry, jammed, mid-reload — stalls
## the group and clears any queued burst, exactly as a real one would.
##
## A CLICK IS AN EVENT AND THIS IS A CLOCK, and the two do not line up. A tap shorter
## than a physics tick is paid out by `TriggerLatch` as exactly one tick of
## trigger-down, and `advance` only starts something on a tick where the cooldown has
## already run out — so a click that landed a few hundredths of a second early used to
## be discarded outright rather than held. Measured over 208 rolled weapons, a player
## tapping 0.12 s ahead of the beat spent **2.00 clicks per round on every mechanism
## in the game**, which is the "you have to click two or three times" report. That is
## what `pull_buffer` is for.

enum Action { SEMI, AUTO, BURST, BOLT, PUMP, REVOLVER, BREAK, SINGLE }

## `GunTables.ACTION` ids onto mechanisms.
const ACTION_IDS: Dictionary = {
	&"semi": Action.SEMI,
	&"auto": Action.AUTO,
	&"burst": Action.BURST,
	&"bolt": Action.BOLT,
	&"pump": Action.PUMP,
	&"double": Action.REVOLVER,
	&"break": Action.BREAK,
	&"single": Action.SINGLE,
}
## Mechanisms that have to be worked by hand before the next round is available.
const MANUAL_ACTIONS: Array[int] = [Action.BOLT, Action.PUMP, Action.BREAK, Action.SINGLE]

## Rounds in a burst.
@export_range(2, 6, 1) var burst_count: int = 3
## Gap after the last round of a burst, as a multiple of the shot interval.
@export_range(1.0, 6.0, 0.05) var burst_gap_scale: float = 2.4
## Require the trigger to be released between shots on a semi-auto. The reference
## has no such gate and lets a 320 rpm semi run like an auto; off reproduces that.
@export var semi_requires_release: bool = true
## Tier index at and above which a SEMI-AUTO repeats while the trigger is HELD
## instead of demanding a click per round.
##
## A well-made gun should be pleasant to shoot, and pumping a trigger is the least
## pleasant thing a good gun can ask of you. Field-Grade is index 3 — Hazard,
## Scrap and Cobbled still make you work for every round, which is most of what
## makes them feel like junk. Manually-cycled actions are excluded on purpose; see
## the MANUAL branch in `_fire`.
@export_range(0, 6, 1) var hold_to_fire_tier: int = 3
## Require a release between bursts.
@export var burst_requires_release: bool = true
## Require a release before a hand-worked action fires again.
@export var manual_requires_release: bool = true
## Ceiling on shots resolved in a single tick. Stops a long frame or a paused
## editor from emptying a magazine in one go.
@export_range(1, 16, 1) var max_shots_per_tick: int = 6
## Seconds a trigger pull keeps looking for a mechanism willing to take it.
##
## This never makes a gun fire faster than its rated rate — `_cooldown` is not
## touched — and it can never turn one click into two rounds, because the pull is
## spent by the round it produces and only one pull is ever held. All it does is stop
## a click that arrived a fraction of a second early from being thrown away.
## 0.18 s is about one human timing error; zero restores the old behaviour exactly.
@export_range(0.0, 0.5, 0.005) var pull_buffer: float = 0.18
## Global rate multiplier, for tuning the whole game's tempo at once.
@export_range(0.25, 3.0, 0.01) var rate_scale: float = 1.0

## Called to fire one round. Must return true only when a round was actually fired.
var shoot: Callable = Callable()

var _action: int = Action.SEMI
var _interval: float = 0.5
var _cooldown: float = 0.0
var _burst_left: int = 0
var _trigger: bool = false
var _blocked_until_release: bool = false
## Set from the tier in `configure`; see `hold_to_fire_tier`.
var _holds: bool = false
## Seconds of life left in a pull that has not reached a mechanism yet.
var _buffer: float = 0.0


func _init() -> void:
	resource_local_to_scene = true


func configure(spec: GunSpec) -> void:
	var id: StringName = GunTables.action_for(spec.fire_mode)
	_action = int(ACTION_IDS.get(id, Action.SEMI))
	_interval = 60.0 / maxf(float(spec.rpm) * rate_scale, 1.0)
	_holds = spec.tier_index >= hold_to_fire_tier
	reset()


## Does this weapon keep firing while the trigger is held, whatever its action is.
func holds_to_fire() -> bool:
	return _holds


func action() -> int:
	return _action


func action_id() -> StringName:
	return StringName(ACTION_IDS.find_key(_action))


## Seconds between rounds at the rated rate.
func interval() -> float:
	return _interval


## True when this mechanism has to be hand-worked between shots.
func is_manual() -> bool:
	return MANUAL_ACTIONS.has(_action)


func is_trigger_down() -> bool:
	return _trigger


func burst_remaining() -> int:
	return _burst_left


## Seconds until the mechanism is willing to fire again. Zero or less means now.
func cooldown_remaining() -> float:
	return maxf(_cooldown, 0.0)


func trigger_down() -> void:
	# The RISING edge is the pull. Re-arming on every tick of a held trigger would
	# leave a live pull behind after the release, and an auto would fire one extra
	# round every time the player let go.
	if not _trigger:
		_buffer = pull_buffer
	_trigger = true


## Let go. The pull already made is deliberately NOT cancelled: a tap is one tick
## down and every tick after that is a release, so cancelling here would throw away
## the very click this exists to keep.
func trigger_up() -> void:
	_trigger = false
	_blocked_until_release = false


## Seconds of life left in a pull the mechanism has not answered yet. Zero means
## nothing is waiting. For a readout, and for a harness asking why a click vanished.
func pull_pending() -> float:
	return maxf(_buffer, 0.0)


## The pull has been answered, even though no round left the barrel. For the two
## refusals a later tick cannot undo — an empty chamber, which answers with a click,
## and an action that has just bound up, which answers with a jam.
func spend_pull() -> void:
	_buffer = 0.0


## Queue the rest of the magazine as an unstoppable string. A worn sear on a
## full-auto does not care that you let go.
func queue_runaway(rounds: int) -> void:
	_burst_left = maxi(_burst_left, maxi(rounds, 0))


func cancel_burst() -> void:
	_burst_left = 0


## Advance the timing and fire whatever the mechanism says should be fired.
## Returns the number of rounds that actually went off this tick.
func advance(delta: float) -> int:
	_cooldown -= delta
	if _buffer > 0.0:
		_buffer = maxf(_buffer - delta, 0.0)
	# Carrying the remainder forward is what makes the rate exact, but the debt may
	# only build while the mechanism is genuinely trying to fire. Let it run while a
	# gate is closed and the gun banks seven seconds of credit, then pays it out as
	# a burst the instant the trigger comes back down.
	if not _trigger or _blocked_until_release:
		_cooldown = maxf(_cooldown, 0.0)
	else:
		_cooldown = maxf(_cooldown, -_interval * float(max_shots_per_tick))
	var fired: int = 0
	while fired < max_shots_per_tick and _cooldown <= 0.0:
		if _burst_left > 0:
			if not _resolve_burst_round():
				break
			fired += 1
			continue
		if not _ready_to_start():
			break
		if not _pull():
			break
		fired += 1
	return fired


func reset() -> void:
	_cooldown = 0.0
	_burst_left = 0
	_trigger = false
	_blocked_until_release = false
	_buffer = 0.0


## One queued round of a burst or a runaway string.
func _resolve_burst_round() -> bool:
	if not _fire():
		_burst_left = 0
		_cooldown = maxf(_cooldown, 0.0)
		return false
	_burst_left -= 1
	_cooldown += _interval * (1.0 if _burst_left > 0 else burst_gap_scale)
	if _burst_left <= 0 and burst_requires_release:
		_blocked_until_release = _trigger
	return true


## Whether a fresh trigger pull is allowed to start something right now. A pull that
## is still inside `pull_buffer` counts as one even though the button is back up:
## the click was made, and this is the tick the mechanism finally got to it.
func _ready_to_start() -> bool:
	if _blocked_until_release:
		return false
	return _trigger or _buffer > 0.0


## Start whatever this mechanism starts on a fresh pull.
##
## A buffered pull is spent by the round it produces and by nothing else, so it keeps
## being offered for the rest of its life if the mechanism is not ready yet. That
## matters by exactly one tick and the whole fix turns on it: the shot that started a
## bolt's cycle set the cooldown from a slightly-negative base, so the cooldown runs
## out a fraction before the bolt comes home, and a pull spent on that one refusing
## tick is a click the player never gets back. Retrying costs one `shoot` call a tick
## for at most `pull_buffer` seconds. The two refusals that ARE final — a dry chamber
## and a bound action — call `spend_pull()` themselves, so neither can be retried into
## a stutter of dry-fire clicks.
func _pull() -> bool:
	if not _fire():
		_cooldown = maxf(_cooldown, 0.0)
		return false
	_buffer = 0.0
	_cooldown += _interval
	# Auto and double-action keep running while the trigger is held; nothing to gate.
	if _action == Action.BURST:
		_burst_left = maxi(burst_count - 1, 0)
	elif _action == Action.SEMI:
		_blocked_until_release = semi_requires_release and not _holds
	elif MANUAL_ACTIONS.has(_action):
		# NOT relaxed by `_holds`. A bolt, a pump and a break-action are worked by
		# hand, and a break-action that repeats on a held trigger is a gun opening,
		# ejecting, reloading and closing itself. It also breaks the rate model: a
		# 20 rpm break-action measured 1.225 s off its own 3 s interval once it was
		# allowed to repeat. Hold-to-fire is for the trigger, not for the action.
		_blocked_until_release = manual_requires_release
	return true


func _fire() -> bool:
	if not shoot.is_valid():
		return false
	return bool(shoot.call())
