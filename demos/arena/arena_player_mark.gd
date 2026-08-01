class_name ArenaPlayerMark
extends Node3D
## A remote player's body, as the arena's AI sees it. HOST ONLY.
##
## The compound's enemies do not know what a network is. They know `AITargetIndex`,
## and the index knows a row is a player because `AITarget.faction` is
## `Factions.PLAYER` — that one flag is what `player_first`, `player_bias` and the
## whole priority solve in `ArenaDirector` key off. So making three more people
## shootable is not a new AI feature: it is three more rows in the table the AI
## already reads, and every behaviour the single-player arena has comes free.
##
## The hit has to land on a REAL collider. `AICombat._trace_bare` casts a physics
## ray against `MASK_BULLET | PLAYER` and turns whatever it struck back into a row
## through `AITargetIndex.row_of_collider`, which is a map keyed on the instance id
## of `AITarget.body()`. `PlayerAvatar` already carries an `AnimatableBody3D` on
## `GameLayers.PLAYER` at `Body/Hull`, so this node parents itself to the avatar and
## points its target's `body_path` at that hull. Nothing new is added to the physics
## world and no second collider can eat a round meant for the capsule.
##
## Damage does NOT stop here. `receiver_path` points back at this node, whose
## `apply_damage` hands the hit to `ArenaNet` — the host's ledger of everyone's
## health — and this node only mirrors the answer back for `health_fraction`, which
## is what `AIMorale` and the flinch model read. The AI therefore sees a player it
## can wound, kill and lose interest in, and the number it is reading is the same
## number the owner of that body is looking at on their own screen.

## A round reached this player. `taken` is what the host's ledger says came off.
signal wounded(peer_id: int, amount: float, from_position: Vector3)

## Where the AI aims at a standing capsule. `PlayerAvatar.STAND_HEIGHT` is 1.80 and
## the player's own baked target aims at 0.76 of eye height; this is the same
## fraction of the same body.
const AIM_HEIGHT: float = 1.25
## Where the avatar's eyes are, matching `NetPresence.EYE_HEIGHT`. Used for the
## line-of-sight test, so a remote player behind a waist-high wall is seen the way
## a local one is.
const EYE_HEIGHT: float = 1.65
## Silhouette radius. `PlayerAvatar.BODY_RADIUS`.
const BODY_RADIUS: float = 0.34
## The avatar's collider, from this node's target. `Avatar/Mark/Target` -> hull.
const HULL_PATH: NodePath = ^"../../Body/Hull"
## Name this node takes under the avatar, so a second attach cannot double it up.
const NODE_NAME: StringName = &"ArenaMark"

var peer_id: int = 0

var _target: AITarget = null
var _fraction: float = 1.0
var _down: bool = false


## Hang a mark on a player's avatar, or return the one already there. The avatar is
## `NetPresence`'s, lives outside the demo's scene, and outlives it — `drop()` is
## how the arena takes its own furniture back down on the way out.
static func attach(avatar: Node3D, id: int) -> ArenaPlayerMark:
	if avatar == null or not is_instance_valid(avatar):
		return null
	var found := avatar.get_node_or_null(NodePath(String(NODE_NAME))) as ArenaPlayerMark
	if found != null:
		return found
	var mark := ArenaPlayerMark.new()
	mark.name = String(NODE_NAME)
	mark.peer_id = id
	avatar.add_child(mark)
	mark.build()
	return mark


## Build the target row. Split out of `attach` because every property has to be
## written BEFORE the node enters the tree: `AITarget._ready` resolves `body_path`
## and `receiver_path` once and caches both.
func build() -> void:
	if _target != null:
		return
	var t := AITarget.new()
	t.name = "Target"
	t.faction = Factions.PLAYER
	t.body_path = HULL_PATH
	t.receiver_path = NodePath("..")
	t.aim_offset = Vector3(0.0, AIM_HEIGHT, 0.0)
	t.eye_offset = Vector3(0.0, EYE_HEIGHT, 0.0)
	t.body_radius = BODY_RADIUS
	# A capsule that is being driven by somebody else's keyboard has no crouch and
	# no footsteps this machine can hear. Its noise comes from the replicated
	# position instead, written into `motion_loudness` by `set_speed`.
	t.footsteps_enabled = false
	add_child(t)
	_target = t


## The row the director registered. Null before `build`.
func target() -> AITarget:
	return _target


## THE SEAM, the same one `PlayerHealth` answers to. `AITarget.receive_damage`
## resolves `receiver_path` and calls this, so every path into a player — a rifle
## round, a shotgun pellet, a claw swing, a blast — arrives here and nowhere else.
## Returning the damage taken keeps the signature `EnemyActor.apply_damage` and
## `PlayerHealth.apply_damage` share.
func apply_damage(amount: float, from_position: Vector3, _attacker: Node = null) -> float:
	if _down or amount <= 0.0:
		return 0.0
	wounded.emit(peer_id, amount, from_position)
	return amount


## What `AITarget.health_fraction` reads, which is what sizes the flinch a hit
## produces and what `AIMorale` scores a wounded contact with.
func health_fraction() -> float:
	return _fraction


## The host's ledger, pushed back so the AI sees what the owner sees.
func set_health(fraction: float, alive: bool) -> void:
	_fraction = clampf(fraction, 0.0, 1.0)
	if _down != alive:
		return
	_down = not alive
	if _target == null:
		return
	if _down:
		# FIRST, and this is the whole reason the mark tracks death at all: a body
		# marked dead leaves `FLAG_ALIVE` on its row and every shooter holding it
		# picks a new mark on its next tick instead of emptying a magazine into
		# somebody who is already looking at a respawn timer.
		_target.mark_dead()
		return
	_target.alive = true
	_target.reset_senses()


## Put the mark where the avatar is. Called by `ArenaNet` every tick: the node is
## parented to the avatar so it rides along, and this only has to keep the loudness
## the AI hears in step with how fast that avatar is actually moving.
func set_speed(metres_per_second: float) -> void:
	if _target != null:
		_target.motion_loudness = clampf(metres_per_second / 6.0, 0.0, 1.0)


## Take the mark off an avatar that is going away, or that the demo is done with.
func drop() -> void:
	if _target != null:
		_target.alive = false
	if is_inside_tree():
		get_parent().remove_child(self)
	queue_free()
