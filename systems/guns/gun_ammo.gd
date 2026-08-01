class_name GunAmmo
extends RefCounted
## Rounds in the gun and rounds in the pouch.
##
## The reference keeps reserve ammo infinite and refills the magazine to `cap` in
## one go (range spec 12.5). That is the default here — `infinite_reserve` on. Turn
## it off and the same object does real accounting: a reload moves at most
## `capacity - loaded` rounds out of the reserve, and a partial reload leaves a
## partial magazine.
##
## Nothing in here touches time. `GunReload` decides when rounds move; this decides
## how many there are to move.

signal ammo_changed(loaded: int, reserve: int)
## The magazine went dry. Fire control listens and starts a reload.
signal emptied

var _capacity: int = 1
var _loaded: int = 0
var _reserve: int = 0
var _reserve_capacity: int = 0
var _infinite: bool = true


## Size the magazine from a rolled weapon. `reserve_mags` is how many spare
## magazines the carrier starts with when the reserve is finite.
func configure(spec: GunSpec, infinite_reserve: bool, reserve_mags: int) -> void:
	_capacity = maxi(1, spec.magazine)
	_infinite = infinite_reserve
	_reserve_capacity = _capacity * maxi(0, reserve_mags)
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


## True when a reload would actually change anything.
func can_reload() -> bool:
	if is_full():
		return false
	return _infinite or _reserve > 0


## Take one round for a shot. Returns false when the magazine was already dry, in
## which case nothing was consumed and the caller should click on an empty chamber.
func consume() -> bool:
	if _loaded <= 0:
		return false
	_loaded -= 1
	ammo_changed.emit(_loaded, reserve())
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
func fill() -> int:
	return load_rounds(_capacity)


## Top the pouch back up — pickups, a bench visit, an AI respawn.
func refill_reserve() -> void:
	if _infinite:
		return
	_reserve = _reserve_capacity
	ammo_changed.emit(_loaded, _reserve)


## Put the weapon back to its carried state without rebuilding anything.
func reset() -> void:
	_loaded = _capacity
	_reserve = _reserve_capacity
	ammo_changed.emit(_loaded, reserve())
