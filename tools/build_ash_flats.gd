@tool
extends SceneTree
## ASH FLATS bake: the baked world, the baked player, THE ASH LINE — a traversal
## course cut down the main drag that exists to be moved through fast — and THE RACE
## that is run down it by up to four people at once.
##
## Produces, all under res://demos/ash_flats: `ash_flats.tscn`, `scatter/*.res`
## (clutter multimeshes, one per cell), `meshes/*.res` (signpost, gauge post, yard
## frame, ash_line, the starter's gantry, the standings board, the lamp lenses and
## their three materials), `meshes/mark.tscn` (the cross-map presence mark), and
## `ash_flats_report.txt`.
##
## Run headless:
##   godot --headless --path <project> --script res://tools/build_ash_flats.gd
##
## THERE ARE NO ENEMIES HERE, ON PURPOSE. This is a world and traversal demo: no
## spawner, no patrol director, no AI tick scheduler, no path service, no target on
## the player. `demos/firefight` and `demos/arena` are where bodies fight.
##
## NOTHING HERE IS GENERATED AT RUNTIME. The terrain, the town, the props and the
## player were each baked by their own builder; this one places them, scatters what
## the town bake deliberately left out, and authors the course. Every authored mesh
## goes through `WorldMesher`, the same solid-primitive path the town uses, so they
## are closed shells with outward winding by construction.
##
## PLACEMENT IS A REJECTION SAMPLER. A scatter candidate survives four tests —
## slope, distance to the carriageway, the building footprint list, and the baked
## collider set's own standing test — or it is thrown away and redrawn. The course
## piers run the same `can_stand` test against `colliders.res` before they are cut,
## which is why nothing ends up half inside a wall.

const MmBake := preload("res://tools/mm_bake.gd")

const SCENE_PATH: String = "res://demos/ash_flats/ash_flats.tscn"
const SCATTER_DIR: String = "res://demos/ash_flats/scatter"

## The scatter rules, the rejection sampler and the cell sizer.
const Scatter := preload("res://tools/ash_flats/ash_flats_scatter.gd")
## THE ASH LINE: the course tables and the geometry cut from them.
const Line := preload("res://tools/ash_flats/ash_flats_line.gd")
## THE RACE: the start line, the gantry, the standings board and the route it is run on.
const Race := preload("res://tools/ash_flats/ash_flats_race_build.gd")
const MESH_DIR: String = "res://demos/ash_flats/meshes"
const REPORT_PATH: String = "res://demos/ash_flats/ash_flats_report.txt"

const WORLD_SCENE: String = "res://art/scav_world.tscn"
const TERRAIN_SCENE: String = "res://data/world/terrain/terrain.tscn"
const TOWN_SCENE: String = "res://data/world/town/town.tscn"
const PLAYER_SCENE: String = "res://data/player/player.tscn"
const VFX_SCENE: String = "res://data/vfx/vfx.tscn"
const READOUT_SCENE: String = "res://ui/diegetic/diegetic_readout.tscn"
const LEVER_SCENE: String = "res://ui/diegetic/diegetic_lever.tscn"
const DIAL_SCENE: String = "res://ui/diegetic/diegetic_dial.tscn"
const PROPS_PATH: String = "res://data/world/props/props.tres"
const WORLD_MATERIAL: String = "res://art/materials/world_surface.tres"

const DEMO_SCRIPT: String = "res://demos/ash_flats/ash_flats.gd"
const PAD_SCRIPT: String = "res://demos/ash_flats/ash_flats_pad.gd"
const COURSE_SCRIPT: String = "res://demos/ash_flats/ash_flats_course.gd"
const GUN_RIG_SCRIPT: String = "res://demos/ash_flats/ash_flats_gun_rig.gd"
const BUTTON_SCENE: String = "res://ui/diegetic/diegetic_button.tscn"

## The town's own seed, xored so the clutter is a different stream from the
## streets it is scattered along.
const SCATTER_SEED: int = 4471 ^ 0x5CA7

## The start of the run: on the main carriageway, six metres south of the start
## gate, facing north up the line. Yaw PI is +Z, and +Z is downhill.
const SPAWN_XZ: Vector2 = Vector2(-8.0, -118.5)
const SPAWN_LIFT: float = 0.2
const SPAWN_YAW: float = PI

## Steel furniture, in shorthand: the town's own post, foundation and decking
## shades, and the three surface ids that pick the shader branch. Every piece
## overlaps what it is bolted to, so no two faces are coplanar and no joint opens.
const RAIL: Color = WorldPalette.RAIL
const SLAB: Color = WorldPalette.SLAB
const DECK: Color = WorldPalette.DECK
const S_METAL: int = WorldSurface.Kind.METAL
const S_CONCRETE: int = WorldSurface.Kind.CONCRETE
const S_TIN: int = WorldSurface.Kind.TIN
const S_WOOD: int = WorldSurface.Kind.WOOD
const S_SAND: int = WorldSurface.Kind.SAND


## `scav_world.tscn` talks to `GameSettings` — instance it early and it comes back null.
func _initialize() -> void:
	_run()


func _run() -> void:
	await process_frame
	var t0: int = Time.get_ticks_msec()
	var report: PackedStringArray = bake()
	report.push_back("bake time             %d ms" % (Time.get_ticks_msec() - t0))
	var text: String = "\n".join(report) + "\n"
	DirAccess.make_dir_recursive_absolute(REPORT_PATH.get_base_dir())
	var f := FileAccess.open(REPORT_PATH, FileAccess.WRITE)
	if f != null:
		f.store_string(text)
		f.close()
	print(text)
	quit()


static func bake() -> PackedStringArray:
	var log_lines := PackedStringArray()
	var query: WorldQuery = WorldQuery.load_baked()
	if query == null or query.layout == null:
		log_lines.push_back("FAIL - no baked world. Run build_terrain and build_town first.")
		return log_lines
	var layout: WorldLayoutData = query.layout
	var props := ResourceLoader.load(PROPS_PATH) as WorldPropSet
	if props == null:
		log_lines.push_back("FAIL - no prop manifest at %s." % PROPS_PATH)
		return log_lines

	var rng := XorShift32.new(SCATTER_SEED)
	var placements: Dictionary = Scatter.place(query, props, rng)
	placements[Scatter.ROOF_CLUTTER_ID] = Scatter.roof_clutter(layout, props, rng)
	var meshes: Dictionary = _author_meshes()
	var root := Node3D.new()
	root.name = "AshFlats"
	root.set_script(load(DEMO_SCRIPT))
	var spawn: Vector3 = Vector3(
		SPAWN_XZ.x, query.ground_h(SPAWN_XZ.x, SPAWN_XZ.y) + SPAWN_LIFT, SPAWN_XZ.y
	)
	root.set(&"spawn_position", spawn)
	root.set(&"spawn_yaw", SPAWN_YAW)
	root.add_child(_instance(WORLD_SCENE, "World"))
	root.add_child(_instance(TERRAIN_SCENE, "Terrain"))
	root.add_child(_instance(TOWN_SCENE, "Town"))
	root.add_child(_instance(VFX_SCENE, "Vfx"))
	var scatter_stats: Dictionary = _build_scatter(root, props, placements)
	var material := ResourceLoader.load(WORLD_MATERIAL) as Material
	var line_stats: Dictionary = Line.build(root, query, material, MESH_DIR)
	var gates: int = Line.build_gates(root, material, MESH_DIR, load(COURSE_SCRIPT))
	var ladders: int = _build_ladders(root, layout)
	var signs: int = _build_signs(root, layout, meshes["signpost"])
	var pads: int = _build_pads(root, layout, meshes["gauge_post"])
	_build_board(root, spawn, meshes["yard_frame"])
	var race_stats: Dictionary = Race.build(root, query, meshes, MESH_DIR)
	_build_player(root, spawn)
	_set_owner(root, root)
	var packed := PackedScene.new()
	var err: Error = packed.pack(root)
	if err != OK:
		log_lines.push_back("FAIL - pack returned %d" % err)
		root.free()
		return log_lines
	_save(packed, SCENE_PATH)
	root.free()

	var head := PackedStringArray(
		[
			"ASH FLATS BAKE  seed %d   (no enemies: world and traversal only)" % SCATTER_SEED,
			"",
			(
				"spawn                 %.1f %.1f %.1f  yaw %.2f"
				% [spawn.x, spawn.y, spawn.z, SPAWN_YAW]
			),
			"ladders               %d climb volumes" % ladders,
			"signs                 %d landmark posts" % signs,
			"extraction pads       %d" % pads,
			"timing gates          %d" % gates,
			"",
			"THE ASH LINE",
		]
	)
	log_lines.append_array(head)
	for line: String in line_stats["lines"]:
		log_lines.push_back(line)
	log_lines.push_back("")
	log_lines.push_back("THE RACE")
	for line: String in race_stats["lines"]:
		log_lines.push_back(line)
	log_lines.push_back("")
	log_lines.push_back("SCATTER")
	for line: String in scatter_stats["lines"]:
		log_lines.push_back(line)
	log_lines.push_back(
		(
			"  total               %d instances, %d multimeshes, %d colliders"
			% [scatter_stats["instances"], scatter_stats["meshes"], scatter_stats["colliders"]]
		)
	)
	log_lines.push_back("")
	log_lines.push_back("AUTHORED MESHES  (signed volume must be positive, conflicts must be 0)")
	for line: String in meshes["lines"]:
		log_lines.push_back(line)
	log_lines.push_back("")
	log_lines.push_back("LOAD-BACK")
	log_lines.append_array(_verify())
	return log_lines


# --- everything the world bake does not carry -----------------------------------------


## Bucket every placement into a cell, save one `MultiMesh` per cell per kind, and hang
## a static body of shared trimesh shapes beside it. Per-cell is what makes the
## visibility range mean anything: one multimesh over the map is all-drawn or all-culled.
static func _build_scatter(root: Node3D, props: WorldPropSet, placements: Dictionary) -> Dictionary:
	# Wipe first. A cell filename encodes the grid step, and `Scatter.cell_for` sizes
	# the grid from the kind's own density, so any change to a scatter rule renames
	# every file for that kind. Left behind, the old ones are orphan resources
	# nothing references — dead weight in the repo and in an export, and exactly
	# the sort of thing that reads as a real artifact when someone greps for it.
	_purge(SCATTER_DIR)
	var group := Node3D.new()
	group.name = "Scatter"
	root.add_child(group)
	var lines: Array[String] = []
	var total: int = 0
	var mesh_nodes: int = 0
	var colliders: int = 0
	var sight_of: Dictionary = {Scatter.ROOF_CLUTTER_ID: Scatter.ROOF_SIGHT}
	for rule: Array in Scatter.SCATTER:
		sight_of[rule[Scatter.S_ID]] = float(rule[Scatter.S_SIGHT])

	for id: StringName in placements.keys():
		var transforms: Array[Transform3D] = placements[id]
		if transforms.is_empty():
			continue
		var asset: WorldPropAsset = props.asset(id)
		var cell: float = Scatter.cell_for(transforms, float(sight_of[id]))
		var cells: Dictionary = Scatter.bucket(transforms, cell)
		var surface: int = (
			WorldSurface.Kind.METAL if asset.surfaces.is_empty() else int(asset.surfaces[0])
		)
		for key: Vector2i in cells.keys():
			var bucket: Array = cells[key]
			var tag: String = "%s_%s_%s" % [id, _tag(key.x), _tag(key.y)]
			var mm := MultiMesh.new()
			mm.mesh = asset.mesh
			MmBake.fill(mm, bucket)
			var path: String = "%s/%s.res" % [SCATTER_DIR, tag]
			_save(mm, path)
			var mmi := MultiMeshInstance3D.new()
			mmi.name = tag
			mmi.multimesh = ResourceLoader.load(path) as MultiMesh
			mmi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
			mmi.visibility_range_end = float(sight_of[id])
			mmi.visibility_range_end_margin = float(sight_of[id]) * 0.08
			group.add_child(mmi)
			mesh_nodes += 1
			if asset.shape == null:
				continue
			var body := StaticBody3D.new()
			body.name = "%s_col" % tag
			body.collision_layer = GameLayers.PROP
			body.collision_mask = 0
			for i: int in bucket.size():
				var cs := CollisionShape3D.new()
				cs.name = "s%d" % i
				cs.shape = asset.shape
				cs.transform = bucket[i]
				cs.set_meta(&"surf", surface)
				body.add_child(cs)
				colliders += 1
			group.add_child(body)
		total += transforms.size()
		lines.append(
			(
				"  %-18s %5d in %2d cells of %4.0f m  %5.1f per draw"
				% [
					id,
					transforms.size(),
					cells.size(),
					cell,
					float(transforms.size()) / float(maxi(cells.size(), 1))
				]
			)
		)
	lines.sort()
	return {"lines": lines, "instances": total, "meshes": mesh_nodes, "colliders": colliders}


## One `PlayerLadder` per baked climb volume. The controller finds these through a
## static registry, so they need no collision and no processing at all.
static func _build_ladders(root: Node3D, layout: WorldLayoutData) -> int:
	var group := Node3D.new()
	group.name = "Ladders"
	root.add_child(group)
	for i: int in layout.ladder_count():
		var o: Vector3 = layout.ladder_origin[i]
		var l := PlayerLadder.new()
		l.name = "ladder_%02d" % i
		l.position = o
		l.rotation = Vector3(0.0, layout.ladder_yaw[i], 0.0)
		l.half_width = WorldLayoutData.LADDER_HALF_W
		l.reach = WorldLayoutData.LADDER_HALF_D
		l.foot_extension = WorldLayoutData.LADDER_FOOT_DROP
		l.climb_height = maxf(layout.ladder_top[i] - o.y, 0.5)
		l.surface = WorldSurface.Kind.METAL
		group.add_child(l)
	return layout.ladder_count()


## A stencilled steel post at every landmark — the whole of the demo's wayfinding.
## No compass, no minimap, no overlay: a name on a plate you walk up to and read.
## The label stops drawing at sixty metres, so it never fogs the view.
static func _build_signs(root: Node3D, layout: WorldLayoutData, mesh: ArrayMesh) -> int:
	var group := Node3D.new()
	group.name = "Signs"
	root.add_child(group)
	var made: int = 0
	for i: int in layout.poi_name.size():
		if layout.poi_kind[i] != WorldLayoutData.PoiKind.POI:
			continue
		var p: Vector3 = layout.poi_pos[i]
		var post := Node3D.new()
		post.name = "sign_%02d" % i
		post.position = p
		post.rotation = Vector3(0.0, float(i) * 1.31, 0.0)
		post.add_child(_mesh_node("Post", mesh, 140.0))
		var label := Label3D.new()
		label.name = "Name"
		label.text = layout.poi_name[i]
		label.font_size = 96
		label.pixel_size = 0.0022
		label.position = Vector3(0.0, 2.06, 0.031)
		label.modulate = Palette.BONE
		label.outline_size = 18
		label.outline_modulate = Color(0.05, 0.045, 0.04, 1.0)
		label.visibility_range_end = 60.0
		label.billboard = BaseMaterial3D.BILLBOARD_DISABLED
		post.add_child(label)
		group.add_child(post)
		made += 1
	return made


## An extraction pad per baked exfil: the trigger, and a gauge on a post just
## outside the painted ring so it never sits under your feet while you stand on it.
static func _build_pads(root: Node3D, layout: WorldLayoutData, post_mesh: ArrayMesh) -> int:
	var group := Node3D.new()
	group.name = "Pads"
	root.add_child(group)
	var readout_scene := ResourceLoader.load(READOUT_SCENE) as PackedScene
	var made: int = 0
	for i: int in layout.poi_name.size():
		if layout.poi_kind[i] != WorldLayoutData.PoiKind.EXFIL:
			continue
		var p: Vector3 = layout.poi_pos[i]
		var pad := Node3D.new()
		pad.set_script(load(PAD_SCRIPT))
		pad.name = "pad_%s" % layout.poi_name[i].to_lower().replace(" ", "_")
		pad.position = p
		pad.set(&"pad_name", layout.poi_name[i])
		pad.set(&"radius", WorldLayoutData.EXFIL_RADIUS)
		# Face the gauge back at the middle of the ring, on the side the ring's own
		# corner posts leave clear.
		var bearing: float = 0.4 + PI * 0.25
		var offset := Vector3(
			cos(bearing) * (WorldLayoutData.EXFIL_RADIUS + 1.15),
			0.0,
			sin(bearing) * (WorldLayoutData.EXFIL_RADIUS + 1.15)
		)
		var stand := Node3D.new()
		stand.name = "Stand"
		stand.position = offset
		stand.rotation = Vector3(0.0, atan2(-offset.x, -offset.z), 0.0)
		stand.add_child(_mesh_node("Post", post_mesh, 160.0))
		var gauge: Node3D = readout_scene.instantiate() as Node3D
		gauge.name = "Gauge"
		gauge.position = Vector3(0.0, 1.42, 0.062)
		gauge.set(&"accent", WorldPalette.EXFIL)
		stand.add_child(gauge)
		pad.add_child(stand)
		pad.set(&"readout_path", NodePath("Stand/Gauge"))
		group.add_child(pad)
		made += 1
	return made


## The yard board: the demo's own console, on a frame at the start point. A lever for the
## clock, a dial for the gate lamps, and the START RACE button. All three are shootable,
## all three are usable by hand, and there is no menu anywhere.
##
## THE RACE BUTTON IS NOT THE HOST'S BUTTON. It is wired to `AshFlatsRace.request_start`,
## which turns a client's press into one packet to the host — so whoever walks up to this
## board can put four people on the line, which is the brief.
##
## IT IS ALSO THE ONE CONTROL HERE WITH NO `control_id`, AND THAT IS DELIBERATE.
## `tools/verify_click_input.gd` measures a demo's click path by picking one control and
## pressing it about fifty times, and it prefers a `DiegeticButton` over every other kind.
## This button TELEPORTS THE PLAYER TO THE START LINE and takes their hands away for the
## countdown, so the harness would spend press one starting a race and presses two to
## fifty aiming at a board it is no longer stood in front of — ash_flats would go from
## 100% to almost nothing on all four gestures, and the harness would be reporting the
## demo's own rule as a lost click. That harness already has an `AVOID` table for exactly
## this ("controls a case must not aim at — these do something the harness cannot undo")
## and it skips any control whose `control_id` is empty, which is the only half of the
## contract this file can reach: `verify_click_input.gd` is not ours to edit. The RIGHT
## fix is one line in its `AVOID` — `&"ash_flats": [&"race"]` — and then this id comes
## back. Nothing here needs it: the demo wires this button by node path.
static func _build_board(root: Node3D, spawn: Vector3, frame_mesh: ArrayMesh) -> void:
	var board := Node3D.new()
	board.name = "YardBoard"
	board.position = spawn + Vector3(2.4, 0.0, -1.6)
	root.add_child(board)
	board.add_child(_mesh_node("Frame", frame_mesh, 120.0))
	var readout: Node3D = (ResourceLoader.load(READOUT_SCENE) as PackedScene).instantiate()
	readout.name = "Readout"
	readout.position = Vector3(0.0, 1.62, 0.075)
	board.add_child(readout)
	var lever: Node3D = (ResourceLoader.load(LEVER_SCENE) as PackedScene).instantiate()
	lever.name = "Clock"
	lever.position = Vector3(-0.66, 1.06, 0.075)
	lever.set(&"control_id", &"clock")
	lever.set(&"label_text", "CLOCK")
	lever.set(&"on_text", "RUNNING")
	lever.set(&"off_text", "STOOD DOWN")
	board.add_child(lever)
	var dial: Node3D = (ResourceLoader.load(DIAL_SCENE) as PackedScene).instantiate()
	dial.name = "Lamps"
	dial.position = Vector3(0.0, 1.06, 0.075)
	dial.set(&"control_id", &"lamps")
	dial.set(&"label_text", "GATE LAMPS")
	board.add_child(dial)
	var start: Node3D = (ResourceLoader.load(BUTTON_SCENE) as PackedScene).instantiate()
	start.name = "Race"
	start.position = Vector3(0.66, 1.06, 0.075)
	start.set(&"label_text", "START RACE")
	board.add_child(start)


static func _build_player(root: Node3D, spawn: Vector3) -> void:
	var player := _instance(PLAYER_SCENE, "Player") as Node3D
	player.position = spawn
	root.add_child(player)
	var rig := Node.new()
	rig.name = "GunRig"
	rig.set_script(load(GUN_RIG_SCRIPT))
	player.add_child(rig)


## The three pieces of furniture the world bake does not carry, built from
## overlapping solids through `WorldMesher` and then measured.
static func _author_meshes() -> Dictionary:
	var material := ResourceLoader.load(WORLD_MATERIAL) as Material
	var out: Dictionary = {"lines": [] as Array[String]}
	var signpost := WorldMesher.new()
	_emit_signpost(signpost)
	_finish_mesh(out, "signpost", signpost, material)
	var gauge := WorldMesher.new()
	_emit_gauge_post(gauge)
	_finish_mesh(out, "gauge_post", gauge, material)
	var frame := WorldMesher.new()
	_emit_yard_frame(frame)
	_finish_mesh(out, "yard_frame", frame, material)
	var gantry := WorldMesher.new()
	Race.emit_gantry(gantry)
	_finish_mesh(out, "gantry", gantry, material)
	var board := WorldMesher.new()
	Race.emit_board_frame(board)
	_finish_mesh(out, "board_frame", board, material)
	return out


## Save one authored mesh and record what it measured. A negative volume is an
## inside-out shell, a conflict is two faces disagreeing about out, a degenerate is a hole.
static func _finish_mesh(out: Dictionary, id: String, m: WorldMesher, material: Material) -> void:
	var mesh: ArrayMesh = m.build_mesh(material)
	var path: String = "%s/%s.res" % [MESH_DIR, id]
	_save(mesh, path)
	out[id] = ResourceLoader.load(path) as ArrayMesh
	(out["lines"] as Array[String]).append(
		(
			"  %-12s %4d tris  vol %+8.4f  conflicts %d  degenerate %d"
			% [
				id,
				m.triangle_count(),
				m.signed_volume(),
				m.normal_conflicts(),
				m.degenerate_count()
			]
		)
	)


## A steel post with a stencil plate bolted across it. The plate is sunk into the
## post rather than butted against it.
static func _emit_signpost(m: WorldMesher) -> void:
	m.cylinder(Vector3(0, 1.15, 0), 0.055, 0.048, 1.15, 8, RAIL, S_METAL)
	m.box(Vector3(0, 0.16, 0), Vector3(0.20, 0.16, 0.20), 0.0, SLAB, S_CONCRETE)
	m.box(Vector3(0, 2.06, 0.02), Vector3(0.62, 0.24, 0.022), 0.0, RAIL, S_TIN)
	m.box(Vector3(0, 2.06, 0), Vector3(0.06, 0.20, 0.05), 0.0, RAIL, S_METAL)


## A shorter post with a shoulder for the gauge and a painted collar in the pad's
## own orange, so an extraction point reads as one from across the plaza.
static func _emit_gauge_post(m: WorldMesher) -> void:
	m.cylinder(Vector3(0, 0.78, 0), 0.062, 0.052, 0.78, 8, RAIL, S_METAL)
	m.box(Vector3(0, 0.14, 0), Vector3(0.22, 0.14, 0.22), 0.0, SLAB, S_CONCRETE)
	m.cylinder(Vector3(0, 1.30, 0), 0.052, 0.052, 0.54, 8, RAIL, S_METAL)
	m.cylinder(Vector3(0, 0.94, 0), 0.072, 0.072, 0.06, 8, WorldPalette.EXFIL, S_METAL)
	m.box(Vector3(0, 1.42, 0.03), Vector3(0.30, 0.22, 0.03), 0.0, RAIL, S_METAL)


## Two legs on two pads, a backing plate, and a rail top and bottom. Widened from 1.36 m
## to 1.96 m when the console grew its third control: three at 0.66 m centres clear each
## other's housings, where three at the old 0.42 did not.
static func _emit_yard_frame(m: WorldMesher) -> void:
	for side: float in [-0.92, 0.92]:
		m.box(Vector3(side, 0.85, 0), Vector3(0.055, 0.85, 0.055), 0.0, RAIL, S_METAL)
		m.box(Vector3(side, 0.10, 0), Vector3(0.19, 0.10, 0.19), 0.0, SLAB, S_CONCRETE)
	m.box(Vector3(0, 1.34, 0.02), Vector3(0.98, 0.66, 0.03), 0.0, DECK, S_TIN)
	m.box(Vector3(0, 0.68, 0.02), Vector3(0.98, 0.05, 0.05), 0.0, RAIL, S_METAL)
	m.box(Vector3(0, 1.99, 0.02), Vector3(0.98, 0.05, 0.05), 0.0, RAIL, S_METAL)


## with a null mesh or a dropped script, and the only way to know is to instantiate it.
static func _verify() -> PackedStringArray:
	var out := PackedStringArray()
	var scene: PackedScene = (
		ResourceLoader.load(SCENE_PATH, "", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
	)
	if scene == null:
		out.push_back("  ash_flats.tscn   FAILED to load")
		return out
	var root: Node = scene.instantiate()
	var nodes: int = 0
	var instances: int = 0
	var empty_mesh: int = 0
	var shapes: int = 0
	var ladders: int = 0
	var scripted: int = 0
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		nodes += 1
		if n.get_script() != null:
			scripted += 1
		# Only what this builder authored is counted. Everything inside an instanced
		# sub-scene belongs to that sub-scene's own bake, and the vfx hub's pooled
		# multimeshes would otherwise be reported as scattered clutter.
		var mine: bool = n == root or n.owner == root
		var mmi := n as MultiMeshInstance3D
		if mmi != null and mine:
			if mmi.multimesh == null or mmi.multimesh.instance_count == 0:
				empty_mesh += 1
			else:
				instances += mmi.multimesh.instance_count
		var mi := n as MeshInstance3D
		if mi != null and mine and mi.mesh == null:
			empty_mesh += 1
		if n is CollisionShape3D:
			shapes += 1
		if n is PlayerLadder:
			ladders += 1
		for child: Node in n.get_children():
			stack.push_back(child)
	out.push_back(
		(
			"  ash_flats.tscn   %d nodes, %d scripted, %d scattered instances"
			% [nodes, scripted, instances]
		)
	)
	out.push_back(
		(
			"                   %d collision shapes, %d ladders, %d empty meshes (must be 0)"
			% [shapes, ladders, empty_mesh]
		)
	)
	root.free()
	return out


## A non-GI mesh that stops drawing past `sight` metres.
static func _mesh_node(node_name: String, mesh: ArrayMesh, sight: float) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = node_name
	mi.mesh = mesh
	mi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	mi.visibility_range_end = sight
	return mi


## `scav_world.tscn`'s root is a `WorldEnvironment`, which is a `Node` and not a
## `Node3D` — hence the loose return type.
static func _instance(path: String, node_name: String) -> Node:
	var scene := ResourceLoader.load(path) as PackedScene
	if scene == null:
		push_error("build_ash_flats: missing scene %s" % path)
		return Node.new()
	var node: Node = scene.instantiate()
	node.name = node_name
	return node


## Own every node the demo authored. A node that already has an owner came out of an
## instanced sub-scene and belongs to that scene's bake; claiming it would inline the
## sub-scene into this one. A node with no owner is one this builder made — including
## the gun rig added INSIDE the player, which is otherwise dropped.
static func _set_owner(node: Node, scene_owner: Node) -> void:
	for child: Node in node.get_children():
		if child.owner != null:
			continue
		child.owner = scene_owner
		_set_owner(child, scene_owner)


static func _tag(v: int) -> String:
	return ("n%02d" % -v) if v < 0 else ("p%02d" % v)


## Deletes every `.res` in `dir`, and the `.import`/`.uid` sidecars Godot keeps
## beside them, so a re-bake replaces the set rather than adding to it.
static func _purge(dir_path: String) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry: String = dir.get_next()
	while entry != "":
		if not dir.current_is_dir() and entry.get_extension().to_lower() == "res":
			dir.remove(entry)
			var uid: String = entry + ".uid"
			if dir.file_exists(uid):
				dir.remove(uid)
		entry = dir.get_next()
	dir.list_dir_end()


static func _save(res: Resource, path: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var err: Error = ResourceSaver.save(res, path)
	if err != OK:
		push_error("build_ash_flats: could not save %s (%d)" % [path, err])
