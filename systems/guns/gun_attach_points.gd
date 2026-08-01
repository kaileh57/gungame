class_name GunAttachPoints
extends RefCounted
## Where things happen on an assembled weapon, read off the geometry rather than
## guessed. Everything here is in MODEL UNITS in the gun's own frame, where +X is
## the muzzle direction, +Y is up and +Z is the shooter's right.
##
## The reference never needed these: it aimed by shoving the weapon's bounding box
## onto the view axis, which lines the camera up with the top of whatever the gun
## happens to be tallest at. `sight` replaced that with a solve off the real optic,
## and the ADS pose puts that point on the view axis exactly.
##
## THAT WAS NOT ENOUGH, and this is the part worth reading. Putting a POINT on the
## axis says nothing about the receiver, the magazine, the stock comb and the optic
## that surround it. These parts are solid slabs with no aperture: the sight datum
## for a fitted optic is a quarter of the way down the sight part's own box and for
## a scope it is the middle of the tube, so the crosshair sat INSIDE the geometry.
## Measured over 111 rolled weapons — every receiver class, irons and optics and
## scopes, every tier — the view axis was inside the weapon's own triangles on 78
## of them.
##
## So `sight` is no longer the optic's centre. It is the EYE LINE: the height your
## eye has to sit at for the whole weapon to pass below your aim, which is what
## looking over a set of irons or over a scope actually is. It is derived in two
## stages, both from the geometry and neither from a constant offset:
##
##   * `for_spec` raises it above the assembly's own bounding box by `clearance`
##     model units, which is a hard guarantee that nothing is on the axis: at full
##     ADS the axis is a line parallel to +X at `(sight.y, sight.z)`, so "no
##     geometry above the axis" is exactly "no geometry with y > sight.y".
##   * `raise_eye_line` then trades that flat margin for an ANGULAR one, using
##     `crest` — the top-rear corner of every fitted part — so the weapon's highest
##     point lands the same number of degrees below the crosshair whether it is a
##     snubnose or a machine gun.
##
## `bore` is the line the round leaves on. It passes through `muzzle` along +X and
## it is deliberately BELOW the eye line: iron sights and scopes sit above the
## barrel on a real gun, and the viewmodel keeps that offset rather than cheating
## the bore up to the eye.

## Muzzle direction and bore axis in gun-local space. Not a tunable — the entire
## part library is authored with the muzzle pointing down +X.
const BORE_AXIS: Vector3 = Vector3.RIGHT
## Below this an eye-relief figure is meaningless and the angular solve is skipped
## rather than dividing by it.
const MIN_RELIEF: float = 1.0e-4

## Assembled bounds in model units, from the baked mesh AABBs through each part's
## fitted transform, so it accounts for scaling and for the joint overlaps.
var bounds: AABB = AABB()
## Muzzle crown, on the bore line.
var muzzle: Vector3 = Vector3.ZERO
## Muzzle-end radius in model units, fitted scale applied. Sizes the flash and the
## smoke. -1 when the barrel part carried no radius proxy.
var muzzle_radius: float = -1.0
## Where brass leaves the action.
var eject: Vector3 = Vector3.ZERO
## The eye line: put the camera here, looking down +X, and the sight is in front
## of you and the whole weapon is below you.
var sight: Vector3 = Vector3.ZERO
## Where the sight picture itself is — the optic's centre, or the notch over the
## irons — before the eye line was raised to clear the body. This is what the
## shooter is looking AT; `sight` is where he is looking FROM.
var sight_datum: Vector3 = Vector3.ZERO
## Top-rear corner of every fitted part's assembled box, `(x, y)` in model units.
## The silhouette the eye line has to stay above, in the order the parts are fitted.
var crest: PackedVector2Array = PackedVector2Array()
## True when `sight_datum` is the axis of a real scope tube rather than a notch to
## squint over. Drives whether the ADS blend leans in or hands off to the scope.
var sight_optical: bool = false
## False when the spec or the part library could not supply geometry. Callers must
## not pose a viewmodel from an invalid solve.
var valid: bool = false


## Derive every attach point from a spec alone. No scene tree, no nodes — this runs
## headless, which is how the ADS alignment is verified at bake time.
##
## `iron_height` is how far above the receiver's top rail the notch of a set of iron
## sights sits, in model units. `notch` is how far down from the top of a fitted
## sight part the sight picture is, as a fraction of that part's height.
## `clearance` is the flat margin the eye line keeps above the whole assembly, also
## in model units; it is what guarantees an unoccluded axis before any pose exists.
## Zero asks for no clearing at all and leaves the eye line on the sight picture,
## which is the behaviour that put the crosshair inside the gun — it exists so the
## occlusion probe can measure the old solve and the new one in the same run.
static func for_spec(
	spec: GunSpec, iron_height: float = 0.10, notch: float = 0.25, clearance: float = 0.03
) -> GunAttachPoints:
	var out := GunAttachPoints.new()
	if spec == null or spec.part_count() < 4 or not PartLibrary.is_loaded():
		return out
	var receiver: GunPart = PartLibrary.part(spec.receiver_index())
	var barrel: GunPart = PartLibrary.part(spec.barrel_index())
	if receiver == null or barrel == null:
		return out

	out.bounds = GunFactory.assembly_aabb(spec)
	out.muzzle = spec.muzzle_local
	if barrel.muzzle_radius > 0.0:
		out.muzzle_radius = barrel.muzzle_radius * spec.part_scales[1]
	out.eject = _eject_from_receiver(receiver)
	out._solve_crest(spec)
	out._solve_sight(spec, receiver, iron_height, notch)
	out.sight_datum = out.sight
	# The flat guarantee. Everything is below the axis from here on, whatever the
	# pose then does with the angle.
	if clearance > 0.0:
		out.sight.y = maxf(out.sight.y, out.bounds.end.y + clearance)
	out.valid = true
	return out


## Prefer the markers `GunFactory.build_node` authored, when a built node is to
## hand. They are the same geometry this class derives; taking them from the node
## keeps one authority for anything that reads the scene instead of the spec.
func adopt_markers(node: Node3D) -> void:
	if node == null:
		return
	var m := node.get_node_or_null(^"Muzzle") as Marker3D
	if m != null:
		muzzle = m.position
	var e := node.get_node_or_null(^"Eject") as Marker3D
	if e != null:
		eject = e.position


## The eye-line height that keeps every part at least `tan_clear` below the view
## axis. Pure: it reads the solve and does not change it, so a pose can try several
## scales before committing to one.
##
## `relief_units` is how far the eye is from the assembly's REAR face, expressed in
## model units — `standoff / scale` for a pose that stands the butt off by
## `standoff` metres at uniform scale `scale`. Working in model units is what keeps
## this pure: the shouldered rotation maps gun-local +X onto the view axis, so a
## part's top-front corner at `(x, y)` is seen at elevation
## `(y - axis) / (relief_units + x - rear)`, and the whole solve is one comparison
## per fitted part with no metres and no camera in it.
func eye_line(relief_units: float, tan_clear: float) -> float:
	var y: float = sight.y
	if not valid or relief_units <= MIN_RELIEF or tan_clear <= 0.0:
		return y
	var rear: float = bounds.position.x
	for point: Vector2 in crest:
		y = maxf(y, point.y + tan_clear * (relief_units + point.x - rear))
	return y


## Commit `eye_line` onto `sight`, and return where it settled.
func raise_eye_line(relief_units: float, tan_clear: float) -> float:
	sight.y = eye_line(relief_units, tan_clear)
	return sight.y


## How far an eye line at `axis_y` sits below the sight picture, as a tangent, for
## an eye `relief_units` model units off the assembly's rear face. Zero when the
## optic is the highest thing on the weapon and the eye looks straight over it;
## large when something else — almost always a tall stock comb right under the eye
## — forced the line up and buried the sight.
func drop_tangent(axis_y: float, relief_units: float) -> float:
	var span: float = relief_units + sight_datum.x - bounds.position.x
	if span <= MIN_RELIEF:
		return 0.0
	return maxf(axis_y - sight_datum.y, 0.0) / span


## Distance from the eye point to the muzzle along the bore, in model units. This
## is the sight radius plus the barrel: how much gun you see when you aim.
func sight_to_muzzle() -> float:
	return maxf(muzzle.x - sight.x, 0.0)


## How far the eye line sits above the bore, in model units. A tall scope on a low
## receiver reads immediately as a taller number here.
func sight_over_bore() -> float:
	return sight.y


## The bore as a ray in gun-local space, for anyone tracing where the round goes
## without going through the viewmodel pose.
func bore_at(distance: float) -> Vector3:
	return muzzle + BORE_AXIS * distance


## Ejection port, in model units: off the receiver's right shoulder, level with the
## top rail. Mirrors the marker `GunFactory.build_node` places, so a spec-only
## caller and a node-reading caller agree. `build_gun_cache.gd` asserts that they do.
static func _eject_from_receiver(receiver: GunPart) -> Vector3:
	var top: GunSocket = receiver.socket_top
	var x: float = top.position.x if top != null else 0.0
	var y: float = (top.position.y * 0.5) if top != null else 0.2
	return Vector3(x, y, receiver.ext.z * 0.5 + 0.06)


## The silhouette, one point per fitted part: the top of its assembled box paired
## with the box's FRONT face.
##
## The front, not the rear, and this is the one place the sign matters. Holding a
## fixed ANGLE below the eye costs more height the further away the geometry is —
## `axis >= y + tan_clear * (relief + x - rear)` grows with x — so the corner that
## binds is the top-front one. Solving on the rear corner instead clears the butt
## and lets the muzzle end creep back up toward the crosshair, which is the end of
## the weapon a shooter is actually looking past.
func _solve_crest(spec: GunSpec) -> void:
	crest = PackedVector2Array()
	for i: int in spec.part_count():
		var mesh: ArrayMesh = PartLibrary.mesh_for(spec.part_indices[i])
		if mesh == null:
			continue
		var box: AABB = spec.part_transform(i) * mesh.get_aabb()
		crest.append(Vector2(box.end.x, box.end.y))


## The sight picture — what the shooter is looking at, not where from.
##
## With a scope fitted the picture is the tube's axis, the centre of the fitted
## sight part's assembled box. With anything else fitted it is just under the top
## of the part, so the blade or the ring reads as a shape rather than as a wall.
## With nothing fitted the receiver's own top rail carries the notch.
func _solve_sight(spec: GunSpec, receiver: GunPart, iron_height: float, notch: float) -> void:
	var index: int = spec.sight_index()
	if index >= 0:
		var mesh: ArrayMesh = PartLibrary.mesh_for(index)
		if mesh != null:
			var box: AABB = spec.part_transform(4) * mesh.get_aabb()
			var centre: Vector3 = box.position + box.size * 0.5
			sight_optical = spec.scoped
			var y: float = centre.y if sight_optical else box.end.y - box.size.y * notch
			sight = Vector3(centre.x, y, centre.z)
			sight.y = maxf(sight.y, iron_height)
			return
	var top: GunSocket = receiver.socket_top
	if top != null:
		sight = Vector3(top.position.x, top.position.y + iron_height, top.position.z)
	else:
		sight = Vector3(0.0, receiver.ext.y * 0.5 + iron_height, 0.0)
