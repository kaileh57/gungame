class_name PlayerLocomotion
extends RefCounted
## The Quake-lineage velocity math, with no node, no physics server and no state.
##
## Every function here is a pure transform of a velocity vector, which is the reason it
## is a separate file: the feel of the controller lives in these six formulas, and they
## can be measured exactly — terminal walk speed, air-strafe gain per frame, how many
## ticks a stop takes — without a collider anywhere near them. `PlayerController` does
## the moving; this does the deciding.
##
## Velocities are returned rather than mutated because GDScript has no by-reference
## parameters. `Vector3` is a value type, so the copies cost a register move and nothing
## is allocated.
##
## Constants live on the controller as exports. Nothing here has a default.


## Quake acceleration. Adds velocity along the wish direction only up to `wish_speed`
## measured ALONG that direction — never the total speed. That distinction is the whole
## trick: strafing sideways in the air projects almost nothing onto the wish axis, so
## `add` stays large and speed keeps climbing. Any "fix" that clamps the magnitude here
## kills bunny-hopping outright.
static func accelerate(
	vel: Vector3, wx: float, wz: float, wish_speed: float, acc: float, dt: float
) -> Vector3:
	var cur: float = vel.x * wx + vel.z * wz
	var add: float = wish_speed - cur
	if add <= 0.0:
		return vel
	var a: float = minf(acc * wish_speed * dt, add)
	vel.x += a * wx
	vel.z += a * wz
	return vel


## Quake friction. `stop_speed` is a floor on the control speed, so a slow walk still
## sheds velocity at a usable rate instead of decaying asymptotically forever. Below
## 0.02 m/s the residue is snapped away, which is what makes a stop feel like a stop.
static func apply_friction(vel: Vector3, f: float, stop_speed: float, dt: float) -> Vector3:
	var sp: float = sqrt(vel.x * vel.x + vel.z * vel.z)
	if sp < 0.02:
		vel.x = 0.0
		vel.z = 0.0
		return vel
	var ctrl: float = maxf(sp, stop_speed)
	var ns: float = maxf(0.0, sp - ctrl * f * dt) / sp
	vel.x *= ns
	vel.z *= ns
	return vel


static func planar_speed(vel: Vector3) -> float:
	return sqrt(vel.x * vel.x + vel.z * vel.z)


## Scale XZ down to `limit` if it is over. Used by the slide, and by nothing else — the
## walk and the air are deliberately uncapped.
static func clamp_planar(vel: Vector3, limit: float) -> Vector3:
	var sp: float = sqrt(vel.x * vel.x + vel.z * vel.z)
	if sp <= limit or sp <= 1e-6:
		return vel
	var k: float = limit / sp
	vel.x *= k
	vel.z *= k
	return vel


## Project a unit wish direction onto the plane of `normal` and renormalise. Without
## this you accelerate into a hill instead of along it, and the resulting speed loss
## reads as the slope being sticky. Returns `Vector2.ZERO` when the projection collapses,
## which only happens facing straight into a wall-steep normal.
static func project_on_slope(wx: float, wz: float, normal: Vector3) -> Vector2:
	var d: float = wx * normal.x + wz * normal.z
	var px: float = wx - normal.x * d
	var pz: float = wz - normal.z * d
	var pl: float = sqrt(px * px + pz * pz)
	if pl < 1e-5:
		return Vector2.ZERO
	return Vector2(px / pl, pz / pl)


## The speed the ground controller is aiming for this tick, before acceleration.
## `wish_scale` is the analogue-stick magnitude: keyboard diagonals clamp to 1, a
## half-pushed stick walks.
static func ground_target_speed(
	walk: float,
	sprint: float,
	crouch: float,
	crouching: bool,
	sprinting: bool,
	ads: float,
	ads_mul: float,
	backpedal_mul: float,
	backpedalling: bool,
	wish_scale: float
) -> float:
	var target: float = walk
	if crouching:
		target = crouch
	elif sprinting:
		target = sprint
	if ads > 0.1 and not sprinting:
		target *= lerpf(1.0, ads_mul, ads)
	if backpedalling:
		target *= backpedal_mul
	return target * wish_scale


## WHICH WAY IS DOWNHILL. Read this before touching anything below it.
##
## `ground_normal` is the OUTWARD, up-facing normal handed back by `move_and_collide`.
## For such a normal the horizontal component leans toward the LOW side of the plane:
## stand on a ramp that falls away to your right and the normal tilts right. So the
## downhill fall line is `+(n.x, n.z)` and the uphill one is `-(n.x, n.z)`.
##
## This was wrong for the entire life of the project, and it is wrong in the reference
## the port came from — both wrote the downhill pull as `-(n.x, n.z)`, which accelerates
## a slide UP the hill and brakes it going down. It hid because on flat ground the term
## is zero and the entry boost is all you feel in the first second. Measured on a
## 20-degree face: sliding uphill sat at a 9.75 m/s equilibrium forever while sliding
## downhill bled to 0.64 m/s in 1.2 s. Every downhill number in this file assumes the
## corrected sign; flipping it back does not merely change the tuning, it inverts the
## mechanic.
##
## The returned vector is deliberately NOT normalised: its length is sin(slope angle),
## which is the same 0..1 steepness term the friction fade wants.
static func fall_line(normal: Vector3) -> Vector2:
	return Vector2(normal.x, normal.z)


## The entry boost actually applied, after the fade. A slide entered from a run is a
## commitment and gets the full multiplier; a slide re-entered at 16 m/s off a landing
## gets none of it, because a boost that compounds on every link is a free speed
## generator and the chain would have no ceiling but the clamp.
##
## `fade_to <= fade_from` disables the fade entirely, which is what the four-argument
## `slide_entry_velocity` below relies on to keep its original behaviour.
static func entry_boost(sp: float, boost: float, fade_from: float, fade_to: float) -> float:
	if fade_to <= fade_from or sp <= fade_from:
		return boost
	if sp >= fade_to:
		return 1.0
	return lerpf(boost, 1.0, (sp - fade_from) / (fade_to - fade_from))


## The instant speed change on entering a slide: 130 % of what you had, floored at
## `min_speed` and ceilinged at `max_speed`. Entering at 5.1 m/s still snaps you to 8.2,
## which is the reason a slide always feels like a commitment rather than a shuffle.
##
## The two fade arguments default to "off" so the original four-argument call is
## unchanged; see `entry_boost` for what they do when supplied.
static func slide_entry_velocity(
	vel: Vector3,
	boost: float,
	min_speed: float,
	max_speed: float,
	fade_from: float = 0.0,
	fade_to: float = 0.0
) -> Vector3:
	var sp: float = sqrt(vel.x * vel.x + vel.z * vel.z)
	if sp <= 0.01:
		return vel
	var target: float = clampf(
		sp * entry_boost(sp, boost, fade_from, fade_to), min_speed, max_speed
	)
	var k: float = target / sp
	vel.x *= k
	vel.z *= k
	return vel


## One tick of sliding. Gravity is resolved along the ground plane so you accelerate
## downhill, friction is scaled three ways — up the fall line, down it, and by how steep
## the face is — and steering is a weak `accelerate` so you can aim a slide without
## pumping it.
##
## The three friction multipliers are what make the economy work. On the flat only
## `fric` applies and a slide is a decaying thing, so hopping on level ground gives back
## less than it costs. Down the fall line `fric_down` (well under 1) lets the gravity
## term win and speed builds toward a terminal set by the grade. Up it, `fric_up` and
## gravity both oppose and the slide dies in well under a second.
static func slide_step(
	vel: Vector3,
	normal: Vector3,
	wish: Vector2,
	moving: bool,
	gravity: float,
	grav_scale: float,
	fric: float,
	fric_up: float,
	fric_down: float,
	slope_fade: float,
	steer: float,
	steer_wish: float,
	max_speed: float,
	dt: float
) -> Vector3:
	var fall: Vector2 = fall_line(normal)
	vel.x += fall.x * gravity * grav_scale * dt
	vel.z += fall.y * gravity * grav_scale * dt
	var slope: float = fall.length()
	var f: float = fric * maxf(1.0 - slope * slope_fade, 0.0)
	if slope > 1e-5:
		# Metres per second along the fall line: positive is down it, negative is up it.
		var along: float = (vel.x * fall.x + vel.z * fall.y) / slope
		if along < -0.2:
			f *= fric_up
		elif along > 0.2:
			f *= fric_down
	vel = apply_friction(vel, maxf(f, 0.0), 3.0, dt)
	if moving:
		vel = accelerate(vel, wish.x, wish.y, steer * steer_wish, steer, dt)
	return clamp_planar(vel, max_speed)


## Lay the velocity INTO the ground plane so a slide follows a descent instead of leaving
## it. The ground controller writes only x and z and leaves y at zero, which is correct
## for walking — the collision resolver puts you back down each tick — but at slide speed
## on a real ramp it is not.
##
## Measured on the movement demo's own slide run, a 23-degree, 8-metre descent: the body
## separated from the face, `_snap_down` stopped re-arming once `was_grounded` went false
## for a single tick, and the whole descent was taken AIRBORNE at a dead-constant
## 9.08 m/s. `sliding` stayed true the whole way — the slide exit only fires after 0.55 s
## of air — so it looked exactly like a slide while neither the downhill pull nor the
## friction ran, and the jump at the bottom did not fire at all because coyote time had
## long since expired. A slide that skims is not a slide.
##
## Only ever pushes DOWN: on a rise the resolver's step-up already handles it, and gluing
## the body to an upslope would fight it. Capped so a near-vertical face cannot produce a
## vertical speed larger than the slide is allowed to carry horizontally.
static func stick_to_plane(vel: Vector3, normal: Vector3, cap: float) -> Vector3:
	if normal.y < 0.2:
		return vel
	var vy: float = -(vel.x * normal.x + vel.z * normal.z) / normal.y
	if vy >= 0.0:
		return vel
	vel.y = maxf(vy, -cap)
	return vel


## The launch out of a slide, and the whole reason the slide is worth entering.
##
## Vertical is the jump scaled by `vertical_mul` plus a `lift` that grows with how fast
## the slide was going — that is the "converts momentum" half: speed you built on the
## way down buys hang time on the way up, so a fast slide-jump is a longer arc AND a
## faster one rather than the same arc with more speed. The lift is paid for with
## `convert` metres per second of planar speed per metre per second of lift, which keeps
## it from being free without making it feel taxed.
##
## `boost` is a small multiplier on what is left, and `max_speed` is the launch ceiling —
## the one that actually bounds a chain, because every other cap in the slide only
## applies while the feet are on the ground.
static func slide_jump_velocity(
	vel: Vector3,
	jump: float,
	vertical_mul: float,
	lift_floor: float,
	lift_gain: float,
	lift_max: float,
	convert: float,
	boost: float,
	max_speed: float
) -> Vector3:
	var sp: float = sqrt(vel.x * vel.x + vel.z * vel.z)
	var lift: float = clampf((sp - lift_floor) * lift_gain, 0.0, lift_max)
	vel.y = jump * vertical_mul + lift
	if sp <= 1e-4:
		return vel
	var target: float = maxf(minf(sp * boost - lift * convert, max_speed), 0.0)
	var k: float = target / sp
	vel.x *= k
	vel.z *= k
	return vel


## Steer the planar velocity toward the wish direction WITHOUT changing its magnitude.
##
## This exists because Quake air control cannot do it. `accelerate` only adds along the
## wish axis up to `air_wish_speed`, so a player holding forward — which is every player,
## always — already projects ten times that onto their own heading and gets exactly
## nothing. Measured on the shipped controller: a full sideways stick during a slide-jump
## turned the velocity 0.0 degrees. Rotating instead of adding fixes it and cannot
## produce speed, which is the property that lets it be generous.
##
## `cone` is the widest angle it will act across; past that the input is ignored rather
## than clamped, so pulling back hard is a decision to keep your line rather than a slow
## reversal. `max_turn` is the radians it may spend this tick.
static func air_redirect(
	vel: Vector3, wx: float, wz: float, max_turn: float, cone: float
) -> Vector3:
	var sp: float = sqrt(vel.x * vel.x + vel.z * vel.z)
	if sp < 0.1 or max_turn <= 0.0:
		return vel
	var cur := Vector2(vel.x / sp, vel.z / sp)
	var ang: float = cur.angle_to(Vector2(wx, wz))
	if absf(ang) > cone:
		return vel
	var turn: float = clampf(ang, -max_turn, max_turn)
	var c: float = cos(turn)
	var s: float = sin(turn)
	vel.x = (cur.x * c - cur.y * s) * sp
	vel.z = (cur.x * s + cur.y * c) * sp
	return vel


## Touching down with the descent folded into travel along the ground instead of thrown
## away. Removing the normal component of a downward velocity on a DOWNSLOPE leaves more
## planar speed than went in, and that surplus is exactly what a chained line is made of:
## land on a ramp still falling and you leave it faster than you arrived.
##
## On flat ground the projection is identical to zeroing Y, so this needs no special
## case for it. `conserve` is how much of the surplus is kept, `gain_cap` the ceiling on
## the multiplier so a near-vertical drop onto a steep face cannot fire you off it.
static func land_on_plane(
	vel: Vector3, normal: Vector3, conserve: float, gain_cap: float
) -> Vector3:
	var before: float = sqrt(vel.x * vel.x + vel.z * vel.z)
	if before <= 1e-4 or conserve <= 0.0:
		vel.y = 0.0
		return vel
	var d: float = vel.x * normal.x + vel.y * normal.y + vel.z * normal.z
	var px: float = vel.x - normal.x * d
	var pz: float = vel.z - normal.z * d
	var after: float = sqrt(px * px + pz * pz)
	vel.y = 0.0
	if after <= before:
		return vel
	var k: float = lerpf(1.0, minf(after / before, maxf(gain_cap, 1.0)), clampf(conserve, 0.0, 1.0))
	vel.x *= k
	vel.z *= k
	return vel


## Gravity plus terminal velocity. Separate from the air controller because the mantle
## and the ladder both need to suppress it while still sharing the clamp.
static func apply_gravity(vel: Vector3, gravity: float, terminal: float, dt: float) -> Vector3:
	vel.y -= gravity * dt
	if vel.y < terminal:
		vel.y = terminal
	return vel


## Exponential damping toward a target, framerate independent. `rate` is the reciprocal
## time constant: 15 closes 63 % of the gap in 1/15 s regardless of tick length.
static func damp(from: float, to: float, rate: float, dt: float) -> float:
	return lerpf(from, to, 1.0 - exp(-rate * dt))


## Look sensitivity scale for a magnified view, per `docs/spec/range.md` §14.2:
## `k = 0.0022 * tan(fov/2) / tan(BASEFOV/2)`. Continuous in the FOV, so a scope that
## eases from 66 to 10 degrees eases the turn rate down with it and never steps.
static func fov_sens_scale(view_fov: float, base_fov: float) -> float:
	return tan(deg_to_rad(view_fov) * 0.5) / maxf(tan(deg_to_rad(base_fov) * 0.5), 1e-4)
