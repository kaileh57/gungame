class_name GunRecoil
extends Resource
## Where the muzzle goes when the gun goes off.
##
## Range spec 12.3. The pattern is deliberately mostly deterministic: a fixed
## horizontal cycle of `GunSpec.recoil_period` shots, a fixed drift bias, a settle
## curve that makes the first rounds climb hardest, and only a small random spice
## scaled by how unreliable the gun is. Learn a gun's cycle and you can hold it on
## a plate at 60 m; that is the whole point and it is why this is not `randf()`.
##
## The kick is split. `permanent_fraction` of it goes into the shooter's actual aim
## and stays there until they pull it back down. The rest goes into a transient
## offset that snaps back in about 100 ms, which is what makes a shot feel like a
## shove rather than a teleport.

## Share of each kick that moves the shooter's real aim and does not come back.
@export_range(0.0, 1.0, 0.01) var permanent_fraction: float = 0.42
## Share that decays. The two need not sum to 1 — the reference's sum to exactly 1.
@export_range(0.0, 1.0, 0.01) var transient_fraction: float = 0.58
## Fraction of the transient offset still present one second later.
@export_range(0.000001, 0.5, 0.000001) var transient_retained_per_second: float = 0.0007
## Pitch is clamped to this, radians, so a runaway auto cannot spin the camera.
@export_range(0.5, 1.55, 0.01) var pitch_limit: float = 1.45
## How much of the kick shouldering absorbs, at full ADS.
@export_range(0.0, 1.0, 0.01) var ads_relief: float = 0.55
## Floor of the settle curve: what the climb decays to after a long string.
@export_range(0.0, 1.0, 0.01) var settle_floor: float = 0.55
## Weight of the sine term in the horizontal walk, against the constant drift bias.
@export_range(0.0, 2.0, 0.01) var horizontal_wave: float = 0.75
@export_range(0.0, 2.0, 0.01) var horizontal_drift_weight: float = 0.55
## Seconds of not firing after which the pattern counter resets, as a multiple of
## the shot interval. The `minimum` keeps slow actions from resetting mid-string.
@export_range(1.0, 8.0, 0.1) var string_reset_intervals: float = 2.2
@export_range(0.1, 2.0, 0.01) var string_reset_minimum: float = 0.42
## Viewmodel punch per shot, and how much of it the kick rating adds.
@export_range(0.0, 0.5, 0.001) var view_kick_base: float = 0.018
@export_range(0.0, 1.0, 0.001) var view_kick_weight: float = 0.05
@export_range(0.01, 1.0, 0.01) var view_kick_max: float = 0.20
@export_range(0.0, 1.0, 0.001) var view_roll_base: float = 0.06
@export_range(0.0, 2.0, 0.001) var view_roll_weight: float = 0.24
@export_range(0.01, 3.0, 0.01) var view_roll_max: float = 0.9
## Fraction of the viewmodel punch left after one second.
@export_range(0.000001, 0.5, 0.000001) var view_retained_per_second: float = 0.0016
## Camera shake added per shot, and its ceiling.
@export_range(0.0, 0.05, 0.0001) var shake_base: float = 0.0016
@export_range(0.0, 0.2, 0.0001) var shake_weight: float = 0.0075
@export_range(0.0, 0.5, 0.001) var shake_max: float = 0.055
## Seconds the per-shot shake envelope holds at full before it starts to fall.
@export_range(0.01, 1.0, 0.01) var shake_time: float = 0.16
## Fraction of the shake left one second after the hold ends. The reference holds
## for the window and then decays hard; cutting it to zero instead would be a pop
## on the last frame of every string.
@export_range(0.000001, 0.5, 0.000001) var shake_retained_per_second: float = 0.02

## Weights the reference applies to the stored transient on its way to the camera:
## `cam.rotation.x = pitch + recoilP*0.85`, `cam.rotation.y = yaw - recoilY*0.75`.
## They live here rather than in the camera because they are part of the kick's
## shape, and an AI's weapon has to compute the same number for its own aim error.
@export_range(0.0, 2.0, 0.01) var view_pitch_weight: float = 0.85
@export_range(0.0, 2.0, 0.01) var view_yaw_weight: float = 0.75
## Shake amplitude, in metres of camera jitter, that counts as full trauma. The
## reference shakes the camera by a raw distance; `PlayerViewEffects` works in
## trauma, and this is the conversion between them.
@export_range(0.005, 0.5, 0.001) var shake_full_scale: float = 0.045

## Decaying aim offset, radians. Read it through `camera_offset()` — the raw fields
## are the store, not the signal, and the weights above are not optional.
var transient_pitch: float = 0.0
var transient_yaw: float = 0.0
## Viewmodel punch, metres back and radians of roll. `GunHandPose` reads these
## every frame and this resource decays them; a reader must never clear them, or
## every other reader of the same weapon loses the shot.
var view_kick: float = 0.0
var view_roll: float = 0.0
## Camera shake amplitude and its remaining envelope, seconds.
var shake: float = 0.0
var shake_left: float = 0.0
## Shots fired in the current string. Drives the settle curve and the walk phase.
var shot_index: int = 0

var _vertical: float = 0.0
var _horizontal: float = 0.0
var _drift: float = 0.0
var _period: float = 6.0
var _random: float = 0.0
var _settle_rate: float = 0.0
var _kick: float = 0.0
var _since_shot: float = 0.0


func _init() -> void:
	resource_local_to_scene = true


func configure(spec: GunSpec) -> void:
	_vertical = spec.recoil_vertical
	_horizontal = spec.recoil_horizontal
	_drift = spec.recoil_drift
	_period = maxf(float(spec.recoil_period), 1.0)
	_random = maxf(spec.recoil_random, 0.0)
	_settle_rate = maxf(spec.recoil_settle, 0.0)
	_kick = clampf(spec.kick / 100.0, 0.0, 2.0)
	reset()


## Fire one shot. Returns the permanent aim change as (pitch, yaw) in radians,
## already signed for the caller to add straight onto its look angles. The
## transient half is folded into `transient_pitch` / `transient_yaw` here.
func fire(ads: float, rand: XorShift32) -> Vector2:
	var n: int = shot_index
	shot_index = n + 1
	_since_shot = 0.0
	var steady: float = 1.0 - ads_relief * clampf(ads, 0.0, 1.0)
	var settle: float = settle_floor + (1.0 - settle_floor) * exp(-float(n) * _settle_rate)
	var phase: float = (float(n) / _period) * 6.2832
	var v_kick: float = _vertical * settle * steady
	var pattern: float = sin(phase) * horizontal_wave + _drift * horizontal_drift_weight
	var spice: float = (rand.next() - 0.5) * _random
	var h_kick: float = (pattern + spice) * _horizontal * steady
	transient_pitch += v_kick * transient_fraction
	transient_yaw += h_kick * transient_fraction
	view_kick = minf(view_kick + view_kick_base + view_kick_weight * _kick, view_kick_max)
	view_roll = minf(view_roll + view_roll_base + view_roll_weight * _kick, view_roll_max)
	shake = minf(shake + shake_base + shake_weight * _kick, shake_max)
	shake_left = shake_time
	return Vector2(v_kick * permanent_fraction, -h_kick * permanent_fraction)


## Advance the decays. `interval` is the current shot interval, 60/rpm, which sets
## how long a gap has to be before the pattern counts as a new string.
func tick(delta: float, interval: float) -> void:
	if delta <= 0.0:
		return
	var keep: float = pow(transient_retained_per_second, delta)
	transient_pitch *= keep
	transient_yaw *= keep
	var view_keep: float = pow(view_retained_per_second, delta)
	view_kick *= view_keep
	view_roll *= view_keep
	if shake_left > 0.0:
		shake_left = maxf(shake_left - delta, 0.0)
	elif shake > 0.0:
		shake *= pow(shake_retained_per_second, delta)
		if shake < 0.0005:
			shake = 0.0
	_since_shot += delta
	if _since_shot > maxf(string_reset_minimum, interval * string_reset_intervals):
		shot_index = 0


## The decaying half of the kick, radians, ready to be ADDED to a shooter's look
## angles as (pitch, yaw). Range spec 14.2. This is 58 % of every shot: without it
## a round moves the aim but does not shove the view, and the gun feels like a
## cursor. Read it every frame after `tick()`, do not accumulate it — it is an
## absolute offset from the real aim, not a delta.
func camera_offset() -> Vector2:
	return Vector2(transient_pitch * view_pitch_weight, -transient_yaw * view_yaw_weight)


## Trauma to hand a view-effects rig, 0-1. Holds for `shake_time` after a shot and
## then falls away, so it is meant to be polled every frame rather than sampled
## once. Zero when nothing has gone off recently.
func shake_trauma() -> float:
	return clampf(shake / shake_full_scale, 0.0, 1.0)


## Clamp a shooter's pitch the way the reference does after adding our delta.
func clamp_pitch(pitch: float) -> float:
	return clampf(pitch, -pitch_limit, pitch_limit)


func reset() -> void:
	transient_pitch = 0.0
	transient_yaw = 0.0
	view_kick = 0.0
	view_roll = 0.0
	shake = 0.0
	shake_left = 0.0
	shot_index = 0
	_since_shot = 999.0
