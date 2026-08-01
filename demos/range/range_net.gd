extends Node
## THE RANGE'S WIRE. Every packet this demo sends or receives goes through here.
##
## It carries no `class_name` on purpose. `tools/build_range.gd` runs as a
## `--script` main loop, where a global class added since the editor last rescanned
## is invisible and naming one breaks the bake on a clean checkout. Everything that
## needs this file preloads it by path, exactly as the builder preloads its kits.
## For the same reason nothing in here names a class that preloads it back: the
## targets, the shooter and the bench are reached through signals, never directly,
## so the dependency only ever points one way.
##
## WHERE IT LIVES. `Range/RangeNet`, put there by the builder, so the node path is
## identical on every machine — which is what Godot's RPC routing requires and the
## reason the whole demo's plumbing sits on one node instead of being scattered over
## the bench, the targets and the shooter.
##
## THE MODEL, in one paragraph. The host runs the range: it owns every target's
## health, every knock-down, the bench, the score and the clock. A client owns its
## own gun — trigger, magazine, jam, recoil, muzzle flash and tracer — because that
## is what makes shooting feel instant, and none of it is a decision. When a client
## fires it sends the host the lines its pellets went down; the host re-traces them
## (`range_arm.gd`) and decides what was hit and what it scored. Everything the host
## decides comes back as an event and every machine draws the same thing.
##
## WHO SHOT IT. The one idea this file is built around. Before the host resolves
## anybody's shot it sets `_actor` to that player's peer id, and clears it after.
## Everything the shot touches on the way through — a plate scoring, a drum going
## up, the EQUIP cap on the bench being knocked in — reads `actor()` and knows whose
## round it was, without a single one of them having to be handed a peer id. It is
## exact because GDScript is single threaded and a shot resolves inside one
## synchronous call: there is no frame in which two players' rounds are in flight
## through the same code at once.
##
## `NetGame` is reached by node path and called by name, never by autoload
## identifier, so this file compiles and runs in a build with no `net/` at all —
## and `demos/range/verify_range.gd`, which stands the demo up under `--script`,
## keeps working untouched. No network means `is_authority()` is true, the roster is
## a list of one, and every `rpc` below is skipped.

## The roster changed: somebody joined, left or was renamed.
signal roster_changed
## The host granted `id` a weapon. Fires on every machine, including the host.
signal equipped(id: int, slot: int, spec: GunSpec)
## The bench's authoritative state. `spec` is what is on the stand.
signal bench_state(spec: GunSpec, dial: int, lever: bool)
## A diegetic control actuated on the host. `value` is its state after the hit.
signal control_state(id: StringName, value: float)
## Something happened to target `index`. `op` is one of `Op`.
signal target_event(index: int, op: int, at: Vector3, amount: float, crit: bool)
## Points were scored. Drawn as a damage pop by every machine.
signal scored_at(id: int, at: Vector3, points: int, label: String, kind: StringName, crit: bool)
## The whole tally, one row per player. See `publish_scores`.
signal scores_changed(rows: Array)
## Somebody else's round went down a line. Cosmetic, drawn locally.
signal shot_seen(id: int, from: Vector3, to: Vector3, surface: int)
## A warhead went off somewhere.
signal blast_seen(at: Vector3, radius: float)
## HOST ONLY: a remote player's round arrived on something. Whoever owns what a
## bullet does to a bench control handles this; `actor()` is already that player.
signal arm_hit(collider: Object, at: Vector3, amount: float)
## The host reset the range.
signal range_reset
## The half-second reconcile: one alive bit and one mover phase per target.
signal sync_state(alive: PackedByteArray, phase: PackedFloat32Array)
## HOST: `id` has arrived in the scene and wants the whole state. Answer with
## `send_state`.
signal state_wanted(id: int)
## CLIENT: the host's answer. Apply it whole.
signal state_arrived(dump: Dictionary)

## What happened to a target.
enum Op { HIT, DOWN, RESTORE, BOOM }

## Anything in the demo finds this node through the group rather than a path, so a
## demo instanced as a child of something else still resolves.
const GROUP: StringName = &"range_net"
## `NetGame`, by path. Named nowhere, so this file compiles with no `net/` present.
const NET_PATH: NodePath = ^"/root/NetGame"
const RangeArm := preload("res://demos/range/range_arm.gd")

## Shots a player may bank while not firing, so a burst arrives as a burst.
const SHOT_BURST: float = 8.0
## Multiple of a weapon's rated cadence a client is allowed to claim, plus a floor
## so a single-shot gun tapped fast is never throttled.
const SHOT_RATE_SLACK: float = 1.6
const SHOT_RATE_FLOOR: float = 4.0
## Metres a claimed muzzle may be from where the host last saw that player stand.
## Generous: presence replicates position at 18 Hz and a sprinting player covers
## nearly half a metre between packets.
const ORIGIN_TOLERANCE: float = 6.0
## Length of an encoded weapon: five part indices, the roll seed, the optics flag.
const SPEC_FIELDS: int = 7
## Seconds between re-asks while a client waits for the host's state, and how many
## times it is worth asking. The host's scene and the client's come up a round trip
## apart and EITHER can win: a hello that lands before `Range/RangeNet` exists on
## the host is dropped by the engine with a warning, and one ask would be the end
## of it. Ten seconds of asking costs twenty tiny packets and covers the race.
const HELLO_PERIOD: float = 0.5
const HELLO_TRIES: int = 20

var _net: Node = null
var _actor: int = NetPlayer.HOST_ID
var _local: int = NetPlayer.HOST_ID
var _arms: Dictionary = {}
var _loadout: Dictionary = {}
var _credit: Dictionary = {}
## Peer ids, cached off the roster. `publish_shot` runs up to five times a round
## per player and building a fresh roster of dictionaries in there would allocate
## a couple of hundred times a second for no reason.
var _peers: PackedInt32Array = PackedInt32Array()
var _hello_left: int = 0
var _hello_clock: float = 0.0


## Group membership and the answer to "am I the authority" are settled in
## `_enter_tree`, not in `_ready`. Godot runs every `_enter_tree` in a scene before
## it runs any `_ready`, so this is the only way every other node in the demo can
## ask the question from its own `_ready` without depending on sibling order.
func _enter_tree() -> void:
	add_to_group(GROUP)
	_net = get_node_or_null(NET_PATH)
	_local = _resolve_local()
	_actor = _local
	_refresh_peers()


func _ready() -> void:
	if _net != null:
		_net.connect(&"peer_joined", _on_peer_joined)
		_net.connect(&"peer_left", _on_peer_left)
		_net.connect(&"players_changed", _on_players_changed)
	if is_authority():
		_adopt_players()
	elif is_networked():
		# A client's scene comes up a transition behind the host's. Ask for the state
		# rather than assume the shipped scene is still what everybody is looking at.
		_hello_left = HELLO_TRIES


func _process(delta: float) -> void:
	if _hello_left <= 0:
		return
	_hello_clock -= delta
	if _hello_clock > 0.0:
		return
	_hello_clock = HELLO_PERIOD
	_hello_left -= 1
	_rq_hello.rpc_id(NetPlayer.HOST_ID)


func _physics_process(delta: float) -> void:
	if _arms.is_empty() or not is_authority():
		return
	var space: PhysicsDirectSpaceState3D = _space()
	for id: int in _arms:
		var arm: RangeArm = _arms[id]
		if arm.in_flight() > 0:
			_actor = id
			arm.step(delta, space)
		_credit[id] = minf(float(_credit.get(id, 0.0)) + delta * _rate_for(id), SHOT_BURST)
	_actor = _local


# --- who and where -----------------------------------------------------------


## The demo's wire, found from anywhere inside it. Null only in a tree that has none.
static func of(node: Node) -> Node:
	var tree: SceneTree = node.get_tree()
	return null if tree == null else tree.get_first_node_in_group(GROUP)


## THE ONE. True on the host and true in single-player. Gate every decision on it.
func is_authority() -> bool:
	return _net == null or bool(_net.call(&"is_authority"))


## False in pure single-player, and in a `--script` harness with no autoloads.
func is_networked() -> bool:
	return _net != null and bool(_net.call(&"is_networked"))


## This machine's peer id. 1 on the host and 1 when there is no session.
func local_peer() -> int:
	return _local


## Whose round is being resolved right now. Read it from anything a shot touches.
func actor() -> int:
	return _actor


## Say whose round the next thing is. The host's own weapon brackets its tick with
## this; the shot intake brackets its trace. Always pair it with a call back to the
## local peer, or the next thing to score is credited to the wrong player.
func set_actor(id: int) -> void:
	_actor = id if id > 0 else _local


## Everyone in the session, in slot order, host first. Never empty: in single-player
## it is a list of one, so a scoreboard is one loop and not two. Rows carry
## `id`, `name`, `color`, `slot` and `local`.
func roster() -> Array:
	var rows: Array = []
	if _net == null:
		rows.append(_row(_local, "PLAYER", NetPlayer.SLOT_COLORS[0], 0, true))
		return rows
	for who: NetPlayer in _net.call(&"players"):
		rows.append(_row(who.peer_id, who.display_name(), who.color(), who.slot, who.is_local))
	return rows


## What the host says a player is holding, or null.
func loadout_of(id: int) -> GunSpec:
	return _loadout.get(id) as GunSpec


# --- what a client sends -----------------------------------------------------


## CLIENT: I pulled the trigger, here is where my round came from and where its
## pellets landed on my machine. The host decides the rest.
##
## Sent reliably, because a lost shot is a shot the player made and never got. At
## 600 rpm that is ten packets a second per player, which is nothing.
func send_shot(origin: Vector3, muzzle: Vector3, aim: Vector3, points: PackedVector3Array) -> void:
	if is_authority() or not is_networked():
		return
	_rq_shot.rpc_id(NetPlayer.HOST_ID, origin, muzzle, aim, points)


# --- what the host publishes -------------------------------------------------


## HOST: give `id` a weapon. The one door — the local player's holster and a remote
## player's arm are both filled from here, so there is one loadout table and every
## machine's scoreboard agrees about who is carrying what.
func grant(id: int, slot: int, spec: GunSpec) -> void:
	if not is_authority() or spec == null or id <= 0:
		return
	_loadout[id] = spec
	var arm: RangeArm = _arms.get(id)
	if arm != null:
		arm.configure(spec)
	if is_networked():
		_ev_equip.rpc(id, slot, _encode_spec(spec))
	equipped.emit(id, slot, spec)


## HOST: a diegetic control actuated. Everyone gets the state, so a bench three
## players are working reads the same from all four seats.
func publish_control(control: DiegeticControl) -> void:
	if not is_authority() or control == null or control.control_id == &"":
		return
	if is_networked():
		_ev_control.rpc(control.control_id, control.value())


## HOST: what is on the stand and where the dial and the lever are sitting.
func publish_bench(spec: GunSpec, dial: int, lever: bool) -> void:
	if is_authority() and is_networked():
		_ev_bench.rpc(_encode_spec(spec), dial, lever)


## HOST: something happened to a target. `amount` is the damage for a HIT and is
## ignored otherwise.
func publish_target(index: int, op: int, at: Vector3, amount: float, crit: bool) -> void:
	if is_authority() and is_networked() and index >= 0:
		_ev_target.rpc(index, op, at, amount, crit)


## HOST: points landed. Carries who earned them, so every machine can draw the pop
## and credit it to the right column.
func publish_pop(
	id: int, at: Vector3, points: int, label: String, kind: StringName, crit: bool
) -> void:
	if is_authority() and is_networked():
		_ev_pop.rpc(id, at, points, label, kind, crit)


## HOST: the whole tally. One row per player:
## `[id, score, hits, spots, downs, streak, best]`. Sent unreliably-ordered because
## it is continuously replaced and a dropped one is fixed by the next.
func publish_scores(rows: Array) -> void:
	if is_authority() and is_networked():
		_ev_scores.rpc(rows)


## A round went down a line, drawn by every machine EXCEPT the one that fired it —
## that machine drew its own the instant the trigger went, which is the whole point
## of predicting it, and a second one a round trip later reads as a double.
func publish_shot(id: int, from: Vector3, to: Vector3, surface: int) -> void:
	if not is_networked() or not is_authority():
		return
	for who: int in _peers:
		if who != id and who != _local:
			_ev_shot.rpc_id(who, id, from, to, surface)
	if id != _local:
		shot_seen.emit(id, from, to, surface)


## HOST: the half-second reconcile. One alive bit and one mover phase per target,
## in the demo's own target order. A machine that missed an event cannot stay wrong
## for longer than that, and — the reason this exists at all — a mover the host has
## half a metre further along than the client is a shot that misses on the host and
## looked like a hit to the player who took it.
func publish_sync(alive: PackedByteArray, phase: PackedFloat32Array) -> void:
	if is_authority() and is_networked():
		_ev_sync.rpc(alive, phase)


## HOST: the range was cleared.
func publish_reset() -> void:
	if not is_authority():
		return
	for id: int in _arms:
		(_arms[id] as RangeArm).clear()
	if is_networked():
		_ev_reset.rpc()


## HOST: answer a client's arrival with everything it needs to be in step. The demo
## builds the dictionary; `GunSpec` values in it are encoded on the way out and
## rebuilt on the way in, because a resource cannot travel on a wire.
func send_state(id: int, dump: Dictionary) -> void:
	if not is_authority() or not is_networked() or id <= 0:
		return
	var wire: Dictionary = dump.duplicate()
	wire[&"bench"] = _encode_spec(dump.get(&"bench") as GunSpec)
	var guns: Dictionary = {}
	for who: int in dump.get(&"loadouts", {}) as Dictionary:
		guns[who] = _encode_spec((dump[&"loadouts"] as Dictionary)[who] as GunSpec)
	wire[&"loadouts"] = guns
	_ev_state.rpc_id(id, wire)


# --- the shot intake ---------------------------------------------------------

## A client's trigger pull, arriving on the host.
##
## `get_remote_sender_id` is the whole security model and it is the engine's, not
## this file's: a peer cannot forge it, so the shot is attributed to whoever really
## sent it and `_actor` is set from that and nothing else. What the packet carries
## is only ever an origin and a set of directions, and both are checked.
@rpc("any_peer", "call_remote", "reliable")
func _rq_shot(origin: Vector3, muzzle: Vector3, aim: Vector3, points: PackedVector3Array) -> void:
	if not is_authority():
		return
	var id: int = multiplayer.get_remote_sender_id()
	var arm: RangeArm = _arms.get(id)
	if arm == null or not arm.is_armed() or not _spend_credit(id):
		return
	if not origin.is_finite() or not muzzle.is_finite() or not _origin_plausible(id, origin):
		return
	_actor = id
	arm.fire(_space(), origin, muzzle, aim, points)
	_actor = _local


## A client asking for the state of the range, once, on arrival.
@rpc("any_peer", "call_remote", "reliable")
func _rq_hello() -> void:
	if is_authority():
		state_wanted.emit(multiplayer.get_remote_sender_id())


# --- what arrives from the host ----------------------------------------------

@rpc("authority", "call_remote", "reliable")
func _ev_equip(id: int, slot: int, parts: PackedInt32Array) -> void:
	var spec: GunSpec = _decode_spec(parts)
	if spec != null:
		_loadout[id] = spec
		equipped.emit(id, slot, spec)


@rpc("authority", "call_remote", "reliable")
func _ev_control(id: StringName, value: float) -> void:
	control_state.emit(id, value)


@rpc("authority", "call_remote", "reliable")
func _ev_bench(parts: PackedInt32Array, dial: int, lever: bool) -> void:
	bench_state.emit(_decode_spec(parts), dial, lever)


@rpc("authority", "call_remote", "reliable")
func _ev_target(index: int, op: int, at: Vector3, amount: float, crit: bool) -> void:
	target_event.emit(index, op, at, amount, crit)


@rpc("authority", "call_remote", "reliable")
func _ev_pop(
	id: int, at: Vector3, points: int, label: String, kind: StringName, crit: bool
) -> void:
	scored_at.emit(id, at, points, label, kind, crit)


@rpc("authority", "call_remote", "unreliable_ordered")
func _ev_scores(rows: Array) -> void:
	scores_changed.emit(rows)


@rpc("authority", "call_remote", "unreliable_ordered")
func _ev_shot(id: int, from: Vector3, to: Vector3, surface: int) -> void:
	shot_seen.emit(id, from, to, surface)


@rpc("authority", "call_remote", "reliable")
func _ev_blast(at: Vector3, radius: float) -> void:
	blast_seen.emit(at, radius)


@rpc("authority", "call_remote", "unreliable_ordered")
func _ev_sync(alive: PackedByteArray, phase: PackedFloat32Array) -> void:
	sync_state.emit(alive, phase)


@rpc("authority", "call_remote", "reliable")
func _ev_reset() -> void:
	range_reset.emit()


@rpc("authority", "call_remote", "reliable")
func _ev_state(wire: Dictionary) -> void:
	_hello_left = 0
	var dump: Dictionary = wire.duplicate()
	dump[&"bench"] = _decode_spec(wire.get(&"bench", PackedInt32Array()))
	var guns: Dictionary = {}
	for who: int in wire.get(&"loadouts", {}) as Dictionary:
		var spec: GunSpec = _decode_spec((wire[&"loadouts"] as Dictionary)[who])
		if spec != null:
			guns[who] = spec
			_loadout[who] = spec
	dump[&"loadouts"] = guns
	state_arrived.emit(dump)


# --- the host's arms ---------------------------------------------------------


## One arm per REMOTE player. The host's own gun is the real `Weapon` in
## `RangeShooter`; it needs no proxy, because it is already here.
func _adopt_players() -> void:
	for row: Dictionary in roster():
		_ensure_arm(int(row[&"id"]))


func _ensure_arm(id: int) -> void:
	if id <= 0 or id == _local or _arms.has(id):
		return
	var arm := RangeArm.new(id)
	arm.on_hit = _on_arm_hit
	arm.on_tracer = _on_arm_tracer.bind(id)
	arm.on_blast = _on_arm_blast
	_arms[id] = arm
	_credit[id] = SHOT_BURST
	var spec: GunSpec = _loadout.get(id) as GunSpec
	if spec != null:
		arm.configure(spec)


## A remote player's round arrived on something. Passed straight out: the bench is
## worked by gunfire and the code that knows what a round does to a control lives
## with the gun, not here. `actor()` is already that player.
func _on_arm_hit(
	collider: Object, at: Vector3, _normal: Vector3, amount: float, _surface: int
) -> void:
	arm_hit.emit(collider, at, amount)


func _on_arm_tracer(from: Vector3, to: Vector3, surface: int, id: int) -> void:
	publish_shot(id, from, to, surface)


func _on_arm_blast(at: Vector3, radius: float) -> void:
	if is_networked():
		_ev_blast.rpc(at, radius)
	blast_seen.emit(at, radius)


# --- gates and plumbing ------------------------------------------------------


## A token bucket per player, refilled at that weapon's own cadence. A client whose
## clock runs fast, or whose packets bunch after a stall, is not punished — the
## bucket holds eight shots — but nothing fires faster than its gun forever.
func _spend_credit(id: int) -> bool:
	var left: float = float(_credit.get(id, SHOT_BURST))
	if left < 1.0:
		return false
	_credit[id] = left - 1.0
	return true


func _rate_for(id: int) -> float:
	var spec: GunSpec = _loadout.get(id) as GunSpec
	if spec == null:
		return SHOT_RATE_FLOOR
	return maxf(float(spec.rpm) / 60.0 * SHOT_RATE_SLACK, SHOT_RATE_FLOOR)


## Is the claimed origin anywhere near where the host last saw that player? Their
## avatar is driven by presence, which is the only position record this demo has.
## No avatar yet means no opinion, and no opinion means yes.
func _origin_plausible(id: int, origin: Vector3) -> bool:
	if _net == null:
		return true
	var who: NetPlayer = _net.call(&"player", id)
	if who == null or who.avatar == null or not is_instance_valid(who.avatar):
		return true
	return who.avatar.global_position.distance_to(origin) <= ORIGIN_TOLERANCE


## The physics world a remote player's round is traced against. Taken off the demo
## root rather than off `/root`, so a demo standing inside a SubViewport is traced
## against the world it is actually in and not against an empty one.
func _space() -> PhysicsDirectSpaceState3D:
	var here := get_parent() as Node3D
	var world: World3D = null
	if here != null:
		world = here.get_world_3d()
	elif get_tree() != null:
		world = get_tree().root.world_3d
	return null if world == null else world.direct_space_state


func _resolve_local() -> int:
	return NetPlayer.HOST_ID if _net == null else int(_net.call(&"peer_id"))


static func _row(id: int, who: String, color: Color, slot: int, local: bool) -> Dictionary:
	return {&"id": id, &"name": who, &"color": color, &"slot": slot, &"local": local}


func _refresh_peers() -> void:
	_peers.clear()
	for row: Dictionary in roster():
		_peers.append(int(row[&"id"]))


func _on_peer_joined(id: int) -> void:
	_refresh_peers()
	if is_authority():
		_ensure_arm(id)
	roster_changed.emit()


func _on_peer_left(id: int) -> void:
	var arm: RangeArm = _arms.get(id)
	if arm != null:
		arm.clear()
	_arms.erase(id)
	_credit.erase(id)
	_loadout.erase(id)
	_refresh_peers()
	roster_changed.emit()


func _on_players_changed() -> void:
	_local = _resolve_local()
	if _actor <= 0:
		_actor = _local
	_refresh_peers()
	roster_changed.emit()


## Five part indices, the roll seed, and whether the optics fit was run — which is
## everything `GunFactory.assemble_indices` needs to rebuild the identical weapon on
## another machine. Seven integers instead of a resource, and no trust involved: the
## same inputs derive the same damage, the same cone and the same name.
static func _encode_spec(spec: GunSpec) -> PackedInt32Array:
	if spec == null:
		return PackedInt32Array()
	return PackedInt32Array(
		[
			spec.receiver_index(),
			spec.barrel_index(),
			spec.stock_index(),
			spec.grip_index(),
			spec.sight_index(),
			spec.roll_seed,
			0 if spec.zoom_levels.is_empty() else 1,
		]
	)


static func _decode_spec(parts: PackedInt32Array) -> GunSpec:
	if parts.size() < SPEC_FIELDS:
		return null
	return GunFactory.assemble_indices(
		parts[0], parts[1], parts[2], parts[3], parts[4], parts[5], parts[6] != 0
	)
