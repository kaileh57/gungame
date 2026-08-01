class_name PlayerMantle
extends Resource
## The vault arc: finding a ledge in front of you, and the two-curve motion that gets you
## onto it — or, when `vault` says the thing is a rail rather than a roof, over it.
##
## The shape of the move is the whole point. The vertical curve finishes at 62 % of the
## duration with a `pow(k, 0.62)` ease-out; the horizontal does not start until 30 % and
## then eases in with `pow(k, 1.35)`. That overlap is what makes it read as "up and over"
## instead of a diagonal slide toward the ledge. Both curves and every constant here are
## the reference's.
##
## The arc is driven by writing the body's position directly, with no collision — that is
## what makes it smooth, and it is also what makes clipping a real risk. See `_kx_cap`.
##
## `plan()` only decides; it never moves anything. The controller owns the body.

## Forward distances probed for a ledge, near to far. Four probes covers a hand rail, a
## crate, a window sill and a container edge without ever needing a fifth.
const PROBE_DISTANCES: PackedFloat32Array = [0.42, 0.66, 0.92, 1.18]
## Bisection steps used to locate the obstacle's near face. Five puts the answer within
## 13 mm of the truth over the widest probe gap, which is finer than the skin width.
const FACE_BISECTIONS: int = 5

@export_group("Reach")
## A ledge must be at least this far above the feet, else it is a step and the stair code
## in the controller already handled it without a cutscene.
@export_range(0.02, 1.0, 0.01) var min_rise: float = 0.18
## How far past the probe point the landing is pushed, so you end up standing on the
## ledge rather than balanced on its lip.
@export_range(0.05, 1.0, 0.01) var landing_push: float = 0.30
## Vertical clearance above the landing point, metres. Crouch height plus a little: the
## stance logic keeps you ducked when you arrive somewhere tight. The controller
## overwrites this from its own crouch height on ready.
@export_range(0.5, 2.2, 0.01) var clear_height: float = 1.18
## Radius used for the landing head-room test. Overwritten by the controller.
@export_range(0.1, 1.0, 0.01) var clear_radius: float = 0.3128
## Step height, only used to tell a ramp from a ledge. Overwritten by the controller.
@export_range(0.0, 1.5, 0.01) var step_height: float = 0.58
## Below this rise-over-run the candidate might just be ground sloping up, and the ramp
## test gets a say. Above it, nothing walkable is that steep.
@export_range(0.2, 4.0, 0.01) var ramp_ratio: float = 1.15

@export_group("Timing")
## Base duration of the arc, before the per-metre term.
@export_range(0.05, 1.0, 0.005) var duration_base: float = 0.19
## Seconds added per metre of rise.
@export_range(0.0, 1.0, 0.005) var duration_per_metre: float = 0.115
@export_range(0.05, 1.0, 0.005) var duration_min: float = 0.20
@export_range(0.1, 2.0, 0.005) var duration_max: float = 0.42
## Fraction of the duration at which the vertical is complete. Everything after this is
## purely horizontal.
@export_range(0.2, 1.0, 0.01) var vertical_done: float = 0.62
## Ease exponent on the vertical. Below 1 it is an ease-OUT: fast off the ground.
@export_range(0.1, 3.0, 0.01) var vertical_ease: float = 0.62
## Fraction of the duration at which the horizontal starts. The gap between this and
## `vertical_done` is the overlap that makes the move read as one gesture.
@export_range(0.0, 1.0, 0.01) var horizontal_start: float = 0.30
## Ease exponent on the horizontal. Above 1 it is an ease-IN: you drift over the lip.
@export_range(0.1, 3.0, 0.01) var horizontal_ease: float = 1.35

@export_group("Exit")
## Speed carried through the arc is capped here before being scaled on exit.
@export_range(0.0, 20.0, 0.05) var carry_cap: float = 7.5
## Fraction of the carried speed a climb-on leaves with.
@export_range(0.0, 1.5, 0.01) var exit_speed_scale: float = 0.62
## Floor on the exit speed of a climb-on, so you always end up standing on the ledge
## rather than teetering on its edge.
@export_range(0.0, 10.0, 0.05) var min_exit_speed: float = 2.4

@export_group("Clearance")
## Added to `clear_radius` to get the body radius used for the anti-clip cap. The
## controller's head-room radius is 0.92 of the real one; this puts it back.
@export_range(0.0, 0.2, 0.001) var lip_margin: float = 0.03

@export_group("Hurdle")
## Decides whether a ledge is climbed onto or hurdled. Clear it to disable hurdling.
@export var vault: PlayerVault = PlayerVault.new()

## True while an arc is running.
var active: bool = false
## Height gained by the arc in progress, metres. Drives the audio and the camera dip.
var rise: float = 0.0
## Planar speed the body had when the arc started, capped at `carry_cap`.
var carried_speed: float = 0.0
## True when the arc in progress goes OVER the obstacle rather than onto it.
var is_hurdle: bool = false

var _from: Vector3 = Vector3.ZERO
var _to: Vector3 = Vector3.ZERO
var _duration: float = 0.25
var _elapsed: float = 0.0
## Highest fraction of the horizontal travel that may be spent before the vertical is
## complete. See `_arm`.
var _kx_cap: float = 1.0


## Look for a ledge ahead of `feet` and, if one is found, arm the arc. `max_rise` is 1.32
## for the automatic vault you get by running into a wall, 2.05 when you asked for it
## with the jump key. Returns true when an arc was armed.
func plan(probe: PlayerProbe, feet: Vector3, yaw: float, max_rise: float, speed: float) -> bool:
	if active or not probe.is_bound():
		return false
	var fx: float = -sin(yaw)
	var fz: float = -cos(yaw)
	var prev_d: float = 0.0
	for d: float in PROBE_DISTANCES:
		var px: float = feet.x + fx * d
		var pz: float = feet.z + fz * d
		var top: float = probe.top_at(px, pz, feet.y + min_rise, feet.y + max_rise)
		if is_nan(top):
			prev_d = d
			continue
		if (
			(top - feet.y) / d < ramp_ratio
			and probe.is_walkable_ramp(feet, px, pz, top, step_height)
		):
			prev_d = d
			continue
		var face: float = _near_face(probe, feet, fx, fz, prev_d, d, top)
		if (
			vault != null
			and vault.plan_over(
				probe,
				feet,
				Vector2(fx, fz),
				Vector3(px, top, pz),
				d,
				speed,
				clear_height,
				clear_radius
			)
		):
			_arm(feet, vault.landing, face, speed, true)
			return true
		var lx: float = px + fx * landing_push
		var lz: float = pz + fz * landing_push
		if not probe.can_stand(Vector3(lx, top + 0.05, lz), clear_height, clear_radius):
			prev_d = d
			continue
		_arm(feet, Vector3(lx, top + 0.02, lz), face, speed, false)
		return true
	return false


## Distance from the feet to the obstacle's near face along (fx, fz).
##
## The probe that found the ledge hit its TOP, somewhere past the face; the arc has to
## know where the face is or it cannot know when it is safe to move forward. Bisect
## between the last distance that found nothing and the one that did, and return the
## far end of the still-clear interval — an underestimate, which is the safe direction.
func _near_face(
	probe: PlayerProbe, feet: Vector3, fx: float, fz: float, lo: float, hi: float, top: float
) -> float:
	var clear: float = lo
	var solid: float = hi
	for _i: int in FACE_BISECTIONS:
		var mid: float = (clear + solid) * 0.5
		var t: float = probe.top_at(feet.x + fx * mid, feet.z + fz * mid, feet.y + 0.02, top + 0.05)
		if is_nan(t):
			clear = mid
		else:
			solid = mid
	return clear


## Advance the arc and return where the feet should be this tick. When the arc finishes,
## `active` goes false and the controller applies the exit velocity.
func advance(dt: float) -> Vector3:
	_elapsed += dt
	var k: float = clampf(_elapsed / _duration, 0.0, 1.0)
	if k >= 1.0:
		active = false
		return _to
	var ky: float = 1.0
	var kx: float = 0.0
	if k < vertical_done:
		ky = pow(k / vertical_done, vertical_ease)
	if k > horizontal_start:
		kx = pow((k - horizontal_start) / (1.0 - horizontal_start), horizontal_ease)
		# Hold at the lip until the feet are above it. Without this the body's leading
		# edge crosses the near face while the arc is still four fifths of the way up,
		# and on the two closest probe distances that is a visible corner clip.
		if k < vertical_done:
			kx = minf(kx, _kx_cap)
	return Vector3(lerpf(_from.x, _to.x, kx), lerpf(_from.y, _to.y, ky), lerpf(_from.z, _to.z, kx))


## Forward speed to leave the arc with. A climb-on sheds most of it; a hurdle keeps it.
func exit_speed() -> float:
	if is_hurdle and vault != null:
		return vault.exit_speed(carried_speed)
	return maxf(min_exit_speed, carried_speed * exit_speed_scale)


## Where the arc ends up. Read by the camera and the landing audio, which want to know
## where you are going before you get there.
func target() -> Vector3:
	return _to


func cancel() -> void:
	active = false


func _arm(feet: Vector3, to: Vector3, face_distance: float, speed: float, hurdle: bool) -> void:
	rise = to.y - feet.y
	carried_speed = minf(speed, carry_cap)
	is_hurdle = hurdle
	_from = feet
	_to = to
	_duration = clampf(duration_base + rise * duration_per_metre, duration_min, duration_max)
	if hurdle and vault != null:
		_duration *= vault.duration_scale
	_elapsed = 0.0
	# The body is a cylinder of this radius and the obstacle's near face is
	# `face_distance` ahead. The centre may advance to within one radius of that face and
	# no further while the feet are still below the top, so cap the horizontal fraction.
	var travel: float = Vector2(to.x - feet.x, to.z - feet.z).length()
	if travel > 1e-5:
		_kx_cap = clampf((face_distance - (clear_radius + lip_margin)) / travel, 0.0, 1.0)
	else:
		_kx_cap = 0.0
	active = true
