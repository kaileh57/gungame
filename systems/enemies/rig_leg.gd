class_name RigLeg
extends Resource
## One leg chain: hip -> knee -> ankle, plus everything the gait solver measured
## off it at bake time.
##
## Quadruped legs carry no meaningful `side` (the reference omits the field
## entirely); it stays 0.0 there and nothing reads it. Array order is positional
## and load-bearing: `l, r` for bipeds, `lf, rf, lh, rh` for quadrupeds, and the
## attack foot-shuffle indexes it with `i % 2`.

@export var hip: StringName = &""
@export var knee: StringName = &""
@export var ankle: StringName = &""
@export_range(-1.0, 1.0, 1.0) var side: float = 0.0
@export_range(0.0, 1.0, 0.01) var phase: float = 0.0
## Direction the knee is pushed toward. Backward for quadruped forelegs and for
## the sentinel's digitigrade legs, forward for everything else.
@export var pole: Vector3 = Vector3(0.0, 0.0, 1.0)
## Foot X inset relative to the hip.
@export_range(0.4, 1.6, 0.01) var stance_k: float = 1.0
## Extra outboard splay of the foot target. Only the skitter uses it.
@export_range(-0.6, 0.6, 0.005, "suffix:m") var out_x: float = 0.0
@export_range(-0.8, 0.8, 0.005, "suffix:m") var z_off: float = 0.0
## Pelvis-dip allowance as a fraction of leg reach.
@export_range(0.02, 0.40, 0.005) var drop_max_k: float = 0.14
## Ankle roll multiplier.
@export_range(0.0, 2.0, 0.05) var roll_k: float = 1.0
## Whether this foot re-plants during a melee swing.
@export var plant: bool = true

## Plantigrade boot: slab height and its back/front Z edges, used to keep the sole
## flat on the floor as the ankle rolls.
@export var has_sole: bool = false
@export_range(0.0, 0.4, 0.002, "suffix:m") var sole_h: float = 0.0
@export_range(-0.6, 0.6, 0.002, "suffix:m") var sole_zb: float = 0.0
@export_range(-0.6, 0.6, 0.002, "suffix:m") var sole_zf: float = 0.0

## Digitigrade or hoofed: an extra rigid segment past the ankle.
@export var has_pastern: bool = false
@export_range(0.0, 1.0, 0.005, "suffix:m") var pastern_len: float = 0.0
@export_range(0.0, 0.4, 0.002, "suffix:m") var pastern_pad_r: float = 0.0
@export_range(-1.5, 1.5, 0.01, "radians_as_degrees") var pastern_a0: float = 0.0
@export_range(-1.5, 1.5, 0.01, "radians_as_degrees") var pastern_a1: float = 0.0
@export_range(-1.0, 1.0, 1.0) var pastern_dir: float = 1.0

## Measured at bake time from the rest pose.
@export var l1: float = 0.0
@export var l2: float = 0.0
@export var reach: float = 0.0
@export var stand_y: float = 0.0
@export var rest_x: float = 0.0
@export var rest_z: float = 0.0
@export var drop_max: float = 0.0
@export var e_max: float = 0.0
@export var hip_rest: Vector3 = Vector3.ZERO
