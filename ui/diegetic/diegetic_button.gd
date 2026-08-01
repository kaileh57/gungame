class_name DiegeticButton
extends DiegeticControl
## A button you shoot. The cap sinks into the housing, the lamp lights, it clicks.
##
## Local +Z is out of the face, so the cap travels -Z when it is pressed and the
## Label3D above it reads the right way round. Momentary by default; set
## `latching` and it stays down and carries a 0/1 value like a breaker switch.

## Metres the cap sinks. A real switch cap moves about a centimetre and so does
## this one — big enough to see across a room, small enough not to read as broken.
@export_range(0.002, 0.05, 0.001) var press_depth: float = 0.011
@export_range(0.01, 0.20, 0.005) var press_seconds: float = 0.05
## Seconds the cap stays down before springing back. Ignored when latching.
@export_range(0.0, 0.5, 0.01) var hold_seconds: float = 0.07
## Latching buttons keep their state and their value. Momentary ones always
## report 0 and spring back.
@export var latching: bool = false
@export var lamp_off_material: Material = null
@export var lamp_on_material: Material = null

var _cap_rest: float = 0.0
var _press_tween: Tween = null

@onready var _cap: Node3D = $Cap
@onready var _lamp: MeshInstance3D = get_node_or_null(^"Cap/Lamp") as MeshInstance3D


func _ready() -> void:
	_cap_rest = _cap.position.z
	super()
	_set_lamp(latching and value() > 0.5)


func _actuate(_local_point: Vector3) -> bool:
	if latching:
		var next: float = 0.0 if value() > 0.5 else 1.0
		set_value(next)
		return true
	_bounce()
	return true


func _refresh_visual(instant: bool) -> void:
	if _cap == null:
		return
	var down: bool = latching and value() > 0.5
	_set_lamp(down)
	var target: float = _cap_rest - (press_depth if down else 0.0)
	if instant:
		_cap.position.z = target
		return
	_kill_press()
	_press_tween = create_tween()
	_press_tween.tween_property(_cap, "position:z", target, press_seconds).set_trans(
		Tween.TRANS_CUBIC
	)


func _sanitize(raw: float) -> float:
	return 1.0 if raw > 0.5 else 0.0


## Momentary travel: down fast, hold, spring back. One tween, no state machine.
func _bounce() -> void:
	_kill_press()
	_press_tween = create_tween()
	_press_tween.tween_property(_cap, "position:z", _cap_rest - press_depth, press_seconds)
	_press_tween.tween_callback(_set_lamp.bind(true))
	_press_tween.tween_interval(hold_seconds)
	(
		_press_tween
		. tween_property(_cap, "position:z", _cap_rest, press_seconds * 1.6)
		. set_trans(Tween.TRANS_BACK)
		. set_ease(Tween.EASE_OUT)
	)
	_press_tween.tween_callback(_set_lamp.bind(false))


func _set_lamp(on: bool) -> void:
	if _lamp == null:
		return
	var mat: Material = lamp_on_material if on else lamp_off_material
	if mat != null:
		_lamp.set_surface_override_material(0, mat)


func _kill_press() -> void:
	if _press_tween != null and _press_tween.is_valid():
		_press_tween.kill()
	_press_tween = null
