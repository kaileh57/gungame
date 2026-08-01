extends Node
## Autoload `Factions`. Who shoots whom, what they paint on their gear, what they
## carry, and the ledger of who owns which patch of dirt.
##
## Territory lives in the nested `Territory` ledger rather than on the zone nodes,
## so ownership outlives a scene swap and this autoload never has to know the
## `AITerritoryZone` node type exists — that would otherwise be a parse cycle,
## since the zone node reads its owner back out of here on `_ready`.
##
## Everything off the diagonal starts HOSTILE. The three of them have been at each
## other's throats since long before the player showed up, and nobody in the ash
## flats is looking for a friend.

## A pair's stance changed. Always emitted once per change, for the ordered pair
## as written; the matrix itself is kept symmetric.
signal stance_changed(a: int, b: int, new_stance: int)
## A body stopped existing. Broadcast to everyone because the OTHER factions are
## who needs it: the faction that owned the body already knows, and the faction
## that shot it is the one still holding a stale contact and a fire order on a
## corpse. `AIBlackboard` listens and retires the contact; the squads that were
## engaging it call the target down and pick another.
##
## Routed through the autoload rather than blackboard-to-blackboard because a
## blackboard has no way to enumerate the others and should not learn one — that
## coupling is exactly what a signal exists to avoid.
signal body_lost(faction: int, target_id: int, position: Vector3)

enum F { SCAV, FOUNDRY, CHOIR }
enum Stance { ALLIED, NEUTRAL, HOSTILE }

const COUNT: int = 3
## Pseudo-faction for the player. Hostile to all three, allied with none.
const PLAYER: int = -1
## No allegiance at all — never a target, never a shooter.
const NEUTRAL_ID: int = -2

const NAMES: PackedStringArray = ["SCAV", "FOUNDRY", "CHOIR"]
## Three-letter stencil each faction sprays on its gear, its crates and its dead.
const MARKS: PackedStringArray = ["RAG", "FDY", "CHR"]

## Relative weight each faction puts on each `GunSpec.archetype` when it arms a
## body. Weights are drawn against their own sum, so they need not total anything.
##
## The three read as three different wars. The Scavs carry whatever came out of
## the pile and fight at spitting distance. The Foundry issues belt-fed and
## bolt-action iron heavy enough to be a two-man job. The Choir picks one shot and
## makes it count, and treats a wide cone as a moral failure.
const WEAPON_PREFERENCE: Array = [
	{
		&"Chopped auto": 22.0,
		&"Snubnose": 16.0,
		&"Shotgun": 14.0,
		&"Submachine gun": 14.0,
		&"Sidearm": 12.0,
		&"Carbine": 10.0,
		&"Auto shotgun": 6.0,
		&"Hybrid": 6.0,
	},
	{
		&"Machine gun": 20.0,
		&"Auto battle rifle": 18.0,
		&"Battle rifle": 16.0,
		&"Slug gun": 12.0,
		&"Hand cannon": 10.0,
		&"Launcher": 8.0,
		&"Assault rifle": 8.0,
		&"Carbine": 8.0,
	},
	{
		&"Sniper": 22.0,
		&"Marksman carbine": 20.0,
		&"Assault rifle": 16.0,
		&"Battle rifle": 14.0,
		&"Hand cannon": 12.0,
		&"Sidearm": 10.0,
		&"Carbine": 6.0,
	},
]

## Slots of the array `comms()` hands back. One packed read per faction per
## command tick beats ten accessors, and `AIComms` indexes it by these names.
const COMMS_VOICE: int = 0
const COMMS_RADIO: int = 1
const COMMS_LATENCY: int = 2
const COMMS_RELAY: int = 3
const COMMS_DISCIPLINE: int = 4
const COMMS_ERROR_BASE: int = 5
const COMMS_ERROR_RANGE: int = 6
const COMMS_ERROR_DOUBT: int = 7
const COMMS_RELAY_ERROR: int = 8
const COMMS_RELAY_CONF: int = 9
const COMMS_FIELDS: int = 10

@export_group("Doctrine: Scav")
## How readily this faction commits to a fight it has not already won. Scales
## squad push distance and how low a confidence a contact needs to be chased.
@export_range(0.1, 2.0, 0.01) var scav_aggression: float = 1.25
## What cover, reloading and suppression are worth to it. High caution buys
## survivors; low caution buys ground.
@export_range(0.1, 2.0, 0.01) var scav_caution: float = 0.65
## How tightly its squads stay together. Low cohesion scatters into a brawl.
@export_range(0.1, 2.0, 0.01) var scav_cohesion: float = 0.70
## Appetite for other people's territory. Multiplies pressure it applies abroad.
@export_range(0.1, 2.0, 0.01) var scav_expansion: float = 1.10

@export_group("Doctrine: Foundry")
@export_range(0.1, 2.0, 0.01) var foundry_aggression: float = 0.95
@export_range(0.1, 2.0, 0.01) var foundry_caution: float = 1.20
@export_range(0.1, 2.0, 0.01) var foundry_cohesion: float = 1.35
@export_range(0.1, 2.0, 0.01) var foundry_expansion: float = 1.00

@export_group("Doctrine: Choir")
@export_range(0.1, 2.0, 0.01) var choir_aggression: float = 1.05
@export_range(0.1, 2.0, 0.01) var choir_caution: float = 1.05
@export_range(0.1, 2.0, 0.01) var choir_cohesion: float = 1.10
@export_range(0.1, 2.0, 0.01) var choir_expansion: float = 0.95

@export_group("Comms")
## Metres a raised voice carries. Physics rather than doctrine, so it is one value
## for everybody: a faction with no radio can only be heard this far.
@export_range(4.0, 120.0, 0.5) var voice_range: float = 26.0
## Metres of error on a called position before range or doubt are added. The floor
## on how precise anybody can be about anywhere.
@export_range(0.0, 8.0, 0.05) var callout_error_base: float = 0.35
## Extra metres of error per metre between the caller and what it is calling. This
## is the term that makes a far-off spotter's report vague and a body at ten
## metres useful — turn it to zero and the faction is telepathic again.
@export_range(0.0, 0.4, 0.001) var callout_error_range: float = 0.055
## How much a caller's own uncertainty multiplies the error. At one, a call made
## at zero confidence is twice as wrong as one made at full.
@export_range(0.0, 4.0, 0.05) var callout_error_doubt: float = 1.15
## Extra error a report picks up on being passed on, as a fraction of what it
## already carried. Nothing said twice survives intact.
@export_range(0.0, 2.0, 0.05) var relay_error_scale: float = 0.60
## What a relayed report's confidence is multiplied by. Below one, so second-hand
## knowledge decays out of the blackboard faster than first-hand.
@export_range(0.1, 1.0, 0.01) var relay_confidence_scale: float = 0.82

@export_group("Comms: Scav")
## Metres a relay reaches. ZERO IS MEANINGFUL: it means this faction has no radios
## at all, and everything it knows travels at shouting distance. The Scavs are the
## faction that does not have any, and it is most of why they fight as a mob.
@export_range(0.0, 400.0, 1.0) var scav_radio_range: float = 0.0
## Seconds of drag on every call before the speaker's own squad hears it.
@export_range(0.0, 2.0, 0.01) var scav_comms_latency: float = 0.30
## Seconds again before the rest of the faction hears the relay.
@export_range(0.0, 8.0, 0.05) var scav_relay_latency: float = 1.60
## How well this faction calls a position and how briskly it says it. One is
## drilled; below one is a crowd talking over itself and guessing at ranges.
@export_range(0.2, 3.0, 0.01) var scav_comms_discipline: float = 0.55

@export_group("Comms: Foundry")
@export_range(0.0, 400.0, 1.0) var foundry_radio_range: float = 145.0
@export_range(0.0, 2.0, 0.01) var foundry_comms_latency: float = 0.16
@export_range(0.0, 8.0, 0.05) var foundry_relay_latency: float = 0.55
@export_range(0.2, 3.0, 0.01) var foundry_comms_discipline: float = 1.35

@export_group("Comms: Choir")
@export_range(0.0, 400.0, 1.0) var choir_radio_range: float = 95.0
@export_range(0.0, 2.0, 0.01) var choir_comms_latency: float = 0.12
@export_range(0.0, 8.0, 0.05) var choir_relay_latency: float = 0.80
@export_range(0.2, 3.0, 0.01) var choir_comms_discipline: float = 1.60

@export_group("Territory")
## Ledger ticks per second. Territory moves on a human timescale; running it any
## faster only burns cycles.
@export_range(0.5, 20.0, 0.5) var territory_tick_hz: float = 4.0
## Let this autoload drive the ledger from `_process`. A director or a headless
## sim that wants to own the clock turns this off and calls `tick_territory`.
@export var territory_auto_tick: bool = true
## Pressure bled off per second with nobody pushing. The whole war runs on this
## number: too high and nothing is ever taken, too low and the map freezes.
@export_range(0.001, 0.5, 0.001) var pressure_decay: float = 0.030
## Multiplier on decay for the faction that already holds the zone. Below one
## because a garrison is not fighting its way in.
@export_range(0.0, 1.0, 0.01) var owner_decay_scale: float = 0.35
## Pressure the holder regains per second simply by standing on it.
@export_range(0.0, 0.5, 0.001) var garrison_regen: float = 0.020
## Ceiling on what a garrison alone is worth, before it is thinned by how much
## of the map that faction is trying to hold. Strictly below one, and it has to
## be: pressure clamps at one, so a garrison that regenerated all the way to the
## top could never be out-pushed and the map would freeze solid.
@export_range(0.2, 0.95, 0.01) var garrison_ceiling: float = 0.60
## How far ahead of the defender an attacker must get before the zone flips,
## scaled by the zone's `value`. This is the hysteresis that stops a border zone
## changing hands four times a minute.
@export_range(0.01, 0.9, 0.01) var capture_margin: float = 0.18
## Extra margin multiplier on a faction's own home zone. Home ground is dear.
@export_range(1.0, 4.0, 0.05) var home_margin_scale: float = 2.10
## Standing difficulty of taking unclaimed ground.
@export_range(0.0, 0.9, 0.01) var neutral_hold: float = 0.12
## Pressure the winner is left holding immediately after a capture. Well under
## one, so the ground it has just taken is takeable back.
@export_range(0.1, 1.0, 0.01) var post_capture_pressure: float = 0.55
## What a loser keeps on a zone it has just lost, as a fraction of what it had.
@export_range(0.0, 1.0, 0.01) var post_capture_residue: float = 0.45
## Pressure at or above which a faction counts as present for contest purposes.
@export_range(0.01, 0.9, 0.01) var contest_threshold: float = 0.15
## How hard a faction's push wears down its rivals' hold on the same zone, as a
## multiple of what it gains itself. This is the term that makes the ledger read
## "who is winning this ground" instead of "is anybody standing on it".
##
## THE LEDGER CANNOT HOLD A FRONT LINE WITHOUT IT, and the failure is invisible
## until it is measured. Pressure accumulates against a bleed of 0.03/s while
## eight bodies inside a cylinder push 0.4/s, so anybody with a single body on a
## zone saturates their own clamp within seconds and the stored value carries no
## information at all about who is winning. Cap the holder (see
## `_garrison_hold_for`) and the attacker still saturates, so a contested zone
## changes hands the instant it is allowed to: measured with this at zero,
## `the_pan`, `tank_farm` and `slag_road` each flipped on a 10.0 s metronome for
## three minutes — forty-one captures that were the dwell timer running out and
## not the fighting.
##
## It wears rivals down MULTIPLICATIVELY rather than subtracting a fixed amount,
## and that is the whole reason it works on two maps at once. Subtracting settles
## at `gain_mine - gain_yours`, which depends on the absolute size of the fight:
## measured, a subtractive version fixed the firefight and froze the nine-zone
## headless war solid, 9 captures against 23 and nothing at all in the final
## third, because five bodies against five nets exactly zero. Wearing down
## settles at `gain_mine / (attrition * gain_yours)`, which depends only on the
## RATIO: even presence parks both sides at `1 / attrition` whatever the numbers,
## and a side with half again as many bodies pulls away quadratically.
##
## Two is a floor derived rather than picked, and it was worth deriving because
## the sweep pulls the other way. Even presence parks both sides at `1/attrition`;
## an attacker takes a ring zone at the holder's ceiling plus that zone's margin,
## which on this map is 0.52, so anything under 1.9 hands a zone to whoever merely
## turns up in equal numbers — and from there the ledger saturates for both sides
## and `capture_dwell` alone decides when the banner changes. Measured: at 1.0 the
## count is higher (median 10 against 3 over 150 s) and it is a lie —
## `tank_farm` flipped at 126.0, 136.0 and 146.0 s, exactly one dwell apart, and
## a third of every trial's flips were rebounds. `verify_firefight` now measures
## that share directly rather than trusting the total.
@export_range(0.0, 6.0, 0.05) var contest_attrition: float = 2.00
## Seconds a zone is settled after changing hands, before it may change again.
##
## THIS IS AN ANTI-STROBE RULE, NOT A CLAMP ON WHO WINS. Ownership is a discrete
## label on a continuous quantity, and where both sides have bodies standing
## inside the same cylinder both of them push at full rate, so the label chatters
## across the threshold as fast as the ledger ticks. Measured on the firefight
## demo with this at zero: `choir_house` changed hands sixteen times in forty
## seconds, in pairs 0.5 to 1.0 s apart, and `tank_farm` eight times in thirty
## — a banner nobody could read, and a capture count that flattered a war which
## was really one zone flapping. It delays no capture that is earned; it refuses
## to relabel the same ground twice inside the time it takes to look at it.
@export_range(0.0, 60.0, 0.5) var capture_dwell: float = 10.0
## How much harder a faction pushes for owning less of the map. This is the
## anti-stalemate term: at zero the strongest faction rolls the board and the war
## ends, and a war that ends is not a level.
##
## Raised from 1.30 with the ceiling and attrition rules in place, because the two
## of them made this term legible for the first time — while every holder sat
## pinned at the 1.0 clamp it could not matter what anybody pushed. Measured over
## five trials each at 150 graded seconds: 1.30 with `overextension_penalty` at
## 1.10 returned 1/2/3/1 ownership changes; this pair returns 6/10/10/12/12, and
## turns over `the_pan` — the ground the whole map is arranged around — four to
## nine times a trial instead of never.
@export_range(0.0, 3.0, 0.05) var underdog_bonus: float = 1.80
## How much faster a faction bleeds pressure for owning more of the map, and how
## much thinner its garrisons are. The anti-runaway term — a wide empire is a thin
## one. See `_garrison_ceiling_for`, which is where it does most of its work now
## that the ceiling is actually enforced.
@export_range(0.0, 3.0, 0.05) var overextension_penalty: float = 1.60
## How much of the underdog bonus also applies to holding on to pressure already
## built, rather than only to building it. Without this a beaten faction can
## push hard and still never accumulate anything, because the bleed takes it
## back between ticks — and the front line quietly sets like concrete.
@export_range(0.0, 1.0, 0.01) var underdog_grip: float = 0.60

## The territory ledger. Zones register into it; squads push against it.
var territory: Territory = Territory.new()

var _stance: PackedInt32Array = PackedInt32Array()
var _tick_accum: float = 0.0


func _ready() -> void:
	reset_stances()
	set_physics_process(true)


## THE LEDGER RUNS ON THE PHYSICS CLOCK, and it has to. Everything that feeds it
## is produced on the physics frame — `AISquad` publishes its pressure from a
## director's `_physics_process`, and the bodies whose positions decide that
## pressure move there too. Ticking it from `_process` instead, which is what this
## did, runs the war off a clock that free-runs: under `--headless` the idle frame
## is unbounded and under load it is not, so the same build advanced the territory
## a different distance per metre walked on every run. That is not a tuning
## difference, it is a different simulation, and it was one of the reasons the
## firefight acceptance gate could not be reproduced twice.
func _physics_process(delta: float) -> void:
	if not territory_auto_tick:
		return
	_tick_accum += delta
	var step: float = 1.0 / maxf(territory_tick_hz, 0.5)
	while _tick_accum >= step:
		_tick_accum -= step
		tick_territory(step)


## Restore the default matrix: allied with yourself, hostile to everyone else.
func reset_stances() -> void:
	_stance.resize(COUNT * COUNT)
	for a: int in COUNT:
		for b: int in COUNT:
			_stance[a * COUNT + b] = Stance.ALLIED if a == b else Stance.HOSTILE


## Stance of `a` toward `b`. Handles the two pseudo-factions without indexing the
## matrix, so `PLAYER` and `NEUTRAL_ID` are always safe to pass.
func stance(a: int, b: int) -> int:
	if a == NEUTRAL_ID or b == NEUTRAL_ID:
		return Stance.NEUTRAL
	if a == b:
		return Stance.ALLIED
	if a == PLAYER or b == PLAYER:
		return Stance.HOSTILE
	if a < 0 or a >= COUNT or b < 0 or b >= COUNT:
		return Stance.NEUTRAL
	return _stance[a * COUNT + b]


func hostile(a: int, b: int) -> bool:
	return stance(a, b) == Stance.HOSTILE


func allied(a: int, b: int) -> bool:
	return stance(a, b) == Stance.ALLIED


## Write a stance symmetrically. Pseudo-factions are fixed and are rejected.
func set_stance(a: int, b: int, new_stance: int) -> void:
	if a < 0 or a >= COUNT or b < 0 or b >= COUNT or a == b:
		push_warning("Factions: cannot set stance for %d/%d." % [a, b])
		return
	if _stance[a * COUNT + b] == new_stance:
		return
	_stance[a * COUNT + b] = new_stance
	_stance[b * COUNT + a] = new_stance
	stance_changed.emit(a, b, new_stance)


func faction_name(faction: int) -> String:
	if faction == PLAYER:
		return "PLAYER"
	if faction < 0 or faction >= COUNT:
		return "NEUTRAL"
	return NAMES[faction]


func mark(faction: int) -> String:
	if faction < 0 or faction >= COUNT:
		return "---"
	return MARKS[faction]


## Body colour: what the faction's gear is painted. Straight off the ART palette.
func faction_color(faction: int) -> Color:
	if faction == PLAYER:
		return Palette.PAPER
	if faction < 0 or faction >= COUNT:
		return Palette.CANVAS
	return Palette.faction_color(faction)


## Stencil colour: the accent the faction daubs its mark in. Deliberately the
## complement of the body colour so an insignia reads at range.
func insignia_color(faction: int) -> Color:
	match faction:
		F.SCAV:
			return Palette.ACCENT_ORANGE
		F.FOUNDRY:
			return Palette.GOLD
		F.CHOIR:
			return Palette.BONE
		PLAYER:
			return Palette.INK
	return Palette.CANVAS


# --- doctrine ----------------------------------------------------------------


## The four doctrine scalars as `[aggression, caution, cohesion, expansion]`.
## Returned as one array because every caller wants at least two of them, and
## four separate accessors would be four times the surface for no gain.
func doctrine(faction: int) -> PackedFloat32Array:
	match faction:
		F.SCAV:
			return PackedFloat32Array(
				[scav_aggression, scav_caution, scav_cohesion, scav_expansion]
			)
		F.FOUNDRY:
			return PackedFloat32Array(
				[foundry_aggression, foundry_caution, foundry_cohesion, foundry_expansion]
			)
		F.CHOIR:
			return PackedFloat32Array(
				[choir_aggression, choir_caution, choir_cohesion, choir_expansion]
			)
	return PackedFloat32Array([1.0, 1.0, 1.0, 1.0])


## The three scalars anything hot actually asks for, read straight off the export
## rather than through `doctrine`.
##
## `doctrine` builds a `PackedFloat32Array` on every call, and these three are
## reached from inside the per-squad command tick — `aggression` from the focus
## solve, `cohesion` from the state machine, `expansion` from the pressure publish.
## That is three allocations per squad per tick, nine squads deep, for three floats.
func aggression(faction: int) -> float:
	match faction:
		F.SCAV:
			return scav_aggression
		F.FOUNDRY:
			return foundry_aggression
		F.CHOIR:
			return choir_aggression
	return 1.0


## How tightly this faction's squads stay together. Low cohesion scatters into a
## brawl; the squad divides its cohesion radius by it.
func cohesion(faction: int) -> float:
	match faction:
		F.SCAV:
			return scav_cohesion
		F.FOUNDRY:
			return foundry_cohesion
		F.CHOIR:
			return choir_cohesion
	return 1.0


func expansion(faction: int) -> float:
	match faction:
		F.SCAV:
			return scav_expansion
		F.FOUNDRY:
			return foundry_expansion
		F.CHOIR:
			return choir_expansion
	return 1.0


# --- comms --------------------------------------------------------------------


## Everything `AIComms` needs to know about how this faction talks, as one packed
## read indexed by the `COMMS_*` constants.
##
## The three of them are three different nets and it shows on screen. The Scavs
## have no radios: a Scav squad knows what it can hear being shouted and nothing
## else, calls a range badly, and takes a second and a half to pass anything on.
## The Foundry issues sets that cover the whole valley and answers fast. The Choir
## is the most precise caller in the game and the slowest to relay — every man is
## accurate and nobody is chatty.
func comms(faction: int) -> PackedFloat32Array:
	var out: PackedFloat32Array = default_comms()
	match faction:
		F.SCAV:
			out[COMMS_RADIO] = scav_radio_range
			out[COMMS_LATENCY] = scav_comms_latency
			out[COMMS_RELAY] = scav_relay_latency
			out[COMMS_DISCIPLINE] = scav_comms_discipline
		F.FOUNDRY:
			out[COMMS_RADIO] = foundry_radio_range
			out[COMMS_LATENCY] = foundry_comms_latency
			out[COMMS_RELAY] = foundry_relay_latency
			out[COMMS_DISCIPLINE] = foundry_comms_discipline
		F.CHOIR:
			out[COMMS_RADIO] = choir_radio_range
			out[COMMS_LATENCY] = choir_comms_latency
			out[COMMS_RELAY] = choir_relay_latency
			out[COMMS_DISCIPLINE] = choir_comms_discipline
	return out


## The shared half of the comms model, with a neutral faction's own numbers in the
## per-faction slots. `AIComms` holds one of these from construction so it is safe
## to build before the first advance.
func default_comms() -> PackedFloat32Array:
	var out: PackedFloat32Array = PackedFloat32Array()
	out.resize(COMMS_FIELDS)
	out[COMMS_VOICE] = voice_range
	out[COMMS_RADIO] = 0.0
	out[COMMS_LATENCY] = 0.20
	out[COMMS_RELAY] = 1.0
	out[COMMS_DISCIPLINE] = 1.0
	out[COMMS_ERROR_BASE] = callout_error_base
	out[COMMS_ERROR_RANGE] = callout_error_range
	out[COMMS_ERROR_DOUBT] = callout_error_doubt
	out[COMMS_RELAY_ERROR] = relay_error_scale
	out[COMMS_RELAY_CONF] = relay_confidence_scale
	return out


## A body of `faction` is gone. Called by `AISquad` when it strikes a casualty off,
## which is the one place in the game that always knows. Every blackboard hears it
## and the ones holding a contact on that id retire it.
func report_body_lost(faction: int, target_id: int, position: Vector3) -> void:
	body_lost.emit(faction, target_id, position)


## Archetype weights this faction arms from. Empty for the pseudo-factions.
func weapon_class_weights(faction: int) -> Dictionary:
	if faction < 0 or faction >= COUNT:
		return {}
	return WEAPON_PREFERENCE[faction]


## Draw an archetype name for `faction` from one uniform in `[0, 1)`. Feed it
## `XorShift32.next()` — never `randf()` — so an armed body is reproducible from
## its spawn seed.
func pick_weapon_class(faction: int, u: float) -> StringName:
	var weights: Dictionary = weapon_class_weights(faction)
	if weights.is_empty():
		return &"Hybrid"
	var total: float = 0.0
	for w: float in weights.values():
		total += w
	var roll: float = clampf(u, 0.0, 0.999999) * total
	var last: StringName = &"Hybrid"
	for key: StringName in weights:
		roll -= float(weights[key])
		last = key
		if roll < 0.0:
			return key
	return last


# --- territory ---------------------------------------------------------------


## Advance the ledger by `delta` seconds. Pushes the live inspector values down
## first, so a knob dragged during a playtest takes effect on the next tick.
func tick_territory(delta: float) -> void:
	territory.pressure_decay = pressure_decay
	territory.owner_decay_scale = owner_decay_scale
	territory.garrison_regen = garrison_regen
	territory.garrison_ceiling = garrison_ceiling
	territory.capture_margin = capture_margin
	territory.home_margin_scale = home_margin_scale
	territory.neutral_hold = neutral_hold
	territory.post_capture_pressure = post_capture_pressure
	territory.post_capture_residue = post_capture_residue
	territory.contest_threshold = contest_threshold
	territory.capture_dwell = capture_dwell
	territory.contest_attrition = contest_attrition
	territory.underdog_bonus = underdog_bonus
	territory.overextension_penalty = overextension_penalty
	territory.underdog_grip = underdog_grip
	territory.tick(delta)


## The ledger of ground. Cylindrical zones, an owner each, and a pressure matrix
## of how hard every faction is currently leaning on every one of them.
##
## Two rules keep the war from ending. A faction pushes harder the less it owns
## and bleeds faster the more it owns; and nobody can be pushed below their last
## home zone. The first stops a stalemate, the second stops a wipe. Both are
## tuned from `Factions`' exports and both are exercised by the headless sim in
## `systems/ai/verify/sim_factions.gd`.
class Territory:
	extends RefCounted

	## A zone changed hands. `previous_owner` is `Factions.NEUTRAL_ID` when the
	## ground was unclaimed.
	signal owner_changed(zone_id: StringName, previous_owner: int, new_owner: int)
	## Two or more factions crossed the contest threshold on a zone, or dropped
	## back out of it.
	signal contest_changed(zone_id: StringName, contested: bool)

	## How far under "unbeatable" a garrison's ceiling is held. See
	## `_garrison_hold_for`: this is the width of the door left open on every zone,
	## in pressure, and it is a constant rather than an export because it is the
	## invariant and not a dial.
	const LOCK_HEADROOM: float = 0.12

	var pressure_decay: float = 0.030
	var owner_decay_scale: float = 0.35
	var garrison_regen: float = 0.020
	var garrison_ceiling: float = 0.60
	var capture_margin: float = 0.18
	var home_margin_scale: float = 2.10
	var neutral_hold: float = 0.12
	var post_capture_pressure: float = 0.55
	var post_capture_residue: float = 0.45
	var contest_threshold: float = 0.15
	var capture_dwell: float = 10.0
	var contest_attrition: float = 2.00
	var underdog_bonus: float = 1.80
	var overextension_penalty: float = 1.60
	var underdog_grip: float = 0.60

	var _ids: Array[StringName] = []
	var _center: PackedVector3Array = PackedVector3Array()
	var _radius: PackedFloat32Array = PackedFloat32Array()
	var _height: PackedFloat32Array = PackedFloat32Array()
	var _value: PackedFloat32Array = PackedFloat32Array()
	var _owner: PackedInt32Array = PackedInt32Array()
	var _home: PackedInt32Array = PackedInt32Array()
	var _contested: PackedInt32Array = PackedInt32Array()
	## Seconds left on each zone's post-capture settle. See `capture_dwell`.
	var _settled: PackedFloat32Array = PackedFloat32Array()
	var _pressure: PackedFloat32Array = PackedFloat32Array()
	var _touched: PackedInt32Array = PackedInt32Array()
	var _share: PackedFloat32Array = PackedFloat32Array()
	var _decay_mul: PackedFloat32Array = PackedFloat32Array()
	var _captures: int = 0

	## Publish a zone's shape and initial owner. Re-registering an existing id
	## updates it in place, which is what a scene reload does. The first owner a
	## zone is registered with becomes its home faction for good.
	func register_zone(
		zone_id: StringName,
		center: Vector3,
		radius: float,
		height: float,
		owner_faction: int,
		value: float = 1.0
	) -> void:
		var i: int = _ids.find(zone_id)
		if i >= 0:
			_center[i] = center
			_radius[i] = radius
			_height[i] = height
			_value[i] = value
			set_owner(zone_id, owner_faction)
			return
		_ids.append(zone_id)
		_center.append(center)
		_radius.append(radius)
		_height.append(height)
		_value.append(value)
		_owner.append(owner_faction)
		_home.append(owner_faction)
		_contested.append(0)
		_settled.append(0.0)
		_pressure.resize(_ids.size() * COUNT)
		_touched.resize(_ids.size() * COUNT)
		var base: int = (_ids.size() - 1) * COUNT
		for f: int in COUNT:
			_pressure[base + f] = post_capture_pressure if f == owner_faction else 0.0
		_recount_shares()

	func unregister_zone(zone_id: StringName) -> void:
		var i: int = _ids.find(zone_id)
		if i < 0:
			return
		var last: int = _ids.size() - 1
		if i != last:
			_ids[i] = _ids[last]
			_center[i] = _center[last]
			_radius[i] = _radius[last]
			_height[i] = _height[last]
			_value[i] = _value[last]
			_owner[i] = _owner[last]
			_home[i] = _home[last]
			_contested[i] = _contested[last]
			_settled[i] = _settled[last]
			for f: int in COUNT:
				_pressure[i * COUNT + f] = _pressure[last * COUNT + f]
				_touched[i * COUNT + f] = _touched[last * COUNT + f]
		_ids.resize(last)
		_center.resize(last)
		_radius.resize(last)
		_height.resize(last)
		_value.resize(last)
		_owner.resize(last)
		_home.resize(last)
		_contested.resize(last)
		_settled.resize(last)
		_pressure.resize(last * COUNT)
		_touched.resize(last * COUNT)
		_recount_shares()

	func count() -> int:
		return _ids.size()

	func id_at(i: int) -> StringName:
		return _ids[i]

	## Shape of a zone as `[centre, radius, height, value]`. Empty for a bad id.
	func shape(zone_id: StringName) -> Array:
		var i: int = _ids.find(zone_id)
		if i < 0:
			return []
		return [_center[i], _radius[i], _height[i], _value[i]]

	func center_at(i: int) -> Vector3:
		return _center[i]

	func owner_at(i: int) -> int:
		return _owner[i]

	func home_at(i: int) -> int:
		return _home[i]

	func zone_owner(zone_id: StringName) -> int:
		var i: int = _ids.find(zone_id)
		return NEUTRAL_ID if i < 0 else _owner[i]

	func set_owner(zone_id: StringName, faction: int) -> void:
		var i: int = _ids.find(zone_id)
		if i < 0 or _owner[i] == faction:
			return
		var previous: int = _owner[i]
		_owner[i] = faction
		_captures += 1
		_recount_shares()
		owner_changed.emit(zone_id, previous, faction)

	## Id of the zone containing `p`, preferring the tightest when they overlap.
	func zone_at(p: Vector3) -> StringName:
		var best: StringName = &""
		var best_r: float = INF
		for i: int in _ids.size():
			var r: float = _radius[i]
			if r >= best_r:
				continue
			var c: Vector3 = _center[i]
			if absf(p.y - c.y) > _height[i] * 0.5:
				continue
			var dx: float = p.x - c.x
			var dz: float = p.z - c.z
			if dx * dx + dz * dz <= r * r:
				best = _ids[i]
				best_r = r
		return best

	func owner_of_point(p: Vector3) -> int:
		var id: StringName = zone_at(p)
		return NEUTRAL_ID if id == &"" else zone_owner(id)

	func zones_owned_by(faction: int) -> Array[StringName]:
		var out: Array[StringName] = []
		for i: int in _ids.size():
			if _owner[i] == faction:
				out.append(_ids[i])
		return out

	## Fraction of the board `faction` holds, in `[0, 1]`. Cached — the tick
	## recomputes it once and every pressure call reads it back.
	func share(faction: int) -> float:
		if faction < 0 or faction >= COUNT or _share.is_empty():
			return 0.0
		return _share[faction]

	## Lean on a zone. `amount` is raw intent; the underdog term is applied here
	## so every caller gets the comeback behaviour without having to know of it.
	##
	## THE HOLDER IS CAPPED AT ITS GARRISON CEILING AND THIS IS WHERE THE MAP USED
	## TO FREEZE. `garrison_ceiling`'s own comment says why the number has to be
	## below one — "pressure clamps at one, so a garrison that regenerated all the
	## way to the top could never be out-pushed and the map would freeze solid" —
	## but until now the ceiling was only applied to the regen trickle in
	## `_tick_zone`, and this function, which is where nearly all of a garrison's
	## pressure actually comes from, walked straight past it. Eight bodies standing
	## on a zone push 0.4 per second against a bleed of 0.02, so every held zone
	## pinned at 1.0 within seconds of being taken and `best_p > defence + margin`
	## became unsatisfiable: the ground left the board.
	##
	## Measured on the firefight demo before this line: **six or seven of the seven
	## zones were mathematically uncapturable at any given moment**, 90% of all
	## graded zone-samples, and the leader could not be made to lose ground by any
	## amount of fighting — which is precisely the runaway-leader lock the war was
	## supposed to be immune to. Attackers are deliberately NOT capped: a faction
	## that is not standing on a zone yet has to be able to out-push whoever is.
	func add_pressure(zone_id: StringName, faction: int, amount: float) -> void:
		var i: int = _ids.find(zone_id)
		if i < 0 or faction < 0 or faction >= COUNT or amount <= 0.0:
			return
		var base: int = i * COUNT
		var k: int = base + faction
		var gain: float = amount * (1.0 + underdog_bonus * (1.0 - share(faction)))
		var ceiling: float = 1.0
		if _owner[i] == faction:
			# Never below what it already holds: ground just taken comes in at
			# `post_capture_pressure`, which is above the ceiling on purpose, and
			# this must not confiscate it — only stop it growing.
			ceiling = maxf(_garrison_hold_for(faction, i), _pressure[k])
		_pressure[k] = minf(_pressure[k] + gain, ceiling)
		_touched[k] = 1
		# And the same push, wearing down everybody else's hold on the same ground.
		# `gain` and not `amount`, so the underdog term tilts the contest as well as
		# the accumulation: a faction that is losing the war pushes harder AND
		# shifts its rivals faster, which is the comeback rule doing the one job it
		# was written for.
		var wear: float = minf(gain * contest_attrition, 1.0)
		if wear <= 0.0:
			return
		for f: int in COUNT:
			if f != faction:
				_pressure[base + f] *= 1.0 - wear

	func pressure(zone_id: StringName, faction: int) -> float:
		var i: int = _ids.find(zone_id)
		if i < 0 or faction < 0 or faction >= COUNT:
			return 0.0
		return _pressure[i * COUNT + faction]

	func pressure_at(i: int, faction: int) -> float:
		return _pressure[i * COUNT + faction]

	func is_contested(zone_id: StringName) -> bool:
		var i: int = _ids.find(zone_id)
		return i >= 0 and _contested[i] != 0

	## Total zone flips since the ledger was created. The sim reads this to prove
	## the map has not frozen.
	func captures() -> int:
		return _captures

	## Bleed, regenerate and resolve every zone. O(zones × factions) with no
	## allocation, so it is cheap enough to run at 4 Hz with a hundred zones.
	func tick(delta: float) -> void:
		_recount_shares()
		for i: int in _ids.size():
			_settled[i] = maxf(_settled[i] - delta, 0.0)
			_tick_zone(i, delta)

	func _tick_zone(i: int, delta: float) -> void:
		var base: int = i * COUNT
		var own: int = _owner[i]
		var held: bool = own >= 0 and own < COUNT and _touched[base + own] != 0
		if held:
			var ceiling: float = _garrison_hold_for(own, i)
			if _pressure[base + own] < ceiling:
				_pressure[base + own] = minf(
					_pressure[base + own] + garrison_regen * delta, ceiling
				)
		var present: int = 0
		var best_f: int = -1
		var best_p: float = 0.0
		for f: int in COUNT:
			var k: int = base + f
			var d: float = pressure_decay * delta * _decay_mul[f]
			if f == own and held:
				d *= owner_decay_scale
			_pressure[k] = maxf(_pressure[k] - d, 0.0)
			_touched[k] = 0
			if _pressure[k] >= contest_threshold:
				present += 1
			if f != own and _pressure[k] > best_p:
				best_p = _pressure[k]
				best_f = f
		_set_contested(i, present >= 2)
		if best_f < 0:
			return
		var defence: float = neutral_hold
		if own >= 0 and own < COUNT:
			defence = _pressure[base + own]
		if own >= 0 and _home[i] == own and _count_owned(own) <= 1:
			return
		if _settled[i] > 0.0:
			return
		if best_p > defence + _margin_for(i):
			_capture(i, best_f)

	## How far ahead of the holder an attacker has to get on THIS zone. One
	## function, so the capture test and the garrison ceiling cannot disagree about
	## what a piece of ground costs — they used to, and the map paid for it.
	func _margin_for(i: int) -> float:
		var margin: float = capture_margin * _value[i]
		if _owner[i] >= 0 and _home[i] == _owner[i]:
			margin *= home_margin_scale
		return margin

	## What a garrison is worth to a faction holding `share` of the board. A wide
	## empire garrisons thinly: this is what stops an over-extended faction from
	## sitting on ground it is not actually defending, and it is the other half of
	## the anti-runaway rule.
	func _garrison_ceiling_for(faction: int) -> float:
		return garrison_ceiling / (1.0 + overextension_penalty * share(faction))

	## The most pressure a holder may build on one zone by standing on it: the
	## ceiling above, held under what an attacker can physically reach.
	##
	## THE SECOND CLAMP IS AN INVARIANT, NOT A TUNING. Pressure clamps at one, so a
	## holder sitting at `1 - margin` or above cannot be out-pushed by anybody at
	## any strength — the zone is off the board, and the war is decided by the
	## ledger's arithmetic rather than by the fighting. Deriving the cap from the
	## same `_margin_for` the capture test uses means no combination of
	## `garrison_ceiling`, `capture_margin`, `home_margin_scale` and a zone's own
	## `value` can reach that state: every zone stays winnable by somebody who
	## brings enough bodies, which is the difference between a hard fight and a
	## removed one. `LOCK_HEADROOM` is how much room is left over the line, so the
	## answer is "hard" rather than "hard by a rounding error".
	##
	## The one deliberate exception is a faction down to its last home zone, which
	## `_tick_zone` refuses to take off it. That is the anti-wipe rule, and it is
	## bounded to one zone per faction.
	func _garrison_hold_for(faction: int, i: int) -> float:
		return minf(_garrison_ceiling_for(faction), 1.0 - _margin_for(i) - LOCK_HEADROOM)

	func _capture(i: int, winner: int) -> void:
		var base: int = i * COUNT
		for f: int in COUNT:
			if f == winner:
				_pressure[base + f] = post_capture_pressure
			else:
				_pressure[base + f] *= post_capture_residue
		var previous: int = _owner[i]
		_owner[i] = winner
		_settled[i] = capture_dwell
		_captures += 1
		_recount_shares()
		owner_changed.emit(_ids[i], previous, winner)

	func _set_contested(i: int, v: bool) -> void:
		var flag: int = 1 if v else 0
		if _contested[i] == flag:
			return
		_contested[i] = flag
		contest_changed.emit(_ids[i], v)

	func _count_owned(faction: int) -> int:
		var n: int = 0
		for i: int in _ids.size():
			if _owner[i] == faction:
				n += 1
		return n

	func _recount_shares() -> void:
		_share.resize(COUNT)
		_decay_mul.resize(COUNT)
		var n: float = maxf(float(_ids.size()), 1.0)
		for f: int in COUNT:
			_share[f] = float(_count_owned(f)) / n
			var spread: float = 1.0 + overextension_penalty * _share[f]
			var grip: float = 1.0 + underdog_bonus * underdog_grip * (1.0 - _share[f])
			_decay_mul[f] = spread / grip
