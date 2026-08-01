class_name DeathPoser
extends RefCounted
## A seeded collapse, not a keyframed animation.
##
## The body is an inverted pendulum tipping about the edge of its own foot; the
## knees buckle on their own schedule; each limb is a damped vector spring dragged
## by the tip and clamped out of the floor; and the whole thing is integrated at a
## fixed 1/120 s so that (seed, take, t) reproduces a frame exactly.
##
## Two details are worth reading before touching this. Contact is judged on the
## TORSO AND LEGS ONLY: an arm flung under the body must not jack the corpse off
## the floor, it just clips. And the limbs are carried by the tip rate from BEFORE
## the step's integration, not after, which is what stops them snapping ahead of
## the body on the first frame.

const DT: float = 1.0 / 120.0
## Corpses fall at 2.8 g. Real gravity reads as floaty on a body this size.
const FALL_G: float = 9.81 * 2.8
## Restitution when the body first meets the ground.
const BOUNCE: float = 0.10
## Past this tip angle the body counts as landed. Feet touching is not landing.
const LAND_ANGLE: float = 0.95
## The pendulum stops here — flat on the ground — and rebounds a fifth of the way.
const FLAT_ANGLE: float = 1.55
## Iteration cap; a scrub past ~25 s of sim silently stops advancing.
const STEP_GUARD: int = 3000


## Roll a fresh collapse. Draw order: yaw, spin, theta, omega, buckle, bDur,
## hSeed, lean, twist, then a (knee, hip) pair per leg, then (k, c) per arm joint.
static func init_state(inst: RigInstance, take: int) -> DeathState:
	var seed_u: int = ((inst.seed_value * 2654435761) ^ (take * 40503 + 7)) & 0xFFFFFFFF
	var r := XorShift32.new(seed_u)
	var s := DeathState.new()
	s.take = take
	s.yaw = r.next() * TAU
	s.spin = (r.next() - 0.5) * 3.4
	s.theta = 0.03 + r.next() * 0.06
	s.omega = 2.3 + r.next() * 3.0
	s.buckle = 0.01 + r.next() * 0.09
	s.buckle_dur = 0.09 + r.next() * 0.15
	s.head_seed = r.next()
	s.lean = (r.next() - 0.5) * 1.2
	s.twist = (r.next() - 0.5) * 1.5
	s.settle = 0.010 + 0.012 * float(inst.gait.get("hip_h", 1.0))
	for _i in inst.rig.legs.size():
		s.knee_flex.append(0.85 + r.next() * 1.15)
		s.hip_flex.append((r.next() - 0.5) * 1.0)
	for arm in inst.rig.arms:
		s.sh_dir.append(Vector3(arm.side * 0.25, -1.0, 0.05).normalized())
		s.sh_vel.append(Vector3.ZERO)
		s.sh_k.append(55.0 + r.next() * 70.0)
		s.sh_c.append(6.0 + r.next() * 4.0)
		s.el_dir.append(Vector3(arm.side * 0.15, -1.0, 0.15).normalized())
		s.el_vel.append(Vector3.ZERO)
		s.el_k.append(90.0 + r.next() * 90.0)
		s.el_c.append(5.0 + r.next() * 4.0)
	return s


## Damped vector spring, semi-implicit Euler. Stable only because dt is pinned to
## 1/120 and k stays under 180: k*dt <= 1.5. Never run this at a variable delta.
static func limb_follow(dir: Vector3, vel: Vector3, want: Vector3, k: float, c: float) -> Array:
	var v: Vector3 = vel + (want - dir) * (k * DT)
	v *= maxf(0.0, 1.0 - c * DT)
	return [(dir + v * DT).normalized(), v]


## Stop a limb spearing through the floor, preserving its horizontal heading and
## only tilting it up.
static func clamp_limb(d: Vector3, origin: Vector3, length: float, floor_y: float) -> Vector3:
	var min_y: float = (floor_y - origin.y) / maxf(length, 1e-4)
	if d.y >= min_y or min_y >= 1.0:
		return d
	var y: float = maxf(-1.0, min_y)
	var h: float = sqrt(maxf(0.0, 1.0 - y * y))
	var hl: float = sqrt(d.x * d.x + d.z * d.z)
	if hl > 1e-6:
		return Vector3(d.x / hl * h, y, d.z / hl * h)
	return Vector3(h, y, 0.0)


## One 1/120 s step of the collapse. `body_len` scales angular gravity by size.
static func advance(inst: RigInstance, s: DeathState, body_len: float) -> void:
	var ang_g: float = 9.81 / maxf(body_len, 0.25)
	var w0: float = s.omega
	s.omega += ang_g * sin(minf(s.theta, PI * 0.5)) * DT * 1.7
	s.theta += s.omega * DT
	if s.theta >= FLAT_ANGLE:
		s.theta = FLAT_ANGLE - (s.theta - FLAT_ANGLE) * 0.2
		s.omega = -absf(s.omega) * 0.18
	s.omega *= 1.0 - (2.0 + 9.0 * s.land) * DT
	s.yaw_spin += s.spin * DT * 0.35
	s.spin *= 1.0 - (1.4 + 26.0 * s.land) * DT
	var tip_ax := Vector3(cos(s.yaw), 0.0, -sin(s.yaw))
	var down := Vector3(0.0, -1.0, 0.0)
	var carry: float = w0 * DT * 1.3
	var untwist: float = -s.spin * DT * 0.35
	for i in inst.rig.arms.size():
		var sd: Vector3 = s.sh_dir[i].rotated(tip_ax, carry).rotated(down, untwist).normalized()
		var sr: Array = limb_follow(sd, s.sh_vel[i], down, s.sh_k[i], s.sh_c[i])
		s.sh_dir[i] = sr[0]
		s.sh_vel[i] = sr[1]
		var ed: Vector3 = s.el_dir[i].rotated(tip_ax, carry).rotated(down, untwist).normalized()
		var er: Array = limb_follow(ed, s.el_vel[i], down, s.el_k[i], s.el_c[i])
		s.el_dir[i] = er[0]
		s.el_vel[i] = er[1]
	s.t += DT


## Write the whole rig for the current integrator state.
static func pose_state(inst: RigInstance, s: DeathState) -> void:
	var rig: EnemyRig = inst.rig
	var rp: RigPose = inst.pose
	var sc: float = float(inst.gait.get("hip_h", inst.gait.get("hover_h", 1.0)))
	var sag: float = BeastMath.smooth(clampf((s.t - 0.02) / 0.30, 0.0, 1.0))
	_place_root(inst, s, sc)

	var n: int = inst.spine_idx.size()
	var hunch: float = float(rig.tags.get("hunch", 0.0))
	for i in n:
		var f: float = float(i + 1) / float(n)
		rp.set_euler(
			inst.spine_idx[i],
			hunch * f + sag * (0.30 + 0.45 * s.lean) * f,
			sag * s.twist * 0.45 * f,
			sag * sin(s.yaw) * 0.45 * f
		)
	if inst.head_idx >= 0:
		rp.set_euler(
			inst.head_idx,
			sag * (0.45 + 0.65 * s.head_seed),
			s.twist * 0.9 * sag,
			sin(s.yaw * 2.0) * 0.5 * sag
		)
	if inst.neck_idx >= 0:
		rp.set_euler(inst.neck_idx, float(rig.tags.get("neck_pitch", 0.0)) + 0.45 * sag, 0.0, 0.0)
	var wags: Array = rig.tags.get("wags", [])
	for i in wags.size():
		rp.set_euler(inst.wag_idx[i], float(wags[i].get("base", 0.0)), 0.0, 0.0)
	var spins: Array = rig.tags.get("spin", [])
	for i in spins.size():
		# Rotors spin down rather than stopping dead.
		var rate: float = s.t * float(spins[i]["rate"]) * maxf(0.0, 1.0 - s.t * 1.6)
		rp.set_euler(inst.spin_idx[i], 0.0, rate, 0.0)

	var buckled: float = BeastMath.smooth(clampf((s.t - s.buckle) / s.buckle_dur, 0.0, 1.0))
	for i in rig.legs.size():
		var leg: RigLeg = rig.legs[i]
		var hip: float = s.hip_flex[i]
		rp.set_euler(
			inst.leg_hip[i],
			-0.08 - 0.55 * buckled + hip * buckled,
			hip * buckled * 0.4,
			hip * buckled * 0.5
		)
		rp.set_euler(inst.leg_knee[i], s.knee_flex[i] * buckled, 0.0, 0.0)
		if inst.leg_ankle[i] >= 0:
			var base: float = leg.pastern_a0 if leg.has_pastern else 0.0
			rp.set_euler(inst.leg_ankle[i], 0.30 * buckled + base, 0.0, 0.0)
	rp.update()
	_pose_limbs(inst, s, sc)


## Advance the collapse to absolute time `t`, re-initialising if the caller has
## scrubbed backwards or switched take.
static func death_to(inst: RigInstance, t: float, take: int) -> void:
	var s: DeathState = inst.death_state
	if s == null or s.take != take or s.t > t + 1e-6:
		s = init_state(inst, take)
		inst.death_state = s
		pose_state(inst, s)
	var body_len: float = float(inst.gait.get("hip_h", inst.gait.get("hover_h", 1.0))) * 1.15
	var guard: int = 0
	var budget: int = STEP_GUARD
	if inst.death_budgeted:
		budget = AnimTuning.get_active().death_steps_per_call
	while s.t < t and guard < STEP_GUARD and guard < budget:
		guard += 1
		advance(inst, s, body_len)
		pose_state(inst, s)
		var low: float = inst.lowest_point(true)
		s.vy -= FALL_G * DT
		s.y += s.vy * DT
		if low <= 0.0:
			s.y -= low
			if s.vy < 0.0:
				s.vy = -s.vy * BOUNCE
			if s.theta > LAND_ANGLE:
				s.land = minf(1.0, s.land + DT * 10.0)
				s.omega *= 1.0 - 24.0 * DT
		if s.land > 0.1:
			s.y -= s.settle * DT * 4.0 * s.land
	pose_state(inst, s)
	var low: float = inst.lowest_point(true)
	if low < 0.0:
		s.y -= low
		pose_state(inst, s)


## Tip about the EDGE OF THE FOOT rather than the root, or the body vaults into
## the air as it rotates. One of only three places the reference uses YXZ.
static func _place_root(inst: RigInstance, s: DeathState, sc: float) -> void:
	var rp: RigPose = inst.pose
	if String(inst.gait.get("type", "biped")) == "hover":
		var euler := Vector3(
			cos(s.yaw) * s.theta * 1.5, s.yaw_spin * 2.2, -sin(s.yaw) * s.theta * 1.5
		)
		rp.root = Transform3D(
			Basis.from_euler(euler, EULER_ORDER_YXZ),
			Vector3(sin(s.yaw) * s.theta * 0.4, s.y, cos(s.yaw) * s.theta * 0.4)
		)
		rp.update()
		return
	var e_d := Vector3(cos(s.yaw) * s.theta, s.yaw_spin, -sin(s.yaw) * s.theta)
	var basis: Basis = Basis.from_euler(e_d, EULER_ORDER_YXZ)
	var piv: Vector3 = Vector3(sin(s.yaw), 0.0, cos(s.yaw)) * (0.26 * sc)
	var pv2: Vector3 = basis * piv
	rp.root = Transform3D(basis, Vector3(piv.x - pv2.x, s.y + piv.y - pv2.y, piv.z - pv2.z))
	rp.update()


static func _pose_limbs(inst: RigInstance, s: DeathState, sc: float) -> void:
	var rp: RigPose = inst.pose
	# Allow the corpse to sink a little rather than hover a millimetre proud.
	var floor_y: float = -0.03 * sc
	for i in inst.rig.arms.size():
		var arm: RigArm = inst.rig.arms[i]
		var sh: int = inst.arm_sh[i]
		var el: int = inst.arm_el[i]
		var sh_origin: Vector3 = rp.origin(sh)
		var q_upper: Quaternion = rp.aim_bone_from(
			sh, clamp_limb(s.sh_dir[i], sh_origin, arm.l1, floor_y), rp.parent_rotation(sh)
		)
		# The elbow has just moved and its clamp needs where it moved to. Bones do
		# not translate, so its new origin is the shoulder's plus the rotated bone
		# offset — no transform rewalk required to find it.
		var el_origin: Vector3 = sh_origin + q_upper * rp.offset(el)
		# The hand hangs past the wrist, so the forearm is clamped 55% longer.
		var ed: Vector3 = clamp_limb(s.el_dir[i], el_origin, arm.l2 * 1.55, floor_y)
		var q_fore: Quaternion = rp.aim_bone_from(el, ed, q_upper)
		if inst.arm_wr[i] >= 0:
			rp.orient_bone_from(
				inst.arm_wr[i],
				BeastMath.quat_from_unit_vectors(Vector3(0.0, -1.0, 0.0), ed),
				q_fore
			)
	var rig: EnemyRig = inst.rig
	var first: int = inst.aim_bone_idx if inst.aim_bone_idx >= 0 else 0x7FFFFFFF
	for i in inst.arm_sh.size():
		first = mini(first, inst.arm_sh[i])
	if first < 0x7FFFFFFF:
		rp.update(first)
	if rig.aim == null or rig.aim.mode != RigAim.MODE_SHOULDER or inst.aim_bone_idx < 0:
		return
	var gi: int = inst.aim_bone_idx
	var gun_len: float = rig.aim.muzzle.length()
	var gd: Vector3 = clamp_limb(
		Vector3(sin(s.yaw) * 0.55, -0.8, cos(s.yaw) * 0.55).normalized(),
		rp.origin(gi),
		gun_len,
		floor_y
	)
	rp.orient_bone(gi, BeastMath.look_q(gd))
	rp.update(gi)
