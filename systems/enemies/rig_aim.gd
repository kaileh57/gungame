class_name RigAim
extends Resource
## How an armed rig points its weapon. Three modes, one per mounting style.
##
## `shoulder` — the weapon has its own bone butted into the shoulder pocket. The
##   frame swings about that anchor and both hands are solved onto its grips.
## `hand` — the weapon is geometry on a wrist. The wrist is placed on the aim line
##   first, then oriented outright.
## `turret` — a yaw/pitch mount, solved iteratively because the muzzle offset moves
##   as the head turns.
##
## A rig with no `RigAim` is a melee rig, and that single fact selects the whole
## melee branch of the pose solver.

const MODE_SHOULDER: StringName = &"shoulder"
const MODE_HAND: StringName = &"hand"
const MODE_TURRET: StringName = &"turret"

@export var mode: StringName = MODE_SHOULDER
## Weapon bone, for `shoulder` mode.
@export var bone: StringName = &""
## Yaw/pitch mount bone, for `turret` mode.
@export var yaw_bone: StringName = &""
## Index of the weapon arm, for `hand` mode.
@export_range(0, 3, 1) var arm: int = 0
## Muzzle offset in the weapon bone's local frame.
@export var muzzle: Vector3 = Vector3.ZERO
## Bore direction in the weapon bone's local frame.
@export var fwd: Vector3 = Vector3(0.0, 0.0, 1.0)
## The weapon's own up, levelled against vertical about the bore.
@export var up: Vector3 = Vector3(0.0, 1.0, 0.0)
## Authored twist about the bore, applied in weapon space.
@export_range(-3.15, 3.15, 0.01, "radians_as_degrees") var roll: float = 0.0
## Elbow pole for `hand` mode. Only its X is read; the solver forces (-1, -0.35).
@export var pole: Vector3 = Vector3(0.7, -1.0, -0.35)
## Fraction of full arm reach the wrist is pushed out to, for `hand` mode.
@export_range(0.3, 1.0, 0.01) var hold: float = 0.80
## Wrist drop as a fraction of arm reach, faded out as the aim goes vertical.
@export_range(-0.5, 0.5, 0.005) var drop: float = 0.0
## Forward offset of the notional eye, used to compute azimuth and elevation.
@export_range(-1.0, 1.0, 0.005, "suffix:m") var eye_z: float = 0.0
@export var yaw_limits: Vector2 = Vector2(-PI, PI)
@export var pitch_limits: Vector2 = Vector2(-1.3, 1.3)
## Which way the weapon whips under recoil. Set per species so a left-handed
## mount does not kick across the shooter's own face.
@export_range(-1.0, 1.0, 1.0) var recoil_side: float = 1.0
@export var hands: Array[RigAimHand] = []
