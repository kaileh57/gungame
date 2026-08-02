class_name GunJam
extends Resource
## Whether the gun goes off, what kind of stoppage it is when it does not, and
## what that costs.
##
## Range spec 12.3: `P(jam) = (1 - reliability/100)^1.8 * 0.05`, rolled **after** the
## round leaves the magazine. A well-made gun at reliability 98 jams once in ~28,000
## rounds; a 50 jams once in 70; a 1 jams one round in 20. The exponent is what makes
## the middle of the reliability scale feel safe and the bottom feel cursed.
##
## That curve reads reliability and nothing else, which is why tier used to be a
## number on a card. `GunGrading.jam_profile()` supplies the rest of the object:
##
##   chance_scale  workmanship AND how far the rated rate outruns it. This is where
##                 "a gun that can mag dump instantly is not scrap grade" is paid
##                 for — a scrappy weapon that rolled a high cyclic is running past
##                 what its own fit can carry, and it binds for it.
##   wear          the chance climbs as the magazine drains. A full mag on a rough
##                 gun is fine; the back half is where it eats itself.
##   tail          the last few rounds on top of that, where a tired spring is
##                 lifting the stack furthest.
##   hard / light  not every stoppage is the same stoppage. A good gun's jams are
##                 mostly a tap and a rack; a Hazard's are mostly strip-it-down.
##   clear_scale   and all of them take longer on a rough gun.
##
## Clearing is held on the reload key. Let go early and the round you spent is
## still gone, the gun is still jammed, and the work is lost.

signal jammed
signal cleared

## The three kinds of stoppage, in ascending cost. `severity()` reports which one
## the gun is currently sitting on so the HUD, the viewmodel and the audio can
## tell a rack from a teardown.
enum Severity { LIGHT, ORDINARY, HARD }

## Ceiling of the jam curve: the chance at reliability 0.
@export_range(0.0, 0.5, 0.001) var jam_chance_at_zero: float = 0.05
## Curve shape. Above 1 the good end of the reliability scale gets disproportionately
## safe, which is the reference's behaviour and the reason tiers mean anything.
@export_range(0.5, 4.0, 0.05) var jam_exponent: float = 1.8
## Seconds of held clearing to get an ordinary stoppage back.
@export_range(0.1, 5.0, 0.05) var clear_seconds: float = 1.2
## Clearing cost of a tap-and-rack, as a share of an ordinary stoppage.
@export_range(0.1, 1.0, 0.01) var light_clear_scale: float = 0.42
## Clearing cost of stripping a bound action down, as a multiple of an ordinary one.
@export_range(1.0, 5.0, 0.05) var hard_clear_scale: float = 2.20
## Extra jam chance while the magazine's last rounds feed, where real guns bind.
## Zero reproduces the reference exactly; `GunGrading` adds its own on top.
@export_range(0.0, 2.0, 0.01) var last_rounds_penalty: float = 0.0
## How many rounds from empty the penalty applies over.
@export_range(0, 10, 1) var last_rounds_window: int = 3
## Hard ceiling on the per-round chance after every multiplier. Without it a Hazard
## running far past its own action reaches a number that is not a gun any more.
##
## 0.18 is one stoppage every five and a half rounds, which on a nine-round Hazard
## magazine is roughly one and a half per mag. The tier ladder wants to go much
## further than that — the raw product on a Hazard averages 38 % — and this is the
## line between "this weapon is a liability" and "this weapon is a cutscene".
@export_range(0.01, 0.9, 0.01) var chance_ceiling: float = 0.18
## Ceiling on how much a weapon's grading may stretch a stoppage. Uncapped, a
## Hazard's teardown costs 8.5 seconds; the shooter is not playing the game for
## any of them. 1.60 puts an ordinary Hazard stoppage at 1.9 s and its worst at
## 4.2 s, which is long enough to lose a fight and short enough to be one.
@export_range(1.0, 4.0, 0.05) var grading_clear_ceiling: float = 1.60
## Let a rolled weapon's grading tilt this resource at all. Off restores the flat
## reliability curve for a test rig that wants the reference's numbers.
@export var use_grading: bool = true
## How much of the weapon's named character reaches the action. 0 leaves the
## smooth tier ladder alone and a "burred chamber" becomes a word again; 1 is the
## shipped weight; 2 makes a fault the defining thing about the gun.
@export_range(0.0, 2.0, 0.05) var quirk_strength: float = 1.0

var _is_jammed: bool = false
var _clearing: float = 0.0
var _base_chance: float = 0.0
var _capacity: int = 1
var _chance_scale: float = 1.0
var _clear_scale: float = 1.0
var _wear: float = 0.0
var _tail: float = 0.0
var _hard: float = 0.0
var _light: float = 1.0
var _severity: int = Severity.ORDINARY


func _init() -> void:
	resource_local_to_scene = true


func configure(spec: GunSpec) -> void:
	var unreliability: float = clampf(1.0 - float(spec.reliability) / 100.0, 0.0, 1.0)
	_base_chance = pow(unreliability, jam_exponent) * jam_chance_at_zero
	_capacity = maxi(spec.magazine, 1)
	_chance_scale = 1.0
	_clear_scale = 1.0
	_wear = 0.0
	_tail = 0.0
	_hard = 0.0
	_light = 1.0
	if use_grading:
		GunGrading.ensure(spec)
		var p: Dictionary = GunGrading.jam_profile(spec, quirk_strength)
		_chance_scale = float(p[&"chance_scale"])
		_clear_scale = clampf(float(p[&"clear_scale"]), 0.35, grading_clear_ceiling)
		_wear = float(p[&"wear"])
		_tail = float(p[&"tail"])
		_hard = float(p[&"hard"])
		_light = float(p[&"light"])
	_is_jammed = false
	_clearing = 0.0
	_severity = Severity.ORDINARY


func is_jammed() -> bool:
	return _is_jammed


func is_clearing() -> bool:
	return _clearing > 0.0


## Which kind of stoppage the gun is sitting on. Only meaningful while jammed.
func severity() -> int:
	return _severity


## Seconds of held clearing this particular stoppage costs, grading and severity
## included. The reload arc and the audio both need the real number.
func current_clear_seconds() -> float:
	var scale: float = 1.0
	if _severity == Severity.LIGHT:
		scale = light_clear_scale
	elif _severity == Severity.HARD:
		scale = hard_clear_scale
	return maxf(clear_seconds * _clear_scale * scale, 0.05)


## 0..1 progress through the clearing action, for a diegetic readout.
func clear_progress() -> float:
	if _clearing <= 0.0:
		return 0.0
	return clampf(1.0 - _clearing / current_clear_seconds(), 0.0, 1.0)


## The chance this shot binds the action, given how many rounds are left.
##
## Three terms, multiplied: the reliability curve scaled by workmanship and rate
## stress, a wear ramp that climbs across the whole magazine, and the last-rounds
## tail on top of it. The ramp is what makes a long burst on a bad gun feel like a
## gamble that gets worse rather than a coin flipped at a fixed odds.
func chance(rounds_left: int) -> float:
	var c: float = _base_chance * _chance_scale
	if _wear > 0.0 and _capacity > 1:
		var drained: float = clampf(1.0 - float(rounds_left) / float(_capacity), 0.0, 1.0)
		c *= 1.0 + _wear * drained * drained
	var tail: float = last_rounds_penalty + _tail
	if tail > 0.0 and last_rounds_window > 0 and rounds_left < last_rounds_window:
		c *= 1.0 + tail * (1.0 - float(rounds_left) / float(last_rounds_window))
	return clampf(c, 0.0, chance_ceiling)


## Roll for a jam on a round that has already been consumed. Returns true when the
## gun just bound up. Costs one draw, plus a second to pick the severity when it
## actually binds.
func roll(rounds_left: int, rand: XorShift32) -> bool:
	if _is_jammed:
		return false
	if rand.next() >= chance(rounds_left):
		return false
	_is_jammed = true
	_clearing = 0.0
	_severity = _roll_severity(rand)
	jammed.emit()
	return true


## Begin clearing. Does nothing if the gun is fine or clearing is already running.
func begin_clear() -> bool:
	if not _is_jammed or _clearing > 0.0:
		return false
	_clearing = current_clear_seconds()
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
	_severity = Severity.ORDINARY
	cleared.emit()
	return true


func reset() -> void:
	_is_jammed = false
	_clearing = 0.0
	_severity = Severity.ORDINARY


## Pick what kind of stoppage this is. The two shares come from the grading and
## never sum past 1; whatever is left over is an ordinary stoppage, which is why
## the mid-tiers get a mix rather than one signature failure.
func _roll_severity(rand: XorShift32) -> int:
	var hard: float = clampf(_hard, 0.0, 1.0)
	var light: float = clampf(_light, 0.0, 1.0 - hard)
	var u: float = rand.next()
	if u < hard:
		return Severity.HARD
	return Severity.LIGHT if u < hard + light else Severity.ORDINARY
