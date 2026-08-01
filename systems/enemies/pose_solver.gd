class_name PoseSolver
extends RefCounted
## The master pose function: a pure write of every bone's local rotation plus the
## root's placement, evaluated at an absolute clip time. Nothing accumulates, so
## the same (clip, t, take, lod) always produces the same frame — which is what
## makes the bake's gap audit meaningful, what lets a distant creature animate at a
## quarter of the frame rate without drifting out of step, and what lets it change
## LOD mid-stride without a pop.
##
## Order matters throughout. Body offsets, then the aim decomposition, then spine,
## head, arms, wags, the root, the feet, the pelvis dip, the leg IK, and finally
## the weapon. Reordering any of it changes the silhouette.
##
## Two things this does that the reference does not, both for the frame budget:
## every per-frame scalar lives in one reused scratch object rather than a fresh
## dictionary, and an IK chain is written with `RigPose.aim_bone_from` so a limb
## costs one transform rewalk instead of one per joint.

## Idle breathing period, seconds. The head sway uses 5.1 s against this 3.4 s so
## the two never line up and the loop never visibly repeats.
const BREATH_PERIOD: float = 3.4
const HEAD_SWAY_PERIOD: float = 5.1
## Hard limit on leg extension, as a fraction of the chain length. The pelvis dips
## to reach the floor; the legs do not rest bent.
const EXTEND_LIMIT: float = 0.985
## A waist twists this far before the feet have to take the rest of the turn.
const WAIST_YAW_LIMIT: float = 0.62
const GRAVITY: float = 9.81

static var _frame: PoseFrame = PoseFrame.new()


## Everything one pose evaluation needs to carry between its stages. Reused across
## calls: a solver that runs on sixty agents cannot afford a dictionary per stage.
class PoseFrame:
	extends RefCounted

	## Body-size scalar, the hip (or hover) height.
	var scale: float = 1.0
	var loco: bool = false
	var run: bool = false
	## Locomotion cycle, `t * freq`, unbounded. Foot phase wraps it, never a
	## delta-advanced accumulator.
	var cyc: float = 0.0
	var duty: float = 0.0
	var stride: float = 0.0
	var freq: float = 0.0
	## 1 while walking or running, 0 otherwise. Gates every gait-driven term.
	var amp: float = 0.0
	var sway: float = 0.0
	var bounce: float = 0.0

	## Clip-level whole-body offsets.
	var body_y: float = 0.0
	var body_z: float = 0.0
	var body_pitch: float = 0.0
	var body_roll: float = 0.0
	var body_yaw: float = 0.0
	var crouch: float = 0.0
	## Attack and stagger progress, 0..1.
	var atk: float = 0.0
	var stg: float = 0.0
	var melee: bool = false
	## Breathing, 0..1.
	var breath: float = 0.0

	## Aim decomposition.
	var aiming: bool = false
	var target: Vector3 = Vector3.ZERO
	var blend: float = 0.0
	var stance_yaw: float = 0.0
	var waist_yaw: float = 0.0
	var waist_pitch: float = 0.0
	var head_yaw: float = 0.0
	var head_pitch: float = 0.0
	## Stance yaw actually applied to the feet, `stance_yaw * blend`.
	var foot_yaw: float = 0.0

	## Muzzle flare and recoil drive, 0..1.
	var pulse: float = 0.0

	## Foot solve, one entry per leg.
	var targets: Array[Vector3] = []
	var pastern_dirs: Array[Vector3] = []
	var rolls: PackedFloat32Array = PackedFloat32Array()
	var planted: PackedByteArray = PackedByteArray()

	func size_legs(n: int) -> void:
		if targets.size() == n:
			return
		targets.resize(n)
		pastern_dirs.resize(n)
		rolls.resize(n)
		planted.resize(n)


## Pose `inst` for `clip` at absolute time `t` at the full solve. `take` selects
## the death variant; -1 keeps whichever take the instance already holds.
static func pose(inst: RigInstance, clip: StringName, t: float, take: int = -1) -> void:
	pose_lod(inst, clip, t, AnimTuning.Lod.FULL, take)


## Pose `inst` at a chosen level of detail. See `AnimTuning.Lod`.
static func pose_lod(
	inst: RigInstance, clip: StringName, t: float, lod: AnimTuning.Lod, take: int = -1
) -> void:
	var rig: EnemyRig = inst.rig
	var g: Dictionary = inst.gait
	var rp: RigPose = inst.pose
	var f: PoseFrame = _frame

	if clip == BeastClips.DEATH:
		DeathPoser.death_to(inst, t, inst.death_take if take < 0 else take)
		inst.flash_pulse = 0.0
		inst.travel = 0.0
		return

	_begin_frame(inst, clip, t, f)
	_pose_spine(inst, clip, t, f)
	_pose_arms(inst, clip, t, f)
	_pose_wags(inst, t, f.loco)

	if String(g.get("type", "biped")) == "hover":
		_place_hover(inst, t, f)
		if rig.aim != null and rig.aim.mode == RigAim.MODE_TURRET and f.aiming:
			AimSolver.solve_turret(inst, f.target, f.pulse)
		inst.flash_pulse = f.pulse
		inst.travel = _travel(g, f)
		return

	_place_root(inst, f)
	_foot_targets(inst, f)
	_apply_dip(inst, f)
	if lod == AnimTuning.Lod.POSE_ONLY:
		_pose_legs_cheap(inst, f)
	else:
		_solve_legs(inst, f)
	rp.update(_first_leg(inst))

	if rig.aim != null:
		# An armed rig is always aim-solved, even at rest and even at the lowest
		# LOD. That is what keeps the weapon in both hands instead of hanging off
		# one wrist, and it is why a creature does not snap its gun up the moment
		# it crosses a LOD boundary. Only the hands drop away with distance.
		var target: Vector3 = f.target if f.aiming else Vector3(0.0, f.scale * 1.15, 6.0)
		var blend: float = f.blend if f.aiming else 1.0
		AimSolver.solve_weapon(inst, target, blend, f.pulse, lod == AnimTuning.Lod.FULL)
	inst.flash_pulse = f.pulse
	inst.travel = _travel(g, f)


static func _body_scale(g: Dictionary) -> float:
	if g.has("hip_h"):
		return float(g["hip_h"])
	if g.has("hover_h"):
		return float(g["hover_h"])
	return 1.0


static func _travel(g: Dictionary, f: PoseFrame) -> float:
	if not f.loco:
		return 0.0
	return float(g["run_speed"]) if f.run else float(g["speed"])


## Fill the scratch frame: gait constants, the clip's whole-body offsets, the aim
## decomposition and the fire pulse. Everything downstream reads from here.
static func _begin_frame(inst: RigInstance, clip: StringName, t: float, f: PoseFrame) -> void:
	var g: Dictionary = inst.gait
	f.scale = _body_scale(g)
	f.loco = BeastClips.is_locomotion(clip)
	f.run = clip == BeastClips.RUN
	f.freq = float(g["run_freq"]) if f.run else float(g["freq"])
	f.duty = float(g["run_duty"]) if f.run else float(g["duty"])
	f.stride = float(g["run_e"]) if f.run else float(g["e"])
	f.cyc = t * f.freq if f.loco else 0.0
	f.amp = 1.0 if f.loco else 0.0
	f.sway = sin(f.cyc * TAU) if f.loco else 0.0
	f.bounce = sin(f.cyc * 2.0 * TAU) if f.loco else 0.0
	f.pulse = BeastClips.fire_pulse(clip, t)
	_body_offsets(inst, clip, t, f)
	_aim_split(inst, clip, t, f)


## Clip-level offsets of the whole body: breathing, the melee lunge, the stagger.
static func _body_offsets(inst: RigInstance, clip: StringName, t: float, f: PoseFrame) -> void:
	f.body_y = 0.0
	f.body_z = 0.0
	f.body_pitch = 0.0
	f.body_roll = 0.0
	f.body_yaw = 0.0
	f.crouch = 0.0
	f.atk = 0.0
	f.stg = 0.0
	f.melee = inst.rig.aim == null
	f.breath = sin(t * 1.5 * TAU / BREATH_PERIOD) * 0.5 + 0.5
	if clip == BeastClips.IDLE:
		f.body_y = sin(t * TAU / BREATH_PERIOD) * 0.012 * f.scale
	elif clip == BeastClips.ATTACK:
		f.atk = clampf(t / BeastClips.length_of(BeastClips.ATTACK), 0.0, 1.0)
	elif clip == BeastClips.STAGGER:
		f.stg = clampf(t / BeastClips.length_of(BeastClips.STAGGER), 0.0, 1.0)
	if f.atk > 0.0 and f.melee:
		# Wind up over the first third of the swing, then follow through.
		var w: float = BeastMath.smooth(f.atk / 0.34)
		var lead: float = -1.0
		if f.atk >= 0.34:
			w = 1.0 - BeastMath.smooth(clampf((f.atk - 0.34) / 0.5, 0.0, 1.0))
			lead = 1.0
		f.body_pitch += 0.16 * w * lead
		f.body_z += 0.045 * w * lead * f.scale
	if f.stg > 0.0:
		var w: float = sin(PI * f.stg) * exp(-f.stg * 1.2)
		f.body_pitch -= 0.42 * w
		f.body_z -= 0.085 * w * f.scale
		f.body_roll += 0.18 * w
		f.crouch += 0.10 * w


## Split an aim direction across the stance, the waist and the head. The waist
## twists first, the feet take whatever is left, and the head leads both.
static func _aim_split(inst: RigInstance, clip: StringName, t: float, f: PoseFrame) -> void:
	f.stance_yaw = 0.0
	f.waist_yaw = 0.0
	f.waist_pitch = 0.0
	f.head_yaw = 0.0
	f.head_pitch = 0.0
	f.blend = 0.0
	f.foot_yaw = 0.0
	var aim_t: Variant = BeastClips.aim_target_for(inst, clip, t)
	f.aiming = aim_t != null
	if not f.aiming:
		return
	f.target = aim_t
	f.blend = clampf(t / 0.22, 0.0, 1.0) if clip == BeastClips.ATTACK else 1.0
	var rig: EnemyRig = inst.rig
	var cx: float = rig.aim.eye_z if rig.aim != null else 0.0
	var eye_y: float = f.scale * 1.15
	var az: float = atan2(f.target.x, f.target.z - cx)
	var flat: float = sqrt(f.target.x * f.target.x + (f.target.z - cx) * (f.target.z - cx))
	var el: float = atan2(f.target.y - eye_y, maxf(flat, 0.05))
	var turn: float = float(rig.tags.get("turn", -1.0))
	if turn < 0.0:
		turn = PI if rig.aim != null else 0.0
	f.waist_yaw = clampf(az, -WAIST_YAW_LIMIT, WAIST_YAW_LIMIT)
	f.stance_yaw = clampf(az - f.waist_yaw, -turn, turn)
	f.waist_pitch = clampf(-el * 0.36, -0.34, 0.30)
	f.head_yaw = clampf(az - f.waist_yaw * 0.9, -0.85, 0.85) * 0.55
	f.head_pitch = clampf(-el * 0.55, -0.75, 0.65)
	if rig.aim != null and rig.aim.mode == RigAim.MODE_TURRET:
		# A turret does not twist the body it is bolted to.
		f.waist_yaw = 0.0
		f.stance_yaw = 0.0
		f.waist_pitch = 0.0
	f.foot_yaw = f.stance_yaw * f.blend


static func _pose_spine(inst: RigInstance, clip: StringName, t: float, f: PoseFrame) -> void:
	var rig: EnemyRig = inst.rig
	var rp: RigPose = inst.pose
	var lean: float = 0.0
	if f.loco:
		lean = float(rig.tags.get("lean_run", 0.0)) * (1.0 if f.run else 0.35)
	var flex_k: float = float(rig.tags.get("flex", 1.15))
	# A long horizontal spine barely twists, so the twist gain is capped at 1 even
	# where the pitch gain is not.
	var twist: float = minf(1.0, flex_k)
	var hunch: float = float(rig.tags.get("hunch", 0.0)) * (1.0 - f.blend * 0.55)
	var tune: AnimTuning = AnimTuning.get_active()
	var kick: float = f.pulse * tune.recoil_lean
	var n: int = inst.spine_idx.size()
	for i in n:
		var frac: float = float(i + 1) / float(n)
		var px: float = (
			hunch * frac
			+ (f.body_pitch * flex_k + lean) * frac
			+ f.amp * f.bounce * 0.020 * frac
			+ f.waist_pitch * f.blend * frac * twist
			- kick * frac
		)
		if clip == BeastClips.IDLE:
			px += f.breath * 0.012 * frac
		var py: float = (
			f.body_yaw * frac * 0.6
			+ f.amp * f.sway * 0.045 * frac
			+ f.waist_yaw * f.blend * frac * twist
		)
		rp.set_euler(
			inst.spine_idx[i], px, py, f.body_roll * frac * 0.8 + f.amp * f.sway * 0.030 * frac
		)

	if inst.head_idx >= 0:
		var hp: float = (
			-hunch * 1.1 - f.body_pitch * 0.7 + f.head_pitch * f.blend + kick * tune.recoil_head_k
		)
		var hy: float = -f.body_yaw * 0.5 + f.stg * 0.2 + f.head_yaw * f.blend
		if f.loco:
			hp += -f.bounce * 0.02
			hy += f.sway * 0.06
		if clip == BeastClips.IDLE and not f.aiming:
			# Two incommensurate periods, so the idle never visibly loops.
			hp += sin(t * TAU / BREATH_PERIOD + 1.1) * 0.05
			hy += sin(t * TAU / HEAD_SWAY_PERIOD) * 0.30
		rp.set_euler(inst.head_idx, hp, hy, -f.body_roll * 0.5)
	if inst.neck_idx >= 0:
		var ny: float = f.sway * 0.04 if f.loco else 0.0
		rp.set_euler(
			inst.neck_idx, float(rig.tags.get("neck_pitch", 0.0)) - f.body_pitch * 0.35, ny, 0.0
		)


static func _pose_arms(inst: RigInstance, clip: StringName, t: float, f: PoseFrame) -> void:
	var rp: RigPose = inst.pose
	var gain: float = 1.7 if f.run else 1.0
	for i in inst.rig.arms.size():
		var arm: RigArm = inst.rig.arms[i]
		var s: float = sin((f.cyc + arm.phase) * TAU) if f.loco else 0.0
		var sx: float = arm.rest.x + s * arm.swing * gain * f.amp
		var sy: float = arm.rest.y
		var sz: float = arm.rest.z
		var ex: float = arm.elbow_rest
		if f.loco:
			ex += (0.34 - 0.30 * s) * gain * f.amp
		if clip == BeastClips.IDLE:
			sx += sin(t * TAU / BREATH_PERIOD + arm.phase * 3.0) * 0.030
			ex += f.breath * 0.05
		if f.aiming and arm.carry:
			sx = arm.carry_pose.x
			sy = arm.carry_pose.y
			sz = arm.carry_pose.z
			ex = arm.carry_pose.w
		if f.atk > 0.0 and arm.attack and f.melee:
			var w: float = BeastMath.smooth(f.atk / 0.30)
			var wind_sh: float = -arm.atk_wind
			var wind_el: float = arm.atk_wind * 0.8
			if f.atk >= 0.30:
				w = 1.0 - BeastMath.smooth(clampf((f.atk - 0.30) / 0.42, 0.0, 1.0))
				wind_sh = 0.0
				wind_el = 0.0
			var k: float = minf(1.0, w + 0.35)
			sx = lerpf(sx, arm.atk_pose.x + wind_sh, k)
			sz = lerpf(sz, arm.atk_pose.z, k)
			ex = lerpf(ex, arm.atk_pose.w + wind_el, k)
		if f.stg > 0.0:
			var w: float = sin(PI * f.stg)
			sx = lerpf(sx, -0.9, w * 0.8)
			ex = lerpf(ex, 1.3, w * 0.8)
			sz = lerpf(sz, arm.rest.z + 0.5 * arm.side, w * 0.7)
		rp.set_euler(inst.arm_sh[i], sx, sy, sz)
		# The elbow only ever flexes; a negative flex would hyperextend it.
		rp.set_euler(inst.arm_el[i], -maxf(ex, 0.0), 0.0, 0.0)
		if inst.arm_wr[i] >= 0:
			rp.set_euler(
				inst.arm_wr[i], arm.wrist_rest.x, arm.wrist_rest.y, arm.wrist_rest.z - sz * 0.85
			)


## Tails, booms and sensor heads, then rotors. The `base` offset lands on the X
## channel whatever axis the wag names — the foreman's booms are authored against
## that behaviour, so it is reproduced rather than corrected.
static func _pose_wags(inst: RigInstance, t: float, loco: bool) -> void:
	var wags: Array = inst.rig.tags.get("wags", [])
	var boost: float = 1.6 if loco else 1.0
	for i in wags.size():
		var w: Dictionary = wags[i]
		var s: float = (
			sin(t * TAU * float(w["f"]) + float(w.get("ph", 0.0))) * float(w["a"]) * boost
		)
		var ax: String = w["ax"]
		var base: float = float(w.get("base", 0.0))
		inst.pose.set_euler(
			inst.wag_idx[i],
			base + (s if ax == "x" else 0.0),
			s if ax == "y" else 0.0,
			s if ax == "z" else 0.0
		)
	var spins: Array = inst.rig.tags.get("spin", [])
	for i in spins.size():
		inst.pose.set_euler(inst.spin_idx[i], 0.0, t * float(spins[i]["rate"]), 0.0)


static func _place_hover(inst: RigInstance, t: float, f: PoseFrame) -> void:
	var g: Dictionary = inst.gait
	var y: float = (
		float(g.get("hover_h", 1.2))
		+ sin(t * TAU * 0.55) * 0.05
		+ sin(t * TAU * 1.31 + 1.7) * 0.022
	)
	var pitch: float = f.body_pitch * 0.5 + (-0.22 if f.loco else 0.0)
	var roll: float = f.body_roll * 0.6 + (0.05 if f.loco else 0.0)
	inst.pose.root = Transform3D(
		Basis.from_euler(Vector3(pitch, f.body_yaw, roll), EULER_ORDER_XYZ),
		Vector3(sin(t * TAU * 0.37) * 0.05, y, 0.0)
	)
	inst.pose.update()


## First bone index any leg touches. Everything below it is already final by the
## time the feet are solved, so the pose's last rewalk starts here.
static func _first_leg(inst: RigInstance) -> int:
	var lo: int = 0
	for i in inst.leg_hip.size():
		if i == 0 or inst.leg_hip[i] < lo:
			lo = inst.leg_hip[i]
	return lo


## One past the last hip. Placing the root only needs to resolve this far for the
## pelvis dip to be judged; the feet rewalk the rest afterwards. A legged rig that
## somehow declares no legs falls back to the whole skeleton.
static func _hip_bound(inst: RigInstance) -> int:
	if inst.leg_hip.is_empty():
		return -1
	var hi: int = 0
	for i in inst.leg_hip.size():
		hi = maxi(hi, inst.leg_hip[i] + 1)
	return hi


## Root placement for a legged rig, including genuine ballistic flight: when no
## foot is in contact the body follows the apex of a real projectile arc of the
## airborne duration, `h = g*T^2/8`, shaped so it starts and ends at zero. A run
## whose duty cycle drops below half genuinely leaves the ground.
static func _place_root(inst: RigInstance, f: PoseFrame) -> void:
	var g: Dictionary = inst.gait
	var bob: float = 0.0
	if f.loco:
		bob = -absf(f.bounce) * float(g["bob"]) * 2.0
	var flight: float = 0.0
	if f.loco and not inst.rig.legs.is_empty():
		var t_prev: float = INF
		var t_next: float = INF
		var support: int = 0
		for leg in inst.rig.legs:
			var p: float = fposmod(f.cyc + leg.phase, 1.0)
			if p < f.duty:
				support += 1
			t_next = minf(t_next, fposmod(1.0 - p, 1.0))
			t_prev = minf(t_prev, fposmod(p - f.duty, 1.0))
		if support == 0:
			var span: float = t_prev + t_next
			var u: float = t_prev / span if span > 1e-6 else 0.0
			var secs: float = span / f.freq
			flight = (GRAVITY * secs * secs / 8.0) * sin(PI * u)
	var crouch: float = f.crouch * float(g.get("hip_h", 1.0)) * 0.82
	var root_y: float = f.body_y + bob + flight - crouch
	var roll: float = f.body_roll * 0.30
	if f.loco:
		roll += f.sway * float(g["sway"])
	inst.pose.root = Transform3D(
		Basis.from_euler(
			Vector3(f.body_pitch * 0.12, f.body_yaw + f.foot_yaw, roll), EULER_ORDER_XYZ
		),
		Vector3(0.0, root_y, f.body_z)
	)
	inst.pose.update(0, _hip_bound(inst))


## Where each foot wants to be this frame, plus the ankle roll and, for hoofed or
## digitigrade legs, the pastern direction the foot plants along.
static func _foot_targets(inst: RigInstance, f: PoseFrame) -> void:
	var g: Dictionary = inst.gait
	f.size_legs(inst.rig.legs.size())
	var cy: float = cos(f.foot_yaw)
	var sy: float = sin(f.foot_yaw)
	var lift_k: float = float(g["lift"]) * (1.35 if f.run else 1.0)
	var reach: float = float(g.get("reach", 1.0))
	for i in inst.rig.legs.size():
		var leg: RigLeg = inst.rig.legs[i]
		var p: float = fposmod(f.cyc + leg.phase, 1.0) if f.loco else -1.0
		var stance: bool = p >= 0.0 and p < f.duty
		var swing: bool = p >= f.duty
		var u: float = (p - f.duty) / (1.0 - f.duty) if swing else 0.0
		var fz: float = leg.rest_z
		var lift: float = 0.0
		if stance:
			# The planted foot slides straight back under the body: linear in phase
			# is what makes it track the ground instead of skating.
			fz += f.stride * (0.5 - p / f.duty)
		elif swing:
			fz += f.stride * (-0.5 + BeastMath.smooth(u))
			lift = sin(PI * pow(u, 0.86)) * lift_k
		elif f.atk > 0.0 and f.melee and leg.plant:
			var shuffle: float = 0.06 if i % 2 == 0 else -0.06
			fz += f.body_z + shuffle * sin(PI * f.atk) * reach
		elif f.stg > 0.0:
			var side_k: float = 1.0 if i % 2 == 1 else 0.4
			fz += f.body_z - sin(PI * f.stg) * reach * 0.10 * side_k
		var roll: float = 0.0
		if stance:
			roll = lerpf(-0.20, 0.42, p / f.duty)
		elif swing:
			roll = lerpf(0.42, -0.20, BeastMath.smooth(u)) - sin(PI * u) * 0.30
		roll *= leg.roll_k
		f.rolls[i] = roll
		var rx: float = leg.rest_x * cy + fz * sy
		var rz: float = -leg.rest_x * sy + fz * cy
		if leg.has_pastern:
			var frac: float = 0.0
			if stance:
				frac = p / f.duty
			elif swing:
				frac = 1.0 - BeastMath.smooth(u)
			var ang: float = leg.pastern_a0 + (leg.pastern_a1 - leg.pastern_a0) * frac
			var d: Vector3 = Vector3(0.0, -cos(ang), sin(ang) * leg.pastern_dir).normalized()
			d = d.rotated(Vector3.UP, f.foot_yaw)
			f.pastern_dirs[i] = d
			f.planted[i] = 1
			f.targets[i] = Vector3(rx, leg.pastern_pad_r + lift, rz) - d * leg.pastern_len
		else:
			var fy: float = leg.stand_y
			if leg.has_sole:
				# Keep the sole flat: the lower of the boot's two Z edges sets the
				# height once the ankle has rolled.
				var c: float = cos(roll)
				var sn: float = sin(roll)
				fy = -minf(-leg.sole_h * c - leg.sole_zb * sn, -leg.sole_h * c - leg.sole_zf * sn)
			f.pastern_dirs[i] = Vector3.ZERO
			f.planted[i] = 0
			f.targets[i] = Vector3(rx, fy + lift, rz)


## Drop the whole body just far enough that no leg has to over-reach for its
## target. This is why the legs never rest visibly bent.
static func _apply_dip(inst: RigInstance, f: PoseFrame) -> void:
	var dip: float = 0.0
	for i in inst.rig.legs.size():
		var leg: RigLeg = inst.rig.legs[i]
		var h: Vector3 = inst.pose.origin(inst.leg_hip[i])
		var rm: float = EXTEND_LIMIT * (leg.l1 + leg.l2)
		var dx: float = h.x - f.targets[i].x
		var dz: float = h.z - f.targets[i].z
		var dxz: float = sqrt(dx * dx + dz * dz)
		if dxz >= rm:
			# Horizontally out of range already: nothing the dip can do but give
			# this leg its whole allowance.
			dip = maxf(dip, leg.drop_max)
			continue
		var hy: float = f.targets[i].y + sqrt(rm * rm - dxz * dxz)
		if h.y - hy > dip:
			dip = minf(h.y - hy, leg.drop_max)
	if dip > 1e-5:
		inst.pose.shift(Vector3(0.0, -dip, 0.0))


## Two-bone IK onto every foot target. The chain is written parent rotation into
## child, so the whole set of legs costs the caller a single `update()`.
static func _solve_legs(inst: RigInstance, f: PoseFrame) -> void:
	var rp: RigPose = inst.pose
	for i in inst.rig.legs.size():
		var leg: RigLeg = inst.rig.legs[i]
		var hip: int = inst.leg_hip[i]
		var o: Dictionary = BeastMath.ik2(
			rp.origin(hip), f.targets[i], leg.l1, leg.l2, leg.pole.normalized()
		)
		var q_thigh: Quaternion = rp.aim_bone_from(hip, o["thigh"], rp.parent_rotation(hip))
		var q_shin: Quaternion = rp.aim_bone_from(inst.leg_knee[i], o["shin"], q_thigh)
		var ankle: int = inst.leg_ankle[i]
		if ankle < 0:
			continue
		if f.planted[i] != 0:
			rp.orient_bone_from(
				ankle,
				BeastMath.quat_from_unit_vectors(Vector3(0.0, -1.0, 0.0), f.pastern_dirs[i]),
				q_shin
			)
		else:
			rp.orient_bone_from(ankle, RigPose.euler_quat(f.rolls[i], f.foot_yaw, 0.0), q_shin)


## Legs for the pose-only solve: the same foot target, reached with three Euler
## writes instead of an IK chain.
##
## The full solve rotates the thigh off the hip-to-foot line about an axis derived
## from the pole vector, which is what lets a knee track sideways. Restricted to
## the sagittal plane the same cosine rule collapses to two angles that can be
## written straight into the bones, and the ankle counter-rotates by their sum to
## keep the foot level. The foot lands on its target to within the leg's lateral
## offset — under two centimetres on everything in the roster, which is a fraction
## of a pixel at the range this LOD is used.
static func _pose_legs_cheap(inst: RigInstance, f: PoseFrame) -> void:
	var rp: RigPose = inst.pose
	for i in inst.rig.legs.size():
		var leg: RigLeg = inst.rig.legs[i]
		var hip: int = inst.leg_hip[i]
		# In the hip's own parent frame, so a leaning chest or a twisted pelvis is
		# already accounted for by the time these become local Euler angles.
		var d: Vector3 = rp.parent_rotation(hip).inverse() * (f.targets[i] - rp.origin(hip))
		var l1: float = leg.l1
		var l2: float = leg.l2
		var dc: float = clampf(d.length(), absf(l1 - l2) + 1e-4, l1 + l2 - 1e-4)
		# Angle of the hip-to-foot line from straight down, toward +Z. Only the
		# sagittal component survives; the lateral offset a real IK solve would
		# absorb is what the drift figure in the bench measures.
		var line: float = atan2(d.z, maxf(-d.y, 1e-4))
		var off: float = acos(clampf((l1 * l1 + dc * dc - l2 * l2) / (2.0 * l1 * dc), -1.0, 1.0))
		var bend: float = (
			PI - acos(clampf((l1 * l1 + l2 * l2 - dc * dc) / (2.0 * l1 * l2), -1.0, 1.0))
		)
		# Which way the joint breaks. Quadruped forelegs point their pole backward.
		var knee_dir: float = 1.0 if leg.pole.z >= 0.0 else -1.0
		var hip_x: float = -line - off * knee_dir
		var knee_x: float = bend * knee_dir
		rp.set_euler(hip, hip_x, 0.0, 0.0)
		rp.set_euler(inst.leg_knee[i], knee_x, 0.0, 0.0)
		var ankle: int = inst.leg_ankle[i]
		if ankle < 0:
			continue
		var base: float = leg.pastern_a0 if leg.has_pastern else f.rolls[i]
		rp.set_euler(ankle, base - hip_x - knee_x, f.foot_yaw, 0.0)
