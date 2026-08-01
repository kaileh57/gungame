class_name ArenaGate
extends Node3D
## A real door in a real wall. The leaf slides, the frame does not, and nothing
## enters this compound without one of these opening first.
##
## The leaf is a `StaticBody3D` and it moves, which means the collider moves with
## it — a gate that only animates its mesh is a gate you walk through while it is
## shut. `travel` is where the leaf ends up relative to its closed position, in the
## gate's own local space, so the same class is a portcullis (travel up) or a
## sliding door (travel sideways) depending on how the builder placed it.
##
## `opened` fires once the leaf has finished moving, not when the lever was
## thrown: whatever is waiting to walk through wants the hole, not the intention.

## The leaf finished opening. Spawners release through this.
signal opened
## The leaf finished closing.
signal closed

## Where the leaf sits when open, relative to shut, in local space.
@export var travel: Vector3 = Vector3(0.0, 3.4, 0.0)
## Seconds for the full throw.
@export_range(0.1, 8.0, 0.05) var seconds: float = 1.35
@export var open_sound: AudioStream = null
@export var close_sound: AudioStream = null

var _open: bool = false
var _t: float = 0.0
var _from: Vector3 = Vector3.ZERO
var _shut: Vector3 = Vector3.ZERO
var _moving: bool = false

@onready var _leaf: StaticBody3D = $Leaf
@onready var _sound: AudioStreamPlayer3D = get_node_or_null(^"Sound") as AudioStreamPlayer3D


func _ready() -> void:
	_shut = _leaf.position
	set_physics_process(false)


func _physics_process(delta: float) -> void:
	_t = minf(_t + delta / maxf(seconds, 0.01), 1.0)
	# Smoothstep, not linear: a two-tonne steel leaf does not start at speed and
	# does not stop dead, and the ease is the whole difference.
	var k: float = _t * _t * (3.0 - 2.0 * _t)
	_leaf.position = _from.lerp(_shut + (travel if _open else Vector3.ZERO), k)
	if _t < 1.0:
		return
	set_physics_process(false)
	_moving = false
	if _open:
		opened.emit()
	else:
		closed.emit()


func is_open() -> bool:
	return _open and not _moving


func is_moving() -> bool:
	return _moving


## Throw the gate. Calling this with the state it is already in and settled does
## nothing; calling it mid-throw reverses from wherever the leaf actually is.
func set_open(value: bool) -> void:
	if value == _open and not _moving:
		return
	_open = value
	_from = _leaf.position
	_t = 0.0
	_moving = true
	set_physics_process(true)
	if _sound != null:
		_sound.stream = open_sound if value else close_sound
		if _sound.stream != null:
			_sound.play()


## World-space point just inside the gate, on the compound side. The spawner
## places a body here so it walks out of the doorway rather than into the frame.
func threshold() -> Transform3D:
	return global_transform
