class_name NetAvatarLink
extends RefCounted
## The seam between the presence system and `NetGame`. Everything the avatar side needs
## to know about the session goes through here, and nothing else in `res://net/avatar/`
## touches the roster or the wire.
##
## `NetGame` is resolved BY NODE PATH rather than by naming the autoload, and that is
## not fussiness: `tools/build_avatar.gd` instantiates the avatar prefab under
## `--script`, where a script that names an autoload at parse time fails to compile
## before the autoloads exist. Trap 21 in STATUS. `NetPlayer` is a plain `class_name`
## with no autoload behind it, so it is named directly and typed properly.
##
## EVERY LOOKUP HAS AN OFFLINE ANSWER. `NetGame` reports a one-player roster in
## single-player and this file passes that through unchanged, so a demo that calls
## `NetPresence.enter()` with no session running draws its own dot and nothing else.
## The `NetGame`-is-missing branches below are for the same reason one rung lower: a
## harness or a bake that runs the avatar scripts without the autoload up.

## Where the authoritative half lives.
const GAME_PATH: NodePath = ^"/root/NetGame"


## The authoritative half, or null. One `get_node_or_null` against an absolute path;
## cheap enough to call every frame and it is.
static func game(tree: SceneTree) -> Node:
	if tree == null or tree.root == null:
		return null
	return tree.root.get_node_or_null(GAME_PATH)


## This machine's peer id. 1 with no session, which is also the host's id, so
## single-player is the host-alone case and needs no branch of its own anywhere.
static func local_id(tree: SceneTree) -> int:
	var net: Node = game(tree)
	if net != null:
		return int(net.call(&"peer_id"))
	return NetColors.HOST_ID


## True when this machine decides things. Also true offline.
static func is_host(tree: SceneTree) -> bool:
	var net: Node = game(tree)
	if net != null:
		return bool(net.call(&"is_authority"))
	return true


## True when there is a real session with real peers on it.
static func is_networked(tree: SceneTree) -> bool:
	var net: Node = game(tree)
	return net != null and bool(net.call(&"is_networked"))


## Everyone in the session, in slot order, host first, never empty. One dictionary per
## player with everything the avatar side draws:
##   id, slot, name, color, local, aim, aim_valid
##
## Flattened out of `NetPlayer` rather than handed out as objects, so the presence
## system reads one shape whether the answer came from the roster or from the
## single-player fallback below it.
static func roster(tree: SceneTree) -> Array:
	var out: Array = []
	var net: Node = game(tree)
	if net == null:
		out.append(_solo())
		return out
	for who: NetPlayer in net.call(&"players"):
		var row: Dictionary = {
			&"id": who.peer_id,
			&"slot": who.slot,
			&"name": who.display_name(),
			&"color": who.color(),
			&"local": who.is_local,
			&"aim": who.aim_point,
			&"aim_valid": who.aim_valid,
		}
		out.append(row)
	if out.is_empty():
		out.append(_solo())
	return out


## One player, or null. The per-frame path: reading a peer's replicated aim through this
## allocates nothing, where `roster()` builds a dictionary per player and is therefore
## only called on the quarter-second reconcile.
static func player(tree: SceneTree, peer_id: int) -> NetPlayer:
	var net: Node = game(tree)
	if net == null:
		return null
	return net.call(&"player", peer_id) as NetPlayer


## Publish this machine's aim point. `NetGame` replicates it at 20 Hz and hands it back
## on every other machine as `NetPlayer.aim_point` — so the avatar side sends the POINT
## and never the ray, and never runs a wire of its own for it.
static func push_aim(tree: SceneTree, point: Vector3, valid: bool) -> void:
	var net: Node = game(tree)
	if net != null:
		net.call(&"set_local_aim", point, valid)


## Hand `NetGame` the node that is currently a player's body. `NetPlayer.avatar` is
## documented as "written by whoever spawns avatars", and this is that writer.
static func bind_avatar(tree: SceneTree, peer_id: int, node: Node3D) -> void:
	var net: Node = game(tree)
	if net == null:
		return
	var who := net.call(&"player", peer_id) as NetPlayer
	if who != null:
		who.avatar = node


## Whether the transport is actually up, as opposed to merely configured. A peer still
## handshaking answers `has_multiplayer_peer()` with true and then refuses every packet
## you hand it with an error, and a peer that has been closed answers `get_unique_id()`
## the same way — both were live in the first two-instance run and both are silenced
## here rather than at each of the six call sites.
static func transport_ready(tree: SceneTree) -> bool:
	var api: MultiplayerAPI = null if tree == null else tree.get_multiplayer()
	if api == null or not api.has_multiplayer_peer():
		return false
	var peer: MultiplayerPeer = api.multiplayer_peer
	return peer != null and peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED


## The single-player row: you, slot 0, host colour.
static func _solo() -> Dictionary:
	return {
		&"id": NetColors.HOST_ID,
		&"slot": 0,
		&"name": "PLAYER 1",
		&"color": NetColors.of_slot(0),
		&"local": true,
		&"aim": Vector3.ZERO,
		&"aim_valid": false,
	}
