class_name RigPart
extends Resource
## One welded primitive on one bone. Three shapes only — box, cone-frustum, sphere.
##
## `center` and `rot` are in the owning bone's local frame, so a part never moves
## relative to its bone. The analytic measures below are exact and are what the
## mass, armour-coverage and bounds figures are calibrated against; substituting
## an AABB approximation changes every stat in the roster.

enum Shape { BOX, CYL, SPH }

@export var bone: StringName = &""
@export var shape: Shape = Shape.BOX
@export var center: Vector3 = Vector3.ZERO
@export var rot: Vector3 = Vector3.ZERO
@export var mat: StringName = &"steel"
## Per-part colour override. Empty means "use the material's own colour".
@export var col_override: String = ""
## Box full extents, centred on `center`.
@export var dims: Vector3 = Vector3.ONE
## Cone frustum: radius at the +Y end, radius at the -Y end, height along local +Y.
@export_range(0.0, 0.6, 0.001, "or_greater") var r0: float = 0.0
@export_range(0.0, 0.6, 0.001, "or_greater") var r1: float = 0.0
@export_range(0.0, 2.0, 0.001, "or_greater") var height: float = 0.0
## Sphere radius.
@export_range(0.0, 0.6, 0.001, "or_greater") var radius: float = 0.0
## Radial segment override for a cylinder. -1 picks from the radius.
@export_range(-1, 24, 1) var seg: int = -1
## Per-part density override in kg/m3. -1 inherits from the rig.
@export_range(-1.0, 9000.0, 1.0, "or_greater") var rho: float = -1.0
## Muzzle-flash scale multiplier. Only the four `flash` spheres use it.
@export_range(0.0, 6.0, 0.05) var fxs: float = 0.0


## Local transform of the primitive within its bone.
func local_transform() -> Transform3D:
	return Transform3D(Basis.from_euler(rot, EULER_ORDER_XYZ), center)


## Exact solid volume in m3.
func volume() -> float:
	match shape:
		Shape.BOX:
			return dims.x * dims.y * dims.z
		Shape.CYL:
			return PI * height / 3.0 * (r0 * r0 + r0 * r1 + r1 * r1)
	return 4.0 / 3.0 * PI * radius * radius * radius


## Exact surface area in m2. The frustum counts BOTH end caps even when a radius
## is zero — the degenerate term simply vanishes — and the `cover` stat depends on
## that, so it is not an oversight to be tidied.
func area() -> float:
	match shape:
		Shape.BOX:
			return 2.0 * (dims.x * dims.y + dims.y * dims.z + dims.x * dims.z)
		Shape.CYL:
			var slant: float = sqrt(height * height + (r0 - r1) * (r0 - r1))
			return PI * (r0 + r1) * slant + PI * (r0 * r0 + r1 * r1)
	return 4.0 * PI * radius * radius


## Half-extents of the primitive's local bounding box.
func extent() -> Vector3:
	match shape:
		Shape.BOX:
			return dims * 0.5
		Shape.CYL:
			var r: float = maxf(r0, r1)
			return Vector3(r, height * 0.5, r)
	return Vector3(radius, radius, radius)


## Radial segment count. Mirrors the reference's tessellation so silhouettes match.
func radial_segments() -> int:
	if seg > 0:
		return seg
	if shape == Shape.CYL:
		return 12 if r0 + r1 > 0.22 else 8
	return 12 if radius > 0.14 else 8
