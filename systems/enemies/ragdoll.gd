class_name Ragdoll
extends PhysicalBoneSimulator3D
## The physics corpse: a baked chain of `PhysicalBone3D` bodies that drives the
## creature's own `Skeleton3D`, so the skinned shell follows a solved fall.
##
## This script is attached by `RagdollBake` to the root of
## `res://data/enemies/ragdolls/<id>.res`. `EnemyBody` instantiates that scene
## under the skeleton at the moment of death, hands it the killing shot, and never
## poses the rig again. Nothing here builds geometry — every shape, mass, joint
## limit and damping value came off the bake.
##
## THE SETTLE IS THE POINT. A ragdoll that keeps twitching costs a solver step
## forever and reads as a broken puppet, so the joints are cone twists with real
## limits, angular damping is high on the limbs and low on the torso, and the
## bodies are allowed to sleep. Once every body has been slow for `settle_time`
## the corpse is declared down: this node stops checking, the engine has already
## put the island to sleep, and `EnemyBody` hands its ragdoll budget slot back so
## the next death can have it.

## The corpse has stopped moving. `EnemyBody` mirrors this onto `collapse_settled`.
signal settled

## Physics ticks the solve may take to come up before the corpse is given up on.
const START_TRIES: int = 3

## Gravity multiplier for every body. True gravity reads floaty on a body this
## size — the hand-authored collapse this replaces falls at 2.8 g for the same
## reason — but a real ragdoll needs less help than a canned pose did.
@export_range(0.25, 6.0, 0.05) var gravity_scale: float = 1.85
## Below this speed, in m/s, a body counts as still.
@export_range(0.0, 4.0, 0.01, "suffix:m/s") var settle_speed: float = 0.18
## Below this rate, in rad/s, a body counts as still.
@export_range(0.0, 12.0, 0.05, "suffix:rad/s") var settle_spin: float = 0.9
## How long every body must stay still before the corpse is declared down.
@export_range(0.05, 4.0, 0.05, "suffix:s") var settle_time: float = 0.5
## Seconds between stillness checks. Far cheaper than testing every physics tick
## and far finer than the time a corpse takes to stop.
@export_range(0.02, 1.0, 0.01, "suffix:s") var check_interval: float = 0.12
## Hard ceiling on the solve. A body wedged in geometry that never goes still is
## declared settled anyway rather than solving until the corpse despawns.
@export_range(0.5, 30.0, 0.5, "suffix:s") var max_solve_time: float = 6.0
## Ceiling on one killing impulse, in newton-seconds. A launcher should throw a
## body; it should not fire it out of the level.
@export_range(0.0, 8000.0, 10.0) var max_impulse: float = 1400.0
## Put every body to sleep the moment the corpse is declared down, instead of
## waiting for the engine's own sleep threshold to catch up. A sleeping body is
## skipped by the solver entirely, which is the whole point of measuring the
## settle: the corpse stays on screen and stops costing anything.
##
## Only applied when the corpse settled by going STILL. A corpse that hit
## `max_solve_time` while still moving is wedged in geometry, and freezing that one
## where it stands would leave a body hanging in mid-air.
@export var sleep_on_settle: bool = true

var _bones: Array[PhysicalBone3D] = []
var _started: bool = false
var _settled: bool = false
var _age: float = 0.0
var _still: float = 0.0
var _check: float = 0.0
var _pending_momentum: Vector3 = Vector3.ZERO
var _pending_point: Vector3 = Vector3.ZERO
var _pending_dir: Vector3 = Vector3.ZERO
var _pending_impulse: float = 0.0
var _tries: int = 0


func _ready() -> void:
	_bones.clear()
	_collect(self)
	for pb in _bones:
		pb.gravity_scale = gravity_scale
	set_physics_process(false)


## Begin the fall.
##
## `momentum` is the velocity the creature was carrying, given to every body so a
## sprinter's corpse keeps going. `dir`/`newtons` are the killing round: the
## impulse lands on the body nearest `point`, which is why a head shot spins the
## body and a hit in the hip drops it.
##
## The solve does not start on this call — it starts on the next physics tick.
## `PhysicalBoneSimulator3D` resolves its bone cache when it enters the tree, and
## starting inside the same frame the node was added races that. One physics frame
## is invisible on a corpse and it removes the whole class of bug.
func begin(momentum: Vector3, point: Vector3, dir: Vector3, newtons: float) -> void:
	if _started:
		return
	_started = true
	_settled = false
	_age = 0.0
	_still = 0.0
	_check = 0.0
	_pending_momentum = momentum
	_pending_point = point
	_pending_dir = dir
	_pending_impulse = clampf(newtons, 0.0, max_impulse)
	set_physics_process(true)


func is_settled() -> bool:
	return _settled


## Hand the skeleton back and stop solving.
##
## `EnemyBody` calls this before the corpse is freed. A simulator that is freed
## mid-simulation leaves the skeleton wearing the last solved GLOBAL pose — bone
## translations included — and the next creature out of the pool inherits a
## crumpled rig. Stopping the simulation first is what puts the bones back under
## the pose solver's control.
func stop() -> void:
	set_physics_process(false)
	if is_simulating_physics():
		physical_bones_stop_simulation()


## How many rigid bodies this corpse is solving. Read by the bake report and by
## anything counting the cost of a wave.
func body_count() -> int:
	return _bones.size()


func _physics_process(delta: float) -> void:
	if not is_simulating_physics():
		_tries += 1
		_launch()
		# Three physics ticks is generous for a cache that resolves on entry. A rig
		# that still refuses to simulate has no usable bodies; declare it down so
		# the corpse is recycled instead of retrying forever.
		if not is_simulating_physics() and _tries >= START_TRIES:
			_finish(false)
		return
	_age += delta
	_check -= delta
	if _check > 0.0:
		return
	var elapsed: float = maxf(check_interval, delta)
	_check = check_interval
	if _is_still():
		_still += elapsed
	else:
		_still = 0.0
	if _still < settle_time and _age < max_solve_time:
		return
	_finish(_still >= settle_time)


## Declare the corpse down. `by_stillness` is false when `max_solve_time` ran out
## on a body that never stopped moving.
func _finish(by_stillness: bool) -> void:
	_settled = true
	set_physics_process(false)
	if sleep_on_settle and by_stillness:
		for pb in _bones:
			pb.sleeping = true
	settled.emit()


## Hand the bodies over to physics and pay out the death impulse. Runs on the
## first physics tick after `begin()`.
func _launch() -> void:
	physical_bones_start_simulation()
	if not is_simulating_physics():
		return
	if _pending_momentum.length_squared() > 1e-6:
		for pb in _bones:
			pb.apply_central_impulse(_pending_momentum * pb.mass)
	if _pending_impulse <= 0.0 or _pending_dir.length_squared() < 1e-6:
		return
	var hit: PhysicalBone3D = _nearest(_pending_point)
	if hit == null:
		return
	hit.apply_impulse(
		_pending_dir.normalized() * _pending_impulse, _pending_point - hit.global_position
	)


func _is_still() -> bool:
	for pb in _bones:
		if pb.linear_velocity.length() > settle_speed:
			return false
		if pb.angular_velocity.length() > settle_spin:
			return false
	return true


func _nearest(point: Vector3) -> PhysicalBone3D:
	var best: PhysicalBone3D = null
	var best_d: float = INF
	for pb in _bones:
		var d: float = pb.global_position.distance_squared_to(point)
		if d < best_d:
			best_d = d
			best = pb
	return best


func _collect(node: Node) -> void:
	for c in node.get_children():
		var pb := c as PhysicalBone3D
		if pb != null:
			_bones.append(pb)
		_collect(c)
