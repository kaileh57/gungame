extends RefCounted
## Where the loose gear on the flats goes, and how it is grouped for culling.
##
## BAKE-TIME ONLY. `tools/build_ash_flats.gd` is the only caller.
##
## Two jobs, and they are the same job seen from either end. The sampler draws
## rejection-sampled placements from the rules below, honouring the distance
## bands, the road corridors, the slope limit, the building footprints and the
## minimum spacing between two of a kind. The grid sizer then decides how coarse
## a cell each kind is batched into, which is what makes a visibility range worth
## setting: one multimesh spanning the map is all-drawn or all-culled.
##
## Everything here is static and draws from a caller-supplied `XorShift32`, so the
## scatter is byte-identical between runs.

## Smallest edge of a scatter cell, metres. One `MultiMeshInstance3D` and one
## static body per cell per prop kind, so distance culling has something to cull.
##
## A fixed grid is wrong here because the kinds do not share a density. Barrels
## crowd a 12-150 m band around the town; rock clusters are 130 pieces smeared
## over a 150-620 m annulus. At one cell size the first batches 11 to a draw call
## and the second batches 1.5, which is not instancing, it is a MeshInstance3D
## with extra steps. So each kind grows its own grid -- see `cell_for`.
const CELL_MIN: float = 96.0
## Instances per cell the sizer wants before it stops doubling a kind's grid.
const TARGET_PER_CELL: int = 16
## Steepest ground a prop will stand on, as the cosine of the slope.
const MAX_SLOPE_COS: float = 0.92
## Candidates drawn per placement before the sampler gives up on that prop.
const MAX_TRIES: int = 40

## The scatter rules, one row per prop kind. Columns: prop id, target count, band
## from the town centre, band to the nearest carriageway edge, spacing between two
## of the same kind, and the range past which a cell stops drawing — all metres.
## The bands are the shape of the settlement: everything a scavenger would have
## dragged sits inside 150 m of the plaza and within sight of a road, and the
## rocks and dead trees start where the streets stop.
const SCATTER: Array[Array] = [
	[&"barrel", 150, Vector2(12.0, 150.0), Vector2(1.6, 16.0), 3.0, 140.0],
	[&"crate", 110, Vector2(12.0, 150.0), Vector2(1.8, 14.0), 3.4, 140.0],
	[&"big_crate", 46, Vector2(14.0, 140.0), Vector2(2.4, 13.0), 6.0, 170.0],
	[&"sandbags", 90, Vector2(10.0, 150.0), Vector2(1.4, 10.0), 2.6, 120.0],
	[&"wreck", 34, Vector2(18.0, 190.0), Vector2(2.0, 9.0), 14.0, 240.0],
	[&"containers", 22, Vector2(24.0, 170.0), Vector2(4.0, 22.0), 18.0, 300.0],
	[&"rock_cluster", 130, Vector2(150.0, 620.0), Vector2(9.0, 1.0e9), 26.0, 520.0],
	[&"dead_tree", 120, Vector2(90.0, 560.0), Vector2(5.0, 1.0e9), 14.0, 300.0],
]
## Column indices into a `SCATTER` row.
const S_ID: int = 0
const S_COUNT: int = 1
const S_BAND: int = 2
const S_ROAD: int = 3
const S_SPACING: int = 4
const S_SIGHT: int = 5

## Roof clutter goes on decks rather than on the ground, so it has its own rule.
const ROOF_CLUTTER_ID: StringName = &"roof_clutter"
## Smallest roof worth cluttering, metres on its short side.
const ROOF_MIN_SIDE: float = 5.5
## Fraction of eligible roofs that get a piece.
const ROOF_SHARE: float = 0.55
const ROOF_SIGHT: float = 180.0


## Rejection-sample every scatter rule. Returns id -> Array[Transform3D].
static func place(query: WorldQuery, props: WorldPropSet, rng: XorShift32) -> Dictionary:
	var out: Dictionary = {}
	for rule: Array in SCATTER:
		var id: StringName = rule[S_ID]
		var asset: WorldPropAsset = props.asset(id)
		if asset == null:
			continue
		var band: Vector2 = rule[S_BAND]
		var road: Vector2 = rule[S_ROAD]
		var spacing: float = float(rule[S_SPACING])
		var clearance: float = maxf(asset.bounds.size.y, 1.0) + 0.25
		var radius: float = maxf(asset.bounds.size.x, asset.bounds.size.z) * 0.5
		var grid: Dictionary = {}
		var placed: Array[Transform3D] = []
		for _i: int in int(rule[S_COUNT]):
			var t: Transform3D = _try_place(
				query, rng, grid, band, road, spacing, clearance, radius
			)
			if t != Transform3D.IDENTITY:
				placed.append(t)
		out[id] = placed
	return out


## One placement, or the identity transform when the sampler ran out of tries. The
## identity is never legal here — every band excludes the plaza — so it is a safe sentinel.
static func _try_place(
	query: WorldQuery,
	rng: XorShift32,
	grid: Dictionary,
	band: Vector2,
	road: Vector2,
	spacing: float,
	clearance: float,
	radius: float
) -> Transform3D:
	var layout: WorldLayoutData = query.layout
	for _try: int in MAX_TRIES:
		var ang: float = rng.next() * TAU
		# Square-rooted radius keeps the density even over the annulus instead of
		# piling everything against the inner edge.
		var t: float = sqrt(rng.next())
		var r: float = band.x + (band.y - band.x) * t
		var x: float = cos(ang) * r
		var z: float = sin(ang) * r
		var d_road: float = layout.dist_to_road(x, z)
		if d_road < road.x or d_road > road.y:
			continue
		if query.ground_normal(x, z).y < MAX_SLOPE_COS:
			continue
		if _inside_building(layout, x, z, radius + 0.8):
			continue
		var g: float = query.ground_h(x, z)
		if not query.can_stand(x, z, g, clearance):
			continue
		if not _claim(grid, x, z, spacing):
			continue
		var basis := Basis(Vector3.UP, rng.next() * TAU)
		return Transform3D(basis, Vector3(x, g, z))
	return Transform3D.IDENTITY


## Spacing test against a hash grid whose cell is the spacing itself, so only the
## nine neighbouring cells can hold a conflict.
static func _claim(grid: Dictionary, x: float, z: float, spacing: float) -> bool:
	var cell: float = maxf(spacing, 0.25)
	var cx: int = int(floor(x / cell))
	var cz: int = int(floor(z / cell))
	for ox: int in [-1, 0, 1]:
		for oz: int in [-1, 0, 1]:
			var key := Vector2i(cx + ox, cz + oz)
			if not grid.has(key):
				continue
			for p: Vector2 in grid[key]:
				if Vector2(x, z).distance_squared_to(p) < spacing * spacing:
					return false
	var home := Vector2i(cx, cz)
	if not grid.has(home):
		grid[home] = []
	(grid[home] as Array).append(Vector2(x, z))
	return true


## True when (x, z) is inside any building footprint grown by `margin`.
static func _inside_building(layout: WorldLayoutData, x: float, z: float, margin: float) -> bool:
	for i: int in layout.building_count():
		var c: Vector3 = layout.building_pos[i]
		var s: Vector2 = layout.building_size[i]
		var half_x: float = s.x * 0.5 + margin
		var half_z: float = s.y * 0.5 + margin
		var dx: float = x - c.x
		var dz: float = z - c.z
		var rough: float = half_x + half_z
		if dx * dx + dz * dz > rough * rough:
			continue
		var ry: float = layout.building_yaw[i]
		var co: float = cos(ry)
		var si: float = sin(ry)
		if absf(dx * co - dz * si) <= half_x and absf(dx * si + dz * co) <= half_z:
			return true
	return false


## Rubbish on the roofs that have a deck: aerials, water drums, a folded awning.
## Placed at the deck height the town bake recorded, so nothing floats.
static func roof_clutter(
	layout: WorldLayoutData, props: WorldPropSet, rng: XorShift32
) -> Array[Transform3D]:
	var placed: Array[Transform3D] = []
	if props.asset(ROOF_CLUTTER_ID) == null:
		return placed
	for i: int in layout.building_count():
		var kind: int = layout.building_kind[i]
		if (
			kind == WorldLayoutData.Kind.RUIN
			or kind == WorldLayoutData.Kind.MARKET
			or kind == WorldLayoutData.Kind.TOWER
		):
			continue
		var s: Vector2 = layout.building_size[i]
		if minf(s.x, s.y) < ROOF_MIN_SIDE:
			continue
		if rng.next() > ROOF_SHARE:
			continue
		var c: Vector3 = layout.building_pos[i]
		var ry: float = layout.building_yaw[i]
		var lx: float = (rng.next() - 0.5) * s.x * 0.45
		var lz: float = (rng.next() - 0.5) * s.y * 0.45
		var co: float = cos(ry)
		var si: float = sin(ry)
		var pos := Vector3(c.x + lx * co + lz * si, c.y, c.z - lx * si + lz * co)
		placed.append(Transform3D(Basis(Vector3.UP, ry + (rng.next() - 0.5) * 0.9), pos))
	return placed


## Buckets placements onto a `cell`-metre grid, keyed by cell coordinate.
static func bucket(transforms: Array[Transform3D], cell: float) -> Dictionary:
	var cells: Dictionary = {}
	for t: Transform3D in transforms:
		var key := Vector2i(int(floor(t.origin.x / cell)), int(floor(t.origin.z / cell)))
		if not cells.has(key):
			cells[key] = []
		(cells[key] as Array).append(t)
	return cells


## Picks a grid edge for one prop kind: the smallest power-of-two multiple of
## `CELL_MIN` that batches `TARGET_PER_CELL` instances into a draw call, without
## letting a cell grow past the distance at which the kind is culled. That bound
## is the point -- a cell wider than its own `sight` can never be culled as a
## unit, so growing further would trade away the culling that justified the grid.
static func cell_for(transforms: Array[Transform3D], sight: float) -> float:
	var cell: float = CELL_MIN
	while cell * 2.0 <= sight:
		var used: int = bucket(transforms, cell).size()
		if float(transforms.size()) / float(maxi(used, 1)) >= float(TARGET_PER_CELL):
			break
		cell *= 2.0
	return cell
