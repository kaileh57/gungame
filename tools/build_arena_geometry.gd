extends RefCounted
## Every solid the arena is made of, and the dimensions they are made to.
##
## Deliberately unregistered — no `class_name`. It is a bake-time file used by one
## builder, and putting it in the global class table would advertise it to shipping
## code that must never call it.
##
## Split out of `res://tools/build_arena.gd` because the two halves are different
## jobs: this one decides what the compound looks like, that one decides what the
## demo is wired to. It runs at bake time and only at bake time — the shipped
## scene loads a single fused `ArrayMesh` and never sees this file.
##
## Every routine emits closed, outward-wound solids into a `WorldMesher`, which
## does the winding swap and the flat-shading duplication on the way in. Joints
## lap rather than butt, ends are capped, and no two coplanar faces are left
## fighting each other for the depth buffer.

# --- compound dimensions, metres -------------------------------------------

## Interior half-extents. 76 by 60 is the smallest floor on which a marksman at
## one end is inside its own effective range of the other and still has to walk.
const HALF_X: float = 38.0
const HALF_Z: float = 30.0
const WALL_HALF_T: float = 0.45
const WALL_H: float = 5.4
## Clear width and height of a vehicle gate, and of a personnel door.
const GATE_HALF_W: float = 2.2
const GATE_H: float = 3.6
const DOOR_HALF_W: float = 1.8
const DOOR_H: float = 3.2
## Where the two north gates sit, and where the two side doors do.
const GATE_X: float = 14.0
const EAST_DOOR_Z: float = -6.0
const WEST_DOOR_Z: float = 2.0

## The control dais at the south end: top face height, and its extent.
const DAIS_Y: float = 1.2
const DAIS_HALF_X: float = 11.0
const DAIS_Z0: float = 16.4
const DAIS_Z1: float = 28.4
## The ramp onto it.
const RAMP_Z0: float = 11.0
const RAMP_HALF_X: float = 5.0

## East gantry deck height and extent. High enough to shoot over a container,
## low enough that falling off it is a stumble rather than a death.
const GANTRY_Y: float = 3.4
const GANTRY_X: float = 33.4
const GANTRY_HALF_W: float = 2.4
const GANTRY_Z0: float = -20.0
const GANTRY_Z1: float = 13.0

## North-west firing platform.
const PLATFORM_Y: float = 2.8
const PLATFORM_CENTER: Vector3 = Vector3(-27.0, 0.0, -19.0)
const PLATFORM_HALF: Vector2 = Vector2(6.0, 5.0)

## Diegetic control geometry: the face of the console's back panel, the height the
## dials sit at, and the top of the desk the levers stand on. The builder places
## the shipped control scenes against these, so the knobs sink into the panel
## rather than floating a centimetre off it.
const PANEL_Z: float = 26.20
const PANEL_Y: float = 2.55
const DESK_TOP_Y: float = 2.05
const DESK_Z: float = 26.0

## Where the player starts, and which way they are looking.
const PLAYER_SPAWN: Vector3 = Vector3(0.0, DAIS_Y + 0.05, 22.0)


static func build() -> WorldMesher:
	var m := WorldMesher.new()
	var rng := XorShift32.new(20260728)
	_apron(m)
	_floor(m)
	_walls(m)
	_dais(m)
	_console(m)
	_gantry(m)
	_platform(m)
	_cover_field(m, rng)
	return m


## The dirt the compound stands on. Wider than the walls so the view from the
## gantry is ground rather than the inside of the sky.
static func _apron(m: WorldMesher) -> void:
	m.box(
		Vector3(0.0, -1.4, 0.0),
		Vector3(HALF_X + 28.0, 0.7, HALF_Z + 26.0),
		0.0,
		Color("6f6047"),
		WorldSurface.Kind.SAND
	)


static func _floor(m: WorldMesher) -> void:
	m.box(
		Vector3(0.0, -0.6, 0.0),
		Vector3(HALF_X + 2.5, 0.6, HALF_Z + 2.5),
		0.0,
		WorldPalette.SLAB,
		WorldSurface.Kind.CONCRETE
	)


## Four runs with holes in them. Every run is built as explicit segments and
## lintels rather than as a box with a hole subtracted, because a subtracted hole
## needs an interior surface and this project does not ship one.
static func _walls(m: WorldMesher) -> void:
	var col: Color = WorldPalette.SLAB.darkened(0.12)
	var north_z: float = -HALF_Z - WALL_HALF_T
	var south_z: float = HALF_Z + WALL_HALF_T
	var east_x: float = HALF_X + WALL_HALF_T
	var west_x: float = -HALF_X - WALL_HALF_T
	var end_x: float = HALF_X + WALL_HALF_T * 2.0
	var end_z: float = HALF_Z + WALL_HALF_T * 2.0

	# North: two vehicle gates.
	_wall_x(m, -end_x, -GATE_X - GATE_HALF_W, north_z, 0.0, WALL_H, col)
	_wall_x(m, -GATE_X + GATE_HALF_W, GATE_X - GATE_HALF_W, north_z, 0.0, WALL_H, col)
	_wall_x(m, GATE_X + GATE_HALF_W, end_x, north_z, 0.0, WALL_H, col)
	_wall_x(m, -GATE_X - GATE_HALF_W, -GATE_X + GATE_HALF_W, north_z, GATE_H, WALL_H, col)
	_wall_x(m, GATE_X - GATE_HALF_W, GATE_X + GATE_HALF_W, north_z, GATE_H, WALL_H, col)

	# South: solid. The dais backs onto it and nothing gets behind you.
	_wall_x(m, -end_x, end_x, south_z, 0.0, WALL_H, col)

	# East and west: one personnel door each, on opposite sides and off-centre, so
	# a flanker coming through either one arrives somewhere the player is not.
	_wall_z(m, -end_z, EAST_DOOR_Z - DOOR_HALF_W, east_x, 0.0, WALL_H, col)
	_wall_z(m, EAST_DOOR_Z + DOOR_HALF_W, end_z, east_x, 0.0, WALL_H, col)
	_wall_z(m, EAST_DOOR_Z - DOOR_HALF_W, EAST_DOOR_Z + DOOR_HALF_W, east_x, DOOR_H, WALL_H, col)
	_wall_z(m, -end_z, WEST_DOOR_Z - DOOR_HALF_W, west_x, 0.0, WALL_H, col)
	_wall_z(m, WEST_DOOR_Z + DOOR_HALF_W, end_z, west_x, 0.0, WALL_H, col)
	_wall_z(m, WEST_DOOR_Z - DOOR_HALF_W, WEST_DOOR_Z + DOOR_HALF_W, west_x, DOOR_H, WALL_H, col)

	# Corner posts, each lapping a metre into both walls it joins. A butted corner
	# shows a seam the first time the sun is not square to it.
	for sx: float in [-1.0, 1.0]:
		for sz: float in [-1.0, 1.0]:
			m.box(
				Vector3(sx * end_x, WALL_H * 0.5 + 0.3, sz * end_z),
				Vector3(1.15, WALL_H * 0.5 + 0.3, 1.15),
				0.0,
				col.darkened(0.08),
				WorldSurface.Kind.CONCRETE
			)


static func _wall_x(
	m: WorldMesher, x0: float, x1: float, z: float, y0: float, y1: float, c: Color
) -> void:
	if x1 - x0 < 0.02 or y1 - y0 < 0.02:
		return
	m.box(
		Vector3((x0 + x1) * 0.5, (y0 + y1) * 0.5, z),
		Vector3((x1 - x0) * 0.5, (y1 - y0) * 0.5, WALL_HALF_T),
		0.0,
		c,
		WorldSurface.Kind.CONCRETE
	)


static func _wall_z(
	m: WorldMesher, z0: float, z1: float, x: float, y0: float, y1: float, c: Color
) -> void:
	if z1 - z0 < 0.02 or y1 - y0 < 0.02:
		return
	m.box(
		Vector3(x, (y0 + y1) * 0.5, (z0 + z1) * 0.5),
		Vector3(WALL_HALF_T, (y1 - y0) * 0.5, (z1 - z0) * 0.5),
		0.0,
		c,
		WorldSurface.Kind.CONCRETE
	)


## The control dais and the ramp onto it. The ramp is an oriented box built from a
## real sloped frame, so its collider is the slope rather than a stair.
static func _dais(m: WorldMesher) -> void:
	m.box(
		Vector3(0.0, DAIS_Y * 0.5, (DAIS_Z0 + DAIS_Z1) * 0.5),
		Vector3(DAIS_HALF_X, DAIS_Y * 0.5, (DAIS_Z1 - DAIS_Z0) * 0.5),
		0.0,
		WorldPalette.DECK,
		WorldSurface.Kind.CONCRETE
	)
	_ramp(
		m,
		Vector3(0.0, 0.0, RAMP_Z0),
		Vector3(0.0, DAIS_Y, DAIS_Z0 + 0.4),
		RAMP_HALF_X,
		0.35,
		WorldPalette.DECK.darkened(0.06),
		WorldSurface.Kind.CONCRETE
	)
	# A kerb down each side of the ramp. Stops a body walking off the edge of it
	# and gives the eye something to read the slope against.
	for sx: float in [-1.0, 1.0]:
		_ramp(
			m,
			Vector3(sx * (RAMP_HALF_X + 0.18), 0.10, RAMP_Z0),
			Vector3(sx * (RAMP_HALF_X + 0.18), DAIS_Y + 0.24, DAIS_Z0 + 0.4),
			0.18,
			0.22,
			WorldPalette.TRIM,
			WorldSurface.Kind.CONCRETE
		)


## A sloped slab from `a` to `b`, `half_w` wide across the slope and `thickness`
## thick beneath its top face. The frame is built right-handed from the slope
## direction, so the box is never inside out however steep it gets.
static func _ramp(
	m: WorldMesher,
	a: Vector3,
	b: Vector3,
	half_w: float,
	thickness: float,
	col: Color,
	surface: int
) -> void:
	var d: Vector3 = b - a
	var span: float = d.length()
	if span < 0.05:
		return
	var along: Vector3 = d / span
	var side := Vector3(along.z, 0.0, -along.x)
	if side.length_squared() < 1e-6:
		side = Vector3.RIGHT
	side = side.normalized()
	# side x up_local = along, so the frame is right-handed and `oriented_box`
	# emits it outward.
	var up_local: Vector3 = along.cross(side).normalized()
	var half_t: float = maxf(thickness, 0.02) * 0.5
	var center: Vector3 = (a + b) * 0.5 - up_local * half_t
	m.oriented_box(center, side * half_w, up_local * half_t, along * (span * 0.5), col, surface)


## The console. A plinth, a desk top, a back panel for the dials and a hood over
## it, each solid lapping into the one below rather than sitting on it.
static func _console(m: WorldMesher) -> void:
	var steel: Color = Color("5b5751")
	m.box(
		Vector3(0.0, (DAIS_Y + DESK_TOP_Y) * 0.5 - 0.05, 26.2),
		Vector3(5.0, (DESK_TOP_Y - DAIS_Y) * 0.5 + 0.05, 0.45),
		0.0,
		steel.darkened(0.15),
		WorldSurface.Kind.METAL
	)
	m.box(
		Vector3(0.0, DESK_TOP_Y - 0.06, 26.05),
		Vector3(5.1, 0.06, 0.62),
		0.0,
		steel,
		WorldSurface.Kind.METAL
	)
	m.box(
		Vector3(0.0, PANEL_Y, PANEL_Z + 0.10),
		Vector3(5.1, 0.58, 0.10),
		0.0,
		steel.darkened(0.08),
		WorldSurface.Kind.METAL
	)
	m.box(
		Vector3(0.0, PANEL_Y + 0.60, PANEL_Z + 0.30),
		Vector3(5.1, 0.07, 0.32),
		0.0,
		steel.darkened(0.2),
		WorldSurface.Kind.METAL
	)
	# Stencil plate over the hood. The sign itself is a Label3D on the assembled
	# scene; this is the steel it is painted on.
	m.box(
		Vector3(0.0, PANEL_Y + 0.95, PANEL_Z + 0.26),
		Vector3(3.2, 0.30, 0.06),
		0.0,
		Color("7a6a4c"),
		WorldSurface.Kind.METAL
	)


## The east gantry: a deck, its posts, a handrail, and the ramp up to it. The
## elevation is the point — a body on it can shoot over the container line, which
## is what makes the ground floor worth using cover on.
static func _gantry(m: WorldMesher) -> void:
	var deck: Color = WorldPalette.RAIL
	m.box(
		Vector3(GANTRY_X, GANTRY_Y - 0.14, (GANTRY_Z0 + GANTRY_Z1) * 0.5),
		Vector3(GANTRY_HALF_W, 0.16, (GANTRY_Z1 - GANTRY_Z0) * 0.5),
		0.0,
		deck,
		WorldSurface.Kind.METAL
	)
	var z: float = GANTRY_Z0 + 1.0
	while z <= GANTRY_Z1 - 1.0:
		for sx: float in [-1.0, 1.0]:
			m.box(
				Vector3(GANTRY_X + sx * (GANTRY_HALF_W - 0.22), GANTRY_Y * 0.5, z),
				Vector3(0.14, GANTRY_Y * 0.5 + 0.05, 0.14),
				0.0,
				deck.darkened(0.12),
				WorldSurface.Kind.METAL
			)
			m.box(
				Vector3(GANTRY_X + sx * GANTRY_HALF_W, GANTRY_Y + 0.55, z),
				Vector3(0.06, 0.55, 0.06),
				0.0,
				deck.darkened(0.05),
				WorldSurface.Kind.METAL
			)
		z += 3.2
	for sx: float in [-1.0, 1.0]:
		m.box(
			Vector3(GANTRY_X + sx * GANTRY_HALF_W, GANTRY_Y + 1.04, (GANTRY_Z0 + GANTRY_Z1) * 0.5),
			Vector3(0.07, 0.07, (GANTRY_Z1 - GANTRY_Z0) * 0.5),
			0.0,
			deck,
			WorldSurface.Kind.METAL
		)
		m.box(
			Vector3(GANTRY_X + sx * GANTRY_HALF_W, GANTRY_Y + 0.56, (GANTRY_Z0 + GANTRY_Z1) * 0.5),
			Vector3(0.05, 0.05, (GANTRY_Z1 - GANTRY_Z0) * 0.5),
			0.0,
			deck,
			WorldSurface.Kind.METAL
		)
	# The stair. One ramp, 27 degrees, landing on the deck rather than beside it.
	_ramp(
		m,
		Vector3(GANTRY_X, 0.0, GANTRY_Z1 + 7.0),
		Vector3(GANTRY_X, GANTRY_Y, GANTRY_Z1 - 0.6),
		GANTRY_HALF_W - 0.3,
		0.30,
		deck.darkened(0.1),
		WorldSurface.Kind.METAL
	)


## The north-west platform. Waist-high cover on top of it, so holding it is a
## position rather than a target.
static func _platform(m: WorldMesher) -> void:
	var c: Vector3 = PLATFORM_CENTER
	m.box(
		Vector3(c.x, PLATFORM_Y * 0.5, c.z),
		Vector3(PLATFORM_HALF.x, PLATFORM_Y * 0.5, PLATFORM_HALF.y),
		0.0,
		WorldPalette.SLAB.darkened(0.05),
		WorldSurface.Kind.CONCRETE
	)
	m.box(
		Vector3(c.x, PLATFORM_Y + 0.45, c.z - PLATFORM_HALF.y + 0.25),
		Vector3(PLATFORM_HALF.x, 0.45, 0.25),
		0.0,
		WorldPalette.TRIM,
		WorldSurface.Kind.CONCRETE
	)
	_ramp(
		m,
		Vector3(c.x + PLATFORM_HALF.x + 6.0, 0.0, c.z + 1.5),
		Vector3(c.x + PLATFORM_HALF.x - 0.5, PLATFORM_Y, c.z + 1.5),
		2.0,
		0.32,
		WorldPalette.SLAB.darkened(0.1),
		WorldSurface.Kind.CONCRETE
	)


## Containers, barriers, drums and a sandbag berm. Placed by hand rather than
## scattered: the whole demo is about whether the AI reads a firing position, and
## a random field of boxes does not have firing positions in it.
static func _cover_field(m: WorldMesher, rng: XorShift32) -> void:
	var containers: Array = [
		[Vector3(-20.0, 0.0, -8.0), 0.0],
		[Vector3(-8.5, 0.0, -18.0), 0.34],
		[Vector3(12.0, 0.0, -14.0), PI * 0.5],
		[Vector3(22.0, 0.0, 2.0), 0.0],
		[Vector3(-24.0, 0.0, 6.0), PI * 0.5],
		[Vector3(4.0, 0.0, 3.0), -0.26],
		[Vector3(3.4, 2.62, 3.0), -0.18],
		[Vector3(18.0, 0.0, -24.0), 0.12],
	]
	for entry: Array in containers:
		_container(m, entry[0], entry[1], rng)

	var barriers: Array = [
		[Vector3(-12.0, 0.0, 8.0), 0.0],
		[Vector3(-8.4, 0.0, 8.4), 0.1],
		[Vector3(-4.8, 0.0, 8.2), -0.06],
		[Vector3(9.0, 0.0, 9.0), 0.22],
		[Vector3(12.5, 0.0, 8.4), 0.05],
		[Vector3(-16.0, 0.0, -2.0), PI * 0.5],
		[Vector3(-16.2, 0.0, 1.4), PI * 0.5],
		[Vector3(16.0, 0.0, -6.0), PI * 0.5],
		[Vector3(16.2, 0.0, -2.6), PI * 0.5],
		[Vector3(-2.0, 0.0, -10.0), 0.4],
		[Vector3(1.5, 0.0, -11.2), 0.28],
		[Vector3(26.0, 0.0, -16.0), -0.5],
		[Vector3(-30.0, 0.0, -4.0), 0.18],
	]
	for entry: Array in barriers:
		_barrier(m, entry[0], entry[1], rng)

	for spot: Vector3 in [
		Vector3(-6.0, 0.0, -3.0),
		Vector3(8.0, 0.0, -20.0),
		Vector3(28.0, 0.0, 10.0),
		Vector3(-30.0, 0.0, 14.0),
	]:
		_drums(m, spot, rng)

	_berm(m, Vector3(-14.0, 0.0, -24.0), 9.0, rng)
	_berm(m, Vector3(24.0, 0.0, 14.0), 6.0, rng)

	# Two pillars in the open ground. They break the marksman's lane down the
	# middle without giving anything to hide behind, which is what stops the lane
	# being either a killing field or a corridor.
	for x: float in [-3.0, 6.0]:
		m.cylinder(
			Vector3(x, 2.6, -6.0),
			0.42,
			0.42,
			2.6,
			14,
			WorldPalette.SLAB.darkened(0.18),
			WorldSurface.Kind.CONCRETE
		)


## A shipping container: a body, a lapped roof and two end ribs.
static func _container(m: WorldMesher, at: Vector3, ry: float, rng: XorShift32) -> void:
	var col: Color = WorldPalette.pick(WorldPalette.CONTAINER, rng)
	var half := Vector3(3.03, 1.30, 1.22)
	m.box(at + Vector3(0.0, half.y, 0.0), half, ry, col, WorldSurface.Kind.TIN)
	m.box(
		at + Vector3(0.0, half.y * 2.0 - 0.05, 0.0),
		Vector3(half.x + 0.06, 0.09, half.z + 0.06),
		ry,
		col.darkened(0.18),
		WorldSurface.Kind.TIN
	)
	var co: float = cos(ry)
	var si: float = sin(ry)
	for sx: float in [-1.0, 1.0]:
		var offset := Vector3(co, 0.0, -si) * (sx * (half.x - 0.06))
		m.box(
			at + offset + Vector3(0.0, half.y, 0.0),
			Vector3(0.10, half.y - 0.04, half.z + 0.05),
			ry,
			col.darkened(0.28),
			WorldSurface.Kind.TIN
		)


## A jersey barrier. Crouch cover you can shoot over — the single most useful
## thing in the compound, and the reason the cover bake finds firing positions.
static func _barrier(m: WorldMesher, at: Vector3, ry: float, rng: XorShift32) -> void:
	var col: Color = WorldPalette.vary(WorldPalette.SLAB, rng, 0.07)
	m.box(
		at + Vector3(0.0, 0.20, 0.0), Vector3(1.62, 0.20, 0.36), ry, col, WorldSurface.Kind.CONCRETE
	)
	m.box(
		at + Vector3(0.0, 0.62, 0.0), Vector3(1.50, 0.34, 0.19), ry, col, WorldSurface.Kind.CONCRETE
	)
	m.box(
		at + Vector3(0.0, 0.92, 0.0),
		Vector3(1.46, 0.10, 0.15),
		ry,
		col.darkened(0.1),
		WorldSurface.Kind.CONCRETE
	)


static func _drums(m: WorldMesher, at: Vector3, rng: XorShift32) -> void:
	var family := PackedColorArray(
		[WorldPalette.DRUM_OLIVE, WorldPalette.DRUM_GREEN, WorldPalette.DRUM_RUST]
	)
	for i: int in 3:
		var a: float = TAU * float(i) / 3.0 + rng.next() * 0.6
		var offset := Vector3(cos(a) * 0.55, 0.0, sin(a) * 0.55)
		m.cylinder(
			at + offset + Vector3(0.0, 0.44, 0.0),
			0.30,
			0.30,
			0.44,
			14,
			WorldPalette.pick(family, rng),
			WorldSurface.Kind.METAL
		)


## A sandbag berm: two courses, the upper one set back, each bag its own colour.
static func _berm(m: WorldMesher, at: Vector3, length: float, rng: XorShift32) -> void:
	var bags: int = maxi(int(length / 0.62), 2)
	for i: int in bags:
		var t: float = float(i) / float(bags - 1) - 0.5
		var x: float = at.x + t * length
		var wobble: float = (rng.next() - 0.5) * 0.14
		m.box(
			Vector3(x, 0.19, at.z + wobble),
			Vector3(0.33, 0.19, 0.26),
			rng.next_range(-0.2, 0.2),
			WorldPalette.vary(WorldPalette.SANDBAG, rng, 0.10),
			WorldSurface.Kind.CLOTH
		)
		if i >= bags - 1:
			continue
		m.box(
			Vector3(x + 0.31, 0.53, at.z + wobble * 0.5 - 0.10),
			Vector3(0.33, 0.19, 0.26),
			rng.next_range(-0.2, 0.2),
			WorldPalette.vary(WorldPalette.SANDBAG, rng, 0.10),
			WorldSurface.Kind.CLOTH
		)


## A gate leaf, built on its own so it can move. Local origin is the shut
## position at the bottom of the leaf.
static func gate_leaf(half_w: float, height: float, material: Material) -> ArrayMesh:
	var m := WorldMesher.new()
	var col := Color("4e4a45")
	m.box(
		Vector3(0.0, height * 0.5, 0.0),
		Vector3(half_w, height * 0.5, 0.12),
		0.0,
		col,
		WorldSurface.Kind.METAL
	)
	var bars: int = maxi(int(half_w * 2.0 / 0.55), 3)
	for i: int in bars:
		var x: float = -half_w + (2.0 * half_w) * (float(i) + 0.5) / float(bars)
		m.box(
			Vector3(x, height * 0.5, 0.0),
			Vector3(0.055, height * 0.5 - 0.02, 0.18),
			0.0,
			col.darkened(0.2),
			WorldSurface.Kind.METAL
		)
	for y: float in [height * 0.22, height * 0.72]:
		m.box(
			Vector3(0.0, y, 0.0),
			Vector3(half_w - 0.01, 0.09, 0.20),
			0.0,
			col.lightened(0.05),
			WorldSurface.Kind.METAL
		)
	return m.build_mesh(material)
