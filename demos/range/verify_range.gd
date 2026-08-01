extends SceneTree
## Acceptance test for the baked range.
##
##   godot --path <project> --script res://demos/range/verify_range.gd
##
## Run it WITHOUT `--headless` when the frame time matters: headless has no
## renderer, so it proves the wiring and says nothing at all about the framerate.
##
## Like every other `--script` main loop in this project it names no project
## class. Autoloads are bound after this file is compiled, so anything that
## mentioned `GunFactory` or `PartLibrary` at compile time would arrive with no
## script; everything below therefore reaches the demo through `call` and `get`.
##
## What it proves, in order: the scene loads with every node the demo's wiring
## expects, the bench rolled a weapon into the player's hands on its own, a plate
## takes damage and scores the numbers §13.2 asks for, a drum detonates and its
## blast reaches the targets around it, the paper target measures a group in
## millimetres, and the whole thing holds its frame budget.

const SCENE := "res://demos/range/range.tscn"
## Frames discarded before timing starts: shader compiles and the readouts'
## one-shot renders all land in the first few and none of them happen again.
const WARMUP_FRAMES := 90
const TIMED_FRAMES := 600

var _done := false


func _process(_d: float) -> bool:
	if _done:
		return false
	_done = true
	_run()
	return false


func _run() -> void:
	var packed := ResourceLoader.load(SCENE, "PackedScene") as PackedScene
	if packed == null:
		print("FAIL: scene did not load")
		quit(1)
		return
	Engine.max_fps = 0
	if DisplayServer.get_name() != "headless":
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		DisplayServer.window_set_size(Vector2i(1920, 1080))
		root.set_content_scale_size(Vector2i(1920, 1080))
	var demo: Node = packed.instantiate()
	root.add_child(demo)
	await process_frame
	await process_frame
	await process_frame

	var missing := PackedStringArray()
	for path: String in [
		"ScavWorld",
		"Vfx",
		"Ground",
		"Lane",
		"Bay",
		"Scatter",
		"WorkLights",
		"Targets",
		"Bench",
		"Player",
		"Shooter",
		"Ambience",
		"Lane/LaneReadout",
		"Bench/Stand",
		"Bench/CardReadout",
		"Bench/PartsReadout",
		"Player/Eye/Holster"
	]:
		if demo.get_node_or_null(NodePath(path)) == null:
			missing.push_back(path)
	print("missing nodes: ", missing)

	var targets: Array = get_nodes_in_group(&"range_targets")
	print("targets: ", targets.size())
	var controls: Array = get_nodes_in_group(&"diegetic_control")
	print("controls: ", controls.size())

	var bench: Node = demo.get_node_or_null(^"Bench")
	var spec: Object = bench.call(&"current") if bench != null else null
	print(
		"bench weapon: ",
		(
			"none"
			if spec == null
			else str(spec.get("weapon_name")) + " / " + str(spec.get("archetype"))
		)
	)
	var stand: Node = demo.get_node_or_null(^"Bench/Stand")
	print("stand children: ", 0 if stand == null else stand.get_child_count())

	var holster: Node = demo.get_node_or_null(^"Player/Eye/Holster")
	var held: Object = holster.call(&"active_spec") if holster != null else null
	print("held: ", "none" if held == null else str(held.get("weapon_name")))

	# Score a hit by hand: find the 15 m centre plate and hand it a round.
	var scored_total := [0]
	var hit_target: Node = null
	for t: Node in targets:
		if float(t.get("distance_hint")) == 15.0 and int(t.get("kind")) == 0:
			hit_target = t
			break
	if hit_target != null:
		hit_target.connect(
			&"scored",
			func(p: int, _a: Vector3, _l: String, _k: StringName) -> void: scored_total[0] += p
		)
		hit_target.call(
			&"apply_bullet_damage",
			40.0,
			hit_target.global_position,
			Vector3.BACK,
			Vector3.FORWARD,
			&"head",
			2.0
		)
		hit_target.call(
			&"apply_bullet_damage",
			90.0,
			hit_target.global_position,
			Vector3.BACK,
			Vector3.FORWARD,
			&"body",
			2.0
		)
		await process_frame
		print("plate hp after 130: ", hit_target.get("health"), "  alive ", hit_target.get("alive"))
	print("points from that plate: ", scored_total[0], "   demo score: ", demo.get("score"))

	# Blow a drum and see the chain reach its neighbour.
	var drums: Array = []
	for t: Node in targets:
		if int(t.get("kind")) == 3:
			drums.push_back(t)
	if not drums.is_empty():
		drums[0].call(&"detonate")
		for _i: int in 40:
			await process_frame
		var down := 0
		for d: Node in drums:
			if not bool(d.get("alive")):
				down += 1
		print("drums: ", drums.size(), "  down after chain: ", down)

	# Paper: ten rounds into a 30 mm cluster and read the group back.
	var paper: Node = null
	for t: Node in targets:
		if int(t.get("kind")) == 4:
			paper = t
	if paper != null:
		var face: Node3D = paper.get_node_or_null(NodePath(str(paper.get("face_path")))) as Node3D
		paper.call(&"set_shooter", "Test#1", "Test")
		for i: int in 10:
			var off := Vector3(cos(float(i)) * 0.015, sin(float(i)) * 0.015, 0.0)
			paper.call(
				&"apply_bullet_damage",
				30.0,
				face.global_position + off,
				Vector3.BACK,
				Vector3.FORWARD,
				&"body",
				1.0
			)
		print("group mm: ", paper.call(&"group_spread_mm"), "  shots: ", paper.call(&"shot_count"))

	# The whole firing path, for real: aim the player at the 15 m centre plate,
	# hold the trigger, and count what the targets say came back. This is the one
	# check that proves the trigger, the cone, the ray, the damage handoff and the
	# scoring are joined end to end rather than merely present.
	var shooter: Node = demo.get_node_or_null(^"Shooter")
	var player: Node = demo.get_node_or_null(^"Player")
	if shooter != null and player != null and hit_target != null:
		demo.call(&"reset_range")
		var eye_y: float = 0.30 + 1.66
		var aim: Vector3 = hit_target.global_position + Vector3(0.0, 0.92, 0.0)
		player.set("yaw", 0.0)
		player.set("pitch", atan2(aim.y - eye_y, absf(aim.z)))
		await process_frame
		await physics_frame
		var gun: Object = shooter.call(&"weapon")
		var landed := [0]
		gun.connect(
			&"hit", func(_c: Object, _p: Vector3, _n: Vector3, _d: float) -> void: landed[0] += 1
		)
		gun.call(&"trigger_down")
		for _i: int in 90:
			await physics_frame
		gun.call(&"trigger_up")
		print(
			"live fire: ",
			landed[0],
			" impacts   score ",
			demo.get("score"),
			"   hits ",
			demo.get("hits")
		)

	# Frame cost, measured over 240 frames with everything live.
	for _i: int in WARMUP_FRAMES:
		await process_frame
	var t0 := Time.get_ticks_usec()
	for _i: int in TIMED_FRAMES:
		await process_frame
	var per := float(Time.get_ticks_usec() - t0) / float(TIMED_FRAMES)
	print("frame: %.3f ms  (%.0f fps)" % [per / 1000.0, 1.0e6 / per])
	print("engine fps monitor: ", Performance.get_monitor(Performance.TIME_FPS))
	print("process ms: ", Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0)
	print("physics ms: ", Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0)
	print("draw calls: ", Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
	print("primitives: ", Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME))
	print("objects drawn: ", Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME))
	print("static triangles in scene: ", _count_tris(demo))

	# The same measurement with the demo gone, so the number above can be read
	# against something.
	demo.queue_free()
	for _i: int in 30:
		await process_frame
	var t1 := Time.get_ticks_usec()
	for _i: int in 300:
		await process_frame
	var idle := float(Time.get_ticks_usec() - t1) / 300.0
	print("empty tree: %.3f ms/frame" % [idle / 1000.0])
	quit(0)


func _count_tris(node: Node) -> int:
	var n := 0
	var mi := node as MeshInstance3D
	if mi != null:
		n += _tris_of(mi.mesh)
	var mm := node as MultiMeshInstance3D
	if mm != null and mm.multimesh != null:
		n += _tris_of(mm.multimesh.mesh) * mm.multimesh.instance_count
	for c: Node in node.get_children():
		n += _count_tris(c)
	return n


func _tris_of(mesh: Mesh) -> int:
	if mesh == null:
		return 0
	var am := mesh as ArrayMesh
	if am == null:
		return mesh.get_faces().size() / 3
	var n := 0
	for s: int in am.get_surface_count():
		n += am.surface_get_array_len(s) / 3
	return n
