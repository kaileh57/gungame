class_name AnimTuning
extends Resource
## The knobs the procedural animation is felt through: how hard a weapon kicks,
## and how much solving a creature is worth at a given distance.
##
## Everything a species owns — stride, swing, hunch, pole vectors — lives on its
## rig, because it is per-creature. What lives here is global and is meant to be
## tuned once by eye, with sixty agents on screen, against the frame budget.
##
## `AnimTuning.active` holds the live instance every solver reads. Save a `.tres`
## and assign it there to override the defaults without touching code.

## How much of a creature is worth solving.
##
## FULL      — every joint: pelvis dip, leg IK, the weapon and both hands on it.
## REDUCED   — legs still IK onto the ground; the weapon still tracks, but the
##             hands stop chasing its grips and hold their carry pose instead.
## POSE_ONLY — no leg IK: the same foot targets, reached with plain Euler angles.
##
## The weapon is aim-solved at every tier. Letting it fall back would make a rifle
## snap up the instant its owner crossed a distance band, which reads worse than
## anything the tiers save.
enum Lod { FULL, REDUCED, POSE_ONLY }

## The instance every solver reads. Assign a tuned resource to retune the whole
## bestiary at once. Built lazily rather than inline: a static of a class's own
## type cannot be constructed while that class is still initialising.
static var active: AnimTuning = null

## Muzzle climb at full fire pulse, radians. Applied about the weapon's own X
## before the hands are solved, so the arms follow the gun rather than detaching.
@export_range(0.0, 0.6, 0.005, "radians_as_degrees") var recoil_pitch: float = 0.15
## Lateral whip at full fire pulse, radians. Which way it whips is the weapon's
## own `RigAim.recoil_side`.
@export_range(0.0, 0.4, 0.005, "radians_as_degrees") var recoil_yaw: float = 0.035
## How far the torso rocks back at full fire pulse, radians, spread over the spine.
@export_range(0.0, 0.4, 0.005, "radians_as_degrees") var recoil_lean: float = 0.055
## Fraction of the lean that reaches the head. Under 1 the head stays on target.
@export_range(0.0, 1.0, 0.01) var recoil_head_k: float = 0.35

## Beyond this range from the camera a creature drops from the full solve to the
## reduced one: legs still IK, hands stop tracking the weapon's grips.
@export_range(2.0, 120.0, 0.5, "suffix:m") var reduced_distance: float = 16.0
## Beyond this it drops to the pose-only solve: analytic legs, no IK.
@export_range(4.0, 240.0, 0.5, "suffix:m") var pose_only_distance: float = 38.0
## Solve a reduced creature every Nth tick. Poses are pure functions of absolute
## time, so skipping ticks costs continuity but never drifts out of phase.
@export_range(1, 8, 1) var reduced_tick_divisor: int = 2
## Solve a pose-only creature every Nth tick.
@export_range(1, 16, 1) var pose_only_tick_divisor: int = 4
## Past this range nothing is solved at all and the last pose is held.
@export_range(20.0, 500.0, 1.0, "suffix:m") var cull_distance: float = 140.0

## Fixed 1/120 s collapse steps a budgeted death may run in one call. A collapse
## catching up from t=0 would otherwise run its whole second of sim in one frame,
## and a wave of simultaneous deaths would stall on it.
@export_range(2, 60, 1) var death_steps_per_call: int = 12


## Which solve a creature at `distance` metres deserves.
func lod_for_distance(distance: float) -> Lod:
	if distance < reduced_distance:
		return Lod.FULL
	if distance < pose_only_distance:
		return Lod.REDUCED
	return Lod.POSE_ONLY


## How often that solve needs to run, in ticks.
func tick_divisor(lod: Lod) -> int:
	match lod:
		Lod.REDUCED:
			return reduced_tick_divisor
		Lod.POSE_ONLY:
			return pose_only_tick_divisor
	return 1


## The live tuning, creating the defaults on first use.
static func get_active() -> AnimTuning:
	if active == null:
		active = AnimTuning.new()
	return active
