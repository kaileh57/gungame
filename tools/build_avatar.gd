extends SceneTree
## Avatar bake: the capsule, the sunglasses, the four materials and the two prefabs the
## multiplayer presence system instances at runtime.
##
##   godot --headless --path <project> --script res://tools/build_avatar.gd
##
## Writes into res://data/net/:
##   avatar_capsule.res    closed capsule shell, smooth normals, 1.80 m tall
##   avatar_sphere.res     closed sphere, for SPHERE presence
##   avatar_visor.res      the wraparound lens band — the sunglasses
##   avatar_temples.res    both arms, one surface
##   avatar_body.tres      scrap-shader polymer, light enough for a tint to read on
##   avatar_lens.tres      dark glass, the one smooth material on the avatar
##   avatar_ghost.tres     translucent capsule (GHOST)
##   avatar_bubble.tres    translucent sphere (SPHERE)
##   laser_dot.tres        the dot
##   beacon.tres           the through-walls mark
##   player_avatar.tscn    the avatar prefab
##   laser_cursor.tscn     the dot prefab
##   avatar_report.txt
##
## Two project rules drive the whole file.
##
## NOTHING IS GENERATED AT RUNTIME. Every mesh, material and scene above is written once
## and loaded thereafter, which is the rule that keeps four clients from each paying to
## weld the same capsule.
##
## WINDING IS CLOCKWISE. Godot's front face is clockwise, so an outward-wound closed
## shell measures NEGATIVE signed volume under the right-hand form. Every shell here is
## authored counter-clockwise about its outward normal and turned round in `_tri`, in
## one place, and every one is audited for negative volume, zero boundary edges and no
## degenerate triangles before it is written. A failure names the shell and fails the
## bake rather than shipping a capsule you can see the inside of.
##
## The work happens on the first idle frame and the two prefab scripts are pulled in
## with `load` rather than by `class_name`, for the reason `tools/build_player.gd`
## documents: `--script` compiles the main-loop script and everything it names before
## the autoloads exist.

const OUT_DIR: String = "res://data/net"
const REPORT_PATH: String = "res://data/net/avatar_report.txt"

const CAPSULE_PATH: String = "res://data/net/avatar_capsule.res"
const SPHERE_PATH: String = "res://data/net/avatar_sphere.res"
const VISOR_PATH: String = "res://data/net/avatar_visor.res"
const TEMPLES_PATH: String = "res://data/net/avatar_temples.res"
const BODY_MAT_PATH: String = "res://data/net/avatar_body.tres"
const LENS_MAT_PATH: String = "res://data/net/avatar_lens.tres"
const GHOST_MAT_PATH: String = "res://data/net/avatar_ghost.tres"
const BUBBLE_MAT_PATH: String = "res://data/net/avatar_bubble.tres"
const DOT_MAT_PATH: String = "res://data/net/laser_dot.tres"
const BEACON_MAT_PATH: String = "res://data/net/beacon.tres"
const AVATAR_SCENE_PATH: String = "res://data/net/player_avatar.tscn"
const CURSOR_SCENE_PATH: String = "res://data/net/laser_cursor.tscn"

const SCRAP_SHADER: String = "res://art/shaders/scrap_surface.gdshader"
const GHOST_SHADER: String = "res://net/avatar/ghost_body.gdshader"
const DOT_SHADER: String = "res://net/avatar/laser_dot.gdshader"
const BEACON_SHADER: String = "res://net/avatar/beacon.gdshader"
const SCRIPT_AVATAR: String = "res://net/avatar/player_avatar.gd"
const SCRIPT_CURSOR: String = "res://net/avatar/laser_cursor.gd"
const SCRIPT_PLATE: String = "res://net/avatar/net_nameplate.gd"
## The condensed face the whole project stencils with, baked by `build_main_menu.gd`.
## Adopted if it is on disk and skipped if it is not, so this bake does not depend on
## the order the UI bake ran in — a missing face falls back to the engine's own, which
## is ugly and obvious rather than fatal.
const FONT_PATH: String = "res://data/ui/font_display.tres"

## The player's own dimensions, from `tools/build_player.gd`. An avatar that is not the
## size of the body it stands for is a capsule that lies about cover.
const STAND_HEIGHT: float = 1.80
const BODY_RADIUS: float = 0.34
## Radius of the SPHERE-mode bubble, and the height of its centre.
const BUBBLE_RADIUS: float = 0.52
const BUBBLE_CENTRE: float = 0.95
## Where the nameplate hangs over the crown.
const PLATE_HEIGHT: float = 2.10

## Sixteen around and six per cap. At sixteen a capsule seen at three metres has no
## visible facet on its silhouette, and the whole body is 448 triangles — a tenth of one
## creature, for something there are never more than three of.
const SEGMENTS: int = 16
const CAP_RINGS: int = 6
## The sphere is seen from further away and can afford fewer.
const SPHERE_SEGMENTS: int = 20
const SPHERE_RINGS: int = 10

## The sunglasses. Eye height is the player prefab's 1.65 m; the band's radius is solved
## against the capsule's own surface at that height so it sits ON the head rather than
## floating off it or sinking into it.
const EYE_HEIGHT: float = 1.645
const VISOR_HALF_ANGLE: float = 1.05
const VISOR_SEGMENTS: int = 10
const VISOR_HEIGHT: float = 0.085
## How far the band sinks into the head, and how far it stands proud of it. Overlapping
## joints, never butted: a union of watertight shells cannot open a seam.
const VISOR_SINK: float = 0.028
const VISOR_PROUD: float = 0.020
const TEMPLE_SIZE: Vector3 = Vector3(0.030, 0.050, 0.26)
const TEMPLE_Z: float = -0.06

## Metres per font pixel on the nameplate, and its size. 42 at 0.0022 is a 92 mm cap
## height at scale 1, which `NetNameplate` then scales against range.
const PLATE_PIXEL_SIZE: float = 0.0022
const PLATE_FONT_SIZE: int = 42
const PLATE_OUTLINE: int = 10
const HOVER_FONT_SIZE: int = 36
const HOVER_PIXEL_SIZE: float = 0.0022

## Height over width the beacon quad is authored at, and what the shader is told.
const BEACON_ASPECT: float = 7.0
const BEACON_BASE: float = STAND_HEIGHT + 0.75

## Avatar shell colour BEFORE the player tint multiplies it. Light, because the tint is
## a multiplier: at a mid value every player comes out a silhouette, which is the exact
## failure `Palette`'s faction note describes.
const SHELL_ALBEDO: Color = Color(0.86, 0.84, 0.80)
const LENS_ALBEDO: Color = Color(0.055, 0.058, 0.065)
const INK: Color = Color(0.035, 0.031, 0.028, 1.0)

## Weld tolerance for the boundary-edge census, in metres.
const WELD: float = 0.00005

var _built: bool = false
var _shells: int = 0
var _failures: int = 0
var _lines: PackedStringArray = PackedStringArray()


func _process(_delta: float) -> bool:
	if _built:
		return true
	_built = true
	_build()
	return true


func _build() -> void:
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	_lines.append("AVATAR BAKE")
	_lines.append("")

	# MATERIALS FIRST, AND THE MESHES ARE DRESSED BEFORE THEY ARE WRITTEN.
	#
	# The first build did this the other way round and shipped four untinted meshes: a
	# mesh saved bare and then handed a material in memory is referenced by the packed
	# scene EXTERNALLY, so the runtime loads the bare copy off disk, renders it with
	# Godot's default white material, and the `tint` instance uniform lands on a shader
	# that does not exist. Every avatar came out beige. The order below is the fix and
	# it is the whole of it.
	var body_mat: Material = _body_material()
	var lens_mat: Material = _lens_material()
	var ghost_mat: Material = _ghost_material(0.16, 0.78, 2.6, 0.55)
	var bubble_mat: Material = _ghost_material(0.10, 0.58, 1.8, 0.70)
	var dot_mat: Material = _dot_material()
	var beacon_mat: Material = _beacon_material()
	_write(body_mat, BODY_MAT_PATH)
	_write(lens_mat, LENS_MAT_PATH)
	_write(ghost_mat, GHOST_MAT_PATH)
	_write(bubble_mat, BUBBLE_MAT_PATH)
	_write(dot_mat, DOT_MAT_PATH)
	_write(beacon_mat, BEACON_MAT_PATH)

	var capsule: ArrayMesh = _capsule_mesh()
	var sphere: ArrayMesh = _sphere_mesh()
	var visor: ArrayMesh = _visor_mesh()
	var temples: ArrayMesh = _temples_mesh()
	capsule.surface_set_material(0, body_mat)
	sphere.surface_set_material(0, bubble_mat)
	visor.surface_set_material(0, lens_mat)
	temples.surface_set_material(0, lens_mat)
	_write(capsule, CAPSULE_PATH)
	_write(sphere, SPHERE_PATH)
	_write(visor, VISOR_PATH)
	_write(temples, TEMPLES_PATH)

	var avatar: Node = _build_avatar(capsule, sphere, visor, temples, ghost_mat, beacon_mat)
	_save_scene(avatar, AVATAR_SCENE_PATH)
	avatar.free()
	var cursor: Node = _build_cursor(dot_mat)
	_save_scene(cursor, CURSOR_SCENE_PATH)
	cursor.free()

	_report()


# --- geometry ----------------------------------------------------------------


## The body. A capsule standing on the origin, so the prefab's own transform is the
## player's feet and no node in the tree carries a magic half-height offset.
func _capsule_mesh() -> ArrayMesh:
	var v := PackedVector3Array()
	var n := PackedVector3Array()
	var r: float = BODY_RADIUS
	var top: float = STAND_HEIGHT - r
	var bottom: float = r
	for i: int in SEGMENTS:
		var t0: float = TAU * float(i) / float(SEGMENTS)
		var t1: float = TAU * float(i + 1) / float(SEGMENTS)
		var d0 := Vector3(cos(t0), 0.0, sin(t0))
		var d1 := Vector3(cos(t1), 0.0, sin(t1))
		# The barrel. Normals are the radial direction, so the ring is smooth and the
		# scrap shader's own flat-shading branch is left off. The corner order is
		# UP first and AROUND second, which is what puts `(b-a) x (c-a)` on the outward
		# normal — the other order is the same quad wound inside out.
		_quad_n(
			v,
			n,
			d0 * r + Vector3.UP * bottom,
			d0 * r + Vector3.UP * top,
			d1 * r + Vector3.UP * top,
			d1 * r + Vector3.UP * bottom,
			[d0, d0, d1, d1]
		)
		_cap(v, n, d0, d1, top, r, 1.0)
		_cap(v, n, d0, d1, bottom, r, -1.0)
	return _commit(v, n, "capsule")


## One column of a hemisphere, from the equator to the pole. `up` is +1 for the crown
## and -1 for the base, which mirrors the whole thing without a second loop.
func _cap(
	v: PackedVector3Array,
	n: PackedVector3Array,
	d0: Vector3,
	d1: Vector3,
	centre: float,
	r: float,
	up: float
) -> void:
	for j: int in CAP_RINGS:
		var p0: float = PI * 0.5 * float(j) / float(CAP_RINGS)
		var p1: float = PI * 0.5 * float(j + 1) / float(CAP_RINGS)
		var n00: Vector3 = _cap_normal(d0, p0, up)
		var n10: Vector3 = _cap_normal(d1, p0, up)
		var n01: Vector3 = _cap_normal(d0, p1, up)
		var n11: Vector3 = _cap_normal(d1, p1, up)
		var origin: Vector3 = Vector3.UP * centre
		# Mirroring the hemisphere through the equator reverses its handedness, so the
		# base column is wound the other way round. Nothing else about the two differs.
		var order: Array = [n00, n01, n11, n10] if up > 0.0 else [n00, n10, n11, n01]
		if j == CAP_RINGS - 1:
			# The pole is one triangle per column, not a degenerate quad.
			_tri_n(
				v,
				n,
				origin + order[0] * r,
				origin + order[1] * r,
				origin + order[3] * r,
				order[0],
				order[1],
				order[3]
			)
			continue
		_quad_n(
			v,
			n,
			origin + order[0] * r,
			origin + order[1] * r,
			origin + order[2] * r,
			origin + order[3] * r,
			order
		)


static func _cap_normal(dir: Vector3, phi: float, up: float) -> Vector3:
	return (dir * cos(phi) + Vector3.UP * (sin(phi) * up)).normalized()


func _sphere_mesh() -> ArrayMesh:
	var v := PackedVector3Array()
	var n := PackedVector3Array()
	var centre := Vector3.UP * BUBBLE_CENTRE
	for i: int in SPHERE_SEGMENTS:
		var t0: float = TAU * float(i) / float(SPHERE_SEGMENTS)
		var t1: float = TAU * float(i + 1) / float(SPHERE_SEGMENTS)
		for j: int in SPHERE_RINGS:
			var p0: float = PI * (float(j) / float(SPHERE_RINGS) - 0.5)
			var p1: float = PI * (float(j + 1) / float(SPHERE_RINGS) - 0.5)
			# Wound UP the column first and AROUND second — a, d, c, b — for the same
			# reason the capsule's barrel is: the other order is the shell inside out.
			var a: Vector3 = _ball_normal(t0, p0)
			var b: Vector3 = _ball_normal(t1, p0)
			var c: Vector3 = _ball_normal(t1, p1)
			var d: Vector3 = _ball_normal(t0, p1)
			if j == 0:
				# South pole: a and b are the same vertex.
				_tri_n(
					v,
					n,
					centre + a * BUBBLE_RADIUS,
					centre + d * BUBBLE_RADIUS,
					centre + c * BUBBLE_RADIUS,
					a,
					d,
					c
				)
				continue
			if j == SPHERE_RINGS - 1:
				# North pole: c and d are the same vertex.
				_tri_n(
					v,
					n,
					centre + a * BUBBLE_RADIUS,
					centre + d * BUBBLE_RADIUS,
					centre + b * BUBBLE_RADIUS,
					a,
					d,
					b
				)
				continue
			_quad_n(
				v,
				n,
				centre + a * BUBBLE_RADIUS,
				centre + d * BUBBLE_RADIUS,
				centre + c * BUBBLE_RADIUS,
				centre + b * BUBBLE_RADIUS,
				[a, d, c, b]
			)
	return _commit(v, n, "sphere")


static func _ball_normal(theta: float, phi: float) -> Vector3:
	return Vector3(cos(phi) * cos(theta), sin(phi), cos(phi) * sin(theta)).normalized()


## The lens band. A closed arc shell — outer wall, inner wall, top, bottom and two end
## caps — swept across the front of the head. The inner wall sits INSIDE the capsule so
## the two solids overlap at the joint; a band that merely touched would show a seam the
## first time the sun was not square to it.
##
## The radius is solved rather than picked: at `EYE_HEIGHT` the capsule is in its crown
## hemisphere, so its cross-section there is a circle of radius sqrt(r^2 - dy^2), and
## the band is set against that.
func _visor_mesh() -> ArrayMesh:
	var v := PackedVector3Array()
	var n := PackedVector3Array()
	var dy: float = EYE_HEIGHT - (STAND_HEIGHT - BODY_RADIUS)
	var head_r: float = sqrt(maxf(BODY_RADIUS * BODY_RADIUS - dy * dy, 0.0001))
	var r_in: float = head_r - VISOR_SINK
	var r_out: float = head_r + VISOR_PROUD
	var half: float = VISOR_HEIGHT * 0.5
	# The capsule faces -Z, so the front of the head is at -PI/2 in the (x, z) circle.
	var mid: float = -PI * 0.5
	for i: int in VISOR_SEGMENTS:
		var t0: float = mid + VISOR_HALF_ANGLE * (2.0 * float(i) / float(VISOR_SEGMENTS) - 1.0)
		var t1: float = mid + VISOR_HALF_ANGLE * (2.0 * float(i + 1) / float(VISOR_SEGMENTS) - 1.0)
		var d0 := Vector3(cos(t0), 0.0, sin(t0))
		var d1 := Vector3(cos(t1), 0.0, sin(t1))
		var y0: float = EYE_HEIGHT - half
		var y1: float = EYE_HEIGHT + half
		# Outer wall outward, inner wall inward, then the two rims. Each is wound so
		# `(b - a) x (c - a)` lands on its own outward normal; the inner wall is
		# therefore the mirror of the outer one and not a copy of it.
		_quad_n(
			v,
			n,
			d0 * r_out + Vector3.UP * y0,
			d0 * r_out + Vector3.UP * y1,
			d1 * r_out + Vector3.UP * y1,
			d1 * r_out + Vector3.UP * y0,
			[d0, d0, d1, d1]
		)
		_quad_n(
			v,
			n,
			d0 * r_in + Vector3.UP * y0,
			d1 * r_in + Vector3.UP * y0,
			d1 * r_in + Vector3.UP * y1,
			d0 * r_in + Vector3.UP * y1,
			[-d0, -d1, -d1, -d0]
		)
		_quad_flat(
			v,
			n,
			d0 * r_in + Vector3.UP * y1,
			d1 * r_in + Vector3.UP * y1,
			d1 * r_out + Vector3.UP * y1,
			d0 * r_out + Vector3.UP * y1,
			Vector3.UP
		)
		_quad_flat(
			v,
			n,
			d0 * r_out + Vector3.UP * y0,
			d1 * r_out + Vector3.UP * y0,
			d1 * r_in + Vector3.UP * y0,
			d0 * r_in + Vector3.UP * y0,
			Vector3.DOWN
		)
		if i == 0:
			_end_cap(v, n, d0, r_in, r_out, y0, y1, -1.0)
		if i == VISOR_SEGMENTS - 1:
			_end_cap(v, n, d1, r_in, r_out, y0, y1, 1.0)
	return _commit(v, n, "visor")


func _end_cap(
	v: PackedVector3Array,
	n: PackedVector3Array,
	dir: Vector3,
	r_in: float,
	r_out: float,
	y0: float,
	y1: float,
	side: float
) -> void:
	# The cap faces along the arc's tangent, which is the radial direction turned a
	# quarter turn about Y — signed so both ends face outward.
	var face := Vector3(-dir.z, 0.0, dir.x) * side
	var a: Vector3 = dir * r_in + Vector3.UP * y0
	var b: Vector3 = dir * r_out + Vector3.UP * y0
	var c: Vector3 = dir * r_out + Vector3.UP * y1
	var d: Vector3 = dir * r_in + Vector3.UP * y1
	if side > 0.0:
		_quad_flat(v, n, a, b, c, d, face)
		return
	_quad_flat(v, n, d, c, b, a, face)


## Both temple arms, in one surface. Two boxes; they overlap the head, they do not touch
## it, which is the same joint rule the band follows.
func _temples_mesh() -> ArrayMesh:
	var v := PackedVector3Array()
	var n := PackedVector3Array()
	var dy: float = EYE_HEIGHT - (STAND_HEIGHT - BODY_RADIUS)
	var head_r: float = sqrt(maxf(BODY_RADIUS * BODY_RADIUS - dy * dy, 0.0001))
	# Outward far enough that the inner face is inside the head at the arm's widest
	# point, which is the end nearest the front of the face.
	var x: float = sqrt(maxf(head_r * head_r - TEMPLE_Z * TEMPLE_Z, 0.0001)) + 0.006
	for side: float in [-1.0, 1.0]:
		_box(v, n, TEMPLE_SIZE, Vector3(x * side, EYE_HEIGHT, TEMPLE_Z))
	return _commit(v, n, "temples")


func _box(v: PackedVector3Array, n: PackedVector3Array, size: Vector3, at: Vector3) -> void:
	var h: Vector3 = size * 0.5
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
		var centre: Vector3 = at + normal * (normal.abs() * h).length()
		var a: Vector3 = t1 * (t1.abs() * h).length()
		var b: Vector3 = t2 * (t2.abs() * h).length()
		_quad_flat(v, n, centre - a - b, centre + a - b, centre + a + b, centre - a + b, normal)


func _quad_flat(
	v: PackedVector3Array,
	n: PackedVector3Array,
	a: Vector3,
	b: Vector3,
	c: Vector3,
	d: Vector3,
	normal: Vector3
) -> void:
	_quad_n(v, n, a, b, c, d, [normal, normal, normal, normal])


func _quad_n(
	v: PackedVector3Array,
	n: PackedVector3Array,
	a: Vector3,
	b: Vector3,
	c: Vector3,
	d: Vector3,
	normals: Array
) -> void:
	_tri_n(v, n, a, b, c, normals[0], normals[1], normals[2])
	_tri_n(v, n, a, c, d, normals[0], normals[2], normals[3])


## Callers hand a, b, c COUNTER-CLOCKWISE about the outward normal — the right-hand
## convention every face table in this project is written in. Godot's front face is
## CLOCKWISE, so the order turns round here and nowhere else.
func _tri_n(
	v: PackedVector3Array,
	n: PackedVector3Array,
	a: Vector3,
	b: Vector3,
	c: Vector3,
	na: Vector3,
	nb: Vector3,
	nc: Vector3
) -> void:
	v.push_back(a)
	v.push_back(c)
	v.push_back(b)
	n.push_back(na)
	n.push_back(nc)
	n.push_back(nb)


func _commit(v: PackedVector3Array, n: PackedVector3Array, tag: String) -> ArrayMesh:
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = v
	arrays[Mesh.ARRAY_NORMAL] = n
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	_audit(v, tag)
	return mesh


## Divergence-theorem volume about the centroid, plus a welded edge census. An
## outward-wound closed shell has NEGATIVE volume by the right-hand form under Godot's
## clockwise front face, and uses every edge exactly twice, once in each direction.
func _audit(v: PackedVector3Array, tag: String) -> void:
	_shells += 1
	var count: int = v.size() / 3
	var centroid := Vector3.ZERO
	for p: Vector3 in v:
		centroid += p
	centroid /= float(maxi(v.size(), 1))
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
			edges[key] = int(edges.get(key, 0)) + (1 if p < q else -1)
	volume /= 6.0
	var open: int = 0
	for key: String in edges:
		if int(edges[key]) != 0:
			open += 1
	var ok: bool = volume < 0.0 and open == 0 and degenerate == 0
	if not ok:
		_failures += 1
	_lines.append(
		(
			"  %-9s %s  tris %5d  volume %+0.6f  open %d  degenerate %d"
			% [tag, "PASS" if ok else "FAIL", count, volume, open, degenerate]
		)
	)


static func _key(p: Vector3) -> String:
	return "%d,%d,%d" % [roundi(p.x / WELD), roundi(p.y / WELD), roundi(p.z / WELD)]


# --- materials ---------------------------------------------------------------


## The shell. Polymer branch of the scrap shader, over a LIGHT albedo, because the
## player colour arrives as the `tint` instance uniform and the shader does
## `albedo * tint * COLOR`. A mid-value base would render every player as a silhouette.
func _body_material() -> Material:
	var mat := ShaderMaterial.new()
	mat.shader = _shader(SCRAP_SHADER)
	mat.set_shader_parameter(&"surface_type", 2)
	mat.set_shader_parameter(&"albedo", SHELL_ALBEDO)
	mat.set_shader_parameter(&"metallic_base", 0.06)
	mat.set_shader_parameter(&"roughness_base", 0.62)
	mat.set_shader_parameter(&"detail_scale", 3.2)
	mat.set_shader_parameter(&"detail_gain", 1.0)
	mat.set_shader_parameter(&"bump_scale", 26.0)
	mat.set_shader_parameter(&"bump_amount", 0.011)
	# The mesh ships smooth normals on purpose: a faceted capsule reads as a mistake.
	mat.set_shader_parameter(&"flat_shaded", false)
	mat.set_shader_parameter(&"emission_energy", 0.0)
	return mat


## The lenses. The one smooth, dark, specular surface on the whole avatar — which is
## exactly why the sunglasses read at distance: a dark band with a moving highlight on a
## light matte body is the strongest two-value contrast the palette allows.
func _lens_material() -> Material:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = LENS_ALBEDO
	mat.metallic = 0.55
	mat.metallic_specular = 0.65
	mat.roughness = 0.10
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	return mat


func _ghost_material(body: float, rim: float, power: float, shade: float) -> Material:
	var mat := ShaderMaterial.new()
	mat.shader = _shader(GHOST_SHADER)
	mat.set_shader_parameter(&"body_alpha", body)
	mat.set_shader_parameter(&"rim_alpha", rim)
	mat.set_shader_parameter(&"rim_power", power)
	mat.set_shader_parameter(&"body_shade", shade)
	return mat


func _dot_material() -> Material:
	var mat := ShaderMaterial.new()
	mat.shader = _shader(DOT_SHADER)
	mat.set_shader_parameter(&"ink_color", INK)
	mat.set_shader_parameter(&"dot_color", Color(1.0, 1.0, 1.0, 1.0))
	return mat


func _beacon_material() -> Material:
	var mat := ShaderMaterial.new()
	mat.shader = _shader(BEACON_SHADER)
	mat.set_shader_parameter(&"ink_color", INK)
	mat.set_shader_parameter(&"aspect", BEACON_ASPECT)
	return mat


func _shader(path: String) -> Shader:
	var shader := ResourceLoader.load(path, "Shader") as Shader
	if shader == null:
		push_error("build_avatar: missing shader %s." % path)
	return shader


# --- the prefabs -------------------------------------------------------------


func _build_avatar(
	capsule: ArrayMesh,
	sphere: ArrayMesh,
	visor: ArrayMesh,
	temples: ArrayMesh,
	ghost_mat: Material,
	beacon_mat: Material
) -> Node3D:
	var root: Node3D = (load(SCRIPT_AVATAR) as Script).new()
	root.name = "PlayerAvatar"

	var body := Node3D.new()
	body.name = "Body"
	root.add_child(body)
	body.add_child(_mesh_node("Shell", capsule, null, true, true))
	body.add_child(_mesh_node("Ghost", capsule, ghost_mat, false))
	body.add_child(_mesh_node("Bubble", sphere, null, false))
	body.add_child(_mesh_node("Visor", visor, null, true, true))
	body.add_child(_mesh_node("Temples", temples, null, true, true))
	body.add_child(_hull())

	var plate: Node3D = _plate("Plate", PLATE_FONT_SIZE, PLATE_PIXEL_SIZE, 22.0, 0.92)
	plate.position = Vector3(0.0, PLATE_HEIGHT, 0.0)
	root.add_child(plate)

	var beacon := _mesh_node("Beacon", _beacon_quad(beacon_mat), null, false)
	beacon.position = Vector3(0.0, BEACON_BASE, 0.0)
	root.add_child(beacon)

	_own(root, root)
	return root


func _build_cursor(dot_mat: Material) -> Node3D:
	var root: Node3D = (load(SCRIPT_CURSOR) as Script).new()
	root.name = "LaserCursor"

	var quad := QuadMesh.new()
	quad.size = Vector2.ONE
	quad.material = dot_mat
	root.add_child(_mesh_node("Dot", quad, null, true))

	# The hover label: small, semi-transparent, and it does NOT fade with distance,
	# because you can only be shown it by deliberately putting your own dot on somebody
	# else's and a fade would delete the answer at exactly the range you had to work
	# for it.
	var plate: Node3D = _plate("Plate", HOVER_FONT_SIZE, HOVER_PIXEL_SIZE, 15.0, 0.62)
	plate.set(&"fade_start", 2000.0)
	plate.set(&"fade_end", 4000.0)
	plate.visible = false
	root.add_child(plate)

	_own(root, root)
	return root


## `shown` is the FULL-mode default; `PlayerAvatar.set_mode` owns it from then on.
##
## Shadows are OFF unless asked for, and that is the safe default here: a translucent
## shell casting an opaque shadow is the single most obvious tell that a ghost is a
## solid with its alpha turned down, and a billboard dot casting one is a black smear
## on the wall beside it.
func _mesh_node(
	node_name: String, mesh: Mesh, override: Material, shown: bool, shadows: bool = false
) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	node.name = node_name
	node.mesh = mesh
	node.visible = shown
	node.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	if override != null:
		node.material_override = override
	if not shadows:
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return node


func _beacon_quad(beacon_mat: Material) -> QuadMesh:
	var quad := QuadMesh.new()
	quad.size = Vector2(1.0, 1.0)
	# Pivot at the FOOT of the shaft, so the node's own position is where the mark
	# starts and scaling it grows the mark upward instead of through the player.
	quad.center_offset = Vector3(0.0, 0.5, 0.0)
	quad.material = beacon_mat
	return quad


func _plate(node_name: String, size: int, pixel: float, pixels: float, alpha: float) -> Node3D:
	var plate: Node3D = (load(SCRIPT_PLATE) as Script).new()
	plate.name = node_name
	plate.set(&"font_size", size)
	plate.set(&"pixel_size", pixel)
	plate.set(&"outline_size", PLATE_OUTLINE)
	plate.set(&"outline_modulate", INK)
	plate.set(&"target_pixels", pixels)
	plate.set(&"base_alpha", alpha)
	plate.set(&"text", "")
	if ResourceLoader.exists(FONT_PATH):
		plate.set(&"font", ResourceLoader.load(FONT_PATH, "Font"))
	return plate


## An `AnimatableBody3D` and not a `StaticBody3D`: the avatar is moved by transform every
## frame, and that is precisely the node built for a collider that is driven rather than
## simulated. `sync_to_physics` is off because the drive happens on the visual frame.
##
## The layer is PLAYER and the mask is nothing — this body blocks, it does not detect.
## See `PlayerAvatar.set_collision_enabled` for why it is inert until the movement mask
## opts in.
func _hull() -> CollisionObject3D:
	var hull := AnimatableBody3D.new()
	hull.name = "Hull"
	hull.sync_to_physics = false
	hull.collision_layer = GameLayers.PLAYER
	hull.collision_mask = 0
	var shape := CapsuleShape3D.new()
	shape.radius = BODY_RADIUS
	shape.height = STAND_HEIGHT
	var node := CollisionShape3D.new()
	node.name = "Shape"
	node.shape = shape
	node.position = Vector3(0.0, STAND_HEIGHT * 0.5, 0.0)
	hull.add_child(node)
	return hull


# --- writing -----------------------------------------------------------------


## Saved, then adopted. `take_over_path` is what makes the packed scenes reference these
## resources EXTERNALLY instead of embedding a private copy of every mesh in both
## prefabs — which is the difference between one capsule on disk and three.
func _write(res: Resource, path: String) -> void:
	var err: Error = ResourceSaver.save(res, path)
	if err != OK:
		push_error("build_avatar: could not save %s (error %d)." % [path, err])
		_failures += 1
		return
	res.take_over_path(path)


func _save_scene(root: Node, path: String) -> void:
	var packed := PackedScene.new()
	var err: Error = packed.pack(root)
	if err != OK:
		push_error("build_avatar: packing %s failed (error %d)." % [path, err])
		_failures += 1
		return
	err = ResourceSaver.save(packed, path)
	if err != OK:
		push_error("build_avatar: could not save %s (error %d)." % [path, err])
		_failures += 1
		return
	_lines.append("  scene     %-34s %d nodes" % [path.get_file(), _count(root)])


## `PackedScene.pack` only keeps nodes whose owner is the root.
func _own(node: Node, root: Node) -> void:
	for child: Node in node.get_children():
		if child.owner == null:
			child.owner = root
		_own(child, root)


func _count(node: Node) -> int:
	var total: int = 1
	for child: Node in node.get_children():
		total += _count(child)
	return total


func _report() -> void:
	_lines.append("")
	_lines.append("  shells %d  failures %d" % [_shells, _failures])
	_lines.append("VERDICT: %s" % ("PASS" if _failures == 0 else "FAIL"))
	var text: String = "\n".join(_lines) + "\n"
	var file := FileAccess.open(REPORT_PATH, FileAccess.WRITE)
	if file != null:
		file.store_string(text)
		file.close()
	print(text)
	if _failures > 0:
		push_error("build_avatar: %d shell or write failures." % _failures)
