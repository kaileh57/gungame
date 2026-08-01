class_name AIPatrol
extends RefCounted
## What a body does with itself when nobody is shooting at it.
##
## An unalerted agent that stands perfectly still facing one direction is the
## clearest tell in the game that there is no mind behind it. This is the machine
## that fixes that: five activities, a dwell timer whose length is drawn from the
## body's own patience and phase, and a generated patrol beat around whatever spot
## the body was posted at.
##
## The gaze is the part that is not cosmetic. `look_direction` is fed straight
## into the sight cone, so a guard on SCAN genuinely sweeps its field and can pick
## up something approaching from a bearing it was not originally facing, while one
## on CONVERSE is looking at the man it is talking to and is correspondingly easy
## to walk behind. Idle behaviour that does not change what the body can perceive
## is theatre; this changes it.
##
## COST AND LOD. This is driven from `AIPerception.look`, which the scheduler only
## calls on a FULL tick — so idle life runs on near, visible bodies and stops
## entirely on the far-LOD ones. That is deliberate and it is the reason it is
## affordable: a body across the valley has no business spending anything on
## deciding whether to lean on a wall. A far body simply holds its last posture.
##
## Conversation pairing goes through a static registry of currently-idle bodies,
## refreshed by the bodies themselves as they tick. It is a dictionary of packed
## `Vector4` — xyz position, w timestamp — so pairing allocates nothing and stale
## entries fall out on age rather than needing anyone to unregister.

enum Activity { POST, SCAN, WALK, CONVERSE, REST }

const ACTIVITY_NAMES: PackedStringArray = ["POST", "SCAN", "WALK", "CONVERSE", "REST"]
## Points in a generated patrol beat. Four reads as a round without the body
## spending its life walking.
const BEAT_POINTS: int = 4
## Milliseconds an entry in the idle registry stays valid. Longer than the slowest
## full tick by a wide margin, short enough that a body that started fighting
## stops being a conversation partner within a second.
const REGISTRY_TTL: float = 1200.0
## Most registry rows one partner search will look at. A crowded plaza must not
## turn a conversation into a linear scan of the whole population.
const PARTNER_SCAN_LIMIT: int = 24
## Seconds between registry publishes. Comfortably inside `REGISTRY_TTL`.
const PUBLISH_INTERVAL: float = 0.45

static var _idle: Dictionary = {}

## Metres the generated beat is thrown around the post. Zero pins the body to its
## mark and it will only ever stand, scan and lean.
var beat_radius: float = 4.5
## Seconds the body holds one activity before choosing another, before patience
## and phase are applied.
var dwell: float = 4.0
## Full sweep of a deliberate scan, radians.
var scan_arc: float = 1.55
## Radians of aimless drift while merely standing the post.
var idle_arc: float = 0.42
## Metres within which another idle body is worth talking to.
var converse_radius: float = 4.0
## Chance, per activity choice, that a body with a partner available takes it.
var converse_chance: float = 0.3
## Multiplier on walk speed while patrolling. A patrol is not a march.
var pace: float = 0.72

var activity_id: int = Activity.POST
var time_in_activity: float = 0.0
## Where this body belongs when it has nothing else to do.
var post: Vector3 = Vector3.ZERO
var post_facing: Vector3 = Vector3.FORWARD
var has_post: bool = false

var _key: int = 0
var _phase: float = 0.0
var _tempo: float = 1.0
var _patience: float = 1.0
var _curiosity: float = 0.5
var _chatter: float = 0.5
var _hold: float = 4.0
var _beat: PackedVector3Array = PackedVector3Array()
var _leg: int = 0
var _here: Vector3 = Vector3.ZERO
var _partner: Vector3 = Vector3.ZERO
var _has_partner: bool = false
var _clock: float = 0.0
var _publish_wait: float = 0.0
var _choices: int = 0


func _init(key: int = 0) -> void:
	_key = key


## Take the species' idle numbers and the body's own temperament. Called once per
## bind; safe to repeat on a pooled body.
func configure(profile: AISpeciesProfile, personality: AIPersonality) -> void:
	if profile != null:
		beat_radius = profile.patrol_radius
		dwell = profile.post_dwell
		scan_arc = deg_to_rad(profile.idle_scan_arc_degrees)
		converse_radius = profile.converse_radius
		converse_chance = profile.converse_chance
		pace = profile.patrol_speed_scale
	if personality != null:
		_phase = personality.phase
		_tempo = personality.tempo
		_patience = personality.patience
		_curiosity = personality.curiosity
		_chatter = personality.chatter
	idle_arc = scan_arc * 0.28
	reset()


## Forget the beat and stand down to POST. The body keeps its post.
func reset() -> void:
	activity_id = Activity.POST
	time_in_activity = 0.0
	_hold = _next_hold()
	_leg = 0
	_has_partner = false
	_clock = _phase


## Post this body at `p`, looking along `facing`, and lay a patrol beat around it.
## A body that is never posted adopts wherever it first ticked, which is what lets
## a scene that places bodies and forgets about them still look inhabited.
func set_post(p: Vector3, facing: Vector3) -> void:
	post = p
	has_post = true
	var flat := Vector3(facing.x, 0.0, facing.z)
	post_facing = flat.normalized() if flat.length_squared() > 1e-6 else Vector3.FORWARD
	_lay_beat()


## One idle step. `calm` is false the moment the body has anything to be alert
## about, and puts the machine back to POST without touching the post itself.
## Returns the current `Activity`.
func tick(delta: float, here: Vector3, calm: bool) -> int:
	_here = here
	if not has_post:
		set_post(here, post_facing)
	if not calm:
		if activity_id != Activity.POST:
			activity_id = Activity.POST
			time_in_activity = 0.0
			_has_partner = false
		return activity_id
	_clock += delta * _tempo
	time_in_activity += delta
	# Publishing is a dictionary write and it is the only per-tick allocation in
	# the module, so it runs on its own slow clock rather than every tick. A
	# conversation partner half a second out of date is still standing there.
	_publish_wait -= delta
	if _publish_wait <= 0.0:
		_publish_wait = PUBLISH_INTERVAL
		_publish(here)
	if time_in_activity >= _hold:
		_choose(here)
	if activity_id == Activity.CONVERSE and not _has_partner:
		_enter(Activity.SCAN)
	return activity_id


func activity() -> int:
	return activity_id


func activity_name() -> String:
	return ACTIVITY_NAMES[activity_id]


## Whether the feet have somewhere to be. Only WALK ever says yes.
func has_goal() -> bool:
	return activity_id == Activity.WALK and not _beat.is_empty()


## The waypoint the body is walking to. Meaningless unless `has_goal`.
func goal() -> Vector3:
	if _beat.is_empty():
		return post
	return _beat[_leg % _beat.size()]


## The generated beat, for the overlay. Empty until the body has a post.
func route() -> PackedVector3Array:
	return _beat


## Yaw offset from the body's own facing, radians. This is where standing still
## stops looking like being switched off.
func gaze_yaw() -> float:
	match activity_id:
		Activity.SCAN:
			# A deliberate sweep: linear out, linear back, with a pause at each end
			# that a raw sine does not give you. Triangle, not sinusoid.
			var t: float = fmod(_clock * 0.42, 2.0)
			var tri: float = t if t < 1.0 else 2.0 - t
			return (tri - 0.5) * scan_arc
		Activity.WALK:
			return sin(_clock * 0.7) * idle_arc * 0.8
		Activity.REST:
			return sin(_clock * 0.21) * idle_arc * 0.5
		Activity.CONVERSE:
			return sin(_clock * 1.4) * 0.05
	return sin(_clock * 0.33) * idle_arc


## The direction this body is actually looking, given where its shoulders point.
## Conversation wins over the sweep: you look at the person you are talking to.
func look_direction(forward: Vector3) -> Vector3:
	var base := Vector3(forward.x, 0.0, forward.z)
	if base.length_squared() < 1e-6:
		base = post_facing
	if activity_id == Activity.CONVERSE and _has_partner:
		var to: Vector3 = _partner - _here
		to.y = 0.0
		if to.length_squared() > 1e-4:
			return to.normalized().rotated(Vector3.UP, gaze_yaw())
	return base.normalized().rotated(Vector3.UP, gaze_yaw())


## Where the body it is talking to is standing. Zero when it is alone.
func partner_position() -> Vector3:
	return _partner if _has_partner else Vector3.ZERO


## Multiplier on walk speed for whatever the feet are doing. Only WALK moves.
func speed_scale() -> float:
	return pace if activity_id == Activity.WALK else 0.0


## Drop the idle registry. Scene teardown, alongside `AIPersonality.clear`.
static func clear() -> void:
	_idle.clear()


## Pick the next thing to do. Weighted by temperament rather than uniform: a
## curious body walks its beat, a chatty one finds someone to stand with, a
## patient one is content to hold its mark and watch.
func _choose(here: Vector3) -> void:
	# Every draw advances the counter. Keying the roll on the leg alone looks fine
	# until a body draws a POST and then draws the same POST for ever, because
	# nothing in its inputs changed between the two decisions — it stands on its
	# mark for the life of the scene and reads as switched off.
	_choices += 1
	var roll: float = _hash01(_leg * 31 + _choices * 5 + activity_id * 7)
	var want_talk: float = _chatter * converse_chance
	if activity_id != Activity.CONVERSE and roll < want_talk and _seek_partner(here):
		_enter(Activity.CONVERSE)
		return
	_has_partner = false
	var walk_bias: float = 0.22 + 0.34 * _curiosity
	if beat_radius <= 0.05:
		walk_bias = 0.0
	var r: float = _hash01(_leg * 17 + _choices * 11 + 3)
	if activity_id == Activity.WALK:
		# Having just walked somewhere, look at what is there before walking on.
		_enter(Activity.SCAN)
		return
	if r < walk_bias:
		_leg += 1
		_enter(Activity.WALK)
		return
	if r < walk_bias + 0.42:
		_enter(Activity.SCAN)
		return
	if r < walk_bias + 0.62 and _patience > 0.95:
		_enter(Activity.REST)
		return
	_enter(Activity.POST)


func _enter(which: int) -> void:
	activity_id = which
	time_in_activity = 0.0
	_hold = _next_hold()


## Dwell for the activity just entered. Scaled by patience, jittered by the body's
## own phase so a line of guards never changes posture on the same frame.
func _next_hold() -> float:
	var base: float = dwell * _patience
	match activity_id:
		Activity.SCAN:
			base *= 0.75
		Activity.WALK:
			base *= 1.4
		Activity.CONVERSE:
			base *= 1.8
		Activity.REST:
			base *= 1.6
	return maxf(base * (0.7 + 0.6 * _hash01(_leg * 13 + _choices * 7 + 11)), 0.6)


## Lay a beat around the post: a ring of points rotated by the body's own phase,
## so two bodies posted at the same place walk different ground.
func _lay_beat() -> void:
	_beat.clear()
	if beat_radius <= 0.05:
		return
	_beat.resize(BEAT_POINTS)
	for i: int in BEAT_POINTS:
		var a: float = _phase + TAU * float(i) / float(BEAT_POINTS)
		var r: float = beat_radius * (0.55 + 0.45 * _hash01(i * 5 + 1))
		_beat[i] = post + Vector3(cos(a) * r, 0.0, sin(a) * r)


## Publish this body's position as available to talk to. Only idle bodies are in
## the registry, so a partner search never finds somebody who is fighting.
func _publish(here: Vector3) -> void:
	if activity_id == Activity.WALK:
		_idle.erase(_key)
		return
	_idle[_key] = Vector4(here.x, here.y, here.z, float(Time.get_ticks_msec()))


## Nearest idle body inside `converse_radius` that is not this one. Bounded scan.
func _seek_partner(here: Vector3) -> bool:
	_has_partner = false
	if converse_radius <= 0.1:
		return false
	var now: float = float(Time.get_ticks_msec())
	var r2: float = converse_radius * converse_radius
	var best: float = r2
	var looked: int = 0
	for id: int in _idle:
		if looked >= PARTNER_SCAN_LIMIT:
			break
		looked += 1
		if id == _key:
			continue
		var row: Vector4 = _idle[id]
		if now - row.w > REGISTRY_TTL:
			continue
		var p := Vector3(row.x, row.y, row.z)
		var d2: float = p.distance_squared_to(here)
		if d2 < best:
			best = d2
			_partner = p
			_has_partner = true
	return _has_partner


## A stable pseudo-random in [0, 1) from this body's key and a step index. Cheaper
## than carrying an RNG and, unlike one, cannot drift out of sync with a reload.
func _hash01(step: int) -> float:
	var h: int = (_key * 2654435761 + step * 2246822519) & 0x7FFFFFFF
	h = (h ^ (h >> 13)) * 1274126177 & 0x7FFFFFFF
	return float(h & 0xFFFFFF) / 16777216.0
