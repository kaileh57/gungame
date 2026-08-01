class_name SettingsPanel
extends Control
## Every key in `GameSettings`, with a live fps readout so the cost of each one is
## visible while you change it.
##
## The rows are built from `ROWS` rather than laid out by hand, which is what keeps
## this page honest: if `GameSettings.DEFAULTS` grows a key and this table does not,
## the missing-key check at boot says so out loud.
##
## Every change applies immediately — `GameSettings.set_value` is the only writer
## and it re-applies the renderer state itself. This page never caches a pending
## value and never has an Apply button, because a settings page with an Apply
## button is a settings page you cannot feel.

## Emitted when the close button is pressed. The host decides what closing means.
signal closed

## The whole page, declaratively. `int` marks a slider whose value must be stored
## as an integer, because `GameSettings` rejects a value whose type does not match
## its default and a float written into an int key would be silently dropped on the
## next load.
const ROWS: Array[Dictionary] = [
	{"kind": "preset"},
	{"kind": "header", "label": "Resolution"},
	{
		"kind": "slider",
		"key": &"render_scale",
		"label": "Render scale",
		"min": 0.5,
		"max": 1.0,
		"step": 0.05,
		"fmt": "%.0f%%",
		"mul": 100.0,
		"hint": "Resolution ceiling. Adaptive resolution scales down from here."
	},
	{
		"kind": "check",
		"key": &"adaptive_resolution",
		"label": "Adaptive resolution",
		"hint": "Drop resolution when the frame rate falls, climb back when it recovers."
	},
	{
		"kind": "option",
		"key": &"msaa",
		"label": "Anti-aliasing",
		"values": [0, 1, 2, 3],
		"names": ["Off", "2x MSAA", "4x MSAA", "8x MSAA"]
	},
	{"kind": "check", "key": &"vsync", "label": "V-Sync"},
	{"kind": "header", "label": "Shadows"},
	{
		"kind": "option",
		"key": &"directional_shadow_size",
		"label": "Sun shadow map",
		"values": [1024, 2048, 3072, 4096, 8192],
		"names": ["1024", "2048", "3072", "4096", "8192"]
	},
	{
		"kind": "option",
		"key": &"shadow_atlas_size",
		"label": "Local shadow atlas",
		"values": [1024, 2048, 4096, 8192],
		"names": ["1024", "2048", "4096", "8192"]
	},
	{
		"kind": "option",
		"key": &"shadow_quality",
		"label": "Shadow filter",
		"values": [0, 1, 2, 3, 4, 5],
		"names": ["Hard", "Very low", "Low", "Medium", "High", "Ultra"]
	},
	{"kind": "header", "label": "Atmosphere and post"},
	{"kind": "check", "key": &"ssao", "label": "Ambient occlusion"},
	{"kind": "check", "key": &"ssil", "label": "Screen-space indirect light"},
	{
		"kind": "option",
		"key": &"ao_quality",
		"label": "AO / SSIL quality",
		"values": [0, 1, 2, 3, 4],
		"names": ["Very low", "Low", "Medium", "High", "Ultra"]
	},
	{"kind": "check", "key": &"glow", "label": "Glow"},
	{"kind": "check", "key": &"fog", "label": "Distance haze"},
	{
		"kind": "check",
		"key": &"volumetric_fog",
		"label": "Volumetric fog",
		"hint": "Needs distance haze on. Expensive; the dust in the light shafts."
	},
	{"kind": "header", "label": "Simulation"},
	{
		"kind": "slider",
		"key": &"max_enemies",
		"label": "Enemy cap",
		"min": 4.0,
		"max": 96.0,
		"step": 1.0,
		"fmt": "%d",
		"int": true
	},
	{
		"kind": "slider",
		"key": &"lod_bias",
		"label": "LOD threshold",
		"min": 0.0,
		"max": 12.0,
		"step": 0.5,
		"fmt": "%.1f px",
		"hint": "Pixel size at which a mesh drops to its next LOD. Larger is cheaper."
	},
	{"kind": "header", "label": "Camera and controls"},
	{
		"kind": "slider",
		"key": &"fov",
		"label": "Field of view",
		"min": 60.0,
		"max": 110.0,
		"step": 1.0,
		"fmt": "%.0f deg"
	},
	{
		"kind": "slider",
		"key": &"mouse_sensitivity",
		"label": "Mouse sensitivity",
		"min": 0.0004,
		"max": 0.0060,
		"step": 0.0001,
		"fmt": "%.4f"
	},
	{
		"kind": "slider",
		"key": &"ads_sensitivity_scale",
		"label": "Aim sensitivity scale",
		"min": 0.20,
		"max": 1.00,
		"step": 0.05,
		"fmt": "%.2fx"
	},
	{"kind": "check", "key": &"invert_y", "label": "Invert vertical look"},
	{
		"kind": "option",
		"key": &"aim_style",
		"label": "Aim indicator",
		"values": [0, 1, 2],
		"names": ["Dot", "Selector", "Dot and selector"],
		"hint":
		(
			"Dot is a centre pip and the weapon's cone. Selector brackets whatever is "
			+ "under the aim point in the world and names it."
		)
	},
]

const LABEL_WIDTH: int = 250
const VALUE_WIDTH: int = 96
## The fps readout is the point of this page; four updates a second is enough to
## read and slow enough not to be its own load.
const FPS_PERIOD: float = 0.25

var _widgets: Dictionary = {}
var _preset_picker: OptionButton = null
## Set while a widget is being written from the store, so the widget's own change
## signal does not bounce straight back into the store.
var _applying: bool = false
var _fps_timer: float = 0.0

@onready var _rows_box: VBoxContainer = $Frame/Body/Scroll/Rows
@onready var _fps_label: Label = $Frame/Body/Header/Fps
@onready var _close_button: Button = $Frame/Body/Footer/CloseButton
@onready var _reset_button: Button = $Frame/Body/Footer/ResetButton


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build()
	_close_button.pressed.connect(_on_close)
	_reset_button.pressed.connect(_on_reset)
	GameSettings.settings_changed.connect(_on_setting_changed)
	sync_all()
	_verify_coverage()


func _process(delta: float) -> void:
	if not visible:
		return
	_fps_timer += delta
	if _fps_timer < FPS_PERIOD:
		return
	_fps_timer = 0.0
	var fps: int = Engine.get_frames_per_second()
	_fps_label.text = "%d fps   %.2f ms" % [fps, 1000.0 / maxf(float(fps), 1.0)]
	_fps_label.add_theme_color_override("font_color", UiStyle.meter_color(float(fps) / 120.0))


## Show the page and pull every widget back into line with the store.
func open() -> void:
	sync_all()
	visible = true
	_close_button.grab_focus()


func close() -> void:
	visible = false
	closed.emit()


## Re-read every value from `GameSettings`. Cheap; called on open and after a reset.
func sync_all() -> void:
	_applying = true
	_sync_preset()
	for key: StringName in _widgets:
		_write_widget(key, GameSettings.get_value(key))
	_applying = false


func _build() -> void:
	for row: Dictionary in ROWS:
		match String(row["kind"]):
			"preset":
				_rows_box.add_child(_make_preset_row())
			"header":
				_rows_box.add_child(_make_header(String(row["label"])))
			"check":
				_rows_box.add_child(_make_check_row(row))
			"slider":
				_rows_box.add_child(_make_slider_row(row))
			"option":
				_rows_box.add_child(_make_option_row(row))


func _make_header(text: String) -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 2)
	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0.0, 10.0)
	box.add_child(spacer)
	var label := Label.new()
	label.text = text.to_upper()
	label.add_theme_color_override("font_color", UiStyle.ACCENT)
	label.add_theme_font_size_override("font_size", UiStyle.FONT_SIZE_SMALL)
	box.add_child(label)
	var rule := ColorRect.new()
	rule.color = UiStyle.TEXT_FAINT
	rule.custom_minimum_size = Vector2(0.0, 1.0)
	box.add_child(rule)
	return box


func _row_shell(label_text: String, hint: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	row.tooltip_text = hint
	var label := Label.new()
	label.text = label_text
	label.custom_minimum_size = Vector2(float(LABEL_WIDTH), float(UiStyle.ROW_H))
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(label)
	return row


func _make_preset_row() -> Control:
	var row := _row_shell("Quality preset", "Writes every render key below at once.")
	_preset_picker = OptionButton.new()
	_preset_picker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_preset_picker.item_selected.connect(_on_preset_selected)
	row.add_child(_preset_picker)
	var pad := Control.new()
	pad.custom_minimum_size = Vector2(float(VALUE_WIDTH), 0.0)
	row.add_child(pad)
	return row


func _make_check_row(row_def: Dictionary) -> Control:
	var key: StringName = row_def["key"]
	var row := _row_shell(String(row_def["label"]), String(row_def.get("hint", "")))
	var check := CheckButton.new()
	check.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	check.toggled.connect(_on_check_toggled.bind(key))
	row.add_child(check)
	var pad := Control.new()
	pad.custom_minimum_size = Vector2(float(VALUE_WIDTH), 0.0)
	row.add_child(pad)
	_widgets[key] = {"kind": "check", "node": check, "def": row_def}
	return row


func _make_slider_row(row_def: Dictionary) -> Control:
	var key: StringName = row_def["key"]
	var row := _row_shell(String(row_def["label"]), String(row_def.get("hint", "")))
	var slider := HSlider.new()
	slider.min_value = float(row_def["min"])
	slider.max_value = float(row_def["max"])
	slider.step = float(row_def["step"])
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	slider.custom_minimum_size = Vector2(0.0, float(UiStyle.ROW_H))
	slider.value_changed.connect(_on_slider_changed.bind(key))
	row.add_child(slider)
	var value := Label.new()
	value.custom_minimum_size = Vector2(float(VALUE_WIDTH), 0.0)
	value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	value.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(value)
	_widgets[key] = {"kind": "slider", "node": slider, "value": value, "def": row_def}
	return row


func _make_option_row(row_def: Dictionary) -> Control:
	var key: StringName = row_def["key"]
	var row := _row_shell(String(row_def["label"]), String(row_def.get("hint", "")))
	var picker := OptionButton.new()
	picker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var names: Array = row_def["names"]
	for i: int in names.size():
		picker.add_item(String(names[i]), i)
	picker.item_selected.connect(_on_option_selected.bind(key))
	row.add_child(picker)
	var pad := Control.new()
	pad.custom_minimum_size = Vector2(float(VALUE_WIDTH), 0.0)
	row.add_child(pad)
	_widgets[key] = {"kind": "option", "node": picker, "def": row_def}
	return row


func _on_preset_selected(index: int) -> void:
	if _applying:
		return
	var names: PackedStringArray = GameSettings.preset_names()
	if index < 0 or index >= names.size():
		return
	GameSettings.apply_preset(names[index])


func _on_check_toggled(pressed: bool, key: StringName) -> void:
	if _applying:
		return
	GameSettings.set_value(key, pressed)


func _on_slider_changed(value: float, key: StringName) -> void:
	if _applying:
		return
	var def: Dictionary = _widgets[key]["def"]
	if bool(def.get("int", false)):
		GameSettings.set_value(key, int(round(value)))
		return
	GameSettings.set_value(key, value)


func _on_option_selected(index: int, key: StringName) -> void:
	if _applying:
		return
	var values: Array = _widgets[key]["def"]["values"]
	if index < 0 or index >= values.size():
		return
	GameSettings.set_value(key, values[index])


func _on_setting_changed(key: StringName, value: Variant) -> void:
	if _applying:
		return
	_applying = true
	if key == &"quality_preset":
		_sync_preset()
	elif _widgets.has(key):
		_write_widget(key, value)
	_applying = false


func _write_widget(key: StringName, value: Variant) -> void:
	var widget: Dictionary = _widgets[key]
	match String(widget["kind"]):
		"check":
			(widget["node"] as CheckButton).button_pressed = bool(value)
		"slider":
			var slider := widget["node"] as HSlider
			slider.value = float(value)
			_write_slider_label(widget, float(value))
		"option":
			var picker := widget["node"] as OptionButton
			var values: Array = widget["def"]["values"]
			picker.selected = maxi(0, values.find(value))


func _write_slider_label(widget: Dictionary, value: float) -> void:
	var def: Dictionary = widget["def"]
	var shown: float = value * float(def.get("mul", 1.0))
	var label := widget["value"] as Label
	if bool(def.get("int", false)):
		label.text = String(def["fmt"]) % int(round(shown))
		return
	label.text = String(def["fmt"]) % shown


func _sync_preset() -> void:
	if _preset_picker == null:
		return
	var names: PackedStringArray = GameSettings.preset_names()
	_preset_picker.clear()
	for i: int in names.size():
		_preset_picker.add_item(names[i], i)
	var current: String = GameSettings.quality_preset
	if GameSettings.is_custom_preset():
		_preset_picker.add_item(GameSettings.CUSTOM_PRESET, names.size())
		_preset_picker.selected = names.size()
		return
	_preset_picker.selected = maxi(0, Array(names).find(current))


func _on_close() -> void:
	close()


func _on_reset() -> void:
	GameSettings.reset_to_defaults()
	sync_all()


## A key in the store with no row is a key the player cannot reach. Raised loudly
## at boot rather than discovered by a player who wanted to turn fog off.
func _verify_coverage() -> void:
	var missing := PackedStringArray()
	for key: StringName in GameSettings.DEFAULTS:
		if key == &"quality_preset" or _widgets.has(key):
			continue
		missing.append(String(key))
	if missing.is_empty():
		return
	push_error(
		(
			"SettingsPanel: GameSettings has %d key(s) with no row: %s."
			% [missing.size(), ", ".join(missing)]
		)
	)
