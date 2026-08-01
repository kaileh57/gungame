class_name EnemyStats
extends Resource
## Everything a fight needs to know about a species, measured off its geometry.
##
## Nothing here is typed in by hand. Mass comes from the primitive volumes, armour
## from the fraction of surface area made of hard materials, speed from stride
## travel over contact time, and threat from all of it. That is why a species
## cannot be made scarier by editing one number: widen its plate and it gains
## armour, mass, stagger resistance and threat together, which is the point.
##
## The fields are exported so a baked `.tres` stays legible and tunable in the
## inspector for a balance pass. The derivation COEFFICIENTS below are consts on
## purpose: they are calibrated against the reference's measured acceptance table
## (`docs/spec/bestiary.md` §16) and changing one silently re-tiers all twelve
## species at once.

## Threat bands. `min` is the inclusive floor; the scan is ascending and the last
## match wins, so a threat below the first floor still lands in Vermin.
const TIERS: Array[Dictionary] = [
	{"n": "Vermin", "c": "6f6a63", "min": -1.0},
	{"n": "Common", "c": "8a9a6b", "min": 33.0},
	{"n": "Hardened", "c": "57a0bb", "min": 40.0},
	{"n": "Elite", "c": "9a79c8", "min": 46.0},
	{"n": "Warlord", "c": "d8822f", "min": 54.0},
	{"n": "Apex", "c": "e6c14f", "min": 63.0}
]

## Boxes and cylinders bound a rounded body and every joint ball double-counts.
## Measured against the primitives, the naive sum over-counts by about a third.
const MASS_FUDGE: float = 0.69
const HP_K: float = 3.4
const HP_MASS_EXP: float = 0.62
## Full armour coverage more than doubles health on top of the mass term.
const HP_COVER_K: float = 1.05
const ARMOUR_K: float = 80.0
const ARMOUR_CAP: float = 95.0
const STAGGER_K: float = 26.0
const STAGGER_MIN: float = 2.0
const STAGGER_MAX: float = 99.0
## Threat weights, in order: damage, health, run speed, armour, detection, poise.
## They sum to exactly 1.0 and the result reads directly as a 0-99 rating.
const THREAT_W: Array[float] = [0.26, 0.24, 0.14, 0.14, 0.11, 0.11]
const THREAT_DPS_K: float = 26.0
const THREAT_HP_K: float = 23.0
const THREAT_SPEED_K: float = 15.0

## Hit zones. `head` takes the firing weapon's full crit multiplier, `core` takes
## 45 % of the crit bonus, and a limb takes neither.
const ZONE_HEAD: StringName = &"head"
const ZONE_CORE: StringName = &"core"
const ZONE_LIMB: StringName = &"limb"
## Fraction of the crit bonus a torso hit carries. Shared with the range's
## `impact()` so a plate and a picker score the same way.
const CORE_CRIT_FRACTION: float = 0.45

@export var id: StringName = &""
@export var display_name: String = ""

## Body mass in kg, from primitive volume times density.
@export_range(0.5, 4000.0, 0.001, "or_greater", "suffix:kg") var mass: float = 0.0
## Fraction of surface area made of armour-bearing material, 0 to 1.
@export_range(0.0, 1.0, 0.00001) var cover: float = 0.0
@export_range(1.0, 2000.0, 1.0, "or_greater", "suffix:hp") var health: float = 1.0
## Percent of incoming damage stopped before it reaches health.
@export_range(0.0, 95.0, 1.0, "suffix:%") var armour: float = 0.0
@export_range(0.0, 12.0, 0.001, "suffix:m/s") var speed: float = 0.0
@export_range(0.0, 14.0, 0.001, "suffix:m/s") var run_speed: float = 0.0
## Attack range in metres. 120 for the marksman, 0.8 for the skitter.
@export_range(0.5, 150.0, 0.01, "suffix:m") var reach: float = 1.0
## Sustained damage per second, or detonation damage for the gorger.
@export_range(0.0, 400.0, 0.1) var damage: float = 0.0
## Resistance to being staggered, 2 to 99. Grows with the log of mass.
@export_range(2.0, 99.0, 0.001) var stagger: float = 2.0
## Sight range the AI wakes at, in metres.
@export_range(0.0, 120.0, 0.1, "suffix:m") var detect: float = 40.0
@export_range(0.0, 99.0, 0.001) var threat: float = 0.0

@export_range(0, 5, 1) var tier_index: int = 0
@export var tier_name: String = "Vermin"
@export var tier_color: Color = Color("6f6a63")

## Standing bounds in metres, measured off the idle pose rather than the rest
## chain — a hunched husk is shorter than its bone tree claims.
@export_range(0.1, 6.0, 0.0001, "suffix:m") var height: float = 0.0
@export_range(0.1, 6.0, 0.0001, "suffix:m") var width: float = 0.0
@export_range(0.1, 6.0, 0.0001, "suffix:m") var depth: float = 0.0
## Height of the lowest geometry off the floor. Non-zero only for hover rigs.
@export_range(0.0, 3.0, 0.0001, "suffix:m") var alt: float = 0.0

## Per-species damage scalars on top of the zone rule, for a balance pass. A limb
## hit is worth less than a torso hit on every species; how much less is taste.
@export_range(0.25, 4.0, 0.01) var head_scale: float = 1.0
@export_range(0.25, 4.0, 0.01) var core_scale: float = 1.0
@export_range(0.05, 2.0, 0.01) var limb_scale: float = 0.7


## Tier index for a threat rating. Ascending scan, last match wins.
static func tier_of(threat_value: float) -> int:
	var out: int = 0
	for i in TIERS.size():
		if threat_value >= float(TIERS[i]["min"]):
			out = i
	return out


static func tier_name_of(threat_value: float) -> String:
	return String(TIERS[tier_of(threat_value)]["n"])


static func tier_color_of(threat_value: float) -> Color:
	return Color(String(TIERS[tier_of(threat_value)]["c"]))


## Damage multiplier for one hit, given the zone and the firing weapon's crit.
## Mirrors the range's `impact()` exactly, then applies the species scalar.
func zone_multiplier(zone: StringName, crit: float) -> float:
	match zone:
		ZONE_HEAD:
			return crit * head_scale
		ZONE_CORE:
			return (1.0 + (crit - 1.0) * CORE_CRIT_FRACTION) * core_scale
	return limb_scale


## Damage after armour and zone, for one hit of `raw` damage.
func apply_damage(raw: float, zone: StringName, crit: float) -> float:
	return maxf(0.0, raw * zone_multiplier(zone, crit) * (1.0 - armour * 0.01))


## Measure a set-up instance. The instance is posed to `idle` as a side effect,
## which is deliberate: the bounds are of the standing creature, not of the rest
## chain, and every armed rig measures a slightly different box once its weapon is
## solved onto the aim line.
##
## Call this with `inst.stats` still null. `BeastClips.aim_target_for` falls back
## to a 1.75 m reference height when it is, and the reference measures the idle
## box under exactly that fallback.
static func derive(inst: RigInstance) -> EnemyStats:
	var rig: EnemyRig = inst.rig
	var mass_sum: float = 0.0
	var area_sum: float = 0.0
	var hard_sum: float = 0.0
	for p in rig.parts:
		if BeastMat.is_fx(p.mat):
			continue
		var a: float = p.area()
		mass_sum += p.volume() * rig.density_of(p)
		area_sum += a
		hard_sum += a * BeastMat.hardness(p.mat)
	mass_sum *= MASS_FUDGE
	var cover_frac: float = clampf(hard_sum / maxf(area_sum, 1e-6), 0.0, 1.0)

	PoseSolver.pose(inst, BeastClips.IDLE, 0.0)
	var box: AABB = _idle_bounds(inst)

	var g: Dictionary = rig.gait
	var info: Dictionary = rig.info
	var s := EnemyStats.new()
	s.id = rig.id
	s.display_name = rig.display_name
	s.mass = mass_sum
	s.cover = cover_frac
	s.health = float(
		roundi(
			(
				HP_K
				* pow(mass_sum, HP_MASS_EXP)
				* (1.0 + HP_COVER_K * cover_frac)
				* float(info.get("hp_k", 1.0))
			)
		)
	)
	s.armour = float(
		roundi(clampf(cover_frac * ARMOUR_K * float(info.get("arm_k", 1.0)), 0.0, ARMOUR_CAP))
	)
	s.speed = float(g.get("speed", 0.0))
	s.run_speed = float(g.get("run_speed", s.speed))
	s.reach = _reach_of(rig)
	s.damage = float(info.get("dps", 10.0))
	s.stagger = clampf(STAGGER_K * BeastMath.log10(1.0 + mass_sum), STAGGER_MIN, STAGGER_MAX)
	s.detect = float(info.get("detect", 40.0))
	s.threat = (
		THREAT_W[0] * clampf(THREAT_DPS_K * BeastMath.log10(1.0 + s.damage), 0.0, 99.0)
		+ THREAT_W[1] * clampf(THREAT_HP_K * BeastMath.log10(1.0 + s.health), 0.0, 99.0)
		+ THREAT_W[2] * clampf(s.run_speed * THREAT_SPEED_K, 0.0, 99.0)
		+ THREAT_W[3] * s.armour
		+ THREAT_W[4] * clampf(s.detect, 0.0, 99.0)
		+ THREAT_W[5] * clampf(s.stagger, 0.0, 99.0)
	)
	s.tier_index = tier_of(s.threat)
	s.tier_name = String(TIERS[s.tier_index]["n"])
	s.tier_color = Color(String(TIERS[s.tier_index]["c"]))
	s.height = box.size.y
	s.width = box.size.x
	s.depth = box.size.z
	s.alt = maxf(0.0, box.position.y)
	s.resource_name = String(rig.id)
	return s


## Rig-space bounds of the posed shell, over the eight corners of every non-fx
## part's extent box. An AABB of an AABB, which is what the reference measures —
## substituting exact primitive support functions changes every height in §16.
static func _idle_bounds(inst: RigInstance) -> AABB:
	var box := AABB()
	var started: bool = false
	for i in inst.part_bone.size():
		if inst.part_fx[i] != 0:
			continue
		var m: Transform3D = inst.pose.globals[inst.part_bone[i]] * inst.part_local[i]
		var e: Vector3 = inst.rig.parts[i].extent()
		for k in 8:
			var corner := Vector3(
				e.x if (k & 1) != 0 else -e.x,
				e.y if (k & 2) != 0 else -e.y,
				e.z if (k & 4) != 0 else -e.z
			)
			var pt: Vector3 = m * corner
			if started:
				box = box.expand(pt)
			else:
				box = AABB(pt, Vector3.ZERO)
				started = true
	return box


## `info.reach` wins; a rig without one borrows 90 % of its stride reach. A reach
## of exactly zero is not a legal value — use the gait fallback explicitly.
static func _reach_of(rig: EnemyRig) -> float:
	var declared: float = float(rig.info.get("reach", 0.0))
	if declared > 0.0:
		return declared
	var gait_reach: float = float(rig.gait.get("reach", 0.0))
	return gait_reach * 0.9 if gait_reach > 0.0 else 1.0
