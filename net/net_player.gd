class_name NetPlayer
extends RefCounted
## One person in a session: the host, or one of the three guests.
##
## This is IDENTITY plus the small amount of per-person state every demo needs in
## order to DRAW somebody — who they are, what colour they read as, where their
## laser pointer is landing, and a handle on whatever node is currently their
## body. It is not a player controller and it is not general replicated state.
## `NetGame` owns the roster and replicates `aim_point` / `aim_valid`; nothing
## else on here goes over the wire.
##
## `NetGame` hands these out and keeps them alive. Do not construct one, and do
## not hold one past a `players_changed` unless you re-check it with
## `NetGame.player(id)` — except for `NetGame.local_player()`, which is the same
## object for the whole run of the process and is safe to cache forever.
##
## In pure single-player there is still exactly one of these: you, slot 0, red.
## That is deliberate, so a nameplate or a laser renderer does not need an
## `if NetGame.is_networked()` branch to work on the title screen.

## The host is always peer 1 in Godot's high-level multiplayer, and this project
## makes the host authoritative, so `peer_id == HOST_ID` and "is the authority"
## are the same question asked twice.
const HOST_ID: int = 1

## Longest username the roster carries. Sixteen characters fits above an avatar
## at ten metres without the label being wider than the body it labels.
const MAX_NAME: int = 16

## Four, and this is where the number lives. `NetGame.MAX_PLAYERS` is an alias of
## it because that is the name the API publishes; `NetRoster` reads it directly.
## It is here rather than on the autoload so that a `class_name` never has to name
## an autoload to find out how many players there can be — see STATUS trap 21.
##
## `SLOT_COLORS` below has exactly this many entries and must keep having them.
const MAX_PLAYERS: int = 4

## One identity colour per slot; slot 0 is always the host and is always RED.
##
## These are picked from `art/palette.gd` and they are picked for SEPARATION, not
## for prettiness — four bodies at forty metres on bleached sand have to be told
## apart in one glance. Measured as HSV:
##
##     slot 0  #a03636  hue   0  sat .66  val .63   the palette's red
##     slot 1  #78adc8  hue 200  sat .40  val .78   the palette's one cold colour
##     slot 2  #e6c14f  hue  45  sat .66  val .90   the brightest thing available
##     slot 3  #8a9a6b  hue  80  sat .31  val .60   sage, the only green in here
##
## The tightest hue gap is gold to sage at 35°, and those two are 0.30 apart in
## value, which is the largest value gap in the set — so every adjacent pair
## separates on at least one axis by a lot. Nothing here is within 45° of the
## host's red, which is the one colour a player must never mistake.
const SLOT_COLORS: PackedColorArray = [
	Palette.TIER_HAZARD,
	Palette.FACTION_CHOIR,
	Palette.GOLD,
	Palette.TIER_COBBLED,
]

## What to call each slot in UI. "RED" is the host, always.
const SLOT_NAMES: PackedStringArray = ["RED", "BLUE", "GOLD", "SAGE"]

## Godot's peer id. 1 is the host. Unique for the life of the session and reused
## by nothing: a peer that drops and rejoins comes back with a new id.
var peer_id: int = HOST_ID

## 0..3. Decides the colour and the position in every player list. The host holds
## slot 0 for as long as the session lasts; guests take the lowest free slot, so a
## guest that leaves frees their colour for the next one.
var slot: int = 0

## What this person calls themselves. Already sanitised and already made unique
## within the session by the host — two people who both type "Kellen" arrive as
## "Kellen" and "Kellen 2".
var username: String = ""

## True on exactly one of these, on every machine: the person sitting at it.
var is_local: bool = false

## Where this player's laser pointer is landing, in world space. Replicated by
## `NetGame` at 20 Hz. Meaningless unless `aim_valid` is true.
##
## Draw a DOT here for every player except the local one — the local player has a
## crosshair and does not need to be told where they are pointing.
var aim_point: Vector3 = Vector3.ZERO

## False when this player's aim ray hit nothing worth pointing at (sky, out of
## range, or they have not aimed yet). Do not draw their dot.
var aim_valid: bool = false

## Whatever node is currently this player's body, or null. Written by whoever
## spawns avatars; `NetGame` never touches it. ALWAYS test it with
## `is_instance_valid()` before use — a scene change frees every avatar in the
## world and this reference goes stale without warning.
var avatar: Node3D = null


## This player's identity colour. Derived from the slot rather than stored, so it
## cannot go stale when a slot is reassigned.
func color() -> Color:
	return SLOT_COLORS[clampi(slot, 0, SLOT_COLORS.size() - 1)]


## "RED", "BLUE", "GOLD" or "SAGE" — the name of the colour, for UI that has to
## say which player it means in words rather than in paint.
func slot_name() -> String:
	return SLOT_NAMES[clampi(slot, 0, SLOT_NAMES.size() - 1)]


## True on the authoritative machine's player. Everything that decides an outcome
## belongs to this one; see `NetGame.is_authority()`.
func is_host() -> bool:
	return peer_id == HOST_ID


## The name to put on screen. Never empty, so a label never renders blank.
func display_name() -> String:
	if username.is_empty():
		return "PLAYER %d" % (slot + 1)
	return username
