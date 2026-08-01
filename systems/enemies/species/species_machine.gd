class_name SpeciesMachine
extends RefCounted
## The four machines: plant and security hardware that outlived its owners.
##
## Two are quadrupeds off the shared trunk builder, one is a hand-built
## digitigrade biped and one is a legless quadrotor, which is why this file has
## more explicit bone work in it than the other two. Every measurement is
## transcribed from the reference and reproduces the acceptance table in
## `docs/spec/bestiary.md` §16.

const M_LATCHDOG: Dictionary = {
	"torso": &"gunmet", "leg": &"alum", "neck": &"gunmet", "pad": &"rubber"
}
const M_FOREMAN: Dictionary = {
	"torso": &"ironox", "leg": &"steel", "neck": &"ironox", "pad": &"rubber"
}


static func latchdog() -> EnemyRig:
	var r: EnemyRig = SpeciesDefs.new_rig(
		&"latchdog",
		"Latchdog",
		&"machine",
		"hunter",
		(
			"A warehouse inventory unit with the inventory parts stripped out. Runs "
			+ "down anything that moves and holds it until something worse arrives."
		),
		640.0
	)
	RigBuilders.quadruped(
		r,
		{
			"backY": 0.62,
			"bodyL": 0.86,
			"bodyW": 0.28,
			"bodyH": 0.235,
			"chestW": 0.30,
			"chestH": 0.255,
			"hipW": 0.115,
			"shW": 0.115,
			"legR": 0.045,
			"padR": 0.045,
			"neckY": 0.06,
			"neckL": 0.20,
			"neckR": 0.085,
			"pastern": {"f": 0.115, "h": 0.125},
			"ph": [0.0, 0.5, 0.5, 0.0],
			"m": M_LATCHDOG
		}
	)
	r.tags["neck_pitch"] = 0.18

	r.box(&"head", Vector3(0.0, 0.01, 0.075), Vector3(0.155, 0.125, 0.185), &"gunmet")
	r.box(&"head", Vector3(0.0, 0.045, 0.135), Vector3(0.115, 0.055, 0.075), &"poly")
	r.sph(&"head", Vector3(-0.045, 0.048, 0.155), 0.028, &"glow")
	r.sph(&"head", Vector3(0.045, 0.048, 0.155), 0.028, &"glow")
	r.cyl(
		&"head",
		Vector3(0.0, 0.085, 0.02),
		0.022,
		0.018,
		0.115,
		&"steel",
		{"rot": Vector3(-0.5, 0.0, 0.0)}
	)
	r.box(
		&"head",
		Vector3(0.0, -0.055, 0.135),
		Vector3(0.10, 0.055, 0.135),
		&"steel",
		{"rot": Vector3(0.18, 0.0, 0.0)}
	)
	r.box(&"chest", Vector3(0.0, 0.125, 0.02), Vector3(0.245, 0.055, 0.335), &"alum")
	r.box(&"spine", Vector3(0.0, 0.125, 0.0), Vector3(0.215, 0.05, 0.30), &"alum")
	r.box(&"pelvis", Vector3(0.0, 0.115, -0.02), Vector3(0.235, 0.055, 0.315), &"alum")
	r.cyl(
		&"chest",
		Vector3(-0.155, 0.02, 0.02),
		0.045,
		0.045,
		0.155,
		&"ironox",
		{"rot": Vector3(0.0, 0.0, PI * 0.5)}
	)
	r.cyl(
		&"chest",
		Vector3(0.155, 0.02, 0.02),
		0.045,
		0.045,
		0.155,
		&"ironox",
		{"rot": Vector3(0.0, 0.0, PI * 0.5)}
	)
	r.bone(&"tail", &"pelvis", Vector3(0.0, 0.06, -0.185))
	r.sph(&"tail", Vector3.ZERO, 0.042, &"gunmet")
	r.cyl(
		&"tail",
		Vector3(0.0, 0.055, -0.115),
		0.022,
		0.010,
		0.30,
		&"gunmet",
		{"rot": Vector3(-1.25, 0.0, 0.0)}
	)
	r.tags["wags"] = [{"b": &"tail", "f": 1.35, "a": 0.35, "ax": "y", "base": 0.0}]
	SpeciesDefs.set_gait(r, 0.52, 1.30, 1.30, 0.085, 0.014, 0.014)
	SpeciesDefs.set_info(r, 48.0, 74.0, 1.1, 1.0, 1.05)
	return r


static func sentinel() -> EnemyRig:
	var r: EnemyRig = SpeciesDefs.new_rig(
		&"sentinel",
		"Sentinel",
		&"machine",
		"suppression",
		(
			"Still running the perimeter routine for a company that no longer "
			+ "exists. Will not chase you past the fence line."
		),
		1050.0
	)
	r.bone(&"pelvis", &"", Vector3(0.0, 1.16, 0.0))
	r.box(&"pelvis", Vector3(0.0, 0.075, 0.0), Vector3(0.335, 0.235, 0.245), &"gunmet")
	r.bone(&"spine", &"pelvis", Vector3(0.0, 0.155, 0.0))
	r.sph(&"spine", Vector3.ZERO, 0.125, &"gunmet")
	r.box(&"spine", Vector3(0.0, 0.115, 0.0), Vector3(0.245, 0.235, 0.205), &"alum")
	r.bone(&"chest", &"spine", Vector3(0.0, 0.215, 0.0))
	r.sph(&"chest", Vector3.ZERO, 0.135, &"gunmet")
	r.box(&"chest", Vector3(0.0, 0.155, 0.005), Vector3(0.475, 0.34, 0.285), &"gunmet")
	r.box(&"chest", Vector3(0.0, 0.145, 0.155), Vector3(0.335, 0.245, 0.055), &"alum")
	r.box(&"chest", Vector3(0.0, 0.30, -0.145), Vector3(0.30, 0.155, 0.115), &"ironox")
	r.tags["spine"] = [&"spine", &"chest"]

	r.bone(&"neck", &"chest", Vector3(0.0, 0.315, 0.02))
	r.sph(&"neck", Vector3.ZERO, 0.075, &"gunmet")
	r.cyl(&"neck", Vector3(0.0, 0.045, 0.0), 0.055, 0.062, 0.145, &"steel")
	r.bone(&"head", &"neck", Vector3(0.0, 0.105, 0.0))
	r.sph(&"head", Vector3.ZERO, 0.072, &"gunmet")
	r.box(&"head", Vector3(0.0, 0.045, 0.03), Vector3(0.245, 0.115, 0.185), &"gunmet")
	r.cyl(
		&"head",
		Vector3(0.0, 0.045, 0.115),
		0.045,
		0.045,
		0.075,
		&"poly",
		{"rot": Vector3(PI * 0.5, 0.0, 0.0)}
	)
	r.sph(&"head", Vector3(0.0, 0.045, 0.145), 0.032, &"glow")
	r.box(&"head", Vector3(0.0, 0.115, -0.02), Vector3(0.185, 0.045, 0.145), &"alum")
	r.tags["head"] = &"head"
	r.tags["neck"] = &"neck"

	# Digitigrade legs. The standing pastern eats 0.238 m of the 1.13 m hip height
	# before the bone budget is split, which is why the thighs are shorter than
	# they look for a two-metre machine.
	var stand: float = 0.055 + 0.20 * cos(0.42)
	var total: float = (1.13 - stand) / 0.95
	var upper: float = total * 0.53
	var lower: float = total - upper
	for s in [-1.0, 1.0]:
		var p: String = "l" if s < 0.0 else "r"
		var hip := StringName(p + "_hip")
		var knee := StringName(p + "_knee")
		var ankle := StringName(p + "_ank")
		r.link(
			hip,
			&"pelvis",
			Vector3(s * 0.135, -0.03, 0.0),
			upper,
			0.072,
			0.062,
			&"alum",
			{"ball_r": 0.088, "ball_m": &"gunmet"}
		)
		r.link(
			knee,
			hip,
			Vector3(0.0, -upper, 0.0),
			lower,
			0.062,
			0.05,
			&"alum",
			{"ball_r": 0.075, "ball_m": &"gunmet"}
		)
		r.bone(ankle, knee, Vector3(0.0, -lower, 0.0))
		r.sph(ankle, Vector3.ZERO, 0.058, &"gunmet")
		r.cyl(ankle, Vector3(0.0, -0.105, 0.0), 0.045, 0.038, 0.24, &"alum")
		r.sph(ankle, Vector3(0.0, -0.20, 0.0), 0.072, &"rubber")
		# Hydraulic ram across the knee, anchored on the THIGH so it cannot part.
		r.cyl(
			hip,
			Vector3(s * 0.062, -upper * 0.55, -0.055),
			0.020,
			0.020,
			upper * 0.78,
			&"steel",
			{"rot": Vector3(-0.06, 0.0, 0.0)}
		)
		r.box(hip, Vector3(s * 0.062, -0.045, -0.055), Vector3(0.045, 0.09, 0.062), &"gunmet")
		var leg := RigLeg.new()
		leg.hip = hip
		leg.knee = knee
		leg.ankle = ankle
		leg.side = s
		leg.phase = 0.0 if s < 0.0 else 0.5
		# Knees break BACKWARD. No other biped in the roster does this.
		leg.pole = Vector3(s * 0.10, 0.0, -1.0)
		leg.has_pastern = true
		leg.pastern_len = 0.20
		leg.pastern_pad_r = 0.072
		leg.pastern_a0 = 0.42
		leg.pastern_a1 = 0.72
		leg.pastern_dir = 1.0
		r.legs.append(leg)

	r.link(
		&"l_sh",
		&"chest",
		Vector3(-0.255, 0.235, 0.0),
		0.28,
		0.062,
		0.052,
		&"alum",
		{"ball_r": 0.085, "ball_m": &"gunmet"}
	)
	r.link(
		&"l_el",
		&"l_sh",
		Vector3(0.0, -0.28, 0.0),
		0.26,
		0.052,
		0.042,
		&"alum",
		{"ball_r": 0.068, "ball_m": &"gunmet"}
	)
	r.bone(&"l_wr", &"l_el", Vector3(0.0, -0.26, 0.0))
	r.sph(&"l_wr", Vector3.ZERO, 0.052, &"gunmet")
	r.box(&"l_wr", Vector3(0.0, -0.075, 0.02), Vector3(0.075, 0.135, 0.09), &"gunmet")
	r.box(
		&"l_wr",
		Vector3(-0.03, -0.155, 0.045),
		Vector3(0.026, 0.115, 0.075),
		&"steel",
		{"rot": Vector3(0.0, 0.0, -0.2)}
	)
	r.box(
		&"l_wr",
		Vector3(0.03, -0.155, 0.045),
		Vector3(0.026, 0.115, 0.075),
		&"steel",
		{"rot": Vector3(0.0, 0.0, 0.2)}
	)
	r.link(
		&"r_sh",
		&"chest",
		Vector3(0.255, 0.235, 0.0),
		0.28,
		0.062,
		0.052,
		&"alum",
		{"ball_r": 0.085, "ball_m": &"gunmet"}
	)
	r.link(
		&"r_el",
		&"r_sh",
		Vector3(0.0, -0.28, 0.0),
		0.24,
		0.058,
		0.05,
		&"alum",
		{"ball_r": 0.068, "ball_m": &"gunmet"}
	)
	r.bone(&"r_wr", &"r_el", Vector3(0.0, -0.24, 0.0))
	r.sph(&"r_wr", Vector3.ZERO, 0.058, &"gunmet")
	r.box(&"r_wr", Vector3(0.0, -0.085, 0.075), Vector3(0.115, 0.155, 0.30), &"gunmet")
	r.cyl(
		&"r_wr",
		Vector3(0.0, -0.085, 0.285),
		0.038,
		0.034,
		0.22,
		&"steel",
		{"rot": Vector3(PI * 0.5, 0.0, 0.0)}
	)
	r.cyl(
		&"r_wr",
		Vector3(0.0, -0.02, 0.135),
		0.045,
		0.045,
		0.135,
		&"ironox",
		{"rot": Vector3(PI * 0.5, 0.0, 0.0)}
	)
	r.sph(&"r_wr", Vector3(0.0, -0.085, 0.40), 0.075, &"flash", {"fxs": 2.2})

	var left := RigArm.new()
	left.shoulder = &"l_sh"
	left.elbow = &"l_el"
	left.wrist = &"l_wr"
	left.side = -1.0
	left.phase = 0.0
	left.rest = Vector3(-0.05, 0.0, -0.16)
	left.elbow_rest = 0.30
	left.swing = 0.36
	left.wrist_rest = Vector3(0.10, 0.0, 0.0)
	left.carry = true
	left.carry_pose = Vector4(-0.70, 0.0, -0.42, 1.05)
	left.attack = true
	left.atk_pose = Vector4(-0.55, 0.0, -0.35, 0.85)
	left.atk_wind = 0.3
	var right := RigArm.new()
	right.shoulder = &"r_sh"
	right.elbow = &"r_el"
	right.wrist = &"r_wr"
	right.side = 1.0
	right.phase = 0.5
	right.rest = Vector3(-0.05, 0.0, 0.16)
	right.elbow_rest = 0.30
	right.swing = 0.30
	right.wrist_rest = Vector3(0.10, 0.0, 0.0)
	r.arms = [left, right]

	var aim := RigAim.new()
	aim.mode = RigAim.MODE_HAND
	aim.arm = 1
	aim.hold = 0.90
	aim.drop = 0.0
	aim.muzzle = Vector3(0.0, -0.085, 0.40)
	aim.fwd = Vector3(0.0, 0.0, 1.0)
	aim.up = Vector3(0.0, 1.0, 0.0)
	aim.roll = 0.0
	aim.pole = Vector3(0.65, -1.0, -0.45)
	r.aim = aim

	r.tags["hunch"] = 0.02
	r.tags["lean_run"] = 0.08
	SpeciesDefs.set_gait(r, 0.60, 1.22, 0.90, 0.145, 0.020, 0.020)
	SpeciesDefs.set_info(r, 66.0, 88.0, 45.0, 1.05, 1.15)
	return r


static func wasp() -> EnemyRig:
	var r: EnemyRig = SpeciesDefs.new_rig(
		&"wasp",
		"Wasp",
		&"machine",
		"recon",
		(
			"Cheap, loud, and always calling someone. Shooting it down is the "
			+ "fastest way to tell the map where you are."
		),
		300.0
	)
	r.bone(&"pelvis", &"", Vector3.ZERO)
	r.sph(&"pelvis", Vector3.ZERO, 0.155, &"gunmet")
	r.box(&"pelvis", Vector3(0.0, 0.02, 0.0), Vector3(0.28, 0.155, 0.34), &"gunmet")
	r.box(&"pelvis", Vector3(0.0, 0.085, -0.02), Vector3(0.20, 0.075, 0.245), &"alum")
	# No spine chain and no legs: the hover branch owns this rig outright.
	r.tags["spine"] = []

	var arms: Array = [
		Vector2(-1.0, 1.0), Vector2(1.0, 1.0), Vector2(-1.0, -1.0), Vector2(1.0, -1.0)
	]
	var spins: Array = []
	for i in arms.size():
		var sx: float = Vector2(arms[i]).x
		var sz: float = Vector2(arms[i]).y
		var nm := StringName("arm%d" % i)
		var rotor := StringName("arm%dr" % i)
		var hx: float = sx * 0.215
		var hz: float = sz * 0.245
		r.bone(nm, &"pelvis", Vector3(sx * 0.115, 0.055, sz * 0.135))
		r.sph(nm, Vector3.ZERO, 0.05, &"gunmet")
		r.cyl(
			nm,
			Vector3(sx * 0.10, 0.005, sz * 0.115),
			0.030,
			0.026,
			0.30,
			&"alum",
			{"rot": Vector3(sz * 0.9, 0.0, -sx * 0.9)}
		)
		r.cyl(nm, Vector3(hx, 0.02, hz), 0.045, 0.042, 0.075, &"gunmet")
		r.cyl(nm, Vector3(hx, 0.055, hz), 0.175, 0.175, 0.028, &"poly")
		r.bone(rotor, nm, Vector3(hx, 0.062, hz))
		r.cyl(rotor, Vector3.ZERO, 0.030, 0.026, 0.045, &"steel")
		r.box(rotor, Vector3(0.0, 0.004, 0.0), Vector3(0.315, 0.012, 0.048), &"poly")
		r.box(rotor, Vector3(0.0, 0.004, 0.0), Vector3(0.048, 0.012, 0.315), &"poly")
		spins.append({"b": rotor, "rate": 46.0 + float(i) * 3.0})
	r.tags["spin"] = spins

	# Sensor ball and gun pod slung under the hull.
	r.bone(&"head", &"pelvis", Vector3(0.0, -0.115, 0.075))
	r.sph(&"head", Vector3.ZERO, 0.088, &"gunmet")
	r.sph(&"head", Vector3(0.0, -0.03, 0.045), 0.062, &"poly")
	r.sph(&"head", Vector3(0.0, -0.03, 0.085), 0.032, &"glowc")
	r.box(&"head", Vector3(0.0, -0.055, -0.10), Vector3(0.075, 0.075, 0.235), &"gunmet")
	r.cyl(
		&"head",
		Vector3(0.0, -0.055, 0.09),
		0.020,
		0.018,
		0.24,
		&"steel",
		{"rot": Vector3(PI * 0.5, 0.0, 0.0)}
	)
	r.sph(&"head", Vector3(0.0, -0.055, 0.215), 0.055, &"flash", {"fxs": 1.8})
	r.tags["head"] = &"head"
	r.tags["neck"] = &""
	r.tags["wags"] = [{"b": &"head", "f": 0.42, "a": 0.55, "ax": "y"}]

	var aim := RigAim.new()
	aim.mode = RigAim.MODE_TURRET
	aim.yaw_bone = &"head"
	aim.yaw_limits = Vector2(-3.15, 3.15)
	aim.pitch_limits = Vector2(-1.30, 1.30)
	aim.eye_z = 0.075
	aim.muzzle = Vector3(0.0, -0.055, 0.215)
	aim.fwd = Vector3(0.0, 0.0, 1.0)
	r.aim = aim

	r.gait = {"type": "hover", "hover_h": 0.92, "hover_speed": 4.6}
	SpeciesDefs.set_info(r, 22.0, 96.0, 30.0, 0.6, 0.7)
	return r


static func foreman() -> EnemyRig:
	var r: EnemyRig = SpeciesDefs.new_rig(
		&"foreman",
		"Foreman",
		&"machine",
		"siege",
		(
			"Site plant that kept working after the site stopped existing. Three "
			+ "tonnes of hydraulics with a grudge and a very slow turn radius. Not a "
			+ "fight you win with rifle rounds."
		),
		1400.0
	)
	RigBuilders.quadruped(
		r,
		{
			"backY": 1.72,
			"bodyL": 1.90,
			"bodyW": 0.86,
			"bodyH": 0.68,
			"chestW": 0.98,
			"chestH": 0.78,
			"hipW": 0.38,
			"shW": 0.42,
			"legR": 0.145,
			"padR": 0.135,
			"neckY": 0.235,
			"neckL": 0.34,
			"neckR": 0.215,
			"pastern": {"f": 0.30, "h": 0.32},
			"ph": [0.0, 0.5, 0.25, 0.75],
			"m": M_FOREMAN
		}
	)
	r.tags["neck_pitch"] = 0.32

	r.box(&"head", Vector3(0.0, 0.0, 0.135), Vector3(0.46, 0.30, 0.42), &"ironox")
	r.box(&"head", Vector3(0.0, 0.045, 0.30), Vector3(0.34, 0.155, 0.10), &"poly")
	r.sph(&"head", Vector3(-0.115, 0.05, 0.335), 0.052, &"glow")
	r.sph(&"head", Vector3(0.115, 0.05, 0.335), 0.052, &"glow")
	r.box(
		&"head",
		Vector3(0.0, -0.135, 0.245),
		Vector3(0.30, 0.115, 0.245),
		&"steel",
		{"rot": Vector3(0.2, 0.0, 0.0)}
	)
	r.cyl(
		&"head",
		Vector3(0.0, 0.20, 0.02),
		0.062,
		0.045,
		0.24,
		&"steel",
		{"rot": Vector3(-0.35, 0.0, 0.0)}
	)
	r.box(&"chest", Vector3(0.0, 0.40, 0.10), Vector3(0.92, 0.135, 0.86), &"steel")
	r.box(&"spine", Vector3(0.0, 0.38, 0.0), Vector3(0.80, 0.115, 0.62), &"steel")
	r.box(&"pelvis", Vector3(0.0, 0.36, -0.05), Vector3(0.86, 0.135, 0.72), &"steel")
	r.cyl(&"spine", Vector3(-0.30, 0.55, -0.12), 0.082, 0.068, 0.42, &"ironox")
	r.cyl(&"spine", Vector3(0.30, 0.55, -0.12), 0.082, 0.068, 0.42, &"ironox")
	r.cyl(&"spine", Vector3(-0.30, 0.75, -0.12), 0.095, 0.080, 0.10, &"gunmet")
	r.cyl(&"spine", Vector3(0.30, 0.75, -0.12), 0.095, 0.080, 0.10, &"gunmet")
	r.box(&"spine", Vector3(0.0, 0.60, -0.10), Vector3(0.52, 0.34, 0.30), &"gunmet")
	for i in 4:
		var z: float = -0.26 + float(i) * 0.175
		r.cyl(&"chest", Vector3(-0.46, 0.20, z), 0.026, 0.026, 0.42, &"gunmet")
		r.cyl(&"chest", Vector3(0.46, 0.20, z), 0.026, 0.026, 0.42, &"gunmet")
	r.box(&"pelvis", Vector3(0.0, 0.10, -0.42), Vector3(0.72, 0.50, 0.26), &"gunmet")
	r.box(&"pelvis", Vector3(0.0, 0.32, -0.34), Vector3(0.78, 0.16, 0.34), &"steel")

	# Breaker arm on the front deck. Its elbow is the only joint in the roster
	# whose tightest overlap moves with the animation.
	r.bone(&"boom", &"chest", Vector3(0.32, 0.42, 0.24))
	r.sph(&"boom", Vector3.ZERO, 0.135, &"gunmet")
	r.cyl(
		&"boom",
		Vector3(0.0, 0.08, 0.30),
		0.088,
		0.075,
		0.72,
		&"ironox",
		{"rot": Vector3(1.30, 0.0, 0.0)}
	)
	r.bone(&"boom2", &"boom", Vector3(0.0, 0.26, 0.66))
	r.sph(&"boom2", Vector3.ZERO, 0.098, &"gunmet")
	r.cyl(
		&"boom2",
		Vector3(0.0, -0.10, 0.28),
		0.062,
		0.055,
		0.62,
		&"ironox",
		{"rot": Vector3(1.70, 0.0, 0.0)}
	)
	r.cyl(
		&"boom2",
		Vector3(0.0, -0.20, 0.58),
		0.075,
		0.055,
		0.34,
		&"steel",
		{"rot": Vector3(1.70, 0.0, 0.0)}
	)
	r.tags["wags"] = [
		{"b": &"boom", "f": 0.30, "a": 0.16, "ax": "x", "base": -0.10},
		{"b": &"boom2", "f": 0.30, "a": 0.22, "ax": "x", "base": 0.24}
	]
	SpeciesDefs.set_gait(r, 0.70, 1.05, 0.80, 0.18, 0.026, 0.016)
	SpeciesDefs.set_info(r, 130.0, 66.0, 3.4, 1.15, 1.2)
	return r
