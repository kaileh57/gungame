class_name AIEngagement
extends Resource
## The range one agent wants to fight at, and what its feet should do to reach it.
##
## Split out of `AICombat` because it is a different job from trigger discipline
## and because it needs memory. A band computed fresh every tick from the current
## distance oscillates: the agent closes, crosses the threshold, backs off,
## crosses it again. This holds the two pieces of state that stop that — a
## commitment clock on the withdrawal and the last posture it reported — so the
## answer is stable over the seconds a body actually takes to walk anywhere.
##
## THE BAND IS THE STEERING CHANNEL. `FirefightAgent._standoff` and
## `AICoverMap.query` both read `AICombat.engagement_band()` and nothing else, so
## everything this class decides about advancing, holding, backing off and
## breaking contact has to come out as a pair of metres. It does: holding is a
## band that straddles the current range, advancing is a band whose top is inside
## it, and a fighting withdrawal is a band whose BOTTOM is outside it — the feet
## then walk away from the contact for the same reason they would normally walk
## toward it.
##
## Reach comes from the equipped `GunSpec`, not from the species, so the same
## profile carrying a scavenged sniper rifle and carrying a scavenged shotgun
## fights at two different distances. That is the whole point of the seam.
##
## The withdrawal is gated on the species' own `flee_health`. A machine authored
## with zero has never had the thought and will stand in fire it cannot answer;
## a scav authored at 0.15 will not. Nothing here is a clamp on the outcome — it
## decides when a body stops walking into a gun it cannot reach.

## Matches `AICombat.Posture`, which is the public name for these. Kept as plain
## ints because Godot 4.7 will not resolve an enum-typed value across a script
## boundary and this class is read from `AICombat`.
const HOLD: int = 0
const ADVANCE: int = 1
const RETREAT: int = 2

@export_group("Band")
## Fraction of the weapon's effective range the agent would rather fight at.
## Half is deliberate: it leaves room to fall back without leaving the fight.
@export_range(0.1, 1.0, 0.01) var preferred_range_fraction: float = 0.55
## Lower edge of the band it will hold, as a fraction of the preferred range.
@export_range(0.2, 1.0, 0.01) var hold_band_low: float = 0.62
## Upper edge, same units. The gap between the two is the hysteresis that stops
## an agent oscillating on the spot.
@export_range(1.0, 2.0, 0.01) var hold_band_high: float = 1.22
## Multiple of effective range past which the agent will not fire at all.
@export_range(0.5, 2.0, 0.01) var max_engage_fraction: float = 1.1
## Reach, in metres, at or below which a species is a closer rather than a
## shooter. Under this the band is pushed hard onto the target — a scattergun
## that hangs back at its nominal preferred range is a scattergun doing nothing.
@export_range(1.0, 40.0, 0.5) var close_reach_metres: float = 14.0
## Fraction of reach a closer aims for instead of `preferred_range_fraction`.
@export_range(0.2, 1.0, 0.01) var close_range_fraction: float = 0.82

@export_group("Withdrawal")
## How far the species' own `flee_health` goes toward making it willing to break
## contact. At 2.6 a body authored to think about leaving at 38 per cent health
## is fully willing; one authored at 15 per cent needs most of the way to pinned.
## A species with `flee_health` of zero never withdraws at any setting.
@export_range(0.0, 8.0, 0.05) var withdraw_willingness: float = 2.6
## Suppression, as a fraction of the species' tolerance, above which a fully
## willing body that cannot answer the fire starts falling back. One is pinned.
@export_range(0.1, 2.0, 0.01) var withdraw_pressure: float = 0.62
## Suppression fraction it has to fall back below before the withdrawal ends.
## Below `withdraw_pressure` on purpose — this is the hysteresis.
@export_range(0.0, 2.0, 0.01) var withdraw_release: float = 0.30
## Multiple of its own engage limit past which a contact counts as outranging it.
## At 1.0 anything it cannot shoot back at qualifies.
@export_range(0.5, 3.0, 0.01) var outranged_ratio: float = 1.0
## Seconds a withdrawal runs before it may be reconsidered, whatever the pressure
## has done in the meantime. A body that changes its mind every tick crosses the
## same ten metres forever.
@export_range(0.5, 20.0, 0.1) var withdraw_seconds: float = 4.5
## Multiple of the current range the band's bottom is pushed out to during a
## withdrawal. Above one, or the feet have nowhere to go.
@export_range(1.05, 3.0, 0.01) var withdraw_push: float = 1.55
## Metres the withdrawal will move a body at most in one commitment. Keeps a
## body that is outranged by a hundred metres from trying to leave the map.
@export_range(4.0, 120.0, 0.5) var withdraw_limit: float = 26.0
## Ammunition fraction below which a body treats itself as outranged whatever
## the geometry says: there is no answering fire to be made with an empty gun.
@export_range(0.0, 0.6, 0.01) var withdraw_ammo_fraction: float = 0.10

## True while the agent is deliberately breaking contact. Read by `wants_cover`.
var withdrawing: bool = false
## Metres the body wants between itself and the contact while it is breaking
## contact. Zero when it is not. Set by `update`, spent by `band`.
var standoff: float = 0.0

var _commit: float = 0.0
var _last_posture: int = HOLD


## One step of range policy. `reach` is what the equipped weapon can actually do,
## `pressure` is suppression as a fraction of the species' tolerance (one is
## pinned), and `ammo_fraction` is what is left in the magazine. Everything else
## is geometry.
##
## Called once per agent tick from `AICombat.tick`, before anything reads the
## band, so the band a body steers on and the band it shoots inside are the same
## band. Only the withdrawal is stateful — the resting band is a pure function of
## the weapon and is safe to read before this has ever run.
func update(
	delta: float,
	reach: float,
	dist: float,
	has_los: bool,
	pressure: float,
	ammo_fraction: float,
	flee_health: float
) -> void:
	# Deliberately unclamped: the negative range is how long the commitment has
	# been over, which is what bounds a withdrawal that is not getting anywhere.
	_commit -= delta
	var was: bool = withdrawing
	_update_withdrawal(reach, dist, has_los, pressure, ammo_fraction, flee_health)
	if not withdrawing:
		standoff = 0.0
		return
	if not was or standoff <= 0.0:
		# Fixed at the moment the withdrawal starts, not chased every tick. A
		# standoff measured off the CURRENT range walks away from a contact that is
		# following, which is a rout; measured off the range the body broke at, it
		# is a bound backwards to somewhere it can shoot from.
		standoff = minf(dist * withdraw_push, dist + withdraw_limit)


## The band the agent wants to fight in: it closes above `y`, backs off below `x`.
##
## The resting band comes straight off the weapon. A withdrawal replaces its
## BOTTOM with the standoff, so a body already inside its own band suddenly reads
## as too close and the feet walk it back — the same mechanism that normally
## makes it advance, run the other way.
func band(reach: float, min_range: float) -> Vector2:
	var pref: float = reach * _preferred_fraction(reach)
	var low: float = maxf(pref * hold_band_low, min_range)
	var high: float = maxf(minf(pref * hold_band_high, engage_limit(reach)), low + 0.5)
	if not withdrawing or standoff <= 0.0:
		return Vector2(low, high)
	return Vector2(standoff, maxf(high, standoff + 0.5))


## Push an authored species band out by an active withdrawal. For a body with no
## gun, whose resting band comes from `AISpeciesProfile` rather than from here.
func widen(native: Vector2) -> Vector2:
	if not withdrawing or standoff <= 0.0:
		return native
	return Vector2(standoff, maxf(native.y, standoff + 0.5))


## Metres past which the agent will not pull the trigger at all.
func engage_limit(reach: float) -> float:
	return reach * max_engage_fraction


## What the feet should do at `dist`. Losing sight is worth closing for even from
## inside the band — a wall between you and the target is not a firing position,
## and a withdrawal is the one case where that does not apply, because the whole
## point of it is to put something solid in the way.
func posture(dist: float, has_los: bool, edges: Vector2) -> int:
	if dist < edges.x:
		_last_posture = RETREAT
	elif dist > edges.y or (not has_los and not withdrawing):
		_last_posture = ADVANCE
	else:
		_last_posture = HOLD
	return _last_posture


func reset() -> void:
	withdrawing = false
	standoff = 0.0
	_commit = 0.0
	_last_posture = HOLD


## A closer wants to be on top of its target; a shooter wants the middle of its
## own reach. The switch is the weapon's range and nothing else, so a species
## that scavenges a shotgun this life and a marksman rifle the next fights both
## of them correctly without an authored flag.
func _preferred_fraction(reach: float) -> float:
	return close_range_fraction if reach <= close_reach_metres else preferred_range_fraction


## Start, hold or end a fighting withdrawal.
##
## The trigger is being under fire you cannot answer: pressure above the
## threshold while the contact sits past your own engage limit, or while the
## magazine is empty enough that the reply would be nothing, or while there is a
## wall in the way. The release is pressure falling back below `withdraw_release`
## once the commitment clock has run out.
##
## A species authored with no `flee_health` never enters it at all — that is the
## hard gate, and it is what keeps machines standing in fire they cannot answer
## while the scavs beside them fall back. Everything between is the brave term:
## the braver the species, the more pressure it takes.
func _update_withdrawal(
	reach: float,
	dist: float,
	has_los: bool,
	pressure: float,
	ammo_fraction: float,
	flee_health: float
) -> void:
	if flee_health <= 0.0 or withdraw_willingness <= 0.0 or reach <= close_reach_metres:
		# A CLOSER NEVER WITHDRAWS. Being outranged is its permanent condition, not
		# a reason to back off — a scattergun that answers a rifle by increasing the
		# range has answered it wrongly, and the harness showed exactly that: a
		# Gasman and a Picker under fire at 37 m both set a 57 m standoff and spent
		# the rest of the run walking away from a fight they win by arriving. Under
		# pressure a closer still wants cover; it just keeps coming.
		withdrawing = false
		return
	var brave: float = clampf(1.0 - flee_health * withdraw_willingness, 0.0, 1.0)
	if withdrawing:
		# It ends when it has WORKED — the body has opened the range it set out to
		# open — or when the shooting stops. Ending it only on the second, which is
		# the obvious rule, leaves a body under sustained fire withdrawing forever
		# against a standoff it reached thirty seconds ago.
		if dist >= standoff and standoff > 0.0:
			withdrawing = false
		elif _commit <= 0.0 and pressure <= withdraw_release * (1.0 + brave):
			withdrawing = false
		elif _commit <= -withdraw_seconds * 2.0:
			# Three times as long as it committed to and still short of its standoff:
			# something is in the way, or the contact is following. Stop backing off
			# and fight from here — a withdrawal that never ends is a rout.
			withdrawing = false
		return
	if pressure < withdraw_pressure * (1.0 + brave):
		return
	var outranged: bool = dist > engage_limit(reach) * outranged_ratio
	if not (outranged or ammo_fraction <= withdraw_ammo_fraction or not has_los):
		return
	withdrawing = true
	_commit = withdraw_seconds
