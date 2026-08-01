class_name ArenaNet
extends Node
## The arena, with four people in it. One node, `/root/Arena/Net`, on every machine.
##
## THE SHAPE OF IT, in one paragraph. The host runs the whole compound: the
## spawners, the director, every brain, every trigger pull and every point of
## damage. It writes what is standing in the room into a snapshot fifteen times a
## second and a client stands up a puppet for each row of it. A client decides
## nothing — it sends three kinds of intent (I worked this control, I hit that body,
## I fired) and draws what it is told. Single player is the same code with the
## network switched off: `NetGame.is_networked()` is false, this node idles, and
## `ArenaController` is the demo it has always been.
##
## WHY THE RPCs LIVE HERE AND NOT ON THE STATION OR THE DIRECTOR. Godot routes an
## RPC by node path, so anything an RPC is declared on has to sit at an identical
## path on all four machines. This node is created by `ArenaController._ready` with
## a fixed name, from a scene every machine loaded out of the same `.tscn`, so its
## path is identical by construction. The station, the spawners and the director are
## reached FROM here.
##
## WHAT IS CLIENT-SIDE AND DELIBERATELY SO. A client's own gun resolves its own
## hits against its own puppets: the hit mark, the damage number and the flinch are
## immediate, because a 60 ms round trip on a trigger pull is the one latency a
## shooter cannot hide. That is PREDICTION and not authority — the same hit is
## reported to the host, the host re-resolves it against the real body with the real
## zone multipliers, and the host's snapshot decides whether anything actually died.
## The two agree because it is the same damage number and the same body; when they
## do not, the host wins one tick later. Cosmetics — tracers, muzzle flash, sparks,
## the laser dots — are local everywhere and never sent.
##
## THE DESK IS THE ONE THING EVERYBODY CAN TOUCH. A client actuates a knob locally
## for the feel of it and tells the host, the host actuates the real one, and the
## host's desk state comes back as the correction. Two people shooting the same dial
## in the same tick is the case that needs it: both step it once locally, one of
## them loses to the control's own debounce on the host, and the broadcast puts both
## screens back on the same detent.

## Name this node takes under the demo root. Load bearing: it is half of the RPC
## path, and it has to be spelled the same on all four machines.
const NODE_NAME: StringName = &"Net"
## Population snapshots a second. Fifteen is where a walking body's dead reckoning
## stops being visible; the puppets steer between snapshots rather than lerping to
## them, so this is a correction rate and not a frame rate.
const SNAPSHOT_HZ: float = 15.0
## Roster broadcasts a second — everyone's health, and who is down.
const SQUAD_HZ: float = 4.0
## Seconds between unprompted re-sends of the desk state, on top of the send that
## every actuation causes. Cheap insurance against a lost packet leaving one
## person's dials reading something nobody else's do.
const DESK_HEARTBEAT: float = 1.0
## Seconds a client waits between knocks before the host has answered.
const ENTER_RETRY: float = 0.75
## Ceiling on a single reported hit. A shotgun's worth of pellets arrives as
## separate reports, and the hardest single round in the game is nowhere near this.
## It is a sanity bound on a malformed or malicious packet, not an anti-cheat.
const MAX_REPORTED_DAMAGE: float = 900.0
## Metres a reported impact point may be from the body it claims to be on. The
## largest thing in the bestiary is a few metres across and a client's body has
## moved on this machine since the shot; six is generous on purpose.
const HIT_SLACK: float = 6.0
## Shot reports a second one player may send. An auto shotgun at its fastest is
## under twelve; this bounds a stuck trigger rather than a real weapon.
const SHOT_RATE: float = 24.0
## Metres a tracer is drawn along when the shooter's aim ray hit nothing.
const MISS_REACH: float = 90.0
## Metres per second a replicated tracer flies. `Weapon` draws its own at the
## round's real speed; this is the middle of that range.
const TRACER_SPEED: float = 620.0

var _controller: ArenaController = null
var _director: ArenaDirector = null
var _station: ArenaStation = null
var _player: PlayerController = null
var _health: PlayerHealth = null
var _hud: CombatHud = null
var _bodies: ArenaNetBodies = ArenaNetBodies.new()
var _people: ArenaNetPlayers = ArenaNetPlayers.new()
## Peers that have said their own copy of this node exists. Nothing is sent to
## anybody else: an RPC to a machine still loading the scene is an error on their
## console and a packet nobody could have used.
var _ready_peers: Dictionary = {}
## What the squad packet last said, so a death can be announced from the change
## rather than from a message of its own.
var _squad_alive: Dictionary = {}
var _snapshot_clock: float = 0.0
var _squad_clock: float = 0.0
var _desk_clock: float = 0.0
var _enter_clock: float = 0.0
var _rx_clock: float = 0.0
var _shot_budget: float = SHOT_RATE
var _greeted: bool = false
var _desk_dirty: bool = true
## Gate mask as last broadcast, so a door opening marks the desk dirty by itself.
var _gates_sent: int = 0


## Stand the node up under the demo root. Called from `ArenaController._ready` on
## every machine, networked or not — an idle copy costs one `_physics_process` that
## returns on its first line, and having it always exist means nothing has to test
## whether it is there.
static func attach(controller: ArenaController) -> ArenaNet:
	var net := ArenaNet.new()
	net.name = String(NODE_NAME)
	controller.add_child(net)
	return net


func _ready() -> void:
	# The network does not stop because somebody opened their own pause menu. This
	# is the same reason `NetPresence` runs always, and it is not a licence to touch
	# `get_tree().paused` — `SceneRouter` still owns that.
	process_mode = Node.PROCESS_MODE_ALWAYS
	NetGame.players_changed.connect(_on_players_changed)
	NetGame.peer_left.connect(_on_peer_left)


func _exit_tree() -> void:
	# The marks hang on `NetPresence`'s avatars, which outlive this demo. Left on,
	# they would be player-faction rows in whatever the host routes to next.
	_people.drop_all()
	_bodies.clear()
	DebugHUD.clear_note(&"arena_net")


## Everything this node drives, handed over by the controller that owns it all.
func bind(
	controller: ArenaController,
	director: ArenaDirector,
	station: ArenaStation,
	spawners: Array[EnemySpawner],
	player: PlayerController,
	health: PlayerHealth,
	hud: CombatHud
) -> void:
	_controller = controller
	_director = director
	_station = station
	_player = player
	_health = health
	_hud = hud
	_bodies.bind(spawners)
	_people.bind(director, health)
	_people.player_hurt.connect(_on_player_hurt)
	_people.player_down.connect(_on_player_down)
	_people.player_up.connect(_on_player_up)
	if not NetGame.is_networked():
		return
	if NetGame.is_authority():
		_desk_dirty = true
		return
	# A client's own health is the host's to write. Everything else about the node
	# stays exactly as single player left it, including the feedback it drives.
	if _health != null:
		_health.network_driven = true


func _physics_process(delta: float) -> void:
	if not NetGame.is_networked():
		return
	_shot_budget = minf(_shot_budget + SHOT_RATE * delta, SHOT_RATE)
	_rx_clock += delta
	if not NetGame.is_authority():
		_tick_client(delta)
		return
	_tick_host(delta)


# --- the host ----------------------------------------------------------------


func _tick_host(delta: float) -> void:
	# The ledger every frame — death clocks and regeneration are seconds of real
	# time and cannot be quantised to a send rate. The ROSTER four times a second:
	# reconciling it walks `NetGame.players()`, which builds an array, and an avatar
	# arriving a quarter of a second late is a quarter of a second nobody can see.
	_people.tick(delta)
	_snapshot_clock += delta
	if _snapshot_clock >= 1.0 / SNAPSHOT_HZ:
		_snapshot_clock = 0.0
		_send_population()
	_squad_clock += delta
	if _squad_clock >= 1.0 / SQUAD_HZ:
		_squad_clock = 0.0
		_people.refresh(NetGame.peer_id())
		_send_squad()
	_desk_clock += delta
	# The gates are not a control anybody throws — they open when a wave is dealt
	# and shut when the last body is through — so their state is watched rather
	# than reported. One integer compare a frame, against a packet that would
	# otherwise be up to a second late on a door a wave is walking out of.
	var gates: int = _controller.gate_mask()
	if gates != _gates_sent:
		_gates_sent = gates
		_desk_dirty = true
	if _desk_dirty or _desk_clock >= DESK_HEARTBEAT:
		_desk_clock = 0.0
		_desk_dirty = false
		_send_desk()


func _send_population() -> void:
	if _ready_peers.is_empty():
		_bodies.events()
		return
	var snap: Dictionary = _bodies.snapshot()
	var events: Dictionary = _bodies.events()
	var quiet: bool = (
		(events["d"] as PackedInt32Array).is_empty()
		and (events["g"] as PackedInt32Array).is_empty()
	)
	for id: int in _ready_peers:
		_rx_snap.rpc_id(id, snap)
		if not quiet:
			_rx_events.rpc_id(id, events)


## Everyone's health, including the host's own, read off the one node that owns it
## on this machine. Four bytes and four ids; it is the cheapest packet here.
func _send_squad() -> void:
	var ids := PackedInt32Array()
	var hp := PackedByteArray()
	for who: NetPlayer in NetGame.players():
		ids.append(who.peer_id)
		hp.append(_health_byte(who.peer_id))
	_apply_squad(ids, hp)
	for id: int in _ready_peers:
		_rx_squad.rpc_id(id, ids, hp)


func _send_desk() -> void:
	if _station == null:
		return
	var d: Dictionary = {
		"v": _station.state(),
		"c": _controller.capacity(),
		"s": _director.summary(),
		"a": _controller.alive_count(),
		"g": _controller.gate_mask(),
	}
	for id: int in _ready_peers:
		_rx_desk.rpc_id(id, d)


func _health_byte(peer_id: int) -> int:
	var fraction: float = 1.0
	var alive: bool = true
	if peer_id == NetGame.peer_id():
		if _health != null:
			fraction = _health.health_fraction()
			alive = not _health.is_dead()
	else:
		fraction = _people.fraction_of(peer_id)
		alive = _people.is_alive(peer_id)
	if not alive:
		return 0
	return clampi(int(fraction * 254.0) + 1, 1, 255)


# --- the client --------------------------------------------------------------


func _tick_client(delta: float) -> void:
	if _greeted:
		return
	_enter_clock -= delta
	if _enter_clock > 0.0:
		return
	_enter_clock = ENTER_RETRY
	_rq_enter.rpc_id(NetPlayer.HOST_ID)


# --- what the demo reports ---------------------------------------------------


## A body entered play on the host. Gives it the id every client will know it by.
func note_spawn(actor: EnemyActor) -> void:
	if NetGame.is_networked() and NetGame.is_authority():
		_bodies.assign(actor)


## A body left play. On the host that is the end of its id; on a client it is this
## machine's own corpse timer recycling a puppet the host is still holding.
func note_despawn(actor: EnemyActor) -> void:
	if not NetGame.is_networked():
		return
	if NetGame.is_authority():
		_bodies.release(actor)
		return
	_bodies.forget(actor)


## A body went down on the host. The bearing comes off its own target, which is
## where `EnemyActor._die` reads the direction it collapses along from.
func note_death(actor: EnemyActor) -> void:
	if not NetGame.is_networked() or not NetGame.is_authority():
		return
	var from: Vector3 = actor.global_position
	var target: AITarget = actor.target()
	if target != null:
		from += target.hit_direction() * 4.0
	_bodies.note_death(actor, from)


## A body pulled a trigger on the host.
func note_fire(actor: EnemyActor, aim: Vector3) -> void:
	if NetGame.is_networked() and NetGame.is_authority():
		_bodies.note_fire(actor, aim)


## The desk was worked on this machine. On the host that is already the truth and
## only has to be published; on a client it is a request.
func report_control(control: DiegeticControl, at: Vector3, power: float, walk_up: bool) -> void:
	if not NetGame.is_networked() or control == null:
		return
	if NetGame.is_authority():
		_desk_dirty = true
		return
	_rq_desk.rpc_id(NetPlayer.HOST_ID, String(control.control_id), at, power, walk_up)


## This machine's own round landed on a body. On the host it has already been
## applied by the weapon itself; on a client this is the report that makes it real.
func report_hit(actor: EnemyActor, damage: float, at: Vector3, dir: Vector3, crit: float) -> void:
	if not NetGame.is_networked() or NetGame.is_authority():
		return
	var id: int = ArenaNetBodies.net_id_of(actor)
	if id <= 0:
		return
	_rq_hit.rpc_id(NetPlayer.HOST_ID, id, damage, at, dir, crit)


## This machine's own gun fired. `to` is where the aim ray landed, which every
## other machine draws a tracer to from this player's avatar, and which the host
## also files as a gunshot the compound can hear.
func report_shot(to: Vector3, energy: float) -> void:
	if not NetGame.is_networked() or _shot_budget < 1.0:
		return
	_shot_budget -= 1.0
	if not NetGame.is_authority():
		_rq_shot.rpc_id(NetPlayer.HOST_ID, to, energy)
		return
	_relay_shot(NetGame.peer_id(), to)


## One line of who is standing, for the debug overlay. Read off the squad packet
## rather than off the ledger, so the host and a client are quoting the same numbers
## and any disagreement between the two shows up on both screens at once.
func squad_line() -> String:
	var parts := PackedStringArray()
	for who: NetPlayer in NetGame.players():
		var hp: int = int(_squad_alive.get(who.peer_id, 255))
		parts.append("%s %s" % [who.slot_name(), "DOWN" if hp == 0 else str(roundi(hp / 2.54))])
	return "  ·  ".join(parts)


# --- host <- client, intent --------------------------------------------------

@rpc("any_peer", "call_remote", "reliable")
func _rq_enter() -> void:
	if not NetGame.is_authority():
		return
	var who: int = multiplayer.get_remote_sender_id()
	if NetGame.player(who) == null:
		return
	_ready_peers[who] = true
	_desk_dirty = true
	_send_squad()


@rpc("any_peer", "call_remote", "reliable")
func _rq_desk(control_id: String, at: Vector3, power: float, walk_up: bool) -> void:
	if not NetGame.is_authority() or _station == null:
		return
	if not _ready_peers.has(multiplayer.get_remote_sender_id()) or not at.is_finite():
		return
	var control: DiegeticControl = _station.control_by_id(StringName(control_id))
	if control == null:
		return
	# The same two entry points a local player has, so a client's shot at a dial is
	# refused by the same debounce and the same `enabled` flag as anybody else's.
	if walk_up:
		control.interact()
	else:
		control.shoot(at, clampf(power, 0.0, 1.0))
	_desk_dirty = true


@rpc("any_peer", "call_remote", "reliable")
func _rq_hit(id: int, damage: float, at: Vector3, dir: Vector3, crit: float) -> void:
	if not NetGame.is_authority():
		return
	if not _ready_peers.has(multiplayer.get_remote_sender_id()):
		return
	if not at.is_finite() or not dir.is_finite() or dir.length_squared() < 1.0e-6:
		return
	var actor: EnemyActor = _bodies.actor_of(id)
	if actor == null or not actor.alive:
		return
	if actor.global_position.distance_to(at) > HIT_SLACK:
		return
	# The same call the local weapon makes, so the host resolves the zone off the
	# impact point against the real rig rather than trusting the shooter's word for
	# where they hit.
	actor.apply_bullet_damage(
		clampf(damage, 0.0, MAX_REPORTED_DAMAGE),
		at,
		Vector3.UP,
		dir.normalized(),
		&"",
		clampf(crit, 1.0, 4.0)
	)


@rpc("any_peer", "call_remote", "unreliable")
func _rq_shot(to: Vector3, energy: float) -> void:
	if not NetGame.is_authority() or not to.is_finite():
		return
	var who: int = multiplayer.get_remote_sender_id()
	if not _ready_peers.has(who):
		return
	var from: Vector3 = _head_of(who)
	# Every gun in the compound is heard by the AI, whoever is holding it. Without
	# this a client could empty a magazine into a wall and nothing would look up.
	if from != Vector3.ZERO:
		AINoiseBus.emit_gunshot(from, clampf(energy, 0.0, 40000.0), Factions.PLAYER, -1)
	_relay_shot(who, to)


# --- client <- host, state ---------------------------------------------------

@rpc("authority", "call_remote", "unreliable_ordered", 1)
func _rx_snap(d: Dictionary) -> void:
	if NetGame.is_authority():
		return
	_greeted = true
	_bodies.apply_snapshot(d, minf(_rx_clock, 1.0))
	_rx_clock = 0.0


@rpc("authority", "call_remote", "reliable")
func _rx_events(d: Dictionary) -> void:
	if not NetGame.is_authority():
		_bodies.apply_events(d)


@rpc("authority", "call_remote", "reliable")
func _rx_desk(d: Dictionary) -> void:
	if NetGame.is_authority() or _station == null:
		return
	_greeted = true
	_station.set_count_ceiling(int(d.get("c", 1)))
	_station.apply_state(d.get("v", PackedInt32Array()))
	_station.set_status(String(d.get("s", "")))
	_station.set_roster(int(d.get("a", 0)), int(d.get("c", 1)))
	_controller.apply_gates(int(d.get("g", 0)))


@rpc("authority", "call_remote", "unreliable_ordered", 1)
func _rx_squad(ids: PackedInt32Array, hp: PackedByteArray) -> void:
	if not NetGame.is_authority():
		_apply_squad(ids, hp)


## The host's answer to a round that reached you: what came off, where from, and
## what you have left. `down` and `up` are the same message with the state change
## the owner's `PlayerHealth` has to run.
@rpc("authority", "call_remote", "reliable")
func _rx_health(health: float, took: float, from_position: Vector3, alive: bool) -> void:
	if NetGame.is_authority() or _health == null:
		return
	_health.sync_health(health, took, from_position, alive)


@rpc("authority", "call_remote", "unreliable")
func _rx_shot(peer_id: int, to: Vector3) -> void:
	if not NetGame.is_authority():
		_draw_shot(peer_id, to)


# --- shared ------------------------------------------------------------------


## Everyone sees everyone else's fire, including the host's own. Cosmetic, so it is
## drawn on each machine rather than replicated as an effect.
func _relay_shot(peer_id: int, to: Vector3) -> void:
	_draw_shot(peer_id, to)
	for id: int in _ready_peers:
		if id != peer_id:
			_rx_shot.rpc_id(id, peer_id, to)


func _draw_shot(peer_id: int, to: Vector3) -> void:
	if peer_id == NetGame.peer_id():
		return
	var from: Vector3 = _head_of(peer_id)
	if from == Vector3.ZERO:
		return
	VfxService.spawn_tracer(from, to, TRACER_SPEED)


## Where a player's gun is, near enough for a tracer to leave from: their avatar's
## head. `PlayerAvatar` owns the number.
func _head_of(peer_id: int) -> Vector3:
	if peer_id == NetGame.peer_id():
		return Vector3.ZERO if _player == null else _player.global_position + Vector3(0, 1.6, 0)
	var presence: NetPresence = NetPresence.instance()
	if presence == null:
		return Vector3.ZERO
	var avatar: PlayerAvatar = presence.avatar_of(peer_id)
	return Vector3.ZERO if avatar == null else avatar.head_point()


## The squad packet, applied the same way on every machine including the one that
## sent it. Hiding a downed player's capsule is what makes a death readable from
## across the compound, and the banner comes off the change rather than off a
## message of its own.
func _apply_squad(ids: PackedInt32Array, hp: PackedByteArray) -> void:
	if ids.size() != hp.size():
		return
	var presence: NetPresence = NetPresence.instance()
	for k: int in ids.size():
		var id: int = ids[k]
		var alive: bool = hp[k] > 0
		var was: bool = bool(_squad_alive.get(id, 255) != 0)
		_squad_alive[id] = hp[k]
		if id == NetGame.peer_id() or presence == null:
			continue
		# The plate fades through the documented seam; the capsule itself is hidden
		# outright, because `set_dim` only reaches the translucent shells and a
		# corpse standing to attention in FULL presence reads as a live player.
		presence.publish(id, {&"visible": alive})
		var avatar: PlayerAvatar = presence.avatar_of(id)
		if avatar != null:
			avatar.visible = alive
		if alive == was or _hud == null:
			continue
		var who: NetPlayer = NetGame.player(id)
		var name_of: String = "SOMEBODY" if who == null else who.display_name().to_upper()
		_hud.banner("%s IS %s" % [name_of, "DOWN" if not alive else "UP"], 1.4)
	_note_squad()


## The overlay line, written four times a second off the packet everybody has,
## rather than once a frame off a roster walk that allocates an array to do it.
func _note_squad() -> void:
	var role: String = "host" if NetGame.is_authority() else "guest"
	DebugHUD.note(&"arena_net", "arena net  %s  %s" % [role, squad_line()])


func _on_player_hurt(peer_id: int, taken: float, from_position: Vector3, health: float) -> void:
	_rx_health.rpc_id(peer_id, health, taken, from_position, _people.is_alive(peer_id))


func _on_player_down(peer_id: int, from_position: Vector3) -> void:
	_rx_health.rpc_id(peer_id, 0.0, 0.0, from_position, false)
	_send_squad()


func _on_player_up(peer_id: int, health: float) -> void:
	_rx_health.rpc_id(peer_id, health, 0.0, Vector3.ZERO, true)
	_send_squad()


func _on_players_changed() -> void:
	for id: int in _ready_peers.keys():
		if NetGame.player(id) == null:
			_ready_peers.erase(id)


func _on_peer_left(id: int) -> void:
	_ready_peers.erase(id)
	_squad_alive.erase(id)
