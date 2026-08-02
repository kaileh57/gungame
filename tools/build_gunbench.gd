extends SceneTree
## Bakes `res://demos/gunbench/gunbench.tscn` — the gunsmith's bay.
##
## Run headless:
##   godot --headless --path <project> --script res://tools/build_gunbench.gd
##
## Everything the bay is made of is authored here and packed into the scene. Nothing
## in `res://demos/gunbench/` generates geometry at run time; the only meshes that
## appear after load are the baked gun parts `PartLibrary` already holds, placed by
## `GunFactory` at the transforms the fit solver wrote.
##
## THE ROOM IS A SOLID. Six overlapping slabs surrounding a void, not a box turned
## inside out and not six planes: every interior surface you see is the outward face
## of a slab with real thickness, so no winding is inverted and no joint between two
## slabs is anything but an overlap. Every shell is censused by
## `res://demos/gunbench/build/gunbench_shapes.gd` for winding, open boundary edges and
## degenerate triangles before it is packed, and this run fails loudly if one is not.
##
## The work is deferred to the first idle frame rather than done in `_initialize`: a
## `--script` main loop is compiled before the autoloads are registered, so anything
## that names `GunFactory` or `SceneRouter` at parse time drags in a script that cannot
## compile yet. By the first frame they exist, and `load()` gets them cleanly.

const OUT_DIR: String = "res://demos/gunbench"
const OUT_SCENE: String = "res://demos/gunbench/gunbench.tscn"
const OUT_REPORT: String = "res://demos/gunbench/build_report.txt"

const SCRIPT_ROOT: String = "res://demos/gunbench/gunbench.gd"
const SCRIPT_STAND: String = "res://demos/gunbench/gunbench_stand.gd"
const SCRIPT_PEG: String = "res://demos/gunbench/gunbench_peg.gd"
const SCRIPT_WEAPON: String = "res://systems/guns/weapon.gd"

## Control ids, stencilled on the panel and matched by `Gunbench._on_control_pressed`.
## Written here as plain `StringName`s rather than read off the demo script, because a
## `--script` bake compiles before the autoloads its class chain reaches exist.
const ID_ROLL: StringName = &"roll"
const ID_CLASS: StringName = &"class"
const ID_TIER: StringName = &"tier"
const ID_COMPARE: StringName = &"compare"
const ID_STRIP: StringName = &"strip"
const ID_GRAB_MAIN: StringName = &"grab_main"
const ID_GRAB_RIVAL: StringName = &"grab_rival"
const ID_ROLL_RACK: StringName = &"roll_rack"

const SCENE_WORLD: String = "res://art/scav_world.tscn"
const SCENE_VFX: String = "res://data/vfx/vfx.tscn"
const SCENE_PLAYER: String = "res://data/player/player.tscn"
const SCENE_BUTTON: String = "res://ui/diegetic/diegetic_button.tscn"
const SCENE_DIAL: String = "res://ui/diegetic/diegetic_dial.tscn"
const SCENE_LEVER: String = "res://ui/diegetic/diegetic_lever.tscn"
const SCENE_READOUT: String = "res://ui/diegetic/diegetic_readout.tscn"

const MAT_STEEL: String = "res://art/materials/scrap_steel.tres"
const MAT_TIMBER: String = "res://art/materials/scrap_timber.tres"
const MAT_POLYMER: String = "res://art/materials/scrap_polymer.tres"
const MAT_CANVAS: String = "res://art/materials/scrap_canvas.tres"
const MAT_EMBER: String = "res://art/materials/glow_ember.tres"

## Seats every panel in the bay on what carries it; no standoff here is hand-picked.
const PanelMount := preload("res://ui/diegetic/panel_mount.gd")
## Closed boxes and cylinders, each one censused for winding, open edges and degenerate
## triangles before it is handed back. Bake-time only; nothing in the demo runs it.
const Shapes := preload("res://demos/gunbench/build/gunbench_shapes.gd")

# --- the room ---------------------------------------------------------------
## Interior half-extents and height. The bay is 11.2 x 10 metres and 4.2 high: wide
## enough that two turntables and a wall rack are not crowded, tight enough that no wall
## is decoration, low enough that five shop lamps light it.
const ROOM_X: float = 5.6
const ROOM_Z: float = 5.0
const ROOM_Y: float = 4.2
const WALL_T: float = 0.5
const FLOOR_T: float = 0.6
## Slabs run past the interior by a wall thickness so every corner is an overlap.
const SLAB_X: float = ROOM_X + WALL_T
const SLAB_Z: float = ROOM_Z + WALL_T

# --- the bench and its board -------------------------------------------------
const BENCH_TOP: Vector3 = Vector3(5.4, 0.10, 0.95)
const BENCH_TOP_Y: float = 0.90
const BENCH_Z: float = -4.475
const BENCH_LEG: Vector3 = Vector3(0.12, 0.90, 0.12)
const BOARD: Vector3 = Vector3(5.4, 1.90, 0.08)
const BOARD_Y: float = 2.05
const BOARD_Z: float = -4.98
## Card scales. A `DiegeticReadout` is 600 x 420 mm at 1.0 — a postcard at the seven
## metres the bench is from the door — so the weapon cards are blown up until their
## 18 px body text is legible from the console and the supporting pair is a size down.
##
## THREE BIG CARDS, NOT TWO. The middle one reads out the weapon in your hands, which
## is a third weapon: the stands are displays and what you carry is traded on and off
## them. 2.05 is what fits three across the 5.4 m board; 2.2 was the two-card scale.
const CARD_BIG: float = 2.05
const CARD_SMALL: float = 1.35
const CARD_BIG_Y: float = 2.33
const CARD_SMALL_Y: float = 1.52
## Board-local X the outer big cards and the two supporting cards are centred on.
const CARD_BIG_X: float = 1.72
const CARD_SMALL_X: float = 0.95
## The stencil bolted over the middle card. A card that reads out your own hands has
## to say so, and it says so on a plate rather than by spending a title line on it.
const HANDS_MARK: Vector3 = Vector3(1.23, 0.20, 0.05)
const HANDS_MARK_Y: float = 2.885

# --- the stands --------------------------------------------------------------
## THE GUNS SIT AT EYE HEIGHT, measured rather than chosen. The console panel tops out
## at y = 1.234 at z = -1.255, so the sight line from the spawn eye (0, 1.66, 1.90) to
## the front of a stand at z = -2.01 grazes y = 1.132 and everything under it is behind
## the console from the door. The old 1.47 m gun left 0.11 m of band under the platter —
## less than a button housing is tall. Lifting the platter 150 mm opens it to 0.30 m.
const STAND_X: float = 1.55
const STAND_Z: float = -2.4
const STAND_BASE: Vector3 = Vector3(0.62, 0.12, 0.62)
const STAND_COLUMN_R: float = 0.10
const STAND_COLUMN_H: float = 1.51
const STAND_COLUMN_Y: float = 0.815
const STAND_PLATTER_R: float = 0.30
const STAND_PLATTER_H: float = 0.06
const STAND_PLATTER_Y: float = 1.55
const STAND_GUN_Y: float = 1.62

# --- the grab stations --------------------------------------------------------
## One per stand, bolted to the FRONT of that stand's column so it sits directly under
## that stand's weapon and can belong to no other. The plate carries the button on the
## left and that weapon's own name on the right, so what the button takes is written
## beside the button that takes it. Its band is [1.15, 1.45] — floor is the console's
## sight line above, ceiling is the platter's underside at 1.52.
const STATION_Y: float = 1.30
const STATION_REACH: float = 0.30
const STATION_ARM: Vector3 = Vector3(0.06, 0.06, STATION_REACH)
const STATION_PLATE: Vector3 = Vector3(0.78, 0.30, 0.045)
## Plate-local X of the button's cap and of the name block's centre, and the metres
## of plate the name is allowed to wrap inside.
const STATION_BUTTON_X: float = -0.235
const STATION_BUTTON_Y: float = -0.03
const STATION_NAME_X: float = 0.18
const STATION_NAME_W: float = 0.40
## Deeper travel and a longer lamp than a console button. This is the control the
## report says nobody could find; it is read at three metres, not at arm's length.
const GRAB_PRESS_DEPTH: float = 0.016
const GRAB_HOLD_SECONDS: float = 0.14

# --- the console -------------------------------------------------------------
const CONSOLE_Z: float = -1.05
const CABINET: Vector3 = Vector3(3.4, 0.85, 0.78)
const SHELF: Vector3 = Vector3(3.5, 0.09, 0.85)
const SHELF_Y: float = 0.885
const PANEL: Vector3 = Vector3(3.3, 0.50, 0.09)
## Laid back 64 degrees off vertical, to keep the console out of the sight line to
## the turntables. At that rake the face's lower edge swings 225 mm back and 110 mm
## DOWN, and 1.00 m put 80 mm of it — with the bottom of the control row — inside the
## shelf. The height is solved off the shelf now; `PANEL_ORIGIN.y` is only a seed.
const PANEL_TILT_DEG: float = -64.0
const PANEL_ORIGIN: Vector3 = Vector3(0.0, 1.00, -1.05)
## The strip lever gets its own floor stanchion off the end of the console. It is a
## two-handed throw, not a fingertip control, and it does not belong in the button row.
const LEVER_POST: Vector3 = Vector3(0.30, 0.95, 0.30)
const LEVER_AT: Vector3 = Vector3(2.28, 0.0, -0.90)
## Control origins sit here in panel-local Z: the housing is 50 mm deep and grows
## backwards from the origin, so this buries it in the panel instead of hovering it.
const CONTROL_Z: float = 0.045

# --- the rack ----------------------------------------------------------------
## Both rails cross into the west wall by a centimetre; the hooks reach back inside
## them and out past where a hanging weapon's flank sits.
const RACK_X: float = -ROOM_X - 0.04
const RAIL: Vector3 = Vector3(0.10, 0.14, 7.4)
const RAIL_TOP_Y: float = 1.86
const RAIL_LOW_Y: float = 1.02
const PEG_X: float = -ROOM_X + 0.12
const PEG_Y: float = 1.45
const PEG_COUNT: int = 6
const PEG_SPACING: float = 1.2
## The rack's OWN roll control. Rerolling the wall has nothing to do with the bench's
## stands, so it gets a plate of its own past the north end of the rails, where it reads
## as the last station on the run and is in frame from the door. It clears the rails by
## 110 mm and the north wall by 250 mm.
##
## THE PLATE CARRIES ITS OWN HEADER, measured: at the 8.1 m from the spawn eye to this
## wall a button's own 67 mm stencil is ten pixels of a 1600-wide frame and reads as a
## smudge. 71 mm of cap height is legible from the door, and 940 mm of plate is what a
## nine-letter header at that size needs.
const RACK_ROLL_PLATE: Vector3 = Vector3(0.06, 0.62, 0.94)
const RACK_ROLL_Y: float = 1.50
const RACK_ROLL_Z: float = -4.28
## Plate-local heights of the header and of the button's cap.
const RACK_ROLL_HEADER_Y: float = 0.16
const RACK_ROLL_BUTTON_Y: float = -0.16

# --- lamps -------------------------------------------------------------------
const LAMP_SHADE_Y: float = 3.55
const LAMP_SHADE_R: float = 0.22
const LAMP_SHADE_H: float = 0.16

## Cylinder segments. Twelve is round enough at bay distance and keeps every post
## under thirty triangles.
const SEGMENTS: int = 12
## Metres a vertex may move and still weld to its neighbour in the edge census.
const WELD: float = 0.00005

## The board by the door. The only instructions in the bay, and they are painted on a
## physical plate rather than drawn over the view.
const SIGN_PLATE: Vector3 = Vector3(1.34, 0.66, 0.06)
const SIGN_AT: Vector3 = Vector3(3.30, 1.60, -0.62)
const SIGN_TILT_DEG: float = -10.0
const SIGN_POST_R: float = 0.05
const SIGN_POST_H: float = 1.50
const BAY_NAME: String = "SCAV WORKS  ·  GUNSMITH BAY"
const SIGN_TEXT: String = (
	"GUNSMITH BAY\n\n"
	+ "SHOOT A CONTROL, OR WALK UP AND PRESS F.\n\n"
	+ "GRAB TAKES THE GUN ABOVE THAT BUTTON, FOR\n"
	+ "WHOEVER PRESSED IT. WHAT THEY HELD GOES ON.\n"
	+ "ROLL RACK REROLLS THE WALL AND NOTHING ELSE.\n"
	+ "THE RACK TRADES WITH THE LEFT STAND.\n"
	+ "THE DECK LEVER STRIPS BOTH STANDS.\n\n"
	+ "F3 DIAGNOSTICS   ·   ESC OUT"
)

var _built: bool = false
var _steel: Material = null
var _timber: Material = null
var _polymer: Material = null
var _canvas: Material = null
var _ember: Material = null
var _display: Font = null
var _report: PackedStringArray = PackedStringArray()
var _failures: int = 0
var _seed_counter: float = 0.0
## Every closed shell in the bay comes from here, and every one is censused on its way
## out. The kit collects findings; this file turns them into failures in `_finish`.
var _shapes: RefCounted = Shapes.new()


func _process(_delta: float) -> bool:
	if _built:
		return true
	_built = true
	_build()
	return true


func _build() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	_line("build_gunbench")
	_steel = ResourceLoader.load(MAT_STEEL, "Material") as Material
	_timber = ResourceLoader.load(MAT_TIMBER, "Material") as Material
	_polymer = ResourceLoader.load(MAT_POLYMER, "Material") as Material
	_canvas = ResourceLoader.load(MAT_CANVAS, "Material") as Material
	_ember = ResourceLoader.load(MAT_EMBER, "Material") as Material
	_display = ResourceLoader.load(UiStyle.FONT_DISPLAY_PATH, "Font") as Font
	if _steel == null or _timber == null or _polymer == null or _canvas == null:
		_fail("the scrap materials are missing. Run res://tools/build_art.gd.")
		_finish()
		return

	var root := Node3D.new()
	root.name = "Gunbench"
	root.set_script(load(SCRIPT_ROOT))

	_add_instance(root, SCENE_WORLD, "ScavWorld")
	_add_instance(root, SCENE_VFX, "Vfx")
	_build_shell(root)
	_build_bench(root)
	_build_cards(root)
	_build_stands(root)
	_build_console(root)
	_build_rack(root)
	_build_sign(root)
	_build_lamps(root)
	_build_player(root)

	_pack(root, OUT_SCENE)
	_finish()


func _finish() -> void:
	for finding: String in _shapes.call(&"findings"):
		_fail(finding)
	_line("")
	_line("shells checked        %d" % int(_shapes.call(&"shells")))
	_line("failures              %d" % _failures)
	_line("RESULT: %s" % ("PASS" if _failures == 0 else "FAIL"))
	var text: String = "\n".join(_report) + "\n"
	var f: FileAccess = FileAccess.open(OUT_REPORT, FileAccess.WRITE)
	if f != null:
		f.store_string(text)
		f.close()
	print(text)
	quit(0 if _failures == 0 else 1)


# --- the room ----------------------------------------------------------------


## Six slabs around a void. Each is a closed solid whose INNER face is an ordinary
## outward-wound face — which is why this room can never show a back face or a seam.
func _build_shell(root: Node3D) -> void:
	var shell := StaticBody3D.new()
	shell.name = "Shell"
	shell.collision_layer = GameLayers.WORLD
	shell.collision_mask = 0
	root.add_child(shell)

	# Floor and ceiling first, then the four walls from one description each.
	var wall_h: float = ROOM_Y + FLOOR_T + WALL_T
	var span_x: float = SLAB_X * 2.0
	var span_z: float = SLAB_Z * 2.0
	var slabs: Array[Array] = [
		["Floor", Vector3(span_x, FLOOR_T, span_z), Vector3(0.0, -FLOOR_T * 0.5, 0.0)],
		["Ceiling", Vector3(span_x, WALL_T, span_z), Vector3(0.0, ROOM_Y + WALL_T * 0.5, 0.0)],
	]
	for side: int in [-1, 1]:
		var f: float = float(side)
		var z_at := Vector3(0.0, _wall_y(), f * (ROOM_Z + WALL_T * 0.5))
		var x_at := Vector3(f * (ROOM_X + WALL_T * 0.5), _wall_y(), 0.0)
		slabs.append(
			["Wall%s" % ("South" if side > 0 else "North"), Vector3(span_x, wall_h, WALL_T), z_at]
		)
		slabs.append(
			["Wall%s" % ("East" if side > 0 else "West"), Vector3(WALL_T, wall_h, span_z), x_at]
		)
	for slab: Array in slabs:
		var slab_name: String = slab[0]
		var size: Vector3 = slab[1]
		var at: Vector3 = slab[2]
		var mat: Material = _steel if slab_name == "Ceiling" else _canvas
		shell.add_child(_mesh_node(slab_name, _shapes.box(size), mat, at))
		var shape := CollisionShape3D.new()
		shape.name = slab_name + "Shape"
		var box := BoxShape3D.new()
		box.size = size
		shape.shape = box
		shape.position = at
		shell.add_child(shape)


## Wall slabs run from under the floor to over the ceiling, so their centre is not the
## room's centre.
func _wall_y() -> float:
	return (ROOM_Y + WALL_T - FLOOR_T) * 0.5


# --- the bench ---------------------------------------------------------------


func _build_bench(root: Node3D) -> void:
	var bench := Node3D.new()
	bench.name = "Bench"
	root.add_child(bench)
	bench.add_child(
		_mesh_node(
			"Top",
			_shapes.box(BENCH_TOP),
			_timber,
			Vector3(0.0, BENCH_TOP_Y - BENCH_TOP.y * 0.5, BENCH_Z)
		)
	)
	var leg: ArrayMesh = _shapes.box(BENCH_LEG)
	var leg_x: float = BENCH_TOP.x * 0.5 - 0.15
	var leg_z: float = BENCH_TOP.z * 0.5 - 0.14
	var corner: int = 0
	for sx: int in [-1, 1]:
		for sz: int in [-1, 1]:
			corner += 1
			bench.add_child(
				_mesh_node(
					"Leg%d" % corner,
					leg,
					_timber,
					Vector3(float(sx) * leg_x, BENCH_LEG.y * 0.5, BENCH_Z + float(sz) * leg_z)
				)
			)
	bench.add_child(
		_mesh_node("Board", _shapes.box(BOARD), _timber, Vector3(0.0, BOARD_Y, BOARD_Z))
	)

	var plate: Vector3 = Vector3(4.2, 0.34, 0.06)
	bench.add_child(
		_mesh_node("NamePlate", _shapes.box(plate), _polymer, Vector3(0.0, 3.28, -ROOM_Z + 0.01))
	)
	var name_at := Vector3(0.0, 3.28, -ROOM_Z + 0.045)
	bench.add_child(_label("NameText", BAY_NAME, 44, 0.0042, UiStyle.ACCENT, name_at))

	var body := StaticBody3D.new()
	body.name = "BenchBody"
	body.collision_layer = GameLayers.WORLD
	body.collision_mask = 0
	bench.add_child(body)
	var shape := CollisionShape3D.new()
	shape.name = "TopShape"
	var box := BoxShape3D.new()
	box.size = Vector3(BENCH_TOP.x, BENCH_TOP_Y, BENCH_TOP.z)
	shape.shape = box
	shape.position = Vector3(0.0, BENCH_TOP_Y * 0.5, BENCH_Z)
	body.add_child(shape)


# --- the five readouts -------------------------------------------------------


## Three big cards across the top — stand A, YOUR HANDS, stand B — and two small ones
## under them for the cartridge you are carrying and the A-against-B comparison. Each
## is seated by `PanelMount`, the only thing that knows how deep a card really is.
func _build_cards(root: Node3D) -> void:
	var cards := Node3D.new()
	cards.name = "Cards"
	root.add_child(cards)
	var big: float = CARD_BIG
	var small: float = CARD_SMALL
	cards.add_child(_readout("Stat", -CARD_BIG_X, CARD_BIG_Y, big, UiStyle.ACCENT))
	cards.add_child(_readout("Hands", 0.0, CARD_BIG_Y, big, UiStyle.GOLD))
	cards.add_child(_readout("Rival", CARD_BIG_X, CARD_BIG_Y, big, UiStyle.COOL))
	cards.add_child(_readout("Cartridge", -CARD_SMALL_X, CARD_SMALL_Y, small, UiStyle.GOLD))
	cards.add_child(_readout("Delta", CARD_SMALL_X, CARD_SMALL_Y, small, UiStyle.TEXT))

	# The stencil over the middle card. Mounted through `PanelMount` like everything
	# else on this board, then the text is hung on the face it solved for.
	var mark := _mesh_node("HandsPlate", _shapes.box(HANDS_MARK), _polymer, Vector3.ZERO)
	cards.add_child(mark)
	PanelMount.new().apply(mark, _board_box(), Vector3(0.0, HANDS_MARK_Y, 0.0), "Board")
	var mark_at := Vector3(0.0, HANDS_MARK_Y, mark.position.z + HANDS_MARK.z * 0.5 + 0.004)
	cards.add_child(_label("HandsText", "IN YOUR HANDS", 48, 0.0019, UiStyle.ACCENT, mark_at))


## The board the cards hang on, as a solid.
func _board_box() -> AABB:
	return PanelMount.centred(Vector3(0.0, BOARD_Y, BOARD_Z), BOARD)


## One card. Its standoff used to be read off the back plate's 50 mm THICKNESS, but
## that plate is centred 35 mm behind the card's origin, so its rear face is 60 mm back:
## at 2.05x the big cards were driven through the 80 mm board. `PanelMount` solves it.
func _readout(node_name: String, x: float, y: float, card_scale: float, accent: Color) -> Node3D:
	var packed := ResourceLoader.load(SCENE_READOUT, "PackedScene") as PackedScene
	if packed == null:
		_fail("%s is missing. Run res://tools/build_ui_assets.gd." % SCENE_READOUT)
		return Node3D.new()
	var node: Node3D = packed.instantiate() as Node3D
	node.name = node_name
	node.set(&"accent", accent)
	node.set(&"glow", 1.5)
	var seat := PanelMount.new()
	seat.panel_scale = card_scale
	seat.apply(node, _board_box(), Vector3(x, y, 0.0), "Board")
	return node


# --- the turntables ----------------------------------------------------------


func _build_stands(root: Node3D) -> void:
	var stands := Node3D.new()
	stands.name = "Stands"
	root.add_child(stands)
	stands.add_child(_stand("MainStand", Vector3(-STAND_X, 0.0, STAND_Z), "A", ID_GRAB_MAIN))
	stands.add_child(_stand("RivalStand", Vector3(STAND_X, 0.0, STAND_Z), "B", ID_GRAB_RIVAL))


## Base, column, platter, the grab station, and the five tags the exploded view uses.
## The tags exist from load; only their text and position ever change.
func _stand(node_name: String, at: Vector3, mark: String, grab_id: StringName) -> Node3D:
	var stand: Node3D = (load(SCRIPT_STAND) as GDScript).new()
	stand.name = node_name
	stand.position = at
	stand.set(&"gun_height", STAND_GUN_Y)
	stand.set(&"station_mark", mark)

	stand.add_child(
		_mesh_node("Base", _shapes.box(STAND_BASE), _steel, Vector3(0.0, STAND_BASE.y * 0.5, 0.0))
	)

	var column := Node3D.new()
	column.name = "Column"
	stand.add_child(column)
	column.add_child(
		_mesh_node(
			"Post",
			_shapes.cylinder(STAND_COLUMN_R, STAND_COLUMN_H),
			_steel,
			Vector3(0.0, STAND_COLUMN_Y, 0.0)
		)
	)
	column.add_child(
		_mesh_node(
			"Platter",
			_shapes.cylinder(STAND_PLATTER_R, STAND_PLATTER_H),
			_steel,
			Vector3(0.0, STAND_PLATTER_Y, 0.0)
		)
	)
	# THE GRAB STATION. It hangs off the FRONT of the column on a bracket that reaches
	# past the platter's rim, so it is under the weapon and in front of it rather than
	# under a 300 mm disc where nothing can be read or reached. The button takes the
	# weapon directly above it; the name of that weapon is stencilled beside the button.
	var station := Node3D.new()
	station.name = "Station"
	station.position = Vector3(0.0, STATION_Y, 0.0)
	column.add_child(station)
	station.add_child(
		_mesh_node(
			"Arm", _shapes.box(STATION_ARM), _steel, Vector3(0.0, 0.0, STATION_REACH * 0.5 + 0.04)
		)
	)
	var arm_box: AABB = PanelMount.centred(
		Vector3(0.0, 0.0, STATION_REACH * 0.5 + 0.04), STATION_ARM
	)
	var plate := _mesh_node("Plate", _shapes.box(STATION_PLATE), _polymer, Vector3.ZERO)
	station.add_child(plate)
	PanelMount.new().apply(plate, arm_box, Vector3.ZERO, "StationArm")
	var face_z: float = plate.position.z + STATION_PLATE.z * 0.5

	var grab: Node3D = _button(
		"Grab", grab_id, "GRAB %s" % mark, Vector3(STATION_BUTTON_X, STATION_BUTTON_Y, face_z)
	)
	grab.set(&"press_depth", GRAB_PRESS_DEPTH)
	grab.set(&"hold_seconds", GRAB_HOLD_SECONDS)
	station.add_child(grab)

	var placard_text: Label3D = _label(
		"Name", "", 30, 0.0013, UiStyle.ACCENT, Vector3(STATION_NAME_X, 0.0, face_z + 0.004)
	)
	# Label3D widths are in pre-scale pixels, so this is the name block's width in
	# metres divided by the pixel size. A long rolled name wraps inside its half of the
	# plate instead of running over the button.
	placard_text.width = STATION_NAME_W / 0.0013
	placard_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	station.add_child(placard_text)

	var pivot := Node3D.new()
	pivot.name = "Pivot"
	stand.add_child(pivot)
	var tags := Node3D.new()
	tags.name = "Tags"
	pivot.add_child(tags)
	for i: int in 5:
		var tag: Label3D = _label("Tag%d" % i, "", 26, 0.0008, UiStyle.ACCENT, Vector3.ZERO)
		tag.billboard = BaseMaterial3D.BILLBOARD_FIXED_Y
		tag.visible = false
		tags.add_child(tag)

	var body := StaticBody3D.new()
	body.name = "Body"
	body.collision_layer = GameLayers.WORLD
	body.collision_mask = 0
	stand.add_child(body)
	var shape := CollisionShape3D.new()
	shape.name = "Shape"
	var cyl := CylinderShape3D.new()
	cyl.radius = STAND_PLATTER_R + 0.01
	cyl.height = STAND_PLATTER_Y + STAND_PLATTER_H * 0.5
	shape.shape = cyl
	shape.position = Vector3(0.0, cyl.height * 0.5, 0.0)
	body.add_child(shape)
	return stand


# --- the console -------------------------------------------------------------


func _build_console(root: Node3D) -> void:
	var console := Node3D.new()
	console.name = "Console"
	root.add_child(console)
	console.add_child(
		_mesh_node(
			"Cabinet", _shapes.box(CABINET), _steel, Vector3(0.0, CABINET.y * 0.5, CONSOLE_Z)
		)
	)
	console.add_child(
		_mesh_node("Shelf", _shapes.box(SHELF), _steel, Vector3(0.0, SHELF_Y, CONSOLE_Z))
	)

	var seat := PanelMount.new()
	seat.axis = Vector3.AXIS_Y
	seat.tilt_degrees = PANEL_TILT_DEG
	var face := _mesh_node("Face", _shapes.box(PANEL), _polymer, Vector3.ZERO)
	console.add_child(face)
	var shelf: AABB = PanelMount.centred(Vector3(0.0, SHELF_Y, CONSOLE_Z), SHELF)
	var placed: Transform3D = seat.apply(face, shelf, PANEL_ORIGIN, "Shelf")

	# An empty node carrying the panel's own frame, so a control is placed in panel
	# coordinates — x along the stencilled row, z out of the face — rather than in
	# world coordinates through a rotation nobody wants to do by hand.
	var panel := Node3D.new()
	panel.name = "Panel"
	panel.transform = placed
	console.add_child(panel)
	# FOUR CONTROLS, NOT FIVE. TO HAND is gone: every stand now carries its own grab
	# button, so a console plate that equips "whichever weapon is on the main stand"
	# was a second way to do the same thing from further away.
	panel.add_child(_button("Roll", ID_ROLL, "ROLL", Vector3(-1.20, 0.0, CONTROL_Z)))
	panel.add_child(_dial("Class", ID_CLASS, "CLASS", -0.40))
	panel.add_child(_dial("Tier", ID_TIER, "TIER", 0.40))
	panel.add_child(_button("Compare", ID_COMPARE, "COMPARE", Vector3(1.20, 0.0, CONTROL_Z)))

	var deck := Node3D.new()
	deck.name = "Deck"
	console.add_child(deck)
	deck.add_child(
		_mesh_node(
			"LeverPost",
			_shapes.box(LEVER_POST),
			_steel,
			LEVER_AT + Vector3(0.0, LEVER_POST.y * 0.5, 0.0)
		)
	)
	var lever := _instance(SCENE_LEVER, "Strip") as Node3D
	if lever != null:
		lever.position = LEVER_AT + Vector3(0.0, LEVER_POST.y + 0.025, 0.0)
		lever.set(&"control_id", ID_STRIP)
		lever.set(&"label_text", "STRIP")
		lever.set(&"off_text", "ASSEMBLED")
		lever.set(&"on_text", "STRIPPED")
		deck.add_child(lever)

	var body := StaticBody3D.new()
	body.name = "Body"
	body.collision_layer = GameLayers.WORLD
	body.collision_mask = 0
	console.add_child(body)
	var shape := CollisionShape3D.new()
	shape.name = "Shape"
	var box := BoxShape3D.new()
	box.size = Vector3(CABINET.x, SHELF_Y + SHELF.y * 0.5, CABINET.z)
	shape.shape = box
	shape.position = Vector3(0.0, box.size.y * 0.5, CONSOLE_Z)
	body.add_child(shape)

	var post := CollisionShape3D.new()
	post.name = "LeverPostShape"
	var post_box := BoxShape3D.new()
	post_box.size = LEVER_POST
	post.shape = post_box
	post.position = LEVER_AT + Vector3(0.0, LEVER_POST.y * 0.5, 0.0)
	body.add_child(post)


## One button, placed in its parent's frame. `at` is a whole position rather than an
## X because the console's row and a stand's grab station want the same button in two
## completely different frames.
func _button(node_name: String, id: StringName, text: String, at: Vector3) -> Node3D:
	var node := _instance(SCENE_BUTTON, node_name) as Node3D
	if node == null:
		return Node3D.new()
	node.position = at
	node.set(&"control_id", id)
	node.set(&"label_text", text)
	node.set(&"cooldown", 0.22)
	return node


func _dial(node_name: String, id: StringName, text: String, x: float) -> Node3D:
	var node := _instance(SCENE_DIAL, node_name) as Node3D
	if node == null:
		return Node3D.new()
	node.position = Vector3(x, 0.0, CONTROL_Z)
	node.set(&"control_id", id)
	node.set(&"label_text", text)
	node.set(&"cooldown", 0.22)
	# The real option lists come from `GunTables.CLASS_MIX` and `Palette.GUN_TIER_NAMES`
	# at run time. Two placeholders here would be two lies in a packed scene.
	return node


# --- the wall rack -----------------------------------------------------------


func _build_rack(root: Node3D) -> void:
	var rack := Node3D.new()
	rack.name = "Rack"
	root.add_child(rack)
	var rail: ArrayMesh = _shapes.box(RAIL)
	rack.add_child(_mesh_node("RailTop", rail, _steel, Vector3(RACK_X, RAIL_TOP_Y, 0.0)))
	rack.add_child(_mesh_node("RailLow", rail, _steel, Vector3(RACK_X, RAIL_LOW_Y, 0.0)))

	var pegs := Node3D.new()
	pegs.name = "Pegs"
	rack.add_child(pegs)
	var span: float = float(PEG_COUNT - 1) * PEG_SPACING
	for i: int in PEG_COUNT:
		pegs.add_child(_peg(i, -span * 0.5 + float(i) * PEG_SPACING))
	rack.add_child(_rack_roll())


## The rack's own roll station: a headed plate bolted to the west wall past the north
## end of the rails, with one button on it that rerolls the six hooks and touches
## nothing else. `PanelMount` solves the standoff off the wall SLAB — the wall you see
## is the inner face of a 500 mm solid, so the standoff is 4 mm from x = -5.6 and not
## from anywhere the eye would guess.
func _rack_roll() -> Node3D:
	var station := Node3D.new()
	station.name = "RollStation"

	var wall: AABB = PanelMount.centred(
		Vector3(-(ROOM_X + WALL_T * 0.5), _wall_y(), 0.0),
		Vector3(WALL_T, ROOM_Y + FLOOR_T + WALL_T, SLAB_Z * 2.0)
	)
	var seat := PanelMount.new()
	seat.axis = Vector3.AXIS_X
	var plate := _mesh_node("Plate", _shapes.box(RACK_ROLL_PLATE), _polymer, Vector3.ZERO)
	station.add_child(plate)
	seat.apply(plate, wall, Vector3(0.0, RACK_ROLL_Y, RACK_ROLL_Z), "WallWest")

	# Local +Z is out of a button's face and out of a label's, so both are turned a
	# quarter turn about up to look into the room. The plate needs no turn: it is a box,
	# and its readable face is the one the standoff was solved along.
	var face: float = plate.position.x + RACK_ROLL_PLATE.x * 0.5
	var turn: Basis = Basis(Vector3.UP, PI * 0.5)
	var head_at := Vector3(face + 0.004, RACK_ROLL_Y + RACK_ROLL_HEADER_Y, RACK_ROLL_Z)
	var header: Label3D = _label("Header", "ROLL RACK", 48, 0.0021, UiStyle.ACCENT, head_at)
	header.basis = turn
	station.add_child(header)

	var at := Vector3(face, RACK_ROLL_Y + RACK_ROLL_BUTTON_Y, RACK_ROLL_Z)
	var button: Node3D = _button("Roll", ID_ROLL_RACK, "ROLL", at)
	button.basis = turn
	button.set(&"press_depth", GRAB_PRESS_DEPTH)
	button.set(&"hold_seconds", GRAB_HOLD_SECONDS)
	station.add_child(button)
	return station


## One hook. The gun hangs muzzle-forward with its right flank to the room, on two
## brackets that reach from inside the rails out past where the weapon's back sits, so
## nothing on this wall floats.
func _peg(index: int, z: float) -> Node3D:
	var peg: StaticBody3D = (load(SCRIPT_PEG) as GDScript).new()
	peg.name = "Peg%d" % index
	peg.position = Vector3(PEG_X, PEG_Y, z)
	peg.collision_layer = GameLayers.PROP
	peg.collision_mask = 0
	peg.set(&"control_id", StringName("peg_%d" % index))
	peg.set(&"cooldown", 0.3)

	var hook: ArrayMesh = _shapes.box(Vector3(0.26, 0.06, 0.06))
	peg.add_child(_mesh_node("HookTop", hook, _steel, Vector3(-0.05, RAIL_TOP_Y - PEG_Y, -0.30)))
	peg.add_child(_mesh_node("HookLow", hook, _steel, Vector3(-0.05, RAIL_LOW_Y - PEG_Y, 0.30)))

	# Gun-local +X is the muzzle and +Y is up. Mapping the muzzle to world -Z points
	# every weapon on the wall at the bench, and puts its right flank out into the room.
	var mount := Node3D.new()
	mount.name = "Mount"
	mount.transform = Transform3D(
		Basis(Vector3(0.0, 0.0, -1.0), Vector3(0.0, 1.0, 0.0), Vector3(1.0, 0.0, 0.0)),
		Vector3(0.02, 0.0, 0.0)
	)
	peg.add_child(mount)

	var tag: Label3D = _label("Tag", "", 24, 0.0012, UiStyle.TEXT, Vector3(0.10, -0.28, 0.0))
	tag.rotation = Vector3(0.0, PI * 0.5, 0.0)
	tag.width = 0.9 / 0.0012
	tag.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	peg.add_child(tag)

	var shape := CollisionShape3D.new()
	shape.name = "Hit"
	var box := BoxShape3D.new()
	box.size = Vector3(0.44, 0.62, 1.14)  # the GUN's box, not the hook's
	shape.shape = box
	shape.position = Vector3(0.13, 0.0, 0.0)
	peg.add_child(shape)
	return peg


# --- the sign ----------------------------------------------------------------


## The mount read backwards: the plate's place is the composition, so the POST moves
## until it is clear behind it. A 10-degree rake swings the plate's top-back corner
## 87 mm back, so a post at -0.60 stood a 100 mm column of steel across the last line.
func _build_sign(root: Node3D) -> void:
	var sign_node := Node3D.new()
	sign_node.name = "Sign"
	root.add_child(sign_node)
	var seat := PanelMount.new()
	seat.tilt_degrees = SIGN_TILT_DEG
	var plate := _mesh_node("Plate", _shapes.box(SIGN_PLATE), _polymer, SIGN_AT)
	plate.basis = seat.mount_basis()
	sign_node.add_child(plate)

	var bounds: AABB = PanelMount.measure(plate)
	var back: float = seat.support_face(bounds, SIGN_AT) - SIGN_POST_R
	var at := Vector3(SIGN_AT.x, SIGN_POST_H * 0.5, back)
	var post: Vector3 = Vector3(SIGN_POST_R, SIGN_POST_H * 0.5, SIGN_POST_R) * 2.0
	sign_node.add_child(_mesh_node("Post", _shapes.cylinder(SIGN_POST_R, SIGN_POST_H), _steel, at))
	seat.declare(plate, bounds, PanelMount.centred(at, post), "SignPost")
	var text: Label3D = _label("Text", SIGN_TEXT, 30, 0.0013, UiStyle.TEXT, Vector3.ZERO)
	text.transform = plate.transform * Transform3D(Basis(), Vector3(0.0, 0.0, 0.036))
	sign_node.add_child(text)


# --- lamps -------------------------------------------------------------------


## Five shop lamps on stems from the ceiling. Only the two over the turntables cast
## shadows — that is what makes a gun read as an object, and five shadow-casting spots
## in one room is four more shadow maps than the bay needs.
##
## THE RACK TAKES TWO, measured: one lamp over the middle of a 7.4 m rail run lights a
## cone 2.56 m across at peg height, so both ends and the roll station fell outside it
## and read as a black plate with a floating stencil. Two at ±2.0 cover the whole run.
func _build_lamps(root: Node3D) -> void:
	var lamps := Node3D.new()
	lamps.name = "Lamps"
	root.add_child(lamps)
	lamps.add_child(_lamp("LampMain", Vector3(-STAND_X, 0.0, STAND_Z), true, 5.4))
	lamps.add_child(_lamp("LampRival", Vector3(STAND_X, 0.0, STAND_Z), true, 5.4))
	lamps.add_child(_lamp("LampConsole", Vector3(0.0, 0.0, CONSOLE_Z), false, 4.2))
	# Clear of the west wall by more than the shade's own radius.
	lamps.add_child(_lamp("LampRackNorth", Vector3(-ROOM_X + 0.95, 0.0, -2.0), false, 4.6))
	lamps.add_child(_lamp("LampRackSouth", Vector3(-ROOM_X + 0.95, 0.0, 2.0), false, 4.6))


func _lamp(node_name: String, at: Vector3, shadows: bool, energy: float) -> Node3D:
	var lamp := Node3D.new()
	lamp.name = node_name
	lamp.position = Vector3(at.x, 0.0, at.z)

	var stem_top: float = ROOM_Y
	var stem_bottom: float = LAMP_SHADE_Y + LAMP_SHADE_H * 0.5 - 0.02
	var stem_h: float = stem_top - stem_bottom
	lamp.add_child(
		_mesh_node(
			"Stem",
			_shapes.cylinder(0.022, stem_h + 0.04),
			_steel,
			Vector3(0.0, stem_bottom + stem_h * 0.5, 0.0)
		)
	)
	lamp.add_child(
		_mesh_node(
			"Shade",
			_shapes.cylinder(LAMP_SHADE_R, LAMP_SHADE_H),
			_steel,
			Vector3(0.0, LAMP_SHADE_Y, 0.0)
		)
	)
	var bulb := _mesh_node(
		"Bulb", _shapes.cylinder(0.09, 0.09), _ember, Vector3(0.0, LAMP_SHADE_Y - 0.10, 0.0)
	)
	lamp.add_child(bulb)

	var light := SpotLight3D.new()
	light.name = "Light"
	light.position = Vector3(0.0, -0.05, 0.0)
	light.rotation = Vector3(-PI * 0.5, 0.0, 0.0)
	light.light_color = Color(1.0, 0.855, 0.678)
	light.light_energy = energy
	light.light_specular = 0.65
	light.spot_range = 4.9
	light.spot_angle = 52.0
	light.spot_angle_attenuation = 1.05
	light.spot_attenuation = 1.35
	light.shadow_enabled = shadows
	light.shadow_bias = 0.035
	light.shadow_normal_bias = 1.1
	bulb.add_child(light)
	return lamp


# --- the player and the weapon ------------------------------------------------


## The baked player, plus the `Weapon` that drives whatever the holster has up. The
## weapon is a sibling rather than a child of the eye: it takes aim, muzzle and shooter
## through `set_rig`, so its place in the tree means nothing and the prefab stays clean.
func _build_player(root: Node3D) -> void:
	var player := _instance(SCENE_PLAYER, "Player") as Node3D
	if player != null:
		player.position = Vector3(0.0, 0.0, 1.90)
		root.add_child(player)

	# The viewmodel renders in its own pass with the world's lights culled out of it, so
	# without a light of its own the gun in your hands is lit by ambient alone and reads
	# as a silhouette. This key is the bay's shop lamp as the gun sees it.
	var key := DirectionalLight3D.new()
	key.name = "ViewmodelKey"
	key.layers = GameLayers.VIEWMODEL
	key.light_cull_mask = GameLayers.VIEWMODEL
	key.light_color = Color(1.0, 0.886, 0.749)
	key.light_energy = 2.6
	key.light_specular = 0.8
	key.shadow_enabled = false
	key.rotation = Vector3(deg_to_rad(-38.0), deg_to_rad(48.0), 0.0)
	root.add_child(key)

	var weapon: Node3D = (load(SCRIPT_WEAPON) as GDScript).new()
	weapon.name = "Weapon"
	weapon.set(&"self_driven", true)
	weapon.set(&"infinite_reserve", true)
	root.add_child(weapon)


# --- node helpers ------------------------------------------------------------


func _add_instance(root: Node3D, path: String, node_name: String) -> void:
	var node: Node = _instance(path, node_name)
	if node != null:
		root.add_child(node)


## `Node`, not `Node3D`: `scav_world.tscn`'s root is a `WorldEnvironment` with no
## transform. Callers that place what they instanced cast it.
func _instance(path: String, node_name: String) -> Node:
	var packed := ResourceLoader.load(path, "PackedScene") as PackedScene
	if packed == null:
		_fail("%s is missing; its builder has not been run." % path)
		return null
	var node: Node = packed.instantiate()
	if node == null:
		_fail("%s did not instantiate." % path)
		return null
	node.name = node_name
	return node


func _mesh_node(
	node_name: String, mesh: ArrayMesh, material: Material, origin: Vector3
) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	node.name = node_name
	node.mesh = mesh
	node.material_override = material
	node.position = origin
	node.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	# A per-object noise offset so two identical boxes do not rust identically, taken
	# from a counter that is deterministic in build order so the bake is reproducible.
	_seed_counter = fmod(_seed_counter + 0.317, 1.0)
	node.set_instance_shader_parameter(&"surface_seed", _seed_counter)
	return node


func _label(
	node_name: String, text: String, font_size: int, pixel_size: float, color: Color, at: Vector3
) -> Label3D:
	var label := Label3D.new()
	label.name = node_name
	label.text = text
	label.font = _display
	label.font_size = font_size
	label.pixel_size = pixel_size
	label.modulate = color
	label.outline_modulate = Color(0.035, 0.031, 0.028, 1.0)
	label.outline_size = 8
	label.position = at
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.shaded = false
	label.double_sided = false
	label.alpha_cut = Label3D.ALPHA_CUT_DISCARD
	label.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	label.render_priority = 2
	return label


# --- io ----------------------------------------------------------------------


func _pack(root: Node, path: String) -> void:
	_own(root, root)
	var packed := PackedScene.new()
	var err: Error = packed.pack(root)
	if err != OK:
		_fail("packing %s failed (error %d)" % [path, err])
		root.free()
		return
	err = ResourceSaver.save(packed, path)
	if err != OK:
		_fail("saving %s failed (error %d)" % [path, err])
	else:
		_line("  wrote       %s (%d nodes)" % [path, _count(root)])
	root.free()


## Instanced sub-scenes keep their own internals; only the instance root is owned here,
## which is what makes `pack` store an instance rather than a flattened copy.
func _own(node: Node, owner_node: Node) -> void:
	for child: Node in node.get_children():
		if child.owner == null:
			child.owner = owner_node
		if child.scene_file_path.is_empty():
			_own(child, owner_node)


func _count(node: Node) -> int:
	var n: int = 1
	for child: Node in node.get_children():
		n += _count(child)
	return n


func _fail(text: String) -> void:
	_failures += 1
	_line("  FAIL        " + text)


func _line(text: String) -> void:
	_report.append(text)
