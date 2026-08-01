extends SceneTree
## Bakes the whole screen-and-menu shell: the two fonts, the slider grabber, the
## Theme, the settings page, the pause menu and the 3D main menu.
##
## Run headless:
##   godot --headless --path <project> --script res://tools/build_main_menu.gd
##
## Everything it emits is a shipped artifact. Nothing in `res://ui/` generates
## geometry at runtime — the workshop, the bench, the board, the plates and the
## lamp are `ArrayMesh` resources packed into `main_menu.tscn` by this file and
## `res://tools/menu_shop.gd`, which owns the room and the shell audit.
##
## The menu is a PLACE. Eight demo plates hang on the board behind the bench, four
## to a row, each in its own lip; the two utility plates lie on the bench itself.
## Nothing stands on air and no two pieces of text share a line — the readout has
## a lane of its own below the bottom plate row, because when it sat at plate
## height its words showed through the gaps between the plates.

const OUT_DIR: String = "res://data/ui"
const OUT_MENU: String = "res://ui/main_menu.tscn"
const OUT_PAUSE: String = "res://ui/pause_menu.tscn"
const OUT_SETTINGS: String = "res://ui/settings_panel.tscn"
const OUT_SIGN: String = "res://data/ui/lobby_sign.tscn"
const OUT_REPORT: String = "res://data/ui/build_report.txt"

const MAIN_MENU_SCRIPT: String = "res://ui/main_menu.gd"
const PAUSE_MENU_SCRIPT: String = "res://ui/pause_menu.gd"
const SETTINGS_SCRIPT: String = "res://ui/settings_panel.gd"
const CONTROL_SCRIPT: String = "res://ui/diegetic/diegetic_control.gd"
const LOBBY_SCRIPT: String = "res://ui/lobby/lobby_bench.gd"
const CONSOLE_SCRIPT: String = "res://ui/lobby/join_console.gd"
const DOTS_SCRIPT: String = "res://ui/lobby/lobby_dots.gd"
const SIGN_SCRIPT: String = "res://ui/lobby/lobby_sign.gd"
const WORLD_SCENE: String = "res://art/scav_world.tscn"

## Typeface sources. Read at bake time only — the outlines end up inside the
## saved `FontFile`, so the shipped game never touches these files.
const FONT_DISPLAY_TTF: String = "res://art/fonts/AnonymousPro-Bold.ttf"
const FONT_MONO_TTF: String = "res://art/fonts/AnonymousPro-Regular.ttf"

const MAT_STEEL: String = "res://art/materials/scrap_steel.tres"
const MAT_TIMBER: String = "res://art/materials/scrap_timber.tres"
const MAT_POLYMER: String = "res://art/materials/scrap_polymer.tres"
const MAT_CANVAS: String = "res://art/materials/scrap_canvas.tres"
const MAT_EMBER: String = "res://art/materials/glow_ember.tres"

## The room, the bench, the board and the shell audit. Held as a constant so the
## layout numbers are shared rather than copied: the plate grid is placed against
## `MenuShop.BOARD_FACE` and its two row heights, and a number that lived in two
## files would drift the first time one of them moved.
const MenuShop := preload("res://tools/menu_shop.gd")

## The lobby's furniture — the join console, the roster, the dots, the lock bar and
## the falling toast — and the numbers behind where they sit. A third file for the
## same reason the second one exists: none of them may carry a thousand lines.
const MenuLobby := preload("res://tools/menu_lobby.gd")

## Seats every plate on what carries it. A lean is not free: it swings the plate's
## far edge back by half its height times the sine of the lean, and both plate
## families here were placed by a constant that did not know that.
const PanelMount := preload("res://ui/diegetic/panel_mount.gd")

## Demo plates. Nine degrees is the lean of a plate resting in a lip with its top
## against the board — enough to catch the lamp, not so much that the title
## foreshortens. At nine degrees a 270 mm plate's top-back corner swings 21 mm back,
## which is what used to bury the plate's top edge 13 mm inside the board.
const CARD_TILT_DEG: float = 9.0
const CARD_PLATE: Vector3 = Vector3(0.46, 0.27, 0.020)
const CARD_LIP: Vector3 = Vector3(0.38, 0.030, 0.075)
const CARD_FONT: int = 34
## Plates per row. Eight demos make two rows of four; a ninth would tighten the
## pitch rather than start a third row, because there is no third lane on the
## board — the readout owns the one below.
const CARD_COLUMNS: int = 4

## The two utility plates lie back on the bench itself, out of the demo grid. Fifty-
## six degrees is a plate laid almost flat, and it swings the plate's low edge 52 mm
## DOWN — which is why these two were solved against the bench top rather than the
## board, and why the old 29 mm lift had 13 mm of plate inside the timber.
const UTIL_TILT_DEG: float = 56.0
const UTIL_PLATE: Vector3 = Vector3(0.34, 0.125, 0.018)
const UTIL_PLATE_LOCAL: Vector3 = Vector3(0.0, 0.029, 0.008)
const UTIL_BLOCK: Vector3 = Vector3(0.28, 0.06, 0.05)
const UTIL_BLOCK_LOCAL: Vector3 = Vector3(0.0, 0.010, -0.012)
const UTIL_X: float = 0.62
const UTIL_Z: float = 0.255

## Where the eye stands. The fov baked here is a starting value only: `main_menu`
## overwrites it with the player's setting on ready, so the shed is sized for a
## wide field of view to find more room rather than more void.
const EYE_AT: Vector3 = Vector3(0.0, 1.62, 1.50)
const EYE_PITCH_DEG: float = -6.5

# --- the lobby ---------------------------------------------------------------
#
# The lobby's own furniture is cut by `res://tools/menu_lobby.gd`, which holds its
# numbers and the reasoning behind them. What stays here is the HOST plate, because
# it is a utility plate like SETTINGS and SHUT DOWN and is built by the same `_build_card`
# against the same bench-top mount.

## The HOST plate, left of the console, in the 16 cm of bench between it and the
## SETTINGS plate. Same lean and same mount as the other two utility plates.
const HOST_X: float = -0.335
const HOST_PLATE: Vector3 = Vector3(0.16, 0.105, 0.016)
const HOST_BLOCK: Vector3 = Vector3(0.13, 0.05, 0.045)

## Loaded at run time rather than named as a type, so that compiling this builder
## does not drag `main_menu.gd` in before the autoloads it refers to exist.
var _menu_script: GDScript = null
var _menu_consts: Dictionary = {}
var _shop: RefCounted = null
var _kit: RefCounted = null
var _steel: Material = null
var _polymer: Material = null
var _ember: Material = null
var _display: Font = null
var _report: PackedStringArray = PackedStringArray()
var _failures: int = 0
var _shells: int = 0


## `_initialize`, not `_init`: the SceneTree's autoloads do not exist yet when a
## `--script` main loop is constructed, and every UI script this builder loads
## refers to `GameSettings` or `SceneRouter` by name. Compiling them a moment too
## early costs the packed scenes their scripts, silently.
func _initialize() -> void:
	if not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(OUT_DIR)):
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	_line("build_main_menu")
	_menu_script = load(MAIN_MENU_SCRIPT) as GDScript
	_menu_consts = _menu_script.get_script_constant_map()
	_build_fonts()
	_build_grabber()
	_build_theme()
	_build_settings_scene()
	_build_pause_scene()
	_build_menu_scene()
	_line("")
	_line("shells checked        %d" % _shells)
	_line("failures              %d" % _failures)
	_line("RESULT: %s" % ("PASS" if _failures == 0 else "FAIL"))
	var text: String = "\n".join(_report) + "\n"
	var f: FileAccess = FileAccess.open(OUT_REPORT, FileAccess.WRITE)
	if f != null:
		f.store_string(text)
		f.close()
	print(text)
	quit(0 if _failures == 0 else 1)


# --- assets -----------------------------------------------------------------


## Both faces are BAKED: the typeface bytes are read once here and stored inside
## the `FontFile`, so the shipped `.tres` carries its own outlines and renders the
## same glyphs on every machine.
##
## They used to be `SystemFont` name lists, which bake nothing — they resolve
## against whatever the host has installed, so a placard stencilled in Bahnschrift
## on Windows came out as DejaVu Sans everywhere else. The stencilled signage IS
## the look; it cannot be a per-machine lottery.
##
## Anonymous Pro carries both roles: the bold for signage and headings, the
## regular for readouts and the F3 overlay. It is a screen-first industrial
## typewriter face with unambiguous 0/O and 1/l, which is what a diegetic readout
## needs, and it is SIL Open Font Licence — redistributable, so shipping it is an
## art decision rather than a legal one. Licence travels with it in
## res://art/fonts/OFL.txt.
func _build_fonts() -> void:
	var mono: FontFile = _font_from(FONT_MONO_TTF)
	mono.subpixel_positioning = TextServer.SUBPIXEL_POSITIONING_DISABLED
	_save(mono, UiStyle.FONT_MONO_PATH)

	var display: FontFile = _font_from(FONT_DISPLAY_TTF)
	_save(display, UiStyle.FONT_DISPLAY_PATH)


## One `FontFile` with the outlines embedded. `load_dynamic_font` reads the file
## through `FileAccess` and copies it into `data`, which is a storage property —
## that copy is what `ResourceSaver` writes and what the game loads. An empty
## `data` after this is a missing source file, and a font that silently falls back
## to Godot's built-in face is exactly the failure this replaces.
func _font_from(ttf: String) -> FontFile:
	var f := FontFile.new()
	f.load_dynamic_font(ttf)
	if f.data.is_empty():
		_failures += 1
		_line("  FONT FAIL   %s embedded no outline data" % ttf.get_file())
	f.antialiasing = TextServer.FONT_ANTIALIASING_GRAY
	f.hinting = TextServer.HINTING_LIGHT
	f.multichannel_signed_distance_field = false
	return f


## A slider grabber: a stubby orange plate with a dark shoulder. Drawn here rather
## than imported, because a two-colour 16x16 is not worth an art pipeline, and
## `PortableCompressedTexture2D` is the one texture class that carries its pixels
## inside a `.tres` without needing the import step to have run.
func _build_grabber() -> void:
	var size := 18
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.0, 0.0, 0.0, 0.0))
	for y: int in size:
		for x: int in size:
			var inset: bool = x >= 4 and x < size - 4 and y >= 1 and y < size - 1
			if not inset:
				continue
			var edge: bool = x == 4 or x == size - 5 or y == 1 or y == size - 2
			img.set_pixel(x, y, UiStyle.PANEL_EDGE if edge else UiStyle.ACCENT)
	var tex := PortableCompressedTexture2D.new()
	# Without this the compressed payload is dropped once the texture has been
	# uploaded to the GPU, and `ResourceSaver` then writes a header with no pixels
	# at all: an 18x18 grabber that loads as a null texture on the next boot.
	tex.keep_compressed_buffer = true
	tex.create_from_image(img, PortableCompressedTexture2D.COMPRESSION_MODE_LOSSLESS)
	_save(tex, UiStyle.GRABBER_PATH)


## One Theme for the whole screen UI. Godot falls back to its own default theme for
## any item this does not name, so every widget the project actually uses is named
## here — a missing entry is a blue-grey Godot button in the middle of a scav menu.
func _build_theme() -> void:
	var theme := Theme.new()
	var mono: Font = ResourceLoader.load(UiStyle.FONT_MONO_PATH, "Font") as Font
	var display: Font = ResourceLoader.load(UiStyle.FONT_DISPLAY_PATH, "Font") as Font
	var grabber: Texture2D = ResourceLoader.load(UiStyle.GRABBER_PATH, "Texture2D") as Texture2D
	theme.default_font = mono
	theme.default_font_size = UiStyle.FONT_SIZE_BODY

	theme.set_font("font", "Label", mono)
	theme.set_color("font_color", "Label", UiStyle.TEXT)
	theme.set_color("font_shadow_color", "Label", Color(0.0, 0.0, 0.0, 0.0))

	var flat := StyleBoxEmpty.new()
	theme.set_stylebox("panel", "Panel", UiStyle.panel_style(UiStyle.PANEL_FILL_OPAQUE))
	theme.set_stylebox("panel", "PanelContainer", UiStyle.panel_style(UiStyle.PANEL_FILL_OPAQUE))

	_style_button(theme, "Button", display, grabber)
	_style_button(theme, "OptionButton", display, grabber)
	theme.set_constant("arrow_margin", "OptionButton", UiStyle.PAD)

	theme.set_font("font", "CheckButton", mono)
	theme.set_color("font_color", "CheckButton", UiStyle.TEXT)
	theme.set_color("font_hover_color", "CheckButton", UiStyle.GOLD)
	theme.set_color("icon_normal_color", "CheckButton", UiStyle.TEXT_DIM)
	theme.set_color("icon_pressed_color", "CheckButton", UiStyle.ACCENT)
	theme.set_color("icon_hover_color", "CheckButton", UiStyle.TEXT)
	theme.set_color("icon_hover_pressed_color", "CheckButton", UiStyle.GOLD)
	for state: String in ["normal", "hover", "pressed", "disabled", "focus"]:
		theme.set_stylebox(state, "CheckButton", flat)

	var track := StyleBoxFlat.new()
	track.bg_color = Color(0.031, 0.029, 0.027, 1.0)
	track.border_color = UiStyle.PANEL_EDGE
	track.set_border_width_all(1)
	track.content_margin_top = 5.0
	track.content_margin_bottom = 5.0
	var filled := StyleBoxFlat.new()
	filled.bg_color = UiStyle.ACCENT.darkened(0.45)
	filled.content_margin_top = 5.0
	filled.content_margin_bottom = 5.0
	theme.set_stylebox("slider", "HSlider", track)
	theme.set_stylebox("grabber_area", "HSlider", filled)
	theme.set_stylebox("grabber_area_highlight", "HSlider", filled)
	theme.set_icon("grabber", "HSlider", grabber)
	theme.set_icon("grabber_highlight", "HSlider", grabber)
	theme.set_constant("center_grabber", "HSlider", 1)

	var bar := StyleBoxFlat.new()
	bar.bg_color = Color(0.031, 0.029, 0.027, 1.0)
	var thumb := StyleBoxFlat.new()
	thumb.bg_color = UiStyle.TEXT_FAINT
	var thumb_hot := StyleBoxFlat.new()
	thumb_hot.bg_color = UiStyle.ACCENT
	for cls: String in ["VScrollBar", "HScrollBar"]:
		theme.set_stylebox("scroll", cls, bar)
		theme.set_stylebox("grabber", cls, thumb)
		theme.set_stylebox("grabber_highlight", cls, thumb_hot)
		theme.set_stylebox("grabber_pressed", cls, thumb_hot)
	theme.set_stylebox("panel", "ScrollContainer", flat)

	theme.set_stylebox("panel", "PopupMenu", UiStyle.panel_style(UiStyle.PANEL_FILL_OPAQUE))
	theme.set_font("font", "PopupMenu", mono)
	theme.set_color("font_color", "PopupMenu", UiStyle.TEXT)
	theme.set_color("font_hover_color", "PopupMenu", UiStyle.GOLD)
	var hot := StyleBoxFlat.new()
	hot.bg_color = UiStyle.ACCENT.darkened(0.55)
	theme.set_stylebox("hover", "PopupMenu", hot)

	theme.set_stylebox("panel", "TooltipPanel", UiStyle.panel_style(UiStyle.PANEL_FILL_OPAQUE))
	theme.set_font("font", "TooltipLabel", mono)
	theme.set_font_size("font_size", "TooltipLabel", UiStyle.FONT_SIZE_SMALL)
	theme.set_color("font_color", "TooltipLabel", UiStyle.TEXT_DIM)

	_save(theme, UiStyle.THEME_PATH)


func _style_button(theme: Theme, cls: String, font: Font, _grabber: Texture2D) -> void:
	theme.set_font("font", cls, font)
	theme.set_font_size("font_size", cls, UiStyle.FONT_SIZE_BODY)
	theme.set_stylebox(
		"normal", cls, UiStyle.button_style(Color(0.098, 0.090, 0.082, 1.0), UiStyle.TEXT_FAINT, 3)
	)
	theme.set_stylebox(
		"hover", cls, UiStyle.button_style(Color(0.145, 0.129, 0.110, 1.0), UiStyle.ACCENT, 6)
	)
	theme.set_stylebox(
		"pressed", cls, UiStyle.button_style(Color(0.212, 0.145, 0.075, 1.0), UiStyle.GOLD, 6)
	)
	theme.set_stylebox(
		"focus", cls, UiStyle.button_style(Color(0.0, 0.0, 0.0, 0.0), UiStyle.GOLD, 3)
	)
	theme.set_stylebox(
		"disabled",
		cls,
		UiStyle.button_style(Color(0.070, 0.066, 0.062, 1.0), UiStyle.TEXT_FAINT, 2)
	)
	theme.set_color("font_color", cls, UiStyle.TEXT)
	theme.set_color("font_hover_color", cls, UiStyle.GOLD)
	theme.set_color("font_pressed_color", cls, UiStyle.GOLD)
	theme.set_color("font_focus_color", cls, UiStyle.TEXT)
	theme.set_color("font_disabled_color", cls, UiStyle.TEXT_FAINT)


# --- screen scenes ----------------------------------------------------------


func _build_settings_scene() -> void:
	var root := Control.new()
	root.name = "SettingsPanel"
	root.set_script(load(SETTINGS_SCRIPT))
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.theme = ResourceLoader.load(UiStyle.THEME_PATH, "Theme") as Theme
	root.mouse_filter = Control.MOUSE_FILTER_STOP

	var scrim := ColorRect.new()
	scrim.name = "Scrim"
	scrim.color = UiStyle.SCRIM
	scrim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(scrim)

	var frame := PanelContainer.new()
	frame.name = "Frame"
	frame.set_anchors_preset(Control.PRESET_CENTER)
	frame.custom_minimum_size = Vector2(820.0, 720.0)
	frame.grow_horizontal = Control.GROW_DIRECTION_BOTH
	frame.grow_vertical = Control.GROW_DIRECTION_BOTH
	root.add_child(frame)

	var body := VBoxContainer.new()
	body.name = "Body"
	body.add_theme_constant_override("separation", 8)
	frame.add_child(body)

	var header := HBoxContainer.new()
	header.name = "Header"
	body.add_child(header)
	var title := Label.new()
	title.name = "Title"
	title.text = "SETTINGS"
	title.add_theme_font_override("font", ResourceLoader.load(UiStyle.FONT_DISPLAY_PATH, "Font"))
	title.add_theme_font_size_override("font_size", UiStyle.FONT_SIZE_TITLE)
	title.add_theme_color_override("font_color", UiStyle.ACCENT)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	var fps := Label.new()
	fps.name = "Fps"
	fps.text = "-- fps"
	fps.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	fps.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	fps.custom_minimum_size = Vector2(220.0, 0.0)
	header.add_child(fps)

	var rule := ColorRect.new()
	rule.name = "Rule"
	rule.color = UiStyle.PANEL_EDGE
	rule.custom_minimum_size = Vector2(0.0, 2.0)
	body.add_child(rule)

	var scroll := ScrollContainer.new()
	scroll.name = "Scroll"
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	body.add_child(scroll)
	var rows := VBoxContainer.new()
	rows.name = "Rows"
	rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rows.add_theme_constant_override("separation", 4)
	scroll.add_child(rows)

	var footer := HBoxContainer.new()
	footer.name = "Footer"
	footer.add_theme_constant_override("separation", 10)
	body.add_child(footer)
	var reset := Button.new()
	reset.name = "ResetButton"
	reset.text = "RESET TO DEFAULTS"
	footer.add_child(reset)
	var gap := Control.new()
	gap.name = "Gap"
	gap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	footer.add_child(gap)
	var close := Button.new()
	close.name = "CloseButton"
	close.text = "CLOSE"
	close.custom_minimum_size = Vector2(180.0, 0.0)
	footer.add_child(close)

	_pack(root, OUT_SETTINGS)


func _build_pause_scene() -> void:
	var root := CanvasLayer.new()
	root.name = "PauseMenu"
	root.set_script(load(PAUSE_MENU_SCRIPT))
	root.layer = 110

	var scrim := ColorRect.new()
	scrim.name = "Scrim"
	scrim.color = UiStyle.SCRIM
	scrim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(scrim)

	var holder := Control.new()
	holder.name = "Root"
	holder.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.theme = ResourceLoader.load(UiStyle.THEME_PATH, "Theme") as Theme
	root.add_child(holder)

	var frame := PanelContainer.new()
	frame.name = "Frame"
	frame.set_anchors_preset(Control.PRESET_CENTER)
	frame.custom_minimum_size = Vector2(420.0, 0.0)
	frame.grow_horizontal = Control.GROW_DIRECTION_BOTH
	frame.grow_vertical = Control.GROW_DIRECTION_BOTH
	holder.add_child(frame)

	var body := VBoxContainer.new()
	body.name = "Body"
	body.add_theme_constant_override("separation", 8)
	frame.add_child(body)

	var title := Label.new()
	title.name = "Title"
	title.text = "HELD"
	title.add_theme_font_override("font", ResourceLoader.load(UiStyle.FONT_DISPLAY_PATH, "Font"))
	title.add_theme_font_size_override("font_size", UiStyle.FONT_SIZE_TITLE)
	title.add_theme_color_override("font_color", UiStyle.ACCENT)
	body.add_child(title)

	var subtitle := Label.new()
	subtitle.name = "Subtitle"
	subtitle.text = ""
	subtitle.add_theme_color_override("font_color", UiStyle.TEXT_DIM)
	subtitle.add_theme_font_size_override("font_size", UiStyle.FONT_SIZE_SMALL)
	body.add_child(subtitle)

	var rule := ColorRect.new()
	rule.name = "Rule"
	rule.color = UiStyle.PANEL_EDGE
	rule.custom_minimum_size = Vector2(0.0, 2.0)
	body.add_child(rule)

	for spec: Array in [
		["Resume", "RESUME"], ["SettingsButton", "SETTINGS"], ["MainMenuButton", "MAIN MENU"]
	]:
		var button := Button.new()
		button.name = String(spec[0])
		button.text = String(spec[1])
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		body.add_child(button)

	var host := Control.new()
	host.name = "SettingsHost"
	host.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	host.theme = ResourceLoader.load(UiStyle.THEME_PATH, "Theme") as Theme
	root.add_child(host)
	host.add_child(_settings_instance())

	_pack(root, OUT_PAUSE)


func _settings_instance() -> Control:
	var packed: PackedScene = ResourceLoader.load(OUT_SETTINGS, "PackedScene") as PackedScene
	var inst := packed.instantiate() as Control
	inst.name = "SettingsPanel"
	inst.visible = false
	return inst


# --- the 3D menu ------------------------------------------------------------


func _build_menu_scene() -> void:
	_steel = ResourceLoader.load(MAT_STEEL, "Material") as Material
	_polymer = ResourceLoader.load(MAT_POLYMER, "Material") as Material
	_ember = ResourceLoader.load(MAT_EMBER, "Material") as Material
	_display = ResourceLoader.load(UiStyle.FONT_DISPLAY_PATH, "Font") as Font
	_shop = MenuShop.new(
		_steel,
		ResourceLoader.load(MAT_TIMBER, "Material") as Material,
		_polymer,
		ResourceLoader.load(MAT_CANVAS, "Material") as Material,
		_ember
	)
	_kit = MenuLobby.new(_steel, _polymer, _ember, _display, load(CONTROL_SCRIPT) as GDScript)
	_pack(_kit.build_sign(load(SIGN_SCRIPT) as GDScript), OUT_SIGN)

	var root := Node3D.new()
	root.name = "MainMenu"
	root.set_script(_menu_script)

	var world: Node = (ResourceLoader.load(WORLD_SCENE, "PackedScene") as PackedScene).instantiate()
	world.name = "ScavWorld"
	root.add_child(world)

	var eye := Camera3D.new()
	eye.name = "Eye"
	eye.current = true
	eye.fov = 78.0
	eye.near = 0.05
	# Far enough to keep the ash flats behind the doorway, which is where the
	# horizon and the haze come from.
	eye.far = 900.0
	eye.position = EYE_AT
	eye.rotation = Vector3(deg_to_rad(EYE_PITCH_DEG), 0.0, 0.0)
	root.add_child(eye)

	_shop.build_room(root)

	var bench := Node3D.new()
	bench.name = "Bench"
	root.add_child(bench)
	_shop.build_bench(bench)
	_shop.build_board(bench)
	_build_signage(bench)

	_shop.build_clutter(root)
	_shop.build_lamp(root)
	_shop.build_fill(root)
	root.add_child(_build_cards())
	root.add_child(_build_lobby())

	var ui := CanvasLayer.new()
	ui.name = "Ui"
	ui.layer = 100
	root.add_child(ui)
	ui.add_child(_settings_instance())

	_pack(root, OUT_MENU)
	for kit: RefCounted in [_shop, _kit]:
		_shells += int(kit.shells)
		_failures += int(kit.failures)
		for line: String in kit.lines as PackedStringArray:
			_line(line)


## The two pieces of standing text. `Board` is the readout `main_menu.gd` writes
## the hovered demo's blurb into, and it lives on its own panel below the bottom
## plate row: at plate height its words came out through the gaps between plates
## and read as another label bleeding through.
func _build_signage(bench: Node3D) -> void:
	bench.add_child(
		_shop.label(
			"Title",
			"SCAV WORKS",
			_display,
			54,
			0.0022,
			UiStyle.ACCENT,
			Vector3(0.0, MenuShop.TITLE_Y, MenuShop.BOARD_FACE + MenuShop.TITLE_PLATE.z - 0.004)
		)
	)
	var board: Label3D = _shop.label(
		"Board",
		String(_menu_consts["BOARD_IDLE"]),
		_display,
		32,
		0.0018,
		UiStyle.TEXT,
		Vector3(0.0, MenuShop.READOUT_Y, MenuShop.BOARD_FACE + MenuShop.READOUT.z - 0.003)
	)
	board.width = (MenuShop.READOUT.x - 0.14) / 0.0018
	board.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	bench.add_child(board)


## The plate grid. Demos fill the board four to a row from the top down; the two
## utility plates lie on the bench where they cannot be mistaken for a demo.
func _build_cards() -> Node3D:
	var cards := Node3D.new()
	cards.name = "Cards"
	var ids: PackedStringArray = SceneRouter.DEMO_ORDER
	var columns: int = maxi(CARD_COLUMNS, ceili(float(ids.size()) * 0.5))
	# The grid gives up pitch before it gives up the board's margins, and the
	# plate gives up width before it touches its neighbour.
	var pitch: float = minf(MenuShop.CARD_COL, (MenuShop.BOARD_W - 0.22) / float(columns))
	var plate := Vector3(minf(CARD_PLATE.x, pitch - 0.12), CARD_PLATE.y, CARD_PLATE.z)
	for i: int in ids.size():
		var info: Dictionary = SceneRouter.DEMOS[ids[i]]
		var column: int = i % columns
		var row: int = i / columns
		var x: float = (float(column) - float(columns - 1) * 0.5) * pitch
		var y: float = (
			MenuShop.CARD_ROW_HIGH - float(row) * (MenuShop.CARD_ROW_HIGH - MenuShop.CARD_ROW_LOW)
		)
		var spec := _demo_spec(StringName(ids[i]), String(info["title"]), Vector3(x, y, 0.0))
		spec.plate_size = plate
		cards.add_child(_build_card("Card_" + ids[i], spec))
	cards.add_child(
		_build_card(
			"Card_settings",
			_util_spec(_menu_consts["ID_SETTINGS"], "SETTINGS", -UTIL_X, UiStyle.COOL)
		)
	)
	cards.add_child(
		_build_card(
			"Card_quit", _util_spec(_menu_consts["ID_QUIT"], "SHUT DOWN", UTIL_X, UiStyle.WARN)
		)
	)
	return cards


## One plate. The bracket is a separate box that overlaps both what carries the
## plate and the plate itself, so the plate never floats and the joint has no seam
## to see through.
func _build_card(node_name: String, spec: PlateSpec) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = node_name
	body.set_script(load(CONTROL_SCRIPT))
	body.position = spec.origin
	body.collision_layer = GameLayers.PROP
	body.collision_mask = 0
	body.set("control_id", spec.id)
	body.set("cooldown", 0.25)

	body.add_child(
		_shop.mesh_node(
			"Bracket",
			_shop.box(spec.bracket_size, "plate bracket"),
			spec.frame_material,
			spec.bracket_local,
			0.5
		)
	)

	# The lean and the standoff are one solve. `spec.plate_local` names where the
	# plate goes on the two axes it is free on; the third is derived from the plate's
	# real bounds, its lean and the box it rests against, and can never be a constant
	# somebody forgot to re-derive after changing the angle.
	var seat := PanelMount.new()
	seat.axis = spec.mount_axis
	seat.tilt_degrees = -spec.tilt_deg
	var plate: MeshInstance3D = _shop.mesh_node(
		"Plate", _shop.box(spec.plate_size, "plate"), spec.plate_material, Vector3.ZERO, 0.66
	)
	body.add_child(plate)
	var tilt: Transform3D = seat.apply(
		plate, _local(spec.support, spec.origin), spec.plate_local, spec.support_name
	)

	var face: float = spec.plate_size.z * 0.5 + 0.003
	var label: Label3D = _shop.label(
		"Label", spec.title, spec.font, spec.font_size, 0.0016, spec.label_color, Vector3.ZERO
	)
	label.transform = tilt * Transform3D(Basis(), Vector3(0.0, spec.label_y, face))
	label.width = spec.plate_size.x / 0.0016 * 0.92
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.add_child(label)

	var tag: Label3D = _shop.label(
		"Tag",
		"",
		spec.font,
		maxi(14, spec.font_size - 10),
		0.0016,
		UiStyle.TEXT_FAINT,
		Vector3.ZERO
	)
	tag.transform = tilt * Transform3D(Basis(), Vector3(0.0, -spec.plate_size.y * 0.30, face))
	body.add_child(tag)

	var shape := CollisionShape3D.new()
	shape.name = "Shape"
	var box := BoxShape3D.new()
	# Padded outward so the cursor grabs the plate slightly before it touches it,
	# which is the difference between a menu that feels crisp and one that feels
	# slippery. Never padded into its neighbour.
	box.size = Vector3(spec.plate_size.x + 0.03, spec.plate_size.y + 0.03, spec.plate_size.z + 0.05)
	shape.shape = box
	shape.transform = tilt
	body.add_child(shape)
	return body


## A demo plate: full size, resting in a lip on the board. `at` is its place in
## the grid; the body itself is parked on the board's front face, so the lip can
## reach back into the board and the plate can lean its top against it.
func _demo_spec(id: StringName, title: String, at: Vector3) -> PlateSpec:
	var spec := PlateSpec.new()
	spec.id = id
	spec.title = title
	spec.origin = Vector3(at.x, at.y, MenuShop.BOARD_FACE)
	spec.plate_size = CARD_PLATE
	spec.plate_local = Vector3(0.0, 0.0, CARD_PLATE.z * 0.5 + 0.008)
	spec.bracket_size = CARD_LIP
	spec.bracket_local = Vector3(0.0, -CARD_PLATE.y * 0.5 + 0.007, CARD_LIP.z * 0.5 - 0.016)
	spec.tilt_deg = CARD_TILT_DEG
	spec.label_y = CARD_PLATE.y * 0.16
	spec.font_size = CARD_FONT
	spec.frame_material = _steel
	spec.plate_material = _polymer
	spec.font = _display
	spec.label_color = UiStyle.TEXT
	spec.support = _board_box()
	spec.support_name = "Board"
	return spec


## The board the demo plates rest against, and the bench top the utility plates lie
## on. Both are read straight off `MenuShop`, so a plate cannot be solved against a
## board that has since moved.
func _board_box() -> AABB:
	var mid: float = (MenuShop.BOARD_BOTTOM + MenuShop.BOARD_TOP) * 0.5
	var span: float = MenuShop.BOARD_TOP - MenuShop.BOARD_BOTTOM
	var size := Vector3(MenuShop.BOARD_W, span, MenuShop.BOARD_T)
	return PanelMount.centred(Vector3(0.0, mid, MenuShop.BOARD_Z), size)


func _bench_top_box() -> AABB:
	var y: float = MenuShop.BENCH_TOP_Y - MenuShop.BENCH_TOP_T * 0.5
	var size := Vector3(MenuShop.BENCH_W, MenuShop.BENCH_TOP_T, MenuShop.BENCH_D)
	return PanelMount.centred(Vector3(0.0, y, 0.0), size)


## A support box moved into the frame of a plate body standing at `origin`.
func _local(box: AABB, origin: Vector3) -> AABB:
	return AABB(box.position - origin, box.size)


## A utility plate: half size, laid back on the bench top against a steel block,
## where it is out of the demo grid but still under the lamp.
func _util_spec(id: StringName, title: String, x: float, label_color: Color) -> PlateSpec:
	var spec := _demo_spec(id, title, Vector3(x, 0.0, 0.0))
	spec.origin = Vector3(x, MenuShop.BENCH_TOP_Y, UTIL_Z)
	spec.plate_size = UTIL_PLATE
	spec.plate_local = UTIL_PLATE_LOCAL
	spec.bracket_size = UTIL_BLOCK
	spec.bracket_local = UTIL_BLOCK_LOCAL
	spec.tilt_deg = UTIL_TILT_DEG
	spec.label_y = 0.0
	spec.font_size = 22
	spec.label_color = label_color
	# Lying back on the bench, not hanging on the board: the standoff this one needs
	# is upward off the timber it rests on.
	spec.mount_axis = Vector3.AXIS_Y
	spec.support = _bench_top_box()
	spec.support_name = "BenchTop"
	return spec


# --- the lobby ---------------------------------------------------------------


## Everything multiplayer, as objects on the same bench: the join console, the host
## plate, four roster sockets, three laser dots and the bar that locks the board.
## `res://ui/lobby/lobby_bench.gd` drives all of it and is the only thing on this
## screen that talks to `NetGame`.
func _build_lobby() -> Node3D:
	var lobby := Node3D.new()
	lobby.name = "Lobby"
	lobby.set_script(load(LOBBY_SCRIPT))
	lobby.add_child(_kit.build_console(load(CONSOLE_SCRIPT)))
	lobby.add_child(_build_card("Host", _host_spec()))
	lobby.add_child(_kit.build_roster())
	lobby.add_child(_kit.build_dots(load(DOTS_SCRIPT)))
	lobby.add_child(_kit.build_lock_bar())
	return lobby


## The HOST plate: a utility plate like SETTINGS and SHUT DOWN, on the same bench, at
## the same lean, solved against the same support — smaller only because that is what
## fits between the console and the settings plate.
func _host_spec() -> PlateSpec:
	var spec := _util_spec(&"host", "HOST  (H)", HOST_X, UiStyle.GOOD)
	spec.plate_size = HOST_PLATE
	spec.bracket_size = HOST_BLOCK
	spec.bracket_local = Vector3(0.0, 0.010, -0.010)
	spec.font_size = 15
	return spec


# --- io ---------------------------------------------------------------------


func _pack(root: Node, path: String) -> void:
	_own(root, root)
	var packed := PackedScene.new()
	var err: Error = packed.pack(root)
	if err != OK:
		_failures += 1
		_line("  PACK FAIL   %s (error %d)" % [path, err])
		root.free()
		return
	_save(packed, path)
	root.free()


## Instanced sub-scenes keep their own internal nodes; only the instance root is
## owned by us, which is what makes `pack` store it as an instance instead of
## flattening a copy of it into this scene.
func _own(node: Node, owner_node: Node) -> void:
	for child: Node in node.get_children():
		if child.owner == null:
			child.owner = owner_node
		if child.scene_file_path.is_empty():
			_own(child, owner_node)


func _save(res: Resource, path: String) -> void:
	var err: Error = ResourceSaver.save(res, path)
	if err != OK:
		_failures += 1
		_line("  SAVE FAIL   %s (error %d)" % [path, err])
		return
	_line("  wrote       %s" % path)


func _line(text: String) -> void:
	_report.append(text)


## Everything one plate needs to exist. A record rather than a thirteen-argument
## call, which is unreadable at the call site and impossible to extend.
class PlateSpec:
	extends RefCounted

	var id: StringName = &""
	var title: String = ""
	var origin: Vector3 = Vector3.ZERO
	var plate_size: Vector3 = Vector3.ONE
	## Where the plate sits in the body, before its lean is applied.
	var plate_local: Vector3 = Vector3.ZERO
	var bracket_size: Vector3 = Vector3.ONE
	var bracket_local: Vector3 = Vector3.ZERO
	var tilt_deg: float = 0.0
	## The solid this plate stands off, in the shed's frame, and which axis it stands
	## off along. `PanelMount` derives the remaining component of `plate_local`.
	var support: AABB = AABB()
	var support_name: String = ""
	var mount_axis: int = Vector3.AXIS_Z
	## Height of the title on the plate's face. The tag hangs below it.
	var label_y: float = 0.0
	var font_size: int = 32
	var frame_material: Material = null
	var plate_material: Material = null
	var font: Font = null
	var label_color: Color = Color.WHITE
