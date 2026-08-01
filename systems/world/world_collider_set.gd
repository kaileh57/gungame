class_name WorldColliderSet
extends Resource
## The world's collision, as a flat array of yaw-rotated boxes in a 9 m spatial
## hash. Baked once; never rebuilt at runtime.
##
## This is deliberately not a pile of Godot physics bodies. The reference's
## movement rules — the step-up, the vault, the slide, the ladder volume — are
## written against exactly these semantics, one array walk per frame with zero
## allocation, and they do not survive being handed to a solver. The bake also
## emits real `StaticBody3D` trimesh geometry for Jolt so that bullets, grenades
## and enemy bodies still collide the ordinary way; the two are generated from
## the same boxes and therefore agree.
##
## Everything below is allocation-free after `prepare()`.

## Broadphase cell size, metres.
const CELL: float = 9.0
## Vertical slack `can_stand` allows before a box counts as blocking.
const STAND_SLACK: float = 0.04
## How far below the terrain the feet may be before `can_stand` gives up.
const GROUND_SLACK: float = 0.05
## Extra radius `can_stand` pads its broadphase query by.
const STAND_QUERY_PAD: float = 1.2
## Broadphase radius `top_at` uses, and the probe radius it tests overlap with.
const TOP_QUERY_R: float = 1.0
const TOP_PROBE_R: float = 0.06
## Cells the ray DDA is allowed to visit before it gives up. 90 x 9 m = 810 m.
const DDA_GUARD: int = 90

@export var centers: PackedVector3Array = PackedVector3Array()
@export var halves: PackedVector3Array = PackedVector3Array()
@export var yaws: PackedFloat32Array = PackedFloat32Array()
@export var surfaces: PackedByteArray = PackedByteArray()
## Teschner hash cell -> indices. Keys are int, values are PackedInt32Array.
@export var grid: Dictionary = {}

## Filled by the last `circle_box` that returned a hit: depth, then the outward
## push direction in world XZ.
var pen_depth: float = 0.0
var pen_nx: float = 0.0
var pen_nz: float = 0.0
## Filled by the last `raycast_boxes`.
var hit_surface: int = 0

var _co: PackedFloat32Array = PackedFloat32Array()
var _si: PackedFloat32Array = PackedFloat32Array()
var _stamp: PackedInt32Array = PackedInt32Array()
var _stamp_id: int = 0
var _hits: PackedInt32Array = PackedInt32Array()
var _ready: bool = false


func size() -> int:
	return yaws.size()


## Classic Teschner hash. JS coerces the xor to int32; the mask keeps the two
## implementations agreeing on bucket membership, which is all that matters.
static func grid_key(i: int, j: int) -> int:
	return ((i * 73856093) ^ (j * 19349663)) & 0xFFFFFFFF


# ------------------------------------------------------------------- bake side


## Append one collider and index it. Bake-time only.
func add_box(center: Vector3, half: Vector3, ry: float, surf: int) -> int:
	var hx: float = absf(half.x)
	var hy: float = absf(half.y)
	var hz: float = absf(half.z)
	var idx: int = yaws.size()
	centers.push_back(center)
	halves.push_back(Vector3(hx, hy, hz))
	yaws.push_back(ry)
	surfaces.push_back(surf)

	var co: float = absf(cos(ry))
	var si: float = absf(sin(ry))
	var ax: float = co * hx + si * hz
	var az: float = si * hx + co * hz
	var i0: int = floori((center.x - ax) / CELL)
	var i1: int = floori((center.x + ax) / CELL)
	var j0: int = floori((center.z - az) / CELL)
	var j1: int = floori((center.z + az) / CELL)
	for i in range(i0, i1 + 1):
		for j in range(j0, j1 + 1):
			var k: int = grid_key(i, j)
			var bucket: PackedInt32Array = grid.get(k, PackedInt32Array())
			bucket.push_back(idx)
			grid[k] = bucket
	_ready = false
	return idx


# ---------------------------------------------------------------- runtime side


## Build the trig and scratch tables. Idempotent; called lazily by every query.
func prepare() -> void:
	if _ready:
		return
	var n: int = yaws.size()
	_co.resize(n)
	_si.resize(n)
	for i in n:
		_co[i] = cos(yaws[i])
		_si[i] = sin(yaws[i])
	_stamp.resize(n)
	_stamp.fill(0)
	_stamp_id = 0
	_hits.resize(0)
	_ready = true


## Colliders whose conservative footprint touches the circle (x, z, r). The
## returned array is a shared scratch buffer — read it before the next query.
func query(x: float, z: float, r: float) -> PackedInt32Array:
	prepare()
	_hits.resize(0)
	_stamp_id += 1
	var i0: int = floori((x - r) / CELL)
	var i1: int = floori((x + r) / CELL)
	var j0: int = floori((z - r) / CELL)
	var j1: int = floori((z + r) / CELL)
	for i in range(i0, i1 + 1):
		for j in range(j0, j1 + 1):
			var bucket: PackedInt32Array = grid.get(grid_key(i, j), PackedInt32Array())
			for idx in bucket:
				if _stamp[idx] == _stamp_id:
					continue
				_stamp[idx] = _stamp_id
				_hits.push_back(idx)
	return _hits


## Circle-versus-oriented-rectangle in XZ. Returns true on overlap and leaves the
## penetration depth and outward normal in `pen_depth` / `pen_nx` / `pen_nz`.
func circle_box(px: float, pz: float, r: float, idx: int) -> bool:
	var c: Vector3 = centers[idx]
	var h: Vector3 = halves[idx]
	var co: float = _co[idx]
	var si: float = _si[idx]
	var dx: float = px - c.x
	var dz: float = pz - c.z
	var lx: float = dx * co - dz * si
	var lz: float = dx * si + dz * co
	var ox: float = lx - clampf(lx, -h.x, h.x)
	var oz: float = lz - clampf(lz, -h.z, h.z)
	var d2: float = ox * ox + oz * oz
	if d2 > r * r:
		return false
	if d2 > 1.0e-9:
		var d: float = sqrt(d2)
		pen_depth = r - d
		ox /= d
		oz /= d
	else:
		# Dead centre inside the rectangle: push out the short way.
		var px1: float = h.x - absf(lx)
		var pz1: float = h.z - absf(lz)
		if px1 < pz1:
			ox = signf(lx)
			if ox == 0.0:
				ox = 1.0
			oz = 0.0
			pen_depth = px1 + r
		else:
			ox = 0.0
			oz = signf(lz)
			if oz == 0.0:
				oz = 1.0
			pen_depth = pz1 + r
	pen_nx = ox * co + oz * si
	pen_nz = -ox * si + oz * co
	return true


## Same transform, boolean only.
func overlaps_xz(px: float, pz: float, r: float, idx: int) -> bool:
	var c: Vector3 = centers[idx]
	var h: Vector3 = halves[idx]
	var dx: float = px - c.x
	var dz: float = pz - c.z
	var lx: float = dx * _co[idx] - dz * _si[idx]
	var lz: float = dx * _si[idx] + dz * _co[idx]
	var ox: float = lx - clampf(lx, -h.x, h.x)
	var oz: float = lz - clampf(lz, -h.z, h.z)
	return ox * ox + oz * oz <= r * r


## Slab test against one box. Returns the entry distance, 0 when the origin is
## already inside, or -1 for a miss.
func ray_box(origin: Vector3, dir: Vector3, idx: int) -> float:
	var c: Vector3 = centers[idx]
	var h: Vector3 = halves[idx]
	var co: float = _co[idx]
	var si: float = _si[idx]
	var px: float = origin.x - c.x
	var pz: float = origin.z - c.z
	var o := Vector3(px * co - pz * si, origin.y - c.y, px * si + pz * co)
	var u := Vector3(dir.x * co - dir.z * si, dir.y, dir.x * si + dir.z * co)
	var t0: float = -1.0e9
	var t1: float = 1.0e9
	for axis in 3:
		var oo: float = o[axis]
		var dd: float = u[axis]
		var hh: float = h[axis]
		if absf(dd) < 1.0e-8:
			if oo < -hh or oo > hh:
				return -1.0
			continue
		var a: float = (-hh - oo) / dd
		var b: float = (hh - oo) / dd
		if a > b:
			var s: float = a
			a = b
			b = s
		t0 = maxf(t0, a)
		t1 = minf(t1, b)
		if t0 > t1:
			return -1.0
	if t0 > 0.0:
		return t0
	return 0.0 if t1 > 0.0 else -1.0


## Nearest box hit along a ray, by 2-D DDA over the broadphase. Returns the
## distance or `max_d` for a miss, leaving the surface id in `hit_surface`.
##
## The DDA does not de-duplicate: a box spanning several cells is tested once per
## cell. Nearest-hit-wins makes that harmless, and it is why the guard is small.
func raycast_boxes(origin: Vector3, dir: Vector3, max_d: float) -> float:
	prepare()
	var best: float = max_d
	hit_surface = WorldSurface.Kind.SAND
	var cx: int = floori(origin.x / CELL)
	var cz: int = floori(origin.z / CELL)
	var step_x: int = 1 if dir.x > 0.0 else -1
	var step_z: int = 1 if dir.z > 0.0 else -1
	var big: float = 1.0e9
	var td_x: float = big if absf(dir.x) < 1.0e-8 else absf(CELL / dir.x)
	var td_z: float = big if absf(dir.z) < 1.0e-8 else absf(CELL / dir.z)
	var tm_x: float = big
	var tm_z: float = big
	if absf(dir.x) >= 1.0e-8:
		tm_x = (float(cx + (1 if dir.x > 0.0 else 0)) * CELL - origin.x) / dir.x
	if absf(dir.z) >= 1.0e-8:
		tm_z = (float(cz + (1 if dir.z > 0.0 else 0)) * CELL - origin.z) / dir.z
	var t: float = 0.0
	var guard: int = 0
	while t < best and guard < DDA_GUARD:
		guard += 1
		var bucket: PackedInt32Array = grid.get(grid_key(cx, cz), PackedInt32Array())
		for idx in bucket:
			var h: float = ray_box(origin, dir, idx)
			if h >= 0.0 and h < best:
				best = h
				hit_surface = surfaces[idx]
		if tm_x < tm_z:
			t = tm_x
			tm_x += td_x
			cx += step_x
		else:
			t = tm_z
			tm_z += td_z
			cz += step_z
	return best


## Highest solid top at (x, z) within [lo, hi], ignoring the terrain. Returns NAN
## when nothing qualifies — valid tops are routinely negative, so -INF is not a
## safe sentinel.
func top_at(x: float, z: float, lo: float, hi: float) -> float:
	var best: float = NAN
	for idx in query(x, z, TOP_QUERY_R):
		var t: float = centers[idx].y + halves[idx].y
		if t < lo or t > hi:
			continue
		if not overlaps_xz(x, z, TOP_PROBE_R, idx):
			continue
		if is_nan(best) or t > best:
			best = t
	return best


## Is there room for a body `h` tall with its feet at `y`, ignoring the terrain?
func clear_above(x: float, z: float, y: float, h: float, r: float) -> bool:
	for idx in query(x, z, r + STAND_QUERY_PAD):
		var cy: float = centers[idx].y
		var hy: float = halves[idx].y
		if cy + hy <= y + STAND_SLACK or cy - hy >= y + h - STAND_SLACK:
			continue
		if overlaps_xz(x, z, r, idx):
			return false
	return true
