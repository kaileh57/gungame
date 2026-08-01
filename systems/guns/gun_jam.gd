class_name GunJam
extends Resource
## Whether the gun goes off, and what it costs when it does not.
##
## Range spec 12.3: `P(jam) = (1 - reliability/100)^1.8 * 0.05`, rolled **after** the
## round leaves the magazine. A well-made gun at reliability 98 jams once in ~28,000
## rounds; a 50 jams once in 70; a 1 jams one round in 20. The exponent is what makes
## the middle of the reliability scale feel safe and the bottom feel cursed.
##
## Clearing takes a flat 1.2 s of holding the reload key. Let go early and the round
## you spent is still gone and the gun is still jammed.

signal jammed
signal cleared

## Ceiling of the jam curve: the chance at reliability 0.
@export_range(0.0, 0.5, 0.001) var jam_chance_at_zero: float = 0.05
## Curve shape. Above 1 the good end of the reliability scale gets disproportionately
## safe, which is the reference's behaviour and the reason tiers mean anything.
@export_range(0.5, 4.0, 0.05) var jam_exponent: float = 1.8
## Seconds of held clearing to get the gun back.
@export_range(0.1, 5.0, 0.05) var clear_seconds: float = 1.2
## Extra jam chance while the magazine's last rounds feed, where real guns bind.
## Zero reproduces the reference exactly.
@export_range(0.0, 2.0, 0.01) var last_rounds_penalty: float = 0.0
## How many rounds from empty the penalty applies over.
@export_range(0, 10, 1) var last_rounds_window: int = 3

var _is_jammed: bool = false
var _clearing: float = 0.0
var _base_chance: float = 0.0


func _init() -> void:
	resource_local_to_scene = true


func configure(spec: GunSpec) -> void:
	var unreliability: float = clampf(1.0 - float(spec.reliability) / 100.0, 0.0, 1.0)
	_base_chance = pow(unreliability, jam_exponent) * jam_chance_at_zero
	_is_jammed = false
	_clearing = 0.0


func is_jammed() -> bool:
	return _is_jammed


func is_clearing() -> bool:
	return _clearing > 0.0


## 0..1 progress through the clearing action, for a diegetic readout.
func clear_progress() -> float:
	if _clearing <= 0.0:
		return 0.0
	return clampf(1.0 - _clearing / maxf(clear_seconds, 0.001), 0.0, 1.0)


## The chance this shot binds the action, given how many rounds are left.
func chance(rounds_left: int) -> float:
	if last_rounds_penalty <= 0.0 or last_rounds_window <= 0:
		return _base_chance
	if rounds_left >= last_rounds_window:
		return _base_chance
	var t: float = 1.0 - float(rounds_left) / float(last_rounds_window)
	return _base_chance * (1.0 + last_rounds_penalty * t)


## Roll for a jam on a round that has already been consumed. Returns true when the
## gun just bound up.
func roll(rounds_left: int, rand: XorShift32) -> bool:
	if _is_jammed:
		return false
	if rand.next() >= chance(rounds_left):
		return false
	_is_jammed = true
	_clearing = 0.0
	jammed.emit()
	return true


## Begin clearing. Does nothing if the gun is fine or clearing is already running.
func begin_clear() -> bool:
	if not _is_jammed or _clearing > 0.0:
		return false
	_clearing = clear_seconds
	return true


## Let go of the reload key. The gun stays jammed and the work is lost.
func abort_clear() -> void:
	_clearing = 0.0


## Advance a running clear. Returns true on the frame the gun comes back.
func tick(delta: float) -> bool:
	if _clearing <= 0.0:
		return false
	_clearing -= delta
	if _clearing > 0.0:
		return false
	_clearing = 0.0
	_is_jammed = false
	cleared.emit()
	return true


func reset() -> void:
	_is_jammed = false
	_clearing = 0.0
