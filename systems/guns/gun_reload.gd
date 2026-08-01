class_name GunReload
extends Resource
## Getting rounds into the chamber: the reload, and the manual action cycle.
##
## Range spec 4.6 derives the reload time from the feed, and 12.5 makes it
## all-or-nothing — the magazine is refilled at completion, not incrementally. That
## is what a box, cylinder or breech reload does here.
##
## A tube is different, because a tube reload *is* a sequence of individual rounds:
## the reference's own formula for it is `0.42 * capacity + 0.70`, a per-shell cost
## plus a fixed cost to get the gate open. So a tube feeds one shell at a time, can
## be broken off the moment a target appears, and keeps whatever it managed to load.
##
## The manual action cycle — working a bolt, racking a pump, breaking a break-action
## open — is the same machinery: a timed window between the shot and the next round
## being ready. The reference expresses it as the fire interval; naming it lets the
## viewmodel and the audio know what the gun is doing.

## The reload finished or was broken off. `loaded` is how many rounds went in.
signal reload_finished(loaded: int)
## One shell went into a tube. Fires per round, not per reload.
signal round_loaded(loaded: int)
## The bolt or pump came back forward and the gun is ready again.
signal cycle_finished

enum Stage { IDLE, RELOADING, CYCLING }

## Feeds that load one round at a time instead of all at once.
const STAGED_FEEDS: Array[StringName] = [&"tube"]

## Share of a tube reload spent getting to the loading gate before the first shell.
@export_range(0.0, 0.6, 0.01) var tube_start_fraction: float = 0.18
## Global multiplier on every reload time, for tuning the whole game at once.
@export_range(0.2, 3.0, 0.01) var reload_time_scale: float = 1.0
## Manual action cycle length as a share of the fire interval. 1.0 makes a bolt gun
## cycle in exactly the time its 42 rpm implies.
@export_range(0.1, 1.0, 0.01) var cycle_fraction: float = 1.0
## Actions that must be worked by hand between shots.
@export var manual_cycle_actions: Array[StringName] = [&"bolt", &"pump", &"break"]

var _stage: int = Stage.IDLE
var _timer: float = 0.0
var _duration: float = 0.0
var _shell_time: float = 0.0
var _loaded_this_reload: int = 0
var _staged: bool = false
var _reload_time: float = 1.0
var _cycle_time: float = 0.0


func _init() -> void:
	resource_local_to_scene = true


func configure(spec: GunSpec, action: StringName) -> void:
	_reload_time = maxf(spec.reload_time, 0.05) * reload_time_scale
	_staged = STAGED_FEEDS.has(spec.feed)
	var interval: float = 60.0 / maxf(float(spec.rpm), 1.0)
	_cycle_time = interval * cycle_fraction if manual_cycle_actions.has(action) else 0.0
	var cap: float = maxf(float(spec.magazine), 1.0)
	_shell_time = _reload_time * (1.0 - tube_start_fraction) / cap
	_stage = Stage.IDLE
	_timer = 0.0
	_duration = 0.0
	_loaded_this_reload = 0


func stage() -> int:
	return _stage


func is_reloading() -> bool:
	return _stage == Stage.RELOADING


func is_cycling() -> bool:
	return _stage == Stage.CYCLING


func is_busy() -> bool:
	return _stage != Stage.IDLE


## True when a tube is mid-reload and can be broken off to take a shot.
func is_interruptible() -> bool:
	return _staged and _stage == Stage.RELOADING


## 0..1 through whatever the action is currently doing.
func progress() -> float:
	if _duration <= 0.0:
		return 0.0
	return clampf(1.0 - _timer / _duration, 0.0, 1.0)


## Seconds a full reload from empty would take. For the stat card and the AI.
func full_duration() -> float:
	return _reload_time


## Seconds the reload of `ammo` will actually take from here. Identical to
## `full_duration()` for anything that swaps a magazine, and shorter for a tube
## with rounds still in it — which is the whole reason a tube gun is worth topping
## up between contacts. The audio and the viewmodel both need the real number:
## a reload arc timed to the from-empty figure would still be playing after the
## gun was loaded.
func expected_duration(ammo: GunAmmo) -> float:
	if not _staged:
		return _reload_time
	var missing: int = maxi(ammo.capacity() - ammo.loaded(), 0)
	var shells: int = missing if ammo.reserve() < 0 else mini(missing, ammo.reserve())
	return _reload_time * tube_start_fraction + float(shells) * _shell_time


func cycle_duration() -> float:
	return _cycle_time


## Start a reload. Returns false when the gun is busy or there is nothing to load.
func begin(ammo: GunAmmo) -> bool:
	if _stage != Stage.IDLE or not ammo.can_reload():
		return false
	_loaded_this_reload = 0
	_stage = Stage.RELOADING
	_duration = _reload_time * tube_start_fraction if _staged else _reload_time
	_timer = _duration
	return true


## Start the manual action cycle after a shot. Returns false for self-loading guns.
func begin_cycle() -> bool:
	if _cycle_time <= 0.0 or _stage != Stage.IDLE:
		return false
	_stage = Stage.CYCLING
	_duration = _cycle_time
	_timer = _duration
	return true


## Break off a running reload, keeping whatever a tube already loaded. A cycle in
## progress is not interruptible — the bolt is already moving.
func interrupt() -> bool:
	if _stage != Stage.RELOADING:
		return false
	_stage = Stage.IDLE
	_timer = 0.0
	_duration = 0.0
	reload_finished.emit(_loaded_this_reload)
	return true


## Advance the action. Returns true when something completed on this tick.
func tick(delta: float, ammo: GunAmmo) -> bool:
	if _stage == Stage.IDLE:
		return false
	_timer -= delta
	if _timer > 0.0:
		return false
	if _stage == Stage.CYCLING:
		_stage = Stage.IDLE
		_duration = 0.0
		cycle_finished.emit()
		return true
	return _advance_reload(ammo)


func reset() -> void:
	_stage = Stage.IDLE
	_timer = 0.0
	_duration = 0.0
	_loaded_this_reload = 0


## A reload stage elapsed: either the whole magazine goes in, or one more shell does
## and the timer restarts for the next.
func _advance_reload(ammo: GunAmmo) -> bool:
	if not _staged:
		_loaded_this_reload = ammo.fill()
		_stage = Stage.IDLE
		_duration = 0.0
		reload_finished.emit(_loaded_this_reload)
		return true
	var moved: int = ammo.load_rounds(1)
	_loaded_this_reload += moved
	if moved > 0:
		round_loaded.emit(_loaded_this_reload)
	if moved <= 0 or not ammo.can_reload():
		_stage = Stage.IDLE
		_duration = 0.0
		reload_finished.emit(_loaded_this_reload)
		return true
	_duration = _shell_time
	_timer += _shell_time
	return false
