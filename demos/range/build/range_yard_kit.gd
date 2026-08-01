extends RefCounted
## The yard the firing line stands in: the roof over the shooting positions, the
## five stations under it, the walls that close the place off behind, and the
## scrap fence that gives the lane its edges.
##
## BAKE-TIME ONLY. `tools/build_range.gd` is the only caller.
##
## NO `class_name` HERE, deliberately. A global class added to the project stays
## invisible to a `--script` main loop until the editor rescans and rewrites
## `.godot/global_script_class_cache.cfg`; a headless bake that named one would
## fail to compile on a clean checkout. The builder preloads this file by path,
## which needs no cache at all.
##
## Everything lands in one of two fused meshes. `YardNear` is the roof, the
## stations and the walls: it is inside forty metres, it is what the low sun draws
## the long shadows off, and it casts. `YardFar` is the run of fence past that.
## The directional cascade stops at 140 m, so a shadow from out there is paid for
## and never seen, and the far group does not cast.
##
## THE ROOF IS LAID IN SHEETS, NOT AS ONE SLAB, and one sheet is missing. That is
## the whole reason the firing point reads as shade rather than as a lid: the sun
## comes through the gap between every pair of sheets and through the hole where
## the fourth should be, so the pad under it is banded instead of flat.

# --- the roof over the firing point -----------------------------------------

## Underside of the roof structure at the datum sheet, metres. Four metres of
## clear height: lower than that and the sheeting is close enough to the eye to
## fill the whole upper half of the frame with one texture.
const CANOPY_Y: float = 4.05
## How far the sheeting reaches either side of the lane centre. It covers the two
## left-hand stations and stops: a range where every position is under cover has
## no sun on it to shoot in, and no contrast between the shade and the lane.
const CANOPY_X_MIN: float = -14.0
const CANOPY_X_MAX: float = -0.9
## Down-range and up-range edges of the sheeting. The far edge stops a hand's
## breadth short of the bay roof so the two do not weld into one component.
const CANOPY_Z_NEAR: float = -3.3
const CANOPY_Z_FAR: float = 7.3
## Where the posts stand. Three bays across, two rows deep.
const POST_X: PackedFloat32Array = [-13.0, -7.3, -1.6]
const POST_Z: PackedFloat32Array = [-2.6, 6.7]
## Half-section of a roof post, metres.
const POST_HALF: float = 0.12
## Head-beam soffit. Posts stop here and the purlins sit on top.
const BEAM_Y: float = 3.85
## Roof sheets, as z centres. The down-range run is missing — see the file
## header — which is also what keeps the solid roof off the front of the frame.
const SHEET_Z: PackedFloat32Array = [-2.0, 0.75, 3.5, 6.25]
const SHEET_HALF_Z: float = 1.30
const MISSING_SHEET: int = 0

# --- the firing stations -----------------------------------------------------

## One station per lane post, on the same 4.2 m spacing.
const STATION_X: PackedFloat32Array = [-8.4, -4.2, 0.0, 4.2, 8.4]
## Far enough up-range of the lane posts that the posts stand in front of the
## benches, which is the way round a firing line actually works.
const STATION_Z: float = -1.0
const BENCH_TOP_Y: float = 1.02

# --- the walls ---------------------------------------------------------------

## Where the yard wall and the lane fence stand, either side of the lane.
const YARD_HALF_X: float = 16.7
## The wall across the back of the yard.
const BACK_Z: float = 9.4
## How far up-range the solid, welded wall runs before it becomes scrap fence.
const WALL_Z_NEAR: float = -6.0
## How far the scrap fence runs before it becomes bare posts and junk.
const FENCE_Z_END: float = -58.0
## Posts keep marking the line, thinning out, to here.
const MARKER_POSTS_Z_END: float = -152.0
const FENCE_STEP: float = 1.25
const WALL_HEIGHT: float = 2.55

## Ammo cans, buckets, crates, pallets and the rest of the small stuff.
const Gear := preload("res://demos/range/build/range_gear.gd")

var _shop: RangeShop = null
var _rand: XorShift32 = null


func _init(workshop: RangeShop, rand: XorShift32) -> void:
	_shop = workshop
	_rand = rand


func build(root: Node3D) -> void:
	var yard := Node3D.new()
	yard.name = "Yard"
	root.add_child(yard)

	var near := WorldMesher.new()
	var far := WorldMesher.new()

	_canopy(near)
	for i: int in STATION_X.size():
		_station(near, i, STATION_X[i])
	_deck(near)
	_pad_furniture(near)
	_walls(near)
	_fence(far)

	_shop.add_mesh(yard, "YardNear", _shop.commit(near, "yard_near"), true)
	_shop.add_mesh(yard, "YardFar", _shop.commit(far, "yard_far"), false)

	_bodies(yard)
	_tarps(yard)
	_lights(yard)


# ================================================================== the canopy


## Six posts, two head beams, three purlins and four runs of sheeting with one
## run left off. Nothing here is decorative: every sheet lands on a purlin and
## every purlin lands on a beam, which is why it reads as built.
func _canopy(m: WorldMesher) -> void:
	for px: float in POST_X:
		for pz: float in POST_Z:
			m.box(
				Vector3(px, (BEAM_Y - 0.30) * 0.5, pz),
				Vector3(POST_HALF, (BEAM_Y + 0.30) * 0.5, POST_HALF),
				0.0,
				RangeShop.C_TIMBER,
				RangeShop.SURF_WOOD
			)
			# Foot plate, so the post is bolted down rather than pushed into the slab.
			m.box(
				Vector3(px, 0.36, pz),
				Vector3(POST_HALF + 0.07, 0.035, POST_HALF + 0.07),
				0.0,
				RangeShop.C_POST,
				RangeShop.SURF_METAL
			)

	var mid_x: float = (CANOPY_X_MIN + CANOPY_X_MAX) * 0.5
	var half_x: float = (CANOPY_X_MAX - CANOPY_X_MIN) * 0.5
	for pz: float in POST_Z:
		m.box(
			Vector3(mid_x, BEAM_Y - 0.11, pz),
			Vector3(half_x - 0.25, 0.13, 0.10),
			0.0,
			RangeShop.C_TIMBER.darkened(0.22),
			RangeShop.SURF_WOOD
		)
	for px: float in POST_X:
		m.box(
			Vector3(px, BEAM_Y + 0.07, (CANOPY_Z_NEAR + CANOPY_Z_FAR) * 0.5),
			Vector3(0.075, 0.07, (CANOPY_Z_FAR - CANOPY_Z_NEAR) * 0.5 + 0.25),
			0.0,
			RangeShop.C_STEEL_DARK,
			RangeShop.SURF_METAL
		)

	# Knee braces at every post head, and a wind brace across each end bay.
	for px: float in POST_X:
		for pz: float in POST_Z:
			var lean: float = 0.85 if pz < 0.0 else -0.85
			m.strut(
				Vector3(px, BEAM_Y - 0.95, pz),
				Vector3(px, BEAM_Y - 0.20, pz + lean),
				0.045,
				RangeShop.C_TIMBER.darkened(0.1),
				RangeShop.SURF_WOOD
			)
	for k: int in POST_X.size() - 1:
		m.strut(
			Vector3(POST_X[k], BEAM_Y - 1.57, POST_Z[0]),
			Vector3(POST_X[k + 1], BEAM_Y - 0.26, POST_Z[0]),
			0.032,
			RangeShop.C_STEEL_DARK,
			RangeShop.SURF_METAL
		)

	for s: int in SHEET_Z.size():
		var zc: float = SHEET_Z[s]
		var y: float = CANOPY_Y + (zc - 2.2) * 0.022
		if s == MISSING_SHEET:
			# The run that blew off. Three bare rafters and the sky between them.
			for r: int in 3:
				m.box(
					Vector3(mid_x, y - 0.13, zc - 1.05 + float(r) * 1.05),
					Vector3(half_x - 0.1, 0.055, 0.06),
					0.0,
					RangeShop.C_TIMBER.darkened(0.12),
					RangeShop.SURF_WOOD
				)
			continue
		# STEEL, not tin, and dark. The tin branch of the world shader mixes up to
		# 0.92 toward a rust colour that is brighter in linear space than anything
		# in this palette, so a roof given the tin id comes back saturated orange
		# whatever base it was handed — and its underside, which is what the
		# shooter looks at, is lit by ambient alone and shows it worst. The steel
		# branch mixes half as far toward a darker rust. The corrugation here is
		# real folded geometry, so nothing is lost by leaving the tin branch's
		# painted-on rib shading behind.
		m.corrugated(
			Vector3(mid_x, y, zc),
			half_x,
			SHEET_HALF_Z,
			12,
			0.055,
			RangeShop.C_TIN.darkened(0.42).lerp(
				RangeShop.C_DRUM_A.darkened(0.40), float(s % 3) * 0.24
			),
			RangeShop.SURF_METAL,
			0.0,
			0.012,
			0.05
		)

	_canopy_hangings(m)


## What hangs off a roof somebody wired themselves: a strung cable of rags along
## the down-range beam, a coil of hose on the middle post, and a board of hooks.
func _canopy_hangings(m: WorldMesher) -> void:
	var y: float = BEAM_Y - 0.22
	m.strut(
		Vector3(POST_X[0], y, POST_Z[0] - 0.16),
		Vector3(POST_X[2], y - 0.10, POST_Z[0] - 0.16),
		0.008,
		RangeShop.C_STEEL_DARK,
		RangeShop.SURF_METAL
	)
	for i: int in 7:
		var t: float = (float(i) + 0.5) / 7.0
		var rx: float = lerpf(POST_X[0], POST_X[2], t)
		var drop: float = 0.26 + RangeShop.hash01(i * 977) * 0.22
		var col: Color = RangeShop.C_TARP_RED if i % 3 == 0 else RangeShop.C_TARP
		m.box(
			Vector3(rx, y - 0.06 - drop * 0.5, POST_Z[0] - 0.16),
			Vector3(0.075, drop * 0.5, 0.012),
			RangeShop.hash01(i * 131) * 0.5 - 0.25,
			col,
			RangeShop.SURF_CLOTH
		)

	# Hose coil on the middle post: four rings of square section, hung off a peg.
	var hx: float = POST_X[1] + POST_HALF + 0.06
	var hy: float = 1.94
	var hz: float = POST_Z[1] - 0.02
	m.box(
		Vector3(hx - 0.03, hy + 0.30, hz),
		Vector3(0.06, 0.02, 0.02),
		0.0,
		RangeShop.C_STEEL,
		RangeShop.SURF_METAL
	)
	for i: int in 10:
		var a0: float = float(i) / 10.0 * TAU
		var a1: float = float(i + 1) / 10.0 * TAU
		var r: float = 0.26
		m.strut(
			Vector3(hx, hy + cos(a0) * r, hz + sin(a0) * r),
			Vector3(hx, hy + cos(a1) * r, hz + sin(a1) * r),
			0.026,
			RangeShop.C_LAMP,
			RangeShop.SURF_POLY
		)

	# Peg board on the up-range face of the last post, with three tools on it.
	m.box(
		Vector3(POST_X[2] + POST_HALF + 0.02, 1.72, POST_Z[1] + 0.30),
		Vector3(0.018, 0.34, 0.30),
		0.0,
		RangeShop.C_TIMBER.darkened(0.24),
		RangeShop.SURF_WOOD
	)
	for i: int in 3:
		var drop: float = 0.22 + float(i) * 0.09
		m.box(
			Vector3(
				POST_X[2] + POST_HALF + 0.05, 1.90 - drop * 0.5, POST_Z[1] + 0.10 + float(i) * 0.2
			),
			Vector3(0.022, drop * 0.5, 0.022),
			0.0,
			RangeShop.C_STEEL if i % 2 == 0 else RangeShop.C_TIMBER,
			RangeShop.SURF_METAL
		)


# ============================================================== firing stations


## A bench, its legs, a bag rest and whatever the person who uses that lane left
## on it. Five of them, none the same.
func _station(m: WorldMesher, index: int, x: float) -> void:
	var z: float = STATION_Z
	var yaw: float = (RangeShop.hash01(index * 7717) - 0.5) * 0.10
	var top: float = BENCH_TOP_Y
	m.box(
		Vector3(x, top, z),
		Vector3(0.80, 0.045, 0.31),
		yaw,
		RangeShop.C_TIMBER.darkened(0.06),
		RangeShop.SURF_WOOD
	)
	m.box(
		Vector3(x, top - 0.10, z),
		Vector3(0.74, 0.04, 0.26),
		yaw,
		RangeShop.C_TIMBER.darkened(0.26),
		RangeShop.SURF_WOOD
	)
	for side: int in 2:
		var lx: float = x + (0.64 if side == 1 else -0.64)
		m.box(
			Vector3(lx, (top + RangeShop.PAD_TOP) * 0.5 - 0.06, z),
			Vector3(0.048, (top - RangeShop.PAD_TOP) * 0.5 + 0.06, 0.048),
			yaw,
			RangeShop.C_POST,
			RangeShop.SURF_METAL
		)
		m.box(
			Vector3(lx, RangeShop.PAD_TOP + 0.02, z),
			Vector3(0.11, 0.025, 0.11),
			yaw,
			RangeShop.C_POST,
			RangeShop.SURF_METAL
		)
	m.strut(
		Vector3(x - 0.62, 0.56, z + 0.02),
		Vector3(x + 0.62, 0.62, z - 0.02),
		0.022,
		RangeShop.C_POST,
		RangeShop.SURF_METAL
	)

	# The rest: two bags, thrown down rather than laid out.
	m.box(
		Vector3(x - 0.11, top + 0.12, z - 0.02),
		Vector3(0.27, 0.077, 0.15),
		yaw + 0.19,
		RangeShop.C_TARP,
		RangeShop.SURF_CLOTH
	)
	m.box(
		Vector3(x + 0.15, top + 0.13, z + 0.03),
		Vector3(0.22, 0.082, 0.135),
		yaw - 0.34,
		RangeShop.C_TARP.darkened(0.14),
		RangeShop.SURF_CLOTH
	)
	_station_kit(m, index, x, z, yaw)


## What is on and under each bench. Written out one lane at a time on purpose —
## five procedurally jittered copies of the same three objects is the thing that
## reads as placeholder.
func _station_kit(m: WorldMesher, index: int, x: float, z: float, yaw: float) -> void:
	match index:
		0:
			Gear.ammo_can(m, Vector3(x + 0.52, BENCH_TOP_Y + 0.12, z + 0.06), yaw + 0.3)
			m.box(
				Vector3(x - 0.72, BENCH_TOP_Y - 0.13, z - 0.22),
				Vector3(0.12, 0.16, 0.02),
				yaw,
				RangeShop.C_TARP_RED,
				RangeShop.SURF_CLOTH
			)
			Gear.bucket(m, Vector3(x - 0.55, RangeShop.PAD_TOP, z + 0.42), 0.155, 0.20)
		1:
			Gear.crate(
				m,
				Vector3(x - 0.48, BENCH_TOP_Y + 0.05, z - 0.02),
				Vector3(0.24, 0.13, 0.17),
				yaw - 0.5
			)
			Gear.bottle(m, Vector3(x + 0.44, BENCH_TOP_Y + 0.05, z + 0.10))
			Gear.mat(m, Vector3(x, RangeShop.PAD_TOP, z - 0.95), 0.62, 0.44, yaw + 0.06)
		2:
			Gear.scope(m, Vector3(x + 1.28, RangeShop.PAD_TOP, z + 0.14))
			m.box(
				Vector3(x + 0.30, BENCH_TOP_Y + 0.05, z + 0.14),
				Vector3(0.16, 0.006, 0.11),
				yaw + 0.42,
				RangeShop.C_PAPER,
				RangeShop.SURF_POLY
			)
			Gear.ammo_can(m, Vector3(x - 0.86, RangeShop.PAD_TOP + 0.12, z + 0.30), yaw - 0.7)
		3:
			Gear.bucket(m, Vector3(x + 0.02, RangeShop.PAD_TOP, z + 0.34), 0.175, 0.24)
			Gear.crate(
				m,
				Vector3(x + 1.15, RangeShop.PAD_TOP + 0.22, z + 0.28),
				Vector3(0.28, 0.22, 0.24),
				0.34
			)
			m.strut(
				Vector3(x - 0.80, RangeShop.PAD_TOP + 0.02, z + 0.20),
				Vector3(x - 0.98, 1.44, z + 0.48),
				0.019,
				RangeShop.C_TIMBER,
				RangeShop.SURF_WOOD
			)
			m.box(
				Vector3(x - 0.99, 1.36, z + 0.50),
				Vector3(0.055, 0.10, 0.13),
				0.3,
				RangeShop.C_TARP.darkened(0.2),
				RangeShop.SURF_CLOTH
			)
		_:
			Gear.ammo_can(m, Vector3(x - 0.36, BENCH_TOP_Y + 0.12, z + 0.02), yaw + 0.12)
			Gear.ammo_can(m, Vector3(x - 0.33, BENCH_TOP_Y + 0.34, z - 0.01), yaw - 0.24)
			Gear.jerry(m, Vector3(x + 0.92, RangeShop.PAD_TOP, z + 0.36), -0.4)
			Gear.mat(m, Vector3(x - 0.1, RangeShop.PAD_TOP, z - 0.9), 0.58, 0.42, yaw - 0.09)


# ============================================================== the pad itself


## What is ON the slab between the shooter and the benches. Six timber battens
## set into the concrete divide the five lanes; a heavy cable runs out from the
## bay to the roof posts; and there is enough gear lying about that the walk to
## the line crosses something.
##
## The battens matter more than any of the clutter. Twenty-two metres of bare
## poured slab has nothing in it for the eye to measure, and six lines running
## away from you give the whole foreground the depth it was missing.
func _deck(m: WorldMesher) -> void:
	var z_far: float = -1.86
	var z_near: float = 4.7
	for lane_x: float in [-10.5, -6.3, -2.1, 2.1, 6.3, 10.5]:
		m.box(
			Vector3(lane_x, RangeShop.PAD_TOP + 0.005, (z_far + z_near) * 0.5),
			Vector3(0.065, 0.022, (z_near - z_far) * 0.5),
			0.0,
			RangeShop.C_POST,
			RangeShop.SURF_WOOD
		)
	# Every third batten carries a steel stud at the line, which is what a lane
	# number would be bolted to.
	for lane_x: float in [-6.3, 2.1]:
		m.box(
			Vector3(lane_x, RangeShop.PAD_TOP + 0.045, z_far + 0.30),
			Vector3(0.095, 0.055, 0.095),
			0.4,
			RangeShop.C_STEEL_DARK,
			RangeShop.SURF_METAL
		)

	# The cable that feeds the floods: out of the bay, along the slab, up a post.
	var run: Array[Vector3] = [
		Vector3(-10.6, 0.34, 7.9),
		Vector3(-8.2, 0.33, 5.9),
		Vector3(-4.4, 0.33, 3.4),
		Vector3(-2.0, 0.33, 1.9),
		Vector3(POST_X[2] + 0.10, 0.34, POST_Z[0] + 0.9),
		Vector3(POST_X[2] + 0.14, 1.30, POST_Z[0] + 0.16),
		Vector3(POST_X[2] + 0.14, BEAM_Y - 0.30, POST_Z[0] + 0.10),
	]
	for i: int in run.size() - 1:
		m.strut(run[i], run[i + 1], 0.021, RangeShop.C_LAMP, RangeShop.SURF_POLY)
	for i: int in 3:
		m.box(
			run[i + 1] + Vector3(0.0, -0.02, 0.0),
			Vector3(0.075, 0.02, 0.075),
			0.0,
			RangeShop.C_POST,
			RangeShop.SURF_METAL
		)

	# Gear left on the deck on the way in.
	Gear.crate(m, Vector3(-3.55, RangeShop.PAD_TOP + 0.21, 2.65), Vector3(0.36, 0.21, 0.26), 0.28)
	Gear.jerry(m, Vector3(-2.85, RangeShop.PAD_TOP, 2.05), 0.9)
	Gear.bucket(m, Vector3(-4.35, RangeShop.PAD_TOP, 2.15), 0.16, 0.21)
	Gear.mat(m, Vector3(3.1, RangeShop.PAD_TOP, 3.05), 0.85, 0.58, -0.22)
	for i: int in 4:
		# Offcuts of batten, stacked where they were cut.
		m.box(
			Vector3(5.9 + float(i) * 0.03, RangeShop.PAD_TOP + 0.04 + float(i) * 0.055, 1.55),
			Vector3(0.72, 0.028, 0.06),
			0.18 + float(i) * 0.09,
			RangeShop.C_TIMBER.darkened(0.1 + float(i) * 0.05),
			RangeShop.SURF_WOOD
		)
	# The hose that feeds the coil, run back to the bay straight across the walk-up
	# rather than tidied to an edge. Lines on the ground are what give a bare slab
	# its depth, and the walk to the line is where the slab is barest.
	var hose: Array[Vector3] = [
		Vector3(-9.4, 0.325, 7.1),
		Vector3(-5.6, 0.325, 5.2),
		Vector3(-1.4, 0.325, 4.35),
		Vector3(1.9, 0.325, 3.15),
		Vector3(5.4, 0.325, 3.45),
		Vector3(7.75, 0.325, 3.32),
	]
	for i: int in hose.size() - 1:
		m.strut(hose[i], hose[i + 1], 0.021, RangeShop.C_LAMP.lightened(0.06), RangeShop.SURF_POLY)
	Gear.coil(m, Vector3(8.1, RangeShop.PAD_TOP, 3.35), 0.38, 14, RangeShop.C_LAMP.lightened(0.06))

	Gear.mat(m, Vector3(-1.45, RangeShop.PAD_TOP, 1.55), 0.78, 0.55, 0.14)

	# Boards left where they were dropped. Flat enough to walk straight over.
	var boards: Array = [
		[Vector2(1.05, 2.35), 0.86, 0.13, -0.62],
		[Vector2(1.35, 2.05), 0.80, 0.11, -0.48],
		[Vector2(-0.9, 4.15), 0.52, 0.40, 0.34],
		[Vector2(-2.35, 0.55), 0.62, 0.14, 1.24],
	]
	for b: Array in boards:
		var at: Vector2 = b[0] as Vector2
		m.box(
			Vector3(at.x, RangeShop.PAD_TOP + 0.019, at.y),
			Vector3(float(b[1]), 0.019, float(b[2])),
			float(b[3]),
			RangeShop.C_TIMBER.darkened(0.18),
			RangeShop.SURF_WOOD
		)


# ================================================================== pad clutter


## The gear that lives on the slab rather than on a bench: a stack of spare
## plates waiting to be hung, a drum of water and the pallet everything came on.
func _pad_furniture(m: WorldMesher) -> void:
	Gear.water_tank(m, Vector3(10.8, 0.0, -11.5))
	var rx: float = 8.9
	var rz: float = 4.6
	for side: int in 2:
		m.box(
			Vector3(rx + (1.35 if side == 1 else -1.35), 0.92, rz),
			Vector3(0.055, 0.62, 0.055),
			0.0,
			RangeShop.C_POST,
			RangeShop.SURF_METAL
		)
	m.box(
		Vector3(rx, 1.48, rz),
		Vector3(1.42, 0.05, 0.06),
		0.0,
		RangeShop.C_POST,
		RangeShop.SURF_METAL
	)
	for i: int in 4:
		var px: float = rx - 0.95 + float(i) * 0.63
		var r: float = 0.20 + RangeShop.hash01(i * 5171) * 0.16
		# Hung from the rail by a strap, so every plate's top edge lines up and the
		# different diameters hang to different depths, which is how a rack looks.
		m.cylinder(
			Vector3(px, 1.31 - r, rz + 0.06),
			r,
			r,
			0.014,
			18,
			RangeShop.C_STEEL,
			RangeShop.SURF_METAL,
			Vector3.BACK
		)
		m.strut(
			Vector3(px, 1.45, rz + 0.02),
			Vector3(px, 1.30, rz + 0.06),
			0.010,
			RangeShop.C_STEEL_DARK,
			RangeShop.SURF_METAL
		)

	# Water drum on a pallet, by the bay's near corner.
	var dx: float = -10.2
	var dz: float = 6.4
	Gear.pallet(m, Vector3(dx, RangeShop.PAD_TOP, dz), 0.22)
	m.cylinder(
		Vector3(dx, RangeShop.PAD_TOP + 0.58, dz),
		0.30,
		0.30,
		0.44,
		14,
		RangeShop.C_DRUM_B,
		RangeShop.SURF_METAL
	)
	m.cylinder(
		Vector3(dx, RangeShop.PAD_TOP + 1.03, dz),
		0.305,
		0.305,
		0.03,
		14,
		RangeShop.C_DRUM_RIB,
		RangeShop.SURF_METAL
	)
	m.cylinder(
		Vector3(dx + 0.16, RangeShop.PAD_TOP + 1.07, dz),
		0.075,
		0.075,
		0.02,
		10,
		RangeShop.C_DRUM_CAP,
		RangeShop.SURF_METAL
	)
	Gear.pallet(m, Vector3(11.4, 0.0, 1.2), -0.31)
	Gear.crate(m, Vector3(11.4, 0.34, 1.2), Vector3(0.34, 0.20, 0.24), -0.31)
	Gear.crate(m, Vector3(11.2, 0.72, 1.1), Vector3(0.30, 0.18, 0.21), 0.12)


# ==================================================================== the walls


## The yard, closed. Corrugated across the back either side of the bay, and a
## welded return down each side as far as the fence takes over.
func _walls(m: WorldMesher) -> void:
	RangeShop.tin_wall(
		m,
		Vector3(-YARD_HALF_X, 0.0, BACK_Z),
		Vector3(-11.0, 0.0, BACK_Z),
		WALL_HEIGHT,
		0.86,
		RangeShop.C_TIN.darkened(0.34)
	)
	RangeShop.tin_wall(
		m,
		Vector3(4.2, 0.0, BACK_Z),
		Vector3(YARD_HALF_X, 0.0, BACK_Z),
		WALL_HEIGHT,
		0.86,
		RangeShop.C_TIN.darkened(0.30).lerp(RangeShop.C_DRUM_A.darkened(0.32), 0.35)
	)
	for side: int in 2:
		var sx: float = YARD_HALF_X if side == 1 else -YARD_HALF_X
		RangeShop.tin_wall(
			m,
			Vector3(sx, 0.0, BACK_Z),
			Vector3(sx, 0.0, WALL_Z_NEAR),
			WALL_HEIGHT - 0.25,
			0.92,
			RangeShop.C_TIN.darkened(0.32).lerp(
				RangeShop.C_DRUM_A.darkened(0.30), 0.14 + float(side) * 0.26
			)
		)
		# A brace off the back of every third post, propping the run.
		var pz: float = BACK_Z - 1.2
		while pz > WALL_Z_NEAR:
			m.strut(
				Vector3(sx, WALL_HEIGHT - 0.7, pz),
				Vector3(sx + (1.0 if side == 1 else -1.0), 0.05, pz),
				0.035,
				RangeShop.C_TIMBER.darkened(0.1),
				RangeShop.SURF_WOOD
			)
			pz -= 3.9


# ==================================================================== the fence


## The scrap fence that carries the yard wall on down the lane. Posts the whole
## way, panels most of the way, and a pair of wire strands wherever a panel is
## gone — which is what makes a boundary read as a boundary rather than as a row
## of sticks.
func _fence(m: WorldMesher) -> void:
	for side: int in 2:
		var sx: float = YARD_HALF_X if side == 1 else -YARD_HALF_X
		var z: float = WALL_Z_NEAR
		while z > FENCE_Z_END:
			var jitter: float = (_rand.next() - 0.5) * 0.22
			var post_h: float = 1.95 + _rand.next() * 0.35
			m.box(
				Vector3(sx + jitter, post_h * 0.5 - 0.15, z),
				Vector3(0.06, post_h * 0.5 + 0.15, 0.06),
				0.0,
				RangeShop.C_POST,
				RangeShop.SURF_METAL
			)
			if _rand.next() > 0.21:
				var h: float = 1.35 + _rand.next() * 0.75
				var lean: float = (_rand.next() - 0.5) * 0.13
				_panel(m, Vector3(sx + jitter * 0.5, 0.0, z - FENCE_STEP * 0.5), h, lean)
			else:
				for strand: int in 2:
					var sy: float = 0.85 + float(strand) * 0.62
					m.strut(
						Vector3(sx + jitter, sy, z),
						Vector3(sx, sy - 0.06, z - FENCE_STEP),
						0.012,
						RangeShop.C_STEEL_DARK,
						RangeShop.SURF_METAL
					)
			z -= FENCE_STEP
		# Past the fence the line is kept by posts alone, thinning with distance.
		var step: float = 4.0
		while z > MARKER_POSTS_Z_END:
			m.box(
				Vector3(sx + (_rand.next() - 0.5) * 0.5, 0.92, z),
				Vector3(0.065, 1.07, 0.065),
				0.0,
				RangeShop.C_POST,
				RangeShop.SURF_METAL
			)
			z -= step
			step *= 1.14


## One leaning sheet of scrap, ribbed on the diagonal it was cut from.
##
## STEEL, NOT TIN. The tin branch of the world shader mixes toward a fixed rust
## colour that is brighter in linear space than any base this palette has, so a
## whole run of tin fence comes back pale orange whatever colour it was given.
## The steel branch mixes toward a darker rust at twice the frequency, which on a
## 1.3 m panel is wear rather than camouflage.
func _panel(m: WorldMesher, base: Vector3, height: float, lean: float) -> void:
	var half_w: float = FENCE_STEP * 0.52
	var col: Color = RangeShop.C_RAIL.lerp(RangeShop.C_DRUM_A.darkened(0.30), _rand.next() * 0.55)
	m.oriented_box(
		base + Vector3(0.0, height * 0.5, 0.0),
		Vector3(0.022, 0.0, 0.0),
		Vector3(sin(lean) * height * 0.5, cos(lean) * height * 0.5, 0.0),
		Vector3(0.0, 0.0, half_w),
		col,
		RangeShop.SURF_METAL
	)
	for i: int in 3:
		var t: float = (float(i) + 0.5) / 3.0 * 2.0 - 1.0
		m.oriented_box(
			base + Vector3(0.02, height * 0.5, t * half_w),
			Vector3(0.016, 0.0, 0.0),
			Vector3(sin(lean) * (height * 0.5 - 0.03), cos(lean) * (height * 0.5 - 0.03), 0.0),
			Vector3(0.0, 0.0, half_w * 0.26),
			col.darkened(0.14),
			RangeShop.SURF_METAL
		)


# ================================================================== attachments


## Colliders. The visual is one fused soup; what you can walk into is nine boxes,
## which is the whole of it and none of the tool rack.
func _bodies(yard: Node3D) -> void:
	for px: float in POST_X:
		for pz: float in POST_Z:
			yard.add_child(
				_shop.box_body(
					"CanopyPost_%d_%d" % [int(px * 10.0), int(pz * 10.0)],
					Vector3(px, 1.5, pz),
					Vector3(POST_HALF * 2.0, 3.4, POST_HALF * 2.0),
					&"wood"
				)
			)
	for x: float in STATION_X:
		yard.add_child(
			_shop.box_body(
				"Bench_%d" % int(x * 10.0),
				Vector3(x, (BENCH_TOP_Y + RangeShop.PAD_TOP) * 0.5, STATION_Z),
				Vector3(1.60, BENCH_TOP_Y - RangeShop.PAD_TOP, 0.62),
				&"wood"
			)
		)

	var wall_y: float = WALL_HEIGHT * 0.5
	yard.add_child(
		_shop.box_body(
			"BackWallLeft",
			Vector3((-YARD_HALF_X - 11.0) * 0.5, wall_y, BACK_Z),
			Vector3(YARD_HALF_X - 11.0, WALL_HEIGHT, 0.30),
			&"metal"
		)
	)
	yard.add_child(
		_shop.box_body(
			"BackWallRight",
			Vector3((4.2 + YARD_HALF_X) * 0.5, wall_y, BACK_Z),
			Vector3(YARD_HALF_X - 4.2, WALL_HEIGHT, 0.30),
			&"metal"
		)
	)
	yard.add_child(
		_shop.box_body("WaterTank", Vector3(10.8, 1.6, -11.5), Vector3(1.90, 3.20, 1.90), &"wood")
	)
	yard.add_child(
		_shop.box_body(
			"DeckCrate",
			Vector3(-3.55, RangeShop.PAD_TOP + 0.21, 2.65),
			Vector3(0.80, 0.42, 0.60),
			&"wood"
		)
	)
	for side: int in 2:
		var sx: float = YARD_HALF_X if side == 1 else -YARD_HALF_X
		yard.add_child(
			_shop.box_body(
				"LaneEdge%s" % ("R" if side == 1 else "L"),
				Vector3(sx, 1.05, (BACK_Z + FENCE_Z_END) * 0.5),
				Vector3(0.34, 2.10, BACK_Z - FENCE_Z_END),
				&"metal"
			)
		)


## Two more sheets in the wind, hung where the shooter can see them move: one off
## the down-range beam, one off the fence at the lane mouth. They join the group
## `range_ambience.gd` sways, so they lean with the same gust as the bay's.
func _tarps(yard: Node3D) -> void:
	var tarps := Node3D.new()
	tarps.name = "YardTarps"
	tarps.add_to_group(&"range_tarps")
	yard.add_child(tarps)
	var specs: Array = [
		[
			"TarpCanopy",
			Vector3(-12.6, BEAM_Y - 0.34, POST_Z[0] + 0.2),
			1.15,
			1.30,
			0.05,
			0.0,
			RangeShop.C_TARP
		],
		[
			"TarpFenceL",
			Vector3(-YARD_HALF_X + 0.18, 1.95, -9.4),
			0.05,
			0.80,
			0.80,
			0.16,
			RangeShop.C_TARP_RED.darkened(0.24)
		],
		[
			"TarpFenceR",
			Vector3(YARD_HALF_X - 0.20, 2.10, -7.2),
			0.05,
			0.88,
			0.95,
			-0.14,
			RangeShop.C_TARP
		],
	]
	for spec: Array in specs:
		var m := WorldMesher.new()
		var hx: float = float(spec[2])
		var hy: float = float(spec[3])
		var hz: float = float(spec[4])
		var col: Color = spec[6] as Color
		for i: int in 3:
			var t: float = float(i) / 2.0
			var w: float = lerpf(1.0, 0.84, t)
			m.box(
				Vector3(0.0, -hy * (0.34 + t * 0.66), 0.0),
				Vector3(maxf(hx * w, 0.03), hy * 0.36, maxf(hz * w, 0.03)),
				float(spec[5]) + t * 0.07,
				col.lerp(Color.BLACK, t * 0.2),
				RangeShop.SURF_CLOTH
			)
		var node := Node3D.new()
		node.name = String(spec[0])
		node.position = spec[1] as Vector3
		tarps.add_child(node)
		_shop.add_mesh(node, "Cloth", _shop.commit(m, String(spec[0]).to_snake_case()), true)


## Two floods under the roof, on the same flicker as the bay's. Short range, no
## shadows and faded out well before they could reach the lane: what they are for
## is the warm pool the shade under the canopy would otherwise not have.
func _lights(yard: Node3D) -> void:
	var lights := Node3D.new()
	lights.name = "YardLights"
	lights.add_to_group(&"range_work_lights")
	yard.add_child(lights)

	var m := WorldMesher.new()
	var specs: Array = [
		[Vector3(POST_X[1], BEAM_Y - 0.34, 1.4), 7.5, 2.3],
		[Vector3(POST_X[2], BEAM_Y - 0.34, 4.6), 6.5, 1.9],
	]
	for i: int in specs.size():
		var at: Vector3 = specs[i][0] as Vector3
		var lamp := OmniLight3D.new()
		lamp.name = "Flood%d" % i
		lamp.position = at + Vector3(0.0, -0.16, 0.0)
		lamp.omni_range = float(specs[i][1])
		lamp.light_energy = float(specs[i][2])
		lamp.light_color = Color(1.0, 0.86, 0.63)
		lamp.shadow_enabled = false
		lamp.distance_fade_enabled = true
		lamp.distance_fade_begin = 30.0
		lamp.distance_fade_length = 12.0
		lights.add_child(lamp)
		# Pressed-steel housing on a swan neck, aimed at the bench below it.
		m.strut(
			at + Vector3(0.0, 0.34, 0.0),
			at + Vector3(0.03, 0.05, 0.0),
			0.011,
			RangeShop.C_LAMP,
			RangeShop.SURF_METAL
		)
		m.box(at, Vector3(0.155, 0.075, 0.10), 0.0, RangeShop.C_LAMP, RangeShop.SURF_METAL)
		m.box(
			at + Vector3(0.0, -0.075, 0.0),
			Vector3(0.135, 0.02, 0.082),
			0.0,
			Color("ffe6b4"),
			RangeShop.SURF_POLY
		)
		m.box(
			at + Vector3(0.0, 0.045, -0.12),
			Vector3(0.155, 0.055, 0.03),
			0.0,
			RangeShop.C_LAMP.lightened(0.1),
			RangeShop.SURF_METAL
		)
	_shop.add_mesh(lights, "Housings", _shop.commit(m, "yard_floods"), false)
