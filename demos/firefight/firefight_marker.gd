class_name FirefightMarker
extends FirefightControl
## A surveyor's post with a vane on it, planted at a vantage point. Look at it,
## press interact, and the camera flies to where the post is pointing.
##
## The vane is not decoration: it is the post's forward axis made visible, and
## `vantage()` returns the transform the camera will actually take, so what the
## marker is aiming at is what you will be looking at. Markers with
## `track_hotspot` set re-aim themselves at whatever ground is most contested,
## which is how a spectator finds the fight without being told where it is.

## Where the camera ends up, expressed as an offset in the marker's own frame.
## +Y lifts the eye above the post, -Z pushes it out along the vane.
@export var eye_offset: Vector3 = Vector3(0.0, 3.4, 2.2)
## Seconds the flight takes. Long enough to read as a move, short enough that a
## spectator does not sit through it twice.
@export_range(0.3, 6.0, 0.05) var flight_seconds: float = 1.9
## Re-aim at the director's hotspot instead of holding a fixed bearing. The vane
## physically turns, so the post is always pointing at the war.
@export var track_hotspot: bool = false
## Degrees per second the vane is allowed to swing while tracking. A vane that
## snaps reads as a bug; one that sweeps reads as a machine.
@export_range(1.0, 180.0, 1.0) var track_rate: float = 26.0
## Seconds between hotspot re-reads while tracking.
@export_range(0.05, 4.0, 0.05) var hotspot_period: float = 0.75
## The node that turns. Usually the vane, so the post stays bolted down.
@export var vane_path: NodePath = NodePath()
## What the sign on the post says.
@export var marker_name: String = ""

var director: FirefightDirector = null

var _vane: Node3D = null
var _aim: Vector3 = Vector3.ZERO
var _recheck: float = 0.0


func _ready() -> void:
	super()
	_vane = get_node_or_null(vane_path) as Node3D
	# `+basis.z` is the way the post is aimed: the bake yaws each marker so that
	# axis points at the ground it overlooks. Taking `-basis.z` here sends the
	# vantage out over the rim wall with its back to the fight.
	_aim = global_position + global_transform.basis.z * 26.0
	set_physics_process(track_hotspot)


func _physics_process(delta: float) -> void:
	if director == null or _vane == null:
		return
	# The hotspot is a sweep over every zone against every body. The vane turns at
	# twenty-six degrees a second, so asking sixty times a second buys nothing and
	# costs a few hundred distance tests a frame in a demo whose whole point is
	# the frame budget.
	_recheck -= delta
	if _recheck <= 0.0:
		_recheck = hotspot_period
		# On a guest the war is not simulated on this machine, so there is nothing
		# local to ask: `FirefightWarLink` calls `set_aim` off the state packet.
		if NetGame.is_authority():
			_aim = director.hotspot()
	var to: Vector3 = _aim - global_position
	to.y = 0.0
	if to.length_squared() < 1.0:
		return
	var want: float = atan2(to.x, to.z) - global_rotation.y
	_vane.rotation.y = rotate_toward(_vane.rotation.y, want, deg_to_rad(track_rate) * delta)


func caption() -> String:
	return marker_name


## Point the vane at ground somebody else worked out. The vane still SWEEPS to it
## at `track_rate`, so a replicated hotspot reads exactly like a local one.
func set_aim(point: Vector3) -> void:
	_aim = point


## The camera transform this marker sends you to: out along the vane, up above
## the post, looking back down at whatever the vane is pointing at.
func vantage() -> Transform3D:
	var frame: Transform3D = global_transform
	if _vane != null:
		frame.basis = frame.basis * Basis(Vector3.UP, _vane.rotation.y)
	var eye: Vector3 = frame * eye_offset
	var look: Vector3 = _aim if track_hotspot else global_position + frame.basis.z * 26.0
	var to: Vector3 = look - eye
	if to.length_squared() < 1e-4:
		to = frame.basis.z
	return Transform3D(Basis.looking_at(to.normalized(), Vector3.UP), eye)


func activate(spectator: Node) -> void:
	if spectator.has_method(&"fly_to"):
		spectator.call(&"fly_to", vantage(), flight_seconds)
	super(spectator)
