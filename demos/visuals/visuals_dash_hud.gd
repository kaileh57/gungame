class_name VisualsDashHud
extends RefCounted
## Authors the dash overlay — streak quad, prompt, meter and readout — for
## `res://tools/build_visuals.gd`.
##
## IT LIVES APART FROM `visuals_dash.gd` FOR ONE REASON, AND IT IS NOT TIDINESS.
## The builder runs under `--script`, on a bare `SceneTree` that has no autoloads in
## it, and it must PRELOAD whatever it calls a static function on. `visuals_dash.gd`
## declares `PlayerController`, `PlayerCameraRig` and `FreecamController` members;
## preloading it therefore drags `player_camera.gd` and `freecam_controller.gd` into
## the bake, both of which name the `GameSettings` autoload, and both of which
## consequently fail to compile there. That failure cascades — "Failed to compile
## depended scripts" — and the only symptom the builder sees is that the static
## function it wanted has become a nonexistent method, which aborts `_build_scene()`
## and surfaces four frames later as "PackedScene.pack failed". It cost an hour once.
##
## So everything the bake CALLS lives here, in a file that touches nothing but
## `UiStyle` and the engine's own Control types, and everything that runs at play
## time lives in `visuals_dash.gd`, which is only ever `load()`ed and attached.
##
## THE SPLIT HAS A SEAM, and it is the node names. `visuals_dash.gd` resolves
## `Streaks`, `Prompt/Hold`, `Prompt/Meter/Fill` and `Prompt/Speed` by path; this
## file creates them. The two drifting apart is a HUD that silently stops updating,
## so `visuals_dash.gd` refuses to stay quiet about a missing child and the builder
## counts them back off the packed scene.

## Names of the four widgets `visuals_dash.gd` reaches for, relative to the layer.
## Both sides read this array — the builder checks it against the packed scene, and
## the runtime script checks it against the tree it woke up in.
const WIDGETS: PackedStringArray = ["Streaks", "Prompt/Hold", "Prompt/Meter/Fill", "Prompt/Speed"]

## Where the streak overlay's shader lives.
const SHADER_STREAKS: String = "res://demos/visuals/dash_streaks.gdshader"
## Prompt geometry, pixels: the panel's width and height, and its lift off the
## bottom edge.
const PROMPT_SIZE: Vector2 = Vector2(320.0, 76.0)
const PROMPT_LIFT: float = 28.0
## Height of the button and of the meter under it, and where each sits in the panel.
const HOLD_H: float = 34.0
const METER_Y: float = 40.0
const METER_H: float = 5.0
const SPEED_Y: float = 50.0
const SPEED_H: float = 24.0


## The whole node: layer, script, overlay and prompt. `script` is the runtime
## `visuals_dash.gd`, handed in by the builder so this file never has to name it.
static func build(script: Script, prompt: String) -> CanvasLayer:
	var node := CanvasLayer.new()
	node.name = "Dash"
	node.layer = 3
	node.set_script(script)
	node.add_child(_streaks())
	node.add_child(_prompt(prompt))
	return node


## The additive radial streak quad. Built HIDDEN: the script shows it only once the
## ramp is off the floor, so a player standing still pays for no fill at all.
static func _streaks() -> ColorRect:
	var rect := ColorRect.new()
	rect.name = "Streaks"
	rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rect.color = Color(0.0, 0.0, 0.0, 0.0)
	rect.visible = false
	var mat := ShaderMaterial.new()
	mat.shader = load(SHADER_STREAKS) as Shader
	mat.set_shader_parameter("amount", 0.0)
	rect.material = mat
	return rect


## Button, meter and speed readout, centred above the bottom edge.
static func _prompt(prompt: String) -> Control:
	var panel := Control.new()
	panel.name = "Prompt"
	panel.anchor_left = 0.5
	panel.anchor_right = 0.5
	panel.anchor_top = 1.0
	panel.anchor_bottom = 1.0
	panel.offset_left = -PROMPT_SIZE.x * 0.5
	panel.offset_right = PROMPT_SIZE.x * 0.5
	panel.offset_top = -PROMPT_SIZE.y - PROMPT_LIFT
	panel.offset_bottom = -PROMPT_LIFT
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var font: Font = load(UiStyle.FONT_MONO_PATH) as Font
	panel.add_child(_hold(prompt, font))
	panel.add_child(_meter())
	panel.add_child(_speed(font))
	return panel


## The pressable half of the prompt. `MOUSE_FILTER_STOP` is left on deliberately even
## though this demo runs with the pointer captured: a touch event is not a mouse
## event and reaches the button regardless, and the moment anything frees the cursor
## the button works with it. Its main job is still to name the key.
static func _hold(prompt: String, font: Font) -> Button:
	var hold := Button.new()
	hold.name = "Hold"
	hold.text = prompt
	hold.focus_mode = Control.FOCUS_NONE
	hold.action_mode = BaseButton.ACTION_MODE_BUTTON_PRESS
	hold.position = Vector2.ZERO
	hold.size = Vector2(PROMPT_SIZE.x, HOLD_H)
	hold.add_theme_font_override(&"font", font)
	hold.add_theme_font_size_override(&"font_size", 15)
	hold.add_theme_color_override(&"font_color", UiStyle.TEXT)
	hold.add_theme_color_override(&"font_hover_color", UiStyle.GOLD)
	hold.add_theme_color_override(&"font_pressed_color", UiStyle.GOLD)
	return hold


## Track and fill. The fill is driven by its RIGHT ANCHOR rather than by its size, so
## the script writes one float a frame and the layout engine does the rest.
static func _meter() -> Control:
	var meter := Control.new()
	meter.name = "Meter"
	meter.position = Vector2(0.0, METER_Y)
	meter.size = Vector2(PROMPT_SIZE.x, METER_H)
	meter.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var track := ColorRect.new()
	track.name = "Track"
	track.set_anchors_preset(Control.PRESET_FULL_RECT)
	track.color = UiStyle.PANEL_EDGE
	track.mouse_filter = Control.MOUSE_FILTER_IGNORE
	meter.add_child(track)

	var fill := ColorRect.new()
	fill.name = "Fill"
	fill.anchor_left = 0.0
	fill.anchor_top = 0.0
	fill.anchor_right = 0.0
	fill.anchor_bottom = 1.0
	fill.offset_left = 0.0
	fill.offset_top = 0.0
	fill.offset_right = 0.0
	fill.offset_bottom = 0.0
	fill.color = UiStyle.GOLD
	fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	meter.add_child(fill)
	return meter


static func _speed(font: Font) -> Label:
	var speed := Label.new()
	speed.name = "Speed"
	speed.position = Vector2(0.0, SPEED_Y)
	speed.size = Vector2(PROMPT_SIZE.x, SPEED_H)
	speed.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	speed.text = "  0 m/s"
	speed.modulate = UiStyle.TEXT_DIM
	speed.add_theme_font_override(&"font", font)
	speed.add_theme_font_size_override(&"font_size", 17)
	speed.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return speed
