class_name SpeciesDefs
extends RefCounted
## The roster's front door, and the three lines every species shares.
##
## A species is a table of proportions handed to a body-plan builder plus the
## welded extras that give it a face and a weapon. Nothing is procedural and
## nothing is random: two calls to `build()` with the same id produce identical
## geometry, which is what lets the bake cache meshes across the whole bestiary.
##
## The measurements live one directory down, split by faction class —
## `SpeciesScav`, `SpeciesMachine`, `SpeciesMutant`. Part and bone counts are
## asserted against `SpeciesTable.CATALOGUE`, so a primitive lost to a bad edit
## fails the bake rather than shipping a creature with a hole in it.
##
## Prefer `SpeciesTable.build()`: the rig this returns has no gait solved onto it
## yet, and an unsolved rig poses into a puddle.


## Build one species' rig, un-solved.
static func build(id: StringName) -> EnemyRig:
	match id:
		&"rat":
			return SpeciesScav.rat()
		&"picker":
			return SpeciesScav.picker()
		&"gasman":
			return SpeciesScav.gasman()
		&"marksman":
			return SpeciesScav.marksman()
		&"latchdog":
			return SpeciesMachine.latchdog()
		&"sentinel":
			return SpeciesMachine.sentinel()
		&"wasp":
			return SpeciesMachine.wasp()
		&"foreman":
			return SpeciesMachine.foreman()
		&"husk":
			return SpeciesMutant.husk()
		&"stilt":
			return SpeciesMutant.stilt()
		&"skitter":
			return SpeciesMutant.skitter()
		&"gorger":
			return SpeciesMutant.gorger()
	push_error("SpeciesDefs: no species named '%s'." % id)
	return null


## An empty rig with its catalogue identity and body density set.
static func new_rig(
	id: StringName, display: String, klass: StringName, role: String, blurb: String, rho: float
) -> EnemyRig:
	var r := EnemyRig.new()
	r.id = id
	r.display_name = display
	r.faction_class = klass
	r.role = role
	r.blurb = blurb
	r.rho = rho
	r.resource_name = String(id)
	return r


## Authored gait inputs. Everything else — frequency, stride, speed — is measured
## off the rest pose by `GaitSolver`, so these six are the only gait knobs.
static func set_gait(
	r: EnemyRig, duty: float, stride_k: float, freq_k: float, lift: float, bob: float, sway: float
) -> void:
	r.gait = {
		"type": "biped",
		"duty": duty,
		"stride_k": stride_k,
		"freq_k": freq_k,
		"lift": lift,
		"bob": bob,
		"sway": sway
	}


## Combat identity: damage per second, sight range, attack reach, and the health
## and armour multipliers applied on top of the measured geometry.
static func set_info(
	r: EnemyRig, dps: float, detect: float, reach: float, hp_k: float, arm_k: float
) -> void:
	r.info = {"dps": dps, "detect": detect, "reach": reach, "hp_k": hp_k, "arm_k": arm_k}
