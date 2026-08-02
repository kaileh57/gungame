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
##
## `GunGrading.reload_profile()` decides how much of a chore all of that is. Reload
## time and cycle time both scale with workmanship — a rough bolt is genuinely slow
## to work, and a Gunsmithed one is quick — and a badly-handling weapon can be
## FUMBLED outright: the magazine goes in the dirt, the full reload time is spent,
## and nothing was loaded. Fumbling is the single thing that makes a Hazard's
## reload frightening rather than merely long, and it disappears almost entirely by
## Field-Grade.

## The reload finished or was broken off. `loaded` is how many rounds went in.
signal reload_finished(loaded: int)
## The reload was dropped. Fires alongside `reload_finished(0)`, and for a tube
## once per dropped shell.
signal fumbled
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
## Ceiling on how much a weapon's grading may stretch its reload. Past this a bad
## gun stops being a bad gun and starts being a cutscene.
@export_range(1.0, 4.0, 0.05) var grading_time_ceiling: float = 2.10
## Ceiling on how much a weapon's grading may stretch a manual action cycle.
@export_range(1.0, 4.0, 0.05) var grading_cycle_ceiling: float = 1.85
## Actions that must be worked by hand between shots.
@export var manual_cycle_actions: Array[StringName] = [&"bolt", &"pump", &"break"]
## Let a rolled weapon's grading tilt this resource at all. Off restores the
## reference's timings for a test rig that wants its numbers.
@export var use_grading: bool = true
## How much of the weapon's named character reaches the reload. 0 leaves the
## smooth tier ladder alone and a "sticky bolt" becomes a word again; 1 is the
## shipped weight; 2 makes a fault the defining thing about the gun.
@export_range(0.0, 2.0, 0.05) var quirk_strength: float = 1.0
## How much of it reaches the magazine `GunAmmo` is filling from. Separate from
## the timing dial because a test rig that wants honest reload times still wants
## an honest count of what went in.
@export_range(0.0, 2.0, 0.05) var feed_quirk_strength: float = 1.0

var _stage: int = Stage.IDLE
var _timer: float = 0.0
var _duration: float = 0.0
var _shell_time: float = 0.0
var _loaded_this_reload: int = 0
var _staged: bool = false
var _reload_time: float = 1.0
var _cycle_time: float = 0.0
var _fumble: float = 0.0
var _fumbled: bool = false
var _rand: XorShift32 = XorShift32.new(1)


func _init() -> void:
	resource_local_to_scene = true


func configure(spec: GunSpec, action: StringName) -> void:
	var time_tilt: float = 1.0
	var cycle_tilt: float = 1.0
	var shell_tilt: float = 1.0
	_fumble = 0.0
	_rand = XorShift32.new(maxi(spec.cfg, 1))
	if use_grading:
		GunGrading.ensure(spec)
		var p: Dictionary = GunGrading.reload_profile(spec, quirk_strength)
		time_tilt = clampf(float(p[&"time_scale"]), 0.35, grading_time_ceiling)
		cycle_tilt = clampf(float(p[&"cycle_scale"]), 0.35, grading_cycle_ceiling)
		_fumble = clampf(float(p[&"fumble"]), 0.0, 0.6)
		var feed: Dictionary = GunGrading.feed_profile(spec, feed_quirk_strength)
		shell_tilt = clampf(float(feed[&"shell_scale"]), 0.35, 2.4)
		_rand = GunGrading.stream(spec, GunGrading.RELOAD_SALT)
	_reload_time = maxf(spec.reload_time, 0.05) * reload_time_scale * time_tilt
	_staged = STAGED_FEEDS.has(spec.feed)
	var interval: float = 60.0 / maxf(float(spec.rpm), 1.0)
	_cycle_time = (
		interval * cycle_fraction * cycle_tilt if manual_cycle_actions.has(action) else 0.0
	)
	var cap: float = maxf(float(spec.magazine), 1.0)
	_shell_time = _reload_time * (1.0 - tube_start_fraction) / cap * shell_tilt
	_stage = Stage.IDLE
	_timer = 0.0
	_duration = 0.0
	_loaded_this_reload = 0
	_fumbled = false


func stage() -> int:
	return _stage


func is_reloading() -> bool:
	return _stage == Stage.RELOADING


func is_cycling() -> bool:
	return _stage == Stage.CYCLING


func is_busy() -> bool:
	return _stage != Stage.IDLE


## Chance a reload of this weapon goes on the ground. For the stat card and the AI.
func fumble_chance() -> float:
	return _fumble


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
##
## The fumble is rolled HERE, not at completion, so a weapon that is going to drop
## its magazine has already decided before the animation plays. Nothing about the
## outcome depends on what the player does during the reload, which is what keeps
## it a property of the gun rather than a random tax on the moment.
func begin(ammo: GunAmmo) -> bool:
	if _stage != Stage.IDLE or not ammo.can_reload():
		return false
	_loaded_this_reload = 0
	_stage = Stage.RELOADING
	_fumbled = not _staged and _fumble > 0.0 and _rand.next() < _fumble
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
	_fumbled = false
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
	_fumbled = false


## A reload stage elapsed: either the whole magazine goes in, or one more shell does
## and the timer restarts for the next.
func _advance_reload(ammo: GunAmmo) -> bool:
	if not _staged:
		return _finish_magazine(ammo)
	if _fumble > 0.0 and _rand.next() < _fumble:
		# The shell went past the gate and onto the floor. It cost its own time and
		# loaded nothing; the reload carries on from where it was.
		fumbled.emit()
		_duration = _shell_time
		_timer += _shell_time
		return false
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


## The magazine-swap ending. A fumbled swap spent the whole reload and loaded
## nothing — the gun is exactly as empty as it was and the clock is gone.
func _finish_magazine(ammo: GunAmmo) -> bool:
	_loaded_this_reload = 0 if _fumbled else ammo.fill()
	var dropped: bool = _fumbled
	_fumbled = false
	_stage = Stage.IDLE
	_duration = 0.0
	if dropped:
		fumbled.emit()
	reload_finished.emit(_loaded_this_reload)
	return true
