class_name RigArm
extends Resource
## One arm chain: shoulder -> elbow -> wrist.
##
## `arms[0]` is always the left arm (`side = -1`), `arms[1]` the right. Every
## per-species `atk_pose` / `carry_pose` assignment in the roster indexes by
## number, so the order is part of the data contract.
##
## The four-component poses are `(shoulder_x, shoulder_y, shoulder_z, elbow_flex)`.

@export var shoulder: StringName = &""
@export var elbow: StringName = &""
@export var wrist: StringName = &""
@export_range(-1.0, 1.0, 1.0) var side: float = -1.0
@export_range(0.0, 1.0, 0.01) var phase: float = 0.0
## Shoulder rest Euler.
@export var rest: Vector3 = Vector3.ZERO
## Elbow rest flex. The elbow only ever flexes — its pose is `-max(flex, 0)` on X.
@export_range(0.0, 2.4, 0.01, "radians_as_degrees") var elbow_rest: float = 0.26
## Shoulder swing amplitude while walking.
@export_range(0.0, 1.6, 0.01, "radians_as_degrees") var swing: float = 0.52
@export var wrist_rest: Vector3 = Vector3(-0.10, 0.0, 0.0)

## Holds a weapon steady while the rig is aiming.
@export var carry: bool = false
@export var carry_pose: Vector4 = Vector4.ZERO
## Swings during a melee attack.
@export var attack: bool = false
@export var atk_pose: Vector4 = Vector4.ZERO
## Windup: subtracted from the shoulder and added at 80% to the elbow during the
## first 30% of the swing, then released.
@export_range(0.0, 2.0, 0.01, "radians_as_degrees") var atk_wind: float = 0.0

## Measured at bake time from the rest pose.
@export var l1: float = 0.0
@export var l2: float = 0.0
