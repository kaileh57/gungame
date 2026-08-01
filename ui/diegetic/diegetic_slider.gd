class_name DiegeticSlider
extends DiegeticControl
## A slider you shoot along its track. Where the round lands is where the knob
## goes — no dragging, no cursor, no held button. The whole track is the hit
## surface, so the collider must span it.
##
## Values are real units, not a 0..1 fraction: give it `min_value` 0 and
## `max_value` 400 and it reads out in metres, which is what a range's target
## distance control wants.

## Length of the travel in metres, centred on local X = 0.
@export_range(0.05, 2.0, 0.005) var track_length: float = 0.34
@export var min_value: float = 0.0
@export var max_value: float = 1.0
## Detent size in value units. Zero means continuous.
@export var step: float = 0.05
@export_range(0.02, 0.40, 0.01) var slide_seconds: float = 0.09
## Applied to the Readout label, if the slider carries one.
@export var value_format: String = "%.2f"

var _slide_tween: Tween = null

@onready var _knob: Node3D = $Knob
@onready var _readout: Label3D = get_node_or_null(^"Readout") as Label3D


func _ready() -> void:
	super()
	_write_readout()


## Re-scale the track. The knob keeps the *fraction* it was at rather than its
## raw number: a slider that read 400 of 400 still reads full after the range
## drops to 40, which is what a panel re-purposing a control expects to see.
func set_range(low: float, high: float) -> void:
	var was: float = fraction()
	min_value = low
	max_value = high
	_value = _sanitize(lerpf(low, high, was))
	if is_node_ready():
		_refresh_visual(true)


## Where the knob sits on the track, 0 at the low end and 1 at the high end.
func fraction() -> float:
	var span: float = max_value - min_value
	if absf(span) < 0.000001:
		return 0.0
	return clampf((value() - min_value) / span, 0.0, 1.0)


func _actuate(local_point: Vector3) -> bool:
	var t: float = clampf(local_point.x / track_length + 0.5, 0.0, 1.0)
	var before: float = value()
	set_value(lerpf(min_value, max_value, t))
	return not is_equal_approx(before, value())


func _refresh_visual(instant: bool) -> void:
	if _knob == null:
		return
	_write_readout()
	var x: float = (fraction() - 0.5) * track_length
	if instant:
		_knob.position.x = x
		return
	_kill_slide()
	_slide_tween = create_tween()
	(
		_slide_tween
		. tween_property(_knob, "position:x", x, slide_seconds)
		. set_trans(Tween.TRANS_CUBIC)
		. set_ease(Tween.EASE_OUT)
	)


func _sanitize(raw: float) -> float:
	var low: float = minf(min_value, max_value)
	var high: float = maxf(min_value, max_value)
	var clamped: float = clampf(raw, low, high)
	if step <= 0.0:
		return clamped
	return clampf(low + roundf((clamped - low) / step) * step, low, high)


## Walking up to a slider and using it nudges it one detent along, wrapping at the
## far end. Shooting it is still absolute.
func _interact_point() -> Vector3:
	var advance: float = step if step > 0.0 else (max_value - min_value) * 0.1
	var next: float = value() + advance
	if next > maxf(min_value, max_value) + 0.000001:
		next = minf(min_value, max_value)
	var span: float = max_value - min_value
	var t: float = 0.0 if absf(span) < 0.000001 else (next - min_value) / span
	return Vector3((clampf(t, 0.0, 1.0) - 0.5) * track_length, 0.0, 0.0)


func _write_readout() -> void:
	if _readout == null:
		return
	_readout.text = value_format % value()


func _kill_slide() -> void:
	if _slide_tween != null and _slide_tween.is_valid():
		_slide_tween.kill()
	_slide_tween = null
