class_name ReadoutCanvas
extends Control
## What a `DiegeticReadout` draws into its SubViewport before the CRT shader gets
## hold of it. Text, rules and stat bars — nothing interactive, because a readout
## reads out.
##
## Drawn immediate-mode and only when something changed. The viewport it lives in
## sits at UPDATE_ONCE, so a panel showing a static stat card costs one render for
## the life of the scene.

const PAD: float = 20.0
const TITLE_SIZE: int = 24
const LINE_SIZE: int = 18
const BAR_SIZE: int = 15
const LINE_STEP: float = 23.0
const BAR_STEP: float = 26.0
const BAR_LABEL_W: float = 132.0

## Phosphor bed. Not black: a dead CRT is dark green-grey and reads as glass.
const CRT_BG: Color = Color(0.043, 0.055, 0.047, 1.0)
## Painted placard: soot with warm off-white stencilling.
const PAINT_BG: Color = Color(0.106, 0.098, 0.090, 1.0)

var _title: String = ""
var _lines: PackedStringArray = PackedStringArray()
var _bar_labels: PackedStringArray = PackedStringArray()
var _bar_values: PackedFloat32Array = PackedFloat32Array()
var _bar_colors: PackedColorArray = PackedColorArray()
var _accent: Color = UiStyle.ACCENT
var _painted: bool = false
var _font: Font = null


func _ready() -> void:
	_font = UiStyle.mono_font()
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func set_title(text: String) -> void:
	_title = text
	queue_redraw()


func set_lines(lines: PackedStringArray) -> void:
	_lines = lines
	queue_redraw()


func set_bars(
	labels: PackedStringArray, fractions: PackedFloat32Array, colors: PackedColorArray
) -> void:
	_bar_labels = labels
	_bar_values = fractions
	_bar_colors = colors
	queue_redraw()


func set_accent(color: Color) -> void:
	_accent = color
	queue_redraw()


## Painted-metal signage instead of a lit CRT. Changes the bed colour and drops
## the phosphor glow; the shader reads the same flag for its own half of the look.
func set_painted(painted: bool) -> void:
	_painted = painted
	queue_redraw()


func _draw() -> void:
	if _font == null:
		_font = UiStyle.mono_font()
	var w: float = size.x
	var h: float = size.y
	draw_rect(Rect2(Vector2.ZERO, size), PAINT_BG if _painted else CRT_BG, true)
	# A hairline inside the edge stops the panel reading as a floating rectangle
	# once the bezel geometry is only two millimetres proud of it.
	draw_rect(Rect2(Vector2(4.0, 4.0), size - Vector2(8.0, 8.0)), Color(_accent, 0.22), false, 2.0)

	var y: float = PAD
	if not _title.is_empty():
		y += float(TITLE_SIZE)
		draw_string(
			_font,
			Vector2(PAD, y),
			_title,
			HORIZONTAL_ALIGNMENT_LEFT,
			w - PAD * 2.0,
			TITLE_SIZE,
			_accent
		)
		y += 8.0
		draw_line(Vector2(PAD, y), Vector2(w - PAD, y), Color(_accent, 0.6), 2.0)
		y += 14.0

	for text: String in _lines:
		y += LINE_STEP
		draw_string(
			_font,
			Vector2(PAD, y),
			text,
			HORIZONTAL_ALIGNMENT_LEFT,
			w - PAD * 2.0,
			LINE_SIZE,
			UiStyle.TEXT
		)

	if _bar_labels.is_empty():
		return
	var bars_h: float = BAR_STEP * float(_bar_labels.size())
	var bar_y: float = maxf(y + 16.0, h - PAD - bars_h)
	for i: int in _bar_labels.size():
		_draw_bar(i, bar_y, w)
		bar_y += BAR_STEP


func _draw_bar(index: int, y: float, w: float) -> void:
	var frac: float = clampf(_bar_values[index] if index < _bar_values.size() else 0.0, 0.0, 1.0)
	var color: Color = _bar_colors[index] if index < _bar_colors.size() else _accent
	draw_string(
		_font,
		Vector2(PAD, y + 14.0),
		_bar_labels[index],
		HORIZONTAL_ALIGNMENT_LEFT,
		BAR_LABEL_W,
		BAR_SIZE,
		UiStyle.TEXT_DIM
	)
	var track := Rect2(
		Vector2(PAD + BAR_LABEL_W, y + 3.0), Vector2(w - PAD * 2.0 - BAR_LABEL_W, 13.0)
	)
	draw_rect(track, Color(0.0, 0.0, 0.0, 0.45), true)
	var fill := Rect2(track.position, Vector2(track.size.x * frac, track.size.y))
	draw_rect(fill, color, true)
	draw_rect(track, Color(color, 0.45), false, 1.0)
