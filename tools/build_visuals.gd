extends SceneTree
## Bakes `res://demos/visuals/visuals.tscn` — the look of the game, in one scene.
##
## Run headless: godot --headless --path <project> --script res://tools/build_visuals.gd
##
## THE WHOLE MAP AT SUNSET. The baked terrain (100 chunks, three LODs, 1760 m across)
## and the baked town (211 chunks, 114 buildings, its own occluder hulls) are both
## instanced whole, and a lookout terrace is graded into the flats OUTSIDE the town on
## the axis the hero camera already looks down — so what you arrive to is a scav
## settlement in the foreground and the entire city behind it. Where that terrace
## stands is not typed in: `VisualsSite` scans the baked terrain and the baked layout
## for a rise that clears the town's roofs with a sightline that no dune interrupts.
##
## Nothing already baked is remade — terrain, town, kits, props, guns, creatures,
## player and VFX hub are all instanced. The only geometry authored here is the pad,
## post, rack and lamp standard, each checked for outward winding, positive volume and
## zero open boundary edges before packing.
##
## THE LIGHT IS THIS DEMO'S OWN. `res://art/scav_world.tscn` is shared by all nine
## demos and is a mid-afternoon balance; the other eight are daytime and must stay
## that way. So this builder bakes a dusk sky material, a dusk Environment and a
## `World` node carrying the same `ScavWorldEnvironment` script over three lights of
## its own — see `VisualsDusk` for what makes a sunset read.
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
## Where the terrace is graded in, decided off the bake rather than typed in.
const Site := preload("res://demos/visuals/visuals_site.gd")
## The dusk look: sky material, Environment and the three lights.
const Dusk := preload("res://demos/visuals/visuals_dusk.gd")
## Authors the hold-to-dash overlay. Note that this is NOT `visuals_dash.gd`: that
## script declares `PlayerController`, `PlayerCameraRig` and `FreecamController`
## members, preloading it drags in two scripts that name the `GameSettings` autoload,
## and an autoload does not exist on the bare `SceneTree` a `--script` bake runs on.
## The result was a silent "PackedScene.pack failed"; see `VisualsDashHud`.
const Dash := preload("res://demos/visuals/visuals_dash_hud.gd")
## The three tests every authored shell has to pass.
const Shell := preload("res://demos/visuals/visuals_shell.gd")
## The five authored shells and the dimensions they are authored to.
const Parts := preload("res://demos/visuals/visuals_parts.gd")
## Seats the post's screen and name plate; no standoff here is picked by hand.
const PanelMount := preload("res://ui/diegetic/panel_mount.gd")

const OUT_DIR: String = "res://demos/visuals"
const OUT_SCENE: String = "res://demos/visuals/visuals.tscn"
const OUT_PAD: String = "res://demos/visuals/pad_mesh.res"
const OUT_POST: String = "res://demos/visuals/post_mesh.res"
const OUT_RACK: String = "res://demos/visuals/rack_mesh.res"
const OUT_LAMP: String = "res://demos/visuals/lamp_mesh.res"
const OUT_BULB: String = "res://demos/visuals/bulb_mesh.res"
const OUT_SKY: String = "res://demos/visuals/dusk_sky.tres"
const OUT_ENV: String = "res://demos/visuals/dusk_environment.tres"
const OUT_REPORT: String = "res://demos/visuals/build_report.txt"

const DEMO_SCRIPT: String = "res://demos/visuals/visuals_demo.gd"
const RIG_SCRIPT: String = "res://demos/visuals/visuals_camera_rig.gd"
const DASH_SCRIPT: String = "res://demos/visuals/visuals_dash.gd"
const WORLD_SCRIPT: String = "res://art/world_environment.gd"

const TERRAIN_SCENE: String = "res://data/world/terrain/terrain.tscn"
const TOWN_SCENE: String = "res://data/world/town/town.tscn"
const TERRAIN_DATA: String = "res://data/world/terrain_data.res"
const LAYOUT_DATA: String = "res://data/world/layout.res"
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

## Where the sun stands. The azimuth is not free: the hero axis bears -48.4 degrees,
## and -87 puts the sun 38.6 degrees off the left of it — ahead of you, back-lighting
## the town, out of frame at a 78 degree lens by a hair. Moving it wrecks the shot.
## The elevation is what makes it dusk rather than afternoon; at 3.5 degrees a six
## metre pole throws ninety-eight metres of shadow across the flats.
const SUN_AZIMUTH: float = -87.0
const SUN_ELEVATION: float = 3.5

## What the on-screen dash prompt says. The trigger is the `sprint` action, so the
## prompt names the key that action ships bound to rather than the action.
const DASH_PROMPT: String = "HOLD  SHIFT  ·  DASH"

const SEED: int = 0x5E17

## Weapons standing in the rack, left to right. Real cache entries, real specs.
const RACK_GUNS: PackedStringArray = ["rifle_t5", "shotgun_t3", "smg_t4", "sniper_t6", "lmg_t4"]

var _mat_world: Material = null
var _mat_ember: Material = null
var _terrain: WorldTerrainData = null
var _layout: WorldLayoutData = null
var _props: WorldPropSet = null
var _rng: XorShift32 = null

## Where the terrace is graded in. Chosen, not typed: `VisualsSite` scans the axis
## behind the town for the rise with the best clear look at it.
var _site: Vector2 = Vector2.ZERO
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
	_layout = load(LAYOUT_DATA) as WorldLayoutData
	_props = load(PROP_SET) as WorldPropSet
	if _mat_world == null or _terrain == null or _props == null:
		_fail("a required baked input is missing; run the world and art bakes first")
		_finish()
		return
	if _layout == null:
		_fail("the town layout is missing; run build_town.gd first")
		_finish()
		return
	_terrain.build_lut()
	_choose_site()
	_measure_site()
	_bake_dusk()
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


## Put the terrace where the town is worth looking at. The old coordinate was typed
## in — (-220, -40), the flattest ground going — and it was a fine answer to "where is
## flat" and the wrong answer to "where can you SEE the city from". `VisualsSite`
## scans back along the hero axis for a rise that clears the town's mean roof with a
## sightline no dune interrupts, and writes its whole scan table into the report.
func _choose_site() -> void:
	var outer: float = Parts.STEP_OUT * float(Parts.STEP_COUNT - 1)
	_site = Site.choose(_terrain, _layout, Parts.PAD_HALF, outer, _report)
	_line("")


## The dusk sky and Environment this demo alone uses. Baked, not authored at load,
## and saved beside the scene so `visuals.tscn` carries a plain resource reference.
func _bake_dusk() -> void:
	var el: float = deg_to_rad(SUN_ELEVATION)
	var az: float = deg_to_rad(SUN_AZIMUTH)
	var horizontal: float = cos(el)
	var dir := Vector3(sin(az) * horizontal, sin(el), -cos(az) * horizontal)
	_save(Dusk.sky_material(dir), OUT_SKY)
	_save(Dusk.environment(OUT_SKY), OUT_ENV)
	_line(
		(
			"dusk sun              %.1f deg elevation, %.1f deg azimuth  dir (%.3f, %.3f, %.3f)"
			% [SUN_ELEVATION, SUN_AZIMUTH, dir.x, dir.y, dir.z]
		)
	)
	# A six metre lamp standard's shadow, which is the number the look lives or dies
	# on and the one thing about "dusk" that can be checked with arithmetic.
	_line(
		(
			"shadow length         %.0f m from a 6 m pole (cascade reaches %.0f m)"
			% [6.0 / maxf(tan(el), 0.0001), Dusk.SHADOW_DISTANCE]
		)
	)


## Fix the terrace's two heights from the ground it is cut into: the top clears the
## highest point under it, the bottom is buried below the lowest.
func _measure_site() -> void:
	var top_hi: float = -1.0e9
	var out: float = Parts.STEP_OUT * float(Parts.STEP_COUNT - 1)
	var wide: Vector2 = Parts.PAD_HALF + Vector2.ONE * out
	var wide_lo: float = 1.0e9
	var samples: int = 0
	var step: float = 2.0
	var x: float = -wide.x
	while x <= wide.x:
		var z: float = -wide.y
		while z <= wide.y:
			var h: float = _terrain.ground_h(_site.x + x, _site.y + z)
			wide_lo = minf(wide_lo, h)
			if absf(x) <= Parts.PAD_HALF.x and absf(z) <= Parts.PAD_HALF.y:
				top_hi = maxf(top_hi, h)
			samples += 1
			z += step
		x += step
	_pad_top = top_hi + Parts.PAD_CLEAR
	_pad_bottom = wide_lo - Parts.PAD_BURY
	_line("site                  (%.0f, %.0f)" % [_site.x, _site.y])
	_line("terrain samples       %d at %.1f m" % [samples, step])
	var fill: float = _pad_top - _pad_bottom
	_line("pad top / bottom      %.3f / %.3f m  (%.2f m fill)" % [_pad_top, _pad_bottom, fill])


func _world_of(local: Vector2) -> Vector3:
	return Vector3(_site.x + local.x, _pad_top, _site.y + local.y)


## Where the player stands: at the parapet, left of the deck's centre.
func _stand() -> Vector3:
	return _deck_of(Shot.STAND_LOCAL) + Vector3(0.0, 0.1, 0.0)


## Deck-local metres to a world point on the deck's top.
func _deck_of(local: Vector2) -> Vector3:
	var at: Vector2 = Shot.deck_local(local)
	return Vector3(_site.x + at.x, _pad_top + Shot.DECK_RISE, _site.y + at.y)


func _build_scene() -> Node3D:
	var root := Node3D.new()
	root.name = "Visuals"
	root.set_script(load(DEMO_SCRIPT))
	root.set("sun_azimuth_degrees", SUN_AZIMUTH)
	root.set("sun_elevation_start", SUN_ELEVATION)
	root.set("sun_elevation_min", 1.0)
	root.set("sun_energy", Dusk.SUN_ENERGY)
	root.set("ambient_energy", Dusk.AMBIENT_ENERGY)
	root.set("sky_fill_energy", Dusk.SKY_FILL_ENERGY)
	root.set("bounce_energy", Dusk.BOUNCE_ENERGY)
	root.set("ash_motes", 420)
	root.set("ground_y", _pad_top)
	root.set("player_spawn", _stand())
	root.set("player_yaw", Shot.VIEW_YAW)
	root.set("player_pitch_degrees", Shot.VIEW_PITCH_DEGREES)

	_add(root, _build_world())
	_add(root, _instance3d(TERRAIN_SCENE, "Terrain"))
	_add(root, _instance3d(TOWN_SCENE, "Town"))
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
	_add(root, Dash.build(load(DASH_SCRIPT), DASH_PROMPT))

	var vfx: Node3D = _instance3d(VFX_SCENE, "Vfx")
	if vfx != null:
		vfx.position = _world_of(Vector2.ZERO)
		_add(root, vfx)
	return root


## The dusk `World` node: the shared `ScavWorldEnvironment` script over this demo's
## own Environment and its own three lights. Not `scav_world.tscn` — that scene is
## instanced by the other eight demos and they are all daytime.
func _build_world() -> WorldEnvironment:
	var script := load(WORLD_SCRIPT) as Script
	var env := load(OUT_ENV) as Environment
	if script == null or env == null:
		_fail("the dusk environment did not bake")
		return null
	var el: float = deg_to_rad(SUN_ELEVATION)
	var az: float = deg_to_rad(SUN_AZIMUTH)
	var horizontal: float = cos(el)
	var dir := Vector3(sin(az) * horizontal, sin(el), -cos(az) * horizontal)
	return Dusk.world_node(script, env, dir)


## The terrace, meshed by `VisualsParts` and checked before it is packed.
func _build_pad() -> Node3D:
	var m: WorldMesher = Parts.pad(_site, _pad_top, _pad_bottom)
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
			_rng.next_range(-Parts.PAD_HALF.x + 6.0, Parts.PAD_HALF.x - 6.0),
			_rng.next_range(-Parts.PAD_HALF.y + 6.0, Parts.PAD_HALF.y - 6.0)
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
	var m: WorldMesher = Parts.lamp()
	_check(m, "lamp")
	var lamp_mesh: ArrayMesh = m.build_mesh(_mat_world)
	_save(lamp_mesh, OUT_LAMP)

	var b: WorldMesher = Parts.bulb()
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
	var m: WorldMesher = Parts.rack()
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
	var m: WorldMesher = Parts.post()
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
	var face := Basis(Vector3.RIGHT, -Parts.POST_FACE_TILT)
	var face_y: float = Parts.POST_TOP_Y + 0.16
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
		var mast: AABB = PanelMount.half_box(Parts.POST_MAST_AT, Parts.POST_MAST_HALF)
		PanelMount.new().apply(readout, mast, Vector3(0.0, Parts.POST_MAST_AT.y, 0.0), "PanelMast")

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
	seat.tilt_degrees = -Parts.POST_PLACARD_RAKE_DEG
	seat.bounds_override = PanelMount.centred(Vector3.ZERO, Parts.POST_PLACARD_SIZE)
	var plinth: AABB = PanelMount.half_box(Parts.POST_PLINTH_AT, Parts.POST_PLINTH_HALF)
	seat.apply(placard, plinth, Vector3(0.0, Parts.POST_PLACARD_Y, 0.0), "Plinth")
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
	for fault: String in Shot.layout_faults(Parts.PAD_HALF):
		_fail(fault)
	_line("")
	for text: String in Shot.frame_lines():
		_line(text)


## Every authored shell, tested three ways: outward winding, positive enclosed
## volume, no open boundary edge. The tests themselves live in `VisualsShell`.
func _check(m: WorldMesher, label: String) -> void:
	_shells += 1
	var result: Array = Shell.report(m, label)
	if not bool(result[0]):
		_failures += 1
	_line(String(result[1]))


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
	_check_dash(root)
	root.free()
	_line("")
	var fmt: String = "scene nodes           %d declared, %d instanced, %d meshes, %d lights"
	_line(fmt % [state.get_node_count(), instances, meshes, lights])
	_line("diegetic controls     %d" % controls)
	if controls != 5:
		_fail("expected 5 diegetic controls on the post, packed %d" % controls)


## The dash overlay is authored by one file and driven by another, so the seam
## between them is checked here rather than trusted: every widget `visuals_dash.gd`
## resolves by path has to exist in the scene that was just written back.
func _check_dash(root: Node) -> void:
	var dash: Node = root.get_node_or_null(^"Dash")
	if dash == null:
		_fail("the dash overlay did not pack")
		return
	var missing := PackedStringArray()
	for path: String in Dash.WIDGETS:
		if dash.get_node_or_null(NodePath(path)) == null:
			missing.append(path)
	_line("dash overlay          %d widgets, script %s" % [Dash.WIDGETS.size(), DASH_SCRIPT])
	if not missing.is_empty():
		_fail("the dash overlay is missing %s" % ", ".join(missing))
	if dash.get_script() == null:
		_fail("the dash overlay packed without its script")


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
