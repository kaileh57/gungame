class_name RigAimHand
extends Resource
## One hand welded onto a shoulder-mounted weapon.
##
## The grip point and the hand orientation are expressed in the WEAPON bone's local
## frame, so the arms follow the gun rather than the gun following the arms. That
## is what puts the rifle in the palm instead of merely near it.

## Index into the rig's arm array.
@export_range(0, 3, 1) var arm: int = 0
## Grip position in the weapon's local frame.
@export var grip: Vector3 = Vector3.ZERO
## Hand Euler XYZ in the weapon's local frame.
@export var hand: Vector3 = Vector3.ZERO
## Elbow pole in the weapon's local frame. Its Y is clamped to at most -0.35 in
## rig space so an elbow never flips up over the shoulder on a steep down-angle.
@export var pole: Vector3 = Vector3(0.0, -1.0, 0.0)
