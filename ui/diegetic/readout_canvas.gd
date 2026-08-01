class_name ReadoutCanvas
extends Control
## What a `DiegeticReadout` draws into its SubViewport before the CRT shader gets
## hold of it. Text, rules and stat bars — nothing interactive, because a readout
## reads out.
##
## Drawn immediate-mode and only when something changed. The viewport it lives in
## sits at UPDATE_ONCE, so a panel showing a static stat card costs one render for
## the life of the scene.

## Base metrics, authored against the 512x320 SubViewport in
## `diegetic_readout.tscn`. Everything below is multiplied by `_scale`.
const PAD: float = 20.0
const TITLE_SIZE: int = 24
const LINE_SIZE: int = 18
const BAR_SIZE: int = 15
const LINE_STEP: float = 23.0
const BAR_STEP: float = 26.0
const BAR_LABEL_W: float = 132.0

## How much bigger than the authored metrics to draw.
##
## The panels are read from a couple of metres away in world space, and at 1.0 the
## join console's address and call-sign fields were reported as unreadably small.
## This is one number rather than seven because the metrics have to move together
## or the line spacing stops matching the glyphs.
const TEXT_SCALE: float = 1.55
## Never shrink past this when auto-fitting, or a long stat card becomes worse than
## the problem being fixed.
const MIN_SCALE: float = 0.85

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


## Scale that fits the current content, never above TEXT_SCALE.
##
## Bigger glyphs mean fewer lines fit, so a panel with a long stat card would clip
## silently. Measure what the content needs and back off only as far as it takes —
## a short panel (the join console, which is the one that had to get bigger) keeps
## the full scale, and only a genuinely full card gives any of it back.
func _fit_scale() -> float:
	var lines: int = _lines.size()
	var bars: int = _bar_labels.size()
	var title_h: float = 0.0 if _title.is_empty() else float(TITLE_SIZE) + 22.0
	var need: float = PAD * 2.0 + title_h + LINE_STEP * float(lines) + BAR_STEP * float(bars)
	if need <= 0.0:
		return TEXT_SCALE
	var room: float = size.y / need
	return clampf(minf(TEXT_SCALE, room), MIN_SCALE, TEXT_SCALE)


func _draw() -> void:
	if _font == null:
		_font = UiStyle.mono_font()
	var w: float = size.x
	var h: float = size.y
	var k: float = _fit_scale()
	var pad: float = PAD * k
	var title_size: int = int(round(float(TITLE_SIZE) * k))
	var line_size: int = int(round(float(LINE_SIZE) * k))
	var line_step: float = LINE_STEP * k
	var bar_step: float = BAR_STEP * k
	draw_rect(Rect2(Vector2.ZERO, size), PAINT_BG if _painted else CRT_BG, true)
	# A hairline inside the edge stops the panel reading as a floating rectangle
	# once the bezel geometry is only two millimetres proud of it.
	draw_rect(Rect2(Vector2(4.0, 4.0), size - Vector2(8.0, 8.0)), Color(_accent, 0.22), false, 2.0)

	var y: float = pad
	if not _title.is_empty():
		y += float(title_size)
		draw_string(
			_font,
			Vector2(pad, y),
			_title,
			HORIZONTAL_ALIGNMENT_LEFT,
			w - pad * 2.0,
			title_size,
			_accent
		)
		y += 8.0
		draw_line(Vector2(pad, y), Vector2(w - pad, y), Color(_accent, 0.6), 2.0)
		y += 14.0

	for text: String in _lines:
		y += line_step
		draw_string(
			_font,
			Vector2(pad, y),
			text,
			HORIZONTAL_ALIGNMENT_LEFT,
			w - pad * 2.0,
			line_size,
			UiStyle.TEXT
		)

	if _bar_labels.is_empty():
		return
	var bars_h: float = bar_step * float(_bar_labels.size())
	var bar_y: float = maxf(y + 16.0, h - pad - bars_h)
	for i: int in _bar_labels.size():
		_draw_bar(i, bar_y, w, k)
		bar_y += bar_step


func _draw_bar(index: int, y: float, w: float, k: float) -> void:
	var pad: float = PAD * k
	var bar_size: int = int(round(float(BAR_SIZE) * k))
	var label_w: float = BAR_LABEL_W * k
	var frac: float = clampf(_bar_values[index] if index < _bar_values.size() else 0.0, 0.0, 1.0)
	var color: Color = _bar_colors[index] if index < _bar_colors.size() else _accent
	draw_string(
		_font,
		Vector2(pad, y + 14.0 * k),
		_bar_labels[index],
		HORIZONTAL_ALIGNMENT_LEFT,
		label_w,
		bar_size,
		UiStyle.TEXT_DIM
	)
	var track := Rect2(
		Vector2(PAD + BAR_LABEL_W, y + 3.0), Vector2(w - pad * 2.0 - BAR_LABEL_W, 13.0)
	)
	draw_rect(track, Color(0.0, 0.0, 0.0, 0.45), true)
	var fill := Rect2(track.position, Vector2(track.size.x * frac, track.size.y))
	draw_rect(fill, color, true)
	draw_rect(track, Color(color, 0.45), false, 1.0)
