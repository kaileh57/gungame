@tool
extends SceneTree
## Prop bake: every building and prop generator run once on flat ground and saved
## as a reusable asset.
##
## Produces
##   res://data/world/props/<id>.res        one `WorldPropAsset` per prop
##   res://data/world/props/props.tres      the `WorldPropSet` manifest
##   res://data/world/props_report.txt      per-prop geometry and self-test
##
## Run headless:
##   godot --headless --path <project> --script res://tools/build_props.gd
## Then check the topology:
##   godot --headless --path <project> --script res://tools/validate_meshes.gd \
##       -- --dir=res://data/world/props --report=res://data/world/props_meshes.txt
##
## These assets are for anything that wants a prop without a town around it — the
## range, the bestiary arena, a test scene. The town build calls the generators in
## `res://systems/world/props/` directly instead, because there the props have to
## follow the terrain and share one mesher.

const OUT_DIR: String = "res://data/world/props"
const SET_PATH: String = "res://data/world/props/props.tres"
const REPORT_PATH: String = "res://data/world/props_report.txt"
const MATERIAL_PATH: String = "res://art/materials/world_surface.tres"

## Same seed the terrain and town bakes use. Every prop draws from its own
## derived stream so adding one does not re-roll the others.
const WORLD_SEED: int = 4471

## The catalogue, in bake order. Ids are frozen: they are what a scene asks for.
const PROP_IDS: Array[StringName] = [
	&"crate",
	&"big_crate",
	&"barrel",
	&"sandbags",
	&"wreck",
	&"dead_tree",
	&"rock_cluster",
	&"power_line",
	&"roof_clutter",
	&"ladder",
	&"stairs",
	&"wall_holed",
	&"containers",
	&"adobe_1f",
	&"adobe_2f",
	&"ruin",
	&"market",
	&"compound",
	&"warehouse",
	&"tower",
]


func _initialize() -> void:
	var t0: int = Time.get_ticks_msec()
	var report: PackedStringArray = bake()
	report.push_back("bake time             %d ms" % (Time.get_ticks_msec() - t0))
	var text: String = "\n".join(report) + "\n"
	DirAccess.make_dir_recursive_absolute(REPORT_PATH.get_base_dir())
	var fh := FileAccess.open(REPORT_PATH, FileAccess.WRITE)
	if fh != null:
		fh.store_string(text)
		fh.close()
	print(text)
	quit(0 if text.contains("RESULT: PASS") else 1)


## Bake the whole catalogue. Static so the world builder can chain it.
static func bake() -> PackedStringArray:
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	var mat: Material = null
	if ResourceLoader.exists(MATERIAL_PATH):
		mat = load(MATERIAL_PATH) as Material
	var tuning := PropTuning.new()

	var out: PackedStringArray = PackedStringArray()
	out.push_back("world prop bake")
	out.push_back("seed      %d" % WORLD_SEED)
	out.push_back("output    %s" % OUT_DIR)
	out.push_back("material  %s" % (MATERIAL_PATH if mat != null else "<missing, unshaded>"))
	out.push_back("")
	out.push_back(
		(
			"%-14s %8s %8s %8s %8s %10s %26s"
			% ["prop", "tris", "degen", "conflict", "boxes", "volume", "bounds (w x h x d)"]
		)
	)
	out.push_back("-".repeat(96))

	var manifest := WorldPropSet.new()
	var bad: PackedStringArray = PackedStringArray()
	var total_tris: int = 0
	var total_boxes: int = 0

	for i in PROP_IDS.size():
		var id: StringName = PROP_IDS[i]
		var mesher := WorldMesher.new()
		var ctx := PropContext.new(
			mesher,
			XorShift32.new(_seed_for(i)),
			WorldColliderSet.new(),
			WorldLayoutData.new(),
			null,
			WorldNoise.new(WORLD_SEED),
			tuning
		)
		_generate(id, ctx)

		var conflicts: int = mesher.normal_conflicts()
		var volume: float = mesher.signed_volume()
		var mesh: ArrayMesh = mesher.build_mesh(mat)
		var aabb: AABB = mesh.get_aabb()

		var asset := WorldPropAsset.new()
		asset.id = id
		asset.mesh = mesh
		asset.shape = _trimesh(mesher)
		asset.boxes = ctx.colliders
		asset.bounds = aabb
		asset.triangle_count = mesher.triangle_count()
		asset.volume = volume
		asset.surfaces = _surfaces_of(mesh)

		var path: String = OUT_DIR.path_join(String(id) + ".res")
		var err: int = ResourceSaver.save(asset, path)
		if err != OK:
			bad.push_back("%s: save failed (%d)" % [id, err])
		manifest.add(id, path, asset.triangle_count, aabb)

		total_tris += asset.triangle_count
		total_boxes += ctx.colliders.size()
		if mesher.triangle_count() == 0:
			bad.push_back("%s: produced no geometry" % id)
		if conflicts > 0:
			bad.push_back("%s: %d normal/winding conflicts" % [id, conflicts])
		if volume <= 0.0:
			bad.push_back("%s: net volume %.6f is not outward" % [id, volume])
		# The ladder is the one deliberate exception: its climb volume lives in the
		# layout, and a collider on the rungs would push the climber off them.
		if ctx.colliders.size() == 0 and id != &"ladder":
			bad.push_back("%s: no colliders" % id)

		out.push_back(
			(
				"%-14s %8d %8d %8d %8d %10.4f %26s"
				% [
					id,
					mesher.triangle_count(),
					mesher.degenerate_count(),
					conflicts,
					ctx.colliders.size(),
					volume,
					"%.2f x %.2f x %.2f" % [aabb.size.x, aabb.size.y, aabb.size.z]
				]
			)
		)

	var err2: int = ResourceSaver.save(manifest, SET_PATH)
	if err2 != OK:
		bad.push_back("manifest: save failed (%d)" % err2)

	out.push_back("")
	out.push_back("props                 %d" % PROP_IDS.size())
	out.push_back("triangles             %d" % total_tris)
	out.push_back("colliders             %d" % total_boxes)
	out.push_back("manifest              %s" % SET_PATH)
	out.push_back("")
	if bad.is_empty():
		out.push_back(
			"RESULT: PASS - %d props, %d triangles, all outward" % [PROP_IDS.size(), total_tris]
		)
	else:
		out.push_back("RESULT: FAIL - %d problems" % bad.size())
		for b: String in bad:
			out.push_back("  " + b)
	return out


## A stream per prop, so the catalogue can grow without re-rolling what is in it.
static func _seed_for(index: int) -> int:
	return (WORLD_SEED * 2654435761 + index * 1013904223) & 0xFFFFFFFF


static func _trimesh(mesher: WorldMesher) -> ConcavePolygonShape3D:
	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(mesher.vertices())
	return shape


## The distinct surface ids the mesh carries, read back out of CUSTOM0.x.
static func _surfaces_of(mesh: ArrayMesh) -> PackedByteArray:
	var seen: PackedByteArray = PackedByteArray()
	if mesh.get_surface_count() == 0:
		return seen
	var custom: PackedFloat32Array = mesh.surface_get_arrays(0)[Mesh.ARRAY_CUSTOM0]
	if custom == null:
		return seen
	var i: int = 0
	while i < custom.size():
		var s: int = int(round(custom[i]))
		if s >= 0 and s < WorldSurface.COUNT and not seen.has(s):
			seen.push_back(s)
		i += 4
	seen.sort()
	return seen


## One canonical instance of each generator, sized so the result is a usable prop
## rather than a demonstration of the code path.
static func _generate(id: StringName, ctx: PropContext) -> void:
	match id:
		&"crate":
			PropClutter.crate(ctx, 0.0, 0.0, 0.0, 0.0)
		&"big_crate":
			PropClutter.big_crate(ctx, 0.0, 0.0, 0.0, 0.0)
		&"barrel":
			PropClutter.barrel(ctx, 0.0, 0.0, 0.0)
		&"sandbags":
			PropClutter.sandbags(ctx, 0.0, 0.0, 0.0, 0.0)
		&"wreck":
			PropClutter.wreck(ctx, 0.0, 0.0, 0.0)
		&"dead_tree":
			PropClutter.dead_tree(ctx, 0.0, 0.0)
		&"rock_cluster":
			PropClutter.rock_cluster(ctx, 0.0, 0.0)
		&"power_line":
			PropClutter.power_line(
				ctx,
				PackedVector2Array([Vector2(-34.0, 0.0), Vector2(0.0, 0.0), Vector2(34.0, 0.0)])
			)
		&"roof_clutter":
			PropClutter.roof_clutter(ctx, 0.0, 0.0, 9.0, 7.0, 0.0, 0.0)
		&"ladder":
			PropStructures.add_ladder(ctx, 0.0, 0.0, 0.0, 0.0, 4.2)
		&"stairs":
			PropStructures.stairs_fixed(
				ctx,
				0.0,
				0.0,
				0.0,
				1.2,
				3.6,
				3.1,
				0.0,
				WorldPalette.SLAB,
				WorldSurface.Kind.CONCRETE
			)
		&"wall_holed":
			PropStructures.wall_with_holes(
				ctx,
				-4.0,
				0.0,
				4.0,
				0.0,
				0.0,
				3.2,
				0.42,
				[Vector4(1.1, 2.9, 0.0, 2.45), Vector4(4.6, 5.5, 1.05, 2.15)] as Array[Vector4],
				Palette.WORLD_ADOBE[0],
				WorldSurface.Kind.CONCRETE,
				WorldSurface.Kind.CONCRETE
			)
		&"containers":
			PropBuildings.containers(ctx, 0.0, 0.0, 0.0, 3)
		&"adobe_1f":
			PropBuildings.adobe(ctx, 0.0, 0.0, 8.0, 7.0, 1, 0.0)
		&"adobe_2f":
			PropBuildings.adobe(ctx, 0.0, 0.0, 9.0, 8.0, 2, 0.0)
		&"ruin":
			PropBuildings.ruin(ctx, 0.0, 0.0, 9.0, 7.0, 0.0)
		&"market":
			PropBuildings.market(ctx, 0.0, 0.0, 11.0, 9.0, 0.0)
		&"compound":
			PropBuildings.compound(ctx, 0.0, 0.0, 16.0, 14.0, 0.0)
		&"warehouse":
			PropBuildings.warehouse(ctx, 0.0, 0.0, 16.0, 22.0, 0.0)
		&"tower":
			PropBuildings.tower(ctx, 0.0, 0.0)
