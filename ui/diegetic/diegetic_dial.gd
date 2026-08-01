class_name DiegeticDial
extends DiegeticControl
## A rotary selector you shoot. Hit the right half of the knob and it indexes
## forward, the left half and it indexes back — the same thing your hand would do
## to it, which is why it needs no explanation on screen.
##
## `value_changed` carries the selected index as a float, so the dial substitutes
## for any other control. `option_selected` carries the index and its label, which
## is what a menu actually wants.

## Emitted with the new selection. Fires alongside `value_changed`.
signal option_selected(index: int, text: String)

## The detent labels. The number of options is the number of detents.
@export var options: PackedStringArray = PackedStringArray():
	set = _set_options
## Total rotation across the whole range, in degrees. A real selector sweeps about
## two thirds of a turn and so does this.
@export_range(30.0, 340.0, 1.0) var sweep_degrees: float = 240.0
@export_range(0.04, 0.40, 0.01) var turn_seconds: float = 0.10
## Past the last detent, wrap to the first instead of stopping.
@export var wraps: bool = true

var _turn_tween: Tween = null

@onready var _knob: Node3D = $Knob
@onready var _readout: Label3D = get_node_or_null(^"Readout") as Label3D


func _ready() -> void:
	super()
	_write_readout()


func selected_index() -> int:
	return int(round(value()))


func selected_text() -> String:
	var i: int = selected_index()
	if i < 0 or i >= options.size():
		return ""
	return options[i]


## Replace the detent labels. The selection is clamped into the new range.
func set_options(new_options: PackedStringArray) -> void:
	_set_options(new_options)


## Set the number of detents without naming them. Labels that already exist are
## kept, so growing a four-position dial to six keeps the first four names and
## numbers the two new ones — which is what a caller adding options means.
func set_steps(steps: int) -> void:
	var count: int = maxi(steps, 1)
	var next := PackedStringArray()
	next.resize(count)
	for i: int in count:
		next[i] = options[i] if i < options.size() else str(i + 1)
	_set_options(next)


## How many detents the dial has.
func steps() -> int:
	return options.size()


## Step the selection. `direction` is +1 or -1; wrapping honours `wraps`.
func step_selection(direction: int) -> void:
	var before: int = selected_index()
	set_value(float(before + direction))
	if selected_index() != before:
		option_selected.emit(selected_index(), selected_text())


func _actuate(local_point: Vector3) -> bool:
	var before: int = selected_index()
	set_value(float(before + (1 if local_point.x >= 0.0 else -1)))
	if selected_index() == before:
		return false
	option_selected.emit(selected_index(), selected_text())
	return true


func _refresh_visual(instant: bool) -> void:
	if _knob == null:
		return
	_write_readout()
	var count: int = maxi(options.size(), 1)
	var span: float = deg_to_rad(sweep_degrees)
	var t: float = 0.0 if count <= 1 else value() / float(count - 1)
	# The knob turns about its own face normal, which is local -Z: a dial you are
	# looking at turns clockwise as the index rises.
	var angle: float = -span * (t - 0.5)
	if instant:
		_knob.rotation.z = angle
		return
	_kill_turn()
	_turn_tween = create_tween()
	(
		_turn_tween
		. tween_property(_knob, "rotation:z", angle, turn_seconds)
		. set_trans(Tween.TRANS_BACK)
		. set_ease(Tween.EASE_OUT)
	)


func _sanitize(raw: float) -> float:
	var count: int = options.size()
	if count <= 1:
		return 0.0
	var index: int = int(round(raw))
	if wraps:
		return float(posmod(index, count))
	return float(clampi(index, 0, count - 1))


func _write_readout() -> void:
	if _readout == null:
		return
	_readout.text = selected_text()


func _set_options(new_options: PackedStringArray) -> void:
	options = new_options
	if not is_node_ready():
		return
	set_value(value(), false)
	_refresh_visual(true)


func _kill_turn() -> void:
	if _turn_tween != null and _turn_tween.is_valid():
		_turn_tween.kill()
	_turn_tween = null
