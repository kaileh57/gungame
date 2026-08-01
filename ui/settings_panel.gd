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
	{"kind": "header", "label": "Display"},
	{
		"kind": "option",
		"key": &"window_mode",
		"label": "Window mode",
		"values": [0, 1, 2],
		## Checked against `GameSettings.WINDOW_MODE_NAMES` at boot — see
		## `_verify_coverage`. A const cannot read an autoload, so the two are kept
		## in step by an assertion rather than by sharing one array.
		"names": ["Windowed", "Borderless", "Fullscreen"],
		"hint":
		(
			"Borderless is a frameless window over the whole screen: alt-tabs instantly. "
			+ "Fullscreen is exclusive: lower input lag, and nothing else gets a pixel. "
			+ "Alt+Enter cycles all three from anywhere in the game."
		)
	},
	{
		"kind": "resolution",
		"key": &"resolution",
		"label": "Window size",
		"hint":
		(
			"The size of the window in Windowed mode. Both fullscreen modes take the whole "
			+ "screen and ignore it — no game can change a monitor's own mode. A size larger "
			+ "than the desktop's free area is shrunk to fit; the figure on the right is what "
			+ "the window actually is."
		)
	},
	{
		"kind": "slider",
		"key": &"ui_scale",
		"label": "HUD scale",
		"min": 0.70,
		"max": 1.40,
		"step": 0.05,
		"fmt": "%.0f%%",
		"mul": 100.0,
		"hint":
		(
			"Size of the menus, the HUD and the reticle, on top of the scaling the window "
			+ "already does for itself. Worth turning down on an ultrawide, where the canvas "
			+ "is scaled off a height that is small next to the width."
		)
	},
	{"kind": "header", "label": "Rendering"},
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

## Common display aspects, for labelling a size in the window-size picker. Matched
## by nearest ratio rather than by reducing the fraction, because 1366x768 reduces
## to 683:384 — true, useless, and every player alive calls that screen 16:9.
const ASPECT_LABELS: Dictionary = {
	"5:4": 1.25,
	"4:3": 1.3333333,
	"3:2": 1.5,
	"16:10": 1.6,
	"16:9": 1.7777778,
	"21:9": 2.3703704,
	"32:9": 3.5555556,
}
## How far a size's ratio may sit from a listed aspect and still be called it.
## 3440x1440 is 2.389 against 21:9's 2.370, and it is sold as 21:9.
const ASPECT_TOLERANCE: float = 0.03

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
	# On the same beat, because the answer changes without anything telling us: the
	# player can drag the window frame, and the OS decides the size in fullscreen.
	_write_window_readout()


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
			"resolution":
				_rows_box.add_child(_make_resolution_row(row))


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


## The one row whose choices are not known until the game is running: the sizes
## depend on the screen the window happens to be on. Built empty and filled by
## `_refresh_resolution_row`, which runs on every open and on every window-mode
## change, so moving the window to a second monitor is enough to re-offer that
## monitor's sizes.
func _make_resolution_row(row_def: Dictionary) -> Control:
	var key: StringName = row_def["key"]
	var row := _row_shell(String(row_def["label"]), String(row_def.get("hint", "")))
	var picker := OptionButton.new()
	picker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	picker.item_selected.connect(_on_resolution_selected)
	row.add_child(picker)
	var actual := Label.new()
	actual.custom_minimum_size = Vector2(float(VALUE_WIDTH), 0.0)
	actual.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	actual.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	actual.add_theme_color_override("font_color", UiStyle.TEXT_DIM)
	actual.add_theme_font_size_override("font_size", UiStyle.FONT_SIZE_SMALL)
	actual.tooltip_text = "What the window actually is right now."
	row.add_child(actual)
	var sizes: Array[Vector2i] = []
	_widgets[key] = {
		"kind": "resolution", "node": picker, "value": actual, "sizes": sizes, "def": row_def
	}
	return row


## Rebuild the size list and the enabled state. Cheap — a dozen items — so it runs
## on every sync rather than trying to work out when the display changed.
func _refresh_resolution_row() -> void:
	if not _widgets.has(&"resolution"):
		return
	var widget: Dictionary = _widgets[&"resolution"]
	var picker := widget["node"] as OptionButton
	var sizes: Array[Vector2i] = GameSettings.resolution_options()
	widget["sizes"] = sizes
	picker.clear()
	for i: int in sizes.size():
		picker.add_item(_resolution_label(sizes[i]), i)
	# `resolution_options` guarantees the stored size is in the list, so a -1 here
	# would be a bug in that guarantee rather than a config to be papered over.
	picker.selected = maxi(0, sizes.find(GameSettings.resolution))
	# Both fullscreen modes take the whole screen; Godot cannot change a monitor's
	# video mode, so offering a choice there would be offering a lie.
	picker.disabled = GameSettings.window_mode != GameSettings.WINDOW_WINDOWED
	_write_window_readout()


func _write_window_readout() -> void:
	if not _widgets.has(&"resolution"):
		return
	var actual: Vector2i = GameSettings.window_size()
	var label := _widgets[&"resolution"]["value"] as Label
	label.text = "" if actual.x <= 0 else "%dx%d" % [actual.x, actual.y]


func _on_resolution_selected(index: int) -> void:
	if _applying:
		return
	var sizes: Array[Vector2i] = _widgets[&"resolution"]["sizes"]
	if index < 0 or index >= sizes.size():
		return
	GameSettings.set_value(&"resolution", sizes[index])


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
	# Going fullscreen greys the size picker out; coming back enables it. The mode
	# row cannot do that to itself, so it is done from here where both are visible.
	if key == &"window_mode":
		_refresh_resolution_row()
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
		"resolution":
			_refresh_resolution_row()


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


## "1920 x 1080   16:9". The aspect is dropped when the size is not close to any
## aspect a person would recognise.
static func _resolution_label(size: Vector2i) -> String:
	var aspect: String = _aspect_label(size)
	if aspect.is_empty():
		return "%d x %d" % [size.x, size.y]
	return "%d x %d   %s" % [size.x, size.y, aspect]


## The nearest common aspect within `ASPECT_TOLERANCE`, or an empty string.
static func _aspect_label(size: Vector2i) -> String:
	if size.x <= 0 or size.y <= 0:
		return ""
	var ratio: float = float(size.x) / float(size.y)
	var best: String = ""
	var best_error: float = ASPECT_TOLERANCE
	for text: String in ASPECT_LABELS:
		var error: float = absf(ratio - float(ASPECT_LABELS[text])) / ratio
		if error < best_error:
			best_error = error
			best = text
	return best


## A key in the store with no row is a key the player cannot reach. Raised loudly
## at boot rather than discovered by a player who wanted to turn fog off.
func _verify_coverage() -> void:
	var missing := PackedStringArray()
	for key: StringName in GameSettings.DEFAULTS:
		if key == &"quality_preset" or _widgets.has(key):
			continue
		missing.append(String(key))
	if not missing.is_empty():
		push_error(
			(
				"SettingsPanel: GameSettings has %d key(s) with no row: %s."
				% [missing.size(), ", ".join(missing)]
			)
		)
	_verify_window_modes()


## The window-mode row spells its three choices out as a const, because a const
## cannot call an autoload. This is the price of that: a check that the words on
## the buttons still mean what `GameSettings` thinks they mean.
func _verify_window_modes() -> void:
	if not _widgets.has(&"window_mode"):
		return
	var shown: Array = _widgets[&"window_mode"]["def"]["names"]
	var owned: PackedStringArray = GameSettings.WINDOW_MODE_NAMES
	if shown.size() == owned.size() and Array(owned) == shown:
		return
	push_error(
		(
			"SettingsPanel: the window-mode row offers %s, GameSettings defines %s."
			% [str(shown), str(Array(owned))]
		)
	)
