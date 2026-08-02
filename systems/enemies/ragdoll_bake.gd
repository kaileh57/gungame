class_name RagdollBake
extends RefCounted
## Turns a species rig into a physics ragdoll, ONCE, at bake time.
##
## `tools/build_enemies.gd` is the only caller. Nothing at runtime may reach this
## file: the result is a `PackedScene` saved to `res://data/enemies/ragdolls/<id>.res`
## and `EnemyBody` instantiates that scene, it never rebuilds it.
##
## WHY Skeleton3D + PhysicalBone3D rather than a hand-rolled body chain: the rig
## already IS a skeleton — `build_enemies` emits one `Skeleton3D` whose bone order
## matches `EnemyRig.bones` one for one, and the shell is skinned to it. Godot's
## `PhysicalBoneSimulator3D` writes bone GLOBAL poses straight into that skeleton,
## so the skinned mesh follows a solved ragdoll with no glue code and no second
## representation of the creature. A rigid-body chain the visual rig chases would
## have to re-derive every bone rotation by hand and would drift.
##
## The simulated set is a pruned STRUCTURAL set, not every bone. A tail, a rotor
## and a trigger finger add joints, add solve cost, and change nothing a corpse
## does. Bones that are not simulated keep the local rotation the animation left
## on them and ride their nearest simulated ancestor rigidly, which is what a hand
## or a foot pad does anyway. The one hard rule is that the set is CLOSED UNDER
## ANCESTORS: if the chest is simulated the pelvis must be too, or the pelvis
## geometry stays behind while the chest flies away and the body tears in half.

## Longest simulated chain a species may bake. A body past this drops its
## lightest simulated LEAF bones first — never an ancestor, which would tear the
## body — and nothing in the roster comes close.
const MAX_BONES: int = 24
## Aspect ratio at which a bone's shell is called a limb and gets a capsule rather
## than a box. Below it the shell is a torso, a head or a pelvis.
const CAPSULE_RATIO: float = 1.55
## Smallest half-extent, radius or half-height a ragdoll shape may have. Jolt
## solves sub-centimetre shapes badly and they buy nothing at this scale.
const MIN_EXTENT: float = 0.035
## A bone lighter than this share of the body is not worth a rigid body of its
## own; its mass rolls up into its nearest simulated ancestor.
const MIN_MASS_SHARE: float = 0.004
## Mass clamp, as a share of the whole body. A joint between a 40 kg torso and a
## 0.2 kg forearm is soft and jittery in every solver; pulling the ratio in is
## what buys a settle instead of a shiver.
const MASS_MIN_SHARE: float = 0.020
const MASS_MAX_SHARE: float = 0.340
## Cone-twist limits in DEGREES, keyed by joint role — Godot's
## `joint_constraints/swing_span` and `twist_span` are degrees, not radians.
##
## Every joint is a cone twist, including the knee and the elbow. A hinge would be
## anatomically truer, but the hinge angle's SIGN depends on the solver's frame
## convention and a hinge fitted backwards bends a knee the wrong way — which
## reads as broken in a way a stiff knee never does. A 26 deg cone folds a leg
## under a falling body convincingly and cannot invert it.
const JOINTS: Dictionary = {
	"spine": [24.0, 16.0],
	"neck": [34.0, 22.0],
	"head": [30.0, 26.0],
	"hip": [56.0, 26.0],
	"knee": [26.0, 10.0],
	"ankle": [26.0, 14.0],
	"shoulder": [64.0, 32.0],
	"elbow": [30.0, 12.0],
	"wrist": [30.0, 20.0],
	"held": [10.0, 10.0]
}
## Angular damping per joint role — the single biggest lever on "puppet" versus
## "body". The torso is allowed to keep rotating; the limbs are not.
const ANGULAR_DAMP: Dictionary = {
	"spine": 1.4,
	"neck": 2.2,
	"head": 2.2,
	"hip": 2.6,
	"knee": 3.2,
	"ankle": 3.6,
	"shoulder": 2.6,
	"elbow": 3.2,
	"wrist": 3.6,
	"held": 4.0
}
## Linear damping, applied in REPLACE mode so a level's default area damp cannot
## change how a corpse falls.
const LINEAR_DAMP: float = 0.22
## Contact friction. High: a corpse that slides after it lands looks like a prop.
const FRICTION: float = 0.95
## Restitution. A corpse does not bounce.
const BOUNCE: float = 0.0
## Role given to a bone that was pulled in only to close the set under ancestors.
const DEFAULT_ROLE: String = "spine"


## Bake one species. `stats_mass` is the bestiary's whole-body mass in kg, which
## the per-bone shares are scaled to.
##
## Returns `{scene, bones, mass, shapes}`, or an empty dictionary when the rig has
## too little structure to be worth simulating — a species with one solid bone
## has nothing to hinge and stays on the cheap poser forever.
static func build(inst: RigInstance, script: GDScript, stats_mass: float) -> Dictionary:
	var shells: Array[Dictionary] = inst.bone_shells()
	var roles: Dictionary = _roles(inst)
	var picked: PackedInt32Array = _select(inst, shells, roles)
	if picked.size() < 2:
		return {}
	var kg: Dictionary = _masses(inst, shells, picked, stats_mass)
	var sim := PhysicalBoneSimulator3D.new()
	sim.name = "Ragdoll"
	if script != null:
		sim.set_script(script)
	var nodes: Dictionary = {}
	var capsules: int = 0
	for bi: int in picked:
		var parent_node: Node = sim
		var parent_bone: int = _parent_of(inst, bi)
		if nodes.has(parent_bone):
			parent_node = nodes[parent_bone]
		var role: String = String(roles.get(bi, DEFAULT_ROLE))
		var made: Dictionary = _make_bone(inst, shells[bi], bi, role, float(kg[bi]))
		var pb: PhysicalBone3D = made["node"]
		if bool(made["capsule"]):
			capsules += 1
		if parent_node == sim:
			pb.set(&"joint_type", PhysicalBone3D.JOINT_TYPE_NONE)
		parent_node.add_child(pb)
		nodes[bi] = pb
	_own(sim, sim)
	var packed := PackedScene.new()
	var err: int = packed.pack(sim)
	sim.free()
	if err != OK:
		return {}
	return {"scene": packed, "bones": picked.size(), "mass": stats_mass, "capsules": capsules}


# ------------------------------------------------------------------ selection


## Joint role per bone index. Everything the pose solver names structurally gets
## one; a bone with no role is not simulated unless ancestor closure pulls it in.
static func _roles(inst: RigInstance) -> Dictionary:
	var rig: EnemyRig = inst.rig
	var out: Dictionary = {}
	if not rig.bones.is_empty():
		out[0] = DEFAULT_ROLE
	for tag: StringName in rig.tags.get("spine", []):
		_tag_role(rig, out, tag, "spine")
	_tag_role(rig, out, rig.tags.get("neck", &""), "neck")
	_tag_role(rig, out, rig.tags.get("head", &""), "head")
	for leg in rig.legs:
		_tag_role(rig, out, leg.hip, "hip")
		_tag_role(rig, out, leg.knee, "knee")
		_tag_role(rig, out, leg.ankle, "ankle")
	for arm in rig.arms:
		_tag_role(rig, out, arm.shoulder, "shoulder")
		_tag_role(rig, out, arm.elbow, "elbow")
		_tag_role(rig, out, arm.wrist, "wrist")
	if rig.aim != null:
		_tag_role(rig, out, rig.aim.bone, "held")
	return out


static func _tag_role(rig: EnemyRig, out: Dictionary, bone: StringName, role: String) -> void:
	if bone.is_empty():
		return
	var i: int = rig.bone_index(bone)
	if i >= 0:
		out[i] = role


## The simulated set, ascending. Roles that carry solid geometry and enough mass
## to matter, closed under ancestors, then trimmed to `MAX_BONES` by dropping the
## lightest LEAF — dropping an ancestor would separate the body.
static func _select(
	inst: RigInstance, shells: Array[Dictionary], roles: Dictionary
) -> PackedInt32Array:
	var total: float = 0.0
	for s in shells:
		total += float(s["mass"])
	var keep: Dictionary = {}
	for bi: int in roles.keys():
		if not bool(shells[bi]["solid"]):
			continue
		if total > 0.0 and float(shells[bi]["mass"]) / total < MIN_MASS_SHARE:
			continue
		keep[bi] = true
	if keep.is_empty():
		return PackedInt32Array()
	for bi: int in keep.keys().duplicate():
		var walk: int = _parent_of(inst, bi)
		while walk >= 0 and not keep.has(walk):
			keep[walk] = true
			walk = _parent_of(inst, walk)
	while keep.size() > MAX_BONES:
		var drop: int = _lightest_leaf(inst, shells, keep)
		if drop < 0:
			break
		keep.erase(drop)
	var out: Array[int] = []
	for bi: int in keep.keys():
		out.append(bi)
	out.sort()
	return PackedInt32Array(out)


## Lightest simulated bone with no simulated child, or -1 when every kept bone is
## an ancestor of another.
static func _lightest_leaf(inst: RigInstance, shells: Array[Dictionary], keep: Dictionary) -> int:
	var has_child: Dictionary = {}
	for bi: int in keep.keys():
		var p: int = _parent_of(inst, bi)
		if keep.has(p):
			has_child[p] = true
	var best: int = -1
	var best_mass: float = INF
	for bi: int in keep.keys():
		if has_child.has(bi):
			continue
		var m: float = float(shells[bi]["mass"])
		if m < best_mass:
			best_mass = m
			best = bi
	return best


static func _parent_of(inst: RigInstance, bone: int) -> int:
	if bone < 0 or bone >= inst.rig.bones.size():
		return -1
	return inst.rig.bone_index(inst.rig.bones[bone].parent)


## Kilograms per simulated bone. Every bone's raw shell mass is attributed to its
## nearest simulated ancestor-or-self, so a hand's weight reaches the forearm that
## carries it. Shares are then clamped and renormalised: a solver given a 200:1
## mass ratio across one joint shivers instead of settling, and the clamp is worth
## more than the two percent of realism it costs.
static func _masses(
	inst: RigInstance, shells: Array[Dictionary], picked: PackedInt32Array, stats_mass: float
) -> Dictionary:
	var sim: Dictionary = {}
	for bi: int in picked:
		sim[bi] = 0.0
	for bi in inst.rig.bones.size():
		var walk: int = bi
		while walk >= 0 and not sim.has(walk):
			walk = _parent_of(inst, walk)
		if walk < 0:
			walk = picked[0]
		sim[walk] = float(sim[walk]) + float(shells[bi]["mass"])
	var total: float = 0.0
	for bi: int in picked:
		total += float(sim[bi])
	var clamped: float = 0.0
	for bi: int in picked:
		var share: float = 1.0 / float(picked.size())
		if total > 0.0:
			share = float(sim[bi]) / total
		share = clampf(share, MASS_MIN_SHARE, MASS_MAX_SHARE)
		sim[bi] = share
		clamped += share
	var body: float = maxf(stats_mass, 1.0)
	for bi: int in picked:
		sim[bi] = maxf(float(sim[bi]) / maxf(clamped, 1e-6) * body, 0.2)
	return sim


# ------------------------------------------------------------------ assembly


## One rigid body: its shape, where it sits relative to its bone, where its joint
## sits, and how hard that joint is allowed to bend.
static func _make_bone(
	inst: RigInstance, shell: Dictionary, bone: int, role: String, kg: float
) -> Dictionary:
	var box: AABB = shell["box"]
	if not bool(shell["solid"]):
		box = AABB(Vector3.ONE * -MIN_EXTENT, Vector3.ONE * MIN_EXTENT * 2.0)
	var fit: Dictionary = _fit_shape(box)
	var body_offset := Transform3D(fit["basis"], box.get_center())

	var pb := PhysicalBone3D.new()
	pb.name = String(inst.rig.bones[bone].name)
	pb.set(&"bone_name", String(inst.rig.bones[bone].name))
	pb.mass = kg
	pb.friction = FRICTION
	pb.bounce = BOUNCE
	pb.linear_damp_mode = PhysicalBone3D.DAMP_MODE_REPLACE
	pb.linear_damp = LINEAR_DAMP
	pb.angular_damp_mode = PhysicalBone3D.DAMP_MODE_REPLACE
	pb.angular_damp = float(ANGULAR_DAMP.get(role, 2.4))
	pb.can_sleep = true
	# Corpses answer to the world and to props, and to nothing else. Self-collision
	# on a rig whose primitives deliberately OVERLAP at every joint would explode
	# the body on frame one, and corpse-on-corpse contact buys a pile nobody looks
	# at for a solve cost that scales with the square of the wave.
	pb.collision_layer = 0
	pb.collision_mask = GameLayers.WORLD | GameLayers.PROP
	pb.body_offset = body_offset
	pb.set(&"joint_type", PhysicalBone3D.JOINT_TYPE_CONE)
	pb.joint_offset = (
		body_offset.affine_inverse() * Transform3D(_joint_basis(box, fit), Vector3.ZERO)
	)
	var limits: Array = JOINTS.get(role, JOINTS["spine"])
	pb.set(&"joint_constraints/swing_span", float(limits[0]))
	pb.set(&"joint_constraints/twist_span", float(limits[1]))

	var col := CollisionShape3D.new()
	col.name = "Shape"
	col.shape = fit["shape"]
	pb.add_child(col)
	return {"node": pb, "capsule": fit["capsule"]}


## Pick a collision shape for a bone's welded shell. A long thin shell is a limb
## and gets a capsule whose +Y runs down it; anything squarer is a torso, a head
## or a pelvis and gets the box itself.
static func _fit_shape(box: AABB) -> Dictionary:
	var e := Vector3(
		maxf(box.size.x * 0.5, MIN_EXTENT),
		maxf(box.size.y * 0.5, MIN_EXTENT),
		maxf(box.size.z * 0.5, MIN_EXTENT)
	)
	var axis: int = 1
	if e.x >= e.y and e.x >= e.z:
		axis = 0
	elif e.z >= e.x and e.z >= e.y:
		axis = 2
	var long_half: float = e[axis]
	var wide: float = 0.0
	for i in 3:
		if i != axis:
			wide = maxf(wide, e[i])
	if long_half / maxf(wide, 1e-4) >= CAPSULE_RATIO:
		var cap := CapsuleShape3D.new()
		cap.radius = maxf(wide, MIN_EXTENT)
		cap.height = maxf(long_half * 2.0, cap.radius * 2.0 + 0.02)
		return {"shape": cap, "basis": _axis_basis(axis), "capsule": true, "axis": axis}
	var b := BoxShape3D.new()
	b.size = e * 2.0
	return {"shape": b, "basis": Basis.IDENTITY, "capsule": false, "axis": axis}


## Rotation taking local +Y onto the box's longest axis, so a capsule lies along
## the limb it clothes.
static func _axis_basis(axis: int) -> Basis:
	if axis == 0:
		return Basis(Vector3(0.0, 0.0, 1.0), -PI * 0.5)
	if axis == 2:
		return Basis(Vector3(1.0, 0.0, 0.0), PI * 0.5)
	return Basis.IDENTITY


## Frame the cone twist is measured in, expressed in the BONE's own space.
##
## Godot's cone-twist takes its TWIST about the joint frame's X axis and swings
## about the other two, so X has to point down the limb or the cone opens
## sideways and a knee that should fold locks rigid instead. The limb direction is
## read off the geometry — the vector from the bone's pivot to its shell centre —
## which is exactly "down the bone" for every segment `EnemyRig.link` emits, and
## falls back to the shell's own long axis for a ball centred on its pivot.
static func _joint_basis(box: AABB, fit: Dictionary) -> Basis:
	var xa: Vector3 = box.get_center()
	if xa.length() < 1e-3:
		xa = _axis_basis(int(fit["axis"])) * Vector3.UP
	xa = xa.normalized()
	if not xa.is_finite() or xa.length_squared() < 0.5:
		xa = Vector3.DOWN
	var up := Vector3.UP if absf(xa.y) < 0.9 else Vector3.FORWARD
	var za: Vector3 = xa.cross(up).normalized()
	var ya: Vector3 = za.cross(xa).normalized()
	return Basis(xa, ya, za)


static func _own(node: Node, root: Node) -> void:
	for c in node.get_children():
		c.owner = root
		_own(c, root)
