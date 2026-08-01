class_name FirefightWarWire
extends RefCounted
## The firefight's wire format: constants, and the four primitives every packet in
## it is built out of. No state, no nodes, nothing to instance — this is the
## agreement between `FirefightWarLink` (which fills packets) and
## `FirefightWarPuppets` (which empties them), written down once so the two can
## never drift.
##
## WHY THIS IS NOT A MultiplayerSynchronizer. A hundred bodies at sixty hertz
## through Godot's replication is a hundred node paths, a hundred visibility
## checks and a Variant per property per tick, and it is the one thing the brief
## for this demo names as the wrong answer. What a spectator actually needs is a
## POSITION and a FACING per body, and the rest of a creature — its gait, its
## legs, its collapse, its shadow — is already a deterministic function of those
## two on every machine, because every machine loaded the same baked rig. So the
## wire carries the two, quantised, and the rig does the rest for free.
##
## THE NUMBERS. A position is three signed 16-bit fixed-point values at 1/32 m,
## which is 3.1 cm of resolution over +/- 1023 m. The arena is 176 m across and
## its ground slab 300 m, so the range is never approached and the resolution is
## an order below anything visible on a body that is 30 pixels tall at its
## nearest. A facing is one byte over the full turn, 1.4 degrees, which is under
## a tenth of the width of a creature at forty metres.
##
## That makes a moving body EIGHT BYTES — one slot, six position, one yaw —
## against the 30-odd a naive Vector3 + quaternion costs, before any header. At
## the rates `FirefightWarLink` actually sends, a hundred bodies is single-digit
## kilobytes a second per client.
##
## EVERY PACKET STARTS WITH THE SAME EIGHT BYTES so a reader can classify one
## without knowing anything else: a magic word, a kind, a pad, and a sequence
## number. The magic word is what lets this share the raw channel politely with
## `NetPresence`, which is already on it — anything that does not open with
## `WAR1` is somebody else's and is dropped before a single field is decoded.

## First four bytes of every packet: "WAR1", little-endian.
const MAGIC: int = 0x31524157
## `SceneMultiplayer.send_bytes` channel. Zero, deliberately: channel zero is the
## one ENet is always created with, and Godot already splits it into a reliable
## and an unreliable sub-channel by transfer mode. Asking for a numbered channel
## buys nothing here and risks a peer that negotiated fewer of them.
const CHANNEL: int = 0
## Bytes before the first record. magic u32, kind u8, pad u8, sequence u16.
const HEADER: int = 8

## Client -> host. "My firefight scene is up; send me everything you have."
const K_HELLO: int = 1
## Client -> host. Where this client's camera is, for relevance. 4 Hz.
const K_VIEW: int = 2
## Client -> host. "I operated the sim-rate dial." Intent, not fact.
const K_DIAL: int = 3
## Host -> client, reliable. Bodies that entered play. Also the join baseline.
const K_SPAWN: int = 4
## Host -> client, unreliable. Where bodies are. The stream.
const K_MOVE: int = 5
## Host -> client, unreliable. Rounds fired, for tracers, flashes and powder.
const K_SHOT: int = 6
## Host -> client, reliable. Bodies that died, and what killed them from where.
const K_DIE: int = 7
## Host -> client, reliable. Bodies the pool took back.
const K_GONE: int = 8
## Host -> client, unreliable. The scoreboard, the hotspot and the sim rate.
const K_STATE: int = 9

## Record widths, in bytes. Named so a size check reads as arithmetic. Every
## host -> client packet is a header followed by a whole number of records of one
## width, so no packet carries a count: the reader divides.
const R_SPAWN: int = 9
const R_MOVE: int = 8
const R_SHOT: int = 14
## A death is one byte, and it is worth saying why it is not more. `EnemyActor`
## takes a `from_position` and turns toward it — but it turns by setting
## `_face_dir`, which only reaches the transform from `_tick_facing`, and
## `_physics_process` stops calling that the instant `alive` goes false. The
## bearing a body was shot from is therefore invisible on a corpse, so sending it
## would be six bytes a death for nothing.
const R_DIE: int = 1
const R_GONE: int = 1
const R_ZONE: int = 6
## Bytes of `K_STATE` before the zone array starts.
const STATE_FIXED: int = 18

## Fixed-point divisor for a world position. 1/32 m.
const POS_SCALE: float = 32.0
## Half the representable range, in metres. `POS_SCALE * POS_LIMIT` must stay
## inside a signed 16-bit integer, and 32 * 1023 = 32736 does.
const POS_LIMIT: float = 1023.0
## Slot ids are one byte, so this is the ceiling on bodies in play at once. Three
## spawners at `max_alive` 32 is 96, corpses included, so there is 2.5x of room.
const MAX_SLOTS: int = 255
## Written into a shot record when the round hit nothing. Not a `VFXSurface.Kind`.
const SURFACE_NONE: int = 255


## An empty packet of `kind`, header filled in, ready to have records appended or
## `resize`d to its full length and encoded into.
static func head(kind: int, seq: int = 0) -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(HEADER)
	bytes.encode_u32(0, MAGIC)
	bytes.encode_u8(4, kind)
	bytes.encode_u8(5, 0)
	bytes.encode_u16(6, seq & 0xFFFF)
	return bytes


## Whether a raw packet off the shared channel is one of ours. Checked before any
## other byte is looked at.
static func is_ours(packet: PackedByteArray) -> bool:
	return packet.size() >= HEADER and packet.decode_u32(0) == MAGIC


static func kind_of(packet: PackedByteArray) -> int:
	return packet.decode_u8(4)


static func seq_of(packet: PackedByteArray) -> int:
	return packet.decode_u16(6)


## How many whole records of `width` a packet has room for after its header.
static func record_count(packet: PackedByteArray, width: int) -> int:
	return (packet.size() - HEADER) / maxi(width, 1)


static func put_pos(bytes: PackedByteArray, at: int, p: Vector3) -> void:
	bytes.encode_s16(at, _fixed(p.x))
	bytes.encode_s16(at + 2, _fixed(p.y))
	bytes.encode_s16(at + 4, _fixed(p.z))


static func get_pos(bytes: PackedByteArray, at: int) -> Vector3:
	return Vector3(
		float(bytes.decode_s16(at)) / POS_SCALE,
		float(bytes.decode_s16(at + 2)) / POS_SCALE,
		float(bytes.decode_s16(at + 4)) / POS_SCALE
	)


## A heading as one byte over the full turn. Sign and wrap are both handled here
## so no caller has to think about either.
static func put_yaw(bytes: PackedByteArray, at: int, yaw: float) -> void:
	bytes.encode_u8(at, int(round(wrapf(yaw, 0.0, TAU) / TAU * 256.0)) & 0xFF)


static func get_yaw(bytes: PackedByteArray, at: int) -> float:
	return float(bytes.decode_u8(at)) / 256.0 * TAU


## Whether `seq` is newer than `last` in a 16-bit sequence space that wraps. The
## unreliable streams carry their own sequence because they are sent UNSEQUENCED
## — ENet then never discards one of ours to make way for somebody else's packet
## on the shared channel, and never blocks the head of the line. The cost of that
## is having to spot a stale packet here, which is this one comparison.
static func newer(seq: int, last: int) -> bool:
	return ((seq - last) & 0xFFFF) < 0x8000 and seq != last


static func _fixed(v: float) -> int:
	return int(round(clampf(v, -POS_LIMIT, POS_LIMIT) * POS_SCALE))
