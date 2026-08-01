class_name SpeciesScav
extends RefCounted
## The four scavenger species: people, still, in the sense that matters least.
##
## They share a silhouette — cloth over meat, hide where it has to take a knock —
## and differ by what they picked up. Every measurement is transcribed from the
## reference and reproduces the acceptance table in `docs/spec/bestiary.md` §16.
## Nothing here is taste; retuning belongs in the baked `EnemyStats`.

const M_RAT: Dictionary = {
	"torso": &"canvas",
	"abs": &"canvas",
	"leg": &"canvas",
	"boot": &"hide",
	"arm": &"canvas",
	"hand": &"hide",
	"skin": &"flesh",
	"shoulder": &"hide"
}
const M_PICKER: Dictionary = {
	"torso": &"canvas",
	"abs": &"hide",
	"leg": &"canvas",
	"boot": &"hide",
	"arm": &"hide",
	"hand": &"hide",
	"skin": &"flesh",
	"shoulder": &"steel"
}
const M_GASMAN: Dictionary = {
	"torso": &"rubber",
	"abs": &"rubber",
	"leg": &"canvas",
	"boot": &"rubber",
	"arm": &"rubber",
	"hand": &"hide",
	"skin": &"flesh",
	"shoulder": &"rubber"
}
const M_MARKSMAN: Dictionary = {
	"torso": &"canvas",
	"abs": &"canvas",
	"leg": &"canvas",
	"boot": &"hide",
	"arm": &"canvas",
	"hand": &"hide",
	"skin": &"flesh",
	"shoulder": &"canvas"
}


static func rat() -> EnemyRig:
	var r: EnemyRig = SpeciesDefs.new_rig(
		&"rat",
		"Scav Rat",
		&"scav",
		"rusher",
		(
			"Bottom of the food chain. Comes in threes, dies in threes, and still "
			+ "gets a hatchet into your back if you turn it."
		),
		780.0
	)
	RigBuilders.humanoid(
		r,
		{
			"hipY": 0.855,
			"footH": 0.075,
			"footL": 0.245,
			"legR": 0.062,
			"hipW": 0.088,
			"pelvH": 0.19,
			"pelvD": 0.175,
			"waistW": 0.255,
			"waistD": 0.175,
			"absH": 0.20,
			"chestW": 0.325,
			"chestH": 0.30,
			"chestD": 0.205,
			"neckR": 0.058,
			"neckH": 0.085,
			"shW": 0.152,
			"armU": 0.265,
			"armL": 0.245,
			"armR": 0.046,
			"handL": 0.10,
			"m": M_RAT
		}
	)
	r.tags["hunch"] = 0.145
	r.tags["lean_run"] = 0.16

	# Gas mask under a stitched hood.
	r.box(&"head", Vector3(0.0, 0.035, 0.022), Vector3(0.165, 0.185, 0.185), &"hide")
	r.box(&"head", Vector3(0.0, -0.012, 0.098), Vector3(0.115, 0.10, 0.055), &"rubber")
	r.cyl(
		&"head",
		Vector3(0.0, -0.052, 0.108),
		0.042,
		0.046,
		0.075,
		&"steel",
		{"rot": Vector3(PI / 2.2, 0.0, 0.0)}
	)
	r.sph(&"head", Vector3(-0.048, 0.032, 0.086), 0.033, &"poly")
	r.sph(&"head", Vector3(0.048, 0.032, 0.086), 0.033, &"poly")
	r.box(&"head", Vector3(0.0, 0.098, -0.005), Vector3(0.185, 0.075, 0.205), &"canvas")
	r.box(&"head", Vector3(0.0, 0.045, -0.088), Vector3(0.155, 0.145, 0.075), &"canvas")

	# Webbing, a bedroll and one scrap pauldron.
	r.box(&"chest", Vector3(0.0, 0.145, 0.098), Vector3(0.30, 0.055, 0.055), &"hide")
	r.box(&"chest", Vector3(0.02, 0.075, -0.098), Vector3(0.20, 0.20, 0.075), &"canvas")
	r.box(
		&"l_sh",
		Vector3(-0.022, 0.012, 0.0),
		Vector3(0.075, 0.115, 0.155),
		&"ironox",
		{"rot": Vector3(0.0, 0.0, 0.2)}
	)
	r.box(&"spine", Vector3(0.0, 0.02, 0.088), Vector3(0.245, 0.09, 0.045), &"hide")

	# Hatchet: haft down through the fist, bit ACROSS the haft. A slab lying flat
	# against the handle reads as a paddle from every angle that matters.
	r.cyl(&"r_wr", Vector3(0.0, -0.165, 0.015), 0.017, 0.020, 0.34, &"timber")
	r.box(&"r_wr", Vector3(0.0, -0.300, 0.015), Vector3(0.032, 0.078, 0.058), &"steel")
	r.box(&"r_wr", Vector3(0.0, -0.300, 0.074), Vector3(0.024, 0.108, 0.082), &"steel")
	r.box(&"r_wr", Vector3(0.0, -0.300, 0.126), Vector3(0.013, 0.132, 0.036), &"steel")
	r.box(&"r_wr", Vector3(0.0, -0.298, -0.024), Vector3(0.030, 0.062, 0.048), &"steel")

	r.arms[1].attack = true
	r.arms[1].atk_pose = Vector4(-1.55, 0.0, 0.10, 0.35)
	r.arms[1].atk_wind = 1.5
	r.arms[0].attack = true
	r.arms[0].atk_pose = Vector4(-0.55, 0.0, -0.35, 0.95)
	r.arms[0].atk_wind = 0.4
	SpeciesDefs.set_gait(r, 0.58, 1.55, 1.10, 0.115, 0.020, 0.030)
	SpeciesDefs.set_info(r, 26.0, 38.0, 1.35, 1.0, 0.85)
	return r


static func picker() -> EnemyRig:
	var r: EnemyRig = SpeciesDefs.new_rig(
		&"picker",
		"Picker",
		&"scav",
		"brawler",
		(
			"Wears a road sign as a shield and swings a crowbar like it owes him "
			+ "money. Slow, patient, hard to flank."
		),
		950.0
	)
	RigBuilders.humanoid(
		r,
		{
			"hipY": 0.925,
			"footH": 0.082,
			"footL": 0.275,
			"legR": 0.075,
			"hipW": 0.098,
			"pelvH": 0.215,
			"pelvD": 0.205,
			"waistW": 0.30,
			"waistD": 0.205,
			"absH": 0.215,
			"chestW": 0.395,
			"chestH": 0.335,
			"chestD": 0.245,
			"neckR": 0.068,
			"neckH": 0.085,
			"shW": 0.182,
			"armU": 0.30,
			"armL": 0.275,
			"armR": 0.056,
			"handL": 0.115,
			"armOut": 0.14,
			"m": M_PICKER
		}
	)
	r.tags["hunch"] = 0.075
	r.tags["lean_run"] = 0.12

	r.box(&"head", Vector3(0.0, 0.02, 0.012), Vector3(0.185, 0.205, 0.205), &"flesh")
	r.box(&"head", Vector3(0.0, 0.008, 0.098), Vector3(0.135, 0.115, 0.055), &"rubber")
	r.sph(&"head", Vector3(-0.052, 0.048, 0.092), 0.036, &"poly")
	r.sph(&"head", Vector3(0.052, 0.048, 0.092), 0.036, &"poly")
	r.cyl(&"head", Vector3(0.0, 0.128, -0.01), 0.115, 0.108, 0.055, &"steel")
	r.box(
		&"head",
		Vector3(0.0, 0.098, 0.062),
		Vector3(0.225, 0.038, 0.115),
		&"steel",
		{"rot": Vector3(0.24, 0.0, 0.0)}
	)
	r.box(&"chest", Vector3(0.0, 0.155, 0.128), Vector3(0.30, 0.225, 0.045), &"ironox")
	r.box(&"chest", Vector3(0.0, 0.145, -0.128), Vector3(0.275, 0.205, 0.042), &"ironox")
	r.box(&"chest", Vector3(0.0, 0.028, 0.135), Vector3(0.245, 0.09, 0.038), &"steel")
	r.box(
		&"l_sh",
		Vector3(-0.038, 0.02, 0.0),
		Vector3(0.085, 0.155, 0.195),
		&"ironox",
		{"rot": Vector3(0.0, 0.0, 0.26)}
	)
	r.box(
		&"r_sh",
		Vector3(0.038, 0.02, 0.0),
		Vector3(0.085, 0.155, 0.195),
		&"ironox",
		{"rot": Vector3(0.0, 0.0, -0.26)}
	)
	r.box(&"spine", Vector3(0.0, 0.02, 0.0), Vector3(0.315, 0.115, 0.225), &"hide")

	# Road-sign shield, strapped to the forearm rather than held.
	r.box(
		&"l_el",
		Vector3(-0.048, -0.155, 0.055),
		Vector3(0.038, 0.46, 0.40),
		&"ironox",
		{"rot": Vector3(0.0, 0.0, 0.14)}
	)
	r.box(
		&"l_el",
		Vector3(-0.062, -0.155, 0.055),
		Vector3(0.016, 0.30, 0.26),
		&"alum",
		{"rot": Vector3(0.0, 0.0, 0.14), "col": "#6d6a5e"}
	)
	r.box(&"l_el", Vector3(-0.020, -0.155, 0.055), Vector3(0.035, 0.155, 0.135), &"steel")

	# Crowbar: shaft, then a gooseneck claw curling forward so the hook reads
	# across the shaft instead of vanishing into its silhouette.
	r.cyl(&"r_wr", Vector3(0.0, -0.205, 0.02), 0.016, 0.016, 0.42, &"gunmet")
	r.cyl(
		&"r_wr",
		Vector3(0.0, -0.408, 0.043),
		0.015,
		0.014,
		0.075,
		&"gunmet",
		{"rot": Vector3(-0.85, 0.0, 0.0)}
	)
	r.box(
		&"r_wr",
		Vector3(0.0, -0.424, 0.092),
		Vector3(0.030, 0.026, 0.080),
		&"gunmet",
		{"rot": Vector3(-0.35, 0.0, 0.0)}
	)
	r.box(
		&"r_wr",
		Vector3(0.0, -0.418, 0.136),
		Vector3(0.030, 0.014, 0.036),
		&"gunmet",
		{"rot": Vector3(0.30, 0.0, 0.0)}
	)

	r.arms[1].attack = true
	r.arms[1].atk_pose = Vector4(-1.35, 0.0, 0.15, 0.30)
	r.arms[1].atk_wind = 1.35
	r.arms[0].attack = true
	r.arms[0].atk_pose = Vector4(-1.05, 0.0, -0.55, 1.15)
	r.arms[0].atk_wind = 0.25
	r.arms[0].rest = Vector3(-0.62, 0.0, -0.30)
	r.arms[0].elbow_rest = 1.15
	r.arms[0].swing = 0.16
	SpeciesDefs.set_gait(r, 0.63, 1.30, 0.92, 0.105, 0.024, 0.036)
	SpeciesDefs.set_info(r, 42.0, 34.0, 1.75, 1.0, 1.0)
	return r


static func gasman() -> EnemyRig:
	var r: EnemyRig = SpeciesDefs.new_rig(
		&"gasman",
		"Gasman",
		&"scav",
		"area denial",
		(
			"Two stolen welding bottles and a lit torch. Kill him at range or you "
			+ "inherit the fire he was standing in."
		),
		880.0
	)
	RigBuilders.humanoid(
		r,
		{
			"hipY": 0.885,
			"footH": 0.088,
			"footL": 0.285,
			"legR": 0.082,
			"hipW": 0.10,
			"pelvH": 0.225,
			"pelvD": 0.235,
			"waistW": 0.335,
			"waistD": 0.245,
			"absH": 0.225,
			"chestW": 0.415,
			"chestH": 0.335,
			"chestD": 0.285,
			"neckR": 0.072,
			"neckH": 0.075,
			"shW": 0.192,
			"armU": 0.29,
			"armL": 0.265,
			"armR": 0.062,
			"handL": 0.115,
			"armOut": 0.17,
			"m": M_GASMAN
		}
	)
	r.tags["hunch"] = 0.10
	r.tags["lean_run"] = 0.10

	# Full-face respirator.
	r.box(&"head", Vector3(0.0, 0.015, 0.018), Vector3(0.195, 0.20, 0.205), &"rubber")
	r.box(&"head", Vector3(0.0, 0.045, 0.098), Vector3(0.155, 0.085, 0.048), &"poly")
	r.cyl(
		&"head",
		Vector3(-0.078, -0.048, 0.062),
		0.052,
		0.052,
		0.085,
		&"steel",
		{"rot": Vector3(0.0, 0.0, PI * 0.5)}
	)
	r.cyl(
		&"head",
		Vector3(0.078, -0.048, 0.062),
		0.052,
		0.052,
		0.085,
		&"steel",
		{"rot": Vector3(0.0, 0.0, PI * 0.5)}
	)
	r.sph(&"head", Vector3(0.0, 0.115, -0.02), 0.105, &"rubber")

	# Bottles, manifold, and two RIGID hoses to the neck pivot. Rigid because a
	# hose routed to a moving bone is the one place this shell could ever part.
	r.cyl(&"chest", Vector3(-0.10, 0.115, -0.235), 0.072, 0.072, 0.46, &"ironox")
	r.cyl(&"chest", Vector3(0.10, 0.115, -0.235), 0.072, 0.072, 0.46, &"brass")
	r.box(&"chest", Vector3(0.0, 0.115, -0.20), Vector3(0.34, 0.30, 0.075), &"steel")
	r.cyl(&"chest", Vector3(-0.10, 0.365, -0.235), 0.032, 0.028, 0.075, &"brass")
	r.cyl(&"chest", Vector3(0.10, 0.365, -0.235), 0.032, 0.028, 0.075, &"brass")
	# The two hoses land either side of the neck pivot, not on it. `tube` drops a
	# ball on every point it is given, so a shared terminal point would emit the
	# same 64-triangle dome twice at the same place — coincident, same winding,
	# z-fighting on every Gasman alive. 14 mm apart is still well inside the
	# 72 mm neck, so both balls stay buried and the shell stays sealed.
	var hose_l: Array[Vector3] = [
		Vector3(-0.10, 0.395, -0.235),
		Vector3(-0.145, 0.415, -0.165),
		Vector3(-0.115, 0.365, -0.055),
		Vector3(-0.045, 0.315, 0.005),
		Vector3(-0.014, 0.282, 0.0)
	]
	r.tube(&"chest", hose_l, 0.019, &"rubber")
	var hose_r: Array[Vector3] = [
		Vector3(0.10, 0.395, -0.235),
		Vector3(0.145, 0.405, -0.155),
		Vector3(0.118, 0.352, -0.05),
		Vector3(0.05, 0.305, 0.005),
		Vector3(0.014, 0.282, 0.0)
	]
	r.tube(&"chest", hose_r, 0.019, &"rubber")
	r.box(&"chest", Vector3(0.0, 0.09, 0.155), Vector3(0.31, 0.28, 0.055), &"hide")
	r.box(&"spine", Vector3(0.0, 0.045, 0.13), Vector3(0.345, 0.22, 0.05), &"hide")

	# Torch wand. The flame tip sits 0.325 m off the wrist pivot and fires down
	# its own -Y, which is the whole reason the muzzle solve is general.
	r.cyl(&"r_wr", Vector3(0.0, -0.135, 0.05), 0.026, 0.024, 0.26, &"gunmet")
	r.cyl(&"r_wr", Vector3(0.0, -0.255, 0.05), 0.028, 0.034, 0.09, &"brass")
	r.sph(&"r_wr", Vector3(0.0, -0.325, 0.05), 0.055, &"flash", {"fxs": 3.0})

	var aim := RigAim.new()
	aim.mode = RigAim.MODE_HAND
	aim.arm = 1
	aim.hold = 0.86
	aim.drop = 0.02
	aim.muzzle = Vector3(0.0, -0.325, 0.05)
	aim.fwd = Vector3(0.0, -1.0, 0.0)
	aim.up = Vector3(0.0, 0.0, 1.0)
	aim.roll = 0.0
	aim.pole = Vector3(0.75, -1.0, -0.30)
	r.aim = aim

	r.arms[0].carry = true
	r.arms[0].carry_pose = Vector4(-0.90, 0.0, -0.52, 1.35)
	SpeciesDefs.set_gait(r, 0.66, 1.18, 0.86, 0.10, 0.026, 0.040)
	SpeciesDefs.set_info(r, 58.0, 30.0, 4.5, 1.05, 0.9)
	return r


static func marksman() -> EnemyRig:
	var r: EnemyRig = SpeciesDefs.new_rig(
		&"marksman",
		"Marksman",
		&"scav",
		"ranged",
		(
			"Sits in a window for six hours for one shot. The rag strips are not "
			+ "camouflage, they are boredom."
		),
		800.0
	)
	var chest_h: float = 0.335
	RigBuilders.humanoid(
		r,
		{
			"hipY": 1.005,
			"footH": 0.078,
			"footL": 0.275,
			"legR": 0.062,
			"hipW": 0.092,
			"pelvH": 0.195,
			"pelvD": 0.18,
			"waistW": 0.265,
			"waistD": 0.185,
			"absH": 0.235,
			"chestW": 0.345,
			"chestH": chest_h,
			"chestD": 0.215,
			"neckR": 0.058,
			"neckH": 0.105,
			"shW": 0.158,
			"armU": 0.315,
			"armL": 0.29,
			"armR": 0.046,
			"handL": 0.105,
			"m": M_MARKSMAN
		}
	)
	r.tags["hunch"] = 0.055
	r.tags["lean_run"] = 0.14

	r.box(&"head", Vector3(0.0, 0.02, 0.012), Vector3(0.16, 0.19, 0.195), &"flesh")
	r.box(&"head", Vector3(0.0, 0.048, 0.085), Vector3(0.135, 0.062, 0.075), &"gunmet")
	r.sph(&"head", Vector3(-0.048, 0.048, 0.105), 0.028, &"poly")
	r.sph(&"head", Vector3(0.048, 0.048, 0.105), 0.028, &"poly")
	r.box(&"head", Vector3(0.0, 0.058, -0.03), Vector3(0.20, 0.155, 0.215), &"canvas")
	r.box(&"head", Vector3(0.0, -0.035, 0.075), Vector3(0.135, 0.085, 0.075), &"canvas")
	for i in 5:
		r.box(
			&"chest",
			Vector3(-0.13 + float(i) * 0.065, 0.075, -0.115),
			Vector3(0.045, 0.30, 0.03),
			&"canvas",
			{"rot": Vector3(0.1, 0.0, (float(i) - 2.0) * 0.08)}
		)
	r.box(
		&"l_sh",
		Vector3(-0.03, -0.03, -0.02),
		Vector3(0.06, 0.24, 0.075),
		&"canvas",
		{"rot": Vector3(0.0, 0.0, 0.12)}
	)
	r.box(
		&"r_sh",
		Vector3(0.03, -0.03, -0.02),
		Vector3(0.06, 0.24, 0.075),
		&"canvas",
		{"rot": Vector3(0.0, 0.0, -0.12)}
	)
	r.box(&"spine", Vector3(0.0, 0.05, -0.115), Vector3(0.235, 0.24, 0.075), &"canvas")

	# The rifle rides its own bone, butted into the shoulder pocket, so the aim
	# solver swings the frame about that anchor and both hands land on the grips.
	var anchor := Vector3(0.132, chest_h * 0.54, 0.030)
	r.bone(&"gun", &"chest", anchor)
	r.box(&"gun", Vector3(0.0, 0.0, 0.055), Vector3(0.056, 0.125, 0.14), &"timber")
	r.box(&"gun", Vector3(0.0, 0.005, 0.20), Vector3(0.050, 0.100, 0.24), &"timber")
	r.box(&"gun", Vector3(0.0, 0.022, 0.395), Vector3(0.046, 0.078, 0.20), &"gunmet")
	r.box(
		&"gun",
		Vector3(0.0, -0.085, 0.295),
		Vector3(0.038, 0.125, 0.060),
		&"timber",
		{"rot": Vector3(0.26, 0.0, 0.0)}
	)
	r.box(
		&"gun",
		Vector3(0.0, -0.075, 0.395),
		Vector3(0.032, 0.115, 0.070),
		&"gunmet",
		{"rot": Vector3(-0.16, 0.0, 0.0)}
	)
	r.box(&"gun", Vector3(0.0, 0.014, 0.545), Vector3(0.052, 0.062, 0.235), &"timber")
	r.cyl(
		&"gun",
		Vector3(0.0, 0.030, 0.700),
		0.013,
		0.012,
		0.44,
		&"gunmet",
		{"rot": Vector3(PI * 0.5, 0.0, 0.0)}
	)
	r.cyl(
		&"gun",
		Vector3(0.0, 0.030, 0.915),
		0.019,
		0.018,
		0.055,
		&"gunmet",
		{"rot": Vector3(PI * 0.5, 0.0, 0.0)}
	)
	r.box(&"gun", Vector3(0.0, 0.072, 0.415), Vector3(0.030, 0.048, 0.075), &"gunmet")
	r.cyl(
		&"gun",
		Vector3(0.0, 0.108, 0.425),
		0.024,
		0.022,
		0.205,
		&"gunmet",
		{"rot": Vector3(PI * 0.5, 0.0, 0.0)}
	)
	r.cyl(
		&"gun",
		Vector3(0.0, 0.020, 0.560),
		0.009,
		0.009,
		0.16,
		&"steel",
		{"rot": Vector3(0.45, 0.0, 0.0)}
	)
	r.sph(&"gun", Vector3(0.0, 0.030, 0.985), 0.05, &"flash", {"fxs": 2.6})
	# Sling: chest to fore-end. It welds the frame to the body, so no pose can
	# open a gap between the rifle and the man carrying it.
	var sling: Array[Vector3] = [
		anchor,
		Vector3(0.06, 0.20, 0.075),
		Vector3(-0.03, 0.10, 0.10),
		Vector3(-0.075, -0.01, 0.075)
	]
	r.tube(&"chest", sling, 0.013, &"canvas")

	var aim := RigAim.new()
	aim.mode = RigAim.MODE_SHOULDER
	aim.bone = &"gun"
	aim.eye_z = 0.05
	aim.muzzle = Vector3(0.0, 0.030, 0.985)
	aim.fwd = Vector3(0.0, 0.0, 1.0)
	aim.up = Vector3(0.0, 1.0, 0.0)
	var grip_r := RigAimHand.new()
	grip_r.arm = 1
	grip_r.grip = Vector3(0.020, -0.038, 0.305)
	grip_r.hand = Vector3(-0.78, 0.10, 0.0)
	grip_r.pole = Vector3(0.55, -1.0, -0.55)
	var grip_l := RigAimHand.new()
	grip_l.arm = 0
	grip_l.grip = Vector3(-0.026, 0.052, 0.470)
	grip_l.hand = Vector3(-1.22, -0.16, -0.30)
	grip_l.pole = Vector3(-0.62, -1.0, -0.22)
	aim.hands = [grip_r, grip_l]
	r.aim = aim

	r.arms[1].carry = true
	r.arms[1].carry_pose = Vector4(-0.80, 0.0, 0.26, 1.50)
	r.arms[0].carry = true
	r.arms[0].carry_pose = Vector4(-1.00, 0.0, -0.40, 1.25)
	SpeciesDefs.set_gait(r, 0.61, 1.42, 0.98, 0.115, 0.020, 0.028)
	SpeciesDefs.set_info(r, 74.0, 82.0, 120.0, 0.92, 0.75)
	return r
