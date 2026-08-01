class_name DiegeticReadout
extends Node3D
## A world-space display: a steel bezel with a screen in it. The screen is a
## SubViewport a `ReadoutCanvas` draws into, composited through the CRT shader.
##
## The panel, the bezel and the grime are baked. The text cannot be — it is the
## number that just changed, which is the entire point of a readout — so the only
## live part is a 512x320 render target that re-renders exactly once per content
## change and costs nothing in between.
##
## Two looks, chosen by `painted`: a phosphor CRT that lights the room a little,
## and a stencilled steel placard that is simply lit like everything else.
##
## [codeblock]
## readout.set_title("MARK 4 'SCRAPJAW'")
## readout.set_lines(["9x39mm  ·  semi", "24 rnd box  ·  2.1 s reload"])
## readout.set_bars(["DAMAGE", "RANGE"], [0.62, 0.31], [UiStyle.WARN, UiStyle.GOOD])
## [/codeblock]

## Stencilled steel instead of a live tube. Also drops the emission to zero, so a
## painted panel is not a light source.
@export var painted: bool = false:
	set = _set_painted
## Multiplies the shader's emission. Only meaningful on the CRT look.
@export_range(0.0, 6.0, 0.05) var glow: float = 1.7:
	set = _set_glow
## Screen colour cast. The CRT bed is green-grey; a warmer tint reads as an older
## tube, a colder one as a Choir panel.
@export var screen_tint: Color = Color(1.0, 1.0, 1.0, 1.0):
	set = _set_screen_tint
## Accent used for the title, rules and default bar colour.
@export var accent: Color = UiStyle.ACCENT:
	set = _set_accent

var _material: ShaderMaterial = null

@onready var _viewport: SubViewport = $Screen/Display
@onready var _canvas: ReadoutCanvas = $Screen/Display/Canvas
@onready var _screen: MeshInstance3D = $Screen


func _ready() -> void:
	_material = _screen.get_active_material(0) as ShaderMaterial
	if _material == null:
		push_error("DiegeticReadout: the Screen mesh carries no ShaderMaterial.")
		return
	# The material is resource_local_to_scene, so this instance owns its own copy
	# and two readouts in one room cannot fight over the same render target.
	_material.set_shader_parameter(&"screen_tex", _viewport.get_texture())
	_apply_style()
	_canvas.set_accent(accent)
	_canvas.set_painted(painted)
	_refresh()


func set_title(text: String) -> void:
	_canvas.set_title(text)
	_refresh()


func set_lines(lines: PackedStringArray) -> void:
	_canvas.set_lines(lines)
	_refresh()


## Stat bars along the bottom. `fractions` are 0..1; short arrays are padded with
## the accent colour rather than erroring, because a caller that gives four labels
## and forgets a colour still wants four bars.
func set_bars(
	labels: PackedStringArray, fractions: PackedFloat32Array, colors: PackedColorArray
) -> void:
	_canvas.set_bars(labels, fractions, colors)
	_refresh()


## Wipe every field. A panel with nothing to say shows an empty lit screen, not
## the last gun's numbers.
func clear() -> void:
	_canvas.set_title("")
	_canvas.set_lines(PackedStringArray())
	_canvas.set_bars(PackedStringArray(), PackedFloat32Array(), PackedColorArray())
	_refresh()


## Re-render the display for exactly one frame.
func _refresh() -> void:
	if _viewport == null:
		return
	_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE


func _apply_style() -> void:
	if _material == null:
		return
	_material.set_shader_parameter(&"style", 1 if painted else 0)
	_material.set_shader_parameter(&"emission_energy", 0.0 if painted else glow)
	_material.set_shader_parameter(&"tint_color", screen_tint)


func _set_painted(value: bool) -> void:
	painted = value
	if not is_node_ready():
		return
	_canvas.set_painted(value)
	_apply_style()
	_refresh()


func _set_glow(value: float) -> void:
	glow = value
	if not is_node_ready():
		return
	_apply_style()


func _set_screen_tint(value: Color) -> void:
	screen_tint = value
	if not is_node_ready():
		return
	_apply_style()


func _set_accent(value: Color) -> void:
	accent = value
	if not is_node_ready():
		return
	_canvas.set_accent(value)
	_refresh()
