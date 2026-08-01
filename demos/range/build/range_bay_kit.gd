class_name RangeBayKit
extends RefCounted
## The bay behind the firing line: a slab, four posts, a corrugated roof, two
## walls, the bench the console is bolted to, and the clutter of a range that
## somebody actually uses.
##
## BAKE-TIME ONLY. `tools/build_range.gd` is the only caller.
##
## The bay is one fused mesh plus four box colliders. Nothing in it repeats often
## enough for instancing to pay — every crate is a different size and a different
## shade — so one un-indexed soup is strictly the cheapest thing it can be, and
## the colliders are the four surfaces you can actually walk into rather than a
## trimesh of the tool rack.

var shop: RangeShop = null


func _init(workshop: RangeShop) -> void:
	shop = workshop


## The place somebody works: slab, posts, roof, walls, bench, racks, tarps and
## the clutter of a range that gets used.
func build(root: Node3D) -> void:
	var bay := Node3D.new()
	bay.name = "Bay"
	root.add_child(bay)

	var m := WorldMesher.new()
	var cz: float = (RangeShop.BAY_Z_NEAR + RangeShop.BAY_Z_FAR) * 0.5
	var hz: float = (RangeShop.BAY_Z_FAR - RangeShop.BAY_Z_NEAR) * 0.5

	# Slab, flush with the pad top, sunk well below grade.
	m.box(
		Vector3(RangeShop.BAY_CENTER_X, RangeShop.PAD_TOP - 0.35, cz),
		Vector3(RangeShop.BAY_HALF_X, 0.35, hz),
		0.0,
		RangeShop.C_PAD.lerp(RangeShop.C_DIRT, 0.25),
		RangeShop.SURF_CONCRETE
	)

	# Four posts, each sunk 0.25 m into the slab.
	var post_x: PackedFloat32Array = [
		RangeShop.BAY_CENTER_X - RangeShop.BAY_HALF_X + 0.5,
		RangeShop.BAY_CENTER_X + RangeShop.BAY_HALF_X - 0.5
	]
	var post_z: PackedFloat32Array = [RangeShop.BAY_Z_NEAR + 0.6, RangeShop.BAY_Z_FAR - 0.6]
	for px: float in post_x:
		for pz: float in post_z:
			m.box(
				Vector3(px, (RangeShop.BAY_POST_TOP + RangeShop.PAD_TOP - 0.25) * 0.5, pz),
				Vector3(0.11, (RangeShop.BAY_POST_TOP - RangeShop.PAD_TOP + 0.25) * 0.5, 0.11),
				0.0,
				RangeShop.C_TIMBER,
				RangeShop.SURF_WOOD
			)
	# Wall plates the roof lands on, lapping over the post heads.
	for pz: float in post_z:
		m.box(
			Vector3(RangeShop.BAY_CENTER_X, RangeShop.BAY_POST_TOP + 0.08, pz),
			Vector3(RangeShop.BAY_HALF_X - 0.3, 0.10, 0.14),
			0.0,
			RangeShop.C_TIMBER.darkened(0.1),
			RangeShop.SURF_WOOD
		)
	# Corrugated roof, lapping past the plates on all four sides. Dark, because
	# the tin branch of the world shader blooms rust over the base colour: at
	# `C_TIN` itself a sunlit roof comes back pale orange, which is not a roof.
	m.corrugated(
		Vector3(RangeShop.BAY_CENTER_X, RangeShop.BAY_ROOF_Y, cz),
		RangeShop.BAY_HALF_X + 0.45,
		hz + 0.55,
		30,
		0.055,
		RangeShop.C_TIN.darkened(0.36),
		RangeShop.SURF_TIN,
		0.0,
		0.035,
		0.07
	)

	# Back wall: corrugated steel in a timber frame, the same as the side.
	#
	# It was a single 14 x 3.1 m timber box, and the timber branch of the world
	# shader warps a 0.45 m grain by `fbm(p * vec3(0.9, 4, 4))`, which on a face
	# that size is one continuous sheet of plywood swirl — the exact reading the
	# art direction forbids. Twenty-six separately toned and staggered boards were
	# tried and did not break it: the noise is world-space, so it runs straight
	# across every seam. Cladding the shed in one material does break it, costs
	# fewer triangles than the boards did, and is what a scav shed is anyway.
	_back_wall(m)
	for rail_y: float in [0.62, 2.52]:
		m.box(
			Vector3(RangeShop.BAY_CENTER_X, rail_y, RangeShop.BAY_Z_FAR - 0.24),
			Vector3(RangeShop.BAY_HALF_X - 0.2, 0.07, 0.05),
			0.0,
			RangeShop.C_TIMBER,
			RangeShop.SURF_WOOD
		)
	# Side wall, corrugated tin, STANDING UP. `WorldMesher.corrugated` puts its
	# profile in Y on an XZ plane, which is a roof: asked for a wall it returns a
	# 3.4 x 8.8 m sheet lying flat in the air at 1.85 m, which is what used to be
	# here and what the 0.24 x 3.10 m collider below never matched.
	var wall_x: float = RangeShop.BAY_CENTER_X - RangeShop.BAY_HALF_X + 0.16
	RangeShop.tin_wall(
		m,
		Vector3(wall_x, RangeShop.PAD_TOP - 0.35, cz - (hz - 0.3)),
		Vector3(wall_x, RangeShop.PAD_TOP - 0.35, cz + (hz - 0.3)),
		3.45,
		0.54,
		RangeShop.C_TIN.darkened(0.34)
	)

	_bench_furniture(m)
	_bay_clutter(m)

	var mesh: ArrayMesh = shop.commit(m, "bay")
	shop.add_mesh(bay, "BayMesh", mesh, true)

	bay.add_child(
		shop.box_body(
			"BaySlab",
			Vector3(RangeShop.BAY_CENTER_X, RangeShop.PAD_TOP - 0.35, cz),
			Vector3(RangeShop.BAY_HALF_X * 2.0, 0.70, hz * 2.0),
			&"concrete"
		)
	)
	bay.add_child(
		shop.box_body(
			"BackWall",
			Vector3(RangeShop.BAY_CENTER_X, 1.63, RangeShop.BAY_Z_FAR - 0.16),
			Vector3((RangeShop.BAY_HALF_X - 0.2) * 2.0, 3.40, 0.30),
			&"metal"
		)
	)
	bay.add_child(
		shop.box_body(
			"SideWall",
			Vector3(RangeShop.BAY_CENTER_X - RangeShop.BAY_HALF_X + 0.16, 1.675, cz),
			Vector3(0.24, 3.45, (hz - 0.3) * 2.0),
			&"metal"
		)
	)
	bay.add_child(
		shop.box_body(
			"Console",
			Vector3(RangeShop.BAY_CENTER_X, 1.20, RangeShop.CONSOLE_Z + 0.20),
			Vector3(7.0, 1.80, 0.72),
			&"metal"
		)
	)
	_add_tarps(bay)


## The back of the bay: a run of corrugated steel between six timber studs, sunk
## into the slab and reaching to just under the roof. See the note at the call
## site for why it is not boarded timber.
func _back_wall(m: WorldMesher) -> void:
	var half: float = RangeShop.BAY_HALF_X - 0.2
	var z: float = RangeShop.BAY_Z_FAR - 0.12
	var base: float = RangeShop.PAD_TOP - 0.35
	RangeShop.tin_wall(
		m,
		Vector3(RangeShop.BAY_CENTER_X - half, base, z),
		Vector3(RangeShop.BAY_CENTER_X + half, base, z),
		3.40,
		0.58,
		RangeShop.C_TIN.darkened(0.30).lerp(RangeShop.C_DRUM_A.darkened(0.34), 0.22)
	)
	for i: int in 6:
		var sx: float = RangeShop.BAY_CENTER_X - half + half * 2.0 * float(i) / 5.0
		m.box(
			Vector3(sx, 1.68, z - 0.13),
			Vector3(0.075, 1.73, 0.075),
			0.0,
			RangeShop.C_TIMBER.darkened(0.14 + RangeShop.hash01(i * 6151 + 17) * 0.16),
			RangeShop.SURF_WOOD
		)


## Bench top, its legs, the control panel the diegetic gear bolts to, and the
## pedestal the bench weapon stands on.
func _bench_furniture(m: WorldMesher) -> void:
	var half_x: float = 3.5
	m.box(
		Vector3(RangeShop.BAY_CENTER_X, RangeShop.CONSOLE_TOP, RangeShop.CONSOLE_Z + 0.22),
		Vector3(half_x, 0.05, 0.44),
		0.0,
		RangeShop.C_RAIL,
		RangeShop.SURF_WOOD
	)
	m.box(
		Vector3(RangeShop.BAY_CENTER_X, RangeShop.CONSOLE_TOP - 0.10, RangeShop.CONSOLE_Z + 0.22),
		Vector3(half_x - 0.12, 0.06, 0.38),
		0.0,
		RangeShop.C_RAIL.darkened(0.2),
		RangeShop.SURF_WOOD
	)
	for lx: float in [RangeShop.BAY_CENTER_X - half_x + 0.3, RangeShop.BAY_CENTER_X + half_x - 0.3]:
		m.box(
			Vector3(
				lx, (RangeShop.CONSOLE_TOP + RangeShop.PAD_TOP) * 0.5, RangeShop.CONSOLE_Z + 0.22
			),
			Vector3(0.07, (RangeShop.CONSOLE_TOP - RangeShop.PAD_TOP) * 0.5 + 0.06, 0.36),
			0.0,
			RangeShop.C_POST,
			RangeShop.SURF_METAL
		)
	# Control panel: a steel face leaning back five degrees, with a lip below it.
	m.box(
		Vector3(RangeShop.BAY_CENTER_X, RangeShop.CONSOLE_PANEL_Y, RangeShop.CONSOLE_Z + 0.10),
		Vector3(half_x, 0.62, 0.09),
		0.0,
		RangeShop.C_STEEL_DARK.darkened(0.25),
		RangeShop.SURF_METAL
	)
	m.box(
		Vector3(
			RangeShop.BAY_CENTER_X, RangeShop.CONSOLE_PANEL_Y + 0.66, RangeShop.CONSOLE_Z + 0.13
		),
		Vector3(half_x, 0.06, 0.13),
		0.0,
		RangeShop.C_STEEL_DARK,
		RangeShop.SURF_METAL
	)
	m.box(
		Vector3(
			RangeShop.BAY_CENTER_X, RangeShop.CONSOLE_PANEL_Y - 0.66, RangeShop.CONSOLE_Z + 0.13
		),
		Vector3(half_x, 0.06, 0.13),
		0.0,
		RangeShop.C_STEEL_DARK,
		RangeShop.SURF_METAL
	)

	# Weapon pedestal, in front of the console where you can walk round it.
	var px: float = RangeShop.BAY_CENTER_X
	var pz: float = 12.9
	m.cylinder(
		Vector3(px, RangeShop.PAD_TOP + 0.05, pz),
		0.42,
		0.34,
		0.09,
		16,
		RangeShop.C_POST,
		RangeShop.SURF_METAL
	)
	m.cylinder(
		Vector3(px, 0.70, pz), 0.11, 0.09, 0.45, 12, RangeShop.C_STEEL_DARK, RangeShop.SURF_METAL
	)
	m.box(
		Vector3(px, 1.16, pz), Vector3(0.34, 0.04, 0.16), 0.0, RangeShop.C_RAIL, RangeShop.SURF_WOOD
	)
	for cradle_x: float in [-0.24, 0.24]:
		m.box(
			Vector3(px + cradle_x, 1.24, pz),
			Vector3(0.05, 0.06, 0.14),
			0.0,
			RangeShop.C_STEEL,
			RangeShop.SURF_METAL
		)


## What the place looks like when people use it: a tool rack, ammo crates, a
## cleaning rod stand, a radio, a bucket of brass and a stack of steel offcuts.
func _bay_clutter(m: WorldMesher) -> void:
	var wall_x: float = RangeShop.BAY_CENTER_X - RangeShop.BAY_HALF_X + 0.34
	# Tool rack: two brackets, a rail, and five things hung off it.
	for bz: float in [11.2, 14.4]:
		m.box(
			Vector3(wall_x, 2.05, bz),
			Vector3(0.16, 0.05, 0.05),
			0.0,
			RangeShop.C_POST,
			RangeShop.SURF_METAL
		)
	m.box(
		Vector3(wall_x + 0.14, 2.02, 12.8),
		Vector3(0.03, 0.03, 1.65),
		0.0,
		RangeShop.C_STEEL,
		RangeShop.SURF_METAL
	)
	var tools: Array = [
		[11.4, 0.42, 0.035, RangeShop.C_STEEL_DARK],
		[11.9, 0.30, 0.028, RangeShop.C_TIMBER],
		[12.5, 0.55, 0.022, RangeShop.C_STEEL],
		[13.2, 0.34, 0.040, RangeShop.C_STEEL_DARK],
		[13.9, 0.48, 0.026, RangeShop.C_TIMBER],
		[14.3, 0.24, 0.033, RangeShop.C_STEEL],
	]
	for tool: Array in tools:
		var tz: float = float(tool[0])
		var drop: float = float(tool[1])
		var rad: float = float(tool[2])
		m.box(
			Vector3(wall_x + 0.14, 2.02 - drop * 0.5, tz),
			Vector3(rad, drop * 0.5, rad),
			0.0,
			tool[3] as Color,
			RangeShop.SURF_METAL
		)

	# Cleaning rods in a bucket by the pedestal.
	m.cylinder(
		Vector3(RangeShop.BAY_CENTER_X + 1.45, RangeShop.PAD_TOP + 0.17, 12.6),
		0.15,
		0.17,
		0.17,
		12,
		RangeShop.C_STEEL_DARK,
		RangeShop.SURF_METAL
	)
	for i: int in 5:
		var lean: float = -0.16 + float(i) * 0.08
		var base := Vector3(RangeShop.BAY_CENTER_X + 1.45, RangeShop.PAD_TOP + 0.06, 12.6)
		var tip: Vector3 = base + Vector3(lean * 0.55, 0.95, lean * 0.3)
		m.strut(
			base,
			tip,
			0.012,
			RangeShop.C_STEEL if i % 2 == 0 else RangeShop.C_BRASS,
			RangeShop.SURF_METAL
		)

	# Ammo crates, stacked and overlapping their lids.
	var crates: Array = [
		[RangeShop.BAY_CENTER_X + 4.4, RangeShop.PAD_TOP, 15.2, 0.34, 0.20, 0.22, 0.0],
		[RangeShop.BAY_CENTER_X + 4.4, RangeShop.PAD_TOP + 0.40, 15.2, 0.32, 0.19, 0.21, 0.22],
		[RangeShop.BAY_CENTER_X + 4.9, RangeShop.PAD_TOP, 14.2, 0.30, 0.18, 0.20, -0.4],
		[RangeShop.BAY_CENTER_X - 5.6, RangeShop.PAD_TOP, 15.6, 0.36, 0.22, 0.24, 0.15],
	]
	for c: Array in crates:
		var cx: float = float(c[0])
		var cy: float = float(c[1])
		var cz2: float = float(c[2])
		var hx: float = float(c[3])
		var hy: float = float(c[4])
		var hz2: float = float(c[5])
		var ry: float = float(c[6])
		m.box(
			Vector3(cx, cy + hy, cz2),
			Vector3(hx, hy, hz2),
			ry,
			RangeShop.C_TIMBER.darkened(0.15),
			RangeShop.SURF_WOOD
		)
		m.box(
			Vector3(cx, cy + hy * 2.0 - 0.015, cz2),
			Vector3(hx + 0.02, 0.035, hz2 + 0.02),
			ry,
			RangeShop.C_TIMBER,
			RangeShop.SURF_WOOD
		)
		m.box(
			Vector3(cx, cy + hy, cz2),
			Vector3(hx + 0.012, hy * 0.35, hz2 + 0.012),
			ry,
			RangeShop.C_POST,
			RangeShop.SURF_METAL
		)

	# A drum of scrap steel offcuts against the back wall.
	m.cylinder(
		Vector3(RangeShop.BAY_CENTER_X + 5.9, RangeShop.PAD_TOP + 0.46, 16.6),
		0.30,
		0.30,
		0.46,
		14,
		RangeShop.C_DRUM_B,
		RangeShop.SURF_METAL
	)
	m.cylinder(
		Vector3(RangeShop.BAY_CENTER_X + 5.9, RangeShop.PAD_TOP + 0.90, 16.6),
		0.31,
		0.31,
		0.04,
		14,
		RangeShop.C_DRUM_RIB,
		RangeShop.SURF_METAL
	)
	for i: int in 6:
		var ang: float = float(i) * 1.05
		var top := Vector3(
			RangeShop.BAY_CENTER_X + 5.9 + cos(ang) * 0.14,
			RangeShop.PAD_TOP + 1.15 + float(i % 3) * 0.09,
			16.6 + sin(ang) * 0.14
		)
		m.strut(
			Vector3(RangeShop.BAY_CENTER_X + 5.9, RangeShop.PAD_TOP + 0.7, 16.6),
			top,
			0.02,
			RangeShop.C_STEEL_DARK,
			RangeShop.SURF_METAL
		)

	# The radio: a boxy set on the bench end with a dial and an aerial.
	var rx: float = RangeShop.BAY_CENTER_X + 2.85
	m.box(
		Vector3(rx, RangeShop.CONSOLE_TOP + 0.14, RangeShop.CONSOLE_Z + 0.22),
		Vector3(0.20, 0.13, 0.11),
		-0.25,
		RangeShop.C_LAMP,
		RangeShop.SURF_POLY
	)
	m.box(
		Vector3(rx - 0.035, RangeShop.CONSOLE_TOP + 0.16, RangeShop.CONSOLE_Z + 0.11),
		Vector3(0.12, 0.07, 0.02),
		-0.25,
		RangeShop.C_BRASS,
		RangeShop.SURF_METAL
	)
	m.strut(
		Vector3(rx + 0.16, RangeShop.CONSOLE_TOP + 0.26, RangeShop.CONSOLE_Z + 0.28),
		Vector3(rx + 0.34, RangeShop.CONSOLE_TOP + 0.86, RangeShop.CONSOLE_Z + 0.36),
		0.008,
		RangeShop.C_STEEL,
		RangeShop.SURF_METAL
	)


## Tarps: solid slabs with a slight sag and a lean, hung off the roof edge and
## the side wall. They sway in `range_ambience.gd`, so each is its own node.
func _add_tarps(bay: Node3D) -> void:
	var specs: Array = [
		[
			"TarpNear",
			Vector3(RangeShop.BAY_CENTER_X - 4.3, 2.35, RangeShop.BAY_Z_NEAR + 0.15),
			1.5,
			1.05,
			0.06,
			RangeShop.C_TARP,
			0.0
		],
		[
			"TarpSide",
			Vector3(RangeShop.BAY_CENTER_X + 6.9, 2.25, 12.2),
			0.05,
			1.10,
			1.4,
			RangeShop.C_TARP_RED,
			0.0
		],
		[
			"TarpBack",
			Vector3(RangeShop.BAY_CENTER_X + 3.1, 2.45, RangeShop.BAY_Z_NEAR + 0.10),
			1.1,
			0.90,
			0.05,
			RangeShop.C_TARP,
			0.22
		],
	]
	var tarps := Node3D.new()
	tarps.name = "Tarps"
	tarps.add_to_group(&"range_tarps")
	bay.add_child(tarps)
	for spec: Array in specs:
		var m := WorldMesher.new()
		var hx: float = float(spec[2])
		var hy: float = float(spec[3])
		var hz: float = float(spec[4])
		var col: Color = spec[5] as Color
		# Three panels of falling width make a hanging sheet that is not a plank.
		for i: int in 3:
			var t: float = float(i) / 2.0
			var w: float = lerpf(1.0, 0.86, t)
			m.box(
				Vector3(0.0, -hy * (0.34 + t * 0.66), 0.0),
				Vector3(maxf(hx * w, 0.03), hy * 0.36, maxf(hz * w, 0.03)),
				float(spec[6]) + t * 0.06,
				col.lerp(Color.BLACK, t * 0.18),
				RangeShop.SURF_CLOTH
			)
		var node := Node3D.new()
		node.name = String(spec[0])
		node.position = spec[1] as Vector3
		tarps.add_child(node)
		shop.add_mesh(node, "Cloth", shop.commit(m, String(spec[0]).to_snake_case()), true)
