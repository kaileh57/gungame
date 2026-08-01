class_name MovementLink
extends Node
## The movement bench's one wire. Every RPC this demo has lives here, on a node at a
## fixed path under the demo root — `Movement/Link` — because an RPC only routes when the
## node path is identical on every machine.
##
## THE BENCH IS A SHARED TABLE, NOT A MATCH. Everything the console owns is replicated,
## anybody may turn anything, and a knob is applied on the machine that turned it BEFORE
## it is sent — so the person turning it feels no latency at all, which is the whole
## point of a tuning tool. The host is the ordering relay rather than the decider: it
## re-broadcasts in the order it received, so four people arguing over the gravity slider
## converge on one number instead of four. The re-broadcast comes back to the person who
## sent it and is a no-op, because writing a property to the value it already holds
## changes nothing and the console only flashes a control that actually moved.
##
## LAP TIMES ARE NOT LIKE THAT. A score is a claim, so the host keeps the ledger: a
## client sends the seconds it measured and the host decides whether that is that peer's
## best and tells everybody. Nobody can post for anybody else — the host reads the
## sender id off the transport and ignores what the packet says.
##
## SINGLE-PLAYER IS THE SAME CODE. `NetAvatarLink.is_networked()` is false, no RPC is
## ever sent, the console is driven straight and the board shows your own times. There is
## no second path through this file for the offline case.
##
## `NetGame` is reached through `NetAvatarLink`, which resolves it by node path. This
## file must never name the autoload: `build_movement.gd` compiles it under `--script`,
## where autoloads do not exist. That is trap 21 in STATUS and it has bitten before.

## Seconds between snapshot requests, and how many a joining client will make before it
## gives up and runs on the values it was baked with.
const ASK_SECONDS: float = 1.2
const MAX_ASKS: int = 4

@export var console_path: NodePath = NodePath("../Console")
@export var timer_path: NodePath = NodePath("../SpeedLoop/RunTimer")
@export var board_path: NodePath = NodePath("../Scoreboard")

var _console: MovementConsole = null
var _timer: RunTimer = null
var _board: MovementScoreboard = null
var _synced: bool = false
var _asks: int = 0
var _since_ask: float = ASK_SECONDS


func _ready() -> void:
	_console = get_node_or_null(console_path) as MovementConsole
	_timer = get_node_or_null(timer_path) as RunTimer
	_board = get_node_or_null(board_path) as MovementScoreboard
	if _console == null or _timer == null or _board == null:
		push_error("MovementLink: console, timer or board did not resolve. Re-run the builder.")
		set_process(false)
		return
	_console.knob_actuated.connect(_on_knob_actuated)
	_timer.run_started.connect(_on_run_started)
	_timer.lap_finished.connect(_on_lap_finished)
	# The host and a solo player are already in step with themselves. Only a client has
	# anything to ask for, and it asks because the host may have been turning knobs for
	# a whole transition before this scene existed here.
	_synced = not _live() or _is_host()
	set_process(not _synced)


## A joining client's snapshot request, retried. Reliable RPCs do not get lost, but the
## host's own `Link` node may not have existed yet when the first one was sent — the host
## routes first and lands first, so this is belt and braces rather than the usual case.
func _process(delta: float) -> void:
	if _synced or not _live() or _is_host():
		set_process(false)
		return
	_since_ask += delta
	if _since_ask < ASK_SECONDS:
		return
	_since_ask = 0.0
	_asks += 1
	if _asks > MAX_ASKS:
		set_process(false)
		push_warning("MovementLink: the host never answered; the bench is on its baked values.")
		return
	_rq_state.rpc_id(NetPlayer.HOST_ID)


# --- local events ------------------------------------------------------------


## A knob was turned ON THIS MACHINE. It has already been applied locally; this only
## tells everybody else. `MovementConsole` never emits this for a value that arrived over
## the wire, so there is no echo to break.
func _on_knob_actuated(id: StringName, value: float) -> void:
	if not _live():
		return
	if _is_host():
		_rs_knob.rpc(String(id), value)
		return
	_rq_knob.rpc_id(NetPlayer.HOST_ID, String(id), value)


func _on_run_started() -> void:
	_board.set_running(true)


## Your lap closed. The board takes it immediately — your own time is yours to know —
## and the host is told so the ledger and everybody else's mast agree.
func _on_lap_finished(lap: float, best: float) -> void:
	_board.set_running(false)
	_board.set_last(lap)
	_board.post(_me(), best)
	if not _live():
		return
	if _is_host():
		_relay_lap(_me(), best)
		return
	_rq_lap.rpc_id(NetPlayer.HOST_ID, best)


# --- the wire ----------------------------------------------------------------

## Client -> host: I turned this knob. The host applies it and passes it on.
@rpc("any_peer", "reliable")
func _rq_knob(id: String, value: float) -> void:
	if not _is_host() or _console == null:
		return
	_console.receive(StringName(id), value)
	_rs_knob.rpc(id, value)


## Host -> everyone: this is the value now.
@rpc("authority", "reliable")
func _rs_knob(id: String, value: float) -> void:
	if _console != null:
		_console.receive(StringName(id), value)


## Client -> host: I have just arrived, tell me where every knob is and who has run.
@rpc("any_peer", "reliable")
func _rq_state() -> void:
	if not _is_host() or _console == null or _board == null:
		return
	var who: int = multiplayer.get_remote_sender_id()
	if who <= 0:
		return
	var snap: Dictionary = _console.snapshot()
	var held: Dictionary = _board.bests()
	var peers := PackedInt32Array()
	var times := PackedFloat32Array()
	for id: int in held:
		peers.append(id)
		times.append(float(held[id]))
	_rs_state.rpc_id(who, snap[&"ids"], snap[&"values"], peers, times)


## Host -> one client: the whole table. The console builds the id list with the preset
## first, so a preset that resets everything under it lands before the values it would
## otherwise have overwritten.
@rpc("authority", "reliable")
func _rs_state(
	ids: PackedStringArray,
	values: PackedFloat32Array,
	peers: PackedInt32Array,
	times: PackedFloat32Array
) -> void:
	_synced = true
	set_process(false)
	if _console != null:
		for i: int in mini(ids.size(), values.size()):
			_console.receive(StringName(ids[i]), values[i])
	if _board == null:
		return
	for i: int in mini(peers.size(), times.size()):
		_board.post(peers[i], times[i])


## Client -> host: I ran this. The sender id comes off the transport, never off the
## packet, so nobody can post a time under somebody else's name.
@rpc("any_peer", "reliable")
func _rq_lap(seconds: float) -> void:
	if not _is_host():
		return
	var who: int = multiplayer.get_remote_sender_id()
	if who > 0:
		_relay_lap(who, seconds)


## Host -> everyone: this peer's best is now this.
@rpc("authority", "reliable")
func _rs_lap(peer_id: int, seconds: float) -> void:
	if _board != null:
		_board.post(peer_id, seconds)


# --- helpers -----------------------------------------------------------------


## Host side. Refuse anything that is not an improvement rather than telling three other
## machines about a time that changes nothing on any of them.
func _relay_lap(peer_id: int, seconds: float) -> void:
	if _board == null or not is_finite(seconds) or seconds <= 0.0:
		return
	var held: float = float(_board.bests().get(peer_id, 0.0))
	if held > 0.0 and held <= seconds:
		return
	_board.post(peer_id, seconds)
	if _live():
		_rs_lap.rpc(peer_id, seconds)


## True when there is a real session with a transport that will actually carry a packet.
func _live() -> bool:
	var tree: SceneTree = get_tree()
	return NetAvatarLink.is_networked(tree) and NetAvatarLink.transport_ready(tree)


## True on the host, and true with no session at all.
func _is_host() -> bool:
	return NetAvatarLink.is_host(get_tree())


func _me() -> int:
	return NetAvatarLink.local_id(get_tree())
