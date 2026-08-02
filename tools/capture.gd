extends Node
## Renders each demo to a PNG so a human (or a vision model) can actually look at
## it. Runs as a normal scene, NOT via --script, so the autoloads resolve.
##   "<godot>" --path <proj> --resolution 1600x900 res://tools/capture.tscn
##
## TIMING. `Engine.get_frames_per_second()` averages over the last second, so
## sampling it a hundred frames after a scene was instanced returns the load
## hitch — mesh upload, shader compilation, nav bake — averaged with the steady
## state, and reads far below what the scene actually runs at. Each target
## therefore gets a warm-up it is allowed to stall in, and only then a measured
## window whose frame times are accumulated here rather than read off the engine.
##
## The previous scene is freed a frame BEFORE the next is instanced. `queue_free`
## is deferred to the end of the frame, so instancing in the same call left two
## copies of every autoload-adjacent singleton (the VFX hub in particular) in the
## tree at once, and the second one refused to take ownership.

const OUT_DIR := "res://_shots"
## The resolution every fps number this project has ever published was measured at.
## Forced here rather than trusted to `--resolution`; see `_uncap`.
const SHOT_SIZE := Vector2i(1600, 900)
## Frames a scene is allowed to stall in before anything is measured.
const WARM_FRAMES := 150
## Frames the measured window spans. At 100 fps this is 0.9 s of steady state.
const MEASURE_FRAMES := 90

const TARGETS: Array[Array] = [
	["main_menu", "res://ui/main_menu.tscn"],
	["visuals", "res://demos/visuals/visuals.tscn"],
	["range", "res://demos/range/range.tscn"],
	["gunbench", "res://demos/gunbench/gunbench.tscn"],
	["bestiary", "res://demos/bestiary/bestiary.tscn"],
	["arena", "res://demos/arena/arena.tscn"],
	["firefight", "res://demos/firefight/firefight.tscn"],
	["ash_flats", "res://demos/ash_flats/ash_flats.tscn"],
	["movement", "res://demos/movement/movement.tscn"],
]

var _index := 0
var _frame := 0
var _current: Node = null
var _log: PackedStringArray = []
var _accum := 0.0
var _worst := 0.0
var _pending := false


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	_uncap()
	_advance()


## Take the frame limiter off before anything is measured.
##
## THIS TOOL SILENTLY STOPPED MEASURING RENDERING COST. It runs as a scene, so the
## autoloads resolve — which is the whole reason it is a scene — and `GameSettings`
## defaults `vsync` to true and now genuinely applies it. So every number this
## harness reported was the display's refresh rate, not the renderer's throughput:
## the run that found this read 170 / 169 / 170 fps on three unrelated scenes of
## wildly different cost, which is a monitor, not a measurement. `verify_range` and
## `verify_movement` have always disabled vsync for exactly this reason; this tool
## was written before the settings pass made the vsync default bite and never
## learned.
##
## `Engine.max_fps` is cleared as well, because a settings profile is free to cap
## frames without touching vsync and the same artefact would come back wearing a
## different hat.
## AND `--resolution` STOPPED BEING OBEYED, which is the bigger of the two. The
## settings pass fixed "fullscreen does nothing", so `GameSettings._apply_window`
## now genuinely pushes the stored window mode — and it runs from an autoload
## `_ready`, i.e. after the command line has been consumed. Every shot from the run
## that found this came out 2560x1440 against a `--resolution 1600x900` that was
## silently discarded: 2.56x the pixels of the 1600x900 that EVERY fps number in
## this project's history was measured at, which is most of why the table looked
## like a cliff. Windowed mode is therefore asserted before the size, because
## sizing an exclusive-fullscreen window does nothing at all.
func _uncap() -> void:
	Engine.max_fps = 0
	if DisplayServer.get_name() == "headless":
		return
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	if DisplayServer.window_get_mode() != DisplayServer.WINDOW_MODE_WINDOWED:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	DisplayServer.window_set_size(SHOT_SIZE)
	var vp: Viewport = get_viewport()
	if vp != null:
		vp.set_content_scale_size(SHOT_SIZE)


func _advance() -> void:
	if _current != null:
		_current.queue_free()
		_current = null
		# One idle frame with nothing in the tree, so the outgoing scene's
		# `_exit_tree` has run before the incoming scene's `_enter_tree`.
		_pending = true
		return
	_pending = false
	if _index >= TARGETS.size():
		_finish()
		return
	var scene_id: String = TARGETS[_index][0]
	var path: String = TARGETS[_index][1]
	_frame = 0
	_accum = 0.0
	_worst = 0.0
	if not ResourceLoader.exists(path):
		_log.append("%-12s MISSING  %s" % [scene_id, path])
		_index += 1
		_advance()
		return
	var packed := load(path) as PackedScene
	if packed == null:
		_log.append("%-12s LOAD FAILED  %s" % [scene_id, path])
		_index += 1
		_advance()
		return
	_current = packed.instantiate()
	add_child(_current)
	# Again per scene, not just once in `_ready`: a demo is free to push a quality
	# preset as it comes up, and `apply_preset` goes through `_apply_display`, which
	# re-asserts vsync. One scene doing that would silently re-cap every measurement
	# after it and the table would read as a cliff rather than a setting.
	_uncap()
	_install_links(scene_id)


## Hand the level its off-mesh links.
##
## `AIPathService` discovers its own link set from `SceneTree.current_scene`'s file
## name, and here the demo is a CHILD of this tool rather than the current scene,
## so that lookup asks for `capture_links.res` and comes back empty. The scene then
## renders and is MEASURED without a traversal layer it has when you actually run
## it — 900 links and their nodes are absent from `firefight`, 268 from `arena` —
## so both the frame and the frame time are of something that does not ship.
func _install_links(scene_id: String) -> void:
	var svc: Node = _find_path_service(_current)
	if svc == null or int(svc.call(&"link_count")) > 0:
		return
	var path: String = "res://data/ai/links/%s_links.res" % scene_id
	if ResourceLoader.exists(path):
		svc.call(&"install_link_set", load(path))


func _find_path_service(root: Node) -> Node:
	var queue: Array[Node] = [root]
	while not queue.is_empty():
		var n: Node = queue.pop_front()
		if n.has_method(&"install_link_set"):
			return n
		for c: Node in n.get_children():
			queue.push_back(c)
	return null


func _process(delta: float) -> void:
	if _pending:
		_advance()
		return
	if _current == null:
		return
	_frame += 1
	if _frame <= WARM_FRAMES:
		return
	if _frame <= WARM_FRAMES + MEASURE_FRAMES:
		_accum += delta
		_worst = maxf(_worst, delta)
		return
	_shoot()


func _shoot() -> void:
	var scene_id: String = TARGETS[_index][0]
	var img := get_viewport().get_texture().get_image()
	var out := "%s/%s.png" % [OUT_DIR, scene_id]
	var err := img.save_png(out)
	var fps := float(MEASURE_FRAMES) / maxf(_accum, 0.000001)
	var low := 1.0 / maxf(_worst, 0.000001)
	var draws := RenderingServer.get_rendering_info(
		RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME
	)
	var prims := RenderingServer.get_rendering_info(
		RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME
	)
	_log.append(
		(
			"%-12s shot=%s  fps=%.0f  worst=%.0f  draw_calls=%d  prims=%d"
			% [scene_id, "ok" if err == OK else "ERR%d" % err, fps, low, draws, prims]
		)
	)
	_index += 1
	_advance()


func _finish() -> void:
	print("\n===== CAPTURE REPORT =====")
	for line in _log:
		print(line)
	print("=====  END  =====")
	get_tree().quit()
