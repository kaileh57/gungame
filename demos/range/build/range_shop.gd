class_name RangeShop
extends RefCounted
## The range bake's workshop: the palette, the site dimensions every kit measures
## from, and the handful of routines that turn a `WorldMesher` into a checked,
## saved, instanced mesh.
##
## BAKE-TIME ONLY. Nothing here is loaded at play time; `tools/build_range.gd` and
## the two kits beside this file are its only callers. It lives under the demo
## rather than under `res://tools/` because the kits live here, and a builder that
## reaches across the tree for its own constants is a builder nobody can move.
##
## Everything routed through `commit()` is validated the same way: a shell whose
## signed volume is not positive is inside out, and a triangle whose stored normal
## disagrees with its winding is a bug in the mesher. Both fail the bake rather
## than shipping. That single funnel is why the level can be asserted correct
## instead of inspected.

## Where every mesh this bake authors is written.
const MESH_DIR: String = "res://demos/range/meshes"
## The condensed face the signs and the placards are stencilled in.
const FONT_DISPLAY: String = "res://data/ui/font_display.tres"

# --- the site, in metres ----------------------------------------------------

## Firing pad. Its top face at 0.30 is the datum every control height and every
## piece of bay furniture is measured from.
const PAD_HALF: Vector3 = Vector3(11.0, 0.15, 5.0)
const PAD_CENTER: Vector3 = Vector3(0.0, 0.15, 3.0)
const PAD_TOP: float = 0.30

## The bay behind the firing line: where its slab starts and stops, how tall the
## four posts stand and where the corrugated roof lands on them.
const BAY_CENTER_X: float = -3.5
const BAY_Z_NEAR: float = 8.0
const BAY_Z_FAR: float = 17.4
const BAY_HALF_X: float = 7.2
const BAY_POST_TOP: float = 3.35
const BAY_ROOF_Y: float = 3.52

## The console the diegetic gear is bolted to. Its face looks back up-range, so
## you turn round from the firing line to work the bench, which is what a bench
## is. `CONSOLE_FACE_Z` is where a control's own origin sits: far enough forward
## of the panel that the cap and its label clear the steel, close enough that the
## housing is still buried in it. A button floating in front of its own console
## is the air gap this project does not have.
const CONSOLE_Z: float = 15.75
const CONSOLE_FACE_Z: float = 15.74
const CONSOLE_TOP: float = 1.06
const CONSOLE_PANEL_Y: float = 1.62

## Which side of the lane the distance markers stand on.
const MARKER_X: float = -8.5

# --- palette ----------------------------------------------------------------

const C_DIRT: Color = Color("6d6047")
const C_DIRT_DARK: Color = Color("5f5440")
const C_BERM: Color = Color("5c5138")
const C_BERM_TOP: Color = Color("6a5e42")
const C_PAD: Color = Color("4a4640")
const C_POST: Color = Color("3a352e")
const C_MARKER_POST: Color = Color("2f2c28")
const C_SIGN: Color = Color("cabfa8")
const C_STEEL: Color = Color("8a8f96")
const C_STEEL_DARK: Color = Color("6f757c")
const C_DOT: Color = Color("b4432f")
const C_RING: Color = Color("8f3323")
const C_BAND: Color = Color("c25a34")
const C_RAIL: Color = Color("4a4238")
const C_GLASS: Color = Color("4e7a52")
const C_DRUM_A: Color = Color("7a4b2a")
const C_DRUM_B: Color = Color("5c6b45")
const C_DRUM_RIB: Color = Color("3f3a32")
const C_DRUM_CAP: Color = Color("c2913a")
const C_PAPER: Color = Color("d8d2c2")
const C_ROCK_A: Color = Color("6a6152")
const C_ROCK_B: Color = Color("585044")
const C_TIN: Color = Color("6a6560")
const C_TIMBER: Color = Color("7a5230")
const C_TARP: Color = Color("6b6152")
const C_TARP_RED: Color = Color("8a4a32")
const C_BRASS: Color = Color("a8823c")
const C_LAMP: Color = Color("2e2b27")
const SURF_METAL: int = 0
const SURF_WOOD: int = 1
const SURF_POLY: int = 2
const SURF_SAND: int = 3
const SURF_CONCRETE: int = 4
const SURF_TIN: int = 5
const SURF_CLOTH: int = 6
const SURF_ROCK: int = 8

## The material every world-surface mesh in the level shares.
var material: Material = null
## Report lines, in bake order. `tools/build_range.gd` prints them.
var report: PackedStringArray = PackedStringArray()
## Set by `fail()`. The bake exits non-zero when it is true.
var failed: bool = false

var _cache: Dictionary = {}


func _init(shared_material: Material) -> void:
	material = shared_material


func prop_body(node_name: String, surface: StringName, zone: StringName) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = node_name
	body.collision_layer = GameLayers.PROP
	body.collision_mask = 0
	body.set_meta(&"surface", surface)
	body.set_meta(&"zone", zone)
	return body


func box_body(node_name: String, at: Vector3, size: Vector3, surface: StringName) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = node_name
	body.collision_layer = GameLayers.WORLD
	body.collision_mask = 0
	body.position = at
	body.set_meta(&"surface", surface)
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	body.add_child(shape)
	return body


func add_box_shape(body: StaticBody3D, at: Vector3, size: Vector3) -> void:
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	shape.position = at
	body.add_child(shape)


func add_cyl_shape(body: StaticBody3D, at: Vector3, radius: float, height: float) -> void:
	var shape := CollisionShape3D.new()
	var cyl := CylinderShape3D.new()
	cyl.radius = radius
	cyl.height = height
	shape.shape = cyl
	shape.position = at
	body.add_child(shape)


func adopt_shape(parent: Node3D, at: Vector3, size: Vector3, surface: StringName) -> void:
	var body := box_body("Collision", at, size, surface)
	parent.add_child(body)


func add_mesh(parent: Node3D, node_name: String, mesh: ArrayMesh, shadows: bool) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = node_name
	mi.mesh = mesh
	mi.cast_shadow = (
		GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		if shadows
		else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	)
	mi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	parent.add_child(mi)
	return mi


## Every node a `PackedScene` keeps needs `owner` pointing at the scene root, and
## it can only be set once the node is already inside that root's tree — hence
## one pass at the end rather than a line per node.
##
## Recursion stops at an instanced scene. A node carrying a `scene_file_path`
## brings its own children with it; claiming them here would inline the whole
## player, the whole VFX hub and every diegetic control into range.tscn and cut
## the link back to the scenes they came from.
func own_all(node: Node, root: Node) -> void:
	for child: Node in node.get_children():
		child.owner = root
		if child.scene_file_path.is_empty():
			own_all(child, root)


## Close a mesher, check it, save it and hand it back. Every mesh in the level
## goes through here, so every mesh in the level is checked.
func commit(m: WorldMesher, mesh_name: String) -> ArrayMesh:
	var mesh: ArrayMesh = m.build_mesh(material)
	var conflicts: int = m.normal_conflicts()
	var volume: float = m.signed_volume()
	var path: String = "%s/%s.res" % [MESH_DIR, mesh_name]
	if ResourceSaver.save(mesh, path) != OK:
		fail("could not save %s" % path)
	else:
		# `save` does not adopt the path, so without this the ArrayMesh is still
		# path-less and every scene referencing it embeds a second copy of the
		# geometry instead of pointing at the .res that was just written.
		mesh.take_over_path(path)
	if conflicts != 0:
		fail("%s has %d normal conflicts" % [mesh_name, conflicts])
	if volume <= 0.0:
		fail("%s reads inside out (signed volume %.4f)" % [mesh_name, volume])
	if m.degenerate_count() > 0:
		note("%s" % mesh_name, "dropped %d degenerate triangles" % m.degenerate_count())
	note(
		mesh_name,
		"%5d tris  volume %+11.3f  conflicts %d" % [m.triangle_count(), volume, conflicts]
	)
	return mesh


func cached(key: String, maker: Callable) -> ArrayMesh:
	if _cache.has(key):
		return _cache[key] as ArrayMesh
	var mesh: ArrayMesh = maker.call() as ArrayMesh
	_cache[key] = mesh
	return mesh


## A VERTICAL corrugated wall between two base points: a flat backing sheet with
## ribs raised alternately on either face, a capping rail, and posts every couple
## of metres. Every piece is a closed box, so the whole run is watertight.
##
## This exists because `WorldMesher.corrugated` cannot make one. Its profile runs
## in Y and its plane is XZ, which is a roof; asking it for a wall gets you a
## sheet lying flat in the air at wall height, which is what the bay's side used
## to be — a horizontal plate standing in for the collider beside it.
##
## `surf` defaults to steel rather than tin on purpose. The tin branch of the
## world shader mixes as far as 0.92 toward a fixed rust colour that is brighter
## in linear space than anything in this palette, so a tin wall at close range
## comes back as pale orange blotching whatever colour it was handed. The ribs
## here are real geometry, so nothing is lost by leaving that branch behind.
static func tin_wall(
	m: WorldMesher,
	a: Vector3,
	b: Vector3,
	height: float,
	rib_step: float,
	col: Color,
	surf: int = SURF_METAL
) -> void:
	var span: Vector3 = b - a
	var length: float = span.length()
	if length < 0.05 or height < 0.05:
		return
	var dir: Vector3 = span / length
	# dir x UP, which is the horizontal normal of the run.
	var nrm := Vector3(-dir.z, 0.0, dir.x)
	var up := Vector3(0.0, height * 0.5, 0.0)
	m.oriented_box(
		(a + b) * 0.5 + Vector3(0.0, height * 0.5, 0.0),
		dir * (length * 0.5),
		up,
		nrm * 0.026,
		col.darkened(0.06),
		surf
	)
	var ribs: int = maxi(2, int(round(length / maxf(rib_step, 0.15))))
	for i: int in ribs:
		var t: float = (float(i) + 0.5) / float(ribs)
		var side: float = 0.034 if i % 2 == 0 else -0.034
		m.oriented_box(
			a + dir * (t * length) + Vector3(0.0, height * 0.5, 0.0) + nrm * side,
			dir * (length / float(ribs) * 0.30),
			Vector3(0.0, height * 0.5 - 0.01, 0.0),
			nrm * 0.022,
			col,
			surf
		)
	m.oriented_box(
		(a + b) * 0.5 + Vector3(0.0, height + 0.02, 0.0),
		dir * (length * 0.5 + 0.05),
		Vector3(0.0, 0.045, 0.0),
		nrm * 0.075,
		C_POST,
		SURF_METAL
	)
	var posts: int = maxi(2, int(round(length / 2.6)) + 1)
	for i: int in posts:
		var t: float = float(i) / float(posts - 1)
		m.oriented_box(
			a + dir * (t * length) + Vector3(0.0, height * 0.5 - 0.12, 0.0),
			dir * 0.07,
			Vector3(0.0, height * 0.5 + 0.18, 0.0),
			nrm * 0.07,
			C_POST,
			SURF_METAL
		)


static func key(v: float) -> String:
	return str(int(round(v * 100.0)))


static func hash01(v: int) -> float:
	var h: int = (v * 374761393 + 668265263) & 0x7FFFFFFF
	h = (h ^ (h >> 13)) * 1274126177 & 0x7FFFFFFF
	return float(h & 0xFFFF) / 65535.0


func note(label: String, text: String) -> void:
	report.push_back("%-22s %s" % [label, text])


func fail(text: String) -> void:
	failed = true
	report.push_back("FAIL                   %s" % text)
	push_error("build_range: %s" % text)
