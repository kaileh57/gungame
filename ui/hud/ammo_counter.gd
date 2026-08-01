class_name AmmoCounter
extends Node3D
## The ammunition count, on the gun.
##
## Screen-space ammo counters are the first thing the project's diegetic rule
## deletes, so this goes where a scav would actually have scratched it: a plate on
## the receiver with the magazine count on it. Parent it to the viewmodel, put it
## on the VIEWMODEL render layer, and it moves with the weapon — including when
## the weapon kicks, which is the whole reason it reads as part of the gun.
##
## Three states, from the reference's HUD rules: normal, low at a quarter of the
## magazine or less, and empty. Low and empty are colour changes, not text
## changes, because you read a colour without looking away from the sights.

## Colour once the magazine is at or below `low_fraction`.
@export var low_color: Color = UiStyle.ACCENT
## Colour at zero, and while the action is jammed.
@export var empty_color: Color = UiStyle.WARN
@export var normal_color: Color = Color(0.792, 0.749, 0.659)
@export_range(0.05, 0.5, 0.01) var low_fraction: float = 0.25
## Shown instead of the count while the action is jammed.
@export var jam_text: String = "JAM"

var _magazine: int = 0
var _capacity: int = 0
var _jammed: bool = false

@onready var _count: Label3D = $Count
@onready var _capacity_label: Label3D = get_node_or_null(^"Capacity") as Label3D


func _ready() -> void:
	_refresh()


## Update the count. Call it when the number changes, not every frame.
func set_ammo(magazine: int, capacity: int) -> void:
	if magazine == _magazine and capacity == _capacity:
		return
	_magazine = magazine
	_capacity = capacity
	_refresh()


## A jammed action shows JAM in the empty colour until it is cleared.
func set_jammed(jammed: bool) -> void:
	if jammed == _jammed:
		return
	_jammed = jammed
	_refresh()


func _refresh() -> void:
	if _count == null:
		return
	if _jammed:
		_count.text = jam_text
		_count.modulate = empty_color
	else:
		_count.text = str(_magazine)
		_count.modulate = _state_color()
	if _capacity_label != null:
		_capacity_label.text = "/%d" % _capacity


func _state_color() -> Color:
	if _magazine <= 0:
		return empty_color
	if _magazine <= maxi(1, int(float(_capacity) * low_fraction)):
		return low_color
	return normal_color
