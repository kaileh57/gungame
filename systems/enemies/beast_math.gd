class_name BeastMath
extends RefCounted
## Scalar, quaternion and two-bone-IK maths shared by every bestiary rig.
##
## Ported from `reference/bestiary (3).html`. Three conventions are load-bearing and
## are reproduced here rather than tidied away:
##
## * `smooth()` is never clamped internally — every call site clamps its own input.
##   Feeding it t > 1 overshoots, which the reference relies on nowhere.
## * `quat_from_unit_vectors()` reproduces three.js's anti-parallel fallback, which
##   derives a perpendicular from the input vector. Godot's `Quaternion(a, b)` picks
##   a fixed +Y instead, so death replays would diverge the moment a limb points
##   exactly opposite its rest direction.
## * `ik2()` normalises the reach direction by the UNCLAMPED distance while solving
##   the cosine rule with the CLAMPED one. Over-extended targets therefore keep
##   their heading and pull the tip in to the chain length instead of flipping.

## Below this, a dot product of two unit vectors counts as anti-parallel.
const UNIT_EPS: float = 1e-6
## Cosine of the polar angle past which `look_q` swaps its up vector.
const LOOK_POLE: float = 0.985


## smoothstep, unclamped. Callers clamp.
static func smooth(t: float) -> float:
	return t * t * (3.0 - 2.0 * t)


## Base-10 logarithm; GDScript only ships the natural one.
static func log10(v: float) -> float:
	return log(v) / log(10.0)


## three.js `Quaternion.setFromUnitVectors`. Both arguments must be unit length.
static func quat_from_unit_vectors(a: Vector3, b: Vector3) -> Quaternion:
	var r: float = a.dot(b) + 1.0
	if r < UNIT_EPS:
		if absf(a.x) > absf(a.z):
			return Quaternion(-a.y, a.x, 0.0, 0.0).normalized()
		return Quaternion(0.0, -a.z, a.y, 0.0).normalized()
	var c: Vector3 = a.cross(b)
	return Quaternion(c.x, c.y, c.z, r).normalized()


## Quaternion whose local +Z lies along `dir` — the reference's `lookQ`.
## Godot's `Basis.looking_at` aims -Z, hence the negation.
static func look_q(dir: Vector3) -> Quaternion:
	if dir.length_squared() < 1e-12:
		return Quaternion.IDENTITY
	var d: Vector3 = dir.normalized()
	var up: Vector3 = Vector3.UP
	if absf(d.y) > LOOK_POLE:
		up = Vector3(0.0, 0.0, -signf(d.y))
	return Basis.looking_at(-d, up).get_rotation_quaternion()


## Euler XYZ of the rotation taking +Y onto `d`. Orients a tube segment.
static func dir_euler(d: Vector3) -> Vector3:
	if d.length_squared() < 1e-12:
		return Vector3.ZERO
	var q: Quaternion = quat_from_unit_vectors(Vector3.UP, d.normalized())
	return Basis(q).get_euler(EULER_ORDER_XYZ)


## Place a two-link chain from `h` to `t`, elbow/knee pushed toward `pole`.
## Returns `thigh` and `shin` as unit directions plus the resolved `knee`/`tgt`.
static func ik2(h: Vector3, t: Vector3, l1: float, l2: float, pole: Vector3) -> Dictionary:
	var v: Vector3 = t - h
	var d: float = v.length()
	var lo: float = absf(l1 - l2) + 1e-4
	var hi: float = l1 + l2 - 1e-4
	if d < 1e-6:
		# Degenerate target: fall straight down. The reference leaves `v` unscaled
		# here and produces a 1e6-long direction; a unit one is what it meant.
		v = Vector3(0.0, -1e-6, 0.0)
		d = 1e-6
	var dc: float = clampf(d, lo, hi)
	var dir: Vector3 = v / d
	var cosine: float = (l1 * l1 + dc * dc - l2 * l2) / (2.0 * l1 * dc)
	var a: float = acos(clampf(cosine, -1.0, 1.0))
	var axis: Vector3 = dir.cross(pole)
	if axis.length_squared() < 1e-9:
		axis = Vector3(1.0, 0.0, 0.0)
	else:
		axis = axis.normalized()
	var thigh: Vector3 = dir.rotated(axis, a)
	var knee: Vector3 = h + thigh * l1
	var tgt: Vector3 = h + dir * dc
	return {"thigh": thigh, "shin": (tgt - knee).normalized(), "knee": knee, "tgt": tgt}


## Closed-form muzzle-on-target for a rigid weapon pivoting about `anchor`.
##
## The muzzle sits at `m` in the weapon's local frame and the bore runs along `f`,
## so aiming the pivot is not aiming the muzzle. Solve |m + lambda*f| = |t - anchor|
## for the point on the bore at target range, then rotate that point onto the
## target direction. `up_local` is the weapon's own up, used to level it; `roll` is
## an authored twist about the bore.
static func aim_quat(
	anchor: Vector3, m: Vector3, f: Vector3, t: Vector3, up_local: Vector3, roll: float
) -> Quaternion:
	var dv: Vector3 = t - anchor
	var d: float = dv.length()
	if d < 1e-5:
		return Quaternion.IDENTITY
	var mf: float = m.dot(f)
	var m2: float = m.length_squared()
	var lam: float = -mf + sqrt(maxf(mf * mf - m2 + d * d, 1e-8))
	var uv: Vector3 = m + f * lam
	if uv.length_squared() < 1e-10:
		uv = f
	uv = uv.normalized()
	dv = dv.normalized()
	var out: Quaternion = quat_from_unit_vectors(uv, dv)
	# Free roll about the aim axis: bring the weapon's own up as near vertical as
	# the bore allows. Applied in RIG space, hence the pre-multiply.
	var yv: Vector3 = out * up_local
	var pa: Vector3 = yv - dv * yv.dot(dv)
	var pb: Vector3 = Vector3(0.0, 1.0, 0.0) - dv * dv.y
	if pa.length_squared() > 1e-8 and pb.length_squared() > 1e-8:
		pa = pa.normalized()
		pb = pb.normalized()
		var ang: float = acos(clampf(pa.dot(pb), -1.0, 1.0))
		if pa.cross(pb).dot(dv) < 0.0:
			ang = -ang
		out = Quaternion(dv, ang) * out
	if roll != 0.0:
		# Authored twist is in WEAPON space, hence the post-multiply.
		out = out * Quaternion(f.normalized(), roll)
	return out


## FNV-1a 32-bit with a wrapping multiply, returned as a signed int32.
## Seeds the per-material surface noise offset.
static func hash_str(t: String) -> int:
	var h: int = 2166136261
	for i in t.length():
		h = (h ^ t.unicode_at(i)) & 0xFFFFFFFF
		h = (h * 16777619) & 0xFFFFFFFF
	if h < 0x80000000:
		return h
	return h - 0x100000000
