extends SceneTree
## Regression harness for the bestiary rig core.
##
## Builds every body plan `RigBuilders` can emit, using the roster's real
## proportions, and audits the welded shell: no joint may open a gap, at rest or
## under any rotation. The reference's own validator reports the same figure —
## the per-species worst overlaps in `docs/spec/bestiary.md` §18.2 are reproduced
## here as expectations, so a proportion typo or a lost overhang fails loudly.
##
## Run headless:
##   godot --headless --path <project> --script res://tools/verify_rig_core.gd

## Radians of random flex applied to every joint in the stress pass.
const STRESS_SWING: float = 0.6
## Random poses per rig in the stress pass.
const STRESS_POSES: int = 64
## Tolerance against the reference's published overlaps, in metres. The reference
## ran in float64; Godot's `Transform3D` is float32, so a rest-pose overlap of
## ~0.1 m carries about 1.3e-8 m of composition error. That is 13 nanometres —
## six orders of magnitude below the tightest real overlap in the roster.
const TOL: float = 2e-7

const HUMAN_MATS: Dictionary = {
	"torso": &"canvas",
	"abs": &"canvas",
	"leg": &"canvas",
	"boot": &"hide",
	"arm": &"canvas",
	"hand": &"hide",
	"skin": &"flesh",
	"shoulder": &"hide"
}
const QUAD_MATS: Dictionary = {
	"torso": &"gunmet", "leg": &"alum", "neck": &"gunmet", "pad": &"rubber"
}

## `id -> [builder proportions, reference worst overlap in metres or -1]`.
## -1 means the reference's minimum lands on species geometry this harness does
## not build, so only the "no gap" assertion applies.
const HUMANOIDS: Dictionary = {
	"rat":
	[
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
			"handL": 0.10
		},
		0.05796
	],
	"picker":
	[
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
			"armOut": 0.14
		},
		0.07056
	],
	"gasman":
	[
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
			"armOut": 0.17
		},
		0.07812
	],
	"marksman":
	[
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
			"chestH": 0.335,
			"chestD": 0.215,
			"neckR": 0.058,
			"neckH": 0.105,
			"shW": 0.158,
			"armU": 0.315,
			"armL": 0.29,
			"armR": 0.046,
			"handL": 0.105
		},
		0.05796
	],
	"husk":
	[
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
			"armOut": 0.08
		},
		0.04788
	],
	"stilt":
	[
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
			"split": 0.50
		},
		0.06804
	],
	"gorger":
	[
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
			"split": 0.50
		},
		0.07812
	]
}
const QUADRUPEDS: Dictionary = {
	"latchdog":
	[
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
			"ph": [0.0, 0.5, 0.5, 0.0]
		},
		0.0393
	],
	"foreman":
	[
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
			"ph": [0.0, 0.5, 0.25, 0.75]
		},
		-1.0
	]
}


func _init() -> void:
	var failures: int = 0
	var worst_overall: float = INF
	var worst_id: String = ""
	print("id            bones parts  rest gap (m)  expected      stress gap (m)  floating")
	for id in HUMANOIDS:
		var row: Array = HUMANOIDS[id]
		var rig: EnemyRig = _make_humanoid(String(id), row[0])
		var r: Dictionary = _audit(rig, float(row[1]))
		failures += int(r["failed"])
		if float(r["stress"]) < worst_overall:
			worst_overall = float(r["stress"])
			worst_id = String(id) + " " + String(r["stress_bone"])
	for id in QUADRUPEDS:
		var row: Array = QUADRUPEDS[id]
		var rig: EnemyRig = _make_quadruped(String(id), row[0])
		var r: Dictionary = _audit(rig, float(row[1]))
		failures += int(r["failed"])
		if float(r["stress"]) < worst_overall:
			worst_overall = float(r["stress"])
			worst_id = String(id) + " " + String(r["stress_bone"])
	failures += _audit_tube()
	print("")
	print("worst separation anywhere: %.9f m is an OVERLAP at %s" % [-worst_overall, worst_id])
	print("FAIL x%d" % failures if failures > 0 else "PASS")
	quit(1 if failures > 0 else 0)


## Rest-pose audit plus a randomised-joint stress pass. Returns the failure count
## and the tightest overlap seen.
func _audit(rig: EnemyRig, expect: float) -> Dictionary:
	GaitSolver.solve(rig)
	var inst := RigInstance.new()
	inst.setup(rig)
	var rest: Dictionary = inst.link_report()
	var rest_gap: float = float(rest["min_link"])
	var failed: int = 0
	if rest_gap <= 0.0 or int(rest["floating"]) > 0:
		failed += 1
	if expect >= 0.0 and absf(rest_gap - expect) > TOL:
		failed += 1

	var rand := XorShift32.new(0x5EED0000 + rig.parts.size())
	var stress: float = rest_gap
	var stress_bone: StringName = rest["worst_bone"]
	var floating: int = 0
	for _p in STRESS_POSES:
		for i in inst.pose.size():
			inst.pose.locals[i] = Quaternion.from_euler(
				Vector3(
					rand.next_range(-STRESS_SWING, STRESS_SWING),
					rand.next_range(-STRESS_SWING, STRESS_SWING),
					rand.next_range(-STRESS_SWING, STRESS_SWING)
				)
			)
		inst.pose.update()
		var rep: Dictionary = inst.link_report()
		floating += int(rep["floating"])
		if float(rep["min_link"]) < stress:
			stress = float(rep["min_link"])
			stress_bone = rep["worst_bone"]
	if stress <= 0.0 or floating > 0:
		failed += 1
	print(
		(
			"%-13s %5d %5d  %12.9f  %-12s  %14.9f  %d"
			% [
				rig.id,
				rig.bones.size(),
				rig.parts.size(),
				rest_gap,
				("%.9f" % expect) if expect >= 0.0 else "-",
				stress,
				floating
			]
		)
	)
	return {"failed": failed, "stress": stress, "stress_bone": stress_bone}


## `tube()` welds a routed polyline: a ball at every kink, cylinders between. The
## audit is per-segment because every part sits on one bone, so `link_report`
## cannot see inside a tube — the seal has to be checked directly.
func _audit_tube() -> int:
	var rig := EnemyRig.new()
	rig.id = &"tube"
	rig.bone(&"root", &"")
	var pts: Array[Vector3] = [
		Vector3(0.0, 0.0, 0.0),
		Vector3(0.12, 0.18, -0.04),
		Vector3(-0.05, 0.31, 0.14),
		Vector3(-0.05, 0.31, 0.145),
		Vector3(0.22, 0.36, 0.02)
	]
	var r: float = 0.018
	rig.tube(&"root", pts, r, &"rubber")
	var mats: Array[Transform3D] = rig.rest_transforms()
	var prims: Array[Dictionary] = []
	for p in rig.parts:
		prims.append(BeastCollide.world_prim(p, mats[rig.bone_index(p.bone)] * p.local_transform()))
	# Parts 0..n-1 are the kink balls in point order; the rest are the segments.
	var balls: int = pts.size()
	var worst: float = INF
	for i in range(balls, prims.size()):
		var seg: int = i - balls
		var a: float = BeastCollide.penetration(prims[i], prims[seg])
		var b: float = BeastCollide.penetration(prims[i], prims[seg + 1])
		worst = minf(worst, minf(a, b))
	var degenerate: int = pts.size() - 1 - (prims.size() - balls)
	print("")
	print(
		(
			"tube: %d kinks, %d segments (%d collapsed), tightest ball/segment overlap %.9f m"
			% [balls, prims.size() - balls, degenerate, worst]
		)
	)
	return 0 if worst > 0.0 else 1


func _make_humanoid(id: String, o: Dictionary) -> EnemyRig:
	var rig := EnemyRig.new()
	rig.id = StringName(id)
	var opts: Dictionary = o.duplicate()
	opts["m"] = HUMAN_MATS
	RigBuilders.humanoid(rig, opts)
	return rig


func _make_quadruped(id: String, o: Dictionary) -> EnemyRig:
	var rig := EnemyRig.new()
	rig.id = StringName(id)
	var opts: Dictionary = o.duplicate()
	opts["m"] = QUAD_MATS
	RigBuilders.quadruped(rig, opts)
	return rig
