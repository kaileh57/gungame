extends Node
## Autoload `GameSettings`. Quality, display and control settings for every demo.
##
## Settings are one flat key/value store persisted to `user://settings.cfg`. A
## quality preset is nothing more than a batch write of the render keys; touching
## any of them afterwards moves the preset to "Custom". Changing a value applies
## it immediately — this class never merely records a number and hopes something
## else notices.
##
## Three things are applied per key:
##   * global renderer state, through RenderingServer
##   * per-viewport state, through the root viewport and any registered SubViewport
##     (the gun viewmodel renders in one, and must track the same quality)
##   * per-environment state, through every registered Environment
##
## A demo's WorldEnvironment registers itself; anything that owns a SubViewport
## should register that too. Both are released automatically when they are freed.

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

## Everything the store can hold. Quality keys are overwritten by the boot preset;
## the rest are player preferences a preset never touches.
const DEFAULTS: Dictionary = {
	&"quality_preset": "High",
	&"adaptive_resolution": true,
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


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_values = DEFAULTS.duplicate(true)
	_read_project_defaults()
	load_settings()
	_viewports.append(get_tree().root)
	_build_timers()
	apply_all()


## Names of the shipped presets, in ascending cost order.
func preset_names() -> PackedStringArray:
	return PRESET_NAMES


## True when the quality keys no longer match any shipped preset.
func is_custom_preset() -> bool:
	return quality_preset == CUSTOM_PRESET


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
