class_name RigInstance
extends RefCounted
## One posed creature: a rig, its bone state, and every index the solvers would
## otherwise look up by name each frame.
##
## Everything hot is resolved once in `setup()` — bone indices, part-to-bone
## mapping, the local transform of every primitive, and the fx/core masks. The
## pose solver then runs without a single string lookup or allocation, which is
## what lets sixty of these animate inside a frame budget.

## Bones whose geometry is ignored when judging floor contact during a collapse.
var core_mask: PackedByteArray = PackedByteArray()

var rig: EnemyRig = null
var pose: RigPose = null
## The species' derived combat record, copied off the rig. See `EnemyRig.stats`.
var stats: Resource = null
var gait: Dictionary = {}

## Explicit aim point in rig space. Overrides the clip's own rehearsal path.
var aim_target: Vector3 = Vector3.ZERO
var has_aim: bool = false
## Metres per second the root would be covering in the current clip.
var travel: float = 0.0
## Seeds the death collapse. Same seed and take reproduce a fall frame for frame.
var seed_value: int = 1013
var death_take: int = 0
var death_state: DeathState = null
## Cap the collapse to a fixed number of fixed steps per call, so a wave of
## simultaneous deaths cannot spike a frame. The bake leaves this off and runs the
## sim to completion.
var death_budgeted: bool = false
## Muzzle flare intensity written by the last pose, in [0, 1].
var flash_pulse: float = 0.0

var part_bone: PackedInt32Array = PackedInt32Array()
var part_local: Array[Transform3D] = []
var part_fx: PackedByteArray = PackedByteArray()
var fx_parts: PackedInt32Array = PackedInt32Array()

var spine_idx: PackedInt32Array = PackedInt32Array()
var head_idx: int = -1
var neck_idx: int = -1
var leg_hip: PackedInt32Array = PackedInt32Array()
var leg_knee: PackedInt32Array = PackedInt32Array()
var leg_ankle: PackedInt32Array = PackedInt32Array()
var arm_sh: PackedInt32Array = PackedInt32Array()
var arm_el: PackedInt32Array = PackedInt32Array()
var arm_wr: PackedInt32Array = PackedInt32Array()
var wag_idx: PackedInt32Array = PackedInt32Array()
var spin_idx: PackedInt32Array = PackedInt32Array()
var aim_bone_idx: int = -1
var aim_yaw_idx: int = -1

## Solid (non-fx) part indices per bone, and the bones whose joint the audit can
## actually judge — both sides must carry geometry for an overlap to mean anything.
var _bone_parts: Array[PackedInt32Array] = []
var _parent_bone: PackedInt32Array = PackedInt32Array()
var _linked_bones: PackedInt32Array = PackedInt32Array()


func setup(source: EnemyRig) -> void:
	rig = source
	gait = source.gait
	stats = source.stats
	pose = RigPose.new()
	pose.configure(source)
	_index_parts()
	_index_bones()
	_index_links()


## Rig-space transform of every primitive, in declaration order.
func part_matrices() -> Array[Transform3D]:
	var out: Array[Transform3D] = []
	var n: int = part_bone.size()
	out.resize(n)
	for i in n:
		out[i] = pose.globals[part_bone[i]] * part_local[i]
	return out


## The no-gap audit, evaluated on the pose currently loaded.
##
## For every bone that has a parent, take the BEST overlap between any solid part
## on that bone and any solid part on its parent — one welded pair is enough to
## seal a joint. `min_link` is the worst of those bests over the whole body: "how
## much does the loosest joint still overlap?". It must stay strictly positive.
## `floating` counts joints whose best overlap has gone to zero or below, which
## means a limb has separated from the body — ship-blocking, never non-zero.
## `worst_bone` names the loosest joint so a failure points at itself.
##
## `link()` and `tube()` are what keep this positive: the pivot ball's centre
## cannot move relative to the parent under any local rotation, so its overlap
## with the parent's shell is a rotation-invariant constant.
func link_report() -> Dictionary:
	var mats: Array[Transform3D] = part_matrices()
	var prims: Array[Dictionary] = []
	prims.resize(part_bone.size())
	for i in part_bone.size():
		if part_fx[i] == 0:
			prims[i] = BeastCollide.world_prim(rig.parts[i], mats[i])
	var worst: float = INF
	var worst_bone: StringName = &""
	var floating: int = 0
	for j in _linked_bones.size():
		var bi: int = _linked_bones[j]
		var kids: PackedInt32Array = _bone_parts[bi]
		var par: PackedInt32Array = _bone_parts[_parent_bone[bi]]
		var best: float = -INF
		for k in kids:
			for p in par:
				best = maxf(best, BeastCollide.penetration(prims[k], prims[p]))
		if best <= 0.0:
			floating += 1
		if best < worst:
			worst = best
			worst_bone = rig.bones[bi].name
	if worst == INF:
		worst = 0.0
	return {"min_link": worst, "floating": floating, "worst_bone": worst_bone}


## Lowest rig-space Y over the posed shell. `core_only` skips the limb bones so an
## arm flung under the body cannot jack a corpse off the floor — it just clips.
func lowest_point(core_only: bool) -> float:
	var lo: float = INF
	for i in part_bone.size():
		if part_fx[i] != 0:
			continue
		if core_only and core_mask[i] == 0:
			continue
		var p: RigPart = rig.parts[i]
		var m: Transform3D = pose.globals[part_bone[i]] * part_local[i]
		lo = minf(lo, BeastCollide.prim_low_y(BeastCollide.world_prim(p, m)))
	return lo


## Per-bone solid shell: the bone-local bounding box of everything welded to that
## bone, and the mass that geometry carries.
##
## One entry per bone, in bone order. `solid` is false for a bone that carries no
## non-fx primitive at all — a pure pivot — and its box and mass are meaningless.
##
## The box is expressed in the BONE's own frame, which makes it a rest-pose
## quantity that stays correct in every pose: a part never moves relative to its
## bone. Mass is RAW volume times density — the same product `EnemyStats.derive`
## sums, but without its whole-body `MASS_FUDGE`, because the overlap that fudge
## corrects for is not distributed evenly over the bones. A caller that wants the
## bestiary's mass should scale these by `stats.mass / sum`, which is exact and
## does not drag the stats module into the rig core.
func bone_shells() -> Array[Dictionary]:
	var n: int = rig.bones.size()
	var lows: PackedVector3Array = PackedVector3Array()
	var highs: PackedVector3Array = PackedVector3Array()
	var mass: PackedFloat32Array = PackedFloat32Array()
	var solid: PackedByteArray = PackedByteArray()
	lows.resize(n)
	highs.resize(n)
	mass.resize(n)
	solid.resize(n)
	for i in part_bone.size():
		var b: int = part_bone[i]
		if part_fx[i] != 0 or b < 0:
			continue
		var p: RigPart = rig.parts[i]
		var m: Transform3D = part_local[i]
		var e: Vector3 = p.extent()
		mass[b] += p.volume() * rig.density_of(p)
		for k in 8:
			var pt: Vector3 = (
				m
				* Vector3(
					e.x if (k & 1) != 0 else -e.x,
					e.y if (k & 2) != 0 else -e.y,
					e.z if (k & 4) != 0 else -e.z
				)
			)
			if solid[b] == 0:
				lows[b] = pt
				highs[b] = pt
				solid[b] = 1
			else:
				lows[b] = lows[b].min(pt)
				highs[b] = highs[b].max(pt)
	var out: Array[Dictionary] = []
	out.resize(n)
	for b in n:
		out[b] = {"solid": solid[b] != 0, "box": AABB(lows[b], highs[b] - lows[b]), "mass": mass[b]}
	return out


## Rig-space muzzle position and bore direction, or an empty dictionary for an
## unarmed rig.
func muzzle() -> Dictionary:
	var a: RigAim = rig.aim
	if a == null:
		return {}
	var idx: int = _muzzle_bone()
	if idx < 0:
		return {}
	var m: Transform3D = pose.globals[idx]
	return {"origin": m * a.muzzle, "dir": (m.basis * a.fwd).normalized()}


## Residual angle in radians between where the muzzle points and where it was
## told to point. Feed this into a hit roll rather than inventing a spread cone.
func aim_error(target: Vector3) -> float:
	var mz: Dictionary = muzzle()
	if mz.is_empty():
		return 0.0
	var to_target: Vector3 = (target - Vector3(mz["origin"])).normalized()
	return acos(clampf(Vector3(mz["dir"]).dot(to_target), -1.0, 1.0))


func _muzzle_bone() -> int:
	var a: RigAim = rig.aim
	match a.mode:
		RigAim.MODE_SHOULDER:
			return aim_bone_idx
		RigAim.MODE_TURRET:
			return aim_yaw_idx
	if a.arm < arm_wr.size():
		return arm_wr[a.arm]
	return -1


func _index_parts() -> void:
	var n: int = rig.parts.size()
	part_bone.resize(n)
	part_local.resize(n)
	part_fx.resize(n)
	core_mask.resize(n)
	var limbs: Dictionary = rig.limb_bones()
	var fx: Array[int] = []
	for i in n:
		var p: RigPart = rig.parts[i]
		part_bone[i] = rig.bone_index(p.bone)
		part_local[i] = p.local_transform()
		var is_fx: bool = BeastMat.is_fx(p.mat)
		part_fx[i] = 1 if is_fx else 0
		core_mask[i] = 0 if (is_fx or limbs.has(p.bone)) else 1
		if is_fx:
			fx.append(i)
	fx_parts = PackedInt32Array(fx)


func _index_links() -> void:
	var n: int = rig.bones.size()
	var buckets: Array[Array] = []
	buckets.resize(n)
	for i in n:
		buckets[i] = []
	for i in part_bone.size():
		if part_fx[i] == 0 and part_bone[i] >= 0:
			buckets[part_bone[i]].append(i)
	_bone_parts.resize(n)
	_parent_bone.resize(n)
	var linked: Array[int] = []
	for i in n:
		_bone_parts[i] = PackedInt32Array(buckets[i])
		_parent_bone[i] = rig.bone_index(rig.bones[i].parent)
	for i in n:
		var p: int = _parent_bone[i]
		if p >= 0 and not _bone_parts[i].is_empty() and not _bone_parts[p].is_empty():
			linked.append(i)
	_linked_bones = PackedInt32Array(linked)


func _index_bones() -> void:
	var spine: Array = rig.tags.get("spine", [])
	spine_idx.resize(spine.size())
	for i in spine.size():
		spine_idx[i] = rig.bone_index(spine[i])
	head_idx = rig.bone_index(rig.tags.get("head", &""))
	neck_idx = rig.bone_index(rig.tags.get("neck", &""))
	var legs: int = rig.legs.size()
	leg_hip.resize(legs)
	leg_knee.resize(legs)
	leg_ankle.resize(legs)
	for i in legs:
		leg_hip[i] = rig.bone_index(rig.legs[i].hip)
		leg_knee[i] = rig.bone_index(rig.legs[i].knee)
		leg_ankle[i] = rig.bone_index(rig.legs[i].ankle)
	var arms: int = rig.arms.size()
	arm_sh.resize(arms)
	arm_el.resize(arms)
	arm_wr.resize(arms)
	for i in arms:
		arm_sh[i] = rig.bone_index(rig.arms[i].shoulder)
		arm_el[i] = rig.bone_index(rig.arms[i].elbow)
		arm_wr[i] = rig.bone_index(rig.arms[i].wrist)
	var wags: Array = rig.tags.get("wags", [])
	wag_idx.resize(wags.size())
	for i in wags.size():
		wag_idx[i] = rig.bone_index(wags[i]["b"])
	var spins: Array = rig.tags.get("spin", [])
	spin_idx.resize(spins.size())
	for i in spins.size():
		spin_idx[i] = rig.bone_index(spins[i]["b"])
	if rig.aim != null:
		aim_bone_idx = rig.bone_index(rig.aim.bone)
		aim_yaw_idx = rig.bone_index(rig.aim.yaw_bone)
