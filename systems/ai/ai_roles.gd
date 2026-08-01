class_name AIRoles
extends Resource
## The role doctrine: what a squad wants somebody doing, and which body is the
## one to do it.
##
## A squad is four jobs, not four copies of the same job. The anchor holds the
## ground and does not move off it. The suppressor keeps rounds landing near the
## contact so nobody else has to be brave. The advancer closes under that fire.
## The flanker leaves the fight entirely to arrive from somewhere else. A scout
## is a body cheap enough to spend finding out where the enemy is.
##
## Assignment is a quota fill, not an optimiser: work out how many of each job
## this many bodies should be doing, then hand each job to whoever scores best
## for it and is not already busy. It runs on a slow tick, it is O(roles × size),
## and it is deliberately sticky — `keep_role_bonus` is what stops a squad
## swapping every job every time somebody ducks.
##
## One of these resources is shared by every squad in the game — it carries the
## squad-behaviour knobs as well as the role ones, because `AISquad` is a plain
## `RefCounted` and cannot hold exports of its own. Nothing here is per-squad
## state; that all lives in `AISquad`.

enum Role { ANCHOR, SUPPRESSOR, FLANKER, ADVANCER, SCOUT }

const ROLE_COUNT: int = 5
const ROLE_NAMES: PackedStringArray = ["ANCHOR", "SUPPRESSOR", "FLANKER", "ADVANCER", "SCOUT"]

@export_group("Mix")
## Bodies always held back on the objective, however big the squad gets.
@export_range(0, 4, 1) var anchor_min: int = 1
## Share of the squad that should be putting rounds downrange.
@export_range(0.0, 1.0, 0.01) var suppressor_fraction: float = 0.34
## Share that should be going the long way round.
@export_range(0.0, 1.0, 0.01) var flanker_fraction: float = 0.25
## Share that should be closing.
@export_range(0.0, 1.0, 0.01) var advancer_fraction: float = 0.34
## Share that should be out front looking. Small — a scout is an expense.
@export_range(0.0, 1.0, 0.01) var scout_fraction: float = 0.12
## Below this many bodies nobody is spared to flank; three men in a line is not a
## pincer, it is three men getting shot one at a time.
@export_range(2, 12, 1) var min_size_for_flanker: int = 3
@export_range(2, 12, 1) var min_size_for_scout: int = 5

@export_group("Weights")
## Worth of having eyes on the contact. Dominates the suppressor score.
@export_range(0.0, 4.0, 0.01) var los_weight: float = 1.30
## Worth of standing behind something.
@export_range(0.0, 4.0, 0.01) var cover_weight: float = 0.85
## Worth of not being nearly dead. Drives who gets sent forward.
@export_range(0.0, 4.0, 0.01) var health_weight: float = 1.10
## Worth of a full magazine.
@export_range(0.0, 4.0, 0.01) var ammo_weight: float = 0.90
## How much incoming fire disqualifies a body from a job that needs composure.
@export_range(0.0, 4.0, 0.01) var suppression_penalty: float = 1.20
## Worth of legs. Flankers and scouts live on this.
@export_range(0.0, 4.0, 0.01) var mobility_weight: float = 1.00
## Worth of a long weapon. Anchors live on this.
@export_range(0.0, 4.0, 0.01) var reach_weight: float = 1.15
## How much being at the right distance for the job counts.
@export_range(0.0, 4.0, 0.01) var distance_weight: float = 0.80
## How hard a species' own preference pulls. At zero every body is interchangeable
## and the squad reads as a mob.
@export_range(0.0, 3.0, 0.01) var bias_weight: float = 1.00
## Bonus a body gets for the job it is already doing. Pure hysteresis.
@export_range(0.0, 3.0, 0.01) var keep_role_bonus: float = 0.55

@export_group("Squad")
## Seconds between role solves. Faster than this and the squad visibly twitches.
@export_range(0.4, 8.0, 0.05) var reassign_interval: float = 1.5
## Metres. Bodies further than this from the squad centroid count as scattered,
## and a scattered squad regroups before it does anything else.
@export_range(4.0, 60.0, 0.5) var cohesion_radius: float = 16.0
## Fraction of the original squad that can die before the survivors pull back to
## the rally point. Below the species' own rout threshold, so a squad regroups
## once before it breaks.
@export_range(0.0, 1.0, 0.01) var regroup_fraction: float = 0.45
## Multiplier on the species' `rout_fraction`. Above one for a faction you want
## to see hold; below one for one you want to see break.
@export_range(0.2, 2.0, 0.01) var rout_scale: float = 1.0
## Seconds one body gets to move before the bound passes to the next. Long enough
## to cross a street, short enough that nobody is out there alone.
@export_range(0.5, 12.0, 0.1) var bound_duration: float = 3.2
## Bodies that must have eyes on the contact before anyone is allowed to move.
## At zero the squad stops bounding and simply charges.
@export_range(0, 4, 1) var bound_min_coverers: int = 1
## Bodies allowed to be crossing at once. One is textbook and very slow; two is
## what a squad that intends to arrive actually does.
@export_range(1, 4, 1) var bound_max_movers: int = 2
## Metres from the contact inside which bounding overwatch applies at all.
##
## YOU DO NOT BOUND ACROSS EIGHTY METRES OF OPEN GROUND; you march until you are
## in contact and then you bound. Without this gate a squad that commits to a
## contact it cannot reach pins every body without a token to a fifteenth of a
## walk and never arrives — measured over a fifteen-minute headless war, that one
## missing test cost eleven of twenty-three zone captures and froze the map for
## the last five minutes.
@export_range(4.0, 120.0, 0.5) var bound_range: float = 34.0
## Metres. A contact further out than this is somebody else's problem. Scaled by
## the faction's aggression.
@export_range(10.0, 300.0, 1.0) var engage_range: float = 70.0
## Confidence a contact needs before the squad will commit to it.
@export_range(0.05, 1.0, 0.01) var push_confidence: float = 0.32
## Seconds between two callouts of the same kind from one squad.
@export_range(0.2, 20.0, 0.1) var callout_cooldown: float = 2.6
## Pressure per second one body inside a zone contributes on the squad's behalf.
@export_range(0.001, 0.25, 0.001) var body_pressure_rate: float = 0.030

@export_group("Comms reaction")
## Ammo fraction at or below which a body reads as reloading, and says so. The
## squad has no direct sight of a magazine — it infers this from the ammo every
## member already reports — so it must sit above whatever a body runs down to
## between bursts and below a full magazine.
@export_range(0.02, 0.6, 0.01) var reload_ammo_floor: float = 0.18
## Seconds a squadmate stays on cover duty after hearing "reloading". Long enough
## to cover the reload, short enough that a squad is not permanently babysitting.
@export_range(0.5, 12.0, 0.1) var cover_hold: float = 3.5
## Minimum ammo fraction a body needs before it is asked to cover anybody.
@export_range(0.0, 1.0, 0.01) var coverer_ammo_floor: float = 0.22
## Suppression above which a body is too busy being shot at to be counted as
## covering anything. This is the term that makes bounding overwatch stall under
## fire instead of marching men into it.
##
## Read against `AISuppression`, where one round cracking past adds `severity_scale`
## — 0.22 — and the level ceilings at 1.4. So this is "about two near misses", and a
## body that has had two rounds go past its head is not steady enough to be somebody
## else's overwatch. At the 0.70 it was first set to, nothing in the firefight ever
## reached it and the clause was inert: measured over 150 s of the live demo, no
## body's suppression exceeded roughly half of that.
@export_range(0.0, 1.4, 0.01) var coverer_suppression_cap: float = 0.50
## Mean health across the squad below which it calls for support.
@export_range(0.0, 1.0, 0.01) var support_health: float = 0.45
## Seconds the squad collapses onto a support call from one of its own before it
## goes back to its objective.
@export_range(2.0, 40.0, 0.5) var support_hold: float = 9.0
## Suppression on ONE BODY that counts as taking fire and gets said out loud.
##
## Per body rather than per squad: averaged over eight men the number never leaves
## the noise floor — measured in the live firefight, squad-mean suppression averages
## 0.001 and peaks at 0.065 — and the man with rounds landing on him is who shouts.
## One round cracking past is `AISuppression.severity_scale`, 0.22, which is exactly
## what "taking fire" means.
@export_range(0.0, 1.4, 0.01) var taking_fire_level: float = 0.22
## How much better a new contact has to score before a squad drops the one it is
## already shooting at. Zero makes the squad flick between targets; this is what
## turns "everyone shoots something" into "everyone shoots the same thing".
@export_range(0.0, 2.0, 0.01) var focus_switch_margin: float = 0.30
## Metres of clearance a covering body needs either side of its line to the
## contact. A squadmate inside that corridor is in the way, so the coverer stops
## counting as cover and nobody is sent across in front of it.
@export_range(0.0, 4.0, 0.05) var lane_clearance: float = 1.10
## Seconds a squad has to sit on its objective with no contact before it calls the
## area clear.
@export_range(2.0, 60.0, 0.5) var clear_dwell: float = 12.0

@export_group("Command")
## Seconds an order must stand before a less urgent one may replace it. The
## anti-thrash rule for `AIOrders`; too low and squads flip verbs mid-crossing.
@export_range(1.0, 60.0, 0.5) var order_dwell: float = 6.0
## Fraction of its peak strength below which a faction stops attacking and pulls
## its squads back onto ground it already holds.
@export_range(0.0, 1.0, 0.01) var withdraw_manpower: float = 0.34
## Fraction of its peak strength a faction needs before it presses an assault
## rather than probing. Between this and `withdraw_manpower` it feels forward.
@export_range(0.0, 1.0, 0.01) var assault_manpower: float = 0.62
## How close to losing a zone must be, in units of the ledger's capture margin,
## before a squad is pulled off the attack to hold it.
@export_range(0.0, 2.0, 0.01) var hold_threat: float = 0.65
## Metres inside which a squad will answer another squad's support call.
@export_range(10.0, 200.0, 1.0) var support_radius: float = 70.0
## Squads a faction may have pinned on ground it already owns.
##
## WITHOUT A CAP EVERY FACTION BECOMES A GARRISON. On a ring of contested zones,
## rival pressure clears the hold threshold on most of a faction's holdings most of
## the time, so every squad is ordered to stand on something and nobody attacks
## anything. Measured in the firefight demo with the cap off: 108 casualties over
## 330 s of real fighting and the map changed hands three times, none of them in the
## late half. `FirefightDirector.max_defending_squads` is the same rule at the other
## end of the pipe, and its comment records the same measurement.
@export_range(0, 4, 1) var hold_squads_max: int = 1
## Squads a faction may divert to answer support calls at once. One squad turning
## round is a rescue; three is the faction giving up on the war to look after
## itself.
@export_range(0, 4, 1) var reinforce_squads_max: int = 1
## Fraction of a zone's radius a holding squad stands out from the centre, toward
## whoever is pushing on it. Zero garrisons the middle of the circle.
@export_range(0.0, 1.2, 0.01) var garrison_standoff: float = 0.62
## Seconds a zone stays discounted after somebody reported it clear.
@export_range(2.0, 180.0, 1.0) var sweep_memory: float = 26.0
## What a freshly swept zone is worth as a destination, as a fraction of normal.
@export_range(0.0, 1.0, 0.01) var sweep_discount: float = 0.35
## Fraction of its remembered peak strength a faction forgets per second. This is
## what stops one bad opening making a faction permanently timid.
@export_range(0.0, 0.2, 0.001) var peak_bleed: float = 0.010

@export_group("Normalisation")
## Run speed, m/s, that counts as fully mobile.
@export_range(1.0, 20.0, 0.1) var reference_speed: float = 7.0
## Weapon reach, metres, that counts as fully long.
@export_range(10.0, 400.0, 1.0) var reference_reach: float = 110.0
## Magazine size that counts as belt-fed for suppression purposes.
@export_range(10, 400, 1) var reference_magazine: int = 60
## Bonus a full-auto weapon adds to its holder's suppressor score.
@export_range(0.0, 3.0, 0.01) var automatic_bonus: float = 0.70


func role_name(role: int) -> String:
	if role < 0 or role >= ROLE_COUNT:
		return "NONE"
	return ROLE_NAMES[role]


## The species' own appetite for a job. `ANCHOR` has no bias field of its own —
## it is the fallback, and a species with no appetite for anything else lands
## there by arithmetic rather than by a special case.
func bias(profile: AISpeciesProfile, role: int) -> float:
	if profile == null:
		return 1.0
	match role:
		Role.SUPPRESSOR:
			return profile.bias_suppressor
		Role.FLANKER:
			return profile.bias_flanker
		Role.ADVANCER:
			return profile.bias_advancer
		Role.SCOUT:
			return profile.bias_scout
	return 1.0


## How many bodies each job should get for a squad of `size`. Anchors are what is
## left over, and `anchor_min` is taken off the top before anything else is
## allotted, so the objective never empties because the fight moved.
func quotas(size: int) -> PackedInt32Array:
	var out: PackedInt32Array = PackedInt32Array()
	out.resize(ROLE_COUNT)
	if size <= 0:
		return out
	var spare: int = maxi(size - anchor_min, 0)
	var want: PackedFloat32Array = PackedFloat32Array(
		[0.0, suppressor_fraction, flanker_fraction, advancer_fraction, scout_fraction]
	)
	if size < min_size_for_flanker:
		want[Role.FLANKER] = 0.0
	if size < min_size_for_scout:
		want[Role.SCOUT] = 0.0
	var total: float = want[1] + want[2] + want[3] + want[4]
	if total <= 0.0:
		out[Role.ANCHOR] = size
		return out
	var handed: int = 0
	for role: int in [Role.SUPPRESSOR, Role.ADVANCER, Role.FLANKER, Role.SCOUT]:
		var n: int = int(floor(float(spare) * want[role] / total + 0.5))
		if want[role] > 0.0:
			n = maxi(n, 1)
		out[role] = clampi(n, 0, spare - handed)
		handed += out[role]
	out[Role.ANCHOR] = size - handed
	return out


## Fitness of one body for one job, before quotas. Everything is normalised to
## roughly `[0, 1]` before it is weighted so the exports above compare like with
## like — a weight of 1.2 really is 20 per cent more important than a weight of 1.
func score(
	role: int,
	profile: AISpeciesProfile,
	dist: float,
	health_frac: float,
	ammo_frac: float,
	has_los: bool,
	in_cover: bool,
	suppression: float,
	current_role: int
) -> float:
	if profile == null:
		return 0.0
	var los: float = 1.0 if has_los else 0.0
	var cover: float = 1.0 if in_cover else 0.0
	var health: float = clampf(health_frac, 0.0, 1.0)
	var ammo: float = clampf(ammo_frac, 0.0, 1.0)
	var supp: float = clampf(suppression, 0.0, 1.0)
	var mobility: float = clampf(profile.run_speed / maxf(reference_speed, 0.1), 0.0, 1.0)
	var reach: float = clampf(profile.weapon_range / maxf(reference_reach, 1.0), 0.0, 1.0)
	var band: Vector2 = profile.engagement_band()
	var in_band: float = 1.0 if dist >= band.x and dist <= band.y else 0.0
	var closeness: float = 1.0 - clampf(dist / maxf(reference_reach, 1.0), 0.0, 1.0)

	var s: float = 0.0
	match role:
		Role.ANCHOR:
			s = reach * reach_weight
			s += cover * cover_weight
			s += los * los_weight * 0.5
			s += (1.0 - mobility) * mobility_weight * 0.6
			s += in_band * distance_weight
		Role.SUPPRESSOR:
			s = los * los_weight
			s += ammo * ammo_weight
			s += cover * cover_weight * 0.8
			s += (
				minf(float(profile.magazine) / float(maxi(reference_magazine, 1)), 1.0)
				* ammo_weight
			)
			if profile.weapon == AISpeciesProfile.Weapon.AUTO:
				s += automatic_bonus
			s += in_band * distance_weight
			s -= supp * suppression_penalty
		Role.FLANKER:
			s = mobility * mobility_weight
			s += (1.0 - los) * los_weight * 0.6
			s += health * health_weight
			s += (1.0 - in_band) * distance_weight * 0.5
			s -= supp * suppression_penalty * 0.5
		Role.ADVANCER:
			s = health * health_weight
			s += mobility * mobility_weight * 0.6
			s += closeness * distance_weight
			s += (1.0 - profile.flee_health) * health_weight * 0.4
			s -= supp * suppression_penalty * 0.8
		Role.SCOUT:
			s = mobility * mobility_weight * 1.2
			s += clampf(profile.sight_range / 200.0, 0.0, 1.0) * los_weight * 0.5
			s -= in_band * distance_weight * 0.5
			s -= supp * suppression_penalty * 0.3
	s *= 1.0 + bias_weight * (bias(profile, role) - 1.0)
	if role == current_role:
		s += keep_role_bonus
	return s


## Fill the quotas. Returns one role per member, parallel to the arrays handed in.
##
## Greedy by design. A true assignment solve would be a few per cent better at
## fifty times the cost, and the hysteresis bonus matters far more to how a squad
## reads than optimality does.
func assign(
	profiles: Array[AISpeciesProfile],
	dist: PackedFloat32Array,
	health: PackedFloat32Array,
	ammo: PackedFloat32Array,
	los: PackedInt32Array,
	cover: PackedInt32Array,
	suppression: PackedFloat32Array,
	current: PackedInt32Array
) -> PackedInt32Array:
	var size: int = profiles.size()
	var out: PackedInt32Array = PackedInt32Array()
	out.resize(size)
	if size == 0:
		return out
	var taken: PackedInt32Array = PackedInt32Array()
	taken.resize(size)
	var quota: PackedInt32Array = quotas(size)
	for i: int in size:
		out[i] = Role.ANCHOR
		taken[i] = 0
	for role: int in [Role.SUPPRESSOR, Role.ADVANCER, Role.FLANKER, Role.SCOUT]:
		for _slot: int in quota[role]:
			var best: int = -1
			var best_s: float = -INF
			for i: int in size:
				if taken[i] != 0:
					continue
				var s: float = score(
					role,
					profiles[i],
					dist[i],
					health[i],
					ammo[i],
					los[i] != 0,
					cover[i] != 0,
					suppression[i],
					current[i]
				)
				if s > best_s:
					best_s = s
					best = i
			if best < 0:
				break
			out[best] = role
			taken[best] = 1
	return out
