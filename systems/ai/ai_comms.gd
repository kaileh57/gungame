class_name AIComms
extends RefCounted
## The net. What one faction says out loud, how long it takes to arrive, and how
## wrong it is by the time it does.
##
## Before this existed a body that saw something wrote it straight onto the
## faction blackboard, and every squad in the faction knew, that instant, to the
## centimetre. That is the single largest reason AI reads as inhuman: not that it
## reacts too fast, but that it reacts too WIDELY. Nobody shouts and nobody
## mishears.
##
## So knowledge now travels as speech. `speak` queues an utterance; `advance`
## delivers it. Two things happen to it on the way.
##
## LATENCY. Every kind of call has a length — "CONTACT, LEFT" is out of the mouth
## in a third of a second, "AREA CLEAR" takes over a second and nobody is in a
## hurry to say it. The speaker's own squad hears it at that delay. The rest of
## the faction hears it again `relay_latency` seconds later, and only if a radio
## actually reaches them; a faction with no radios is heard by whoever is inside
## shouting distance and by nobody else.
##
## ERROR. A called position is a bearing and a guess at a range, and the range
## guess is the part that is wrong. Error grows with how far the speaker was from
## what it is describing and with how unsure it was, shrinks with the faction's
## comms discipline, and grows again when the report is relayed. A body describing
## ITSELF — "reloading", "moving" — is nearly exact, because it knows where it is
## standing.
##
## Delivered traffic lands in a fixed ring with a monotonic sequence number.
## Listeners keep a cursor and read forward from it, so a squad that ticks at four
## hertz and one that ticks at one hertz both see every message exactly once and
## neither can be handed the same message twice. A listener more than `LOG_SIZE`
## messages behind loses the oldest, which is the correct behaviour: it was not
## listening.
##
## COST. Everything here is bounded by a constant. `MAX_PENDING` utterances in
## flight, `LOG_SIZE` delivered messages retained, no allocation after `_init`,
## and `advance` is O(pending) on the faction's slow tick — not per frame, not per
## body.

## The moment it leaves the speaker's mouth. Position is the SPEAKER, so a voice
## line or an overlay marker plays where the body actually is.
signal spoken(kind: int, speaker_id: int, squad_id: StringName, position: Vector3, target_id: int)
## The moment it lands on a listener. Position is the SUBJECT as called — already
## carrying its error — so an overlay drawing this draws what the faction now
## believes rather than what is true.
signal heard(kind: int, speaker_id: int, squad_id: StringName, position: Vector3, target_id: int)

## "Contact, bearing —." A target the caller has eyes on.
const CONTACT: int = 0
## "Moving!" The caller has the bound and is crossing.
const MOVING: int = 1
## "Man down." A squadmate was killed.
const MAN_DOWN: int = 2
## "Pushing." The squad committed to an assault.
const PUSH: int = 3
## "Fall back." Losses crossed the regroup threshold.
const REGROUP: int = 4
## "Frag out." Somebody took the faction's one grenade slot.
const GRENADE: int = 5
## "Flanking." A flanker started the long way round.
const FLANKING: int = 6
## "Taking fire!" Rounds are landing on the caller.
const TAKING_FIRE: int = 7
## "Reloading — cover me." The single most useful thing anybody says.
const RELOADING: int = 8
## "Need support." The caller is losing and wants bodies.
const NEED_SUPPORT: int = 9
## "Target down." Something the faction was shooting at stopped existing.
const TARGET_DOWN: int = 10
## "Area clear." Ground swept, nothing on it. Lowers its priority for a while.
const AREA_CLEAR: int = 11
const KIND_COUNT: int = 12

const KIND_NAMES: PackedStringArray = [
	"CONTACT",
	"MOVING",
	"MAN DOWN",
	"PUSH",
	"REGROUP",
	"GRENADE",
	"FLANKING",
	"TAKING FIRE",
	"RELOADING",
	"NEED SUPPORT",
	"TARGET DOWN",
	"AREA CLEAR",
]

## Seconds each call takes to get out, before the faction's own latency. Roughly
## how long the sentence is: a warning is a syllable, an all-clear is a report.
const KIND_DELAY: PackedFloat32Array = [
	0.30, 0.22, 0.40, 0.45, 0.50, 0.26, 0.44, 0.24, 0.34, 0.62, 0.38, 1.05
]

## Whether the call is ABOUT the speaker (0) or about something the speaker is
## looking at (1). Only the second kind carries range error worth modelling.
const KIND_ABOUT_SUBJECT: PackedInt32Array = [1, 0, 0, 1, 0, 1, 0, 0, 0, 0, 1, 0]

## Priority when the queue is full. A shout about incoming fire displaces a
## conversational all-clear; nothing displaces a man down.
const KIND_PRIORITY: PackedFloat32Array = [
	0.85, 0.45, 1.00, 0.60, 0.90, 0.95, 0.50, 0.88, 0.70, 0.92, 0.55, 0.20
]

## Heard by the speaker's own squad only.
const SCOPE_SQUAD: int = 0
## Relayed to the whole faction, subject to radio reach.
const SCOPE_FACTION: int = 1

## Utterances that may be in flight at once. Past this the quietest is displaced.
const MAX_PENDING: int = 32
## Delivered messages kept for listeners to read back. A listener further behind
## than this has stopped listening and is treated as such.
const LOG_SIZE: int = 64

## Which faction's net this is. Doctrine is re-read from `Factions` every advance,
## so a knob dragged during a playtest takes effect on the next tick.
var faction: int = 0

var _kind: PackedInt32Array = PackedInt32Array()
var _speaker: PackedInt32Array = PackedInt32Array()
var _squad: Array[StringName] = []
var _subject: PackedVector3Array = PackedVector3Array()
var _origin: PackedVector3Array = PackedVector3Array()
var _target: PackedInt32Array = PackedInt32Array()
var _due: PackedFloat32Array = PackedFloat32Array()
var _relay_at: PackedFloat32Array = PackedFloat32Array()
var _conf: PackedFloat32Array = PackedFloat32Array()
var _sigma: PackedFloat32Array = PackedFloat32Array()
var _stage: PackedInt32Array = PackedInt32Array()
var _used: int = 0

var _lkind: PackedInt32Array = PackedInt32Array()
var _lspeaker: PackedInt32Array = PackedInt32Array()
var _lsquad: Array[StringName] = []
var _lpos: PackedVector3Array = PackedVector3Array()
var _lorigin: PackedVector3Array = PackedVector3Array()
var _ltarget: PackedInt32Array = PackedInt32Array()
var _lconf: PackedFloat32Array = PackedFloat32Array()
var _lscope: PackedInt32Array = PackedInt32Array()
var _head: int = 0

## `Factions.comms(faction)`, refreshed each advance. See `Factions.COMMS_*` for
## what each slot means.
var _doc: PackedFloat32Array = PackedFloat32Array()
var _spoken_total: PackedInt32Array = PackedInt32Array()
var _heard_total: PackedInt32Array = PackedInt32Array()
var _rng: XorShift32 = null
var _now: float = 0.0


func _init(comms_faction: int = 0, seed_value: int = 0xC0FFEE) -> void:
	faction = comms_faction
	_rng = XorShift32.new(maxi(seed_value, 1))
	_kind.resize(MAX_PENDING)
	_speaker.resize(MAX_PENDING)
	_squad.resize(MAX_PENDING)
	_subject.resize(MAX_PENDING)
	_origin.resize(MAX_PENDING)
	_target.resize(MAX_PENDING)
	_due.resize(MAX_PENDING)
	_relay_at.resize(MAX_PENDING)
	_conf.resize(MAX_PENDING)
	_sigma.resize(MAX_PENDING)
	_stage.resize(MAX_PENDING)
	_lkind.resize(LOG_SIZE)
	_lspeaker.resize(LOG_SIZE)
	_lsquad.resize(LOG_SIZE)
	_lpos.resize(LOG_SIZE)
	_lorigin.resize(LOG_SIZE)
	_ltarget.resize(LOG_SIZE)
	_lconf.resize(LOG_SIZE)
	_lscope.resize(LOG_SIZE)
	_spoken_total.resize(KIND_COUNT)
	_heard_total.resize(KIND_COUNT)
	_doc = Factions.default_comms()


## Say something. `origin` is where the speaker is standing, `subject` is what the
## call is about — the same point for "reloading", a contact's position for
## "contact". Returns false when the queue was full of more urgent traffic, which
## is a message nobody in the noise would have caught anyway.
##
## Nothing is delivered here. The error is rolled NOW, at the speaker's own range
## and confidence, because that is when the speaker formed the estimate; the delay
## is served by `advance`.
func speak(
	kind: int,
	speaker_id: int,
	squad_id: StringName,
	origin: Vector3,
	subject: Vector3,
	target_id: int,
	confidence: float
) -> bool:
	if kind < 0 or kind >= KIND_COUNT:
		return false
	var i: int = _claim(kind)
	if i < 0:
		return false
	var sigma: float = _error_for(kind, origin, subject, confidence)
	_kind[i] = kind
	_speaker[i] = speaker_id
	_squad[i] = squad_id
	_origin[i] = origin
	_subject[i] = _scatter(subject, sigma)
	_target[i] = target_id
	_conf[i] = clampf(confidence, 0.0, 1.0)
	_sigma[i] = sigma
	_stage[i] = SCOPE_SQUAD
	_due[i] = _now + _doc[Factions.COMMS_LATENCY] + KIND_DELAY[kind] * _pace()
	_relay_at[i] = _due[i] + _doc[Factions.COMMS_RELAY]
	_spoken_total[kind] += 1
	spoken.emit(kind, speaker_id, squad_id, origin, target_id)
	return true


## Serve the queue. Call this once per faction on the slow command tick — every
## number in here moves on a scale of a fraction of a second, and running it per
## frame would deliver the same messages at the same times for sixty times the
## cost.
func advance(delta: float) -> void:
	_doc = Factions.comms(faction)
	_now += delta
	var i: int = 0
	while i < _used:
		if _stage[i] == SCOPE_SQUAD:
			if _now < _due[i]:
				i += 1
				continue
			_deliver(i, SCOPE_SQUAD)
			if reach() <= 0.0:
				_drop(i)
				continue
			_stage[i] = SCOPE_FACTION
			# The relay is a second-hand account, and it is worse than the first.
			_subject[i] = _scatter(_subject[i], _sigma[i] * _doc[Factions.COMMS_RELAY_ERROR])
			_conf[i] *= _doc[Factions.COMMS_RELAY_CONF]
			i += 1
			continue
		if _now < _relay_at[i]:
			i += 1
			continue
		_deliver(i, SCOPE_FACTION)
		_drop(i)


## Metres a faction-scope call carries: the radio if there is one, a raised voice
## if there is not.
func reach() -> float:
	return maxf(_doc[Factions.COMMS_RADIO], _doc[Factions.COMMS_VOICE])


## Sequence number one past the newest delivered message. A listener stores this
## as its cursor and reads forward from it next time.
func head() -> int:
	return _head


## Oldest sequence number still readable. A cursor below this has fallen out of
## the ring and should be snapped up to it.
func oldest() -> int:
	return maxi(_head - LOG_SIZE, 0)


## Whether a listener standing at `listener_pos`, in squad `listener_squad`, is on
## the receiving end of delivered message `seq`.
##
## Squad-scope traffic is heard by the speaker's own squad, full stop — they are
## within a few metres of each other by construction, and a squad that cannot hear
## itself is not a squad. Faction-scope traffic needs a radio that reaches, or a
## listener close enough to have caught the shout directly, and never goes back to
## the squad that already had it.
func reaches(seq: int, listener_pos: Vector3, listener_squad: StringName) -> bool:
	if seq < oldest() or seq >= _head:
		return false
	var k: int = seq % LOG_SIZE
	if _lscope[k] == SCOPE_SQUAD:
		return _lsquad[k] == listener_squad
	if _lsquad[k] == listener_squad:
		return false
	var r: float = reach()
	return _lorigin[k].distance_squared_to(listener_pos) <= r * r


func kind_at(seq: int) -> int:
	return _lkind[seq % LOG_SIZE]


func speaker_at(seq: int) -> int:
	return _lspeaker[seq % LOG_SIZE]


func squad_at(seq: int) -> StringName:
	return _lsquad[seq % LOG_SIZE]


## The subject position AS CALLED — carrying its error. This is what a listener
## acts on, and the fact that it is not the truth is the entire point.
func position_at(seq: int) -> Vector3:
	return _lpos[seq % LOG_SIZE]


func origin_at(seq: int) -> Vector3:
	return _lorigin[seq % LOG_SIZE]


func target_at(seq: int) -> int:
	return _ltarget[seq % LOG_SIZE]


func confidence_at(seq: int) -> float:
	return _lconf[seq % LOG_SIZE]


func scope_at(seq: int) -> int:
	return _lscope[seq % LOG_SIZE]


## Utterances still in flight. A harness watching this drain to zero knows the net
## is quiet.
func pending() -> int:
	return _used


func spoken_total(kind: int) -> int:
	return 0 if kind < 0 or kind >= KIND_COUNT else _spoken_total[kind]


func heard_total(kind: int) -> int:
	return 0 if kind < 0 or kind >= KIND_COUNT else _heard_total[kind]


func clear() -> void:
	_used = 0
	_head = 0
	_now = 0.0
	for k: int in KIND_COUNT:
		_spoken_total[k] = 0
		_heard_total[k] = 0


## How much longer than the book this faction takes to say anything. Discipline
## above one is drilled and clipped; below one is a crowd talking over itself.
func _pace() -> float:
	return clampf(1.0 / maxf(_doc[Factions.COMMS_DISCIPLINE], 0.15), 0.4, 4.0)


## Metres of radius the called position is wrong by.
##
## A call about the speaker itself is nearly exact. A call about something it is
## looking at is a range estimate, and range estimates get worse with range and
## with doubt. Discipline divides the lot: a trained faction calls a grid, a mob
## calls "over there".
func _error_for(kind: int, origin: Vector3, subject: Vector3, confidence: float) -> float:
	var base: float = _doc[Factions.COMMS_ERROR_BASE]
	if KIND_ABOUT_SUBJECT[kind] != 0:
		base += origin.distance_to(subject) * _doc[Factions.COMMS_ERROR_RANGE]
		base *= 1.0 + _doc[Factions.COMMS_ERROR_DOUBT] * (1.0 - clampf(confidence, 0.0, 1.0))
	return base / clampf(_doc[Factions.COMMS_DISCIPLINE], 0.2, 3.0)


## Push a point off by up to `sigma` metres in the horizontal plane. Uniform over
## the disc rather than gaussian, because a bounded error is a wrong call and an
## unbounded one is a bug report.
func _scatter(p: Vector3, sigma: float) -> Vector3:
	if sigma <= 0.001:
		return p
	var a: float = _rng.next() * TAU
	var r: float = sigma * sqrt(_rng.next())
	return p + Vector3(cos(a) * r, 0.0, sin(a) * r)


## A slot for a new utterance. Takes a free one, or displaces the least urgent
## thing in flight when that is less urgent than what is being said now.
func _claim(kind: int) -> int:
	if _used < MAX_PENDING:
		_used += 1
		return _used - 1
	var worst: int = -1
	var worst_p: float = KIND_PRIORITY[kind]
	for i: int in _used:
		var p: float = KIND_PRIORITY[_kind[i]]
		if p < worst_p:
			worst_p = p
			worst = i
	return worst


func _deliver(i: int, scope: int) -> void:
	var k: int = _head % LOG_SIZE
	_lkind[k] = _kind[i]
	_lspeaker[k] = _speaker[i]
	_lsquad[k] = _squad[i]
	_lpos[k] = _subject[i]
	_lorigin[k] = _origin[i]
	_ltarget[k] = _target[i]
	_lconf[k] = _conf[i]
	_lscope[k] = scope
	_head += 1
	_heard_total[_kind[i]] += 1
	heard.emit(_kind[i], _speaker[i], _squad[i], _subject[i], _target[i])


func _drop(i: int) -> void:
	var last: int = _used - 1
	if i != last:
		_kind[i] = _kind[last]
		_speaker[i] = _speaker[last]
		_squad[i] = _squad[last]
		_subject[i] = _subject[last]
		_origin[i] = _origin[last]
		_target[i] = _target[last]
		_due[i] = _due[last]
		_relay_at[i] = _relay_at[last]
		_conf[i] = _conf[last]
		_sigma[i] = _sigma[last]
		_stage[i] = _stage[last]
	_used = last
