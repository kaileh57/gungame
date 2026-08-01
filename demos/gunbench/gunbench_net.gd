class_name GunbenchNet
extends Node
## THE GUN BENCH ON THE WIRE. Everything four people share in the bay, and nothing else.
##
## The bench is a room full of state that everybody can see: two stands with a weapon
## on each, six hooks with a weapon on each, two filter dials, one strip lever, and a
## weapon in every player's hands. The host owns all of it. A client sends the press it
## made and draws what it is told, exactly as `res://net/README.md` asks for.
##
## THE WHOLE PROTOCOL IS THREE MESSAGES.
##   `_rq_hello`   client -> host   "I am in the bay, send me the bench"
##   `_rq_action`  client -> host   "I actuated this control, with this value"
##   `_rs_state`   host -> a peer   the WHOLE bench, every time any of it changes
##
## THE SNAPSHOT IS WHOLE AND NOT A DELTA, on purpose. The entire bay is eight weapons,
## two dial detents and a lever — 54 integers, about 260 bytes on the wire — and it
## changes only when somebody presses something, which is a few times a second at the
## very most. A delta protocol here would buy nothing measurable and would cost the one
## thing that actually matters in a four-player session: a client that misses a message
## can never end up looking at a different bench from everybody else, because the next
## press corrects it completely.
##
## A WEAPON IS SIX INTEGERS. `GunSpec` is a hundred derived numbers, every one of them
## a pure function of five part indices and a seed — `GunAssembler.build` is
## `assemble` followed by `fit_optics`, and `GunFactory.assemble_indices` runs exactly
## that pair. So the wire carries the five indices and the seed and the receiver
## rebuilds the identical weapon, name, tint, recoil pattern and all. Sending the
## resource itself would be two orders of magnitude larger and would let a hostile
## packet name any resource path it liked.
##
## NOTHING ARRIVING HERE IS TRUSTED. Every index is checked against `PartLibrary` for
## range AND for kind before it reaches `GunFactory`, because `GunAssembler.assemble`
## takes five `GunPart`s and a null one is a crash rather than a dropped packet. Every
## field of the snapshot is type-checked before it is read. A client's action is
## attributed to the peer id Godot reports as the sender and never to anything inside
## the message, so nobody can grab a weapon on somebody else's behalf.
##
## THE HOST ONLY SENDS TO PEERS IT HAS HEARD FROM. The host reaches the bay first — it
## routes, and everybody follows — but a client's scene can finish loading at any point
## after that, and an RPC addressed to a node that does not exist yet is a red line in
## everybody's console. So a peer is sent nothing until its `_rq_hello` arrives, and
## `hello()` keeps asking until an answer lands, which also covers the reverse race
## where a client somehow loads before the host's own `_ready` has run.

## The host answered: this is the whole bench. Fires on a CLIENT only — the host wrote
## the snapshot and is already in it, and re-applying it would rebuild eight weapons on
## every press for nothing.
signal world_arrived(state: Dictionary)
## A client pressed something. HOST ONLY, and `from_peer` is Godot's sender id.
signal action_arrived(from_peer: int, action: StringName, value: int)
## A peer announced itself in the bay. HOST ONLY. The bench answers it by rolling that
## player a starting weapon and publishing, which is also what sends them the snapshot.
signal peer_arrived(peer_id: int)

## Node name under the demo root. The path has to be identical on every machine for
## Godot to route an RPC to it, so it is a constant and not a choice.
const NODE_NAME: StringName = &"Net"

## A weapon on the wire: receiver, barrel, stock, grip, sight, seed. A sight index of
## -1 is iron sights, which is a real weapon and not an absent one; an EMPTY array is
## the absent one.
const WIRE_SIZE: int = 6
## Part kinds the first five wire slots must actually be, in order. A packet that puts
## a stock index in the barrel slot assembles into something the fit solver never
## produced, so it is refused rather than built.
const WIRE_KINDS: PackedStringArray = ["receiver", "barrel", "stock", "grip", "sight"]

## Seconds between `hello` attempts, and how long a client keeps asking before it gives
## up and says so. Twelve seconds is far past any scene load; a bench still empty then
## is a bug worth a line in the console rather than a spinner forever.
const HELLO_PERIOD: float = 0.35
const HELLO_SECONDS: float = 12.0

## Snapshot keys. Named once here so the writer and the reader cannot drift.
const K_MAIN: StringName = &"a"
const K_RIVAL: StringName = &"b"
const K_PEGS: StringName = &"pegs"
const K_HANDS: StringName = &"hands"
const K_CLASS: StringName = &"cls"
const K_TIER: StringName = &"tier"
const K_STRIP: StringName = &"strip"
## The control that was actuated, its value — which for a hook is WHICH hook — and who
## actuated it, so every machine can flash the same plate. Cosmetic, and carried on the
## state message rather than on a second one because it is only ever true of the state
## that arrived with it.
const K_ACTION: StringName = &"act"
const K_VALUE: StringName = &"val"
const K_BY: StringName = &"by"

## Peers that have announced themselves in this scene. Host only.
var _present: Dictionary = {}
var _hello_clock: float = 0.0
var _hello_left: float = 0.0
var _synced: bool = false


func _ready() -> void:
	set_process(false)


func _process(delta: float) -> void:
	if _synced:
		set_process(false)
		return
	_hello_left -= delta
	if _hello_left <= 0.0:
		set_process(false)
		push_warning("GunbenchNet: the host never sent the bench. The bay stays empty.")
		return
	_hello_clock -= delta
	if _hello_clock > 0.0:
		return
	_hello_clock = HELLO_PERIOD
	_send_hello()


# --- what the bench calls ----------------------------------------------------


## Client: ask the host for the bench, and keep asking until it answers. Harmless and
## free on the host and in single-player, where there is nobody to ask.
func hello() -> void:
	if not _live() or _is_authority():
		return
	_synced = false
	_hello_left = HELLO_SECONDS
	_hello_clock = 0.0
	set_process(true)


## Client: tell the host what was pressed. `value` is the dial detent, the lever's new
## position or the peg's index, depending on the control; controls that carry no value
## pass zero.
func request(action: StringName, value: int) -> void:
	if not _live():
		return
	_rq_action.rpc_id(NetPlayer.HOST_ID, action, value)


## Host: hand the whole bench to everybody who has announced themselves in the bay. In
## single-player there is nobody to hand it to and no socket is touched.
func publish(state: Dictionary) -> void:
	if not _live():
		return
	for peer_id: int in _present.keys():
		if peer_id == NetPlayer.HOST_ID:
			continue
		_rs_state.rpc_id(peer_id, state)


## Host: forget a peer that left, so nothing is addressed to a socket that is gone.
func forget(peer_id: int) -> void:
	_present.erase(peer_id)


## True once this machine has the host's bench. Always true on the host and in
## single-player, where there is nothing to wait for.
func is_synced() -> bool:
	return _synced or _is_authority()


# --- a weapon, in six integers ----------------------------------------------


## `spec` as the five part indices and the seed. An empty array means "no weapon",
## which is a state both stands and every hook can genuinely be in.
static func encode_spec(spec: GunSpec) -> PackedInt32Array:
	if spec == null or spec.part_indices.size() < 4:
		return PackedInt32Array()
	return PackedInt32Array(
		[
			spec.receiver_index(),
			spec.barrel_index(),
			spec.stock_index(),
			spec.grip_index(),
			spec.sight_index(),
			spec.roll_seed,
		]
	)


## Rebuild the weapon `encode_spec` wrote down, or null. Optics ARE fitted, because
## `GunFactory.roll` fits them and the two have to come out identical — a bench card
## that read "iron sights" on one machine and "3.2x / 6.1x" on another would be the
## whole point of this file failing quietly.
static func decode_spec(wire: PackedInt32Array) -> GunSpec:
	if not is_wire(wire):
		return null
	return GunFactory.assemble_indices(wire[0], wire[1], wire[2], wire[3], wire[4], wire[5], true)


## Whether `wire` names five real parts of the five right kinds. An empty array is a
## legal absent weapon and is NOT a wire, so callers test it first.
static func is_wire(wire: PackedInt32Array) -> bool:
	if wire.size() != WIRE_SIZE:
		return false
	for slot: int in 4:
		if not _is_part(wire[slot], StringName(WIRE_KINDS[slot])):
			return false
	# The sight is the one optional part: -1 is a weapon with iron sights.
	return wire[4] < 0 or _is_part(wire[4], &"sight")


## Range AND kind, in that order. `PartLibrary.part` raises on an out-of-range index,
## so the range test has to come first or a malformed packet fills the console.
static func _is_part(index: int, kind: StringName) -> bool:
	if index < 0 or index >= PartLibrary.count():
		return false
	var part: GunPart = PartLibrary.part(index)
	return part != null and part.kind == kind


# --- the three messages ------------------------------------------------------

## A client has arrived in the bay. Remember it and hand it the bench.
@rpc("any_peer", "reliable")
func _rq_hello() -> void:
	if not _is_authority():
		return
	var from: int = multiplayer.get_remote_sender_id()
	if from <= 0 or NetGame.player(from) == null:
		return
	_present[from] = true
	peer_arrived.emit(from)


## A client pressed something. The sender is Godot's, never the packet's.
@rpc("any_peer", "reliable")
func _rq_action(action: StringName, value: int) -> void:
	if not _is_authority():
		return
	var from: int = multiplayer.get_remote_sender_id()
	if from <= 0 or NetGame.player(from) == null:
		return
	# A peer that presses before it says hello is still in the bay; take the press and
	# take the hint, so its snapshot goes out with everybody else's.
	_present[from] = true
	action_arrived.emit(from, action, value)


## The whole bench, from the host.
@rpc("authority", "reliable")
func _rs_state(state: Dictionary) -> void:
	_synced = true
	set_process(false)
	world_arrived.emit(state)


# --- state -------------------------------------------------------------------


func _send_hello() -> void:
	if not _live():
		return
	_rq_hello.rpc_id(NetPlayer.HOST_ID)


## Whether there is a session to speak into at all. False in single-player, where every
## send in this file is skipped and every decision is already local.
func _live() -> bool:
	return NetGame.is_networked() and multiplayer.has_multiplayer_peer()


func _is_authority() -> bool:
	return NetGame.is_authority()
