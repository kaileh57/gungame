class_name SpeciesTable
extends RefCounted
## The bestiary catalogue: what exists, what it is called, and how to get one.
##
## Twelve species — four scav, four machine, four mutant — 714 welded parts over
## 207 bones. The counts in `CATALOGUE` are not documentation: the bake asserts
## them, so a primitive silently lost to a bad edit fails the run rather than
## shipping a creature with a hole in it.
##
## Building a species is deterministic and cheap enough to do at bake time and at
## runtime both, but shipping code should load the baked `EnemyStats` and mesh
## buckets rather than re-deriving anything.

## Every id, in roster order. The instantiation seed depends on this order.
const IDS: Array[StringName] = [
	&"rat",
	&"picker",
	&"gasman",
	&"marksman",
	&"latchdog",
	&"sentinel",
	&"wasp",
	&"foreman",
	&"husk",
	&"stilt",
	&"skitter",
	&"gorger"
]

## Seed of the first species; each subsequent one steps by `SEED_STEP`. The seed
## drives the death collapse, so two rats with the same take fall identically and
## a rat and a husk never do.
const SEED_BASE: int = 1013
const SEED_STEP: int = 7919

## Layer every limb hitbox sits on. A shot resolves here, never against the body's
## broad collider.
const HITBOX_LAYER: int = GameLayers.ENEMY_HITBOX

## Hitboxes smaller than this in any axis are grown to it. A 12 mm claw tip is
## geometry, not a target, and a collider that thin costs more than it earns.
const HITBOX_MIN_EXTENT: float = 0.03

## id -> {display, class, role, parts, bones, legs, arms}. `parts` and `bones` are
## the reference's measured counts and are asserted by the bake.
const CATALOGUE: Dictionary = {
	&"rat":
	{
		"display": "Scav Rat",
		"class": &"scav",
		"role": "rusher",
		"parts": 52,
		"bones": 17,
		"legs": 2,
		"arms": 2
	},
	&"picker":
	{
		"display": "Picker",
		"class": &"scav",
		"role": "brawler",
		"parts": 55,
		"bones": 17,
		"legs": 2,
		"arms": 2
	},
	&"gasman":
	{
		"display": "Gasman",
		"class": &"scav",
		"role": "area denial",
		"parts": 69,
		"bones": 17,
		"legs": 2,
		"arms": 2
	},
	&"marksman":
	{
		"display": "Marksman",
		"class": &"scav",
		"role": "ranged",
		"parts": 69,
		"bones": 18,
		"legs": 2,
		"arms": 2
	},
	&"latchdog":
	{
		"display": "Latchdog",
		"class": &"machine",
		"role": "hunter",
		"parts": 49,
		"bones": 18,
		"legs": 4,
		"arms": 0
	},
	&"sentinel":
	{
		"display": "Sentinel",
		"class": &"machine",
		"role": "suppression",
		"parts": 49,
		"bones": 17,
		"legs": 2,
		"arms": 2
	},
	&"wasp":
	{
		"display": "Wasp",
		"class": &"machine",
		"role": "recon",
		"parts": 37,
		"bones": 10,
		"legs": 0,
		"arms": 0
	},
	&"foreman":
	{
		"display": "Foreman",
		"class": &"machine",
		"role": "siege",
		"parts": 65,
		"bones": 19,
		"legs": 4,
		"arms": 0
	},
	&"husk":
	{
		"display": "Husk",
		"class": &"mutant",
		"role": "fodder",
		"parts": 80,
		"bones": 17,
		"legs": 2,
		"arms": 2
	},
	&"stilt":
	{
		"display": "Stilt",
		"class": &"mutant",
		"role": "stalker",
		"parts": 78,
		"bones": 17,
		"legs": 2,
		"arms": 2
	},
	&"skitter":
	{
		"display": "Skitter",
		"class": &"mutant",
		"role": "swarm",
		"parts": 59,
		"bones": 23,
		"legs": 6,
		"arms": 0
	},
	&"gorger":
	{
		"display": "Gorger",
		"class": &"mutant",
		"role": "detonator",
		"parts": 52,
		"bones": 17,
		"legs": 2,
		"arms": 2
	}
}


static func has(id: StringName) -> bool:
	return CATALOGUE.has(id)


static func index_of(id: StringName) -> int:
	return IDS.find(id)


## Death-collapse seed for a species. Stable across runs and across builds.
static func seed_for(id: StringName) -> int:
	return SEED_BASE + index_of(id) * SEED_STEP


static func display_name(id: StringName) -> String:
	return String(CATALOGUE[id]["display"])


## Ids belonging to one of `scav`, `machine`, `mutant`, in roster order.
static func by_class(klass: StringName) -> Array[StringName]:
	var out: Array[StringName] = []
	for id in IDS:
		if CATALOGUE[id]["class"] == klass:
			out.append(id)
	return out


## A fully measured rig: geometry built, gait solved off the rest pose. This is
## the only correct way to obtain one — an unsolved rig has no speeds, no limb
## lengths and no foot targets, and poses into a puddle.
static func build(id: StringName) -> EnemyRig:
	var rig: EnemyRig = SpeciesDefs.build(id)
	if rig == null:
		return null
	GaitSolver.solve(rig)
	return rig


## A rig, an instance and its stats, ready to pose. The stats are derived with
## `inst.stats` still null and assigned afterwards, which is the ordering the
## reference measures its idle bounds under.
static func instantiate(id: StringName) -> RigInstance:
	var rig: EnemyRig = build(id)
	if rig == null:
		return null
	var inst := RigInstance.new()
	inst.setup(rig)
	inst.seed_value = seed_for(id)
	inst.stats = EnemyStats.derive(inst)
	return inst


## Per-bone hit regions for a set-up instance, in declaration order.
##
## One box per bone that carries non-fx geometry, fitted in the bone's own local
## frame, so it follows the skeleton for free — no per-frame refit, no capsule
## approximation, and a claw tip is a limb hit rather than a torso hit. Zones are
## `head` (head and neck), `core` (root, spine and chest) and `limb` (everything
## else, including a carried weapon and the wasp's rotor arms).
##
## Each entry: `bone`, `bone_index`, `zone`, `center` and `size` in bone-local
## metres, and `layer`.
static func hitboxes(inst: RigInstance) -> Array[Dictionary]:
	var rig: EnemyRig = inst.rig
	var zones: Dictionary = _zone_map(rig)
	var lows: Array[Vector3] = []
	var highs: Array[Vector3] = []
	var used: PackedByteArray = PackedByteArray()
	lows.resize(rig.bones.size())
	highs.resize(rig.bones.size())
	used.resize(rig.bones.size())
	for i in inst.part_bone.size():
		if inst.part_fx[i] != 0:
			continue
		var b: int = inst.part_bone[i]
		if b < 0:
			continue
		var m: Transform3D = inst.part_local[i]
		var e: Vector3 = rig.parts[i].extent()
		for k in 8:
			var pt: Vector3 = (
				m
				* Vector3(
					e.x if (k & 1) != 0 else -e.x,
					e.y if (k & 2) != 0 else -e.y,
					e.z if (k & 4) != 0 else -e.z
				)
			)
			if used[b] == 0:
				lows[b] = pt
				highs[b] = pt
				used[b] = 1
			else:
				lows[b] = lows[b].min(pt)
				highs[b] = highs[b].max(pt)

	var out: Array[Dictionary] = []
	for b in rig.bones.size():
		if used[b] == 0:
			continue
		var size: Vector3 = (highs[b] - lows[b]).max(
			Vector3(HITBOX_MIN_EXTENT, HITBOX_MIN_EXTENT, HITBOX_MIN_EXTENT)
		)
		out.append(
			{
				"bone": rig.bones[b].name,
				"bone_index": b,
				"zone": zones.get(rig.bones[b].name, EnemyStats.ZONE_LIMB),
				"center": (highs[b] + lows[b]) * 0.5,
				"size": size,
				"layer": HITBOX_LAYER
			}
		)
	return out


## Bone name -> hit zone. Only the head, neck, root and spine chain are named;
## every other bone falls through to `limb`.
static func _zone_map(rig: EnemyRig) -> Dictionary:
	var out: Dictionary = {}
	if not rig.bones.is_empty():
		out[rig.bones[0].name] = EnemyStats.ZONE_CORE
	for b in rig.tags.get("spine", []):
		out[b] = EnemyStats.ZONE_CORE
	var neck: StringName = rig.tags.get("neck", &"")
	if not neck.is_empty():
		out[neck] = EnemyStats.ZONE_HEAD
	var head: StringName = rig.tags.get("head", &"")
	if not head.is_empty():
		out[head] = EnemyStats.ZONE_HEAD
	return out
