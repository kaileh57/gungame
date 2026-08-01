extends Node
## Autoload `GameSettings`. Quality, display and control settings for every demo.
##
## Settings are one flat key/value store persisted to `user://settings.cfg`. A
## quality preset is nothing more than a batch write of the render keys; touching
## any of them afterwards moves the preset to "Custom". Changing a value applies
## it immediately — this class never merely records a number and hopes something
## else notices.
##
## Four things are applied per key:
##   * the WINDOW itself — mode, size and HUD scale, through DisplayServer
##   * global renderer state, through RenderingServer
##   * per-viewport state, through the root viewport and any registered SubViewport
##     (the gun viewmodel renders in one, and must track the same quality)
##   * per-environment state, through every registered Environment
##
## A demo's WorldEnvironment registers itself; anything that owns a SubViewport
## should register that too. Both are released automatically when they are freed.
##
## THE WINDOW, AND WHY THE GAME SURVIVES ANY SHAPE OF IT. `project.godot` sets
## `canvas_items` stretch with the `expand` aspect against a 1920x1080 base, and
## every camera keeps Godot's default `KEEP_HEIGHT`. Those two together are the
## whole scaling story:
##   * 3D always renders at the window's real pixel count, times `render_scale`.
##   * `KEEP_HEIGHT` fixes the VERTICAL fov, so a wider window shows MORE world at
##     the sides rather than a squashed picture — Hor+, what an ultrawide wants.
##   * `expand` scales the 2D canvas by `min(w/1920, h/1080)` and hands the slack
##     back as extra canvas, so the HUD never distorts, never gets letterboxed,
##     and an anchored corner element stays in its corner at any aspect.
## `ui_scale` multiplies that canvas scale for players who want a bigger or
## smaller HUD than the window's own arithmetic gives them. Nothing in this file
## needs the window to be any particular shape and nothing may start needing it.

## Emitted after a value has been stored AND applied. `key` is one of the keys in
## DEFAULTS; `value` is the new value.
signal settings_changed(key: StringName, value: Variant)
## Emitted when a whole preset has been applied, after every key has settled.
signal preset_applied(preset_name: String)

const CONFIG_PATH: String = "user://settings.cfg"
const CONFIG_SECTION: String = "settings"
const CUSTOM_PRESET: String = "Custom"
const PRESET_NAMES: PackedStringArray = ["Potato", "Low", "Medium", "High", "Ultra"]

## Keys a preset owns. Writing any of these by hand demotes the preset to Custom.
const QUALITY_KEYS: Array[StringName] = [
	&"render_scale",
	&"msaa",
	&"ssao",
	&"ssil",
	&"ao_quality",
	&"glow",
	&"shadow_atlas_size",
	&"directional_shadow_size",
	&"shadow_quality",
	&"fog",
	&"volumetric_fog",
	&"max_enemies",
	&"lod_bias",
	&"vsync",
]

## `render_scale` is the resolution ceiling. `lod_bias` is the mesh-LOD switch
## threshold in pixels — larger means LODs drop sooner. `max_enemies` is the hard
## population cap AI honours. `shadow_quality` indexes the soft-shadow filter
## ladder, 0 hard through 5 ultra.
const PRESETS: Dictionary = {
	"Potato":
	{
		&"render_scale": 0.55,
		&"msaa": 0,
		&"ssao": false,
		&"ssil": false,
		&"ao_quality": 0,
		&"glow": false,
		&"shadow_atlas_size": 1024,
		&"directional_shadow_size": 1024,
		&"shadow_quality": 0,
		&"fog": false,
		&"volumetric_fog": false,
		&"max_enemies": 10,
		&"lod_bias": 8.0,
		&"vsync": true,
	},
	"Low":
	{
		&"render_scale": 0.70,
		&"msaa": 0,
		&"ssao": false,
		&"ssil": false,
		&"ao_quality": 0,
		&"glow": false,
		&"shadow_atlas_size": 2048,
		&"directional_shadow_size": 2048,
		&"shadow_quality": 1,
		&"fog": true,
		&"volumetric_fog": false,
		&"max_enemies": 18,
		&"lod_bias": 4.0,
		&"vsync": true,
	},
	"Medium":
	{
		&"render_scale": 0.85,
		&"msaa": 1,
		&"ssao": true,
		&"ssil": false,
		&"ao_quality": 1,
		&"glow": true,
		&"shadow_atlas_size": 2048,
		&"directional_shadow_size": 3072,
		&"shadow_quality": 2,
		&"fog": true,
		&"volumetric_fog": false,
		&"max_enemies": 28,
		&"lod_bias": 2.0,
		&"vsync": true,
	},
	"High":
	{
		&"render_scale": 1.0,
		&"msaa": 1,
		&"ssao": true,
		&"ssil": false,
		&"ao_quality": 2,
		&"glow": true,
		&"shadow_atlas_size": 4096,
		&"directional_shadow_size": 4096,
		&"shadow_quality": 3,
		&"fog": true,
		&"volumetric_fog": true,
		&"max_enemies": 44,
		&"lod_bias": 1.0,
		&"vsync": true,
	},
	"Ultra":
	{
		&"render_scale": 1.0,
		&"msaa": 2,
		&"ssao": true,
		&"ssil": true,
		&"ao_quality": 4,
		&"glow": true,
		&"shadow_atlas_size": 8192,
		&"directional_shadow_size": 8192,
		&"shadow_quality": 4,
		&"fog": true,
		&"volumetric_fog": true,
		&"max_enemies": 64,
		&"lod_bias": 0.5,
		&"vsync": true,
	},
}

# --- the window -------------------------------------------------------------
#
# Three modes, cycled in this order by `cycle_window_mode()`. BORDERLESS is
# Godot's non-exclusive fullscreen: a frameless window covering the screen, which
# alt-tabs instantly and lets an overlay draw over it. FULLSCREEN is exclusive:
# lower input latency, and nothing else gets a pixel.

const WINDOW_WINDOWED: int = 0
const WINDOW_BORDERLESS: int = 1
const WINDOW_FULLSCREEN: int = 2
## Indexed by the three constants above. The settings page shows these words and
## checks its own copy against them at boot.
const WINDOW_MODE_NAMES: PackedStringArray = ["Windowed", "Borderless", "Fullscreen"]

## Window sizes the settings page offers, before they are filtered to the screen.
##
## Godot exposes NO video-mode enumeration — `DisplayServer` will tell you a
## screen's current size and nothing else — and it never changes a monitor's mode,
## so both fullscreen modes always run at whatever the desktop is already set to.
## That makes this list what it says it is: window sizes, offered when they fit.
## Sorted widest first by `resolution_options()`, not by the order written here.
const WINDOW_SIZES: Array[Vector2i] = [
	Vector2i(1024, 768),
	Vector2i(1280, 720),
	Vector2i(1280, 800),
	Vector2i(1366, 768),
	Vector2i(1440, 900),
	Vector2i(1600, 900),
	Vector2i(1680, 1050),
	Vector2i(1920, 1080),
	Vector2i(1920, 1200),
	Vector2i(2048, 1152),
	Vector2i(2560, 1080),
	Vector2i(2560, 1440),
	Vector2i(2560, 1600),
	Vector2i(3440, 1440),
	Vector2i(3840, 1080),
	Vector2i(3840, 1600),
	Vector2i(3840, 2160),
	Vector2i(5120, 1440),
	Vector2i(5120, 2160),
]

## The smallest window the UI stays usable in, enforced through
## `window_set_min_size`. The settings page is 820x720 canvas pixels; at 960x540
## the canvas scale is 0.5, `ui_scale` tops out at 1.4, and 820x720 still fits
## inside the 1371x771 of canvas that leaves. Go smaller and the page's own footer
## — the one carrying RESET TO DEFAULTS — goes off the bottom of the screen.
const MIN_WINDOW: Vector2i = Vector2i(960, 540)

## Bounds on `ui_scale`. The ceiling is not taste: see `MIN_WINDOW`.
const UI_SCALE_MIN: float = 0.70
const UI_SCALE_MAX: float = 1.40

## Everything the store can hold. Quality keys are overwritten by the boot preset;
## the rest are player preferences a preset never touches — including every window
## key, because no quality preset may move somebody's window.
const DEFAULTS: Dictionary = {
	&"quality_preset": "High",
	&"adaptive_resolution": true,
	## One of WINDOW_WINDOWED / WINDOW_BORDERLESS / WINDOW_FULLSCREEN.
	&"window_mode": WINDOW_WINDOWED,
	## The WINDOWED size. Both fullscreen modes take the whole screen and ignore
	## it. Replaced at boot by `_default_resolution()` with something that fits the
	## desktop actually in front of the player.
	&"resolution": Vector2i(1920, 1080),
	## Multiplier on the canvas scale the window's own size already implies. 1.0 is
	## "whatever `expand` decided", which is right for almost everybody.
	&"ui_scale": 1.0,
	## Indexes `CombatReticle.Style`: 0 dot, 1 world selector, 2 both. A preference,
	## not a quality key — no preset touches it.
	&"aim_style": 2,
	&"fov": 78.0,
	&"mouse_sensitivity": 0.0022,
	&"ads_sensitivity_scale": 0.65,
	&"invert_y": false,
	&"render_scale": 1.0,
	&"msaa": 1,
	&"ssao": true,
	&"ssil": false,
	&"ao_quality": 2,
	&"glow": true,
	&"shadow_atlas_size": 4096,
	&"directional_shadow_size": 4096,
	&"shadow_quality": 3,
	&"fog": true,
	&"volumetric_fog": true,
	&"max_enemies": 44,
	&"lod_bias": 1.0,
	&"vsync": true,
}

## Seconds between adaptive-resolution samples. The reference samples at 0.4 s and
## the hysteresis constants below are calibrated against that period.
const ADAPT_PERIOD: float = 0.4
## Seconds of quiet before a changed setting is flushed to disk, so dragging a
## slider does not write the file sixty times a second.
const SAVE_DEBOUNCE: float = 0.75

## Vertical field of view in degrees. Cameras read this; three.js and Godot agree
## on the axis as long as `keep_aspect` stays at KEEP_HEIGHT.
## Set when the window mode we asked for is not the mode we ended up in.
##
## Godot 4.x runs the game EMBEDDED INSIDE THE EDITOR by default, and an embedded
## window cannot go exclusive fullscreen — `window_set_mode` returns without
## error and the window simply stays put. That is indistinguishable from a broken
## setting unless somebody checks, so this checks, and the settings page says so
## rather than leaving the user clicking a dead control.
var window_mode_blocked: bool = false

var fov: float:
	get:
		return float(_values[&"fov"])

## Radians of yaw per pixel of mouse motion, before any ADS scaling.
var mouse_sensitivity: float:
	get:
		return float(_values[&"mouse_sensitivity"])

## Multiplier applied to `mouse_sensitivity` while aiming down sights.
var ads_sensitivity_scale: float:
	get:
		return float(_values[&"ads_sensitivity_scale"])

var invert_y: bool:
	get:
		return bool(_values[&"invert_y"])

## Hard cap on simultaneously simulated enemies. AI must honour this.
var max_enemies: int:
	get:
		return int(_values[&"max_enemies"])

## The user's resolution ceiling, before adaptive resolution scales down from it.
var render_scale: float:
	get:
		return float(_values[&"render_scale"])

var quality_preset: String:
	get:
		return String(_values[&"quality_preset"])

## One of WINDOW_WINDOWED / WINDOW_BORDERLESS / WINDOW_FULLSCREEN.
var window_mode: int:
	get:
		return clampi(int(_values[&"window_mode"]), 0, WINDOW_MODE_NAMES.size() - 1)

## The size the player ASKED the window to be. `window_size()` is what it became.
var resolution: Vector2i:
	get:
		return _values[&"resolution"]

## Player multiplier on the canvas scale. See the note at the top of the file.
var ui_scale: float:
	get:
		return clampf(float(_values[&"ui_scale"]), UI_SCALE_MIN, UI_SCALE_MAX)

var _values: Dictionary = {}
var _environments: Array[Environment] = []
var _viewports: Array[Viewport] = []
var _save_timer: Timer = null
var _adapt_timer: Timer = null
## Current adaptive multiplier on top of `render_scale`, in [_adapt_min_ratio, 1].
var _adapt_ratio: float = 1.0
var _adapt_dir: int = 0
var _adapt_min_ratio: float = 0.55
var _adapt_fps_low: int = 45
var _adapt_fps_high: int = 58
var _adapt_step_down: float = 0.15
var _adapt_step_up: float = 0.10
## The window mode and size this file last PUSHED at the OS, so it can tell its
## own writes from the player's. A window dragged to a new size by hand leaves
## `_pushed_size` matching the stored value, so the next unrelated settings write
## does not snap the frame back out from under the mouse. -1 and ZERO mean
## "nothing pushed yet", which is also how a mode change forces the geometry to be
## re-pushed: coming back from fullscreen, the windowed size no longer exists.
var _pushed_mode: int = -1
var _pushed_size: Vector2i = Vector2i.ZERO


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_values = DEFAULTS.duplicate(true)
	_read_project_defaults()
	load_settings()
	_viewports.append(get_tree().root)
	_build_timers()
	if _has_window():
		DisplayServer.window_set_min_size(MIN_WINDOW)
	apply_all()
	_verify_stretch()


## Names of the shipped presets, in ascending cost order.
func preset_names() -> PackedStringArray:
	return PRESET_NAMES


## True when the quality keys no longer match any shipped preset.
func is_custom_preset() -> bool:
	return quality_preset == CUSTOM_PRESET


# --- the window -------------------------------------------------------------


## Windowed -> borderless -> fullscreen -> windowed. What the settings page's
## picker steps through, and what Alt+Enter does from anywhere in the game.
func cycle_window_mode() -> void:
	set_value(&"window_mode", (window_mode + 1) % WINDOW_MODE_NAMES.size())


## The window sizes to offer, widest first.
##
## "Supported" means FITS ON THIS SCREEN — see `WINDOW_SIZES` for why that is the
## strongest claim available. The screen's own size and whatever is stored right
## now are always in the list, so the picker can never fail to show the size that
## is actually in force, and so a config carried over from a bigger monitor still
## has a selected row rather than silently reading as the first one.
func resolution_options() -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var limit: Vector2i = _screen_size()
	for size: Vector2i in WINDOW_SIZES:
		if limit.x <= 0 or (size.x <= limit.x and size.y <= limit.y):
			out.append(size)
	if limit.x > 0 and not out.has(limit):
		out.append(limit)
	var current: Vector2i = resolution
	if current.x > 0 and not out.has(current):
		out.append(current)
	out.sort_custom(_wider_first)
	return out


## What the window ACTUALLY is, which is not always what `resolution` says: a size
## bigger than the desktop's free area is shrunk to fit, both fullscreen modes
## take the whole screen, and the player may drag the frame to anything they like.
## Zero under `--headless`, where there is no window to measure.
func window_size() -> Vector2i:
	if not _has_window():
		return Vector2i.ZERO
	return DisplayServer.window_get_size()


## The size of the screen the window is currently on, or zero with no display.
## Multi-monitor falls out of this: drag the window to the other screen and the
## next call answers for that one.
static func _screen_size() -> Vector2i:
	if not _has_window():
		return Vector2i.ZERO
	return DisplayServer.screen_get_size(DisplayServer.window_get_current_screen())


## Write every quality key from a preset and apply the lot. Unknown names are an
## error rather than a silent no-op.
func apply_preset(preset_name: String) -> void:
	if not PRESETS.has(preset_name):
		push_error("GameSettings: no such quality preset '%s'." % preset_name)
		return
	var preset: Dictionary = PRESETS[preset_name]
	for key: StringName in preset:
		_values[key] = preset[key]
	_values[&"quality_preset"] = preset_name
	_adapt_ratio = 1.0
	_adapt_dir = 0
	apply_all()
	for key: StringName in preset:
		settings_changed.emit(key, preset[key])
	settings_changed.emit(&"quality_preset", preset_name)
	preset_applied.emit(preset_name)
	_queue_save()


## Store a value, apply it, announce it, and schedule a save. Writing a quality
## key by hand moves the preset to Custom.
func set_value(key: StringName, value: Variant) -> void:
	if not DEFAULTS.has(key):
		push_error("GameSettings: unknown key '%s'." % key)
		return
	if _values.has(key) and _values[key] == value:
		return
	_values[key] = value
	if QUALITY_KEYS.has(key) and _values[&"quality_preset"] != CUSTOM_PRESET:
		_values[&"quality_preset"] = CUSTOM_PRESET
		settings_changed.emit(&"quality_preset", CUSTOM_PRESET)
	if key == &"render_scale" or key == &"adaptive_resolution":
		_adapt_ratio = 1.0
		_adapt_dir = 0
	apply_all()
	settings_changed.emit(key, value)
	_queue_save()


func get_value(key: StringName, fallback: Variant = null) -> Variant:
	if _values.has(key):
		return _values[key]
	if fallback != null:
		return fallback
	return DEFAULTS.get(key)


func has_key(key: StringName) -> bool:
	return DEFAULTS.has(key)


## The scale actually handed to the viewport: the user's ceiling times whatever
## adaptive resolution has decided the machine can hold.
func effective_render_scale() -> float:
	return clampf(render_scale * _adapt_ratio, 0.25, 2.0)


## Re-apply every setting to the renderer, every registered viewport and every
## registered environment.
func apply_all() -> void:
	_prune()
	_apply_display()
	_apply_renderer()
	for vp: Viewport in _viewports:
		apply_to_viewport(vp)
	for env: Environment in _environments:
		apply_to_environment(env)


## Push the viewport-scoped quality keys onto one viewport. Safe to call on a
## SubViewport that renders the weapon viewmodel.
func apply_to_viewport(vp: Viewport) -> void:
	if vp == null or not is_instance_valid(vp):
		return
	vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
	vp.scaling_3d_scale = effective_render_scale()
	vp.msaa_3d = _msaa_mode(int(_values[&"msaa"]))
	vp.positional_shadow_atlas_size = int(_values[&"shadow_atlas_size"])
	vp.positional_shadow_atlas_16_bits = int(_values[&"shadow_atlas_size"]) <= 2048
	vp.mesh_lod_threshold = float(_values[&"lod_bias"])


## Push the environment-scoped quality keys onto one Environment.
func apply_to_environment(env: Environment) -> void:
	if env == null:
		return
	env.ssao_enabled = bool(_values[&"ssao"])
	env.ssil_enabled = bool(_values[&"ssil"])
	env.glow_enabled = bool(_values[&"glow"])
	env.fog_enabled = bool(_values[&"fog"])
	env.volumetric_fog_enabled = bool(_values[&"fog"]) and bool(_values[&"volumetric_fog"])


## A WorldEnvironment calls this on ready so quality changes reach its Environment.
func register_environment(env: Environment) -> void:
	if env == null or _environments.has(env):
		return
	_environments.append(env)
	apply_to_environment(env)


func unregister_environment(env: Environment) -> void:
	_environments.erase(env)


## A SubViewport calls this so it tracks the same resolution scale and MSAA as the
## main view. The root viewport is registered automatically.
func register_viewport(vp: Viewport) -> void:
	if vp == null or _viewports.has(vp):
		return
	_viewports.append(vp)
	apply_to_viewport(vp)


func unregister_viewport(vp: Viewport) -> void:
	_viewports.erase(vp)


## Restore every key to its shipped default and re-apply.
func reset_to_defaults() -> void:
	_values = DEFAULTS.duplicate(true)
	_read_project_defaults()
	apply_preset(String(_values[&"quality_preset"]))


func save_settings() -> void:
	var cfg := ConfigFile.new()
	for key: StringName in _values:
		cfg.set_value(CONFIG_SECTION, String(key), _values[key])
	var err: Error = cfg.save(CONFIG_PATH)
	if err != OK:
		push_error("GameSettings: could not write %s (error %d)." % [CONFIG_PATH, err])


## Merge the persisted file over the defaults. Unknown or mistyped keys are
## dropped rather than trusted — a hand-edited config must not brick the renderer.
func load_settings() -> void:
	if not FileAccess.file_exists(CONFIG_PATH):
		return
	var cfg := ConfigFile.new()
	if cfg.load(CONFIG_PATH) != OK:
		push_warning("GameSettings: %s is unreadable, using defaults." % CONFIG_PATH)
		return
	for key_text: String in cfg.get_section_keys(CONFIG_SECTION):
		var key := StringName(key_text)
		if not DEFAULTS.has(key):
			continue
		var value: Variant = cfg.get_value(CONFIG_SECTION, key_text)
		if typeof(value) != typeof(DEFAULTS[key]):
			continue
		_values[key] = value


func _read_project_defaults() -> void:
	_values[&"quality_preset"] = String(
		ProjectSettings.get_setting("demos/quality/default_preset", "High")
	)
	if not PRESETS.has(_values[&"quality_preset"]):
		_values[&"quality_preset"] = "High"
	for key: StringName in PRESETS[_values[&"quality_preset"]]:
		_values[key] = PRESETS[_values[&"quality_preset"]][key]
	_values[&"adaptive_resolution"] = bool(
		ProjectSettings.get_setting("demos/quality/adaptive_resolution", true)
	)
	# Not a const, because the honest default depends on the monitor. Re-derived by
	# `reset_to_defaults`, so RESET on a laptop gives a laptop-sized window rather
	# than the 1080p one written in DEFAULTS.
	_values[&"resolution"] = _default_resolution()
	_adapt_min_ratio = float(ProjectSettings.get_setting("demos/quality/adaptive_scale_min", 0.55))
	_adapt_fps_low = int(ProjectSettings.get_setting("demos/quality/adaptive_fps_floor", 45))
	_adapt_fps_high = int(ProjectSettings.get_setting("demos/quality/adaptive_fps_ceiling", 58))
	_adapt_step_down = float(ProjectSettings.get_setting("demos/quality/adaptive_step_down", 0.15))
	_adapt_step_up = float(ProjectSettings.get_setting("demos/quality/adaptive_step_up", 0.10))


func _build_timers() -> void:
	_save_timer = Timer.new()
	_save_timer.one_shot = true
	_save_timer.wait_time = SAVE_DEBOUNCE
	_save_timer.process_mode = Node.PROCESS_MODE_ALWAYS
	_save_timer.timeout.connect(save_settings)
	add_child(_save_timer)

	_adapt_timer = Timer.new()
	_adapt_timer.wait_time = ADAPT_PERIOD
	_adapt_timer.process_mode = Node.PROCESS_MODE_PAUSABLE
	_adapt_timer.timeout.connect(_adapt_resolution)
	add_child(_adapt_timer)
	_adapt_timer.start()


func _queue_save() -> void:
	if _save_timer != null:
		_save_timer.start(SAVE_DEBOUNCE)


## Asymmetric hysteresis, straight from the reference: drop after 3 bad samples
## (1.2 s), climb back only after 8 good ones (3.2 s), so it settles instead of
## oscillating around the threshold.
func _adapt_resolution() -> void:
	if not bool(_values[&"adaptive_resolution"]):
		return
	var fps: int = Engine.get_frames_per_second()
	if fps <= 0:
		return
	if fps < _adapt_fps_low and _adapt_ratio > _adapt_min_ratio:
		_adapt_dir = _adapt_dir - 1 if _adapt_dir < 0 else -1
	elif fps > _adapt_fps_high and _adapt_ratio < 1.0:
		_adapt_dir = _adapt_dir + 1 if _adapt_dir > 0 else 1
	else:
		_adapt_dir = 0
	var moved: bool = false
	if _adapt_dir <= -3:
		_adapt_ratio = maxf(_adapt_min_ratio, _adapt_ratio - _adapt_step_down)
		_adapt_dir = 0
		moved = true
	elif _adapt_dir >= 8:
		_adapt_ratio = minf(1.0, _adapt_ratio + _adapt_step_up)
		_adapt_dir = 0
		moved = true
	if not moved:
		return
	_prune()
	for vp: Viewport in _viewports:
		vp.scaling_3d_scale = effective_render_scale()


func _apply_display() -> void:
	var mode := DisplayServer.VSYNC_DISABLED
	if bool(_values[&"vsync"]):
		mode = DisplayServer.VSYNC_ENABLED
	DisplayServer.window_set_vsync_mode(mode)
	_apply_ui_scale()
	_apply_window()


## The one knob that resizes the HUD without touching the 3D. `canvas_items`
## stretch already scales the UI with the window; this multiplies that, which is
## what an ultrawide player wants — their canvas scale is decided by a height that
## is small next to the width, so the HUD reads large for the space it is in.
func _apply_ui_scale() -> void:
	if not is_inside_tree():
		return
	var root_window: Window = get_tree().root
	var want: float = ui_scale
	# Guarded, because Godot has no guard of its own: every write to this re-runs
	# the viewport's whole size calculation and re-lays out every Control under it,
	# and `apply_all()` runs on each tick of each slider drag on the settings page.
	if not is_equal_approx(root_window.content_scale_factor, want):
		root_window.content_scale_factor = want


## Push the window mode and, in windowed mode, the size.
##
## Called from `apply_all()`, so on EVERY settings write — both halves therefore
## early-out on "already there". The mode half compares against the OS-facing
## value this file last wrote rather than against `DisplayServer.window_get_mode`,
## because the two disagree the moment the player alt-tabs or the WM has an
## opinion, and re-asserting the mode on every FOV tick would fight them for it.
## Re-push every setting from scratch, including ones the incremental path would
## skip as unchanged. This is what the settings page's APPLY does: it is the
## answer to "is this actually taking effect?", and it costs nothing to press.
func force_apply() -> void:
	_pushed_mode = -1
	_pushed_size = Vector2i.ZERO
	apply_all()


func _apply_window() -> void:
	if not _has_window():
		return
	var mode: int = window_mode
	if mode != _pushed_mode:
		_pushed_mode = mode
		# A trip through either fullscreen mode destroys the windowed geometry, so
		# the size must be pushed again on the way back rather than skipped as
		# unchanged.
		_pushed_size = Vector2i.ZERO
		var want_mode: DisplayServer.WindowMode = _display_window_mode(mode)
		DisplayServer.window_set_mode(want_mode)
		if mode == WINDOW_WINDOWED:
			DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_BORDERLESS, false)
		# Did it take? An embedded editor window silently refuses fullscreen.
		var blocked: bool = DisplayServer.window_get_mode() != want_mode
		if blocked != window_mode_blocked:
			window_mode_blocked = blocked
			settings_changed.emit(&"window_mode_blocked", blocked)
		if blocked:
			push_warning(
				(
					(
						"GameSettings: asked for %s, window stayed in mode %d. "
						+ "A game embedded in the editor cannot go fullscreen — "
						+ "run it in a separate window or from an exported build."
					)
					% [WINDOW_MODE_NAMES[mode], int(DisplayServer.window_get_mode())]
				)
			)
	if mode != WINDOW_WINDOWED:
		return
	var want: Vector2i = _fit_to_desktop(resolution)
	if want == _pushed_size:
		return
	_pushed_size = want
	DisplayServer.window_set_size(want)
	DisplayServer.window_set_position(_centred_position(want))


static func _display_window_mode(mode: int) -> DisplayServer.WindowMode:
	match mode:
		WINDOW_BORDERLESS:
			return DisplayServer.WINDOW_MODE_FULLSCREEN
		WINDOW_FULLSCREEN:
			return DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN
	return DisplayServer.WINDOW_MODE_WINDOWED


## True when there is a real window to talk to. Every bake tool and every
## verification harness runs `--headless`, where the window calls are no-ops and
## the screen is zero by zero — centring a window in a zero rect is at best a
## wasted call and at worst a division by nothing.
static func _has_window() -> bool:
	return DisplayServer.get_name() != "headless" and DisplayServer.window_get_size().x > 0


## The window's own frame: title bar and borders, MEASURED rather than assumed.
## Windows puts 39 px above the client area and 16 px around it, GNOME 37, a
## borderless window none at all, and guessing wrong is a title bar off the screen.
## Zero while fullscreen, which is correct — there is no frame then.
static func _decorations() -> Vector2i:
	var deco: Vector2i = (
		DisplayServer.window_get_size_with_decorations() - DisplayServer.window_get_size()
	)
	return Vector2i(maxi(deco.x, 0), maxi(deco.y, 0))


static func _usable_rect() -> Rect2i:
	return DisplayServer.screen_get_usable_rect(DisplayServer.window_get_current_screen())


## Shrink a wanted window size until the window AND its frame fit inside the
## desktop's usable area — outside the taskbar, and with the title bar on screen.
## A window taller than the desktop puts its own title bar out of reach, which on
## Windows means it can no longer be moved or closed with the mouse.
static func _fit_to_desktop(size: Vector2i) -> Vector2i:
	if not _has_window():
		return size
	var room: Vector2i = _usable_rect().size - _decorations()
	return Vector2i(
		clampi(size.x, MIN_WINDOW.x, maxi(room.x, MIN_WINDOW.x)),
		clampi(size.y, MIN_WINDOW.y, maxi(room.y, MIN_WINDOW.y))
	)


## Centre a window of `size` in the desktop's usable area.
##
## `window_set_position` places the CLIENT area, while the frame hangs above and
## to the left of it, so the frame's own offset is added back — otherwise a
## perfectly centred window wears its title bar off the top of the screen.
static func _centred_position(size: Vector2i) -> Vector2i:
	var usable: Rect2i = _usable_rect()
	var frame: Vector2i = (
		DisplayServer.window_get_position() - DisplayServer.window_get_position_with_decorations()
	)
	var free: Vector2i = usable.size - _decorations() - size
	return usable.position + frame + Vector2i(maxi(free.x, 0) / 2, maxi(free.y, 0) / 2)


## The window size a fresh install gets: the project's design resolution, shrunk
## to whatever the desktop in front of the player can actually hold.
static func _default_resolution() -> Vector2i:
	var want := Vector2i(
		int(ProjectSettings.get_setting("display/window/size/viewport_width", 1920)),
		int(ProjectSettings.get_setting("display/window/size/viewport_height", 1080))
	)
	return _fit_to_desktop(want)


static func _wider_first(a: Vector2i, b: Vector2i) -> bool:
	if a.x != b.x:
		return a.x > b.x
	return a.y > b.y


## The three project settings the note at the top of this file rests on.
##
## Nothing here reads them at runtime — Godot applies them itself before any of
## this exists — so changing one would not break anything visible on the machine
## that changed it. It would break every OTHER aspect ratio, quietly, months
## later, on somebody else's monitor. That is worth six lines and one check at
## boot. The costs, in order: a mode other than `canvas_items` either renders the
## 3D at the 1920x1080 base and upscales it or stops scaling the HUD at all; an
## aspect other than `expand` letterboxes (`keep`), distorts (`ignore`) or shrinks
## the base along one axis until anchored HUD corners fall off the screen
## (`keep_width`, `keep_height`); and an `integer` scale mode letterboxes at every
## window size that is not a whole multiple of the base, which is nearly all of
## them.
func _verify_stretch() -> void:
	var want := {
		"display/window/stretch/mode": "canvas_items",
		"display/window/stretch/aspect": "expand",
		"display/window/stretch/scale_mode": "fractional",
	}
	var wrong := PackedStringArray()
	for path: String in want:
		var value: String = String(ProjectSettings.get_setting(path, String(want[path])))
		if value != String(want[path]):
			wrong.append("%s is '%s', not '%s'" % [path, value, String(want[path])])
	if wrong.is_empty():
		return
	push_error(
		(
			"GameSettings: the window scaling contract is broken — %s. " % ", ".join(wrong)
			+ "See the note at the top of core/game_settings.gd."
		)
	)


func _apply_renderer() -> void:
	var dir_size: int = int(_values[&"directional_shadow_size"])
	RenderingServer.directional_shadow_atlas_set_size(dir_size, dir_size <= 2048)
	var sq := _shadow_quality(int(_values[&"shadow_quality"]))
	RenderingServer.directional_soft_shadow_filter_set_quality(sq)
	RenderingServer.positional_soft_shadow_filter_set_quality(sq)

	var aoq: int = int(_values[&"ao_quality"])
	var half: bool = aoq <= 1
	RenderingServer.environment_set_ssao_quality(_ssao_quality(aoq), half, 0.5, 2, 50.0, 300.0)
	RenderingServer.environment_set_ssil_quality(_ssil_quality(aoq), half, 0.5, 4, 50.0, 300.0)

	var volumetric: bool = bool(_values[&"fog"]) and bool(_values[&"volumetric_fog"])
	RenderingServer.environment_set_volumetric_fog_filter_active(volumetric)
	if volumetric:
		RenderingServer.environment_set_volumetric_fog_volume_size(128, 96)
	else:
		RenderingServer.environment_set_volumetric_fog_volume_size(64, 48)


func _prune() -> void:
	var live_viewports: Array[Viewport] = []
	for vp: Viewport in _viewports:
		if is_instance_valid(vp):
			live_viewports.append(vp)
	_viewports = live_viewports
	var live_envs: Array[Environment] = []
	for env: Environment in _environments:
		if is_instance_valid(env):
			live_envs.append(env)
	_environments = live_envs


static func _msaa_mode(level: int) -> Viewport.MSAA:
	match level:
		1:
			return Viewport.MSAA_2X
		2:
			return Viewport.MSAA_4X
		3:
			return Viewport.MSAA_8X
	return Viewport.MSAA_DISABLED


static func _shadow_quality(level: int) -> RenderingServer.ShadowQuality:
	match level:
		0:
			return RenderingServer.SHADOW_QUALITY_HARD
		1:
			return RenderingServer.SHADOW_QUALITY_SOFT_VERY_LOW
		2:
			return RenderingServer.SHADOW_QUALITY_SOFT_LOW
		3:
			return RenderingServer.SHADOW_QUALITY_SOFT_MEDIUM
		4:
			return RenderingServer.SHADOW_QUALITY_SOFT_HIGH
	return RenderingServer.SHADOW_QUALITY_SOFT_ULTRA


static func _ssao_quality(level: int) -> RenderingServer.EnvironmentSSAOQuality:
	match level:
		0:
			return RenderingServer.ENV_SSAO_QUALITY_VERY_LOW
		1:
			return RenderingServer.ENV_SSAO_QUALITY_LOW
		2:
			return RenderingServer.ENV_SSAO_QUALITY_MEDIUM
		3:
			return RenderingServer.ENV_SSAO_QUALITY_HIGH
	return RenderingServer.ENV_SSAO_QUALITY_ULTRA


static func _ssil_quality(level: int) -> RenderingServer.EnvironmentSSILQuality:
	match level:
		0:
			return RenderingServer.ENV_SSIL_QUALITY_VERY_LOW
		1:
			return RenderingServer.ENV_SSIL_QUALITY_LOW
		2:
			return RenderingServer.ENV_SSIL_QUALITY_MEDIUM
		3:
			return RenderingServer.ENV_SSIL_QUALITY_HIGH
	return RenderingServer.ENV_SSIL_QUALITY_ULTRA
