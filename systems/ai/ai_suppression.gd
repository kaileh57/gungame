class_name AISuppression
extends Resource
## Being shot at, and shooting at something to keep it down. One instance per
## agent, duplicated off a species template so every knob below is an inspector
## knob rather than a magic number buried in a behaviour.
##
## Suppression is the only mechanism in the module that lets fire matter when it
## misses. A round that passes inside `crack_radius` of a body raises that body's
## suppression; suppression widens its cone, and past the species' tolerance it
## stops shooting altogether and goes looking for something solid. That single
## loop is what turns a firefight into a firefight rather than two turrets
## trading hitscans until one falls over.
##
## The decay has a delay on it, which matters more than the rate does. Without it
## an agent recovers between the rounds of an incoming burst and is never pinned
## by anything; with it, sustained fire pins and a single shot does not.
##
## The outgoing half is the same idea from the other end: a bounded burst at a
## remembered position, on a cooldown, refusing to spend the last third of a
## magazine on it. An agent that suppresses until it is dry has suppressed itself.

@export_group("Incoming")
## Metres. A round passing further than this from the body is not noticed at all.
@export_range(0.2, 12.0, 0.05) var crack_radius: float = 2.4
## Miss distance below which the pass is worth full severity — near enough that a
## few more centimetres would have been a hit.
@export_range(0.0, 3.0, 0.01) var full_severity_radius: float = 0.35
## Shape of the falloff between the two radii. Above 1 the outer metre is cheap.
@export_range(0.5, 4.0, 0.05) var falloff_exponent: float = 1.6
## What one round at full severity is worth. Deliberately a fraction: measured
## against the harness, a scale of 1 lets a single round pin a body outright and
## the fight becomes whoever shot first. At 0.22 it takes three or four rounds in
## quick succession, which is what pinning should cost.
@export_range(0.02, 1.0, 0.01) var severity_scale: float = 0.22
## Multiplier on everything incoming. Species scale: machines barely notice.
@export_range(0.0, 4.0, 0.01) var gain: float = 1.0
## Hard cap. Above 1.0 so that heavy fire keeps a body down through the delay.
@export_range(0.2, 3.0, 0.01) var ceiling: float = 1.4
## Suppression bled off per second, once the delay has elapsed.
@export_range(0.01, 2.0, 0.01) var decay_per_second: float = 0.34
## Seconds of nothing landing nearby before recovery starts. This is what makes
## sustained fire pin and a single round not.
@export_range(0.0, 3.0, 0.01) var decay_delay: float = 0.45
## Extra cone multiplier at full suppression: 1.6 means the cone is 2.6x as wide.
@export_range(0.0, 4.0, 0.05) var spread_at_max: float = 1.6
## How fast the remembered threat direction swings toward the newest round.
@export_range(0.02, 1.0, 0.01) var direction_blend: float = 0.35

@export_group("Outgoing")
## Seconds a deliberate suppressing burst lasts once started.
@export_range(0.2, 8.0, 0.05) var burst_seconds: float = 1.6
## Seconds before the agent may start another one.
@export_range(0.1, 12.0, 0.05) var cooldown_seconds: float = 2.4
## Fraction of the magazine held back. An agent that suppresses itself dry has
## achieved nothing.
@export_range(0.0, 0.9, 0.01) var ammo_floor: float = 0.35
## Cone multiplier while suppressing. Deliberately wide: the point is the noise
## and the area, not the hit.
@export_range(1.0, 6.0, 0.05) var suppressive_spread_multiplier: float = 2.4
## Fraction of weapon range beyond which suppressing is just littering.
@export_range(0.2, 2.0, 0.01) var max_range_fraction: float = 1.15
## Confidence in the remembered position below which there is nothing to shoot at.
@export_range(0.0, 1.0, 0.01) var min_confidence: float = 0.25

## 0 to `ceiling`. Read by the cone, the posture and the debug overlay.
var level: float = 0.0
## Directions this body has been shot from, blended into one. Used to choose
## which way to hide, so it is kept even when the level has decayed to zero.
var direction: Vector3 = Vector3.ZERO

var _quiet: float = 0.0
var _burst_left: float = 0.0
var _cooldown: float = 0.0


## Advance both clocks. Called once per agent tick with that agent's delta.
func advance(delta: float) -> void:
	_quiet += delta
	if _quiet >= decay_delay:
		level = maxf(level - decay_per_second * delta, 0.0)
	_burst_left = maxf(_burst_left - delta, 0.0)
	_cooldown = maxf(_cooldown - delta, 0.0)


## Add `severity` (0-1) of suppression from a threat lying in `from_direction`,
## which must be a unit vector pointing from the body toward the shooter. Passing
## a zero vector leaves the remembered direction alone, which is correct for a
## blast the body cannot place.
func apply(severity: float, from_direction: Vector3 = Vector3.ZERO) -> void:
	if severity <= 0.0:
		return
	level = clampf(level + severity * severity_scale * gain, 0.0, ceiling)
	_quiet = 0.0
	if from_direction.length_squared() > 1e-6:
		var blend: float = clampf(direction_blend * severity * 2.0, 0.0, 1.0)
		direction = direction.lerp(from_direction.normalized(), blend)
		if direction.length_squared() > 1e-6:
			direction = direction.normalized()


## Score a round that travelled `travel` metres from `origin` along `dir` against
## a body of radius `radius` centred on `point`, and apply whatever it is worth.
## Returns the severity so a caller can decide whether it was worth reacting to.
func register_shot(
	origin: Vector3, dir: Vector3, travel: float, point: Vector3, radius: float
) -> float:
	var miss: float = miss_distance(origin, dir, travel, point)
	var severity: float = severity_for(miss, radius)
	if severity > 0.0:
		apply(severity, (origin - point).normalized())
	return severity


## Closest approach of the shot segment to `point`, in metres. Exact and
## allocation-free; this runs once per agent per round fired in the scene.
static func miss_distance(origin: Vector3, dir: Vector3, travel: float, point: Vector3) -> float:
	var rel: Vector3 = point - origin
	var along: float = clampf(rel.dot(dir), 0.0, travel)
	return (rel - dir * along).length()


## Severity of a pass at `miss` metres against a silhouette of `radius`. One at
## the silhouette, zero at `crack_radius`, curved in between.
func severity_for(miss: float, radius: float) -> float:
	var inner: float = radius + full_severity_radius
	var outer: float = maxf(crack_radius, inner + 0.05)
	if miss <= inner:
		return 1.0
	if miss >= outer:
		return 0.0
	return pow(1.0 - (miss - inner) / (outer - inner), falloff_exponent)


## Level as a 0-1 fraction of the ceiling.
func normalized() -> float:
	return level / maxf(ceiling, 0.01)


## Multiplier the aiming cone should be scaled by right now.
func spread_multiplier() -> float:
	return 1.0 + level * spread_at_max


## Past this the agent stops shooting and wants something solid in front of it.
## `tolerance` is the species' own — a machine will sit in fire that routs a dog.
func is_pinned(tolerance: float) -> bool:
	return level >= tolerance


## Approaching pinned. The cue to start moving to cover, before it is too late to.
func is_pressured(tolerance: float) -> bool:
	return level >= tolerance * 0.8


## Unit vector pointing at where the fire is coming from, or zero if nothing has
## been fired at this body yet.
func threat_direction() -> Vector3:
	return direction


## Ask to start a deliberate suppressing burst at a remembered position. Returns
## true once, at the start of the burst; `is_suppressing()` reports the rest.
func request(dist: float, weapon_range: float, ammo: int, magazine: int, confidence: float) -> bool:
	if _burst_left > 0.0 or _cooldown > 0.0:
		return false
	if confidence < min_confidence or dist > weapon_range * max_range_fraction:
		return false
	if float(ammo) <= float(magazine) * ammo_floor:
		return false
	_burst_left = burst_seconds
	_cooldown = burst_seconds + cooldown_seconds
	return true


func is_suppressing() -> bool:
	return _burst_left > 0.0


## Cut a burst short — the target reappeared, or the squad moved onto it.
func stop_suppressing() -> void:
	_burst_left = 0.0


func reset() -> void:
	level = 0.0
	direction = Vector3.ZERO
	_quiet = decay_delay
	_burst_left = 0.0
	_cooldown = 0.0
