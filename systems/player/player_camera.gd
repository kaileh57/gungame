class_name PlayerCameraRig
extends Camera3D
## The eye. Reads state off the controller and turns it into a transform and a field of
## view; it never writes back, so nothing here can change where the player ends up.
##
## The rig is `top_level` and positions itself in world space every rendered frame from
## the two view anchors the controller straddles. That interpolation is the reason a
## 60 Hz body looks smooth on a 144 Hz screen — without it the eye would step once per
## physics tick and every straight line in the world would shimmer.
##
## Euler order: three.js `Euler(x, y, z, 'YXZ')` composes R = Ry·Rx·Rz, and Godot's
## default `EULER_ORDER_YXZ` composes the same way, so the reference's camera code
## ports with no reordering. `rotation_order` is left at its default on purpose.
##
## Recoil is GUNS' to cause and this rig's to absorb: call `apply_recoil_impulse()` on
## each shot and the springs here do the rest.
##
## The rig is also where an optic finally becomes worth its score. `GunSpec` rolls a
## magnification and a ladder of levels; this is the one thing that reads them, and the
## shouldered FOV is derived from the selected level rather than being a constant.

## The magnification the shoulder is aiming at changed — either a different weapon came
## up or the wheel stepped the ladder. `scoped` says whether the world camera is doing
## the zooming or a scope tube is.
signal zoom_changed(level: float, index: int, scoped: bool)

## Bob amplitudes are the reference's, scaled by this. Motion sickness is a real
## failure mode and the reference was tuned on a small window; 0.8 keeps the weight of
## the walk cycle without the horizon swimming on a 27-inch monitor.
@export_range(0.0, 1.5, 0.01) var bob_scale: float = 0.8
@export_range(0.0, 0.2, 0.001) var bob_vertical: float = 0.036
@export_range(0.0, 0.2, 0.001) var bob_lateral: float = 0.050
@export_range(0.0, 0.1, 0.001) var bob_roll: float = 0.011

@export_group("Roll and lean")
## Radians of roll per m/s of sideways velocity. The strafe lean.
@export_range(0.0, 0.02, 0.0001) var strafe_roll: float = 0.0042
@export_range(1.0, 6.0, 0.05) var slide_roll_mul: float = 2.6
## Radians of bank at the peak of a slide, times `PlayerSlide.bank`. The controller owns
## the envelope — snap in, settle, steerable — and this is only how far it goes. Kept
## small on purpose: a sustained roll is the single most reliable way to make a speed
## feature nauseating, and 0.075 rad is 4.3 degrees, a dropped shoulder rather than a
## barrel roll.
@export_range(0.0, 0.3, 0.005) var slide_roll_bank: float = 0.075
@export_range(0.0, 0.6, 0.005) var lean_roll: float = 0.20
@export_range(0.0, 1.5, 0.01) var lean_offset: float = 0.46
@export_range(1.0, 40.0, 0.5) var roll_damp: float = 13.0

@export_group("Field of view")
## Base FOV. Overwritten from `GameSettings.fov` on ready and whenever it changes.
@export_range(50.0, 130.0, 0.5) var fov_base: float = 78.0
@export_range(0.0, 20.0, 0.1) var fov_sprint_bonus: float = 5.5
@export_range(0.0, 30.0, 0.1) var fov_slide_bonus: float = 8.0
## Speed at which the slide's FOV bonus starts growing, and the span over which it does.
@export_range(0.0, 30.0, 0.5) var fov_slide_speed_floor: float = 8.0
@export_range(1.0, 30.0, 0.5) var fov_slide_speed_span: float = 10.0
## Degrees of extra FOV per m/s over the floor.
@export_range(0.0, 3.0, 0.01) var fov_slide_speed_gain: float = 0.85
## Punch on leaving the ground out of a slide, easing out with `PlayerSlide.launch`.
## The slide's own bonus drops the instant the feet leave, and without this the launch
## reads as the view snapping BACK at the exact moment it should be opening up.
@export_range(0.0, 20.0, 0.1) var fov_slide_jump_kick: float = 6.0
@export_range(0.0, 2.0, 0.01) var fov_fall_gain: float = 0.30
@export_range(1.0, 30.0, 0.5) var fov_damp: float = 9.0
@export_range(1.0, 30.0, 0.5) var fov_damp_sliding: float = 7.0
## Hard ceiling on how fast the MOVEMENT part of the field of view may change, deg/s.
## This is the anti-nausea guarantee with a number on it: chaining slide-jumps steps the
## target around violently and a damper alone only slows the first part of the swing.
## Deliberately applied before the ADS blend, so a scope still comes up at full speed.
@export_range(5.0, 400.0, 1.0) var fov_max_rate: float = 90.0

@export_group("Optics")
## Magnification used when nothing is held, and the floor under any rolled optic. The
## reference's bare-irons zoom.
@export_range(1.0, 4.0, 0.01) var zoom_default: float = 1.15
## A SCOPED weapon does not zoom the world camera. You keep both eyes open, the view
## leans in by this much and the magnification happens inside the tube — which is what
## makes a scope read as a scope rather than as a wider crop of the same picture.
@export_range(1.0, 2.0, 0.01) var scoped_lean: float = 1.14
## Draw the sniper-scope picture when a scoped weapon is shouldered. Off is for a
## display stand or a cutscene, which has a camera but no shooter.
@export var scope_overlay: bool = true
## How far into the shoulder the magnification wheel takes over from weapon switching.
@export_range(0.1, 1.0, 0.01) var zoom_cycle_ads: float = 0.55
## Optional. A `WeaponHolster` whose equipped `GunSpec` supplies the zoom ladder.
@export var holster_path: NodePath = NodePath("Holster")

@export_group("Wiring")
@export var controller_path: NodePath = NodePath("..")
## Optional. A `PlayerViewEffects` whose shake and damage punch are added on top of
## everything computed here. Absent, the rig runs exactly as it did before it existed.
@export var effects_path: NodePath = NodePath("../Effects")
## Extra camera drop while sliding, metres.
@export_range(-0.5, 0.0, 0.005) var slide_drop: float = -0.10
## Recoil spring stiffness and damping, from the reference. Integrated on a fixed
## sub-step because explicit Euler at these rates is not frame-rate independent.
@export_range(20.0, 600.0, 1.0) var recoil_stiffness: float = 190.0
@export_range(1.0, 60.0, 0.5) var recoil_damping: float = 21.0

## Index into the current weapon's zoom ladder. Reset to the bottom rung on every swap,
## because coming up on 9x because the last gun was a sniper is how you lose a fight.
var zoom_index: int = 0

var _player: PlayerController = null
var _effects: PlayerViewEffects = null
var _holster: WeaponHolster = null
var _zoom_levels: PackedFloat32Array = PackedFloat32Array([1.15])
var _scoped: bool = false
var _scope: ScopeOverlay = null
var _roll: float = 0.0
var _fov: float = 78.0
## The movement-driven field of view before the ADS blend, rate-limited on its own so a
## scope is never slowed by a limiter that exists for the slide.
var _fov_move: float = 78.0
var _recoil: Vector3 = Vector3.ZERO
var _recoil_vel: Vector3 = Vector3.ZERO
var _fov_kick: float = 0.0


func _ready() -> void:
	top_level = true
	rotation_order = EULER_ORDER_YXZ
	_player = get_node_or_null(controller_path) as PlayerController
	if _player == null:
		push_error("PlayerCameraRig: controller_path does not point at a PlayerController.")
		set_process(false)
		return
	_effects = get_node_or_null(effects_path) as PlayerViewEffects
	fov_base = GameSettings.fov
	_fov = fov_base
	_fov_move = fov_base
	fov = _fov
	_zoom_levels = PackedFloat32Array([zoom_default])
	_bind_holster()
	_mount_scope()
	GameSettings.settings_changed.connect(_on_settings_changed)
	process_priority = 100


## Build the scope picture and hang it on its own layer.
##
## THE CAMERA OWNS IT because the camera is what knows the weapon is scoped and which
## rung of the ladder is selected, and because mounting it here means every armed level
## has a working scope instead of the ones that remembered to add one -- the same
## reasoning that put the ammunition plate on `WeaponHolster`.
##
## A high layer so the tube sits over the combat HUD: the crosshair and the hit markers
## belong to shooting from the hip, and drawing them across a scope picture is exactly
## the clutter the tube exists to remove.
func _mount_scope() -> void:
	if not scope_overlay:
		return
	var layer := CanvasLayer.new()
	layer.name = "ScopeLayer"
	layer.layer = 64
	add_child(layer)
	_scope = ScopeOverlay.new()
	_scope.name = "ScopeOverlay"
	layer.add_child(_scope)


func _process(delta: float) -> void:
	if _player.freecam_active:
		return
	var dt: float = minf(delta, 0.1)
	_step_recoil(dt)
	var f: float = Engine.get_physics_interpolation_fraction()
	_place(_player.view_prev.lerp(_player.view_curr, f), dt)
	_aim(dt)


## The mouse wheel is the magnification ladder once you are properly in the shoulder, and
## the weapon selector the rest of the time. Claimed in `_input` rather than
## `_unhandled_input` because the holster sits deeper in the tree and would otherwise
## swap the gun out from under the wheel before this ever saw the event.
func _input(event: InputEvent) -> void:
	if _player == null or _player.ads < zoom_cycle_ads or _zoom_levels.size() < 2:
		return
	if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		return
	var button := event as InputEventMouseButton
	if button == null or not button.pressed:
		return
	if button.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		cycle_zoom(1)
	elif button.button_index == MOUSE_BUTTON_WHEEL_UP:
		cycle_zoom(-1)
	else:
		return
	get_viewport().set_input_as_handled()


## Step the ladder, wrapping. `dir` is +1 to magnify.
func cycle_zoom(dir: int) -> void:
	var n: int = _zoom_levels.size()
	if n < 2:
		return
	zoom_index = posmod(zoom_index + (1 if dir > 0 else -1), n)
	zoom_changed.emit(current_zoom(), zoom_index, _scoped)


## The magnification the shoulder is currently set to.
func current_zoom() -> float:
	if _zoom_levels.is_empty():
		return zoom_default
	return _zoom_levels[clampi(zoom_index, 0, _zoom_levels.size() - 1)]


## True when the held weapon magnifies through a tube rather than by cropping the view.
func is_scoped() -> bool:
	return _scoped


## Fully shouldered FOV in degrees: `2*atan(tan(base/2) / z)`, where z is the selected
## rung of the weapon's own zoom ladder.
##
## SCOPES USED TO ZOOM *LESS* THAN IRON SIGHTS. The rule here was
## `scoped ? scoped_lean : zoom`, which handed a scoped weapon a flat 1.14x and threw
## its ladder away — and since scoped weapons are the ones whose ladders reach 4.2x to
## 5.4x, putting a real scope to your eye zoomed you in less than a set of irons with a
## middling optic. The reasoning behind it, recorded on `scoped_lean`, was that you keep
## both eyes open and the magnification happens inside the tube.
##
## THERE IS NO TUBE. Nothing in the project draws one: `zoom_changed` carries a `scoped`
## flag and has no listeners, and there is no overlay, no masked render and no reticle
## anywhere. So the magnification a scope was promised to do "inside the tube" was not
## happening anywhere at all, which is exactly what the player hit — twice — as "I
## cannot get the zoom scope to actually do the GUI zoom in any situation".
##
## Until a tube exists, a scope magnifies the world camera like every other optic, which
## is what makes it worth carrying. `scoped_lean` is kept because a real scope overlay
## is still the better answer and this is the number it will want back.
func ads_fov() -> float:
	var divisor: float = maxf(current_zoom(), 1.0)
	return rad_to_deg(2.0 * atan(tan(deg_to_rad(fov_base) * 0.5) / divisor))


## GUNS calls this once per shot. Pitch and yaw are radians of muzzle climb, roll is
## radians of body twist, kick is degrees of FOV punch.
func apply_recoil_impulse(pitch: float, yaw: float, roll: float, fov_kick: float) -> void:
	_recoil_vel.x += pitch
	_recoil_vel.y += yaw
	_recoil_vel.z += roll
	_fov_kick += fov_kick


func _place(anchor: Vector3, dt: float) -> void:
	var sp: float = _player.speed
	var bobbing: bool = _player.grounded and not _player.sliding
	var amp: float = 0.0
	if bobbing:
		amp = clampf(sp / _player.sprint_speed, 0.0, 1.15) * bob_scale
	var phase: float = _player.bob_t
	var by: float = sin(phase * 2.0) * bob_vertical * amp
	var bx: float = cos(phase) * bob_lateral * amp
	var br: float = cos(phase) * bob_roll * amp

	var side: float = _player.velocity.x * cos(_player.yaw) - _player.velocity.z * sin(_player.yaw)
	var roll_mul: float = slide_roll_mul if _player.sliding else 1.0
	var roll_target: float = -side * strafe_roll * roll_mul - _player.lean * lean_roll + br
	# The bank is a signed 0..1 envelope the controller shapes; this is only its depth.
	# Negative because a positive bank means "drop the right shoulder", and rolling the
	# camera right is a negative rotation about the view axis.
	roll_target -= _player.slide.bank * slide_roll_bank
	_roll = _damp(_roll, roll_target, roll_damp, dt)

	var off: float = _player.lean * lean_offset + bx * 0.5
	var drop: float = slide_drop if _player.sliding else 0.0
	global_position = Vector3(
		anchor.x + cos(_player.yaw) * off,
		anchor.y + by + _player.land_dip + drop,
		anchor.z - sin(_player.yaw) * off
	)


func _aim(dt: float) -> void:
	var shake: Vector3 = Vector3.ZERO if _effects == null else _effects.angles()
	var p: float = clampf(_player.pitch + _recoil.x, -1.56, 1.56) + _player.land_dip * 0.5
	global_rotation = Vector3(
		p + shake.x, _player.yaw + _recoil.y + shake.y, _roll + _recoil.z * 0.012 + shake.z
	)
	if _effects != null:
		# View-space, so a shake reads the same whether you are looking at the floor or
		# at the sky. Applied after the rotation for exactly that reason.
		var o: Vector3 = _effects.offset()
		if o != Vector3.ZERO:
			global_position += global_basis * o

	if _scope != null:
		_scope.set_state(_player.ads, _scoped, current_zoom())

	var sp: float = _player.speed
	var move: float = fov_base
	if _player.sprinting and sp > 4.0:
		move += fov_sprint_bonus * clampf((sp - 4.0) / 3.5, 0.0, 1.0)
	if _player.sliding:
		var over: float = clampf(sp - fov_slide_speed_floor, 0.0, fov_slide_speed_span)
		move += fov_slide_bonus + over * fov_slide_speed_gain
	move += fov_slide_jump_kick * _player.slide.launch
	if not _player.grounded:
		move += clampf(-_player.velocity.y - 6.0, 0.0, 16.0) * fov_fall_gain
	# Damped, then hard-limited. The damper alone cannot bound the swing when the target
	# steps six degrees in one tick, which is exactly what a chained launch does.
	var eased: float = _damp(_fov_move, move, fov_damp_sliding if _player.sliding else fov_damp, dt)
	var cap: float = fov_max_rate * dt
	_fov_move += clampf(eased - _fov_move, -cap, cap)
	# The outer damp is left exactly where it was so the shoulder and the recoil punch
	# behave as they did; only the movement term gained a limiter.
	var target: float = lerpf(_fov_move, ads_fov(), _player.ads) + _fov_kick
	if _effects != null:
		target += _effects.fov_offset()
	_fov = _damp(_fov, target, fov_damp_sliding if _player.sliding else fov_damp, dt)
	if absf(fov - _fov) > 0.01:
		fov = _fov


## Two second-order springs and one damper, on a fixed 1/240 s sub-step. At 30 fps the
## reference's explicit Euler on a stiffness of 190 starts to ring; sub-stepping costs
## four cheap iterations and makes the kick identical at every frame rate.
func _step_recoil(dt: float) -> void:
	var steps: int = clampi(ceili(dt * 240.0), 1, 16)
	var sdt: float = dt / float(steps)
	for _i: int in steps:
		_recoil_vel -= (_recoil * recoil_stiffness + _recoil_vel * recoil_damping) * sdt
		_recoil += _recoil_vel * sdt
	_fov_kick = _damp(_fov_kick, 0.0, 13.0, dt)


## Optics are optional wiring: a demo with no holster keeps bare irons and never notices.
func _bind_holster() -> void:
	if holster_path.is_empty():
		return
	_holster = get_node_or_null(holster_path) as WeaponHolster
	if _holster == null:
		return
	_holster.weapon_changed.connect(_on_weapon_changed)
	_holster.slot_equipped.connect(_on_slot_equipped)
	_adopt_spec(_holster.active_spec())


func _on_weapon_changed(_slot: int, spec: GunSpec) -> void:
	_adopt_spec(spec)


func _on_slot_equipped(slot: int, spec: GunSpec) -> void:
	if _holster != null and slot == _holster.active_slot:
		_adopt_spec(spec)


func _adopt_spec(spec: GunSpec) -> void:
	zoom_index = 0
	_scoped = spec != null and spec.scoped
	if spec == null:
		_zoom_levels = PackedFloat32Array([zoom_default])
	else:
		_zoom_levels = spec.zoom_ladder()
		if _zoom_levels.is_empty():
			_zoom_levels = PackedFloat32Array([maxf(spec.zoom, zoom_default)])
	zoom_changed.emit(current_zoom(), zoom_index, _scoped)


func _on_settings_changed(key: StringName, value: Variant) -> void:
	if key == &"fov":
		fov_base = float(value)


static func _damp(from: float, to: float, rate: float, dt: float) -> float:
	return lerpf(from, to, 1.0 - exp(-rate * dt))
