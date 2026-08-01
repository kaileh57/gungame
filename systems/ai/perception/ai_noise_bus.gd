class_name AINoiseBus
extends RefCounted
## The global ear. Anything in the world that makes a sound worth reacting to
## files it here; every listening agent drains it on its own tick.
##
## A ring of fixed size with a monotonic sequence number, not a signal. Signals
## would fan a gunshot out to a hundred connected agents synchronously, inside the
## caller's frame, from inside whatever was firing — and an agent that is asleep
## on a far-LOD tick would miss the event entirely rather than picking it up two
## ticks later. A cursor into a ring costs one integer per agent, dispatches
## nothing, and lets a slow agent catch up on everything it slept through. When an
## agent falls further behind than the ring is deep it loses the oldest events,
## which is the correct failure: a fight that loud has already told it everything.
##
## State is static and survives a scene change, so `reset` is not optional —
## SceneRouter's demo swap must call it or the new scene starts with the old
## scene's gunfire still ringing.

## A sound with a position and a falloff. Grants awareness and a place to look.
const KIND_NOISE: int = 0
## A round cracking past. Grants suppression, not awareness — being shot at from
## somewhere you cannot see tells you nothing about where the shooter is.
const KIND_CRACK: int = 1
## Events retained. At the loudest this game gets — a dozen bodies in a firefight,
## six reports a second each — this is about a second and a half of history, which
## is longer than the slowest agent's tick interval by a wide margin.
const CAPACITY: int = 256
## Smallest report radius, metres. Below this a sound is not worth filing.
const MIN_RADIUS: float = 2.0

## Muzzle energy, joules, at which `reference_radius` and `reference_loudness`
## hold. Overwritten by `AIPerceptionTuning.apply_to_bus`.
static var reference_energy: float = 1500.0
static var reference_radius: float = 60.0
static var radius_max: float = 240.0
static var reference_loudness: float = 1.0
static var loudness_per_decade: float = 0.42
static var suppressed_scale: float = 0.34
static var merge_distance: float = 1.6
static var merge_window_ms: float = 120.0

static var _pos: PackedVector3Array = PackedVector3Array()
static var _radius: PackedFloat32Array = PackedFloat32Array()
static var _loud: PackedFloat32Array = PackedFloat32Array()
static var _faction: PackedInt32Array = PackedInt32Array()
static var _source: PackedInt32Array = PackedInt32Array()
static var _kind: PackedInt32Array = PackedInt32Array()
static var _stamp: PackedFloat64Array = PackedFloat64Array()
static var _seq: int = 0


## Drop every pending event and rewind the sequence. Call on scene teardown.
static func reset() -> void:
	_ensure()
	_seq = 0
	for i: int in CAPACITY:
		_kind[i] = -1
		_stamp[i] = -1.0e12


## Sequence number the next event will be written at. An agent stores this once
## and passes it back to `drain` forever after.
static func cursor() -> int:
	return _seq


## Oldest sequence still in the ring. A cursor below this has lost events.
static func oldest() -> int:
	return maxi(_seq - CAPACITY, 0)


## File a sound. Returns the sequence number it landed at, which is the sequence
## of an existing event when this one merged into it.
static func emit_noise(
	p: Vector3, radius: float, loudness: float, faction: int, source_id: int, kind: int = KIND_NOISE
) -> int:
	_ensure()
	if radius < MIN_RADIUS or loudness <= 0.0:
		return _seq
	var now: float = float(Time.get_ticks_msec())
	var merged: int = _find_merge(p, kind, now)
	if merged >= 0:
		var m: int = merged % CAPACITY
		_radius[m] = maxf(_radius[m], radius)
		_loud[m] = maxf(_loud[m], loudness)
		_stamp[m] = now
		return merged
	var i: int = _seq % CAPACITY
	_pos[i] = p
	_radius[i] = radius
	_loud[i] = loudness
	_faction[i] = faction
	_source[i] = source_id
	_kind[i] = kind
	_stamp[i] = now
	_seq += 1
	return _seq - 1


## File a weapon report from its muzzle energy in joules. Returns the sequence it
## landed at. `suppressed` folds in a can, a subsonic load, or a bow.
static func emit_gunshot(
	p: Vector3, muzzle_energy: float, faction: int, source_id: int, suppressed: bool = false
) -> int:
	var k: float = suppressed_scale if suppressed else 1.0
	return emit_noise(
		p,
		radius_for_energy(muzzle_energy) * k,
		loudness_for_energy(muzzle_energy) * k,
		faction,
		source_id,
		KIND_NOISE
	)


## Metres at which a shot of this energy stops being audible. Sound intensity
## falls off with the square of distance, so the radius at a fixed hearing
## threshold goes with the square root of the energy behind it.
static func radius_for_energy(joules: float) -> float:
	var ratio: float = maxf(joules, 1.0) / maxf(reference_energy, 1.0)
	return clampf(reference_radius * sqrt(ratio), MIN_RADIUS, radius_max)


## Strength at the source. Logarithmic, because ears are: without it a magnum is
## twenty times more alarming than a pistol instead of half again.
static func loudness_for_energy(joules: float) -> float:
	var ratio: float = maxf(joules, 1.0) / maxf(reference_energy, 1.0)
	var decades: float = log(ratio) * 0.4342944819
	return clampf(reference_loudness + loudness_per_decade * decades, 0.15, 3.0)


## Whether `seq` is still readable. False once the ring has wrapped past it.
static func has(seq: int) -> bool:
	return seq >= oldest() and seq < _seq and _kind[seq % CAPACITY] >= 0


static func event_position(seq: int) -> Vector3:
	return _pos[seq % CAPACITY]


static func event_radius(seq: int) -> float:
	return _radius[seq % CAPACITY]


static func event_loudness(seq: int) -> float:
	return _loud[seq % CAPACITY]


static func event_faction(seq: int) -> int:
	return _faction[seq % CAPACITY]


static func event_source(seq: int) -> int:
	return _source[seq % CAPACITY]


static func event_kind(seq: int) -> int:
	return _kind[seq % CAPACITY]


## Milliseconds since boot that the event was filed at.
static func event_time(seq: int) -> float:
	return _stamp[seq % CAPACITY]


## Most recent event of the same kind within the merge window and distance, or
## -1. Only the tail is scanned: anything older than the window cannot merge, and
## the window is short enough that the tail is a handful of entries.
static func _find_merge(p: Vector3, kind: int, now: float) -> int:
	var d2: float = merge_distance * merge_distance
	var stop: int = maxi(_seq - 16, 0)
	var s: int = _seq - 1
	while s >= stop:
		var i: int = s % CAPACITY
		if now - _stamp[i] > merge_window_ms:
			return -1
		if _kind[i] == kind and _pos[i].distance_squared_to(p) <= d2:
			return s
		s -= 1
	return -1


static func _ensure() -> void:
	if _pos.size() == CAPACITY:
		return
	_pos.resize(CAPACITY)
	_radius.resize(CAPACITY)
	_loud.resize(CAPACITY)
	_faction.resize(CAPACITY)
	_source.resize(CAPACITY)
	_kind.resize(CAPACITY)
	_stamp.resize(CAPACITY)
	for i: int in CAPACITY:
		_kind[i] = -1
		_stamp[i] = -1.0e12
