extends SceneTree
## Bakes `res://demos/visuals/visuals.tscn` — the look of the game, in one scene.
##
## Run headless: godot --headless --path <project> --script res://tools/build_visuals.gd
##
## A scav settlement graded into the ash flats at (-220, -40), seen from a lookout
## terrace on its east shoulder with the low sun almost in your eyes. Five town kits,
## a hundred props, six lamps, a rack of real guns, five creatures, a camera on a rail.
##
## Nothing already baked is remade — terrain, kits, props, guns, creatures, player,
## VFX hub and environment are all instanced. The only geometry authored here is the
## pad, post, rack and lamp standard, each checked for outward winding, positive
## volume and zero open boundary edges before packing.
##
## THE PAD. Terrain is nowhere flat enough for a pre-baked kit: the flattest 100 m
## square still falls 3.3 m corner to corner. So the settlement gets a graded terrace —
## three closed, overlapping, stepped boxes with a level top whose outermost course
## starts six metres BELOW the lowest ground under it. A buried closed solid cannot
## open a seam against the terrain, which is why this is not a skirt chasing heights.
##
## COMPOSITION lives in `VisualsShot`: the one hero angle and the pad coordinate of
## everything placed against it. This file bakes what that says and prints its frame
## table into the report, so the shot is checkable on numbers.

const MmBake := preload("res://tools/mm_bake.gd")
## The shot. Preloaded, not reached by class name: `--script` runs before the global
## class cache is necessarily built.
const Shot := preload("res://demos/visuals/visuals_shot.gd")
## Seats the post's screen and name plate; no standoff here is picked by hand.
const PanelMount := preload("res://ui/diegetic/panel_mount.gd")

const OUT_DIR: String = "res://demos/visuals"
const OUT_SCENE: String = "res://demos/visuals/visuals.tscn"
const OUT_PAD: String = "res://demos/visuals/pad_mesh.res"
const OUT_POST: String = "res://demos/visuals/post_mesh.res"
const OUT_RACK: String = "res://demos/visuals/rack_mesh.res"
const OUT_LAMP: String = "res://demos/visuals/lamp_mesh.res"
const OUT_BULB: String = "res://demos/visuals/bulb_mesh.res"
const OUT_REPORT: String = "res://demos/visuals/build_report.txt"

const DEMO_SCRIPT: String = "res://demos/visuals/visuals_demo.gd"
const RIG_SCRIPT: String = "res://demos/visuals/visuals_camera_rig.gd"

const WORLD_SCENE: String = "res://art/scav_world.tscn"
const TERRAIN_SCENE: String = "res://data/world/terrain/terrain.tscn"
const TERRAIN_DATA: String = "res://data/world/terrain_data.res"
const PLAYER_SCENE: String = "res://data/player/player.tscn"
const VFX_SCENE: String = "res://data/vfx/vfx.tscn"
const KIT_DIR: String = "res://data/world/kits"
const PROP_SET: String = "res://data/world/props/props.tres"
const ENEMY_DIR: String = "res://data/enemies"
const GUN_CACHE: String = "res://data/guns/cache"

const MAT_WORLD: String = "res://art/materials/world_surface.tres"
const MAT_EMBER: String = "res://art/materials/glow_ember.tres"

const CTL_DIAL: String = "res://ui/diegetic/diegetic_dial.tscn"
const CTL_SLIDER: String = "res://ui/diegetic/diegetic_slider.tscn"
const CTL_LEVER: String = "res://ui/diegetic/diegetic_lever.tscn"
const CTL_READOUT: String = "res://ui/diegetic/diegetic_readout.tscn"

## Where the settlement is graded in: the flattest ground outside the town.
const SITE: Vector2 = Vector2(-220.0, -40.0)
## Half-extents of the level top course, metres. Everything built stands inside it.
const PAD_HALF: Vector2 = Vector2(56.0, 48.0)
## Each course out from the top is this much wider and this much lower.
const STEP_OUT: float = 4.5
const STEP_DOWN: float = 0.95
const STEP_COUNT: int = 3
const PAD_BURY: float = 6.0
const PAD_CLEAR: float = 0.25

## Tread rise of the stair off the back of the deck. Where it stands is `VisualsShot`.
const STEP_RISE: float = 0.6
const STEP_TREADS: int = 4

## Floor albedo. Darker than the terrain's sand: flat ground is the brightest case in
## `world_material.gdshader` (slope-darkening drops out at a straight-up normal), so
## raw terrain colours read as bleached paper here.
const PAD_FLOOR: Color = Color("60503a")
## The deck is read at arm's length. Dusted concrete, not asphalt: the asphalt branch
## carries drift and wear at 9 m and 22 m wavelengths, which on a 21 m slab is one
## blotch that reads as cloud. Warm too — a dark neutral flat under a 12-degree sun
## catches only sky and turns blue.
const DECK_FLOOR: Color = Color("6b5f4c")

const SEED: int = 0x5E17
const SEG: int = 12
const WELD: float = 0.0002

## Weapons standing in the rack, left to right. Real cache entries, real specs.
const RACK_GUNS: PackedStringArray = ["rifle_t5", "shotgun_t3", "smg_t4", "sniper_t6", "lmg_t4"]

## The post's face is canted off vertical so you read it looking down, standing at it.
const POST_TOP_Y: float = 1.02
const POST_FACE_TILT: float = deg_to_rad(24.0)
## The two solids anything on the post mounts against, and the raked name plate that
## had its lower line inside the first. One description each, used by the mesher AND
## by the mount, so the two cannot disagree.
const POST_PLINTH_AT: Vector3 = Vector3(0.0, 0.16, 0.0)
const POST_PLINTH_HALF: Vector3 = Vector3(1.30, 0.56, 0.55)
const POST_MAST_AT: Vector3 = Vector3(0.0, 1.72, -0.34)
const POST_MAST_HALF: Vector3 = Vector3(0.66, 0.30, 0.045)
const POST_PLACARD_RAKE_DEG: float = 17.19
const POST_PLACARD_Y: float = 0.72
## Fallback bounds for the name plate: a headless `Label3D` reports no AABB at all,
## because its geometry is a glyph run the text server has not been asked to lay out.
const POST_PLACARD_SIZE: Vector3 = Vector3(1.10, 0.14, 0.0)

var _mat_world: Material = null
var _mat_ember: Material = null
var _terrain: WorldTerrainData = null
var _props: WorldPropSet = null
var _rng: XorShift32 = null

var _pad_top: float = 0.0
var _pad_bottom: float = 0.0

var _report: PackedStringArray = PackedStringArray()
var _failures: int = 0
var _shells: int = 0


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	_rng = XorShift32.new(SEED)
	_line("build_visuals")
	_line("")

	_mat_world = load(MAT_WORLD) as Material
	_mat_ember = load(MAT_EMBER) as Material
	_terrain = load(TERRAIN_DATA) as WorldTerrainData
	_props = load(PROP_SET) as WorldPropSet
	if _mat_world == null or _terrain == null or _props == null:
		_fail("a required baked input is missing; run the world and art bakes first")
		_finish()
		return
	_terrain.build_lut()
	_measure_site()
	_frame_report()
	_line("")

	var root := _build_scene()
	_set_owner(root, root)
	var packed := PackedScene.new()
	if packed.pack(root) != OK:
		_fail("PackedScene.pack failed")
		_finish()
		return
	if ResourceSaver.save(packed, OUT_SCENE) != OK:
		_fail("could not save %s" % OUT_SCENE)
	root.free()
	_load_back()
	_finish()


## Fix the terrace's two heights from the ground it is cut into: the top clears the
## highest point under it, the bottom is buried below the lowest.
func _measure_site() -> void:
	var top_hi: float = -1.0e9
	var wide: Vector2 = PAD_HALF + Vector2.ONE * (STEP_OUT * float(STEP_COUNT - 1))
	var wide_lo: float = 1.0e9
	var samples: int = 0
	var step: float = 2.0
	var x: float = -wide.x
	while x <= wide.x:
		var z: float = -wide.y
		while z <= wide.y:
			var h: float = _terrain.ground_h(SITE.x + x, SITE.y + z)
			wide_lo = minf(wide_lo, h)
			if absf(x) <= PAD_HALF.x and absf(z) <= PAD_HALF.y:
				top_hi = maxf(top_hi, h)
			samples += 1
			z += step
		x += step
	_pad_top = top_hi + PAD_CLEAR
	_pad_bottom = wide_lo - PAD_BURY
	_line("site                  (%.0f, %.0f)" % [SITE.x, SITE.y])
	_line("terrain samples       %d at %.1f m" % [samples, step])
	var fill: float = _pad_top - _pad_bottom
	_line("pad top / bottom      %.3f / %.3f m  (%.2f m fill)" % [_pad_top, _pad_bottom, fill])


func _world_of(local: Vector2) -> Vector3:
	return Vector3(SITE.x + local.x, _pad_top, SITE.y + local.y)


## Where the player stands: at the parapet, left of the deck's centre.
func _stand() -> Vector3:
	return _deck_of(Shot.STAND_LOCAL) + Vector3(0.0, 0.1, 0.0)


## Deck-local metres to a world point on the deck's top.
func _deck_of(local: Vector2) -> Vector3:
	var at: Vector2 = Shot.deck_local(local)
	return Vector3(SITE.x + at.x, _pad_top + Shot.DECK_RISE, SITE.y + at.y)


## The deck, kerb and stair, welded into the pad's shell: each reaches the buried
## bottom, so the terrace stays one closed solid. Everything here is yawed to the
## hero axis, which the mesher takes as an argument, so the terrace is still built
## out of closed boxes and still passes the same three tests.
func _build_deck(m: WorldMesher) -> void:
	var yaw: float = Shot.VIEW_YAW
	var half: Vector2 = Shot.DECK_HALF
	var deck_top: float = _pad_top + Shot.DECK_RISE
	var rise: float = (deck_top - _pad_bottom) * 0.5
	var centre: Vector2 = Shot.deck_local(Vector2.ZERO)
	m.box(
		Vector3(SITE.x + centre.x, _pad_bottom + rise, SITE.y + centre.y),
		Vector3(half.x, rise, half.y),
		yaw,
		DECK_FLOOR,
		WorldSurface.Kind.CONCRETE
	)
	# The street: a slab three centimetres proud of the floor. Proud, not flush — two
	# coplanar faces in one place is the z-fight this project bans. It crosses the left
	# of frame at forty metres, giving the raking light a long flat thing to skim.
	m.box(
		Vector3(SITE.x - 12.0, _pad_top - 0.24, SITE.y + 14.0),
		Vector3(30.0, 0.27, 4.5),
		0.42,
		Palette.WORLD_ASPHALT[0],
		WorldSurface.Kind.ASPHALT
	)
	# Kerb: four overlapping bars, so the drop has an edge you can see from below. Warm
	# and dark, not neutral concrete: a light neutral bar lying flat under the eye is
	# the one thing in frame with no warm bounce, and reads as a grey rule.
	var kerb: Color = Color("57493a")
	var bars: Array = [
		[Vector2(0.0, -half.y - 0.02), Vector2(half.x + 0.16, 0.16)],
		[Vector2(0.0, half.y + 0.02), Vector2(half.x + 0.16, 0.16)],
		[Vector2(-half.x - 0.02, 0.0), Vector2(0.16, half.y + 0.16)],
		[Vector2(half.x + 0.02, 0.0), Vector2(0.16, half.y + 0.16)],
	]
	for bar: Array in bars:
		var at: Vector2 = Shot.deck_local(bar[0] as Vector2)
		var bh: Vector2 = bar[1]
		var top := Vector3(SITE.x + at.x, deck_top + 0.01, SITE.y + at.y)
		m.box(top, Vector3(bh.x, 0.28, bh.y), yaw, kerb, WorldSurface.Kind.CONCRETE)
	# Stair off the back face, at the far end from where you stand: you come up it, pass
	# the console, and walk to the parapet. Each tread reaches the pad bottom and the
	# last stops BELOW the floor — a tread laid ON it puts two faces in one place.
	for t in STEP_TREADS:
		var tread: float = deck_top - STEP_RISE * float(t + 1)
		var at: Vector2 = Shot.deck_local(
			Vector2(Shot.STAIR_LOCAL_X, half.y + 0.55 + 1.10 * float(t))
		)
		m.box(
			Vector3(SITE.x + at.x, (_pad_bottom + tread) * 0.5, SITE.y + at.y),
			Vector3(3.0, (tread - _pad_bottom) * 0.5, 0.62),
			yaw,
			Palette.WORLD_CONCRETE[1],
			WorldSurface.Kind.CONCRETE
		)


func _build_scene() -> Node3D:
	var root := Node3D.new()
	root.name = "Visuals"
	root.set_script(load(DEMO_SCRIPT))
	root.set("sun_azimuth_degrees", -87.0)
	root.set("sun_elevation_start", 12.5)
	root.set("ash_motes", 420)
	root.set("ground_y", _pad_top)
	root.set("player_spawn", _stand())
	root.set("player_yaw", Shot.VIEW_YAW)
	root.set("player_pitch_degrees", Shot.VIEW_PITCH_DEGREES)

	_add(root, _instance(WORLD_SCENE, "World"))
	_add(root, _instance3d(TERRAIN_SCENE, "Terrain"))
	_add(root, _build_pad())
	_add(root, _build_kits())
	_add(root, _build_clutter())
	_add(root, _build_landmarks())
	_add(root, _build_lamps())
	_add(root, _build_rack())
	_add(root, _build_post())
	_add(root, _build_creatures())
	_add(root, _build_rig())
	_add(root, _build_player())

	var vfx: Node3D = _instance3d(VFX_SCENE, "Vfx")
	if vfx != null:
		vfx.position = _world_of(Vector2.ZERO)
		_add(root, vfx)
	return root


## The terrace: closed boxes, each narrower and taller than the last, overlapping
## by a full course in Y so the union is watertight.
func _build_pad() -> Node3D:
	var m := WorldMesher.new()
	for i in STEP_COUNT:
		var out: float = STEP_OUT * float(STEP_COUNT - 1 - i)
		var half := Vector3(PAD_HALF.x + out, 0.0, PAD_HALF.y + out)
		var top: float = _pad_top - STEP_DOWN * float(STEP_COUNT - 1 - i)
		half.y = (top - _pad_bottom) * 0.5
		# Sand, never concrete: the concrete branch brightens by up to 1.8x, and a
		# hundred metres of it under a low sun reads as poured white.
		var col: Color = PAD_FLOOR if i == STEP_COUNT - 1 else Palette.WORLD_SAND[i]
		m.box(Vector3(SITE.x, _pad_bottom + half.y, SITE.y), half, 0.0, col, WorldSurface.Kind.SAND)
	# One ramp up the south face. Stacked boxes, not a sloped plane.
	for lane in [-30.0]:
		for s in 6:
			var t: float = float(s) / 6.0
			var rise: float = _pad_top - (_pad_top - STEP_DOWN * float(STEP_COUNT))
			var y_top: float = _pad_top - rise * t
			var depth: float = 1.6
			var z: float = SITE.y + PAD_HALF.y + STEP_OUT * float(STEP_COUNT - 1) + depth * float(s)
			m.box(
				Vector3(SITE.x + lane, (_pad_bottom + y_top) * 0.5, z),
				Vector3(4.2, (y_top - _pad_bottom) * 0.5, depth * 0.85),
				0.0,
				Palette.WORLD_SAND[1],
				WorldSurface.Kind.SAND
			)
	_build_deck(m)
	_check(m, "pad")

	var mesh: ArrayMesh = m.build_mesh(_mat_world)
	_save(mesh, OUT_PAD)

	var node := Node3D.new()
	node.name = "Pad"
	var mi := MeshInstance3D.new()
	mi.name = "Mesh"
	mi.mesh = mesh
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	node.add_child(mi)
	node.add_child(_static_trimesh(mesh, "Body", WorldSurface.Kind.SAND))
	return node


func _build_kits() -> Node3D:
	var node := Node3D.new()
	node.name = "Kits"
	for entry: Array in Shot.KITS:
		var id: String = entry[0]
		var kit: Node3D = _instance3d("%s/%s.tscn" % [KIT_DIR, id], id.capitalize())
		if kit == null:
			continue
		kit.position = _world_of(entry[1])
		kit.rotation.y = float(entry[2])
		node.add_child(kit)
	return node


## Anything there are more than eight of goes into a MultiMesh.
func _build_clutter() -> Node3D:
	var node := Node3D.new()
	node.name = "Clutter"
	_scatter(node, &"barrel", 30, 0.0)
	_scatter(node, &"crate", 24, 0.0)
	_scatter(node, &"sandbags", 20, 0.0)
	_scatter(node, &"big_crate", 10, 0.0)
	return node


func _scatter(parent: Node3D, id: StringName, count: int, _pad: float) -> void:
	var asset: WorldPropAsset = _props.asset(id)
	if asset == null or asset.mesh == null:
		_fail("prop '%s' is not in the baked set" % id)
		return
	var transforms: Array[Transform3D] = []
	var tries: int = 0
	while transforms.size() < count and tries < count * 60:
		tries += 1
		var p := Vector2(
			_rng.next_range(-PAD_HALF.x + 6.0, PAD_HALF.x - 6.0),
			_rng.next_range(-PAD_HALF.y + 6.0, PAD_HALF.y - 6.0)
		)
		if not _clutter_spot_free(p, maxf(asset.bounds.size.x, asset.bounds.size.z) * 0.5 + 0.4):
			continue
		var basis := Basis(Vector3.UP, _rng.next_range(0.0, TAU))
		# Prop meshes are baked standing on y = 0, so the pad top IS their base.
		transforms.append(Transform3D(basis, _world_of(p)))
	if transforms.is_empty():
		return

	var mm := MultiMesh.new()
	mm.mesh = asset.mesh
	MmBake.fill(mm, transforms)

	var mmi := MultiMeshInstance3D.new()
	mmi.name = String(id).capitalize()
	mmi.multimesh = mm
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	parent.add_child(mmi)
	parent.add_child(_boxes_body(asset, transforms, String(id).capitalize() + "Body"))
	var boxes: int = 0 if asset.boxes == null else asset.boxes.size()
	_line("clutter %-12s %3d x %d boxes" % [String(id), transforms.size(), boxes])


func _clutter_spot_free(p: Vector2, radius: float) -> bool:
	for entry: Array in Shot.KITS:
		var id: String = entry[0]
		var centre: Vector2 = entry[1]
		var half: Vector2 = Shot.kit_half(id, float(entry[2])) + Vector2.ONE * radius
		var d: Vector2 = (p - centre).abs()
		if d.x < half.x and d.y < half.y:
			return false
	# Nothing random inside the hero shot's foreground. A crate dropped at nine metres
	# under a 78 degree lens is as tall in frame as the water tower at seventy, and reads
	# as litter thrown at the camera. What stands close is placed: truck and dead tree.
	if p.distance_to(Shot.stand()) < 13.0 + radius:
		return false
	var local: Vector2 = Shot.to_deck(p)
	for zone: Array in [
		[Vector2.ZERO, Shot.DECK_HALF + Vector2(1.5, 1.5)],
		[Vector2(Shot.STAIR_LOCAL_X, Shot.DECK_HALF.y + 3.0), Vector2(3.6, 3.6)],
	]:
		var d2: Vector2 = (local - (zone[0] as Vector2)).abs()
		var h2: Vector2 = (zone[1] as Vector2) + Vector2.ONE * radius
		if d2.x < h2.x and d2.y < h2.y:
			return false
	for lamp: Array in Shot.LAMPS:
		if p.distance_to(lamp[0] as Vector2) < radius + 1.2:
			return false
	for mark: Array in Shot.LANDMARKS:
		var asset: WorldPropAsset = _props.asset(mark[0] as StringName)
		if asset == null:
			continue
		var reach: float = maxf(asset.bounds.size.x, asset.bounds.size.z) * 0.5 + radius + 0.6
		if p.distance_to(mark[1] as Vector2) < reach:
			return false
	return true


## One static body carrying every collider of every instance of a scattered prop.
func _boxes_body(
	asset: WorldPropAsset, transforms: Array[Transform3D], node_name: String
) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = node_name
	body.collision_layer = GameLayers.PROP
	body.collision_mask = 0
	if asset.boxes == null:
		return body
	var n: int = 0
	for t: Transform3D in transforms:
		for i in asset.boxes.size():
			var shape := BoxShape3D.new()
			shape.size = asset.boxes.halves[i] * 2.0
			var local := Transform3D(Basis(Vector3.UP, asset.boxes.yaws[i]), asset.boxes.centers[i])
			var cs := CollisionShape3D.new()
			cs.name = "box_%03d" % n
			cs.shape = shape
			cs.transform = t * local
			body.add_child(cs)
			n += 1
	return body


## The pieces placed by eye rather than by scatter: the things that frame the shot.
func _build_landmarks() -> Node3D:
	var node := Node3D.new()
	node.name = "Landmarks"
	var i: int = 0
	for entry: Array in Shot.LANDMARKS:
		var asset: WorldPropAsset = _props.asset(entry[0] as StringName)
		if asset == null:
			_fail("landmark prop '%s' is missing" % entry[0])
			continue
		var inst: Node3D = asset.instantiate("%s_%d" % [String(entry[0]), i])
		# A landmark whose pad coordinate lands inside the terrace stands ON it, three
		# metres up, instead of being buried in its side.
		var at: Vector2 = entry[1]
		var local: Vector2 = Shot.to_deck(at)
		var on_deck: bool = absf(local.x) < Shot.DECK_HALF.x and absf(local.y) < Shot.DECK_HALF.y
		inst.position = _deck_of(local) if on_deck else _world_of(at)
		inst.rotation.y = float(entry[2])
		node.add_child(inst)
		i += 1
	return node


## A lamp standard: buried foot, tapered pole, cranked arm, conical shade, and a
## bulb on its own emissive mesh with an omni behind it. Built once, instanced six.
func _build_lamps() -> Node3D:
	var m := WorldMesher.new()
	var steel: Color = Palette.WORLD_METAL[0]
	var rust: Color = Palette.WORLD_RUST[0]
	# Foot: buried 0.35 m so the pad swallows the base plate.
	m.box(
		Vector3(0.0, -0.15, 0.0), Vector3(0.34, 0.20, 0.34), 0.0, rust, WorldSurface.Kind.CONCRETE
	)
	m.cylinder(Vector3(0.0, 2.35, 0.0), 0.10, 0.062, 2.45, SEG, steel, WorldSurface.Kind.METAL)
	# Crank: two struts, overlapping the pole head and each other.
	m.strut(
		Vector3(0.0, 4.62, 0.0), Vector3(0.0, 5.05, -0.50), 0.05, steel, WorldSurface.Kind.METAL
	)
	m.strut(
		Vector3(0.0, 5.02, -0.44), Vector3(0.0, 5.06, -1.28), 0.05, steel, WorldSurface.Kind.METAL
	)
	# Shade: a capped cone, wide end down, overlapping the arm tip.
	m.cylinder(Vector3(0.0, 4.90, -1.24), 0.44, 0.10, 0.20, SEG, rust, WorldSurface.Kind.TIN)
	_check(m, "lamp")
	var lamp_mesh: ArrayMesh = m.build_mesh(_mat_world)
	_save(lamp_mesh, OUT_LAMP)

	var b := WorldMesher.new()
	b.cylinder(
		Vector3(0.0, 4.74, -1.24), 0.155, 0.155, 0.055, SEG, Palette.GOLD, WorldSurface.Kind.POLY
	)
	_check(b, "bulb")
	var bulb_mesh: ArrayMesh = b.build_mesh(_mat_ember)
	_save(bulb_mesh, OUT_BULB)

	var pole_shape := CylinderShape3D.new()
	pole_shape.radius = 0.12
	pole_shape.height = 4.9

	var node := Node3D.new()
	node.name = "Lamps"
	var i: int = 0
	for entry: Array in Shot.LAMPS:
		var stand := Node3D.new()
		stand.name = "Lamp%d" % i
		stand.position = _world_of(entry[0] as Vector2)
		stand.rotation.y = float(entry[1])

		var mi := MeshInstance3D.new()
		mi.name = "Mesh"
		mi.mesh = lamp_mesh
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		stand.add_child(mi)

		var bulb := MeshInstance3D.new()
		bulb.name = "Bulb"
		bulb.mesh = bulb_mesh
		bulb.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		bulb.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
		stand.add_child(bulb)

		var light := OmniLight3D.new()
		light.name = "Light"
		light.position = Vector3(0.0, 4.70, -1.24)
		light.light_color = Color(1.0, 0.784, 0.502)
		light.light_energy = 3.4
		light.omni_range = 14.0
		light.omni_attenuation = 1.6
		light.light_specular = 0.5
		light.shadow_enabled = i < 3
		light.distance_fade_enabled = true
		light.distance_fade_begin = 55.0
		light.distance_fade_length = 20.0
		# Persistent, or the group is lost the moment the scene is packed and the
		# LAMPS lever finds nothing to switch off.
		light.add_to_group(&"visuals_lamp", true)
		stand.add_child(light)

		var body := StaticBody3D.new()
		body.name = "Body"
		body.collision_layer = GameLayers.PROP
		body.collision_mask = 0
		var cs := CollisionShape3D.new()
		cs.name = "Pole"
		cs.shape = pole_shape
		cs.position = Vector3(0.0, 2.45, 0.0)
		body.add_child(cs)
		stand.add_child(body)

		node.add_child(stand)
		i += 1
	return node


## An A-frame rack with five real weapons standing in it. The guns are the baked
## cache scenes, forced onto the world render layer — their default is the
## viewmodel layer, and a rack of invisible rifles is a subtle bug to chase.
func _build_rack() -> Node3D:
	var m := WorldMesher.new()
	var wood: Color = Palette.WORLD_WOOD[0]
	var steel: Color = Palette.WORLD_METAL[1]
	# Buried sill, two uprights, a back rail and a butt shelf. Every joint overlaps.
	m.box(Vector3(0.0, -0.06, 0.0), Vector3(1.35, 0.10, 0.34), 0.0, wood, WorldSurface.Kind.WOOD)
	for sx in [-1.28, 1.28]:
		m.box(
			Vector3(sx, 0.58, -0.20), Vector3(0.07, 0.66, 0.07), 0.0, wood, WorldSurface.Kind.WOOD
		)
	m.box(Vector3(0.0, 1.14, -0.20), Vector3(1.35, 0.06, 0.07), 0.0, wood, WorldSurface.Kind.WOOD)
	m.box(Vector3(0.0, 0.13, -0.02), Vector3(1.35, 0.05, 0.15), 0.0, steel, WorldSurface.Kind.METAL)
	# Five dividers on the rail, so each weapon has a slot to lean in.
	for i in 6:
		var x: float = -1.20 + 0.48 * float(i)
		m.box(
			Vector3(x, 1.20, -0.20), Vector3(0.035, 0.09, 0.09), 0.0, steel, WorldSurface.Kind.METAL
		)
	_check(m, "rack")
	var mesh: ArrayMesh = m.build_mesh(_mat_world)
	_save(mesh, OUT_RACK)

	var node := Node3D.new()
	node.name = "Rack"
	# Off your left shoulder at three metres, turned a quarter toward you: out of the
	# hero frame, but the first thing in it the moment you look left, and the piece
	# of deck furniture the pan reads best.
	node.position = _deck_of(Shot.RACK_LOCAL)
	node.rotation.y = Shot.VIEW_YAW - 0.55

	var mi := MeshInstance3D.new()
	mi.name = "Mesh"
	mi.mesh = mesh
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	node.add_child(mi)
	node.add_child(_static_trimesh(mesh, "Body", WorldSurface.Kind.WOOD))

	var slot: int = 0
	for id: String in RACK_GUNS:
		var path: String = "%s/%s.tscn" % [GUN_CACHE, id]
		var gun: Node3D = _instance3d(path, "Gun_" + id)
		if gun == null:
			_fail("gun cache entry '%s' is missing" % id)
			continue
		gun.set("render_layers", GameLayers.WORLD)
		gun.set("cast_shadows", true)
		gun.set("model_scale", 0.09)
		# Leaning muzzle-up in its slot, jittered so the row is not machine-perfect.
		var x: float = -0.96 + 0.48 * float(slot)
		gun.position = Vector3(x, 0.30, -0.06)
		# The assembly runs along the model's +X, not its -Z, so standing a weapon
		# on its butt is a roll about Z. Rolling about X lies it on the floor.
		gun.rotation = Vector3(
			_rng.next_range(-0.10, 0.10), _rng.next_range(-0.14, 0.14), deg_to_rad(74.0)
		)
		node.add_child(gun)
		slot += 1
	return node


## The control post: a steel console on a plinth, with the dial, the slider, the
## three levers and the panel on its canted face. This demo's whole UI.
func _build_post() -> Node3D:
	var m := WorldMesher.new()
	# Neither straight off the palette. `WORLD_CONCRETE[0]` through the shader's
	# concrete branch peaks near 1.8x and, on a plinth you stand over, reads as poured
	# white; `WORLD_METAL[0]` is a cool grey, and the console's top faces nothing but
	# sky, which turns it navy. Warm dark concrete and the art direction's own steel.
	var concrete: Color = Color("554c40")
	var steel: Color = Color("4d4a44")
	# Plinth, buried 0.4 m.
	m.box(POST_PLINTH_AT, POST_PLINTH_HALF, 0.0, concrete, WorldSurface.Kind.CONCRETE)
	# Console body, overlapping the plinth top by 6 cm.
	m.box(Vector3(0.0, 0.86, 0.0), Vector3(1.16, 0.24, 0.44), 0.0, steel, WorldSurface.Kind.METAL)
	# Canted face: an oriented box tilted about local X. The frame stays
	# right-handed, so the shell stays outward.
	var c: float = cos(POST_FACE_TILT)
	var s: float = sin(POST_FACE_TILT)
	m.oriented_box(
		Vector3(0.0, POST_TOP_Y + 0.10, 0.10),
		Vector3(1.16, 0.0, 0.0),
		Vector3(0.0, c, s) * 0.055,
		Vector3(0.0, -s, c) * 0.36,
		steel,
		WorldSurface.Kind.METAL
	)
	# Panel mast behind the face, carrying the readout.
	for sx in [-0.60, 0.60]:
		m.box(
			Vector3(sx, 1.30, -0.34), Vector3(0.05, 0.42, 0.05), 0.0, steel, WorldSurface.Kind.METAL
		)
	m.box(POST_MAST_AT, POST_MAST_HALF, 0.0, steel, WorldSurface.Kind.METAL)
	_check(m, "post")
	var mesh: ArrayMesh = m.build_mesh(_mat_world)
	_save(mesh, OUT_POST)

	var node := Node3D.new()
	node.name = "Post"
	# Six metres behind your right shoulder, between the stair head and the parapet.
	# Facing the way you face, so operating it still gives you the view — it just is
	# not standing in it. This is the whole of the recomposition: everything else
	# follows from the console no longer owning the middle of the frame.
	node.position = _deck_of(Shot.POST_LOCAL)
	node.rotation.y = Shot.VIEW_YAW

	var mi := MeshInstance3D.new()
	mi.name = "Mesh"
	mi.mesh = mesh
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	node.add_child(mi)
	node.add_child(_static_trimesh(mesh, "Body", WorldSurface.Kind.METAL))

	# Everything mounted on the face shares this basis, so nothing floats or sinks.
	var face := Basis(Vector3.RIGHT, -POST_FACE_TILT)
	var face_y: float = POST_TOP_Y + 0.16
	var face_z: float = 0.10

	# Left to right along the face. One table, one loop: five controls that differ
	# only in the properties they carry cannot drift into five spellings.
	var presets := PackedStringArray(GameSettings.PRESET_NAMES)
	var furniture: Array = [
		[CTL_DIAL, "Quality", -0.74, {&"options": presets, &"wraps": true}],
		[CTL_LEVER, "Ride", -0.36, {&"off_text": "STAND", &"on_text": "FLY"}],
		[
			CTL_SLIDER,
			"Sun",
			0.06,
			{&"min_value": 3.0, &"max_value": 46.0, &"step": 0.5, &"track_length": 0.52}
		],
		[CTL_LEVER, "Lamps", 0.62, {}],
		[CTL_LEVER, "Ash", 0.85, {}],
	]
	for entry: Array in furniture:
		var control: Node3D = _instance3d(entry[0] as String, entry[1] as String)
		if control == null:
			continue
		control.set(&"control_id", StringName((entry[1] as String).to_lower()))
		control.set(&"label_text", (entry[1] as String).to_upper())
		for key: StringName in entry[3] as Dictionary:
			control.set(key, (entry[3] as Dictionary)[key])
		control.transform = Transform3D(
			face, Vector3(float(entry[2]), face_y, face_z) + face.y * 0.03
		)
		node.add_child(control)

	var readout: Node3D = _instance3d(CTL_READOUT, "Readout")
	if readout != null:
		readout.set("painted", false)
		readout.set("glow", 1.9)
		node.add_child(readout)
		var mast: AABB = PanelMount.half_box(POST_MAST_AT, POST_MAST_HALF)
		PanelMount.new().apply(readout, mast, Vector3(0.0, POST_MAST_AT.y, 0.0), "PanelMast")

	# The one thing the post has to say that a control cannot: what it is.
	var placard := Label3D.new()
	placard.name = "Placard"
	placard.text = "SCAV DELTA  ·  GRADE 4 SETTLEMENT\nSHOOT NOTHING.  LOOK AT IT."
	placard.font = load(UiStyle.FONT_DISPLAY_PATH) as Font
	placard.font_size = 40
	placard.pixel_size = 0.0016
	placard.modulate = UiStyle.TEXT_DIM
	placard.outline_size = 0
	placard.billboard = BaseMaterial3D.BILLBOARD_DISABLED
	placard.shaded = true
	placard.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	node.add_child(placard)
	# Raked 17 degrees toward the eye, which swings its lower line 19 mm back — far
	# enough that at 0.56 the last line was inside the plinth's top-front corner.
	var seat := PanelMount.new()
	seat.tilt_degrees = -POST_PLACARD_RAKE_DEG
	seat.bounds_override = PanelMount.centred(Vector3.ZERO, POST_PLACARD_SIZE)
	var plinth: AABB = PanelMount.half_box(POST_PLINTH_AT, POST_PLINTH_HALF)
	seat.apply(placard, plinth, Vector3(0.0, POST_PLACARD_Y, 0.0), "Plinth")
	return node


## Set dressing with a pulse. The actors carry no profile, so nothing configures a
## brain or a weapon: they stand, breathe and cast a shadow.
func _build_creatures() -> Node3D:
	var node := Node3D.new()
	node.name = "Creatures"
	var i: int = 0
	for entry: Array in Shot.CREATURES:
		var path: String = "%s/%s.res" % [ENEMY_DIR, entry[0]]
		var actor: Node3D = _instance3d(path, "%s_%d" % [entry[0], i])
		if actor == null:
			_fail("species '%s' is not baked" % entry[0])
			continue
		actor.position = _world_of(entry[1] as Vector2) + Vector3(0.0, 0.05, 0.0)
		actor.rotation.y = float(entry[2])
		node.add_child(actor)
		i += 1
	return node


## The pan: a closed loop outside everything built, and an aim curve that walks the
## subjects. Baked here; the rig script only samples them.
func _build_rig() -> Node3D:
	var node := Node3D.new()
	node.name = "CameraRig"
	node.set_script(load(RIG_SCRIPT))
	node.position = _world_of(Vector2.ZERO)

	var eye := Curve3D.new()
	eye.bake_interval = 0.5
	# Ten stations on an irregular ring, rising over the far side. The ring clears the
	# terrace: its tightest station is 62 m out and the pad's own corner is 56 by 48,
	# so the pan never flies through the graded edge it is meant to be looking at.
	var radii: PackedFloat32Array = [66.0, 70.0, 74.0, 71.0, 64.0, 62.0, 65.0, 69.0, 73.0, 70.0]
	var heights: PackedFloat32Array = [3.0, 3.7, 5.2, 7.2, 9.4, 10.2, 8.6, 6.0, 4.2, 3.3]
	for i in radii.size() + 1:
		var k: int = i % radii.size()
		var a: float = TAU * float(i) / float(radii.size()) + 0.72
		var r: float = radii[k]
		var p := Vector3(sin(a) * r, heights[k], cos(a) * (r * 0.92) + 2.0)
		# Handles a third of the way to the neighbours: the Catmull-to-Bezier ratio.
		var t := Vector3(cos(a), 0.0, -sin(a) * 0.92) * (TAU * r / float(radii.size()) / 3.0)
		eye.add_point(p, -t, t)
	node.set("eye_curve", eye)

	var aim := Curve3D.new()
	aim.bake_interval = 0.5
	# The subjects, in the order the pan should walk them: water tower, compound,
	# plaza, street block, lookout deck.
	for p: Vector3 in [
		Vector3(-43.0, 11.0, 15.0),
		Vector3(-38.0, 3.5, -14.0),
		Vector3(-4.0, 1.6, 4.0),
		Vector3(-2.0, 5.0, -30.0),
		Vector3(Shot.DECK.x, 3.6, Shot.DECK.y),
	]:
		aim.add_point(p)
	node.set("aim_curve", aim)
	# Metres in at which the ride opens: the low south-east station, which is the
	# hero angle from the air.
	node.set("start_travel", 24.0)
	node.set("fov", 46.0)

	var cam := Camera3D.new()
	cam.name = "Camera"
	cam.fov = 46.0
	cam.near = 0.08
	cam.far = 1400.0
	cam.cull_mask = 0xFFFFFF & ~GameLayers.VIEWMODEL
	cam.current = false
	node.add_child(cam)
	return node


func _build_player() -> Node3D:
	var player: Node3D = _instance3d(PLAYER_SCENE, "Player")
	if player == null:
		_fail("the baked player is missing; run build_player.gd")
		return null
	player.position = _stand()
	player.rotation.y = Shot.VIEW_YAW
	return player


## `VisualsShot` owns the layout; the builder's job is to refuse to bake one that
## does not fit. Faults become build failures, the frame table goes in the report.
func _frame_report() -> void:
	for fault: String in Shot.layout_faults(PAD_HALF):
		_fail(fault)
	_line("")
	for text: String in Shot.frame_lines():
		_line(text)


## Every authored shell, tested three ways: outward winding, positive enclosed
## volume, no open boundary edge.
func _check(m: WorldMesher, label: String) -> void:
	_shells += 1
	var vol: float = m.signed_volume()
	var conflicts: int = m.normal_conflicts()
	var degen: int = m.degenerate_count()
	var open: int = _open_edges(m.vertices())
	var ok: bool = vol > 0.0 and conflicts == 0 and degen == 0 and open == 0
	if not ok:
		_failures += 1
	var tag: String = "OK" if ok else "FAIL"
	var fmt: String = "shell %-6s %5d tris  vol %+9.2f  bad %d/%d/%d  %s"
	_line(fmt % [label, m.triangle_count(), vol, conflicts, degen, open, tag])


## Boundary edges of a welded triangle soup. A closed solid has none; one is the
## air gap this project bans.
func _open_edges(pos: PackedVector3Array) -> int:
	var ids: Dictionary = {}
	var index := PackedInt32Array()
	index.resize(pos.size())
	for i in pos.size():
		var key: Vector3i = Vector3i(
			roundi(pos[i].x / WELD), roundi(pos[i].y / WELD), roundi(pos[i].z / WELD)
		)
		if not ids.has(key):
			ids[key] = ids.size()
		index[i] = ids[key]
	var edges: Dictionary = {}
	for t in index.size() / 3:
		for e in 3:
			var a: int = index[t * 3 + e]
			var b: int = index[t * 3 + (e + 1) % 3]
			if a == b:
				continue
			var key: Vector2i = Vector2i(mini(a, b), maxi(a, b))
			edges[key] = int(edges.get(key, 0)) + 1
	var open: int = 0
	for count: int in edges.values():
		if count % 2 == 1:
			open += 1
	return open


func _load_back() -> void:
	var packed: PackedScene = ResourceLoader.load(OUT_SCENE, "", ResourceLoader.CACHE_MODE_IGNORE)
	if packed == null:
		_fail("could not load %s back" % OUT_SCENE)
		return
	var state: SceneState = packed.get_state()
	var meshes: int = 0
	var lights: int = 0
	var controls: int = 0
	var instances: int = 0
	for i in state.get_node_count():
		var type: String = state.get_node_type(i)
		if type == "MeshInstance3D" or type == "MultiMeshInstance3D":
			meshes += 1
		elif type.ends_with("Light3D"):
			lights += 1
		if state.get_node_instance(i) != null:
			instances += 1
	var root := packed.instantiate(PackedScene.GEN_EDIT_STATE_DISABLED)
	for node: Node in root.find_children("*", "", true, false):
		var script := node.get_script() as Script
		if script == null:
			continue
		var file: String = script.resource_path.get_file()
		if file.begins_with("diegetic_") and file != "diegetic_readout.gd":
			controls += 1
	root.free()
	_line("")
	var fmt: String = "scene nodes           %d declared, %d instanced, %d meshes, %d lights"
	_line(fmt % [state.get_node_count(), instances, meshes, lights])
	_line("diegetic controls     %d" % controls)
	if controls != 5:
		_fail("expected 5 diegetic controls on the post, packed %d" % controls)


func _instance(path: String, node_name: String) -> Node:
	if not ResourceLoader.exists(path):
		_fail("missing scene %s" % path)
		return null
	var packed: PackedScene = load(path) as PackedScene
	if packed == null:
		_fail("%s is not a PackedScene" % path)
		return null
	var node: Node = packed.instantiate(PackedScene.GEN_EDIT_STATE_INSTANCE)
	if node == null:
		_fail("%s did not instance" % path)
		return null
	node.name = node_name
	return node


## Same, for scenes this builder places. `scav_world.tscn` is not one: a
## WorldEnvironment is a plain Node and has nowhere to be.
func _instance3d(path: String, node_name: String) -> Node3D:
	var node: Node3D = _instance(path, node_name) as Node3D
	if node == null and ResourceLoader.exists(path):
		_fail("%s did not instance as a Node3D" % path)
	return node


## A trimesh body for an authored shell; nothing calls it at run time.
func _static_trimesh(mesh: ArrayMesh, node_name: String, _surface: int) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = node_name
	body.collision_layer = GameLayers.PROP
	body.collision_mask = 0
	var cs := CollisionShape3D.new()
	cs.name = "Shape"
	cs.shape = mesh.create_trimesh_shape()
	body.add_child(cs)
	return body


func _add(parent: Node3D, child: Node) -> void:
	if child != null:
		parent.add_child(child)


## Owner assignment stops at a sub-scene root: recursing would pack a thousand
## copies of the terrain instead of one reference.
func _set_owner(node: Node, owner: Node) -> void:
	for child: Node in node.get_children():
		if child != owner:
			child.owner = owner
		if child.scene_file_path.is_empty():
			_set_owner(child, owner)


func _save(res: Resource, path: String) -> void:
	if ResourceSaver.save(res, path) != OK:
		_fail("could not save %s" % path)


func _line(text: String) -> void:
	_report.push_back(text)


func _fail(message: String) -> void:
	_failures += 1
	_report.push_back("FAIL: " + message)
	push_error("build_visuals: " + message)


func _finish() -> void:
	_line("")
	_line("shells checked        %d" % _shells)
	_line("failures              %d" % _failures)
	_line("RESULT: %s" % ("PASS" if _failures == 0 else "FAIL"))
	var text: String = "\n".join(_report) + "\n"
	var f: FileAccess = FileAccess.open(OUT_REPORT, FileAccess.WRITE)
	if f != null:
		f.store_string(text)
		f.close()
	print(text)
	quit(0 if _failures == 0 else 1)
