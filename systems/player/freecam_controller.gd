class_name FreecamController
extends Camera3D
## A noclip camera that can be dropped into any scene and toggled with the contract's
## `freecam_toggle` action.
##
## It is deliberately self-sufficient: on activation it adopts whatever camera was
## current — transform, FOV, clip planes — makes itself current, and hands everything
## back untouched on deactivation. A demo with no player at all still gets a working
## freecam by adding this one node; the player scene wires `player_path` so the body
## stops dead instead of coasting on underneath.
##
## Movement is a damped velocity rather than a direct position write. Instant
## teleporting reads as jitter at any speed above a walk, and the whole point of a
## freecam is looking at things.
##
## Near plane sits at 0.05 m. Below that a 32-bit depth buffer starts to z-fight at
## distance, which is the "clipping weirdness" a naive freecam gets when it flies its
## default 0.05-with-a-4000-far-plane setup through a building.

signal freecam_changed(is_active: bool)

## Metres per second at the default speed multiplier.
@export_range(0.5, 60.0, 0.1) var base_speed: float = 15.0
## Held-sprint multiplier. 46/15 is the reference's fast freecam.
@export_range(1.0, 10.0, 0.05) var sprint_mul: float = 3.07
## Held-aim multiplier, for creeping the camera into position.
@export_range(0.01, 1.0, 0.01) var slow_mul: float = 0.22
## Wheel steps multiply this in and out, clamped to [0.05, 20].
@export_range(1.01, 2.0, 0.01) var wheel_step: float = 1.18
## Seconds-scale approach rate for the velocity damper. Higher is twitchier.
@export_range(1.0, 40.0, 0.5) var move_damp: float = 12.0
@export_range(1.0, 40.0, 0.5) var look_damp: float = 30.0
@export_range(0.1, 4.0, 0.01) var look_scale: float = 1.0
@export_range(0.5, 1.55, 0.005) var pitch_limit: float = 1.53
@export_range(0.01, 1.0, 0.01) var near_plane: float = 0.05
## Optional. When set, the player controller is told to stand down while flying.
@export var player_path: NodePath = NodePath()

var active: bool = false

var _player: PlayerController = null
var _prev_camera: Camera3D = null
var _yaw: float = 0.0
var _pitch: float = 0.0
var _yaw_target: float = 0.0
var _pitch_target: float = 0.0
var _velocity: Vector3 = Vector3.ZERO
var _speed_mul: float = 1.0


func _ready() -> void:
	top_level = true
	rotation_order = EULER_ORDER_YXZ
	near = near_plane
	current = false
	set_process(false)
	_player = get_node_or_null(player_path) as PlayerController


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"freecam_toggle"):
		get_viewport().set_input_as_handled()
		set_active(not active)
		return
	if not active or Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		return
	if event is InputEventMouseMotion:
		var motion := event as InputEventMouseMotion
		var sens: float = GameSettings.mouse_sensitivity * look_scale
		_yaw_target -= motion.relative.x * sens
		_pitch_target = clampf(_pitch_target - motion.relative.y * sens, -pitch_limit, pitch_limit)
		return
	if event.is_action_pressed(&"weapon_next"):
		_set_speed_mul(_speed_mul * wheel_step)
	elif event.is_action_pressed(&"weapon_prev"):
		_set_speed_mul(_speed_mul / wheel_step)


func _process(delta: float) -> void:
	var dt: float = minf(delta, 0.1)
	var k: float = 1.0 - exp(-look_damp * dt)
	_yaw = lerpf(_yaw, _yaw_target, k)
	_pitch = lerpf(_pitch, _pitch_target, k)
	global_rotation = Vector3(_pitch, _yaw, 0.0)

	var ix: float = Input.get_axis(&"move_left", &"move_right")
	var iz: float = Input.get_axis(&"move_back", &"move_forward")
	var lift: float = 0.0
	if Input.is_action_pressed(&"jump"):
		lift += 1.0
	if Input.is_action_pressed(&"crouch"):
		lift -= 1.0
	var mul: float = _speed_mul
	if Input.is_action_pressed(&"sprint"):
		mul *= sprint_mul
	elif Input.is_action_pressed(&"aim"):
		mul *= slow_mul

	# Forward follows the pitch, so looking down and pushing forward flies down. The
	# lift axis stays world-vertical, which is what makes it usable as a camera.
	var basis3: Basis = global_basis
	var wanted: Vector3 = (-basis3.z * iz + basis3.x * ix) * base_speed * mul
	wanted.y += lift * base_speed * mul
	_velocity = _velocity.lerp(wanted, 1.0 - exp(-move_damp * dt))
	global_position += _velocity * dt


## Turn the freecam on or off. Idempotent, and safe to call from a debug menu.
func set_active(value: bool) -> void:
	if active == value:
		return
	active = value
	if active:
		_enter()
	else:
		_leave()
	if _player != null:
		_player.set_freecam_active(active)
	freecam_changed.emit(active)


func _enter() -> void:
	var from: Camera3D = get_viewport().get_camera_3d()
	if from != null and from != self:
		_prev_camera = from
		global_transform = from.global_transform
		fov = from.fov
		far = from.far
	near = near_plane
	var e: Vector3 = global_basis.get_euler(EULER_ORDER_YXZ)
	_yaw = e.y
	_pitch = clampf(e.x, -pitch_limit, pitch_limit)
	_yaw_target = _yaw
	_pitch_target = _pitch
	_velocity = Vector3.ZERO
	current = true
	set_process(true)


func _leave() -> void:
	set_process(false)
	_velocity = Vector3.ZERO
	# Only give the view back if there is something to give it back to. In a scene
	# whose only camera is this one, staying current and simply stopping is the honest
	# behaviour; going dark is not.
	if _prev_camera != null and is_instance_valid(_prev_camera):
		current = false
		_prev_camera.make_current()
	_prev_camera = null


func _set_speed_mul(value: float) -> void:
	_speed_mul = clampf(value, 0.05, 20.0)
