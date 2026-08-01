class_name SpeciesMutant
extends RefCounted
## The four mutants: what the dust makes of a body given long enough.
##
## Three humanoids stretched or swollen off the shared biped builder, plus a
## hand-built hexapod. Bone claws and dorsal spines are routed with `tube()`, so
## every kink carries a ball and a claw cannot come apart at full extension.
## Every measurement is transcribed from the reference and reproduces the
## acceptance table in `docs/spec/bestiary.md` §16.

const M_HUSK: Dictionary = {
	"torso": &"pallid",
	"abs": &"pallid",
	"leg": &"pallid",
	"boot": &"hide",
	"arm": &"pallid",
	"hand": &"pallid",
	"skin": &"pallid",
	"shoulder": &"bone"
}
const M_STILT: Dictionary = {
	"torso": &"pallid",
	"abs": &"pallid",
	"leg": &"pallid",
	"boot": &"pallid",
	"arm": &"pallid",
	"hand": &"pallid",
	"skin": &"pallid",
	"shoulder": &"bone"
}
const M_GORGER: Dictionary = {
	"torso": &"gut",
	"abs": &"gut",
	"leg": &"flesh",
	"boot": &"hide",
	"arm": &"flesh",
	"hand": &"flesh",
	"skin": &"flesh",
	"shoulder": &"flesh"
}


static func husk() -> EnemyRig:
	var r: EnemyRig = SpeciesDefs.new_rig(
		&"husk",
		"Husk",
		&"mutant",
		"fodder",
		(
			"Whatever is left after the dust finishes with a person. Slow, stupid, "
			+ "and there are always more behind it."
		),
		720.0
	)
	RigBuilders.humanoid(
		r,
		{
			"hipY": 0.835,
			"footH": 0.065,
			"footL": 0.245,
			"legR": 0.052,
			"hipW": 0.082,
			"pelvH": 0.175,
			"pelvD": 0.155,
			"waistW": 0.205,
			"waistD": 0.145,
			"absH": 0.215,
			"chestW": 0.305,
			"chestH": 0.295,
			"chestD": 0.185,
			"neckR": 0.048,
			"neckH": 0.10,
			"shW": 0.142,
			"armU": 0.30,
			"armL": 0.285,
			"armR": 0.038,
			"handL": 0.115,
			"armOut": 0.08,
			"m": M_HUSK
		}
	)
	r.tags["hunch"] = 0.20
	r.tags["lean_run"] = 0.10

	r.box(&"head", Vector3(0.0, 0.008, 0.008), Vector3(0.145, 0.185, 0.185), &"pallid")
	r.box(&"head", Vector3(0.0, -0.062, 0.075), Vector3(0.10, 0.075, 0.075), &"pallid")
	r.sph(&"head", Vector3(-0.045, 0.035, 0.078), 0.022, &"gut")
	r.sph(&"head", Vector3(0.045, 0.035, 0.078), 0.022, &"gut")
	r.box(&"head", Vector3(0.0, 0.078, -0.015), Vector3(0.115, 0.062, 0.135), &"gut")
	for i in 4:
		r.box(
			&"chest",
			Vector3(0.0, 0.02 + float(i) * 0.062, 0.098),
			Vector3(0.245 - float(i) * 0.012, 0.026, 0.045),
			&"bone"
		)
	r.box(&"chest", Vector3(0.0, 0.10, 0.105), Vector3(0.038, 0.245, 0.045), &"bone")
	r.box(&"spine", Vector3(0.0, 0.10, -0.075), Vector3(0.045, 0.30, 0.062), &"bone")
	r.sph(&"spine", Vector3(0.0, 0.06, 0.075), 0.088, &"gut")
	r.box(&"pelvis", Vector3(0.0, 0.02, 0.0), Vector3(0.245, 0.155, 0.185), &"canvas")
	r.box(&"l_sh", Vector3(-0.018, 0.02, 0.0), Vector3(0.045, 0.115, 0.115), &"bone")
	for wrist: StringName in [&"l_wr", &"r_wr"]:
		for i in [-1.0, 0.0, 1.0]:
			var claw: Array[Vector3] = [
				Vector3(i * 0.022, -0.075, 0.010),
				Vector3(i * 0.030, -0.145, 0.048),
				Vector3(i * 0.034, -0.205, 0.062)
			]
			r.tube(wrist, claw, 0.010, &"bone")

	r.arms[0].attack = true
	r.arms[0].atk_pose = Vector4(-1.65, 0.0, -0.35, 0.30)
	r.arms[0].atk_wind = 1.2
	r.arms[1].attack = true
	r.arms[1].atk_pose = Vector4(-1.45, 0.0, 0.35, 0.45)
	r.arms[1].atk_wind = 1.0
	r.arms[0].rest = Vector3(-0.32, 0.0, -0.10)
	r.arms[1].rest = Vector3(-0.28, 0.0, 0.10)
	r.arms[0].elbow_rest = 0.62
	r.arms[1].elbow_rest = 0.55
	SpeciesDefs.set_gait(r, 0.68, 1.05, 0.76, 0.075, 0.026, 0.055)
	SpeciesDefs.set_info(r, 18.0, 22.0, 1.25, 0.85, 0.6)
	return r


static func stilt() -> EnemyRig:
	var r: EnemyRig = SpeciesDefs.new_rig(
		&"stilt",
		"Stilt",
		&"mutant",
		"stalker",
		(
			"Three metres of bad news that walks quietly and reaches over cover. "
			+ "Aim for the knees, there is nothing else worth hitting."
		),
		690.0
	)
	RigBuilders.humanoid(
		r,
		{
			"hipY": 1.72,
			"footH": 0.078,
			"footL": 0.34,
			"legR": 0.076,
			"hipW": 0.108,
			"pelvH": 0.225,
			"pelvD": 0.195,
			"waistW": 0.255,
			"waistD": 0.185,
			"absH": 0.335,
			"chestW": 0.365,
			"chestH": 0.345,
			"chestD": 0.225,
			"neckR": 0.056,
			"neckH": 0.185,
			"shW": 0.168,
			"armU": 0.52,
			"armL": 0.50,
			"armR": 0.054,
			"handL": 0.185,
			"armOut": 0.06,
			"split": 0.50,
			"m": M_STILT
		}
	)
	r.tags["hunch"] = 0.10
	r.tags["lean_run"] = 0.10

	r.box(&"head", Vector3(0.0, 0.008, 0.02), Vector3(0.135, 0.225, 0.195), &"pallid")
	r.box(
		&"head",
		Vector3(0.0, -0.082, 0.062),
		Vector3(0.10, 0.125, 0.125),
		&"pallid",
		{"rot": Vector3(0.2, 0.0, 0.0)}
	)
	r.sph(&"head", Vector3(0.0, 0.075, 0.062), 0.030, &"gut")
	r.box(&"head", Vector3(0.0, 0.135, -0.02), Vector3(0.098, 0.075, 0.155), &"bone")
	for i in 5:
		r.box(
			&"spine",
			Vector3(0.0, 0.02 + float(i) * 0.070, -0.078),
			Vector3(0.048, 0.062, 0.075),
			&"bone",
			{"rot": Vector3(0.3, 0.0, 0.0)}
		)
	r.box(&"chest", Vector3(0.0, 0.135, 0.098), Vector3(0.185, 0.235, 0.048), &"bone")
	r.box(&"l_sh", Vector3(-0.022, 0.03, 0.0), Vector3(0.055, 0.135, 0.115), &"bone")
	r.box(&"r_sh", Vector3(0.022, 0.03, 0.0), Vector3(0.055, 0.135, 0.115), &"bone")
	for wrist: StringName in [&"l_wr", &"r_wr"]:
		for i in [-1.0, 0.0, 1.0]:
			var claw: Array[Vector3] = [
				Vector3(i * 0.024, -0.085, 0.012),
				Vector3(i * 0.032, -0.20, 0.058),
				Vector3(i * 0.038, -0.315, 0.082)
			]
			r.tube(wrist, claw, 0.010, &"bone")

	# Arms held forward, not down: it reaches before it steps.
	r.arms[0].rest = Vector3(0.16, 0.0, -0.06)
	r.arms[1].rest = Vector3(0.16, 0.0, 0.06)
	r.arms[0].elbow_rest = 0.30
	r.arms[1].elbow_rest = 0.30
	r.arms[0].swing = 0.34
	r.arms[1].swing = 0.34
	r.arms[0].attack = true
	r.arms[0].atk_pose = Vector4(-2.05, 0.0, -0.30, 0.20)
	r.arms[0].atk_wind = 0.9
	r.arms[1].attack = true
	r.arms[1].atk_pose = Vector4(-2.05, 0.0, 0.30, 0.20)
	r.arms[1].atk_wind = 0.9
	SpeciesDefs.set_gait(r, 0.64, 1.10, 0.82, 0.155, 0.030, 0.030)
	SpeciesDefs.set_info(r, 62.0, 58.0, 2.6, 0.95, 0.7)
	return r


static func skitter() -> EnemyRig:
	var r: EnemyRig = SpeciesDefs.new_rig(
		&"skitter",
		"Skitter",
		&"mutant",
		"swarm",
		(
			"Six legs, no patience. Comes out of drains in numbers and goes for "
			+ "ankles because that is all it can reach."
		),
		520.0
	)
	r.bone(&"pelvis", &"", Vector3(0.0, 0.40, -0.20))
	r.sph(&"pelvis", Vector3.ZERO, 0.155, &"chitin")
	r.sph(&"pelvis", Vector3(0.0, 0.02, -0.185), 0.185, &"chitin")
	r.box(
		&"pelvis",
		Vector3(0.0, 0.10, -0.185),
		Vector3(0.22, 0.115, 0.28),
		&"chitin",
		{"rot": Vector3(0.2, 0.0, 0.0)}
	)
	r.bone(&"spine", &"pelvis", Vector3(0.0, 0.01, 0.185))
	r.sph(&"spine", Vector3.ZERO, 0.125, &"chitin")
	r.box(&"spine", Vector3(0.0, 0.02, 0.02), Vector3(0.245, 0.155, 0.235), &"chitin")
	r.bone(&"chest", &"spine", Vector3(0.0, 0.005, 0.185))
	r.sph(&"chest", Vector3.ZERO, 0.125, &"chitin")
	r.box(&"chest", Vector3(0.0, 0.02, 0.04), Vector3(0.265, 0.145, 0.225), &"chitin")
	r.box(
		&"chest",
		Vector3(0.0, 0.085, 0.02),
		Vector3(0.185, 0.062, 0.185),
		&"chitin",
		{"rot": Vector3(0.15, 0.0, 0.0)}
	)
	r.tags["spine"] = [&"spine", &"chest"]
	r.tags["flex"] = 0.40

	r.bone(&"neck", &"chest", Vector3(0.0, -0.01, 0.135))
	r.sph(&"neck", Vector3.ZERO, 0.085, &"chitin")
	r.bone(&"head", &"neck", Vector3(0.0, 0.0, 0.055))
	r.sph(&"head", Vector3.ZERO, 0.082, &"chitin")
	r.box(&"head", Vector3(0.0, 0.0, 0.055), Vector3(0.155, 0.098, 0.135), &"chitin")
	for s in [-1.0, 1.0]:
		r.sph(&"head", Vector3(s * 0.052, 0.035, 0.098), 0.030, &"gut")
		r.sph(&"head", Vector3(s * 0.026, 0.048, 0.108), 0.018, &"gut")
		r.cyl(
			&"head",
			Vector3(s * 0.045, -0.03, 0.135),
			0.018,
			0.006,
			0.155,
			&"chitin",
			{"rot": Vector3(1.25, 0.0, s * 0.35)}
		)
	r.tags["head"] = &"head"
	r.tags["neck"] = &"neck"
	r.tags["neck_pitch"] = 0.10

	# Six splayed legs in two alternating tripods, {l0,r1,l2} against {r0,l1,r2}.
	# The pole points up and out, which is what reads as arthropod rather than dog.
	var rows: Array = [
		{"parent": &"chest", "z": 0.10, "out": 0.40, "u": 0.34, "l": 0.34, "ph": 0.0},
		{"parent": &"spine", "z": 0.00, "out": 0.36, "u": 0.36, "l": 0.36, "ph": 0.5},
		{"parent": &"pelvis", "z": -0.08, "out": 0.40, "u": 0.36, "l": 0.36, "ph": 0.0}
	]
	for ri in rows.size():
		var row: Dictionary = rows[ri]
		var upper: float = row["u"]
		var lower: float = row["l"]
		for s in [-1.0, 1.0]:
			var nm: String = ("l" if s < 0.0 else "r") + str(ri)
			var hip := StringName(nm + "_hip")
			var knee := StringName(nm + "_knee")
			var ankle := StringName(nm + "_ank")
			r.link(
				hip,
				row["parent"],
				Vector3(s * 0.10, 0.03, row["z"]),
				upper,
				0.036,
				0.028,
				&"chitin",
				{"ball_r": 0.052}
			)
			r.link(
				knee,
				hip,
				Vector3(0.0, -upper, 0.0),
				lower,
				0.028,
				0.015,
				&"chitin",
				{"ball_r": 0.040}
			)
			r.bone(ankle, knee, Vector3(0.0, -lower, 0.0))
			r.sph(ankle, Vector3.ZERO, 0.024, &"chitin")
			r.cyl(ankle, Vector3(0.0, -0.045, 0.0), 0.018, 0.010, 0.10, &"chitin")
			r.sph(ankle, Vector3(0.0, -0.09, 0.0), 0.024, &"chitin")
			var leg := RigLeg.new()
			leg.hip = hip
			leg.knee = knee
			leg.ankle = ankle
			leg.side = s
			leg.phase = fmod(float(row["ph"]) + (0.0 if s < 0.0 else 0.5), 1.0)
			leg.pole = Vector3(s, 1.25, 0.0)
			leg.out_x = s * float(row["out"])
			leg.has_pastern = true
			leg.pastern_len = 0.09
			leg.pastern_pad_r = 0.024
			leg.pastern_a0 = 0.10
			leg.pastern_a1 = 0.42
			leg.pastern_dir = 1.0
			r.legs.append(leg)

	SpeciesDefs.set_gait(r, 0.46, 1.00, 1.55, 0.085, 0.012, 0.010)
	SpeciesDefs.set_info(r, 20.0, 44.0, 0.8, 0.8, 1.0)
	return r


static func gorger() -> EnemyRig:
	var r: EnemyRig = SpeciesDefs.new_rig(
		&"gorger",
		"Gorger",
		&"mutant",
		"detonator",
		(
			"Full of something that used to be a person and is now mostly pressure. "
			+ "Do not let it get inside fifteen metres."
		),
		600.0
	)
	RigBuilders.humanoid(
		r,
		{
			"hipY": 0.735,
			"footH": 0.088,
			"footL": 0.265,
			"legR": 0.105,
			"hipW": 0.145,
			"pelvH": 0.245,
			"pelvD": 0.315,
			"waistW": 0.475,
			"waistD": 0.415,
			"absH": 0.245,
			"chestW": 0.50,
			"chestH": 0.315,
			"chestD": 0.395,
			"neckR": 0.088,
			"neckH": 0.045,
			"shW": 0.225,
			"armU": 0.245,
			"armL": 0.225,
			"armR": 0.062,
			"handL": 0.115,
			"armOut": 0.34,
			"split": 0.50,
			"m": M_GORGER
		}
	)
	r.tags["hunch"] = 0.05
	r.tags["lean_run"] = 0.08

	r.sph(&"spine", Vector3(0.0, 0.055, 0.115), 0.245, &"gut")
	r.sph(&"spine", Vector3(-0.165, 0.005, 0.055), 0.165, &"gut")
	r.sph(&"spine", Vector3(0.165, 0.005, 0.055), 0.165, &"gut")
	r.sph(&"spine", Vector3(0.0, -0.075, 0.075), 0.185, &"gut")
	r.sph(&"chest", Vector3(0.0, 0.045, 0.145), 0.165, &"gut")
	# Pressure sacs, deliberately asymmetric.
	r.sph(&"chest", Vector3(-0.185, 0.145, -0.155), 0.125, &"gut")
	r.sph(&"chest", Vector3(0.165, 0.195, -0.125), 0.098, &"gut")
	r.sph(&"spine", Vector3(0.0, 0.115, -0.215), 0.135, &"gut")
	r.sph(&"spine", Vector3(-0.215, 0.135, -0.055), 0.095, &"gut")
	# Head sunk into the shoulders.
	r.sph(&"head", Vector3(0.0, 0.02, 0.02), 0.115, &"flesh")
	r.box(&"head", Vector3(0.0, -0.035, 0.078), Vector3(0.135, 0.088, 0.098), &"gut")
	r.sph(&"head", Vector3(-0.048, 0.055, 0.088), 0.024, &"gut")
	r.sph(&"head", Vector3(0.048, 0.055, 0.088), 0.024, &"gut")
	r.box(&"head", Vector3(0.0, 0.075, -0.02), Vector3(0.155, 0.075, 0.145), &"hide")
	r.box(&"pelvis", Vector3(0.0, 0.03, 0.0), Vector3(0.50, 0.215, 0.375), &"canvas")
	r.box(&"pelvis", Vector3(0.0, 0.115, 0.015), Vector3(0.53, 0.075, 0.40), &"hide")

	# Arms shoved out by the belly.
	r.arms[0].rest = Vector3(-0.20, 0.0, -0.42)
	r.arms[1].rest = Vector3(-0.20, 0.0, 0.42)
	r.arms[0].elbow_rest = 0.75
	r.arms[1].elbow_rest = 0.75
	r.arms[0].swing = 0.28
	r.arms[1].swing = 0.28
	r.arms[0].attack = true
	r.arms[0].atk_pose = Vector4(-1.85, 0.0, -0.55, 0.15)
	r.arms[0].atk_wind = 0.7
	r.arms[1].attack = true
	r.arms[1].atk_pose = Vector4(-1.85, 0.0, 0.55, 0.15)
	r.arms[1].atk_wind = 0.7
	SpeciesDefs.set_gait(r, 0.70, 0.98, 0.88, 0.075, 0.030, 0.075)
	SpeciesDefs.set_info(r, 210.0, 30.0, 3.2, 0.9, 0.55)
	return r
