extends "res://tools/menu_geometry.gd"
## The workshop the main menu stands in: the shed, the bench, the board and the
## clutter, cut from the closed-shell kit this extends.
##
## `res://tools/build_main_menu.gd` owns the bake, the plates and the packing.
## This owns the room: the slab, the plank wall and its doorway, the roof, the
## bench, the board the plates hang on, the lamp over them and the clutter that
## makes it a place rather than a grey box. It is a plain `RefCounted` helper
## rather than a second bake step, so the menu is still one script, one report and
## one artifact — and so neither file has to carry a thousand lines.
##
## Every solid is a closed box or a closed cylinder off `menu_geometry.gd`, which
## this extends: that file owns the primitives and the shell audit, this one owns
## where they go and what colour they are.
##
## Two rules shape the numbers below and nothing may quietly break them:
##   * Nothing floats. Every plate is carried by the board, every post reaches the
##     floor, every crate sits on the slab.
##   * The board has four lanes stacked up it — title, top plate row, bottom plate
##     row, readout — and they do not share a line. The readout used to sit at
##     plate height behind the plates, so its text showed through the gaps between
##     them and read as garbage bleeding out of a label.

# --- the shed ---------------------------------------------------------------

## Ash flats under the slab. Wide enough that its edge lands on the horizon line
## rather than in the frame, which is the only cheap way to own a horizon.
const GROUND: Vector3 = Vector3(1200.0, 3.0, 1200.0)
## Poured slab the shed stands on. Its top face is y = 0.
const SLAB: Vector3 = Vector3(9.30, 0.26, 6.60)
const SLAB_Z: float = 0.70
const WALL_Z: float = -1.18
const WALL_T: float = 0.085
const WALL_TOP: float = 3.78
const WALL_HALF: float = 4.60
## The doorway. The sun comes in through it — `Palette.SUN_DIRECTION` points out
## of it and a little up — so it is both the light source and the way out.
const DOOR_X0: float = -3.56
const DOOR_X1: float = -1.94
const DOOR_TOP: float = 2.28
## Lap-siding board height. Small enough that the timber shader's object-space
## banding reads as grain instead of as stripes.
const BOARD_H: float = 0.30
const RAFTER_Y: float = 3.16
const ROOF_Y: float = 3.32
const ROOF_Z0: float = -1.22
const ROOF_Z1: float = 2.72

# --- the bench --------------------------------------------------------------

const BENCH_TOP_Y: float = 0.9225
const BENCH_W: float = 2.16
const BENCH_D: float = 0.74
const BENCH_TOP_T: float = 0.055
const BENCH_LEG: float = 0.088

# --- the board ---------------------------------------------------------------

const BOARD_W: float = 2.44
const BOARD_T: float = 0.05
const BOARD_Z: float = -0.44
const BOARD_BOTTOM: float = 0.95
const BOARD_TOP: float = 2.30
## Front face of the board. Every plate body is parked on this plane.
const BOARD_FACE: float = BOARD_Z + BOARD_T * 0.5
## Column pitch of the plate grid, and the two rows it stacks into.
const CARD_COL: float = 0.58
const CARD_ROW_LOW: float = 1.50
const CARD_ROW_HIGH: float = 1.86
## The readout lane, clear of both plate rows.
const READOUT_Y: float = 1.17
const READOUT: Vector3 = Vector3(2.16, 0.25, 0.024)
## The signage lane, above the top plate row.
const TITLE_Y: float = 2.155
const TITLE_PLATE: Vector3 = Vector3(1.34, 0.19, 0.028)

# --- the lamp ----------------------------------------------------------------

## Two fixtures on one conduit, each over its own half of the board. One lamp
## centred cannot cover a board two and a half metres wide without a cone so wide
## that it lights the whole shed evenly, which is the same as no lamp at all.
const LAMP_X: float = 0.62
const LAMP_Y: float = 2.20
const LAMP_Z: float = 0.12
## What each fixture is pointed at, on its own side.
const LAMP_TARGET: Vector3 = Vector3(0.62, 1.52, -0.42)

var _steel: Material = null
var _timber: Material = null
var _polymer: Material = null
var _canvas: Material = null
var _ember: Material = null
## Fixed stream. The plank tints and widths must come out the same on every bake
## or the shed changes its mind every time the menu is rebuilt.
var _rng: XorShift32 = XorShift32.new(0x5CA7B0)


func _init(
	steel: Material, timber: Material, polymer: Material, canvas: Material, ember: Material
) -> void:
	_steel = steel
	_timber = timber
	_polymer = polymer
	_canvas = canvas
	_ember = ember


# --- the room ---------------------------------------------------------------


## Ground, slab, plank wall with its doorway, roof, and the silhouettes you see
## through the door. Added under one `Room` node so the whole set can be found.
func build_room(root: Node3D) -> void:
	var room := Node3D.new()
	room.name = "Room"
	root.add_child(room)
	_build_ground(room)
	_build_wall(room)
	_build_roof(room)
	_build_outside(room)


func _build_ground(room: Node3D) -> void:
	var ground := mesh_node(
		"Ground",
		box(GROUND, "ground"),
		_canvas,
		Vector3(0.0, -0.06 - GROUND.y * 0.5, 0.0),
		0.11,
		Color(1.46, 1.42, 1.33)
	)
	# A flat plane gains nothing by casting into its own cascade and loses shadow
	# resolution the shed needs.
	ground.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	room.add_child(ground)
	room.add_child(
		mesh_node(
			"Slab",
			box(SLAB, "slab"),
			_polymer,
			Vector3(0.0, -SLAB.y * 0.5, SLAB_Z),
			0.24,
			Color(2.28, 2.22, 2.10)
		)
	)
	room.add_child(
		mesh_node(
			"Threshold",
			box(Vector3(DOOR_X1 - DOOR_X0 + 0.5, 0.14, 0.9), "threshold"),
			_polymer,
			Vector3((DOOR_X0 + DOOR_X1) * 0.5, -0.03, WALL_Z - 0.4),
			0.31,
			Color(2.10, 2.06, 1.96)
		)
	)


## Lap siding in three runs — left of the doorway, right of it, and a short stack
## carried over its head. Boards rather than sheets, and no board taller than a
## third of a metre: the scrap shader bands its timber along the OBJECT's own Y at
## four times the detail frequency, so a four-metre plank comes out as forty
## stripes of nothing recognisable. At a third of a metre it comes out as grain.
##
## Roughly one board in four is a sheet of steel patched in, because a scav wall
## is whatever was to hand and a wall of one material at this size reads as
## wallpaper.
func _build_wall(room: Node3D) -> void:
	var wall := Node3D.new()
	wall.name = "BackWall"
	room.add_child(wall)
	var n: int = 0
	for run: Array in [
		[-WALL_HALF, DOOR_X0, -0.12],
		[DOOR_X1, WALL_HALF, -0.12],
		[DOOR_X0, DOOR_X1, DOOR_TOP - 0.06],
	]:
		var x0: float = float(run[0])
		var x1: float = float(run[1])
		var y0: float = float(run[2])
		var rows: int = int(ceil((WALL_TOP - y0) / BOARD_H))
		for r: int in rows:
			n += 1
			var shade: float = _rng.next_range(0.58, 0.98)
			var steel: bool = _rng.chance(0.24)
			# Proud by up to two centimetres, so every lap catches its own shadow
			# line instead of the run going flat under the lamp.
			var proud: float = _rng.next_range(0.0, 0.020)
			wall.add_child(
				mesh_node(
					"Board%02d" % n,
					box(Vector3(x1 - x0, BOARD_H + 0.02, WALL_T), "wall board"),
					_steel if steel else _timber,
					Vector3((x0 + x1) * 0.5, y0 + BOARD_H * (float(r) + 0.5), WALL_Z + proud),
					0.07 + 0.029 * float(n),
					Color(shade, shade, shade * 1.05) if steel else timber_tint(shade)
				)
			)
	_build_wall_frame(wall)
	_build_door_frame(wall)


## The studs the siding is nailed to, seen from inside. Four of them, none behind
## the board where they would never be seen.
func _build_wall_frame(wall: Node3D) -> void:
	var face: float = WALL_Z + WALL_T * 0.5 + 0.035
	var stud: ArrayMesh = box(Vector3(0.10, 1.7, 0.08), "stud")
	var n: int = 0
	for x: float in [-4.16, -1.50, 1.52, 3.66]:
		n += 1
		for tier: int in 2:
			wall.add_child(
				mesh_node(
					"Stud%d%s" % [n, "A" if tier == 0 else "B"],
					stud,
					_timber,
					Vector3(x, 0.83 + 1.66 * float(tier), face),
					0.52 + 0.07 * float(n) + 0.03 * float(tier),
					timber_tint(0.80)
				)
			)


func _build_door_frame(wall: Node3D) -> void:
	var face: float = WALL_Z + 0.02
	var jamb: ArrayMesh = box(Vector3(0.16, DOOR_TOP + 0.2, 0.20), "door jamb")
	for x: float in [DOOR_X0 - 0.07, DOOR_X1 + 0.07]:
		wall.add_child(
			mesh_node(
				"Jamb%s" % ("L" if x < DOOR_X1 else "R"),
				jamb,
				_timber,
				Vector3(x, (DOOR_TOP + 0.2) * 0.5 - 0.1, face),
				0.61 if x < DOOR_X1 else 0.67,
				timber_tint(0.82)
			)
		)
	wall.add_child(
		mesh_node(
			"Lintel",
			box(Vector3(DOOR_X1 - DOOR_X0 + 0.52, 0.18, 0.22), "lintel"),
			_timber,
			Vector3((DOOR_X0 + DOOR_X1) * 0.5, DOOR_TOP + 0.09, face),
			0.73,
			timber_tint(0.80)
		)
	)


## Rafters and three sheets of deck. Only the far band of it is ever in frame, but
## that band is what gives the shot a ceiling instead of a sky.
func _build_roof(room: Node3D) -> void:
	var roof := Node3D.new()
	roof.name = "Roof"
	room.add_child(roof)
	var length: float = ROOF_Z1 - ROOF_Z0
	var rafter: ArrayMesh = box(Vector3(0.09, 0.17, length), "rafter")
	var n: int = 0
	for x: float in [-3.85, -2.75, -1.65, -0.55, 0.55, 1.65, 2.75, 3.85]:
		n += 1
		roof.add_child(
			mesh_node(
				"Rafter%d" % n,
				rafter,
				_timber,
				Vector3(x, RAFTER_Y, (ROOF_Z0 + ROOF_Z1) * 0.5),
				0.13 * float(n),
				timber_tint(0.78)
			)
		)
	var sheet: ArrayMesh = box(Vector3(WALL_HALF * 2.0 + 0.2, 0.06, 1.38), "roof sheet")
	for i: int in 3:
		var deck := mesh_node(
			"Deck%d" % (i + 1),
			sheet,
			_steel,
			Vector3(0.0, ROOF_Y, ROOF_Z0 + 0.66 + 1.29 * float(i)),
			0.29 + 0.19 * float(i),
			Color(0.72, 0.73, 0.78)
		)
		# The wall already puts the whole interior in shade; the deck casting as
		# well only costs a pass over the cascade.
		deck.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		roof.add_child(deck)


## What is out through the door: a wrecked block, a leaning pole, a far ridge.
## Silhouettes only — the view out is straight into the low sun, so they read as
## shapes in the haze and nothing more is needed.
func _build_outside(room: Node3D) -> void:
	var out := Node3D.new()
	out.name = "Outside"
	room.add_child(out)
	out.add_child(
		mesh_node(
			"Ruin",
			box(Vector3(5.0, 2.1, 3.4), "ruin"),
			_polymer,
			Vector3(-13.5, 1.02, -12.5),
			0.36,
			Color(2.2, 2.05, 1.8)
		)
	)
	out.add_child(
		mesh_node(
			"RuinLow",
			box(Vector3(3.0, 1.1, 2.2), "ruin low"),
			_polymer,
			Vector3(-9.4, 0.54, -8.4),
			0.44,
			Color(2.0, 1.88, 1.66)
		)
	)
	var pole := mesh_node(
		"Pole",
		cylinder(0.10, 5.2, "pole"),
		_timber,
		Vector3(-6.6, 2.5, -5.8),
		0.58,
		timber_tint(0.9)
	)
	pole.rotation = Vector3(deg_to_rad(-6.0), 0.0, deg_to_rad(8.0))
	out.add_child(pole)
	out.add_child(
		mesh_node(
			"Crossarm",
			box(Vector3(1.5, 0.11, 0.11), "pole crossarm"),
			_timber,
			Vector3(-6.85, 4.62, -5.77),
			0.62,
			timber_tint(0.88)
		)
	)
	out.add_child(
		mesh_node(
			"Ridge",
			box(Vector3(46.0, 3.8, 13.0), "ridge"),
			_canvas,
			Vector3(-31.0, 0.0, -35.0),
			0.66,
			Color(1.36, 1.3, 1.22)
		)
	)


# --- the bench ---------------------------------------------------------------


## Five loose planks on a trestle, not one slab: the timber shader runs its grain
## along local X, so a single 2.16 m top comes out as one swirl of plywood, and
## five boards each with their own seed come out as boards.
func build_bench(bench: Node3D) -> void:
	var plank: ArrayMesh = box(Vector3(BENCH_W, BENCH_TOP_T, 0.152), "bench plank")
	for i: int in 5:
		var z: float = -0.294 + 0.147 * float(i)
		var shade: float = 0.82 + 0.13 * float(i % 3)
		# Alternate boards sit four millimetres low. Five boards flush with each
		# other are one board; four millimetres is a shadow line you can see from
		# the far side of the shed and cannot trip over.
		var drop: float = 0.004 * float(i % 2)
		bench.add_child(
			mesh_node(
				"Top%d" % (i + 1),
				plank,
				_timber,
				Vector3(0.0, BENCH_TOP_Y - BENCH_TOP_T * 0.5 - drop, z),
				0.21 + 0.13 * float(i),
				timber_tint(shade)
			)
		)
	var apron: ArrayMesh = box(Vector3(BENCH_W - 0.05, 0.12, 0.05), "bench apron")
	for sz: int in [-1, 1]:
		bench.add_child(
			mesh_node(
				"Apron%s" % ("B" if sz < 0 else "F"),
				apron,
				_timber,
				Vector3(0.0, BENCH_TOP_Y - 0.115, float(sz) * (BENCH_D * 0.5 - 0.02)),
				0.66 if sz < 0 else 0.72,
				timber_tint(0.90)
			)
		)
	var leg: ArrayMesh = box(Vector3(BENCH_LEG, 0.90, BENCH_LEG), "bench leg")
	var leg_x: float = BENCH_W * 0.5 - 0.12
	var leg_z: float = BENCH_D * 0.5 - 0.10
	var corner: int = 0
	for sx: int in [-1, 1]:
		for sz: int in [-1, 1]:
			corner += 1
			bench.add_child(
				mesh_node(
					"Leg%d" % corner,
					leg,
					_timber,
					Vector3(float(sx) * leg_x, 0.45, float(sz) * leg_z),
					0.3 + 0.11 * float(corner),
					timber_tint(0.86)
				)
			)
	var rail: ArrayMesh = box(Vector3(BENCH_W - 0.20, 0.06, 0.06), "bench rail")
	bench.add_child(mesh_node("RailFront", rail, _steel, Vector3(0.0, 0.30, leg_z), 0.55))
	bench.add_child(mesh_node("RailBack", rail, _steel, Vector3(0.0, 0.30, -leg_z), 0.63))
	bench.add_child(
		mesh_node(
			"Shelf",
			box(Vector3(BENCH_W - 0.26, 0.045, BENCH_D - 0.30), "bench shelf"),
			_timber,
			Vector3(0.0, 0.36, 0.0),
			0.77,
			timber_tint(0.84)
		)
	)
	_build_vice(bench)


func _build_vice(bench: Node3D) -> void:
	var y: float = BENCH_TOP_Y
	bench.add_child(
		mesh_node(
			"ViceBase",
			box(Vector3(0.19, 0.07, 0.17), "vice base"),
			_steel,
			Vector3(0.80, y + 0.035, -0.14),
			0.19
		)
	)
	bench.add_child(
		mesh_node(
			"ViceBody",
			box(Vector3(0.13, 0.13, 0.30), "vice body"),
			_steel,
			Vector3(0.80, y + 0.095, -0.10),
			0.27
		)
	)
	bench.add_child(
		mesh_node(
			"ViceJaw",
			box(Vector3(0.20, 0.11, 0.06), "vice jaw"),
			_steel,
			Vector3(0.80, y + 0.135, 0.01),
			0.33
		)
	)
	var handle := mesh_node(
		"ViceHandle",
		cylinder(0.014, 0.30, "vice handle"),
		_steel,
		Vector3(0.80, y + 0.145, -0.24),
		0.39
	)
	handle.rotation = Vector3(deg_to_rad(90.0), 0.0, deg_to_rad(14.0))
	bench.add_child(handle)
	bench.add_child(
		mesh_node(
			"Tin", cylinder(0.085, 0.11, "tin"), _steel, Vector3(-0.86, y + 0.055, -0.16), 0.45
		)
	)
	bench.add_child(
		mesh_node(
			"Rag",
			box(Vector3(0.24, 0.035, 0.19), "rag"),
			_canvas,
			Vector3(-0.60, y + 0.018, 0.05),
			0.51
		)
	)


# --- the board ---------------------------------------------------------------


## The board the whole menu hangs on: two posts standing on the slab, six boards
## across them, a cap rail, a stencil plate for the sign and a dark panel for the
## readout. Nothing on it overlaps anything else on it.
func build_board(bench: Node3D) -> void:
	var post: ArrayMesh = box(Vector3(0.10, BOARD_TOP + 0.14, 0.11), "board post")
	for sx: int in [-1, 1]:
		bench.add_child(
			mesh_node(
				"BoardPost%s" % ("L" if sx < 0 else "R"),
				post,
				_timber,
				Vector3(
					float(sx) * (BOARD_W * 0.5 - 0.06),
					(BOARD_TOP + 0.14) * 0.5 - 0.10,
					BOARD_Z - 0.05
				),
				0.81 if sx < 0 else 0.87,
				timber_tint(0.84)
			)
		)
	var height: float = BOARD_TOP - BOARD_BOTTOM
	var rows: int = 6
	var pitch: float = height / float(rows)
	var slat: ArrayMesh = box(Vector3(BOARD_W, pitch + 0.012, BOARD_T), "board slat")
	for i: int in rows:
		var shade: float = _rng.next_range(0.86, 1.10)
		# Every other board set back a centimetre, for the same reason the bench
		# boards step: a flat sheet under a raking lamp has no boards in it.
		var back: float = 0.008 * float(i % 2)
		bench.add_child(
			mesh_node(
				"BoardSlat%d" % (i + 1),
				slat,
				_timber,
				Vector3(0.0, BOARD_BOTTOM + pitch * (float(i) + 0.5), BOARD_Z - back),
				0.09 + 0.14 * float(i),
				timber_tint(shade)
			)
		)
	bench.add_child(
		mesh_node(
			"BoardCap",
			box(Vector3(BOARD_W + 0.12, 0.09, 0.14), "board cap"),
			_timber,
			Vector3(0.0, BOARD_TOP + 0.02, BOARD_Z + 0.02),
			0.93,
			timber_tint(0.80)
		)
	)
	bench.add_child(
		mesh_node(
			"SignPlate",
			box(TITLE_PLATE, "sign plate"),
			_steel,
			Vector3(0.0, TITLE_Y, BOARD_FACE + TITLE_PLATE.z * 0.5 - 0.008),
			0.17
		)
	)
	_build_readout(bench)


func _build_readout(bench: Node3D) -> void:
	var front: float = BOARD_FACE + READOUT.z * 0.5 - 0.008
	bench.add_child(
		mesh_node(
			"ReadoutPanel",
			box(READOUT, "readout panel"),
			_polymer,
			Vector3(0.0, READOUT_Y, front),
			0.23
		)
	)
	var lip: ArrayMesh = box(Vector3(READOUT.x + 0.06, 0.022, 0.05), "readout lip")
	for sy: int in [-1, 1]:
		bench.add_child(
			mesh_node(
				"ReadoutLip%s" % ("B" if sy < 0 else "T"),
				lip,
				_steel,
				Vector3(0.0, READOUT_Y + float(sy) * (READOUT.y * 0.5 - 0.004), front - 0.004),
				0.35 if sy < 0 else 0.43
			)
		)
	var stud: ArrayMesh = cylinder(0.016, 0.03, "readout stud")
	for sx: int in [-1, 1]:
		var node := mesh_node(
			"ReadoutStud%s" % ("L" if sx < 0 else "R"),
			stud,
			_ember,
			Vector3(float(sx) * (READOUT.x * 0.5 - 0.055), READOUT_Y, front + READOUT.z * 0.5),
			0.53
		)
		node.rotation = Vector3(deg_to_rad(90.0), 0.0, 0.0)
		bench.add_child(node)


# --- clutter -----------------------------------------------------------------


## Crates, drums, a shelf and the bits on the floor. This is the difference
## between a bench in a void and a corner of somebody's workshop, and it is all
## boxes and cylinders — nothing here costs more than a draw call.
func build_clutter(root: Node3D) -> void:
	var yard := Node3D.new()
	yard.name = "Clutter"
	root.add_child(yard)
	_build_crates(yard)
	_build_drums(yard)
	_build_shelf(yard)
	yard.add_child(
		mesh_node(
			"UnderCrate",
			box(Vector3(0.46, 0.46, 0.44), "under crate"),
			_timber,
			Vector3(-0.52, 0.23, -0.02),
			0.61,
			timber_tint(0.88)
		)
	)
	yard.add_child(
		mesh_node("Bucket", cylinder(0.15, 0.30, "bucket"), _steel, Vector3(0.62, 0.15, 0.22), 0.69)
	)
	var plank := mesh_node(
		"LeaningPlank",
		box(Vector3(0.26, 2.3, 0.05), "leaning plank"),
		_timber,
		Vector3(4.06, 1.06, -0.76),
		0.75,
		timber_tint(0.86)
	)
	plank.rotation = Vector3(deg_to_rad(-13.0), deg_to_rad(6.0), 0.0)
	yard.add_child(plank)


func _build_crates(yard: Node3D) -> void:
	var big: ArrayMesh = box(Vector3(0.62, 0.60, 0.58), "crate")
	var specs: Array[Array] = [
		[Vector3(1.74, 0.30, -0.72), 11.0, 0.80],
		[Vector3(1.68, 0.89, -0.66), -7.0, 0.94],
		[Vector3(3.30, 0.30, 0.34), 24.0, 0.72],
	]
	var n: int = 0
	for spec: Array in specs:
		n += 1
		var shade: float = float(spec[2])
		var crate := mesh_node(
			"Crate%d" % n, big, _timber, spec[0] as Vector3, 0.15 * float(n), timber_tint(shade)
		)
		crate.rotation = Vector3(0.0, deg_to_rad(float(spec[1])), 0.0)
		yard.add_child(crate)
	var can := mesh_node(
		"JerryCan",
		box(Vector3(0.17, 0.40, 0.32), "jerry can"),
		_steel,
		Vector3(1.62, 1.39, -0.64),
		0.57
	)
	can.rotation = Vector3(0.0, deg_to_rad(-6.0), 0.0)
	yard.add_child(can)


func _build_drums(yard: Node3D) -> void:
	var drum: ArrayMesh = cylinder(0.29, 0.86, "drum")
	var band: ArrayMesh = cylinder(0.305, 0.06, "drum band")
	var skin := Color(1.32, 1.30, 1.26)
	var n: int = 0
	for spec: Array in [[Vector3(3.62, 0.43, 0.22), 0.38], [Vector3(2.72, 0.43, -0.68), 0.72]]:
		n += 1
		var at: Vector3 = spec[0] as Vector3
		yard.add_child(mesh_node("Drum%d" % n, drum, _steel, at, float(spec[1]), skin))
		for dy: float in [-0.22, 0.22]:
			yard.add_child(
				mesh_node(
					"DrumBand%d%s" % [n, "L" if dy < 0.0 else "U"],
					band,
					_steel,
					at + Vector3(0.0, dy, 0.0),
					float(spec[1]) + 0.09,
					skin
				)
			)


func _build_shelf(yard: Node3D) -> void:
	var x: float = 2.34
	var z: float = WALL_Z + 0.32
	var upright: ArrayMesh = box(Vector3(0.06, 1.62, 0.30), "shelf upright")
	for sx: int in [-1, 1]:
		yard.add_child(
			mesh_node(
				"ShelfPost%s" % ("L" if sx < 0 else "R"),
				upright,
				_steel,
				Vector3(x + float(sx) * 0.31, 0.81, z),
				0.24 if sx < 0 else 0.32
			)
		)
	var board: ArrayMesh = box(Vector3(0.70, 0.04, 0.32), "shelf board")
	for i: int in 3:
		yard.add_child(
			mesh_node(
				"ShelfBoard%d" % (i + 1),
				board,
				_timber,
				Vector3(x, 0.46 + 0.52 * float(i), z),
				0.4 + 0.12 * float(i),
				timber_tint(0.88)
			)
		)
	var tin: ArrayMesh = cylinder(0.065, 0.14, "shelf tin")
	var n: int = 0
	for spec: Array in [[-0.2, 0], [0.0, 0], [0.22, 1], [-0.1, 2], [0.16, 2]]:
		n += 1
		var shelf_y: float = 0.55 + 0.52 * float(int(spec[1]))
		yard.add_child(
			mesh_node(
				"ShelfTin%d" % n,
				tin,
				_steel,
				Vector3(x + float(spec[0]), shelf_y, z),
				0.5 + 0.06 * float(n)
			)
		)


# --- light -------------------------------------------------------------------


## Two tin shades on drop rods off one conduit under the rafters, each aimed back
## and down at its own half of the board so the plates are lit square on rather
## than grazed. `main_menu.gd` flickers `Lamp/Bulb/Light`, so those names are
## contract; the second fixture is the one that is not on its way out, and it does
## not cast, which keeps the menu to a single shadow pass.
func build_lamp(root: Node3D) -> void:
	var lamp := Node3D.new()
	lamp.name = "Lamp"
	root.add_child(lamp)
	lamp.add_child(
		mesh_node(
			"Conduit",
			box(Vector3(3.1, 0.05, 0.05), "conduit"),
			_steel,
			Vector3(0.0, RAFTER_Y - 0.14, LAMP_Z),
			0.12
		)
	)
	_build_fixture(lamp, "", Vector3(-LAMP_X, LAMP_Y, LAMP_Z), true)
	_build_fixture(lamp, "2", Vector3(LAMP_X, LAMP_Y, LAMP_Z), false)


func _build_fixture(lamp: Node3D, suffix: String, head: Vector3, shadowed: bool) -> void:
	var rod_top: float = RAFTER_Y - 0.14
	lamp.add_child(
		mesh_node(
			"Rod" + suffix,
			cylinder(0.016, rod_top - head.y + 0.12, "lamp rod"),
			_steel,
			Vector3(head.x, (rod_top + head.y - 0.12) * 0.5 + 0.06, head.z),
			0.18
		)
	)
	var target := Vector3(signf(head.x) * LAMP_TARGET.x, LAMP_TARGET.y, LAMP_TARGET.z)
	var aim: Vector3 = (target - head).normalized()
	var shade: MeshInstance3D = mesh_node(
		"Shade" + suffix,
		cylinder(0.135, 0.17, "lamp shade"),
		_steel,
		head,
		0.38,
		Color(0.92, 0.95, 1.04)
	)
	# Basis.looking_at puts -Z down the beam; the extra quarter turn swings the
	# cylinder's own Y axis onto it, so the open end of the tin faces the board.
	shade.basis = Basis.looking_at(aim, Vector3.UP) * Basis(Vector3.RIGHT, -PI * 0.5)
	lamp.add_child(shade)

	var bulb: MeshInstance3D = mesh_node(
		"Bulb" + suffix, cylinder(0.05, 0.055, "bulb"), _ember, head + aim * 0.055, 0.44
	)
	lamp.add_child(bulb)

	var light := SpotLight3D.new()
	light.name = "Light" + suffix
	light.basis = Basis.looking_at(aim, Vector3.UP)
	light.light_color = Color(1.0, 0.898, 0.776)
	light.light_energy = 3.1
	light.light_specular = 0.32
	light.spot_range = 5.2
	light.spot_angle = 52.0
	light.spot_angle_attenuation = 1.4
	light.spot_attenuation = 1.3
	light.shadow_enabled = shadowed
	light.shadow_bias = 0.035
	light.shadow_normal_bias = 1.2
	bulb.add_child(light)


## Two unshadowed omnis: the warm one is the lamp's spill off the bench top, the
## cool one is the daylight coming through the doorway bouncing off the slab.
## Neither casts, so neither costs a shadow pass.
func build_fill(root: Node3D) -> void:
	var fill := Node3D.new()
	fill.name = "Fill"
	root.add_child(fill)

	var warm := OmniLight3D.new()
	warm.name = "BenchFill"
	warm.position = Vector3(0.0, 1.24, 0.34)
	warm.light_color = Color(1.0, 0.871, 0.729)
	warm.light_energy = 0.9
	warm.light_specular = 0.15
	warm.omni_range = 3.4
	warm.omni_attenuation = 1.6
	fill.add_child(warm)

	var door := OmniLight3D.new()
	door.name = "DoorFill"
	door.position = Vector3(-2.62, 1.30, -0.66)
	door.light_color = Color(1.0, 0.902, 0.784)
	door.light_energy = 2.2
	door.light_specular = 0.1
	door.omni_range = 7.2
	door.omni_attenuation = 1.3
	fill.add_child(door)

	# The daylight that has been round the shed twice. Wide, weak and cool, and
	# the only thing standing between the far corners and pure black.
	var room := OmniLight3D.new()
	room.name = "RoomFill"
	room.position = Vector3(0.5, 2.0, 0.9)
	room.light_color = Color(0.859, 0.867, 0.918)
	room.light_energy = 0.62
	room.light_specular = 0.05
	room.omni_range = 9.0
	room.omni_attenuation = 1.1
	fill.add_child(room)


## Sun-bleached timber, at `shade` brightness. `scrap_timber` is a saturated
## #8a5a2b, which is right for a rifle stock held at arm's length and quite wrong
## for four square metres of shed wall under a warm lamp — at that size it reads
## as varnished plywood, which is the exact slop this project forbids. The blue
## channel is lifted hard to walk the hue back to the weathered grey-brown the
## palette actually calls for, and `shade` is the only knob a caller needs.
static func timber_tint(shade: float) -> Color:
	return Color(shade * 0.64, shade * 0.89, shade * 1.68)
