extends Node
## Autoload `NetGame`. Every question about multiplayer is asked here.
##
## FOUR PLAYERS, HOST AUTHORITATIVE, HOST OWNS THE SCENE. The host runs all the
## game logic — enemies, targets, scoring, the physics of record — and the three
## guests send intent and receive state. The host also decides which demo everyone
## is in; a client never routes itself. Those two sentences are the whole model
## and every rule below falls out of them.
##
## SINGLE PLAYER IS THE DEFAULT AND IS UNTOUCHED. With no session open,
## `is_networked()` is false, `is_authority()` is true, `players()` is a list of
## one — you — and nothing in this file does anything at all. A demo that gates
## its logic on `is_authority()` runs exactly as it does today with the network
## code absent, which is the point: no demo may require a network to run.
##
## JOINING IS ONLY POSSIBLE WHILE THE HOST IS ON THE TITLE SCREEN. The moment the
## host routes into a demo, `lobby_closed` fires and a late arrival is refused
## with a sentence saying so. Coming back to the title reopens it.
##
## READ `res://net/README.md` BEFORE BUILDING ON ANY OF THIS. It is short, it has
## the worked examples, and it is the contract the other systems are written to.

## The host is on the title screen and will accept guests.
signal lobby_opened
## The host has left the title screen, or has stopped hosting. No more joins.
signal lobby_closed
## A player was ACCEPTED into the roster. Fires on every machine, host included,
## and for every player including the local one, so an avatar spawner can be
## written once. Never fires for a peer that was refused.
signal peer_joined(id: int)
## A player left the roster. Their `NetPlayer` is already gone from `players()`.
signal peer_left(id: int)
## The roster changed in any way — someone joined, left, or was renamed. UI that
## draws the player list should redraw on this and ignore the two above.
signal players_changed
## `join()` did not work, and this is the whole sentence to show the person who
## typed the address.
signal join_failed(reason: String)
## This machine is in. Fires on the CLIENT only; the host is in from `host()`.
signal joined
## A live session ended for a reason nobody here chose — currently only the host
## going away. Clients are routed back to the title screen automatically.
signal disconnected(reason: String)
## The router has been asked and has answered. `ok` false is normal and does not
## stop anybody hosting; `message` is a fragment for a sentence, not a sentence.
signal upnp_finished(ok: bool, message: String)

enum State {
	## No session. Single-player. The default and the resting state.
	OFF,
	## Resolving a hostname the person typed. Briefly, and never blocking.
	RESOLVING,
	## The socket is open and we are waiting to be let in.
	CONNECTING,
	## In somebody else's game. Not the authority.
	CLIENT,
	## Running the game everyone else is in. The authority.
	HOSTING,
}

## Four. Every list, every colour set and every piece of UI in this project is
## designed around exactly four, and the roster refuses the fifth by name. The
## number itself lives on `NetPlayer`, beside the four colours it has to match.
const MAX_PLAYERS: int = NetPlayer.MAX_PLAYERS

## Steam's first user port, unremarkable and unlikely to be in use. Anything from
## 1024 to 65535 works; the host and the guests only have to agree.
const DEFAULT_PORT: int = 27015

## Bumped whenever the wire format below changes in a way an older build would
## misread. A mismatch is caught in the handshake and reported in words, which is
## much better than two builds silently disagreeing about a packet.
const PROTOCOL_VERSION: int = 1

## The ENet socket accepts more transport connections than there are player slots,
## on purpose: a fifth person has to get far enough in to be TOLD the game is
## full. Shutting the door at the socket would only give them "connection failed".
const SOCKET_BACKLOG: int = MAX_PLAYERS + 4

## Seconds `join` waits for the far end to answer at all.
const CONNECT_SECONDS: float = 10.0

## Seconds `join` waits, after the socket is up, to be let into the roster. Short,
## because by then the host is one round trip away.
const HANDSHAKE_SECONDS: float = 5.0

## Seconds the host lets a connected peer sit without asking to join before it
## drops them. Anything that connects and then says nothing is not this game.
const PENDING_SECONDS: float = 6.0

## Seconds between telling a peer why it is refused and closing the socket on it.
## ENet flushes queued reliable packets on a graceful disconnect, so this is belt
## and braces — but "connection failed" with no reason is the worst thing
## multiplayer can say to anybody and it is worth a quarter second to never say it.
const REFUSAL_LINGER: float = 0.25

## Seconds between aim broadcasts: 20 Hz. Fast enough that a laser dot tracks a
## turning head, slow enough that four players cost nothing.
const AIM_PERIOD: float = 0.05

## Seconds between sweeps of the host's pending-peer list.
const SWEEP_PERIOD: float = 1.0

const CONFIG_PATH: String = "user://net.cfg"
const CONFIG_SECTION: String = "net"

## What this machine calls itself. Assign it freely — it is sanitised, clamped to
## `NetPlayer.MAX_NAME`, saved to `user://net.cfg`, and pushed into the roster if
## a session is already open. Defaults to the OS account name.
##
## Deliberately NOT a `GameSettings` key: that store is quality and controls, it
## validates against a fixed key table, and a previous pass destroyed
## `settings.cfg` by writing to it carelessly. A name lives in its own file.
var username: String:
	get:
		return _username
	set(value):
		_apply_username(value)

## One of `NetUpnp.State`. Only ever anything but IDLE on a host.
var upnp_state: int = NetUpnp.State.IDLE

## A fragment about what the router did, for UI: "UDP 27015 forwarded",
## "UPnP is switched off in the router". Lower case, no full stop.
var upnp_message: String = ""

## The WAN address the router reported, when UPnP worked. THIS is the address to
## read out to somebody joining over the internet. Empty when UPnP did not run or
## did not work.
var external_address: String = ""

## This machine's address on the local network, filled in by `host()`. The address
## to read out to somebody in the same building.
var lan_address: String = ""

## The port the current session is on.
var active_port: int = DEFAULT_PORT

var _username: String = ""
var _state: int = State.OFF
var _peer: ENetMultiplayerPeer = null
## Who is in, in both the wire form and the materialised form. See `NetRoster`.
var _roster: NetRoster = null
## peer_id -> the second it connected. Host only, and only until it handshakes.
var _pending: Dictionary = {}
## "Me", for the whole life of the process, networked or not. `local_player()`
## always returns this exact object so anything may cache it.
## Built at DECLARATION, not in `_ready()`. The docstring on `local_player()`
## promises this is never null, and anything reached before this node's `_ready()`
## — an autoload later in the list, a scene a tool instances under its own root —
## would otherwise get a null and hand a `[null]` roster to callers. `range` did
## exactly that: "Invalid access to property 'peer_id' on a base object of type
## 'Nil'". The username is loaded in `_ready()` and assigned onto this object.
var _local: NetPlayer = NetPlayer.new()
var _upnp: NetUpnp = null
## `/root/SceneRouter`, looked up rather than named, so nothing in `tools/` that
## compiles this file falls over on a missing autoload.
var _router: Node = null
## Which demo the local machine is in, tracked from the router's `route_started`
## rather than read after the fact, so the lobby shuts the instant the host
## commits to leaving the title screen instead of half a second later.
var _scene_id: String = ""
var _lobby_open: bool = false
var _want_host: String = ""
var _want_port: int = DEFAULT_PORT
## True once the socket is up, so a timeout can tell "nobody there" from "there,
## but it never let me in".
var _transport_up: bool = false
var _resolve_id: int = -1
var _deadline: Timer = null
var _aim_timer: Timer = null
var _sweep_timer: Timer = null


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_process(false)
	_roster = NetRoster.new()
	_local.peer_id = NetPlayer.HOST_ID
	_local.slot = 0
	_local.is_local = true
	_username = _load_username()
	_local.username = _username
	_upnp = NetUpnp.new()
	_upnp.finished.connect(_on_upnp_finished)
	_build_timers()
	_bind_multiplayer()
	_bind_router()
	# Deferred so the first frame — and the title screen on it — exists before a
	# socket does. Hosting from inside `_ready` would open the lobby before the
	# router has told anybody which scene we are on.
	_apply_cmdline.call_deferred()


func _exit_tree() -> void:
	if _upnp != null:
		_upnp.shutdown()
	if _peer != null:
		_peer.close()
		_peer = null


## Only ever running while a hostname is being resolved.
func _process(_delta: float) -> void:
	if _state != State.RESOLVING or _resolve_id < 0:
		return
	var status: int = IP.get_resolve_item_status(_resolve_id)
	if status == IP.RESOLVER_STATUS_WAITING:
		return
	var address: String = ""
	if status == IP.RESOLVER_STATUS_DONE:
		address = IP.get_resolve_item_address(_resolve_id)
	IP.erase_resolve_item(_resolve_id)
	_resolve_id = -1
	set_process(false)
	if address.is_empty():
		var wanted: String = _want_host
		_teardown()
		_fail_join(
			"Could not look up '%s'. Check the spelling, or use the host's IP address." % wanted
		)
		return
	_connect_to(address, _want_port)


## Open a game other people can join, and ask the router to forward the port.
##
## Returns OK, or the error `ENetMultiplayerPeer.create_server` gave — almost
## always `ERR_ALREADY_IN_USE`, meaning something else already has that port.
## UPnP runs on a thread and never gates this: a host with no UPnP is still a
## host, it is just only reachable on the LAN.
func host(port: int = DEFAULT_PORT) -> Error:
	if _state != State.OFF:
		push_error("NetGame: already in a session. Call leave() first.")
		return ERR_ALREADY_IN_USE
	var peer := ENetMultiplayerPeer.new()
	var err: Error = peer.create_server(port, SOCKET_BACKLOG)
	if err != OK:
		peer.close()
		return err
	_peer = peer
	multiplayer.multiplayer_peer = peer
	_state = State.HOSTING
	active_port = port
	lan_address = _lan_address()
	_roster.entries = [{"id": NetPlayer.HOST_ID, "slot": 0, "name": _username}]
	_publish_roster()
	_refresh_lobby()
	_upnp.forward(port)
	upnp_state = _upnp.state
	upnp_message = _upnp.message
	_announce("hosting opened")
	return OK


## Join a game. `address` may be bare or carry its own port — "192.168.1.5",
## "192.168.1.5:27015", "[::1]:27015", "localhost", or a hostname. An address
## with a port in it wins over the `port` argument.
##
## Asynchronous, always. Success arrives as `joined`; every failure arrives as
## `join_failed` with a sentence fit to show a person. It never blocks and it
## never throws.
func join(address: String, port: int = DEFAULT_PORT) -> void:
	if _state != State.OFF:
		_fail_join("You are already in a session. Leave that one first.")
		return
	var parsed: Dictionary = NetAddress.parse(address, port)
	if not bool(parsed["ok"]):
		_fail_join(String(parsed["error"]))
		return
	_want_host = String(parsed["host"])
	_want_port = int(parsed["port"])
	_transport_up = false
	if not bool(parsed["needs_lookup"]):
		_connect_to(_want_host, _want_port)
		return
	_state = State.RESOLVING
	_resolve_id = IP.resolve_hostname_queue_item(_want_host, IP.TYPE_ANY)
	set_process(true)
	_arm_deadline(CONNECT_SECONDS)


## End the session. Safe to call at any time, including when there is none.
##
## A CLIENT is also routed back to the title screen — a client in a demo with no
## authority is a puppet with nobody holding it. A HOST stays where it is: it was
## the authority before and still is, so its demo becomes single-player.
func leave() -> void:
	if _state == State.OFF:
		return
	var was_client: bool = _state == State.CLIENT
	if _state == State.HOSTING:
		_upnp.release()
		upnp_state = _upnp.state
		upnp_message = ""
		external_address = ""
	_teardown()
	if was_client:
		_route_home()


func is_host() -> bool:
	return _state == State.HOSTING


## False in pure single-player. True from the moment `host()` succeeds, and from
## the moment a client is let into the roster.
func is_networked() -> bool:
	return _state == State.HOSTING or _state == State.CLIENT


## THE ONE EVERY DEMO NEEDS. True on the host, and true always when there is no
## session, so the same line of code gates a wave spawner in single-player and in
## a four-player game. If this is false you are a client: send intent, draw what
## you are told, and decide nothing.
func is_authority() -> bool:
	return not is_networked() or is_host()


## True while this machine is hosting AND is on the title screen, which is the
## only time anybody may join. Watch `lobby_opened` / `lobby_closed` instead of
## polling it.
func is_lobby_open() -> bool:
	return _state == State.HOSTING and _scene_id.is_empty()


## Everyone in the session, ordered by slot, host first.
##
## In single-player this is a list of ONE — you — not an empty list, so a
## nameplate, a laser renderer or a scoreboard written against this loop works
## solo and at four players without an `is_networked()` branch anywhere in it.
func players() -> Array[NetPlayer]:
	var list: Array[NetPlayer] = []
	if not is_networked():
		list.append(_local)
		return list
	return _roster.sorted()


## The person sitting at this machine. NEVER null, and the same object for the
## whole run of the process, so it is safe to cache in a `@onready`.
func local_player() -> NetPlayer:
	return _local


## One player by peer id, or null if there is no such player.
func player(id: int) -> NetPlayer:
	if _roster.players.has(id):
		return _roster.players[id]
	if not is_networked() and id == NetPlayer.HOST_ID:
		return _local
	return null


func max_players() -> int:
	return MAX_PLAYERS


## This machine's peer id: 1 on the host, and 1 in single-player, which keeps
## `peer_id() == NetPlayer.HOST_ID` meaning "I am the authority" everywhere.
func peer_id() -> int:
	if is_networked():
		return multiplayer.get_unique_id()
	return NetPlayer.HOST_ID


## Send everyone, including the host, to a demo. Empty id means the title screen.
## HOST ONLY; clients follow automatically and need call nothing.
##
## A courtesy wrapper: `SceneRouter.go()` on the host does exactly the same, since
## the router announces every route it starts. Either is fine.
func host_goto(demo_id: String) -> void:
	if _state == State.CLIENT:
		push_error("NetGame: host_goto is the host's to call. Clients follow.")
		return
	_router_go(demo_id)


## Where this machine's laser pointer is landing, in world space. Call it once a
## frame from whatever owns the aim ray; pass `valid` false when the ray hit
## nothing worth pointing at and no dot is drawn for you on anyone's screen.
## Replicated at 20 Hz; in single-player it is a local write and costs nothing.
func set_local_aim(point: Vector3, valid: bool) -> void:
	_local.aim_point = point
	_local.aim_valid = valid


## One line for a debug overlay or a lobby footer. Never empty.
func status_line() -> String:
	var text: String = "single player"
	var target: String = NetAddress.format(_want_host, _want_port)
	if _state == State.RESOLVING:
		text = "looking up %s" % _want_host
	elif _state == State.CONNECTING:
		text = "connecting to %s" % target
	elif _state == State.CLIENT:
		text = "guest of %s  %d/%d" % [target, _roster.players.size(), MAX_PLAYERS]
	elif _state == State.HOSTING:
		text = (
			"hosting %s:%d  %d/%d  lobby %s  upnp %s"
			% [
				lan_address,
				active_port,
				_roster.players.size(),
				MAX_PLAYERS,
				"open" if is_lobby_open() else "shut",
				upnp_message if not upnp_message.is_empty() else "idle",
			]
		)
	return text


# --- the handshake ----------------------------------------------------------
#
# A client that has connected at the socket level is NOT a player yet. It asks,
# and the host answers with the roster or with a refusal and a reason. Everything
# that can go wrong is a sentence somebody can act on.

## Client -> host. The only RPC a peer may send before it is in the roster.
@rpc("any_peer", "reliable")
func _rq_join(protocol: int, wanted: String) -> void:
	var id: int = multiplayer.get_remote_sender_id()
	_pending.erase(id)
	var refusal: String = _join_refusal(id, protocol)
	if not refusal.is_empty():
		_refuse(id, refusal)
		return
	_roster.add(id, _sanitise(wanted))
	_publish_roster()


## Why this peer may not come in, or empty if it may. One chain rather than early
## returns so the ORDER of the tests reads: who you are, what build you are,
## whether the door is open, whether there is room.
func _join_refusal(id: int, protocol: int) -> String:
	var reason: String = ""
	if _state != State.HOSTING:
		reason = "That machine is not hosting a game."
	elif id <= 0:
		reason = "That join request arrived with no sender."
	elif protocol != PROTOCOL_VERSION:
		reason = (
			(
				"The host speaks network protocol %d and you speak %d. "
				+ "One of you needs the other's build of the game."
			)
			% [PROTOCOL_VERSION, protocol]
		)
	elif not is_lobby_open():
		reason = (
			"That game has already started. You can only join while the host is "
			+ "on the title screen."
		)
	elif _roster.index_of(id) >= 0:
		reason = "You are already in that game."
	elif _roster.full():
		reason = "That game is full. It already has %d players." % MAX_PLAYERS
	return reason


## Host -> one client. Say why, then close the door a moment later.
func _refuse(id: int, reason: String) -> void:
	rpc_id(id, &"_rs_refuse", reason)
	var linger: SceneTreeTimer = get_tree().create_timer(REFUSAL_LINGER, true, false, true)
	linger.timeout.connect(_drop_peer.bind(id))


@rpc("authority", "reliable")
func _rs_refuse(reason: String) -> void:
	if _state != State.CONNECTING and _state != State.RESOLVING:
		return
	_teardown()
	_fail_join(reason)


## Host -> everyone. The whole roster every time: it is at most four entries and
## a full snapshot cannot drift the way a stream of deltas can.
@rpc("authority", "reliable")
func _rs_roster(entries: Array) -> void:
	if _state == State.HOSTING:
		return
	var mine: int = multiplayer.get_unique_id()
	var welcomed: bool = _state == State.CONNECTING and NetRoster.has_id(entries, mine)
	if welcomed:
		_state = State.CLIENT
		_transport_up = true
		_disarm_deadline()
	_apply_roster(entries)
	if welcomed:
		joined.emit()


## Host -> everyone. The host has committed to a scene; go there.
@rpc("authority", "reliable")
func _rs_goto(demo_id: String) -> void:
	if _state != State.CLIENT or _router == null:
		return
	_router.call(&"follow_host", demo_id)


## Client -> host. Unreliable and ordered: a dropped aim packet is replaced 50 ms
## later by a fresher one, and re-sending a stale position would be worse.
@rpc("any_peer", "unreliable_ordered")
func _rq_aim(point: Vector3, valid: bool) -> void:
	if _state != State.HOSTING:
		return
	var who: NetPlayer = _roster.players.get(multiplayer.get_remote_sender_id(), null)
	if who == null:
		return
	who.aim_point = point
	who.aim_valid = valid
	rpc(&"_rs_aim", who.peer_id, point, valid)


## Host -> everyone. Aim goes through the host rather than peer to peer so that
## nobody can move somebody else's dot, and so the host's copy is the copy.
@rpc("authority", "unreliable_ordered")
func _rs_aim(id: int, point: Vector3, valid: bool) -> void:
	if id == _local.peer_id:
		return
	var who: NetPlayer = _roster.players.get(id, null)
	if who == null:
		return
	who.aim_point = point
	who.aim_valid = valid


# --- the roster -------------------------------------------------------------


## Materialise `entries` and announce the difference. Host and clients both come
## through here, so `peer_joined` / `peer_left` mean the same thing on every
## machine: somebody entered or left the roster.
func _apply_roster(entries: Array) -> void:
	# Keyed off the PEER rather than off `_state`, because a client materialises
	# its first roster in the same call that promotes it out of CONNECTING, and
	# getting this wrong would mark the host's NetPlayer as the local one.
	var mine: int = multiplayer.get_unique_id() if _peer != null else NetPlayer.HOST_ID
	var moved: Dictionary = _roster.apply(entries, mine, _local)
	var gone: PackedInt32Array = moved["gone"]
	var added: PackedInt32Array = moved["added"]
	for id: int in gone:
		peer_left.emit(id)
	for id: int in added:
		peer_joined.emit(id)
	players_changed.emit()
	if not added.is_empty() or not gone.is_empty():
		_announce(_roster_line())


## Host only: apply the roster locally and push it to everyone else.
func _publish_roster() -> void:
	_apply_roster(_roster.entries)
	if _state == State.HOSTING and _peer != null:
		rpc(&"_rs_roster", _roster.entries)


# --- transport --------------------------------------------------------------


func _connect_to(ip: String, port: int) -> void:
	var peer := ENetMultiplayerPeer.new()
	var err: Error = peer.create_client(ip, port)
	if err != OK:
		peer.close()
		_fail_join("Could not open a socket to %s (error %d)." % [ip, err])
		return
	_peer = peer
	multiplayer.multiplayer_peer = peer
	_state = State.CONNECTING
	active_port = port
	_arm_deadline(CONNECT_SECONDS)


func _on_connected_to_server() -> void:
	_transport_up = true
	_arm_deadline(HANDSHAKE_SECONDS)
	rpc_id(NetPlayer.HOST_ID, &"_rq_join", PROTOCOL_VERSION, _username)


func _on_connection_failed() -> void:
	var target: String = NetAddress.format(_want_host, _want_port)
	_teardown()
	_fail_join(
		(
			(
				"Nothing answered at %s. Check the address and the port, that the host "
				+ "is hosting, and that their router lets the port through."
			)
			% target
		)
	)


func _on_server_disconnected() -> void:
	if _state == State.CONNECTING:
		var target: String = NetAddress.format(_want_host, _want_port)
		_teardown()
		_fail_join("%s closed the connection without saying why." % target)
		return
	if _state != State.CLIENT:
		return
	_teardown()
	_announce("host left")
	disconnected.emit("The host left. You are back in single player.")
	_route_home()


func _on_peer_connected(id: int) -> void:
	if _state == State.HOSTING:
		_pending[id] = _now()


func _on_peer_disconnected(id: int) -> void:
	_pending.erase(id)
	if _state != State.HOSTING:
		return
	if _roster.remove(id):
		_publish_roster()


## Drop a peer that was refused, or one that connected and then never asked to
## join. Both are the same act from here.
func _drop_peer(id: int) -> void:
	if _state != State.HOSTING or _peer == null:
		return
	_peer.disconnect_peer(id)


func _on_sweep() -> void:
	if _state != State.HOSTING:
		return
	var now: float = _now()
	for id: int in _pending.keys():
		if now - float(_pending[id]) > PENDING_SECONDS:
			_pending.erase(id)
			_drop_peer(id)


func _on_deadline() -> void:
	if _state != State.RESOLVING and _state != State.CONNECTING:
		return
	var target: String = NetAddress.format(_want_host, _want_port)
	var reason: String = ""
	if _state == State.RESOLVING:
		reason = "Looking up '%s' took too long. Use the host's IP address." % _want_host
	elif _transport_up:
		reason = (
			(
				"%s answered but never let you into the lobby. "
				+ "It is probably running a different build of the game."
			)
			% target
		)
	else:
		reason = (
			"%s did not answer in %d seconds. Check the address, and that the host is hosting."
			% [target, int(CONNECT_SECONDS)]
		)
	_teardown()
	_fail_join(reason)


func _on_aim_tick() -> void:
	if not is_networked() or _roster.players.size() < 2:
		return
	if _state == State.HOSTING:
		rpc(&"_rs_aim", NetPlayer.HOST_ID, _local.aim_point, _local.aim_valid)
	else:
		rpc_id(NetPlayer.HOST_ID, &"_rq_aim", _local.aim_point, _local.aim_valid)


## Put everything back the way single-player found it. The one place a session
## ends, whoever ended it and for whatever reason.
func _teardown() -> void:
	_disarm_deadline()
	if _resolve_id >= 0:
		IP.erase_resolve_item(_resolve_id)
		_resolve_id = -1
	set_process(false)
	_transport_up = false
	_pending.clear()
	_roster.entries.clear()
	_state = State.OFF
	if _peer != null:
		if multiplayer.multiplayer_peer == _peer:
			multiplayer.multiplayer_peer = null
		_peer.close()
		_peer = null
	_local.peer_id = NetPlayer.HOST_ID
	_local.slot = 0
	_local.aim_valid = false
	# Through the roster rather than around it, so anything that spawned an avatar
	# on `peer_joined` gets its matching `peer_left` and can tear the avatar down.
	_apply_roster([])
	_refresh_lobby()


# --- the router -------------------------------------------------------------
#
# `SceneRouter` stays the only thing that writes `get_tree().paused` and
# `Input.mouse_mode`, and the only thing that swaps a scene. All this adds is who
# is allowed to ASK it to.


func _bind_router() -> void:
	_router = get_node_or_null(^"/root/SceneRouter")
	if _router == null:
		push_warning("NetGame: no SceneRouter autoload — the host cannot own the scene.")
		return
	_scene_id = String(_router.get(&"current_demo"))
	if _router.has_method(&"set_network"):
		_router.call(&"set_network", self)
	if _router.has_signal(&"route_started"):
		_router.connect(&"route_started", _on_route_started)


## Every route the local machine starts comes through here, including the ones a
## client started by being told to. On the host it is the announcement; everywhere
## it is how `_scene_id` — and therefore the lobby door — stays honest.
func _on_route_started(demo_id: String) -> void:
	_scene_id = demo_id
	if _state == State.HOSTING and _peer != null:
		rpc(&"_rs_goto", demo_id)
	_refresh_lobby()


func _router_go(demo_id: String) -> void:
	if _router == null:
		return
	if demo_id.is_empty():
		_router.call(&"back_to_menu")
	else:
		_router.call(&"go", demo_id)


## Send a client that has lost its host back to the title screen.
func _route_home() -> void:
	if _router == null or _scene_id.is_empty():
		return
	_router.call(&"follow_host", "")


func _refresh_lobby() -> void:
	var open: bool = is_lobby_open()
	if open == _lobby_open:
		return
	_lobby_open = open
	if open:
		lobby_opened.emit()
	else:
		lobby_closed.emit()


# --- plumbing ---------------------------------------------------------------


## `--host`, `--host=<port>`, `--join=<address>`, `--name=<username>`, read off
## the command line at boot.
##
## Not a test hook — a shipped option, and the only way to put two instances in a
## session without clicking through UI. Both argument vectors are searched because
## Godot only routes to `get_cmdline_user_args` what came after a bare `--`, and
## nobody types that from memory.
##
##     godot --path <project> -- --host
##     godot --path <project> -- --join=localhost --name=GUEST
func _apply_cmdline() -> void:
	var args := PackedStringArray(OS.get_cmdline_user_args())
	args.append_array(OS.get_cmdline_args())
	var address: String = ""
	var port: int = DEFAULT_PORT
	var wants_host: bool = false
	for arg: String in args:
		if arg == "--host":
			wants_host = true
		elif arg.begins_with("--host="):
			wants_host = true
			port = arg.substr(7).to_int()
		elif arg.begins_with("--join="):
			address = arg.substr(7)
		elif arg.begins_with("--name="):
			username = arg.substr(7)
	if wants_host:
		host(port)
	elif not address.is_empty():
		join(address, port)


## One line to stdout on every session event.
##
## A multiplayer failure usually happens on somebody else's machine, so the log is
## often the only record of what went wrong — and four players cannot generate
## enough of these to drown anything.
func _announce(what: String) -> void:
	print("NetGame: %s | %s" % [status_line(), what])


func _roster_line() -> String:
	var names := PackedStringArray()
	for who: NetPlayer in players():
		names.append("%d %s %s" % [who.peer_id, who.slot_name(), who.display_name()])
	return " / ".join(names)


## Every `join_failed` goes through here so the reason is logged as well as shown.
func _fail_join(reason: String) -> void:
	_announce("join failed: " + reason)
	join_failed.emit(reason)


func _bind_multiplayer() -> void:
	var api: MultiplayerAPI = multiplayer
	api.peer_connected.connect(_on_peer_connected)
	api.peer_disconnected.connect(_on_peer_disconnected)
	api.connected_to_server.connect(_on_connected_to_server)
	api.connection_failed.connect(_on_connection_failed)
	api.server_disconnected.connect(_on_server_disconnected)


## Every timer here runs while the tree is paused. A pause menu must not stall the
## socket, or the host looks dead to everybody else the moment it opens one.
func _build_timers() -> void:
	_deadline = _make_timer(CONNECT_SECONDS, true, _on_deadline)
	_aim_timer = _make_timer(AIM_PERIOD, false, _on_aim_tick)
	_aim_timer.start()
	_sweep_timer = _make_timer(SWEEP_PERIOD, false, _on_sweep)
	_sweep_timer.start()


func _make_timer(seconds: float, one_shot: bool, handler: Callable) -> Timer:
	var timer := Timer.new()
	timer.wait_time = seconds
	timer.one_shot = one_shot
	timer.autostart = false
	timer.process_mode = Node.PROCESS_MODE_ALWAYS
	timer.timeout.connect(handler)
	add_child(timer)
	return timer


func _arm_deadline(seconds: float) -> void:
	_deadline.stop()
	_deadline.wait_time = seconds
	_deadline.start()


func _disarm_deadline() -> void:
	_deadline.stop()


func _on_upnp_finished(ok: bool, message: String) -> void:
	upnp_state = _upnp.state
	upnp_message = message
	external_address = _upnp.external_ip
	_announce("upnp %s: %s" % ["ok" if ok else "no", message])
	upnp_finished.emit(ok, message)


func _apply_username(value: String) -> void:
	var cleaned: String = _sanitise(value)
	if cleaned.is_empty():
		cleaned = _default_username()
	if cleaned == _username:
		return
	_username = cleaned
	# Null only if something assigns this before the autoload's `_ready`, which
	# nothing in the project does — but a crash in a property setter at boot is a
	# very bad way to find that out.
	if _local != null:
		_local.username = cleaned
	_save_username()
	if _state == State.HOSTING and _roster.rename(NetPlayer.HOST_ID, cleaned):
		_publish_roster()


func _load_username() -> String:
	var cfg := ConfigFile.new()
	if cfg.load(CONFIG_PATH) != OK:
		return _default_username()
	var stored: String = _sanitise(String(cfg.get_value(CONFIG_SECTION, "username", "")))
	if stored.is_empty():
		return _default_username()
	return stored


func _save_username() -> void:
	var cfg := ConfigFile.new()
	# A missing file is the normal case on a first run and is not worth reporting.
	cfg.load(CONFIG_PATH)
	cfg.set_value(CONFIG_SECTION, "username", _username)
	var err: Error = cfg.save(CONFIG_PATH)
	if err != OK:
		push_warning("NetGame: could not write %s (error %d)." % [CONFIG_PATH, err])


static func _default_username() -> String:
	var guess: String = _sanitise(OS.get_environment("USERNAME"))
	if guess.is_empty():
		guess = _sanitise(OS.get_environment("USER"))
	if guess.is_empty():
		guess = "SCAV"
	return guess


## Strip control characters and clamp the length. A name arrives from another
## machine, so it is not trusted: a newline or a hundred characters in a Label3D
## is somebody else's UI broken from across the internet.
static func _sanitise(raw: String) -> String:
	var out: String = ""
	for i: int in raw.length():
		if raw.unicode_at(i) >= 32:
			out += raw[i]
	out = out.strip_edges()
	if out.length() > NetPlayer.MAX_NAME:
		out = out.substr(0, NetPlayer.MAX_NAME).strip_edges()
	return out


## The best guess at this machine's address on the local network, preferring the
## private ranges a home network actually uses over a VPN or a virtual adapter.
static func _lan_address() -> String:
	var best: String = "127.0.0.1"
	var best_rank: int = 0
	for address: String in IP.get_local_addresses():
		var rank: int = _address_rank(address)
		if rank > best_rank:
			best_rank = rank
			best = address
	return best


static func _address_rank(address: String) -> int:
	if address.contains(":") or address.begins_with("127.") or address.begins_with("169.254."):
		return 0
	if address.begins_with("192.168."):
		return 3
	if address.begins_with("10.") or address.begins_with("172."):
		return 2
	return 1


static func _now() -> float:
	return float(Time.get_ticks_msec()) * 0.001
