class_name WorldTerrainData
extends Resource
## The baked height field: the warped sampling axis, the 201x201 height grid, and
## the road and rock masks painted onto it.
##
## Filling this costs 40401 evaluations of `terrain_h`, each nine fbm calls deep.
## That is a bake, not a `_ready()`. Everything here is a table lookup.

## Sampling epsilon for `ground_normal`, metres.
const NORMAL_EPS: float = 1.2
## Beyond this |x| or |z| the road test is skipped outright.
const ROAD_BOUND_X: float = 175.0
const ROAD_BOUND_Z: float = 210.0
## Road paint above which the footing counts as asphalt.
const ROAD_SOLID: float = 0.5
## Bins in `ax_lut`.
const LUT_BINS: int = 2048

## Samples per axis, matching `TerrainField.TN`.
@export var tn: int = TerrainField.TN
## The warped axis, `tn + 1` entries spanning [-880, +880].
@export var ax: PackedFloat32Array = PackedFloat32Array()
## Height at every grid intersection, row-major, `(tn+1)^2` entries.
@export var heights: PackedFloat32Array = PackedFloat32Array()
## Road paint, 0 off the carriageway to 1 on it. Same layout as `heights`.
##
## This exists so nothing at runtime has to call `dist_to_road`, which is linear
## in the number of road segments and which the reference called on every
## footstep and every terrain raycast hit.
@export var road: PackedFloat32Array = PackedFloat32Array()
## Per-quad surface id, `tn^2` entries. Sand or rock, decided by slope and height
## at bake time exactly as the vertex colours were — so what you hear underfoot
## is what the shader draws. (The reference instead re-tested the ground normal
## per footstep, which disagrees with its own vertex colours by up to one quad
## along every rock margin and misses the mesa caps entirely.)
@export var quad_surface: PackedByteArray = PackedByteArray()
## Uniform-bin acceleration table for `ax_index`, `LUT_BINS + 1` entries.
##
## The warped axis is monotone but not uniform, so a lookup needs a search. The
## bins are 0.86 m wide, finer than the narrowest cell (3.70 m), so each bin
## falls inside one cell and the search collapses to one comparison. Movement
## calls `ground_normal` every substep, which is eight of these.
@export var ax_lut: PackedInt32Array = PackedInt32Array()
## The seed the whole map was rolled from. Recorded so a demo can assert it.
@export var world_seed: int = 0


func _row() -> int:
	return tn + 1


## Index of the axis cell containing `v`, clamped into range. Binary search;
## `ax_index` below prefers the baked table and falls back to this.
func ax_index_search(v: float) -> int:
	if v <= ax[0]:
		return 0
	if v >= ax[tn]:
		return tn - 1
	var lo: int = 0
	var hi: int = tn
	while hi - lo > 1:
		var m: int = (lo + hi) >> 1
		if ax[m] <= v:
			lo = m
		else:
			hi = m
	return lo


## Build `ax_lut`. Bake-time only; `ax` must already be filled.
func build_lut() -> void:
	ax_lut = PackedInt32Array()
	ax_lut.resize(LUT_BINS + 1)
	var span: float = ax[tn] - ax[0]
	for b in LUT_BINS + 1:
		ax_lut[b] = ax_index_search(ax[0] + span * float(b) / float(LUT_BINS))


## Index of the axis cell containing `v`. O(1) against the baked table.
func ax_index(v: float) -> int:
	if ax_lut.size() != LUT_BINS + 1:
		return ax_index_search(v)
	if v <= ax[0]:
		return 0
	if v >= ax[tn]:
		return tn - 1
	var b: int = int((v - ax[0]) / (ax[tn] - ax[0]) * float(LUT_BINS))
	if b < 0:
		b = 0
	elif b > LUT_BINS:
		b = LUT_BINS
	var i: int = ax_lut[b]
	while i < tn - 1 and ax[i + 1] <= v:
		i += 1
	return i


## Height on the rendered terrain surface. Split along the a-c diagonal, which is
## the diagonal the mesher emits — the reference interpolated the other one and
## let the player float by up to a metre on the coarse rim cells.
##
## Outside the sampled extent the edge value is held. There is no mesh out there,
## so extrapolating a height would only invent ground that is not drawn.
func ground_h(x: float, z: float) -> float:
	var i: int = ax_index(x)
	var j: int = ax_index(z)
	var w: int = _row()
	var s: float = clampf((x - ax[i]) / (ax[i + 1] - ax[i]), 0.0, 1.0)
	var t: float = clampf((z - ax[j]) / (ax[j + 1] - ax[j]), 0.0, 1.0)
	var h00: float = heights[j * w + i]
	var h10: float = heights[j * w + i + 1]
	var h01: float = heights[(j + 1) * w + i]
	var h11: float = heights[(j + 1) * w + i + 1]
	if t >= s:
		return h00 + (h01 - h00) * t + (h11 - h01) * s
	return h00 + (h10 - h00) * s + (h11 - h10) * t


## Terrain normal, sampled with a 1.2 m cross. Used for slope projection, slide
## acceleration, and for refusing to scatter props onto dune faces.
func ground_normal(x: float, z: float, e: float = NORMAL_EPS) -> Vector3:
	var hl: float = ground_h(x - e, z)
	var hr: float = ground_h(x + e, z)
	var hd: float = ground_h(x, z - e)
	var hu: float = ground_h(x, z + e)
	return Vector3(hl - hr, 2.0 * e, hd - hu).normalized()


## Baked road paint at a point, bilinear over the same grid as `ground_h`.
func road_at(x: float, z: float) -> float:
	if road.is_empty():
		return 0.0
	var i: int = ax_index(x)
	var j: int = ax_index(z)
	var w: int = _row()
	var s: float = clampf((x - ax[i]) / (ax[i + 1] - ax[i]), 0.0, 1.0)
	var t: float = clampf((z - ax[j]) / (ax[j + 1] - ax[j]), 0.0, 1.0)
	var r00: float = road[j * w + i]
	var r10: float = road[j * w + i + 1]
	var r01: float = road[(j + 1) * w + i]
	var r11: float = road[(j + 1) * w + i + 1]
	return lerpf(lerpf(r00, r10, s), lerpf(r01, r11, s), t)


## Surface id of the quad containing (x, z) — the id the shader is branching on
## for the triangle you are standing on.
func quad_surface_at(x: float, z: float) -> int:
	if quad_surface.size() != tn * tn:
		return WorldSurface.Kind.SAND
	return quad_surface[ax_index(z) * tn + ax_index(x)]


## What the ground underfoot is made of. Two table lookups.
##
## The reference tested |z| < 205 here and |z| < 210 when it painted the road,
## leaving a five-metre strip that looked like asphalt and sounded like sand;
## both use 210 here.
func surface_at_ground(x: float, z: float) -> int:
	if absf(x) < ROAD_BOUND_X and absf(z) < ROAD_BOUND_Z and road_at(x, z) > ROAD_SOLID:
		return WorldSurface.Kind.ASPHALT
	return quad_surface_at(x, z)


## Ray against the height field, marched at 1.4 m then bisected eight times.
## Returns the distance, or `max_d` for a miss.
func raycast_terrain(origin: Vector3, dir: Vector3, max_d: float) -> float:
	var step_len: float = 1.4
	var prev: float = origin.y - ground_h(origin.x, origin.z)
	var d: float = step_len
	while d < max_d:
		var h: float = origin.y + dir.y * d - ground_h(origin.x + dir.x * d, origin.z + dir.z * d)
		if h <= 0.0 and prev > 0.0:
			var lo: float = d - step_len
			var hi: float = d
			for _k in 8:
				var m: float = (lo + hi) * 0.5
				var hm: float = (
					origin.y + dir.y * m - ground_h(origin.x + dir.x * m, origin.z + dir.z * m)
				)
				if hm <= 0.0:
					hi = m
				else:
					lo = m
			return hi
		prev = h
		d += step_len
	return max_d
