class_name AimSolver
extends RefCounted
## Puts the muzzle on the target — not the pivot, the muzzle.
##
## A weapon is a rigid body pivoting about an anchor with the bore offset from that
## pivot, so pointing the anchor at a target misses it by an angle that grows as
## the target closes. `BeastMath.aim_quat` solves that offset in closed form; this
## file mounts it three ways, kicks it when the shot goes off, and then welds the
## hands onto whatever came out.
##
## The recoil is applied to the weapon BEFORE the hands are solved, which is the
## whole trick: the arms chase the gun, so a kick travels up the rig instead of
## tearing the grips out of the palms.

## An elbow pole may never point above this in rig space, or the joint flips over
## the shoulder the moment the weapon depresses steeply.
const POLE_Y_MAX: float = -0.35
## The turret's muzzle moves as its head turns, so the yaw/pitch solve iterates.
const TURRET_ITERATIONS: int = 8


## Two-bone IK onto `target`, optionally with an outright wrist orientation.
##
## Writes the whole chain without a single intermediate transform rewalk: the
## shoulder's resolved rig rotation is fed straight into the elbow and the elbow's
## into the wrist. The caller updates once when it is done placing bones.
static func solve_arm(
	inst: RigInstance,
	arm_i: int,
	target: Vector3,
	pole: Vector3,
	hand_q: Quaternion,
	use_hand_q: bool
) -> void:
	var a: RigArm = inst.rig.arms[arm_i]
	var sh: int = inst.arm_sh[arm_i]
	var el: int = inst.arm_el[arm_i]
	var wr: int = inst.arm_wr[arm_i]
	var rp: RigPose = inst.pose
	var o: Dictionary = BeastMath.ik2(rp.origin(sh), target, a.l1, a.l2, pole.normalized())
	var q_upper: Quaternion = rp.aim_bone_from(sh, o["thigh"], rp.parent_rotation(sh))
	var q_fore: Quaternion = rp.aim_bone_from(el, o["shin"], q_upper)
	if wr >= 0 and use_hand_q:
		rp.orient_bone_from(wr, hand_q, q_fore)


## Aim the rig's weapon at `target`, faded in by `blend` and kicked by `pulse`.
##
## The fade is applied to the affected bones' local rotations so a gun swings up
## into an attack rather than snapping to it on the first frame. `hands` is false
## at the reduced LOD: the weapon still tracks, the arms hold their carry pose.
static func solve_weapon(
	inst: RigInstance, target: Vector3, blend: float, pulse: float = 0.0, hands: bool = true
) -> void:
	var a: RigAim = inst.rig.aim
	if a == null:
		return
	if a.mode == RigAim.MODE_TURRET:
		solve_turret(inst, target, pulse)
		return
	var touched: PackedInt32Array = _touched_bones(inst, a, hands)
	var before: Array[Quaternion] = []
	if blend < 1.0:
		before = inst.pose.capture_locals(touched)
	if a.mode == RigAim.MODE_SHOULDER:
		_solve_shoulder(inst, a, target, pulse, hands)
	else:
		_solve_hand(inst, a, target, pulse)
	if blend < 1.0:
		inst.pose.blend_locals(touched, before, clampf(blend, 0.0, 1.0))
	inst.pose.update(_lowest(touched))


## Yaw then pitch in the mount's own space, clamped to the mount's travel. Eight
## passes converge the muzzle offset, which swings as the head turns.
static func solve_turret(inst: RigInstance, target: Vector3, pulse: float = 0.0) -> void:
	var a: RigAim = inst.rig.aim
	var bi: int = inst.aim_yaw_idx
	if bi < 0:
		return
	var mount: Transform3D = inst.pose.parent_transform(bi)
	var tl: Vector3 = mount.affine_inverse() * target
	var off: Vector3 = inst.pose.offset(bi)
	var pitch: float = 0.0
	for _i in TURRET_ITERATIONS:
		var muzzle_local: Vector3 = inst.pose.locals[bi] * a.muzzle + off
		var dx: float = tl.x - muzzle_local.x
		var dy: float = tl.y - muzzle_local.y
		var dz: float = tl.z - muzzle_local.z
		var yaw: float = atan2(dx, dz)
		pitch = atan2(-dy, sqrt(dx * dx + dz * dz))
		# One of only three places the reference uses YXZ instead of XYZ.
		inst.pose.locals[bi] = (
			Basis
			. from_euler(
				Vector3(
					clampf(pitch, a.pitch_limits.x, a.pitch_limits.y),
					clampf(yaw, a.yaw_limits.x, a.yaw_limits.y),
					0.0
				),
				EULER_ORDER_YXZ
			)
			. get_rotation_quaternion()
		)
	if pulse > 0.0:
		# The mount rocks back on its own bore, after the solve, so the kick is
		# visible rather than iterated away.
		inst.pose.locals[bi] *= _recoil_quat(a, pulse)
	inst.pose.update(bi)


## Weapon on its own bone: swing the frame about its anchor, kick it, then solve
## both hands onto the grips it now presents. The gun leads, the arms follow.
static func _solve_shoulder(
	inst: RigInstance, a: RigAim, target: Vector3, pulse: float, hands: bool
) -> void:
	var gi: int = inst.aim_bone_idx
	if gi < 0:
		return
	var rp: RigPose = inst.pose
	var anchor: Vector3 = rp.origin(gi)
	var q: Quaternion = BeastMath.aim_quat(anchor, a.muzzle, a.fwd, target, a.up, a.roll)
	if pulse > 0.0:
		q *= _recoil_quat(a, pulse)
	rp.orient_bone_from(gi, q, rp.parent_rotation(gi))
	if not hands:
		return
	rp.update(gi)
	var gun: Transform3D = rp.globals[gi]
	var gun_q: Quaternion = gun.basis.get_rotation_quaternion()
	for h in a.hands:
		if h.arm >= inst.rig.arms.size():
			continue
		var grip: Vector3 = gun * h.grip
		var hand_q: Quaternion = gun_q * RigPose.euler_quat(h.hand.x, h.hand.y, h.hand.z)
		var pole: Vector3 = gun_q * h.pole
		pole.y = minf(pole.y, POLE_Y_MAX)
		solve_arm(inst, h.arm, grip, pole.normalized(), hand_q, true)


## Weapon welded to a wrist: place the wrist on the aim line first, then orient it
## outright so the bore — not the forearm — ends up on the target.
static func _solve_hand(inst: RigInstance, a: RigAim, target: Vector3, pulse: float) -> void:
	if a.arm >= inst.rig.arms.size():
		return
	var arm: RigArm = inst.rig.arms[a.arm]
	var rp: RigPose = inst.pose
	var sh: int = inst.arm_sh[a.arm]
	var origin: Vector3 = rp.origin(sh)
	var dir: Vector3 = target - origin
	if dir.length_squared() < 1e-10:
		dir = Vector3.BACK
	dir = dir.normalized()
	var total: float = arm.l1 + arm.l2
	var tgt: Vector3 = origin + dir * (total * a.hold)
	# The drop fades out as the aim goes vertical: an arm raised overhead has no
	# room to sag.
	tgt.y += a.drop * total * maxf(0.0, 1.0 - absf(dir.y) * 1.4)
	var px: float = a.pole.x
	if is_zero_approx(px):
		px = arm.side * 0.7
	solve_arm(inst, a.arm, tgt, Vector3(px, -1.0, POLE_Y_MAX), Quaternion.IDENTITY, false)
	var wr: int = inst.arm_wr[a.arm]
	if wr < 0:
		return
	rp.update(sh)
	var q: Quaternion = BeastMath.aim_quat(rp.origin(wr), a.muzzle, a.fwd, target, a.up, a.roll)
	if pulse > 0.0:
		q *= _recoil_quat(a, pulse)
	rp.orient_bone(wr, q)


## The kick, in the weapon's own frame: muzzle climb about the axis across the
## bore, plus a little whip across it. Post-multiplied, so it rides on whatever
## the aim solve produced rather than fighting it.
static func _recoil_quat(a: RigAim, pulse: float) -> Quaternion:
	var tune: AnimTuning = AnimTuning.get_active()
	var fwd: Vector3 = a.fwd.normalized()
	var across: Vector3 = a.up.cross(fwd)
	if across.length_squared() < 1e-8:
		across = Vector3.RIGHT
	across = across.normalized()
	var climb := Quaternion(across, -tune.recoil_pitch * pulse)
	var whip := Quaternion(a.up.normalized(), tune.recoil_yaw * pulse * a.recoil_side)
	return climb * whip


static func _touched_bones(inst: RigInstance, a: RigAim, hands: bool) -> PackedInt32Array:
	var out: PackedInt32Array = PackedInt32Array()
	if a.mode == RigAim.MODE_SHOULDER:
		if inst.aim_bone_idx >= 0:
			out.append(inst.aim_bone_idx)
		if hands:
			for h in a.hands:
				if h.arm < inst.arm_sh.size():
					out.append(inst.arm_sh[h.arm])
					out.append(inst.arm_el[h.arm])
					out.append(inst.arm_wr[h.arm])
	elif a.arm < inst.arm_sh.size():
		out.append(inst.arm_sh[a.arm])
		out.append(inst.arm_el[a.arm])
		out.append(inst.arm_wr[a.arm])
	return out


static func _lowest(indices: PackedInt32Array) -> int:
	var lo: int = 0x7FFFFFFF
	for i in indices:
		if i >= 0 and i < lo:
			lo = i
	return 0 if lo == 0x7FFFFFFF else lo
