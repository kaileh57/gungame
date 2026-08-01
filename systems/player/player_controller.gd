class_name PlayerController
extends CharacterBody3D
## Quake-lineage kinematic controller: separate ground and air acceleration, real
## air-strafing, a slope-aware slide, auto-vault, ladders and silent stair stepping.
##
## The node's origin is the FEET, not the centre and not the eye — every constant in
## the reference is written that way and translating them would only invite sign bugs.
##
## `move_and_slide()` is never called. The reference resolves XZ before Y, runs three
## depenetration passes, and folds step-up into the horizontal pass; that order is what
## the feel is made of. What is used instead of the reference's oriented-box array is
## `move_and_collide`, so the same rules run against whatever colliders a demo actually
## contains. The one thing borrowed wholesale from Godot is the swept cast — it is
## strictly better than discrete depenetration and removes the reference's tunnelling.
##
## Every number here comes from `docs/spec/world.md` §17. Where a value was changed it
## says so in the comment on that export.
##
## PERFORMANCE NOTE: `move_and_collide` returns a KinematicCollision3D that Godot
## reuses between calls. Read `get_normal`/`get_travel`/`get_remainder` off it before
## the next move, never hold it. In exchange the whole tick allocates nothing.

## A foot hit the ground. `surface` indexes `WorldSurface.Kind`, read from the `surf`
## metadata on the collider that was stood on.
signal stepped(surface: int, volume: float)
## Feet touched down after time in the air. `impact` is 0..1, `fall_height` in metres.
signal landed(surface: int, impact: float, fall_height: float)
signal jumped
signal slide_changed(is_sliding: bool)
signal mantle_started(rise: float)
signal ladder_changed(attached: bool)
## A fall hard enough to hurt to look at. `severity` is 0..0.9, for a vignette flash.
signal hard_landing(severity: float)
signal respawned
## The exclusive movement state changed. Both arguments index `PlayerState.Kind`; the
## full snapshot is on `state`, which is already up to date when this fires.
signal state_changed(from: int, to: int)

## Metres of travel per collision substep. 22 m/s at 60 Hz is three substeps.
const SUBSTEP_TRAVEL: float = 0.16
const MAX_SUBSTEPS: int = 8
## Horizontal slide iterations per substep.
const MAX_SLIDES: int = 4
## A step-up that gains less lateral ground than this is not worth the vertical shove.
const MIN_STEP_GAIN: float = 0.002
## The autoloads are reached through `/root` and preloaded types rather than through the
## global singleton identifiers, so the controller still compiles and runs in a bare
## `SceneTree` — which is what makes the headless acceptance run in `tests/` possible.
## Both are resolved once in `_ready`; nothing here does a string lookup per frame.
const GameSettingsScript := preload("res://core/game_settings.gd")
const SceneRouterScript := preload("res://core/scene_router.gd")

@export_group("Movement")
@export_range(1.0, 40.0, 0.1) var gravity: float = 21.5
@export_range(0.0, 20.0, 0.05) var walk_speed: float = 4.35
@export_range(0.0, 20.0, 0.05) var sprint_speed: float = 7.5
@export_range(0.0, 20.0, 0.05) var crouch_speed: float = 2.15
## Movement multiplier while fully aimed in.
@export_range(0.1, 1.0, 0.01) var ads_speed_mul: float = 0.52
## Backpedalling is deliberately worse than advancing.
@export_range(0.3, 1.0, 0.01) var backpedal_mul: float = 0.82
@export_range(1.0, 60.0, 0.1) var ground_accel: float = 13.5
## Huge on purpose. With `air_wish_speed` this is the air-strafe gain, not a speed cap.
@export_range(1.0, 200.0, 0.5) var air_accel: float = 92.0
## Wish speed used in the air. Small, so `accelerate` almost never early-outs sideways.
@export_range(0.1, 5.0, 0.01) var air_wish_speed: float = 1.15
@export_range(0.0, 30.0, 0.1) var friction: float = 10.5
## Friction is scaled by this when no direction is pressed. This is the active brake.
@export_range(1.0, 3.0, 0.01) var idle_brake_mul: float = 1.45
@export_range(0.1, 20.0, 0.1) var stop_speed: float = 3.0
@export_range(1.0, 20.0, 0.05) var jump_velocity: float = 6.8
@export_range(-200.0, -5.0, 1.0) var terminal_velocity: float = -60.0
@export_range(0.0, 0.5, 0.005) var coyote_time: float = 0.11
@export_range(0.0, 0.5, 0.005) var jump_buffer_time: float = 0.13
## Fraction of speed kept when a descent is deflected off a slope too steep to stand on.
## 1.0 is a frictionless slide-off; lower it and steep faces start to grab.
@export_range(0.0, 1.0, 0.01) var steep_slide_retain: float = 1.0

@export_group("Body")
@export_range(0.1, 1.0, 0.01) var radius: float = 0.34
@export_range(1.0, 2.5, 0.01) var stand_height: float = 1.80
@export_range(0.5, 1.8, 0.01) var crouch_height: float = 1.12
@export_range(0.5, 2.2, 0.01) var stand_eye: float = 1.66
@export_range(0.3, 1.6, 0.01) var crouch_eye: float = 0.90
@export_range(0.0, 1.5, 0.01) var step_height: float = 0.58
## Contact tolerance under the feet. Without it `grounded` toggles every other tick on a
## flat box top, which stutters footsteps and eats jump inputs.
@export_range(0.005, 0.20, 0.001) var ground_skin: float = 0.045
## How far below the feet a drop is followed rather than fallen off. Raise it and you
## glue to descending stairs; lower it and walking off a shallow ramp becomes a hop.
@export_range(0.0, 1.5, 0.01) var snap_probe: float = 0.52
## Shortest forward leg of a step-up, metres. Roughly one tick of walking, so a riser
## reached exactly at the end of a sweep is still cleared instead of stopping you dead.
@export_range(0.01, 0.30, 0.005) var step_forward_probe: float = 0.06
## Physics-server skin width. Larger forgives coplanar seams between baked colliders.
@export_range(0.001, 0.05, 0.001) var collision_margin: float = 0.008
@export_range(1.0, 40.0, 0.5) var crouch_rate: float = 13.0
@export_range(1.0, 60.0, 0.5) var slide_crouch_rate: float = 22.0

@export_group("Slide")
## Thirty dials, their runtime state, and the whole slide/slide-jump/chain mechanic. It
## is a separate resource because the feature has more constants than the rest of the
## controller put together and because they are the ones a tuning pass actually turns.
@export var slide: PlayerSlide = PlayerSlide.new()

@export_group("Traversal")
## Rise the automatic vault will take when you run into a wall.
@export_range(0.2, 3.0, 0.01) var mantle_auto_rise: float = 1.32
## Rise the deliberate vault will take when you hold jump against a wall.
@export_range(0.2, 4.0, 0.01) var mantle_manual_rise: float = 2.05
@export_range(0.5, 8.0, 0.05) var ladder_climb_speed: float = 3.3
@export_range(0.5, 8.0, 0.05) var ladder_descend_speed: float = 3.9
@export_range(0.0, 8.0, 0.05) var ladder_shimmy_speed: float = 2.4
@export_range(0.0, 12.0, 0.5) var ladder_kick_out: float = 5.0
@export_range(0.0, 12.0, 0.5) var ladder_kick_up: float = 4.4

@export_group("Stamina")
@export_range(0.0, 60.0, 0.5) var stamina_drain: float = 13.5
@export_range(0.0, 60.0, 0.5) var stamina_regen: float = 21.0
@export_range(0.0, 20.0, 0.5) var stamina_jump_cost: float = 3.5
@export_range(0.0, 20.0, 0.5) var stamina_slide_cost: float = 7.0

@export_group("Look")
## Multiplies `GameSettings.mouse_sensitivity`. Per-scene trim, not the user setting.
@export_range(0.1, 4.0, 0.01) var look_scale: float = 1.0
@export_range(0.5, 1.55, 0.005) var pitch_limit: float = 1.53
## Optional bindings. The frozen input map has no lean actions; set these to action
## names that exist and Q/E-style leaning turns on, leave them empty and it stays off.
@export var lean_left_action: StringName = &""
@export var lean_right_action: StringName = &""
@export_range(0.0, 1.0, 0.01) var lean_amount: float = 1.0
## The eye. Look sensitivity is divided by its magnification, so a 9x optic turns at a
## ninth of the rate of irons without the player touching a slider. Clear it and the
## scaling falls back to 1x.
@export var camera_path: NodePath = NodePath("Eye")

@export_group("Feel")
## Rate the stair smoother returns the camera to the body. Lower is smoother and lazier.
@export_range(1.0, 60.0, 0.5) var stair_smooth_rate: float = 15.0
## Hard ceiling on the stair-smoothing offset, so a bad snap can never throw the camera.
@export_range(0.05, 1.5, 0.01) var stair_smooth_max: float = 0.8
@export_range(1.0, 40.0, 0.5) var ads_damp_rate: float = 14.0
@export_range(1.0, 40.0, 0.5) var lean_damp_rate: float = 10.0
## Head-bob phase advance at a standstill, rad/s, and the extra per m/s of ground speed.
## A footstep fires every PI of phase, so together these set the stride length.
@export_range(0.0, 10.0, 0.01) var bob_idle_rate: float = 2.35
@export_range(0.0, 4.0, 0.01) var bob_speed_gain: float = 0.92
## Below this ground speed the stride is parked and no footsteps fire.
@export_range(0.0, 4.0, 0.01) var step_min_speed: float = 1.1
## Landing dip spring, integrated at a fixed 120 Hz so it does not vary with tick rate.
@export_range(10.0, 400.0, 1.0) var land_spring_stiffness: float = 120.0
@export_range(1.0, 60.0, 0.5) var land_spring_damping: float = 13.0

@export_group("World")
## Falling below this respawns you. The reference's void kill plane.
@export var void_y: float = -80.0
## Metres of fall before a landing hurts to look at.
@export_range(1.0, 40.0, 0.5) var hard_landing_height: float = 8.5
@export var body_shape_path: NodePath = NodePath("Body")

## Look angles in radians. Yaw 0 faces -Z; mouse right decreases yaw.
var yaw: float = 0.0
var pitch: float = 0.0
var grounded: bool = false
var was_grounded: bool = false
var sliding: bool = false
var sprinting: bool = false
var is_moving: bool = false
## 0 standing, 1 fully ducked. Drives body height and eye height.
var crouch_t: float = 0.0
## 0 hip, 1 fully aimed in.
var ads: float = 0.0
## -1 left, +1 right. Zero unless the lean actions are bound.
var lean: float = 0.0
var stamina: float = 100.0
## Planar speed at the END of the tick, m/s.
var speed: float = 0.0
## Seconds since the feet last left the ground.
var air: float = 0.0
## Bob phase in radians. A footstep fires every PI of it.
var bob_t: float = 0.0
## Stair smoother: the feet snap, this holds the camera back, and it damps to zero.
var cam_y: float = 0.0
## Landing dip offset, metres. Negative is down.
var land_dip: float = 0.0
var ground_normal: Vector3 = Vector3.UP
## Indexes `WorldSurface.Kind`. 3 is sand.
var ground_surface: int = 3
var ladder: PlayerLadder = null
## The exclusive movement state plus everything a consumer would otherwise poll for.
## Rewritten in place at the end of every tick; never replaced, so a reference taken
## once stays valid.
var state: PlayerState = PlayerState.new()
var freecam_active: bool = false
var input_suspended: bool = false
## Unit wish direction in world XZ; x is world X, y is world Z.
var wish: Vector2 = Vector2.ZERO
## The eye anchors this tick straddles. The camera rig lerps between them so a 60 Hz
## body reads smooth on a 144 Hz screen.
var view_prev: Vector3 = Vector3.ZERO
var view_curr: Vector3 = Vector3.ZERO

var _mantle: PlayerMantle = PlayerMantle.new()
var _probe: PlayerProbe = PlayerProbe.new()
var _exclude: Array[RID] = []
var _move_input: Vector2 = Vector2.ZERO
var _wish_scale: float = 0.0
var _want_crouch: bool = false
var _crouching: bool = false
var _want_sprint: bool = false
var _jump_held: bool = false
var _jump_buf: float = 0.0
var _coyote: float = 0.0
var _stamina_lock: float = 0.0
var _speed_now: float = 0.0
var _bob_step: float = 0.0
var _land_vel: float = 0.0
var _fall_start: float = 0.0
var _bumped: bool = false
var _bump_normal: Vector2 = Vector2.ZERO
## Planar speed the body carried INTO the wall it bumped, sampled before the collision
## response clipped the into-wall component away. The auto vault gates on this, not on
## the tick's opening speed — by the time a bump is known the opening speed is a lie.
var _bump_speed: float = 0.0
var _ground_rid: RID = RID()
var _spawn_position: Vector3 = Vector3.ZERO
var _spawn_yaw: float = 0.0
var _height: float = 1.80
var _settings: GameSettingsScript = null
var _router: SceneRouterScript = null
var _camera: Camera3D = null

## Health, armour, death and respawn. Installed here rather than authored into a
## scene, which is what makes the player damageable in EVERY demo that has one.
@onready var health: PlayerHealth = PlayerHealth.install(self)

@onready var _body: CollisionShape3D = get_node(body_shape_path)


func _ready() -> void:
	_exclude = [get_rid()]
	_height = stand_height
	_spawn_position = global_position
	_spawn_yaw = yaw
	_fall_start = global_position.y
	_mantle.step_height = step_height
	_mantle.clear_radius = radius * 0.92
	_mantle.clear_height = crouch_height + 0.06
	_apply_body_height(stand_height)
	_settings = get_node_or_null(^"/root/GameSettings") as GameSettingsScript
	_router = get_node_or_null(^"/root/SceneRouter") as SceneRouterScript
	_camera = get_node_or_null(camera_path) as Camera3D
	if _router != null:
		_router.pause_changed.connect(_on_pause_changed)


func _unhandled_input(event: InputEvent) -> void:
	if input_suspended or freecam_active:
		return
	if not (event is InputEventMouseMotion):
		return
	if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		return
	var motion := event as InputEventMouseMotion
	# Applied the instant the event arrives rather than once per tick: at 144 fps that
	# is the difference between crisp and swimmy, and it costs nothing.
	if _settings == null:
		return
	# Divided by the magnification, then trimmed by the user's ADS preference. The trim
	# blends with the shoulder instead of stepping at the halfway mark.
	var sens: float = _settings.mouse_sensitivity * look_scale
	if _camera != null:
		sens *= PlayerLocomotion.fov_sens_scale(_camera.fov, _settings.fov)
	sens *= lerpf(1.0, _settings.ads_sensitivity_scale, ads)
	yaw -= motion.relative.x * sens
	var dy: float = motion.relative.y * sens
	if _settings.invert_y:
		dy = -dy
	pitch = clampf(pitch - dy, -pitch_limit, pitch_limit)


func _physics_process(delta: float) -> void:
	var dt: float = minf(delta, 0.06)
	view_prev = view_anchor()
	was_grounded = grounded
	if freecam_active:
		velocity = Vector3.ZERO
		speed = 0.0
	else:
		_tick(dt)
	view_curr = view_anchor()
	_sync_state(dt)


## Where the eye sits before bob, lean and dip are added. The camera rig interpolates
## between the last two of these so a 60 Hz body never judders on a 144 Hz screen.
func view_anchor() -> Vector3:
	var eye: float = lerpf(stand_eye, crouch_eye, crouch_t)
	return global_position + Vector3(0.0, eye + cam_y, 0.0)


func eye_position() -> Vector3:
	return view_anchor()


func forward() -> Vector3:
	return Vector3(-sin(yaw), 0.0, -cos(yaw))


func is_mantling() -> bool:
	return _mantle.active


## Recoil's horizontal shove on the body. GUNS calls this on each shot.
func apply_shove(amount: float) -> void:
	var f: Vector3 = forward()
	velocity.x -= f.x * amount
	velocity.z -= f.z * amount


func teleport(to: Vector3, to_yaw: float) -> void:
	global_position = to
	yaw = to_yaw
	velocity = Vector3.ZERO
	cam_y = 0.0
	land_dip = 0.0
	_land_vel = 0.0
	_fall_start = to.y
	slide.reset()
	_mantle.cancel()
	_detach_ladder()
	view_prev = view_anchor()
	view_curr = view_prev


## THE DAMAGE SEAM. `AITarget.receive_damage` resolves `receiver_path` — default `..`,
## this node — and forwards a hit only to this exact pair, which is also what
## `EnemyActor` answers to. A round does not care which side of the fight it landed on.
func apply_damage(amount: float, from_position: Vector3, attacker: Node = null) -> void:
	health.apply_damage(amount, from_position, attacker)


func health_fraction() -> float:
	return health.health_fraction()


func set_spawn(to: Vector3, to_yaw: float) -> void:
	_spawn_position = to
	_spawn_yaw = to_yaw


func respawn() -> void:
	teleport(_spawn_position, _spawn_yaw)
	respawned.emit()


## Freecam took over. The body stops dead rather than coasting on under the camera.
func set_freecam_active(value: bool) -> void:
	if freecam_active == value:
		return
	freecam_active = value
	velocity = Vector3.ZERO
	_jump_buf = 0.0
	slide.reset()
	if value:
		_mantle.cancel()
		_detach_ladder()


## For the weapon bench and anything else that wants the cursor back without pausing.
func set_input_suspended(value: bool) -> void:
	input_suspended = value
	if value:
		_move_input = Vector2.ZERO
		wish = Vector2.ZERO
		_wish_scale = 0.0
		is_moving = false
		_want_sprint = false
		_want_crouch = false
		_jump_held = false
		_jump_buf = 0.0


func _tick(dt: float) -> void:
	_probe.bind(get_world_3d().direct_space_state, _exclude, collision_mask)
	_read_input()
	_speed_now = Vector2(velocity.x, velocity.z).length()
	sprinting = (
		_want_sprint and _move_input.y > 0.0 and not _want_crouch and stamina > 1.0 and ads < 0.4
	)
	_update_slide(dt)
	_update_stance(dt)
	if _mantle.active:
		_step_mantle(dt)
		_post_move(dt)
		return
	if _update_ladder(dt):
		_post_move(dt)
		return
	if grounded:
		_ground_move(dt)
	else:
		_air_move(dt)
	_jump_buf = maxf(0.0, _jump_buf - dt)
	if _mantle.active:
		_post_move(dt)
		return
	# Vault triggers read the bump `_integrate` just recorded. They ran BEFORE the move
	# once, which meant the wall contact they were looking for was always one tick stale
	# and the speed gate was reading a velocity the wall had already flattened — the auto
	# vault could not fire at all. Keep this after the move.
	_integrate(dt)
	_update_landing()
	_vault_triggers()
	_post_move(dt)


func _read_input() -> void:
	if input_suspended:
		return
	_move_input.x = Input.get_axis(&"move_left", &"move_right")
	_move_input.y = Input.get_axis(&"move_back", &"move_forward")
	_want_crouch = Input.is_action_pressed(&"crouch")
	_want_sprint = Input.is_action_pressed(&"sprint")
	_jump_held = Input.is_action_pressed(&"jump")
	if Input.is_action_just_pressed(&"jump"):
		_jump_buf = jump_buffer_time
	# Forward is `(-sin yaw, -cos yaw)`, right is `(cos yaw, -sin yaw)`: two trig calls.
	var sy: float = sin(yaw)
	var cy: float = cos(yaw)
	var wx: float = -sy * _move_input.y + cy * _move_input.x
	var wz: float = -cy * _move_input.y - sy * _move_input.x
	var mag: float = sqrt(wx * wx + wz * wz)
	is_moving = mag > 1e-4
	if is_moving:
		wish = Vector2(wx / mag, wz / mag)
		# Keyboard diagonals give 1.414 and clamp to 1, matching the reference exactly.
		# A stick keeps its magnitude, which the reference had no way to express.
		_wish_scale = minf(mag, 1.0)
	else:
		wish = Vector2.ZERO
		_wish_scale = 0.0


func _update_slide(dt: float) -> void:
	if slide.can_enter(_want_crouch, sliding, grounded, _speed_now):
		sliding = true
		stamina = maxf(0.0, stamina - stamina_slide_cost * slide.stamina_share(_speed_now))
		_stamina_lock = 0.5
		velocity = slide.enter(velocity, yaw, _move_input.x)
		slide_changed.emit(true)
	if not sliding:
		slide.lock -= dt
		return
	if slide.tick(dt, _want_crouch, grounded, air, PlayerLocomotion.planar_speed(velocity)):
		sliding = false
		slide_changed.emit(false)


func _update_stance(dt: float) -> void:
	_crouching = _want_crouch or sliding
	# Only pay for the head-room query when standing up is actually on the table.
	if not _crouching and crouch_t > 0.001:
		_crouching = not _probe.can_stand(global_position, stand_height, radius * 0.92)
	var rate: float = slide_crouch_rate if sliding else crouch_rate
	crouch_t = PlayerLocomotion.damp(crouch_t, 1.0 if _crouching else 0.0, rate, dt)
	_apply_body_height(lerpf(stand_height, crouch_height, crouch_t))


func _apply_body_height(h: float) -> void:
	if absf(h - _height) < 1e-4:
		return
	_height = h
	var shape := _body.shape as CylinderShape3D
	if shape == null:
		return
	shape.height = h
	shape.radius = radius
	_body.position.y = h * 0.5


func _ground_move(dt: float) -> void:
	_coyote = coyote_time
	air = 0.0
	if sliding:
		velocity = slide.step(velocity, ground_normal, wish, is_moving, gravity, dt)
	else:
		_walk_physics(dt)
	if _jump_buf <= 0.0:
		return
	_jump_buf = 0.0
	if not sliding and _begin_mantle(mantle_manual_rise, _speed_now):
		return
	_launch(sliding)


## Leave the ground. `from_slide` is the whole difference between a hop and the thing
## the slide exists for, and it is passed in rather than read off `sliding` because the
## coyote branch fires after the slide has already been cancelled by the lip.
func _launch(from_slide: bool) -> void:
	if from_slide:
		velocity = slide.launch_velocity(velocity, jump_velocity)
		if sliding:
			sliding = false
			slide_changed.emit(false)
	else:
		velocity.y = jump_velocity
		slide.plain_jump()
	grounded = false
	_coyote = 0.0
	stamina = maxf(0.0, stamina - stamina_jump_cost)
	_stamina_lock = 0.30
	jumped.emit()


func _walk_physics(dt: float) -> void:
	var target: float = PlayerLocomotion.ground_target_speed(
		walk_speed,
		sprint_speed,
		crouch_speed,
		_crouching,
		sprinting,
		ads,
		ads_speed_mul,
		backpedal_mul,
		_move_input.y < 0.0,
		_wish_scale
	)
	# Skipping friction on a buffered jump is what carries speed through a bunny hop.
	if not (_jump_held and _jump_buf > 0.0):
		var f: float = friction * (1.0 if is_moving else idle_brake_mul)
		velocity = PlayerLocomotion.apply_friction(velocity, f, stop_speed, dt)
	if not is_moving:
		return
	# Project the wish direction onto the slope, else you accelerate into the hill.
	var p: Vector2 = PlayerLocomotion.project_on_slope(wish.x, wish.y, ground_normal)
	if p == Vector2.ZERO:
		return
	velocity = PlayerLocomotion.accelerate(velocity, p.x, p.y, target, ground_accel, dt)


func _air_move(dt: float) -> void:
	air += dt
	_coyote -= dt
	if _coyote > 0.0 and _jump_buf > 0.0:
		_jump_buf = 0.0
		# Cresting a lip cancels the slide before the buffered jump is read, so the
		# coyote branch has to remember that it was one. Without this, the single most
		# satisfying input in the game — slide off a roof edge, tap jump — is a hop.
		_launch(sliding or slide.air > 0.0)
	if is_moving:
		velocity = PlayerLocomotion.accelerate(
			velocity, wish.x, wish.y, air_wish_speed, air_accel, dt
		)
		# On top of the Quake accelerate, not instead of it: strafe-jumping gains speed
		# exactly as it did. The redirect only rotates, and only inside the slide-jump
		# window, which is what keeps the slide-jump the thing with the good air control.
		velocity = slide.redirect(velocity, wish, dt)
	velocity = PlayerLocomotion.apply_gravity(velocity, gravity, terminal_velocity, dt)


func _vault_triggers() -> void:
	if _bumped and not _mantle.active:
		var into: float = wish.x * _bump_normal.x + wish.y * _bump_normal.y
		if is_moving and into > 0.35 and (grounded or air < 0.5) and _bump_speed > 2.6:
			_begin_mantle(mantle_auto_rise, _bump_speed)
	if _jump_held and not grounded and not _mantle.active and air > 0.05:
		_begin_mantle(mantle_manual_rise, maxf(_speed_now, _bump_speed))


func _begin_mantle(max_rise: float, speed: float) -> bool:
	if ladder != null or freecam_active:
		return false
	if not _mantle.plan(_probe, global_position, yaw, max_rise, speed):
		return false
	velocity = Vector3.ZERO
	if sliding:
		sliding = false
		slide_changed.emit(false)
	mantle_started.emit(_mantle.rise)
	return true


func _step_mantle(dt: float) -> void:
	global_position = _mantle.advance(dt)
	cam_y = PlayerLocomotion.damp(cam_y, -0.10, 14.0, dt)
	if _mantle.active:
		return
	var f: Vector3 = forward()
	var sp: float = _mantle.exit_speed()
	velocity = Vector3(f.x * sp, 0.4, f.z * sp)
	grounded = true
	air = 0.0
	_fall_start = global_position.y


func _integrate(dt: float) -> void:
	# Cleared here rather than per substep: a bump on the first of three substeps is still
	# the bump this tick made, and clearing it inside `_resolve_xz` threw it away again
	# before anything could read it.
	_bumped = false
	_bump_speed = 0.0
	var steps: int = clampi(ceili(velocity.length() * dt / SUBSTEP_TRAVEL), 1, MAX_SUBSTEPS)
	var sdt: float = dt / float(steps)
	for _i: int in steps:
		_resolve_xz(sdt)
		_resolve_y(sdt)
		# `was_grounded` is a one-tick memory, so a body that misses contact for one tick
		# can never re-acquire it. A walk never notices. A slide over a 6 cm ramp lip
		# free-falls the rest of the descent; a chain link takes its surplus and is then
		# left 7 cm clear of the face with nothing to pull it back. Follow the ground
		# while sliding or chaining, bounded by `snap_probe`. See `stick_to_plane`.
		var follow: bool = was_grounded or sliding or slide.chain > 0.0
		if not grounded and follow and velocity.y <= 0.2 and ladder == null:
			_snap_down()
	if global_position.y < void_y:
		respawn()


## Horizontal motion, slid along whatever it hits, with step-up folded in exactly where
## the reference folds it in. Stepping is attempted on ANY blocker while grounded, not
## only on a steep one. That is deliberate and it is worth two paragraphs.
##
## A cylinder walking up a flight of stairs does not only hit the riser. Half the time it
## catches the top edge of the step, and an edge contact reports a shallow, floor-like
## normal — which, if it is treated as a floor, has its horizontal component subtracted
## out of the velocity. Measured on a 31-degree flight at sprint that costs a third of
## the speed and turns a clean run-up into a stutter. Stepping on the edge contact keeps
## it. The same rule is what rescues you from a coplanar seam between two baked
## colliders: it lifts, clears the crack, and puts you back down at the same height,
## which reads as nothing at all having happened.
##
## It is safe because `_try_step` refuses anything that does not land on walkable ground
## within one step height, and restores the saved position when it refuses.
func _resolve_xz(dt: float) -> void:
	var remaining := Vector3(velocity.x * dt, 0.0, velocity.z * dt)
	if remaining.length_squared() <= 1e-12:
		return
	var floor_cos: float = cos(floor_max_angle)
	for _i: int in MAX_SLIDES:
		var col: KinematicCollision3D = move_and_collide(remaining, false, collision_margin)
		if col == null:
			return
		var n: Vector3 = col.get_normal()
		var rest: Vector3 = col.get_remainder()
		if not _bumped:
			_bumped = true
			# Sampled here, before the clip below eats the into-wall component. This is
			# the speed the vault gate means when it says "running at a wall".
			_bump_speed = Vector2(velocity.x, velocity.z).length()
			var flat := Vector2(-n.x, -n.z)
			_bump_normal = flat.normalized() if flat.length_squared() > 1e-8 else Vector2.ZERO
		if (grounded or _coyote > 0.0) and _try_step(rest, floor_cos):
			return
		var vn: float = velocity.x * n.x + velocity.z * n.z
		if vn < 0.0:
			velocity.x -= vn * n.x
			velocity.z -= vn * n.z
		remaining = rest.slide(n)
		remaining.y = 0.0
		if remaining.length_squared() <= 1e-12:
			return


## Lift, advance, drop. Accepted only when the drop lands on something walkable no more
## than a step higher than where we started, and only when the detour actually bought
## lateral ground. Everything else restores the saved position, so a failed attempt is
## invisible rather than a stutter.
func _try_step(rest: Vector3, floor_cos: float) -> bool:
	var saved: Vector3 = global_position
	var dir := Vector3(rest.x, 0.0, rest.z)
	# When the sweep spends its whole budget arriving at the riser the remainder is
	# nearly zero, and a step of nearly zero length lands back on the same floor and is
	# rejected — at which point the wall cancels the velocity outright and a full-speed
	# run up a staircase stutters to a stop every few risers. The forward leg therefore
	# has a floor of `step_forward_probe`, and falls back to the velocity direction when
	# the remainder has no direction left at all.
	if dir.length_squared() <= 1e-12:
		dir = Vector3(velocity.x, 0.0, velocity.z)
	if dir.length_squared() <= 1e-12:
		return false
	var flat: Vector3 = dir.normalized() * maxf(dir.length(), step_forward_probe)
	move_and_collide(Vector3(0.0, step_height, 0.0), false, collision_margin)
	var lifted: float = global_position.y - saved.y
	if lifted <= 0.0005:
		global_position = saved
		return false
	move_and_collide(flat, false, collision_margin)
	var gained: float = Vector2(global_position.x - saved.x, global_position.z - saved.z).length()
	var down: KinematicCollision3D = null
	if gained >= MIN_STEP_GAIN:
		down = move_and_collide(Vector3(0.0, -(lifted + 0.02), 0.0), false, collision_margin)
	var rise: float = global_position.y - saved.y
	if down == null or down.get_normal().y < floor_cos or rise > step_height + 0.001:
		global_position = saved
		return false
	# The feet jump, the camera does not. This offset is damped back to zero in
	# _post_move, and it is the entire reason stairs do not strobe.
	cam_y = clampf(cam_y - rise, -stair_smooth_max, stair_smooth_max)
	grounded = true
	ground_normal = down.get_normal()
	_read_surface(down)
	if velocity.y < 0.0:
		velocity.y = 0.0
	return true


func _resolve_y(dt: float) -> void:
	grounded = false
	var floor_cos: float = cos(floor_max_angle)
	var vy: float = velocity.y * dt
	if absf(vy) > 1e-9:
		var col: KinematicCollision3D = move_and_collide(
			Vector3(0.0, vy, 0.0), false, collision_margin
		)
		if col != null:
			var n: Vector3 = col.get_normal()
			if velocity.y <= 0.0 and n.y >= floor_cos:
				_touch_down(n)
				grounded = true
				ground_normal = n
				_read_surface(col)
			elif velocity.y > 0.0 and n.y < -0.1:
				velocity.y = 0.0
			elif velocity.y < 0.0 and n.y > 0.01:
				_deflect_steep(col, n)
	if grounded or velocity.y > 0.0:
		return
	# The skin test, not the move above, is what keeps `grounded` true while walking:
	# on flat ground velocity.y is zero, so there is no downward move to collide with.
	var probe: KinematicCollision3D = move_and_collide(
		Vector3(0.0, -ground_skin, 0.0), true, collision_margin
	)
	if probe == null or probe.get_normal().y < floor_cos:
		return
	grounded = true
	ground_normal = probe.get_normal()
	_read_surface(probe)
	_touch_down(ground_normal)


## Feet on ground. Normally just `velocity.y = 0`; inside the slide-jump window with
## crouch held it is a chain link and `PlayerSlide.land` folds the descent into the plane.
func _touch_down(n: Vector3) -> void:
	velocity = slide.land(velocity, n, _want_crouch)


## A descent landed on a face steeper than `floor_max_angle`. It is not standable, so
## the fall is redirected along it instead of being stopped by it: the blocked remainder
## is re-applied down the slope and the velocity loses only its normal component. Without
## this the body pins itself to the face, gravity keeps piling into a velocity that
## cannot be spent, and the first walkable ledge below launches you off it.
func _deflect_steep(col: KinematicCollision3D, n: Vector3) -> void:
	var rest: Vector3 = col.get_remainder().slide(n)
	if rest.length_squared() > 1e-12:
		move_and_collide(rest, false, collision_margin)
	var slid: Vector3 = velocity.slide(n)
	velocity.x = slid.x * steep_slide_retain
	velocity.z = slid.z * steep_slide_retain
	velocity.y = slid.y


## Follow the ground down a drop rather than launching off it. Without this, walking
## off the top of a shallow ramp turns into a hop.
func _snap_down() -> void:
	if grounded or velocity.y > 0.9 or _mantle.active or ladder != null:
		return
	var probe: KinematicCollision3D = move_and_collide(
		Vector3(0.0, -snap_probe, 0.0), true, collision_margin
	)
	if probe == null or probe.get_normal().y < cos(floor_max_angle):
		return
	var dy: float = probe.get_travel().y
	global_position.y += dy
	cam_y = clampf(cam_y - dy, -stair_smooth_max, stair_smooth_max)
	velocity.y = 0.0
	grounded = true
	ground_normal = probe.get_normal()
	_read_surface(probe)


## Minecraft rules: walk into it to go up, back off to come down, do neither and you
## sink slowly. Returns true when the ladder owns this tick.
##
## The scan lives on `PlayerLadder` rather than here because the interact prompt asks the
## same question in the same frame, and the answer is cached per physics frame per query
## point. Two callers, one linear pass.
func _update_ladder(dt: float) -> bool:
	var l: PlayerLadder = PlayerLadder.find_for(global_position, _height)
	if l == null:
		_detach_ladder()
		return false
	var ox: float = l.out_x()
	var oz: float = l.out_z()
	var press_in: float = -(wish.x * ox + wish.y * oz) if is_moving else 0.0
	if ladder != l and press_in <= 0.12 and not _jump_held:
		_detach_ladder()
		return false
	if ladder != l:
		ladder = l
		ladder_changed.emit(true)
	sliding = false
	grounded = false
	_coyote = 0.0
	var climb: float = -0.14
	if _jump_held or press_in > 0.12:
		climb = 1.0
	elif press_in < -0.45:
		climb = -1.0
	velocity.y = climb * (ladder_climb_speed if climb > 0.0 else ladder_descend_speed)
	# Spring back to a fixed stand-off from the rungs, and shimmy sideways along them.
	var tx: float = l.global_position.x + ox * 0.20
	var tz: float = l.global_position.z + oz * 0.20
	var perp: float = ((tx - global_position.x) * ox + (tz - global_position.z) * oz) * 7.0
	var along: float = 0.0
	if is_moving:
		along = (wish.x * l.along_x() + wish.y * l.along_z()) * ladder_shimmy_speed
	velocity.x = ox * perp + l.along_x() * along
	velocity.z = oz * perp + l.along_z() * along
	if climb > 0.0 and global_position.y > l.top_y() - 0.75 and _ladder_top_out(l):
		return true
	_ladder_exits(l, press_in, ox, oz)
	bob_t += dt * absf(climb) * 7.5
	if bob_t - _bob_step > PI:
		_bob_step = bob_t
		stepped.emit(l.surface, 0.30)
	_integrate(dt)
	_jump_buf = maxf(0.0, _jump_buf - dt)
	return true


func _ladder_exits(l: PlayerLadder, press_in: float, ox: float, oz: float) -> void:
	if global_position.y >= l.top_y() + 0.15:
		_detach_ladder()
	elif global_position.y < l.bottom_y() - 0.25:
		_detach_ladder()
	if _jump_buf <= 0.0 or press_in > 0.12:
		return
	# Tapping jump while not pressing into the rungs kicks you off the wall. This runs
	# after the climb branch already wrote velocity, and overwrites it. Keep the order.
	_jump_buf = 0.0
	_detach_ladder()
	velocity = Vector3(ox * ladder_kick_out, ladder_kick_up, oz * ladder_kick_out)


## Step off the top of a ladder onto whatever is up there. Roof side is tried first,
## then the outward side, because on a roof ladder the far side is usually a drop.
func _ladder_top_out(l: PlayerLadder) -> bool:
	for dir: float in [-1.0, 1.0]:
		var tx: float = l.global_position.x + l.out_x() * 0.85 * dir
		var tz: float = l.global_position.z + l.out_z() * 0.85 * dir
		var top: float = _probe.top_at(tx, tz, global_position.y - 0.75, global_position.y + 1.0)
		if is_nan(top):
			continue
		if not _probe.can_stand(Vector3(tx, top + 0.05, tz), crouch_height + 0.06, radius * 0.92):
			continue
		global_position = Vector3(tx, top + 0.03, tz)
		velocity = Vector3.ZERO
		_detach_ladder()
		grounded = true
		air = 0.0
		_fall_start = global_position.y
		cam_y = clampf(cam_y - 0.12, -stair_smooth_max, stair_smooth_max)
		return true
	return false


func _detach_ladder() -> void:
	if ladder == null:
		return
	ladder = null
	ladder_changed.emit(false)


func _update_landing() -> void:
	if grounded and not was_grounded:
		var fall: float = _fall_start - global_position.y
		var impact: float = clampf(fall / 7.0, 0.0, 1.0)
		_land_vel -= 0.13 + impact * 0.30
		landed.emit(ground_surface, impact, fall)
		if fall > hard_landing_height:
			hard_landing.emit(clampf((fall - hard_landing_height) / 9.0, 0.0, 0.9))
			# A chained landing rolls the drop out instead of eating it. Read off
			# `from_slide`, not the window, which `_touch_down` has already spent.
			var keep: float = slide.impact_keep(slide.from_slide and _want_crouch)
			velocity.x *= keep
			velocity.z *= keep
		air = 0.0
		slide.from_slide = false
	# Reset the fall reference while standing, and once more on the tick the feet leave
	# the ground. Not while airborne, or every fall would measure zero.
	if grounded or was_grounded:
		_fall_start = global_position.y


func _post_move(dt: float) -> void:
	var sp: float = PlayerLocomotion.planar_speed(velocity)
	slide.advance(dt, grounded, sliding, _move_input.x)
	_stamina_lock = maxf(0.0, _stamina_lock - dt)
	if sprinting and sp > 3.2 and grounded:
		stamina = maxf(0.0, stamina - stamina_drain * dt)
	elif _stamina_lock <= 0.0:
		stamina = minf(100.0, stamina + stamina_regen * dt)
	if stamina <= 0.5:
		sprinting = false
	var blocked: bool = sprinting or sliding or input_suspended or ladder != null
	var ads_want: float = 1.0 if Input.is_action_pressed(&"aim") and not blocked else 0.0
	ads = PlayerLocomotion.damp(ads, ads_want, ads_damp_rate, dt)
	_update_lean(dt)
	_update_bob(sp, dt)
	cam_y = PlayerLocomotion.damp(cam_y, 0.0, stair_smooth_rate, dt)
	_step_land_spring(dt)
	speed = sp


## Rewrite the shared snapshot in place and fire `state_changed` on the edge. This is the
## last thing a tick does, so anything that reads `state` from the signal — or from any
## later frame — sees a fully settled body rather than a half-resolved one.
func _sync_state(dt: float) -> void:
	state.velocity = velocity
	state.planar_speed = speed
	state.feet = global_position
	state.eye = view_curr
	state.height = _height
	state.radius = radius
	state.crouch_t = crouch_t
	state.grounded = grounded
	state.ground_normal = ground_normal
	state.ground_slope = acos(clampf(ground_normal.y, -1.0, 1.0))
	state.ground_surface = ground_surface
	state.air_time = air
	state.sprinting = sprinting
	state.ads = ads
	state.stamina = stamina
	state.lean = lean
	state.slide_bank = slide.bank
	state.slide_launch = slide.launch
	state.yaw = yaw
	state.pitch = pitch
	if state.advance(dt, _mantle.active, ladder != null, sliding, grounded, crouch_t):
		state_changed.emit(int(state.previous), int(state.kind))


func _update_lean(dt: float) -> void:
	var want: float = 0.0
	if lean_left_action != &"" and lean_right_action != &"":
		want = Input.get_axis(lean_left_action, lean_right_action) * lean_amount
		if sprinting or sliding:
			want = 0.0
	if not is_zero_approx(want):
		# Do not lean into a wall.
		var lx: float = cos(yaw) * want
		var lz: float = -sin(yaw) * want
		var at := global_position + Vector3(lx * 0.55, 0.6, lz * 0.55)
		if not _probe.can_stand(at, 0.6, 0.22):
			want = 0.0
	lean = PlayerLocomotion.damp(lean, want, lean_damp_rate, dt)


func _update_bob(sp: float, dt: float) -> void:
	var bob_speed: float = sp if grounded and not sliding else 0.0
	bob_t += dt * (bob_idle_rate + bob_speed * bob_speed_gain)
	if bob_speed <= step_min_speed:
		# Park the phase half a stride back so the next step lands promptly.
		_bob_step = bob_t - PI * 0.5
		return
	if bob_t - _bob_step > PI:
		_bob_step = bob_t
		stepped.emit(ground_surface, clampf(0.22 + sp * 0.085, 0.2, 1.0))


## Landing dip, integrated on a fixed 120 Hz sub-step. Explicit Euler on a stiffness of
## 120 is stable at 60 Hz but the spec is explicit that these springs are not
## frame-rate independent, so it does not get to depend on the tick rate.
func _step_land_spring(dt: float) -> void:
	var steps: int = maxi(1, ceili(dt * 120.0))
	var sdt: float = dt / float(steps)
	for _i: int in steps:
		_land_vel += -land_dip * land_spring_stiffness * sdt - _land_vel * land_spring_damping * sdt
		land_dip += _land_vel * sdt


func _read_surface(col: KinematicCollision3D) -> void:
	var rid: RID = col.get_collider_rid()
	if rid == _ground_rid:
		return
	_ground_rid = rid
	ground_surface = 3
	var shape: Object = col.get_collider_shape()
	if shape != null and shape.has_meta(&"surf"):
		ground_surface = int(shape.get_meta(&"surf"))
		return
	var body: Object = col.get_collider()
	if body != null and body.has_meta(&"surf"):
		ground_surface = int(body.get_meta(&"surf"))


func _on_pause_changed(is_paused: bool) -> void:
	if is_paused:
		_jump_buf = 0.0
