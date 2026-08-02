class_name GunSpread
extends Resource
## The cone the gun is actually shooting into, and where inside it each pellet goes.
##
## Range spec 12.1. The rolled `GunSpec.spread_rad` is the gun standing still on a
## bench; everything that happens to it after that lives here — shouldering steadies
## it, moving opens it, being airborne wrecks it, and every shot blooms it a little
## wider before it recovers.
##
## How MUCH of that a weapon suffers is its grading. `GunGrading.spread_profile()`
## supplies five tilts, and between them they are most of what separates a Scrap
## gun from a Gunsmithed one in the hand:
##
##   bloom_scale    a rough gun opens up faster per shot
##   ceiling_scale  and keeps opening further before it stops
##   settle         and takes longer to come back down
##   sight          and its sights are bent, so shouldering buys less
##   relief         and shouldering absorbs less of the bloom while it fires
##   floor          and it never quite returns to its own bench group at all
##
## That last one is the one you feel between shots rather than during a burst: a
## Hazard's first cold shot and its tenth are not the same shot, and it never gets
## the first one back.
##
## `effective()` returns the **full** cone angle in radians. `sample()` wants the
## half-angle, so callers pass `effective() * 0.5`. Getting that wrong doubles every
## group in the game, which is why the two are named differently.

## Cone multiplier at full ADS with a fitted optic. Shouldering a scoped gun steadies
## it more than shouldering an iron-sighted one because your cheek has somewhere to go.
@export_range(0.05, 1.0, 0.01) var ads_scale_optic: float = 0.34
## Cone multiplier at full ADS on irons.
@export_range(0.05, 1.0, 0.01) var ads_scale_irons: float = 0.56
## Speed, m/s, at which the movement penalty reaches its knee.
@export_range(1.0, 20.0, 0.1) var move_reference_speed: float = 6.5
## How far past the knee the penalty keeps growing. 1.4 lets a sprint reach 4.72x.
@export_range(1.0, 3.0, 0.05) var move_ceiling: float = 1.4
## Quadratic weight on movement. The whole penalty is `1 + this * mv^2`.
@export_range(0.0, 6.0, 0.05) var move_weight: float = 1.9
## Flat cone penalty while both feet are off the ground.
@export_range(0.0, 6.0, 0.05) var airborne_penalty: float = 1.6
## Cone multiplier while crouched. Not in the reference, which has no crouch.
@export_range(0.25, 1.0, 0.01) var crouch_scale: float = 0.80
## Bloom added per shot: `base + kick_weight * kick/100`, before the semi and ADS trims.
@export_range(0.0, 2.0, 0.01) var bloom_base: float = 0.30
@export_range(0.0, 4.0, 0.01) var bloom_kick_weight: float = 1.15
## Bloom from a single-shot action, as a fraction of the full-auto figure.
@export_range(0.1, 1.0, 0.01) var bloom_semi_scale: float = 0.72
## How much of the bloom shouldering absorbs, at full ADS.
@export_range(0.0, 1.0, 0.01) var bloom_ads_relief: float = 0.45
## Hard ceiling on accumulated bloom, in multiples of the base cone.
@export_range(0.5, 10.0, 0.1) var bloom_max: float = 3.4
## Ceiling on the ceiling, after a rough weapon's grading has widened it.
@export_range(1.0, 16.0, 0.1) var bloom_max_limit: float = 7.5
## Fraction of the bloom left after one second. 0.055 is a fast, forgiving recovery.
@export_range(0.001, 0.9, 0.001) var bloom_retained_per_second: float = 0.055
## Below this the bloom is snapped to its floor so it stops costing a multiply.
@export_range(0.0, 0.05, 0.0001) var bloom_epsilon: float = 0.002
## Let a rolled weapon's grading tilt this resource at all. Off restores the
## reference's behaviour for a test rig that wants its numbers.
@export var use_grading: bool = true
## How much of the weapon's named character reaches the cone. 0 leaves the smooth
## tier ladder alone and a "loose optic" becomes a word again; 1 is the shipped
## weight; 2 makes a fault the defining thing about the gun.
@export_range(0.0, 2.0, 0.05) var quirk_strength: float = 1.0

## Accumulated per-shot bloom, in multiples of the base cone. Runtime state.
var bloom: float = 0.0

var _base_rad: float = 0.0
var _has_optic: bool = false
var _kick: float = 0.0
var _automatic: bool = false
var _bloom_scale: float = 1.0
var _ceiling: float = 3.4
var _settle: float = 1.0
var _sight: float = 1.0
var _relief: float = 1.0
var _floor: float = 0.0


func _init() -> void:
	resource_local_to_scene = true


func configure(spec: GunSpec) -> void:
	_base_rad = maxf(spec.spread_rad, 0.0)
	_has_optic = spec.has_optic
	_kick = clampf(spec.kick / 100.0, 0.0, 2.0)
	_automatic = spec.automatic
	_bloom_scale = 1.0
	_ceiling = bloom_max
	_settle = 1.0
	_sight = 1.0
	_relief = 1.0
	_floor = 0.0
	if use_grading:
		GunGrading.ensure(spec)
		var p: Dictionary = GunGrading.spread_profile(spec, quirk_strength)
		_bloom_scale = float(p[&"bloom_scale"])
		_ceiling = minf(bloom_max * float(p[&"ceiling_scale"]), bloom_max_limit)
		_settle = maxf(float(p[&"settle"]), 0.05)
		_sight = clampf(float(p[&"sight"]), 0.0, 1.0)
		_relief = clampf(float(p[&"relief"]), 0.0, 2.0)
		_floor = clampf(float(p[&"floor"]), 0.0, _ceiling)
	bloom = _floor


## Base cone with nothing happening to it, radians, full angle.
func base_radians() -> float:
	return _base_rad


## Residual bloom this weapon can never decay through, in multiples of the base
## cone. Zero on anything Field-Grade or better.
func bloom_floor() -> float:
	return _floor


## The full cone angle, radians, for a shooter in the given stance.
## `ads` is 0..1 shoulder blend, `speed` is horizontal m/s.
##
## The sights are worth `_sight` of their nominal tightening: a Relic's optic
## delivers all of it, a Hazard's bent irons deliver about a third, and that is
## most of why shouldering a bad gun does not feel like it did anything.
func effective(ads: float, speed: float, on_ground: bool, crouched: bool) -> float:
	var nominal: float = ads_scale_optic if _has_optic else ads_scale_irons
	var tight: float = 1.0 - _sight * (1.0 - nominal)
	var ads_mul: float = 1.0 - clampf(ads, 0.0, 1.0) * (1.0 - tight)
	var mv: float = clampf(speed / maxf(move_reference_speed, 0.01), 0.0, move_ceiling)
	var move_mul: float = 1.0 + move_weight * mv * mv
	if not on_ground:
		move_mul += airborne_penalty
	if crouched and on_ground:
		move_mul *= crouch_scale
	return _base_rad * ads_mul * move_mul * (1.0 + bloom)


## Widen the cone for one shot fired. Call once per trigger event, not per pellet.
func add_shot(ads: float) -> void:
	var per_shot: float = (bloom_base + bloom_kick_weight * _kick) * _bloom_scale
	if not _automatic:
		per_shot *= bloom_semi_scale
	per_shot *= 1.0 - clampf(bloom_ads_relief * _relief, 0.0, 0.95) * clampf(ads, 0.0, 1.0)
	bloom = minf(bloom + per_shot, _ceiling)


## Force the bloom open, for the runaway-sear case that dumps a magazine.
func force_bloom(value: float) -> void:
	bloom = clampf(maxf(bloom, value), 0.0, _ceiling)


## Exponential recovery toward the weapon's own floor. Frame-rate independent by
## construction, and `_settle` above 1 on a well-made gun retains less per second
## than the resource's base rate rather than more.
func decay(delta: float) -> void:
	var excess: float = bloom - _floor
	if excess <= 0.0:
		return
	excess *= pow(pow(bloom_retained_per_second, _settle), delta)
	bloom = _floor + excess
	if excess < bloom_epsilon:
		bloom = _floor


func reset() -> void:
	bloom = _floor


## Pick a direction inside a cone of half-angle `half_rad` around `dir`.
## `sqrt(u)` gives a uniform areal distribution — without it every group would
## clump in the middle and the cone would read as far tighter than it is.
static func sample(dir: Vector3, half_rad: float, rand: XorShift32) -> Vector3:
	if half_rad <= 0.0:
		return dir
	var a: float = rand.next() * 6.2832
	var r: float = sqrt(rand.next()) * half_rad
	var t: Vector3 = Vector3.UP if absf(dir.y) < 0.9 else Vector3.RIGHT
	var u: Vector3 = dir.cross(t).normalized()
	var v: Vector3 = dir.cross(u).normalized()
	var tr: float = tan(r)
	return (dir + u * (tr * cos(a)) + v * (tr * sin(a))).normalized()
