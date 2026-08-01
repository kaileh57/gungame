class_name EnemyRig
extends Resource
## A creature's skeleton and its welded primitive shell.
##
## THE NO-GAP GUARANTEE lives in `link()` and `tube()`. Read the note on `link()`
## before adding geometry to any species: every joint gets a sphere centred on its
## own pivot, and every segment overhangs both of its ends. Those two rules are
## why a limb cannot come apart no matter how it is routed, and the bake asserts
## the result on 308 poses per species.
##
## Bones are appended parent-before-child. Parts are appended in declaration order.
## Both orderings are contracts, not conveniences.

## Default overhang above the pivot, as a fraction of the segment's top radius.
const LINK_OVER_TOP: float = 0.62
## Default overhang past the far end, as a fraction of the segment's bottom radius.
const LINK_OVER_BOT: float = 0.30
## Joint ball radius as a fraction of the segment's top radius. Fatter than the
## segment it caps, so it protrudes through the cylinder wall in every direction.
const LINK_BALL_K: float = 1.14
## A tube's kink balls are 6% fatter than the tube itself.
const TUBE_BALL_K: float = 1.06

@export var id: StringName = &""
@export var display_name: String = ""
## `scav`, `machine` or `mutant`.
@export var faction_class: StringName = &"scav"
@export var role: String = ""
@export var blurb: String = ""
## Uniform body density in kg/m3. -1 falls back to per-material density.
@export_range(-1.0, 9000.0, 1.0, "or_greater") var rho: float = -1.0

@export var bones: Array[RigBone] = []
@export var parts: Array[RigPart] = []
@export var legs: Array[RigLeg] = []
@export var arms: Array[RigArm] = []
@export var aim: RigAim = null
## The species' derived combat record, measured off this shell at bake time.
## Typed as `Resource` on purpose: the rig core is the bottom of the dependency
## graph and must not import the stats module to describe a skeleton.
@export var stats: Resource = null

## `spine`, `head`, `neck`, `hunch`, `lean_run`, `flex`, `neck_pitch`, `turn`,
## `wags`, `spin`. `turn` of -1 means "unset": the solver substitutes PI for an
## armed rig and 0 for a melee one.
@export var tags: Dictionary = {
	"spine": [],
	"head": &"",
	"neck": &"",
	"hunch": 0.0,
	"lean_run": 0.0,
	"flex": 1.15,
	"neck_pitch": 0.0,
	"turn": -1.0,
	"wags": [],
	"spin": []
}
## Authored gait inputs plus everything `GaitSolver` derives from the rest pose.
@export var gait: Dictionary = {
	"type": "biped",
	"duty": 0.60,
	"stride_k": 1.45,
	"freq_k": 1.0,
	"lift": 0.16,
	"bob": 0.022,
	"sway": 0.02
}
## `dps`, `detect`, `reach`, `hp_k`, `arm_k`.
@export var info: Dictionary = {"dps": 10.0, "detect": 40.0, "hp_k": 1.0, "arm_k": 1.0}

var _index: Dictionary = {}


## Index of a bone by name, or -1.
func bone_index(n: StringName) -> int:
	if _index.is_empty() and not bones.is_empty():
		_rebuild_index()
	return int(_index.get(n, -1))


func has_bone(n: StringName) -> bool:
	return bone_index(n) >= 0


## Declare a bone. Returns its name so call sites can chain like the reference.
func bone(n: StringName, parent: StringName, off: Vector3 = Vector3.ZERO) -> StringName:
	if _index.size() != bones.size():
		_rebuild_index()
	var b := RigBone.new()
	b.name = n
	b.parent = parent
	b.offset = off
	_index[n] = bones.size()
	bones.append(b)
	return n


func box(b: StringName, c: Vector3, d: Vector3, m: StringName, o: Dictionary = {}) -> void:
	var p: RigPart = _new_part(b, RigPart.Shape.BOX, c, m, o)
	p.dims = d
	parts.append(p)


func cyl(
	b: StringName, c: Vector3, r0: float, r1: float, h: float, m: StringName, o: Dictionary = {}
) -> void:
	var p: RigPart = _new_part(b, RigPart.Shape.CYL, c, m, o)
	p.r0 = r0
	p.r1 = r1
	p.height = h
	parts.append(p)


func sph(b: StringName, c: Vector3, r: float, m: StringName, o: Dictionary = {}) -> void:
	var p: RigPart = _new_part(b, RigPart.Shape.SPH, c, m, o)
	p.radius = r
	parts.append(p)


## A bone plus the segment that clothes it — THE no-gap primitive.
##
## The segment runs down local -Y for `length`, but the cylinder spans
## `y in [+ov0, -length-ov1]`, so neighbouring segments always interpenetrate along
## the bone axis by `ov0(child) + ov1(parent)` at rest. On top of that a ball sits
## at exactly the joint pivot: the pivot is the bone's origin, so under ANY local
## rotation the ball's centre is fixed relative to the parent and its overlap with
## the parent's geometry is a rotation-invariant constant. That invariance — not a
## tolerance, not a fudge — is what seals the seam.
func link(
	n: StringName,
	parent: StringName,
	off: Vector3,
	length: float,
	r0: float,
	r1: float,
	m: StringName,
	o: Dictionary = {}
) -> StringName:
	bone(n, parent, off)
	var b: RigBone = bones[bones.size() - 1]
	b.length = length
	b.radius = r0
	var ov0: float = float(o.get("ov0", LINK_OVER_TOP)) * r0
	var ov1: float = float(o.get("ov1", LINK_OVER_BOT)) * r1
	var h: float = length + ov0 + ov1
	var cy: float = (ov0 - length - ov1) * 0.5
	var pass_through: Dictionary = {}
	if o.has("seg"):
		pass_through["seg"] = o["seg"]
	if o.has("rho"):
		pass_through["rho"] = o["rho"]
	cyl(n, Vector3(0.0, cy, 0.0), r0, r1, h, m, pass_through)
	if bool(o.get("ball", true)):
		var br: float = maxf(r0 * LINK_BALL_K, float(o.get("pr", 0.0)) * 1.02)
		if o.has("ball_r"):
			br = float(o["ball_r"])
		var ball_m: StringName = o.get("ball_m", m)
		sph(n, Vector3.ZERO, br, ball_m, pass_through)
	return n


## A polyline of cylinders with a ball at every kink — hoses, cables, claws, slings.
## The ball-at-every-kink rule is `link()`'s invariant applied to a routed tube:
## the joint is covered by a solid whose position no bend can move.
func tube(b: StringName, pts: Array[Vector3], r: float, m: StringName) -> void:
	for p in pts:
		sph(b, p, r * TUBE_BALL_K, m)
	for i in pts.size() - 1:
		var a: Vector3 = pts[i]
		var c: Vector3 = pts[i + 1]
		var d: Vector3 = c - a
		var seg_len: float = d.length()
		if seg_len < 1e-5:
			continue
		cyl(b, (a + c) * 0.5, r, r, seg_len, m, {"rot": BeastMath.dir_euler(d)})


## Density for one part: its own override, else the rig's, else the material's.
func density_of(p: RigPart) -> float:
	if p.rho >= 0.0:
		return p.rho
	if rho >= 0.0:
		return rho
	return BeastMat.density(p.mat)


## Rest-pose global transforms, one per bone, with the root at the origin.
func rest_transforms() -> Array[Transform3D]:
	var out: Array[Transform3D] = []
	out.resize(bones.size())
	for i in bones.size():
		var b: RigBone = bones[i]
		var local := Transform3D(Basis.IDENTITY, b.offset)
		if b.parent.is_empty():
			out[i] = local
		else:
			out[i] = out[bone_index(b.parent)] * local
	return out


## Bone names whose geometry must be ignored when judging floor contact during a
## collapse: an arm flung under the body must not jack the corpse off the ground.
func limb_bones() -> Dictionary:
	var out: Dictionary = {}
	for a in arms:
		out[a.shoulder] = true
		out[a.elbow] = true
		out[a.wrist] = true
	if aim != null and not aim.bone.is_empty():
		out[aim.bone] = true
	return out


func _rebuild_index() -> void:
	_index.clear()
	for i in bones.size():
		_index[bones[i].name] = i


func _new_part(
	b: StringName, s: RigPart.Shape, c: Vector3, m: StringName, o: Dictionary
) -> RigPart:
	var p := RigPart.new()
	p.bone = b
	p.shape = s
	p.center = c
	p.mat = m
	var rot: Vector3 = o.get("rot", Vector3.ZERO)
	p.rot = rot
	p.col_override = String(o.get("col", ""))
	if o.get("seg") != null:
		p.seg = int(o["seg"])
	if o.get("rho") != null:
		p.rho = float(o["rho"])
	p.fxs = float(o.get("fxs", 0.0))
	return p
