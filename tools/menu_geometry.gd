extends RefCounted
## The closed-shell primitive kit every piece of the main menu is cut from.
##
## Two primitives — a box and a cylinder — plus the two node wrappers that mount
## them, plus the audit that gates them. `res://tools/menu_shop.gd` extends this
## and builds the workshop out of it; `res://tools/build_main_menu.gd` reaches
## through the same instance for the plates.
##
## Solids that meet OVERLAP at the joint rather than butt: a union of watertight
## shells cannot open a seam, which is what makes the project's air-gap rule cheap
## to keep. Each shell is audited before it is handed back — negative signed
## volume (Godot's front face is CLOCKWISE, so an outward-wound shell measures
## negative under the right-hand form), zero boundary edges, no degenerate
## triangles — and a shell that fails is named and counted so the bake fails with
## it. `shells`, `failures` and `lines` are what the bake report reads.

## Cylinder segment count. Twelve is round enough at bench distance.
const SEGMENTS: int = 12
## Metres a vertex may move and still count as the same vertex when the boundary
## edge check welds a shell.
const WELD: float = 0.00005

var shells: int = 0
var failures: int = 0
var lines: PackedStringArray = PackedStringArray()

# --- node helpers ------------------------------------------------------------


## One `MeshInstance3D`. `seed_value` picks the grime pattern and `tint` shifts the
## material's albedo per instance, which is how twenty-eight planks come off one
## timber material without twenty-eight materials.
func mesh_node(
	node_name: String,
	mesh: ArrayMesh,
	material: Material,
	origin: Vector3,
	seed_value: float,
	tint: Color = Color.WHITE
) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	node.name = node_name
	node.mesh = mesh
	node.material_override = material
	node.position = origin
	node.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	node.set_instance_shader_parameter(&"surface_seed", seed_value)
	if tint != Color.WHITE:
		node.set_instance_shader_parameter(&"tint", tint)
	return node


func label(
	node_name: String,
	text: String,
	font: Font,
	font_size: int,
	pixel_size: float,
	color: Color,
	origin: Vector3
) -> Label3D:
	var node := Label3D.new()
	node.name = node_name
	node.text = text
	node.font = font
	node.font_size = font_size
	node.pixel_size = pixel_size
	node.modulate = color
	node.position = origin
	node.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	node.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	node.shaded = false
	node.double_sided = false
	node.alpha_cut = Label3D.ALPHA_CUT_DISCARD
	node.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	node.render_priority = 2
	return node


# --- geometry ----------------------------------------------------------------


## A closed box centred on its own origin. Six quads, twelve triangles, per-face
## normals, non-indexed. Winding follows the project's convention: the outward
## normal of a triangle is `(b - a).cross(c - a)`.
func box(size: Vector3, tag: String = "box") -> ArrayMesh:
	var h: Vector3 = size * 0.5
	var v := PackedVector3Array()
	var n := PackedVector3Array()
	# normal, then the two in-plane axes whose cross product is that normal.
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
	return _commit(v, n, tag)


## A closed cylinder about the Y axis, centred on its own origin, with both caps
## fanned from a centre vertex so the shell has no boundary edge.
func cylinder(radius: float, height: float, tag: String = "cylinder") -> ArrayMesh:
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
		# Per-face normal, not per-vertex: the scrap shader is flat-lit and a smooth
		# ring on a twelve-sided post reads as a shading error, not as a curve.
		var fn: Vector3 = (d0 + d1).normalized()
		_tri(v, n, b0, t0, t1, fn)
		_tri(v, n, b0, t1, b1, fn)
		_tri(v, n, Vector3(0.0, top, 0.0), t1, t0, Vector3.UP)
		_tri(v, n, Vector3(0.0, -top, 0.0), b0, b1, Vector3.DOWN)
	return _commit(v, n, tag)


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


func _commit(v: PackedVector3Array, n: PackedVector3Array, tag: String) -> ArrayMesh:
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = v
	arrays[Mesh.ARRAY_NORMAL] = n
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	_check(v, tag)
	return mesh


## Divergence-theorem volume about the centroid plus a welded edge census. Under
## Godot's clockwise front face an outward-wound closed shell has NEGATIVE volume
## by the right-hand form, and uses every edge exactly twice, once in each
## direction. Positive volume here means the shell is inside out.
func _check(v: PackedVector3Array, tag: String) -> void:
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
	failures += 1
	lines.append(
		(
			"  SHELL FAIL  %-16s tris %d  volume %.9f  open edges %d  degenerate %d"
			% [tag, count, volume, open, degenerate]
		)
	)


static func _key(p: Vector3) -> String:
	return "%d,%d,%d" % [roundi(p.x / WELD), roundi(p.y / WELD), roundi(p.z / WELD)]
