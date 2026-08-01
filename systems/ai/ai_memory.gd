class_name AIMemory
extends RefCounted
## One agent's recollection of who it has seen, where, and how long ago.
##
## Fixed capacity, allocated once. A Dictionary keyed by target id would be the
## obvious structure and is the wrong one: it grows without bound across a long
## fight, rehashes on every new contact, and gives an agent a perfect roll of
## everyone who has ever shot at it. Eight slots with weakest-first eviction is
## both cheaper and a better model of an animal.
##
## Two numbers per contact and they are not the same thing. `awareness` is how
## convinced the agent is that something is there right now — it drives the alert
## state machine. `confidence` is how much it trusts the remembered position — it
## decays faster, and it is what turns a chase into a search.

## The golden angle. Consecutive search points land this far apart around the
## last known position, which is the arrangement that never doubles back on a
## patch it has already swept no matter how many points the agent gets through.
const GOLDEN_ANGLE: float = 2.39996323

var capacity: int = 8
## Ceiling on stored awareness. Above 1.0 so a target that steps behind a crate
## has a little in the bank and does not instantly stop being a target.
var awareness_ceiling: float = 1.35
## Awareness below which a contact is dropped entirely.
var forget_threshold: float = 0.02
## Confidence lost per second when `fade` is not given an explicit rate.
var confidence_decay: float = 0.55
## Seconds of dead reckoning a remembered velocity is worth.
var extrapolate_seconds: float = 2.0
## Ceiling on the confidence a second-hand contact can reach. Below the engage
## threshold, so hearsay never produces something an agent will shoot at.
var report_confidence_cap: float = 0.85
## Metres from the last known position the first search point sits at, how much
## further out each subsequent one is thrown, and where the spiral stops growing.
var search_ring_start: float = 3.0
var search_ring_growth: float = 3.4
var search_radius_max: float = 24.0
## Awareness multiplier applied while a contact is still inside the observer's
## reaction window — the double take. Written by whoever is observing, because it
## is a property of the observer's species, not of the memory.
var reaction_choke: float = 0.22
## Seconds a contact may be out of sight before it has to be noticed from scratch.
var reacquire_grace: float = 0.9

var _id: PackedInt32Array = PackedInt32Array()
var _pos: PackedVector3Array = PackedVector3Array()
var _vel: PackedVector3Array = PackedVector3Array()
var _awareness: PackedFloat32Array = PackedFloat32Array()
var _confidence: PackedFloat32Array = PackedFloat32Array()
var _seen_at: PackedFloat32Array = PackedFloat32Array()
var _visible: PackedInt32Array = PackedInt32Array()
var _threat: PackedFloat32Array = PackedFloat32Array()
var _exposure: PackedFloat32Array = PackedFloat32Array()
var _used: int = 0
var _now: float = 0.0


func _init(slots: int = 8) -> void:
	capacity = maxi(slots, 2)
	_id.resize(capacity)
	_pos.resize(capacity)
	_vel.resize(capacity)
	_awareness.resize(capacity)
	_confidence.resize(capacity)
	_seen_at.resize(capacity)
	_visible.resize(capacity)
	_threat.resize(capacity)
	_exposure.resize(capacity)
	clear()


## Copy the global feel settings in. Capacity is fixed at construction, so a
## tuning pass that widens `memory_slots` takes effect on the next spawn.
func apply_tuning(t: AIPerceptionTuning) -> void:
	awareness_ceiling = t.awareness_ceiling
	forget_threshold = t.forget_threshold
	confidence_decay = t.confidence_decay
	extrapolate_seconds = t.extrapolate_seconds
	report_confidence_cap = t.heard_confidence_cap
	search_ring_start = t.search_ring_start
	search_ring_growth = t.search_ring_growth
	search_radius_max = t.search_radius_max


func clear() -> void:
	_used = 0
	for i: int in capacity:
		_id[i] = -1
		_awareness[i] = 0.0
		_confidence[i] = 0.0
		_visible[i] = 0
		_threat[i] = 1.0
		_exposure[i] = 0.0


func count() -> int:
	return _used


## Direct sighting. `gain` is already scaled by distance, exposure and the
## observer's own alertness; this only integrates it.
##
## `latency` is the observer's reaction time for this contact. Until the contact
## has been continuously in view for that long the gain is choked rather than
## blocked — the body notices something is there and takes a moment to decide it
## is a problem, which is a double take and not a blindfold. Zero, the default,
## is the old instant behaviour and is what a harness wants.
##
## The elapsed time comes from the memory's own clock rather than an argument:
## the gap since this slot was last written IS the observer's tick interval, and
## a gap longer than `reacquire_grace` means the contact went away and has to be
## noticed again.
func observe(
	id: int, p: Vector3, v: Vector3, gain: float, threat: float, latency: float = 0.0
) -> int:
	var i: int = _slot(id)
	var gap: float = _now - _seen_at[i]
	if gap > reacquire_grace or _confidence[i] <= 0.0:
		_exposure[i] = 0.0
	else:
		_exposure[i] += gap
	_pos[i] = p
	_vel[i] = v
	_threat[i] = threat
	_visible[i] = 1
	_seen_at[i] = _now
	var k: float = 1.0
	if latency > 0.0 and _exposure[i] < latency:
		k = clampf(reaction_choke, 0.0, 1.0)
	_awareness[i] = minf(_awareness[i] + gain * k, awareness_ceiling)
	_confidence[i] = 1.0
	return i


## Second-hand contact: a noise, a squadmate's callout, a body found. `weight` is
## how much awareness it is worth and doubles as the confidence ceiling, so a
## distant gunshot never produces a target you can shoot at.
func report(id: int, p: Vector3, weight: float, threat: float) -> int:
	var i: int = _slot(id)
	if _visible[i] == 0:
		_pos[i] = p
		_confidence[i] = maxf(_confidence[i], clampf(weight, 0.0, report_confidence_cap))
	_threat[i] = maxf(_threat[i], threat)
	_awareness[i] = minf(_awareness[i] + weight, awareness_ceiling)
	return i


## Advance the clock and bleed everything that was not seen this tick. Call once
## per agent tick, after perception has written its observations. A negative
## `conf_rate` uses the tuned `confidence_decay`.
func fade(delta: float, awareness_decay: float, conf_rate: float = -1.0) -> void:
	_now += delta
	var conf: float = confidence_decay if conf_rate < 0.0 else conf_rate
	var i: int = 0
	while i < _used:
		if _visible[i] == 0:
			_awareness[i] = maxf(_awareness[i] - awareness_decay * delta, 0.0)
			_confidence[i] = maxf(_confidence[i] - conf * delta, 0.0)
			if _awareness[i] <= forget_threshold:
				_evict(i)
				continue
		_visible[i] = 0
		i += 1


func awareness_of(id: int) -> float:
	var i: int = _find(id)
	return 0.0 if i < 0 else _awareness[i]


## Slot of the contact worth reacting to, or -1. Ranks on awareness first because
## a thing you can see beats a thing you remember, then on remembered confidence
## and the contact's own threat weight.
func best_slot() -> int:
	var best: int = -1
	var best_score: float = 0.0
	for i: int in _used:
		var s: float = _awareness[i] * (0.45 + 0.55 * _confidence[i]) * _threat[i]
		if s > best_score:
			best_score = s
			best = i
	return best


func slot_of(id: int) -> int:
	return _find(id)


func slot_id(i: int) -> int:
	return _id[i]


func slot_position(i: int) -> Vector3:
	return _pos[i]


func slot_velocity(i: int) -> Vector3:
	return _vel[i]


func slot_awareness(i: int) -> float:
	return _awareness[i]


func slot_confidence(i: int) -> float:
	return _confidence[i]


func slot_visible(i: int) -> bool:
	return _visible[i] != 0


## Seconds since this contact was last actually seen.
func slot_age(i: int) -> float:
	return _now - _seen_at[i]


## Seconds of unbroken exposure this contact has had. Below the observer's own
## reaction time the body has noticed something but has not yet acted on it, which
## is the state the overlay draws as a question mark rather than a target box.
func slot_exposure(i: int) -> float:
	return _exposure[i]


## Where the contact probably is now: the last known position pushed along its
## last known velocity, for as long as that guess is worth anything. Extrapolating
## past a couple of seconds produces confident nonsense, so it stops there.
func predicted_position(i: int) -> Vector3:
	var age: float = minf(_now - _seen_at[i], extrapolate_seconds)
	return _pos[i] + _vel[i] * age * _confidence[i]


## The `step`-th place worth looking for contact `i`.
##
## Step zero is not part of the spiral. It is a single point thrown along the
## direction the contact was last travelling, because the first thing anybody does
## when something disappears is look where it was going. Walking a spiral from
## step zero instead makes an agent check its own left shoulder while the target
## sprints out of the far side of the ring, and that reads as an idiot.
##
## After that it is a golden-angle spiral about the dead-reckoned position,
## expanding with the square root of the step so the area swept grows at a
## constant rate rather than accelerating away from the agent. The spiral is
## ANCHORED to the escape heading, so the ground downrange gets checked before
## the ground behind. `phase` rotates the whole thing and should be constant per
## agent — two bodies searching the same last known position then sweep different
## ground without either of them having to know the other exists.
##
## `reach` is the searcher's own appetite, from `AIPersonality.search_reach`. A
## curious body clears the room; a cautious one checks the doorway. Whatever it
## does, the point stays inside `search_radius_max` of the last known position:
## past that it is not searching, it is wandering off.
##
## Y is taken from the last known position: this is a ground search, and lifting
## a point to the spiral's own height would send the navigator into a wall.
func search_point(i: int, step: int, phase: float, reach: float = 1.0) -> Vector3:
	var k: int = maxi(step, 0)
	var lead: Vector3 = _vel[i]
	lead.y = 0.0
	var heading: float = phase
	if lead.length_squared() > 0.04:
		heading = atan2(lead.z, lead.x)
	var span: float = clampf(reach, 0.3, 2.0)
	var center: Vector3 = predicted_position(i)
	var r: float = search_ring_start * span
	var a: float = heading
	if k > 0:
		# Step zero is common ground — everybody checks where it went. From step one
		# the spiral is rotated by the searcher's OWN phase, not a fraction of it,
		# and that is what splits a squad's search. Measured with the phase weighted
		# at 0.15: four bodies searching one position produced points 1 m apart at
		# every step and swept the same ground four times over.
		r = search_ring_start + search_ring_growth * sqrt(float(k)) * span
		a = heading + phase + GOLDEN_ANGLE * float(k)
	var p := Vector3(center.x + cos(a) * r, _pos[i].y, center.z + sin(a) * r)
	# Clamp against the LAST KNOWN position, not the dead-reckoned one: the cap is
	# how far from the evidence the agent is allowed to get, and extrapolation is
	# not evidence.
	var off: Vector3 = p - _pos[i]
	off.y = 0.0
	var d: float = off.length()
	if d > search_radius_max and d > 1e-4:
		p = _pos[i] + off / d * search_radius_max
	return p


func forget(id: int) -> void:
	var i: int = _find(id)
	if i >= 0:
		_evict(i)


func _find(id: int) -> int:
	for i: int in _used:
		if _id[i] == id:
			return i
	return -1


## Slot for `id`, creating one if there is room and evicting the weakest contact
## if there is not. A fresh slot starts at zero and has to earn its awareness.
func _slot(id: int) -> int:
	var i: int = _find(id)
	if i >= 0:
		return i
	if _used < capacity:
		i = _used
		_used += 1
	else:
		i = 0
		var worst: float = INF
		for k: int in _used:
			var s: float = _awareness[k] * _threat[k]
			if s < worst:
				worst = s
				i = k
	_id[i] = id
	_pos[i] = Vector3.ZERO
	_vel[i] = Vector3.ZERO
	_awareness[i] = 0.0
	_confidence[i] = 0.0
	_seen_at[i] = _now
	_visible[i] = 0
	_threat[i] = 1.0
	_exposure[i] = 0.0
	return i


func _evict(i: int) -> void:
	var last: int = _used - 1
	if i != last:
		_id[i] = _id[last]
		_pos[i] = _pos[last]
		_vel[i] = _vel[last]
		_awareness[i] = _awareness[last]
		_confidence[i] = _confidence[last]
		_seen_at[i] = _seen_at[last]
		_visible[i] = _visible[last]
		_threat[i] = _threat[last]
		_exposure[i] = _exposure[last]
	_id[last] = -1
	_used = last
