extends Node
## Autoload `DebugHUD`. The project's persistent UI host.
##
## It carries two things that must exist in every scene and cannot be left to each
## demo to remember: the **F3 developer overlay** and the **pause menu**. The
## contract allows exactly one UI autoload, so this is it; the alternative is three
## demo authors each instancing the pause menu slightly differently and Escape
## behaving differently in each of them.
##
## Keys — F3 overlay, F4 cycles the viewport's render debug mode, ctrl+1..9 toggle
## a debug-draw channel, F12 saves a screenshot. Ctrl is required on the number keys
## because bare 1/2/3 are weapon selects; Godot's exact action matching means a
## ctrl-modified press never reaches them.
##
## Systems publish their own 3D debug draws rather than this file reaching into
## them:
## [codeblock]
## func _ready() -> void:
##     DebugHUD.add_channel(DebugHUD.CHANNEL_AI_PATHS, "AI paths", _draw_paths)
##
## func _draw_paths(d: UiDebugDraw) -> void:
##     d.polyline(_path, Color(0.25, 0.66, 0.78))
## [/codeblock]
## A channel is removed automatically when the object that registered it dies, so
## a demo swap cannot leave a dangling callable behind.

## Emitted when a debug-draw channel is switched on or off, by key, click or code.
signal channel_toggled(id: StringName, enabled: bool)

## Well-known channel ids. Systems may register any id they like, but these four
## are the ones the AI owner is expected to publish, so a demo can switch them on
## by name without knowing which script drew them.
const CHANNEL_AI_PATHS: StringName = &"ai_paths"
const CHANNEL_SIGHT_CONES: StringName = &"sight_cones"
const CHANNEL_COVER_POINTS: StringName = &"cover_points"
const CHANNEL_ALERT_STATE: StringName = &"alert_state"
## Built in here, because collision shapes and navigation agents belong to no
## single system — they are engine state, readable without any system's help.
const CHANNEL_COLLISION: StringName = &"collision shapes"
const CHANNEL_NAV: StringName = &"nav agents"

const PAUSE_MENU_SCENE: String = "res://ui/pause_menu.tscn"
const SCREENSHOT_DIR: String = "user://screenshots"
const OVERLAY_LAYER: int = 120
## Frames of history in the graph. Three seconds at 60 fps, 1.5 at 120.
const GRAPH_SAMPLES: int = 180
## Row rebuilds per second. The numbers are unreadable faster than this and the
## string formatting is the only per-frame cost the overlay would otherwise have.
const SAMPLE_HZ: float = 8.0
## How often the built-in channels re-walk the scene for new nodes.
const SCENE_WALK_REFRESH: float = 0.75
## Hard cap on nodes cached per walk. A town's collision soup is unbounded; the
## overlay is a diagnostic, not a renderer.
const WALK_LIMIT: int = 1200
## Shapes further than this from the camera are skipped.
const COLLISION_RADIUS: float = 60.0
## Height above the path a nav polyline is lifted, so it is not z-fighting with
## the floor it was solved across.
const NAV_LIFT: float = 0.06

const RENDER_MODES: Array[int] = [
	Viewport.DEBUG_DRAW_DISABLED,
	Viewport.DEBUG_DRAW_WIREFRAME,
	Viewport.DEBUG_DRAW_OVERDRAW,
	Viewport.DEBUG_DRAW_UNSHADED,
	Viewport.DEBUG_DRAW_LIGHTING,
	Viewport.DEBUG_DRAW_NORMAL_BUFFER,
	Viewport.DEBUG_DRAW_SSAO,
	Viewport.DEBUG_DRAW_OCCLUDERS,
]
const RENDER_MODE_NAMES: PackedStringArray = [
	"normal",
	"wireframe",
	"overdraw",
	"unshaded",
	"lighting",
	"normals",
	"ssao",
	"occluders",
]

var _layer: CanvasLayer = null
var _overlay: DebugOverlay = null
var _drawer: UiDebugDraw = null
var _pause_menu: PauseMenu = null
var _channel_ids: Array[StringName] = []
var _channels: Dictionary = {}
var _notes: Dictionary = {}
var _note_keys: Array[StringName] = []
var _samples: PackedFloat32Array = PackedFloat32Array()
var _head: int = 0
var _filled: int = 0
var _since_sample: float = 0.0
var _render_mode: int = 0
var _target_fps: int = 120
var _max_draw_calls: int = 800
var _collision_shapes: Array[CollisionShape3D] = []
var _nav_agents: Array[NavigationAgent3D] = []
var _walk_age: float = 1.0
var _player: Node3D = null


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_target_fps = int(ProjectSettings.get_setting("demos/budget/target_fps", 120))
	_max_draw_calls = int(ProjectSettings.get_setting("demos/budget/max_draw_calls", 800))
	_samples.resize(GRAPH_SAMPLES)
	_samples.fill(0.0)
	# Wireframe rendering needs the wireframe index buffers generated up front;
	# switching the mode on without this shows a solid scene and looks like a bug.
	RenderingServer.set_debug_generate_wireframes(true)
	_build_overlay()
	_build_drawer()
	_build_pause_menu()
	add_channel(CHANNEL_COLLISION, "collision shapes", _draw_collision)
	add_channel(CHANNEL_NAV, "nav agents", _draw_nav)
	if SceneRouter.demo_changed.connect(_on_demo_changed) != OK:
		push_error("DebugHUD: could not connect to SceneRouter.demo_changed.")


func _input(event: InputEvent) -> void:
	if event.is_action_pressed(&"debug_toggle"):
		get_viewport().set_input_as_handled()
		toggle_overlay()
		return
	if event.is_action_pressed(&"screenshot"):
		get_viewport().set_input_as_handled()
		take_screenshot()
		return
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo:
		return
	if key.keycode == KEY_F4:
		get_viewport().set_input_as_handled()
		set_render_debug((_render_mode + 1) % RENDER_MODES.size())
		return
	if not key.ctrl_pressed:
		return
	var index: int = key.keycode - KEY_1
	if index < 0 or index >= _channel_ids.size():
		return
	get_viewport().set_input_as_handled()
	var id: StringName = _channel_ids[index]
	set_channel_enabled(id, not is_channel_enabled(id))


func _process(delta: float) -> void:
	_samples[_head] = delta * 1000.0
	_head = (_head + 1) % GRAPH_SAMPLES
	_filled = mini(_filled + 1, GRAPH_SAMPLES)
	_walk_age += delta
	_draw_channels()
	if not _overlay.visible:
		return
	_since_sample += delta
	if _since_sample < 1.0 / SAMPLE_HZ:
		return
	_since_sample = 0.0
	_refresh()


## Register a 3D debug draw. `drawer` is called with the shared `UiDebugDraw` every
## frame the channel is on; it dies with the object that owns it.
func add_channel(id: StringName, label: String, drawer: Callable) -> void:
	if _channels.has(id):
		_channels[id]["drawer"] = drawer
		_channels[id]["label"] = label
		return
	_channel_ids.append(id)
	_channels[id] = {"label": label, "drawer": drawer, "enabled": false}


func remove_channel(id: StringName) -> void:
	_channel_ids.erase(id)
	_channels.erase(id)


func is_channel_enabled(id: StringName) -> bool:
	if not _channels.has(id):
		return false
	return bool(_channels[id]["enabled"])


func set_channel_enabled(id: StringName, enabled: bool) -> void:
	if not _channels.has(id):
		push_error("DebugHUD: no debug channel '%s'." % id)
		return
	if bool(_channels[id]["enabled"]) == enabled:
		return
	_channels[id]["enabled"] = enabled
	channel_toggled.emit(id, enabled)


## The shared line drawer. Only valid to call from inside a channel callback.
func drawer() -> UiDebugDraw:
	return _drawer


## Pin an extra row on the overlay. A demo uses this to publish its own state
## without inventing a second HUD.
func note(key: StringName, text: String) -> void:
	if not _notes.has(key):
		_note_keys.append(key)
	_notes[key] = text


func clear_note(key: StringName) -> void:
	_notes.erase(key)
	_note_keys.erase(key)


func toggle_overlay() -> void:
	set_overlay_visible(not _overlay.visible)


func set_overlay_visible(visible_now: bool) -> void:
	_overlay.visible = visible_now
	if visible_now:
		_refresh()


func is_overlay_visible() -> bool:
	return _overlay.visible


## Index into RENDER_MODES, not the raw Viewport constant.
func set_render_debug(index: int) -> void:
	_render_mode = clampi(index, 0, RENDER_MODES.size() - 1)
	get_viewport().debug_draw = RENDER_MODES[_render_mode]


func render_debug_mode() -> int:
	return _render_mode


## The pause menu instance, or null when the UI bake has not been run.
func pause_menu() -> PauseMenu:
	return _pause_menu


## Write the current frame to `user://screenshots`. Returns the path, or an empty
## string if the image could not be saved.
func take_screenshot() -> String:
	await RenderingServer.frame_post_draw
	var image: Image = get_viewport().get_texture().get_image()
	if image == null:
		push_error("DebugHUD: the viewport returned no image.")
		return ""
	DirAccess.make_dir_recursive_absolute(SCREENSHOT_DIR)
	var stamp: String = Time.get_datetime_string_from_system(false, false)
	stamp = stamp.replace(":", "").replace("-", "").replace("T", "_")
	var path: String = "%s/shot_%s.png" % [SCREENSHOT_DIR, stamp]
	var err: Error = image.save_png(path)
	if err != OK:
		push_error("DebugHUD: could not write %s (error %d)." % [path, err])
		return ""
	print("screenshot: ", ProjectSettings.globalize_path(path))
	return path


func _build_overlay() -> void:
	_layer = CanvasLayer.new()
	_layer.name = "DebugLayer"
	_layer.layer = OVERLAY_LAYER
	add_child(_layer)
	_overlay = DebugOverlay.new()
	_overlay.name = "Overlay"
	_overlay.visible = false
	if _overlay.toggle_clicked.connect(_on_toggle_clicked) != OK:
		push_error("DebugHUD: could not connect the overlay's toggle signal.")
	_layer.add_child(_overlay)


func _build_drawer() -> void:
	_drawer = UiDebugDraw.new()
	_drawer.name = "DebugLines"
	add_child(_drawer)


func _build_pause_menu() -> void:
	if not ResourceLoader.exists(PAUSE_MENU_SCENE):
		push_error(
			(
				"DebugHUD: %s is missing, so Escape will pause with no menu. " % PAUSE_MENU_SCENE
				+ "Run res://tools/build_ui_scenes.gd."
			)
		)
		return
	var packed: PackedScene = ResourceLoader.load(PAUSE_MENU_SCENE, "PackedScene") as PackedScene
	_pause_menu = packed.instantiate() as PauseMenu
	add_child(_pause_menu)


func _on_demo_changed(_demo_id: String) -> void:
	_player = null
	_collision_shapes.clear()
	_nav_agents.clear()
	_walk_age = SCENE_WALK_REFRESH


func _on_toggle_clicked(index: int) -> void:
	if index < 0 or index >= _channel_ids.size():
		return
	var id: StringName = _channel_ids[index]
	set_channel_enabled(id, not is_channel_enabled(id))


func _draw_channels() -> void:
	var any: bool = false
	for id: StringName in _channel_ids:
		if bool(_channels[id]["enabled"]):
			any = true
			break
	if not any:
		if _drawer.visible:
			_drawer.begin()
			_drawer.flush()
		return
	_drawer.begin()
	for id: StringName in _channel_ids:
		var channel: Dictionary = _channels[id]
		if not bool(channel["enabled"]):
			continue
		var drawer_call: Callable = channel["drawer"]
		if drawer_call.is_valid():
			drawer_call.call(_drawer)
	_drawer.flush()


func _draw_collision(target: UiDebugDraw) -> void:
	_walk_scene()
	var camera: Camera3D = get_viewport().get_camera_3d()
	var eye: Vector3 = camera.global_position if camera != null else Vector3.ZERO
	var radius_sq: float = COLLISION_RADIUS * COLLISION_RADIUS
	for shape: CollisionShape3D in _collision_shapes:
		if not is_instance_valid(shape) or shape.disabled:
			continue
		if camera != null and shape.global_position.distance_squared_to(eye) > radius_sq:
			continue
		target.collision_shape(shape, UiStyle.COOL)


## Solved navigation paths, straight off the agents. This needs no cooperation
## from whatever is steering them, which is the point: when an enemy walks into a
## wall you want to know whether the path was wrong or the follower was.
func _draw_nav(target: UiDebugDraw) -> void:
	_walk_scene()
	for agent: NavigationAgent3D in _nav_agents:
		if not is_instance_valid(agent):
			continue
		var path: PackedVector3Array = agent.get_current_navigation_path()
		var lift := Vector3(0.0, NAV_LIFT, 0.0)
		for i: int in range(1, path.size()):
			target.line(path[i - 1] + lift, path[i] + lift, UiStyle.GOOD)
		var here: Vector3 = agent.global_position
		target.ring(here + lift, Vector3.RIGHT, Vector3.BACK, agent.radius, UiStyle.ACCENT)
		if agent.target_position.is_finite():
			target.cross_mark(agent.target_position + lift, 0.35, UiStyle.GOLD)


## One walk feeds every built-in channel. Two channels on at once must not walk
## the tree twice in the same frame, so the age check lives here.
func _walk_scene() -> void:
	if _walk_age < SCENE_WALK_REFRESH:
		return
	_walk_age = 0.0
	_collision_shapes.clear()
	_nav_agents.clear()
	var scene: Node = get_tree().current_scene
	if scene == null:
		return
	var found: int = 0
	var stack: Array[Node] = [scene]
	while not stack.is_empty() and found < WALK_LIMIT:
		var node: Node = stack.pop_back()
		var shape := node as CollisionShape3D
		if shape != null:
			_collision_shapes.append(shape)
			found += 1
		else:
			var agent := node as NavigationAgent3D
			if agent != null:
				_nav_agents.append(agent)
				found += 1
		for child: Node in node.get_children():
			stack.push_back(child)


func _refresh() -> void:
	var visible_cursor: bool = Input.mouse_mode == Input.MOUSE_MODE_VISIBLE
	_overlay.mouse_filter = (
		Control.MOUSE_FILTER_STOP if visible_cursor else Control.MOUSE_FILTER_IGNORE
	)
	var demo: String = SceneRouter.current_demo
	var title: String = demo.to_upper() if not demo.is_empty() else "MAIN MENU"
	_overlay.set_header("%s   f3" % title, "%s   f4" % RENDER_MODE_NAMES[_render_mode])
	_overlay.set_graph(_samples, _head)
	_build_rows()
	_build_toggles()
	_overlay.queue_redraw()


func _build_toggles() -> void:
	var labels := PackedStringArray()
	var states := PackedByteArray()
	for id: StringName in _channel_ids:
		labels.append(String(_channels[id]["label"]))
		states.append(1 if bool(_channels[id]["enabled"]) else 0)
	_overlay.set_toggles(labels, states)


func _build_rows() -> void:
	var labels := PackedStringArray()
	var values := PackedStringArray()
	var colors := PackedColorArray()
	_frame_rows(labels, values, colors)
	_render_rows(labels, values, colors)
	_scene_rows(labels, values, colors)
	for key: StringName in _note_keys:
		labels.append(String(key))
		values.append(String(_notes[key]))
		colors.append(UiStyle.TEXT)
	if not PartLibrary.is_loaded():
		labels.append("part library")
		values.append("FAILED")
		colors.append(UiStyle.WARN)
	elif not PartLibrary.unrepaired.is_empty():
		labels.append("unrepaired parts")
		values.append(str(PartLibrary.unrepaired.size()))
		colors.append(UiStyle.WARN)
	_overlay.set_rows(labels, values, colors)


func _frame_rows(
	labels: PackedStringArray, values: PackedStringArray, colors: PackedColorArray
) -> void:
	var fps: int = Engine.get_frames_per_second()
	var total: float = 0.0
	var peak: float = 0.0
	var sorted := PackedFloat32Array()
	sorted.resize(_filled)
	for i: int in _filled:
		var ms: float = _samples[(_head + GRAPH_SAMPLES - 1 - i) % GRAPH_SAMPLES]
		sorted[i] = ms
		total += ms
		peak = maxf(peak, ms)
	sorted.sort()
	var mean: float = total / maxf(1.0, float(_filled))
	# The 1 % low is the mean of the worst 1 % of frames, not the single worst —
	# one hitch is noise, a hundredth of them consistently slow is a problem.
	var worst_count: int = maxi(1, _filled / 100)
	var worst_total: float = 0.0
	for i: int in worst_count:
		worst_total += sorted[_filled - 1 - i]
	var low_ms: float = worst_total / float(worst_count)

	labels.append("FRAME")
	values.append("")
	colors.append(UiStyle.ACCENT)
	labels.append("fps")
	values.append(str(fps))
	colors.append(UiStyle.meter_color(float(fps) / float(_target_fps)))
	labels.append("frame")
	values.append(
		"%.2f ms   mean %.2f" % [_samples[(_head + GRAPH_SAMPLES - 1) % GRAPH_SAMPLES], mean]
	)
	colors.append(UiStyle.TEXT)
	labels.append("1% low")
	values.append("%.2f ms   (%d fps)" % [low_ms, int(1000.0 / maxf(low_ms, 0.001))])
	colors.append(UiStyle.TEXT)
	labels.append("peak")
	values.append("%.2f ms" % peak)
	colors.append(UiStyle.TEXT_DIM)
	labels.append("process / physics")
	(
		values
		. append(
			(
				"%.2f / %.2f ms"
				% [
					Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
					Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0,
				]
			)
		)
	)
	colors.append(UiStyle.TEXT)


func _render_rows(
	labels: PackedStringArray, values: PackedStringArray, colors: PackedColorArray
) -> void:
	var calls: int = int(
		RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)
	)
	var prims: int = int(
		RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME)
	)
	var objs: int = int(
		RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_OBJECTS_IN_FRAME)
	)
	var vp: Viewport = get_viewport()
	labels.append("RENDER")
	values.append("")
	colors.append(UiStyle.ACCENT)
	labels.append("draw calls")
	values.append("%d / %d" % [calls, _max_draw_calls])
	colors.append(UiStyle.meter_color(1.0 - float(calls) / float(maxi(_max_draw_calls, 1))))
	labels.append("primitives")
	values.append(_thousands(prims))
	colors.append(UiStyle.TEXT)
	labels.append("objects drawn")
	values.append(_thousands(objs))
	colors.append(UiStyle.TEXT)
	labels.append("video memory")
	values.append(_bytes(int(Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED))))
	colors.append(UiStyle.TEXT)
	labels.append("render scale")
	(
		values
		. append(
			(
				"%.0f%%   %dx%d"
				% [
					GameSettings.effective_render_scale() * 100.0,
					int(vp.get_visible_rect().size.x),
					int(vp.get_visible_rect().size.y),
				]
			)
		)
	)
	colors.append(UiStyle.TEXT)
	labels.append("preset")
	values.append(GameSettings.quality_preset)
	colors.append(UiStyle.TEXT_DIM)


func _scene_rows(
	labels: PackedStringArray, values: PackedStringArray, colors: PackedColorArray
) -> void:
	labels.append("SCENE")
	values.append("")
	colors.append(UiStyle.ACCENT)
	labels.append("nodes / objects")
	(
		values
		. append(
			(
				"%d / %d"
				% [
					int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
					int(Performance.get_monitor(Performance.OBJECT_COUNT)),
				]
			)
		)
	)
	colors.append(UiStyle.TEXT)
	var orphans: int = int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT))
	labels.append("orphans / resources")
	values.append(
		"%d / %d" % [orphans, int(Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT))]
	)
	colors.append(UiStyle.WARN if orphans > 0 else UiStyle.TEXT)
	labels.append("static memory")
	values.append(_bytes(int(Performance.get_monitor(Performance.MEMORY_STATIC))))
	colors.append(UiStyle.TEXT)
	var camera: Camera3D = get_viewport().get_camera_3d()
	labels.append("camera")
	values.append(_vec(camera.global_position) if camera != null else "none")
	colors.append(UiStyle.TEXT)
	if _player == null or not is_instance_valid(_player):
		_player = get_tree().get_first_node_in_group(&"player") as Node3D
	if _player != null:
		labels.append("player")
		values.append(_vec(_player.global_position))
		colors.append(UiStyle.TEXT)


static func _vec(v: Vector3) -> String:
	return "%.1f  %.1f  %.1f" % [v.x, v.y, v.z]


static func _bytes(n: int) -> String:
	if n >= 1073741824:
		return "%.2f GB" % (float(n) / 1073741824.0)
	if n >= 1048576:
		return "%.1f MB" % (float(n) / 1048576.0)
	return "%.1f KB" % (float(n) / 1024.0)


static func _thousands(n: int) -> String:
	var text: String = str(n)
	var out: String = ""
	var count: int = 0
	for i: int in range(text.length() - 1, -1, -1):
		out = text[i] + out
		count += 1
		if count % 3 == 0 and i > 0:
			out = " " + out
	return out
