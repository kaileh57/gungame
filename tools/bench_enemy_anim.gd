extends SceneTree
## Headless cost and correctness harness for the procedural animation solvers.
##
## Builds a biped with a shoulder-mounted weapon and a quadruped, solves a crowd of
## each at every level of detail, and reports microseconds per enemy per tick — the
## only number that decides whether sixty agents fit in a frame. It also measures
## how far the pose-only legs land from the full IK solve, and how much a second of
## collapse costs.
##
## Run:
##   godot --headless --path <project> --script res://tools/bench_enemy_anim.gd --quit

const CROWD: int = 64
const TICKS: int = 160
const WARMUP: int = 40
const CLIP_MIX: Array[StringName] = [
	BeastClips.IDLE, BeastClips.WALK, BeastClips.RUN, BeastClips.AIM, BeastClips.ATTACK
]


func _init() -> void:
	print("=== enemy animation benchmark ===")
	print("crowd %d, %d ticks per measurement\n" % [CROWD, TICKS])
	_check_math()
	var biped: EnemyRig = _build_biped()
	var quad: EnemyRig = _build_quad()
	_report_gait("biped_armed", biped)
	_report_gait("quadruped", quad)
	for entry in [["biped_armed", biped], ["quadruped", quad]]:
		var label: String = entry[0]
		var rig: EnemyRig = entry[1]
		print(
			(
				"--- %s: %d bones, %d parts, %d legs, %d arms ---"
				% [label, rig.bones.size(), rig.parts.size(), rig.legs.size(), rig.arms.size()]
			)
		)
		_bench_lods(rig)
		_bench_parts(rig)
		_ground_check(rig)
		_lod_drift(rig)
		_slide_check(rig)
		_bench_death(rig)
		print("")
	quit()


## The two places the solvers replaced engine helpers with hand-rolled maths must
## agree with the engine to the last bit that matters.
func _check_math() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260728
	var worst: float = 0.0
	for i in 4000:
		var e := Vector3(
			rng.randf_range(-PI, PI), rng.randf_range(-PI, PI), rng.randf_range(-PI, PI)
		)
		var a: Quaternion = Basis.from_euler(e, EULER_ORDER_XYZ).get_rotation_quaternion()
		var b: Quaternion = RigPose.euler_quat(e.x, e.y, e.z)
		worst = maxf(worst, absf(absf(a.dot(b)) - 1.0))
	print(
		"euler_quat vs Basis.from_euler(XYZ): worst |1 - |dot|| = %.12f over 4000 triples" % worst
	)


## Every cached rig rotation must match the transform it was carried alongside.
func _check_rots(inst: RigInstance) -> float:
	var worst: float = 0.0
	for i in inst.pose.size():
		var q: Quaternion = inst.pose.globals[i].basis.get_rotation_quaternion()
		worst = maxf(worst, absf(absf(q.dot(inst.pose.rots[i])) - 1.0))
	return worst


func _report_gait(label: String, rig: EnemyRig) -> void:
	var g: Dictionary = rig.gait
	print(
		(
			"%s gait: reach %.3f m, freq %.3f Hz, stride %.3f m, walk %.2f m/s, run %.2f m/s"
			% [label, g["reach"], g["freq"], g["e"], g["speed"], g["run_speed"]]
		)
	)


## Microseconds per enemy per tick at each LOD, plus the per-frame cost of a crowd.
func _bench_lods(rig: EnemyRig) -> void:
	var crowd: Array[RigInstance] = _crowd(rig)
	var names: Array[String] = ["FULL", "REDUCED", "POSE_ONLY"]
	for lod_i in 3:
		var lod: AnimTuning.Lod = lod_i as AnimTuning.Lod
		var name: String = names[lod_i]
		for clip in CLIP_MIX:
			for w in WARMUP:
				_tick(crowd, clip, float(w) * 0.016, lod)
			# This machine is shared with the rest of the build; take the best of
			# three runs so a scheduler slice does not become the reported cost.
			var total: int = 0x7FFFFFFF
			for _rep in 3:
				var t0: int = Time.get_ticks_usec()
				for i in TICKS:
					_tick(crowd, clip, float(i) * 0.016, lod)
				total = mini(total, Time.get_ticks_usec() - t0)
			var per: float = float(total) / float(TICKS * CROWD)
			var frame: float = float(total) / float(TICKS)
			print(
				(
					"  %-9s %-8s %7.2f us/enemy/tick   %8.1f us for %d enemies"
					% [name, String(clip), per, frame, CROWD]
				)
			)
		var div: int = AnimTuning.get_active().tick_divisor(lod)
		if div > 1:
			print("             (solved 1 tick in %d at this LOD)" % div)


## Where the time actually goes, so a future optimisation aims at the right thing.
func _bench_parts(rig: EnemyRig) -> void:
	var inst: RigInstance = _make(rig, 0)
	PoseSolver.pose(inst, BeastClips.WALK, 0.4)
	var reps: int = 20000
	var n: int = inst.pose.size()

	var t0: int = Time.get_ticks_usec()
	for i in reps:
		inst.pose.update()
	var upd: float = float(Time.get_ticks_usec() - t0) / float(reps)

	t0 = Time.get_ticks_usec()
	for i in reps:
		inst.pose.set_euler(3, 0.1, 0.2, 0.3)
	var eul: float = float(Time.get_ticks_usec() - t0) / float(reps)

	var pole := Vector3(0.0, 0.0, 1.0)
	var hip: Vector3 = inst.pose.origin(inst.leg_hip[0])
	var tgt: Vector3 = hip + Vector3(0.05, -0.8, 0.1)
	t0 = Time.get_ticks_usec()
	for i in reps:
		BeastMath.ik2(hip, tgt, rig.legs[0].l1, rig.legs[0].l2, pole)
	var ik: float = float(Time.get_ticks_usec() - t0) / float(reps)

	t0 = Time.get_ticks_usec()
	for i in reps:
		inst.lowest_point(true)
	var low: float = float(Time.get_ticks_usec() - t0) / float(reps)

	print(
		(
			"  cost split: update(%d bones) %.2f us, set_euler %.3f us, ik2 %.3f us, lowest_point %.2f us"
			% [n, upd, eul, ik, low]
		)
	)


## The full solve must leave the shell exactly on the floor: no float, no sink.
func _ground_check(rig: EnemyRig) -> void:
	var inst: RigInstance = _make(rig, 0)
	var worst_rot: float = 0.0
	for clip in [BeastClips.IDLE, BeastClips.WALK, BeastClips.RUN]:
		var worst_float: float = -INF
		var worst_sink: float = INF
		var airborne: int = 0
		for i in 200:
			PoseSolver.pose_lod(inst, clip, float(i) * 0.01, AnimTuning.Lod.FULL)
			var low: float = inst.lowest_point(false)
			# A run whose duty cycle drops under half genuinely leaves the ground,
			# so float is only a defect while at least one foot is in stance.
			if low > 1e-4:
				airborne += 1
			worst_float = maxf(worst_float, low)
			worst_sink = minf(worst_sink, low)
			worst_rot = maxf(worst_rot, _check_rots(inst))
		print(
			(
				"  ground %-6s 200 poses: float %+.5f m, sink %+.5f m, off-ground frames %d"
				% [String(clip), worst_float, worst_sink, airborne]
			)
		)
	print("  cached rig rotations vs transforms: worst |1 - |dot|| = %.12f" % worst_rot)


## How far the analytic pose-only legs land from where the full IK solve puts them.
func _lod_drift(rig: EnemyRig) -> void:
	var a: RigInstance = _make(rig, 0)
	var b: RigInstance = _make(rig, 0)
	var worst: float = 0.0
	for clip in [BeastClips.IDLE, BeastClips.WALK, BeastClips.RUN]:
		for i in 120:
			var t: float = float(i) * 0.01
			PoseSolver.pose_lod(a, clip, t, AnimTuning.Lod.FULL)
			PoseSolver.pose_lod(b, clip, t, AnimTuning.Lod.POSE_ONLY)
			for k in rig.legs.size():
				var ai: int = a.leg_ankle[k]
				if ai < 0:
					continue
				worst = maxf(worst, a.pose.origin(ai).distance_to(b.pose.origin(ai)))
	print("  pose-only foot drift vs full solve: worst %.4f m over 360 poses" % worst)


## The one property that decides whether a walk reads as walking: a planted foot
## must travel backward through the rig at exactly the speed the body travels
## forward through the world, or it skates.
func _slide_check(rig: EnemyRig) -> void:
	var inst: RigInstance = _make(rig, 0)
	for clip in [BeastClips.WALK, BeastClips.RUN]:
		var dt: float = 1.0 / 240.0
		var g: Dictionary = rig.gait
		var freq: float = g["run_freq"] if clip == BeastClips.RUN else g["freq"]
		var duty: float = g["run_duty"] if clip == BeastClips.RUN else g["duty"]
		var worst: float = 0.0
		var samples: int = 0
		for i in 400:
			var t: float = float(i) * 0.005
			PoseSolver.pose(inst, clip, t)
			var travel: float = inst.travel
			var before: Array[Vector3] = _contacts(inst)
			PoseSolver.pose(inst, clip, t + dt)
			var after: Array[Vector3] = _contacts(inst)
			for k in before.size():
				# Planted means in stance at BOTH samples and clear of either
				# transition: a sample that straddles the wrap from toe-off to
				# heel-strike compares two different footfalls.
				var p0: float = fposmod(t * freq + rig.legs[k].phase, 1.0)
				var p1: float = fposmod((t + dt) * freq + rig.legs[k].phase, 1.0)
				var lo: float = duty * 0.15
				var hi: float = duty * 0.85
				if p0 < lo or p0 > hi or p1 < lo or p1 > hi:
					continue
				var rate: float = (after[k].z - before[k].z) / dt
				worst = maxf(worst, absf(rate + travel))
				samples += 1
		print(
			(
				"  foot slip %-4s: worst |ground speed - body speed| %.5f m/s over %d planted samples"
				% [String(clip), worst, samples]
			)
		)


## Where each foot actually touches the ground. A hoof rocks over its pad through
## the stance, so on a pastern leg the ankle joint legitimately travels while the
## contact point does not — measure the pad, not the joint.
func _contacts(inst: RigInstance) -> Array[Vector3]:
	var out: Array[Vector3] = []
	for i in inst.leg_ankle.size():
		var leg: RigLeg = inst.rig.legs[i]
		var m: Transform3D = inst.pose.globals[inst.leg_ankle[i]]
		if leg.has_pastern:
			out.append(m * Vector3(0.0, -leg.pastern_len, 0.0))
		else:
			out.append(m.origin)
	return out


## A collapse is a 1/120 s fixed-step sim; this is what one second of it costs.
func _bench_death(rig: EnemyRig) -> void:
	var inst: RigInstance = _make(rig, 7)
	inst.death_take = 2
	PoseSolver.pose_lod(inst, BeastClips.DEATH, 0.0, AnimTuning.Lod.FULL)
	var t0: int = Time.get_ticks_usec()
	for i in 120:
		PoseSolver.pose_lod(inst, BeastClips.DEATH, float(i + 1) / 120.0, AnimTuning.Lod.FULL)
	var total: int = Time.get_ticks_usec() - t0
	print(
		(
			"  death: %d us for 1.0 s of collapse (%.2f us per 1/120 s step), settled y %.4f"
			% [total, float(total) / 120.0, inst.death_state.y]
		)
	)


func _tick(crowd: Array[RigInstance], clip: StringName, t: float, lod: AnimTuning.Lod) -> void:
	for i in crowd.size():
		PoseSolver.pose_lod(crowd[i], clip, t + float(i) * 0.37, lod)


func _crowd(rig: EnemyRig) -> Array[RigInstance]:
	var out: Array[RigInstance] = []
	for i in CROWD:
		out.append(_make(rig, i))
	return out


func _make(rig: EnemyRig, index: int) -> RigInstance:
	var inst := RigInstance.new()
	inst.setup(rig)
	inst.seed_value = 1013 + index * 7919
	return inst


## An upright scav with a rifle butted into the shoulder pocket and both hands on
## it — the most expensive shape in the roster: two IK legs, two IK arms and a
## weapon solve.
func _build_biped() -> EnemyRig:
	var r := EnemyRig.new()
	r.id = &"bench_biped"
	r.rho = 780.0
	RigBuilders.humanoid(
		r,
		{
			"m":
			{
				"torso": &"canvas",
				"skin": &"flesh",
				"leg": &"canvas",
				"boot": &"rubber",
				"arm": &"canvas",
				"hand": &"flesh",
				"shoulder": &"steel"
			},
			"hipY": 0.92,
			"footH": 0.06,
			"footL": 0.26,
			"legR": 0.075,
			"hipW": 0.105,
			"pelvH": 0.20,
			"pelvD": 0.20,
			"waistW": 0.30,
			"waistD": 0.22,
			"absH": 0.20,
			"chestH": 0.32,
			"chestW": 0.40,
			"chestD": 0.24,
			"neckR": 0.065,
			"neckH": 0.10,
			"armR": 0.055,
			"armU": 0.29,
			"armL": 0.27,
			"handL": 0.11,
			"shW": 0.19
		}
	)
	r.tags["hunch"] = 0.06
	r.tags["lean_run"] = 0.12
	r.bone(&"gun", &"chest", Vector3(0.10, 0.24, 0.12))
	r.box(&"gun", Vector3(0.0, 0.0, 0.22), Vector3(0.07, 0.10, 0.62), &"gunmet")
	r.cyl(
		&"gun",
		Vector3(0.0, 0.01, 0.60),
		0.016,
		0.014,
		0.34,
		&"gunmet",
		{"rot": Vector3(PI * 0.5, 0.0, 0.0)}
	)
	var aim := RigAim.new()
	aim.mode = RigAim.MODE_SHOULDER
	aim.bone = &"gun"
	aim.muzzle = Vector3(0.0, 0.01, 0.78)
	aim.fwd = Vector3(0.0, 0.0, 1.0)
	aim.eye_z = 0.08
	var fore := RigAimHand.new()
	fore.arm = 0
	fore.grip = Vector3(0.0, -0.02, 0.34)
	fore.hand = Vector3(-0.9, 0.0, 0.0)
	fore.pole = Vector3(-0.5, -1.0, -0.2)
	var trig := RigAimHand.new()
	trig.arm = 1
	trig.grip = Vector3(0.0, -0.05, 0.02)
	trig.hand = Vector3(-1.1, 0.0, 0.0)
	trig.pole = Vector3(0.6, -1.0, -0.3)
	aim.hands = [fore, trig]
	r.aim = aim
	for arm in r.arms:
		arm.carry = true
	r.arms[0].carry_pose = Vector4(-1.10, 0.0, 0.34, 1.05)
	r.arms[1].carry_pose = Vector4(-1.25, 0.0, -0.30, 1.35)
	GaitSolver.solve(r)
	return r


## A four-legged mutant: hoofed pastern legs, no arms, no weapon.
func _build_quad() -> EnemyRig:
	var r := EnemyRig.new()
	r.id = &"bench_quad"
	r.rho = 940.0
	RigBuilders.quadruped(
		r,
		{
			"m": {"torso": &"hide", "leg": &"hide", "pad": &"chitin", "neck": &"flesh"},
			"bodyL": 1.10,
			"bodyH": 0.44,
			"bodyW": 0.40,
			"backY": 0.86,
			"hipW": 0.14,
			"legR": 0.055,
			"padR": 0.055,
			"neckL": 0.34,
			"neckR": 0.085,
			"neckY": 0.06,
			"chestW": 0.40,
			"chestH": 0.42,
			"shW": 0.15,
			"chestRise": 0.03,
			"pastern": {"f": 0.13, "h": 0.15},
			"ph": [0.0, 0.5, 0.55, 0.05]
		}
	)
	r.link(&"tail", &"pelvis", Vector3(0.0, 0.12, -0.26), 0.34, 0.032, 0.018, &"hide")
	r.tags["wags"] = [{"b": &"tail", "f": 0.8, "a": 0.10, "ax": "y", "base": 0.0}]
	GaitSolver.solve(r)
	return r
