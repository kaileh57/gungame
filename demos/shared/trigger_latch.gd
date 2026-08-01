class_name TriggerLatch
extends RefCounted
## A trigger pull shorter than one physics tick, made to count.
##
## THE BUG THIS EXISTS FOR. Three demos read their trigger with
## `Input.is_action_pressed(&"fire")` inside `_physics_process`. That is a poll of
## the CURRENT button state at 60 Hz, and the demos draw at 133-220 fps, so a click
## that opens and closes between two ticks is never seen at all. Measured by
## `tools/verify_click_input.gd` before this class existed: **fifty sub-frame
## trigger taps at the range produced zero rounds, and fifty at the arena produced
## zero rounds.** The gun only fired if you held the button long enough to straddle
## a tick — which is exactly the report, "you have to HARD click".
##
## WHAT IT DOES. `press()` and `release()` are fed from `_unhandled_input`, where
## every edge arrives whether or not a physics tick is anywhere near it. `resolve()`
## is called once per physics frame and answers one question: should the trigger be
## down this tick. A press that was never seen held is paid out as one tick down
## followed by one tick up, which is a complete pull as far as `FireControl` is
## concerned — including the release that `semi_requires_release` waits for.
##
## A press already served by the held path is not paid out twice: `release()` takes
## it back off the queue. Holding the button through a whole magazine therefore
## behaves exactly as it did before this class existed.
##
## [codeblock]
## func _unhandled_input(event: InputEvent) -> void:
##     if event.is_action_pressed(&"fire"):
##         _trigger.press()
##     elif event.is_action_released(&"fire"):
##         _trigger.release()
##
## func _physics_process(delta: float) -> void:
##     if _trigger.resolve():
##         _weapon.trigger_down()
##     else:
##         _weapon.trigger_up()
##     _weapon.tick(delta)
## [/codeblock]

## Unserved presses held at once. A person cannot mean more than a few clicks
## inside a sixtieth of a second, and a stuck input should not bank a magazine.
var max_taps: int = 4

var _held: bool = false
var _taps: int = 0
var _releasing: bool = false
var _served_while_held: bool = false


## The button went down.
func press() -> void:
	_held = true
	_taps = mini(_taps + 1, max_taps)


## The button came up. If a physics tick already saw the button held, that press
## has been paid and comes back off the queue.
func release() -> void:
	_held = false
	if _served_while_held:
		_taps = maxi(_taps - 1, 0)
	_served_while_held = false


## True while the button is physically down.
func held() -> bool:
	return _held


## Presses latched and not yet paid out.
func pending() -> int:
	return _taps


## Forget everything. For the frames where firing is not allowed at all — paused,
## freecam, mid-swap — so a press made against a closed gate does not go off the
## moment it opens.
func clear() -> void:
	_held = false
	_taps = 0
	_releasing = false
	_served_while_held = false


## Should the trigger be down this physics tick? Call exactly once per tick.
func resolve() -> bool:
	if _held:
		_served_while_held = true
		_releasing = false
		return true
	# One tick up after a paid-out tap, so a semi-auto's release gate opens.
	if _releasing:
		_releasing = false
		return false
	if _taps > 0:
		_taps -= 1
		_releasing = true
		return true
	return false
