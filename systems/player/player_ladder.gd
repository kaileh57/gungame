class_name PlayerLadder
extends Node3D
## A climbable volume. Place one at the FOOT of the ladder with its local +Z pointing
## away from whatever the ladder is bolted to — the same convention the reference uses,
## where the ladder's outward vector is `(sin(ry), cos(ry))`, which is exactly what a
## Y-rotation does to local +Z in Godot. No axis flip, no sign fiddling.
##
## Get the orientation backwards and the rungs run edge-on to the climber while the
## climb volume sits inside the wall, which is the one failure mode worth naming.
##
## Ladders are found by a linear scan over a static registry rather than by physics
## overlap. There are a few hundred of them in a town, the test is eight comparisons,
## and the controller has to run it every tick anyway; an Area3D per ladder would cost
## far more and answer a vaguer question. The registry is the reference's `LADDERS`
## array with node lifetime bolted on.
##
## The world frame is cached on ready and refreshed on transform change, so a scan
## touches no matrices at all — only floats.

## Sideways weighting in `fit_score`. Given two ladders you are standing between, prefer
## the one you are facing over the one you are beside.
const LATERAL_WEIGHT: float = 0.6
## Head-room slack below the foot of the ladder. You can grab on from a little below it.
const MOUNT_SLACK_BELOW: float = 0.35
## How far above the top rung you can still be considered attached.
const MOUNT_SLACK_ABOVE: float = 0.25

static var _registry: Array[PlayerLadder] = []
static var _cache_frame: int = -1
static var _cache_position: Vector3 = Vector3.ZERO
static var _cache_height: float = 0.0
static var _cache_result: PlayerLadder = null

## Half-width of the climbable face along the rungs, metres. The reference's `hx`.
@export_range(0.1, 3.0, 0.01) var half_width: float = 0.78
## How far out from the rungs you can still be holding on, metres. The reference's `hz`.
@export_range(0.1, 3.0, 0.01) var reach: float = 0.95
## How far you may be BEHIND the rung plane and still count as on the ladder. Small, and
## negative-side only: it is the thickness of the rails, not a way into the wall.
@export_range(0.0, 1.0, 0.01) var back_reach: float = 0.45
## Climbable height above this node's origin, metres. The top rung sits here.
@export_range(0.5, 40.0, 0.05) var climb_height: float = 3.0
## How far below the origin the climb volume still starts. The reference bakes this into
## its record as `y0 - 0.15` so you can grab the ladder from a shallow dip at its foot.
@export_range(0.0, 1.0, 0.01) var foot_extension: float = 0.15
## Surface id reported for climb footsteps. Indexes `WorldSurface.Kind`; 0 is metal.
@export_range(0, 8, 1) var surface: int = 0

var _origin: Vector3 = Vector3.ZERO
var _co: float = 1.0
var _si: float = 0.0


func _ready() -> void:
	set_notify_transform(true)
	refresh()
	if not _registry.has(self):
		_registry.append(self)


func _exit_tree() -> void:
	_registry.erase(self)
	if _cache_result == self:
		_cache_frame = -1
		_cache_result = null


func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSFORM_CHANGED:
		refresh()


## Every ladder currently in the tree. Freed nodes take themselves out, so the caller
## never has to validate an entry.
static func registry() -> Array[PlayerLadder]:
	return _registry


## The reference's `findLadder`: the best ladder for a body whose feet are at `feet` and
## which is `height` tall, or null.
##
## The result is cached per physics frame per query point because the spec calls this
## twice a frame — once to drive the climb, once to draw the "climb" prompt — and the
## scan is linear over every ladder in the level.
static func find_for(feet: Vector3, height: float) -> PlayerLadder:
	var frame: int = Engine.get_physics_frames()
	if (
		frame == _cache_frame
		and absf(height - _cache_height) < 1e-4
		and feet.distance_squared_to(_cache_position) < 1e-8
	):
		return _cache_result
	var best: PlayerLadder = null
	var best_score: float = INF
	for l: PlayerLadder in _registry:
		var score: float = l.fit_score(feet, height)
		if score >= 0.0 and score < best_score:
			best_score = score
			best = l
	_cache_frame = frame
	_cache_position = feet
	_cache_height = height
	_cache_result = best
	return best


## Re-read the world transform into the cached frame. Called automatically on any
## transform change; public so a builder can move a ladder and read it back in the same
## frame, before the tree notification lands.
func refresh() -> void:
	_origin = global_position
	var yaw: float = global_basis.get_euler(EULER_ORDER_YXZ).y
	_co = cos(yaw)
	_si = sin(yaw)


## Lowest point you can still grab on at. Below the origin by `foot_extension`.
func bottom_y() -> float:
	return _origin.y - foot_extension


## The top rung. Climbing past this tops out; the world builder is expected to place it
## above the parapet, not level with it, or you climb into the parapet and stick.
func top_y() -> float:
	return _origin.y + climb_height


## Unit vector pointing away from the wall, world XZ. Local +Z.
func out_x() -> float:
	return _si


func out_z() -> float:
	return _co


## Unit vector along the rungs, world XZ. Local +X.
func along_x() -> float:
	return _co


func along_z() -> float:
	return -_si


## How close a body with feet at `feet` and height `height` is to being on this ladder.
## LOWER is better; -1.0 means "not on it at all". Never returns a score in between, so
## the caller can test one value.
func fit_score(feet: Vector3, height: float) -> float:
	if feet.y + height < bottom_y() - MOUNT_SLACK_BELOW:
		return -1.0
	if feet.y > top_y() + MOUNT_SLACK_ABOVE:
		return -1.0
	var dx: float = feet.x - _origin.x
	var dz: float = feet.z - _origin.z
	var lx: float = dx * _co - dz * _si
	var lz: float = dx * _si + dz * _co
	if absf(lx) > half_width or lz < -back_reach or lz > reach:
		return -1.0
	return absf(lx) * LATERAL_WEIGHT + absf(lz)
