class_name RigPose
extends RefCounted
## Forward-kinematic bone state for one instantiated rig, held in RIG SPACE.
##
## Rig space is the parent space of the rig root: +Y up, +Z forward, y = 0 is the
## ground. Every IK solve, every foot target and the whole validator work there,
## which is why a wrapper above the root may translate and rotate the creature
## freely without disturbing a single solve.
##
## This deliberately does not use `Node3D` transforms. The reference's IK reads a
## parent's freshly-updated world matrix between writing the parent and writing the
## child; Godot defers node transform propagation, so a node-based port either
## calls `force_update_transform()` a dozen times a frame or solves a forearm
## against last frame's upper arm. A flat parent-before-child array makes the flush
## a partial re-walk of at most a couple of dozen matrices.

## Local rotation about the bone's own pivot, one per bone.
var locals: Array[Quaternion] = []
## Rig-space transform, one per bone. Includes `root`.
var globals: Array[Transform3D] = []
## Rig-space rotation, one per bone, carried alongside `globals`.
##
## Not redundant: an IK solve needs a bone's parent's rig rotation on every joint,
## and extracting one from a `Basis` costs a square root and three branches, where
## accumulating it as a quaternion down the chain costs sixteen multiplies. Keeping
## both makes `update()` cheaper than it was with only the transforms.
var rots: Array[Quaternion] = []
## The rig root's own placement, written by the pose solver each frame.
var root: Transform3D = Transform3D.IDENTITY

var _parents: PackedInt32Array = PackedInt32Array()
var _offsets: PackedVector3Array = PackedVector3Array()
var _count: int = 0


func configure(rig: EnemyRig) -> void:
	_count = rig.bones.size()
	_parents.resize(_count)
	_offsets.resize(_count)
	locals.resize(_count)
	globals.resize(_count)
	rots.resize(_count)
	for i in _count:
		var b: RigBone = rig.bones[i]
		_parents[i] = -1 if b.parent.is_empty() else rig.bone_index(b.parent)
		_offsets[i] = b.offset
	reset()


func size() -> int:
	return _count


## Identity everywhere: the rest pose, root at the origin.
func reset() -> void:
	root = Transform3D.IDENTITY
	for i in _count:
		locals[i] = Quaternion.IDENTITY
	update()


## Recompute rig-space transforms for bones `from` up to but excluding `to`, or to
## the end when `to` is negative. Bones are stored parent-before-child, so a range
## starting at `from` is exactly the affected subtree.
##
## The bound matters: placing the root only has to resolve as far as the hips
## before the pelvis dip can be judged, and everything past them is rewalked again
## once the feet are solved. Bounding the first pass halves the composes on a
## humanoid.
func update(from: int = 0, to: int = -1) -> void:
	var last: int = _count if to < 0 or to > _count else to
	var root_q: Quaternion = root.basis.get_rotation_quaternion()
	for i in range(from, last):
		var p: int = _parents[i]
		if p < 0:
			var q: Quaternion = root_q * locals[i]
			rots[i] = q
			globals[i] = Transform3D(Basis(q), root * _offsets[i])
		else:
			var q: Quaternion = rots[p] * locals[i]
			rots[i] = q
			globals[i] = Transform3D(Basis(q), globals[p] * _offsets[i])


## Slide the whole rig vertically without recomputing a single rotation.
##
## The pelvis dip only ever changes the root's height, and a pure translation of
## the root translates every bone by the same vector — so the second full rewalk
## the reference does after dipping is eighteen transform multiplies for a result
## that is eighteen vector adds.
func shift(delta: Vector3) -> void:
	root.origin += delta
	for i in _count:
		globals[i].origin += delta


## Quaternion of an Euler XYZ triple, without going through a `Basis`.
##
## `Basis.from_euler` builds a 3x3 and `get_rotation_quaternion` then takes it
## apart again with a square root and a three-way branch. Composing the three axis
## quaternions directly is the same rotation for a third of the work, and this runs
## a dozen times per creature per frame.
static func euler_quat(x: float, y: float, z: float) -> Quaternion:
	if y == 0.0 and z == 0.0:
		# Elbows, knees and ankle rolls are all pure X. Half the writes in a pose
		# take this branch and it saves them four transcendentals each.
		return Quaternion(sin(x * 0.5), 0.0, 0.0, cos(x * 0.5))
	var c1: float = cos(x * 0.5)
	var s1: float = sin(x * 0.5)
	var c2: float = cos(y * 0.5)
	var s2: float = sin(y * 0.5)
	var c3: float = cos(z * 0.5)
	var s3: float = sin(z * 0.5)
	return Quaternion(
		s1 * c2 * c3 + c1 * s2 * s3,
		c1 * s2 * c3 - s1 * c2 * s3,
		c1 * c2 * s3 + s1 * s2 * c3,
		c1 * c2 * c3 - s1 * s2 * s3
	)


func origin(i: int) -> Vector3:
	return globals[i].origin


## Fixed offset of a bone from its parent's origin. Bones never translate.
func offset(i: int) -> Vector3:
	return _offsets[i]


## Index of a bone's parent, or -1 for the root.
func parent_index(i: int) -> int:
	return _parents[i]


## Rig-space transform of a bone's parent — the frame `offset` and `locals` live in.
func parent_transform(i: int) -> Transform3D:
	var p: int = _parents[i]
	return root if p < 0 else globals[p]


## Rig-space rotation of a bone's parent — the frame a local rotation is written in.
func parent_rotation(i: int) -> Quaternion:
	var p: int = _parents[i]
	if p < 0:
		return root.basis.get_rotation_quaternion()
	return rots[p]


## Write a bone's local rotation from an Euler XYZ triple. three.js's default order
## is XYZ and Godot's is YXZ; getting that wrong silently mangles every pose.
func set_euler(i: int, x: float, y: float, z: float) -> void:
	if i < 0:
		return
	locals[i] = euler_quat(x, y, z)


## Point a bone's local -Y along `dir_rig`, expressed in rig space.
func aim_bone(i: int, dir_rig: Vector3) -> void:
	if i < 0:
		return
	var q: Quaternion = BeastMath.quat_from_unit_vectors(Vector3(0.0, -1.0, 0.0), dir_rig)
	locals[i] = parent_rotation(i).inverse() * q


## Force a bone's rig-space orientation outright.
func orient_bone(i: int, q_rig: Quaternion) -> void:
	if i < 0:
		return
	locals[i] = parent_rotation(i).inverse() * q_rig


## Point a bone's local -Y along `dir_rig` given its parent's already-known rig
## rotation, and return the rig rotation the bone itself ends up with.
##
## Chaining these is what collapses an IK limb to a single transform rewalk. The
## reference re-flushes the world matrix between writing a hip and aiming a knee
## because the knee's solve reads the hip's fresh world quaternion — but that
## quaternion is exactly what this returns, so the flush is unnecessary: feed bone
## n's result into bone n+1 and update once at the end of the pose.
func aim_bone_from(i: int, dir_rig: Vector3, parent_rot: Quaternion) -> Quaternion:
	if i < 0:
		return parent_rot
	var q: Quaternion = BeastMath.quat_from_unit_vectors(Vector3(0.0, -1.0, 0.0), dir_rig)
	locals[i] = parent_rot.inverse() * q
	return q


## Force a bone's rig-space orientation given its parent's already-known rig
## rotation. The tip of a chain written with `aim_bone_from`.
func orient_bone_from(i: int, q_rig: Quaternion, parent_rot: Quaternion) -> void:
	if i < 0:
		return
	locals[i] = parent_rot.inverse() * q_rig


## Blend a set of bones between two stored local-rotation snapshots. Used to fade
## an aim solve in over the first fifth of an attack instead of snapping to it.
func blend_locals(indices: PackedInt32Array, before: Array[Quaternion], t: float) -> void:
	for k in indices.size():
		var i: int = indices[k]
		if i >= 0:
			locals[i] = before[k].slerp(locals[i], t)


## Snapshot the local rotations of a set of bones.
func capture_locals(indices: PackedInt32Array) -> Array[Quaternion]:
	var out: Array[Quaternion] = []
	out.resize(indices.size())
	for k in indices.size():
		var i: int = indices[k]
		out[k] = locals[i] if i >= 0 else Quaternion.IDENTITY
	return out
