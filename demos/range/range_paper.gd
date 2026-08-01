class_name RangePaperTarget
extends RangeTarget
## The ring target at 25 m. It never falls over; what it does is measure.
##
## Every hole is kept in face-local metres and the extreme spread — the widest
## pair in the group — is reported in millimetres, which is how a group is
## actually measured. Rings score on distance from centre in 77 mm steps, not on
## the printed rings, because the printed rings are a texture and the texture is
## drawn at 34 px of 512 across 1.15 m, which is 76.4 mm and therefore wrong.
## §13.2 of the spec is explicit about which of the two the score uses.
##
## The board clears itself when a DIFFERENT gun starts shooting at it, so a group
## is always one weapon's group. That is the whole point of the target and it is
## why `owner_tag` exists.

## The group changed. `spread_mm` is the extreme spread, `shots` the sample size.
signal group_measured(spread_mm: float, shots: int, gun_name: String)
## The board was papered over, either by a new gun or by the bench button.
signal board_cleared

## Face-local metres between scoring rings.
@export_range(0.02, 0.2, 0.001) var ring_spacing: float = 0.077
## Holes kept. Past this the oldest drops out, so the readout tracks the last
## sixty rounds rather than the whole afternoon.
@export_range(3, 200, 1) var group_capacity: int = 60
## The node whose local frame holes are measured in. The printed face.
@export var face_path: NodePath = NodePath()

## `name#seed` of the weapon that owns the current group.
var owner_tag: String = ""

var _face: Node3D = null
var _holes: PackedVector2Array = PackedVector2Array()
## Extreme spread of `_holes`, cached. Only a new hole can widen a group, so the
## full O(n^2) sweep is only needed when a hole is dropped off the front.
var _spread: float = 0.0
var _gun_name: String = ""


func _ready() -> void:
	super()
	_face = get_node_or_null(face_path) as Node3D
	if _face == null:
		_face = self


## Paper takes the shot, records it and scores it, and is never any worse off.
##
## A client's own round does not land here — the host owns the group, because a
## group made of four machines' guesses is not a group. The hole comes back through
## `_note_remote_hit` with the point the host resolved.
func apply_bullet_damage(
	amount: float, at: Vector3, _normal: Vector3, _dir: Vector3, _zone: StringName, _crit: float
) -> void:
	if not authority:
		return
	var offset: Vector2 = _hole_at(at)
	var ring: int = maxi(0, 10 - roundi(offset.length() / ring_spacing))
	struck.emit(amount, at, ring >= 10)
	_push_hole(offset)
	scored.emit(
		points + ring * 2,
		at,
		"X RING" if ring >= 10 else str(roundi(amount)),
		POP_CRIT if ring >= 8 else POP_HIT
	)
	registered.emit(ring >= 10, false)
	group_measured.emit(_spread * 1000.0, _holes.size(), _gun_name)


## A hole the host put in this board. Same arithmetic, no scoring: the points for
## it are already on their way as their own event.
func _note_remote_hit(at: Vector3) -> void:
	_push_hole(_hole_at(at))
	group_measured.emit(_spread * 1000.0, _holes.size(), _gun_name)


func _hole_at(at: Vector3) -> Vector2:
	var local: Vector3 = _face.to_local(at)
	return Vector2(local.x, local.y)


## Called before the shot is scored so the board belongs to whoever is shooting
## it. A tag is `name#seed`: two rolls of the same gun name are still two guns.
func set_shooter(tag: String, gun_name: String) -> void:
	if tag == owner_tag:
		return
	owner_tag = tag
	_gun_name = gun_name
	clear_group()


## Fresh paper. The bench has a button for this and the readout goes blank.
func clear_group() -> void:
	_holes.clear()
	_spread = 0.0
	board_cleared.emit()
	group_measured.emit(0.0, 0, _gun_name)


## Extreme spread of the current group, millimetres. Zero under three shots,
## because two holes are a line and not a group.
func group_spread_mm() -> float:
	return 0.0 if _holes.size() < 3 else _spread * 1000.0


func shot_count() -> int:
	return _holes.size()


func gun_name() -> String:
	return _gun_name


func restore() -> void:
	# Paper never falls, so restoring it means new paper rather than new health.
	clear_group()
	super()


func _push_hole(at: Vector2) -> void:
	var dropped: bool = false
	while _holes.size() >= group_capacity:
		_holes.remove_at(0)
		dropped = true
	# A new hole can only ever widen the group, so the common case is one pass
	# over the existing holes. Dropping one from the front can narrow it, and
	# only then is the full pairwise sweep worth doing.
	if dropped:
		_holes.push_back(at)
		_recompute_spread()
		return
	for existing: Vector2 in _holes:
		_spread = maxf(_spread, existing.distance_to(at))
	_holes.push_back(at)


func _recompute_spread() -> void:
	_spread = 0.0
	var count: int = _holes.size()
	for i: int in count:
		for j: int in range(i + 1, count):
			_spread = maxf(_spread, _holes[i].distance_to(_holes[j]))
