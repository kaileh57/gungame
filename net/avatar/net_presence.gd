class_name NetPresence
extends Node
## How players see each other. One node, parented to `/root`, that owns every avatar
## and every laser dot in the game.
##
## A DEMO NEEDS ONE LINE:
## [codeblock]
## func _ready() -> void:
##     NetPresence.enter(NetPresence.FULL, $Player/Eye)     # walk-around demos
##     NetPresence.enter(NetPresence.SPHERE, $Spectator)    # firefight spectators
##     NetPresence.enter(NetPresence.GHOST, $Player/Eye)    # ash_flats race
## [/codeblock]
## The eye may be omitted, in which case the viewport's live camera is used every frame
## — which is what a demo with an F8 freecam wants. Call it from `_ready`, not
## `_enter_tree`: the singleton parents itself to `/root` and the tree must have
## finished adding your scene first. Single-player demos may call it too and cost
## nothing: the roster is one player long and only your own dot is drawn.
##
## WHAT IT DRAWS. A `PlayerAvatar` and a `LaserCursor` per remote player, plus your own
## dot, drawn dim. There is deliberately no avatar for yourself: you are inside it.
##
## THE DOT IS A POINT, NOT A RAY. The owner casts on its own machine — borrowing the
## ray `CombatReticle` already casts, so a demo with a reticle spends nothing — and
## hands the RESULT to `NetGame.set_local_aim()`. `NetGame` relays it at 20 Hz through
## the host and it arrives on every other machine as `NetPlayer.aim_point`. Nobody
## re-simulates anybody's aim, nobody can move somebody else's dot, and there is no
## second wire for it.
##
## POSITION IS THE ONE THING THIS FILE STILL SENDS ITSELF. `NetGame` replicates the
## roster and the aim; it does not yet replicate where a body is. Until something does,
## presence broadcasts its own position and yaw at `push_hz` over
## `SceneMultiplayer.send_bytes`, so an avatar stands where its player stands rather
## than at the origin. It is addressed to a PEER and not to a node path, which is what
## makes it safe for a player who has not entered the scene yet — an RPC would fail
## noisily in exactly that case. Packets carry a magic word and anything without it is
## ignored, so the channel is shared politely.
##
## `publish()` overrides it. The first `publish()` for a peer takes that peer off the
## fallback permanently, so whoever ends up owning authoritative movement wins without
## having to come here and turn anything off.

## Presence modes, re-exported from `PlayerAvatar` so a demo names one thing.
const FULL: int = PlayerAvatar.Mode.FULL
const SPHERE: int = PlayerAvatar.Mode.SPHERE
const GHOST: int = PlayerAvatar.Mode.GHOST

## Where the singleton lives. Fixed, so anything can find it without being handed it.
const NODE_NAME: StringName = &"NetPresence"
const AVATAR_SCENE: String = "res://data/net/player_avatar.tscn"
const CURSOR_SCENE: String = "res://data/net/laser_cursor.tscn"

## Group `CombatReticle` puts itself in. When a demo has one, its ray answers the aim
## question and this file casts nothing at all — the reticle already casts exactly the
## right ray, against exactly the right mask, on every physics frame.
const RETICLE_GROUP: StringName = &"aim_indicator"

## First four bytes of every position packet. Anything else on the raw channel is
## somebody else's and is dropped without being parsed.
const MAGIC: int = 0x3156414E
const KIND_MOVE: int = 1
const PAYLOAD_SIZE: int = 5
const CHANNEL: int = 0

## Eye height above the feet, from `tools/build_player.gd`. Used to derive a body
## position when all this file has is a camera.
const EYE_HEIGHT: float = 1.65

## Deliberately NOT a static cache of the node.
##
## A `static var` holding a Node keeps this script — and everything the node owns —
## alive past the point where Godot counts leaked objects at exit, so caching the
## singleton here reported as "4 ObjectDB instances leaked / 1 resource still in
## use" in every demo that called `enter()`. The tree is the only owner; look the
## node up by name, which is what the fallback path already did.
const _SINGLETON_DOC: int = 0

## Position packets per second, each way. Modest by design — the interpolation on the
## receiving end is what makes it look continuous, not the rate.
@export_range(2.0, 60.0, 1.0) var push_hz: float = 18.0
## Metres the body must move, or radians it must turn, before a packet is worth
## sending. A player standing still costs one keepalive every `idle_seconds`.
@export_range(0.0, 2.0, 0.005) var move_epsilon: float = 0.03
@export_range(0.0, 1.0, 0.005) var turn_epsilon: float = 0.02
@export_range(0.1, 5.0, 0.05) var idle_seconds: float = 0.5
## How often the roster is reconciled. Four players; this is not a hot path.
@export_range(0.05, 2.0, 0.05) var roster_seconds: float = 0.25
## Reach and mask of the aim ray, used only when the demo has no reticle to borrow.
@export_range(1.0, 1000.0, 1.0) var aim_reach: float = 240.0
@export_flags_3d_physics var aim_mask: int = GameLayers.MASK_BULLET
## Replicate this machine's own position and yaw. Turn it off once something
## authoritative is driving avatars through `publish()`.
@export var replicate_transform: bool = true
## Draw your own dot, dimmed. Worth keeping: it is what makes putting your dot on
## somebody else's dot a thing you can aim at rather than a thing you guess at.
@export var show_own_dot: bool = true

@export_group("Dot hover")
## Half-angle, in radians, of the cone around your aim point that counts as being on
## somebody's dot. 0.02 rad is about 1.15 degrees — 0.2 m at ten metres, 2 m at a
## hundred — so it feels the same at every range instead of impossible at one of them.
@export_range(0.002, 0.2, 0.001) var hover_angle: float = 0.020
@export_range(0.02, 4.0, 0.01) var hover_min: float = 0.15
@export_range(0.1, 20.0, 0.1) var hover_max: float = 2.50
## How much the radius grows once you are already on a dot, so the name does not strobe
## at the edge of the cone.
@export_range(1.0, 3.0, 0.05) var hover_release: float = 1.45

var mode: int = FULL:
	set = set_mode

var _local_id: int = NetColors.HOST_ID
var _eye: Camera3D = null
var _body: Node3D = null
var _body_forced: bool = false
var _reticle: Node = null
var _avatars: Dictionary = {}
var _cursors: Dictionary = {}
var _names: Dictionary = {}
var _colors: Dictionary = {}
var _published: Dictionary = {}
var _last_rx: Dictionary = {}
var _avatar_scene: PackedScene = null
var _cursor_scene: PackedScene = null
var _aim_point: Vector3 = Vector3.ZERO
var _aim_valid: bool = false
var _sent_feet: Vector3 = Vector3.ZERO
var _sent_yaw: float = 0.0
var _push_clock: float = 0.0
var _idle_clock: float = 0.0
var _roster_clock: float = 999.0
var _hovered: int = 0
var _query: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.new()


## The singleton, created on first use. Safe to call from anywhere, including before any
## demo has loaded — the lobby should call it once so the node exists on every machine
## before the first packet arrives.
static func instance() -> NetPresence:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null or tree.root == null:
		return null
	var found := tree.root.get_node_or_null(NodePath(NODE_NAME)) as NetPresence
	if found == null:
		found = NetPresence.new()
		found.name = NODE_NAME
		tree.root.add_child(found)
	return found


## The node if it already exists, without creating one. Teardown paths use this so
## leaving a demo can never resurrect the singleton on the way out.
static func _peek() -> NetPresence:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null or tree.root == null:
		return null
	return tree.root.get_node_or_null(NodePath(NODE_NAME)) as NetPresence


## A demo declares how players appear in it, and where its eye is. One line, in
## `_ready`. `eye` may be null, which means "whatever camera the viewport is using".
static func enter(presence_mode: int, eye: Node = null) -> NetPresence:
	var it: NetPresence = instance()
	if it == null:
		return null
	it.set_mode(presence_mode)
	it.set_local_eye(eye as Camera3D)
	return it


## Hide everyone. A scene change does not need this — the roster survives and the next
## packet re-places every avatar — but a demo that tears down early can be tidy.
static func leave() -> void:
	var it: NetPresence = _peek()
	if it != null:
		it.set_local_eye(null)
		it._clear_placements()


func _ready() -> void:
	# ALWAYS, because a local pause menu is local. Freezing the other three players
	# because you opened your own settings page is a bug you would only find in a
	# four-player session, which is the hardest kind of session to be in.
	process_mode = Node.PROCESS_MODE_ALWAYS
	_avatar_scene = ResourceLoader.load(AVATAR_SCENE, "PackedScene") as PackedScene
	_cursor_scene = ResourceLoader.load(CURSOR_SCENE, "PackedScene") as PackedScene
	if _avatar_scene == null or _cursor_scene == null:
		push_error("NetPresence: missing %s. Run res://tools/build_avatar.gd." % AVATAR_SCENE)
	_query.collide_with_areas = false
	_query.collide_with_bodies = true
	_bind_channel()


func _process(delta: float) -> void:
	_roster_clock += delta
	if _roster_clock >= roster_seconds:
		_roster_clock = 0.0
		_bind_channel()
		_sync_roster()
	_update_hover()


func _physics_process(delta: float) -> void:
	_probe_aim()
	NetAvatarLink.push_aim(get_tree(), _aim_point, _aim_valid)
	var own := _cursors.get(_local_id) as LaserCursor
	if own != null:
		own.push(_aim_point, _aim_valid and show_own_dot)
	_push_clock += delta
	_idle_clock += delta
	if _push_clock >= 1.0 / maxf(push_hz, 1.0):
		_push_clock = 0.0
		_send_move()


# --- what a demo and an authority call ---------------------------------------


func set_mode(new_mode: int) -> void:
	mode = clampi(new_mode, FULL, GHOST)
	for id: int in _avatars:
		(_avatars[id] as PlayerAvatar).set_mode(mode)


## The eye the aim ray is cast from and every distance is measured against. Null means
## the viewport's live camera, resolved every frame.
func set_local_eye(camera: Camera3D) -> void:
	_eye = camera
	_reticle = null
	if not _body_forced:
		_body = null


## What this machine's avatar stands for. Optional: the first `CharacterBody3D` above
## the eye is used when nothing is set, which is the player prefab's own shape.
func set_local_body(node: Node3D) -> void:
	_body = node
	_body_forced = node != null


## Drive an avatar from an authority. Any subset of `name`, `color`, `position`, `yaw`,
## `visible`.
##
## The first call carrying a position for a peer takes that peer off this file's own
## transform fallback permanently, so the two can never fight over where somebody is.
func publish(peer_id: int, state: Dictionary) -> void:
	if peer_id <= 0:
		return
	if state.has(&"position") or state.has(&"yaw"):
		_published[peer_id] = true
	if state.has(&"name"):
		_names[peer_id] = String(state[&"name"])
	if state.has(&"color"):
		_colors[peer_id] = Color(state[&"color"])
	var avatar: PlayerAvatar = _ensure_peer(peer_id)
	_dress(peer_id)
	if avatar == null:
		return
	if state.has(&"visible"):
		avatar.set_dim(1.0 if bool(state[&"visible"]) else 0.0)
	if state.has(&"position"):
		avatar.set_target(Vector3(state[&"position"]), float(state.get(&"yaw", 0.0)))


## Forget a player. The roster sweep does it on its own when `NetGame` drops somebody,
## so this is only needed to make a departure instant.
func drop(peer_id: int) -> void:
	NetAvatarLink.bind_avatar(get_tree(), peer_id, null)
	for table: Dictionary in [_avatars, _cursors]:
		var node := table.get(peer_id) as Node
		if node != null:
			node.queue_free()
		table.erase(peer_id)
	for table: Dictionary in [_names, _colors, _published, _last_rx]:
		table.erase(peer_id)


# --- what everyone else can read --------------------------------------------


## Where this machine's aim ray landed, in world space.
func aim_point() -> Vector3:
	return _aim_point


## Whether the aim ray hit anything at all. False looking at the sky.
func aim_valid() -> bool:
	return _aim_valid


## Where a player's dot is sitting, smoothed. `Vector3.ZERO` if they have no live dot.
func dot_of(peer_id: int) -> Vector3:
	var cursor := _cursors.get(peer_id) as LaserCursor
	return Vector3.ZERO if cursor == null or not cursor.is_live() else cursor.point()


## The peer whose dot your dot is currently on, or 0. This is the hook for anything that
## wants to react to two players pointing at the same thing.
func hovered_peer() -> int:
	return _hovered


func avatar_of(peer_id: int) -> PlayerAvatar:
	return _avatars.get(peer_id) as PlayerAvatar


## A player's name. `NetPlayer.display_name()` is never empty, so the fallback below is
## only ever seen in the quarter-second between a position packet creating an avatar and
## the next roster reconcile naming it — which is why it is a word and not the peer id,
## because a ten-digit number over somebody's head reads as a bug even for one frame.
func name_of(peer_id: int) -> String:
	return String(_names.get(peer_id, "PLAYER"))


func color_of(peer_id: int) -> Color:
	return _colors.get(peer_id, NetColors.of_slot(0))


## This machine's peer id. 1 when there is no session, which is also the host's id.
func local_id() -> int:
	return _local_id


# --- the roster --------------------------------------------------------------


## Reconcile against `NetGame`'s roster: add anyone new, drop anyone gone, refresh every
## name and colour, and take each player's replicated aim point. Four players, four
## times a second, plus one dot update per player per frame.
func _sync_roster() -> void:
	var tree: SceneTree = get_tree()
	_local_id = NetAvatarLink.local_id(tree)
	var seen: Dictionary = {}
	for row: Dictionary in NetAvatarLink.roster(tree):
		var id: int = int(row[&"id"])
		seen[id] = true
		_names[id] = String(row[&"name"])
		_colors[id] = Color(row[&"color"])
		_ensure_peer(id)
		_dress(id)
	for id: int in _cursors.keys():
		if not seen.has(id):
			drop(id)


## Remote dots, from `NetGame`'s replicated aim. Runs every frame, so it goes through
## `NetAvatarLink.player` rather than `roster` and allocates nothing.
##
## PUSHED EVERY FRAME, EVEN WHEN THE POINT HAS NOT MOVED. The first version pushed only
## on change, which is the obvious optimisation and it is wrong: `LaserCursor` fades a
## dot out after `stale_seconds` without a push, so a player standing still pointing at
## a wall had their dot disappear after a second and come back the moment they twitched.
## Measured, in the two-instance run, with both cameras parked.
##
## Staleness cannot be measured here anyway — `NetPlayer.aim_point` holds its last value
## forever and carries no timestamp, so this loop can only ever be reading how long
## since the value CHANGED, never how long since it arrived. What actually governs a
## dead dot is the roster: `NetGame` drops a departed player and `_sync_roster` frees
## their cursor with them. `aim_valid` governs the rest.
func _sync_dots() -> void:
	var tree: SceneTree = get_tree()
	for id: int in _cursors:
		if id == _local_id:
			continue
		var who: NetPlayer = NetAvatarLink.player(tree, id)
		if who != null:
			(_cursors[id] as LaserCursor).push(who.aim_point, who.aim_valid)


## Make sure a peer has the nodes it needs. Everyone gets a cursor — including you,
## because your own dot is drawn. Only remote players get an avatar: you are inside
## yours and drawing it would put a capsule in your own eye.
func _ensure_peer(peer_id: int) -> PlayerAvatar:
	if not _cursors.has(peer_id) and _cursor_scene != null:
		var cursor := _cursor_scene.instantiate() as LaserCursor
		cursor.set_peer(peer_id)
		add_child(cursor)
		_cursors[peer_id] = cursor
	if peer_id == _local_id or _avatar_scene == null:
		return null
	if not _avatars.has(peer_id):
		var avatar := _avatar_scene.instantiate() as PlayerAvatar
		avatar.name = "Avatar%d" % peer_id
		avatar.peer_id = peer_id
		add_child(avatar)
		avatar.set_mode(mode)
		_avatars[peer_id] = avatar
		# `NetPlayer.avatar` is documented as written by whoever spawns avatars. This
		# is that writer, and it is what lets anything else find a player's body.
		NetAvatarLink.bind_avatar(get_tree(), peer_id, avatar)
	return _avatars[peer_id] as PlayerAvatar


## Push the current name and colour onto whatever nodes a peer has.
func _dress(peer_id: int) -> void:
	var color: Color = color_of(peer_id)
	var text: String = name_of(peer_id)
	var avatar := _avatars.get(peer_id) as PlayerAvatar
	if avatar != null:
		avatar.set_color(color)
		avatar.set_player_name(text)
	var cursor := _cursors.get(peer_id) as LaserCursor
	if cursor != null:
		cursor.set_color(color)
		cursor.set_player_name(text)
		# Re-applied rather than set once at creation: a client's peer id is 1 until the
		# handshake completes and something else after, so a cursor made before it
		# would otherwise be dimmed as "yours" forever.
		cursor.set_dim(peer_id == _local_id)


func _clear_placements() -> void:
	for id: int in _cursors:
		(_cursors[id] as LaserCursor).push(Vector3.ZERO, false)


# --- the local aim ray -------------------------------------------------------


## Where this machine is pointing.
##
## A demo with a `CombatReticle` has already answered this on the same physics frame,
## against the bullet mask, from the same pixel the click path uses — so its answer is
## borrowed and NO ray is cast here at all. The fallback exists for demos that have no
## reticle, and it is deliberately the same query.
func _probe_aim() -> void:
	var reticle: Node = _find_reticle()
	if reticle != null:
		var borrowed: Variant = reticle.call(&"aim_point")
		_aim_valid = bool(reticle.call(&"aim_valid")) and typeof(borrowed) == TYPE_VECTOR3
		if _aim_valid:
			_aim_point = borrowed
		return
	var camera: Camera3D = _resolve_eye()
	var world: World3D = null if camera == null else camera.get_world_3d()
	var space: PhysicsDirectSpaceState3D = null if world == null else world.direct_space_state
	if space == null:
		_aim_valid = false
		return
	var pixel: Vector2 = camera.get_viewport().get_visible_rect().size * 0.5
	_query.from = camera.project_ray_origin(pixel)
	_query.to = _query.from + camera.project_ray_normal(pixel) * aim_reach
	_query.collision_mask = aim_mask
	var hit: Dictionary = space.intersect_ray(_query)
	_aim_valid = not hit.is_empty()
	if _aim_valid:
		_aim_point = hit["position"]


func _find_reticle() -> Node:
	if _reticle != null and is_instance_valid(_reticle) and _reticle.is_inside_tree():
		return _reticle
	_reticle = null
	var tree: SceneTree = get_tree()
	if tree == null:
		return null
	var found: Node = tree.get_first_node_in_group(RETICLE_GROUP)
	if found != null and found.has_method(&"aim_point") and found.has_method(&"aim_valid"):
		_reticle = found
	return _reticle


func _resolve_eye() -> Camera3D:
	if _eye != null and is_instance_valid(_eye) and _eye.is_inside_tree():
		return _eye
	var viewport: Viewport = get_viewport()
	return null if viewport == null else viewport.get_camera_3d()


## The node this machine's avatar stands for, and where its feet are. A camera on its
## own is enough: subtract the eye height and you have a body, which is what a
## spectator in SPHERE mode is anyway.
func _local_stand() -> Dictionary:
	var camera: Camera3D = _resolve_eye()
	if camera == null:
		return {}
	if _body == null or not is_instance_valid(_body):
		_body = _find_body(camera)
	var forward: Vector3 = -camera.global_basis.z
	var yaw: float = atan2(-forward.x, -forward.z)
	if _body != null:
		return {&"feet": _body.global_position, &"yaw": yaw}
	return {&"feet": camera.global_position - Vector3(0.0, EYE_HEIGHT, 0.0), &"yaw": yaw}


## The first `CharacterBody3D` at or above the eye. The player prefab puts the eye one
## level under the body, so this finds it immediately and gives up quickly when there is
## no player at all.
static func _find_body(from: Node) -> Node3D:
	var walk: Node = from
	var depth: int = 0
	while walk != null and depth < 4:
		var body := walk as CharacterBody3D
		if body != null:
			return body
		walk = walk.get_parent()
		depth += 1
	return null


# --- the position channel ----------------------------------------------------


func _bind_channel() -> void:
	var api := multiplayer as SceneMultiplayer
	if api != null and not api.peer_packet.is_connected(_on_peer_packet):
		api.peer_packet.connect(_on_peer_packet)


## Send when the body actually moved or turned, or when the keepalive is due. Standing
## still costs two packets a second instead of eighteen.
func _send_move() -> void:
	if not replicate_transform or not NetAvatarLink.transport_ready(get_tree()):
		return
	var stand: Dictionary = _local_stand()
	if stand.is_empty():
		return
	var feet: Vector3 = stand[&"feet"]
	var yaw: float = stand[&"yaw"]
	var moved: bool = _sent_feet.distance_to(feet) > move_epsilon
	var turned: bool = absf(angle_difference(_sent_yaw, yaw)) > turn_epsilon
	if not moved and not turned and _idle_clock < idle_seconds:
		return
	_sent_feet = feet
	_sent_yaw = yaw
	_idle_clock = 0.0
	var payload: Array = [KIND_MOVE, _local_id, feet, yaw, _names.get(_local_id, "")]
	var api := multiplayer as SceneMultiplayer
	var target: int = 0 if _local_id == NetColors.HOST_ID else NetColors.HOST_ID
	api.send_bytes(
		_encode(payload), target, MultiplayerPeer.TRANSFER_MODE_UNRELIABLE_ORDERED, CHANNEL
	)


## Everything on the raw channel arrives here, including whatever anybody else is using
## it for. The magic word is checked before a single byte is deserialised.
func _on_peer_packet(id: int, packet: PackedByteArray) -> void:
	if packet.size() < 8 or packet.decode_u32(0) != MAGIC:
		return
	var payload: Variant = bytes_to_var(packet.slice(4))
	if typeof(payload) != TYPE_ARRAY:
		return
	var fields: Array = payload
	if not _well_formed(fields):
		return
	var origin: int = int(fields[1])
	if _local_id == NetColors.HOST_ID and id != NetColors.HOST_ID:
		if not _accept_from(id):
			return
		# The sender's real id, over whatever the packet claimed. A client cannot move
		# another player's avatar, and a client that lies is simply corrected.
		origin = id
		fields[1] = origin
		var api := multiplayer as SceneMultiplayer
		api.send_bytes(
			_encode(fields), 0, MultiplayerPeer.TRANSFER_MODE_UNRELIABLE_ORDERED, CHANNEL
		)
	if origin == _local_id or origin <= 0 or _published.has(origin):
		return
	var avatar: PlayerAvatar = _ensure_peer(origin)
	if avatar != null:
		avatar.set_target(fields[2], float(fields[3]))


## Every field of an arriving packet, checked for type before anything is read out of
## it. This is the only place in `res://net/avatar/` that parses bytes off a socket, and
## a malformed array reaching `PlayerAvatar.set_target` would be a crash rather than a
## dropped frame. Non-finite floats are refused too: one NaN in a position propagates
## into the interpolator and the avatar never comes back.
static func _well_formed(fields: Array) -> bool:
	if fields.size() != PAYLOAD_SIZE or typeof(fields[0]) != TYPE_INT:
		return false
	if int(fields[0]) != KIND_MOVE or typeof(fields[1]) != TYPE_INT:
		return false
	if typeof(fields[2]) != TYPE_VECTOR3 or typeof(fields[3]) != TYPE_FLOAT:
		return false
	if typeof(fields[4]) != TYPE_STRING:
		return false
	return (fields[2] as Vector3).is_finite() and is_finite(fields[3])


## Rate limit, on the host, per peer. A client that sends faster than it should is
## throttled rather than trusted, and the floor is half the nominal period so a fast
## clock or a bunched pair is not punished.
func _accept_from(peer_id: int) -> bool:
	var now: int = Time.get_ticks_msec()
	var floor_ms: int = int(500.0 / maxf(push_hz, 1.0))
	if now - int(_last_rx.get(peer_id, -100000)) < floor_ms:
		return false
	_last_rx[peer_id] = now
	return true


## Magic word, then the variant. Objects are never encoded and `bytes_to_var` is called
## without allowing them, so a hostile packet cannot instantiate anything.
static func _encode(payload: Array) -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(4)
	bytes.encode_u32(0, MAGIC)
	bytes.append_array(var_to_bytes(payload))
	return bytes


# --- dot on dot --------------------------------------------------------------


## Whose dot is your dot on. The radius is ANGULAR, so the interaction feels identical
## at ten metres and at a hundred, and it widens once you are on somebody so the name
## does not strobe at the edge.
func _update_hover() -> void:
	_sync_dots()
	var found: int = 0
	var best: float = INF
	var camera: Camera3D = _resolve_eye()
	if _aim_valid and camera != null:
		var range_m: float = camera.global_position.distance_to(_aim_point)
		var radius: float = clampf(range_m * hover_angle, hover_min, hover_max)
		if _hovered != 0:
			radius *= hover_release
		for id: int in _cursors:
			if id == _local_id:
				continue
			var cursor := _cursors[id] as LaserCursor
			if not cursor.is_live():
				continue
			var gap: float = _aim_point.distance_to(cursor.point())
			if gap < radius and gap < best:
				best = gap
				found = id
	if found == _hovered:
		return
	_hovered = found
	for id: int in _cursors:
		(_cursors[id] as LaserCursor).set_hovered(id == found)
