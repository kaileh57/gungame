@tool
extends SceneTree
## Shooting-range bake: four hundred metres of dirt, a bay somebody works in, and
## every target in `docs/spec/range.md` §15.
##
##   godot --headless --path <project> --script res://tools/build_range.gd
##
## Writes
##   res://demos/range/meshes/*.res      every solid this level is made of
##   res://demos/range/paper_face.res    the ring target's printed face
##   res://demos/range/ammo_counter.tscn the magazine plate that rides the gun
##   res://demos/range/range.tscn        the demo SceneRouter routes to as "range"
##   res://demos/range/range_report.txt  the self-test
##
## The geometry itself is authored by the two kits beside the demo —
## `RangeBayKit` and `RangeTargetKit` — through the shared `RangeShop`, which
## validates and saves every mesh. This file lays out the level and packs it.
##
## NOTHING HERE NAMES AN AUTOLOAD. A `--script` main loop compiles before the tree
## has bound its singletons, so a builder that mentions `GunFactory` at compile
## time arrives with no script at all. The demo's own scripts name them freely —
## they are attached by path, and they load at play time like everything else.
##
## HOW THE GEOMETRY IS KEPT HONEST. Every solid comes out of `WorldMesher`, which
## emits closed outward-wound boxes, cylinders and struts and nothing else. Joints
## overlap: a post enters the slab it stands on, a berm course sits inside the
## course below it, the shed roof laps over its wall plates. The report at the end
## states each mesh's signed volume and normal-conflict count, and the bake exits
## non-zero if any shell reads inside out.
##
## Down-range is -Z. The firing line is z = 0. Targets are placed at -distance,
## which is the reference's convention and the one every number in the spec uses.

const SCENE_PATH: String = "res://demos/range/range.tscn"
const REPORT_PATH: String = "res://demos/range/range_report.txt"
const AMMO_SCENE_PATH: String = "res://demos/range/ammo_counter.tscn"

const WORLD_MATERIAL: String = "res://art/materials/world_surface.tres"
## The prop catalogue `tools/build_props.gd` bakes. The junk down the shoulders
## of the lane is instanced out of it rather than authored again here.
const PROP_SET: String = "res://data/world/props/props.tres"
const SCAV_WORLD_SCENE: String = "res://art/scav_world.tscn"
const VFX_SCENE: String = "res://data/vfx/vfx.tscn"
const PLAYER_SCENE: String = "res://data/player/player.tscn"

const BUTTON_SCENE: String = "res://ui/diegetic/diegetic_button.tscn"
const LEVER_SCENE: String = "res://ui/diegetic/diegetic_lever.tscn"
const DIAL_SCENE: String = "res://ui/diegetic/diegetic_dial.tscn"
const READOUT_SCENE: String = "res://ui/diegetic/diegetic_readout.tscn"

## Seats the lane screen on its stanchion; no standoff here is picked by hand.
const PanelMount := preload("res://ui/diegetic/panel_mount.gd")

const DEMO_SCRIPT: String = "res://demos/range/range_demo.gd"
const SHOOTER_SCRIPT: String = "res://demos/range/range_shooter.gd"
const BENCH_SCRIPT: String = "res://demos/range/weapon_bench.gd"
const AMBIENCE_SCRIPT: String = "res://demos/range/range_ambience.gd"
const AMMO_COUNTER_SCRIPT: String = "res://ui/hud/ammo_counter.gd"
## The demo's whole networking spine, on ONE node at a FIXED path. Godot routes an
## RPC by node path, so `Range/RangeNet` has to exist, be spelled the same and sit
## in the same place on every machine — which is exactly what baking it into the
## scene guarantees and what a node added at runtime would not.
const NET_SCRIPT: String = "res://demos/range/range_net.gd"

## Master bake seed. Rocks, casings and clutter are drawn off it, so the level is
## byte-identical between runs and a diff of range.tscn means something changed.
const SEED: int = 0x5A17_C0DE

# --- the level, in metres ----------------------------------------------------

## Ground slab: how far it reaches and how deep it goes.
const GROUND_HALF_X: float = 300.0
const GROUND_Z_NEAR: float = 140.0
const GROUND_Z_FAR: float = -520.0
const GROUND_DEPTH: float = 2.4
## Ground grid cell. 15 m keeps the vertex count at four figures and is still
## fine enough that the colour drift reads as ground rather than as facets.
const GROUND_CELL: float = 15.0
## Peak ground undulation outside the lane corridor. Zero inside it: a target
## that floats a centimetre or sinks one is the defect this whole project is
## about, and flat dirt under the lane is how that is guaranteed.
const GROUND_RELIEF: float = 0.55
const CORRIDOR_HALF: float = 24.0

## Distance markers, metres down-range.
const MARKER_DISTANCES: PackedFloat32Array = [15.0, 35.0, 70.0, 140.0, 250.0, 400.0]

## The lane readout and the stanchion it is bolted to. One description of the plate,
## used by the mesher and by `PanelMount`, so the screen's standoff cannot drift from
## the steel it stands on.
const LANE_POST_AT: Vector3 = Vector3(-7.4, 0.75, 0.30)
const LANE_POST_HALF: Vector3 = Vector3(0.07, 0.85, 0.07)
const LANE_PANEL_AT: Vector3 = Vector3(-7.4, 1.85, 0.32)
const LANE_PANEL_HALF: Vector3 = Vector3(0.80, 0.62, 0.06)
const LANE_READOUT_SCALE: float = 1.35

## Depth the first berm course reaches below the pad, metres. Each course above
## it goes BERM_SINK_STEP deeper again — see `_berm`.
const BERM_SINK: float = 0.4
## Extra depth per course, and the distance each course's outer face is set back
## from the one below it. Both exist for the same reason: three boxes that share
## a face plane are coplanar, which z-fights along the whole 440 m outer wall,
## and where they share a bottom edge as well they weld into a six-triangle
## non-manifold seam. A tenth of a metre is invisible at berm scale and makes
## every face its own plane.
const BERM_SINK_STEP: float = 0.2
const BERM_SETBACK: float = 0.15

## Half-width of every backstop course. The side berms' outer faces stand at
## x = +/-51, so 51 here would put two solids on the same plane: they weld into
## one component along a four-triangle edge, which is a butted joint and reads as
## a seam. 50 buries each end a metre inside the berm it meets, which is an
## overlap and cannot open.
const BACKSTOP_HALF_W: float = 50.0

## Wall thickness of a lamp shade, metres.
const SHADE_WALL: float = 0.012

## The yard kit carries no `class_name`: a global class added to the project is
## invisible to a `--script` main loop until the editor rescans and rewrites
## `.godot/global_script_class_cache.cfg`, so naming one here would break the
## headless bake on a clean checkout. Preloading by path needs no cache.
const YardKit := preload("res://demos/range/build/range_yard_kit.gd")

var _shop: RangeShop = null
var _rand: XorShift32 = null


func _initialize() -> void:
	var t0: int = Time.get_ticks_msec()
	if DirAccess.make_dir_recursive_absolute(RangeShop.MESH_DIR) != OK:
		push_error("build_range: cannot create %s." % RangeShop.MESH_DIR)
		quit(1)
		return
	_rand = XorShift32.new(SEED)
	var shared := ResourceLoader.load(WORLD_MATERIAL, "Material") as Material
	if shared == null:
		push_error("build_range: %s is missing. Run tools/build_art.gd first." % WORLD_MATERIAL)
		quit(1)
		return
	_shop = RangeShop.new(shared)

	_build_ammo_counter()
	var root: Node3D = _build_scene()
	_save_scene(root)
	root.free()

	_shop.report.push_back("bake time             %d ms" % (Time.get_ticks_msec() - t0))
	_shop.report.push_back("result                %s" % ("FAIL" if _shop.failed else "PASS"))
	var text: String = "\n".join(_shop.report) + "\n"
	var f := FileAccess.open(REPORT_PATH, FileAccess.WRITE)
	if f != null:
		f.store_string(text)
		f.close()
	print(text)
	quit(1 if _shop.failed else 0)


# ============================================================== scene assembly


func _build_scene() -> Node3D:
	var root := Node3D.new()
	root.name = "Range"
	root.set_script(load(DEMO_SCRIPT))

	_add_instance(root, SCAV_WORLD_SCENE, "ScavWorld", Vector3.ZERO)
	_add_instance(root, VFX_SCENE, "Vfx", Vector3.ZERO)

	# First of the demo's own nodes, so that anything asking "am I the authority"
	# from its `_ready` has already had the answer settled — `RangeNet` binds in
	# `_enter_tree`, and Godot runs every `_enter_tree` in a scene before any
	# `_ready`, so this is belt as well as braces.
	var wire := Node.new()
	wire.name = "RangeNet"
	wire.set_script(load(NET_SCRIPT))
	root.add_child(wire)

	_build_ground(root)
	RangeBayKit.new(_shop).build(root)
	_build_lane(root)
	YardKit.new(_shop, _rand).build(root)
	RangeScatterKit.new(_shop, _rand).build(root, _prop_set())
	_build_lights(root)

	var targets := Node3D.new()
	targets.name = "Targets"
	root.add_child(targets)
	RangeTargetKit.new(_shop, _rand).build(targets)

	var bench: Node3D = _build_bench(root)

	var player: Node3D = _add_instance(
		root, PLAYER_SCENE, "Player", Vector3(0.0, RangeShop.PAD_TOP, 5.5)
	)
	if player != null:
		var shooter := Node3D.new()
		shooter.name = "Shooter"
		shooter.set_script(load(SHOOTER_SCRIPT))
		root.add_child(shooter)
		shooter.set("player_path", NodePath("../Player"))

	var ambience := Node3D.new()
	ambience.name = "Ambience"
	ambience.set_script(load(AMBIENCE_SCRIPT))
	root.add_child(ambience)

	root.set("bench_path", NodePath("Bench"))
	root.set("targets_path", NodePath("Targets"))
	root.set("shooter_path", NodePath("Shooter"))
	root.set("player_path", NodePath("Player"))
	root.set("lane_readout_path", NodePath("Lane/LaneReadout"))
	root.set("net_path", NodePath("RangeNet"))
	if bench == null:
		_shop.fail("bench was not built")
	return root


## The baked prop catalogue, or null with a note when it has not been built. The
## range is a complete level without it — the shoulders are simply bare — so a
## missing catalogue is reported and survived rather than failed.
func _prop_set() -> WorldPropSet:
	if not ResourceLoader.exists(PROP_SET):
		_shop.note("prop set", "MISSING %s — run tools/build_props.gd" % PROP_SET)
		return null
	var catalogue := ResourceLoader.load(PROP_SET, "WorldPropSet") as WorldPropSet
	if catalogue == null:
		_shop.note("prop set", "UNREADABLE %s" % PROP_SET)
		return null
	_shop.note("prop set", "%s (%d props)" % [PROP_SET, catalogue.count()])
	return catalogue


func _save_scene(root: Node3D) -> void:
	_shop.own_all(root, root)
	var packed := PackedScene.new()
	if packed.pack(root) != OK:
		_shop.fail("PackedScene.pack failed")
		return
	if ResourceSaver.save(packed, SCENE_PATH) != OK:
		_shop.fail("could not save %s" % SCENE_PATH)
		return
	_shop.note("scene", "%s (%d nodes)" % [SCENE_PATH, _count_nodes(root)])


func _count_nodes(node: Node) -> int:
	var n: int = 1
	for child: Node in node.get_children():
		n += _count_nodes(child)
	return n


## Instance a baked scene, keeping it editable so the demo's own scripts can read
## into it. Returns null and records a failure when the scene is missing, because
## a demo without its player is not a demo.
func _add_instance(root: Node3D, path: String, node_name: String, at: Vector3) -> Node3D:
	var packed := ResourceLoader.load(path, "PackedScene") as PackedScene
	if packed == null:
		_shop.fail("missing scene %s" % path)
		return null
	# Instantiated ONCE and then narrowed. `scav_world.tscn`'s root is a
	# `WorldEnvironment`, which is a plain `Node`, so the Node3D cast legitimately
	# fails for it — instantiating a second time to get the untyped node orphans
	# the first tree for the rest of the run.
	var plain: Node = packed.instantiate()
	if plain == null:
		_shop.fail("could not instance %s" % path)
		return null
	plain.name = node_name
	var node := plain as Node3D
	if node != null:
		node.position = at
	root.add_child(plain)
	return node


# =================================================================== the ground


## One closed slab: a relief-displaced top grid, a skirt round its rim and a
## floor. Built as a solid rather than as a plane so that standing in a crater or
## flying the freecam under the map never shows the world's underside missing.
func _build_ground(root: Node3D) -> void:
	var m := WorldMesher.new()
	var nx: int = int(ceil(GROUND_HALF_X * 2.0 / GROUND_CELL))
	var nz: int = int(ceil((GROUND_Z_NEAR - GROUND_Z_FAR) / GROUND_CELL))
	var x0: float = -GROUND_HALF_X
	var z0: float = GROUND_Z_FAR
	var floor_y: float = -GROUND_DEPTH

	var height := PackedFloat32Array()
	var tone := PackedFloat32Array()
	height.resize((nx + 1) * (nz + 1))
	tone.resize((nx + 1) * (nz + 1))
	for iz: int in nz + 1:
		for ix: int in nx + 1:
			var x: float = x0 + float(ix) * GROUND_CELL
			var z: float = z0 + float(iz) * GROUND_CELL
			height[iz * (nx + 1) + ix] = _ground_height(
				x, z, ix == 0 or ix == nx or iz == 0 or iz == nz
			)
			tone[iz * (nx + 1) + ix] = RangeShop.hash01(ix * 7919 + iz * 104729)

	for iz: int in nz:
		for ix: int in nx:
			var xa: float = x0 + float(ix) * GROUND_CELL
			var xb: float = xa + GROUND_CELL
			var za: float = z0 + float(iz) * GROUND_CELL
			var zb: float = za + GROUND_CELL
			var i00: int = iz * (nx + 1) + ix
			var i10: int = i00 + 1
			var i01: int = i00 + nx + 1
			var i11: int = i01 + 1
			var a := Vector3(xa, height[i00], za)
			var b := Vector3(xb, height[i10], za)
			var c := Vector3(xb, height[i11], zb)
			var d := Vector3(xa, height[i01], zb)
			var shade: float = (tone[i00] + tone[i11]) * 0.5
			var col: Color = RangeShop.C_DIRT.lerp(RangeShop.C_DIRT_DARK, shade)
			# Counter-clockwise seen from above is (a, d, c, b): +X then +Z.
			m.quad(a, d, c, b, col, RangeShop.SURF_SAND)

	# Rim skirt, four walls, each wound so its outward face points away from the
	# pan, then the floor wound to face down. `quad` takes its corners
	# counter-clockwise seen from the front, so the two -Z/-X walls run the
	# opposite way round from the +Z/+X pair.
	for ix: int in nx:
		var xa: float = x0 + float(ix) * GROUND_CELL
		var xb: float = xa + GROUND_CELL
		m.quad(
			Vector3(xb, floor_y, z0),
			Vector3(xa, floor_y, z0),
			Vector3(xa, 0.0, z0),
			Vector3(xb, 0.0, z0),
			RangeShop.C_DIRT_DARK,
			RangeShop.SURF_ROCK
		)
		var zn: float = GROUND_Z_NEAR
		m.quad(
			Vector3(xa, floor_y, zn),
			Vector3(xb, floor_y, zn),
			Vector3(xb, 0.0, zn),
			Vector3(xa, 0.0, zn),
			RangeShop.C_DIRT_DARK,
			RangeShop.SURF_ROCK
		)
	for iz: int in nz:
		var za: float = z0 + float(iz) * GROUND_CELL
		var zb: float = za + GROUND_CELL
		m.quad(
			Vector3(x0, floor_y, za),
			Vector3(x0, floor_y, zb),
			Vector3(x0, 0.0, zb),
			Vector3(x0, 0.0, za),
			RangeShop.C_DIRT_DARK,
			RangeShop.SURF_ROCK
		)
		var xe: float = -x0
		m.quad(
			Vector3(xe, floor_y, zb),
			Vector3(xe, floor_y, za),
			Vector3(xe, 0.0, za),
			Vector3(xe, 0.0, zb),
			RangeShop.C_DIRT_DARK,
			RangeShop.SURF_ROCK
		)
	m.quad(
		Vector3(x0, floor_y, z0),
		Vector3(-x0, floor_y, z0),
		Vector3(-x0, floor_y, GROUND_Z_NEAR),
		Vector3(x0, floor_y, GROUND_Z_NEAR),
		RangeShop.C_DIRT_DARK,
		RangeShop.SURF_ROCK
	)

	var mesh: ArrayMesh = _shop.commit(m, "ground")
	var mi := MeshInstance3D.new()
	mi.name = "GroundMesh"
	mi.mesh = mesh
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED

	var body := StaticBody3D.new()
	body.name = "Ground"
	body.collision_layer = GameLayers.WORLD
	body.collision_mask = 0
	body.set_meta(&"surface", &"sand")
	body.add_child(mi)
	# One box under the whole pan. The relief is under half a metre and entirely
	# outside the corridor, so a plane collider is exact where anyone stands and
	# never wrong by more than the height of a boot anywhere else.
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(GROUND_HALF_X * 2.0, GROUND_DEPTH, GROUND_Z_NEAR - GROUND_Z_FAR)
	shape.shape = box
	shape.position = Vector3(0.0, -GROUND_DEPTH * 0.5, (GROUND_Z_NEAR + GROUND_Z_FAR) * 0.5)
	body.add_child(shape)
	root.add_child(body)


## Relief is flat inside the corridor the targets stand in and ramps up outside
## it, so nothing the player shoots at is ever half-buried or floating.
func _ground_height(x: float, z: float, rim: bool) -> float:
	if rim:
		return 0.0
	var out: float = maxf(absf(x) - CORRIDOR_HALF, 0.0)
	var behind: float = maxf(z - 22.0, 0.0)
	var reach: float = clampf(maxf(out, behind) / 70.0, 0.0, 1.0)
	if reach <= 0.0:
		return 0.0
	var n: float = sin(x * 0.031 + 1.7) * cos(z * 0.024 - 0.6) + sin(z * 0.055) * 0.4
	return n * GROUND_RELIEF * reach


# ===================================================================== the lane


## Firing pad, lane posts, berms, backstop and the distance markers. One mesh:
## it is all static, it is all the same material, and it is what the player looks
## at for the whole demo, so it wants to be one draw call.
func _build_lane(root: Node3D) -> void:
	var lane := Node3D.new()
	lane.name = "Lane"
	root.add_child(lane)

	var near := WorldMesher.new()
	var far := WorldMesher.new()
	var bodies: Array[Node3D] = []

	# Pad. Sunk 0.2 m into the ground so its hem never opens.
	near.box(
		Vector3(RangeShop.PAD_CENTER.x, RangeShop.PAD_CENTER.y - 0.10, RangeShop.PAD_CENTER.z),
		Vector3(RangeShop.PAD_HALF.x, RangeShop.PAD_HALF.y + 0.10, RangeShop.PAD_HALF.z),
		0.0,
		RangeShop.C_PAD,
		RangeShop.SURF_CONCRETE
	)
	bodies.append(
		_shop.box_body(
			"Pad",
			Vector3(RangeShop.PAD_CENTER.x, RangeShop.PAD_CENTER.y - 0.10, RangeShop.PAD_CENTER.z),
			Vector3(
				RangeShop.PAD_HALF.x * 2.0,
				(RangeShop.PAD_HALF.y + 0.10) * 2.0,
				RangeShop.PAD_HALF.z * 2.0
			),
			&"concrete"
		)
	)
	# Kerb along the down-range lip, so the pad reads as poured and not as a decal.
	near.box(
		Vector3(0.0, 0.36, RangeShop.PAD_CENTER.z - RangeShop.PAD_HALF.z + 0.09),
		Vector3(RangeShop.PAD_HALF.x, 0.20, 0.09),
		0.0,
		RangeShop.C_PAD.darkened(0.12),
		RangeShop.SURF_CONCRETE
	)

	# Five lane posts on the firing line.
	for i: int in range(-2, 3):
		var px: float = float(i) * 4.2
		near.box(
			Vector3(px, 0.72, -1.6),
			Vector3(0.06, 0.72, 0.06),
			0.0,
			RangeShop.C_MARKER_POST,
			RangeShop.SURF_METAL
		)
		near.box(
			Vector3(px, 1.40, -1.6),
			Vector3(0.10, 0.04, 0.10),
			0.0,
			RangeShop.C_STEEL_DARK,
			RangeShop.SURF_METAL
		)

	_berm(far, -46.0, true)
	_berm(far, 46.0, false)
	_backstop(far)
	bodies.append(
		_shop.box_body("BermLeft", Vector3(-46.0, 3.3, -170.0), Vector3(10.0, 7.4, 440.0), &"sand")
	)
	bodies.append(
		_shop.box_body("BermRight", Vector3(46.0, 3.3, -170.0), Vector3(10.0, 7.4, 440.0), &"sand")
	)
	bodies.append(
		_shop.box_body("Backstop", Vector3(0.0, 4.3, -392.0), Vector3(102.0, 9.4, 12.0), &"sand")
	)

	for d: float in MARKER_DISTANCES:
		_marker(lane, d, near if d <= 70.0 else far)

	var near_mesh: ArrayMesh = _shop.commit(near, "lane_near")
	var far_mesh: ArrayMesh = _shop.commit(far, "lane_far")
	_shop.add_mesh(lane, "LaneNear", near_mesh, true)
	# The berms and the backstop are 440 m long and 7 m high. Inside the
	# directional shadow cascade they are the single most expensive thing in the
	# level, and what they buy is a shadow you can only see by standing on top of
	# one. They are lit and they receive; they do not cast.
	_shop.add_mesh(lane, "LaneFar", far_mesh, false)
	for body: Node3D in bodies:
		lane.add_child(body)

	# The readout the shooter reads without turning round: score, streak and the
	# group the paper target last measured. Faces up-range, off to the left of
	# the lane so it never covers a target.
	#
	# The mount sits at LOWER z than the screen: the shooter stands down-range of
	# the post, so behind the readout is behind in -Z, and a plate at +Z would
	# stand between the panel and the eye reading it. Which is exactly why the
	# screen's own z is solved off that plate rather than written down: a
	# `DiegeticReadout` reaches 60 mm behind its origin, 81 mm at this scale.
	var post := WorldMesher.new()
	post.box(LANE_POST_AT, LANE_POST_HALF, 0.0, RangeShop.C_MARKER_POST, RangeShop.SURF_METAL)
	post.box(LANE_PANEL_AT, LANE_PANEL_HALF, 0.0, RangeShop.C_POST, RangeShop.SURF_METAL)
	_shop.add_mesh(lane, "LaneReadoutMount", _shop.commit(post, "lane_readout_mount"), true)
	var readout: Node3D = _readout(lane, "LaneReadout", Vector3.ZERO, 0.0, false)
	if readout != null:
		var seat := PanelMount.new()
		seat.panel_scale = LANE_READOUT_SCALE
		var plate: AABB = PanelMount.half_box(LANE_PANEL_AT, LANE_PANEL_HALF)
		var at := Vector3(LANE_PANEL_AT.x, LANE_PANEL_AT.y, 0.0)
		seat.apply(readout, plate, at, "LaneReadoutMount")


## Earthworks, not a wall: three courses, each inside the one below, every course
## reaching 0.4 m under the pan so the hem cannot open.


## A side berm as three stacked courses, each narrower and shorter-topped than
## the one below, all reaching under the pad so there is no ground seam. The
## courses overlap generously in width; they are never flush.
func _berm(m: WorldMesher, x: float, left: bool) -> void:
	var sign_x: float = -1.0 if left else 1.0
	var courses: Array = [
		[5.0, 2.6, 0.0, RangeShop.C_BERM],
		[4.0, 4.8, 1.0, RangeShop.C_BERM.lerp(RangeShop.C_BERM_TOP, 0.45)],
		[3.0, 7.0, 2.0, RangeShop.C_BERM_TOP],
	]
	for k: int in courses.size():
		var course: Array = courses[k]
		var half_w: float = float(course[0]) - BERM_SETBACK * float(k)
		var top: float = float(course[1])
		var inset: float = float(course[2])
		var sink: float = BERM_SINK + BERM_SINK_STEP * float(k)
		var cx: float = x + sign_x * inset
		m.box(
			Vector3(cx, (top - sink) * 0.5, -170.0),
			Vector3(half_w, (top + sink) * 0.5, 220.0),
			0.0,
			course[3] as Color,
			RangeShop.SURF_SAND
		)


func _backstop(m: WorldMesher) -> void:
	var courses: Array = [
		[6.0, 3.4, 0.0, RangeShop.C_BERM],
		[4.5, 6.2, 1.5, RangeShop.C_BERM.lerp(RangeShop.C_BERM_TOP, 0.45)],
		[3.0, 9.0, 3.0, RangeShop.C_BERM_TOP],
	]
	for k: int in courses.size():
		var course: Array = courses[k]
		var half_d: float = float(course[0]) - BERM_SETBACK * float(k)
		var top: float = float(course[1])
		var back: float = float(course[2])
		var sink: float = BERM_SINK + BERM_SINK_STEP * float(k)
		m.box(
			Vector3(0.0, (top - sink) * 0.5, -392.0 - back),
			Vector3(BACKSTOP_HALF_W, (top + sink) * 0.5, half_d),
			0.0,
			course[3] as Color,
			RangeShop.SURF_SAND
		)


## Post, plate and the number, readable from both sides because you walk past it.
func _marker(lane: Node3D, distance: float, m: WorldMesher) -> void:
	var z: float = -distance
	m.box(
		Vector3(RangeShop.MARKER_X, 1.15, z),
		Vector3(0.08, 1.35, 0.08),
		0.0,
		RangeShop.C_MARKER_POST,
		RangeShop.SURF_METAL
	)
	m.box(
		Vector3(RangeShop.MARKER_X, 2.62, z),
		Vector3(0.72, 0.38, 0.035),
		0.0,
		RangeShop.C_SIGN,
		RangeShop.SURF_WOOD
	)
	m.box(
		Vector3(RangeShop.MARKER_X, 2.28, z),
		Vector3(0.10, 0.34, 0.05),
		0.0,
		RangeShop.C_MARKER_POST,
		RangeShop.SURF_METAL
	)

	var holder := Node3D.new()
	holder.name = "Marker%d" % int(distance)
	holder.position = Vector3(RangeShop.MARKER_X, 2.62, z)
	lane.add_child(holder)
	for face: int in 2:
		var label := Label3D.new()
		label.name = "Front" if face == 0 else "Back"
		label.text = "%d m" % int(distance)
		label.font = ResourceLoader.load(RangeShop.FONT_DISPLAY, "Font") as Font
		label.font_size = 64
		label.pixel_size = 0.0088
		label.modulate = Color("1c1a18")
		label.outline_size = 0
		label.shaded = true
		label.double_sided = false
		label.no_depth_test = false
		label.position = Vector3(0.0, 0.0, 0.042 if face == 0 else -0.042)
		label.rotation.y = 0.0 if face == 0 else PI
		# Big signs at 400 m still have to be legible, so they never fade out.
		label.visibility_range_end = 0.0
		holder.add_child(label)


# ===================================================================== lighting

## Wall thickness of a work-light shade, metres. Pressed steel, and thick enough
## that the rim reads as an edge rather than a crease at conversational range.


## A conical lamp shade as a closed thin-walled shell: outer wall, inner wall,
## and an annulus at each rim.
##
## A shade has to stay open at the bottom or it hides its own bulb, and the
## cheap way to get that is an uncapped cone -- which is a hole. The far side of
## a single-sided cone is backfacing, so you see straight through the lamp to
## the roof. Two walls and two rims cost 4x the triangles of the cheat and are
## watertight, which is the bar. Winding is derived, not guessed: the outer wall
## repeats `WorldMesher.cylinder`'s own quad order, the inner wall reverses it,
## and each rim is ordered so its normal points away from the material.
static func _shade(
	m: WorldMesher,
	at: Vector3,
	r_bot: float,
	r_top: float,
	hy: float,
	wall: float,
	segments: int,
	col: Color,
	surf: int
) -> void:
	var seg: int = maxi(3, segments)
	var y_bot: float = at.y - hy
	var y_top: float = at.y + hy
	var ob := PackedVector3Array()
	var ot := PackedVector3Array()
	var ib := PackedVector3Array()
	var it := PackedVector3Array()
	ob.resize(seg)
	ot.resize(seg)
	ib.resize(seg)
	it.resize(seg)
	for i: int in seg:
		var ang: float = float(i) / float(seg) * TAU
		# Matches cylinder()'s frame for a +Y axis: ax = +Z, az = -X.
		var dir := Vector3(-sin(ang), 0.0, cos(ang))
		ob[i] = Vector3(at.x, y_bot, at.z) + dir * r_bot
		ot[i] = Vector3(at.x, y_top, at.z) + dir * r_top
		ib[i] = Vector3(at.x, y_bot, at.z) + dir * maxf(r_bot - wall, 0.001)
		it[i] = Vector3(at.x, y_top, at.z) + dir * maxf(r_top - wall, 0.001)
	for i: int in seg:
		var j: int = (i + 1) % seg
		m.quad(ob[i], ot[i], ot[j], ob[j], col, surf)  # outer wall, faces out
		m.quad(ib[i], ib[j], it[j], it[i], col, surf)  # inner wall, faces in
		m.quad(ob[i], ob[j], ib[j], ib[i], col, surf)  # bottom rim, faces down
		m.quad(it[i], it[j], ot[j], ot[i], col, surf)  # top rim, faces up


## Work lights under the bay roof and a lamp over the pedestal. Four omnis with
## short ranges and no shadows: the sun does the shadow work outside, and inside
## the bay the geometry is small enough that shadowless fill reads correctly.
func _build_lights(root: Node3D) -> void:
	var lights := Node3D.new()
	lights.name = "WorkLights"
	lights.add_to_group(&"range_work_lights")
	root.add_child(lights)

	var m := WorldMesher.new()
	var specs: Array = [
		[Vector3(RangeShop.BAY_CENTER_X - 3.6, 3.10, 11.4), 6.5, 2.6, Color(1.0, 0.85, 0.62)],
		[Vector3(RangeShop.BAY_CENTER_X + 2.6, 3.10, 14.6), 6.0, 2.2, Color(1.0, 0.84, 0.60)],
		[Vector3(RangeShop.BAY_CENTER_X, 2.55, 12.9), 4.2, 3.4, Color(1.0, 0.93, 0.78)],
	]
	for i: int in specs.size():
		var spec: Array = specs[i]
		var at: Vector3 = spec[0] as Vector3
		var lamp := OmniLight3D.new()
		lamp.name = "Lamp%d" % i
		lamp.position = at + Vector3(0.0, -0.12, 0.0)
		lamp.omni_range = float(spec[1])
		lamp.light_energy = float(spec[2])
		lamp.light_color = spec[3] as Color
		lamp.shadow_enabled = false
		lamp.distance_fade_enabled = true
		lamp.distance_fade_begin = 34.0
		lamp.distance_fade_length = 10.0
		lights.add_child(lamp)
		# Shade and flex, hung off the roof purlin.
		m.strut(
			at + Vector3(0.0, 0.42, 0.0),
			at + Vector3(0.02, 0.06, 0.0),
			0.008,
			RangeShop.C_LAMP,
			RangeShop.SURF_METAL
		)
		_shade(m, at, 0.16, 0.06, 0.09, SHADE_WALL, 12, RangeShop.C_LAMP, RangeShop.SURF_METAL)
		m.cylinder(
			at + Vector3(0.0, 0.09, 0.0),
			0.06,
			0.06,
			0.02,
			12,
			RangeShop.C_LAMP,
			RangeShop.SURF_METAL
		)
		m.cylinder(
			at + Vector3(0.0, -0.06, 0.0),
			0.045,
			0.045,
			0.035,
			10,
			Color("ffe6b4"),
			RangeShop.SURF_POLY
		)
	_shop.add_mesh(lights, "Fittings", _shop.commit(m, "work_lights"), false)


# ======================================================================== bench


## The weapon bench, expressed entirely as things you shoot. A dial picks the
## class, a lever scavenges, five buttons swap one part each, two buttons equip,
## one resets the range. Two readouts carry the stat card. No screen panel
## anywhere; if you want to know what a gun is, you read the placard.
func _build_bench(root: Node3D) -> Node3D:
	var bench := Node3D.new()
	bench.name = "Bench"
	bench.set_script(load(BENCH_SCRIPT))
	root.add_child(bench)

	var y_top: float = RangeShop.CONSOLE_PANEL_Y + 0.30
	var y_bot: float = RangeShop.CONSOLE_PANEL_Y - 0.30
	var slots: Array = [
		["reroll_receiver", "RECEIVER", -2.85, y_top],
		["reroll_barrel", "BARREL", -1.95, y_top],
		["reroll_grip", "GRIP", -1.05, y_top],
		["reroll_stock", "STOCK", -0.15, y_top],
		["reroll_sight", "SIGHT", 0.75, y_top],
		["equip_primary", "EQUIP", 1.95, y_top],
		["equip_sidearm", "SIDEARM", 2.85, y_top],
		["reset_range", "RESET", 2.85, y_bot],
		["clear_paper", "NEW PAPER", 1.95, y_bot],
	]
	for entry: Array in slots:
		var button: Node3D = _control(bench, BUTTON_SCENE, String(entry[0]))
		if button == null:
			continue
		button.position = Vector3(
			RangeShop.BAY_CENTER_X + float(entry[2]), float(entry[3]), RangeShop.CONSOLE_FACE_Z
		)
		button.rotation.y = PI
		button.set("control_id", StringName(entry[0]))
		button.set("label_text", String(entry[1]))

	var dial: Node3D = _control(bench, DIAL_SCENE, "class_dial")
	if dial != null:
		dial.position = Vector3(RangeShop.BAY_CENTER_X - 2.85, y_bot, RangeShop.CONSOLE_FACE_Z)
		dial.rotation.y = PI
		dial.set("control_id", &"class_dial")
		dial.set("label_text", "CLASS")
		# Labels come off `GunTables.CLASS_MIX`, the same source the demo reads, so a
		# detent can never point at a class name the roller does not recognise.
		var class_labels := PackedStringArray(["ANY"])
		for row: Array in GunTables.CLASS_MIX:
			class_labels.append(String(row[0]).to_upper())
		dial.set("options", class_labels)
		dial.set("wraps", true)

	var lever: Node3D = _control(bench, LEVER_SCENE, "scavenge_lever")
	if lever != null:
		# On the open bench top and clear of the panel: at the console's own z the
		# lever would stand inside the steel face the caps are bolted to.
		lever.position = Vector3(
			RangeShop.BAY_CENTER_X - 1.05, RangeShop.CONSOLE_TOP + 0.04, RangeShop.CONSOLE_Z - 0.15
		)
		lever.rotation.y = PI
		lever.set("control_id", &"scavenge_lever")
		lever.set("label_text", "SCAVENGE")
		lever.set("off_text", "SET")
		lever.set("on_text", "PULLED")
		lever.set("throw_degrees", 42.0)

	var card: Node3D = _readout(
		bench,
		"CardReadout",
		Vector3(RangeShop.BAY_CENTER_X - 3.3, 2.42, RangeShop.BAY_Z_FAR - 0.20),
		PI,
		false
	)
	if card != null:
		card.scale = Vector3(1.5, 1.5, 1.5)
	var parts: Node3D = _readout(
		bench,
		"PartsReadout",
		Vector3(RangeShop.BAY_CENTER_X + 3.3, 2.42, RangeShop.BAY_Z_FAR - 0.20),
		PI,
		true
	)
	if parts != null:
		parts.scale = Vector3(1.4, 1.4, 1.4)

	# The placard above the bench. This is the only writing in the demo that
	# explains anything, and it is a painted board bolted to a wall.
	var sign := Node3D.new()
	sign.name = "Placard"
	sign.position = Vector3(RangeShop.BAY_CENTER_X, 3.02, RangeShop.BAY_Z_FAR - 0.20)
	sign.rotation.y = PI
	bench.add_child(sign)
	var sm := WorldMesher.new()
	sm.box(
		Vector3.ZERO,
		Vector3(2.4, 0.26, 0.035),
		0.0,
		RangeShop.C_SIGN.darkened(0.1),
		RangeShop.SURF_WOOD
	)
	_shop.add_mesh(sign, "Board", _shop.commit(sm, "placard"), false)
	var text := Label3D.new()
	text.name = "Text"
	text.text = "SHOOT THE BENCH TO WORK IT"
	text.font = ResourceLoader.load(RangeShop.FONT_DISPLAY, "Font") as Font
	text.font_size = 64
	text.pixel_size = 0.0052
	text.modulate = Color("1c1a18")
	text.shaded = true
	text.double_sided = false
	text.position = Vector3(0.0, 0.0, 0.04)
	sign.add_child(text)

	var stand := Node3D.new()
	stand.name = "Stand"
	stand.position = Vector3(RangeShop.BAY_CENTER_X, 1.30, 12.9)
	bench.add_child(stand)

	bench.set("stand_path", NodePath("Stand"))
	bench.set("card_path", NodePath("CardReadout"))
	bench.set("parts_path", NodePath("PartsReadout"))
	return bench


func _control(bench: Node3D, scene_path: String, node_name: String) -> Node3D:
	var packed := ResourceLoader.load(scene_path, "PackedScene") as PackedScene
	if packed == null:
		_shop.fail("missing control scene %s" % scene_path)
		return null
	var node := packed.instantiate() as Node3D
	if node == null:
		_shop.fail("could not instance %s" % scene_path)
		return null
	node.name = node_name
	bench.add_child(node)
	return node


func _readout(parent: Node3D, node_name: String, at: Vector3, yaw: float, painted: bool) -> Node3D:
	var packed := ResourceLoader.load(READOUT_SCENE, "PackedScene") as PackedScene
	if packed == null:
		_shop.fail("missing %s" % READOUT_SCENE)
		return null
	var node := packed.instantiate() as Node3D
	if node == null:
		return null
	node.name = node_name
	node.position = at
	node.rotation.y = yaw
	node.set("painted", painted)
	parent.add_child(node)
	return node


## The magazine count, on the gun rather than on the screen. A scratched plate
## welded to the left of the receiver, with the count stencilled into it — which
## is what `AmmoCounter` was written to drive and what the project's diegetic rule
## wants instead of a 44 px number in the corner.
##
## Baked as its own scene because `RangeShooter` parents it to the holster's hand
## at play time, and a demo does not author geometry while it is running.
func _build_ammo_counter() -> void:
	var root := Node3D.new()
	root.name = "AmmoCounter"
	root.set_script(load(AMMO_COUNTER_SCRIPT))

	var m := WorldMesher.new()
	m.box(Vector3.ZERO, Vector3(0.052, 0.030, 0.004), 0.0, RangeShop.C_LAMP, RangeShop.SURF_METAL)
	# The surround. Darkened hard off `C_STEEL_DARK`: the world material gives steel
	# 0.66 metallic, so on the viewmodel pass — where the only thing there is to
	# reflect is an open desert sky — a mid-grey bezel comes back as a bright
	# chrome frame around the numbers and reads as screen furniture rather than as
	# a plate someone welded on.
	m.box(
		Vector3(0.0, 0.0, -0.003),
		Vector3(0.056, 0.034, 0.004),
		0.0,
		RangeShop.C_STEEL_DARK.darkened(0.55),
		RangeShop.SURF_METAL
	)
	var plate := MeshInstance3D.new()
	plate.name = "Plate"
	plate.mesh = _shop.commit(m, "ammo_plate")
	plate.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	plate.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	root.add_child(plate)

	var font: Font = ResourceLoader.load(RangeShop.FONT_DISPLAY, "Font") as Font
	var count := Label3D.new()
	count.name = "Count"
	count.text = "0"
	count.font = font
	count.font_size = 64
	count.pixel_size = 0.00062
	count.position = Vector3(-0.012, 0.0, 0.006)
	count.shaded = false
	count.double_sided = false
	count.no_depth_test = false
	root.add_child(count)

	var capacity := Label3D.new()
	capacity.name = "Capacity"
	capacity.text = "/0"
	capacity.font = font
	capacity.font_size = 40
	capacity.pixel_size = 0.00052
	capacity.position = Vector3(0.026, -0.008, 0.006)
	capacity.modulate = Color(0.51, 0.482, 0.435)
	capacity.shaded = false
	capacity.double_sided = false
	root.add_child(capacity)

	# Where a receiver plate sits relative to the holster hand: left of the breech,
	# canted toward the eye so it is legible without breaking the sight line.
	#
	# THE AIM IS SOLVED, NOT GUESSED. In the hand's own frame the bore runs along
	# +X and the eye sits at (-0.466, 0.142, -0.089) — that is, almost directly
	# BEHIND the breech and only nine centimetres off to the side. A plate lying
	# along the receiver flank therefore presents its edge to the shooter, and a
	# plate at the old 0.40 rad presented its BACK: `Count` and `Capacity` are
	# `double_sided = false`, so the numbers vanished and what the viewmodel put in
	# front of the eye was the blank rear face of the mount — a 10 cm sheet of
	# sky-reflecting steel, the brightest and flattest thing on screen, sitting
	# over the gun. These two angles point the plate's +Z at that eye position.
	# The counter is also stood down to three quarters: aimed square on, the full
	# plate is a billboard rather than something welded to a gun.
	root.position = Vector3(-0.062, 0.010, -0.056)
	root.rotation = Vector3(-0.315, -1.652, 0.06)
	root.scale = Vector3.ONE * 0.72

	_shop.own_all(root, root)
	var packed := PackedScene.new()
	if packed.pack(root) != OK:
		_shop.fail("could not pack the ammo counter")
	elif ResourceSaver.save(packed, AMMO_SCENE_PATH) != OK:
		_shop.fail("could not save %s" % AMMO_SCENE_PATH)
	else:
		_shop.note("ammo counter", AMMO_SCENE_PATH)
	root.free()
