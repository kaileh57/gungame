class_name CourseKit
extends RefCounted
## The set of parts the movement course is welded from, and the one rule that
## makes it trustworthy: MESH AND COLLISION COME OUT OF THE SAME CALL.
##
## `solid()` emits an outward-wound closed box into the shared `WorldMesher` and,
## in the same breath, a `BoxShape3D` at the same centre with the same basis and
## the same half-extents. Nothing else in this file touches geometry, so the thing
## you see and the thing you collide with cannot drift apart — which for a
## movement playground is the difference between a measurement and a guess.
##
## Everything here is bake-time. `res://tools/build_movement.gd` drives it once,
## headless, and ships an ArrayMesh and a .tscn; none of this runs in the demo.
##
## JOINTS OVERLAP, NEVER BUTT, AND NO TWO FACES ARE EVER COPLANAR. Posts sink into
## the apron, boards are wider than the posts that hold them, lintels are narrower
## than the columns they span, and ramps climb a few centimetres past the deck they
## meet. Each of those is a deliberate choice against a z-fighting seam or a gap
## you can see daylight through.

## The accumulated course. One surface, one draw call, world-space vertices — see
## the note at the top of `WorldMesher` for why they stay in world space.
var mesh: WorldMesher = WorldMesher.new()
## Closed boxes emitted so far, colliders and mesh-only alike.
var solids: int = 0
## Label3D nodes handed out. Text is the only thing on the course that costs a
## draw call each, which is why every one of them carries a draw distance.
var labels: int = 0

var _rng: XorShift32 = null
var _font: Font = null


## `seed` drives nothing but colour choice, and `font` is used by every sign.
func _init(seed: int, font: Font) -> void:
	_rng = XorShift32.new(seed)
	_font = font


# ------------------------------------------------------------------- geometry


## The only place geometry is created. `body` may be null for decoration that
## should not collide — ladder rungs, and nothing else on this course.
func solid(
	body: StaticBody3D, center: Vector3, basis: Basis, half: Vector3, col: Color, surf: int
) -> void:
	mesh.oriented_box(center, basis.x * half.x, basis.y * half.y, basis.z * half.z, col, surf)
	solids += 1
	if body == null:
		return
	var shape := BoxShape3D.new()
	shape.size = half * 2.0
	var node := CollisionShape3D.new()
	node.name = "S%03d" % body.get_child_count()
	node.shape = shape
	node.transform = Transform3D(basis, center)
	# `PlayerController._read_surface` reads this off whatever it landed on, which
	# is how a footstep on the tin tower deck sounds different from the concrete.
	node.set_meta(&"surf", surf)
	body.add_child(node)


## Axis-aligned convenience for the nine tenths of the course that stands upright.
func box(
	body: StaticBody3D, center: Vector3, half: Vector3, col: Color, surf: int, yaw: float = 0.0
) -> void:
	solid(body, center, Basis(Vector3.UP, yaw), half, col, surf)


## A slab whose TOP FACE starts at `foot` and climbs at `angle` for `run` metres
## along the heading `yaw` (0 climbs toward +X, PI/2 toward -Z). Returns the world
## point the top face reaches.
##
## `ends.x` buries the toe that many metres below the apron, so that joint is an
## overlap rather than a lip. `ends.y` is the RISE the slab is carried past its
## nominal top, and it is how a ramp meets a platform without either a step up or
## a pair of coplanar faces: the slab keeps climbing into the platform's body, so
## the last thing underfoot is a few centimetres of hump and then a silent drop
## onto the deck. Six centimetres is a fifth of `snap_probe` and reads as nothing.
##
## `yaw` turns the whole slab about Y, slope vector and cross-slope alike, so the
## basis stays right-handed no matter which way the lane points. The course needs
## it because a fan of ramps only reads as a fan when it is climbing AWAY from the
## bench rather than sideways across it.
func ramp(
	body: StaticBody3D,
	foot: Vector3,
	angle: float,
	run: float,
	half_width: float,
	thickness: float,
	col: Color,
	surf: int,
	ends: Vector2 = Vector2(0.8, 0.0),
	yaw: float = 0.0
) -> Vector3:
	var turn := Basis(Vector3.UP, yaw)
	var slope: Vector3 = turn * Vector3(cos(angle), sin(angle), 0.0)
	var normal: Vector3 = turn * Vector3(-sin(angle), cos(angle), 0.0)
	var length: float = run / cos(angle)
	var tail: float = 0.0
	if ends.y > 0.0 and absf(sin(angle)) > 0.0001:
		tail = minf(ends.y / absf(sin(angle)), 1.2)
	var total: float = length + ends.x + tail
	var center: Vector3 = foot + slope * (total * 0.5 - ends.x) - normal * thickness
	var half := Vector3(total * 0.5, thickness, half_width)
	solid(body, center, Basis(slope, normal, turn * Vector3.BACK), half, col, surf)
	return foot + slope * length


## Square-section strut, mesh only. Ladder rungs get one of these and no collider:
## a collider on a rung does nothing but shove the climber off the ladder.
func rung(a: Vector3, b: Vector3, radius: float, col: Color, surf: int) -> void:
	mesh.strut(a, b, radius, col, surf)
	solids += 1


## Two posts and a board. Every station gets one, and it is the only place the
## course explains itself in words.
func sign_post(
	parent: Node3D, body: StaticBody3D, at: Vector3, heading: float, title: String, sub: String
) -> void:
	var b: Basis = Basis(Vector3.UP, heading)
	var steel: Color = pick(Palette.WORLD_METAL)
	for s: float in [-1.0, 1.0]:
		var post: Vector3 = at + b.x * (1.7 * s) + Vector3(0.0, 0.85, 0.0)
		box(body, post, Vector3(0.09, 1.15, 0.09), steel, WorldSurface.Kind.METAL, heading)
	# Wider than the posts and shallower than them: no shared plane on any axis.
	var board: Vector3 = at + Vector3(0.0, 2.35, 0.0)
	box(
		body,
		board,
		Vector3(1.9, 0.60, 0.07),
		pick(Palette.WORLD_RUST),
		WorldSurface.Kind.METAL,
		heading
	)
	# Sized to be read from the bench, thirty to fifty metres off, not from arm's
	# length: a station whose name you have to walk to is a station you never find.
	var face: Vector3 = at + b.z * 0.09
	plate(parent, title, face + Vector3(0.0, 2.55, 0.0), heading, 0.42, Palette.BONE)
	plate(parent, sub, face + Vector3(0.0, 2.10, 0.0), heading, 0.26, Palette.ACCENT_ORANGE)


func static_body(parent: Node3D, node_name: String) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = node_name
	body.collision_layer = GameLayers.WORLD
	body.collision_mask = 0
	parent.add_child(body)
	return body


# ----------------------------------------------------------------------- text


## Text painted flat on a horizontal surface, reading toward `heading`. Yaw 0
## reads north, which is the direction the spawn faces.
func stencil(
	parent: Node3D,
	text: String,
	at: Vector3,
	heading: float,
	height: float,
	col: Color,
	range_end: float
) -> Label3D:
	var node: Label3D = label(parent, text, at, height, col, range_end)
	node.transform.basis = Basis(Vector3.UP, heading) * Basis(Vector3.RIGHT, -PI * 0.5)
	return node


## Text on a vertical face, readable by someone the face is pointing at.
func plate(
	parent: Node3D,
	text: String,
	at: Vector3,
	heading: float,
	height: float,
	col: Color,
	range_end: float = 110.0
) -> Label3D:
	var node: Label3D = label(parent, text, at, height, col, range_end)
	node.transform.basis = Basis(Vector3.UP, heading)
	return node


## `height` is the metre height of one line. A 48 px font is 48 * pixel_size
## metres tall, so asking in metres keeps every sign legible from the distance it
## is meant to be read at instead of from wherever the numbers landed.
func label(
	parent: Node3D, text: String, at: Vector3, height: float, col: Color, range_end: float
) -> Label3D:
	var node := Label3D.new()
	node.name = "T%03d" % labels
	labels += 1
	node.text = text
	node.font = _font
	node.font_size = 48
	node.outline_size = 12
	node.modulate = col
	node.outline_modulate = Color(0.035, 0.031, 0.028, 1.0)
	node.pixel_size = height / 48.0
	node.double_sided = false
	node.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	node.visibility_range_end = range_end
	node.position = at
	parent.add_child(node)
	return node


# --------------------------------------------------------------------- colour


## Deterministic shade from one of the palette's world ramps.
func pick(shades: PackedColorArray) -> Color:
	return shades[_rng.next_int(0, shades.size() - 1)]


func concrete() -> Color:
	return pick(Palette.WORLD_CONCRETE)


func steel() -> Color:
	return pick(Palette.WORLD_METAL)


func rusty() -> Color:
	return pick(Palette.WORLD_RUST)


func tin() -> Color:
	return pick(Palette.WORLD_TIN)


# ------------------------------------------------------------------- readback


## Cap every `GeometryInstance3D` under `node` at a draw distance. Thirty-six
## sliders and a hundred stencils stop costing anything the moment you walk to the
## far end of the yard, which is most of the time.
static func set_draw_range(node: Node, range_end: float) -> void:
	for child: Node in node.get_children():
		var geom := child as GeometryInstance3D
		if geom != null:
			geom.visibility_range_end = range_end
		set_draw_range(child, range_end)


## Positive means every shell faces outward; see `WorldMesher.signed_volume`.
func report() -> String:
	return (
		"%d solids, %d triangles, signed volume %.1f m3, %d normal conflicts, %d degenerates"
		% [
			solids,
			mesh.triangle_count(),
			mesh.signed_volume(),
			mesh.normal_conflicts(),
			mesh.degenerate_count(),
		]
	)
