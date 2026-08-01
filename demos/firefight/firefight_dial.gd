class_name FirefightDial
extends FirefightControl
## The speed dial: a drum on a plinth with five notches cut into its rim and a
## needle that points at the one currently in force.
##
## Interacting steps to the next detent and drives `Engine.time_scale`. The
## needle is the readout — there is no number on screen anywhere and the notches
## are real geometry, engraved at the same angles the needle stops at, so the
## thing can be read at a glance from the far side of the arena.
##
## It restores real time on the way out. A demo that leaves the engine running at
## a quarter speed hands the main menu back broken, and that is the kind of bug
## nobody thinks to look for.
##
## IN MULTIPLAYER IT IS ONE OBJECT IN ONE SHARED WORLD, so the host owns it. A
## client that operates it does not turn its own drum: it emits
## `detent_requested`, the link sends that to the host as intent, and the detent
## comes back to everybody in the state packet through `set_detent`. Every
## machine's needle, and every machine's `Engine.time_scale`, therefore agree —
## which they have to, because a client's dead reckoning of a hundred bodies is
## measured in simulated seconds and would run at the wrong speed otherwise.

## The dial reached a new detent. `scale` is the time scale now in force.
signal detent_changed(index: int, scale: float)
## A client operated the dial and is asking the host to step it.
signal detent_requested

## Engine time scales the needle stops at, slowest first. Five is as many notches
## as fit legibly on a drum this size.
@export var detents: PackedFloat32Array = [0.25, 0.5, 1.0, 2.0, 4.0]
## Which detent the dial starts on. Real time, unless a demo wants otherwise.
@export_range(0, 8, 1) var initial_detent: int = 2
## Total sweep of the needle across the whole range, in degrees. Matches the arc
## the notches are cut over at bake time.
@export_range(30.0, 330.0, 1.0) var sweep_degrees: float = 220.0
## Degrees per second the needle travels between detents.
@export_range(30.0, 1440.0, 5.0) var needle_rate: float = 420.0
## The needle. Rotates about its own local Z.
@export var needle_path: NodePath = NodePath()

var _needle: Node3D = null
var _index: int = 0
var _want_angle: float = 0.0


func _ready() -> void:
	super()
	_needle = get_node_or_null(needle_path) as Node3D
	_index = clampi(initial_detent, 0, maxi(detents.size() - 1, 0))
	_want_angle = _angle_for(_index)
	if _needle != null:
		_needle.rotation.z = _want_angle
	_apply_scale()


func _exit_tree() -> void:
	Engine.time_scale = 1.0


func _physics_process(delta: float) -> void:
	if _needle == null:
		set_physics_process(false)
		return
	# Driven off the physics step so the needle travels at the same rate whatever
	# the dial has just done to the frame clock. A readout that speeds up with
	# the thing it is reporting is a bad readout.
	var step: float = deg_to_rad(needle_rate) * delta / maxf(Engine.time_scale, 0.01)
	_needle.rotation.z = rotate_toward(_needle.rotation.z, _want_angle, step)
	if is_equal_approx(_needle.rotation.z, _want_angle):
		set_physics_process(false)


func caption() -> String:
	return "SIM RATE"


func scale_now() -> float:
	return detents[_index] if _index < detents.size() else 1.0


func detent_index() -> int:
	return _index


## Step to the next detent. The authoritative move: the host's own press lands
## here, and so does a client's request once the host has accepted it.
func step_detent() -> void:
	if detents.is_empty():
		return
	set_detent((_index + 1) % detents.size())


## Put the dial ON a detent. This is the path the wire takes, so it has to be
## safe to call with the value the dial is already showing — which it is, and
## which is why the state packet can carry the detent unconditionally.
func set_detent(index: int) -> void:
	if detents.is_empty():
		return
	var want: int = clampi(index, 0, detents.size() - 1)
	if want == _index:
		return
	_index = want
	_want_angle = _angle_for(_index)
	set_physics_process(true)
	_apply_scale()


func activate(spectator: Node) -> void:
	if detents.is_empty():
		return
	if NetGame.is_authority():
		step_detent()
	else:
		detent_requested.emit()
	super(spectator)


func _angle_for(i: int) -> float:
	if detents.size() < 2:
		return 0.0
	var t: float = float(i) / float(detents.size() - 1)
	return deg_to_rad(sweep_degrees * (0.5 - t))


func _apply_scale() -> void:
	Engine.time_scale = scale_now()
	detent_changed.emit(_index, scale_now())
