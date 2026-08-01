class_name GunPose
extends RefCounted
## The solved resting pose of one weapon in a first-person hand: two positions, a
## rotation curve and a scale curve, plus the measurements that prove the shouldered
## end of it is right.
##
## Separated from the animation because it is pure. Nothing here reads a clock, a node
## or an input, so the whole thing can be built and interrogated headless — which is
## exactly what `res://tools/build_gun_cache.gd` does, over every weapon it caches.
##
## THE SIGHT-LINE SOLVE. The reference aims by shoving the weapon's bounding box onto
## the view axis: the top of the box goes to the crosshair and the box's own centre of
## width slides to the middle of the screen. That is a good trick and it is wrong for a
## gun wearing a scope, because the top of the box is the top of the tube and you end up
## looking over the optic instead of through it.
##
## Here the pose is solved from the real sight instead. At full ADS the holder's
## rotation is exactly `(0, π/2, 0)` — the gun's +X is the muzzle direction, so π/2 of
## yaw maps the bore onto camera −Z with no cheated tilt — and the translation is chosen
## to put `GunAttachPoints.sight` on the view axis:
##
##     holder.x = -sight.z * scale        holder.y = -sight.y * scale
##
## which drops out of the rotation: local `(x,y,z)` lands at `(z, y, -x) * scale`. The
## result is exact, not eyeballed: `sight_offset(1.0)` is zero to float precision and
## `bore_alignment(1.0)` is 1.0, and the gun cache bake asserts both over a sample of
## weapons rather than hoping somebody notices in play.

## Attach points the solve was built from. Check `valid` before trusting a pose.
var attach: GunAttachPoints = GunAttachPoints.new()
## Holder position at the hip, metres.
var hip: Vector3 = Vector3.ZERO
## Holder position shouldered, metres. Puts `attach.sight` on the view axis.
var ads: Vector3 = Vector3.ZERO
## Holder scale at the hip. Shouldered is this times `ads_scale`.
var base_scale: float = 0.043
var ads_scale: float = 1.5
## The lift applied inside the holder, in model units.
var lift: float = 0.30
var hip_pitch: float = 0.03
var hip_yaw_lead: float = 0.055
var hip_roll: float = 0.02
## True when the action is slow enough that working it is worth animating.
var slow_action: bool = false


## The whole resting transform at ADS amount `t`, with no sway, kick, reload or swap
## layered on. `t` of 1 is the pose the alignment assertions are made against.
func transform(t: float) -> Transform3D:
	var k: float = clampf(t, 0.0, 1.0)
	var s: float = uniform_scale(k)
	var basis := Basis.from_euler(rotation(k), EULER_ORDER_XYZ)
	return Transform3D(basis.scaled(Vector3(s, s, s)), hip.lerp(ads, k))


## Holder Euler angles at ADS amount `t`. At `t` of 1 this is exactly `(0, π/2, 0)`:
## the bore on the view axis, no cheated yaw, no muzzle dip.
func rotation(t: float) -> Vector3:
	var inv: float = 1.0 - clampf(t, 0.0, 1.0)
	return Vector3(hip_pitch * inv, PI * 0.5 - hip_yaw_lead * inv, hip_roll * inv)


func uniform_scale(t: float) -> float:
	return base_scale * (1.0 + (ads_scale - 1.0) * clampf(t, 0.0, 1.0))


## The eye point in the lifted holder frame, which is the frame `transform` maps.
func sight_point() -> Vector3:
	return attach.sight + Vector3(0.0, lift, 0.0)


## Where the sight lands off the view axis at ADS amount `t`, in metres. Both
## components are zero at `t` of 1 for a correctly solved weapon.
func sight_offset(t: float) -> Vector2:
	var p: Vector3 = transform(t) * sight_point()
	return Vector2(p.x, p.y)


## Distance from the eye to the sight at ADS amount `t`, metres. This is the eye relief
## you would feel, and it is what the rear standoff is really tuning.
func sight_distance(t: float) -> float:
	return -(transform(t) * sight_point()).z


## Cosine of the angle between the bore and the view axis. 1.0 is dead parallel.
func bore_alignment(t: float) -> float:
	var dir: Vector3 = (transform(t).basis * GunAttachPoints.BORE_AXIS).normalized()
	return dir.dot(Vector3.FORWARD)
