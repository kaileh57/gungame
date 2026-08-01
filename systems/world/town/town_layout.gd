class_name TownLayout
extends RefCounted
## The town plan: two arterial roads, a recursive street grid cut into four
## quadrants, a lot subdivision inside every block, and a rule table that decides
## what gets built on each lot. Then the wilds, the landmarks and the extraction
## pads.
##
## Rectangles are `Vector4(x0, z0, x1, z1)` throughout.
##
## ONE STREAM, ONE TOWN. `generate` is a pure function of the tuning resource.
## Every branch below either draws or does not draw in exactly the order the
## reference does, including the draws that get thrown away — the block roll that
## a plaza-apron block never uses, the split fraction a refused BSP cut still
## consumes, the two clutter draws taken before the keep-out test rejects the
## site. Those wasted draws are what makes the town look scattered instead of
## planned, and removing them re-rolls everything downstream.

## Stream salts. Independent sequences, mixed into the world seed.
const SALT_TOWN: int = 0xA51F
const SALT_WILDS: int = 0x77E5

## Probe range for a roof-to-roof plank, and how far past a roof edge the probe
## looks before it starts.
const LINK_PROBE_MIN: float = 1.6
const LINK_PROBE_MAX: float = 7.5
const LINK_PROBE_STEP: float = 0.5
const LINK_PROBE_LEAD: float = 0.6

## Outlying camp centres.
const CAMPS: PackedVector2Array = [
	Vector2(-236.0, 118.0),
	Vector2(214.0, -168.0),
	Vector2(-176.0, -244.0),
	Vector2(262.0, 262.0),
]
## Nose of the downed transport.
const CRASH_ORIGIN: Vector2 = Vector2(-300.0, 132.0)

## The two power-line runs, in world XZ.
const POWER_LINE_NS: PackedVector2Array = [
	Vector2(-24.0, -120.0),
	Vector2(-24.0, -86.0),
	Vector2(-26.0, -52.0),
	Vector2(-24.0, -18.0),
	Vector2(-26.0, 20.0),
	Vector2(-24.0, 54.0),
	Vector2(-26.0, 92.0),
]
const POWER_LINE_EW: PackedVector2Array = [
	Vector2(-100.0, 42.0),
	Vector2(-66.0, 40.0),
	Vector2(-32.0, 42.0),
	Vector2(26.0, 40.0),
	Vector2(62.0, 42.0),
	Vector2(98.0, 40.0),
]

## The two water towers.
const TOWER_SITES: PackedVector2Array = [Vector2(-62.0, -48.0), Vector2(74.0, 66.0)]

var town: WorldTown
var tuning: TownTuning
var blocks: Array[Vector4] = []


func _init(town_ctx: WorldTown) -> void:
	town = town_ctx
	tuning = town_ctx.town_tuning


## Build the whole map. Returns the finished context; the caller reads
## `town.mesher`, `town.colliders` and `town.layout` off it.
##
## Order is fixed: the town first, because the terrain bake reads the road lines
## it produces; then the wilds, which interleave their own placement stream with
## the town stream; then the pads.
static func generate(town_tuning: TownTuning, terrain: WorldTerrainData) -> WorldTown:
	var r := XorShift32.new(town_tuning.world_seed ^ SALT_TOWN)
	var ctx := WorldTown.new(r, town_tuning, terrain)
	var plan := TownLayout.new(ctx)
	plan.layout_town()
	plan.scatter_wilds()
	plan.place_exfils()
	return ctx


# ------------------------------------------------------------------ subdivision


## Recursive street cut. Each level pushes a carriageway down the middle of the
## rectangle and recurses into the two halves.
func bsp(rect: Vector4, depth: int) -> void:
	var r: XorShift32 = town.rng
	var w: float = rect.z - rect.x
	var d: float = rect.w - rect.y
	var keep: float = tuning.bsp_min_keep
	if (
		depth <= 0
		or (w < tuning.bsp_min_split and d < tuning.bsp_min_split)
		or w < keep
		or d < keep
	):
		blocks.push_back(rect)
		return
	var widths: PackedFloat32Array = tuning.road_widths
	var wi: int = mini(widths.size() - 1, widths.size() - depth)
	var rw: float = widths[wi] if wi >= 0 and wi < widths.size() else 3.6
	# The aspect test short-circuits: the coin is only flipped in the ambiguous
	# band, so how many draws this level costs depends on the rectangle.
	var along: bool = w > d * 1.08
	if not along and w > d * 0.92:
		along = r.chance(0.5)
	var t: float = r.next_range(0.36, 0.64)
	if along:
		var cx: float = rect.x + w * t
		if cx - rect.x < keep or rect.z - cx < keep:
			blocks.push_back(rect)
			return
		town.layout.add_road(cx, rect.y - 1.0, cx, rect.w + 1.0, rw)
		bsp(Vector4(rect.x, rect.y, cx - rw * 0.5, rect.w), depth - 1)
		bsp(Vector4(cx + rw * 0.5, rect.y, rect.z, rect.w), depth - 1)
		return
	var cz: float = rect.y + d * t
	if cz - rect.y < keep or rect.w - cz < keep:
		blocks.push_back(rect)
		return
	town.layout.add_road(rect.x - 1.0, cz, rect.z + 1.0, cz, rw)
	bsp(Vector4(rect.x, rect.y, rect.z, cz - rw * 0.5), depth - 1)
	bsp(Vector4(rect.x, cz + rw * 0.5, rect.z, rect.w), depth - 1)


## Split a block into building lots, leaving a walkable alley between each pair.
func lots(rect: Vector4, out: Array[Vector4], min_size: float) -> void:
	var r: XorShift32 = town.rng
	var w: float = rect.z - rect.x
	var d: float = rect.w - rect.y
	if w < min_size * 2.0 and d < min_size * 2.0:
		out.push_back(rect)
		return
	if r.chance(tuning.lot_stop_chance):
		out.push_back(rect)
		return
	var along: bool = w > d
	var t: float = r.next_range(0.38, 0.62)
	var gap: float = r.next_range(0.6, 1.8)
	if along:
		var cx: float = rect.x + w * t
		if cx - rect.x < min_size or rect.z - cx < min_size:
			out.push_back(rect)
			return
		lots(Vector4(rect.x, rect.y, cx - gap * 0.5, rect.w), out, min_size)
		lots(Vector4(cx + gap * 0.5, rect.y, rect.z, rect.w), out, min_size)
		return
	var cz: float = rect.y + d * t
	if cz - rect.y < min_size or rect.w - cz < min_size:
		out.push_back(rect)
		return
	lots(Vector4(rect.x, rect.y, rect.z, cz - gap * 0.5), out, min_size)
	lots(Vector4(rect.x, cz + gap * 0.5, rect.z, rect.w), out, min_size)


# ----------------------------------------------------------------------- plaza


## The town square: a gutted road hauler up on blocks, a loading ramp, a signpost
## nobody has read in years, fire drums and the main market.
##
## The hauler's wheels take their axle from the trailer's own local +Z, so what
## you shoot is what you see — the reference drew them face-on and collided them
## edge-on.
static func plaza(town: WorldTown, cx: float, cz: float) -> void:
	var r: XorShift32 = town.rng
	var base: float = town.ground_h(cx, cz)
	var ry: float = 0.42
	var hull_c: Color = WorldPalette.vary(WorldPalette.HAULER, r, 0.1)
	town.solid(
		Vector3(cx, base + 1.5, cz), Vector3(8.5, 1.5, 2.6), ry, hull_c, WorldSurface.Kind.TIN
	)
	var deck_c: Color = WorldPalette.vary(WorldPalette.SLAB, r)
	town.solid(
		Vector3(cx, base + 3.35, cz - 0.3),
		Vector3(7.4, 0.35, 2.3),
		ry,
		deck_c,
		WorldSurface.Kind.TIN
	)
	var cab: Vector2 = PropContext.local(cx, cz, ry, -7.0, 0.0)
	var cab_c: Color = WorldPalette.vary(PropClutter.WRECK_STEEL, r)
	town.solid(
		Vector3(cab.x, base + 4.1, cab.y),
		Vector3(2.0, 1.3, 2.0),
		ry,
		cab_c,
		WorldSurface.Kind.METAL
	)

	var axle := Vector3(sin(ry), 0.0, cos(ry))
	for i in 6:
		var p: Vector2 = PropContext.local(
			cx, cz, ry, -6.0 + float(i) * 2.6, 2.75 if i % 2 == 1 else -2.75
		)
		if not r.chance(0.7):
			continue
		town.mesher.cylinder(
			Vector3(p.x, base + 0.7, p.y),
			0.72,
			0.72,
			0.34,
			11,
			WorldPalette.TYRE,
			WorldSurface.Kind.POLY,
			axle
		)
		town.add_col(
			Vector3(p.x, base + 0.7, p.y), Vector3(0.72, 0.72, 0.34), ry, WorldSurface.Kind.POLY
		)

	for i in 7:
		var t: float = float(i) / 7.0
		var p: Vector2 = PropContext.local(cx, cz, ry, 8.4 + t * 4.2, 0.0)
		var step_c: Color = WorldPalette.vary(WorldPalette.DECK, r)
		town.solid(
			Vector3(p.x, base + 3.0 * (1.0 - t) * 0.5, p.y),
			Vector3(0.32, maxf(0.06, 3.0 * (1.0 - t) * 0.5), 2.2),
			ry,
			step_c,
			WorldSurface.Kind.METAL
		)

	var sign_p: Vector2 = PropContext.local(cx, cz, ry, 0.0, 8.5)
	var sb: float = town.ground_h(sign_p.x, sign_p.y)
	var post_c: Color = WorldPalette.vary(WorldPalette.POST, r)
	town.mesher.cylinder(
		Vector3(sign_p.x, sb + 2.6, sign_p.y), 0.13, 0.11, 2.6, 6, post_c, WorldSurface.Kind.WOOD
	)
	town.add_col(
		Vector3(sign_p.x, sb + 2.6, sign_p.y), Vector3(0.18, 2.6, 0.18), 0.0, WorldSurface.Kind.WOOD
	)
	for i in 6:
		var a: float = r.next() * TAU
		var board_len: float = r.next_range(0.9, 1.7)
		var board_c: Color = WorldPalette.vary(WorldPalette.pick(Palette.WORLD_WOOD, r), r)
		town.deco(
			Vector3(
				sign_p.x + cos(a) * board_len * 0.5,
				sb + 2.0 + float(i) * 0.5,
				sign_p.y + sin(a) * board_len * 0.5
			),
			Vector3(board_len * 0.5, 0.11, 0.03),
			-a,
			board_c,
			WorldSurface.Kind.WOOD
		)

	for _i in 5:
		var a: float = r.next() * TAU
		var rad: float = r.next_range(11.0, 17.0)
		var px: float = cx + cos(a) * rad
		var pz: float = cz + sin(a) * rad
		PropClutter.barrel(town, px, town.ground_h(px, pz), pz)

	PropBuildings.market(town, cx - 13.0, cz + 12.0, 11.0, 9.0, 0.2)
	town.layout.add_poi(cx, base, cz, "PLAZA", WorldLayoutData.PoiKind.POI)


# ------------------------------------------------------------------ roof links


## Plank bridges between roofs that are close enough and level enough to cross.
## Each pair is considered once, from whichever building reaches it first.
func link_roofs() -> void:
	var r: XorShift32 = town.rng
	var done: Dictionary = {}
	for bi in town.buildings.size():
		var b: BuildingRecord = town.buildings[bi]
		if not b.can_bridge_from():
			continue
		for dir in 4:
			var a: float = b.ry + float(dir) * PI * 0.5
			var ox: float = cos(a)
			var oz: float = -sin(a)
			var half: float = b.w * 0.5 if dir % 2 == 0 else b.d * 0.5
			var ex: float = b.x + ox * half
			var ez: float = b.z + oz * half
			var target: BuildingRecord = null
			var gap: float = 0.0
			var g: float = LINK_PROBE_MIN
			while g < LINK_PROBE_MAX:
				var hit: BuildingRecord = town.roof_at(
					ex + ox * (g + LINK_PROBE_LEAD), ez + oz * (g + LINK_PROBE_LEAD)
				)
				if hit != null and hit != b:
					target = hit
					gap = g
					break
				g += LINK_PROBE_STEP
			if target == null:
				continue
			if absf(target.roof_y - b.roof_y) > tuning.roof_link_max_step:
				continue
			var ti: int = town.buildings.find(target)
			var key: int = mini(bi, ti) * 65536 + maxi(bi, ti)
			if done.has(key):
				continue
			done[key] = true
			if not r.chance(tuning.roof_link_chance):
				continue
			var y: float = maxf(b.roof_y, target.roof_y) + 0.08
			var mx: float = ex + ox * (gap + LINK_PROBE_LEAD) * 0.5
			var mz: float = ez + oz * (gap + LINK_PROBE_LEAD) * 0.5
			var pry: float = atan2(-oz, ox)
			var bw: float = r.next_range(0.45, 0.72)
			var plank_c: Color = WorldPalette.vary(WorldPalette.pick(Palette.WORLD_WOOD, r), r)
			town.solid(
				Vector3(mx, y, mz),
				Vector3((gap + 1.7) * 0.5, 0.06, bw),
				pry,
				plank_c,
				WorldSurface.Kind.WOOD
			)
			if r.chance(tuning.roof_rail_chance):
				town.deco(
					Vector3(mx, y + 0.55, mz),
					Vector3((gap + 1.7) * 0.5, 0.025, 0.025),
					pry,
					WorldPalette.RAIL,
					WorldSurface.Kind.METAL
				)
				for s: float in [-1.0, 1.0]:
					town.deco(
						Vector3(mx + s * ox * gap * 0.4, y + 0.28, mz + s * oz * gap * 0.4),
						Vector3(0.025, 0.28, 0.025),
						0.0,
						WorldPalette.RAIL,
						WorldSurface.Kind.METAL
					)


# ------------------------------------------------------------------ the town


## Roads, blocks, buildings, the plaza, the two towers, the roof bridges and the
## litter down the main strip.
func layout_town() -> void:
	var r: XorShift32 = town.rng
	var t: float = tuning.town_half_extent
	town.layout.add_road(-8.0, -t - 40.0, -8.0, t + 6.0, tuning.main_strip_width)
	town.layout.add_road(-t - 6.0, 16.0, t + 6.0, 16.0, tuning.cross_street_width)
	var quads: Array[Vector4] = [
		Vector4(-t, -t, -12.5, 11.2),
		Vector4(-2.5, -t, t, 11.2),
		Vector4(-t, 20.8, -12.5, t),
		Vector4(-2.5, 20.8, t, t),
	]
	for q in quads:
		bsp(q, tuning.bsp_depth)
	for blk in blocks:
		town.layout.blocks.push_back(blk)
	plaza(town, tuning.plaza_center.x, tuning.plaza_center.y)

	for blk in blocks:
		var bw: float = blk.z - blk.x
		var bd: float = blk.w - blk.y
		var cx: float = (blk.x + blk.z) * 0.5
		var cz: float = (blk.y + blk.w) * 0.5
		var to_plaza: float = Vector2(cx, cz).distance_to(tuning.plaza_center)
		if to_plaza < tuning.plaza_radius + minf(bw, bd) * 0.4:
			_plaza_apron(blk)
			continue
		var k: float = r.next()
		var d_core: float = Vector2(cx, cz).length()
		if bw > 26.0 and bd > 22.0 and k < tuning.warehouse_chance:
			town.register(
				PropBuildings.warehouse(
					town, cx, cz, bw - 3.0, bd - 3.0, float(r.next_int(0, 1)) * PI * 0.5
				)
			)
			continue
		if bw > 24.0 and bd > 24.0 and k < tuning.compound_chance:
			town.register(PropBuildings.compound(town, cx, cz, bw - 3.0, bd - 3.0, 0.0))
			continue
		var lot_list: Array[Vector4] = []
		lots(blk, lot_list, tuning.lot_min_size)
		for lot in lot_list:
			_build_lot(blk, lot, d_core)

	for site in TOWER_SITES:
		town.register(PropBuildings.tower(town, site.x, site.y))
	link_roofs()
	_street_clutter()
	PropClutter.power_line(town, POWER_LINE_NS)
	PropClutter.power_line(town, POWER_LINE_EW)


## Blocks that back onto the square get gravel and junk instead of buildings.
func _plaza_apron(blk: Vector4) -> void:
	var r: XorShift32 = town.rng
	for _i in 4:
		var px: float = r.next_range(blk.x, blk.z)
		var pz: float = r.next_range(blk.y, blk.w)
		if Vector2(px, pz).distance_to(tuning.plaza_center) < 11.0:
			continue
		if r.chance(0.5):
			PropClutter.barrel(town, px, town.ground_h(px, pz), pz)
		else:
			PropClutter.crate(town, px, town.ground_h(px, pz), pz, r.next() * 3.0)


## One lot: ruin, container row, market, open yard or house, by a single roll.
func _build_lot(blk: Vector4, lot: Vector4, d_core: float) -> void:
	var r: XorShift32 = town.rng
	var lw: float = (lot.z - lot.x) - r.next_range(1.0, 2.6)
	var ld: float = (lot.w - lot.y) - r.next_range(1.0, 2.6)
	if lw < 5.0 or ld < 5.0:
		return
	var lx: float = (lot.x + lot.z) * 0.5 + r.next_range(-0.6, 0.6)
	var lz: float = (lot.y + lot.w) * 0.5 + r.next_range(-0.6, 0.6)
	var ry: float = 0.0 if r.chance(0.86) else r.next_range(-0.12, 0.12)
	var q: float = r.next()
	if q < 0.13:
		town.register(PropBuildings.ruin(town, lx, lz, lw, ld, ry))
		return
	if q < 0.21:
		var n: int = maxi(1, int(floor(lw / 6.4)))
		for i in n:
			PropBuildings.containers(
				town, lx + (float(i) - float(n - 1) * 0.5) * 2.9, lz, ry + PI * 0.5, 3
			)
		return
	if q < 0.27 and lw > 11.0 and ld > 9.0:
		town.register(PropBuildings.market(town, lx, lz, lw, ld, ry))
		return
	if q < 0.33:
		_yard(lot)
		return

	var floors: int = 1
	var pr: float = r.next()
	var near: float = 1.0 - smoothstep(tuning.core_near, tuning.core_far, d_core)
	if pr < tuning.floor2_base + near * tuning.floor2_core:
		floors = 2
	if pr < tuning.floor3_base + near * tuning.floor3_core:
		floors = 3
	if pr < tuning.floor4_base + near * tuning.floor4_core:
		floors = 4
	if lw < 7.0 or ld < 7.0:
		floors = mini(floors, 2)
	var door_side: int = 0 if absf(lot.y - blk.y) < absf(lot.x - blk.x) else 3
	town.register(PropBuildings.adobe(town, lx, lz, lw, ld, floors, ry, 0.0, door_side))


## An open yard: scattered junk and, half the time, a wire fence along the front.
func _yard(lot: Vector4) -> void:
	var r: XorShift32 = town.rng
	var n: int = r.next_int(3, 8)
	for _i in n:
		var px: float = r.next_range(lot.x + 1.0, lot.z - 1.0)
		var pz: float = r.next_range(lot.y + 1.0, lot.w - 1.0)
		var u: float = r.next()
		var b: float = town.ground_h(px, pz)
		if u < 0.30:
			PropClutter.barrel(town, px, b, pz)
		elif u < 0.55:
			PropClutter.crate(town, px, b, pz, r.next() * 3.0)
		elif u < 0.72:
			PropClutter.sandbags(town, px, b, pz, r.next() * 3.0)
		elif u < 0.85:
			PropClutter.wreck(town, px, pz, r.next() * 3.0)
		else:
			PropClutter.big_crate(town, px, b, pz, r.next() * 3.0)
	if not r.chance(0.5):
		return
	for i in 7:
		var px: float = lerpf(lot.x, lot.z, float(i) / 6.0)
		var pz: float = lot.y + 0.4
		var b: float = town.ground_h(px, pz)
		town.mesher.cylinder(
			Vector3(px, b + 0.9, pz),
			0.045,
			0.045,
			0.9,
			5,
			WorldPalette.RAIL,
			WorldSurface.Kind.METAL
		)
		town.add_col(
			Vector3(px, b + 0.9, pz), Vector3(0.07, 0.9, 0.07), 0.0, WorldSurface.Kind.METAL
		)
	town.deco(
		Vector3((lot.x + lot.z) * 0.5, town.ground_h(lot.x, lot.y) + 1.72, lot.y + 0.4),
		Vector3((lot.z - lot.x) * 0.5, 0.03, 0.03),
		0.0,
		WorldPalette.RAIL,
		WorldSurface.Kind.METAL
	)


## Junk strewn down the main strip and the cross street. The position and the
## axis are drawn before the plaza keep-out rejects the site, so a rejected item
## still costs two draws — which is why the litter is not evenly spaced.
func _street_clutter() -> void:
	var r: XorShift32 = town.rng
	var t: float = tuning.town_half_extent
	for _i in tuning.street_clutter:
		var f: float = r.next_range(-1.0, 1.0)
		var along: bool = r.chance(0.5)
		var px: float = -8.0 + r.next_range(-9.0, 9.0) if along else f * t
		var pz: float = f * t if along else 16.0 + r.next_range(-8.0, 8.0)
		if Vector2(px, pz).distance_to(tuning.plaza_center) < tuning.street_clutter_keepout:
			continue
		var b: float = town.ground_h(px, pz)
		var u: float = r.next()
		if u < 0.25:
			PropClutter.barrel(town, px, b, pz)
		elif u < 0.45:
			PropClutter.wreck(town, px, pz, r.next() * 3.0)
		elif u < 0.62:
			PropClutter.crate(town, px, b, pz, r.next() * 3.0)
		elif u < 0.78:
			PropClutter.sandbags(town, px, b, pz, r.next() * 3.0)
		else:
			town.mesher.cylinder(
				Vector3(px, b + 2.6, pz),
				0.08,
				0.07,
				2.6,
				6,
				WorldPalette.RAIL,
				WorldSurface.Kind.METAL
			)
			town.add_col(
				Vector3(px, b + 2.6, pz), Vector3(0.11, 2.6, 0.11), 0.0, WorldSurface.Kind.METAL
			)
			town.deco(
				Vector3(px + 0.5, b + 5.0, pz),
				Vector3(0.5, 0.06, 0.06),
				0.0,
				WorldPalette.RAIL,
				WorldSurface.Kind.METAL
			)


# ------------------------------------------------------------------- the wilds


## Everything outside the town: rock fields, dead trees, wrecks, drum dumps,
## container drops, fence lines, four squatter camps and a crashed transport.
##
## Two streams interleave here. The local one decides WHERE — angle, radius, the
## branch roll, camp offsets, fence bearings. Every generator it calls draws from
## the town stream. The fence branch's colour comes from the local stream, which
## is the reference's inconsistency and is reproduced.
func scatter_wilds() -> void:
	var r := XorShift32.new(tuning.world_seed ^ SALT_WILDS)
	for _i in tuning.wilds_count:
		var a: float = r.next() * TAU
		var rad: float = (
			tuning.wilds_inner + pow(r.next(), tuning.wilds_radius_bias) * tuning.wilds_span
		)
		var x: float = cos(a) * rad
		var z: float = sin(a) * rad
		if absf(x) > tuning.wilds_bound or absf(z) > tuning.wilds_bound:
			continue
		var h: float = town.ground_h(x, z)
		if town.ground_normal(x, z).y < tuning.wilds_min_normal:
			continue
		var u: float = r.next()
		if u < 0.34:
			PropClutter.rock_cluster(town, x, z)
		elif u < 0.56:
			PropClutter.dead_tree(town, x, z)
		elif u < 0.66:
			PropClutter.wreck(town, x, z, r.next() * 3.0)
		elif u < 0.74:
			var drums: int = r.next_int(2, 5)
			for _j in drums:
				# Three separate offset draws: the drum's x and the x its ground
				# height is sampled at are different numbers. That is why a dump
				# reads as dropped rather than placed.
				var bx: float = x + r.next_range(-3.0, 3.0)
				var gx: float = x + r.next_range(-3.0, 3.0)
				var bz: float = z + r.next_range(-3.0, 3.0)
				PropClutter.barrel(town, bx, town.ground_h(gx, z), bz)
		elif u < 0.80:
			PropBuildings.containers(town, x, z, r.next() * 3.0, 2)
		elif u < 0.86:
			var a2: float = r.next() * TAU
			var posts: int = r.next_int(5, 14)
			for j in posts:
				var px: float = x + cos(a2) * float(j) * 2.4
				var pz: float = z + sin(a2) * float(j) * 2.4
				var b: float = town.ground_h(px, pz)
				var post_c: Color = WorldPalette.vary(WorldPalette.POST, r)
				town.mesher.cylinder(
					Vector3(px, b + 0.85, pz), 0.05, 0.05, 0.85, 5, post_c, WorldSurface.Kind.WOOD
				)
				town.add_col(
					Vector3(px, b + 0.85, pz),
					Vector3(0.08, 0.85, 0.08),
					0.0,
					WorldSurface.Kind.WOOD
				)
		elif u < 0.93:
			PropClutter.crate(town, x, h, z, r.next() * 3.0)
		else:
			PropClutter.dead_tree(town, x, z)

	for camp in CAMPS:
		var nb: int = r.next_int(2, 4)
		for _i in nb:
			var a: float = r.next() * TAU
			var rad: float = r.next_range(4.0, 14.0)
			var x: float = camp.x + cos(a) * rad
			var z: float = camp.y + sin(a) * rad
			if town.ground_normal(x, z).y < tuning.camp_min_normal:
				continue
			if r.chance(0.55):
				town.register(
					PropBuildings.adobe(
						town,
						x,
						z,
						r.next_range(6.0, 9.0),
						r.next_range(6.0, 9.0),
						1,
						r.next() * TAU
					)
				)
			elif r.chance(0.5):
				PropBuildings.containers(town, x, z, r.next() * TAU, 2)
			else:
				town.register(
					PropBuildings.ruin(
						town, x, z, r.next_range(6.0, 10.0), r.next_range(6.0, 10.0), r.next() * TAU
					)
				)
		for _i in 6:
			var a: float = r.next() * TAU
			var rad: float = r.next_range(3.0, 18.0)
			var x: float = camp.x + cos(a) * rad
			var z: float = camp.y + sin(a) * rad
			if r.chance(0.5):
				PropClutter.barrel(town, x, town.ground_h(x, z), z)
			else:
				PropClutter.wreck(town, x, z, r.next() * TAU)
		town.layout.add_poi(
			camp.x, town.ground_h(camp.x, camp.y), camp.y, "CAMP", WorldLayoutData.PoiKind.POI
		)

	_crash_site(r)


## The downed transport: nine tapering fuselage rings climbing out of the sand,
## and two wings canted into the dunes.
func _crash_site(r: XorShift32) -> void:
	var ax: float = CRASH_ORIGIN.x
	var az: float = CRASH_ORIGIN.y
	for i in 9:
		var t: float = float(i) / 9.0
		var px: float = ax + t * 34.0
		var pz: float = az + sin(t * 3.0) * 6.0
		var b: float = town.ground_h(px, pz)
		var col: Color = WorldPalette.vary(WorldPalette.FUSELAGE, r, 0.1)
		town.solid(
			Vector3(px, b + 1.2 + t * 1.6, pz),
			Vector3(2.0, 1.5 - t * 0.7, 1.9 - t * 0.8),
			0.4 + t * 0.2,
			col,
			WorldSurface.Kind.TIN
		)
	# Into the dunes, not over them. The height came off the ground under the
	# FUSELAGE and then added 3.4 m, which left an eighteen-metre panel hanging in
	# clear air nine metres off the axis with nothing under it. Each wing is now
	# sampled under its own centre and dropped until the sand closes over its
	# lower face, which is what "canted into the dunes" was always meant to be.
	for s: float in [-1.0, 1.0]:
		var wz: float = az + s * 9.0
		town.solid(
			Vector3(ax + 8.0, town.ground_h(ax + 8.0, wz) + 0.1, wz),
			Vector3(9.0, 0.22, 2.4),
			s * 0.28,
			WorldPalette.VENT,
			WorldSurface.Kind.TIN
		)
	town.layout.add_poi(
		ax + 16.0, town.ground_h(ax + 16.0, az), az, "CRASH", WorldLayoutData.PoiKind.POI
	)


# ------------------------------------------------------------------ extraction


## Three ways out: the culvert down in the wadi, the north gate past the last
## power pole, and the tallest wide roof in town.
func place_exfils() -> void:
	var wz: float = 196.0
	var wx: float = TerrainField.wadi_x(wz)
	_exfil(wx, wz, town.ground_h(wx, wz), "CULVERT")

	# The reference put this pad on the mirror image of the graded rim shelf, 15 m
	# off the road it is named after. The sign flip is corrected here: the shelf
	# runs along -8 - sin(z * 0.008) * 18 and so does the gate.
	var nz: float = -236.0
	var nx: float = -8.0 - sin(nz * 0.008) * 18.0
	_exfil(nx, nz, town.ground_h(nx, nz), "NORTH GATE")

	var best: BuildingRecord = null
	var best_rise: float = -INF
	for b in town.buildings:
		if not b.has_deck():
			continue
		if Vector2(b.x, b.z).length() > tuning.rooftop_max_radius:
			continue
		if minf(b.w, b.d) < tuning.rooftop_min_width:
			continue
		var rise: float = b.roof_y - b.base
		if rise > best_rise:
			best_rise = rise
			best = b
	if best != null:
		_exfil(best.x, best.z, best.roof_y, "ROOFTOP LZ")
	else:
		_exfil(40.0, 40.0, town.ground_h(40.0, 40.0), "ROOFTOP LZ")


## One pad: a painted ring, four flagged posts and a drum to hide behind.
func _exfil(x: float, z: float, y: float, pad_name: String) -> void:
	town.layout.add_poi(x, y, z, pad_name, WorldLayoutData.PoiKind.EXFIL)
	var rad: float = tuning.exfil_radius
	var seg: int = 16
	for i in seg:
		var a0: float = float(i) / float(seg) * TAU
		var a1: float = float(i + 1) / float(seg) * TAU
		town.mesher.strut(
			Vector3(x + cos(a0) * rad, y + 0.03, z + sin(a0) * rad),
			Vector3(x + cos(a1) * rad, y + 0.03, z + sin(a1) * rad),
			0.11,
			WorldPalette.EXFIL,
			WorldSurface.Kind.CONCRETE
		)
	for i in 4:
		var a: float = float(i) / 4.0 * TAU + 0.4
		var px: float = x + cos(a) * (rad + 0.5)
		var pz: float = z + sin(a) * (rad + 0.5)
		town.mesher.cylinder(
			Vector3(px, y + 1.35, pz),
			0.07,
			0.06,
			1.35,
			6,
			WorldPalette.RAIL,
			WorldSurface.Kind.METAL
		)
		town.add_col(
			Vector3(px, y + 1.35, pz), Vector3(0.1, 1.35, 0.1), 0.0, WorldSurface.Kind.METAL
		)
		town.deco(
			Vector3(px, y + 2.75, pz),
			Vector3(0.34, 0.24, 0.03),
			-a,
			WorldPalette.EXFIL,
			WorldSurface.Kind.TIN
		)
	PropClutter.barrel(town, x + rad * 0.75, y, z + rad * 0.75)
