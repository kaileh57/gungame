class_name NetColors
extends RefCounted
## Player colour, for the things that DRAW players.
##
## The table itself is not here. `NetPlayer.SLOT_COLORS` owns it — the roster assigns
## slots, so the roster owns what a slot looks like, and a second table would be a
## second truth that drifts the first time somebody edits one of them. This file is the
## façade the avatar side uses, plus the two transforms of a player colour that only
## something drawing a player needs:
##
##   `text()`   the same hue lifted toward bone. A saturated colour at full value is
##              unreadable as small type over pale sand, and bone-white alone loses its
##              owner. The lift keeps the hue as identity and keeps the glyphs legible.
##   `tint()`   the same colour as a MULTIPLIER for the avatar shell, whose albedo is a
##              light neutral. The scrap shader does `albedo * tint * COLOR`, so this is
##              what the instance uniform wants.
##
## Host is slot 0 and slot 0 is red. That is `NetPlayer`'s rule and this file only
## repeats it.

## Peer id the server always has under Godot's high-level multiplayer.
const HOST_ID: int = NetPlayer.HOST_ID
## How many players the whole design is built for. Four. Not "at least four".
const MAX_PLAYERS: int = NetPlayer.MAX_PLAYERS

## How far a colour is lifted toward bone before it is used as small type.
const TEXT_LIFT: float = 0.42
## Bone. What a lifted player colour lifts toward.
const TEXT_BASE: Color = Color(0.94, 0.92, 0.88)
## The project's ink, which every mark on the avatar side is outlined in.
const INK: Color = Color(0.035, 0.031, 0.028, 1.0)


## The colour of a slot. Out-of-range slots wrap rather than erroring, because a fifth
## player is a bug in the lobby and not a reason to stop rendering.
static func of_slot(slot: int) -> Color:
	return NetPlayer.SLOT_COLORS[posmod(slot, NetPlayer.SLOT_COLORS.size())]


## Name of a slot's colour, for UI that has to say which player it means in words.
static func slot_name(slot: int) -> String:
	return NetPlayer.SLOT_NAMES[posmod(slot, NetPlayer.SLOT_NAMES.size())]


## The readable version: same hue, lifted toward bone. Used by every nameplate and by
## the hover label.
static func text(color: Color) -> Color:
	return color.lerp(TEXT_BASE, TEXT_LIFT)


## The version to push into the `tint` instance uniform of a shell whose albedo is a
## light neutral. Slightly lifted, because a multiply of two values below one lands
## darker than either and a player at slot 0's value 0.63 comes out nearly black.
static func tint(color: Color) -> Color:
	return color.lerp(Color.WHITE, 0.18)
