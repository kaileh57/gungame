class_name DebugOverlay
extends Control
## The F3 panel, drawn immediate-mode.
##
## Every number on this panel would otherwise be a Label, and forty Labels is
## forty Controls laying themselves out behind a panel nobody is looking at most
## of the time. One `_draw()` is one canvas item, costs nothing while hidden, and
## lets the frametime graph share the same pass as the text.
##
## `DebugHUD` owns the data and pushes it in; this class owns nothing but the
## pixels. Rows whose value is empty are drawn as section headings with a rule.

## A toggle row was clicked. `index` indexes the array last given to `set_toggles`.
signal toggle_clicked(index: int)

const PANEL_W: float = 452.0
const MARGIN: float = 12.0
const GRAPH_H: float = 52.0
const ROW_H: float = 17.0
const TOGGLE_H: float = 17.0
## Frametime budgets drawn as reference rules: 120 fps and 60 fps.
const BUDGET_MS: PackedFloat32Array = [8.333, 16.667]
## Ceiling of the graph's vertical axis. Spikes above this clip rather than
## rescaling the whole plot, so the shape of a normal frame stays comparable.
const GRAPH_MAX_MS: float = 33.4

var _headline: String = ""
var _mode_line: String = ""
var _labels: PackedStringArray = PackedStringArray()
var _values: PackedStringArray = PackedStringArray()
var _colors: PackedColorArray = PackedColorArray()
var _toggle_labels: PackedStringArray = PackedStringArray()
var _toggle_states: PackedByteArray = PackedByteArray()
var _samples: PackedFloat32Array = PackedFloat32Array()
var _head: int = 0
var _font: Font = null
var _toggle_top: float = 0.0


func _ready() -> void:
	_font = UiStyle.mono_font()
	set_anchors_preset(Control.PRESET_TOP_LEFT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	position = Vector2(MARGIN, MARGIN)
	size = Vector2(PANEL_W, 640.0)


func _gui_input(event: InputEvent) -> void:
	var click := event as InputEventMouseButton
	if click == null or not click.pressed or click.button_index != MOUSE_BUTTON_LEFT:
		return
	var index: int = int(floor((click.position.y - _toggle_top) / TOGGLE_H))
	if index < 0 or index >= _toggle_labels.size():
		return
	accept_event()
	toggle_clicked.emit(index)


## The demo name and render debug mode shown in the header.
func set_header(headline: String, mode_line: String) -> void:
	_headline = headline
	_mode_line = mode_line


## Metric rows. A row with an empty value is a section heading.
func set_rows(
	labels: PackedStringArray, values: PackedStringArray, colors: PackedColorArray
) -> void:
	_labels = labels
	_values = values
	_colors = colors


## The debug-draw channel list and which of them are on.
func set_toggles(labels: PackedStringArray, states: PackedByteArray) -> void:
	_toggle_labels = labels
	_toggle_states = states


## Ring buffer of frame times in milliseconds, plus the index of the next write.
func set_graph(samples: PackedFloat32Array, head: int) -> void:
	_samples = samples
	_head = head


func _draw() -> void:
	if _font == null:
		_font = UiStyle.mono_font()
	var content_h: float = _content_height()
	var panel := Rect2(Vector2.ZERO, Vector2(PANEL_W, content_h))
	draw_rect(panel, UiStyle.PANEL_FILL, true)
	draw_rect(panel, UiStyle.PANEL_EDGE, false, 1.0)

	var y: float = 8.0
	y = _draw_header(y)
	y = _draw_graph(y)
	y = _draw_rows(y)
	_draw_toggles(y)


func _draw_header(y: float) -> float:
	var top: float = y + 15.0
	draw_string(
		_font,
		Vector2(10.0, top),
		_headline,
		HORIZONTAL_ALIGNMENT_LEFT,
		PANEL_W - 20.0,
		UiStyle.FONT_SIZE_BODY,
		UiStyle.ACCENT
	)
	draw_string(
		_font,
		Vector2(10.0, top),
		_mode_line,
		HORIZONTAL_ALIGNMENT_RIGHT,
		PANEL_W - 20.0,
		UiStyle.FONT_SIZE_SMALL,
		UiStyle.TEXT_DIM
	)
	draw_line(Vector2(10.0, top + 6.0), Vector2(PANEL_W - 10.0, top + 6.0), UiStyle.TEXT_FAINT, 1.0)
	return top + 12.0


func _draw_graph(y: float) -> float:
	var count: int = _samples.size()
	if count == 0:
		return y
	var rect := Rect2(Vector2(10.0, y), Vector2(PANEL_W - 20.0, GRAPH_H))
	draw_rect(rect, Color(0.0, 0.0, 0.0, 0.35), true)
	for ms: float in BUDGET_MS:
		var by: float = rect.position.y + rect.size.y * (1.0 - clampf(ms / GRAPH_MAX_MS, 0.0, 1.0))
		draw_line(
			Vector2(rect.position.x, by),
			Vector2(rect.end.x, by),
			Color(UiStyle.TEXT_FAINT, 0.55),
			1.0
		)

	var step: float = rect.size.x / float(count)
	var points := PackedVector2Array()
	var colors := PackedColorArray()
	points.resize(count * 2)
	colors.resize(count * 2)
	for i: int in count:
		# Read oldest-first so the plot scrolls left and the newest frame is at
		# the right edge, which is where the eye already is.
		var ms: float = _samples[(_head + i) % count]
		var h: float = clampf(ms / GRAPH_MAX_MS, 0.0, 1.0) * rect.size.y
		var x: float = rect.position.x + float(i) * step
		var c: Color = UiStyle.GOOD
		if ms > BUDGET_MS[1]:
			c = UiStyle.WARN
		elif ms > BUDGET_MS[0]:
			c = UiStyle.ACCENT
		points[i * 2] = Vector2(x, rect.end.y)
		points[i * 2 + 1] = Vector2(x, rect.end.y - h)
		colors[i * 2] = c
		colors[i * 2 + 1] = c
	draw_multiline_colors(points, colors, maxf(1.0, step))
	draw_rect(rect, UiStyle.TEXT_FAINT, false, 1.0)
	return rect.end.y + 8.0


func _draw_rows(y: float) -> float:
	var row_y: float = y
	for i: int in _labels.size():
		var value: String = _values[i] if i < _values.size() else ""
		var color: Color = _colors[i] if i < _colors.size() else UiStyle.TEXT
		if value.is_empty():
			row_y += 5.0
			draw_string(
				_font,
				Vector2(10.0, row_y + 11.0),
				_labels[i],
				HORIZONTAL_ALIGNMENT_LEFT,
				PANEL_W - 20.0,
				UiStyle.FONT_SIZE_SMALL,
				UiStyle.ACCENT
			)
			draw_line(
				Vector2(10.0, row_y + 15.0),
				Vector2(PANEL_W - 10.0, row_y + 15.0),
				UiStyle.TEXT_FAINT,
				1.0
			)
			row_y += ROW_H + 2.0
			continue
		draw_string(
			_font,
			Vector2(14.0, row_y + 12.0),
			_labels[i],
			HORIZONTAL_ALIGNMENT_LEFT,
			PANEL_W - 28.0,
			UiStyle.FONT_SIZE_SMALL,
			UiStyle.TEXT_DIM
		)
		draw_string(
			_font,
			Vector2(14.0, row_y + 12.0),
			value,
			HORIZONTAL_ALIGNMENT_RIGHT,
			PANEL_W - 28.0,
			UiStyle.FONT_SIZE_SMALL,
			color
		)
		row_y += ROW_H
	return row_y


func _draw_toggles(y: float) -> float:
	if _toggle_labels.is_empty():
		return y
	var row_y: float = y + 5.0
	draw_string(
		_font,
		Vector2(10.0, row_y + 11.0),
		"DEBUG DRAW  (ctrl+number, or click)",
		HORIZONTAL_ALIGNMENT_LEFT,
		PANEL_W - 20.0,
		UiStyle.FONT_SIZE_SMALL,
		UiStyle.ACCENT
	)
	draw_line(
		Vector2(10.0, row_y + 15.0), Vector2(PANEL_W - 10.0, row_y + 15.0), UiStyle.TEXT_FAINT, 1.0
	)
	row_y += ROW_H + 2.0
	_toggle_top = row_y
	for i: int in _toggle_labels.size():
		var on: bool = i < _toggle_states.size() and _toggle_states[i] != 0
		var box := Rect2(Vector2(14.0, row_y + 3.0), Vector2(10.0, 10.0))
		draw_rect(box, UiStyle.ACCENT if on else Color(0, 0, 0, 0.4), true)
		draw_rect(box, UiStyle.TEXT_FAINT, false, 1.0)
		draw_string(
			_font,
			Vector2(32.0, row_y + 12.0),
			"%d  %s" % [i + 1, _toggle_labels[i]],
			HORIZONTAL_ALIGNMENT_LEFT,
			PANEL_W - 46.0,
			UiStyle.FONT_SIZE_SMALL,
			UiStyle.TEXT if on else UiStyle.TEXT_DIM
		)
		row_y += TOGGLE_H
	return row_y


func _content_height() -> float:
	var h: float = 20.0 + 12.0
	if not _samples.is_empty():
		h += GRAPH_H + 8.0
	for i: int in _labels.size():
		var is_head: bool = i >= _values.size() or _values[i].is_empty()
		h += (ROW_H + 7.0) if is_head else ROW_H
	if not _toggle_labels.is_empty():
		h += ROW_H + 7.0 + TOGGLE_H * float(_toggle_labels.size())
	return h + 10.0
