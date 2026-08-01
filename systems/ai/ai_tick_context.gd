class_name AITickContext
extends RefCounted
## Everything an agent is allowed to touch outside itself, handed down once per
## tick by the director.
##
## This exists to keep the dependency graph one-way. An agent that held a
## reference to the director would make the two types mutually recursive, and it
## would also make every service the director owns reachable from inside a
## behaviour, which is how AI code turns into a ball of string. Instead the
## director fills one of these — the same instance every frame, never reallocated
## — and drains whatever the agents wrote back into it.
##
## The budgets are the point. `rays` and `paths` are pools for the whole frame,
## not per agent: the first agents to tick spend from them and the rest degrade
## gracefully, which is exactly the behaviour you want when a hundred bodies wake
## up in the same second.

## A sound with a position and a falloff. Grants awareness and a place to look.
const EVENT_NOISE: int = 0
## A round cracking past. Grants suppression, not awareness — being shot at from
## somewhere you cannot see does not tell you where the shooter is.
const EVENT_CRACK: int = 1
## Two events of the same kind closer together than this merge into the loudest.
## A machine gun would otherwise queue ten identical reports a second.
const MERGE_DISTANCE: float = 1.6
## Ceiling on queued events. A full queue keeps the loudest; a quiet report that
## arrives late is exactly the one nobody would have reacted to.
const MAX_EVENTS: int = 48

## Seconds since this agent last ticked. Not the frame delta.
var delta: float = 0.0
## Seconds since the director started. A shared clock, so agents can compare ages.
var now: float = 0.0
var targets: AITargetIndex = null
var space: PhysicsDirectSpaceState3D = null
## The ticking agent's own faction blackboard. Swapped in per agent.
var blackboard: AIBlackboard = null
var cover: AICoverMap = null
## Raycasts left in this frame's pool.
var rays: int = 0
## Path requests left in this frame's pool.
var paths: int = 0

var _noise_pos: PackedVector3Array = PackedVector3Array()
var _noise_radius: PackedFloat32Array = PackedFloat32Array()
var _noise_loud: PackedFloat32Array = PackedFloat32Array()
var _noise_faction: PackedInt32Array = PackedInt32Array()
var _noise_source: PackedInt32Array = PackedInt32Array()
var _noise_kind: PackedInt32Array = PackedInt32Array()


## Refill the frame pools. Called by the director at the top of each frame.
func begin_frame(ray_pool: int, path_pool: int, clock: float) -> void:
	rays = ray_pool
	paths = path_pool
	now = clock


## Claim up to `wanted` raycasts. Returns how many were actually granted, which
## may be zero; a caller that gets less than it asked for must do less work, not
## do the work anyway.
func take_rays(wanted: int) -> int:
	var granted: int = mini(wanted, rays)
	rays -= granted
	return granted


## Give back rays that were budgeted but not spent, so a cheap agent does not
## starve the next one.
func refund_rays(unused: int) -> void:
	rays += maxi(unused, 0)


func take_path() -> bool:
	if paths <= 0:
		return false
	paths -= 1
	return true


## Announce a noise. Queued rather than dispatched, because dispatch has to walk
## every agent and doing that from inside an agent's own tick would re-enter the
## scheduler. The director drains this at the end of the frame.
##
## Reports of the same kind from the same faction within `MERGE_DISTANCE` fold
## into one, taking the louder of the two and its position: a burst of automatic
## fire is one event at the muzzle, not eleven. The scan is linear over the queue,
## which is bounded by `MAX_EVENTS` and in practice sits in single digits.
func queue_noise(
	p: Vector3,
	radius: float,
	loudness: float,
	faction: int,
	source_id: int,
	kind: int = EVENT_NOISE
) -> void:
	var merge_sq: float = MERGE_DISTANCE * MERGE_DISTANCE
	var quietest: int = -1
	var quietest_loud: float = INF
	for i: int in _noise_pos.size():
		if _noise_kind[i] == kind and _noise_faction[i] == faction:
			if _noise_pos[i].distance_squared_to(p) <= merge_sq:
				if loudness > _noise_loud[i]:
					_noise_pos[i] = p
					_noise_loud[i] = loudness
					_noise_source[i] = source_id
				_noise_radius[i] = maxf(_noise_radius[i], radius)
				return
		if _noise_loud[i] < quietest_loud:
			quietest_loud = _noise_loud[i]
			quietest = i
	if _noise_pos.size() >= MAX_EVENTS:
		if quietest < 0 or loudness <= quietest_loud:
			return
		_noise_pos[quietest] = p
		_noise_radius[quietest] = radius
		_noise_loud[quietest] = loudness
		_noise_faction[quietest] = faction
		_noise_source[quietest] = source_id
		_noise_kind[quietest] = kind
		return
	_noise_pos.append(p)
	_noise_radius.append(radius)
	_noise_loud.append(loudness)
	_noise_faction.append(faction)
	_noise_source.append(source_id)
	_noise_kind.append(kind)


## Announce a round cracking past a point. Suppression without awareness — being
## shot at from somewhere you cannot see tells you nothing about where from.
func queue_crack(p: Vector3, radius: float, loudness: float, faction: int, source_id: int) -> void:
	queue_noise(p, radius, loudness, faction, source_id, EVENT_CRACK)


func noise_count() -> int:
	return _noise_pos.size()


func noise_position(i: int) -> Vector3:
	return _noise_pos[i]


func noise_radius(i: int) -> float:
	return _noise_radius[i]


func noise_loudness(i: int) -> float:
	return _noise_loud[i]


func noise_faction(i: int) -> int:
	return _noise_faction[i]


func noise_source(i: int) -> int:
	return _noise_source[i]


## EVENT_NOISE or EVENT_CRACK. Determines whether the event grants a place to
## look or only a reason to flinch.
func noise_kind(i: int) -> int:
	return _noise_kind[i]


func clear_noise() -> void:
	_noise_pos.clear()
	_noise_radius.clear()
	_noise_loud.clear()
	_noise_faction.clear()
	_noise_source.clear()
	_noise_kind.clear()
