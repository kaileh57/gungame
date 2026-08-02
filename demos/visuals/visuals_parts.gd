class_name VisualsParts
extends RefCounted
## Every piece of geometry this demo authors, and the dimensions it is authored to.
##
## Lifted out of `res://tools/build_visuals.gd` when that file crossed the
## thousand-line cap. The split is not arbitrary: what lives here is the five
## SHELLS — terrace, lamp standard, bulb, weapon rack, control post — each a pure
## function of its own constants that returns a `WorldMesher` and touches nothing
## else. What stayed in the builder is where those shells are placed, what is
## instanced beside them, and how the scene is packed.
##
## Every shell obeys the project rule that authored geometry is a union of CLOSED
## SOLIDS: boxes overlap their neighbours rather than butting against them, and
## `VisualsShell.report()` proves it for each one at bake time — positive enclosed
## volume, outward winding, zero open boundary edges.
##
## Nothing here runs at load. `res://tools/build_visuals.gd` calls these once and
## saves the meshes to `res://demos/visuals/*.res`.

const Shot := preload("res://demos/visuals/visuals_shot.gd")

## Half-extents of the level top course, metres. Everything built stands inside it.
const PAD_HALF: Vector2 = Vector2(56.0, 48.0)
## Each course out from the top is this much wider and this much lower.
const STEP_OUT: float = 4.5
const STEP_DOWN: float = 0.95
const STEP_COUNT: int = 3
## Metres the outermost course starts BELOW the lowest ground under the terrace. A
## buried closed solid cannot open a seam against the terrain, which is why this is
## a graded pad and not a skirt chasing heights.
const PAD_BURY: float = 6.0
const PAD_CLEAR: float = 0.25

## Tread rise of the stair off the back of the deck. Where it stands is `VisualsShot`.
const STEP_RISE: float = 0.6
const STEP_TREADS: int = 4

## Floor albedo. Darker than the terrain's sand: flat ground is the brightest case in
## `world_material.gdshader` (slope-darkening drops out at a straight-up normal), so
## raw terrain colours read as bleached paper here.
const PAD_FLOOR: Color = Color("60503a")
## The deck is read at arm's length. Dusted concrete, not asphalt: the asphalt branch
## carries drift and wear at 9 m and 22 m wavelengths, which on a 21 m slab is one
## blotch that reads as cloud. Warm too — a dark neutral flat under a low sun catches
## only sky and turns blue.
const DECK_FLOOR: Color = Color("6b5f4c")
## Sides on every authored cylinder and cone.
const SEG: int = 12

## The post's face is canted off vertical so you read it looking down, standing at it.
const POST_TOP_Y: float = 1.02
const POST_FACE_TILT: float = deg_to_rad(24.0)
## The two solids anything on the post mounts against, and the raked name plate that
## had its lower line inside the first. One description each, used by the mesher AND
## by the mount, so the two cannot disagree.
const POST_PLINTH_AT: Vector3 = Vector3(0.0, 0.16, 0.0)
const POST_PLINTH_HALF: Vector3 = Vector3(1.30, 0.56, 0.55)
const POST_MAST_AT: Vector3 = Vector3(0.0, 1.72, -0.34)
const POST_MAST_HALF: Vector3 = Vector3(0.66, 0.30, 0.045)
const POST_PLACARD_RAKE_DEG: float = 17.19
const POST_PLACARD_Y: float = 0.72
## Fallback bounds for the name plate: a headless `Label3D` reports no AABB at all,
## because its geometry is a glyph run the text server has not been asked to lay out.
const POST_PLACARD_SIZE: Vector3 = Vector3(1.10, 0.14, 0.0)


## The terrace: closed boxes, each narrower and taller than the last, overlapping by
## a full course in Y so the union is watertight. The deck, kerb and stair are welded
## into the same shell — each reaches the buried bottom, so it stays one solid.
static func pad(site: Vector2, pad_top: float, pad_bottom: float) -> WorldMesher:
	var m := WorldMesher.new()
	for i in STEP_COUNT:
		var out: float = STEP_OUT * float(STEP_COUNT - 1 - i)
		var half := Vector3(PAD_HALF.x + out, 0.0, PAD_HALF.y + out)
		var top: float = pad_top - STEP_DOWN * float(STEP_COUNT - 1 - i)
		half.y = (top - pad_bottom) * 0.5
		# Sand, never concrete: the concrete branch brightens by up to 1.8x, and a
		# hundred metres of it under a low sun reads as poured white.
		var col: Color = PAD_FLOOR if i == STEP_COUNT - 1 else Palette.WORLD_SAND[i]
		m.box(Vector3(site.x, pad_bottom + half.y, site.y), half, 0.0, col, WorldSurface.Kind.SAND)
	# One ramp up the south face. Stacked boxes, not a sloped plane.
	for s in 6:
		var t: float = float(s) / 6.0
		var rise: float = STEP_DOWN * float(STEP_COUNT)
		var y_top: float = pad_top - rise * t
		var depth: float = 1.6
		var z: float = site.y + PAD_HALF.y + STEP_OUT * float(STEP_COUNT - 1) + depth * float(s)
		m.box(
			Vector3(site.x - 30.0, (pad_bottom + y_top) * 0.5, z),
			Vector3(4.2, (y_top - pad_bottom) * 0.5, depth * 0.85),
			0.0,
			Palette.WORLD_SAND[1],
			WorldSurface.Kind.SAND
		)
	_deck(m, site, pad_top, pad_bottom)
	return m


## The lookout deck, its kerb and its stair. Everything is yawed to the hero axis,
## which the mesher takes as an argument, so the terrace is still built out of closed
## boxes and still passes the same three tests.
static func _deck(m: WorldMesher, site: Vector2, pad_top: float, pad_bottom: float) -> void:
	var yaw: float = Shot.VIEW_YAW
	var half: Vector2 = Shot.DECK_HALF
	var deck_top: float = pad_top + Shot.DECK_RISE
	var rise: float = (deck_top - pad_bottom) * 0.5
	var centre: Vector2 = Shot.deck_local(Vector2.ZERO)
	m.box(
		Vector3(site.x + centre.x, pad_bottom + rise, site.y + centre.y),
		Vector3(half.x, rise, half.y),
		yaw,
		DECK_FLOOR,
		WorldSurface.Kind.CONCRETE
	)
	# The street: a slab three centimetres proud of the floor. Proud, not flush — two
	# coplanar faces in one place is the z-fight this project bans. It crosses the left
	# of frame at forty metres, giving the raking light a long flat thing to skim.
	m.box(
		Vector3(site.x - 12.0, pad_top - 0.24, site.y + 14.0),
		Vector3(30.0, 0.27, 4.5),
		0.42,
		Palette.WORLD_ASPHALT[0],
		WorldSurface.Kind.ASPHALT
	)
	# Kerb: four overlapping bars, so the drop has an edge you can see from below. Warm
	# and dark, not neutral concrete: a light neutral bar lying flat under the eye is
	# the one thing in frame with no warm bounce, and reads as a grey rule.
	var kerb: Color = Color("57493a")
	var bars: Array = [
		[Vector2(0.0, -half.y - 0.02), Vector2(half.x + 0.16, 0.16)],
		[Vector2(0.0, half.y + 0.02), Vector2(half.x + 0.16, 0.16)],
		[Vector2(-half.x - 0.02, 0.0), Vector2(0.16, half.y + 0.16)],
		[Vector2(half.x + 0.02, 0.0), Vector2(0.16, half.y + 0.16)],
	]
	for bar: Array in bars:
		var at: Vector2 = Shot.deck_local(bar[0] as Vector2)
		var bh: Vector2 = bar[1]
		var top := Vector3(site.x + at.x, deck_top + 0.01, site.y + at.y)
		m.box(top, Vector3(bh.x, 0.28, bh.y), yaw, kerb, WorldSurface.Kind.CONCRETE)
	# Stair off the back face, at the far end from where you stand: you come up it, pass
	# the console, and walk to the parapet. Each tread reaches the pad bottom and the
	# last stops BELOW the floor — a tread laid ON it puts two faces in one place.
	for t in STEP_TREADS:
		var tread: float = deck_top - STEP_RISE * float(t + 1)
		var at: Vector2 = Shot.deck_local(
			Vector2(Shot.STAIR_LOCAL_X, half.y + 0.55 + 1.10 * float(t))
		)
		m.box(
			Vector3(site.x + at.x, (pad_bottom + tread) * 0.5, site.y + at.y),
			Vector3(3.0, (tread - pad_bottom) * 0.5, 0.62),
			yaw,
			Palette.WORLD_CONCRETE[1],
			WorldSurface.Kind.CONCRETE
		)


## A lamp standard: buried foot, tapered pole, cranked arm and conical shade. Six
## metres to the head, which at a three and a half degree sun is ninety-eight metres
## of shadow — the one thing about "dusk" that can be checked with arithmetic.
static func lamp() -> WorldMesher:
	var m := WorldMesher.new()
	var steel: Color = Palette.WORLD_METAL[0]
	var rust: Color = Palette.WORLD_RUST[0]
	# Foot: buried 0.35 m so the pad swallows the base plate.
	m.box(
		Vector3(0.0, -0.15, 0.0), Vector3(0.34, 0.20, 0.34), 0.0, rust, WorldSurface.Kind.CONCRETE
	)
	m.cylinder(Vector3(0.0, 2.35, 0.0), 0.10, 0.062, 2.45, SEG, steel, WorldSurface.Kind.METAL)
	# Crank: two struts, overlapping the pole head and each other.
	m.strut(
		Vector3(0.0, 4.62, 0.0), Vector3(0.0, 5.05, -0.50), 0.05, steel, WorldSurface.Kind.METAL
	)
	m.strut(
		Vector3(0.0, 5.02, -0.44), Vector3(0.0, 5.06, -1.28), 0.05, steel, WorldSurface.Kind.METAL
	)
	# Shade: a capped cone, wide end down, overlapping the arm tip.
	m.cylinder(Vector3(0.0, 4.90, -1.24), 0.44, 0.10, 0.20, SEG, rust, WorldSurface.Kind.TIN)
	return m


## The filament, on its own emissive mesh so the omni behind it has something to sit in.
static func bulb() -> WorldMesher:
	var m := WorldMesher.new()
	m.cylinder(
		Vector3(0.0, 4.74, -1.24), 0.155, 0.155, 0.055, SEG, Palette.GOLD, WorldSurface.Kind.POLY
	)
	return m


## An A-frame rack: buried sill, two uprights, a back rail, a butt shelf and five
## dividers, so each weapon has a slot to lean in. Every joint overlaps.
static func rack() -> WorldMesher:
	var m := WorldMesher.new()
	var wood: Color = Palette.WORLD_WOOD[0]
	var steel: Color = Palette.WORLD_METAL[1]
	m.box(Vector3(0.0, -0.06, 0.0), Vector3(1.35, 0.10, 0.34), 0.0, wood, WorldSurface.Kind.WOOD)
	for sx in [-1.28, 1.28]:
		m.box(
			Vector3(sx, 0.58, -0.20), Vector3(0.07, 0.66, 0.07), 0.0, wood, WorldSurface.Kind.WOOD
		)
	m.box(Vector3(0.0, 1.14, -0.20), Vector3(1.35, 0.06, 0.07), 0.0, wood, WorldSurface.Kind.WOOD)
	m.box(Vector3(0.0, 0.13, -0.02), Vector3(1.35, 0.05, 0.15), 0.0, steel, WorldSurface.Kind.METAL)
	for i in 6:
		var x: float = -1.20 + 0.48 * float(i)
		m.box(
			Vector3(x, 1.20, -0.20), Vector3(0.035, 0.09, 0.09), 0.0, steel, WorldSurface.Kind.METAL
		)
	return m


## The control post: a steel console on a plinth, with a canted face for the controls
## and a mast behind it for the panel.
##
## Neither colour is straight off the palette. `WORLD_CONCRETE[0]` through the
## shader's concrete branch peaks near 1.8x and, on a plinth you stand over, reads as
## poured white; `WORLD_METAL[0]` is a cool grey, and the console's top faces nothing
## but sky, which turns it navy. Warm dark concrete and the art direction's own steel.
static func post() -> WorldMesher:
	var m := WorldMesher.new()
	var concrete: Color = Color("554c40")
	var steel: Color = Color("4d4a44")
	# Plinth, buried 0.4 m.
	m.box(POST_PLINTH_AT, POST_PLINTH_HALF, 0.0, concrete, WorldSurface.Kind.CONCRETE)
	# Console body, overlapping the plinth top by 6 cm.
	m.box(Vector3(0.0, 0.86, 0.0), Vector3(1.16, 0.24, 0.44), 0.0, steel, WorldSurface.Kind.METAL)
	# Canted face: an oriented box tilted about local X. The frame stays right-handed,
	# so the shell stays outward.
	var c: float = cos(POST_FACE_TILT)
	var s: float = sin(POST_FACE_TILT)
	m.oriented_box(
		Vector3(0.0, POST_TOP_Y + 0.10, 0.10),
		Vector3(1.16, 0.0, 0.0),
		Vector3(0.0, c, s) * 0.055,
		Vector3(0.0, -s, c) * 0.36,
		steel,
		WorldSurface.Kind.METAL
	)
	# Panel mast behind the face, carrying the readout.
	for sx in [-0.60, 0.60]:
		m.box(
			Vector3(sx, 1.30, -0.34), Vector3(0.05, 0.42, 0.05), 0.0, steel, WorldSurface.Kind.METAL
		)
	m.box(POST_MAST_AT, POST_MAST_HALF, 0.0, steel, WorldSurface.Kind.METAL)
	return m
