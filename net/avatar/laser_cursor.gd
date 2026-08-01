class_name LaserCursor
extends Node3D
## One player's laser-pointer dot, sitting on whatever they are pointing at.
##
## THE DOT IS A POINT, NOT A RAY. The owner casts the ray on its own machine and sends
## the RESULT — one `Vector3` at `NetPresence.aim_period` — so nobody re-simulates
## anybody's aim, the dot cannot disagree with what the owner sees, and the cost on the
## wire is a dozen bytes rather than a ray plus a world state to cast it against. There
## is no beam. You see where they are pointing, not where they are pointing FROM.
##
## Three things this node does that a bare `MeshInstance3D` at a position would not:
##
##   IT INTERPOLATES. Points arrive fifteen times a second and the frame runs at two
##   hundred and forty, so a raw assignment is a dot that ticks. It chases the last
##   point with an exponential whose time constant is under one send interval, and
##   SNAPS when the jump is bigger than `snap_distance` — a flick across the map should
##   arrive, not sweep through the wall in between.
##
##   IT LIFTS OFF THE SURFACE. The point is ON geometry, so a quad drawn there
##   z-fights. It is pushed toward the eye by an amount that grows with range, which is
##   sub-pixel laterally at every distance and always in front of the surface.
##
##   IT HOLDS AN ANGULAR SIZE. A dot of fixed world size is a dinner plate at two
##   metres and invisible at eighty. `size_angle` is its half-size in radians, clamped
##   at both ends, so it reads the same wherever it lands.
##
## `set_hovered(true)` reveals the owner's name above it — that is the whole dot-on-dot
## interaction, and `NetPresence` decides who is hovered because only it can see every
## dot at once.

## Node names inside the baked scene. Looked up once in `_ready`.
const DOT_NODE: NodePath = ^"Dot"
const PLATE_NODE: NodePath = ^"Plate"
const P_DOT_COLOR: StringName = &"dot_color"
const P_OPACITY: StringName = &"opacity"

## Metres of a jump past which the dot teleports instead of sliding. A laser sweeping
## across a room is real; a laser sliding through a building is not.
@export_range(0.5, 60.0, 0.5) var snap_distance: float = 8.0
## Seconds the interpolation takes to cover about two thirds of the gap. Under one send
## interval, or the dot lags visibly behind the owner's own crosshair.
@export_range(0.01, 0.5, 0.005) var smooth_seconds: float = 0.055
## Half-size of the QUAD in radians of the viewer's field. The bright core is 60% of
## that (`core_radius` 0.30 of a quad whose half-width is 0.5), so 0.0088 rad puts a
## seven-pixel core inside a ten-pixel dark ring at 1080p and 78 degrees — findable on
## bleached sand, and still a dot rather than a marker pen. The first build used 0.0034
## and rendered a core under one pixel across, which is a dot you cannot see.
@export_range(0.0005, 0.05, 0.0001) var size_angle: float = 0.0105
@export_range(0.005, 2.0, 0.005) var size_min: float = 0.030
## Past the range where this binds the dot stops holding its angular size and starts
## shrinking, which is correct: at a hundred metres you want to be told there IS a dot,
## not to be shown a dinner plate.
@export_range(0.02, 8.0, 0.01) var size_max: float = 1.20
## Fraction of the range the dot is pushed toward the eye by, and its limits. Enough to
## clear the depth buffer at four hundred metres, small enough to be invisible at two.
@export_range(0.0, 0.05, 0.0005) var lift_fraction: float = 0.004
@export_range(0.0, 1.0, 0.001) var lift_max: float = 0.35
## Seconds without a fresh point before the dot fades away. One dropped packet must not
## blink it; a player who has left must not leave a dot behind.
@export_range(0.1, 5.0, 0.05) var stale_seconds: float = 1.1
@export_range(0.02, 2.0, 0.01) var fade_seconds: float = 0.18
## Alpha of your OWN dot, which is drawn dimmer because your crosshair already told you.
@export_range(0.0, 1.0, 0.01) var dim_opacity: float = 0.5

var peer_id: int = 0

var _dot: MeshInstance3D = null
var _plate: NetNameplate = null
var _material: ShaderMaterial = null
var _color: Color = Color.WHITE
var _target: Vector3 = Vector3.ZERO
var _shown: Vector3 = Vector3.ZERO
var _valid: bool = false
var _placed: bool = false
var _since_push: float = 999.0
var _fade: float = 0.0
var _dim: bool = false
var _hovered: bool = false


func _ready() -> void:
	_dot = get_node_or_null(DOT_NODE) as MeshInstance3D
	_plate = get_node_or_null(PLATE_NODE) as NetNameplate
	if _dot != null:
		# Duplicated because `dot_color` is a plain uniform and four cursors need four
		# colours. The SHADER is shared, so this costs a resource and not a compile.
		_material = (_dot.get_active_material(0) as ShaderMaterial).duplicate()
		_dot.material_override = _material
	if _plate != null:
		# Faded to nothing, NOT hidden. `NetNameplate` owns its own `visible` every
		# frame — it hides itself when there is no camera or no text and shows itself
		# otherwise — so a `visible = false` here survives exactly one frame. The first
		# two-instance run had the hover label permanently on screen because of it.
		_plate.set_dim(0.0)
	visible = false
	set_process(true)


func _process(delta: float) -> void:
	_since_push += delta
	var want: float = 1.0 if _valid and _since_push < stale_seconds else 0.0
	_fade = move_toward(_fade, want, delta / maxf(fade_seconds, 0.001))
	if _fade <= 0.004:
		visible = false
		return
	var camera: Camera3D = _eye()
	if camera == null or not _placed:
		visible = false
		return
	_advance(delta)
	visible = true
	_place(camera)


## Take a new aim point. Called by `NetPresence` — from the network for a remote player,
## and straight off the local probe for your own dot.
func push(point: Vector3, valid: bool) -> void:
	_since_push = 0.0
	_valid = valid
	if not valid:
		return
	if not _placed or _shown.distance_to(point) > snap_distance:
		_shown = point
		_placed = true
	_target = point


## The dot's own colour, and the colour of the name it reveals when hovered.
func set_color(c: Color) -> void:
	_color = c
	if _material != null:
		_material.set_shader_parameter(P_DOT_COLOR, c)
	if _plate != null:
		_plate.player_color = c


func set_player_name(text: String) -> void:
	if _plate != null:
		_plate.text = text


## Whose dot this is, for `NetPresence`'s bookkeeping.
func set_peer(id: int) -> void:
	peer_id = id
	name = "Dot%d" % id


## Draw dimmer. Your own dot wears this: the crosshair already says where you are
## pointing, so your dot is there to make the dot-on-dot game legible and nothing more.
func set_dim(on: bool) -> void:
	_dim = on


## Somebody's dot is on this one. Reveals the owner's name above it.
func set_hovered(on: bool) -> void:
	if _hovered == on:
		return
	_hovered = on
	if _plate != null:
		_plate.set_dim(1.0 if on else 0.0)


## Where the dot actually is, smoothed. `NetPresence` tests hover against this rather
## than against the raw target, so the interaction agrees with what is on screen.
func point() -> Vector3:
	return _shown


## True while the dot is being drawn — a fresh point, and not yet faded out.
func is_live() -> bool:
	return _valid and _since_push < stale_seconds and _placed


## Exponential chase. Framerate independent: the fraction covered in a frame is
## `1 - exp(-dt/tau)`, so 240 fps and 60 fps settle on the same curve.
func _advance(delta: float) -> void:
	var alpha: float = 1.0 - exp(-delta / maxf(smooth_seconds, 0.001))
	_shown = _shown.lerp(_target, clampf(alpha, 0.0, 1.0))


func _place(camera: Camera3D) -> void:
	var eye: Vector3 = camera.global_position
	var to_eye: Vector3 = eye - _shown
	var distance: float = to_eye.length()
	if distance < 0.001:
		visible = false
		return
	global_position = _shown + to_eye * (minf(distance * lift_fraction, lift_max) / distance)
	var size: float = clampf(distance * size_angle * 2.0, size_min, size_max)
	if _dot != null:
		_dot.scale = Vector3(size, size, size)
	if _material != null:
		_material.set_shader_parameter(P_OPACITY, _fade * (dim_opacity if _dim else 1.0))
	if _plate != null and _hovered:
		# A constant multiple of the dot's own size, so the gap is constant on screen.
		_plate.position = Vector3(0.0, size * 1.8, 0.0)
		_plate.set_dim(_fade)


func _eye() -> Camera3D:
	var viewport: Viewport = get_viewport()
	return null if viewport == null else viewport.get_camera_3d()
