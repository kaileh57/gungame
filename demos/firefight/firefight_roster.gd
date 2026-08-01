class_name FirefightRoster
extends RefCounted
## Who fights for whom, and how. The demo's own roster data, in one place.
##
## The bestiary bake already sorted every creature into scav, machine or mutant
## and already derived its health, armour, speed, reach, sight and dps from the
## reference's numbers. Those three classes ARE `Factions.F` in order, and those
## derived stats are read straight off the baked `EnemyStats` — deriving a second
## health here would give the demo a body that dies at a different number from
## the one the bullets are working against.
##
## What is left is the half of a fighter the bestiary has no opinion about: how
## wide its cone of vision is, how fast it cycles, how much it will put up with
## before it runs, and which of the five squad roles it is any good at. That is
## `BEHAVIOUR`, and it is design data, so it is a table and not a formula.
##
## The one asymmetry worth knowing about: the Choir field no ranged species at
## all. The mutants' longest reach is the Stilt's 2.6 m. That is the bestiary's
## own truth and it is not papered over here — the Choir are a tide, they close
## or they die, and the territory model carries them because pressure comes from
## bodies standing on ground rather than from kills.

## Faction -> the species it fields, in the order `ROSTER_WEIGHTS` weights them.
const ROSTERS: Array = [
	[&"rat", &"picker", &"marksman", &"gasman"],
	[&"latchdog", &"sentinel", &"wasp", &"foreman"],
	[&"husk", &"skitter", &"stilt", &"gorger"],
]
## Relative draw weight per roster slot. Fodder is common, the long gun is not: a
## faction of nothing but marksmen never closes and so never captures anything.
const ROSTER_WEIGHTS: PackedFloat32Array = [4.0, 3.0, 2.0, 1.0]

## Melee, Rifle, Auto, Cone, Detonator — `AISpeciesProfile.Weapon`, by index.
const WEAPON_MELEE: int = 0
const WEAPON_RIFLE: int = 1
const WEAPON_AUTO: int = 2
const WEAPON_CONE: int = 3
const WEAPON_DETONATOR: int = 4

## fov, rpm, burst, mag, reload, spread, weapon, and the four role biases plus
## the two courage numbers. `mag` of 999 means a body that does not reload,
## which is every creature fighting with its own limbs.
const BEHAVIOUR: Dictionary = {
	&"rat":
	{
		"fov": 150.0,
		"rpm": 110.0,
		"burst": 1,
		"mag": 999,
		"reload": 0.6,
		"spread": 3.0,
		"weapon": WEAPON_MELEE,
		"supp": 0.0,
		"flank": 1.4,
		"adv": 1.9,
		"scout": 1.1,
		"rout": 0.55,
		"flee": 0.15,
	},
	&"picker":
	{
		"fov": 140.0,
		"rpm": 84.0,
		"burst": 1,
		"mag": 999,
		"reload": 0.6,
		"spread": 3.0,
		"weapon": WEAPON_MELEE,
		"supp": 0.0,
		"flank": 1.1,
		"adv": 1.7,
		"scout": 0.6,
		"rout": 0.65,
		"flee": 0.18,
	},
	&"gasman":
	{
		"fov": 120.0,
		"rpm": 46.0,
		"burst": 1,
		"mag": 14,
		"reload": 2.8,
		"spread": 7.0,
		"weapon": WEAPON_CONE,
		"supp": 1.3,
		"flank": 0.7,
		"adv": 1.1,
		"scout": 0.4,
		"rout": 0.7,
		"flee": 0.25,
	},
	&"marksman":
	{
		"fov": 96.0,
		"rpm": 52.0,
		"burst": 1,
		"mag": 8,
		"reload": 3.1,
		"spread": 0.55,
		"weapon": WEAPON_RIFLE,
		"supp": 1.1,
		"flank": 0.4,
		"adv": 0.35,
		"scout": 1.3,
		"rout": 0.75,
		"flee": 0.30,
	},
	&"latchdog":
	{
		"fov": 160.0,
		"rpm": 130.0,
		"burst": 1,
		"mag": 999,
		"reload": 0.5,
		"spread": 3.0,
		"weapon": WEAPON_MELEE,
		"supp": 0.0,
		"flank": 1.8,
		"adv": 1.9,
		"scout": 1.4,
		"rout": 0.85,
		"flee": 0.0,
	},
	&"sentinel":
	{
		"fov": 118.0,
		"rpm": 520.0,
		"burst": 9,
		"mag": 90,
		"reload": 3.6,
		"spread": 1.7,
		"weapon": WEAPON_AUTO,
		"supp": 2.2,
		"flank": 0.35,
		"adv": 0.6,
		"scout": 0.5,
		"rout": 0.9,
		"flee": 0.0,
	},
	&"wasp":
	{
		"fov": 200.0,
		"rpm": 190.0,
		"burst": 3,
		"mag": 30,
		"reload": 2.4,
		"spread": 2.4,
		"weapon": WEAPON_RIFLE,
		"supp": 0.7,
		"flank": 1.5,
		"adv": 0.9,
		"scout": 2.2,
		"rout": 0.6,
		"flee": 0.35,
	},
	&"foreman":
	{
		"fov": 130.0,
		"rpm": 40.0,
		"burst": 1,
		"mag": 999,
		"reload": 0.8,
		"spread": 3.0,
		"weapon": WEAPON_MELEE,
		"supp": 0.0,
		"flank": 0.2,
		"adv": 1.6,
		"scout": 0.1,
		"rout": 0.95,
		"flee": 0.0,
	},
	&"husk":
	{
		"fov": 130.0,
		"rpm": 60.0,
		"burst": 1,
		"mag": 999,
		"reload": 0.6,
		"spread": 4.0,
		"weapon": WEAPON_MELEE,
		"supp": 0.0,
		"flank": 0.6,
		"adv": 1.8,
		"scout": 0.2,
		"rout": 0.9,
		"flee": 0.05,
	},
	&"stilt":
	{
		"fov": 150.0,
		"rpm": 48.0,
		"burst": 1,
		"mag": 999,
		"reload": 0.7,
		"spread": 3.0,
		"weapon": WEAPON_MELEE,
		"supp": 0.0,
		"flank": 1.9,
		"adv": 1.2,
		"scout": 1.6,
		"rout": 0.6,
		"flee": 0.22,
	},
	&"skitter":
	{
		"fov": 200.0,
		"rpm": 150.0,
		"burst": 1,
		"mag": 999,
		"reload": 0.5,
		"spread": 4.0,
		"weapon": WEAPON_MELEE,
		"supp": 0.0,
		"flank": 1.6,
		"adv": 2.0,
		"scout": 0.9,
		"rout": 0.5,
		"flee": 0.10,
	},
	&"gorger":
	{
		"fov": 120.0,
		"rpm": 30.0,
		"burst": 1,
		"mag": 1,
		"reload": 6.0,
		"spread": 3.0,
		"weapon": WEAPON_DETONATOR,
		"supp": 0.0,
		"flank": 0.3,
		"adv": 2.0,
		"scout": 0.0,
		"rout": 1.0,
		"flee": 0.0,
	},
}

## Blast radius given to a detonator species, in metres.
const BLAST_RADIUS: float = 4.2

## Ceiling on armour inside this demo, as a percentage. Nothing here may take
## less than half of what is aimed at it.
##
## THIS IS THE ONE BODY NUMBER THE DEMO OVERRIDES, and it is overridden because
## without it the demo is not a war. `EnemyActor.apply_damage_at` multiplies
## incoming damage by `1 - armour/100`, and the bestiary hands the machines 69,
## 76 and 86 per cent against the 2 to 18 the scavs and mutants get. Multiplied
## out that is effective hit points of 252 for a Latchdog, 588 for a Sentinel and
## 7,600 for a Foreman, against 31 for a Husk and 44 for a Rat — the mean Foundry
## body is worth sixteen Choir. Measured on the live demo before this cap: the
## Foundry lost TWO bodies in six minutes while the other two lost sixty each,
## its zones could never be taken because a garrison that cannot be killed holds
## its ledger pressure at the 1.0 clamp forever, and the map set at 1/4/2 and
## stayed there. A Husk swinging 18 damage at 60 rpm needs seven minutes of
## uninterrupted contact to kill one Foreman.
##
## Fifty is where the asymmetry stops being a stalemate: a Foreman is still 2,128
## effective hit points and still the hardest thing on the field, and the Foundry
## is still four times the meat of anyone else. It just dies eventually.
##
## The bestiary's numbers themselves are NOT touched — `data/enemies/*.res` and
## every other consumer of `EnemyStats` see the real ones. This applies to
## `firefight_profiles.tres` and nothing else.
const ARMOUR_CEILING: float = 50.0


## Which faction fields a species, off the bestiary's own class.
static func faction_of(id: StringName) -> int:
	match StringName(SpeciesTable.CATALOGUE[id]["class"]):
		&"scav":
			return Factions.F.SCAV
		&"machine":
			return Factions.F.FOUNDRY
		_:
			return Factions.F.CHOIR


## Draw a species for `faction` from `u` in [0, 1), weighted by `ROSTER_WEIGHTS`.
static func draw(faction: int, u: float) -> StringName:
	var roster: Array = ROSTERS[faction]
	var total: float = 0.0
	for i: int in roster.size():
		total += ROSTER_WEIGHTS[mini(i, ROSTER_WEIGHTS.size() - 1)]
	var t: float = clampf(u, 0.0, 0.9999) * total
	for i: int in roster.size():
		t -= ROSTER_WEIGHTS[mini(i, ROSTER_WEIGHTS.size() - 1)]
		if t <= 0.0:
			return roster[i]
	return roster[roster.size() - 1]


## Build one species' AI profile from its baked stats plus the table above. Runs
## at bake time only; `res://tools/build_firefight.gd` writes the result out as a
## resource and the demo loads that.
static func profile_for(id: StringName, stats: EnemyStats) -> AISpeciesProfile:
	var b: Dictionary = BEHAVIOUR[id]
	var p := AISpeciesProfile.new()
	p.resource_name = String(id)
	p.species_id = id
	p.display_name = SpeciesTable.display_name(id)
	p.faction = faction_of(id)
	p.threat = stats.threat
	p.tier = stats.tier_index

	p.height = stats.height
	p.body_radius = maxf(maxf(stats.width, stats.depth) * 0.5, 0.22)
	p.health = maxf(stats.health, 1.0)
	p.armour = minf(stats.armour, ARMOUR_CEILING)
	p.eye_height = maxf(stats.height * 0.86, 0.3)
	p.walk_speed = maxf(stats.speed, 0.4)
	p.run_speed = maxf(stats.run_speed, p.walk_speed + 0.2)
	p.turn_rate = clampf(3.0 + 4.0 / maxf(p.height, 0.4), 0.3, 12.0)
	# The bestiary records a hovering species' rest altitude as `alt`. Anything
	# that flies holds that height above the ground instead of standing on it.
	p.hover_height = stats.alt if id == &"wasp" else 0.0

	p.sight_range = maxf(stats.detect, 12.0)
	p.fov_degrees = float(b["fov"])
	p.peripheral_range = clampf(p.body_radius * 8.0, 2.0, 8.0)
	p.awareness_gain = 2.2
	p.awareness_decay = 0.42
	p.hearing_sensitivity = 1.0
	# The more dangerous the thing, the faster it is off the mark. Flat 0.42 s
	# gives a Husk and a Foreman the same reflexes, which they should not have.
	p.reaction_time = clampf(0.42 - stats.threat * 0.004, 0.10, 0.6)

	var weapon: int = int(b["weapon"])
	p.weapon = weapon
	p.weapon_range = maxf(stats.reach, 1.0)
	p.min_range = 0.0
	p.rpm = float(b["rpm"])
	p.burst = int(b["burst"])
	p.burst_pause = 0.55 if p.burst > 1 else 1.0
	p.magazine = mini(int(b["mag"]), 400)
	p.reload_time = float(b["reload"])
	p.spread_degrees = float(b["spread"])
	p.aim_settle = 0.7
	# `EnemyStats.damage` is the reference's sustained dps. Splitting it across
	# the rate of fire is what makes a body that fires nine times a second and
	# one that swings twice do the damage over a second the bestiary promised.
	p.damage = maxf(stats.damage * 60.0 / maxf(p.rpm, 1.0), 1.0)
	p.blast_radius = BLAST_RADIUS if weapon == WEAPON_DETONATOR else 0.0
	p.suicide_charge = weapon == WEAPON_DETONATOR

	p.flee_health = float(b["flee"])
	p.rout_fraction = float(b["rout"])
	p.suppression_tolerance = clampf(0.35 + stats.armour * 0.006, 0.2, 0.95)
	p.suppression_gain = 1.0
	p.bias_suppressor = float(b["supp"])
	p.bias_flanker = float(b["flank"])
	p.bias_advancer = float(b["adv"])
	p.bias_scout = float(b["scout"])
	p.reference_dps = stats.damage
	return p
