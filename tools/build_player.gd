extends SceneTree
## Bakes the two scenes every demo instances:
##   `res://data/player/player.tscn`  — body, eye, view effects, holster, viewmodel
##                                      pass and freecam, wired to each other and to
##                                      nothing else.
##   `res://data/player/freecam.tscn` — the freecam on its own, for the demos that have
##                                      no player at all.
##
## Nothing in either scene reaches out into a demo, so the same prefabs drop into the
## range, the bestiary and the open world without a line of glue.
##
## The work happens on the first idle frame rather than in `_initialize`, and the player
## scripts are pulled in with `load` rather than by their `class_name`. Both are forced
## by the same fact: `--script` compiles the main-loop script and everything it depends
## on BEFORE the autoloads are registered, so a builder that names `PlayerController`
## at parse time drags in a script that names `GameSettings`, and that fails to compile.
## By the first frame the autoloads are up and the same scripts load cleanly. Nodes are
## therefore typed to their engine base class here and script properties are set through
## `Object.set` — the annotations are still real, they are just one rung lower.
##
## Run headless:
##   godot --headless --path <project> --script res://tools/build_player.gd

const OUT_DIR: String = "res://data/player"
const PLAYER_PATH: String = "res://data/player/player.tscn"
const FREECAM_PATH: String = "res://data/player/freecam.tscn"

const SCRIPT_CONTROLLER: String = "res://systems/player/player_controller.gd"
const SCRIPT_CAMERA: String = "res://systems/player/player_camera.gd"
const SCRIPT_EFFECTS: String = "res://systems/player/player_view_effects.gd"
const SCRIPT_HOLSTER: String = "res://systems/player/weapon_holster.gd"
const SCRIPT_VIEWMODEL: String = "res://systems/player/viewmodel/viewmodel_pass.gd"
const SCRIPT_FREECAM: String = "res://systems/player/freecam_controller.gd"

## Player height 1.8 m, eye 1.65 m — the project's scale contract. The controller's
## own defaults carry the rest; only what the scene must pin down is set here.
const BODY_RADIUS: float = 0.34
const BODY_HEIGHT: float = 1.80
## A hair over 45 degrees, so a ramp built at exactly 45 is unambiguously walkable
## instead of landing on the wrong side of a floating-point comparison.
const FLOOR_MAX_ANGLE: float = 0.8029
const NEAR_PLANE: float = 0.06
const FAR_PLANE: float = 1400.0
## The reference's viewmodel lens: 58 degrees, near 0.006 m, far 6 m.
const GUN_FOV: float = 58.0
const GUN_NEAR: float = 0.006
const GUN_FAR: float = 6.0
## Every visual layer except the viewmodel's. A world camera that renders the gun would
## draw it clipped through walls at the wrong FOV, which is the whole reason the
## viewmodel gets its own pass — and it is also what keeps the two viewmodel lights,
## which live on `VIEWMODEL` alone, from touching a single world surface.
const WORLD_CULL_MASK: int = 0xFFFFF & ~GameLayers.VIEWMODEL

## The sky the gun's ambient and reflections come off. Baked by `res://tools/build_art.gd`,
## which runs before this step in `bake_all`.
const SKY_MATERIAL: String = "res://art/materials/sky_material.tres"
const AMBIENT_ENERGY: float = 0.42

## The viewmodel key and fill, in the eye's frame. Pitch is downward from horizontal;
## yaw is off the view axis toward the shooter's right. `ViewmodelPass` exports the same
## values and re-applies them at load, so the prefab and the runtime cannot drift.
const KEY_COLOR: Color = Color(1.0, 0.94, 0.86)
const KEY_ENERGY: float = 2.1
const KEY_PITCH: float = -38.0
const KEY_YAW: float = 34.0
const FILL_COLOR: Color = Color(0.62, 0.68, 0.80)
const FILL_ENERGY: float = 0.55
const FILL_PITCH: float = 22.0
const FILL_YAW: float = -128.0

var _built: bool = false


func _process(_delta: float) -> bool:
	if _built:
		return true
	_built = true
	_build()
	return true


func _build() -> void:
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	var player: Node = _build_player()
	_save(player, PLAYER_PATH)
	player.free()
	var freecam: Node = _build_freecam("Freecam", NodePath())
	_save(freecam, FREECAM_PATH)
	freecam.free()


func _save(root: Node, path: String) -> void:
	var packed := PackedScene.new()
	var err: Error = packed.pack(root)
	if err != OK:
		push_error("build_player: packing %s failed (error %d)." % [path, err])
		return
	err = ResourceSaver.save(packed, path)
	if err != OK:
		push_error("build_player: could not save %s (error %d)." % [path, err])
	else:
		print("build_player: baked %s (%d nodes)" % [path, _count(root)])


func _build_player() -> CharacterBody3D:
	var root: CharacterBody3D = _build_body()
	var eye: Camera3D = _add_camera(root)
	_add_effects(root)
	_add_holster(eye)
	_add_viewmodel_lights(eye)
	_add_viewmodel(root)
	var cam: Camera3D = _build_freecam("Freecam", NodePath(".."))
	root.add_child(cam)
	_own(root, root)
	return root


func _build_body() -> CharacterBody3D:
	var script: Script = load(SCRIPT_CONTROLLER)
	var root: CharacterBody3D = script.new()
	root.name = "Player"
	root.collision_layer = GameLayers.PLAYER
	root.collision_mask = GameLayers.MASK_PLAYER_MOVE
	root.floor_max_angle = FLOOR_MAX_ANGLE
	root.safe_margin = float(root.get(&"collision_margin"))
	root.set(&"body_shape_path", NodePath("Body"))
	root.set(&"radius", BODY_RADIUS)
	root.set(&"stand_height", BODY_HEIGHT)

	# A cylinder, not a capsule. A capsule's rounded base slides off ledges and turns
	# every step edge into a ramp, which is exactly the feel this controller is built to
	# avoid; the reference's collider is a circle in XZ and a slab in Y, and a cylinder
	# is that. It is marked local-to-scene because the controller resizes it when you
	# crouch, and two players sharing one shape resource would crouch each other.
	var shape := CylinderShape3D.new()
	shape.radius = BODY_RADIUS
	shape.height = BODY_HEIGHT
	shape.resource_local_to_scene = true

	var body := CollisionShape3D.new()
	body.name = "Body"
	body.shape = shape
	body.position = Vector3(0.0, BODY_HEIGHT * 0.5, 0.0)
	root.add_child(body)
	return root


func _add_camera(root: CharacterBody3D) -> Camera3D:
	var script: Script = load(SCRIPT_CAMERA)
	var eye: Camera3D = script.new()
	eye.name = "Eye"
	eye.set(&"controller_path", NodePath(".."))
	eye.set(&"effects_path", NodePath("../Effects"))
	eye.current = true
	eye.near = NEAR_PLANE
	eye.far = FAR_PLANE
	eye.fov = 78.0
	eye.cull_mask = WORLD_CULL_MASK
	eye.rotation_order = EULER_ORDER_YXZ
	eye.top_level = true
	root.add_child(eye)
	return eye


func _add_effects(root: CharacterBody3D) -> void:
	var script: Script = load(SCRIPT_EFFECTS)
	var fx: Node = script.new()
	fx.name = "Effects"
	fx.set(&"controller_path", NodePath(".."))
	root.add_child(fx)


## The holster hangs off the eye, in the ordinary tree, so its hotkeys reach it and its
## pose is trivially eye-relative. Only the meshes it builds go to the viewmodel layer.
##
## `Hand` and `Hand/Lift` are baked rather than left to the runtime because a demo hangs
## props off `Hand` — the range's ammo counter does — and a node that only exists after
## `_ready` is a node an `@onready` cannot find.
func _add_holster(eye: Camera3D) -> void:
	var script: Script = load(SCRIPT_HOLSTER)
	var holster: Node3D = script.new()
	holster.name = "Holster"
	holster.set(&"player_path", NodePath("../.."))
	eye.add_child(holster)

	var hand := Node3D.new()
	hand.name = "Hand"
	# The pose solve composes its Euler triple in XYZ and its ADS assertions are made in
	# that order; Godot's Node3D default is YXZ.
	hand.rotation_order = EULER_ORDER_XYZ
	holster.add_child(hand)

	var lift := Node3D.new()
	lift.name = "Lift"
	hand.add_child(lift)


## The only lights the viewmodel pass has. A light is culled per camera by its own
## visual layers against that camera's `cull_mask`, and every world light is on `WORLD`,
## so the gun camera saw nothing at all and a metallic receiver tonemapped to black.
## These sit on `VIEWMODEL` alone — invisible to the world camera, which culls exactly
## that layer — and under the eye, so the shading is welded to the view.
func _add_viewmodel_lights(eye: Camera3D) -> void:
	var key := DirectionalLight3D.new()
	key.name = "ViewmodelKey"
	key.layers = GameLayers.VIEWMODEL
	key.shadow_enabled = false
	key.rotation_order = EULER_ORDER_YXZ
	key.light_color = KEY_COLOR
	key.light_energy = KEY_ENERGY
	key.rotation = Vector3(deg_to_rad(KEY_PITCH), deg_to_rad(KEY_YAW), 0.0)
	eye.add_child(key)

	var fill := DirectionalLight3D.new()
	fill.name = "ViewmodelFill"
	fill.layers = GameLayers.VIEWMODEL
	fill.shadow_enabled = false
	fill.rotation_order = EULER_ORDER_YXZ
	fill.light_color = FILL_COLOR
	fill.light_energy = FILL_ENERGY
	fill.light_specular = 0.15
	fill.rotation = Vector3(deg_to_rad(FILL_PITCH), deg_to_rad(FILL_YAW), 0.0)
	eye.add_child(fill)


func _add_viewmodel(root: CharacterBody3D) -> void:
	var script: Script = load(SCRIPT_VIEWMODEL)
	var rig: CanvasLayer = script.new()
	rig.name = "Viewmodel"
	rig.set(&"eye_path", NodePath("../Eye"))
	rig.set(&"controller_path", NodePath(".."))
	# Layer 0 puts the composite directly over the 3D world and under every HUD layer,
	# which is exactly where a viewmodel belongs.
	rig.layer = 0
	root.add_child(rig)

	var screen := SubViewportContainer.new()
	screen.name = "Screen"
	screen.stretch = true
	screen.mouse_filter = Control.MOUSE_FILTER_IGNORE
	screen.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	rig.add_child(screen)

	var view := SubViewport.new()
	view.name = "View"
	view.transparent_bg = true
	view.handle_input_locally = false
	view.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	# The viewmodel pass has no point lights of its own and the world's are culled out
	# of it, so a shadow atlas here would be an idle texture and nothing else.
	view.positional_shadow_atlas_size = 0
	screen.add_child(view)

	var cam := Camera3D.new()
	cam.name = "GunCam"
	cam.current = true
	cam.near = GUN_NEAR
	cam.far = GUN_FAR
	cam.fov = GUN_FOV
	cam.cull_mask = GameLayers.VIEWMODEL
	cam.rotation_order = EULER_ORDER_YXZ
	cam.environment = _viewmodel_environment()
	view.add_child(cam)


## The gun's environment.
##
## The background must be CLEARED, not the sky: the SubViewport is composited over the
## world and a sky here would paint over the frame behind it. But ambient and REFLECTION
## both come off the same sky the world uses, and the reflection half is not optional —
## `gun_steel` is metallic 0.72, and a metal with no radiance map to reflect has almost
## no diffuse remainder to light. That is what rendered the held weapon as a black slab.
## Taking both off the shared sky is also what makes a gun in the hand the same alloy as
## the gun that was lying on the ground a second ago.
func _viewmodel_environment() -> Environment:
	var sky_material := ResourceLoader.load(SKY_MATERIAL, "Material") as Material
	if sky_material == null:
		push_error("build_player: missing %s. Run res://tools/build_art.gd first." % SKY_MATERIAL)
		return null

	var sky := Sky.new()
	sky.sky_material = sky_material
	sky.process_mode = Sky.PROCESS_MODE_REALTIME
	# 128 is plenty for a radiance map nothing mirror-smooth is ever going to sample.
	sky.radiance_size = Sky.RADIANCE_SIZE_128

	var env := Environment.new()
	env.background_mode = Environment.BG_CLEAR_COLOR
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = AMBIENT_ENERGY
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.tonemap_white = 6.0
	env.adjustment_enabled = true
	env.adjustment_contrast = 1.04
	env.adjustment_saturation = 0.9
	# No fog, no glow, no SSAO: the gun is half a metre from the lens and the composite
	# would double-apply anything the world environment already did.
	env.ssao_enabled = false
	env.glow_enabled = false
	env.fog_enabled = false
	return env


func _build_freecam(node_name: String, player_path: NodePath) -> Camera3D:
	var script: Script = load(SCRIPT_FREECAM)
	var cam: Camera3D = script.new()
	cam.name = node_name
	cam.set(&"player_path", player_path)
	cam.near = float(cam.get(&"near_plane"))
	cam.far = FAR_PLANE
	cam.cull_mask = WORLD_CULL_MASK
	cam.current = false
	cam.rotation_order = EULER_ORDER_YXZ
	cam.top_level = true
	return cam


## `PackedScene.pack` only keeps nodes whose owner is the root. Setting it in one sweep
## afterwards is less error-prone than remembering it at fourteen call sites.
func _own(node: Node, root: Node) -> void:
	for child: Node in node.get_children():
		if child.owner == null:
			child.owner = root
		_own(child, root)


func _count(node: Node) -> int:
	var n: int = 1
	for child: Node in node.get_children():
		n += _count(child)
	return n
