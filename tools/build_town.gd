@tool
extends SceneTree
## Town bake: the layout plan in, a shipped town out.
##
## Produces
##   res://data/world/town_tuning.tres        the knob box, created if absent
##   res://data/world/layout.res              roads, ladders, buildings, POIs, pads
##   res://data/world/colliders.res           the oriented-box collision grid
##   res://data/world/town/chunk_*.res        fused chunk meshes and their shapes
##   res://data/world/town/town_nav.res       the baked navigation mesh
##   res://data/world/town/town_occluders.res the building occluder hull set
##   res://data/world/town/town.tscn          the assembled `Town` node
##   res://data/world/kits/<id>.tscn          six reusable environment kits
##   res://data/world/kits/<id>_layout.res    each kit's ladders and structures
##   res://data/world/town_report.txt         the self-test output
##
## Run headless:
##   godot --headless --path <project> --script res://tools/build_town.gd
##
## Then RE-RUN `tools/build_terrain.gd`. The terrain's road paint reads
## `layout.res`, so the streets only appear on the ground after this has written
## it. That is the reference's build order and it is not optional.
##
## WHY FUSED CHUNKS AND NOT MULTIMESH. Nothing in this world repeats. Every crate
## is a different size, every wall a different shade — colour is a per-vertex
## attribute and the shader's grain is keyed to object space, so two drums are
## never the same mesh. A MultiMesh would need one instance buffer per distinct
## prop and would still cost a draw call each. Fusing everything whose centroid
## shares a 48 m cell into one un-indexed soup gives ONE draw call per chunk for
## the entire town, which is strictly fewer than any instancing scheme could
## reach here. The chunk grid is the culling unit; the occluders do the rest.

const TUNING_PATH: String = "res://data/world/town_tuning.tres"
const LAYOUT_PATH: String = "res://data/world/layout.res"
const COLLIDER_PATH: String = "res://data/world/colliders.res"
const TERRAIN_PATH: String = "res://data/world/terrain_data.res"
const OUT_DIR: String = "res://data/world/town"
const KIT_DIR: String = "res://data/world/kits"
const SCENE_PATH: String = "res://data/world/town/town.tscn"
const NAV_PATH: String = "res://data/world/town/town_nav.res"
## The per-shell auditor `validate_meshes.gd` grades the shipped town by. The
## bake gates on the same arithmetic so the report cannot disagree with the sweep.
const MeshAudit := preload("res://tools/mesh_audit.gd")
const OCCLUDER_PATH: String = "res://data/world/town/town_occluders.res"
const MATERIAL_PATH: String = "res://art/materials/world_surface.tres"
const REPORT_PATH: String = "res://data/world/town_report.txt"

## Beyond this distance from the town centre a chunk stops casting shadows. The
## wilds are junk on sand; their shadows cost more than they read.
const SHADOW_RADIUS: float = 220.0

## Vertical padding added to the navmesh source bounds so a roof deck at 14 m is
## still inside the baked volume.
const NAV_HEIGHT_PAD: float = 40.0

## Geometry findings the bake refuses to ship. `bake()` clears it; `_initialize`
## turns it into the process exit code, because a builder that cannot fail is not
## a check, it is a log line.
static var _failures: PackedStringArray = PackedStringArray()


func _initialize() -> void:
	var t0: int = Time.get_ticks_msec()
	var report: PackedStringArray = bake()
	report.push_back("bake time             %d ms" % (Time.get_ticks_msec() - t0))
	report.push_back("")
	if _failures.is_empty():
		report.push_back("RESULT: PASS")
	else:
		report.push_back("RESULT: FAIL - %d surface(s) with findings" % _failures.size())
		for line: String in _failures:
			report.push_back("  " + line)
	var text: String = "\n".join(report) + "\n"
	DirAccess.make_dir_recursive_absolute(REPORT_PATH.get_base_dir())
	var f := FileAccess.open(REPORT_PATH, FileAccess.WRITE)
	if f != null:
		f.store_string(text)
		f.close()
	print(text)
	quit(0 if _failures.is_empty() else 1)


static func bake() -> PackedStringArray:
	_failures = PackedStringArray()
	var log_lines := PackedStringArray()
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	DirAccess.make_dir_recursive_absolute(KIT_DIR)

	var tuning: TownTuning = _load_tuning()
	var terrain: WorldTerrainData = null
	if ResourceLoader.exists(TERRAIN_PATH):
		terrain = ResourceLoader.load(TERRAIN_PATH) as WorldTerrainData
	if terrain == null:
		log_lines.push_back("FATAL: no terrain_data.res. Run build_terrain.gd first.")
		return log_lines

	var town: WorldTown = TownLayout.generate(tuning, terrain)
	var mesher: WorldMesher = town.mesher
	var colliders: WorldColliderSet = town.colliders

	_save(town.layout, LAYOUT_PATH)
	_save(colliders, COLLIDER_PATH)

	var material: Material = null
	if ResourceLoader.exists(MATERIAL_PATH):
		material = ResourceLoader.load(MATERIAL_PATH) as Material

	# ------------------------------------------------------------- chunk meshes
	var root := Node3D.new()
	root.name = "Town"
	var body := StaticBody3D.new()
	body.name = "Collision"
	body.collision_layer = GameLayers.WORLD
	body.collision_mask = 0

	var buckets: Dictionary = mesher.chunk_triangles(tuning.chunk_size)
	var keys: Array = buckets.keys()
	keys.sort_custom(
		func(a: Vector2i, b: Vector2i) -> bool: return a.y * 100000 + a.x < b.y * 100000 + b.x
	)
	var col_buckets: Dictionary = _bucket_colliders(colliders, tuning.chunk_size)
	var chunk_tris: int = 0
	var collision_tris: int = 0
	var shadow_chunks: int = 0
	for key: Vector2i in keys:
		var tris: PackedInt32Array = buckets[key]
		var mesh: ArrayMesh = mesher.build_subset(tris, material)
		var path: String = "%s/chunk_%s_%s.res" % [OUT_DIR, _tag(key.x), _tag(key.y)]
		_save(mesh, path)
		chunk_tris += tris.size()
		var mi := MeshInstance3D.new()
		mi.name = "chunk_%s_%s" % [_tag(key.x), _tag(key.y)]
		mi.mesh = ResourceLoader.load(path) as ArrayMesh
		mi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
		var centre := Vector2(
			(float(key.x) + 0.5) * tuning.chunk_size, (float(key.y) + 0.5) * tuning.chunk_size
		)
		if centre.length() > SHADOW_RADIUS:
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		else:
			shadow_chunks += 1
		root.add_child(mi)

		if col_buckets.has(key):
			var faces: PackedVector3Array = _collider_faces(colliders, col_buckets[key])
			var shape := ConcavePolygonShape3D.new()
			shape.set_faces(faces)
			collision_tris += faces.size() / 3
			var spath: String = "%s/chunk_%s_%s_col.res" % [OUT_DIR, _tag(key.x), _tag(key.y)]
			_save(shape, spath)
			var cs := CollisionShape3D.new()
			cs.name = "shape_%s_%s" % [_tag(key.x), _tag(key.y)]
			cs.shape = ResourceLoader.load(spath) as Shape3D
			body.add_child(cs)
	root.add_child(body)

	# ---------------------------------------------------------------- occluders
	var occ_boxes: int = 0
	var occluder: ArrayOccluder3D = _build_occluders(town, tuning)
	if occluder != null:
		occ_boxes = occluder.get_indices().size() / 36
		_save(occluder, OCCLUDER_PATH)
		var oi := OccluderInstance3D.new()
		oi.name = "Occluders"
		oi.occluder = ResourceLoader.load(OCCLUDER_PATH) as Occluder3D
		root.add_child(oi)

	# ---------------------------------------------------------------- navigation
	# Control bake: the bare height field on its own. It must come out as one
	# island holding effectively all of the ground area — if it does not, the
	# faces are being fed to Recast wrong and nothing built on top can be
	# trusted either.
	var ground_only := NavigationMeshSourceGeometryData3D.new()
	ground_only.add_faces(_terrain_faces(terrain, tuning), Transform3D.IDENTITY)
	var ground_nav: NavigationMesh = _make_navmesh(tuning)
	NavigationServer3D.bake_from_source_geometry_data(ground_nav, ground_only)
	var ground_link: Dictionary = _nav_connectivity(ground_nav)

	var nav_src := NavigationMeshSourceGeometryData3D.new()
	var nav_faces: int = _nav_source(nav_src, town, terrain, tuning)
	var navmesh: NavigationMesh = _make_navmesh(tuning)
	NavigationServer3D.bake_from_source_geometry_data(navmesh, nav_src)
	_save(navmesh, NAV_PATH)
	var nav_region := NavigationRegion3D.new()
	nav_region.name = "Nav"
	nav_region.navigation_mesh = ResourceLoader.load(NAV_PATH) as NavigationMesh
	root.add_child(nav_region)
	var shape_count: int = body.get_child_count()

	_set_owner(root, root)
	var packed := PackedScene.new()
	var err: Error = packed.pack(root)
	if err != OK:
		push_error("build_town: pack failed (%d)" % err)
	_save(packed, SCENE_PATH)
	root.free()

	# --------------------------------------------------------------------- kits
	var kit_lines := PackedStringArray()
	for i in TownKits.IDS.size():
		kit_lines.push_back(_bake_kit(i, tuning, material))

	# ------------------------------------------------------------------- report
	var nav_polys: int = navmesh.get_polygon_count()
	var nav_link: Dictionary = _nav_connectivity(navmesh)
	log_lines.push_back("TOWN BAKE  seed %d" % tuning.world_seed)
	log_lines.push_back("")
	log_lines.push_back("roads                 %d segments" % town.layout.road_lines.size())
	log_lines.push_back("blocks                %d" % town.layout.blocks.size())
	log_lines.push_back("buildings             %s" % _kind_tally(town))
	log_lines.push_back("ladders               %d climb volumes" % town.layout.ladder_count())
	log_lines.push_back(
		(
			"points of interest    %d  (%d extraction pads)"
			% [town.layout.poi_name.size(), _count_exfils(town.layout)]
		)
	)
	log_lines.push_back("")
	log_lines.push_back(
		(
			"geometry              %d tris in %d chunks of %.0f m"
			% [mesher.triangle_count(), keys.size(), tuning.chunk_size]
		)
	)
	log_lines.push_back(
		(
			"                      %d tris per chunk mean, %d chunks cast shadows"
			% [chunk_tris / maxi(1, keys.size()), shadow_chunks]
		)
	)
	log_lines.push_back(
		(
			"collision             %d boxes -> %d tris in %d shapes"
			% [colliders.size(), collision_tris, shape_count]
		)
	)
	log_lines.push_back("occluders             %d building hulls" % occ_boxes)
	log_lines.push_back("")
	log_lines.push_back(
		"navmesh               %d polys from %d source tris" % [nav_polys, nav_faces]
	)
	var nav_box: AABB = nav_link["aabb"]
	log_lines.push_back(
		(
			"navmesh connectivity  %d components; largest %d of %d polys, %.0f of %.0f m2"
			% [
				nav_link["components"],
				nav_link["polys"],
				nav_polys,
				nav_link["area"],
				nav_link["total_area"]
			]
		)
	)
	log_lines.push_back(
		(
			"navmesh bare ground   %d components, largest %.0f of %.0f m2 (%.2f%%)"
			% [
				ground_link["components"],
				ground_link["area"],
				ground_link["total_area"],
				100.0 * ground_link["area"] / maxf(1.0, ground_link["total_area"])
			]
		)
	)
	log_lines.push_back(
		(
			"navmesh main island   spans %.0f x %.0f m, y %.1f .. %.1f"
			% [nav_box.size.x, nav_box.size.z, nav_box.position.y, nav_box.end.y]
		)
	)
	log_lines.push_back("")
	for line: String in _audit("town soup", mesher.arrays()):
		log_lines.push_back(line)
	log_lines.push_back("")
	log_lines.push_back("KITS")
	for line in kit_lines:
		log_lines.push_back(line)
	log_lines.push_back("")
	log_lines.push_back("LOAD-BACK")
	for line in _verify_saved():
		log_lines.push_back(line)
	return log_lines


## Reload and instantiate everything that was just written. A scene that packs
## cleanly can still fail to come back — a null mesh reference, an occluder that
## lost its resource, a navmesh region with nothing in it. This is the only proof
## that what shipped is what was built.
static func _verify_saved() -> PackedStringArray:
	var out := PackedStringArray()
	var scene: PackedScene = (
		ResourceLoader.load(SCENE_PATH, "", ResourceLoader.CACHE_MODE_IGNORE_DEEP) as PackedScene
	)
	if scene == null:
		out.push_back("  town.tscn        FAILED to load")
		return out
	var root: Node = scene.instantiate()
	var meshes: int = 0
	var missing: int = 0
	var verts: int = 0
	for child in root.get_children():
		var mi := child as MeshInstance3D
		if mi == null:
			continue
		meshes += 1
		if mi.mesh == null or mi.mesh.get_surface_count() == 0:
			missing += 1
			continue
		verts += mi.mesh.surface_get_array_len(0)
	var nav := root.get_node_or_null(^"Nav") as NavigationRegion3D
	var occ := root.get_node_or_null(^"Occluders") as OccluderInstance3D
	var col := root.get_node_or_null(^"Collision") as StaticBody3D
	out.push_back(
		(
			"  town.tscn        %d nodes, %d mesh instances (%d empty), %d verts"
			% [_count_nodes(root), meshes, missing, verts]
		)
	)
	out.push_back(
		(
			"                   nav %d polys, occluder %d verts, %d collision shapes"
			% [
				(
					0
					if nav == null or nav.navigation_mesh == null
					else (nav.navigation_mesh.get_polygon_count())
				),
				0 if occ == null or occ.occluder == null else occ.occluder.get_vertices().size(),
				0 if col == null else col.get_child_count()
			]
		)
	)
	root.free()

	for id in TownKits.IDS:
		var kit: PackedScene = (
			ResourceLoader.load(
				"%s/%s.tscn" % [KIT_DIR, id], "", ResourceLoader.CACHE_MODE_IGNORE_DEEP
			)
			as PackedScene
		)
		if kit == null:
			out.push_back("  %-16s FAILED to load" % id)
			continue
		var node: Node = kit.instantiate()
		var mi := node.get_node_or_null(^"Mesh") as MeshInstance3D
		var bodies := node.get_node_or_null(^"Collision") as StaticBody3D
		out.push_back(
			(
				"  %-16s %d nodes, %d verts, %d shapes, size %s"
				% [
					id,
					_count_nodes(node),
					0 if mi == null or mi.mesh == null else mi.mesh.surface_get_array_len(0),
					0 if bodies == null else bodies.get_child_count(),
					_size_text(node.get_meta(&"kit_size", Vector3.ZERO))
				]
			)
		)
		node.free()
	return out


static func _size_text(v: Vector3) -> String:
	return "%.1f x %.1f x %.1f m" % [v.x, v.y, v.z]


static func _count_nodes(node: Node) -> int:
	var n: int = 1
	for child in node.get_children():
		n += _count_nodes(child)
	return n


# ------------------------------------------------------------------------ kits


## Build, save and validate one kit. Returns its report line.
##
## Kits are small enough to prove closure the hard way: every triangle edge is
## interned and counted, and a closed set of solids uses every edge exactly
## twice. One boundary edge means a hole you could see through.
static func _bake_kit(index: int, tuning: TownTuning, material: Material) -> String:
	var id: String = TownKits.IDS[index]
	var town: WorldTown = TownKits.build(index, tuning)
	var mesher: WorldMesher = town.mesher
	var mesh: ArrayMesh = mesher.build_mesh(material)
	var mesh_path: String = "%s/%s_mesh.res" % [KIT_DIR, id]
	_save(mesh, mesh_path)
	_save(town.layout, "%s/%s_layout.res" % [KIT_DIR, id])

	var aabb: AABB = _bounds(mesher.vertices())
	var root := Node3D.new()
	root.name = id.to_pascal_case()
	root.set_meta(&"kit_id", id)
	root.set_meta(&"kit_blurb", TownKits.BLURBS[index])
	root.set_meta(&"kit_size", aabb.size)
	root.set_meta(&"kit_origin_offset", aabb.position)

	var mi := MeshInstance3D.new()
	mi.name = "Mesh"
	mi.mesh = ResourceLoader.load(mesh_path) as ArrayMesh
	mi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	root.add_child(mi)

	var body := StaticBody3D.new()
	body.name = "Collision"
	body.collision_layer = GameLayers.WORLD
	body.collision_mask = 0
	for i in town.colliders.size():
		var shape := BoxShape3D.new()
		shape.size = town.colliders.halves[i] * 2.0
		var cs := CollisionShape3D.new()
		cs.name = "box_%03d" % i
		cs.shape = shape
		cs.transform = Transform3D(
			Basis(Vector3.UP, town.colliders.yaws[i]), town.colliders.centers[i]
		)
		body.add_child(cs)
	root.add_child(body)

	_set_owner(root, root)
	var packed := PackedScene.new()
	packed.pack(root)
	_save(packed, "%s/%s.tscn" % [KIT_DIR, id])
	root.free()

	var row: Dictionary = MeshAudit.check_surface(mesher.arrays())
	if MeshAudit.failed(row, false):
		_failures.push_back("kit %s: %s" % [id, MeshAudit.why(row, false)])
	return (
		"  %-13s %6d tris  %4d boxes  %5.1f x %5.1f x %5.1f m  %4d shells  %s"
		% [
			id,
			mesher.triangle_count(),
			town.colliders.size(),
			aabb.size.x,
			aabb.size.y,
			aabb.size.z,
			int(row["shells"]),
			MeshAudit.why(row, false)
		]
	)


# ------------------------------------------------------------------- occluders


## One hull per building, pulled inside its own facade. Anything narrower than
## the threshold is skipped: testing it costs more than it hides.
static func _build_occluders(town: WorldTown, tuning: TownTuning) -> ArrayOccluder3D:
	var verts := PackedVector3Array()
	var idx := PackedInt32Array()
	for b in town.buildings:
		if not b.has_deck():
			continue
		var hw: float = b.w * 0.5 - tuning.occluder_inset
		var hd: float = b.d * 0.5 - tuning.occluder_inset
		if hw < tuning.occluder_min_size * 0.5 or hd < tuning.occluder_min_size * 0.5:
			continue
		var height: float = b.roof_y - b.base
		if height < 1.0:
			continue
		_push_box(
			verts,
			idx,
			Vector3(b.x, (b.base + b.roof_y) * 0.5, b.z),
			Vector3(hw, height * 0.5, hd),
			b.ry
		)
	if idx.is_empty():
		return null
	var occ := ArrayOccluder3D.new()
	occ.set_arrays(verts, idx)
	return occ


## Twelve triangles of a yawed box, appended to an occluder buffer.
static func _push_box(
	verts: PackedVector3Array, idx: PackedInt32Array, c: Vector3, h: Vector3, ry: float
) -> void:
	var base: int = verts.size()
	var basis := Basis(Vector3.UP, ry)
	for s in 8:
		var local := Vector3(h.x if s & 1 else -h.x, h.y if s & 2 else -h.y, h.z if s & 4 else -h.z)
		verts.push_back(c + basis * local)
	const QUADS: Array[Vector4i] = [
		Vector4i(0, 1, 3, 2),
		Vector4i(4, 6, 7, 5),
		Vector4i(0, 4, 5, 1),
		Vector4i(2, 3, 7, 6),
		Vector4i(0, 2, 6, 4),
		Vector4i(1, 5, 7, 3),
	]
	for q in QUADS:
		(
			idx
			. append_array(
				PackedInt32Array(
					[
						base + q.x,
						base + q.y,
						base + q.z,
						base + q.x,
						base + q.z,
						base + q.w,
					]
				)
			)
		)


# ------------------------------------------------------------------ navigation


## The Recast settings both bakes share.
##
## CELL SIZE IS NOT A TOWN SETTING. A `NavigationMesh` is rasterised into the
## navigation MAP when its region is merged, and the map takes its cell size and
## height from `ProjectSettings` — 0.25 / 0.25 here, the same numbers
## `tools/firefight/firefight_nav.gd` pins itself to. A navmesh baked finer than
## the map does not merge cleanly: the server reports "more than 2 edges tried to
## occupy the same map rasterization space", polygon edges fail to join across the
## seam, and off-mesh links fail to attach to the polygons under their ends.
##
## Measured with the town's own 0.21 / 0.145: 13 edge errors on every sync, and of
## 2,416 baked off-mesh links only 9% of the ladders and 16% of the drops were
## ones the navigation server would actually path through — against 100% of every
## kind in `arena` and `firefight`, which are baked at the map's own cell size.
## `TownTuning.nav_cell_size` is therefore read as the FLOOR of the town's detail,
## not as the bake value, and the map wins.
static func _make_navmesh(tuning: TownTuning) -> NavigationMesh:
	var nm := NavigationMesh.new()
	nm.cell_size = maxf(
		tuning.nav_cell_size,
		float(ProjectSettings.get_setting("navigation/3d/default_cell_size", 0.25))
	)
	nm.cell_height = maxf(
		tuning.nav_cell_height,
		float(ProjectSettings.get_setting("navigation/3d/default_cell_height", 0.25))
	)
	nm.agent_radius = tuning.nav_agent_radius
	nm.agent_height = tuning.nav_agent_height
	nm.agent_max_climb = tuning.nav_agent_max_climb
	nm.agent_max_slope = tuning.nav_agent_max_slope
	nm.region_min_size = tuning.nav_region_min
	nm.region_merge_size = tuning.nav_region_merge
	nm.edge_max_length = tuning.nav_cell_size * 30.0
	nm.edge_max_error = 1.2
	nm.detail_sample_distance = 4.0
	nm.detail_sample_max_error = 0.6
	nm.filter_low_hanging_obstacles = true
	nm.filter_ledge_spans = true
	nm.filter_walkable_low_height_spans = true
	return nm


## Feed Recast the terrain the AI can walk on and the boxes it cannot walk
## through. The COLLIDERS are the source, not the visual mesh: handrails, window
## frames and antennae are drawn but not collided, and carving the navmesh around
## them would fence the AI out of every doorway. Returns the triangle count.
static func _nav_source(
	src: NavigationMeshSourceGeometryData3D,
	town: WorldTown,
	terrain: WorldTerrainData,
	tuning: TownTuning
) -> int:
	var lim: float = tuning.nav_half_extent
	var ground: PackedVector3Array = _terrain_faces(terrain, tuning)
	src.add_faces(ground, Transform3D.IDENTITY)

	var boxes := PackedVector3Array()
	var count: int = town.colliders.size()
	for i in count:
		var c: Vector3 = town.colliders.centers[i]
		if absf(c.x) > lim or absf(c.z) > lim:
			continue
		if absf(c.y) > NAV_HEIGHT_PAD:
			continue
		boxes.append_array(_box_faces(c, town.colliders.halves[i], town.colliders.yaws[i]))
	src.add_faces(boxes, Transform3D.IDENTITY)
	return (ground.size() + boxes.size()) / 3


## The height field inside the nav window.
##
## WINDING. Godot's navigation baker reverses every triangle on its way into
## Recast, because Godot treats clockwise as front-facing and Recast treats
## counter-clockwise as up. Faces handed to it must therefore be in GODOT's
## convention — clockwise seen from above for ground you can walk on. Get it
## backwards and Recast reads the whole height field as ceiling: it bakes
## silently, reports no error, and returns a navmesh with zero polygons.
static func _terrain_faces(terrain: WorldTerrainData, tuning: TownTuning) -> PackedVector3Array:
	var lim: float = tuning.nav_half_extent
	var ax: PackedFloat32Array = terrain.ax
	var hg: PackedFloat32Array = terrain.heights
	var tn: int = terrain.tn
	var w: int = tn + 1
	var out := PackedVector3Array()
	for j in tn:
		if ax[j + 1] < -lim or ax[j] > lim:
			continue
		for i in tn:
			if ax[i + 1] < -lim or ax[i] > lim:
				continue
			var a := Vector3(ax[i], hg[j * w + i], ax[j])
			var b := Vector3(ax[i + 1], hg[j * w + i + 1], ax[j])
			var c := Vector3(ax[i + 1], hg[(j + 1) * w + i + 1], ax[j + 1])
			var d := Vector3(ax[i], hg[(j + 1) * w + i], ax[j + 1])
			out.append_array(PackedVector3Array([a, c, d, a, b, c]))
	return out


## Components in the navmesh graph, how big the largest one is, and how much of
## the walkable area it holds. Polygons are joined when they share an edge; a
## second component is an island the AI can see and never reach.
##
## Returns {components, polys, area, total_area, aabb}.
static func _nav_connectivity(navmesh: NavigationMesh) -> Dictionary:
	var n: int = navmesh.get_polygon_count()
	if n == 0:
		return {"components": 0, "polys": 0, "area": 0.0, "total_area": 0.0, "aabb": AABB()}
	var verts: PackedVector3Array = navmesh.get_vertices()
	# Recast's detail pass re-emits boundary vertices per polygon, so raw indices
	# never match across a shared edge. Weld on position instead, quantised to a
	# tenth of a millimetre.
	var welded := PackedInt32Array()
	welded.resize(verts.size())
	var seen: Dictionary = {}
	for i in verts.size():
		var key := Vector3i(
			roundi(verts[i].x * 10000.0), roundi(verts[i].y * 10000.0), roundi(verts[i].z * 10000.0)
		)
		if not seen.has(key):
			seen[key] = i
		welded[i] = int(seen[key])

	var adjacency: Array[PackedInt32Array] = []
	adjacency.resize(n)
	for i in n:
		adjacency[i] = PackedInt32Array()
	var owner_of: Dictionary = {}
	for p in n:
		var poly: PackedInt32Array = navmesh.get_polygon(p)
		var m: int = poly.size()
		for e in m:
			var a: int = welded[poly[e]]
			var b: int = welded[poly[(e + 1) % m]]
			var key: int = mini(a, b) * 1000000 + maxi(a, b)
			if owner_of.has(key):
				var q: int = int(owner_of[key])
				if q != p:
					adjacency[p].push_back(q)
					adjacency[q].push_back(p)
			else:
				owner_of[key] = p

	var component := PackedInt32Array()
	component.resize(n)
	component.fill(-1)
	var sizes := PackedInt32Array()
	var stack := PackedInt32Array()
	for seed in n:
		if component[seed] >= 0:
			continue
		var id: int = sizes.size()
		var count: int = 0
		stack.resize(0)
		stack.push_back(seed)
		component[seed] = id
		while not stack.is_empty():
			var cur: int = stack[stack.size() - 1]
			stack.remove_at(stack.size() - 1)
			count += 1
			for nb in adjacency[cur]:
				if component[nb] < 0:
					component[nb] = id
					stack.push_back(nb)
		sizes.push_back(count)

	var best: int = 0
	for i in sizes.size():
		if sizes[i] > sizes[best]:
			best = i
	var total: float = 0.0
	var best_area: float = 0.0
	var box := AABB()
	var first: bool = true
	for p in n:
		var poly: PackedInt32Array = navmesh.get_polygon(p)
		var a: float = 0.0
		for e in range(1, poly.size() - 1):
			var p0: Vector3 = verts[poly[0]]
			var p1: Vector3 = verts[poly[e]]
			var p2: Vector3 = verts[poly[e + 1]]
			a += absf((p1.x - p0.x) * (p2.z - p0.z) - (p2.x - p0.x) * (p1.z - p0.z)) * 0.5
		total += a
		if component[p] != best:
			continue
		best_area += a
		for vi in poly:
			if first:
				box = AABB(verts[vi], Vector3.ZERO)
				first = false
			else:
				box = box.expand(verts[vi])
	return {
		"components": sizes.size(),
		"polys": sizes[best],
		"area": best_area,
		"total_area": total,
		"aabb": box,
	}


# ---------------------------------------------------------------------- boxes


## Buckets collider indices by the chunk their centre falls in, so each chunk's
## collision shape holds exactly the boxes drawn in it.
static func _bucket_colliders(colliders: WorldColliderSet, cell: float) -> Dictionary:
	var out: Dictionary = {}
	for i in colliders.size():
		var c: Vector3 = colliders.centers[i]
		var key := Vector2i(floori(c.x / cell), floori(c.z / cell))
		if not out.has(key):
			out[key] = PackedInt32Array()
		var arr: PackedInt32Array = out[key]
		arr.push_back(i)
		out[key] = arr
	return out


static func _collider_faces(
	colliders: WorldColliderSet, list: PackedInt32Array
) -> PackedVector3Array:
	var faces := PackedVector3Array()
	for i in list:
		faces.append_array(_box_faces(colliders.centers[i], colliders.halves[i], colliders.yaws[i]))
	return faces


## Thirty-six vertices, twelve outward triangles, of a yaw-rotated box.
static func _box_faces(c: Vector3, h: Vector3, ry: float) -> PackedVector3Array:
	var basis := Basis(Vector3.UP, ry)
	var p := PackedVector3Array()
	p.resize(8)
	for s in 8:
		p[s] = (
			c
			+ (
				basis
				* Vector3(h.x if s & 1 else -h.x, h.y if s & 2 else -h.y, h.z if s & 4 else -h.z)
			)
		)
	const QUADS: Array[Vector4i] = [
		Vector4i(0, 1, 3, 2),
		Vector4i(4, 6, 7, 5),
		Vector4i(0, 4, 5, 1),
		Vector4i(2, 3, 7, 6),
		Vector4i(0, 2, 6, 4),
		Vector4i(1, 5, 7, 3),
	]
	var out := PackedVector3Array()
	for q in QUADS:
		out.append_array(PackedVector3Array([p[q.x], p[q.y], p[q.z], p[q.x], p[q.z], p[q.w]]))
	return out


# ------------------------------------------------------------------ self-test


## Scores one accumulator per shell and records anything that must not ship.
##
## The old check printed `signed volume ... (must be positive)` and never
## compared it to anything, which was harmless only because the number itself was
## meaningless: `WorldMesher.signed_volume()` sums the whole soup about one shared
## centroid, so twenty inside-out buildings are drowned by the hundred correct
## ones beside them and the total stays healthily positive. The town shipped
## +85564.2 m3 and a PASS while carrying hundreds of inverted shells. Per shell,
## about its own centroid, is the only decomposition that can see them.
##
## The union is scored, never a chunk. `chunk_triangles` cuts closed solids along
## a ragged line of triangle edges, so any single chunk is a lidless fragment with
## thousands of boundary edges by construction — scoring one reports the cut, not
## a hole.
static func _audit(label: String, arrays: Array) -> PackedStringArray:
	var row: Dictionary = MeshAudit.check_surface(arrays)
	if MeshAudit.failed(row, false):
		_failures.push_back("%s: %s" % [label, MeshAudit.why(row, false)])
	var out := PackedStringArray()
	out.push_back("shells                %d" % int(row["shells"]))
	out.push_back("flat shells           %d" % int(row["flat"]))
	out.push_back(
		"inverted shells       %d  (must be 0 - you see through it)" % int(row["inverted"])
	)
	out.push_back(
		"boundary edges        %d  (must be 0 - an open shell is an air gap)" % int(row["boundary"])
	)
	out.push_back(
		(
			"non-manifold edges    %d  (must be 0 - a butted joint, not overlapped)"
			% int(row["nonmanifold"])
		)
	)
	out.push_back(
		(
			"degenerate tris       %d  (must be 0 - a dropped face opens a shell)"
			% int(row["degenerate"])
		)
	)
	out.push_back(
		"duplicate faces       %d  (must be 0 - coplanar, they z-fight)" % int(row["duplicate"])
	)
	out.push_back(
		"winding/normal flips  %d  (must be 0 - lit one way, drawn the other)" % int(row["flip"])
	)
	out.push_back("outward volume        %+.1f m3 summed over shells" % float(row["volume"]))
	return out


static func _bounds(pos: PackedVector3Array) -> AABB:
	if pos.is_empty():
		return AABB()
	var out := AABB(pos[0], Vector3.ZERO)
	for v in pos:
		out = out.expand(v)
	return out


# ----------------------------------------------------------------------- misc


static func _load_tuning() -> TownTuning:
	if ResourceLoader.exists(TUNING_PATH):
		var res: TownTuning = ResourceLoader.load(TUNING_PATH) as TownTuning
		if res != null:
			return res
	var fresh := TownTuning.new()
	_save(fresh, TUNING_PATH)
	return fresh


## Chunk indices are signed; `n05` reads better in a filename than `-5`.
static func _tag(v: int) -> String:
	return ("n%02d" % -v) if v < 0 else ("p%02d" % v)


static func _kind_tally(town: WorldTown) -> String:
	var names: PackedStringArray = [
		"house", "warehouse", "ruin", "tower", "market", "compound", "containers"
	]
	var counts := PackedInt32Array()
	counts.resize(names.size())
	for b in town.buildings:
		counts[b.kind] += 1
	var parts := PackedStringArray()
	for i in names.size():
		if counts[i] > 0:
			parts.push_back("%d %s" % [counts[i], names[i]])
	return "%d total - %s" % [town.buildings.size(), ", ".join(parts)]


static func _count_exfils(layout: WorldLayoutData) -> int:
	var n: int = 0
	for k in layout.poi_kind:
		if k == WorldLayoutData.PoiKind.EXFIL:
			n += 1
	return n


static func _set_owner(node: Node, owner: Node) -> void:
	for child in node.get_children():
		if child != owner:
			child.owner = owner
		_set_owner(child, owner)


static func _save(res: Resource, path: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var err: Error = ResourceSaver.save(res, path)
	if err != OK:
		push_error("build_town: could not save %s (%d)" % [path, err])
