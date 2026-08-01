extends RefCounted
## Per-shell topology audit for a baked surface. The single implementation behind
## both `validate_meshes.gd` (the project-wide sweep) and the self-checks a
## builder runs before it is allowed to write its artifacts.
##
## WINDING. Godot's rasteriser treats CLOCKWISE triangles as front-facing, so an
## outward-facing closed shell has NEGATIVE volume under the textbook right-hand
## form `p0 . (p1 x p2) / 6`. Everything below reports the negated value, i.e.
## POSITIVE MEANS OUTWARD, and a shell whose reported volume is negative is
## inside out: from the outside you see through it, from the inside you see its
## walls. That is the #1 defect this file exists to catch.
##
## SHELLS, NOT MESHES. Props are built from overlapping solids that interpenetrate
## without sharing vertices, so each solid stays its own edge-connected component
## and is scored on its own. A summed volume over a whole mesh cannot see an
## inverted solid — twenty inside-out boxes are drowned by the hundreds of correct
## ones around them, which is precisely how a town with 500 bad shells reported
## `+85564.2 m3  (must be positive)` and passed. Never gate on a sum.
##
## Two solids that were butted rather than overlapped weld into one component
## with a four-triangle edge, which is reported as non-manifold — exactly the
## seam you wanted to hear about.

## Vertex weld grid, metres. Two positions closer than this along every axis are
## the same point. One tenth of a millimetre: below any joint overlap the world
## build uses, above the float error in a baked transform.
const WELD: float = 1.0e-4
## Twice the triangle area below which a face has no usable normal.
const AREA_EPS: float = 1.0e-10
## A shell whose volume is under this in absolute terms is too flat to read a
## sign from, and is reported as flat rather than inverted.
const VOLUME_EPS: float = 1.0e-9

## Keys every returned row carries, in report order.
const FIELDS: PackedStringArray = [
	"tris",
	"verts",
	"shells",
	"boundary",
	"nonmanifold",
	"degenerate",
	"duplicate",
	"inverted",
	"flat",
	"flip",
]


## An all-zero row, for callers that accumulate into one.
static func blank_row() -> Dictionary:
	var row: Dictionary = {}
	for f: String in FIELDS:
		row[f] = 0
	row["volume"] = 0.0
	return row


## Adds `src`'s counters into `dst` in place.
static func accumulate(dst: Dictionary, src: Dictionary) -> void:
	for f: String in FIELDS:
		dst[f] = int(dst[f]) + int(src[f])
	dst["volume"] = float(dst["volume"]) + float(src["volume"])


## Every surface of `mesh` folded into one row. Use only when the surfaces are
## parts of one solid; otherwise score them separately.
static func check_mesh(mesh: Mesh) -> Dictionary:
	var row: Dictionary = blank_row()
	for si: int in mesh.get_surface_count():
		accumulate(row, check_surface(mesh.surface_get_arrays(si)))
	return row


## Scores a raw `SurfaceTool`/`ArrayMesh` array set. `open` surfaces (a
## heightfield, a buried slab underside) legitimately carry boundary edges; that
## judgement belongs to the caller, so this reports the count either way.
static func check_surface(arrays: Array) -> Dictionary:
	var row: Dictionary = blank_row()
	if arrays.is_empty() or arrays[Mesh.ARRAY_VERTEX] == null:
		return row
	var pos: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var nrm: PackedVector3Array = (
		arrays[Mesh.ARRAY_NORMAL] if arrays[Mesh.ARRAY_NORMAL] != null else PackedVector3Array()
	)
	var idx: PackedInt32Array = (
		arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
	)
	var corner_count: int = idx.size() if idx.size() > 0 else pos.size()
	if corner_count < 3:
		return row
	var tri_count: int = corner_count / 3
	row["verts"] = pos.size()

	# Weld positions onto a WELD-metre lattice. Distinct baked vertices that sit
	# on the same point are the same point for topology; the shading normals that
	# made them distinct are irrelevant here.
	var weld: Dictionary = {}
	var wid: PackedInt32Array = PackedInt32Array()
	wid.resize(pos.size())
	var next_id: int = 0
	for i: int in pos.size():
		var p: Vector3 = pos[i]
		var key := Vector3i(int(round(p.x / WELD)), int(round(p.y / WELD)), int(round(p.z / WELD)))
		var found: int = weld.get(key, -1)
		if found < 0:
			found = next_id
			weld[key] = found
			next_id += 1
		wid[i] = found

	var live: PackedInt32Array = PackedInt32Array()
	var degenerate: int = 0
	for t: int in tri_count:
		var c0: int = idx[t * 3] if idx.size() > 0 else t * 3
		var c1: int = idx[t * 3 + 1] if idx.size() > 0 else t * 3 + 1
		var c2: int = idx[t * 3 + 2] if idx.size() > 0 else t * 3 + 2
		var a: int = wid[c0]
		var b: int = wid[c1]
		var c: int = wid[c2]
		if a == b or b == c or a == c:
			degenerate += 1
			continue
		if (pos[c1] - pos[c0]).cross(pos[c2] - pos[c0]).length_squared() < AREA_EPS * AREA_EPS:
			degenerate += 1
			continue
		live.push_back(c0)
		live.push_back(c1)
		live.push_back(c2)
	row["tris"] = tri_count
	row["degenerate"] = degenerate
	var n: int = live.size() / 3
	if n == 0:
		return row

	# Duplicate faces: two triangles on the same three welded points. Whether they
	# are wound the same way or opposed, they are coplanar and they z-fight.
	var face_seen: Dictionary = {}
	var duplicate: int = 0
	for t: int in n:
		var tri := PackedInt32Array([wid[live[t * 3]], wid[live[t * 3 + 1]], wid[live[t * 3 + 2]]])
		tri.sort()
		var fkey: Vector3i = Vector3i(tri[0], tri[1], tri[2])
		if face_seen.has(fkey):
			duplicate += 1
		else:
			face_seen[fkey] = t
	row["duplicate"] = duplicate

	# Godot's front face is CLOCKWISE, so an outward triangle's stored normal must
	# oppose the right-hand cross product of its winding. Where it does not, the
	# triangle is lit as if it faced one way and drawn as if it faced the other,
	# and on a closed shell that is the whole surface inside out. This is the one
	# check an open surface can still be held to.
	var flip: int = 0
	if nrm.size() == pos.size():
		for t: int in n:
			var p0: Vector3 = pos[live[t * 3]]
			var p1: Vector3 = pos[live[t * 3 + 1]]
			var p2: Vector3 = pos[live[t * 3 + 2]]
			if (p1 - p0).cross(p2 - p0).dot(nrm[live[t * 3]]) > 0.0:
				flip += 1
	row["flip"] = flip

	# Edge map. Key packs the two welded ids, low first, into one int.
	var edge_tris: Dictionary = {}
	for t: int in n:
		for e: int in 3:
			var u: int = wid[live[t * 3 + e]]
			var v: int = wid[live[t * 3 + (e + 1) % 3]]
			var k: int = (mini(u, v) << 32) | maxi(u, v)
			var lst: PackedInt32Array = edge_tris.get(k, PackedInt32Array())
			lst.push_back(t)
			edge_tris[k] = lst

	# Union-find over triangles joined by a shared edge.
	var parent: PackedInt32Array = PackedInt32Array()
	parent.resize(n)
	for t: int in n:
		parent[t] = t
	for k: int in edge_tris:
		var lst: PackedInt32Array = edge_tris[k]
		for j: int in range(1, lst.size()):
			_union(parent, lst[0], lst[j])

	var boundary: int = 0
	var nonmanifold: int = 0
	for k: int in edge_tris:
		var lst: PackedInt32Array = edge_tris[k]
		if lst.size() == 1:
			boundary += 1
		elif lst.size() > 2:
			nonmanifold += 1
	row["boundary"] = boundary
	row["nonmanifold"] = nonmanifold

	# Per-shell volume about that shell's own centroid, reported outward-positive.
	var shells: Dictionary = {}
	for t: int in n:
		var rroot: int = _find(parent, t)
		var acc: PackedInt32Array = shells.get(rroot, PackedInt32Array())
		acc.push_back(t)
		shells[rroot] = acc
	var inverted: int = 0
	var flat: int = 0
	var volume: float = 0.0
	for rroot: int in shells:
		var tris: PackedInt32Array = shells[rroot]
		var origin := Vector3.ZERO
		for t: int in tris:
			origin += pos[live[t * 3]] + pos[live[t * 3 + 1]] + pos[live[t * 3 + 2]]
		origin /= float(tris.size() * 3)
		var raw: float = 0.0
		for t: int in tris:
			var a := pos[live[t * 3]] - origin
			var b := pos[live[t * 3 + 1]] - origin
			var c := pos[live[t * 3 + 2]] - origin
			raw += a.dot(b.cross(c))
		var outward: float = -raw / 6.0
		volume += outward
		if absf(outward) < VOLUME_EPS:
			flat += 1
		elif outward < 0.0:
			inverted += 1
	row["shells"] = shells.size()
	row["inverted"] = inverted
	row["flat"] = flat
	row["volume"] = volume
	return row


## One line naming everything wrong with `row`, or "clean". `open` suppresses the
## boundary-edge and inverted-shell complaints for a surface that is a sheet by
## design — a half-shell has no meaningful volume sign.
static func why(row: Dictionary, open: bool) -> String:
	var bits := PackedStringArray()
	if int(row["tris"]) == 0:
		bits.push_back("empty surface")
	if not open and int(row["boundary"]) > 0:
		bits.push_back("%d boundary edge(s)" % int(row["boundary"]))
	if int(row["nonmanifold"]) > 0:
		bits.push_back("%d non-manifold edge(s)" % int(row["nonmanifold"]))
	if int(row["degenerate"]) > 0:
		bits.push_back("%d degenerate tri(s)" % int(row["degenerate"]))
	if int(row["duplicate"]) > 0:
		bits.push_back("%d duplicate face(s)" % int(row["duplicate"]))
	if int(row["flip"]) > 0:
		bits.push_back("%d normal/winding conflict(s)" % int(row["flip"]))
	if not open and int(row["inverted"]) > 0:
		bits.push_back("%d inverted shell(s)" % int(row["inverted"]))
	if bits.is_empty():
		return "clean"
	return ", ".join(bits)


## True when `row` describes a surface a bake may not ship.
static func failed(row: Dictionary, open: bool) -> bool:
	return (
		int(row["tris"]) == 0
		or int(row["nonmanifold"]) > 0
		or int(row["degenerate"]) > 0
		or int(row["duplicate"]) > 0
		or int(row["flip"]) > 0
		or (not open and int(row["boundary"]) > 0)
		or (not open and int(row["inverted"]) > 0)
	)


static func _find(parent: PackedInt32Array, a: int) -> int:
	var x: int = a
	while parent[x] != x:
		parent[x] = parent[parent[x]]
		x = parent[x]
	return x


static func _union(parent: PackedInt32Array, a: int, b: int) -> void:
	var ra: int = _find(parent, a)
	var rb: int = _find(parent, b)
	if ra != rb:
		parent[rb] = ra
