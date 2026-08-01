extends RefCounted
## The bestiary hall's two primitives — a closed box and a closed cylinder — plus
## the shell audit every one of them has to pass before it is handed back.
##
## Cached by size. Twelve plinths share one `ArrayMesh` resource and are checked
## once, which is both the draw-call saving and the reason `shells` counts unique
## shells rather than placements.
##
## Findings are collected rather than printed. The caller drains `problems` into
## its own report so a geometry failure reads in the same voice as a scene one.

## Cylinder segments. Twelve is round enough at hall distance.
const SEGMENTS: int = 12
## Weld tolerance for the boundary-edge census, in metres.
const WELD: float = 0.00005
## Below this a triangle has no area and is a defect, not a sliver.
const AREA_EPS: float = 1.0e-12

## Unique shells built and audited so far.
var shells: int = 0
## One line per shell that failed the audit. Empty means every shell is closed
## and outward.
var problems: PackedStringArray = PackedStringArray()

var _cache: Dictionary = {}


## A closed box on its own origin: six quads, per-face normals, non-indexed,
## outward wound so a triangle's normal is `(b-a).cross(c-a)`.
func box(size: Vector3) -> ArrayMesh:
	var key: String = "b%.5f,%.5f,%.5f" % [size.x, size.y, size.z]
	if _cache.has(key):
		return _cache[key]
	var h: Vector3 = size * 0.5
	var v := PackedVector3Array()
	var n := PackedVector3Array()
	var faces: Array[Array] = [
		[Vector3.RIGHT, Vector3.UP, Vector3.BACK],
		[Vector3.LEFT, Vector3.BACK, Vector3.UP],
		[Vector3.UP, Vector3.BACK, Vector3.RIGHT],
		[Vector3.DOWN, Vector3.RIGHT, Vector3.BACK],
		[Vector3.BACK, Vector3.RIGHT, Vector3.UP],
		[Vector3.FORWARD, Vector3.UP, Vector3.RIGHT],
	]
	for face: Array in faces:
		var normal: Vector3 = face[0]
		var t1: Vector3 = face[1]
		var t2: Vector3 = face[2]
		var centre: Vector3 = normal * (normal.abs() * h).length()
		var a: Vector3 = t1 * (t1.abs() * h).length()
		var b: Vector3 = t2 * (t2.abs() * h).length()
		tri(v, n, centre - a - b, centre + a - b, centre + a + b, normal)
		tri(v, n, centre - a - b, centre + a + b, centre - a + b, normal)
	var mesh: ArrayMesh = commit(v, n)
	_cache[key] = mesh
	return mesh


## A closed cylinder about Y, both caps fanned from a centre vertex so the shell
## has no boundary edge.
func cylinder(radius: float, height: float) -> ArrayMesh:
	var key: String = "c%.5f,%.5f" % [radius, height]
	if _cache.has(key):
		return _cache[key]
	var v := PackedVector3Array()
	var n := PackedVector3Array()
	var top: float = height * 0.5
	for i: int in SEGMENTS:
		var a0: float = TAU * float(i) / float(SEGMENTS)
		var a1: float = TAU * float(i + 1) / float(SEGMENTS)
		var d0 := Vector3(cos(a0), 0.0, sin(a0))
		var d1 := Vector3(cos(a1), 0.0, sin(a1))
		var b0: Vector3 = d0 * radius - Vector3(0.0, top, 0.0)
		var t0: Vector3 = d0 * radius + Vector3(0.0, top, 0.0)
		var b1: Vector3 = d1 * radius - Vector3(0.0, top, 0.0)
		var t1: Vector3 = d1 * radius + Vector3(0.0, top, 0.0)
		var fn: Vector3 = (d0 + d1).normalized()
		tri(v, n, b0, t0, t1, fn)
		tri(v, n, b0, t1, b1, fn)
		tri(v, n, Vector3(0.0, top, 0.0), t1, t0, Vector3.UP)
		tri(v, n, Vector3(0.0, -top, 0.0), b0, b1, Vector3.DOWN)
	var mesh: ArrayMesh = commit(v, n)
	_cache[key] = mesh
	return mesh


func tri(
	v: PackedVector3Array,
	n: PackedVector3Array,
	a: Vector3,
	b: Vector3,
	c: Vector3,
	normal: Vector3
) -> void:
	# a, c, b: callers wind counter-clockwise, Godot's front face is CLOCKWISE.
	v.push_back(a)
	v.push_back(c)
	v.push_back(b)
	n.push_back(normal)
	n.push_back(normal)
	n.push_back(normal)


## Seals a vertex/normal pair into a one-surface mesh and audits it on the way
## out. Nothing leaves this file unchecked.
func commit(v: PackedVector3Array, n: PackedVector3Array) -> ArrayMesh:
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = v
	arrays[Mesh.ARRAY_NORMAL] = n
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	_check(v)
	return mesh


## Divergence-theorem volume about the centroid plus a welded edge census. Under
## Godot's clockwise front face an outward closed shell has NEGATIVE volume and
## uses every edge twice; positive volume means the shell is inside out.
func _check(v: PackedVector3Array) -> void:
	shells += 1
	var count: int = v.size() / 3
	var centroid := Vector3.ZERO
	for p: Vector3 in v:
		centroid += p
	centroid /= float(v.size())

	var volume: float = 0.0
	var degenerate: int = 0
	var edges: Dictionary = {}
	for t: int in count:
		var a: Vector3 = v[t * 3] - centroid
		var b: Vector3 = v[t * 3 + 1] - centroid
		var c: Vector3 = v[t * 3 + 2] - centroid
		volume += a.dot(b.cross(c))
		if (b - a).cross(c - a).length() < AREA_EPS:
			degenerate += 1
		for e: int in 3:
			var p: String = _key(v[t * 3 + e])
			var q: String = _key(v[t * 3 + (e + 1) % 3])
			var key: String = p + "|" + q if p < q else q + "|" + p
			var dir: int = 1 if p < q else -1
			edges[key] = int(edges.get(key, 0)) + dir
	volume /= 6.0

	var open: int = 0
	for key: String in edges:
		if int(edges[key]) != 0:
			open += 1
	if volume < 0.0 and open == 0 and degenerate == 0:
		return
	problems.append(
		"shell %d tris, volume %.9f, %d open, %d degenerate" % [count, volume, open, degenerate]
	)


static func _key(p: Vector3) -> String:
	return "%d,%d,%d" % [roundi(p.x / WELD), roundi(p.y / WELD), roundi(p.z / WELD)]
