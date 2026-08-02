class_name GunAmmo
extends RefCounted
## Rounds in the gun and rounds in the pouch — and, on a scavenged magazine,
## whether the number in the gun is the number you asked for.
##
## The reference keeps reserve ammo infinite and refills the magazine to `cap` in
## one go (range spec 12.5). That is the default here — `infinite_reserve` on. Turn
## it off and the same object does real accounting: a reload moves at most
## `capacity - loaded` rounds out of the reserve, and a partial reload leaves a
## partial magazine.
##
## `GunGrading.feed_profile()` adds the part the reference has no model for: the
## magazine as a piece of scavenged hardware in its own right, judged on the
## weapon's workmanship AND on how tall the stack is. A six-shot cylinder is fine
## on a bad gun. A scavenged sixty-round drum on the same gun is a liability, and
## it fails in two ways you feel rather than read:
##
##   short    a fresh magazine did not seat its full count. You have 26 in a 30
##            and no warning except the number on the HUD.
##   misfeed  the stack strips two rounds where it should have stripped one. The
##            round is simply gone.
##
## Both are drawn off a stream salted per weapon, so a given gun always cheats you
## the same way and you learn to distrust that gun specifically.
##
## Nothing in here touches time. `GunReload` decides when rounds move; this decides
## how many there are to move.

signal ammo_changed(loaded: int, reserve: int)
## The magazine went dry. Fire control listens and starts a reload.
signal emptied
## The stack stripped a round it should not have. `lost` is how many went with the
## shot beyond the one that was fired.
signal misfed(lost: int)
## A fresh magazine seated short. `short` is how many rounds it is missing.
signal short_loaded(short: int)

var _capacity: int = 1
var _loaded: int = 0
var _reserve: int = 0
var _reserve_capacity: int = 0
var _infinite: bool = true
var _short: float = 0.0
var _misfeed: float = 0.0
var _rand: XorShift32 = XorShift32.new(1)


## Size the magazine from a rolled weapon. `reserve_mags` is how many spare
## magazines the carrier starts with when the reserve is finite.
##
## `quirk_strength` is the same dial the mechanism resources carry, defaulted so
## the existing three-argument call site is unchanged. This object is a
## `RefCounted` rather than a `Resource` and has no inspector of its own, so
## `Weapon` is where a rig that wants to turn the character layer off would pass
## it through; `GunReload.feed_quirk_strength` is the inspector-facing twin.
func configure(
	spec: GunSpec, infinite_reserve: bool, reserve_mags: int, quirk_strength: float = 1.0
) -> void:
	_capacity = maxi(1, spec.magazine)
	_infinite = infinite_reserve
	_reserve_capacity = _capacity * maxi(0, reserve_mags)
	GunGrading.ensure(spec)
	var p: Dictionary = GunGrading.feed_profile(spec, maxf(quirk_strength, 0.0))
	_short = clampf(float(p[&"short"]), 0.0, 0.6)
	_misfeed = clampf(float(p[&"misfeed"]), 0.0, 0.25)
	_rand = GunGrading.stream(spec, GunGrading.FEED_SALT)
	_loaded = _capacity
	_reserve = _reserve_capacity
	ammo_changed.emit(_loaded, reserve())


func capacity() -> int:
	return _capacity


func loaded() -> int:
	return _loaded


## Rounds available for the next reload. -1 reads as "infinite" for the HUD.
func reserve() -> int:
	return -1 if _infinite else _reserve


func is_empty() -> bool:
	return _loaded <= 0


func is_full() -> bool:
	return _loaded >= _capacity


## Per-shot chance the stack strips a second round. For the stat card and the AI.
func misfeed_chance() -> float:
	return _misfeed


## True when a reload would actually change anything.
##
## A weapon that short-loads is never "full" by count, so this asks whether the
## magazine could take another round at all rather than whether it is topped off —
## otherwise a gun that seated 26 of 30 would refuse to be reloaded ever again.
func can_reload() -> bool:
	if is_full():
		return false
	return _infinite or _reserve > 0


## Take one round for a shot. Returns false when the magazine was already dry, in
## which case nothing was consumed and the caller should click on an empty chamber.
##
## A worn feed may take a second round with it. That round is gone — it is not
## fired, it is not in the pouch, it is lying in the dirt behind the ejection port.
func consume() -> bool:
	if _loaded <= 0:
		return false
	_loaded -= 1
	var lost: int = 0
	if _misfeed > 0.0 and _loaded > 0 and _rand.next() < _misfeed:
		lost = 1
		_loaded -= 1
	ammo_changed.emit(_loaded, reserve())
	if lost > 0:
		misfed.emit(lost)
	if _loaded <= 0:
		emptied.emit()
	return true


## Move up to `count` rounds from the reserve into the magazine. Returns how many
## actually moved, which is zero when the pouch is empty.
func load_rounds(count: int) -> int:
	var want: int = mini(count, _capacity - _loaded)
	if want <= 0:
		return 0
	if not _infinite:
		want = mini(want, _reserve)
		if want <= 0:
			return 0
		_reserve -= want
	_loaded += want
	ammo_changed.emit(_loaded, reserve())
	return want


## Fill the magazine in one motion, the reference's all-or-nothing reload.
##
## On a worn feed the motion does not always finish the job: up to `short` of the
## capacity fails to seat, uniformly, so the same gun gives you a different count
## each time and you cannot plan around it. The rounds that did not seat are not
## consumed — they are still in the pouch, and topping up again may seat them.
func fill() -> int:
	var moved: int = load_rounds(_capacity)
	if _short <= 0.0 or _capacity <= 1 or moved <= 0:
		return moved
	var worst: int = int(floor(_short * float(_capacity)))
	if worst <= 0:
		return moved
	var missing: int = mini(_rand.next_int(0, worst), _loaded - 1)
	if missing <= 0:
		return moved
	_loaded -= missing
	if not _infinite:
		_reserve = mini(_reserve + missing, _reserve_capacity)
	ammo_changed.emit(_loaded, reserve())
	short_loaded.emit(missing)
	return moved - missing


## Top the pouch back up — pickups, a bench visit, an AI respawn.
func refill_reserve() -> void:
	if _infinite:
		return
	_reserve = _reserve_capacity
	ammo_changed.emit(_loaded, _reserve)


## Put the weapon back to its carried state without rebuilding anything. A carried
## gun is always properly loaded; short-loading is something the reload does.
func reset() -> void:
	_loaded = _capacity
	_reserve = _reserve_capacity
	ammo_changed.emit(_loaded, reserve())
