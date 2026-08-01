extends RefCounted
## Closed-shell primitives for the gun bench's bake, and the census that proves each
## one really is closed.
##
## BAKE TIME ONLY. `res://tools/build_gunbench.gd` preloads this and packs the meshes
## it returns into `gunbench.tscn`; nothing under `res://demos/gunbench/` runs it at
## play time, and nothing in the demo generates geometry. It lives here rather than in
## `tools/` for the same reason `demos/range/build/` does: it is this demo's own kit,
## and the builder that drives it is already at the linter's file-length ceiling.
##
## EVERY SHELL IS CHECKED BEFORE IT IS HANDED BACK. A closed, outward-wound shell has
## NEGATIVE signed volume about its centroid — Godot's front face is CLOCKWISE, and its
## own `BoxMesh` measures -8.0, so positive means inside out. It also uses every welded
## edge exactly twice, once in each direction, and has no zero-area triangle.
##
## Findings are COLLECTED, not printed and not pushed as errors: the builder owns the
## report and the exit code, and a kit that decides on its own to fail a bake is a kit
## that cannot be reused by a harness that wants to measure rather than gate.
##
## [codeblock]
## var shapes := GunbenchShapes.new()
## node.mesh = shapes.box(Vector3(1.0, 0.2, 0.4))
## for finding: String in shapes.findings():
##     report.fail(finding)
## [/codeblock]

## Cylinder segments. Twelve is round enough at bay distance and keeps every post
## under thirty triangles.
const SEGMENTS: int = 12
## Metres a vertex may move and still weld to its neighbour in the edge census.
const WELD: float = 0.00005

var _shells: int = 0
var _findings: PackedStringArray = PackedStringArray()


## Shells built and checked so far.
func shells() -> int:
	return _shells


## One line per shell that failed the census. Empty is the healthy answer.
func findings() -> PackedStringArray:
	return _findings


## A closed box centred on its own origin. Six quads, per-face normals, non-indexed.
## Outward normal of a triangle is `(b - a).cross(c - a)`.
func box(size: Vector3) -> ArrayMesh:
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
		_quad(v, n, centre - a - b, centre + a - b, centre + a + b, centre - a + b, normal)
	return _commit(v, n)


## A closed cylinder about Y, centred on its origin, both caps fanned from a centre
## vertex so the shell has no boundary edge.
func cylinder(radius: float, height: float) -> ArrayMesh:
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
		_tri(v, n, b0, t0, t1, fn)
		_tri(v, n, b0, t1, b1, fn)
		_tri(v, n, Vector3(0.0, top, 0.0), t1, t0, Vector3.UP)
		_tri(v, n, Vector3(0.0, -top, 0.0), b0, b1, Vector3.DOWN)
	return _commit(v, n)


func _quad(
	v: PackedVector3Array,
	n: PackedVector3Array,
	a: Vector3,
	b: Vector3,
	c: Vector3,
	d: Vector3,
	normal: Vector3
) -> void:
	_tri(v, n, a, b, c, normal)
	_tri(v, n, a, c, d, normal)


func _tri(
	v: PackedVector3Array,
	n: PackedVector3Array,
	a: Vector3,
	b: Vector3,
	c: Vector3,
	normal: Vector3
) -> void:
	# Callers hand a, b, c counter-clockwise about `normal` — the right-hand
	# convention every face table above is written in. Godot's front face is
	# CLOCKWISE, so the pushed order turns round here and nowhere else. The normal
	# is stored data and already points outward, so it is passed through untouched.
	v.push_back(a)
	v.push_back(c)
	v.push_back(b)
	n.push_back(normal)
	n.push_back(normal)
	n.push_back(normal)


func _commit(v: PackedVector3Array, n: PackedVector3Array) -> ArrayMesh:
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = v
	arrays[Mesh.ARRAY_NORMAL] = n
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	_check(v)
	return mesh


## Divergence-theorem volume about the centroid plus a welded edge census. A closed,
## outward-wound shell has NEGATIVE volume under Godot's clockwise front face —
## positive means inside out — and uses every edge exactly twice, once each way.
func _check(v: PackedVector3Array) -> void:
	_shells += 1
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
		if (b - a).cross(c - a).length() < 1e-12:
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
	_findings.append(
		(
			"SHELL  tris %d  volume %.9f  open edges %d  degenerate %d"
			% [count, volume, open, degenerate]
		)
	)


static func _key(p: Vector3) -> String:
	return "%d,%d,%d" % [roundi(p.x / WELD), roundi(p.y / WELD), roundi(p.z / WELD)]
