class_name PlayerAvatar
extends Node3D
## What another player looks like: a capsule with sunglasses and their name over it.
##
## The brief is a capsule, and the capsule is doing real work — it is the cheapest shape
## that reads as a person at eighty metres, it has no pose to get wrong, and there is no
## rig to animate out of sync with a network tick. What it lacks is a FRONT, which is
## the one thing you need from another player at a glance, so it wears a wraparound
## visor and two temple arms: a dark band across a light body, which survives being
## twelve pixels tall and tells you which way they are facing at a distance where a nose
## would not.
##
## THREE PRESENCE MODES, because the demos want different things, and a demo picks with
## one line (see `NetPresence`):
##
##   FULL    the capsule, the visor, the nameplate, a collider. Every demo you walk
##           around in.
##   SPHERE  a translucent bubble instead of a body. The firefight spectator: present
##           and locatable, but not pretending to be a combatant on a field of a
##           hundred of them.
##   GHOST   a translucent capsule, no collider, and the cross-map beacon. The
##           ash_flats race, where you must know where the other three are through a
##           town, and must not be able to body-block them.
##
## EVERYTHING IS BAKED. The meshes, the four materials and this scene are written once
## by `res://tools/build_avatar.gd` into `res://data/net/`; nothing here builds geometry
## at runtime. Colour is the one per-player thing and it costs no material: it goes in
## through the `tint` instance uniform that both the scrap shader and the ghost shader
## declare, so four players are four uniform writes and not four materials.

enum Mode { FULL = 0, SPHERE = 1, GHOST = 2 }

const BODY_NODE: NodePath = ^"Body"
const SHELL_NODE: NodePath = ^"Body/Shell"
const GHOST_NODE: NodePath = ^"Body/Ghost"
const BUBBLE_NODE: NodePath = ^"Body/Bubble"
const VISOR_NODE: NodePath = ^"Body/Visor"
const TEMPLES_NODE: NodePath = ^"Body/Temples"
const HULL_NODE: NodePath = ^"Body/Hull"
const PLATE_NODE: NodePath = ^"Plate"
const BEACON_NODE: NodePath = ^"Beacon"

const P_TINT: StringName = &"tint"
const P_MARK_COLOR: StringName = &"mark_color"
const P_OPACITY: StringName = &"opacity"

## Player height, from `tools/build_player.gd`. The avatar is the same size as the body
## it stands in for, or a capsule is a liar about cover.
const STAND_HEIGHT: float = 1.80
const BODY_RADIUS: float = 0.34
## Where the nameplate hangs, above the crown.
const PLATE_HEIGHT: float = STAND_HEIGHT + 0.30
## Where the GHOST beacon's shaft starts. Clear of the plate, so the two do not overlap
## at the range where both are readable.
const BEACON_BASE: float = STAND_HEIGHT + 0.75
## Height over width the beacon quad is authored at. Must match the shader's `aspect`.
const BEACON_ASPECT: float = 7.0

## Seconds the avatar takes to cover about two thirds of the gap to its last known
## position. Under one network tick at any sane tick rate.
@export_range(0.01, 0.5, 0.005) var smooth_seconds: float = 0.075
## Metres of a jump past which the avatar teleports instead of sliding. A respawn, a
## scene change or a fresh join must arrive rather than fly across the map.
@export_range(0.5, 60.0, 0.5) var snap_distance: float = 5.0
## Beacon height as a fraction of range, and its limits, in metres. At 300 m the
## default gives a 9 m shaft, which is about 1.7 degrees — findable while turning.
@export_range(0.0, 0.2, 0.001) var beacon_fraction: float = 0.030
@export_range(0.5, 40.0, 0.5) var beacon_min: float = 3.0
@export_range(2.0, 200.0, 1.0) var beacon_max: float = 40.0

var peer_id: int = 0
var player_name: String = "":
	set = set_player_name
var player_color: Color = Color.WHITE:
	set = set_color
var mode: int = Mode.FULL:
	set = set_mode

var _body: Node3D = null
var _shell: MeshInstance3D = null
var _ghost: MeshInstance3D = null
var _bubble: MeshInstance3D = null
var _visor: MeshInstance3D = null
var _temples: MeshInstance3D = null
var _hull: CollisionObject3D = null
var _plate: NetNameplate = null
var _beacon: MeshInstance3D = null
var _beacon_material: ShaderMaterial = null
var _target: Vector3 = Vector3.ZERO
var _target_yaw: float = 0.0
var _yaw: float = 0.0
var _placed: bool = false
var _dim: float = 1.0
## The plate's authored fade band, so GHOST can widen it and FULL can put it back.
var _plate_fade: Vector2 = Vector2(55.0, 90.0)


func _ready() -> void:
	_body = get_node_or_null(BODY_NODE) as Node3D
	_shell = get_node_or_null(SHELL_NODE) as MeshInstance3D
	_ghost = get_node_or_null(GHOST_NODE) as MeshInstance3D
	_bubble = get_node_or_null(BUBBLE_NODE) as MeshInstance3D
	_visor = get_node_or_null(VISOR_NODE) as MeshInstance3D
	_temples = get_node_or_null(TEMPLES_NODE) as MeshInstance3D
	_hull = get_node_or_null(HULL_NODE) as CollisionObject3D
	_plate = get_node_or_null(PLATE_NODE) as NetNameplate
	_beacon = get_node_or_null(BEACON_NODE) as MeshInstance3D
	if _plate != null:
		_plate_fade = Vector2(_plate.fade_start, _plate.fade_end)
	if _beacon != null:
		# One material per avatar, because `mark_color` is a plain uniform. Four of them
		# in the worst case, and the shader behind them is shared.
		_beacon_material = (_beacon.get_active_material(0) as ShaderMaterial).duplicate()
		_beacon.material_override = _beacon_material
	visible = false
	set_mode(mode)
	set_color(player_color)
	set_player_name(player_name)
	set_process(true)


func _process(delta: float) -> void:
	if not _placed:
		visible = false
		return
	visible = _dim > 0.004
	if not visible:
		return
	var alpha: float = clampf(1.0 - exp(-delta / maxf(smooth_seconds, 0.001)), 0.0, 1.0)
	global_position = global_position.lerp(_target, alpha)
	_yaw = lerp_angle(_yaw, _target_yaw, alpha)
	if _body != null:
		_body.rotation.y = _yaw
	if mode == Mode.GHOST:
		_size_beacon()


## Where the avatar is, and which way it faces. This is what NET-CORE pushes every
## network tick; everything between ticks is the smoothing above.
func set_target(world_position: Vector3, yaw: float) -> void:
	if not _placed or global_position.distance_to(world_position) > snap_distance:
		snap_to(world_position, yaw)
		return
	_target = world_position
	_target_yaw = yaw


## Put the avatar somewhere with no interpolation. A spawn, a teleport, a scene change.
func snap_to(world_position: Vector3, yaw: float) -> void:
	_target = world_position
	_target_yaw = yaw
	_yaw = yaw
	global_position = world_position
	if _body != null:
		_body.rotation.y = yaw
	_placed = true


func set_player_name(text: String) -> void:
	player_name = text
	if _plate != null:
		_plate.text = text


## The player's colour, straight into the `tint` instance uniform of every shell. No
## material is created and none is duplicated: this is three uniform writes.
func set_color(c: Color) -> void:
	player_color = c
	# The shell's tint is a MULTIPLIER over a light neutral albedo, so it is lifted
	# first: slot 0 is the palette's red at value 0.63, and 0.63 times 0.86 is a body
	# you cannot pick out of its own shadow. The ghost and the bubble write the colour
	# straight to ALBEDO and want the same lifted value, so both take one number.
	var tint: Color = NetColors.tint(c)
	for shell: MeshInstance3D in [_shell, _ghost, _bubble]:
		if shell != null:
			shell.set_instance_shader_parameter(P_TINT, tint)
	if _plate != null:
		_plate.player_color = c
	if _beacon_material != null:
		_beacon_material.set_shader_parameter(P_MARK_COLOR, c)


## Switch presence mode. Cheap enough to call every frame; it only toggles visibility.
func set_mode(new_mode: int) -> void:
	mode = clampi(new_mode, int(Mode.FULL), int(Mode.GHOST))
	var solid: bool = mode == Mode.FULL
	var ghosted: bool = mode == Mode.GHOST
	var bubbled: bool = mode == Mode.SPHERE
	if _shell != null:
		_shell.visible = solid
	if _ghost != null:
		_ghost.visible = ghosted
	if _bubble != null:
		_bubble.visible = bubbled
	# The visor survives into GHOST because facing is the one thing a translucent
	# capsule cannot tell you on its own, and a racer needs to know which way you went.
	for part: MeshInstance3D in [_visor, _temples]:
		if part != null:
			part.visible = solid or ghosted
	if _beacon != null:
		_beacon.visible = ghosted
	set_collision_enabled(not ghosted)
	_apply_plate_mode(ghosted)


## Whether the avatar blocks anything. GHOST turns it off, which is what "no player
## collision" in the race means.
##
## NOTE for whoever owns movement: this collider sits on `GameLayers.PLAYER`, and
## `GameLayers.MASK_PLAYER_MOVE` is `WORLD | PROP` — it does NOT include PLAYER. So the
## hull is inert until the local player's move mask gains that bit. That is a one-line
## change in the layer contract and it is deliberately not made here.
func set_collision_enabled(on: bool) -> void:
	if _hull == null:
		return
	# The LAYER, not the node's process mode: a body with no layers is invisible to
	# every query and every mask, while a disabled process mode would leave the shape
	# in the world and merely stop the callbacks nothing here uses.
	_hull.collision_layer = GameLayers.PLAYER if on else 0


## Fade the whole avatar, 0 to 1. Used while a player is joining or leaving, so nobody
## pops into existence at full opacity in the middle of the frame.
func set_dim(fraction: float) -> void:
	_dim = clampf(fraction, 0.0, 1.0)
	if _plate != null:
		_plate.set_dim(_dim)
	for shell: MeshInstance3D in [_ghost, _bubble]:
		if shell != null:
			var material := shell.get_active_material(0) as ShaderMaterial
			if material != null:
				shell.set_instance_shader_parameter(P_OPACITY, _dim)


## World point the nameplate hangs over. What a hover label or a callout anchors to.
func head_point() -> Vector3:
	return global_position + Vector3(0.0, PLATE_HEIGHT, 0.0)


## The plate rides the beacon in GHOST so the through-walls mark says WHO, and sits on
## the head otherwise. The fade band is widened to the whole map for the same reason:
## a beacon you can see at three hundred metres over a name that faded at ninety is a
## coloured smear with no owner.
func _apply_plate_mode(ghosted: bool) -> void:
	if _plate == null:
		return
	_plate.set_through_walls(ghosted)
	_plate.fade_start = 2000.0 if ghosted else _plate_fade.x
	_plate.fade_end = 4000.0 if ghosted else _plate_fade.y
	_plate.position = Vector3(0.0, BEACON_BASE if ghosted else PLATE_HEIGHT, 0.0)


## The beacon holds an angular size rather than a world one, so it is the same mark at
## forty metres and at four hundred. The plate is lifted to sit above its diamond.
func _size_beacon() -> void:
	if _beacon == null:
		return
	var viewport: Viewport = get_viewport()
	var camera: Camera3D = null if viewport == null else viewport.get_camera_3d()
	if camera == null:
		return
	var distance: float = camera.global_position.distance_to(global_position)
	var height: float = clampf(distance * beacon_fraction, beacon_min, beacon_max)
	_beacon.scale = Vector3(height / BEACON_ASPECT, height, 1.0)
	if _plate != null:
		_plate.position.y = BEACON_BASE + height * 1.02
