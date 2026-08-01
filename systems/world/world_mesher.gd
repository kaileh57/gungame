class_name WorldMesher
extends RefCounted
## Triangle-soup accumulator for the world bake. Every primitive it emits is a
## closed, outward-wound solid.
##
## WINDING. Godot's rasteriser treats CLOCKWISE triangles as front-facing — the
## opposite of three.js and of the textbook right-hand rule. (Measured: a 2x2x2
## `BoxMesh` has divergence volume -8 under `v0 . (v1 x v2) / 6`, and its stored
## normals are anti-parallel to `(v1-v0) x (v2-v0)`.) Rather than invert every
## primitive by hand and lose the ability to read them against the reference,
## every routine below is written in the familiar counter-clockwise-is-outward
## form and `_emit` performs the single swap on the way into the buffer. The
## self-test in `signed_volume` reports in the same familiar form: positive means
## outward, whatever the buffer holds.
##
## FLAT SHADING. Nothing is indexed and nothing is welded. The reference draws the
## whole world with `flatShading: true`, and the surface id in `CUSTOM0.x` is a
## nine-way branch that must never interpolate between two different types across
## a shared vertex. Duplicated vertices are the point, not an oversight.
##
## WORLD SPACE. Chunks keep their vertices in world coordinates and are instanced
## at identity. `world_material.gdshader` reads object-space position for its
## procedural grain, so rebasing a chunk to a local origin would shift the grain
## and put a visible seam down every chunk border. The mesh AABB stays tight
## either way, so frustum culling loses nothing.

## Twice the triangle area below which a face is dropped as degenerate. At world
## scale the smallest legitimate face is a 0.03 m antenna crossbar (9e-4 m2), so
## this is five orders of magnitude clear of anything real.
const AREA_EPS: float = 1.0e-10

## No half-extent is allowed below this. A zero-thickness box would have its
## faces dropped as degenerate and leave an open shell, which is the one thing
## this file exists to prevent.
const MIN_HALF: float = 0.001

## Default thickness given to a corrugated sheet. The reference emits an open
## single-sided plane here, which vanishes when seen from below under backface
## culling; a roof you can fall through is exactly the defect this project
## exists to not have.
const CORRUG_THICKNESS: float = 0.06

var _pos: PackedVector3Array = PackedVector3Array()
var _nrm: PackedVector3Array = PackedVector3Array()
var _col: PackedColorArray = PackedColorArray()
var _cus: PackedFloat32Array = PackedFloat32Array()
var _tri_count: int = 0
var _degenerate: int = 0


func triangle_count() -> int:
	return _tri_count


func degenerate_count() -> int:
	return _degenerate


func is_empty() -> bool:
	return _tri_count == 0


func vertices() -> PackedVector3Array:
	return _pos


# ------------------------------------------------------------------ emission


## The single place vertices enter the buffer. Colours arrive LINEAR.
func _emit(
	a: Vector3,
	b: Vector3,
	c: Vector3,
	ca: Color,
	cb: Color,
	cc: Color,
	ba: float,
	bb: float,
	bc: float,
	type: float
) -> void:
	var n: Vector3 = (b - a).cross(c - a)
	var l: float = n.length()
	if l < AREA_EPS:
		_degenerate += 1
		return
	n /= l
	# a, c, b — the clockwise-front swap. `n` stays the true outward normal.
	_pos.push_back(a)
	_pos.push_back(c)
	_pos.push_back(b)
	_nrm.push_back(n)
	_nrm.push_back(n)
	_nrm.push_back(n)
	_col.push_back(ca)
	_col.push_back(cc)
	_col.push_back(cb)
	_cus.push_back(type)
	_cus.push_back(ba)
	_cus.push_back(0.0)
	_cus.push_back(0.0)
	_cus.push_back(type)
	_cus.push_back(bc)
	_cus.push_back(0.0)
	_cus.push_back(0.0)
	_cus.push_back(type)
	_cus.push_back(bb)
	_cus.push_back(0.0)
	_cus.push_back(0.0)
	_tri_count += 1


## One flat-shaded triangle, single colour. `col` is sRGB.
func tri(a: Vector3, b: Vector3, c: Vector3, col: Color, type: int, blend: float = 0.0) -> void:
	var lc: Color = col.srgb_to_linear()
	_emit(a, b, c, lc, lc, lc, blend, blend, blend, float(type))


## Per-vertex colour and road blend, colours already LINEAR. Used by the terrain,
## which shades continuously but keeps its surface type per quad.
func tri_v(
	a: Vector3,
	b: Vector3,
	c: Vector3,
	ca: Color,
	cb: Color,
	cc: Color,
	ba: float,
	bb: float,
	bc: float,
	type: int
) -> void:
	_emit(a, b, c, ca, cb, cc, ba, bb, bc, float(type))


## Planar quad, vertices counter-clockwise seen from the front.
func quad(a: Vector3, b: Vector3, c: Vector3, d: Vector3, col: Color, type: int) -> void:
	var lc: Color = col.srgb_to_linear()
	_emit(a, b, c, lc, lc, lc, 0.0, 0.0, 0.0, float(type))
	_emit(a, c, d, lc, lc, lc, 0.0, 0.0, 0.0, float(type))


func _quad_lin(a: Vector3, b: Vector3, c: Vector3, d: Vector3, lc: Color, type: float) -> void:
	_emit(a, b, c, lc, lc, lc, 0.0, 0.0, 0.0, type)
	_emit(a, c, d, lc, lc, lc, 0.0, 0.0, 0.0, type)


## Closed box from three half-extent vectors forming a right-handed frame
## (ex x ey = +ez). All six faces, all outward. This is the workhorse: better
## than nine tenths of the world is one of these.
func oriented_box(
	center: Vector3, ex: Vector3, ey: Vector3, ez: Vector3, col: Color, type: int
) -> void:
	var lc: Color = col.srgb_to_linear()
	var t: float = float(type)
	var a: Vector3 = center - ex - ey - ez
	var b: Vector3 = center + ex - ey - ez
	var c: Vector3 = center + ex - ey + ez
	var d: Vector3 = center - ex - ey + ez
	var e: Vector3 = center - ex + ey - ez
	var f: Vector3 = center + ex + ey - ez
	var g: Vector3 = center + ex + ey + ez
	var h: Vector3 = center - ex + ey + ez
	_quad_lin(e, h, g, f, lc, t)
	_quad_lin(a, b, c, d, lc, t)
	_quad_lin(d, c, g, h, lc, t)
	_quad_lin(b, a, e, f, lc, t)
	_quad_lin(c, b, f, g, lc, t)
	_quad_lin(a, d, h, e, lc, t)


## Yaw-rotated box, half-extents `half`, rotated `ry` about +Y. Local +X points
## along world `(cos ry, 0, -sin ry)` and local +Z along `(sin ry, 0, cos ry)` —
## the reference's convention, which is exactly `Basis(Vector3.UP, ry)`.
func box(center: Vector3, half: Vector3, ry: float, col: Color, type: int) -> void:
	var co: float = cos(ry)
	var si: float = sin(ry)
	var hx: float = maxf(absf(half.x), MIN_HALF)
	var hy: float = maxf(absf(half.y), MIN_HALF)
	var hz: float = maxf(absf(half.z), MIN_HALF)
	oriented_box(
		center,
		Vector3(co, 0.0, -si) * hx,
		Vector3(0.0, hy, 0.0),
		Vector3(si, 0.0, co) * hz,
		col,
		type
	)


## Capped cylinder or cone about an arbitrary axis. The reference could only make
## Y-axis cylinders — its tenth argument rotates the seam, not the body — which
## is why its tipped drums and truck wheels stand upright inside colliders that
## lie on their side. Here the axis is real and the two always agree.
func cylinder(
	center: Vector3,
	r0: float,
	r1: float,
	hy: float,
	segments: int,
	col: Color,
	type: int,
	axis: Vector3 = Vector3.UP,
	seam: float = 0.0,
	capped: bool = true
) -> void:
	var seg: int = maxi(3, segments)
	var lc: Color = col.srgb_to_linear()
	var t: float = float(type)
	var ay: Vector3 = axis.normalized()
	if not ay.is_finite() or ay.length_squared() < 0.5:
		ay = Vector3.UP
	var helper: Vector3 = Vector3.RIGHT if absf(ay.y) > 0.94 else Vector3.UP
	var ax: Vector3 = helper.cross(ay).normalized()
	var az: Vector3 = ax.cross(ay)

	var bot: Vector3 = center - ay * hy
	var top: Vector3 = center + ay * hy
	var ring_b := PackedVector3Array()
	var ring_t := PackedVector3Array()
	ring_b.resize(seg)
	ring_t.resize(seg)
	for i in seg:
		var ang: float = seam + float(i) / float(seg) * TAU
		var dir: Vector3 = ax * cos(ang) + az * sin(ang)
		ring_b[i] = bot + dir * r0
		ring_t[i] = top + dir * r1
	for i in seg:
		var j: int = (i + 1) % seg
		_quad_lin(ring_b[i], ring_t[i], ring_t[j], ring_b[j], lc, t)
	if not capped:
		return
	for i in seg:
		var j: int = (i + 1) % seg
		_emit(top, ring_t[j], ring_t[i], lc, lc, lc, 0.0, 0.0, 0.0, t)
		_emit(bot, ring_b[i], ring_b[j], lc, lc, lc, 0.0, 0.0, 0.0, t)


## Square-section strut from `a` to `b`, half-width `rad`. Braces, branches,
## power-line conductors and the exfil ring are all made of these.
func strut(a: Vector3, b: Vector3, rad: float, col: Color, type: int) -> void:
	var d: Vector3 = b - a
	var len_sq: float = d.length_squared()
	if len_sq < 1.0e-12:
		return
	var dir: Vector3 = d / sqrt(len_sq)
	var helper: Vector3 = Vector3.RIGHT if absf(dir.y) > 0.94 else Vector3.UP
	var side: Vector3 = dir.cross(helper).normalized()
	# side x (dir x side) = dir, so this ordering is right-handed. The other one
	# is not, and produces a strut that is inside out along its whole length.
	var up: Vector3 = dir.cross(side)
	var r: float = maxf(absf(rad), MIN_HALF)
	oriented_box((a + b) * 0.5, side * r, up * r, dir * (sqrt(len_sq) * 0.5), col, type)


## Corrugated sheet with real thickness. Ribs run along local X, `ribs` segments
## alternating +-`amp` in Y; `tilt` slopes the whole sheet by `lx * tilt`.
##
## Solid, not a plane: the top face carries the profile, the underside mirrors it
## `thickness` lower, and all four rims are closed. Nothing about the silhouette
## changes and the roof stops disappearing when you stand under it.
func corrugated(
	center: Vector3,
	hx: float,
	hz: float,
	ribs: int,
	amp: float,
	col: Color,
	type: int,
	ry: float = 0.0,
	tilt: float = 0.0,
	thickness: float = CORRUG_THICKNESS
) -> void:
	var n: int = maxi(2, ribs)
	var lc: Color = col.srgb_to_linear()
	var t: float = float(type)
	var co: float = cos(ry)
	var si: float = sin(ry)
	var half_t: float = maxf(thickness, MIN_HALF * 2.0) * 0.5

	var upper := PackedVector3Array()
	var lower := PackedVector3Array()
	upper.resize((n + 1) * 2)
	lower.resize((n + 1) * 2)
	for i in n + 1:
		var lx: float = -hx + 2.0 * hx * float(i) / float(n)
		var ly: float = (amp if (i % 2) == 1 else -amp) + lx * tilt
		for e in 2:
			var lz: float = -hz if e == 0 else hz
			var wx: float = center.x + lx * co + lz * si
			var wz: float = center.z - lx * si + lz * co
			upper[i * 2 + e] = Vector3(wx, center.y + ly + half_t, wz)
			lower[i * 2 + e] = Vector3(wx, center.y + ly - half_t, wz)

	for i in n:
		var a0: int = i * 2
		var a1: int = (i + 1) * 2
		_quad_lin(upper[a0], upper[a0 + 1], upper[a1 + 1], upper[a1], lc, t)
		_quad_lin(lower[a0], lower[a1], lower[a1 + 1], lower[a0 + 1], lc, t)
		_quad_lin(lower[a1], lower[a0], upper[a0], upper[a1], lc, t)
		_quad_lin(lower[a0 + 1], lower[a1 + 1], upper[a1 + 1], upper[a0 + 1], lc, t)
	var last: int = n * 2
	_quad_lin(lower[0], lower[1], upper[1], upper[0], lc, t)
	_quad_lin(lower[last + 1], lower[last], upper[last], upper[last + 1], lc, t)


# ------------------------------------------------------------------ self-test


## Divergence-theorem volume about the mesh centroid, reported in the textbook
## right-hand form: POSITIVE means the surface faces outward. The buffer holds
## the clockwise swap, so this negates on the way out.
func signed_volume() -> float:
	if _tri_count == 0:
		return 0.0
	var origin: Vector3 = Vector3.ZERO
	for v in _pos:
		origin += v
	origin /= float(_pos.size())
	var sum: float = 0.0
	for t in _tri_count:
		var a: Vector3 = _pos[t * 3] - origin
		var b: Vector3 = _pos[t * 3 + 1] - origin
		var c: Vector3 = _pos[t * 3 + 2] - origin
		sum += a.dot(b.cross(c))
	return -sum / 6.0


## Triangles whose stored normal disagrees with the direction their winding
## implies. Always zero — `_emit` derives one from the other — but the assertion
## is cheap and it is the first thing that would break if the swap were touched.
func normal_conflicts() -> int:
	var bad: int = 0
	for t in _tri_count:
		var v0: Vector3 = _pos[t * 3]
		var v1: Vector3 = _pos[t * 3 + 1]
		var v2: Vector3 = _pos[t * 3 + 2]
		if (v0 - v2).cross(v0 - v1).dot(_nrm[t * 3]) <= 0.0:
			bad += 1
	return bad


# ------------------------------------------------------------------- readback


## Mesh arrays for the whole accumulator, ready for `add_surface_from_arrays`.
func arrays() -> Array:
	var out: Array = []
	out.resize(Mesh.ARRAY_MAX)
	out[Mesh.ARRAY_VERTEX] = _pos
	out[Mesh.ARRAY_NORMAL] = _nrm
	out[Mesh.ARRAY_COLOR] = _col
	out[Mesh.ARRAY_CUSTOM0] = _cus
	return out


## The format flag `arrays()` must be handed alongside: CUSTOM0 as four floats,
## which is what `res://art/world_material.gdshader` declares.
static func surface_format() -> int:
	return Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT


func build_mesh(material: Material = null) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	if _tri_count == 0:
		return mesh
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays(), [], {}, surface_format())
	if material != null:
		mesh.surface_set_material(0, material)
	return mesh


## Bucket triangles by the XZ cell their centroid falls in. Returns
## `{Vector2i: PackedInt32Array of triangle indices}`.
func chunk_triangles(cell: float) -> Dictionary:
	var buckets: Dictionary = {}
	for t in _tri_count:
		var cx: float = (_pos[t * 3].x + _pos[t * 3 + 1].x + _pos[t * 3 + 2].x) / 3.0
		var cz: float = (_pos[t * 3].z + _pos[t * 3 + 1].z + _pos[t * 3 + 2].z) / 3.0
		var key := Vector2i(floori(cx / cell), floori(cz / cell))
		if not buckets.has(key):
			buckets[key] = PackedInt32Array()
		var arr: PackedInt32Array = buckets[key]
		arr.push_back(t)
		buckets[key] = arr
	return buckets


## A mesh holding only the listed triangles. Vertices stay in world space; see
## the note at the top of the file about why they must.
func build_subset(tris: PackedInt32Array, material: Material = null) -> ArrayMesh:
	var n: int = tris.size()
	var pos := PackedVector3Array()
	var nrm := PackedVector3Array()
	var col := PackedColorArray()
	var cus := PackedFloat32Array()
	pos.resize(n * 3)
	nrm.resize(n * 3)
	col.resize(n * 3)
	cus.resize(n * 12)
	for k in n:
		var t: int = tris[k]
		for e in 3:
			var src: int = t * 3 + e
			var dst: int = k * 3 + e
			pos[dst] = _pos[src]
			nrm[dst] = _nrm[src]
			col[dst] = _col[src]
			cus[dst * 4] = _cus[src * 4]
			cus[dst * 4 + 1] = _cus[src * 4 + 1]
			cus[dst * 4 + 2] = _cus[src * 4 + 2]
			cus[dst * 4 + 3] = _cus[src * 4 + 3]
	var out: Array = []
	out.resize(Mesh.ARRAY_MAX)
	out[Mesh.ARRAY_VERTEX] = pos
	out[Mesh.ARRAY_NORMAL] = nrm
	out[Mesh.ARRAY_COLOR] = col
	out[Mesh.ARRAY_CUSTOM0] = cus
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, out, [], {}, surface_format())
	if material != null:
		mesh.surface_set_material(0, material)
	return mesh
