extends RefCounted
## Counts how much of the view the held weapon's own geometry covers.
##
## This is a ray cast from the eye through a grid of screen samples, done as a
## rasterisation because that is the same measurement without the quadratic cost:
## a sample is occluded exactly when the ray through it meets a triangle of the
## assembly, and testing a projected triangle against the samples inside its own
## bounding box visits every (sample, triangle) pair that could possibly meet
## instead of all of them.
##
## Everything is measured in the EYE's frame, looking down -Z, in TANGENT units:
## a point at `(x, y, z)` lands at `(x / -z, y / -z)`, so the sample at tangent
## `(u, v)` is the ray `(u, v, -1)`. That keeps the measurement independent of
## resolution, and turns a field of view into a half-extent through `tan`.
##
## The near plane is the viewmodel camera's own 0.006 m. Geometry crossing it is
## clipped rather than dropped, because a triangle with one vertex behind the eye
## projects to garbage and a butt-plate that reaches the near plane is exactly the
## case worth measuring.

## `ViewmodelPass.near_plane`. Nothing closer than this is drawn, so nothing
## closer than this can occlude.
const NEAR: float = 0.006
## Below this the triangle is degenerate in screen space and covers no sample.
const AREA_EPS: float = 1.0e-12

var _faces: Dictionary = {}


## Assembly triangles for `spec`, in the eye's frame, as flat vertex triples.
##
## `holder` is the transform the pose puts on the gun's holder — `GunPose`'s own,
## which maps LIFTED model units into the eye's frame — and `lift` is the lift in
## model units that `GunPose.sight_point()` adds, so the two agree by construction.
func triangles(spec: GunSpec, holder: Transform3D, lift: float) -> PackedVector3Array:
	var out := PackedVector3Array()
	if spec == null:
		return out
	var lifted: Transform3D = holder * Transform3D(Basis(), Vector3(0.0, lift, 0.0))
	for i: int in spec.part_count():
		var mesh: PackedVector3Array = _mesh_faces(spec.part_indices[i])
		if mesh.is_empty():
			continue
		var place: Transform3D = lifted * spec.part_transform(i)
		var base: int = out.size()
		out.resize(base + mesh.size())
		for v: int in mesh.size():
			out[base + v] = place * mesh[v]
	return out


## Fraction of a rectangular grid of rays that meet the geometry, and whether the
## ray straight down the view axis is one of them.
##
## `half` holds the half-extents of the window in tangent units and `grid` the
## sample counts. Both counts should be ODD so the exact view axis is sampled
## rather than straddled.
##
## Returns `{covered, samples, fraction, centre}`.
func cover(tris: PackedVector3Array, half: Vector2, grid: Vector2i) -> Dictionary:
	var cols: int = maxi(grid.x, 1)
	var rows: int = maxi(grid.y, 1)
	var hit := PackedByteArray()
	hit.resize(cols * rows)
	hit.fill(0)
	var poly := PackedVector3Array()
	poly.resize(4)
	var i: int = 0
	while i + 2 < tris.size():
		var count: int = _clip_near(tris[i], tris[i + 1], tris[i + 2], poly)
		for f: int in maxi(count - 2, 0):
			_fill(poly[0], poly[f + 1], poly[f + 2], hit, half, cols, rows)
		i += 3
	var covered: int = 0
	for cell: int in hit.size():
		covered += 1 if hit[cell] != 0 else 0
	var samples: int = cols * rows
	return {
		"covered": covered,
		"samples": samples,
		"fraction": float(covered) / float(samples),
		"centre": hit[(rows / 2) * cols + cols / 2] != 0,
	}


## Highest elevation, in tangent units, reached by any vertex inside a vertical
## band of half-width `half_u` around the view axis. Negative when the whole
## weapon sits below the view axis, which is the number the ADS solve steers.
## Returns -INF when nothing is in the band at all.
func crest(tris: PackedVector3Array, half_u: float) -> float:
	var top: float = -INF
	for v: int in tris.size():
		var p: Vector3 = tris[v]
		if p.z > -NEAR:
			continue
		var depth: float = -p.z
		if absf(p.x) > half_u * depth:
			continue
		top = maxf(top, p.y / depth)
	return top


## Drop the cached mesh faces.
func clear_cache() -> void:
	_faces.clear()


## Triangle soup for one part, cached. `Mesh.get_faces` already flattens every
## surface into vertex triples, which is the form the raster wants.
func _mesh_faces(index: int) -> PackedVector3Array:
	if _faces.has(index):
		return _faces[index]
	var mesh: ArrayMesh = PartLibrary.mesh_for(index)
	var faces := PackedVector3Array() if mesh == null else mesh.get_faces()
	_faces[index] = faces
	return faces


## Sutherland-Hodgman against `z <= -NEAR`, writing the surviving polygon into
## `poly` and returning how many vertices it has: 0, 3 or 4.
func _clip_near(a: Vector3, b: Vector3, c: Vector3, poly: PackedVector3Array) -> int:
	var src: Array[Vector3] = [a, b, c]
	var keep: Array[bool] = [a.z <= -NEAR, b.z <= -NEAR, c.z <= -NEAR]
	if keep[0] and keep[1] and keep[2]:
		poly[0] = a
		poly[1] = b
		poly[2] = c
		return 3
	if not (keep[0] or keep[1] or keep[2]):
		return 0
	var count: int = 0
	for e: int in 3:
		var n: int = (e + 1) % 3
		if keep[e]:
			poly[count] = src[e]
			count += 1
		if keep[e] != keep[n]:
			poly[count] = _cut(src[e], src[n])
			count += 1
	return count


## Where the segment crosses the near plane.
static func _cut(p: Vector3, q: Vector3) -> Vector3:
	var span: float = q.z - p.z
	if absf(span) < 1.0e-12:
		return p
	return p.lerp(q, (-NEAR - p.z) / span)


## Rasterise one wholly-in-front triangle into the grid.
func _fill(
	a: Vector3, b: Vector3, c: Vector3, hit: PackedByteArray, half: Vector2, cols: int, rows: int
) -> void:
	var pa := Vector2(a.x / -a.z, a.y / -a.z)
	var pb := Vector2(b.x / -b.z, b.y / -b.z)
	var pc := Vector2(c.x / -c.z, c.y / -c.z)
	var area: float = (pb.x - pa.x) * (pc.y - pa.y) - (pb.y - pa.y) * (pc.x - pa.x)
	if absf(area) < AREA_EPS:
		return
	var lo := Vector2(minf(pa.x, minf(pb.x, pc.x)), minf(pa.y, minf(pb.y, pc.y)))
	var hi := Vector2(maxf(pa.x, maxf(pb.x, pc.x)), maxf(pa.y, maxf(pb.y, pc.y)))
	if hi.x < -half.x or lo.x > half.x or hi.y < -half.y or lo.y > half.y:
		return
	var sign: float = signf(area)
	var i0: int = maxi(_index(lo.x, half.x, cols, true), 0)
	var i1: int = mini(_index(hi.x, half.x, cols, false), cols - 1)
	var j0: int = maxi(_index(lo.y, half.y, rows, true), 0)
	var j1: int = mini(_index(hi.y, half.y, rows, false), rows - 1)
	for j: int in range(j0, j1 + 1):
		var v: float = _coord(j, half.y, rows)
		var row: int = j * cols
		for i: int in range(i0, i1 + 1):
			if hit[row + i] != 0:
				continue
			var u: float = _coord(i, half.x, cols)
			if ((pb.x - pa.x) * (v - pa.y) - (pb.y - pa.y) * (u - pa.x)) * sign < 0.0:
				continue
			if ((pc.x - pb.x) * (v - pb.y) - (pc.y - pb.y) * (u - pb.x)) * sign < 0.0:
				continue
			if ((pa.x - pc.x) * (v - pc.y) - (pa.y - pc.y) * (u - pc.x)) * sign < 0.0:
				continue
			hit[row + i] = 1


## Tangent coordinate of sample `i`, spanning `[-half, half]` inclusive.
static func _coord(i: int, half: float, count: int) -> float:
	if count <= 1:
		return 0.0
	return -half + 2.0 * half * float(i) / float(count - 1)


## Sample index at a tangent coordinate, rounded outward when `up` so the span
## returned always contains every sample the triangle could cover.
static func _index(value: float, half: float, count: int, up: bool) -> int:
	if count <= 1:
		return 0
	var t: float = (value + half) / (2.0 * half) * float(count - 1)
	return int(ceil(t)) if up else int(floor(t))
