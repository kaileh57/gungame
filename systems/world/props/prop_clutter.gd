class_name PropClutter
extends RefCounted
## The loose furniture of the world: crates, drums, sandbags, wrecks, dead trees,
## boulders, power lines and whatever is rusting on a roof.
##
## Two of the reference's props are drawn on the wrong axis — the tipped drum and
## the truck's wheels both render as upright cylinders inside a collider that is
## lying down. `PropTuning.fix_lying_cylinders` builds them on the axis their
## collision actually uses. Turn it off to see the original.

## Standing drum: half-height and radius.
const BARREL_HALF_H: float = 0.46
const BARREL_RADIUS: float = 0.30
## The rolling hoop sits at 70 % of the drum's height and stands 2 cm proud.
const BARREL_HOOP_T: float = 0.7
const BARREL_HOOP_OUT: float = 0.02
const BARREL_HOOP_HALF: float = 0.03
const BARREL_TIP_CHANCE: float = 0.18

## Sandbag stock: half-extents, course pitch and the offset given to odd courses.
const BAG_HALF: Vector3 = Vector3(0.24, 0.13, 0.17)
const BAG_PITCH: float = 0.46
## Courses rise 0.25 m over 0.26 m bags, so every course bites 1 cm into the one
## below it. That 1 cm is the whole reason a sandbag wall has no daylight in it.
const BAG_COURSE: float = 0.25

## Derelict truck.
const WHEEL_RADIUS: float = 0.36
const WHEEL_HALF_W: float = 0.15
const WHEEL_STRIP_CHANCE: float = 0.22
## Axle positions along the chassis, as a fraction of half-length.
const WHEEL_AXLES: PackedFloat32Array = [-0.62, 0.46]

## Wreck liveries. Hauler brown first, then a steel and a rust, drawn through a
## short-circuited pair of chances. The steel is the container livery's grey — it
## is named by hex in the reference and belongs to no `Palette.WORLD_*` family.
const WRECK_STEEL: Color = Color("4a4d52")

## Power-line pole crossarm: half-length and how far below the pole top it sits.
const CROSSARM_HALF: float = 1.5
const CROSSARM_DROP: float = 0.40
const WIRE_DROP: float = 0.45


## A stack of one to three small crates, each jittered on its own.
static func crate(ctx: PropContext, x: float, y: float, z: float, ry: float) -> void:
	var r: XorShift32 = ctx.rng
	var n: int = r.next_int(1, 3)
	var yy: float = y
	var ov: float = ctx.tuning.joint_overlap
	for _i in n:
		var s: float = r.next_range(0.35, 0.55)
		var h: float = r.next_range(0.3, 0.5)
		var t: int = WorldSurface.Kind.WOOD if r.chance(0.45) else WorldSurface.Kind.METAL
		var jx: float = r.next_range(-0.1, 0.1)
		var jz: float = r.next_range(-0.1, 0.1)
		var depth: float = s * r.next_range(0.8, 1.2)
		var yaw: float = ry + r.next_range(-0.3, 0.3)
		var family: PackedColorArray = (
			Palette.WORLD_WOOD if t == WorldSurface.Kind.WOOD else Palette.WORLD_METAL
		)
		var col: Color = WorldPalette.vary(WorldPalette.pick(family, r), r)
		ctx.solid(Vector3(x + jx, yy + h, z + jz), Vector3(s, h, depth), yaw, col, t, t)
		yy += h * 2.0 - ov


## A 44-gallon drum, standing or on its side.
##
## The colour picks short-circuit: the second `chance` only draws when the first
## fails, so this consumes one or two draws before `vary`. Reproduced as written,
## because the whole town hangs off the draw count.
static func barrel(ctx: PropContext, x: float, y: float, z: float) -> void:
	var r: XorShift32 = ctx.rng
	var base: Color = WorldPalette.DRUM_RUST
	if not r.chance(0.3):
		base = WorldPalette.DRUM_GREEN if r.chance(0.5) else WorldPalette.DRUM_OLIVE
	var tipped: bool = r.chance(BARREL_TIP_CHANCE)
	var seg: int = ctx.tuning.barrel_segments
	if tipped:
		var col: Color = WorldPalette.vary(base, r)
		var yaw: float = r.next() * 3.0
		var axis: Vector3 = (
			Vector3(cos(yaw), 0.0, -sin(yaw)) if ctx.tuning.fix_lying_cylinders else Vector3.UP
		)
		ctx.mesher.cylinder(
			Vector3(x, y + BARREL_RADIUS, z),
			BARREL_RADIUS,
			BARREL_RADIUS,
			BARREL_HALF_H,
			seg,
			col,
			WorldSurface.Kind.METAL,
			axis
		)
		ctx.add_col(
			Vector3(x, y + BARREL_RADIUS, z),
			Vector3(BARREL_HALF_H, BARREL_RADIUS, BARREL_RADIUS),
			yaw,
			WorldSurface.Kind.METAL
		)
		return
	var body: Color = WorldPalette.vary(base, r)
	ctx.mesher.cylinder(
		Vector3(x, y + BARREL_HALF_H, z),
		BARREL_RADIUS,
		BARREL_RADIUS,
		BARREL_HALF_H,
		seg,
		body,
		WorldSurface.Kind.METAL
	)
	ctx.mesher.cylinder(
		Vector3(x, y + BARREL_HALF_H * BARREL_HOOP_T, z),
		BARREL_RADIUS + BARREL_HOOP_OUT,
		BARREL_RADIUS + BARREL_HOOP_OUT,
		BARREL_HOOP_HALF,
		seg,
		WorldPalette.RAIL,
		WorldSurface.Kind.METAL
	)
	ctx.add_col(
		Vector3(x, y + BARREL_HALF_H, z),
		Vector3(BARREL_RADIUS, BARREL_HALF_H, BARREL_RADIUS),
		0.0,
		WorldSurface.Kind.METAL
	)


## A pyramid of hessian bags, two or three courses, each course one bag shorter.
static func sandbags(ctx: PropContext, x: float, y: float, z: float, ry: float) -> void:
	var r: XorShift32 = ctx.rng
	var rows: int = r.next_int(2, 3)
	var length: int = r.next_int(3, 5)
	var co: float = cos(ry)
	var si: float = sin(ry)
	for j in rows:
		for i in length - j:
			var u: float = (float(i) - float(length - j - 1) * 0.5) * BAG_PITCH + float(j % 2) * 0.1
			ctx.solid(
				Vector3(x + u * co, y + 0.14 + float(j) * BAG_COURSE, z - u * si),
				BAG_HALF,
				ry + r.next_range(-0.14, 0.14),
				WorldPalette.vary(WorldPalette.SANDBAG, r, 0.14),
				WorldSurface.Kind.CLOTH,
				WorldSurface.Kind.CLOTH
			)


## One to three shipping crates stacked, all the same footprint. The early exit
## still spends its `chance` draw on the last course.
static func big_crate(ctx: PropContext, x: float, y: float, z: float, ry: float) -> void:
	var r: XorShift32 = ctx.rng
	var n: int = r.next_int(1, 3)
	var wd: float = r.next_range(0.7, 1.2)
	var dp: float = r.next_range(0.7, 1.2)
	var yy: float = y
	var ov: float = ctx.tuning.joint_overlap
	for _i in n:
		var hgt: float = r.next_range(0.5, 0.8)
		ctx.solid(
			Vector3(x, yy + hgt, z),
			Vector3(wd, hgt, dp),
			ry,
			WorldPalette.vary(WorldPalette.pick(Palette.WORLD_WOOD, r), r),
			WorldSurface.Kind.WOOD,
			WorldSurface.Kind.WOOD
		)
		yy += hgt * 2.0 - ov
		if r.chance(0.4):
			break


## The derelict truck: chassis, cab, bed and four wheels, sunk a little into the
## sand. With `fix_lying_cylinders` the wheels are round the way they roll.
static func wreck(ctx: PropContext, x: float, z: float, ry: float) -> void:
	var r: XorShift32 = ctx.rng
	var base: float = ctx.ground_h(x, z)
	var y0: float = base - r.next_range(0.02, 0.30)
	var body_base: Color = WorldPalette.HAULER
	if not r.chance(0.45):
		body_base = WRECK_STEEL if r.chance(0.5) else Palette.WORLD_RUST[0]
	var body_c: Color = WorldPalette.vary(body_base, r, 0.15)
	var trim_c: Color = WorldPalette.vary(Palette.WORLD_METAL[1], r, 0.12)
	var length: float = r.next_range(2.3, 3.1)
	var wid: float = r.next_range(0.92, 1.15)
	var axle_y: float = y0 + WHEEL_RADIUS
	var deck_y: float = axle_y + 0.31
	var co: float = cos(ry)
	var si: float = sin(ry)

	ctx.solid(
		Vector3(x, axle_y + 0.20, z),
		Vector3(length, 0.11, wid * 0.86),
		ry,
		trim_c,
		WorldSurface.Kind.METAL,
		WorldSurface.Kind.METAL
	)
	var cab: Vector2 = PropContext.local(x, z, ry, -length * 0.42, 0.0)
	ctx.solid(
		Vector3(cab.x, deck_y + 0.42, cab.y),
		Vector3(length * 0.30, 0.42, wid * 0.92),
		ry,
		body_c,
		WorldSurface.Kind.TIN,
		WorldSurface.Kind.TIN
	)
	if r.chance(0.62):
		ctx.solid(
			Vector3(cab.x + co * 0.06, deck_y + 1.02, cab.y - si * 0.06),
			Vector3(length * 0.24, 0.24, wid * 0.80),
			ry,
			WorldPalette.vary(body_c, r, 0.1),
			WorldSurface.Kind.TIN,
			WorldSurface.Kind.TIN
		)
	else:
		for du: float in [-length * 0.22, length * 0.22]:
			for dv: float in [-wid * 0.78, wid * 0.78]:
				var p: Vector2 = PropContext.local(x, z, ry, -length * 0.42 + du, dv)
				ctx.deco(
					Vector3(p.x, deck_y + 1.0, p.y),
					Vector3(0.05, 0.34, 0.05),
					ry,
					trim_c,
					WorldSurface.Kind.METAL
				)
	var bed: Vector2 = PropContext.local(x, z, ry, length * 0.30, 0.0)
	ctx.solid(
		Vector3(bed.x, deck_y + 0.10, bed.y),
		Vector3(length * 0.52, 0.10, wid * 0.92),
		ry,
		WorldPalette.vary(body_c, r, 0.12),
		WorldSurface.Kind.TIN,
		WorldSurface.Kind.TIN
	)
	for sgn: float in [-1.0, 1.0]:
		if not r.chance(0.75):
			continue
		var rail: Vector2 = PropContext.local(x, z, ry, length * 0.30, sgn * wid * 0.88)
		ctx.solid(
			Vector3(rail.x, deck_y + 0.38, rail.y),
			Vector3(length * 0.52, 0.28, 0.06),
			ry,
			WorldPalette.vary(body_c, r, 0.12),
			WorldSurface.Kind.TIN,
			WorldSurface.Kind.TIN
		)
	var wheel_axis: Vector3 = Vector3(si, 0.0, co) if ctx.tuning.fix_lying_cylinders else Vector3.UP
	for a2: float in WHEEL_AXLES:
		for sgn: float in [-1.0, 1.0]:
			var p: Vector2 = PropContext.local(x, z, ry, length * a2, sgn * wid * 0.95)
			if r.chance(WHEEL_STRIP_CHANCE):
				ctx.mesher.cylinder(
					Vector3(p.x, axle_y, p.y),
					0.12,
					0.12,
					0.07,
					8,
					trim_c,
					WorldSurface.Kind.METAL,
					wheel_axis
				)
				continue
			ctx.mesher.cylinder(
				Vector3(p.x, axle_y, p.y),
				WHEEL_RADIUS,
				WHEEL_RADIUS,
				WHEEL_HALF_W,
				ctx.tuning.tyre_segments,
				WorldPalette.vary(WorldPalette.TYRE, r, 0.1),
				WorldSurface.Kind.POLY,
				wheel_axis
			)
			ctx.mesher.cylinder(
				Vector3(p.x, axle_y, p.y),
				WHEEL_RADIUS * 0.45,
				WHEEL_RADIUS * 0.45,
				WHEEL_HALF_W + 0.01,
				8,
				trim_c,
				WorldSurface.Kind.METAL,
				wheel_axis
			)
			ctx.add_col(
				Vector3(p.x, axle_y, p.y),
				Vector3(0.16, WHEEL_RADIUS, WHEEL_RADIUS),
				ry,
				WorldSurface.Kind.POLY
			)
	if r.chance(0.4):
		var bon: Vector2 = PropContext.local(x, z, ry, -length * 0.72, 0.0)
		ctx.solid(
			Vector3(bon.x, deck_y + 0.55, bon.y),
			Vector3(0.06, 0.42, wid * 0.7),
			ry + r.next_range(-0.4, 0.4),
			trim_c,
			WorldSurface.Kind.TIN,
			WorldSurface.Kind.TIN
		)


## A tapered trunk with two to five bare branches. Branches do not collide.
static func dead_tree(ctx: PropContext, x: float, z: float) -> void:
	var r: XorShift32 = ctx.rng
	var base: float = ctx.ground_h(x, z)
	var h: float = r.next_range(2.2, 4.4)
	ctx.mesher.cylinder(
		Vector3(x, base + h * 0.5, z),
		0.19,
		0.09,
		h * 0.5,
		ctx.tuning.trunk_segments,
		WorldPalette.vary(WorldPalette.POST, r, 0.14),
		WorldSurface.Kind.WOOD
	)
	ctx.add_col(
		Vector3(x, base + h * 0.5, z), Vector3(0.22, h * 0.5, 0.22), 0.0, WorldSurface.Kind.WOOD
	)
	var n: int = r.next_int(2, 5)
	for _i in n:
		var a: float = r.next() * TAU
		var branch_len: float = r.next_range(0.7, 1.8)
		var t: float = r.next_range(0.55, 0.95)
		var y0: float = base + h * t
		ctx.mesher.strut(
			Vector3(x, y0, z),
			Vector3(x + cos(a) * branch_len, y0 + r.next_range(0.3, 1.1), z + sin(a) * branch_len),
			0.055,
			WorldPalette.vary(WorldPalette.BRANCH, r),
			WorldSurface.Kind.WOOD
		)


## Three to eight boulders scattered over a few metres.
##
## Each one is sunk 45 % of its own half-height into the ground, which is what
## keeps the cluster from showing daylight underneath on sloping terrain.
static func rock_cluster(ctx: PropContext, x: float, z: float) -> void:
	var r: XorShift32 = ctx.rng
	var n: int = r.next_int(3, 8)
	for _i in n:
		var a: float = r.next() * TAU
		var rad: float = r.next_range(0.0, 4.5)
		var px: float = x + cos(a) * rad
		var pz: float = z + sin(a) * rad
		var base: float = ctx.ground_h(px, pz)
		var s: float = r.next_range(0.5, 2.2)
		var hh: float = s * r.next_range(0.5, 1.1)
		ctx.solid(
			Vector3(px, base + hh * 0.55, pz),
			Vector3(s, hh, s * r.next_range(0.6, 1.4)),
			r.next() * 3.0,
			WorldPalette.vary(WorldPalette.pick(Palette.WORLD_ROCK, r), r, 0.13),
			WorldSurface.Kind.ROCK,
			WorldSurface.Kind.ROCK
		)


## A run of timber poles with two conductors slung between them.
##
## With `fix_wire_endpoints` each span is interpolated between the two crossarms
## it actually joins and sags from there. The reference holds a single Y for the
## whole span, mixing this pole's height with the previous pole's ground, so on
## any slope one end of every wire floats.
static func power_line(ctx: PropContext, pts: PackedVector2Array) -> void:
	var r: XorShift32 = ctx.rng
	var prev_arm: float = 0.0
	var prev: Vector2 = Vector2.ZERO
	for i in pts.size():
		var p: Vector2 = pts[i]
		var base: float = ctx.ground_h(p.x, p.y)
		var h: float = r.next_range(6.5, 8.5)
		ctx.mesher.cylinder(
			Vector3(p.x, base + h * 0.5, p.y),
			0.16,
			0.11,
			h * 0.5,
			ctx.tuning.trunk_segments,
			WorldPalette.vary(WorldPalette.POST, r),
			WorldSurface.Kind.WOOD
		)
		ctx.add_col(
			Vector3(p.x, base + h * 0.5, p.y),
			Vector3(0.2, h * 0.5, 0.2),
			0.0,
			WorldSurface.Kind.WOOD
		)
		ctx.deco(
			Vector3(p.x, base + h - CROSSARM_DROP, p.y),
			Vector3(CROSSARM_HALF, 0.08, 0.08),
			0.0,
			WorldPalette.vary(WorldPalette.POST, r),
			WorldSurface.Kind.WOOD
		)
		var arm: float = base + h - WIRE_DROP
		if i > 0:
			_wire_span(ctx, prev, prev_arm if ctx.tuning.fix_wire_endpoints else arm, p, arm)
		prev = p
		prev_arm = arm


static func _wire_span(ctx: PropContext, a: Vector2, ay: float, b: Vector2, by: float) -> void:
	var seg: int = maxi(1, ctx.tuning.wire_segments)
	var sag: float = ctx.tuning.wire_sag
	var off: float = ctx.tuning.wire_half_spacing
	for sgn: float in [-1.0, 1.0]:
		for s in seg:
			var t0: float = float(s) / float(seg)
			var t1: float = float(s + 1) / float(seg)
			ctx.mesher.strut(
				Vector3(
					lerpf(a.x, b.x, t0) + sgn * off,
					lerpf(ay, by, t0) - sag * sin(t0 * PI),
					lerpf(a.y, b.y, t0)
				),
				Vector3(
					lerpf(a.x, b.x, t1) + sgn * off,
					lerpf(ay, by, t1) - sag * sin(t1 * PI),
					lerpf(a.y, b.y, t1)
				),
				ctx.tuning.wire_radius,
				WorldPalette.WIRE,
				WorldSurface.Kind.METAL
			)


## One to four pieces of junk on a roof deck, placed inside the parapet.
##
## The antenna mast deliberately has no collider — it would otherwise snag every
## sprint across the roof, and it is 45 mm of aluminium.
static func roof_clutter(
	ctx: PropContext, x: float, z: float, w: float, d: float, ry: float, y: float
) -> void:
	var r: XorShift32 = ctx.rng
	var n: int = r.next_int(1, 4)
	for _i in n:
		var lu: float = r.next_range(-w * 0.5 + 1.0, w * 0.5 - 1.0)
		var lv: float = r.next_range(-d * 0.5 + 1.0, d * 0.5 - 1.0)
		var p: Vector2 = PropContext.local(x, z, ry, lu, lv)
		var k: float = r.next()
		if k < 0.30:
			ctx.mesher.cylinder(
				Vector3(p.x, y + 0.75, p.y),
				0.62,
				0.62,
				0.75,
				9,
				WorldPalette.vary(Palette.WORLD_TIN[0], r),
				WorldSurface.Kind.TIN
			)
			ctx.add_col(
				Vector3(p.x, y + 0.75, p.y), Vector3(0.62, 0.75, 0.62), 0.0, WorldSurface.Kind.TIN
			)
		elif k < 0.55:
			var bw: float = r.next_range(0.5, 0.9)
			var bh: float = r.next_range(0.4, 0.8)
			ctx.solid(
				Vector3(p.x, y + bh, p.y),
				Vector3(bw, bh, bw * r.next_range(0.7, 1.3)),
				r.next_range(0.0, 3.0),
				WorldPalette.vary(WorldPalette.VENT, r),
				WorldSurface.Kind.METAL
			)
		elif k < 0.75:
			crate(ctx, p.x, y, p.y, r.next_range(0.0, 3.0))
		elif k < 0.90:
			ctx.mesher.cylinder(
				Vector3(p.x, y + 2.2, p.y),
				0.045,
				0.02,
				2.2,
				ctx.tuning.post_segments,
				WorldPalette.RAIL,
				WorldSurface.Kind.METAL
			)
			for a in 3:
				ctx.deco(
					Vector3(p.x, y + 3.2 + float(a) * 0.35, p.y),
					Vector3(0.42 - float(a) * 0.1, 0.015, 0.015),
					float(a) * 0.7,
					WorldPalette.RAIL,
					WorldSurface.Kind.METAL
				)
		else:
			sandbags(ctx, p.x, y, p.y, r.next_range(0.0, 6.0))
