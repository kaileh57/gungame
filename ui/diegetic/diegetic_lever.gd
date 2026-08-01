class_name DiegeticLever
extends DiegeticControl
## A two-position lever you shoot. The arm throws over, the detent clunks.
##
## Value is 0 or 1 and `value_changed` carries it, so a lever wires up to a bool
## the same way a button does — but you can read its state from across the room,
## which is the entire reason it exists rather than a second button.
##
## `toggled` is the signal you actually want: it hands you the bool directly and
## saves every listener writing the same `> 0.5` on the other end.

## The lever settled in a new position. Fires alongside `value_changed`.
signal toggled(on: bool)

## Half the total throw. The arm swings from -throw to +throw about local X.
@export_range(5.0, 80.0, 1.0) var throw_degrees: float = 34.0
@export_range(0.04, 0.40, 0.01) var throw_seconds: float = 0.11
## Label3D text for each end of the throw, if the lever carries a "State" label.
@export var off_text: String = "OFF"
@export var on_text: String = "ON"

var _throw_tween: Tween = null

@onready var _arm: Node3D = $Arm
@onready var _state_label: Label3D = get_node_or_null(^"State") as Label3D


func _ready() -> void:
	super()
	if value_changed.connect(_on_value_changed) != OK:
		push_error("DiegeticLever: could not mirror value_changed onto toggled.")
	_write_state_label()


## True when the lever is thrown.
func is_on() -> bool:
	return value() > 0.5


## Throw the lever from code. `notify` false sets the position without firing
## `toggled`, which is what wiring a panel up to its initial state wants.
func set_on(on: bool, notify: bool = true) -> void:
	set_value(1.0 if on else 0.0, notify)


func _actuate(_local_point: Vector3) -> bool:
	set_value(0.0 if is_on() else 1.0)
	return true


func _refresh_visual(instant: bool) -> void:
	if _arm == null:
		return
	_write_state_label()
	var angle: float = deg_to_rad(throw_degrees) * (1.0 if is_on() else -1.0)
	if instant:
		_arm.rotation.x = angle
		return
	_kill_throw()
	_throw_tween = create_tween()
	(
		_throw_tween
		. tween_property(_arm, "rotation:x", angle, throw_seconds)
		. set_trans(Tween.TRANS_BACK)
		. set_ease(Tween.EASE_OUT)
	)


func _sanitize(raw: float) -> float:
	return 1.0 if raw > 0.5 else 0.0


func _on_value_changed(new_value: float) -> void:
	toggled.emit(new_value > 0.5)


func _write_state_label() -> void:
	if _state_label == null:
		return
	_state_label.text = on_text if is_on() else off_text


func _kill_throw() -> void:
	if _throw_tween != null and _throw_tween.is_valid():
		_throw_tween.kill()
	_throw_tween = null
