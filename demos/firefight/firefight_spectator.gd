class_name FirefightSpectator
extends Node
## The viewer. A camera, a gaze cursor and nothing else — no body, no collider,
## no health, no weapon. There is no code path in this demo that can damage the
## spectator because there is nothing standing anywhere for a bullet to hit.
##
## HOW YOU OPERATE ANYTHING. Point the camera at one of the posts and press
## interact. Selection is resolved against a cached list of everything in the
## `firefight_control` group, by angle first and distance second, eight times a
## second — a gaze cursor does not need to be exact, it needs to be stable, and
## re-resolving it every frame makes it flicker between two posts that are nearly
## in line. The selected control shows it itself; this node draws nothing.
##
## FLIGHT. `fly_to` stands the freecam down for the duration and drives the
## transform directly, then hands it back. `FreecamController` re-reads its yaw
## and pitch out of the transform on reactivation, so the camera you get back is
## aimed where the flight left it rather than snapping to where you were looking
## when you pressed the key. Any movement input, or F8, cancels the flight on the
## spot — a camera that will not give control back is worse than no flight at all.

## The spectator arrived at a marker's vantage.
signal arrived(at: Transform3D)
## The gaze cursor moved to a different control, or to nothing.
signal focus_changed(control: FirefightControl)

## Actions that abort a flight the moment they are touched.
const CANCEL_ACTIONS: PackedStringArray = [
	"move_forward", "move_back", "move_left", "move_right", "jump", "crouch"
]

@export var freecam_path: NodePath = NodePath()
## Half-angle of the gaze cursor, in degrees. Wide enough to catch a post you are
## looking near, tight enough that two posts are never both candidates.
@export_range(1.0, 30.0, 0.25) var gaze_degrees: float = 7.0
## Seconds between gaze resolves.
@export_range(0.02, 0.5, 0.01) var scan_period: float = 0.125
## Where the camera starts, before anyone has flown anywhere.
@export var start_transform: Transform3D = Transform3D.IDENTITY

var _cam: FreecamController = null
var _controls: Array[FirefightControl] = []
var _focus: FirefightControl = null
var _scan_accum: float = 0.0

var _flying: bool = false
var _flight_t: float = 0.0
var _flight_len: float = 1.0
var _from: Transform3D = Transform3D.IDENTITY
var _to: Transform3D = Transform3D.IDENTITY


func _ready() -> void:
	_cam = get_node_or_null(freecam_path) as FreecamController
	if _cam == null:
		push_error("FirefightSpectator: freecam_path does not resolve to a FreecamController.")
		set_process(false)
		return
	_cam.global_transform = start_transform
	_cam.freecam_changed.connect(_on_freecam_changed)
	refresh_controls()
	# Deferred because `set_active` adopts the current camera, and on the first
	# frame of a scene there is not one yet.
	_cam.set_active.call_deferred(true)


func _unhandled_input(event: InputEvent) -> void:
	if _flying:
		for action: String in CANCEL_ACTIONS:
			if event.is_action_pressed(StringName(action)):
				_end_flight()
				return
		return
	if not event.is_action_pressed(&"interact"):
		return
	# Resolve the gaze AGAIN, here, on the press. The scan runs eight times a
	# second because a cursor that re-resolves every frame flickers between two
	# posts nearly in line — but that leaves the cached answer up to 125 ms old,
	# and a viewer who swings onto a post and presses immediately was pressing
	# against where they had been looking an eighth of a second earlier. Selection
	# is a dot product over a handful of posts, so paying for it on the press costs
	# nothing and removes the whole class of missed press.
	_resolve_focus()
	if _focus == null:
		return
	get_viewport().set_input_as_handled()
	_focus.activate(self)


func _process(delta: float) -> void:
	# Wall-clock, so the speed dial cannot slow the camera down with the war.
	var real: float = delta / maxf(Engine.time_scale, 0.01)
	if _flying:
		_advance_flight(real)
		return
	_scan_accum += real
	if _scan_accum < scan_period:
		return
	_scan_accum = 0.0
	_resolve_focus()


## Re-read the control group. Controls are baked into the scene and do not come
## and go, so this is called once at load; it is public for a tool that adds one.
func refresh_controls() -> void:
	_controls.clear()
	for node in get_tree().get_nodes_in_group(&"firefight_control"):
		var c := node as FirefightControl
		if c != null:
			_controls.append(c)


func camera() -> FreecamController:
	return _cam


func focused() -> FirefightControl:
	return _focus


func is_flying() -> bool:
	return _flying


## Take the camera to `where` over `seconds` of wall-clock time. Calling this
## during a flight retargets it from wherever the camera currently is.
func fly_to(where: Transform3D, seconds: float) -> void:
	if _cam == null:
		return
	_from = _cam.global_transform
	_to = where
	_flight_len = maxf(seconds, 0.05)
	_flight_t = 0.0
	if not _flying:
		_flying = true
		_cam.set_active(false)
	_set_focus(null)


func _advance_flight(delta: float) -> void:
	_flight_t += delta
	var t: float = clampf(_flight_t / _flight_len, 0.0, 1.0)
	# Smoothstep on both position and rotation. A linear camera move starts and
	# stops with a jolt, which is the one thing a spectator notices.
	var s: float = t * t * (3.0 - 2.0 * t)
	var q: Quaternion = _from.basis.get_rotation_quaternion().slerp(
		_to.basis.get_rotation_quaternion(), s
	)
	_cam.global_transform = Transform3D(Basis(q), _from.origin.lerp(_to.origin, s))
	if t >= 1.0:
		_end_flight()


func _end_flight() -> void:
	if not _flying:
		return
	_flying = false
	_cam.set_active(true)
	arrived.emit(_cam.global_transform)


## F8 during a flight means the viewer wants the stick back. Give it to them and
## stop driving.
func _on_freecam_changed(is_active: bool) -> void:
	if is_active and _flying:
		_flying = false
		arrived.emit(_cam.global_transform)


func _resolve_focus() -> void:
	var eye: Vector3 = _cam.global_position
	var fwd: Vector3 = -_cam.global_transform.basis.z
	var floor_cos: float = cos(deg_to_rad(gaze_degrees))
	var best: FirefightControl = null
	var best_score: float = floor_cos
	for c: FirefightControl in _controls:
		if not is_instance_valid(c):
			continue
		var to: Vector3 = c.global_position - eye
		var d2: float = to.length_squared()
		if d2 > c.reach * c.reach or d2 < 1e-4:
			continue
		var aligned: float = fwd.dot(to / sqrt(d2))
		if aligned > best_score:
			best_score = aligned
			best = c
	_set_focus(best)


func _set_focus(c: FirefightControl) -> void:
	if c == _focus:
		return
	if _focus != null and is_instance_valid(_focus):
		_focus.set_focused(false)
	_focus = c
	if _focus != null:
		_focus.set_focused(true)
	focus_changed.emit(_focus)
