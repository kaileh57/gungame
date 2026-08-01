class_name UiStyle
extends RefCounted
## The screen-space UI contract: colours, metrics, timings and the baked Theme.
##
## Screen UI in this project is deliberately scarce — a main menu, a pause menu,
## a settings page, the F3 overlay and the combat reticle. Everything else is a
## physical object you shoot. So there is one style file, not a design system.
##
## Colours are drawn from `Palette`; nothing here invents a hue. The two fonts, the
## slider grabber and the Theme are baked by `res://tools/build_main_menu.gd` and
## loaded from `res://data/ui/`. If the bake has not been run the accessors fall
## back to the engine's own font, which is ugly but never null — the UI still
## functions and the missing bake is obvious on sight.

const FONT_MONO_PATH: String = "res://data/ui/font_mono.tres"
const FONT_DISPLAY_PATH: String = "res://data/ui/font_display.tres"
const THEME_PATH: String = "res://data/ui/ui_theme.tres"
## The one bitmap in the whole screen UI: the slider grabber, which cannot be a
## StyleBox because Godot's Slider asks for an icon.
const GRABBER_PATH: String = "res://data/ui/slider_grabber.tres"
## The two sounds a physical control makes: the clack of it actuating and the
## dead knock of it refusing. Baked by `res://tools/build_ui_assets.gd`, shared by
## every `DiegeticControl` that has not been handed a sound of its own.
const CLICK_SOUND_PATH: String = "res://data/ui/control_click.res"
const DENY_SOUND_PATH: String = "res://data/ui/control_deny.res"

## Panel body. Not black — nothing in this game is black.
const PANEL_FILL: Color = Color(0.055, 0.051, 0.047, 0.94)
## Panel body when it sits over a live 3D scene and must stay readable.
const PANEL_FILL_OPAQUE: Color = Color(0.072, 0.067, 0.061, 1.0)
const PANEL_EDGE: Color = Color(0.302, 0.290, 0.267, 1.0)
## Full-screen dim behind a modal. Alpha is the whole point of it.
const SCRIM: Color = Color(0.035, 0.031, 0.028, 0.72)

const TEXT: Color = Color(0.792, 0.749, 0.659)
const TEXT_DIM: Color = Color(0.510, 0.482, 0.435)
const TEXT_FAINT: Color = Color(0.353, 0.337, 0.310)
const ACCENT: Color = Color(0.847, 0.510, 0.184)
const GOLD: Color = Color(0.902, 0.757, 0.310)
const WARN: Color = Color(0.627, 0.212, 0.212)
const GOOD: Color = Color(0.541, 0.604, 0.420)
const COOL: Color = Color(0.341, 0.627, 0.733)

## Row heights and paddings, in CanvasItem pixels at the 1920x1080 design size.
const PAD: int = 14
const ROW_H: int = 30
const CORNER: int = 3
const EDGE_W: int = 2

const FONT_SIZE_TITLE: int = 30
const FONT_SIZE_HEAD: int = 19
const FONT_SIZE_BODY: int = 15
const FONT_SIZE_SMALL: int = 13

## Nothing in this UI animates for longer than this. The user asked for fast.
const ANIM_FAST: float = 0.12
const ANIM_SLOW: float = 0.15

static var _mono: Font = null
static var _display: Font = null
static var _theme: Theme = null
static var _click: AudioStream = null
static var _deny: AudioStream = null


## The fixed-pitch face. Used by the debug overlay, every readout and every number
## that must not jitter as it counts.
static func mono_font() -> Font:
	if _mono == null:
		_mono = _load_font(FONT_MONO_PATH)
	return _mono


## The condensed face used for headings, demo titles and stencilled signage.
static func display_font() -> Font:
	if _display == null:
		_display = _load_font(FONT_DISPLAY_PATH)
	return _display


## The baked Theme, or null when the UI bake has not been run.
static func ui_theme() -> Theme:
	if _theme == null and ResourceLoader.exists(THEME_PATH):
		_theme = ResourceLoader.load(THEME_PATH, "Theme") as Theme
	return _theme


## The clack a control makes when it actuates. One stream, shared by every control
## in the game — an `AudioStreamPlayer3D` reads it, it is never mutated, and a copy
## per control would be forty copies of the same 12 kB.
static func click_sound() -> AudioStream:
	if _click == null:
		_click = _load_sound(CLICK_SOUND_PATH)
	return _click


## The knock a control makes when it refuses: disabled, under-powered, or still
## inside its cooldown.
static func deny_sound() -> AudioStream:
	if _deny == null:
		_deny = _load_sound(DENY_SOUND_PATH)
	return _deny


## A flat panel box. `edge` of width 0 draws no border.
static func panel_style(
	fill: Color, edge: Color = PANEL_EDGE, width: int = EDGE_W, radius: int = CORNER
) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = fill
	sb.set_border_width_all(width)
	sb.border_color = edge
	sb.set_corner_radius_all(radius)
	sb.content_margin_left = PAD
	sb.content_margin_right = PAD
	sb.content_margin_top = PAD
	sb.content_margin_bottom = PAD
	return sb


## Button faces. Scav UI is a welded plate: a dark fill, a bright left edge that
## grows when you touch it, and no gradients anywhere.
static func button_style(fill: Color, edge: Color, left_bar: int) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = fill
	sb.border_color = edge
	sb.border_width_left = left_bar
	sb.border_width_top = 0
	sb.border_width_right = 0
	sb.border_width_bottom = 0
	sb.set_corner_radius_all(0)
	sb.content_margin_left = PAD
	sb.content_margin_right = PAD
	sb.content_margin_top = 7
	sb.content_margin_bottom = 7
	return sb


## Interpolate a bar colour from bad to good across 0..1. Used by the settings
## page's fps readout and by every stat bar on a readout panel.
static func meter_color(t: float) -> Color:
	var x: float = clampf(t, 0.0, 1.0)
	if x < 0.5:
		return WARN.lerp(ACCENT, x * 2.0)
	return ACCENT.lerp(GOOD, (x - 0.5) * 2.0)


## Null rather than a fallback: a missing font makes the UI unreadable and has to
## be shouted about, a missing sound only makes it quiet.
static func _load_sound(path: String) -> AudioStream:
	if not ResourceLoader.exists(path):
		push_warning("UiStyle: %s is missing. Run res://tools/build_ui_assets.gd." % path)
		return null
	return ResourceLoader.load(path, "AudioStream") as AudioStream


static func _load_font(path: String) -> Font:
	if ResourceLoader.exists(path):
		var f: Font = ResourceLoader.load(path, "Font") as Font
		if f != null:
			return f
	push_warning("UiStyle: %s is missing. Run res://tools/build_main_menu.gd." % path)
	return ThemeDB.fallback_font
