class_name LobbyDots
extends Node3D
## The laser pointers on the title screen: where the other three players are aiming,
## drawn as a dot on whatever they are pointing at.
##
## THE DOT IS A POINT, NOT A BEAM. Each machine casts its own aim ray, hands the
## RESULT to `NetGame.set_local_aim()`, and `NetGame` relays it to everybody at 20 Hz.
## Nobody re-simulates anybody's aim and nobody can move somebody else's dot. Drawing
## them is purely local, on every machine, with no RPC of its own.
##
## PUT YOUR DOT ON SOMEBODY ELSE'S AND THEIR NAME APPEARS above it, small and
## half-transparent. The test is angular rather than metric so it feels the same at
## the far corner of the board as it does on the bench in front of you.
##
## WHY THIS EXISTS RATHER THAN `NetPresence`. The presence system draws a capsule for
## every remote player at their body's position — and on the title screen every
## player's eye is the same baked camera, so four capsules would stack in your face
## between you and the board. The lobby needs the dots without the bodies, so it draws
## them itself out of `NetGame.players()`, which is the published pattern. Nothing
## here is coupled to `net/avatar/`; a demo still gets the full presence system.
##
## THE AIM RAY COSTS NOTHING. When the cursor is on a plate, `DiegeticInteractor` has
## already cast that exact ray this physics frame and its answer is borrowed. When it
## is not, the ray is solved ANALYTICALLY against the four boxes that make up the
## readable parts of this shed — the board, the bench top, the plank wall, the slab —
## rather than by adding colliders to a scene that deliberately has almost none. Those
## boxes are baked into `solids` by `res://tools/build_main_menu.gd`, so they cannot
## drift away from the geometry they stand for.

## Metres the aim ray reaches. The shed is nine metres across.
const REACH: float = 14.0
## Metres the dot is lifted off the surface toward the eye, so it never z-fights the
## board it is sitting on.
const LIFT: float = 0.010
## Radians of half-angle that counts as "your dot is on their dot".
const HOVER_ANGLE: float = 0.020
## Seconds for a dot to catch up with a fresh aim packet. Aim arrives at 20 Hz and
## this is what turns fifty-millisecond steps into a slide.
const FOLLOW_SECONDS: float = 0.055

## The solids the aim ray is allowed to land on, as (centre, size) pairs. Written by
## the builder from the shed's own numbers.
@export var solids: PackedVector3Array = PackedVector3Array()

var _eye: Camera3D = null
var _hands: DiegeticInteractor = null
var _point: Vector3 = Vector3.ZERO
var _valid: bool = false
var _dots: Array[MeshInstance3D] = []
var _names: Array[Label3D] = []
var _live: PackedVector3Array = PackedVector3Array()


func _ready() -> void:
	for child: Node in get_children():
		var dot := child as MeshInstance3D
		if dot == null:
			continue
		_dots.append(dot)
		_names.append(dot.get_node_or_null(^"Name") as Label3D)
		_live.append(Vector3.ZERO)
		dot.visible = false
	set_process(true)


func _process(delta: float) -> void:
	_solve_aim()
	NetGame.set_local_aim(_point, _valid)
	_draw_others(delta)


## The eye the rays come from and the hands whose answer is borrowed. `hands` may be
## null, in which case every ray is solved against `solids`.
func bind(eye: Camera3D, hands: DiegeticInteractor) -> void:
	_eye = eye
	_hands = hands


## Where this machine is pointing, in world space.
func aim_point() -> Vector3:
	return _point


func aim_valid() -> bool:
	return _valid


# --- this machine's aim ------------------------------------------------------


func _solve_aim() -> void:
	_valid = false
	if _eye == null or not is_instance_valid(_eye):
		return
	# The hands already cast this ray, against the plates, on this physics frame.
	if _hands != null and is_instance_valid(_hands) and _hands.hovered() != null:
		_point = _hands.hover_point()
		_valid = true
		return
	var viewport: Viewport = _eye.get_viewport()
	if viewport == null:
		return
	var pixel: Vector2 = viewport.get_mouse_position()
	var from: Vector3 = _eye.project_ray_origin(pixel)
	var direction: Vector3 = _eye.project_ray_normal(pixel)
	var best: float = REACH
	for i: int in _solid_count():
		var hit: float = _ray_box(from, direction, _solid(i))
		if hit >= 0.0 and hit < best:
			best = hit
			_valid = true
	if _valid:
		_point = from + direction * best


func _solid_count() -> int:
	return solids.size() / 2


func _solid(index: int) -> AABB:
	var centre: Vector3 = solids[index * 2]
	var size: Vector3 = solids[index * 2 + 1]
	return AABB(centre - size * 0.5, size)


## Slab test. Returns the distance along `direction` at which the ray enters the box,
## or -1 when it misses. `direction` is expected normalised, so the answer is metres.
static func _ray_box(from: Vector3, direction: Vector3, box: AABB) -> float:
	var lo: float = 0.0
	var hi: float = INF
	for axis: int in 3:
		var d: float = direction[axis]
		var b0: float = box.position[axis]
		var b1: float = b0 + box.size[axis]
		if absf(d) < 0.000001:
			if from[axis] < b0 or from[axis] > b1:
				return -1.0
			continue
		var t0: float = (b0 - from[axis]) / d
		var t1: float = (b1 - from[axis]) / d
		lo = maxf(lo, minf(t0, t1))
		hi = minf(hi, maxf(t0, t1))
		if lo > hi:
			return -1.0
	return lo


# --- everybody else's ---------------------------------------------------------


## One dot per remote player, in slot order. Written straight out of the roster, so
## in single player this loop runs once, finds only the local player, and draws
## nothing at all.
func _draw_others(delta: float) -> void:
	if _dots.is_empty():
		return
	var eye_at: Vector3 = Vector3.ZERO if _eye == null else _eye.global_position
	var k: float = 1.0 - exp(-delta / FOLLOW_SECONDS)
	var used: int = 0
	# YOUR OWN LASER IS NOT FOR YOU. These dots exist so you can see where the other
	# three are pointing; your own aim is the crosshair in the middle of your screen, and
	# a second marker riding it is noise.
	#
	# FILTERED BY PEER ID, NOT ONLY BY `is_local`. The roster rebuilds `NetPlayer`
	# objects from network entries, so the player who is you can come back as a DIFFERENT
	# object carrying the same `peer_id` and a default `is_local` of false — and that
	# copy sailed straight through an `is_local` test and drew your own dot back at you.
	# The id is the identity; the flag is only a hint about which object you are holding.
	var me: int = NetGame.peer_id()
	for who: NetPlayer in NetGame.players():
		if who.is_local or who.peer_id == me or not who.aim_valid or used >= _dots.size():
			continue
		_place(used, who, eye_at, k)
		used += 1
	for i: int in range(used, _dots.size()):
		_dots[i].visible = false


func _place(index: int, who: NetPlayer, eye_at: Vector3, k: float) -> void:
	var dot: MeshInstance3D = _dots[index]
	var target: Vector3 = who.aim_point
	if not dot.visible:
		_live[index] = target
	else:
		_live[index] = _live[index].lerp(target, k)
	var at: Vector3 = _live[index]
	dot.visible = true
	dot.global_position = at + (eye_at - at).normalized() * LIFT
	var color: Color = who.color()
	var material := dot.material_override as StandardMaterial3D
	if material != null:
		material.albedo_color = color
		material.emission = color
	var tag: Label3D = _names[index]
	if tag == null:
		return
	tag.text = who.display_name()
	tag.modulate = Color(color.r, color.g, color.b, 0.55)
	tag.visible = _on_dot(at, eye_at)


## Is this machine's own dot sitting on that one? Angular, measured from the eye, so
## the tolerance is the same everywhere in the shed.
func _on_dot(at: Vector3, eye_at: Vector3) -> bool:
	if not _valid:
		return false
	var theirs: Vector3 = at - eye_at
	var mine: Vector3 = _point - eye_at
	if theirs.length_squared() < 0.0001 or mine.length_squared() < 0.0001:
		return false
	return theirs.normalized().dot(mine.normalized()) > cos(HOVER_ANGLE)
