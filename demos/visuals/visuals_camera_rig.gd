class_name VisualsCameraRig
extends Node3D
## The slow pan. A camera walked along one baked curve, aimed at a point walked
## along a second one.
##
## Two curves rather than a curve and a look-at target: the eye and the subject
## want different speeds. The eye crawls a long shallow arc across the front of
## the settlement while the aim point slides from the watchtower to the plaza and
## back, so the frame keeps re-composing itself even on the straight stretches.
## A single spline with a tangent-facing camera gives you the opposite — a fixed
## composition on a moving mount, which reads as a level flythrough, not a shot.
##
## Nothing here is generated. `res://tools/build_visuals.gd` bakes both `Curve3D`
## resources into the scene; this script samples them.
##
## Both curves loop. The eye curve is closed, so `travel` wraps without a seam;
## the aim curve is open and ping-pongs, because an aim point that snaps back to
## the start would whip the camera at the loop point.

## The ride started or stopped.
signal riding_changed(riding: bool)

@export_group("Motion")
## Metres per second along the eye curve. Slow: this is a landscape shot.
@export_range(0.2, 12.0, 0.05) var eye_speed: float = 1.65
## Fraction of the aim curve crossed per second. Slower than the eye, so the
## subject drifts across frame rather than tracking with it.
@export_range(0.005, 0.5, 0.005) var aim_rate: float = 0.028
## Seconds for the camera to settle onto a new aim. Smooths the curve sampling
## and hides the ping-pong turnaround.
@export_range(0.05, 4.0, 0.01) var aim_damp: float = 0.9
## Degrees of roll dialled in across the ride, peaking mid-arc. A degree and a
## half is below conscious notice and above dead-flat.
@export_range(0.0, 6.0, 0.1) var roll_degrees: float = 1.4

@export_group("Lens")
@export_range(20.0, 110.0, 0.5) var fov: float = 46.0
## Metres the camera has travelled at scene load. Set this to frame the hero
## angle on the first frame, which is the shot the project is judged on.
@export_range(0.0, 400.0, 0.5) var start_travel: float = 0.0

@export_group("Curves")
@export var eye_curve: Curve3D = null
@export var aim_curve: Curve3D = null

## Distance walked along the eye curve, metres.
var travel: float = 0.0
## Position along the aim curve, 0..1, ping-ponged.
var aim_t: float = 0.0

var _riding: bool = false
var _aim_now: Vector3 = Vector3.ZERO
var _aim_dir: float = 1.0
var _eye_length: float = 0.0

@onready var _camera: Camera3D = $Camera


func _ready() -> void:
	_camera.top_level = true
	_camera.fov = fov
	_camera.current = false
	set_process(false)
	if eye_curve != null:
		_eye_length = eye_curve.get_baked_length()
	travel = start_travel
	_aim_now = _sample_aim()
	_place()


func _process(delta: float) -> void:
	if _eye_length <= 0.0:
		return
	travel = fposmod(travel + eye_speed * delta, _eye_length)
	aim_t += aim_rate * delta * _aim_dir
	if aim_t > 1.0:
		aim_t = 1.0
		_aim_dir = -1.0
	elif aim_t < 0.0:
		aim_t = 0.0
		_aim_dir = 1.0
	# Exponential approach, frame-rate independent. `aim_damp` is the time to
	# close 63 % of the gap, so the shot settles at the same rate at 60 and 144.
	var k: float = 1.0 - exp(-delta / maxf(aim_damp, 0.001))
	_aim_now = _aim_now.lerp(_sample_aim(), k)
	_place()


func is_riding() -> bool:
	return _riding


## Hand the viewport to the rig, or give it back. The camera the ride interrupted
## is remembered and made current again on the way out, so this composes with the
## freecam instead of fighting it.
func set_riding(value: bool) -> void:
	if _riding == value:
		return
	_riding = value
	set_process(value)
	if value:
		_camera.fov = fov
		_place()
		_camera.make_current()
	riding_changed.emit(value)


func camera() -> Camera3D:
	return _camera


func _place() -> void:
	if eye_curve == null or _eye_length <= 0.0:
		return
	var eye: Vector3 = to_global(eye_curve.sample_baked(travel, true))
	var to_subject: Vector3 = _aim_now - eye
	if to_subject.length_squared() < 0.0001:
		return
	_camera.global_position = eye
	_camera.look_at(_aim_now, Vector3.UP)
	if is_zero_approx(roll_degrees):
		return
	var phase: float = travel / _eye_length * TAU
	_camera.rotate_object_local(Vector3.FORWARD, deg_to_rad(roll_degrees) * sin(phase))


func _sample_aim() -> Vector3:
	if aim_curve == null:
		return global_position
	return to_global(aim_curve.sample_baked(aim_t * aim_curve.get_baked_length(), true))
