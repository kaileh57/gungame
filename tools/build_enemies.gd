extends SceneTree
## Bake the bestiary. Run once, headless:
##
##   godot --headless --path <project> --script res://tools/build_enemies.gd
##
## For each species it welds the rig's primitives into ONE skinned `ArrayMesh`
## with one surface per material, wraps it in a spawnable `EnemyActor` scene and
## saves it to `res://data/enemies/<id>.res`. A rat is 52 primitives and six
## materials; after the merge it is one mesh instance and six draw calls, and the
## only per-frame cost is seventeen bone quaternions. Nothing here may run at
## runtime — a creature that rebuilds its own geometry in `_ready` is the bug this
## whole file exists to prevent.
##
## It then re-poses every species across the reference's 308-pose grid and
## measures the joint overlap, because the no-air-gaps rule is not a claim you
## make about geometry, it is a number you measure. `res://data/enemy_bake_report.txt`
## carries the result and the bake fails loudly rather than shipping a seam.
##
## The roster itself lives in `SpeciesTable`; this file never authors a
## measurement, it only welds, measures and saves what the roster declares.

## Loaded on the first idle frame, never `preload`ed. `--script` compiles this
## file and its whole preload graph BEFORE `Main::start` registers the autoloads
## as global constants, and `enemy_actor.gd` reaches `AICombat`, which names
## `Factions`. Preloading it therefore fails the whole bake at parse time. By the
## first frame the autoloads exist and `load()` resolves cleanly — the same
## deferral `build_player.gd` and `build_arena.gd` use, for the same reason.
const ACTOR_SCRIPT_PATH: String = "res://systems/enemies/enemy_actor.gd"
const BODY_SCRIPT_PATH: String = "res://systems/enemies/enemy_body.gd"

const OUT_DIR: String = "res://data/enemies"
## Ragdolls live in their own directory so nothing that walks `data/enemies/*.res`
## looking for a species ever picks one up.
const RAGDOLL_DIR: String = "res://data/enemies/ragdolls"
const REPORT_PATH: String = "res://data/enemy_bake_report.txt"

## The reference's validation grid: frames sampled per clip, `t = i/frames * len`.
const CLIP_FRAMES: Dictionary = {
	&"idle": 16, &"walk": 40, &"run": 40, &"aim": 72, &"attack": 24, &"stagger": 20
}
## Death is sampled at 24 frames across each of five seeded takes.
const DEATH_FRAMES: int = 24
const DEATH_TAKES: int = 5

## A joint whose best parent/child overlap falls to this or below is a seam.
const GAP_EPSILON: float = 0.0
## Primitive shells thinner than this are treated as degenerate rather than solid.
const VOLUME_EPSILON: float = 1e-12
## Capsule radius as a fraction of the measured idle-pose width.
const COLLIDER_WIDTH_K: float = 0.5
## Aim point as a fraction of body height.
const AIM_HEIGHT_K: float = 0.62
## Eye point as a fraction of body height.
const EYE_HEIGHT_K: float = 0.92

# ------------------------------------------------------------------ ragdoll
#
# Every constant below shapes the physics ragdoll baked into
# `res://data/enemies/ragdolls/<id>.res`. See `_bake_ragdoll` for why the set of
# simulated bones is a pruned STRUCTURAL set rather than every bone: a tail, a
# rotor and a finger add joints and solve cost and change nothing a corpse does.

## Longest simulated chain a species may bake. A body past this drops its
## smallest-mass simulated bones first; nothing in the roster comes close.
const RAGDOLL_MAX_BONES: int = 24
## Aspect ratio at which a bone's shell is called a limb and gets a capsule
## rather than a box. Below it the shell is a torso, a head or a pelvis.
const RAGDOLL_CAPSULE_RATIO: float = 1.55
## Smallest half-extent, radius or half-height a ragdoll shape may have. Jolt
## solves sub-centimetre shapes badly and they buy nothing at this scale.
const RAGDOLL_MIN_EXTENT: float = 0.035
## A bone lighter than this share of the body is not worth a rigid body of its
## own; its mass rolls up into its nearest simulated ancestor and it rides along
## rigidly, which is what a hand or a foot pad does anyway.
const RAGDOLL_MIN_MASS_SHARE: float = 0.004
## Mass clamp, as a share of the whole body. A joint between a 40 kg torso and a
## 0.2 kg forearm is soft and jittery in every solver; pulling the ratio in is
## what buys a settle instead of a shiver.
const RAGDOLL_MASS_MIN_SHARE: float = 0.020
const RAGDOLL_MASS_MAX_SHARE: float = 0.340
## Cone-twist limits in DEGREES, keyed by joint role. Godot's
## `joint_constraints/swing_span` and `twist_span` are degrees, not radians.
##
## Every joint is a cone twist, including the knee and the elbow. A hinge would be
## anatomically truer, but the hinge angle's SIGN depends on the solver's frame
## convention and a hinge fitted backwards bends a knee the wrong way — which
## reads as broken in a way a stiff knee never does. A 26 deg cone folds a leg
## under a falling body convincingly and cannot invert it.
const RAGDOLL_JOINTS: Dictionary = {
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
const RAGDOLL_ANGULAR_DAMP: Dictionary = {
	"spine": 1.4, "neck": 2.2, "head": 2.2, "hip": 2.6, "knee": 3.2, "ankle": 3.6,
	"shoulder": 2.6, "elbow": 3.2, "wrist": 3.6, "held": 4.0
}
## Linear damping, applied in REPLACE mode so a level's default area damp cannot
## change how a corpse falls.
const RAGDOLL_LINEAR_DAMP: float = 0.22
## Baked gravity scale. `EnemyBody.ragdoll_gravity_scale` overrides it live; the
## reference's hand-authored collapse falls at 2.8 g because true gravity reads
## floaty on a body this size, and a real ragdoll has the same problem.
const RAGDOLL_GRAVITY_SCALE: float = 1.85
## Contact friction. High: a corpse that slides after it lands looks like a prop.
const RAGDOLL_FRICTION: float = 0.95


## One material's worth of merged geometry.
class Surface:
	extends RefCounted

	var mat_key: StringName = &""
	var col_override: String = ""
	var verts: PackedVector3Array = PackedVector3Array()
	var norms: PackedVector3Array = PackedVector3Array()
	var bones: PackedInt32Array = PackedInt32Array()
	var weights: PackedFloat32Array = PackedFloat32Array()

	## Emits one triangle and returns its contribution to the enclosing volume in
	## the AUTHORING convention, where the right-hand cross of (a,b,c) points
	## outward. That is the rig builders' convention and the reference's, and the
	## caller's inside-out test is written against it.
	##
	## The vertices go out as a, c, b. Godot's front face is CLOCKWISE where the
	## reference's is counter-clockwise, so the emitted winding has to turn round
	## or every creature is lit correctly and culled inside out. `n` is left alone:
	## it already points outward and is stored data, not re-derived at draw time.
	## Every triangle in a creature passes through here, `quad` included, so this
	## is the only place the two conventions meet.
	func tri(a: Vector3, b: Vector3, c: Vector3, bone: int) -> float:
		var n: Vector3 = (b - a).cross(c - a)
		var area2: float = n.length()
		if area2 < 1e-12:
			return 0.0
		n /= area2
		verts.append(a)
		verts.append(c)
		verts.append(b)
		for _i in 3:
			norms.append(n)
			bones.append(bone)
			bones.append(0)
			bones.append(0)
			bones.append(0)
			weights.append(1.0)
			weights.append(0.0)
			weights.append(0.0)
			weights.append(0.0)
		return a.dot(b.cross(c)) / 6.0

	func quad(a: Vector3, b: Vector3, c: Vector3, d: Vector3, bone: int) -> float:
		return tri(a, b, c, bone) + tri(a, c, d, bone)

	func to_arrays() -> Array:
		var arr: Array = []
		arr.resize(Mesh.ARRAY_MAX)
		arr[Mesh.ARRAY_VERTEX] = verts
		arr[Mesh.ARRAY_NORMAL] = norms
		arr[Mesh.ARRAY_BONES] = bones
		arr[Mesh.ARRAY_WEIGHTS] = weights
		return arr


var _materials: Dictionary = {}
var _rows: Array[Dictionary] = []
var _failures: PackedStringArray = PackedStringArray()
var _actor_script: GDScript = null
var _body_script: GDScript = null
var _started: bool = false


func _process(_delta: float) -> bool:
	if _started:
		return true
	_started = true
	_actor_script = load(ACTOR_SCRIPT_PATH) as GDScript
	_body_script = load(BODY_SCRIPT_PATH) as GDScript
	if _actor_script == null or _body_script == null:
		printerr("build_enemies: could not load the actor scripts.")
		quit(1)
		return true
	_run()
	return true


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(BeastMat.MATERIAL_DIR))
	print("build_enemies: %d species" % SpeciesTable.IDS.size())
	var built: Array = []
	for id in SpeciesTable.IDS:
		var inst: RigInstance = SpeciesTable.instantiate(id)
		if inst == null:
			_failures.append("%s: roster returned no rig" % id)
			continue
		for p in inst.rig.parts:
			_register_material(p.mat, p.col_override)
		built.append([id, inst])
	# Materials are saved before the first scene is packed: a surface override
	# has to point at a resource that already exists on disk.
	_save_materials()
	for entry: Array in built:
		_bake_species(entry[0], entry[1])
	var ok: bool = _write_report()
	quit(0 if ok else 1)


# ------------------------------------------------------------------ per species


func _bake_species(id: StringName, inst: RigInstance) -> void:
	var rig: EnemyRig = inst.rig
	var stats: EnemyStats = inst.stats
	var expect: Dictionary = SpeciesTable.CATALOGUE[id]
	if rig.parts.size() != int(expect["parts"]):
		_failures.append(
			"%s: %d parts, catalogue says %d" % [id, rig.parts.size(), int(expect["parts"])]
		)
	if rig.bones.size() != int(expect["bones"]):
		_failures.append(
			"%s: %d bones, catalogue says %d" % [id, rig.bones.size(), int(expect["bones"])]
		)

	var rest: Array[Transform3D] = rig.rest_transforms()
	var built: Dictionary = _build_surfaces(rig, inst, rest)
	var surfaces: Array = built["surfaces"]
	var flash: Dictionary = built["flash"]
	var mesh: ArrayMesh = _merge(surfaces)
	var skin: Skin = _build_skin(rig, rest)
	var check: Dictionary = _validate(inst)

	var scene: PackedScene = _assemble(id, rig, stats, mesh, skin, flash, _zones(inst))
	var path: String = "%s/%s.res" % [OUT_DIR, id]
	var err: int = ResourceSaver.save(scene, path)
	if err != OK:
		_failures.append("%s: ResourceSaver.save -> %d" % [id, err])

	var row: Dictionary = {
		"id": id,
		"parts": rig.parts.size(),
		"bones": rig.bones.size(),
		"surfaces": mesh.get_surface_count(),
		"verts": int(built["verts"]),
		"inverted": int(built["inverted"]),
		"degenerate": int(built["degenerate"]),
		"separation": -float(check["min_link"]),
		"floating": int(check["floating"]),
		"poses": int(check["poses"]),
		"clips": check["clips"],
		"height": stats.height,
		"saved": err == OK
	}
	row["pass"] = (
		err == OK
		and row["inverted"] == 0
		and row["floating"] == 0
		and row["separation"] <= GAP_EPSILON
		and row["verts"] > 0
	)
	_rows.append(row)
	print(
		(
			"  %-9s parts %3d  surf %2d  verts %6d  sep %+9.5f m  floating %d  %s"
			% [
				id,
				row["parts"],
				row["surfaces"],
				row["verts"],
				row["separation"],
				row["floating"],
				"PASS" if row["pass"] else "FAIL"
			]
		)
	)


# ------------------------------------------------------------------ geometry


## Weld every primitive into one accumulator per (material, colour override).
## `fx` flare primitives are pulled out into their own per-bone meshes: they live
## at zero scale until a shot inflates them, which a shared skinned surface cannot
## express.
func _build_surfaces(rig: EnemyRig, inst: RigInstance, rest: Array[Transform3D]) -> Dictionary:
	var surfaces: Array = []
	var index: Dictionary = {}
	var flash: Dictionary = {}
	var inverted: int = 0
	var degenerate: int = 0
	var verts: int = 0
	for i in rig.parts.size():
		var p: RigPart = rig.parts[i]
		var bone: int = inst.part_bone[i]
		var key: String = BeastMat.material_id(p.mat, p.col_override)
		_register_material(p.mat, p.col_override)
		var target: Surface = null
		if inst.part_fx[i] != 0:
			if not flash.has(bone):
				var fs := Surface.new()
				fs.mat_key = p.mat
				fs.col_override = p.col_override
				flash[bone] = fs
			target = flash[bone]
		else:
			if not index.has(key):
				var s := Surface.new()
				s.mat_key = p.mat
				s.col_override = p.col_override
				index[key] = surfaces.size()
				surfaces.append(s)
			target = surfaces[index[key]]
		# Flare geometry is authored in its own bone's frame so a BoneAttachment3D
		# can scale it; everything else is baked into rig rest space and skinned.
		var xf: Transform3D = p.local_transform()
		if inst.part_fx[i] == 0:
			xf = rest[bone] * xf
		var before: int = target.verts.size()
		var vol: float = _emit(target, p, xf, 0 if inst.part_fx[i] != 0 else bone)
		if inst.part_fx[i] == 0:
			verts += target.verts.size() - before
		if vol <= VOLUME_EPSILON:
			if absf(vol) <= VOLUME_EPSILON:
				degenerate += 1
			else:
				inverted += 1
	return {
		"surfaces": surfaces,
		"flash": flash,
		"inverted": inverted,
		"degenerate": degenerate,
		"verts": verts
	}


## Emit one primitive. Returns its enclosed signed volume, which is positive when
## every face points outward — the same test `bake_gun_parts.gd` orients by.
func _emit(s: Surface, p: RigPart, xf: Transform3D, bone: int) -> float:
	match p.shape:
		RigPart.Shape.BOX:
			return _emit_box(s, xf, p.dims * 0.5, bone)
		RigPart.Shape.CYL:
			return _emit_cyl(s, xf, p.r0, p.r1, p.height, p.radial_segments(), bone)
	return _emit_sph(s, xf, p.radius, p.radial_segments(), bone)


func _emit_box(s: Surface, xf: Transform3D, e: Vector3, bone: int) -> float:
	var x := Vector3(e.x, 0.0, 0.0)
	var y := Vector3(0.0, e.y, 0.0)
	var z := Vector3(0.0, 0.0, e.z)
	var vol: float = 0.0
	vol += _face(s, xf, x, y, z, bone)
	vol += _face(s, xf, -x, z, y, bone)
	vol += _face(s, xf, y, z, x, bone)
	vol += _face(s, xf, -y, x, z, bone)
	vol += _face(s, xf, z, x, y, bone)
	vol += _face(s, xf, -z, y, x, bone)
	return vol


## One box face: `u` cross `v` must point out of the solid.
func _face(s: Surface, xf: Transform3D, c: Vector3, u: Vector3, v: Vector3, bone: int) -> float:
	return s.quad(xf * (c - u - v), xf * (c + u - v), xf * (c + u + v), xf * (c - u + v), bone)


## Cone frustum along local +Y: `r0` at the top, `r1` at the bottom, capped at both
## ends. A zero radius collapses its cap and the side quads become triangles, so a
## cone is a frustum without a special case.
func _emit_cyl(
	s: Surface, xf: Transform3D, r0: float, r1: float, h: float, seg: int, bone: int
) -> float:
	var top := Vector3(0.0, h * 0.5, 0.0)
	var bot := Vector3(0.0, -h * 0.5, 0.0)
	var vol: float = 0.0
	var ring: PackedVector3Array = PackedVector3Array()
	ring.resize(seg + 1)
	for i in seg + 1:
		var a: float = float(i) / float(seg) * TAU
		ring[i] = Vector3(cos(a), 0.0, sin(a))
	for i in seg:
		var d0: Vector3 = ring[i]
		var d1: Vector3 = ring[i + 1]
		var b0: Vector3 = xf * (bot + d0 * r1)
		var b1: Vector3 = xf * (bot + d1 * r1)
		var t0: Vector3 = xf * (top + d0 * r0)
		var t1: Vector3 = xf * (top + d1 * r0)
		vol += s.quad(b0, t0, t1, b1, bone)
		if r0 > 1e-6:
			vol += s.tri(xf * top, t1, t0, bone)
		if r1 > 1e-6:
			vol += s.tri(xf * bot, b0, b1, bone)
	return vol


## Flat-shaded UV sphere. Pole rings emit a single triangle rather than a
## collapsed quad, so the mesh carries no degenerate faces.
func _emit_sph(s: Surface, xf: Transform3D, r: float, wseg: int, bone: int) -> float:
	var hseg: int = maxi(5, wseg >> 1)
	var vol: float = 0.0
	for j in hseg:
		var th0: float = float(j) / float(hseg) * PI
		var th1: float = float(j + 1) / float(hseg) * PI
		for i in wseg:
			var ph0: float = float(i) / float(wseg) * TAU
			var ph1: float = float(i + 1) / float(wseg) * TAU
			var a: Vector3 = xf * _sph_point(r, th0, ph0)
			var b: Vector3 = xf * _sph_point(r, th0, ph1)
			var c: Vector3 = xf * _sph_point(r, th1, ph1)
			var d: Vector3 = xf * _sph_point(r, th1, ph0)
			if j == 0:
				vol += s.tri(a, c, d, bone)
			elif j == hseg - 1:
				vol += s.tri(a, b, c, bone)
			else:
				vol += s.quad(a, b, c, d, bone)
	return vol


func _sph_point(r: float, theta: float, phi: float) -> Vector3:
	var rr: float = r * sin(theta)
	return Vector3(rr * cos(phi), r * cos(theta), rr * sin(phi))


func _merge(surfaces: Array) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	for s: Surface in surfaces:
		if s.verts.is_empty():
			continue
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, s.to_arrays())
		var idx: int = mesh.get_surface_count() - 1
		mesh.surface_set_name(idx, BeastMat.material_id(s.mat_key, s.col_override))
	return mesh


## Rigid skin: every vertex belongs to exactly one bone at full weight. The
## primitives are solids, not skin, and blending them would pinch the joints the
## overlap rule exists to keep sealed.
func _build_skin(rig: EnemyRig, rest: Array[Transform3D]) -> Skin:
	var skin := Skin.new()
	for i in rig.bones.size():
		skin.add_bind(i, rest[i].affine_inverse())
		skin.set_bind_name(i, rig.bones[i].name)
	return skin


# ------------------------------------------------------------------ measurement


## Re-pose the species across the reference's 308-frame grid and measure, for
## every parent/child bone pair, how deeply the child's geometry is still buried
## in the parent's. `min_link` is the loosest joint in the worst frame; anything
## at or below zero is a visible seam.
func _validate(inst: RigInstance) -> Dictionary:
	var links: Array = _link_pairs(inst)
	var clips: Array[Dictionary] = []
	var worst: float = INF
	var floating: int = 0
	var poses: int = 0
	for clip in CLIP_FRAMES.keys():
		var frames: int = int(CLIP_FRAMES[clip])
		var r: Dictionary = _sample(inst, links, StringName(clip), frames, -1)
		clips.append(r)
		worst = minf(worst, float(r["min_link"]))
		floating += int(r["floating"])
		poses += frames
	for take in DEATH_TAKES:
		var r: Dictionary = _sample(inst, links, BeastClips.DEATH, DEATH_FRAMES, take)
		clips.append(r)
		worst = minf(worst, float(r["min_link"]))
		floating += int(r["floating"])
		poses += DEATH_FRAMES
	return {"min_link": worst, "floating": floating, "poses": poses, "clips": clips}


func _sample(
	inst: RigInstance, links: Array, clip: StringName, frames: int, take: int
) -> Dictionary:
	var length: float = BeastClips.length_of(clip)
	var worst: float = INF
	var floating: int = 0
	var min_y: float = INF
	var max_y: float = -INF
	for f in frames:
		var t: float = float(f) / float(frames) * length
		if take >= 0:
			inst.death_state = null
			PoseSolver.pose(inst, clip, t, take)
		else:
			PoseSolver.pose(inst, clip, t)
		var prims: Array = _prims(inst)
		for pair: Array in links:
			var best: float = -INF
			for k: int in pair[0]:
				for pnt: int in pair[1]:
					best = maxf(best, BeastCollide.penetration(prims[k], prims[pnt]))
			if best <= 0.0:
				floating += 1
			worst = minf(worst, best)
		for i in prims.size():
			if prims[i].is_empty():
				continue
			min_y = minf(min_y, BeastCollide.prim_low_y(prims[i]))
			max_y = maxf(max_y, BeastCollide.prim_high_y(prims[i]))
	var label: String = String(clip) if take < 0 else "%s#%d" % [clip, take]
	return {
		"clip": label,
		"frames": frames,
		"min_link": worst,
		"floating": floating,
		"min_y": min_y,
		"max_y": max_y
	}


## Parent/child part-index pairs, resolved once. Bones with no geometry on one
## side of the joint are dropped: there is nothing there to separate.
func _link_pairs(inst: RigInstance) -> Array:
	var by_bone: Dictionary = {}
	for i in inst.part_bone.size():
		if inst.part_fx[i] != 0:
			continue
		var b: int = inst.part_bone[i]
		if not by_bone.has(b):
			by_bone[b] = PackedInt32Array()
		by_bone[b].append(i)
	var out: Array = []
	for i in inst.rig.bones.size():
		var bone: RigBone = inst.rig.bones[i]
		if bone.parent.is_empty():
			continue
		var parent: int = inst.rig.bone_index(bone.parent)
		if not by_bone.has(i) or not by_bone.has(parent):
			continue
		out.append([by_bone[i], by_bone[parent]])
	return out


func _prims(inst: RigInstance) -> Array:
	var mats: Array[Transform3D] = inst.part_matrices()
	var out: Array = []
	out.resize(mats.size())
	for i in mats.size():
		if inst.part_fx[i] != 0:
			out[i] = {}
		else:
			out[i] = BeastCollide.world_prim(inst.rig.parts[i], mats[i])
	return out


# ------------------------------------------------------------------ assembly


## Damage zone per bone, baked flat so a hit resolves with one array read instead
## of a dictionary walk. `SpeciesTable` decides which bones are head and core.
func _zones(inst: RigInstance) -> Array[StringName]:
	var out: Array[StringName] = []
	out.resize(inst.rig.bones.size())
	out.fill(EnemyStats.ZONE_LIMB)
	for hb in SpeciesTable.hitboxes(inst):
		out[int(hb["bone_index"])] = StringName(hb["zone"])
	return out


func _assemble(
	id: StringName,
	rig: EnemyRig,
	stats: EnemyStats,
	mesh: ArrayMesh,
	skin: Skin,
	flash: Dictionary,
	zones: Array[StringName]
) -> PackedScene:
	var actor := CharacterBody3D.new()
	actor.set_script(_actor_script)
	actor.name = String(id).capitalize()
	actor.set(&"species_id", id)

	var shape := CollisionShape3D.new()
	shape.name = "Shape"
	# The collider is fitted to the measured idle silhouette, not to the rest
	# chain: a hunched rat and an upright marksman are not the same cylinder.
	var height: float = maxf(0.3, stats.height)
	var radius: float = maxf(0.12, stats.width * COLLIDER_WIDTH_K)
	var capsule := CapsuleShape3D.new()
	capsule.radius = minf(radius, height * 0.5 - 0.01)
	capsule.height = height
	shape.shape = capsule
	shape.position = Vector3(0.0, height * 0.5 + stats.alt, 0.0)

	var target := AITarget.new()
	target.name = "Target"
	target.aim_offset = Vector3(0.0, height * AIM_HEIGHT_K, 0.0)
	target.eye_offset = Vector3(0.0, height * EYE_HEIGHT_K, 0.0)
	target.body_radius = radius

	var agent := NavigationAgent3D.new()
	agent.name = "NavAgent"
	agent.radius = radius
	agent.height = height
	agent.path_desired_distance = maxf(0.5, radius * 1.4)
	agent.target_desired_distance = maxf(0.6, radius * 1.6)

	var body := Node3D.new()
	body.set_script(_body_script)
	body.name = "Body"
	body.set(&"species_id", id)
	body.set(&"species_rig", rig)
	body.set(&"species_stats", stats)
	body.set(&"bone_zones", zones)

	var skel := Skeleton3D.new()
	skel.name = "Skeleton"
	for b in rig.bones:
		var idx: int = skel.add_bone(String(b.name))
		if not b.parent.is_empty():
			skel.set_bone_parent(idx, rig.bone_index(b.parent))
		skel.set_bone_rest(idx, Transform3D(Basis.IDENTITY, b.offset))
		skel.set_bone_pose_position(idx, b.offset)

	var shell := MeshInstance3D.new()
	shell.name = "Shell"
	shell.mesh = mesh
	shell.skin = skin
	shell.skeleton = NodePath("..")
	for i in mesh.get_surface_count():
		shell.set_surface_override_material(i, _material_for(mesh.surface_get_name(i)))

	actor.add_child(shape)
	actor.add_child(target)
	actor.add_child(agent)
	actor.add_child(body)
	body.add_child(skel)
	skel.add_child(shell)

	var flash_paths: Array[NodePath] = []
	for bone: int in flash.keys():
		var att := BoneAttachment3D.new()
		att.name = "Flash%d" % bone
		var fm := MeshInstance3D.new()
		fm.name = "Mesh"
		fm.mesh = _merge([flash[bone]])
		fm.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var fs: Surface = flash[bone]
		fm.set_surface_override_material(
			0, _material_for(BeastMat.material_id(fs.mat_key, fs.col_override))
		)
		skel.add_child(att)
		att.bone_idx = bone
		att.add_child(fm)
		flash_paths.append(NodePath("Skeleton/%s/Mesh" % att.name))
	body.set(&"flash_paths", flash_paths)
	var shells: Array[NodePath] = [NodePath("Skeleton/Shell")]
	body.set(&"shell_paths", shells)

	for n in [shape, target, agent, body, skel, shell]:
		n.owner = actor
	for bone: int in flash.keys():
		var att: Node = skel.get_node("Flash%d" % bone)
		att.owner = actor
		att.get_node("Mesh").owner = actor

	var packed := PackedScene.new()
	packed.pack(actor)
	actor.free()
	return packed


# ------------------------------------------------------------------ materials


func _register_material(key: StringName, col_override: String) -> void:
	var id: String = BeastMat.material_id(key, col_override)
	if not _materials.has(id):
		_materials[id] = [key, col_override]


func _material_for(id: String) -> Material:
	if not _materials.has(id):
		return null
	var pair: Array = _materials[id]
	return load(BeastMat.material_path(pair[0], pair[1])) as Material


func _save_materials() -> void:
	for id: String in _materials.keys():
		var pair: Array = _materials[id]
		var mat: Material = BeastMat.build_material(pair[0], pair[1])
		mat.resource_name = id
		var path: String = BeastMat.material_path(pair[0], pair[1])
		var err: int = ResourceSaver.save(mat, path)
		if err != OK:
			_failures.append("material %s: ResourceSaver.save -> %d" % [id, err])
	print("build_enemies: %d materials -> %s" % [_materials.size(), BeastMat.MATERIAL_DIR])


# ------------------------------------------------------------------ report


func _write_report() -> bool:
	var ok: bool = _failures.is_empty() and not _rows.is_empty()
	var out: PackedStringArray = PackedStringArray()
	out.append("ENEMY BAKE REPORT")
	out.append("res://tools/build_enemies.gd - merged skinned shells, one per species.")
	out.append("")
	out.append(
		(
			"%-10s %5s %5s %4s %7s %6s %6s %14s %8s %6s %s"
			% [
				"species",
				"parts",
				"bones",
				"surf",
				"verts",
				"inv",
				"degen",
				"worst sep (m)",
				"floating",
				"poses",
				"result"
			]
		)
	)
	for r in _rows:
		if not r["pass"]:
			ok = false
		out.append(
			(
				"%-10s %5d %5d %4d %7d %6d %6d %14.9f %8d %6d %s"
				% [
					r["id"],
					r["parts"],
					r["bones"],
					r["surfaces"],
					r["verts"],
					r["inverted"],
					r["degenerate"],
					r["separation"],
					r["floating"],
					r["poses"],
					"PASS" if r["pass"] else "FAIL"
				]
			)
		)
	out.append("")
	out.append("Worst separation is the negated minimum parent/child overlap over every")
	out.append("sampled pose. It must be <= 0: a positive number is an open joint.")
	out.append("`inv` counts primitives whose emitted shell encloses negative volume;")
	out.append("`floating` counts parent/child links with no overlap at all.")
	out.append("")
	out.append("PER-CLIP DETAIL (frames / floating / min overlap / min Y / max Y)")
	for r in _rows:
		out.append("")
		out.append("%s  height %.4f m" % [r["id"], r["height"]])
		for c: Dictionary in r["clips"]:
			out.append(
				(
					"    %-9s %4d %6d %14.9f %14.9f %14.9f"
					% [c["clip"], c["frames"], c["floating"], c["min_link"], c["min_y"], c["max_y"]]
				)
			)
	if not _failures.is_empty():
		out.append("")
		out.append("ERRORS")
		for f in _failures:
			out.append("  " + f)
	out.append("")
	out.append("RESULT: %s" % ("PASS" if ok else "FAIL"))
	var f := FileAccess.open(REPORT_PATH, FileAccess.WRITE)
	if f == null:
		printerr("build_enemies: cannot write %s" % REPORT_PATH)
		return false
	f.store_string("\n".join(out) + "\n")
	f.close()
	print("build_enemies: %s -> %s" % ["PASS" if ok else "FAIL", REPORT_PATH])
	return ok
