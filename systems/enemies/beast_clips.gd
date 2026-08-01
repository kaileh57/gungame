class_name BeastClips
extends RefCounted
## The clip table and the two pure functions that drive aiming and muzzle flare.
##
## A pose is a pure function of (clip, absolute time, take). Locomotion is NOT a
## looping animation: the cycle is `t * freq` with `t` unbounded, and foot phase is
## `fposmod(cyc + phase, 1)`. Never advance a phase accumulator by `delta` — it
## drifts, and every frame-exact guarantee in the bake report goes with it.

const IDLE: StringName = &"idle"
const WALK: StringName = &"walk"
const RUN: StringName = &"run"
const AIM: StringName = &"aim"
const ATTACK: StringName = &"attack"
const STAGGER: StringName = &"stagger"
const DEATH: StringName = &"death"

const CLIPS: Array[StringName] = [IDLE, WALK, RUN, AIM, ATTACK, STAGGER, DEATH]

## `walk` and `run` are nominal: locomotion is unbounded in time and the length is
## only meaningful to a scrub bar. `attack`, `stagger` and `death` are one-shot.
const CLIPLEN: Dictionary = {
	&"idle": 3.4,
	&"walk": 1.0,
	&"run": 1.0,
	&"aim": 9.0,
	&"attack": 1.15,
	&"stagger": 0.85,
	&"death": 1.7
}

## Nine waypoints in rig space, metres. The rig holds each for 62% of a second,
## then swings to the next; `AIM_FIRE` gates the muzzle flare per waypoint.
const AIM_PATH: Array = [
	Vector3(0.0, 1.00, 9.0),
	Vector3(5.5, 1.30, 6.0),
	Vector3(-6.0, 2.60, 4.5),
	Vector3(2.0, 0.06, 2.6),
	Vector3(-2.5, 3.60, 3.0),
	Vector3(7.0, 1.10, -3.0),
	Vector3(-5.0, 0.70, -5.5),
	Vector3(0.0, 4.20, 1.6),
	Vector3(1.2, 0.90, 1.4)
]
const AIM_FIRE: Array = [1, 1, 1, 1, 0, 1, 1, 0, 1]
## Seconds per waypoint: the aim clip's 9 s over its 9 waypoints.
const AIM_SEG: float = 1.0
## The two shot times within a waypoint's second.
const SHOT_TIMES: Array = [0.22, 0.40]
## Reference height the aim path's Y was authored against.
const AIM_REF_HEIGHT: float = 1.75


static func is_locomotion(clip: StringName) -> bool:
	return clip == WALK or clip == RUN


static func length_of(clip: StringName) -> float:
	return float(CLIPLEN.get(clip, 1.0))


## Where the rig is looking this frame, or null if the clip does not aim at all.
## An explicit target always wins; only the aim rehearsal's Y scales with height.
static func aim_target_for(inst: RigInstance, clip: StringName, t: float) -> Variant:
	if inst.has_aim:
		return inst.aim_target
	var s: float = inst.stats.height if inst.stats != null else AIM_REF_HEIGHT
	if clip == AIM:
		var n: int = AIM_PATH.size()
		var i: int = int(floor(t / AIM_SEG)) % n
		var u: float = fposmod(t, AIM_SEG) / AIM_SEG
		var a: Vector3 = AIM_PATH[i]
		var b: Vector3 = AIM_PATH[(i + 1) % n]
		var k: float = BeastMath.smooth(clampf((u - 0.62) / 0.34, 0.0, 1.0))
		return Vector3(
			lerpf(a.x, b.x, k), lerpf(a.y, b.y, k) * (s / AIM_REF_HEIGHT), lerpf(a.z, b.z, k)
		)
	if clip == ATTACK:
		if inst.rig.aim != null:
			return Vector3(0.0, s * 0.62, 7.0)
		return Vector3(0.0, s * 0.45, 1.6)
	return null


## Muzzle flare intensity in [0, 1]: one spike per shot.
static func fire_pulse(clip: StringName, t: float) -> float:
	if clip == ATTACK:
		return maxf(0.0, 1.0 - absf(t - 0.40) / 0.09)
	if clip != AIM:
		return 0.0
	var i: int = int(floor(t / AIM_SEG)) % AIM_PATH.size()
	if int(AIM_FIRE[i]) == 0:
		return 0.0
	var u: float = fposmod(t, AIM_SEG) / AIM_SEG
	var f: float = 0.0
	for c in SHOT_TIMES:
		f = maxf(f, 1.0 - absf(u - float(c)) / 0.035)
	return maxf(0.0, f)
