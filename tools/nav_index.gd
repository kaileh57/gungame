extends RefCounted
## A flat XZ bucket grid over a navigation mesh's polygons, in world space.
##
## Answers "what walkable heights exist at (x, z)" in constant time. That is the
## whole primitive the ledge discovery is built out of.
##
## Shared by `tools/bake_nav_links.gd`, which builds link sets out of it, and by
## `tools/verify_ai_traversal.gd`, which needs the same "what is walkable here"
## answer to draw roof goals. It lived inside the bake tool, and the harness
## preloaded an entire `SceneTree` bake script to borrow one class off it.
##
## Deliberately NO `class_name`. A global class name is only resolvable once the
## editor has scanned the project into its class cache, and both users of this
## file run under `--script`, where a freshly added one is not there yet: the
## harness died on "Could not find type AINavIndex". Both preload it and name the
## type off the preloaded const, which needs no cache at all.

## XZ cell of the lookup grid, metres.
const INDEX_CELL: float = 4.0

var polys: Array[PackedVector3Array] = []
var buckets: Dictionary = {}
var bounds: AABB = AABB()
## Connected-component label per entry in `polys`, filled by `label()`.
var comps: PackedInt32Array = PackedInt32Array()


## Which walkable island a point belongs to, or -1 when it is on none.
func component_at(p: Vector3) -> int:
	if comps.is_empty():
		return -1
	var key: int = floori(p.x / INDEX_CELL) * 100003 + floori(p.z / INDEX_CELL)
	if not buckets.has(key):
		return -1
	var best: int = -1
	var best_d: float = INF
	for row: int in buckets[key] as PackedInt32Array:
		var poly: PackedVector3Array = polys[row]
		if not _contains(poly, p.x, p.z):
			continue
		var d: float = absf(_plane_y(poly, p.x, p.z) - p.y)
		if d < best_d:
			best_d = d
			best = comps[row]
	return best


func build(navmesh: NavigationMesh, xform: Transform3D) -> void:
	var verts: PackedVector3Array = navmesh.get_vertices()
	var first: bool = true
	for p: int in navmesh.get_polygon_count():
		var idx: PackedInt32Array = navmesh.get_polygon(p)
		var poly := PackedVector3Array()
		var lo := Vector2(INF, INF)
		var hi := Vector2(-INF, -INF)
		for i: int in idx:
			var v: Vector3 = xform * verts[i]
			poly.push_back(v)
			lo = Vector2(minf(lo.x, v.x), minf(lo.y, v.z))
			hi = Vector2(maxf(hi.x, v.x), maxf(hi.y, v.z))
			if first:
				bounds = AABB(v, Vector3.ZERO)
				first = false
			else:
				bounds = bounds.expand(v)
		if poly.size() < 3:
			continue
		var row: int = polys.size()
		polys.push_back(poly)
		for cx: int in range(floori(lo.x / INDEX_CELL), floori(hi.x / INDEX_CELL) + 1):
			for cz: int in range(floori(lo.y / INDEX_CELL), floori(hi.y / INDEX_CELL) + 1):
				var key: int = cx * 100003 + cz
				if not buckets.has(key):
					buckets[key] = PackedInt32Array()
				var arr: PackedInt32Array = buckets[key]
				arr.push_back(row)
				buckets[key] = arr


## Walkable height at (x, z) nearest `near_y`, or NAN when there is none.
func height_at(x: float, z: float, near_y: float) -> float:
	var key: int = floori(x / INDEX_CELL) * 100003 + floori(z / INDEX_CELL)
	if not buckets.has(key):
		return NAN
	var best: float = NAN
	var best_d: float = INF
	for row: int in buckets[key] as PackedInt32Array:
		var poly: PackedVector3Array = polys[row]
		if not _contains(poly, x, z):
			continue
		var y: float = _plane_y(poly, x, z)
		var d: float = absf(y - near_y)
		if d < best_d:
			best_d = d
			best = y
	return best


## Every walkable height at (x, z), lowest first.
##
## This is what makes "upper level" mean something. A town on rolling terrain
## has navmesh from -5 m to +19 m and none of that says which of it is a roof;
## a point with a second walkable surface under it does.
func stack_at(x: float, z: float) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	var key: int = floori(x / INDEX_CELL) * 100003 + floori(z / INDEX_CELL)
	if not buckets.has(key):
		return out
	for row: int in buckets[key] as PackedInt32Array:
		var poly: PackedVector3Array = polys[row]
		if _contains(poly, x, z):
			out.push_back(_plane_y(poly, x, z))
	out.sort()
	return out


## Convex point-in-polygon in XZ. Recast emits convex polygons, so one
## consistent sign across every edge is the whole test.
static func _contains(poly: PackedVector3Array, x: float, z: float) -> bool:
	var n: int = poly.size()
	var sign_seen: int = 0
	for i: int in n:
		var a: Vector3 = poly[i]
		var b: Vector3 = poly[(i + 1) % n]
		var cross: float = (b.x - a.x) * (z - a.z) - (b.z - a.z) * (x - a.x)
		if absf(cross) < 1e-7:
			continue
		var s: int = 1 if cross > 0.0 else -1
		if sign_seen == 0:
			sign_seen = s
		elif s != sign_seen:
			return false
	return true


## Height of the polygon's plane at (x, z), fitted through its first three
## vertices. A detail-meshed polygon is near planar; the residual is millimetres.
static func _plane_y(poly: PackedVector3Array, x: float, z: float) -> float:
	var a: Vector3 = poly[0]
	var b: Vector3 = poly[1]
	var c: Vector3 = poly[2]
	var normal: Vector3 = (b - a).cross(c - a)
	if absf(normal.y) < 1e-5:
		return a.y
	return a.y - (normal.x * (x - a.x) + normal.z * (z - a.z)) / normal.y
