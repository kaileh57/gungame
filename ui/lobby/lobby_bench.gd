class_name LobbyBench
extends Node3D
## The multiplayer half of the title screen, as objects on the workbench.
##
## Everything about a session is a thing you can look at here. The JOIN console is a
## steel box whose lid springs up into a screen. The HOST plate lies beside it and is
## also the H key. The roster is four sockets along the back of the bench with a
## coloured tag standing in each one that is taken. A locked demo board wears a bar
## across it. And every event — a game created, a guest arriving, a guest leaving —
## drops a stencilled sign through your view that tumbles away.
##
## THIS FILE OWNS THE POLICY. `JoinConsole` knows how to open and how to take typing;
## it does not know what an address means. `LobbySign` knows how to fall. This is the
## one place that talks to `NetGame`, and the one place that decides what any of it
## means, which is what keeps the networking out of six files.
##
## JOINING IS ONLY POSSIBLE FROM HERE, and only while the host is still on this
## screen — `NetGame` enforces that and says so in words when somebody is late. The
## refusal is shown on the console itself and the whole sentence goes to the bench
## readout, because a sentence that does not fit on a 46 cm screen is not a reason to
## truncate the reason.
##
## SINGLE PLAYER IS UNTOUCHED. With no session, the roster is one tag and three empty
## sockets, the demo board is unlocked, nothing is ever sent, and every plate works
## exactly as it did before any of this existed.

## Metres the lock bar falls from when the board is locked to a client.
const LOCK_DROP: float = 0.37
const LOCK_SECONDS: float = 0.34

var _menu: Node3D = null
var _eye: Camera3D = null
var _console: JoinConsole = null
var _dots: LobbyDots = null
var _slots: Array[Node3D] = []
## peer id -> the name and colour they had while they were here, so a departure can
## be announced by name after `NetGame` has already forgotten them.
var _names: Dictionary = {}
var _colors: Dictionary = {}
## Whatever was last typed into the address field, kept so a failed join does not
## cost you the address you nearly got right.
var _address: String = ""
## False until this machine is properly in a session. The roster arrives as one lump
## on join and would otherwise announce three arrivals at once.
var _announce: bool = false
var _locked: bool = false
var _lock_rest: float = 0.0
var _lock_tween: Tween = null

@onready var _host_plate: DiegeticControl = $Host
@onready var _lock: Node3D = $LockBar
@onready var _roster: Node3D = $Roster


func _ready() -> void:
	_console = $Console
	_dots = $Dots
	for i: int in NetPlayer.MAX_PLAYERS:
		_slots.append(_roster.get_node_or_null(NodePath("Slot%d" % i)) as Node3D)
	_lock_rest = _lock.position.y
	_lock.visible = false
	_host_plate.pressed.connect(_on_host_pressed)
	_console.submitted.connect(_on_console_submitted)
	_console.shut_down.connect(_on_console_shut)
	_bind_net()
	_refresh_roster()
	_refresh_host_plate()


## H hosts. It is the one keyboard shortcut on the title screen, it is printed on the
## plate that does the same thing, and it is refused while the console has the
## keyboard so that typing an address containing an h does not open a game.
func _unhandled_input(event: InputEvent) -> void:
	if _console != null and _console.is_typing():
		return
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo:
		return
	if key.keycode != KEY_H and key.physical_keycode != KEY_H:
		return
	get_viewport().set_input_as_handled()
	_take_host_action()


## Hand over the eye the signs fall across and the hands the laser dot borrows.
## Called by `MainMenu` once, after both exist.
##
## THE SESSION CAN BE OLDER THAN THIS SCREEN, so it is reconciled here rather than in
## `_ready`. Two real cases: `--host` on the command line opens the lobby from a
## deferred call at boot, before anything has instanced the menu; and a host returning
## to the title from a demo reopens it in `route_started`, which fires BEFORE the
## scene swap. Both emit `lobby_opened` at nobody. Reconciling in `bind` rather than
## in `_ready` is deliberate — the toast needs an eye to fall across, and `_ready`
## runs a step before there is one.
func bind(menu: Node3D, eye: Camera3D, hands: DiegeticInteractor) -> void:
	_menu = menu
	_eye = eye
	if _dots != null:
		_dots.bind(eye, hands)
	if NetGame.is_networked():
		_announce = true
	if NetGame.is_lobby_open():
		_open_lobby("LOBBY OPEN")


## What the bench readout says about one of this file's controls, or `""` when the
## control is not one of ours and the menu should answer for itself.
func blurb_for(control: DiegeticControl) -> String:
	if control == null:
		return ""
	match String(control.control_id):
		"join":
			return _join_blurb()
		"join_go":
			return "CONFIRM WHAT IS ON THE SCREEN."
		"host":
			return _host_blurb()
	return ""


## Drop a bar across the demo board, or take it off. The plates go dark on their own
## — this is the part that says WHY, from across the room, without reading anything.
func set_locked(locked: bool) -> void:
	if locked == _locked:
		return
	_locked = locked
	if _lock_tween != null and _lock_tween.is_valid():
		_lock_tween.kill()
	if not locked:
		_lock.visible = false
		return
	_lock.visible = true
	_lock.position.y = _lock_rest + LOCK_DROP
	_lock_tween = create_tween()
	_lock_tween.set_trans(Tween.TRANS_BOUNCE)
	_lock_tween.set_ease(Tween.EASE_OUT)
	_lock_tween.tween_property(_lock, ^"position:y", _lock_rest, LOCK_SECONDS)


## Throw a sign through the view. Public so anything else on this screen can use the
## same toast rather than inventing a second one.
func toast(text: String, color: Color) -> void:
	LobbySign.drop(self, _eye, text, color)


# --- the session -------------------------------------------------------------


func _bind_net() -> void:
	NetGame.lobby_opened.connect(_on_lobby_opened)
	NetGame.lobby_closed.connect(_refresh_host_plate)
	NetGame.peer_joined.connect(_on_peer_joined)
	NetGame.peer_left.connect(_on_peer_left)
	NetGame.players_changed.connect(_refresh_roster)
	NetGame.joined.connect(_on_joined)
	NetGame.join_failed.connect(_on_join_failed)
	NetGame.disconnected.connect(_on_disconnected)
	NetGame.upnp_finished.connect(_on_upnp_finished)


## The HOST plate and the H key are the same action, and which action that is depends
## on where you already are: open a game, close the one you opened, or walk out of
## somebody else's.
func _take_host_action() -> void:
	# Mid-connect is neither in nor out. `NetGame.host()` refuses a session that is
	# already opening, and the only thing this file knows how to say about a refusal
	# is "the port is in use" — which would be a lie about what just happened, on the
	# screen of somebody who is three seconds into waiting for a join.
	if _console != null and _console.mode() == JoinConsole.Mode.WAITING:
		return
	if NetGame.is_networked():
		NetGame.leave()
		_console.shut()
		toast("LEFT THE GAME", UiStyle.TEXT_DIM)
		_say("")
		_refresh_host_plate()
		_refresh_roster()
		return
	var err: Error = NetGame.host()
	if err == OK:
		return
	var reason: String = (
		"COULD NOT OPEN UDP %d (ERROR %d). SOMETHING ELSE IS ALREADY ON THAT PORT."
		% [NetGame.DEFAULT_PORT, err]
	)
	_say(reason)
	_console.open_address(_address)
	_console.set_status("THE PORT IS ALREADY IN USE.", true)


func _on_lobby_opened() -> void:
	_open_lobby("GAME CREATED")


## The door is open. Say so with a sign, put your address on the console so you can
## read it out, and let the roster and the host plate catch up.
##
## `headline` differs by how we got here: pressing H on a live title screen CREATED
## the game, while arriving on a title screen that is already hosting only found the
## door open. Both are true and neither may claim the other.
func _open_lobby(headline: String) -> void:
	_announce = true
	toast(headline, NetPlayer.SLOT_COLORS[0])
	_show_address()
	_refresh_host_plate()
	_refresh_roster()


func _on_peer_joined(id: int) -> void:
	if not _announce or id == NetGame.peer_id():
		return
	var who: NetPlayer = NetGame.player(id)
	if who == null:
		return
	toast("%s JOINED" % who.display_name(), who.color())
	_console.burst()


func _on_peer_left(id: int) -> void:
	# `_teardown` drops the whole roster on the way out of a session, and those are
	# not departures anybody wants announced. By then `is_networked` is already false.
	if not _announce or not NetGame.is_networked() or id == NetGame.peer_id():
		return
	var gone: String = String(_names.get(id, "SOMEBODY"))
	toast("%s LEFT" % gone, Color(_colors.get(id, UiStyle.TEXT_DIM)))


func _on_joined() -> void:
	_announce = true
	_console.shut()
	toast("YOU ARE IN", NetGame.local_player().color())
	_say("YOU ARE IN THE GAME. THE HOST PICKS WHERE EVERYONE GOES.")
	_refresh_host_plate()


func _on_join_failed(reason: String) -> void:
	_console.open_address(_address)
	_console.set_status(reason, true)
	_say(reason)
	_refresh_host_plate()


func _on_disconnected(reason: String) -> void:
	_announce = false
	toast("HOST LEFT", UiStyle.WARN)
	_say(reason)
	_refresh_host_plate()
	_refresh_roster()


func _on_upnp_finished(_ok: bool, _message: String) -> void:
	if _console.mode() == JoinConsole.Mode.READOUT:
		_show_address()


func _on_host_pressed() -> void:
	_take_host_action()


## WHILE YOU ARE HOSTING THIS BOX IS YOUR ADDRESS BOARD and nothing else, so it is
## put straight back up. Shutting it — a stray click on the case, an Escape — used to
## throw away the one thing a guest needs to reach you, with no way at all to get it
## back short of stopping hosting and starting again. Reopening is safe: `open_readout`
## does not emit `shut_down`, so this cannot come back round on itself.
func _on_console_shut() -> void:
	_say("")
	if NetGame.is_host():
		_show_address()


## The two beats of the join flow. Confirming the address does NOT open a socket: it
## turns the box into a name field, because the username travels inside the join
## handshake and therefore has to exist before the socket does.
func _on_console_submitted(field: int, text: String) -> void:
	if field == JoinConsole.Mode.ADDRESS:
		_address = text
		_console.open_name(NetGame.username)
		return
	if not text.strip_edges().is_empty():
		NetGame.username = text
	_console.set_waiting(_address)
	_console.set_status("CONNECTING...", false)
	_say("CONNECTING TO %s." % _address)
	NetGame.join(_address)


# --- what the bench shows ----------------------------------------------------


func _show_address() -> void:
	var body: String = "LAN  %s" % NetAddress.format(NetGame.lan_address, NetGame.active_port)
	if not NetGame.external_address.is_empty():
		body += "\nNET  %s" % NetAddress.format(NetGame.external_address, NetGame.active_port)
	_console.open_readout(body, _upnp_note())


## Say plainly whether people outside the building can get in. A router that refused
## is normal and is not an error; a host who does not know it is a host with three
## friends who cannot connect.
func _upnp_note() -> String:
	if NetGame.upnp_state == NetUpnp.State.MAPPED:
		return "PORT FORWARDED. ANYONE CAN JOIN."
	if NetGame.upnp_state == NetUpnp.State.WORKING:
		return "ASKING THE ROUTER..."
	return "LAN ONLY UNLESS YOU FORWARD UDP %d YOURSELF." % NetGame.active_port


func _refresh_host_plate() -> void:
	if NetGame.is_host():
		_host_plate.set_label("STOP HOSTING")
		return
	if NetGame.is_networked():
		_host_plate.set_label("LEAVE GAME")
		return
	_host_plate.set_label("HOST  (H)")


func _refresh_roster() -> void:
	var by_slot: Dictionary = {}
	for who: NetPlayer in NetGame.players():
		by_slot[who.slot] = who
		_names[who.peer_id] = who.display_name()
		_colors[who.peer_id] = who.color()
	for i: int in _slots.size():
		_dress_slot(i, by_slot.get(i, null) as NetPlayer)


func _dress_slot(index: int, who: NetPlayer) -> void:
	var slot: Node3D = _slots[index]
	if slot == null:
		return
	var filled: bool = who != null
	var tag := slot.get_node_or_null(^"Tag") as Node3D
	if tag != null:
		tag.visible = filled
	var free := slot.get_node_or_null(^"Free") as Node3D
	if free != null:
		free.visible = not filled
	var label := slot.get_node_or_null(^"Tag/Name") as Label3D
	if label != null:
		label.text = "" if not filled else who.display_name()
	var mark := slot.get_node_or_null(^"Tag/Mark") as Label3D
	if mark == null:
		return
	mark.text = "" if not filled else _mark_for(who)
	mark.visible = filled and not mark.text.is_empty()


## The host is marked because the host decides everything; you are marked because
## four tags in one colour scheme are four tags you have to work out.
static func _mark_for(who: NetPlayer) -> String:
	if who.is_host():
		return "HOST"
	return "YOU" if who.is_local else ""


func _join_blurb() -> String:
	if NetGame.is_networked():
		return "YOU ARE ALREADY IN A GAME. LEAVE IT BEFORE JOINING ANOTHER."
	return "OPEN IT AND TYPE THE HOST'S ADDRESS — AN IP, OR AN IP AND A PORT."


func _host_blurb() -> String:
	var room: int = NetPlayer.MAX_PLAYERS
	if NetGame.is_host():
		return "YOU ARE HOSTING. %d PLAYERS, WHILE YOU STAY ON THIS SCREEN." % room
	if NetGame.is_networked():
		return "YOU ARE A GUEST. THIS WALKS OUT OF THE GAME."
	return "OPEN A GAME OF YOUR OWN. THE H KEY DOES THE SAME THING."


func _say(text: String) -> void:
	if _menu != null and _menu.has_method(&"say"):
		_menu.call(&"say", text)
