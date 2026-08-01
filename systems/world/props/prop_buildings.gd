class_name PropBuildings
extends RefCounted
## The seven things the town is built out of: adobe blocks, a depot, container
## stacks, ruins, the water tower, the market and the walled compound.
##
## Each returns a `BuildingRecord` (containers return their stack height instead
## — they have no interior and are never roof-bridged). None of them publish
## themselves to the layout: the caller decides what is worth remembering, which
## is how the reference ends up with a compound's inner shack that exists but is
## not addressable.

## Adobe wall thickness, and the storey height range when none is forced.
const ADOBE_WALL_TH: float = 0.42
## Roof deck sits this far above the top storey's ceiling line.
const ADOBE_ROOF_LIFT: float = 0.26
## Floor slab half-thickness.
const SLAB_HALF: float = 0.15
## Stair well is capped at this many metres square.
const WELL_MAX: float = 2.4
## The flight's run, as a multiple of the storey height. Anything under about
## 1.1 makes a ladder, not a staircase.
const STAIR_RUN_SCALE: float = 1.15

## Depot wall thickness, and gable rise as a fraction of the short half-span.
const DEPOT_WALL_TH: float = 0.34
const DEPOT_GABLE_RISE: float = 0.38
## Catwalk height as a fraction of the depot's wall height.
const DEPOT_CATWALK_T: float = 0.56

## Shipping container half-extents: 6.10 x 2.60 x 2.44 m.
const CONTAINER_HALF: Vector3 = Vector3(3.05, 1.30, 1.22)
## Stacked containers sit INTO the one below. The reference leaves a 4 cm gap for
## the corner castings, which reads as a slot of daylight through the stack.
const CONTAINER_BITE: float = 0.04

## Ruin wall thickness, and the chance a whole side has fallen down.
const RUIN_WALL_TH: float = 0.4
const RUIN_SIDE_GONE: float = 0.28
## Below this the ragged wall segment is rubble, not wall.
const RUIN_MIN_STUB: float = 0.4

## Water tower: leg segments and bracing rings.
const TOWER_SEGMENTS: int = 5
const TOWER_LEG_TAPER: float = 0.42
const TOWER_LEG_RAD: float = 0.1


## A flat-roofed adobe block of `floors` storeys, with a door, windows, an
## internal stair, a parapet and whatever junk is on the roof.
##
## `fh_override` forces the storey height; at 0 it is rolled, which costs one
## draw. `door_side` is a corner index 0-3.
static func adobe(
	ctx: PropContext,
	x: float,
	z: float,
	w: float,
	d: float,
	floors: int,
	ry: float,
	fh_override: float = 0.0,
	door_side: int = 0
) -> BuildingRecord:
	var r: XorShift32 = ctx.rng
	var fh: float = fh_override if fh_override > 0.0 else r.next_range(3.0, 3.5)
	var base: float = ctx.ground_h(x, z)
	var wall_c: Color = WorldPalette.vary(WorldPalette.pick(Palette.WORLD_ADOBE, r), r, 0.10)
	var trim_c: Color = WorldPalette.vary(WorldPalette.pick(Palette.WORLD_CONCRETE, r), r, 0.10)
	var roof_c: Color = (
		WorldPalette.vary(WorldPalette.pick(Palette.WORLD_ADOBE, r), r, 0.13)
		if r.chance(0.55)
		else WorldPalette.vary(WorldPalette.pick(Palette.WORLD_CONCRETE, r), r, 0.13)
	)
	var frame_c: Color = (
		WorldPalette.vary(WorldPalette.pick(Palette.WORLD_WOOD, r), r, 0.14)
		if r.chance(0.6)
		else WorldPalette.vary(WorldPalette.DECK, r, 0.14)
	)
	var hw: float = w * 0.5
	var hd: float = d * 0.5
	var cor: PackedVector2Array = PropContext.corners(x, z, ry, hw, hd)

	ctx.solid(
		Vector3(x, base - 0.9, z),
		Vector3(hw + 0.22, 1.0, hd + 0.22),
		ry,
		trim_c,
		WorldSurface.Kind.CONCRETE
	)
	var roof_y: float = base + fh * float(floors)

	for f in floors:
		var y0: float = base + fh * float(f)
		for s in 4:
			var a: Vector2 = cor[s]
			var b: Vector2 = cor[(s + 1) % 4]
			var length: float = a.distance_to(b)
			var holes: Array[Vector4] = []
			if f == 0 and s == door_side:
				var dw: float = minf(length - 1.2, r.next_range(1.55, 2.05))
				var du: float = length * 0.5 - dw * 0.5 + (r.next() - 0.5) * (length * 0.18)
				if dw > 1.0:
					holes.append(Vector4(du, du + dw, 0.0, 2.45))
			if f == 0 and s == (door_side + 2) % 4 and r.chance(0.62):
				var bw: float = minf(length - 1.2, r.next_range(1.4, 1.9))
				if bw > 1.0:
					holes.append(
						Vector4(length * 0.5 - bw * 0.5, length * 0.5 + bw * 0.5, 0.0, 2.35)
					)
			var n_win: int = maxi(0, int(floor(length / r.next_range(2.6, 4.0))))
			for i in n_win:
				var u: float = (float(i) + 0.5) / float(n_win) * length
				var ww: float = r.next_range(0.7, 1.15)
				if _hole_conflict(holes, u, ww):
					continue
				if r.chance(0.22):
					continue
				var sill: float = r.next_range(0.95, 1.25)
				holes.append(
					Vector4(u - ww * 0.5, u + ww * 0.5, sill, sill + r.next_range(0.95, 1.35))
				)
			PropStructures.wall_with_holes(
				ctx,
				a.x,
				a.y,
				b.x,
				b.y,
				y0,
				fh + ctx.tuning.joint_overlap,
				ADOBE_WALL_TH,
				holes,
				wall_c,
				WorldSurface.Kind.CONCRETE,
				WorldSurface.Kind.CONCRETE,
				frame_c
			)
		_adobe_deck(ctx, x, z, ry, hw, hd, w, d, y0, fh, f, floors, roof_c, trim_c)

	var par: float = r.next_range(0.75, 1.15)
	for s in 4:
		var a: Vector2 = cor[s]
		var b: Vector2 = cor[(s + 1) % 4]
		var holes: Array[Vector4] = []
		if r.chance(0.4):
			holes.append(Vector4(1.0, 1.0 + r.next_range(0.8, 1.6), 0.0, par))
		PropStructures.wall_with_holes(
			ctx,
			a.x,
			a.y,
			b.x,
			b.y,
			roof_y + ADOBE_ROOF_LIFT,
			par,
			0.30,
			holes,
			wall_c,
			WorldSurface.Kind.CONCRETE,
			WorldSurface.Kind.CONCRETE
		)

	if r.chance(0.55):
		var s: int = r.next_int(0, 3)
		var a: Vector2 = cor[s]
		var b: Vector2 = cor[(s + 1) % 4]
		var t: float = r.next_range(0.25, 0.75)
		var lp: Vector2 = a.lerp(b, t)
		var nrm: float = atan2(-(b.y - a.y), b.x - a.x) + PI * 0.5
		PropStructures.add_ladder(
			ctx,
			lp.x + cos(nrm) * 0.32,
			lp.y - sin(nrm) * 0.32,
			nrm + PI * 0.5,
			base,
			roof_y + ADOBE_ROOF_LIFT + par + 0.30
		)

	PropClutter.roof_clutter(ctx, x, z, w, d, ry, roof_y + ADOBE_ROOF_LIFT)

	if r.chance(0.5):
		_adobe_awning(ctx, cor, door_side, base, r)

	return BuildingRecord.new(
		x, z, w, d, ry, roof_y + ADOBE_ROOF_LIFT, base, WorldLayoutData.Kind.HOUSE
	)


## The floor deck of storey `f`, pierced by the stair well, plus the flight that
## climbs through it. The top storey's deck is the roof.
static func _adobe_deck(
	ctx: PropContext,
	x: float,
	z: float,
	ry: float,
	hw: float,
	hd: float,
	w: float,
	d: float,
	y0: float,
	fh: float,
	f: int,
	floors: int,
	roof_c: Color,
	trim_c: Color
) -> void:
	var well_w: float = minf(WELL_MAX, w * 0.42)
	var well_d: float = minf(WELL_MAX, d * 0.42)
	var y_top: float = y0 + fh
	var wu: float = hw - well_w * 0.5 - 0.35
	var wv: float = -hd + well_d * 0.5 + 0.35
	var ov: float = ctx.tuning.joint_overlap
	var slab_c: Color = roof_c if f == floors - 1 else trim_c
	# The two full-width bands, then the two stubs either side of the well. The
	# stubs are grown along v into the bands so the deck has no hairline in it,
	# but never along u, which would swallow the well.
	var bands: Array[Vector4] = [
		Vector4(-hw, hw, -hd, wv - well_d * 0.5),
		Vector4(-hw, hw, wv + well_d * 0.5, hd),
		Vector4(-hw, wu - well_w * 0.5, wv - well_d * 0.5 - ov, wv + well_d * 0.5 + ov),
		Vector4(wu + well_w * 0.5, hw, wv - well_d * 0.5 - ov, wv + well_d * 0.5 + ov),
	]
	for seg: Vector4 in bands:
		if seg.y - seg.x < 0.05 or seg.w - seg.z < 0.05:
			continue
		var p: Vector2 = PropContext.local(x, z, ry, (seg.x + seg.y) * 0.5, (seg.z + seg.w) * 0.5)
		ctx.solid(
			Vector3(p.x, y_top + 0.11, p.y),
			Vector3((seg.y - seg.x) * 0.5, SLAB_HALF, (seg.w - seg.z) * 0.5),
			ry,
			slab_c,
			WorldSurface.Kind.CONCRETE
		)
	var run: float = fh * STAIR_RUN_SCALE
	var sp: Vector2 = PropContext.local(x, z, ry, wu, wv + well_d * 0.5 + run * 0.5)
	PropStructures.stairs_fixed(
		ctx,
		sp.x,
		sp.y,
		ry + PI * 0.5,
		minf(1.1, well_w - 0.2),
		run,
		fh + ADOBE_ROOF_LIFT,
		y0,
		trim_c,
		WorldSurface.Kind.CONCRETE
	)


static func _adobe_awning(
	ctx: PropContext, cor: PackedVector2Array, door_side: int, base: float, r: XorShift32
) -> void:
	var a: Vector2 = cor[door_side]
	var b: Vector2 = cor[(door_side + 1) % 4]
	var m: Vector2 = (a + b) * 0.5
	var nrm: float = atan2(-(b.y - a.y), b.x - a.x) + PI * 0.5
	var ox: float = cos(nrm)
	var oz: float = -sin(nrm)
	var cloth: Color = WorldPalette.pick(Palette.WORLD_CLOTH, r)
	ctx.deco(
		Vector3(m.x + ox * 0.9, base + 2.45, m.y + oz * 0.9),
		Vector3(1.5, 0.04, 0.95),
		nrm + PI * 0.5,
		cloth,
		WorldSurface.Kind.CLOTH
	)
	# The two posts stand 1.75 m out from the wall and 1.3 m either side of the
	# door, so on any slope the ground under them is not the ground under the
	# building. Their heads stay at `base + 2.4` — the awning has to be level —
	# and each foot is taken down to the terrain it actually stands on.
	for sg: float in [-1.0, 1.0]:
		var qx: float = m.x + ox * 1.75 + sg * -oz * 1.3
		var qz: float = m.y + oz * 1.75 + sg * ox * 1.3
		var foot: float = minf(base, ctx.ground_h(qx, qz)) - 0.05
		var head: float = base + 2.4
		ctx.mesher.cylinder(
			Vector3(qx, (head + foot) * 0.5, qz),
			0.05,
			0.05,
			(head - foot) * 0.5,
			ctx.tuning.post_segments,
			WorldPalette.LADDER,
			WorldSurface.Kind.METAL
		)


## The depot: four pierced walls, a corrugated gable roof with real thickness, a
## catwalk on every side and a few pallets inside.
static func warehouse(
	ctx: PropContext, x: float, z: float, w: float, d: float, ry: float
) -> BuildingRecord:
	var r: XorShift32 = ctx.rng
	var base: float = ctx.ground_h(x, z)
	var h: float = r.next_range(6.0, 8.2)
	var hw: float = w * 0.5
	var hd: float = d * 0.5
	var wall_c: Color = WorldPalette.vary(WorldPalette.pick(Palette.WORLD_CONCRETE, r), r)
	var tin_c: Color = WorldPalette.vary(WorldPalette.pick(Palette.WORLD_TIN, r), r)
	ctx.solid(
		Vector3(x, base - 0.75, z),
		Vector3(hw + 0.3, 0.8, hd + 0.3),
		ry,
		WorldPalette.vary(WorldPalette.SLAB, r),
		WorldSurface.Kind.CONCRETE
	)
	var door_side: int = r.next_int(0, 3)
	var cor: PackedVector2Array = PropContext.corners(x, z, ry, hw, hd)

	# The trim shade is drawn per side, in the argument list of each wall — four
	# draws, not one. Hoisting it out of the loop would shorten the stream by three
	# and re-roll everything the depot is followed by.
	for s in 4:
		var a: Vector2 = cor[s]
		var b: Vector2 = cor[(s + 1) % 4]
		var length: float = a.distance_to(b)
		var holes: Array[Vector4] = []
		if s == door_side:
			holes.append(Vector4(length * 0.5 - 2.8, length * 0.5 + 2.8, 0.0, 4.8))
		elif s == (door_side + 2) % 4 and r.chance(0.7):
			holes.append(Vector4(length * 0.5 - 1.3, length * 0.5 + 1.3, 0.0, 2.6))
		var nw: int = int(floor(length / 3.4))
		for i in nw:
			var u: float = (float(i) + 0.5) / float(nw) * length
			if _hole_conflict(holes, u, 1.2 - 0.5):
				continue
			holes.append(Vector4(u - 0.65, u + 0.65, h - 2.1, h - 0.9))
		PropStructures.wall_with_holes(
			ctx,
			a.x,
			a.y,
			b.x,
			b.y,
			base,
			h,
			DEPOT_WALL_TH,
			holes,
			wall_c,
			WorldSurface.Kind.CONCRETE,
			WorldSurface.Kind.CONCRETE,
			WorldPalette.vary(WorldPalette.RAIL, r, 0.12)
		)

	var eave: float = (base + h) if ctx.tuning.fix_warehouse_roof_base else h
	var ridge: float = eave + minf(hw, hd) * DEPOT_GABLE_RISE
	var co: float = cos(ry)
	var si: float = sin(ry)
	var slope: float = (ridge - eave) / hw
	for sgn: float in [-1.0, 1.0]:
		ctx.mesher.corrugated(
			Vector3(x + sgn * hw * 0.5 * co, (eave + ridge) * 0.5 + 0.15, z - sgn * hw * 0.5 * si),
			hw * 0.5 * sqrt(1.0 + slope * slope),
			hd + 0.35,
			maxi(2, int(round(hw * 1.6))),
			0.09,
			tin_c,
			WorldSurface.Kind.TIN,
			ry,
			-sgn * slope,
			ctx.tuning.corrugated_thickness
		)
		ctx.add_col(
			Vector3(x + sgn * hw * 0.5 * co, (eave + ridge) * 0.5 - 0.1, z - sgn * hw * 0.5 * si),
			Vector3(hw * 0.5, 0.35, hd),
			ry,
			WorldSurface.Kind.TIN
		)
	ctx.deco(
		Vector3(x, ridge + 0.22, z), Vector3(0.24, 0.1, hd + 0.35), ry, tin_c, WorldSurface.Kind.TIN
	)

	var cw_y: float = base + h * DEPOT_CATWALK_T
	for s in 4:
		_depot_catwalk(ctx, cor[s], cor[(s + 1) % 4], cw_y, r)
	var lp: Vector2 = PropContext.local(x, z, ry, -hw + 0.55, -hd + 2.8)
	PropStructures.add_ladder(ctx, lp.x, lp.y, ry + PI * 0.5, base, cw_y + 0.95)

	var inv: int = r.next_int(3, 7)
	for _i in inv:
		var p: Vector2 = PropContext.local(
			x, z, ry, r.next_range(-hw + 1.5, hw - 1.5), r.next_range(-hd + 1.5, hd - 1.5)
		)
		if r.chance(0.4):
			PropClutter.barrel(ctx, p.x, base, p.y)
		else:
			PropClutter.big_crate(ctx, p.x, base, p.y, r.next_range(0.0, 3.0))

	return BuildingRecord.new(x, z, w, d, ry, base + h, base, WorldLayoutData.Kind.WAREHOUSE)


## One side's catwalk. The deck shade is drawn here, once per side, because that
## is where the reference draws it.
static func _depot_catwalk(
	ctx: PropContext, a: Vector2, b: Vector2, cw_y: float, r: XorShift32
) -> void:
	# Drawn before the length guard: a wall too short to carry a catwalk still costs
	# the stream its three colour draws, exactly as the unguarded reference does.
	var deck_c: Color = WorldPalette.vary(WorldPalette.DECK, r)
	var length: float = a.distance_to(b)
	if length < 1.0:
		return
	var m: Vector2 = (a + b) * 0.5
	var wry: float = atan2(-(b.y - a.y), b.x - a.x)
	var nrm: float = wry + PI * 0.5
	var ox: float = -cos(nrm) * 0.75
	var oz: float = sin(nrm) * 0.75
	ctx.solid(
		Vector3(m.x + ox, cw_y, m.y + oz),
		Vector3(length * 0.5 - 0.3, 0.07, 0.7),
		wry,
		deck_c,
		WorldSurface.Kind.METAL,
		WorldSurface.Kind.METAL
	)
	ctx.deco(
		Vector3(m.x + ox * 2.05, cw_y + 0.52, m.y + oz * 2.05),
		Vector3(length * 0.5 - 0.3, 0.03, 0.03),
		wry,
		WorldPalette.RAIL,
		WorldSurface.Kind.METAL
	)
	for i in 5:
		var p: Vector2 = a.lerp(b, float(i) / 4.0)
		ctx.deco(
			Vector3(p.x + ox * 2.05, cw_y + 0.26, p.y + oz * 2.05),
			Vector3(0.03, 0.26, 0.03),
			0.0,
			WorldPalette.RAIL,
			WorldSurface.Kind.METAL
		)


## A stack of shipping containers, drifting a little further off true with every
## tier. Returns the height of the top face.
static func containers(ctx: PropContext, x: float, z: float, ry: float, n: int = 3) -> float:
	var r: XorShift32 = ctx.rng
	var base: float = ctx.ground_h(x, z)
	var y: float = base
	var stack: int = r.next_int(1, maxi(1, n))
	for i in stack:
		var jx: float = r.next_range(-0.3, 0.3) * float(i)
		var jr: float = r.next_range(-0.05, 0.05) * float(i)
		ctx.solid(
			Vector3(x + jx, y + CONTAINER_HALF.y, z),
			CONTAINER_HALF,
			ry + jr,
			WorldPalette.vary(WorldPalette.pick(WorldPalette.CONTAINER, r), r, 0.13),
			WorldSurface.Kind.TIN,
			WorldSurface.Kind.TIN
		)
		y += CONTAINER_HALF.y * 2.0 - CONTAINER_BITE
	if r.chance(0.5):
		PropStructures.add_ladder(
			ctx,
			x + (CONTAINER_HALF.x + 0.12) * cos(ry),
			z - (CONTAINER_HALF.x + 0.12) * sin(ry),
			ry + PI * 0.5,
			base,
			y + 0.9
		)
	return y


## A gutted shell: some walls gone entirely, the rest broken off at a height that
## follows the terrain noise rather than the rng, so a ruin looks the same from
## every direction it is generated in.
static func ruin(
	ctx: PropContext, x: float, z: float, w: float, d: float, ry: float
) -> BuildingRecord:
	var r: XorShift32 = ctx.rng
	var base: float = ctx.ground_h(x, z)
	var hw: float = w * 0.5
	var hd: float = d * 0.5
	var wall_c: Color = WorldPalette.vary(WorldPalette.pick(Palette.WORLD_ADOBE, r), r, 0.12)
	var height: float = r.next_range(3.0, 6.5)
	ctx.solid(
		Vector3(x, base - 0.5, z),
		Vector3(hw + 0.2, 0.6, hd + 0.2),
		ry,
		WorldPalette.vary(WorldPalette.SLAB, r),
		WorldSurface.Kind.CONCRETE
	)
	var cor: PackedVector2Array = PropContext.corners(x, z, ry, hw, hd)
	var ov: float = ctx.tuning.joint_overlap
	for s in 4:
		if r.chance(RUIN_SIDE_GONE):
			continue
		var a: Vector2 = cor[s]
		var b: Vector2 = cor[(s + 1) % 4]
		var length: float = a.distance_to(b)
		var segs: int = maxi(3, int(round(length / 1.1)))
		var wry: float = atan2(-(b.y - a.y), b.x - a.x)
		for i in segs:
			var hh: float = (
				height
				* clampf(
					(
						0.25
						+ (
							ctx.noise.fbm2(x * 0.3 + float(s) * 3.0 + float(i) * 0.7, z * 0.3, 3)
							* 1.5
						)
					),
					0.1,
					1.15
				)
			)
			if hh < RUIN_MIN_STUB:
				continue
			var p: Vector2 = a.lerp(b, (float(i) + 0.5) / float(segs))
			ctx.solid(
				Vector3(p.x, base + hh * 0.5, p.y),
				Vector3(length / float(segs) * 0.5 + ov, hh * 0.5, RUIN_WALL_TH * 0.5),
				wry,
				wall_c,
				WorldSurface.Kind.CONCRETE,
				WorldSurface.Kind.CONCRETE
			)
	var rn: int = r.next_int(5, 12)
	for _i in rn:
		var a2: float = r.next() * TAU
		var rad: float = r.next_range(0.3, minf(hw, hd) * 1.25)
		var s2: float = r.next_range(0.3, 0.9)
		var hgt: float = r.next_range(0.2, 0.75)
		ctx.solid(
			Vector3(x + cos(a2) * rad, base + hgt * 0.55, z + sin(a2) * rad),
			Vector3(s2, hgt, s2 * r.next_range(0.6, 1.4)),
			r.next() * 3.0,
			WorldPalette.vary(WorldPalette.pick(Palette.WORLD_CONCRETE, r), r, 0.16),
			WorldSurface.Kind.CONCRETE,
			WorldSurface.Kind.CONCRETE
		)
	var rb: int = r.next_int(2, 6)
	for _i in rb:
		var c: Vector2 = cor[r.next_int(0, 3)]
		var px: float = c.x + r.next_range(-0.5, 0.5)
		var pz: float = c.y + r.next_range(-0.5, 0.5)
		# The three draws stay in this order and keep their ranges: the whole town
		# comes off one rng stream, so re-rolling here would re-roll the world.
		var mid: float = base + r.next_range(1.5, 3.2)
		var half: float = r.next_range(0.6, 1.4)
		var seam: float = r.next() * 3.0
		# A rod is rebar standing out of a broken corner. Its TIP is where the
		# draws put it; its FOOT is driven into the ground under its own xz rather
		# than left at tip - 2 * half, because the corner stub it is supposed to
		# grow out of is usually shorter than the rod and often absent altogether.
		# Left alone this was 25 rods across the town ending in a lit cap in
		# mid-air, up to three metres clear of anything - the tallest floater in
		# the world and the one visible from the ash flats spawn.
		var tip: float = mid + half
		var foot: float = minf(mid - half, ctx.ground_h(px, pz) - 0.06)
		ctx.mesher.cylinder(
			Vector3(px, (tip + foot) * 0.5, pz),
			0.025,
			0.02,
			(tip - foot) * 0.5,
			4,
			Palette.WORLD_RUST[0],
			WorldSurface.Kind.METAL,
			Vector3.UP,
			seam
		)
	return BuildingRecord.new(x, z, w, d, ry, base + height * 0.5, base, WorldLayoutData.Kind.RUIN)


## The water tower — four tapering legs, four bracing rings, a railed platform,
## the tank and a ladder up one leg. The landmark you navigate the town by.
static func tower(ctx: PropContext, x: float, z: float) -> BuildingRecord:
	var r: XorShift32 = ctx.rng
	var base: float = ctx.ground_h(x, z)
	var height: float = r.next_range(13.0, 19.0)
	var leg_r: float = r.next_range(2.4, 3.4)
	var metal_c: Color = WorldPalette.vary(WorldPalette.RAIL, r)
	var tank_c: Color = WorldPalette.vary(Palette.WORLD_TIN[0], r)

	for i in 4:
		var a: float = float(i) / 4.0 * TAU + PI * 0.25
		for s in TOWER_SEGMENTS:
			var t0: float = float(s) / float(TOWER_SEGMENTS)
			var t1: float = float(s + 1) / float(TOWER_SEGMENTS)
			var r0: float = lerpf(leg_r, leg_r * TOWER_LEG_TAPER, t0)
			var r1: float = lerpf(leg_r, leg_r * TOWER_LEG_TAPER, t1)
			var p0 := Vector3(x + cos(a) * r0, base + height * t0, z + sin(a) * r0)
			var p1 := Vector3(x + cos(a) * r1, base + height * t1, z + sin(a) * r1)
			# Segments are grown into each other along the leg: butted end to end
			# they would share a face, and a shared face is a seam.
			var grow: Vector3 = (p1 - p0).normalized() * ctx.tuning.joint_overlap
			ctx.mesher.strut(p0 - grow, p1 + grow, TOWER_LEG_RAD, metal_c, WorldSurface.Kind.METAL)
			ctx.add_col(
				(p0 + p1) * 0.5,
				Vector3(0.15, p0.distance_to(p1) * 0.5, 0.15),
				0.0,
				WorldSurface.Kind.METAL
			)
	for s in range(1, TOWER_SEGMENTS):
		var t: float = float(s) / float(TOWER_SEGMENTS)
		var rad: float = lerpf(leg_r, leg_r * TOWER_LEG_TAPER, t)
		var yy: float = base + height * t
		for i in 4:
			var a0: float = float(i) / 4.0 * TAU + PI * 0.25
			var a1: float = float(i + 1) / 4.0 * TAU + PI * 0.25
			var p0 := Vector2(x + cos(a0) * rad, z + sin(a0) * rad)
			var p1 := Vector2(x + cos(a1) * rad, z + sin(a1) * rad)
			var m: Vector2 = (p0 + p1) * 0.5
			ctx.deco(
				Vector3(m.x, yy, m.y),
				Vector3(p0.distance_to(p1) * 0.5, 0.055, 0.055),
				atan2(-(p1.y - p0.y), p1.x - p0.x),
				metal_c,
				WorldSurface.Kind.METAL
			)

	var py: float = base + height
	ctx.solid(
		Vector3(x, py, z),
		Vector3(leg_r * 0.72, 0.08, leg_r * 0.72),
		PI * 0.25,
		WorldPalette.vary(WorldPalette.DECK, r),
		WorldSurface.Kind.METAL,
		WorldSurface.Kind.METAL
	)
	var rail_r: float = leg_r * 0.72 * sqrt(2.0) * 0.72
	for i in 4:
		var a0: float = float(i) / 4.0 * TAU
		var a1: float = float(i + 1) / 4.0 * TAU
		var p0 := Vector2(x + cos(a0) * rail_r, z + sin(a0) * rail_r)
		var p1 := Vector2(x + cos(a1) * rail_r, z + sin(a1) * rail_r)
		var m: Vector2 = (p0 + p1) * 0.5
		ctx.deco(
			Vector3(m.x, py + 0.5, m.y),
			Vector3(p0.distance_to(p1) * 0.5, 0.03, 0.03),
			atan2(-(p1.y - p0.y), p1.x - p0.x),
			WorldPalette.RAIL,
			WorldSurface.Kind.METAL
		)
	var seg: int = ctx.tuning.tank_segments
	ctx.mesher.cylinder(
		Vector3(x, py + 2.0, z),
		leg_r * 0.55,
		leg_r * 0.55,
		1.85,
		seg,
		tank_c,
		WorldSurface.Kind.TIN
	)
	ctx.add_col(
		Vector3(x, py + 2.0, z),
		Vector3(leg_r * 0.55, 1.85, leg_r * 0.55),
		0.0,
		WorldSurface.Kind.TIN
	)
	ctx.mesher.cylinder(
		Vector3(x, py + 4.0 - 0.02, z), leg_r * 0.55, 0.1, 0.16, seg, tank_c, WorldSurface.Kind.TIN
	)
	PropStructures.add_ladder(ctx, x + leg_r * 0.99, z, PI * 0.5, base, py + 1.05)
	ctx.layout.add_poi(x, py, z, "TOWER", WorldLayoutData.PoiKind.POI)
	return BuildingRecord.new(
		x, z, leg_r * 2.0, leg_r * 2.0, 0.0, py, base, WorldLayoutData.Kind.TOWER
	)


## A grid of canopied market stalls with tables, crates and drums under them.
static func market(
	ctx: PropContext, x: float, z: float, w: float, d: float, ry: float
) -> BuildingRecord:
	var r: XorShift32 = ctx.rng
	var base: float = ctx.ground_h(x, z)
	var rows: int = maxi(1, int(floor(d / 4.2)))
	var n: int = maxi(1, int(floor(w / 3.4)))
	for j in rows:
		for i in n:
			var u: float = (float(i) + 0.5) / float(n) * w - w * 0.5
			var v: float = (float(j) + 0.5) / float(rows) * d - d * 0.5
			var p: Vector2 = PropContext.local(x, z, ry, u, v)
			_market_stall(ctx, p.x, p.y, ry, r)
	ctx.layout.add_poi(x, base + 2.6, z, "MARKET", WorldLayoutData.PoiKind.POI)
	return BuildingRecord.new(x, z, w, d, ry, base + 2.6, base, WorldLayoutData.Kind.MARKET)


static func _market_stall(ctx: PropContext, px: float, pz: float, ry: float, r: XorShift32) -> void:
	var b: float = ctx.ground_h(px, pz)
	var hh: float = r.next_range(2.0, 2.5)
	var sw: float = r.next_range(1.2, 1.7)
	var sd: float = r.next_range(0.8, 1.2)
	# `b` is the ground under the stall's CENTRE, and the four posts stand up to
	# 1.7 m out from it. The canopy has to stay level, so the heads all sit at
	# `b + hh` and each post is lengthened downward to the terrain beneath its own
	# corner — otherwise every stall on a grade hangs its downhill legs in the air.
	for sx: float in [-1.0, 1.0]:
		for sz: float in [-1.0, 1.0]:
			var q: Vector2 = PropContext.local(px, pz, ry, sx * sw, sz * sd)
			var foot: float = minf(b, ctx.ground_h(q.x, q.y)) - 0.05
			var mid: float = (b + hh + foot) * 0.5
			var ph: float = (b + hh - foot) * 0.5
			ctx.mesher.cylinder(
				Vector3(q.x, mid, q.y),
				0.055,
				0.05,
				ph,
				ctx.tuning.post_segments,
				WorldPalette.POST,
				WorldSurface.Kind.WOOD
			)
			ctx.add_col(
				Vector3(q.x, mid, q.y), Vector3(0.09, ph, 0.09), 0.0, WorldSurface.Kind.WOOD
			)
	var cloth_c: Color = WorldPalette.vary(WorldPalette.pick(Palette.WORLD_CLOTH, r), r, 0.14)
	ctx.deco(
		Vector3(px, b + hh + 0.06, pz),
		Vector3(sw + 0.25, 0.035, sd + 0.25),
		ry + r.next_range(-0.06, 0.06),
		cloth_c,
		WorldSurface.Kind.CLOTH
	)
	ctx.add_col(
		Vector3(px, b + hh + 0.06, pz),
		Vector3(sw + 0.25, 0.08, sd + 0.25),
		ry,
		WorldSurface.Kind.CLOTH
	)
	ctx.solid(
		Vector3(px, b + 0.75, pz),
		Vector3(sw * 0.85, 0.06, sd * 0.7),
		ry,
		WorldPalette.vary(WorldPalette.pick(Palette.WORLD_WOOD, r), r),
		WorldSurface.Kind.WOOD,
		WorldSurface.Kind.WOOD
	)
	for sg: float in [-1.0, 1.0]:
		var q: Vector2 = PropContext.local(px, pz, ry, sg * sw * 0.8, sg * sd * 0.6)
		ctx.deco(
			Vector3(q.x, b + 0.37, q.y),
			Vector3(0.05, 0.37, 0.05),
			0.0,
			WorldPalette.POST,
			WorldSurface.Kind.WOOD
		)
	if r.chance(0.4):
		PropClutter.crate(
			ctx, px + r.next_range(-1.0, 1.0), b, pz + r.next_range(-1.0, 1.0), r.next() * 3.0
		)
	if r.chance(0.3):
		PropClutter.barrel(ctx, px + r.next_range(-1.5, 1.5), b, pz + r.next_range(-1.5, 1.5))


## A walled yard with a gate, a shack inside and a scatter of stores.
##
## The inner shack's record is discarded exactly as the reference discards it: it
## has a roof and possibly a ladder, but it is not in the layout, so nothing will
## ever bridge to it or extract from it.
static func compound(
	ctx: PropContext, x: float, z: float, w: float, d: float, ry: float
) -> BuildingRecord:
	var r: XorShift32 = ctx.rng
	var base: float = ctx.ground_h(x, z)
	var hw: float = w * 0.5
	var hd: float = d * 0.5
	var wall_c: Color = WorldPalette.vary(WorldPalette.pick(Palette.WORLD_CONCRETE, r), r, 0.12)
	var gate: int = r.next_int(0, 3)
	var cor: PackedVector2Array = PropContext.corners(x, z, ry, hw, hd)
	for s in 4:
		var a: Vector2 = cor[s]
		var b: Vector2 = cor[(s + 1) % 4]
		var length: float = a.distance_to(b)
		var holes: Array[Vector4] = []
		if s == gate:
			holes.append(Vector4(length * 0.5 - 2.6, length * 0.5 + 2.6, 0.0, 3.4))
		PropStructures.wall_with_holes(
			ctx,
			a.x,
			a.y,
			b.x,
			b.y,
			base,
			r.next_range(2.6, 3.4),
			0.34,
			holes,
			wall_c,
			WorldSurface.Kind.CONCRETE,
			WorldSurface.Kind.CONCRETE
		)
	adobe(
		ctx,
		x + r.next_range(-2.0, 2.0),
		z + r.next_range(-2.0, 2.0),
		minf(w * 0.5, 8.0),
		minf(d * 0.5, 8.0),
		1,
		ry + r.next_range(-0.2, 0.2)
	)
	var np: int = r.next_int(2, 5)
	for _i in np:
		var p: Vector2 = PropContext.local(
			x, z, ry, r.next_range(-hw + 1.0, hw - 1.0), r.next_range(-hd + 1.0, hd - 1.0)
		)
		if r.chance(0.5):
			PropClutter.barrel(ctx, p.x, ctx.ground_h(p.x, p.y), p.y)
		else:
			PropClutter.crate(ctx, p.x, ctx.ground_h(p.x, p.y), p.y, r.next() * 3.0)
	return BuildingRecord.new(x, z, w, d, ry, base + 3.4, base, WorldLayoutData.Kind.COMPOUND)


## True when a proposed opening centred at `u` of half-width `ww` comes within
## half a metre of one already placed. Overlapping openings each emit their own
## lintel slab and z-fight, so every caller checks before it pushes.
static func _hole_conflict(holes: Array[Vector4], u: float, ww: float) -> bool:
	for o: Vector4 in holes:
		if u - ww < o.y + 0.5 and u + ww > o.x - 0.5:
			return true
	return false
