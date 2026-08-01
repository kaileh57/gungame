class_name LobbySign
extends RigidBody3D
## The lobby's toast: a stencilled steel sign that FALLS THROUGH YOUR VIEW, tumbles,
## and is gone.
##
## Every lobby event says itself this way — "GAME CREATED", "KELLEN JOINED",
## "KELLEN LEFT". A message that has to obey gravity cannot be mistaken for chrome,
## and a notice you watch fall is one you actually read. It is the same object every
## time with different words on it, because a second kind of toast is a second thing
## to learn.
##
## IT COLLIDES WITH NOTHING. Its `collision_mask` is zero, so it tests against nothing
## and can never land on the bench, knock a plate off the board, or come to rest across
## the menu; its `collision_layer` is `VIEWMODEL`, the one layer in the contract that
## nothing queries, so nothing tests against it either. It falls under gravity, it
## spins, it leaves the frame at the bottom, and it frees itself after `live_seconds`.
## That is the whole safety argument for putting a rigid body in a menu.
##
## LAYER ZERO WOULD READ THE SAME AND DOES NOT WORK — see `tools/menu_lobby.gd`.
##
## Both faces carry the text, so it is readable whichever way it happens to be facing
## while it turns over.
##
## BAKED, like everything else in this menu: `res://tools/build_main_menu.gd` writes
## `res://data/ui/lobby_sign.tscn` and this file only ever instances it.

## The baked prefab. One artifact, instanced per toast.
const SCENE_PATH: String = "res://data/ui/lobby_sign.tscn"

## Metres in front of the eye the sign is dropped. Close enough to be big, far enough
## that the near plane never clips it.
const DEPTH: float = 1.05
## Metres above the view centre it starts, measured along the camera's own up axis.
## The top of a 78-degree frame at `DEPTH` is 0.85 m up, so this clears it with the
## sign's own half-height and a little margin — it ENTERS the frame rather than
## appearing in it, and it does not start so far out that it is falling at speed by
## the time it arrives.
const RISE: float = 1.02
## Downward push at birth, on top of gravity. Without it the first quarter second is
## a sign hanging still in the air.
##
## THIS AND `gravity_scale` (0.30, on the prefab) SET HOW LONG IT IS READABLE, and
## they are the two numbers to turn if it ever feels wrong. At full gravity a sign
## crosses the whole frame in 0.4 s, which is long enough to notice and much too
## short to read; at 0.30 it takes about 0.9 s to cross, which is one glance.
const DROP_SPEED: float = 0.20

## Loaded once for the whole run. A toast that costs a disk read is a toast that
## stutters the menu the first time somebody joins.
static var _packed: PackedScene = null
static var _looked: bool = false

## Seconds before it frees itself. It is out of the bottom of the frame in about 1.2.
@export_range(0.5, 8.0, 0.1) var live_seconds: float = 2.6

var _seeded: XorShift32 = null

@onready var _front: Label3D = $Front
@onready var _back: Label3D = $Back


## Drop one. `host` is anything already in the 3D tree, `eye` is the camera it falls
## across. Returns the sign, or null when the prefab has not been baked — a missing
## toast must never take the menu down with it.
static func drop(host: Node, eye: Camera3D, text: String, color: Color) -> LobbySign:
	if host == null or eye == null or not host.is_inside_tree():
		return null
	var packed: PackedScene = _prefab()
	if packed == null:
		return null
	var board := packed.instantiate() as LobbySign
	if board == null:
		return null
	# AIMED BEFORE IT ENTERS THE TREE, and that is not a style choice. A rigid body's
	# transform belongs to the physics server the moment the body is registered, and
	# writing it afterwards is a teleport the solver need not honour on the frame the
	# body was added. MEASURED: every sign stayed at the world origin, under the
	# bench, falling through the floor where nobody ever saw one.
	board.aim(eye, host as Node3D)
	host.add_child(board)
	board.set_text(text, color)
	board.begin_life()
	return board


## Put it above the frame, face it at the eye, and throw it.
##
## Called BEFORE the node is in a tree, so the placement is expressed in the PARENT'S
## frame — `global_transform` means nothing until a node has a tree to be global in.
## The velocities need no such conversion: a rigid body's linear and angular velocity
## are world space whatever its parent is doing.
func aim(eye: Camera3D, parent: Node3D) -> void:
	var rng: XorShift32 = _rng()
	var eye_basis: Basis = eye.global_basis
	var forward: Vector3 = -eye_basis.z
	var up: Vector3 = eye_basis.y
	var right: Vector3 = eye_basis.x
	var side: float = rng.next_range(-0.30, 0.30)
	var at: Vector3 = eye.global_position + forward * DEPTH + up * RISE + right * side
	# Face the eye, then roll a little, so no two toasts arrive at the same angle.
	var roll := Basis(Vector3(0.0, 0.0, 1.0), rng.next_range(-0.30, 0.30))
	var placed := Transform3D(Basis.looking_at(forward, up) * roll, at)
	if parent != null and parent.is_inside_tree():
		placed = parent.global_transform.affine_inverse() * placed
	transform = placed
	linear_velocity = (
		right * rng.next_range(-0.40, 0.40) + up * -DROP_SPEED + forward * rng.next_range(0.0, 0.12)
	)
	angular_velocity = Vector3(
		rng.next_range(-0.9, 0.9), rng.next_range(-0.7, 0.7), rng.next_range(-1.6, -0.6)
	)


## Start the clock that frees it. Separate from `aim` because it needs a tree.
func begin_life() -> void:
	var life: SceneTreeTimer = get_tree().create_timer(live_seconds, true, false, true)
	life.timeout.connect(queue_free)


## Write both faces. Separate from `aim` so a test can letter one without a camera.
func set_text(text: String, color: Color) -> void:
	var shown: String = text.to_upper()
	for face: Label3D in [_front, _back]:
		if face == null:
			continue
		face.text = shown
		face.modulate = color


## A stream per sign, seeded off the clock rather than off a counter, because two
## toasts in the same second must not tumble identically. Cosmetic and local on every
## machine, so nothing across the wire depends on it agreeing.
func _rng() -> XorShift32:
	if _seeded == null:
		_seeded = XorShift32.new(Time.get_ticks_usec() ^ get_instance_id())
	return _seeded


static func _prefab() -> PackedScene:
	if _looked:
		return _packed
	_looked = true
	if not ResourceLoader.exists(SCENE_PATH):
		push_warning("LobbySign: %s is missing. Run res://tools/build_main_menu.gd." % SCENE_PATH)
		return null
	_packed = ResourceLoader.load(SCENE_PATH, "PackedScene") as PackedScene
	return _packed
