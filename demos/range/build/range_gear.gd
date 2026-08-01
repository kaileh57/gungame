extends RefCounted
## The small hand props a working range is littered with: ammo cans, buckets,
## crates, bottles, jerry cans, matting, pallets and a spotting scope.
##
## BAKE-TIME ONLY, and all of it static — nothing here holds state, it only
## writes solids into a caller's `WorldMesher`. `range_yard_kit.gd` is the caller.
##
## NO `class_name`, for the same reason the yard kit has none: a global class
## added to the project is invisible to a `--script` main loop until the editor
## rescans and rewrites `.godot/global_script_class_cache.cfg`. Callers preload
## this file by path.
##
## Every routine leaves a closed outward shell, because `RangeShop.commit` fails
## the bake for anything that does not.


## A steel ammo can with a lid lip and a folding handle. `at` is the centre of
## the body, not its base — these get stacked on bench tops as often as floors.
static func ammo_can(m: WorldMesher, at: Vector3, yaw: float) -> void:
	m.box(at, Vector3(0.155, 0.105, 0.085), yaw, RangeShop.C_DRUM_B, RangeShop.SURF_METAL)
	m.box(
		at + Vector3(0.0, 0.105, 0.0),
		Vector3(0.162, 0.018, 0.092),
		yaw,
		RangeShop.C_DRUM_B.darkened(0.2),
		RangeShop.SURF_METAL
	)
	m.strut(
		at + Vector3(-0.06, 0.13, 0.0),
		at + Vector3(0.06, 0.13, 0.0),
		0.012,
		RangeShop.C_STEEL_DARK,
		RangeShop.SURF_METAL
	)


## A galvanised bucket standing on `base`, filled to the brim with picked-up brass.
static func bucket(m: WorldMesher, base: Vector3, radius: float, height: float) -> void:
	m.cylinder(
		base + Vector3(0.0, height * 0.5, 0.0),
		radius * 0.82,
		radius,
		height * 0.5,
		12,
		RangeShop.C_STEEL_DARK,
		RangeShop.SURF_METAL
	)
	m.cylinder(
		base + Vector3(0.0, height - 0.02, 0.0),
		radius + 0.012,
		radius + 0.012,
		0.018,
		12,
		RangeShop.C_STEEL,
		RangeShop.SURF_METAL
	)
	m.cylinder(
		base + Vector3(0.0, height - 0.05, 0.0),
		radius * 0.92,
		radius * 0.86,
		0.035,
		12,
		RangeShop.C_BRASS,
		RangeShop.SURF_METAL
	)


## A banded timber crate, `at` being its centre.
static func crate(m: WorldMesher, at: Vector3, half: Vector3, yaw: float) -> void:
	m.box(at, half, yaw, RangeShop.C_TIMBER.darkened(0.16), RangeShop.SURF_WOOD)
	m.box(
		at + Vector3(0.0, half.y - 0.012, 0.0),
		Vector3(half.x + 0.016, 0.026, half.z + 0.016),
		yaw,
		RangeShop.C_TIMBER,
		RangeShop.SURF_WOOD
	)
	m.box(
		at,
		Vector3(half.x + 0.010, half.y * 0.34, half.z + 0.010),
		yaw,
		RangeShop.C_POST,
		RangeShop.SURF_METAL
	)


## A bottle standing on `base`. The same glass the bottle row down-range is cut
## from, at the size somebody actually drinks out of.
static func bottle(m: WorldMesher, base: Vector3) -> void:
	m.cylinder(
		base + Vector3(0.0, 0.075, 0.0),
		0.038,
		0.030,
		0.075,
		9,
		RangeShop.C_GLASS,
		RangeShop.SURF_POLY
	)
	m.cylinder(
		base + Vector3(0.0, 0.175, 0.0),
		0.021,
		0.016,
		0.030,
		8,
		RangeShop.C_GLASS.lightened(0.12),
		RangeShop.SURF_POLY
	)


## A jerry can standing on `base`, handle bar across the top and a cap beside it.
static func jerry(m: WorldMesher, base: Vector3, yaw: float) -> void:
	m.box(
		base + Vector3(0.0, 0.22, 0.0),
		Vector3(0.155, 0.22, 0.07),
		yaw,
		RangeShop.C_DRUM_B.darkened(0.1),
		RangeShop.SURF_METAL
	)
	m.box(
		base + Vector3(0.0, 0.44, 0.0),
		Vector3(0.13, 0.035, 0.055),
		yaw,
		RangeShop.C_STEEL_DARK,
		RangeShop.SURF_METAL
	)
	m.cylinder(
		base + Vector3(0.08 * cos(yaw), 0.49, -0.08 * sin(yaw)),
		0.026,
		0.026,
		0.022,
		8,
		RangeShop.C_DRUM_CAP,
		RangeShop.SURF_METAL
	)


## A scrap of matting, a centimetre thick, lying on `base`.
static func mat(m: WorldMesher, base: Vector3, hx: float, hz: float, yaw: float) -> void:
	m.box(
		base + Vector3(0.0, 0.004, 0.0),
		Vector3(hx, 0.012, hz),
		yaw,
		RangeShop.C_TARP.darkened(0.26),
		RangeShop.SURF_CLOTH
	)


## A timber pallet standing on `base`: three bearers across, five deck boards
## along, and the fork slots between the bearers left as real gaps.
static func pallet(m: WorldMesher, base: Vector3, yaw: float) -> void:
	for i: int in 3:
		var off: float = (float(i) - 1.0) * 0.34
		m.box(
			base + Vector3(0.0, 0.048, off).rotated(Vector3.UP, yaw),
			Vector3(0.60, 0.048, 0.075),
			yaw,
			RangeShop.C_TIMBER.darkened(0.24),
			RangeShop.SURF_WOOD
		)
	for i: int in 5:
		var off: float = (float(i) - 2.0) * 0.28
		m.box(
			base + Vector3(off, 0.118, 0.0).rotated(Vector3.UP, yaw),
			Vector3(0.052, 0.026, 0.42),
			yaw,
			RangeShop.C_TIMBER,
			RangeShop.SURF_WOOD
		)


## A spotting scope on a tripod standing on `base`, looking down-range.
static func scope(m: WorldMesher, base: Vector3) -> void:
	var head: Vector3 = base + Vector3(0.0, 1.16, 0.0)
	for i: int in 3:
		var a: float = float(i) / 3.0 * TAU + 0.4
		m.strut(
			base + Vector3(cos(a) * 0.30, 0.0, sin(a) * 0.30),
			head + Vector3(cos(a) * 0.035, -0.06, sin(a) * 0.035),
			0.014,
			RangeShop.C_POST,
			RangeShop.SURF_METAL
		)
	m.cylinder(head, 0.035, 0.035, 0.045, 10, RangeShop.C_STEEL_DARK, RangeShop.SURF_METAL)
	m.cylinder(
		head + Vector3(0.0, 0.085, -0.05),
		0.05,
		0.038,
		0.185,
		12,
		RangeShop.C_LAMP,
		RangeShop.SURF_POLY,
		Vector3(0.0, 0.16, -1.0)
	)
	m.cylinder(
		head + Vector3(0.0, 0.055, 0.16),
		0.030,
		0.030,
		0.022,
		10,
		RangeShop.C_STEEL,
		RangeShop.SURF_METAL,
		Vector3(0.0, 0.16, -1.0)
	)


## A flat coil of hose or heavy cable lying on `base`, `turns` segments round.
static func coil(m: WorldMesher, base: Vector3, radius: float, turns: int, col: Color) -> void:
	var n: int = maxi(6, turns)
	for i: int in n:
		var a0: float = float(i) / float(n) * TAU
		var a1: float = float(i + 1) / float(n) * TAU
		var r: float = radius + float(i % 2) * radius * 0.24
		m.strut(
			base + Vector3(cos(a0) * r, 0.022, sin(a0) * r),
			base + Vector3(cos(a1) * r, 0.022, sin(a1) * r),
			0.022,
			col,
			RangeShop.SURF_POLY
		)


## A header tank on a four-legged timber stand, `at` being the foot of the
## stand. Four and a bit metres to the cap, so it stands well clear of a roof.
static func water_tank(m: WorldMesher, at: Vector3) -> void:
	var leg: float = 0.80
	var deck: float = 3.15
	for sx: int in 2:
		for sz: int in 2:
			var lx: float = at.x + (leg if sx == 1 else -leg)
			var lz: float = at.z + (leg if sz == 1 else -leg)
			m.box(
				Vector3(lx, deck * 0.5 - 0.10, lz),
				Vector3(0.10, deck * 0.5 + 0.10, 0.10),
				0.0,
				RangeShop.C_TIMBER.darkened(0.12),
				RangeShop.SURF_WOOD
			)
	for level: float in [0.95, 2.25]:
		for side: int in 2:
			var s: float = leg if side == 1 else -leg
			m.box(
				Vector3(at.x, level, at.z + s),
				Vector3(leg, 0.05, 0.05),
				0.0,
				RangeShop.C_TIMBER.darkened(0.24),
				RangeShop.SURF_WOOD
			)
			m.box(
				Vector3(at.x + s, level, at.z),
				Vector3(0.05, 0.05, leg),
				0.0,
				RangeShop.C_TIMBER.darkened(0.24),
				RangeShop.SURF_WOOD
			)
	m.strut(
		Vector3(at.x - leg, 0.35, at.z - leg),
		Vector3(at.x + leg, 2.25, at.z - leg),
		0.045,
		RangeShop.C_TIMBER.darkened(0.18),
		RangeShop.SURF_WOOD
	)
	m.box(
		Vector3(at.x, deck, at.z),
		Vector3(leg + 0.22, 0.06, leg + 0.22),
		0.0,
		RangeShop.C_TIMBER.darkened(0.3),
		RangeShop.SURF_WOOD
	)
	m.cylinder(
		Vector3(at.x, deck + 0.92, at.z),
		0.98,
		0.94,
		0.86,
		16,
		RangeShop.C_DRUM_B.darkened(0.1),
		RangeShop.SURF_METAL
	)
	for band_y: float in [deck + 0.35, deck + 1.42]:
		m.cylinder(
			Vector3(at.x, band_y, at.z),
			1.00,
			1.00,
			0.05,
			16,
			RangeShop.C_DRUM_RIB,
			RangeShop.SURF_METAL
		)
	m.cylinder(
		Vector3(at.x, deck + 1.86, at.z),
		0.34,
		0.30,
		0.10,
		12,
		RangeShop.C_STEEL_DARK,
		RangeShop.SURF_METAL
	)
	# Downpipe and tap, run out of the tank's belly and down the near leg.
	m.strut(
		Vector3(at.x - 0.90, deck + 0.20, at.z),
		Vector3(at.x - leg - 0.09, 0.62, at.z),
		0.032,
		RangeShop.C_STEEL_DARK,
		RangeShop.SURF_METAL
	)
	m.strut(
		Vector3(at.x - leg - 0.09, 0.62, at.z),
		Vector3(at.x - leg - 0.30, 0.62, at.z),
		0.030,
		RangeShop.C_BRASS,
		RangeShop.SURF_METAL
	)
	for rung: int in 6:
		m.box(
			Vector3(at.x + leg + 0.10, 0.42 + float(rung) * 0.46, at.z),
			Vector3(0.02, 0.018, 0.20),
			0.0,
			RangeShop.C_POST,
			RangeShop.SURF_METAL
		)
	for rail: int in 2:
		m.box(
			Vector3(at.x + leg + 0.10, 1.60, at.z + (0.19 if rail == 1 else -0.19)),
			Vector3(0.022, 1.30, 0.022),
			0.0,
			RangeShop.C_POST,
			RangeShop.SURF_METAL
		)
