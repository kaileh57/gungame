class_name DeathState
extends RefCounted
## The integrator state for one collapse. Seeded from (instance seed, take), so a
## given creature dying take 3 falls exactly the same way every time — which is
## what makes a death replayable, cacheable and testable.
##
## The draw order in `DeathPoser.init_state` is load-bearing. Reordering a single
## `next()` re-rolls every fall in the game.

var take: int = 0
## Simulated time, advanced in fixed 1/120 s steps and never by frame delta.
var t: float = 0.0
## Vertical offset and velocity of the root.
var y: float = 0.0
var vy: float = 0.0
## Compass direction the body topples toward.
var yaw: float = 0.0
## Residual yaw spin, and its accumulated angle.
var spin: float = 0.0
var yaw_spin: float = 0.0
## Tip angle from vertical, and its rate.
var theta: float = 0.0
var omega: float = 0.0
## When the knees give, and how long they take.
var buckle: float = 0.0
var buckle_dur: float = 0.0
## How settled the corpse is: 0 falling, 1 fully down. Damps everything.
var land: float = 0.0
## How far the body sinks into the ground per second once landed. No gap.
var settle: float = 0.0
## Head loll, spine lean and spine twist amounts.
var head_seed: float = 0.0
var lean: float = 0.0
var twist: float = 0.0

var knee_flex: PackedFloat32Array = PackedFloat32Array()
var hip_flex: PackedFloat32Array = PackedFloat32Array()

## Per-arm damped vector springs. Index matches the rig's arm array.
var sh_dir: Array[Vector3] = []
var sh_vel: Array[Vector3] = []
var sh_k: PackedFloat32Array = PackedFloat32Array()
var sh_c: PackedFloat32Array = PackedFloat32Array()
var el_dir: Array[Vector3] = []
var el_vel: Array[Vector3] = []
var el_k: PackedFloat32Array = PackedFloat32Array()
var el_c: PackedFloat32Array = PackedFloat32Array()
