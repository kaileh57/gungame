class_name BeastCollide
extends RefCounted
## Analytic distance queries over the posed primitive shell.
##
## These are what the bake's joint validator measures with, and they are also the
## cheapest correct way to do enemy-vs-enemy separation and precise limb hit
## resolution at runtime: no physics bodies, no capsule approximation, no per-limb
## `Area3D` churn following a skeleton.
##
## `penetration()` returns POSITIVE when two primitives overlap. A joint whose
## best parent/child overlap is at or below zero is a visible seam, and that is
## precisely the failure the project's no-air-gaps rule forbids.

## Samples taken along a cylinder axis when testing it against a box.
const CYL_BOX_STEPS: int = 24
## Below this squared length a separating-axis cross product is degenerate.
const AXIS_EPS: float = 1e-10
## Ericson's degeneracy epsilon for the segment-segment solve.
const SEG_EPS: float = 1e-12


## World-space (strictly: rig-space) primitive for a part under a bone transform.
static func world_prim(p: RigPart, m: Transform3D) -> Dictionary:
	var pos: Vector3 = m.origin
	var q: Quaternion = m.basis.get_rotation_quaternion()
	var sc: Vector3 = m.basis.get_scale()
	match p.shape:
		RigPart.Shape.SPH:
			return {"s": RigPart.Shape.SPH, "c": pos, "r": p.radius * sc.x}
		RigPart.Shape.CYL:
			var ax: Vector3 = q * Vector3.UP
			return {
				"s": RigPart.Shape.CYL,
				"a": pos + ax * (p.height * 0.5 * sc.y),
				"b": pos - ax * (p.height * 0.5 * sc.y),
				"r0": p.r0 * sc.x,
				"r1": p.r1 * sc.x
			}
	return {
		"s": RigPart.Shape.BOX,
		"c": pos,
		"e": Vector3(p.dims.x * 0.5 * sc.x, p.dims.y * 0.5 * sc.y, p.dims.z * 0.5 * sc.z),
		"ax": [q * Vector3.RIGHT, q * Vector3.UP, q * Vector3.BACK]
	}


## Radius of a cone frustum at parameter `t`, with t = 0 at the +Y (`a`) end.
static func cyl_r(c: Dictionary, t: float) -> float:
	return float(c["r0"]) + (float(c["r1"]) - float(c["r0"])) * t


## Closest point to `pt` inside an oriented box.
static func pt_box(pt: Vector3, b: Dictionary) -> Vector3:
	var d: Vector3 = pt - Vector3(b["c"])
	var e: Vector3 = b["e"]
	var ax: Array = b["ax"]
	var out: Vector3 = b["c"]
	out += Vector3(ax[0]) * clampf(d.dot(ax[0]), -e.x, e.x)
	out += Vector3(ax[1]) * clampf(d.dot(ax[1]), -e.y, e.y)
	out += Vector3(ax[2]) * clampf(d.dot(ax[2]), -e.z, e.z)
	return out


## Ericson's closest points on two segments. Parallel and collinear pairs fall to
## the `s = 0` branch and fix `t` by clamping; every straight limb chain lands
## there, so that branch is the common case rather than an edge case.
static func seg_closest(p1: Vector3, q1: Vector3, p2: Vector3, q2: Vector3) -> Dictionary:
	var d1: Vector3 = q1 - p1
	var d2: Vector3 = q2 - p2
	var r: Vector3 = p1 - p2
	var a: float = d1.dot(d1)
	var e: float = d2.dot(d2)
	var f: float = d2.dot(r)
	var s: float = 0.0
	var t: float = 0.0
	if a <= SEG_EPS and e <= SEG_EPS:
		return {"p": p1, "q": p2, "s": 0.0, "t": 0.0}
	if a <= SEG_EPS:
		t = clampf(f / e, 0.0, 1.0)
	else:
		var c: float = d1.dot(r)
		if e <= SEG_EPS:
			s = clampf(-c / a, 0.0, 1.0)
		else:
			var b: float = d1.dot(d2)
			var denom: float = a * e - b * b
			if absf(denom) > SEG_EPS:
				s = clampf((b * f - c * e) / denom, 0.0, 1.0)
			t = (b * s + f) / e
			if t < 0.0:
				t = 0.0
				s = clampf(-c / a, 0.0, 1.0)
			elif t > 1.0:
				t = 1.0
				s = clampf((b - c) / a, 0.0, 1.0)
	return {"p": p1 + d1 * s, "q": p2 + d2 * t, "s": s, "t": t}


## Positive when the two primitives overlap, in metres of interpenetration.
static func penetration(a: Dictionary, b: Dictionary) -> float:
	var out: float = 0.0
	match int(a["s"]) * 3 + int(b["s"]):
		0:
			out = _box_box(a, b)
		1:
			out = _cyl_box(b, a)
		2:
			out = _sph_box(b, a)
		3:
			out = _cyl_box(a, b)
		4:
			out = _cyl_cyl(a, b)
		5:
			out = _sph_cyl(b, a)
		6:
			out = _sph_box(a, b)
		7:
			out = _sph_cyl(a, b)
		_:
			out = float(a["r"]) + float(b["r"]) - Vector3(a["c"]).distance_to(b["c"])
	return out


## Lowest rig-space Y of a primitive, exact rather than AABB-approximated.
static func prim_low_y(o: Dictionary) -> float:
	match int(o["s"]):
		RigPart.Shape.SPH:
			var sc: Vector3 = o["c"]
			return sc.y - float(o["r"])
		RigPart.Shape.CYL:
			var pa: Vector3 = o["a"]
			var pb: Vector3 = o["b"]
			var ax: Vector3 = (pa - pb).normalized()
			var k: float = sqrt(maxf(0.0, 1.0 - ax.y * ax.y))
			return minf(pa.y - float(o["r0"]) * k, pb.y - float(o["r1"]) * k)
	var c: Vector3 = o["c"]
	var e: Vector3 = o["e"]
	var ax_list: Array = o["ax"]
	var spread: float = (
		absf(Vector3(ax_list[0]).y) * e.x
		+ absf(Vector3(ax_list[1]).y) * e.y
		+ absf(Vector3(ax_list[2]).y) * e.z
	)
	return c.y - spread


## Highest rig-space Y of a primitive. Same support functions, opposite sign.
static func prim_high_y(o: Dictionary) -> float:
	match int(o["s"]):
		RigPart.Shape.SPH:
			var sc: Vector3 = o["c"]
			return sc.y + float(o["r"])
		RigPart.Shape.CYL:
			var pa: Vector3 = o["a"]
			var pb: Vector3 = o["b"]
			var ax: Vector3 = (pa - pb).normalized()
			var k: float = sqrt(maxf(0.0, 1.0 - ax.y * ax.y))
			return maxf(pa.y + float(o["r0"]) * k, pb.y + float(o["r1"]) * k)
	var c: Vector3 = o["c"]
	var e: Vector3 = o["e"]
	var ax_list: Array = o["ax"]
	var spread: float = (
		absf(Vector3(ax_list[0]).y) * e.x
		+ absf(Vector3(ax_list[1]).y) * e.y
		+ absf(Vector3(ax_list[2]).y) * e.z
	)
	return c.y + spread


static func _sph_box(s: Dictionary, b: Dictionary) -> float:
	# Returns the radius verbatim when the centre is inside the box. That is not a
	# degenerate case to guard against: it is the invariant that seals every
	# shoulder, because a joint ball sits exactly on a pivot buried in the torso.
	return float(s["r"]) - Vector3(s["c"]).distance_to(pt_box(s["c"], b))


static func _sph_cyl(s: Dictionary, c: Dictionary) -> float:
	var pa: Vector3 = c["a"]
	var d: Vector3 = Vector3(c["b"]) - pa
	var len2: float = d.length_squared()
	var t: float = 0.0
	if len2 > SEG_EPS:
		t = clampf((Vector3(s["c"]) - pa).dot(d) / len2, 0.0, 1.0)
	var p: Vector3 = pa + d * t
	return float(s["r"]) + cyl_r(c, t) - Vector3(s["c"]).distance_to(p)


static func _cyl_cyl(a: Dictionary, b: Dictionary) -> float:
	var r: Dictionary = seg_closest(a["a"], a["b"], b["a"], b["b"])
	var dist: float = Vector3(r["p"]).distance_to(r["q"])
	return cyl_r(a, r["s"]) + cyl_r(b, r["t"]) - dist


static func _cyl_box(c: Dictionary, b: Dictionary) -> float:
	var pa: Vector3 = c["a"]
	var d: Vector3 = Vector3(c["b"]) - pa
	var best: float = -INF
	for i in CYL_BOX_STEPS + 1:
		var t: float = float(i) / float(CYL_BOX_STEPS)
		var p: Vector3 = pa + d * t
		best = maxf(best, cyl_r(c, t) - p.distance_to(pt_box(p, b)))
	return best


## Separating-axis test. The magnitude of a NEGATIVE result is meaningless — the
## scan early-outs on the first separating axis — so only its sign is usable.
static func _box_box(a: Dictionary, b: Dictionary) -> float:
	var aa: Array = a["ax"]
	var ba: Array = b["ax"]
	var ea: Vector3 = a["e"]
	var eb: Vector3 = b["e"]
	var delta: Vector3 = Vector3(b["c"]) - Vector3(a["c"])
	var axes: Array[Vector3] = [aa[0], aa[1], aa[2], ba[0], ba[1], ba[2]]
	for i in 3:
		for j in 3:
			var cross: Vector3 = Vector3(aa[i]).cross(ba[j])
			if cross.length_squared() > AXIS_EPS:
				axes.append(cross.normalized())
	var best: float = INF
	for ax in axes:
		var ra: float = (
			absf(Vector3(aa[0]).dot(ax)) * ea.x
			+ absf(Vector3(aa[1]).dot(ax)) * ea.y
			+ absf(Vector3(aa[2]).dot(ax)) * ea.z
		)
		var rb: float = (
			absf(Vector3(ba[0]).dot(ax)) * eb.x
			+ absf(Vector3(ba[1]).dot(ax)) * eb.y
			+ absf(Vector3(ba[2]).dot(ax)) * eb.z
		)
		var overlap: float = ra + rb - absf(delta.dot(ax))
		if overlap <= 0.0:
			return overlap
		best = minf(best, overlap)
	return best
