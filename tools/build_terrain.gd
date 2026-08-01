@tool
extends SceneTree
## Terrain bake: the analytic height field in, a chunked crack-free mesh out.
##
## Produces
##   res://data/world/terrain_data.res      the height / road / surface tables
##   res://data/world/terrain/*.res         300 chunk meshes, 100 collision shapes
##   res://data/world/terrain/terrain.tscn  the assembled `TerrainChunks` node
##   res://data/world/terrain_report.txt    the self-test output
##
## Run headless:
##   godot --headless --path <project> --script res://tools/build_terrain.gd
##
## The road paint comes from `res://data/world/layout.res`. When the town has not
## been baked yet the map bakes unpaved and the report says so; re-run this after
## the layout bake and the streets appear. `bake()` is static so the world
## builder can call it directly in the same process.
##
## LOD WITHOUT CRACKS. Each chunk carries three levels built at strides 1, 2 and
## 4 over its 20x20 quads. The interior of a coarse level is coarse, but every
## coarse cell that touches the chunk BORDER is fanned from its own centre out to
## the FULL-RESOLUTION vertices along that border. So the perimeter polyline of a
## chunk is bit-identical at all three levels, and any two neighbours meet
## exactly whatever levels they happen to be drawing. There are no skirts and no
## T-junctions; §"seam" in the report proves it by counting edges.

const OUT_DIR: String = "res://data/world/terrain"
const TERRAIN_PATH: String = "res://data/world/terrain_data.res"
const SCENE_PATH: String = "res://data/world/terrain/terrain.tscn"
const LAYOUT_PATH: String = "res://data/world/layout.res"
const MATERIAL_PATH: String = "res://art/materials/world_surface.tres"
const REPORT_PATH: String = "res://data/world/terrain_report.txt"

## The reference's default seed. Everything about the map follows from it.
const WORLD_SEED: int = 4471

## Quads per chunk edge. Must divide `TerrainField.TN` (200) and be divisible by
## every stride in `LOD_STRIDES`. 20 gives a 10x10 board: the smallest chunk is
## 37 m across at the town, the largest 246 m at the rim.
const CHUNK_QUADS: int = 20

## Sampling stride per level of detail. Every entry must divide `CHUNK_QUADS`.
const LOD_STRIDES: PackedInt32Array = [1, 2, 4]

## Level whose triangles become the collision mesh.
const COLLISION_LOD: int = 0

## The four corners of a coarse cell average to its fan centre; this is the
## weight each corner gets. Named rather than inlined because the fan is the one
## place the mesh leaves the sampled surface.
const FAN_CENTRE_WEIGHT: float = 0.25


func _initialize() -> void:
	var t0: int = Time.get_ticks_msec()
	var report: PackedStringArray = bake(WORLD_SEED)
	report.push_back("bake time             %d ms" % (Time.get_ticks_msec() - t0))
	var text: String = "\n".join(report) + "\n"
	DirAccess.make_dir_recursive_absolute(REPORT_PATH.get_base_dir())
	var f := FileAccess.open(REPORT_PATH, FileAccess.WRITE)
	if f != null:
		f.store_string(text)
		f.close()
	print(text)
	quit()


## The whole bake. Returns the report lines.
static func bake(world_seed: int) -> PackedStringArray:
	var log_lines := PackedStringArray()
	DirAccess.make_dir_recursive_absolute(OUT_DIR)

	var field := TerrainField.new(world_seed)
	var ax: PackedFloat32Array = field.axis()
	var hg: PackedFloat32Array = field.heights()

	var vk: PackedFloat32Array = field.rock_grid()
	var vc: PackedColorArray = field.colour_grid(vk)
	var layout: WorldLayoutData = null
	if ResourceLoader.exists(LAYOUT_PATH):
		layout = ResourceLoader.load(LAYOUT_PATH) as WorldLayoutData
	var vr: PackedFloat32Array = field.road_grid(layout, vk)
	var qs: PackedByteArray = field.quad_surface_grid(vk)

	var data := WorldTerrainData.new()
	data.tn = TerrainField.TN
	data.ax = ax
	data.heights = hg
	data.road = vr
	data.quad_surface = qs
	data.world_seed = world_seed
	data.build_lut()
	_save(data, TERRAIN_PATH)

	var material: Material = null
	if ResourceLoader.exists(MATERIAL_PATH):
		material = ResourceLoader.load(MATERIAL_PATH) as Material

	var root := Node3D.new()
	root.name = "Terrain"
	root.set_script(load("res://systems/world/terrain/terrain_chunks.gd"))

	var body := StaticBody3D.new()
	body.name = "Collision"
	body.collision_layer = GameLayers.WORLD
	body.collision_mask = 0

	var chunks: int = TerrainField.TN / CHUNK_QUADS
	var tri_totals := PackedInt32Array()
	tri_totals.resize(LOD_STRIDES.size())
	var vert_totals := PackedInt32Array()
	vert_totals.resize(LOD_STRIDES.size())
	var degenerates: int = 0
	var downward: int = 0
	var seam_faults: int = 0
	var collision_tris: int = 0
	var edge_use: Array[Dictionary] = []
	for _l in LOD_STRIDES.size():
		edge_use.push_back({})
	var vert_ids: Dictionary = {}

	for cj in chunks:
		for ci in chunks:
			var i0: int = ci * CHUNK_QUADS
			var j0: int = cj * CHUNK_QUADS
			var node := Node3D.new()
			node.name = "chunk_%02d_%02d" % [ci, cj]
			var lo := Vector3(ax[i0], 0.0, ax[j0])
			var hi := Vector3(ax[i0 + CHUNK_QUADS], 0.0, ax[j0 + CHUNK_QUADS])
			node.set_meta(&"chunk_radius", (hi - lo).length() * 0.5)

			for lod in LOD_STRIDES.size():
				var m := WorldMesher.new()
				_emit_chunk(m, field, vc, vr, qs, i0, j0, LOD_STRIDES[lod])
				degenerates += m.degenerate_count()
				tri_totals[lod] += m.triangle_count()
				vert_totals[lod] += m.vertices().size()
				_tally_edges(edge_use[lod], vert_ids, m.vertices())
				var mesh: ArrayMesh = m.build_mesh(material)
				downward += _count_downward(mesh)
				seam_faults += _check_seam(m.vertices(), field, i0, j0)
				var path: String = "%s/chunk_%02d_%02d_lod%d.res" % [OUT_DIR, ci, cj, lod]
				_save(mesh, path)
				var mi := MeshInstance3D.new()
				mi.name = "lod%d" % lod
				mi.mesh = ResourceLoader.load(path) as ArrayMesh
				mi.set_meta(&"lod", lod)
				mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
				node.add_child(mi)
				if lod == COLLISION_LOD:
					var shape := ConcavePolygonShape3D.new()
					shape.set_faces(m.vertices())
					collision_tris += m.triangle_count()
					var spath: String = "%s/chunk_%02d_%02d_col.res" % [OUT_DIR, ci, cj]
					_save(shape, spath)
					var cs := CollisionShape3D.new()
					cs.name = "shape_%02d_%02d" % [ci, cj]
					cs.shape = ResourceLoader.load(spath) as Shape3D
					body.add_child(cs)
			root.add_child(node)

	root.add_child(body)
	_set_owner(root, root)
	var packed := PackedScene.new()
	var err: Error = packed.pack(root)
	if err != OK:
		push_error("build_terrain: pack failed (%d)" % err)
	_save(packed, SCENE_PATH)
	root.free()

	# ---------------------------------------------------------------- report
	log_lines.push_back("TERRAIN BAKE  seed %d" % world_seed)
	log_lines.push_back("")
	log_lines.push_back(
		(
			"grid                  %d x %d verts, axis [%.1f, %.1f] m"
			% [TerrainField.TN + 1, TerrainField.TN + 1, ax[0], ax[TerrainField.TN]]
		)
	)
	log_lines.push_back(
		(
			"cell size             %.2f m centre -> %.2f m rim"
			% [
				ax[TerrainField.TN / 2 + 1] - ax[TerrainField.TN / 2],
				ax[TerrainField.TN] - ax[TerrainField.TN - 1]
			]
		)
	)
	log_lines.push_back("height range          %.2f .. %.2f m" % [_min_of(hg), _max_of(hg)])
	log_lines.push_back("rock quads            %d of %d" % [_count_rock(qs), qs.size()])
	if layout == null:
		log_lines.push_back("road paint            NONE - no layout.res, map bakes unpaved")
	else:
		log_lines.push_back(
			(
				"road paint            %d roads, %d of %d verts painted"
				% [layout.road_lines.size(), _count_positive(vr), vr.size()]
			)
		)
	log_lines.push_back("")
	log_lines.push_back("chunks                %d x %d of %d quads" % [chunks, chunks, CHUNK_QUADS])
	for lod in LOD_STRIDES.size():
		log_lines.push_back(
			(
				"lod%d  stride %-2d      %6d tris  %7d verts  (%d per chunk)"
				% [
					lod,
					LOD_STRIDES[lod],
					tri_totals[lod],
					vert_totals[lod],
					tri_totals[lod] / (chunks * chunks)
				]
			)
		)
	log_lines.push_back(
		"collision             %d tris across %d shapes" % [collision_tris, chunks * chunks]
	)
	log_lines.push_back("")
	log_lines.push_back("degenerate tris       %d  (must be 0)" % degenerates)
	log_lines.push_back("downward faces        %d  (must be 0)" % downward)
	log_lines.push_back("seam faults           %d  (must be 0)" % seam_faults)
	for lod in LOD_STRIDES.size():
		log_lines.push_back(
			(
				"lod%d open edges       %d  (must be %d - the map rim)"
				% [lod, _count_single(edge_use[lod]), TerrainField.TN * 4]
			)
		)
	log_lines.push_back(
		(
			"normal agreement      worst %.4f rad between terrain_n and ground_normal"
			% _normal_disagreement(field)
		)
	)
	return log_lines


# ------------------------------------------------------------------- emission


## One chunk at one stride. `s == 1` emits the plain two-triangle quads the
## reference does; coarser strides fan every border cell out to the full-
## resolution boundary vertices so the chunk's outline never changes.
static func _emit_chunk(
	m: WorldMesher,
	field: TerrainField,
	vc: PackedColorArray,
	vr: PackedFloat32Array,
	qs: PackedByteArray,
	i0: int,
	j0: int,
	s: int
) -> void:
	var tn: int = TerrainField.TN
	var w: int = tn + 1
	var ax: PackedFloat32Array = field.axis()
	var hg: PackedFloat32Array = field.heights()
	if s == 1:
		for j in range(j0, j0 + CHUNK_QUADS):
			for i in range(i0, i0 + CHUNK_QUADS):
				var ka: int = j * w + i
				var kb: int = j * w + i + 1
				var kc: int = (j + 1) * w + i + 1
				var kd: int = (j + 1) * w + i
				var a := Vector3(ax[i], hg[ka], ax[j])
				var b := Vector3(ax[i + 1], hg[kb], ax[j])
				var c := Vector3(ax[i + 1], hg[kc], ax[j + 1])
				var d := Vector3(ax[i], hg[kd], ax[j + 1])
				var t: int = qs[j * tn + i]
				m.tri_v(a, d, c, vc[ka], vc[kd], vc[kc], vr[ka], vr[kd], vr[kc], t)
				m.tri_v(a, c, b, vc[ka], vc[kc], vc[kb], vr[ka], vr[kc], vr[kb], t)
		return

	var cells: int = CHUNK_QUADS / s
	for cj in cells:
		for ci in cells:
			var ia: int = i0 + ci * s
			var ib: int = ia + s
			var ja: int = j0 + cj * s
			var jb: int = ja + s
			var t: int = _coarse_type(qs, ia, ja, s)
			var on_border: bool = ci == 0 or cj == 0 or ci == cells - 1 or cj == cells - 1
			if not on_border:
				var ka: int = ja * w + ia
				var kb: int = ja * w + ib
				var kc: int = jb * w + ib
				var kd: int = jb * w + ia
				var a := Vector3(ax[ia], hg[ka], ax[ja])
				var b := Vector3(ax[ib], hg[kb], ax[ja])
				var c := Vector3(ax[ib], hg[kc], ax[jb])
				var d := Vector3(ax[ia], hg[kd], ax[jb])
				m.tri_v(a, d, c, vc[ka], vc[kd], vc[kc], vr[ka], vr[kd], vr[kc], t)
				m.tri_v(a, c, b, vc[ka], vc[kc], vc[kb], vr[ka], vr[kc], vr[kb], t)
				continue
			_fan_cell(
				m,
				field,
				vc,
				vr,
				ia,
				ja,
				ib,
				jb,
				ci == 0,
				cj == 0,
				ci == cells - 1,
				cj == cells - 1,
				t
			)


## Ring-fan a coarse cell whose named sides must carry full-resolution vertices.
##
## The ring is walked counter-clockwise seen from above — (i,j), (i,j+1),
## (i+1,j+1), (i+1,j) — which is the same order the full-resolution quads use, so
## the fan comes out facing up like everything else.
static func _fan_cell(
	m: WorldMesher,
	field: TerrainField,
	vc: PackedColorArray,
	vr: PackedFloat32Array,
	ia: int,
	ja: int,
	ib: int,
	jb: int,
	fine_min_i: bool,
	fine_min_j: bool,
	fine_max_i: bool,
	fine_max_j: bool,
	t: int
) -> void:
	var ring_p := PackedVector3Array()
	var ring_c := PackedColorArray()
	var ring_b := PackedFloat32Array()
	_walk(field, vc, vr, ring_p, ring_c, ring_b, ia, ja, ia, jb, fine_min_i)
	_walk(field, vc, vr, ring_p, ring_c, ring_b, ia, jb, ib, jb, fine_max_j)
	_walk(field, vc, vr, ring_p, ring_c, ring_b, ib, jb, ib, ja, fine_max_i)
	_walk(field, vc, vr, ring_p, ring_c, ring_b, ib, ja, ia, ja, fine_min_j)

	var w: int = TerrainField.TN + 1
	var ax: PackedFloat32Array = field.axis()
	var hg: PackedFloat32Array = field.heights()
	var ks: PackedInt32Array = [ja * w + ia, ja * w + ib, jb * w + ib, jb * w + ia]
	var centre := Vector3((ax[ia] + ax[ib]) * 0.5, 0.0, (ax[ja] + ax[jb]) * 0.5)
	var cc := Color(0.0, 0.0, 0.0)
	var cb: float = 0.0
	for k in ks:
		centre.y += hg[k] * FAN_CENTRE_WEIGHT
		cc += vc[k] * FAN_CENTRE_WEIGHT
		cb += vr[k] * FAN_CENTRE_WEIGHT
	cc.a = 1.0

	var n: int = ring_p.size()
	for e in n:
		var f: int = (e + 1) % n
		m.tri_v(centre, ring_p[e], ring_p[f], cc, ring_c[e], ring_c[f], cb, ring_b[e], ring_b[f], t)


## Append one side of a coarse cell's ring, excluding its final vertex (the next
## side supplies it). `fine` subdivides the side at every full-resolution grid
## point on it; otherwise the side is a single straight segment.
static func _walk(
	field: TerrainField,
	vc: PackedColorArray,
	vr: PackedFloat32Array,
	ring_p: PackedVector3Array,
	ring_c: PackedColorArray,
	ring_b: PackedFloat32Array,
	i_from: int,
	j_from: int,
	i_to: int,
	j_to: int,
	fine: bool
) -> void:
	var w: int = TerrainField.TN + 1
	var ax: PackedFloat32Array = field.axis()
	var hg: PackedFloat32Array = field.heights()
	var span_i: int = i_to - i_from
	var span_j: int = j_to - j_from
	var steps: int = 1
	if fine:
		steps = absi(span_i) + absi(span_j)
		span_i = signi(span_i)
		span_j = signi(span_j)
	for e in steps:
		var i: int = i_from + span_i * e
		var j: int = j_from + span_j * e
		var k: int = j * w + i
		ring_p.push_back(Vector3(ax[i], hg[k], ax[j]))
		ring_c.push_back(vc[k])
		ring_b.push_back(vr[k])


## Surface id of a coarse cell: the majority of the fine quads it swallows.
static func _coarse_type(qs: PackedByteArray, ia: int, ja: int, s: int) -> int:
	var tn: int = TerrainField.TN
	var rock: int = 0
	for j in range(ja, ja + s):
		for i in range(ia, ia + s):
			if qs[j * tn + i] == WorldSurface.Kind.ROCK:
				rock += 1
	return WorldSurface.Kind.ROCK if rock * 2 > s * s else WorldSurface.Kind.SAND


# ------------------------------------------------------------------ self-test


## Faces whose stored normal points down. A height field has none.
static func _count_downward(mesh: ArrayMesh) -> int:
	if mesh.get_surface_count() == 0:
		return 0
	var arrays: Array = mesh.surface_get_arrays(0)
	var nrm: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var bad: int = 0
	for n in nrm:
		if n.y <= 0.0:
			bad += 1
	return bad / 3


## Count how often every edge is used, keyed by interned vertex position. An edge
## used once is an open boundary; across a whole level only the map rim should be.
static func _tally_edges(use: Dictionary, ids: Dictionary, pos: PackedVector3Array) -> void:
	var tris: int = pos.size() / 3
	for t in tris:
		var a: int = _intern(ids, pos[t * 3])
		var b: int = _intern(ids, pos[t * 3 + 1])
		var c: int = _intern(ids, pos[t * 3 + 2])
		_bump(use, a, b)
		_bump(use, b, c)
		_bump(use, c, a)


static func _intern(ids: Dictionary, v: Vector3) -> int:
	if ids.has(v):
		return int(ids[v])
	var id: int = ids.size()
	ids[v] = id
	return id


static func _bump(use: Dictionary, a: int, b: int) -> void:
	var key: int = (mini(a, b) << 22) | maxi(a, b)
	use[key] = int(use.get(key, 0)) + 1


static func _count_single(use: Dictionary) -> int:
	var n: int = 0
	for v: int in use.values():
		if v == 1:
			n += 1
	return n


## Every triangle edge lying on a chunk's perimeter must be a full-resolution
## grid segment, at every level. Returns the number that are not.
##
## This is the LOD-crack proof: two neighbours can only crack if one of them puts
## a vertex on the shared line that the other does not have, or spans a segment
## the other subdivides.
static func _check_seam(pos: PackedVector3Array, field: TerrainField, i0: int, j0: int) -> int:
	var ax: PackedFloat32Array = field.axis()
	var x_lo: float = ax[i0]
	var x_hi: float = ax[i0 + CHUNK_QUADS]
	var z_lo: float = ax[j0]
	var z_hi: float = ax[j0 + CHUNK_QUADS]
	var fine_x := {}
	var fine_z := {}
	for e in CHUNK_QUADS + 1:
		fine_x[ax[i0 + e]] = true
		fine_z[ax[j0 + e]] = true
	var faults: int = 0
	var tris: int = pos.size() / 3
	for t in tris:
		for e in 3:
			var a: Vector3 = pos[t * 3 + e]
			var b: Vector3 = pos[t * 3 + (e + 1) % 3]
			var on_x: bool = (a.x == b.x) and (a.x == x_lo or a.x == x_hi)
			var on_z: bool = (a.z == b.z) and (a.z == z_lo or a.z == z_hi)
			if on_x:
				if not fine_z.has(a.z) or not fine_z.has(b.z):
					faults += 1
				elif _grid_gap(ax, j0, a.z, b.z) != 1:
					faults += 1
			elif on_z:
				if not fine_x.has(a.x) or not fine_x.has(b.x):
					faults += 1
				elif _grid_gap(ax, i0, a.x, b.x) != 1:
					faults += 1
	return faults


## How many full-resolution cells an edge on a perimeter line spans.
static func _grid_gap(ax: PackedFloat32Array, base: int, u: float, v: float) -> int:
	var iu: int = -1
	var iv: int = -1
	for e in CHUNK_QUADS + 1:
		if ax[base + e] == u:
			iu = e
		if ax[base + e] == v:
			iv = e
	return absi(iu - iv)


## Worst angle, in radians, between the analytic field normal and the normal of
## the mesh that got built from it. Large values mean the grid is undersampling.
static func _normal_disagreement(field: TerrainField) -> float:
	var worst: float = 0.0
	var step: float = 7.0
	var u: float = -400.0
	while u <= 400.0:
		var v: float = -400.0
		while v <= 400.0:
			var a: Vector3 = field.terrain_n(u, v)
			var b: Vector3 = field.ground_normal(u, v)
			worst = maxf(worst, a.angle_to(b))
			v += step
		u += step
	return worst


# ---------------------------------------------------------------------- misc


static func _min_of(a: PackedFloat32Array) -> float:
	var lo: float = INF
	for v in a:
		lo = minf(lo, v)
	return lo


static func _max_of(a: PackedFloat32Array) -> float:
	var hi: float = -INF
	for v in a:
		hi = maxf(hi, v)
	return hi


static func _count_rock(qs: PackedByteArray) -> int:
	var n: int = 0
	for v in qs:
		if v == WorldSurface.Kind.ROCK:
			n += 1
	return n


static func _count_positive(a: PackedFloat32Array) -> int:
	var n: int = 0
	for v in a:
		if v > 0.0:
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
		push_error("build_terrain: could not save %s (%d)" % [path, err])
