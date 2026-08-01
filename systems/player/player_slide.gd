class_name PlayerSlide
extends Resource
## Every dial the slide, the slide-jump and the chain have, plus the small amount of
## state that belongs to them rather than to the body.
##
## It is a `Resource` and not a plain helper so that all thirty knobs are real
## `@export_range` entries: they show up under the player in the inspector, they carry
## their own bounds, and `MovementConsole` can drive any of them from the bench without
## a table of setters. `PlayerController` owns one and does nothing with it but ask.
##
## THE MECHANIC, in one paragraph, because the numbers below only make sense against it.
## A slide is entered from a run and boosted once, as a commitment. On the flat it decays
## — `friction` alone applies and hopping on level ground gives back less than it costs.
## Down a fall line `downhill_friction` lets the gravity term win and speed climbs toward
## a terminal set by the grade. Jumping out of a slide spends some of that speed on hang
## time (`jump_lift_gain`, paid for at `jump_convert`) so the arc is longer as well as
## faster, and opens a window (`jump_air_time`) in which the velocity can be steered
## without losing magnitude and in which the next touchdown folds its descent into the
## ground instead of throwing it away. That last part is the chain: land on a downslope
## still falling and you leave faster than you arrived, so a line across roofs and ramps
## holds together while the same inputs on flat ground bleed out in three hops.

@export_group("Entry")
@export_range(1.0, 20.0, 0.1) var entry_speed: float = 5.0
@export_range(1.0, 3.0, 0.01) var boost: float = 1.30
@export_range(1.0, 30.0, 0.1) var min_speed: float = 8.2
@export_range(1.0, 40.0, 0.1) var max_speed: float = 19.5
## Entry speed at which the boost has faded to 1.0; the fade starts at `min_speed`. This
## is what stops a chain multiplying itself on every link.
@export_range(2.0, 40.0, 0.1) var boost_fade: float = 15.0
@export_range(0.0, 2.0, 0.01) var relock: float = 0.30

@export_group("Surface")
## Base friction, and the only one that applies on level ground.
@export_range(0.0, 10.0, 0.01) var friction: float = 0.85
## Friction multiplier down the fall line. Under 1, so gravity wins and speed builds.
@export_range(0.05, 2.0, 0.01) var downhill_friction: float = 0.30
## Friction multiplier up it. Gravity already opposes you here; this finishes the job.
@export_range(1.0, 8.0, 0.05) var uphill_friction: float = 2.40
## How much the whole friction term shrinks with steepness: `f *= 1 - sin(angle) * this`.
@export_range(0.0, 1.5, 0.01) var slope_fade: float = 0.55
## Fraction of full gravity resolved along the ground plane.
@export_range(0.0, 2.0, 0.01) var gravity_scale: float = 0.92
@export_range(0.0, 20.0, 0.1) var steer: float = 4.6
## Wish-speed fraction the steer aims at. Low, so steering aims a slide, never pumps it.
@export_range(0.05, 1.5, 0.01) var steer_wish: float = 0.62

@export_group("Jump")
## Jump multiplier out of a slide. At 1.0 the arc matches a run-jump and only the speed
## is higher; above it, the slide-jump hangs longer too.
@export_range(0.5, 1.6, 0.01) var jump_vertical: float = 1.02
## Planar speed above which the slide starts buying lift.
@export_range(0.0, 20.0, 0.1) var jump_lift_floor: float = 6.0
## Extra vertical m/s bought per m/s of slide speed over the floor.
@export_range(0.0, 1.0, 0.005) var jump_lift_gain: float = 0.20
@export_range(0.0, 8.0, 0.05) var jump_lift_max: float = 3.20
## Planar m/s paid per m/s of lift. The hang time is bought, not printed.
@export_range(0.0, 2.0, 0.01) var jump_convert: float = 0.35
@export_range(0.5, 1.6, 0.01) var jump_boost: float = 1.10
## The launch ceiling — the only cap that bounds a chain, since every other one applies
## while the feet are down. Generous, but a real wall.
@export_range(5.0, 45.0, 0.5) var jump_max_speed: float = 24.0

@export_group("Air and chain")
## Seconds after a launch during which the redirect is live and a landing chains.
@export_range(0.0, 4.0, 0.05) var jump_air_time: float = 1.20
## Degrees per second the redirect may turn the velocity. It cannot add speed, which is
## exactly why it can afford to be this generous.
@export_range(0.0, 360.0, 1.0) var jump_air_turn: float = 96.0
## Widest angle it acts across. Past it the input is ignored, so hauling the stick back
## keeps your line rather than slowly reversing it.
@export_range(10.0, 180.0, 1.0) var jump_air_cone: float = 88.0
## Fraction kept of the surplus from folding a descent into the ground plane. The chain.
@export_range(0.0, 1.0, 0.01) var land_conserve: float = 0.62
## Ceiling on that surplus, as a multiplier on the speed you arrived with.
@export_range(1.0, 4.0, 0.05) var land_gain_cap: float = 1.85
## How long after a slide-jump touchdown a slide still counts as a link in the same line
## rather than a fresh commitment out of a run. See `chain`.
@export_range(0.0, 1.0, 0.01) var chain_window: float = 0.25
## How much of the hard-landing speed penalty a chained landing is spared.
@export_range(0.0, 1.0, 0.01) var land_impact_relief: float = 1.0

@export_group("Bank")
## Peak bank is 1; it settles to `bank_hold` over `bank_settle` seconds, and the strafe
## input pushes it either way on top by up to `bank_steer`.
@export_range(0.0, 1.0, 0.01) var bank_hold: float = 0.35
@export_range(0.05, 2.0, 0.01) var bank_settle: float = 0.45
@export_range(0.0, 1.0, 0.01) var bank_steer: float = 0.55
@export_range(1.0, 30.0, 0.5) var bank_rate: float = 9.0

## Slide runtime, kept here so the controller's tick reads as a sequence of questions.
## Seconds the current slide has run; the bank envelope and the exit rules use it.
var t: float = 0.0
## Re-entry lockout. Counts down whether or not a slide is running.
var lock: float = 0.0
## Seconds left of the slide-jump window. Non-zero means redirect air control is live and
## the next touchdown is a chain link. It only runs down while the feet are ON THE
## GROUND: a chained arc off a real slope can hang for well over a second — the harness
## measures 1.28 s on the third link — and a window that expired mid-flight would take
## the steering away at the apex and drop the link at the far end of the best jump in
## the game. Touching down consumes it outright, so it cannot leak.
var air: float = 0.0
## Signed camera lean, -1 left to +1 right. The rig scales it; the shape is decided here.
var bank: float = 0.0
## 1 on the tick a slide launched, easing to 0 across `jump_air_time`.
var launch: float = 0.0
## True while the jump currently in the air came out of a slide.
var from_slide: bool = false
## Counts down from a slide-jump touchdown. While it runs, an entry is a LINK in a line
## rather than a commitment out of a run, and is handed neither the boost, nor the speed
## floor, nor the stamina bill.
##
## This is the load-bearing rule of the whole economy. With the boost re-applying on
## every landing, hopping on level ground compounds — measured at a 9.0 m/s plateau
## against a 7.5 m/s sprint, so the correct play was to mash crouch forever. With it
## suppressed, friction is the only term left on the flat and a chain there decays hop
## by hop, while downhill the gravity term keeps paying and the same inputs hold a line.
var chain: float = 0.0

## Which shoulder the current slide drops. Latched at entry.
var _bank_sign: float = 1.0


func _init() -> void:
	# Duplicated per scene instance, so two players in one tree cannot share tuning and a
	# console turning a knob on one cannot silently move the other.
	resource_local_to_scene = true


## Everything the body carries between slides, cleared. Called on teleport and freecam.
func reset() -> void:
	t = 0.0
	lock = 0.0
	air = 0.0
	bank = 0.0
	launch = 0.0
	chain = 0.0
	from_slide = false


## True when a slide may start this tick.
func can_enter(want_crouch: bool, sliding: bool, grounded: bool, speed_now: float) -> bool:
	return want_crouch and not sliding and grounded and speed_now > entry_speed and lock <= 0.0


## Commit. Returns the entry velocity; the caller charges stamina with `stamina_share`.
func enter(vel: Vector3, yaw: float, strafe: float) -> Vector3:
	t = 0.0
	lock = relock
	_bank_sign = _lean_sign(vel, yaw, strafe)
	if chain > 0.0:
		chain = 0.0
		# The speed you arrive with is the speed you keep. No boost and no floor, only
		# the ceiling — everything a link gains has to come from the slope.
		return PlayerLocomotion.clamp_planar(vel, max_speed)
	return PlayerLocomotion.slide_entry_velocity(
		vel, boost, min_speed, max_speed, min_speed, boost_fade
	)


## How much of the full stamina cost this entry earned, 0..1. A slide out of a sprint was
## handed the whole boost and pays for it; a chain link was given nothing and is charged
## nothing. Without this, four links empty the bar and you come out of a perfect line
## unable to sprint. Ask before `enter`, which consumes the chain flag.
func stamina_share(speed_now: float) -> float:
	if chain > 0.0 or boost <= 1.0001:
		return 0.0
	var given: float = PlayerLocomotion.entry_boost(speed_now, boost, min_speed, boost_fade)
	return clampf((given - 1.0) / (boost - 1.0), 0.0, 1.0)


## Advance the running slide. Returns true when it has ended.
func tick(dt: float, want_crouch: bool, grounded: bool, air_time: float, sp: float) -> bool:
	t += dt
	lock -= dt
	if not want_crouch and t > 0.22:
		return true
	if sp < 2.7 and t > 0.28:
		return true
	return not grounded and air_time > 0.55


## One tick of sliding, with every multiplier this resource owns spent in one call.
func step(
	vel: Vector3, normal: Vector3, wish: Vector2, moving: bool, gravity: float, dt: float
) -> Vector3:
	var out: Vector3 = PlayerLocomotion.slide_step(
		vel,
		normal,
		wish,
		moving,
		gravity,
		gravity_scale,
		friction,
		uphill_friction,
		downhill_friction,
		slope_fade,
		steer,
		steer_wish,
		max_speed,
		dt
	)
	# Follow the face rather than skim off it. Without this the descent is taken in the
	# air and neither the pull nor the friction ever runs — see `stick_to_plane`.
	return PlayerLocomotion.stick_to_plane(out, normal, max_speed)


## Leave the ground out of a slide, and open the window.
func launch_velocity(vel: Vector3, jump: float) -> Vector3:
	air = maxf(jump_air_time, 0.001)
	launch = 1.0
	from_slide = true
	# Shorter than `relock`: the whole point of a chain is that the next touchdown goes
	# straight back under you, and a 0.30 s lockout eats the link.
	lock = 0.10
	return PlayerLocomotion.slide_jump_velocity(
		vel,
		jump,
		jump_vertical,
		jump_lift_floor,
		jump_lift_gain,
		jump_lift_max,
		jump_convert,
		jump_boost,
		jump_max_speed
	)


## Steer the arc without paying for it. No-op outside the window.
func redirect(vel: Vector3, wish: Vector2, dt: float) -> Vector3:
	if air <= 0.0:
		return vel
	return PlayerLocomotion.air_redirect(
		vel, wish.x, wish.y, deg_to_rad(jump_air_turn) * dt, deg_to_rad(jump_air_cone)
	)


## Touch down. Inside the window with crouch held this is a chain link and the descent is
## folded into the ground plane; otherwise the vertical is simply spent. The window is
## consumed either way, because `_integrate` can substep and a surplus that compounds per
## substep is a surplus that depends on frame rate.
func land(vel: Vector3, normal: Vector3, want_crouch: bool) -> Vector3:
	if air <= 0.0:
		vel.y = 0.0
		return vel
	air = 0.0
	chain = chain_window
	if not want_crouch:
		vel.y = 0.0
		return vel
	return PlayerLocomotion.land_on_plane(vel, normal, land_conserve, land_gain_cap)


## Planar multiplier a hard landing keeps. 0.55 normally, up to 1.0 when a chained
## landing rolls the drop out instead of eating it.
func impact_keep(chained: bool) -> float:
	return lerpf(0.55, 1.0, clampf(land_impact_relief, 0.0, 1.0)) if chained else 0.55


## The jump that was not a slide-jump. Shuts every slide window, including the visual
## one, so tapping jump immediately after a slide-jump does not inherit its FOV kick.
func plain_jump() -> void:
	air = 0.0
	launch = 0.0
	from_slide = false


## Windows and the bank envelope, once per tick after the body has settled.
func advance(dt: float, grounded: bool, sliding: bool, strafe: float) -> void:
	if grounded:
		air = maxf(0.0, air - dt)
	chain = maxf(0.0, chain - dt)
	# The camera envelope runs on the clock whatever the body is doing: a kick that held
	# flat for a whole second and then stepped off on landing would read as a glitch.
	launch = maxf(0.0, launch - dt / maxf(jump_air_time, 0.001))
	var want: float = 0.0
	if sliding:
		want = _bank_sign * lerpf(1.0, bank_hold, clampf(t / maxf(bank_settle, 0.01), 0.0, 1.0))
		want = clampf(want + strafe * bank_steer, -1.0, 1.0)
	bank = PlayerLocomotion.damp(bank, want, bank_rate, dt)


## Which shoulder to drop. The lateral velocity decides when there is one to read, the
## strafe key when there is not, and failing both it is the right — a slide taken dead
## straight still leans, because a slide that does not lean reads as a crouch.
static func _lean_sign(vel: Vector3, yaw: float, strafe: float) -> float:
	var side: float = vel.x * cos(yaw) - vel.z * sin(yaw)
	if absf(side) > 0.6:
		return signf(side)
	if absf(strafe) > 0.1:
		return signf(strafe)
	return 1.0
