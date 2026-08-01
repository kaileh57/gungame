class_name GaitSolver
extends RefCounted
## Derives locomotion from geometry. Walking speed is never authored: it is stride
## travel divided by contact time, and the stride is capped by how far the foot can
## actually swing without the leg straightening past its limit.
##
## To retune a creature, change `duty`, `stride_k` or `freq_k` and let the speed
## fall out. Typing a speed in by hand desynchronises the feet from the ground and
## is the single most common way a procedural walk starts to skate.

const GRAVITY: float = 9.81
## Pendulum constant: step frequency scales as sqrt(g / leg length).
const FREQ_K: float = 0.30
## Shortest leg the pendulum model is trusted for, in metres.
const MIN_REACH: float = 0.12
## Hard ceiling on leg extension while computing swing travel.
const EXTEND_CAP: float = 0.965
## Running lengthens the stride and shortens the contact phase.
const RUN_FREQ_K: float = 1.42
const RUN_DUTY_K: float = 0.56
const RUN_DUTY_MIN: float = 0.30
const RUN_STRIDE_K: float = 1.45

const DEFAULTS: Dictionary = {
	"type": "biped",
	"duty": 0.60,
	"stride_k": 1.45,
	"freq_k": 1.0,
	"lift": 0.16,
	"bob": 0.022,
	"sway": 0.02
}


## Measure the rest pose and write every derived gait and limb length back onto
## the rig. Run once, at bake time.
static func solve(rig: EnemyRig) -> void:
	var g: Dictionary = rig.gait
	for k in DEFAULTS:
		if not g.has(k):
			g[k] = DEFAULTS[k]
	var rest: Array[Transform3D] = rig.rest_transforms()
	_measure_arms(rig, rest)
	if rig.legs.is_empty():
		_solve_hover(g)
		return
	_measure_legs(rig, rest)

	var reach: float = 0.0
	var hip_h: float = 0.0
	var stand_y: float = 0.0
	var emax: float = INF
	var drop_max: float = INF
	for leg in rig.legs:
		reach += leg.reach
		hip_h += leg.hip_rest.y
		stand_y += leg.stand_y
		emax = minf(emax, leg.e_max)
		drop_max = minf(drop_max, leg.drop_max)
	var n: float = float(rig.legs.size())
	reach /= n
	var duty: float = g["duty"]
	g["reach"] = reach
	g["hip_h"] = hip_h / n
	g["stand_y"] = stand_y / n
	g["freq"] = FREQ_K * sqrt(GRAVITY / maxf(reach, MIN_REACH)) * float(g["freq_k"])
	g["e"] = minf(float(g["stride_k"]) * duty * reach, emax * 0.90)
	g["speed"] = float(g["e"]) * float(g["freq"]) / duty
	g["emax_v"] = emax
	g["drop_max"] = drop_max
	g["run_freq"] = float(g["freq"]) * RUN_FREQ_K
	g["run_duty"] = maxf(RUN_DUTY_MIN, duty * RUN_DUTY_K)
	g["run_e"] = minf(float(g["e"]) * RUN_STRIDE_K, emax * 0.94)
	g["run_speed"] = float(g["run_e"]) * float(g["run_freq"]) / float(g["run_duty"])


## Legless rigs short-circuit. The reference leaves `run_freq`/`run_duty`/`run_e`
## undefined here and its hover branch returns before touching them; zeroing them
## reproduces that while keeping GDScript out of a divide by zero.
static func _solve_hover(g: Dictionary) -> void:
	var hover: float = float(g.get("hover_speed", 3.0))
	g["speed"] = hover * 0.55
	g["run_speed"] = hover
	g["freq"] = 1.0
	g["e"] = 0.0
	g["run_freq"] = 0.0
	g["run_duty"] = 0.0
	g["run_e"] = 0.0


static func _measure_arms(rig: EnemyRig, rest: Array[Transform3D]) -> void:
	for arm in rig.arms:
		var sh: Vector3 = rest[rig.bone_index(arm.shoulder)].origin
		var el: Vector3 = rest[rig.bone_index(arm.elbow)].origin
		var wr: Vector3 = rest[rig.bone_index(arm.wrist)].origin
		arm.l1 = sh.distance_to(el)
		arm.l2 = el.distance_to(wr)


static func _measure_legs(rig: EnemyRig, rest: Array[Transform3D]) -> void:
	for leg in rig.legs:
		var hip: Vector3 = rest[rig.bone_index(leg.hip)].origin
		var knee: Vector3 = rest[rig.bone_index(leg.knee)].origin
		var ankle: Vector3 = rest[rig.bone_index(leg.ankle)].origin
		leg.hip_rest = hip
		leg.l1 = hip.distance_to(knee)
		leg.l2 = knee.distance_to(ankle)
		leg.reach = leg.l1 + leg.l2
		if leg.has_pastern:
			leg.stand_y = leg.pastern_pad_r + leg.pastern_len * cos(leg.pastern_a0)
		elif leg.has_sole:
			leg.stand_y = leg.sole_h
		else:
			leg.stand_y = 0.0
		leg.rest_x = hip.x * leg.stance_k + leg.out_x
		leg.rest_z = hip.z + leg.z_off
		if leg.has_pastern:
			leg.rest_z += leg.pastern_len * sin(leg.pastern_a0) * leg.pastern_dir
		# 3-D hip-to-foot distance at rest, then the fore-aft travel that still
		# leaves the leg short of straight once the pelvis has dipped as far as
		# it is allowed to.
		var rest3: float = (
			Vector3(leg.rest_x - hip.x, leg.stand_y - hip.y, leg.rest_z - hip.z).length()
		)
		leg.drop_max = leg.drop_max_k * leg.reach
		var eff: float = maxf(0.25 * leg.reach, rest3 - leg.drop_max)
		var span: float = EXTEND_CAP * leg.reach
		leg.e_max = 2.0 * sqrt(maxf(span * span - eff * eff, 0.0025))
