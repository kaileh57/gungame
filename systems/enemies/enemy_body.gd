class_name EnemyBody
extends Node3D
## The animated shell of one creature: baked mesh in, bone rotations out.
##
## This node is the root of every `res://data/enemies/<id>.res` scene the bake
## emits. It owns no geometry of its own — `res://tools/build_enemies.gd` merged
## the species' primitives per material into a single skinned `ArrayMesh` and
## saved it as a child. At runtime the only per-frame work is evaluating the pose
## solver and writing one quaternion per bone, which is why sixty of these fit in
## a frame.
##
## A pose is a pure function of (clip, absolute time, take). Nothing here
## integrates a phase accumulator, so a body that skips ten frames at distance
## resumes on exactly the pose it would have reached had it never skipped. That is
## what makes the distance LOD below free rather than a source of drift.

## The clip reached its end. Never emitted for `idle`, `walk`, `run` or `aim`,
## which are unbounded.
signal clip_finished(clip: StringName)
## The collapse has settled: the corpse is on the floor and no longer moving.
signal collapse_settled

## Clip time past which a collapse is considered finished. The sim keeps running
## after this, but nothing visible changes.
const COLLAPSE_SETTLE_TIME: float = 2.4
## Seconds between LOD re-evaluations. Cheaper than testing every frame and far
## finer than any distance an enemy covers in that time.
const LOD_REFRESH: float = 0.25

@export_group("Species")
@export var species_id: StringName = &""
## The skeleton and welded shell this body animates. Written by the bake.
@export var species_rig: EnemyRig = null
## Mass, health, reach, tier — derived once at bake time, never recomputed.
@export var species_stats: EnemyStats = null
## Damage zone per bone, in bone order. Baked flat so resolving a hit is one
## array read: `head`, `core` or `limb`.
@export var bone_zones: Array[StringName] = []

@export_group("Nodes")
## Skeleton whose bone order matches `species_rig.bones` one for one.
@export var skeleton_path: NodePath = NodePath("Skeleton")
## Skinned mesh instances that carry the faction tint.
@export var shell_paths: Array[NodePath] = []
## Muzzle-flare meshes, one per bone that carries flare geometry. Held at zero
## scale until a shot inflates them.
@export var flash_paths: Array[NodePath] = []

@export_group("Animation")
## Full pose rate inside this distance, in metres.
@export_range(0.0, 200.0, 0.5) var lod_near: float = 18.0
## Beyond this distance the body poses at `pose_hz_far`.
@export_range(0.0, 400.0, 0.5) var lod_far: float = 55.0
## Poses per second within `lod_near`. Zero means every frame.
@export_range(0.0, 120.0, 1.0) var pose_hz_near: float = 0.0
## Poses per second between `lod_near` and `lod_far`.
@export_range(1.0, 60.0, 1.0) var pose_hz_mid: float = 24.0
## Poses per second past `lod_far`.
@export_range(1.0, 60.0, 1.0) var pose_hz_far: float = 8.0
## Peak scale of the muzzle flare geometry, which is baked at unit size.
@export_range(0.0, 4.0, 0.01) var flash_scale: float = 1.0

@export_group("Ragdoll")
## The baked physics corpse for this species, from `RagdollBake`. Null falls the
## whole species back on `DeathPoser`.
@export var ragdoll_scene: PackedScene = null
## Master switch. Off is the pre-ragdoll behaviour, exactly.
@export var ragdoll_enabled: bool = true
## HARD cap on creatures solving a ragdoll at once, process-wide. Deaths past it
## take the cheap poser. This is the number that keeps a hundred-body firefight at
## frame rate, so raise it deliberately.
@export_range(0, 32, 1) var ragdoll_max_active: int = 8
## Past this distance from the camera a death is not worth a solver — the poser
## reads identically at range and costs a thousandth as much.
@export_range(0.0, 400.0, 1.0, "suffix:m") var ragdoll_distance: float = 45.0
## Gravity multiplier handed to the corpse, overriding the baked value.
@export_range(0.25, 6.0, 0.05) var ragdoll_gravity_scale: float = 1.85
## Longest a physics corpse may go unsettled before it is declared down anyway, so
## a body wedged in geometry still gets recycled.
@export_range(1.0, 40.0, 0.5, "suffix:s") var ragdoll_timeout: float = 8.0

@export_group("Reactions")
## Fraction of maximum health a single hit must remove to break the current clip
## into a stagger.
@export_range(0.0, 1.0, 0.01) var stagger_fraction: float = 0.14
## Staggers are suppressed for this long after one plays, so a burst cannot lock a
## body in a flinch loop.
@export_range(0.0, 4.0, 0.05) var stagger_refractory: float = 0.9

var _inst: RigInstance = null
var _skel: Skeleton3D = null
var _shells: Array[MeshInstance3D] = []
var _flashes: Array[Node3D] = []
var _bone_count: int = 0
var _clip: StringName = BeastClips.IDLE
var _clip_t: float = 0.0
var _clip_len: float = 0.0
var _clip_ended: bool = false
var _dead: bool = false
var _settled: bool = false
var _resume_clip: StringName = BeastClips.IDLE
var _stagger_lock: float = 0.0
var _tint: Color = Color.WHITE
var _pose_accum: float = 0.0
var _pose_interval: float = 0.0
var _lod_timer: float = 0.0
var _camera: Camera3D = null
var _rag: Ragdoll = null
var _rag_claimed: bool = false


func _ready() -> void:
	_resolve_nodes()
	if species_rig == null:
		push_error("EnemyBody '%s' has no rig; it will not animate." % name)
		set_process(false)
		return
	_inst = RigInstance.new()
	_inst.setup(species_rig)
	_inst.stats = species_stats
	var skel_bones: int = 0 if _skel == null else _skel.get_bone_count()
	_bone_count = mini(species_rig.bones.size(), skel_bones)
	if _skel != null and skel_bones != species_rig.bones.size():
		push_error(
			(
				"EnemyBody '%s': skeleton has %d bones, rig has %d. Re-run build_enemies."
				% [name, skel_bones, species_rig.bones.size()]
			)
		)
	_clip_len = BeastClips.length_of(_clip)
	_apply_pose()


## Hand any held ragdoll slot back on the way out.
##
## `RagdollBudget` is a process-wide count and a demo that reloads its level frees
## its creatures without ever calling `sleep()`. Without this, every corpse that
## was still solving at the moment of the reload leaks its slot and the cap fills
## up permanently — after two reloads nothing ragdolls again.
func _exit_tree() -> void:
	_release_ragdoll_slot()


func _process(delta: float) -> void:
	_stagger_lock = maxf(0.0, _stagger_lock - delta)
	_clip_t += delta
	_advance_clip_end()
	_lod_timer -= delta
	if _lod_timer <= 0.0:
		_lod_timer = LOD_REFRESH
		_refresh_lod()
	if _pose_interval <= 0.0:
		_apply_pose()
		return
	_pose_accum += delta
	if _pose_accum < _pose_interval:
		return
	_pose_accum = 0.0
	_apply_pose()


## Play `name`, which must be one of `BeastClips.CLIPS`. Re-requesting the clip
## that is already running is ignored rather than restarting it, so a brain that
## asks for `walk` every tick does not freeze the legs on frame zero.
func play_clip(name: String) -> void:
	var clip := StringName(name)
	if not BeastClips.CLIPS.has(clip):
		push_error("EnemyBody '%s': unknown clip '%s'." % [self.name, name])
		return
	if clip == _clip:
		return
	if _dead and clip != BeastClips.DEATH:
		return
	if _is_interruptible(_clip):
		_resume_clip = _clip
	_clip = clip
	_clip_t = 0.0
	_clip_len = BeastClips.length_of(clip)
	_clip_ended = false
	_pose_accum = _pose_interval
	if clip == BeastClips.DEATH:
		_dead = true
		_settled = false
	_apply_pose()


## Point the weapon — or the head, on an unarmed rig — at a world position. The
## target survives clip changes; call `clear_aim()` to hand control back to the
## clip's own rehearsal path.
func aim_at(world_pos: Vector3) -> void:
	if _inst == null:
		return
	_inst.aim_target = to_local(world_pos)
	_inst.has_aim = true


## Drop the explicit aim target.
func clear_aim() -> void:
	if _inst != null:
		_inst.has_aim = false


## World-space bore origin. Falls back to the head, then to the body origin, so a
## melee species still answers with something a tracer can start from.
func muzzle_point() -> Vector3:
	if _inst == null:
		return global_position
	var mz: Dictionary = _inst.muzzle()
	if not mz.is_empty():
		return to_global(Vector3(mz["origin"]))
	if _inst.head_idx >= 0:
		return to_global(_inst.pose.globals[_inst.head_idx].origin)
	return global_position


## World-space bore direction, normalised. `-Z` of the body when unarmed.
func muzzle_direction() -> Vector3:
	if _inst == null:
		return -global_basis.z
	var mz: Dictionary = _inst.muzzle()
	if mz.is_empty():
		return -global_basis.z
	return (global_basis * Vector3(mz["dir"])).normalized()


## Faction wash over the whole shell. One instance uniform, no per-body material.
func set_faction_color(c: Color) -> void:
	_tint = c
	for m in _shells:
		m.set_instance_shader_parameter(&"tint", c)


## Residual angle in radians between the bore and a world point. Feed this to a
## hit roll instead of inventing a spread cone: it is the error the rig actually
## has, including the frames where the arms have not caught up yet.
func aim_error(world_pos: Vector3) -> float:
	if _inst == null:
		return 0.0
	return _inst.aim_error(to_local(world_pos))


## Metres per second the current clip's stride implies. Drive the actor's
## locomotion with this and the feet never skate.
func clip_travel() -> float:
	return _inst.travel if _inst != null else 0.0


## Break into a flinch if the hit was heavy enough and the body is not already
## flinching. Returns true when the stagger actually played.
func react_to_hit(damage: float, max_health: float) -> bool:
	if _dead or _stagger_lock > 0.0 or max_health <= 0.0:
		return false
	if damage / max_health < stagger_fraction:
		return false
	_stagger_lock = stagger_refractory
	play_clip(String(BeastClips.STAGGER))
	return true


## Start the collapse with no known killing shot. `take` picks one of the seeded
## falls; -1 keeps the take the instance was seeded with.
func collapse(take: int = -1) -> void:
	collapse_from(Vector3.ZERO, 0.0, global_position, Vector3.ZERO, take)


## Start the collapse from the round that ended it.
##
## `dir` is the round's unit direction and `newtons` its impulse in newton-seconds;
## `point` is where it landed, so the push arrives on the bone it actually hit —
## a head shot spins the body, a hit in the hip drops it. `momentum` is the
## velocity the creature was carrying, so a sprinter's corpse keeps going.
##
## Two tiers, and the choice is made here. Near the camera and inside the ragdoll
## budget, the body is handed to physics and this node stops processing entirely.
## Otherwise it takes `DeathPoser` — the seeded, hand-authored collapse — which at
## distance reads the same and costs a thousandth as much. `take` still seeds the
## poser, so a far death is as reproducible as it ever was.
func collapse_from(
	dir: Vector3, newtons: float, point: Vector3, momentum: Vector3, take: int = -1
) -> void:
	if _dead:
		return
	if _inst != null:
		_inst.death_state = null
		if take >= 0:
			_inst.death_take = take
	if _begin_ragdoll(dir, newtons, point, momentum):
		return
	play_clip(String(BeastClips.DEATH))


## True while this corpse is a physics ragdoll rather than a posed collapse.
func is_ragdolling() -> bool:
	return _rag != null


## Take a ragdoll slot and hand the body to physics. False means "not this death"
## — no scene, too far, or the cap is full — and the caller falls back.
func _begin_ragdoll(dir: Vector3, newtons: float, point: Vector3, momentum: Vector3) -> bool:
	if not ragdoll_enabled or ragdoll_scene == null or _skel == null or _inst == null:
		return false
	if _camera_distance() > ragdoll_distance:
		return false
	if not RagdollBudget.claim(ragdoll_max_active):
		return false
	var node := ragdoll_scene.instantiate() as Ragdoll
	if node == null:
		RagdollBudget.release()
		push_error("EnemyBody '%s': ragdoll_scene is not a Ragdoll." % name)
		return false
	# Both are read by the corpse's own `_ready`, so they have to be set before it
	# joins the tree.
	node.gravity_scale = ragdoll_gravity_scale
	node.max_solve_time = ragdoll_timeout
	_rag = node
	_rag_claimed = true
	_dead = true
	_settled = false
	_clip = BeastClips.DEATH
	_clip_t = 0.0
	_clip_ended = true
	_inst.flash_pulse = 0.0
	_apply_flash()
	_skel.add_child(node)
	node.settled.connect(_on_ragdoll_settled)
	node.begin(momentum, point, dir, newtons)
	# The rig is the simulator's now. Nothing this node does per frame — clip
	# clock, LOD, pose solve, skeleton write — has any effect on a physics corpse,
	# so it all stops.
	set_process(false)
	return true


func _on_ragdoll_settled() -> void:
	_release_ragdoll_slot()
	if _settled:
		return
	_settled = true
	collapse_settled.emit()


## Give the solver slot back without freeing the corpse. A settled ragdoll is
## asleep and costs nothing; holding its slot would starve the next death.
func _release_ragdoll_slot() -> void:
	if not _rag_claimed:
		return
	_rag_claimed = false
	RagdollBudget.release()


## Tear the physics corpse down. The skeleton reverts to whatever local pose the
## animation last wrote, so this only ever runs on a body leaving service.
func _drop_ragdoll() -> void:
	_release_ragdoll_slot()
	if _rag == null:
		return
	_rag.stop()
	# Removed rather than only queued: a freed-next-frame simulator would still
	# write bone poses over the first frame of the revived body's idle.
	if _rag.get_parent() != null:
		_rag.get_parent().remove_child(_rag)
	_rag.queue_free()
	_rag = null
	_reset_bone_rest()


## Put every bone back on the offset the bake wrote into its rest pose.
##
## The simulator drives bone GLOBAL poses, which moves bone POSITIONS as well as
## rotations. `_apply_pose` only ever writes rotations, because in this rig a bone
## position is a static baked quantity that no clip touches — so without this a
## body coming back out of the pool would wear the corpse's last translations and
## reassemble itself inside out.
func _reset_bone_rest() -> void:
	if _skel == null or species_rig == null:
		return
	for i in _bone_count:
		_skel.set_bone_pose_position(i, species_rig.bones[i].offset)


## Metres to the active camera, or zero when there is none — a scene with no
## camera is a tool, and a tool wants the full-fat path.
func _camera_distance() -> float:
	if _camera == null or not is_instance_valid(_camera):
		var vp: Viewport = get_viewport()
		_camera = null if vp == null else vp.get_camera_3d()
	if _camera == null:
		return 0.0
	return global_position.distance_to(_camera.global_position)


## Stop the pose clock. A body parked in a pool is invisible and a kilometre out
## of the world, so every clip second it accumulates and every quaternion it
## writes into the skeleton is work nobody will ever see. `revive()` starts it
## again; the pose is a pure function of clip time, so nothing drifts across the
## sleep.
func sleep() -> void:
	set_process(false)
	_drop_ragdoll()


## Reseat a pooled body for reuse: forget the corpse, the aim and the flinch.
func revive(seed_value: int, take: int) -> void:
	_drop_ragdoll()
	set_process(_inst != null)
	_dead = false
	_settled = false
	_stagger_lock = 0.0
	_resume_clip = BeastClips.IDLE
	if _inst != null:
		_inst.seed_value = seed_value
		_inst.death_take = take
		_inst.death_state = null
		_inst.has_aim = false
	_clip = BeastClips.DEATH
	play_clip(String(BeastClips.IDLE))


func is_dead() -> bool:
	return _dead


func has_settled() -> bool:
	return _settled


## The posed instance, for callers that need bone transforms or the analytic
## shell — precise limb hit resolution, for instance.
func instance() -> RigInstance:
	return _inst


## Which damage zone a world-space impact landed in.
##
## Resolved analytically against the posed primitives rather than against a
## skeleton of collision shapes: fifty point-to-primitive distances on the frame a
## shot lands cost far less than fifty `BoneAttachment3D` nodes updating on every
## frame that it does not.
func zone_at(world_point: Vector3) -> StringName:
	if _inst == null or bone_zones.is_empty():
		return EnemyStats.ZONE_CORE
	var local: Vector3 = to_local(world_point)
	var best: float = INF
	var best_bone: int = -1
	for i in _inst.part_bone.size():
		if _inst.part_fx[i] != 0:
			continue
		var m: Transform3D = _inst.pose.globals[_inst.part_bone[i]] * _inst.part_local[i]
		var d: float = _surface_distance(_inst.rig.parts[i], m, local)
		if d < best:
			best = d
			best_bone = _inst.part_bone[i]
	if best_bone < 0 or best_bone >= bone_zones.size():
		return EnemyStats.ZONE_CORE
	return bone_zones[best_bone]


## Signed distance from a point to a primitive's surface, negative inside. Uses
## the same analytic shapes the bake's joint validator measures with.
func _surface_distance(p: RigPart, m: Transform3D, point: Vector3) -> float:
	var prim: Dictionary = BeastCollide.world_prim(p, m)
	match p.shape:
		RigPart.Shape.SPH:
			return Vector3(prim["c"]).distance_to(point) - float(prim["r"])
		RigPart.Shape.BOX:
			return BeastCollide.pt_box(point, prim).distance_to(point)
	var a: Vector3 = prim["a"]
	var d: Vector3 = Vector3(prim["b"]) - a
	var len2: float = d.length_squared()
	var t: float = 0.0
	if len2 > 1e-12:
		t = clampf((point - a).dot(d) / len2, 0.0, 1.0)
	return (a + d * t).distance_to(point) - BeastCollide.cyl_r(prim, t)


## Rig-space to world for one bone, without a node lookup.
func bone_global(index: int) -> Transform3D:
	if _inst == null or index < 0 or index >= _inst.pose.globals.size():
		return global_transform
	return global_transform * _inst.pose.globals[index]


func _apply_pose() -> void:
	if _inst == null or _skel == null:
		return
	PoseSolver.pose(_inst, _clip, _clip_t)
	var locals: Array[Quaternion] = _inst.pose.locals
	for i in _bone_count:
		_skel.set_bone_pose_rotation(i, locals[i])
	_skel.transform = _inst.pose.root
	_apply_flash()


func _apply_flash() -> void:
	if _flashes.is_empty():
		return
	var s: float = _inst.flash_pulse * flash_scale
	var visible_now: bool = s > 0.001
	for f in _flashes:
		f.visible = visible_now
		if visible_now:
			f.scale = Vector3(s, s, s)


func _advance_clip_end() -> void:
	if _clip_ended:
		if _dead and not _settled and _clip_t >= COLLAPSE_SETTLE_TIME:
			_settled = true
			collapse_settled.emit()
		return
	if BeastClips.is_locomotion(_clip) or _clip == BeastClips.IDLE:
		return
	if _clip == BeastClips.AIM:
		return
	if _clip_t < _clip_len:
		return
	_clip_ended = true
	clip_finished.emit(_clip)
	if _clip == BeastClips.STAGGER or _clip == BeastClips.ATTACK:
		play_clip(String(_resume_clip))


func _is_interruptible(clip: StringName) -> bool:
	return clip != BeastClips.DEATH and clip != BeastClips.STAGGER


func _refresh_lod() -> void:
	if _camera == null or not is_instance_valid(_camera):
		var vp: Viewport = get_viewport()
		_camera = null if vp == null else vp.get_camera_3d()
	if _camera == null:
		_pose_interval = 0.0
		return
	var d: float = global_position.distance_to(_camera.global_position)
	if d <= lod_near:
		_pose_interval = 0.0 if pose_hz_near <= 0.0 else 1.0 / pose_hz_near
	elif d <= lod_far:
		_pose_interval = 1.0 / pose_hz_mid
	else:
		_pose_interval = 1.0 / pose_hz_far


func _resolve_nodes() -> void:
	_skel = get_node_or_null(skeleton_path) as Skeleton3D
	if _skel == null:
		push_error("EnemyBody '%s': skeleton_path does not resolve." % name)
	_shells.clear()
	for p in shell_paths:
		var m := get_node_or_null(p) as MeshInstance3D
		if m != null:
			_shells.append(m)
	_flashes.clear()
	for p in flash_paths:
		var f := get_node_or_null(p) as Node3D
		if f != null:
			f.visible = false
			_flashes.append(f)
	set_faction_color(_tint)
