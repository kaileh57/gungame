class_name AITraversal
extends RefCounted
## The scripted motion an agent plays to cross one off-mesh link.
##
## Pathing across a link is free — the navigation server does it. Getting a body
## up a ladder is not: `EnemyActor`'s motor is a flat-ground motor. It applies
## gravity, it calls `move_and_slide` against the world, and `steer()` only takes
## a horizontal direction. Anything that leaves the floor has to come off that
## motor for the duration.
##
## SO IT DOES. `begin()` turns the actor's `_physics_process` off and this class
## writes `global_position` and `rotation.y` itself at the physics rate until the
## crossing is finished. That is not a convenience, it is the guarantee the brief
## asks for: with the motor stopped there is no gravity integrating underneath the
## climb and no `move_and_slide` shoving the body sideways off a rung, so a
## traversal *cannot* be interrupted into a fall. The one thing that does
## interrupt it is dying, and that is handled explicitly — `step()` aborts and
## hands the motor straight back so the corpse falls the way a corpse should.
##
## Every crossing is the same object: a short polyline of legs, each with a speed,
## a vertical curve and a facing. A ladder is three legs (to the rungs, up them,
## out onto the deck); a vault is one leg with a bump in it; a drop is one leg
## whose height eases in like a fall. Writing them as data rather than as five
## `match` arms is what keeps this readable and what makes the speeds tunable
## from one place.
##
## The tunables are plain vars, not `@export`s, for the same reason
## `AINavigator`'s are: this is a RefCounted owned by an agent, not a node.
## `AIPathService` holds the exported copies and stamps them onto every traversal
## it services.

## Vertical profile of one leg.
##
## NOT `Curve`. Godot has a native class of that name and an enum that shadows it
## is a parse error on the whole file — which fails silently in the worst possible
## way: `AITraversal` does not compile, `AINavigator.traverse` comes out null, and
## every agent throws "Nonexistent function 'is_running' in base 'Nil'" on every
## tick. `gdparse` and `gdlint` do not know the engine's class list and pass it.
enum Profile {
	## Constant rate from a to b.
	LINEAR,
	## Height eases in quadratically: a step off a ledge accelerating into a fall.
	FALL,
	## Height takes a sine bump above the straight line: a leap or a vault.
	ARC,
}

## Legs never run shorter than this many seconds, so a zero-length approach still
## gets a frame and the state machine cannot divide by zero.
const MIN_LEG_TIME: float = 0.02
## Metres of clearance the ladder's top-out leg lifts through before stepping
## forward, so a body tops out ABOVE the parapet rather than through it.
const TOP_OUT_LIFT: float = 0.12

## Metres a second climbed on a ladder.
var climb_speed: float = 1.9
## Metres a second walked while stepping onto the link's entry point.
var mount_speed: float = 2.4
## Metres a second across a vault.
var vault_speed: float = 3.1
## Metres a second pulling up onto a ledge.
var mantle_speed: float = 2.0
## Metres a second across a gap jump, measured along the ground.
var jump_speed: float = 5.2
## Metres a second stepping off a ledge, measured along the ground.
var drop_speed: float = 2.6
## Metres a second across a plank or girder.
var bridge_speed: float = 2.2
## Height of the sine bump on a jump, as a fraction of the span. A leap that is
## flat reads as a slide.
var jump_arc: float = 0.16
## Height of the sine bump on a vault, metres.
var vault_arc: float = 0.42
## Radians a second the body may swing its facing during a crossing. Fast: an
## agent that turns to the ladder at its walking turn rate climbs sideways.
var turn_rate: float = 7.0
## Seconds held at the exit before the motor is handed back, so the body has
## planted before it starts walking again.
var settle_time: float = 0.10

## The link kind currently being crossed, or -1. Read-only outside this class.
var kind: int = -1
## True when the last crossing ran all the way to its exit. False while one is
## running and after one was aborted, so a body shot off a ladder is not counted
## as having climbed it. Read-only outside this class.
var completed: bool = false

var _body: CharacterBody3D = null
var _rig: Node = null
var _points: PackedVector3Array = PackedVector3Array()
var _speeds: PackedFloat32Array = PackedFloat32Array()
var _curves: PackedByteArray = PackedByteArray()
var _face: PackedVector3Array = PackedVector3Array()
var _clips: PackedStringArray = PackedStringArray()
var _leg: int = -1
var _u: float = 0.0
var _settle: float = 0.0
var _exit: Vector3 = Vector3.ZERO
var _elapsed: float = 0.0
var _had_physics: bool = true
## Height of the sine bump on whichever leg is curved, metres. One value because
## no crossing has two arced legs.
var _arc: float = 0.0


## Bind the body this traversal moves and the rig it plays clips on. `rig` may be
## null — a body without a rig still crosses, it just does not animate.
func bind(body: CharacterBody3D, rig: Node) -> void:
	_body = body
	_rig = rig if rig != null and rig.has_method(&"play_clip") else null


func is_running() -> bool:
	return _leg >= 0


## Where the crossing ends. Valid while running and immediately after it finishes.
func exit_point() -> Vector3:
	return _exit


## Seconds the current crossing has been running.
func elapsed() -> float:
	return _elapsed


## Start crossing a link of `link_kind` from `entry` to `exit_position`. False
## when there is nothing to bind to or a crossing is already running.
func begin(link_kind: int, entry: Vector3, exit_position: Vector3) -> bool:
	if _body == null or is_running():
		return false
	_points = PackedVector3Array()
	_speeds = PackedFloat32Array()
	_curves = PackedByteArray()
	_face = PackedVector3Array()
	_clips = PackedStringArray()
	kind = link_kind
	completed = false
	_exit = exit_position
	var here: Vector3 = _body.global_position
	match link_kind:
		AILinkBaker.Kind.LADDER:
			_build_ladder(here, entry, exit_position)
		AILinkBaker.Kind.DROP:
			_build_simple(here, entry, exit_position, drop_speed, Profile.FALL, 0.0)
		AILinkBaker.Kind.JUMP:
			var span: float = Vector2(exit_position.x - entry.x, exit_position.z - entry.z).length()
			_build_simple(here, entry, exit_position, jump_speed, Profile.ARC, span * jump_arc)
		AILinkBaker.Kind.VAULT:
			_build_simple(here, entry, exit_position, vault_speed, Profile.ARC, vault_arc)
		AILinkBaker.Kind.MANTLE:
			_build_simple(here, entry, exit_position, mantle_speed, Profile.ARC, vault_arc * 0.5)
		_:
			_build_simple(here, entry, exit_position, bridge_speed, Profile.LINEAR, 0.0)
	_leg = 0
	_u = 0.0
	_settle = 0.0
	_elapsed = 0.0
	_had_physics = _body.is_physics_processing()
	_body.velocity = Vector3.ZERO
	_body.set_physics_process(false)
	_play(0)
	return true


## Advance the crossing. Returns true while it is still running.
##
## A body that died mid-crossing is handed its motor back on the spot: gravity
## resumes, `EnemyActor._die` has already started the collapse, and the corpse
## falls from wherever on the ladder it was hit. Anything else would leave a dead
## body hanging in the air until the pool reclaimed it.
func step(delta: float) -> bool:
	if _leg < 0:
		return false
	if _body == null or not is_instance_valid(_body):
		_leg = -1
		return false
	if _body.get(&"alive") == false:
		abort()
		return false
	_elapsed += delta
	if _settle > 0.0:
		_settle -= delta
		if _settle <= 0.0:
			_finish()
	else:
		_advance_leg(delta)
	return _leg >= 0


## Stop wherever the body is and hand the motor straight back.
func abort() -> void:
	if _leg < 0:
		return
	_leg = -1
	_settle = 0.0
	kind = -1
	if _body != null and is_instance_valid(_body):
		_body.velocity = Vector3.ZERO
		_body.set_physics_process(_had_physics)


## Move along the current leg, and roll onto the next one when it is spent. The
## last leg hands over to `settle_time` rather than finishing outright, so a body
## has planted at the exit before its motor starts pushing it around again.
func _advance_leg(delta: float) -> void:
	var a: Vector3 = _points[_leg]
	var b: Vector3 = _points[_leg + 1]
	var seconds: float = maxf(a.distance_to(b) / maxf(_speeds[_leg], 0.05), MIN_LEG_TIME)
	_u += delta / seconds
	_body.global_position = _sample(a, b, clampf(_u, 0.0, 1.0), _curves[_leg], _arc_of(_leg))
	_turn(_face[_leg], delta)
	if _u < 1.0:
		return
	_u = 0.0
	_leg += 1
	if _leg < _points.size() - 1:
		_play(_leg)
		return
	_body.global_position = _exit
	if settle_time <= 0.0:
		_finish()
		return
	_settle = settle_time
	_leg = _points.size() - 2


## Legs for a ladder: walk to the rungs, climb them, step out onto the deck.
##
## The climb faces the wall — `entry - exit` flattened is the direction the rungs
## are bolted in — because a body that climbs facing outward reads as a lift, not
## a ladder.
func _build_ladder(here: Vector3, entry: Vector3, exit_position: Vector3) -> void:
	var wall := Vector3(exit_position.x - entry.x, 0.0, exit_position.z - entry.z)
	if wall.length_squared() < 1e-4:
		wall = Vector3(entry.x - here.x, 0.0, entry.z - here.z)
	if wall.length_squared() < 1e-4:
		wall = Vector3.FORWARD
	wall = wall.normalized()
	var top := Vector3(entry.x, exit_position.y + TOP_OUT_LIFT, entry.z)
	_points.push_back(here)
	_points.push_back(entry)
	_points.push_back(top)
	_points.push_back(exit_position)
	_speeds.append_array([mount_speed, climb_speed, mount_speed])
	_curves.append_array([Profile.LINEAR, Profile.LINEAR, Profile.LINEAR])
	_face.append_array([wall, wall, wall])
	_clips.append_array([String(BeastClips.WALK), String(BeastClips.WALK), String(BeastClips.WALK)])
	_arc = 0.0


## Legs for everything that is one movement: step onto the entry, then cross.
func _build_simple(
	here: Vector3, entry: Vector3, exit_position: Vector3, speed: float, curve: int, arc: float
) -> void:
	var out := Vector3(exit_position.x - entry.x, 0.0, exit_position.z - entry.z)
	if out.length_squared() < 1e-4:
		out = Vector3(entry.x - here.x, 0.0, entry.z - here.z)
	if out.length_squared() < 1e-4:
		out = Vector3.FORWARD
	out = out.normalized()
	_points.push_back(here)
	_points.push_back(entry)
	_points.push_back(exit_position)
	_speeds.append_array([mount_speed, speed])
	_curves.append_array([Profile.LINEAR, curve])
	_face.append_array([out, out])
	_clips.append_array([String(BeastClips.WALK), String(BeastClips.RUN)])
	_arc = arc


func _arc_of(leg: int) -> float:
	return _arc if _curves[leg] == Profile.ARC else 0.0


## Position along one leg at parameter `u`.
static func _sample(a: Vector3, b: Vector3, u: float, curve: int, arc: float) -> Vector3:
	var p: Vector3 = a.lerp(b, u)
	if curve == Profile.FALL:
		p.y = lerpf(a.y, b.y, u * u)
	elif curve == Profile.ARC and arc > 0.0:
		p.y += sin(PI * u) * arc
	return p


func _turn(want: Vector3, delta: float) -> void:
	if want.length_squared() < 1e-6:
		return
	var target: float = atan2(want.x, want.z)
	_body.rotation.y = rotate_toward(_body.rotation.y, target, turn_rate * delta)


func _play(leg: int) -> void:
	if _rig != null and leg < _clips.size():
		_rig.play_clip(_clips[leg])


func _finish() -> void:
	_leg = -1
	kind = -1
	completed = true
	if _body == null or not is_instance_valid(_body):
		return
	_body.global_position = _exit
	_body.velocity = Vector3.ZERO
	_body.set_physics_process(_had_physics)
