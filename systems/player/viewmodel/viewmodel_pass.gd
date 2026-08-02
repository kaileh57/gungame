class_name ViewmodelPass
extends CanvasLayer
## The second render pass the gun lives in, and the only light that reaches it.
##
## The world camera is 78 degrees with a 0.06 m near plane and a 1400 m far plane. A
## gun held at arm's length wants a narrower lens and a near plane two orders of
## magnitude closer, and it must never be clipped by the wall you are standing against.
## Those requirements are mutually exclusive inside one projection, so — exactly as the
## reference does — there are two cameras and two passes.
##
## The implementation is the cheapest one that is actually correct: the gun stays in
## the ordinary scene tree (so its input, its physics neighbours and its node paths are
## all normal) but its meshes sit on the `GameLayers.VIEWMODEL` visual layer. The world
## camera culls that layer; a `Camera3D` inside a transparent `SubViewport` renders it
## and nothing else, and the container composites the result over the world.
##
## LIGHTING. A layer-separated pass is cheap but it is not free: in Godot a light is
## culled per camera by ITS OWN visual layers against the camera's `cull_mask`, and the
## world's sun sits on `WORLD`. So the viewmodel camera saw no lights at all, and the
## gun's steel is metallic 0.72 — with no directional light and no radiance map, a
## metal renders as its own tiny diffuse remainder, which after tonemapping is black.
## That is the whole of the black-slab bug's shading half, and there are two halves to
## the fix:
##
##   * The environment takes its ambient AND its reflections from the project's sky, so
##     the metal has something to reflect and reads as the same alloy the gun on the
##     bench two metres away is made of.
##   * A key and a fill are parented to the eye on the `VIEWMODEL` layer alone. Being
##     on that layer is what keeps them out of the world — the world camera's cull mask
##     excludes it — and being under the eye is what keeps the shading welded to the
##     view instead of swimming as you turn, which is the property the discarded
##     second-World3D rig bought with a whole extra world.
##
## Cost is one extra 3D pass over five meshes on a cleared target plus two shadowless
## directionals. The pass is fill-rate bound and nothing else; there is no second shadow
## map, no second cull of the world, and no geometry duplicated.

## FOV at the hip and at full ADS, degrees — the reference's 58 and 44. Narrower than
## the world camera on purpose: it makes the gun read as close without modelling it at
## a size that would clip.
@export_range(20.0, 110.0, 0.5) var fov_hip: float = 58.0
@export_range(10.0, 90.0, 0.5) var fov_ads: float = 44.0
## The reference's viewmodel near plane. Legal here because nothing in this pass is
## more than a couple of metres away, so the depth range never has to stretch.
@export_range(0.001, 0.2, 0.001) var near_plane: float = 0.006
@export_range(1.0, 40.0, 0.5) var far_plane: float = 6.0
## Render target scale. 1 is native; dropping it is the first thing to try if the extra
## pass ever costs measurable frames, because a viewmodel tolerates softness.
@export_range(0.25, 1.0, 0.05) var resolution_scale: float = 1.0

@export_group("Lighting")
## Key light colour. Warm, high and slightly behind the shooter — the light you would
## be standing in out on the flats.
@export var key_color: Color = Color(1.0, 0.94, 0.86)
@export_range(0.0, 8.0, 0.05) var key_energy: float = 2.1
## Key direction as pitch/yaw degrees, in the eye's frame. Pitch is downward from
## horizontal, yaw is off the view axis toward the shooter's right.
@export_range(-90.0, 90.0, 0.5) var key_pitch: float = -38.0
@export_range(-180.0, 180.0, 0.5) var key_yaw: float = 34.0
## Fill light, cold and low, so the underside of the receiver is not a black hole.
@export var fill_color: Color = Color(0.62, 0.68, 0.80)
@export_range(0.0, 8.0, 0.05) var fill_energy: float = 0.55
@export_range(-90.0, 90.0, 0.5) var fill_pitch: float = 22.0
@export_range(-180.0, 180.0, 0.5) var fill_yaw: float = -128.0

@export_group("Wiring")
@export var eye_path: NodePath = NodePath("../Eye")
@export var controller_path: NodePath = NodePath("..")
@export var container_path: NodePath = NodePath("Screen")
@export var viewport_path: NodePath = NodePath("Screen/View")
@export var camera_path: NodePath = NodePath("Screen/View/GunCam")
## Lights live under the eye rather than under this node: a `CanvasLayer` is not a
## `Node3D`, and the whole point of them is that they turn with the view.
@export var key_name: StringName = &"ViewmodelKey"
@export var fill_name: StringName = &"ViewmodelFill"

var _eye: Camera3D = null
var _player: PlayerController = null
var _container: SubViewportContainer = null
## Set while a scope tube has replaced the hands. See `set_suppressed`.
var _suppressed: bool = false
var _view: SubViewport = null
var _cam: Camera3D = null
var _key: DirectionalLight3D = null
var _fill: DirectionalLight3D = null
var _fov: float = 58.0


func _ready() -> void:
	_container = get_node_or_null(container_path) as SubViewportContainer
	_view = get_node_or_null(viewport_path) as SubViewport
	_cam = get_node_or_null(camera_path) as Camera3D
	if _container == null or _view == null or _cam == null:
		push_error("ViewmodelPass: baked children missing; the gun is not composited.")
		set_process(false)
		return
	_eye = get_node_or_null(eye_path) as Camera3D
	_player = get_node_or_null(controller_path) as PlayerController
	if _eye == null or _player == null:
		push_error("ViewmodelPass: eye_path or controller_path does not resolve.")
		set_process(false)
		return
	_cam.near = near_plane
	_cam.far = far_plane
	_cam.cull_mask = GameLayers.VIEWMODEL
	_cam.current = true
	_view.transparent_bg = true
	_view.scaling_3d_scale = resolution_scale
	_fov = fov_hip
	_cam.fov = _fov
	build_lighting()
	GameSettings.register_viewport(_view)
	# Must land after the camera rig has placed the eye for this frame, or the gun
	# trails the view by one frame and every fast turn smears.
	process_priority = 110


func _exit_tree() -> void:
	if _view != null:
		GameSettings.unregister_viewport(_view)


## Hide the hands entirely, for the duration of something that replaces them.
##
## A SCOPE PICTURE WITH A RIFLE IN IT IS NOT A SCOPE PICTURE. Looking down a tube you
## see the target and nothing else — leaving the weapon and its ammunition plate drawn
## inside the circle is what made the first working tube still read wrong. Routed
## through the same switch freecam uses, so the gun viewport genuinely stops rendering
## rather than being drawn and covered: at 4x-9x magnification the pass is the most
## expensive thing on screen and it is completely invisible.
func set_suppressed(value: bool) -> void:
	_suppressed = value


func _process(_delta: float) -> void:
	# Freecam is a debug view of the world, not of your hands.
	var showing: bool = not _player.freecam_active and not _suppressed
	if _container.visible != showing:
		_container.visible = showing
		_view.render_target_update_mode = (
			SubViewport.UPDATE_ALWAYS if showing else SubViewport.UPDATE_DISABLED
		)
		_set_lights_visible(showing)
	if not showing:
		return
	_cam.global_transform = _eye.global_transform
	var want: float = lerpf(fov_hip, fov_ads, _player.ads)
	if absf(want - _fov) > 0.01:
		_fov = want
		_cam.fov = want


## Find or create the key and the fill under the eye and push the exported values onto
## them. Idempotent, so a pair baked into the player prefab is adopted rather than
## duplicated, and `res://tools/build_player.gd` and the runtime cannot drift.
func build_lighting() -> void:
	if _eye == null:
		return
	_key = _light(key_name)
	_key.light_color = key_color
	_key.light_energy = key_energy
	_key.rotation = Vector3(deg_to_rad(key_pitch), deg_to_rad(key_yaw), 0.0)
	_fill = _light(fill_name)
	_fill.light_color = fill_color
	_fill.light_energy = fill_energy
	# A cold fill that threw highlights would read as a second sun on the receiver.
	_fill.light_specular = 0.15
	_fill.rotation = Vector3(deg_to_rad(fill_pitch), deg_to_rad(fill_yaw), 0.0)


func key_light() -> DirectionalLight3D:
	return _key


func fill_light() -> DirectionalLight3D:
	return _fill


func _light(node_name: StringName) -> DirectionalLight3D:
	var found := _eye.get_node_or_null(NodePath(node_name)) as DirectionalLight3D
	if found == null:
		found = DirectionalLight3D.new()
		found.name = String(node_name)
		_eye.add_child(found)
	# The one line that keeps this light out of the world: the world camera's cull mask
	# is every layer EXCEPT the viewmodel's, so a light that lives only there is invisible
	# to it and cannot touch a single world surface.
	found.layers = GameLayers.VIEWMODEL
	found.shadow_enabled = false
	found.rotation_order = EULER_ORDER_YXZ
	return found


func _set_lights_visible(shown: bool) -> void:
	if _key != null:
		_key.visible = shown
	if _fill != null:
		_fill.visible = shown
