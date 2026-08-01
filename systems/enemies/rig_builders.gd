class_name RigBuilders
extends RefCounted
## The two body plans every species is cut from: an upright biped and a
## four-legged trunk. Both emit nothing but `link()`ed segments and pivot balls,
## so the no-gap guarantee comes for free.
##
## Proportions arrive as a plain dictionary because that is how the roster reads:
## a species is a table of measurements, not a subclass.

## Biped leg rest straightness. The pelvis dips to reach the floor; the legs do
## not rest bent, which is why this sits just short of 1.
const BIPED_BEND: float = 0.985
## Quadrupeds genuinely rest with a bend in every leg.
const QUAD_BEND: float = 0.93
## Thigh fraction of the total biped leg.
const BIPED_SPLIT: float = 0.52
## A long horizontal spine barely twists.
const QUAD_FLEX: float = 0.28


## Upright biped. Returns the derived leg lengths for callers that want them.
static func humanoid(r: EnemyRig, o: Dictionary) -> Dictionary:
	var m: Dictionary = o["m"]
	var torso: StringName = m["torso"]
	var skin: StringName = m["skin"]
	var hip_y: float = o["hipY"]
	var foot_h: float = o["footH"]
	var foot_l: float = o["footL"]
	var leg_r: float = o["legR"]
	var hip_w: float = o["hipW"]
	var pelv_h: float = o["pelvH"]
	var waist_w: float = o["waistW"]
	var waist_d: float = o["waistD"]
	var abs_h: float = o["absH"]
	var chest_h: float = o["chestH"]
	var neck_r: float = o["neckR"]
	var neck_h: float = o["neckH"]
	var bend: float = float(o.get("bend", BIPED_BEND))
	var split: float = float(o.get("split", BIPED_SPLIT))
	var total: float = (hip_y - foot_h) / bend
	var upper: float = total * split
	var lower: float = total - upper

	r.bone(&"pelvis", &"", Vector3(0.0, hip_y, 0.0))
	r.box(
		&"pelvis",
		Vector3(0.0, pelv_h * 0.30, 0.0),
		Vector3(hip_w * 2.0 + leg_r * 2.1, pelv_h, float(o["pelvD"])),
		torso
	)
	r.bone(&"spine", &"pelvis", Vector3(0.0, pelv_h * 0.66, 0.0))
	r.sph(&"spine", Vector3.ZERO, waist_d * 0.56, torso)
	var abs_m: StringName = m.get("abs", torso)
	r.box(
		&"spine",
		Vector3(0.0, abs_h * 0.40, float(o.get("absZ", 0.0))),
		Vector3(waist_w, abs_h, waist_d),
		abs_m
	)
	r.bone(&"chest", &"spine", Vector3(0.0, abs_h * 0.76, 0.0))
	r.sph(&"chest", Vector3.ZERO, waist_d * 0.54, torso)
	r.box(
		&"chest",
		Vector3(0.0, chest_h * 0.42, float(o.get("chestZ", 0.0))),
		Vector3(float(o["chestW"]), chest_h, float(o["chestD"])),
		torso
	)
	r.tags["spine"] = [&"spine", &"chest"]

	r.bone(&"neck", &"chest", Vector3(0.0, chest_h * 0.84, float(o.get("neckZ", 0.0))))
	r.sph(&"neck", Vector3.ZERO, neck_r * 1.30, skin)
	r.cyl(
		&"neck", Vector3(0.0, neck_h * 0.38, 0.0), neck_r * 0.94, neck_r * 1.06, neck_h * 1.35, skin
	)
	r.bone(&"head", &"neck", Vector3(0.0, neck_h * 0.84, 0.0))
	r.sph(&"head", Vector3.ZERO, neck_r * 1.16, skin)
	r.tags["head"] = &"head"
	r.tags["neck"] = &"neck"

	_humanoid_legs(r, o, upper, lower)
	_humanoid_arms(r, o, chest_h)
	return {"upper": upper, "lower": lower, "leg_r": leg_r}


## Four-legged trunk. Front knees break backward, hind knees forward — the classic
## elbow/stifle arrangement. Leg order is lf, rf, lh, rh.
static func quadruped(r: EnemyRig, o: Dictionary) -> void:
	var m: Dictionary = o["m"]
	var torso: StringName = m["torso"]
	var neck_m: StringName = m.get("neck", torso)
	var body_l: float = o["bodyL"]
	var body_h: float = o["bodyH"]
	var back_y: float = o["backY"]
	var hip_w: float = o["hipW"]
	var leg_r: float = o["legR"]
	var pad_r: float = o["padR"]
	var neck_l: float = o["neckL"]
	var neck_r: float = o["neckR"]
	var chest_rise: float = float(o.get("chestRise", 0.0))
	var bend: float = float(o.get("bend", QUAD_BEND))
	var pastern: Dictionary = o["pastern"]
	var phases: Array = o["ph"]

	r.bone(&"pelvis", &"", Vector3(0.0, back_y, -body_l * 0.34))
	r.box(
		&"pelvis",
		Vector3.ZERO,
		Vector3(hip_w * 2.0 + leg_r * 2.2, body_h * 0.94, body_l * 0.44),
		torso
	)
	r.bone(&"spine", &"pelvis", Vector3(0.0, body_h * 0.02, body_l * 0.30))
	r.sph(&"spine", Vector3.ZERO, body_h * 0.46, torso)
	r.box(
		&"spine",
		Vector3(0.0, 0.0, body_l * 0.10),
		Vector3(float(o["bodyW"]) * 0.92, body_h * 0.90, body_l * 0.36),
		torso
	)
	r.bone(&"chest", &"spine", Vector3(0.0, chest_rise, body_l * 0.30))
	r.sph(&"chest", Vector3.ZERO, body_h * 0.48, torso)
	r.box(
		&"chest",
		Vector3(0.0, 0.0, body_l * 0.10),
		Vector3(float(o["chestW"]), float(o["chestH"]), body_l * 0.40),
		torso
	)
	r.tags["spine"] = [&"spine", &"chest"]
	r.tags["flex"] = QUAD_FLEX

	r.bone(&"neck", &"chest", Vector3(0.0, float(o["neckY"]), body_l * 0.26))
	r.sph(&"neck", Vector3.ZERO, neck_r * 1.25, neck_m)
	r.cyl(
		&"neck",
		Vector3(0.0, -neck_l * 0.34, neck_l * 0.30),
		neck_r,
		neck_r * 0.94,
		neck_l * 1.25,
		neck_m,
		{"rot": Vector3(-1.15, 0.0, 0.0)}
	)
	r.bone(&"head", &"neck", Vector3(0.0, neck_l * 0.30, neck_l * 0.70))
	r.sph(&"head", Vector3.ZERO, neck_r * 1.05, neck_m)
	r.tags["head"] = &"head"
	r.tags["neck"] = &"neck"
	r.tags["neck_pitch"] = 0.0

	var y_pel: float = back_y
	var y_che: float = y_pel + body_h * 0.02 + chest_rise
	var st_f: float = pad_r + float(pastern["f"]) * cos(0.30)
	var st_h: float = pad_r + float(pastern["h"]) * cos(0.34)
	var tot_f: float = (y_che - body_h * 0.30 - st_f) / bend
	var tot_h: float = (y_pel - body_h * 0.30 - st_h) / bend
	var front: Vector2 = Vector2(tot_f * 0.52, tot_f - tot_f * 0.52)
	var hind: Vector2 = Vector2(tot_h * 0.54, tot_h - tot_h * 0.54)
	var sh_w: float = o["shW"]
	var fz: float = body_l * 0.16
	var hz: float = -body_l * 0.10
	var fp: Dictionary = {"len": pastern["f"], "pad_r": pad_r, "a0": 0.30, "a1": 0.62}
	var hp: Dictionary = {"len": pastern["h"], "pad_r": pad_r, "a0": 0.34, "a1": 0.66}
	var fwd_pole := Vector3(0.0, 0.0, -1.0)
	var back_pole := Vector3(0.0, 0.0, 1.0)
	_quad_leg(
		r,
		&"lf",
		&"chest",
		Vector3(-sh_w, -body_h * 0.30, fz),
		front,
		leg_r,
		{"phase": phases[0], "pole": fwd_pole, "pastern": fp, "m": m}
	)
	_quad_leg(
		r,
		&"rf",
		&"chest",
		Vector3(sh_w, -body_h * 0.30, fz),
		front,
		leg_r,
		{"phase": phases[1], "pole": fwd_pole, "pastern": fp, "m": m}
	)
	_quad_leg(
		r,
		&"lh",
		&"pelvis",
		Vector3(-hip_w, -body_h * 0.30, hz),
		hind,
		leg_r,
		{"phase": phases[2], "pole": back_pole, "pastern": hp, "m": m}
	)
	_quad_leg(
		r,
		&"rh",
		&"pelvis",
		Vector3(hip_w, -body_h * 0.30, hz),
		hind,
		leg_r,
		{"phase": phases[3], "pole": back_pole, "pastern": hp, "m": m}
	)


static func _humanoid_legs(r: EnemyRig, o: Dictionary, upper: float, lower: float) -> void:
	var m: Dictionary = o["m"]
	var leg_m: StringName = m["leg"]
	var boot_m: StringName = m["boot"]
	var leg_r: float = o["legR"]
	var hip_w: float = o["hipW"]
	var foot_h: float = o["footH"]
	var foot_l: float = o["footL"]
	for s in [-1.0, 1.0]:
		var p: String = "l" if s < 0.0 else "r"
		var hip := StringName(p + "_hip")
		var knee := StringName(p + "_knee")
		var ankle := StringName(p + "_ank")
		r.link(
			hip,
			&"pelvis",
			Vector3(s * hip_w, 0.0, 0.0),
			upper,
			leg_r,
			leg_r * 0.84,
			leg_m,
			{"ball_r": leg_r * 1.20}
		)
		r.link(
			knee,
			hip,
			Vector3(0.0, -upper, 0.0),
			lower,
			leg_r * 0.86,
			leg_r * 0.64,
			leg_m,
			{"ball_r": leg_r * 0.98}
		)
		r.bone(ankle, knee, Vector3(0.0, -lower, 0.0))
		r.sph(ankle, Vector3.ZERO, leg_r * 0.74, boot_m)
		r.box(
			ankle,
			Vector3(0.0, -foot_h * 0.5, foot_l * 0.22),
			Vector3(leg_r * 2.0, foot_h, foot_l),
			boot_m
		)
		var leg := RigLeg.new()
		leg.hip = hip
		leg.knee = knee
		leg.ankle = ankle
		leg.side = s
		leg.phase = 0.0 if s < 0.0 else 0.5
		leg.pole = Vector3(s * 0.12, 0.0, 1.0)
		leg.stance_k = float(o.get("stanceK", 0.86))
		leg.has_sole = true
		leg.sole_h = foot_h
		leg.sole_zb = foot_l * 0.22 - foot_l * 0.5
		leg.sole_zf = foot_l * 0.22 + foot_l * 0.5
		r.legs.append(leg)


static func _humanoid_arms(r: EnemyRig, o: Dictionary, chest_h: float) -> void:
	var m: Dictionary = o["m"]
	var arm_m: StringName = m["arm"]
	var hand_m: StringName = m["hand"]
	var shoulder_m: StringName = m.get("shoulder", arm_m)
	var arm_r: float = o["armR"]
	var arm_u: float = o["armU"]
	var arm_l: float = o["armL"]
	var hand_l: float = o["handL"]
	var sh_w: float = o["shW"]
	var arm_out: float = float(o.get("armOut", 0.11))
	for s in [-1.0, 1.0]:
		var p: String = "l" if s < 0.0 else "r"
		var sh := StringName(p + "_sh")
		var el := StringName(p + "_el")
		var wr := StringName(p + "_wr")
		r.link(
			sh,
			&"chest",
			Vector3(s * sh_w, chest_h * float(o.get("shY", 0.72)), 0.0),
			arm_u,
			arm_r,
			arm_r * 0.86,
			arm_m,
			{"ball_r": arm_r * 1.26, "ball_m": shoulder_m}
		)
		r.link(
			el,
			sh,
			Vector3(0.0, -arm_u, 0.0),
			arm_l,
			arm_r * 0.86,
			arm_r * 0.68,
			arm_m,
			{"ball_r": arm_r * 0.99}
		)
		r.bone(wr, el, Vector3(0.0, -arm_l, 0.0))
		r.sph(wr, Vector3.ZERO, arm_r * 0.80, hand_m)
		r.box(
			wr,
			Vector3(0.0, -hand_l * 0.40, arm_r * 0.12),
			Vector3(arm_r * 1.24, hand_l, arm_r * 1.98),
			hand_m
		)
		r.box(
			wr,
			Vector3(0.0, -hand_l * 0.72, arm_r * 0.42),
			Vector3(arm_r * 1.10, hand_l * 0.52, arm_r * 0.95),
			hand_m,
			{"rot": Vector3(0.55, 0.0, 0.0)}
		)
		r.cyl(
			wr,
			Vector3(-s * arm_r * 0.58, -hand_l * 0.30, arm_r * 0.34),
			arm_r * 0.30,
			arm_r * 0.24,
			hand_l * 0.66,
			hand_m,
			{"rot": Vector3(-0.55, 0.0, s * 0.60)}
		)
		var arm := RigArm.new()
		arm.shoulder = sh
		arm.elbow = el
		arm.wrist = wr
		arm.side = s
		arm.phase = 0.0 if s < 0.0 else 0.5
		arm.rest = Vector3(float(o.get("armPitch", -0.06)), 0.0, s * arm_out)
		arm.elbow_rest = float(o.get("elbowRest", 0.26))
		arm.swing = float(o.get("swing", 0.52))
		arm.wrist_rest = Vector3(-0.10, 0.0, 0.0)
		r.arms.append(arm)


static func _quad_leg(
	r: EnemyRig,
	nm: StringName,
	parent: StringName,
	off: Vector3,
	lengths: Vector2,
	leg_r: float,
	o: Dictionary
) -> void:
	var m: Dictionary = o["m"]
	var leg_m: StringName = m["leg"]
	var pad_m: StringName = m.get("pad", leg_m)
	var pastern: Dictionary = o["pastern"]
	var pastern_len: float = pastern["len"]
	var hip := StringName(String(nm) + "_hip")
	var knee := StringName(String(nm) + "_knee")
	var ankle := StringName(String(nm) + "_ank")
	r.link(hip, parent, off, lengths.x, leg_r, leg_r * 0.82, leg_m, {"ball_r": leg_r * 1.2})
	r.link(
		knee,
		hip,
		Vector3(0.0, -lengths.x, 0.0),
		lengths.y,
		leg_r * 0.84,
		leg_r * 0.62,
		leg_m,
		{"ball_r": leg_r * 0.96}
	)
	r.bone(ankle, knee, Vector3(0.0, -lengths.y, 0.0))
	r.sph(ankle, Vector3.ZERO, leg_r * 0.68, leg_m)
	r.cyl(
		ankle,
		Vector3(0.0, -pastern_len * 0.5, 0.0),
		leg_r * 0.56,
		leg_r * 0.44,
		pastern_len * 1.14,
		leg_m
	)
	r.sph(ankle, Vector3(0.0, -pastern_len, 0.0), float(pastern["pad_r"]), pad_m)
	var leg := RigLeg.new()
	leg.hip = hip
	leg.knee = knee
	leg.ankle = ankle
	leg.phase = o["phase"]
	leg.pole = o["pole"]
	leg.has_pastern = true
	leg.pastern_len = pastern_len
	leg.pastern_pad_r = pastern["pad_r"]
	leg.pastern_a0 = pastern["a0"]
	leg.pastern_a1 = pastern["a1"]
	leg.pastern_dir = float(pastern.get("dir", 1.0))
	r.legs.append(leg)
