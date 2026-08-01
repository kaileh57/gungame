class_name FirefightWarLink
extends Node
## The war on the wire. One node that turns a hundred host-side bodies into a
## few kilobytes a second, and turns those bytes back into a hundred bodies on
## every client.
##
## THE RULE THIS FILE EXISTS TO ENFORCE: the host runs the war and nobody else
## runs any part of it. `FirefightDirector` is switched off entirely on a client
## — no thinks, no paths, no perception, no ledger, no spawning — and what a
## client has instead is `FirefightWarPuppets`, which places real creatures where
## it is told. There is no code path on a client that can decide a body moved,
## fired, hit anything or died.
##
## WHAT IS SENT, AND WHAT IS DELIBERATELY NOT.
##
## Sent continuously: position and facing, eight bytes a body, at a rate that
## depends on how far that body is from THAT client's camera. Sent as events:
## spawns, deaths, recycles, rounds fired, and the scoreboard. Not sent at all:
## every clip, every foot, every muzzle flash, every tracer streak, every powder
## bank, every impact, every corpse pose, every flag's height in metres, every
## vane's angle. All of those are functions of the things above, and every
## machine has the same baked assets to compute them from.
##
## RELEVANCE IS A RATE, NOT A CUT. The obvious economy is to stop sending bodies
## a client cannot see, and it is the wrong one here: this is a SPECTATOR demo
## whose whole subject is a war seen from an overlook, and a body that pops into
## existence when you turn toward it ruins exactly the shot the demo is for. So
## nothing is ever culled. What changes with distance is how often a body is
## resampled — every push near the camera, every second push in the middle
## distance, every fourth push beyond it. A body forty metres away is thirty
## pixels tall and moves a pixel between packets; a body a hundred and fifty
## metres away is three pixels tall, and the client's own dead reckoning covers
## the gap better than the eye can measure it.
##
## AND A BODY THAT HAS NOT MOVED COSTS NOTHING. Each body carries a version that
## only advances when it has actually travelled past `move_epsilon`, and each
## peer remembers the version it was last told. Half of this battle at any moment
## is lying in cover shooting, and half of a hundred bodies is fifty records a
## push that are never built.

## A state packet landed. The demo root redraws its overlay off this, because on
## a guest the director's own standings tick never runs.
signal state_changed

## Metres from a client's camera inside which a body is resampled every push.
@export_range(5.0, 400.0, 1.0) var near_metres: float = 45.0
## Metres inside which it is resampled every `mid_divisor` pushes.
@export_range(5.0, 600.0, 1.0) var mid_metres: float = 105.0
@export_range(1, 8, 1) var mid_divisor: int = 2
@export_range(1, 16, 1) var far_divisor: int = 4
## Position pushes per second of WALL clock. Wall, not simulated: the sim-rate
## dial goes to four times, and a stream that went to four times with it would
## quadruple the bandwidth to say the same thing.
@export_range(2.0, 60.0, 1.0) var push_hz: float = 15.0
## Metres a body must travel before it is worth another eight bytes.
@export_range(0.0, 1.0, 0.005) var move_epsilon: float = 0.08
## Radians it must turn, for a body that is standing and traversing.
@export_range(0.0, 1.0, 0.005) var yaw_epsilon: float = 0.06
## Records in one position packet. 110 at eight bytes is 888, comfortably inside
## a datagram, so the stream is never fragmented.
@export_range(8, 200, 1) var max_records: int = 110
## Scoreboard, hotspot and sim-rate pushes per second.
@export_range(0.25, 10.0, 0.25) var state_hz: float = 2.0
## How often a client tells the host where its camera is, per second.
@export_range(0.5, 20.0, 0.5) var view_hz: float = 4.0

var _director: FirefightDirector = null
var _gunfire: FirefightGunfire = null
var _puppets: FirefightWarPuppets = null
var _dial: FirefightDial = null
var _banners: Array[FirefightBanner] = []
var _vanes: Array[FirefightMarker] = []
var _pools: Array[EnemySpawner] = []
var _by_hash: Dictionary = {}
var _api: SceneMultiplayer = null
var _host: bool = false
var _client: bool = false
var _bodies: PackedInt32Array = PackedInt32Array()

var _actors: Array[EnemyActor] = []
var _slot_of: Dictionary = {}
var _live: PackedInt32Array = PackedInt32Array()
var _free: PackedInt32Array = PackedInt32Array()
var _ver: PackedInt32Array = PackedInt32Array()
var _ver_pos: PackedVector3Array = PackedVector3Array()
var _ver_yaw: PackedFloat32Array = PackedFloat32Array()
var _peer_ver: Dictionary = {}
var _views: Dictionary = {}

var _spawn_batch: PackedInt32Array = PackedInt32Array()
var _die_batch: PackedInt32Array = PackedInt32Array()
var _gone_batch: PackedInt32Array = PackedInt32Array()
var _shot_batch: Array = []

var _push_accum: float = 0.0
var _state_accum: float = 0.0
var _view_accum: float = 0.0
var _frame: int = 0
var _seq: int = 0
var _last_move_seq: int = -1
var _last_state_seq: int = -1
var _tx: int = 0
var _tx_rate: float = 0.0
var _rx: int = 0
var _rx_rate: float = 0.0
var _meter: float = 0.0
var _records: int = 0
var _record_rate: float = 0.0
var _auto_tick_was: bool = true
var _greeted: bool = false


func _ready() -> void:
	set_physics_process(false)


func _exit_tree() -> void:
	if _api != null and _api.peer_packet.is_connected(_on_peer_packet):
		_api.peer_packet.disconnect(_on_peer_packet)
	if _client:
		# The ledger was stood down for the duration; a demo that leaves a global
		# switched off hands the next one a war that never ticks.
		Factions.territory_auto_tick = _auto_tick_was
		if _puppets != null:
			_puppets.clear()


## Wire the link into the demo. Called by the demo root once the whole tree is
## up, in the same pass that binds the gunfire and the markers.
##
## In single player this returns having done nothing at all and the node stays
## asleep: `is_networked()` is false, so there is no socket, no slot ledger and
## no per-frame cost. The demo is byte for byte the one that shipped.
func bind(director: FirefightDirector, gunfire: FirefightGunfire, dial: FirefightDial) -> void:
	_director = director
	_gunfire = gunfire
	_dial = dial
	if _director == null:
		return
	_collect_scene()
	_bodies.resize(Factions.COUNT)
	if NetGame.is_networked():
		_open()
		return
	# NOT IN A SESSION YET. In the shipped flow that means single player, and
	# nothing below ever fires. It also covers a session that is still being
	# opened while this scene loads, which is exactly what the documented
	# `--host` and `--join` command-line options do — `NetGame` applies them a
	# frame after the main scene is up, so a demo launched straight into would
	# otherwise sleep through its own session. MEASURED: without the second of
	# these two the host streamed nothing at all to a guest that had joined it.
	if not NetGame.joined.is_connected(_open):
		NetGame.joined.connect(_open)
	if not NetGame.lobby_opened.is_connected(_open):
		NetGame.lobby_opened.connect(_open)


## Whether this machine is doing anything on the wire for this demo.
func is_streaming() -> bool:
	return _host or _client


## Live bodies per faction as most recently told by the host. EMPTY on the host
## and in single player, where the director counts its own agents and is right.
func standings() -> PackedInt32Array:
	return _bodies if _client else PackedInt32Array()


## One line for the engineering overlay, in the same shape as everything else on
## it: what is being sent, how much of it, and to how many people.
func wire_line() -> String:
	if not is_streaming():
		return ""
	var role: String = "host" if _host else "guest"
	return (
		"net %s  %d bodies  %.0f rec/s  up %.1f kB/s  down %.1f kB/s  %d peers"
		% [
			role,
			_live.size() if _host else _puppets.live_count(),
			_record_rate,
			_tx_rate / 1024.0,
			_rx_rate / 1024.0,
			_views.size() if _host else 1,
		]
	)


## Take up whichever side of the wire this machine is on. Idempotent, because it
## is reached both from `bind` and from a late `joined`.
func _open() -> void:
	if is_streaming():
		return
	_api = multiplayer as SceneMultiplayer
	if _api == null:
		return
	if not _api.peer_packet.is_connected(_on_peer_packet):
		_api.peer_packet.connect(_on_peer_packet)
	_host = NetGame.is_authority()
	_client = not _host
	if _host:
		_open_host()
	else:
		_open_client()
	set_physics_process(true)


func _physics_process(delta: float) -> void:
	# Wall clock. Everything this node schedules is a network rate and none of it
	# should move when the sim-rate dial does.
	var real: float = delta / maxf(Engine.time_scale, 0.01)
	_meter += real
	if _meter >= 1.0:
		_tx_rate = float(_tx) / _meter
		_rx_rate = float(_rx) / _meter
		_record_rate = float(_records) / _meter
		_tx = 0
		_rx = 0
		_records = 0
		_meter = 0.0
	if _client:
		_puppets.advance(delta)
		_view_accum += real
		if _view_accum >= 1.0 / view_hz:
			_view_accum = 0.0
			_send_view()
			# UNTIL THE HOST HAS SAID ANYTHING AT ALL, keep saying hello. One
			# reliable greeting is enough when the socket is up when it is sent,
			# and it is not sent into a socket that is still connecting — which is
			# exactly what happens if this scene is opened before the handshake
			# finishes. Four bytes a second until somebody answers is a cheaper
			# fix than a state machine.
			if not _greeted:
				_send_hello()
		return
	if not NetGame.is_networked():
		# The host left the session and its demo became single-player. Stop
		# talking; the bodies carry on exactly as they were.
		_host = false
		set_physics_process(false)
		return
	_flush_events()
	_push_accum += real
	if _push_accum >= 1.0 / push_hz:
		_push_accum = 0.0
		_push_moves()
	_state_accum += real
	if _state_accum >= 1.0 / state_hz:
		_state_accum = 0.0
		_push_state()


# ------------------------------------------------------------------- host side


func _open_host() -> void:
	_actors.resize(FirefightWarWire.MAX_SLOTS)
	_ver.resize(FirefightWarWire.MAX_SLOTS)
	_ver_pos.resize(FirefightWarWire.MAX_SLOTS)
	_ver_yaw.resize(FirefightWarWire.MAX_SLOTS)
	for i: int in FirefightWarWire.MAX_SLOTS:
		_free.append(FirefightWarWire.MAX_SLOTS - 1 - i)
	for s: EnemySpawner in _pools:
		if s == null:
			continue
		s.spawned.connect(_on_spawned)
		s.despawned.connect(_on_despawned)
	NetGame.peer_left.connect(_on_peer_left)
	if _dial != null:
		_dial.detent_changed.connect(_on_detent_changed)


func _on_spawned(actor: EnemyActor) -> void:
	var slot: int = int(_slot_of.get(actor, -1))
	if slot < 0:
		if _free.is_empty():
			return
		slot = _free[_free.size() - 1]
		_free.resize(_free.size() - 1)
		_slot_of[actor] = slot
	_actors[slot] = actor
	if _live.find(slot) < 0:
		_live.append(slot)
	_ver[slot] += 1
	_ver_pos[slot] = actor.global_position
	_ver_yaw[slot] = actor.global_rotation.y
	_spawn_batch.append(slot)
	if not actor.fired.is_connected(_on_fired):
		actor.fired.connect(_on_fired.bind(actor))
	if not actor.died.is_connected(_on_died):
		actor.died.connect(_on_died)


func _on_despawned(actor: EnemyActor) -> void:
	var slot: int = int(_slot_of.get(actor, -1))
	if slot < 0:
		return
	_slot_of.erase(actor)
	_actors[slot] = null
	var i: int = _live.find(slot)
	if i >= 0:
		_live.remove_at(i)
	_free.append(slot)
	_gone_batch.append(slot)


func _on_died(actor: EnemyActor) -> void:
	var slot: int = int(_slot_of.get(actor, -1))
	if slot >= 0:
		_die_batch.append(slot)


## Every round fired, as an event. This is the one place a client is told a shot
## happened at all: the tracer, the flash, the powder and the impact are then
## drawn locally on every machine out of the same three numbers.
func _on_fired(
	origin: Vector3, direction: Vector3, hit_position: Vector3, hit: Object, actor: EnemyActor
) -> void:
	var slot: int = int(_slot_of.get(actor, -1))
	if slot < 0 or _views.is_empty():
		return
	var landed: Vector3 = hit_position
	var surface: int = FirefightGunfire.surface_of(hit)
	if landed.distance_squared_to(origin) < 1e-4:
		landed = origin + direction * 60.0
	_shot_batch.append([slot, origin, landed, surface])


func _on_peer_left(id: int) -> void:
	_views.erase(id)
	_peer_ver.erase(id)


## The dial moved on the host. Everyone's needle, everyone's `Engine.time_scale`.
func _on_detent_changed(_index: int, _scale: float) -> void:
	_state_accum = 1.0


## Spawns, deaths and recycles, batched once a physics frame and sent reliably.
## Batched because the opening deployment stands sixty-six bodies up on ONE
## frame, and sixty-six reliable packets is a stall where one packet is not.
func _flush_events() -> void:
	if _views.is_empty():
		_spawn_batch.clear()
		_die_batch.clear()
		_gone_batch.clear()
		_shot_batch.clear()
		return
	if not _spawn_batch.is_empty():
		_send_spawns(_spawn_batch, 0)
		_spawn_batch.clear()
	if not _die_batch.is_empty():
		_send_slots(FirefightWarWire.K_DIE, _die_batch)
		_die_batch.clear()
	if not _gone_batch.is_empty():
		_send_slots(FirefightWarWire.K_GONE, _gone_batch)
		_gone_batch.clear()
	if not _shot_batch.is_empty():
		_send_shots()
		_shot_batch.clear()


func _send_spawns(slots: PackedInt32Array, to: int) -> void:
	var n: int = slots.size()
	var bytes: PackedByteArray = FirefightWarWire.head(FirefightWarWire.K_SPAWN)
	bytes.resize(FirefightWarWire.HEADER + n * FirefightWarWire.R_SPAWN)
	var at: int = FirefightWarWire.HEADER
	for k: int in n:
		var slot: int = slots[k]
		var actor: EnemyActor = _actors[slot]
		if actor == null or not is_instance_valid(actor):
			continue
		bytes.encode_u8(at, slot)
		bytes.encode_u8(at + 1, _species_code(actor))
		FirefightWarWire.put_pos(bytes, at + 2, actor.global_position)
		FirefightWarWire.put_yaw(bytes, at + 8, actor.global_rotation.y)
		at += FirefightWarWire.R_SPAWN
	bytes.resize(at)
	if at > FirefightWarWire.HEADER:
		_send(bytes, to, MultiplayerPeer.TRANSFER_MODE_RELIABLE)


func _send_slots(kind: int, slots: PackedInt32Array) -> void:
	var bytes: PackedByteArray = FirefightWarWire.head(kind)
	bytes.resize(FirefightWarWire.HEADER + slots.size())
	for k: int in slots.size():
		bytes.encode_u8(FirefightWarWire.HEADER + k, slots[k])
	_send(bytes, 0, MultiplayerPeer.TRANSFER_MODE_RELIABLE)


func _send_shots() -> void:
	var n: int = _shot_batch.size()
	var bytes: PackedByteArray = FirefightWarWire.head(FirefightWarWire.K_SHOT, _next_seq())
	bytes.resize(FirefightWarWire.HEADER + n * FirefightWarWire.R_SHOT)
	var at: int = FirefightWarWire.HEADER
	for k: int in n:
		var rec: Array = _shot_batch[k]
		bytes.encode_u8(at, int(rec[0]))
		FirefightWarWire.put_pos(bytes, at + 1, rec[1])
		FirefightWarWire.put_pos(bytes, at + 7, rec[2])
		bytes.encode_u8(at + 13, int(rec[3]))
		at += FirefightWarWire.R_SHOT
	_send(bytes, 0, MultiplayerPeer.TRANSFER_MODE_UNRELIABLE)


## The position stream, built once per peer because the rate a body is sent at
## depends on where THAT peer's camera is.
func _push_moves() -> void:
	_frame += 1
	_bump_versions()
	for id: int in _views.keys():
		var eye: Vector3 = _views[id]
		# A LOCAL COPY, WRITTEN BACK AT THE END. `PackedInt32Array` is a value
		# type: mutating this alias does not reach the dictionary, and without the
		# write-back below every peer's ledger would read as all-zero forever and
		# the version filter — the thing that makes half this battle free — would
		# quietly do nothing at all.
		var seen: PackedInt32Array = _peer_ver[id]
		var bytes: PackedByteArray = FirefightWarWire.head(FirefightWarWire.K_MOVE, _next_seq())
		var at: int = FirefightWarWire.HEADER
		bytes.resize(FirefightWarWire.HEADER + max_records * FirefightWarWire.R_MOVE)
		for slot: int in _live:
			var actor: EnemyActor = _actors[slot]
			if actor == null or not is_instance_valid(actor):
				continue
			if seen[slot] == _ver[slot] or not _due(slot, eye, actor.global_position):
				continue
			seen[slot] = _ver[slot]
			bytes.encode_u8(at, slot)
			FirefightWarWire.put_pos(bytes, at + 1, actor.global_position)
			FirefightWarWire.put_yaw(bytes, at + 7, actor.global_rotation.y)
			at += FirefightWarWire.R_MOVE
			_records += 1
			if at >= bytes.size():
				break
		_peer_ver[id] = seen
		bytes.resize(at)
		if at > FirefightWarWire.HEADER:
			_send(bytes, id, MultiplayerPeer.TRANSFER_MODE_UNRELIABLE)


## A body's version only advances once it has actually moved. Everything
## downstream — the per-peer bookkeeping, the packet size, the bandwidth — falls
## out of this one comparison, which is why it is done once for all peers rather
## than once per peer.
func _bump_versions() -> void:
	var eps2: float = move_epsilon * move_epsilon
	for slot: int in _live:
		var actor: EnemyActor = _actors[slot]
		if actor == null or not is_instance_valid(actor):
			continue
		var p: Vector3 = actor.global_position
		var y: float = actor.global_rotation.y
		if (
			p.distance_squared_to(_ver_pos[slot]) < eps2
			and absf(angle_difference(y, _ver_yaw[slot])) < yaw_epsilon
		):
			continue
		_ver_pos[slot] = p
		_ver_yaw[slot] = y
		_ver[slot] += 1


## Whether this body's turn has come round for this peer. The slot is added to
## the frame counter so the mid and far tiers are spread evenly over the cycle
## instead of all landing on the same push and spiking the packet.
func _due(slot: int, eye: Vector3, at: Vector3) -> bool:
	var d: float = eye.distance_to(at)
	if d <= near_metres:
		return true
	var every: int = mid_divisor if d <= mid_metres else far_divisor
	return (_frame + slot) % maxi(every, 1) == 0


## The scoreboard, the hotspot the tracking mast points at, the sim rate and the
## three body counts. Sixty-one bytes twice a second for everything in this demo
## that is not a body.
func _push_state() -> void:
	if _views.is_empty():
		return
	var ledger: Factions.Territory = Factions.territory
	var n: int = _banners.size()
	var bytes: PackedByteArray = FirefightWarWire.head(FirefightWarWire.K_STATE, _next_seq())
	bytes.resize(FirefightWarWire.STATE_FIXED + n * FirefightWarWire.R_ZONE)
	bytes.encode_u8(8, 0 if _dial == null else _dial.detent_index())
	# Three, hard, because three bytes is what the layout reserves. A fourth
	# faction would silently write over the hotspot rather than fail loudly.
	for f: int in mini(Factions.COUNT, 3):
		bytes.encode_u8(9 + f, mini(_director.body_count(f), 255))
	FirefightWarWire.put_pos(bytes, 12, _director.hotspot())
	var at: int = FirefightWarWire.STATE_FIXED
	for b: FirefightBanner in _banners:
		bytes.encode_u32(at, _zone_hash(b.zone_id))
		bytes.encode_s8(at + 4, ledger.zone_owner(b.zone_id))
		bytes.encode_u8(at + 5, 1 if ledger.is_contested(b.zone_id) else 0)
		at += FirefightWarWire.R_ZONE
	_send(bytes, 0, MultiplayerPeer.TRANSFER_MODE_UNRELIABLE)


## A client said hello. Everything standing right now, reliably, to that one
## peer — and reliable delivery is ordered, so every later event lands behind it.
func _on_hello(id: int) -> void:
	var seen := PackedInt32Array()
	seen.resize(FirefightWarWire.MAX_SLOTS)
	if not _views.has(id):
		_views[id] = _director.global_position
	_send_spawns(_live, id)
	for slot: int in _live:
		var actor: EnemyActor = _actors[slot]
		if actor != null and is_instance_valid(actor):
			seen[slot] = _ver[slot]
	# Filled first, published second, for the value-type reason in `_push_moves`.
	_peer_ver[id] = seen
	var dead := PackedInt32Array()
	for slot: int in _live:
		var actor: EnemyActor = _actors[slot]
		if actor != null and is_instance_valid(actor) and not actor.alive:
			dead.append(slot)
	if not dead.is_empty():
		_send_slots(FirefightWarWire.K_DIE, dead)
	_state_accum = 1.0


## Where a client is looking, for the relevance tiers. Intent, and harmless if a
## client lies about it: the worst it can buy is more of its own bandwidth.
func _on_view(id: int, at: Vector3) -> void:
	_views[id] = at
	if not _peer_ver.has(id):
		_on_hello(id)


## A client operated the sim-rate dial. It does not turn its own — the dial is
## one physical object in one shared world, and the host owns it.
func _on_dial_request() -> void:
	if _dial != null:
		_dial.step_detent()


func _species_code(actor: EnemyActor) -> int:
	var faction: int = clampi(actor.faction, 0, FirefightRoster.ROSTERS.size() - 1)
	var roster: Array = FirefightRoster.ROSTERS[faction]
	return faction * 4 + maxi(roster.find(actor.species_id), 0)


# ----------------------------------------------------------------- client side


func _open_client() -> void:
	# A client neither ticks the ledger nor is allowed to. With nothing pushing
	# pressure into it, an auto-ticking ledger decays every zone to neutral and
	# strikes seven flags that the host still has flying.
	_auto_tick_was = Factions.territory_auto_tick
	Factions.territory_auto_tick = false
	# EVERYTHING ALREADY STANDING, BACK IN THE POOL. In the shipped flow there is
	# nothing here — a guest follows the host into a scene it has already joined.
	# Launched straight into this demo with `--join`, though, `NetGame` applies
	# the command line a frame after the scene is up, and the director can get an
	# opening deployment away before it learns it is not the authority. Anything
	# it managed to stand up is a body nobody else can see, so it goes.
	# Killed before it is pooled, and the order matters: `despawn` alone parks a
	# body that is still `alive`, and the director goes on counting it in
	# `body_count` for the rest of the run because its retirement queue is only
	# drained from the physics callback it no longer has.
	for s: EnemySpawner in _pools:
		if s == null:
			continue
		for a: EnemyActor in s.live_actors().duplicate():
			a.kill()
		s.despawn_all()
	_puppets = FirefightWarPuppets.new(_pools)
	if _dial != null and not _dial.detent_requested.is_connected(_on_detent_requested):
		_dial.detent_requested.connect(_on_detent_requested)
	_send_hello()
	_send_view()


func _send_hello() -> void:
	_send(
		FirefightWarWire.head(FirefightWarWire.K_HELLO),
		NetPlayer.HOST_ID,
		MultiplayerPeer.TRANSFER_MODE_RELIABLE
	)


func _on_detent_requested() -> void:
	_send(
		FirefightWarWire.head(FirefightWarWire.K_DIAL),
		NetPlayer.HOST_ID,
		MultiplayerPeer.TRANSFER_MODE_RELIABLE
	)


func _send_view() -> void:
	var cam: Camera3D = get_viewport().get_camera_3d()
	if cam == null:
		return
	var bytes: PackedByteArray = FirefightWarWire.head(FirefightWarWire.K_VIEW)
	bytes.resize(FirefightWarWire.HEADER + 6)
	FirefightWarWire.put_pos(bytes, FirefightWarWire.HEADER, cam.global_position)
	_send(bytes, NetPlayer.HOST_ID, MultiplayerPeer.TRANSFER_MODE_UNRELIABLE)


func _read_spawns(packet: PackedByteArray) -> void:
	var n: int = FirefightWarWire.record_count(packet, FirefightWarWire.R_SPAWN)
	for k: int in n:
		var at: int = FirefightWarWire.HEADER + k * FirefightWarWire.R_SPAWN
		var code: int = packet.decode_u8(at + 1)
		_puppets.spawn(
			packet.decode_u8(at),
			code / 4,
			code % 4,
			FirefightWarWire.get_pos(packet, at + 2),
			FirefightWarWire.get_yaw(packet, at + 8)
		)


func _read_moves(packet: PackedByteArray) -> void:
	var n: int = FirefightWarWire.record_count(packet, FirefightWarWire.R_MOVE)
	_records += n
	for k: int in n:
		var at: int = FirefightWarWire.HEADER + k * FirefightWarWire.R_MOVE
		_puppets.move(
			packet.decode_u8(at),
			FirefightWarWire.get_pos(packet, at + 1),
			FirefightWarWire.get_yaw(packet, at + 7)
		)


func _read_shots(packet: PackedByteArray) -> void:
	var n: int = FirefightWarWire.record_count(packet, FirefightWarWire.R_SHOT)
	for k: int in n:
		var at: int = FirefightWarWire.HEADER + k * FirefightWarWire.R_SHOT
		var origin: Vector3 = FirefightWarWire.get_pos(packet, at + 1)
		var landed: Vector3 = FirefightWarWire.get_pos(packet, at + 7)
		_puppets.shot(packet.decode_u8(at), landed)
		if _gunfire != null:
			_gunfire.remote_shot(origin, landed, packet.decode_u8(at + 13))


func _read_state(packet: PackedByteArray) -> void:
	if packet.size() < FirefightWarWire.STATE_FIXED:
		return
	if _dial != null:
		_dial.set_detent(packet.decode_u8(8))
	for f: int in mini(Factions.COUNT, _bodies.size()):
		_bodies[f] = packet.decode_u8(9 + f)
	# The tracking mast points at the fighting, and the fighting is a sweep over
	# every zone against every body — which a guest does not have. It is one
	# point twice a second, so it rides along here rather than being recomputed
	# out of information this machine does not possess.
	var where: Vector3 = FirefightWarWire.get_pos(packet, 12)
	for m: FirefightMarker in _vanes:
		m.set_aim(where)
	var n: int = (packet.size() - FirefightWarWire.STATE_FIXED) / FirefightWarWire.R_ZONE
	for k: int in n:
		var at: int = FirefightWarWire.STATE_FIXED + k * FirefightWarWire.R_ZONE
		var banner: FirefightBanner = _by_hash.get(packet.decode_u32(at))
		if banner == null:
			continue
		var owner_faction: int = packet.decode_s8(at + 4)
		# The ledger first, so anything else in the scene reading it agrees, then
		# the mast, which is the only thing that knows about half mast.
		Factions.territory.set_owner(banner.zone_id, owner_faction)
		banner.set_state(owner_faction, packet.decode_u8(at + 5) != 0)
	state_changed.emit()


# ------------------------------------------------------------------- transport


func _send(bytes: PackedByteArray, to: int, mode: MultiplayerPeer.TransferMode) -> void:
	if _api == null:
		return
	_tx += bytes.size()
	_api.send_bytes(bytes, to, mode, FirefightWarWire.CHANNEL)


## Everything on the raw channel arrives here, including `NetPresence`'s avatar
## traffic. The magic word is checked before a single field is decoded.
func _on_peer_packet(id: int, packet: PackedByteArray) -> void:
	if not FirefightWarWire.is_ours(packet):
		return
	_rx += packet.size()
	var kind: int = FirefightWarWire.kind_of(packet)
	if _host:
		_host_packet(id, kind, packet)
		return
	if not _client or id != NetPlayer.HOST_ID:
		return
	_greeted = true
	_client_packet(kind, packet)


func _host_packet(id: int, kind: int, packet: PackedByteArray) -> void:
	match kind:
		FirefightWarWire.K_HELLO:
			_on_hello(id)
		FirefightWarWire.K_VIEW:
			if packet.size() >= FirefightWarWire.HEADER + 6:
				_on_view(id, FirefightWarWire.get_pos(packet, FirefightWarWire.HEADER))
		FirefightWarWire.K_DIAL:
			_on_dial_request()


func _client_packet(kind: int, packet: PackedByteArray) -> void:
	var seq: int = FirefightWarWire.seq_of(packet)
	match kind:
		FirefightWarWire.K_SPAWN:
			_read_spawns(packet)
		FirefightWarWire.K_MOVE:
			# The stream is sent UNSEQUENCED so ENet never drops one of ours to
			# make room for somebody else's packet on the shared channel. The
			# price is spotting a reordered one here, which is one comparison.
			if FirefightWarWire.newer(seq, _last_move_seq):
				_last_move_seq = seq
				_read_moves(packet)
		FirefightWarWire.K_SHOT:
			_read_shots(packet)
		FirefightWarWire.K_DIE:
			for k: int in FirefightWarWire.record_count(packet, FirefightWarWire.R_DIE):
				_puppets.kill(packet.decode_u8(FirefightWarWire.HEADER + k))
		FirefightWarWire.K_GONE:
			for k: int in FirefightWarWire.record_count(packet, FirefightWarWire.R_GONE):
				_puppets.gone(packet.decode_u8(FirefightWarWire.HEADER + k))
		FirefightWarWire.K_STATE:
			if FirefightWarWire.newer(seq, _last_state_seq):
				_last_state_seq = seq
				_read_state(packet)


func _next_seq() -> int:
	_seq = (_seq + 1) & 0xFFFF
	return _seq


## The three things in the scene this node drives or reports on: the masts, the
## tracking vanes, and the pools every body on every machine comes out of. All
## three are found rather than pathed, so the bake owes this file nothing.
func _collect_scene() -> void:
	for node in get_tree().get_nodes_in_group(FirefightBanner.GROUP):
		var b := node as FirefightBanner
		if b != null:
			_banners.append(b)
			_by_hash[_zone_hash(b.zone_id)] = b
	for node in get_tree().get_nodes_in_group(&"firefight_control"):
		var m := node as FirefightMarker
		if m != null and m.track_hotspot:
			_vanes.append(m)
	for p: NodePath in _director.spawner_paths:
		_pools.append(_director.get_node_or_null(p) as EnemySpawner)


## A zone's identity on the wire. The hash and not the index, because the ledger
## is an autoload that outlives a scene and its registration order depends on
## what this process happened to load before the firefight — which is not the
## same on two machines that arrived here by different routes.
static func _zone_hash(zone_id: StringName) -> int:
	return String(zone_id).hash() & 0xFFFFFFFF
