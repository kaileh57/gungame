class_name RigBone
extends Resource
## One joint. Bones are declared parent-before-child and the whole pipeline —
## forward kinematics, the skin bind poses, the validator's link scan — relies on
## that ordering, so never reorder the array after the fact.

@export var name: StringName = &""
## Empty for the root bone.
@export var parent: StringName = &""
## Offset from the parent's origin, in the parent's frame.
@export var offset: Vector3 = Vector3.ZERO
## Segment length written by `EnemyRig.link`. Zero for a plain bone.
@export_range(0.0, 2.0, 0.001, "or_greater") var length: float = 0.0
## Segment top radius written by `EnemyRig.link`.
@export_range(0.0, 0.5, 0.001, "or_greater") var radius: float = 0.0
