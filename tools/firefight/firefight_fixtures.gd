extends RefCounted
## The firefight's diegetic hardware, authored as one `ArrayMesh` with a surface
## per part: post, vane, mast, flag, plinth, drum, needle.
##
## BAKE-TIME ONLY. `tools/build_firefight.gd` is the only caller.
##
## One mesh means one resource. The scene cannot cut an `ArrayMesh` up by surface
## at load, so each sub-assembly is authored around its own local origin and the
## scene places a `MeshInstance3D` per part with that part's offset already in the
## geometry.
##
## Every part is checked on its own rather than as one soup. A post and a vane
## never touch, so a hole in the vane would be invisible in an aggregate edge
## count the post's closed shell dominates. `open_parts` is what the bake gates on.

## Position quantisation for the edge census, in ten-thousandths of a metre.
const WELD_SCALE: float = 10000.0

## Parts that failed their own solidity check. Non-zero fails the bake.
var open_parts: int = 0
## One line per finding, plus the summary, in the caller's report voice.
var log_lines: PackedStringArray = PackedStringArray()

var _sweep_degrees: float = 220.0


## `sweep_degrees` is the dial's total needle travel. The drum's detent marks are
## cut over the same arc, so the mark and the angle the needle stops at cannot
## disagree.
func _init(sweep_degrees: float) -> void:
	_sweep_degrees = sweep_degrees


## Every diegetic control and banner in one mesh, laid out at the origin in
## sub-assemblies the scene instances at their own transforms. One mesh means one
## resource; the scene cuts it up by surface, which it cannot do, so instead each
## sub-assembly is authored around its own local origin and the scene places a
## `MeshInstance3D` per part with the part's own offset baked into the geometry.
##
## In practice that means this returns a mesh per part, packed into one ArrayMesh
## with one surface each: post, vane, mast, flag, plinth, drum, needle.
func build(material: Material) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	var parts: Array = [
		["post", _mesh_post()],
		["vane", _mesh_vane()],
		["mast", _mesh_mast()],
		["flag", _mesh_flag()],
		["plinth", _mesh_plinth()],
		["drum", _mesh_drum()],
		["needle", _mesh_needle()],
	]
	for entry: Array in parts:
		var m: WorldMesher = entry[1]
		# Each fixture is checked on its own rather than as part of one soup. A
		# post and a vane never touch, so a hole in the vane would be invisible in
		# an aggregate edge count that the post's own closed shell dominates.
		var volume: float = m.signed_volume()
		var open_edges: int = boundary_edges(m.vertices())
		if volume <= 0.0 or open_edges != 0 or m.degenerate_count() != 0:
			open_parts += 1
			log_lines.push_back(
				(
					"fixture FAIL          %-8s volume %+.4f, %d boundary edges, %d degenerate"
					% [entry[0], volume, open_edges, m.degenerate_count()]
				)
			)
		mesh.add_surface_from_arrays(
			Mesh.PRIMITIVE_TRIANGLES, m.arrays(), [], {}, WorldMesher.surface_format()
		)
		mesh.surface_set_name(mesh.get_surface_count() - 1, entry[0])
		mesh.surface_set_material(mesh.get_surface_count() - 1, material)
	log_lines.push_back(
		"fixture solidity      %d parts, %d not watertight" % [parts.size(), open_parts]
	)
	return mesh


## Fixtures are drawn white and coloured at runtime through the `tint` instance
## uniform. One material, any number of colours, no per-instance material.
func _mesh_post() -> WorldMesher:
	var m := WorldMesher.new()
	m.box(Vector3(0.0, 0.09, 0.0), Vector3(0.62, 0.14, 0.62), 0.0, Color.WHITE, 0)
	m.cylinder(Vector3(0.0, 1.05, 0.0), 0.10, 0.085, 1.05, 12, Color.WHITE, 0)
	m.box(Vector3(0.0, 1.92, 0.0), Vector3(0.20, 0.06, 0.20), 0.0, Color.WHITE, 0)
	return m


func _mesh_vane() -> WorldMesher:
	var m := WorldMesher.new()
	m.box(Vector3(0.0, 0.0, -0.70), Vector3(0.045, 0.30, 0.72), 0.0, Color.WHITE, 0)
	m.box(Vector3(0.0, 0.0, -1.34), Vector3(0.04, 0.11, 0.16), 0.0, Color.WHITE, 0)
	m.cylinder(Vector3.ZERO, 0.11, 0.11, 0.09, 10, Color.WHITE, 0)
	return m


func _mesh_mast() -> WorldMesher:
	var m := WorldMesher.new()
	m.box(Vector3(0.0, 0.16, 0.0), Vector3(0.95, 0.20, 0.95), 0.0, Color.WHITE, 0)
	m.cylinder(Vector3(0.0, 3.2, 0.0), 0.13, 0.07, 3.15, 10, Color.WHITE, 0)
	m.strut(Vector3(0.0, 0.3, 0.0), Vector3(0.78, 1.5, 0.0), 0.045, Color.WHITE, 0)
	m.strut(Vector3(0.0, 0.3, 0.0), Vector3(-0.39, 1.5, 0.68), 0.045, Color.WHITE, 0)
	m.strut(Vector3(0.0, 0.3, 0.0), Vector3(-0.39, 1.5, -0.68), 0.045, Color.WHITE, 0)
	return m


func _mesh_flag() -> WorldMesher:
	var m := WorldMesher.new()
	m.box(Vector3(0.62, 0.0, 0.0), Vector3(0.60, 0.38, 0.035), 0.0, Color.WHITE, 0)
	m.box(Vector3(1.20, -0.12, 0.0), Vector3(0.12, 0.20, 0.030), 0.0, Color.WHITE, 0)
	m.cylinder(Vector3.ZERO, 0.055, 0.055, 0.42, 8, Color.WHITE, 0, Vector3.UP)
	return m


func _mesh_plinth() -> WorldMesher:
	var m := WorldMesher.new()
	m.box(Vector3(0.0, 0.22, 0.0), Vector3(0.72, 0.24, 0.60), 0.0, Color.WHITE, 0)
	m.box(Vector3(0.0, 0.66, -0.10), Vector3(0.56, 0.26, 0.42), 0.0, Color.WHITE, 0)
	return m


## The drum, with five detent marks on the rim as real geometry at exactly the
## angles the needle stops at. The marks stand proud of the rim rather than being
## cut into it: a groove in a closed shell is a hole in a closed shell, and this
## bake refuses to write one of those.
func _mesh_drum() -> WorldMesher:
	var m := WorldMesher.new()
	m.cylinder(Vector3(0.0, 0.0, 0.0), 0.30, 0.30, 0.055, 20, Color.WHITE, 0, Vector3.FORWARD)
	var detents: int = 5
	var sweep: float = deg_to_rad(_sweep_degrees)
	for i: int in detents:
		var t: float = float(i) / float(detents - 1)
		var ang: float = sweep * (0.5 - t)
		# Local +Y at zero, swinging through the same arc `FirefightDial` drives
		# the needle over, so the needle and the mark it stops at are the same
		# angle by construction and cannot drift when either is retuned.
		var ey := Vector3(-sin(ang), cos(ang), 0.0)
		var ex := Vector3(cos(ang), sin(ang), 0.0)
		var tall: float = 0.058 if i == detents / 2 else 0.038
		m.oriented_box(
			ey * 0.255 + Vector3(0.0, 0.0, 0.03),
			ex * 0.014,
			ey * tall,
			Vector3(0.0, 0.0, 0.026),
			Color.WHITE,
			0
		)
	return m


func _mesh_needle() -> WorldMesher:
	var m := WorldMesher.new()
	m.box(Vector3(0.0, 0.17, 0.03), Vector3(0.022, 0.19, 0.020), 0.0, Color.WHITE, 0)
	m.cylinder(Vector3(0.0, 0.0, 0.03), 0.055, 0.055, 0.026, 10, Color.WHITE, 0, Vector3.FORWARD)
	return m


## Edges used exactly once across the whole soup. A pile of closed solids,
## however much they interpenetrate, uses every edge twice.
static func boundary_edges(pos: PackedVector3Array) -> int:
	var ids: Dictionary = {}
	var use: Dictionary = {}
	var tris: int = pos.size() / 3
	for t: int in tris:
		var a: int = _intern(ids, pos[t * 3])
		var b: int = _intern(ids, pos[t * 3 + 1])
		var c: int = _intern(ids, pos[t * 3 + 2])
		_bump(use, a, b)
		_bump(use, b, c)
		_bump(use, c, a)
	var n: int = 0
	for v: int in use.values():
		if v == 1:
			n += 1
	return n


static func _intern(ids: Dictionary, p: Vector3) -> int:
	var key := Vector3i(
		roundi(p.x * WELD_SCALE), roundi(p.y * WELD_SCALE), roundi(p.z * WELD_SCALE)
	)
	var found: int = ids.get(key, -1)
	if found >= 0:
		return found
	var id: int = ids.size()
	ids[key] = id
	return id


static func _bump(use: Dictionary, a: int, b: int) -> void:
	var key: int = (mini(a, b) << 24) | maxi(a, b)
	use[key] = int(use.get(key, 0)) + 1
