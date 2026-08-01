extends SceneTree
## Bakes `res://demos/movement/movement.tscn` — the movement playground.
##
## This file is layout and nothing else. Every box, ramp, sign and stencil is cut
## by `CourseKit`, which emits the mesh and the collider from one call so the two
## cannot disagree; read that file before this one.
##
## THE NUMBERS ARE THE POINT. Ledge heights, gap distances, slope angles, stair
## rises and roof clearances are each graded across the bands the controller
## actually has: `step_height` 0.58, the 1.07 m jump apex at the shipped gravity,
## `mantle_auto_rise` 1.32, `mantle_manual_rise` 2.05, `floor_max_angle` 46
## degrees, `crouch_height` 1.12 and `hard_landing_height` 8.5. Each is painted on
## a VERTICAL face that looks back at the bench — a block's leading edge, a lane's
## backstop, a lintel's soffit — so the course reads its own measurements back
## without a line of screen text. Flat on the deck is not a face: at eye height a
## figure painted on the ground is a five-degree smear from anywhere except
## standing on it, which is exactly too late to have read it.
##
## Run headless:
##   godot --headless --path <project> --script res://tools/build_movement.gd
##
## Autoloads are not up while `--script` compiles this file, so every script that
## names one is pulled in with `load()` on the first idle frame and its properties
## written through `Object.set`. Same reason, same shape as `build_player.gd`.

const OUT_DIR: String = "res://demos/movement"
const SCENE_PATH: String = "res://demos/movement/movement.tscn"
const MESH_PATH: String = "res://demos/movement/course_mesh.res"

const SCRIPT_DEMO: String = "res://demos/movement/movement_demo.gd"
const SCRIPT_CONSOLE: String = "res://demos/movement/movement_console.gd"
const SCRIPT_INTERACTOR: String = "res://demos/movement/course_interactor.gd"
const SCRIPT_GATE: String = "res://demos/movement/split_gate.gd"
const SCRIPT_TIMER: String = "res://demos/movement/run_timer.gd"
const SCRIPT_BOARD: String = "res://demos/movement/movement_scoreboard.gd"
const SCRIPT_LINK: String = "res://demos/movement/movement_link.gd"
const SCRIPT_LADDER: String = "res://systems/player/player_ladder.gd"
const SOUND_PASS: String = "res://demos/movement/gate_pass.res"
const SOUND_LAP: String = "res://demos/movement/gate_lap.res"

const WORLD_SCENE: String = "res://art/scav_world.tscn"
const PLAYER_SCENE: String = "res://data/player/player.tscn"
const SLIDER_SCENE: String = "res://ui/diegetic/diegetic_slider.tscn"
const DIAL_SCENE: String = "res://ui/diegetic/diegetic_dial.tscn"
const LEVER_SCENE: String = "res://ui/diegetic/diegetic_lever.tscn"
const BUTTON_SCENE: String = "res://ui/diegetic/diegetic_button.tscn"
const READOUT_SCENE: String = "res://ui/diegetic/diegetic_readout.tscn"
## Proves the gantry screen clears the frame it hangs in.
const PanelMount := preload("res://ui/diegetic/panel_mount.gd")
const WORLD_MATERIAL: String = "res://art/materials/world_surface.tres"
const DISPLAY_FONT: String = "res://data/ui/font_display.tres"

## Colour jitter seed. Any constant would do; this one spells the demo's name, so
## the yard does not come out the same shade as the town.
const COLOUR_SEED: int = 0x4D4F5645

## Shorthands. `WorldSurface.Kind.CONCRETE` spelled out at ninety call sites turns
## the layout into a wall of noise.
const _CONCRETE: int = WorldSurface.Kind.CONCRETE
const _METAL: int = WorldSurface.Kind.METAL
const _TIN: int = WorldSurface.Kind.TIN
const _PALE: Color = Palette.BONE
const _HOT: Color = Palette.ACCENT_ORANGE
## Ramp ends, in `CourseKit.ramp`'s terms: how far the toe is buried and how far
## the slab is carried past its nominal top. Every ramp here wants one of these.
const _LIP: Vector2 = Vector2(0.8, 0.06)
const _TOE: Vector2 = Vector2(0.8, 0.08)

## THE FRAME IS PART OF THE SPEC. Yaw 0 faces -Z, so the whole course is laid out
## NORTH of the bench and inside a 110-degree cone from it: the demo's job is to be
## tuned in a feedback pass, and a knob you cannot see is a knob you do not turn.
## Every anchor below was chosen against the camera the player wakes up behind —
## eye 1.66 m over a 1.60 m overlook at z = +16.8, a 78-degree vertical FOV, 16:9 —
## with the near stations low, the far ones tall, and nothing behind the spawn.
##
## Yard. One apron slab, four wall runs sunk into it and overlapping at the corners.
## Pushed north of the origin: the bench only needs a short apron behind it, and the
## slide run needs every metre it can get in front.
const APRON_CZ: float = -4.0
const APRON_HX: float = 40.0
const APRON_HZ: float = 32.0
## Tall enough to be a backdrop rather than a bright seam on the horizon.
const WALL_HEIGHT: float = 4.6

## Console apron. Under `step_height`, so walking onto it is itself a step test.
const PAD_TOP: float = 0.45
const PAD_CZ: float = 16.0
const PAD_HZ: float = 8.0
const PAD_HX: float = 15.0

## The overlook the player wakes up on, at the back of the apron. THE BENCH HAS TO
## BE BELOW THE EYE OR IT IS A WALL. With the desks and the eye on one level a desk
## top sits within 50 cm of eye height and hides the whole course behind it out to
## thirty metres; from 1.15 m up, the same rank sits in the bottom third of frame
## and everything past twelve metres is clear over it. The step up is 1.15 m, which
## is inside `mantle_auto_rise` — run at it and the vault puts you back on — and
## there is a ramp off each end for when you would rather walk.
const DECK_TOP: float = 1.60
const DECK_CZ: float = 18.4
const DECK_HZ: float = 5.0
const DECK_HX: float = 7.0
const DECK_RAMP_RUN: float = 4.2
## The bench: six desks in one rank across the front, split around a centre aisle
## so the course is read down the middle and the knobs frame it left and right.
## The aisle is 7.2 m wide at the rank, which puts the inner desk edge 27 degrees
## off centre — everything inside that is course, everything outside it is bench.
## Offsets are in desk order: GROUND and AIR innermost, TRAVERSAL and FEEL out at
## the rim, where the 110-degree frame runs out and the fourth pair falls off it.
const DESK_Z: float = 9.9
const DESK_OFFSETS: PackedFloat32Array = [-5.2, 5.2, -8.9, 8.9, -12.6, 12.6]
const DESK_TILT: float = 0.40
const DESK_HALF_X: float = 1.62
## Desk top height above the pad. Slider spacing along it is per desk and lives in
## `MovementTuning.DESK_PITCH`, because the SLIDE desk carries more than the rest.
const DESK_HEIGHT: float = 0.62

## Master column and the gantry over it. The screen used to hang off a 10 cm
## bracket that read as nothing at all from where you stand; it is now slung under
## a portal frame that is itself the top edge of the shot.
const MASTER_Z: float = 11.4
const GANTRY_HALF_X: float = 2.40
const GANTRY_TOP: float = PAD_TOP + 5.15
const READOUT_Y: float = PAD_TOP + 4.15
## The panel ships 0.60 m wide — a hand-held instrument. This is a scoreboard.
const READOUT_SCALE: float = 1.90

## Ledge bank — the mantle band, measured. 0.58 is `step_height`, 1.07 the jump
## apex at the shipped gravity, 1.32 the auto vault, 2.05 the held vault from
## standing. 2.80 is inside the held vault taken from the top of a jump, which is
## the real ceiling; 3.40 is above it, and is there to be the one you cannot have.
##
## Turned a quarter turn from where it used to sit: the blocks now run ACROSS the
## view and are charged from the bench side, so the grading reads as a staircase
## from where you stand instead of as one block edge-on at the rim of the yard.
const LEDGE_HEIGHTS: PackedFloat32Array = [
	0.20, 0.40, 0.58, 0.75, 0.90, 1.07, 1.32, 1.60, 2.05, 2.80, 3.40
]
const LEDGE_Z: float = -15.0
const LEDGE_PITCH: float = 2.6
const LEDGE_HALF_X: float = 1.15
const LEDGE_HALF_Z: float = 1.55
## X of the TALLEST block. The bank grows outward from here toward -X. Tall end
## inboard, because inboard is where the gap run's 1.20 m decks stand in front of
## it: from the bench the sight line past those decks is 0.86 m at the bank, so a
## block shorter than that is a block you cannot see until you walk to it, and the
## tall half of the grading is the half worth reading from the console.
const LEDGE_INNER_X: float = -4.6
## The banner behind the bank, which is what carries the band names at a distance.
const LEDGE_BANNER_Z: float = -18.0
const LEDGE_BANNER_LOW: float = 3.70
const LEDGE_BANNER_HIGH: float = 5.10

## Gap run. A standing jump at walk speed carries about 2.75 m and at sprint 4.75; the
## run brackets both and keeps going. Nine LANES side by side rather than one chain end
## to end — a 61 m chain cannot be seen from one place, and a gap is for retrying.
const GAP_DISTANCES: PackedFloat32Array = [1.5, 2.0, 2.5, 3.0, 3.5, 4.0, 4.5, 5.0, 5.5]
const GAP_LANE_PITCH: float = 2.9
const GAP_HALF_X: float = 1.35
const GAP_TOP: float = 1.2
## South edge of the take-off pads. Lanes are jumped toward -Z, away from the bench.
## The longest lanes sit to the WEST. 2.50 rather than 1.50 because the 5.5 m lane
## reaches 12.3 m north of its lip and the ledge bank's run-up mark is at -11.15:
## one metre closer and the acceptance run spawns inside a landing pad.
const GAP_TAKEOFF_Z: float = 2.5
const GAP_TAKEOFF_LEN: float = 3.2
const GAP_LANDING_LEN: float = 3.6

## Slope fan. `floor_max_angle` is baked at 0.8029 rad = 46.0 degrees, so 46 is the last
## lane you can stand on and 50 the first that slides you back down. Lanes climb away
## from the bench, steep ones inboard, so the fan reads as ten wedges of real length.
const SLOPE_ANGLES: PackedFloat32Array = [
	10.0, 18.0, 26.0, 32.0, 38.0, 43.0, 46.0, 50.0, 55.0, 62.0
]
const SLOPE_FOOT_Z: float = -13.0
const SLOPE_RISE: float = 2.6
const SLOPE_RUN_MAX: float = 9.0
## X of the STEEPEST lane. The fan opens outward from here toward +X.
const SLOPE_LANE_X0: float = 5.0
const SLOPE_LANE_PITCH: float = 2.5
const SLOPE_HALF_W: float = 1.40

## Stair bank. Rise per step, from a kerb to a ladder rung. Flights climb away from the
## bench across the EAST flank — the west is the ledge bank's, and two stations in one
## corridor means the near one screens the far one.
const STAIR_RISES: PackedFloat32Array = [0.12, 0.22, 0.34, 0.46]
const STAIR_COUNTS: PackedInt32Array = [21, 12, 8, 6]
const STAIR_GOING: float = 0.32
const STAIR_Z0: float = 0.5
## X of the finest flight; the bank grows outward toward +X.
const STAIR_X0: float = 15.0
const STAIR_PITCH: float = 4.2
const STAIR_HALF_X: float = 1.35

## Ladder tower. Three flights, three decks, and a nine-metre drop off the top —
## `hard_landing_height` is 8.5, so the last one hurts to look at. Dead centre at the
## far end: the only thing nine metres tall, so it is what the eye lands on.
const TOWER_X: float = 0.0
const TOWER_WALL_Z: float = -20.0
const TOWER_DECKS: PackedFloat32Array = [3.0, 6.0, 9.0]
const TOWER_RUNG_SPACING: float = 0.30
## Decks run north, away from the climb face; the ladders are on the bench side.
const TOWER_DECK_BACK: float = -26.05

## Slide run. Every clearance is above `crouch_height` 1.12 and far below standing, so
## all three are passable ducked and none upright. Laid down the east flank, entry
## nearest the bench, so the roofs recede instead of walling the yard.
const SLIDE_X: float = 33.0
const SLIDE_Z0: float = 2.5
const SLIDE_UP_RUN: float = 6.5
const SLIDE_DECK_LEN: float = 4.5
const SLIDE_DOWN_RUN: float = 8.0
const TUNNEL_CLEARANCES: PackedFloat32Array = [1.70, 1.40, 1.22]
const TUNNEL_SECTION: float = 5.6
const TUNNEL_HALF_W: float = 2.2
const TUNNEL_DECK_TOP: float = 3.4

## Speed loop, in lap order. Gate 0 is both the start and the finish.
const GATE_POSITIONS: PackedVector3Array = [
	Vector3(0.0, 0.0, 5.5),
	Vector3(-26.0, 0.0, -6.0),
	Vector3(-8.0, 0.0, -24.0),
	Vector3(10.0, 0.0, -28.0),
	Vector3(21.0, 0.0, 4.0),
]
const GATE_NAMES: PackedStringArray = ["START", "LEDGE BANK", "TOWER", "SLOPE FAN", "STAIR BANK"]
## Lintel half-extents. The gate's name is painted 4 mm PROUD of this, not at a
## hand-picked 0.21 that sat 10 mm inside it and hid all five signs.
const GATE_LINTEL: Vector3 = Vector3(2.30, 0.22, 0.22)
## Centre height of that lintel. The board, the beacon and the lintel share it.
const GATE_LINTEL_Y: float = 3.05
## Lap board, on the west flank facing the bench. NOT beside the start gate, which is
## where it wants to be and cannot go: the gap run's nine lanes are 2.7 m wide on a 2.9 m
## pitch, so every metre of ground between x = -13 and x = +13 south of the take-offs is
## somebody's run-up, and a post in one of those is a post you sprint into. This is the
## same band the GAP RUN sign already stands in, at the rim of the authored view cone.
const BOARD_AT: Vector3 = Vector3(-14.4, 0.0, 4.6)

## Where the player stands on load. Yaw 0 faces -Z, at the mouth of the bench with
## the whole course in front and nothing at all behind.
const SPAWN: Vector3 = Vector3(0.0, DECK_TOP + 0.05, 16.8)

## Draw-distance caps, metres. Small text stops drawing before big text does.
## The whole course now fits inside 52 m of the bench, so a 110 m sign range was
## paying a draw call a frame for text nothing can be at.
const RANGE_SLIDER: float = 22.0
const RANGE_STENCIL: float = 46.0
const RANGE_SIGN: float = 62.0

var _built: bool = false
var _kit: CourseKit = null
var _pass_sound: AudioStream = null
var _lap_sound: AudioStream = null
var _holo: ShaderMaterial = null


func _process(_delta: float) -> bool:
	if _built:
		return true
	_built = true
	_build()
	return true


func _build() -> void:
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	_kit = CourseKit.new(COLOUR_SEED, load(DISPLAY_FONT) as Font)
	_bake_assets()

	var root := Node3D.new()
	root.name = "Movement"

	var world: Node = (load(WORLD_SCENE) as PackedScene).instantiate()
	world.name = "ScavWorld"
	root.add_child(world)

	var course := Node3D.new()
	course.name = "Course"
	root.add_child(course)

	_yard(course)
	_console_pad(course)
	_ledge_bank(course)
	_gap_run(course)
	_slope_fan(course)
	_stair_bank(course)
	_ladder_tower(course)
	_slide_run(course)

	var player: Node = (load(PLAYER_SCENE) as PackedScene).instantiate()
	player.name = "Player"
	(player as Node3D).position = SPAWN
	root.add_child(player)

	# EVERY station that welds geometry has to run before `_save_mesh`, which
	# snapshots the accumulator and does not clear it. The console's desks and the
	# loop's arches used to be built after the snapshot: their colliders shipped,
	# their triangles did not, and fifty-five solids — six benches, the master
	# column under the screen and all five gates — were invisible in the demo.
	var console: Node3D = _console(root)
	var timer: Node = _loop(root)
	var board: Node3D = CourseMarks.scoreboard(_kit, root, BOARD_AT, _holo)
	board.set_script(load(SCRIPT_BOARD))
	CourseMarks.link(root, load(SCRIPT_LINK), console, timer, board)
	_interactor(root)

	var mesh: ArrayMesh = _kit.save_mesh(load(WORLD_MATERIAL) as Material, MESH_PATH)
	var view := MeshInstance3D.new()
	view.name = "CourseMesh"
	view.mesh = mesh
	view.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	course.add_child(view)
	course.move_child(view, 0)

	root.set_script(load(SCRIPT_DEMO))
	root.set(&"player_path", NodePath("Player"))
	root.set(&"console_path", root.get_path_to(console))

	CourseKit.claim(root, root)
	CourseKit.pack_scene(root, SCENE_PATH)
	_report(mesh, player)
	root.free()


## The two chimes and the projector material, written before anything references them.
func _bake_assets() -> void:
	_pass_sound = CourseMarks.save(CourseMarks.chime_pass(), SOUND_PASS) as AudioStream
	_lap_sound = CourseMarks.save(CourseMarks.chime_lap(), SOUND_LAP) as AudioStream
	_holo = CourseMarks.projector()


# ------------------------------------------------------------------ stations


## The apron everything stands on, and the wall that keeps the yard a yard.
func _yard(parent: Node3D) -> void:
	var body: StaticBody3D = _kit.static_body(parent, "Yard")
	var apron := Vector3(APRON_HX, 0.5, APRON_HZ)
	_kit.box(body, Vector3(0.0, -0.5, APRON_CZ), apron, Palette.WORLD_CONCRETE[0], _CONCRETE)
	var wy: float = WALL_HEIGHT * 0.5 - 0.2
	var wh: float = WALL_HEIGHT * 0.5 + 0.2
	for s: float in [-1.0, 1.0]:
		var along_z := Vector3((APRON_HX - 1.5) * s, wy, APRON_CZ)
		var along_x := Vector3(0.0, wy, APRON_CZ + (APRON_HZ - 1.5) * s)
		_kit.box(body, along_z, Vector3(0.5, wh, APRON_HZ), _kit.concrete(), _CONCRETE)
		_kit.box(body, along_x, Vector3(APRON_HX, wh, 0.5), _kit.concrete(), _CONCRETE)


func _console_pad(parent: Node3D) -> void:
	var body: StaticBody3D = _kit.static_body(parent, "ConsolePad")
	var half := Vector3(PAD_HX, PAD_TOP * 0.5 + 0.15, PAD_HZ)
	var at := Vector3(0.0, PAD_TOP * 0.5 - 0.15, PAD_CZ)
	_kit.box(body, at, half, Palette.WORLD_CONCRETE[3], _CONCRETE)

	# The overlook. Deeper than the apron is wide at the back and sunk into it, so
	# the two share no plane.
	var deck_h := Vector3(DECK_HX, (DECK_TOP - PAD_TOP) * 0.5 + 0.20, DECK_HZ)
	var deck_c := Vector3(0.0, (DECK_TOP + PAD_TOP) * 0.5 - 0.20, DECK_CZ)
	_kit.box(body, deck_c, deck_h, Palette.WORLD_CONCRETE[2], _CONCRETE)
	# A ramp off each end, out at the rim of vision where it costs the shot nothing.
	var rise: float = atan2(DECK_TOP - PAD_TOP, DECK_RAMP_RUN)
	for s: float in [-1.0, 1.0]:
		var foot := Vector3((DECK_HX + DECK_RAMP_RUN) * s, PAD_TOP, DECK_CZ)
		var yaw: float = 0.0 if s < 0.0 else PI
		var pale: Color = _kit.concrete()
		_kit.ramp(body, foot, rise, DECK_RAMP_RUN, 2.4, 0.35, pale, _CONCRETE, _TOE, yaw)
	# Kerb along the lip, broken in the middle. It is the bottom edge of the shot —
	# without it the near third of frame is bare apron — and it is deliberately only
	# 22 cm proud: anything taller reaches up the frame far enough to bury the very
	# slider rows the demo exists to show.
	for s: float in [-1.0, 1.0]:
		var rail := Vector3(4.3 * s, DECK_TOP - 0.06, DECK_CZ - DECK_HZ)
		_kit.box(body, rail, Vector3(2.7, 0.28, 0.14), _kit.concrete(), _CONCRETE)
	_bench_clutter(body)
	# The one instruction on the course, painted where you are already looking down.
	var top: float = DECK_TOP + 0.02
	_kit.stencil(parent, "SHOOT OR PRESS E", Vector3(0.0, top, 15.0), 0.0, 0.26, _PALE, RANGE_SIGN)


## What a bench that has been worked at looks like. Seven boxes on the apron in the
## four-to-seven metre band, which is the part of the frame a first-person camera
## always fills with floor and which is empty in every shot that has nothing there.
func _bench_clutter(body: StaticBody3D) -> void:
	# x, z, half-extents, yaw, and the height its underside stands at above the
	# apron — 0 for everything on the deck, 0.80 for the one crate on the stack.
	var crates: Array = [
		[-4.60, 12.20, Vector3(0.62, 0.44, 0.52), 0.22, 0.0],
		[-4.72, 12.06, Vector3(0.36, 0.30, 0.34), -0.30, 0.80],
		[-6.20, 10.80, Vector3(0.95, 0.32, 0.42), 0.09, 0.0],
		[-2.90, 13.00, Vector3(0.32, 0.46, 0.32), 0.41, 0.0],
		[3.60, 12.60, Vector3(0.70, 0.38, 0.55), -0.14, 0.0],
		[5.10, 11.60, Vector3(0.30, 0.44, 0.30), 0.0, 0.0],
		[5.62, 12.24, Vector3(0.30, 0.44, 0.30), 0.55, 0.0],
	]
	for crate: Array in crates:
		var half: Vector3 = crate[2]
		var at := Vector3(float(crate[0]), PAD_TOP + float(crate[4]) + half.y, float(crate[1]))
		# Drums keep the metal surface; the crates are read as timber, which is what
		# stops a 60 cm box four metres from the lens blowing out under a low sun.
		var drum: bool = half.x < 0.35
		var col: Color = _kit.steel() if drum else _kit.rusty()
		_kit.box(body, at, half, col, _METAL if drum else _CONCRETE, float(crate[3]))


## Eleven blocks in a rank across the view, tops graded through every band the
## traversal code has, tallest inboard. The number lives on each block's SOUTH
## face — the one you are running at — because a figure painted flat on the deck is
## invisible from anywhere except standing on it, which is exactly too late.
func _ledge_bank(parent: Node3D) -> void:
	var body: StaticBody3D = _kit.static_body(parent, "LedgeBank")
	var n: int = LEDGE_HEIGHTS.size()
	var face_z: float = LEDGE_Z + LEDGE_HALF_Z
	for i: int in n:
		var h: float = LEDGE_HEIGHTS[i]
		var x: float = _ledge_x(i)
		var at := Vector3(x, (h - 0.3) * 0.5, LEDGE_Z)
		# Scrap plate, not concrete. Eleven pale blocks on a pale apron thirty metres
		# out are eleven blocks you cannot count; gunmetal against ash you can.
		var half := Vector3(LEDGE_HALF_X, (h + 0.3) * 0.5, LEDGE_HALF_Z)
		_kit.box(body, at, half, _kit.steel(), _METAL)
		# Hazard nose on the lip you are running at, sunk 1 cm into the block and
		# stopping 2 cm below its top so it cannot be what a height probe finds.
		var nose := Vector3(x, h - 0.10, face_z + 0.02)
		_kit.box(body, nose, Vector3(LEDGE_HALF_X - 0.05, 0.08, 0.035), _HOT, _METAL)
		# Text no taller than the block carries, so 0.20 m reads 0.20 m.
		var size: float = clampf(h * 0.50, 0.12, 0.38)
		var mark := Vector3(x, (h - 0.20) * 0.5, face_z + 0.05)
		_kit.plate(parent, "%.2f" % h, mark, 0.0, size, _PALE, RANGE_STENCIL)
	# The bands, on a banner slung above the bank on two posts: what you walk up,
	# what you hop, what the vault takes you over, and what you never reach. It
	# clears the tallest block by 30 cm, so you can run the whole rank under it.
	var bands: Array = [
		["STEP", 0, 2],
		["JUMP", 3, 5],
		["AUTO VAULT", 6, 6],
		["HOLD JUMP", 7, 8],
		["JUMP THEN VAULT", 9, 9],
		["NO", 10, 10],
	]
	_banner(body, _ledge_x(0), _ledge_x(n - 1), LEDGE_BANNER_Z, LEDGE_BANNER_LOW, LEDGE_BANNER_HIGH)
	var mid_y: float = (LEDGE_BANNER_LOW + LEDGE_BANNER_HIGH) * 0.5
	for band: Array in bands:
		var mid_x: float = (_ledge_x(int(band[1])) + _ledge_x(int(band[2]))) * 0.5
		var at := Vector3(mid_x, mid_y, LEDGE_BANNER_Z + 0.16)
		_kit.plate(parent, String(band[0]), at, 0.0, 0.52, _HOT, RANGE_SIGN)
	# West of the bank, not east: east of it is the aisle, and a sign in the aisle
	# is a sign standing in front of the tower the aisle is pointed at.
	var post := Vector3(_ledge_x(0) - 3.4, 0.0, LEDGE_Z + 3.2)
	_kit.sign_post(parent, body, post, 0.0, "LEDGE BANK", "TOP HEIGHT IN METRES")


## X of ledge `i`. The tallest sits at `LEDGE_INNER_X` and the rank runs out to -X.
func _ledge_x(i: int) -> float:
	return LEDGE_INNER_X - LEDGE_PITCH * float(LEDGE_HEIGHTS.size() - 1 - i)


## Nine lanes at one height with the gap in each one graded. Fall short and you
## land on the apron 1.2 m down, which is inside the auto vault — a miss costs you
## the run and nothing else.
func _gap_run(parent: Node3D) -> void:
	var body: StaticBody3D = _kit.static_body(parent, "GapRun")
	for j: int in GAP_DISTANCES.size():
		var d: float = GAP_DISTANCES[j]
		var x: float = _gap_x(j)
		var take_cz: float = GAP_TAKEOFF_Z - GAP_TAKEOFF_LEN * 0.5
		var land_far: float = GAP_TAKEOFF_Z - GAP_TAKEOFF_LEN - d - GAP_LANDING_LEN
		var land_cz: float = land_far + GAP_LANDING_LEN * 0.5
		_gap_pad(body, x, take_cz, GAP_TAKEOFF_LEN * 0.5)
		_gap_pad(body, x, land_cz, GAP_LANDING_LEN * 0.5)
		# Hazard nose on the take-off lip, and the distance under it.
		var nose := Vector3(x, GAP_TOP - 0.10, GAP_TAKEOFF_Z + 0.02)
		_kit.box(body, nose, Vector3(GAP_HALF_X - 0.05, 0.08, 0.035), _HOT, _METAL)
		var mark := Vector3(x, GAP_TOP * 0.5 - 0.08, GAP_TAKEOFF_Z + 0.05)
		_kit.plate(parent, "%.1f" % d, mark, 0.0, 0.46, _PALE, RANGE_STENCIL)
	# No ramp onto the take-offs, deliberately: their top is 1.20 m, inside
	# `mantle_auto_rise`, so the way on is to run at them.
	var east: float = _gap_x(0)
	var west: float = _gap_x(GAP_DISTANCES.size() - 1)
	var entry := Vector3((east + west) * 0.5, 0.02, GAP_TAKEOFF_Z + 2.6)
	_kit.stencil(parent, "1.20  VAULT ON", entry, 0.0, 0.55, _HOT, RANGE_STENCIL)
	# Alongside the run rather than at the head of it: at the head it lines up with
	# the ledge bank's sign forty metres behind and the two read as one board.
	var post := Vector3(west - 4.0, 0.0, GAP_TAKEOFF_Z - 4.5)
	_kit.sign_post(parent, body, post, 0.0, "GAP RUN", "CLEAR DISTANCE IN METRES")


## One pad: a deck on a narrower pier, so the void beside it reads as a void and
## the two boxes share no plane.
func _gap_pad(body: StaticBody3D, x: float, cz: float, half_z: float) -> void:
	var deck := Vector3(x, GAP_TOP - 0.18, cz)
	var pier := Vector3(x, 0.30, cz)
	_kit.box(body, deck, Vector3(GAP_HALF_X, 0.18, half_z), _kit.concrete(), _CONCRETE)
	_kit.box(body, pier, Vector3(GAP_HALF_X - 0.35, 0.62, half_z - 0.4), _kit.concrete(), _CONCRETE)


## X of lane `j`. Descending west to east: the 5.5 m lane reaches 12 m north and
## needs an empty yard behind it, and the slope fan is what is east of here.
func _gap_x(j: int) -> float:
	var span: float = GAP_LANE_PITCH * float(GAP_DISTANCES.size() - 1)
	return span * 0.5 - GAP_LANE_PITCH * float(j)


## Ten lanes, ten angles, climbing away from the bench. Ramps overlap by 0.3 m so
## no two flanks are coplanar, the decks butt, and each deck's south face sits
## exactly where its ramp's top face reaches height. The angle is painted on a
## backstop board at the head of the lane, which is the only face on a ramp that
## looks back at you.
func _slope_fan(parent: Node3D) -> void:
	var body: StaticBody3D = _kit.static_body(parent, "SlopeFan")
	for j: int in SLOPE_ANGLES.size():
		var deg: float = SLOPE_ANGLES[j]
		var a: float = deg_to_rad(deg)
		var run: float = _slope_run(deg)
		var rise: float = run * tan(a)
		var x: float = _slope_x(j)
		var foot := Vector3(x, 0.0, SLOPE_FOOT_Z)
		var pale: Color = _kit.concrete()
		_kit.ramp(body, foot, a, run, SLOPE_HALF_W, 0.32, pale, _CONCRETE, _LIP, PI * 0.5)
		var deck_z: float = SLOPE_FOOT_Z - run - 1.6
		var deck := Vector3(x, (rise - 0.3) * 0.5, deck_z)
		var deck_half := Vector3(SLOPE_LANE_PITCH * 0.5, (rise + 0.3) * 0.5, 1.6)
		_kit.box(body, deck, deck_half, _kit.concrete(), _CONCRETE)
		# Backstop: a board across the head of the lane, standing proud of the deck,
		# carrying the number where it can be read from the bench.
		var board_z: float = deck_z - 1.35
		var board := Vector3(x, rise + 0.75, board_z)
		_kit.box(
			body, board, Vector3(SLOPE_LANE_PITCH * 0.5 - 0.06, 0.75, 0.11), _kit.rusty(), _METAL
		)
		var col: Color = _HOT if deg >= 46.0 else _PALE
		var face: Vector3 = board + Vector3(0.0, 0.14, 0.12)
		_kit.plate(parent, "%d" % int(deg), face, 0.0, 0.72, col, RANGE_SIGN)
		if is_equal_approx(deg, 46.0):
			var under: Vector3 = board + Vector3(0.0, -0.50, 0.12)
			_kit.plate(parent, "LIMIT", under, 0.0, 0.30, _HOT, RANGE_SIGN)
	var post := Vector3(_slope_x(SLOPE_ANGLES.size() - 1) + 3.6, 0.0, SLOPE_FOOT_Z + 2.0)
	_kit.sign_post(parent, body, post, 0.0, "SLOPE FAN", "DEGREES — WALKABLE TO 46")


## Ramp length for one lane. Clamped, so the shallow end does not run out of yard.
func _slope_run(deg: float) -> float:
	return clampf(SLOPE_RISE / tan(deg_to_rad(deg)), 1.2, SLOPE_RUN_MAX)


## X of lane `j`. The steepest sits at `SLOPE_LANE_X0` and the fan opens toward +X.
func _slope_x(j: int) -> float:
	return SLOPE_LANE_X0 + SLOPE_LANE_PITCH * float(SLOPE_ANGLES.size() - 1 - j)


## Four flights at four rises, climbing away from the bench. Each step is a
## full-height slab overlapping its neighbour front and back, so a flight is one
## solid with no seam to catch on.
func _stair_bank(parent: Node3D) -> void:
	var body: StaticBody3D = _kit.static_body(parent, "StairBank")
	var tread: float = (STAIR_GOING + 0.06) * 0.5
	for f: int in STAIR_RISES.size():
		var rise: float = STAIR_RISES[f]
		var n: int = STAIR_COUNTS[f]
		var x: float = _stair_x(f)
		for i: int in range(1, n + 1):
			var top: float = rise * float(i)
			var front: float = STAIR_Z0 - STAIR_GOING * float(i - 1)
			var at := Vector3(x, (top - 0.3) * 0.5, front - tread)
			var half := Vector3(STAIR_HALF_X, (top + 0.3) * 0.5, tread)
			_kit.box(body, at, half, _kit.concrete(), _CONCRETE)
		var total: float = rise * float(n)
		var deck_z: float = STAIR_Z0 - STAIR_GOING * float(n) - 1.5
		var deck := Vector3(x, (total - 0.3) * 0.5, deck_z)
		_kit.box(
			body, deck, Vector3(STAIR_HALF_X, (total + 0.3) * 0.5, 1.6), _kit.concrete(), _CONCRETE
		)
		# Same backstop trick as the slope fan: the landing gets a board, and the
		# board gets the number, because it is the face that looks back at you.
		var board := Vector3(x, total + 0.70, deck_z - 1.35)
		_kit.box(body, board, Vector3(STAIR_HALF_X - 0.06, 0.70, 0.11), _kit.rusty(), _METAL)
		_kit.plate(
			parent, "%.2f" % rise, board + Vector3(0.0, 0.06, 0.12), 0.0, 0.62, _PALE, RANGE_SIGN
		)
	var post := Vector3(_stair_x(0) - 3.4, 0.0, STAIR_Z0 + 3.4)
	_kit.sign_post(parent, body, post, 0.0, "STAIR BANK", "RISE PER STEP IN METRES")


func _stair_x(f: int) -> float:
	return STAIR_X0 + STAIR_PITCH * float(f)


## A banner on two posts: the panel spans `lo_x`..`hi_x` and floats between `low`
## and `high`, so it carries text at a distance without walling anything off. Both
## posts sit outboard of the run it names and the panel overhangs them, so nothing
## in it shares a plane with anything else.
func _banner(
	body: StaticBody3D, lo_x: float, hi_x: float, z: float, low: float, high: float
) -> void:
	var cx: float = (lo_x + hi_x) * 0.5
	var half_x: float = (hi_x - lo_x) * 0.5 + 1.6
	var mid: float = (low + high) * 0.5
	for s: float in [-1.0, 1.0]:
		var post := Vector3(cx + (half_x - 0.55) * s, (high - 0.4) * 0.5, z)
		_kit.box(body, post, Vector3(0.16, (high + 0.4) * 0.5, 0.16), _kit.steel(), _METAL)
	var panel := Vector3(half_x, (high - low) * 0.5, 0.13)
	_kit.box(body, Vector3(cx, mid, z), panel, _kit.rusty(), _METAL)


## Three ladders, three decks, one nine-metre drop. The climb face is the SOUTH
## one, so the ladders are what you see down the middle of the yard; the decks run
## north behind the wall. The decks stop 0.55 m short of the rung plane; that
## clearance is what keeps the climber's 0.34 m radius off the deck edge on the way
## past it.
func _ladder_tower(parent: Node3D) -> void:
	var body: StaticBody3D = _kit.static_body(parent, "LadderTower")
	var top: float = TOWER_DECKS[TOWER_DECKS.size() - 1]
	var stack_y: float = (top + 0.4) * 0.5 - 0.15
	var stack_h: float = (top + 0.7) * 0.5 + 0.05
	# The ladder wall is wider than the decks it meets, so the two share no plane.
	var wall := Vector3(TOWER_X, stack_y, TOWER_WALL_Z - 0.15)
	_kit.box(body, wall, Vector3(2.6, stack_h, 0.15), _kit.concrete(), _CONCRETE)
	for s: float in [-1.0, 1.0]:
		for t: float in [TOWER_WALL_Z - 1.15, TOWER_WALL_Z - 5.55]:
			var pier := Vector3(TOWER_X + 2.1 * s, stack_y, t)
			_kit.box(body, pier, Vector3(0.22, stack_h, 0.22), _kit.steel(), _METAL)
	var z0: float = TOWER_WALL_Z - 0.10
	var hz: float = (z0 - TOWER_DECK_BACK) * 0.5
	var cz: float = (TOWER_DECK_BACK + z0) * 0.5
	for d: int in TOWER_DECKS.size():
		var y: float = TOWER_DECKS[d]
		_kit.box(body, Vector3(TOWER_X, y - 0.2, cz), Vector3(2.5, 0.2, hz), _kit.tin(), _TIN)
		# Kerbs sunk into the deck rather than resting on it, and inset from its
		# edges. Nothing about them is coplanar with the slab they sit in.
		for s: float in [-1.0, 1.0]:
			var side := Vector3(TOWER_X + 2.35 * s, y + 0.06, cz + 0.1)
			_kit.box(body, side, Vector3(0.12, 0.20, hz - 0.15), _kit.steel(), _METAL)
		var back := Vector3(TOWER_X, y + 0.06, TOWER_DECK_BACK + 0.14)
		_kit.box(body, back, Vector3(2.35, 0.20, 0.12), _kit.steel(), _METAL)
		# On the wall beside the rungs, at the height it names, facing the bench.
		var mark := Vector3(TOWER_X + 1.55, y - 0.55, TOWER_WALL_Z + 0.04)
		_kit.plate(parent, "%.1f M" % y, mark, 0.0, 0.62, _PALE, RANGE_SIGN)
	var warn := Vector3(TOWER_X - 1.35, top + 0.55, TOWER_WALL_Z + 0.04)
	_kit.plate(parent, "HARD\nLANDING\nOVER 8.5", warn, 0.0, 0.34, _HOT, RANGE_SIGN)
	_tower_ladders(parent)
	var post := Vector3(TOWER_X + 4.6, 0.0, TOWER_WALL_Z + 3.4)
	_kit.sign_post(parent, body, post, 0.0, "LADDER TOWER", "3 / 6 / 9 METRES")


## Rails, rungs and the climb volumes that go with them. The volume's origin sits
## 0.45 m proud of the wall face because `PlayerLadder` springs the body to a fixed
## 0.20 m stand-off from that origin and the body carries 0.34 m of radius: any
## closer and the climber's back is inside the wall.
func _tower_ladders(parent: Node3D) -> void:
	var rung_z: float = TOWER_WALL_Z + 0.21
	var origin_z: float = TOWER_WALL_Z + 0.45
	var script: Script = load(SCRIPT_LADDER)
	for d: int in TOWER_DECKS.size():
		var y0: float = 0.0 if d == 0 else TOWER_DECKS[d - 1]
		var climb: float = TOWER_DECKS[d] - y0 + 0.30
		for s: float in [-1.0, 1.0]:
			var x: float = TOWER_X + 0.36 * s
			var rail_col: Color = _kit.rusty()
			_kit.rung(
				Vector3(x, y0 + 0.05, rung_z),
				Vector3(x, y0 + climb, rung_z),
				0.035,
				rail_col,
				_METAL
			)
		# A flight is carried 0.30 m past its deck so the climber has a rung to pull
		# on level with the lip — which is exactly where the flight above wants its
		# first rung. Whoever gets there first owns it: flights after the ground one
		# start a rung up, or the two land in the same cubic centimetre and z-fight.
		var first_rung: int = 1 if d == 0 else 2
		var rung_count: int = int(floor(climb / TOWER_RUNG_SPACING + 0.001))
		for r: int in range(first_rung, rung_count + 1):
			var ry: float = y0 + TOWER_RUNG_SPACING * float(r)
			var a := Vector3(TOWER_X - 0.36, ry, rung_z + 0.02)
			var b := Vector3(TOWER_X + 0.36, ry, rung_z + 0.02)
			_kit.rung(a, b, 0.030, _kit.rusty(), _METAL)
		var ladder: Node3D = script.new()
		ladder.name = "Ladder%d" % d
		ladder.position = Vector3(TOWER_X, y0, origin_z)
		# Local +Z points away from the wall, which here is world +Z — the bench side.
		ladder.set(&"half_width", 0.78)
		ladder.set(&"reach", 0.95)
		ladder.set(&"climb_height", climb)
		ladder.set(&"surface", _METAL)
		parent.add_child(ladder)


## Run-up, drop, and a roof low enough that standing is not on the menu. The whole
## run is laid along -Z down the east flank so the three roofs recede one behind
## the other instead of forming a wall across the yard.
func _slide_run(parent: Node3D) -> void:
	var body: StaticBody3D = _kit.static_body(parent, "SlideRun")
	var wide: float = TUNNEL_HALF_W + 0.15
	var up: float = atan2(TUNNEL_DECK_TOP, SLIDE_UP_RUN)
	var foot := Vector3(SLIDE_X, 0.0, SLIDE_Z0)
	var pale: Color = _kit.concrete()
	_kit.ramp(body, foot, up, SLIDE_UP_RUN, wide, 0.35, pale, _CONCRETE, _LIP, PI * 0.5)
	var deck_z: float = SLIDE_Z0 - SLIDE_UP_RUN - SLIDE_DECK_LEN * 0.5
	var deck := Vector3(SLIDE_X, (TUNNEL_DECK_TOP - 0.3) * 0.5, deck_z)
	var deck_h := Vector3(TUNNEL_HALF_W, (TUNNEL_DECK_TOP + 0.3) * 0.5, SLIDE_DECK_LEN * 0.5)
	_kit.box(body, deck, deck_h, _kit.concrete(), _CONCRETE)
	# The drop that pays for the slide: eight metres of 23-degree descent turns a
	# sprint into well past `slide_entry_speed`. It starts 0.2 m inside the deck, so
	# the crest is a 6 cm lip and not a coplanar seam.
	var crest_z: float = deck_z - SLIDE_DECK_LEN * 0.5 + 0.2
	var crest := Vector3(SLIDE_X, TUNNEL_DECK_TOP, crest_z)
	var down: float = -atan2(TUNNEL_DECK_TOP, SLIDE_DOWN_RUN)
	var drop: Color = _kit.concrete()
	_kit.ramp(
		body, crest, down, SLIDE_DOWN_RUN, wide, 0.35, drop, _CONCRETE, Vector2.ZERO, PI * 0.5
	)
	var mouth: float = crest_z - SLIDE_DOWN_RUN
	var length: float = TUNNEL_SECTION * float(TUNNEL_CLEARANCES.size())
	for s: float in [-1.0, 1.0]:
		var side := Vector3(SLIDE_X + (TUNNEL_HALF_W + 0.35) * s, 1.3, mouth - length * 0.5)
		_kit.box(body, side, Vector3(0.35, 1.6, length * 0.5), _kit.concrete(), _CONCRETE)
	for c: int in TUNNEL_CLEARANCES.size():
		var clear: float = TUNNEL_CLEARANCES[c]
		var mid: float = mouth - TUNNEL_SECTION * (float(c) + 0.5)
		var roof := Vector3(SLIDE_X, clear + 0.30, mid)
		var roof_h := Vector3(TUNNEL_HALF_W + 0.4, 0.30, TUNNEL_SECTION * 0.5 + 0.15)
		_kit.box(body, roof, roof_h, _kit.tin(), _TIN)
		# On the roof slab's own south face, which is the lintel you are about to
		# fail to clear standing up.
		var mark := Vector3(SLIDE_X, clear + 0.30, mid + TUNNEL_SECTION * 0.5 + 0.18)
		_kit.plate(parent, "%.2f" % clear, mark, 0.0, 0.44, _PALE, RANGE_SIGN)
	var post := Vector3(SLIDE_X - 4.4, 0.0, SLIDE_Z0 - 1.2)
	_kit.sign_post(parent, body, post, 0.0, "SLIDE RUN", "ROOF CLEARANCE IN METRES")


# ------------------------------------------------------------------- console


## The tuning bank: six desks in one rank facing the spawn, split around a centre
## aisle, wired at load by `MovementConsole`.
##
## It used to be a hexagon around the master column, which meant three of the six
## desks were behind your head at all times and the other three were seen edge-on.
## A rank costs nothing, keeps every knob in front of you, and leaves the middle of
## the frame clear for the thing you are tuning against.
func _console(root: Node3D) -> Node3D:
	var console := Node3D.new()
	console.name = "Console"
	console.set_script(load(SCRIPT_CONSOLE))
	console.set(&"player_path", NodePath("../Player"))
	root.add_child(console)

	var frame: StaticBody3D = _kit.static_body(console, "Frame")
	var desks := Node3D.new()
	desks.name = "Desks"
	console.add_child(desks)

	var slider_scene: PackedScene = load(SLIDER_SCENE)
	for k: int in MovementTuning.DESK_NAMES.size():
		_desk(desks, frame, k, slider_scene)
	var readout: Node3D = _column(console, frame)
	console.set(&"readout_path", console.get_path_to(readout))
	return console


func _desk(parent: Node3D, frame: StaticBody3D, index: int, slider_scene: PackedScene) -> void:
	# Every desk faces the spawn, so its frame is the world's: +X along the top,
	# +Z out toward the reader.
	var yaw: float = 0.0
	var at := Vector3(DESK_OFFSETS[index], PAD_TOP, DESK_Z)
	var flat := Basis.IDENTITY
	# Tilting about the desk's local X leans the top toward whoever is standing at
	# it, which is the only reason a slider on it is readable at all.
	var top: Basis = flat * Basis(Vector3.RIGHT, DESK_TILT)
	var slab: Vector3 = at + Vector3(0.0, DESK_HEIGHT, 0.0)

	_kit.solid(frame, slab, top, Vector3(DESK_HALF_X, 0.055, 0.42), _kit.steel(), _METAL)
	for s: float in [-1.0, 1.0]:
		var leg: Vector3 = at + flat.x * ((DESK_HALF_X - 0.25) * s) + Vector3(0.0, 0.22, 0.0)
		var stay: Vector3 = (
			at + flat.x * ((DESK_HALF_X - 0.20) * s) + flat.z * -0.50 + Vector3(0.0, 0.55, 0.0)
		)
		_kit.box(frame, leg, Vector3(0.10, 0.40, 0.10), _kit.steel(), _METAL, yaw)
		_kit.box(frame, stay, Vector3(0.07, 0.60, 0.07), _kit.steel(), _METAL, yaw)
	var board: Vector3 = at + flat.z * -0.50 + Vector3(0.0, 0.95, 0.0)
	_kit.box(frame, board, Vector3(DESK_HALF_X, 0.30, 0.06), _kit.rusty(), _METAL, yaw)
	var name_at: Vector3 = board + flat.z * 0.08
	_kit.plate(parent, MovementTuning.DESK_NAMES[index], name_at, yaw, 0.40, _HOT, RANGE_SIGN)

	# One rank of six at the shipped pitch for five desks, byte-identical to before.
	# SLIDE carries fourteen in two ranks: the slide is the deep part of the controller
	# and widening the desk instead would run it into its neighbour 3.7 m away.
	var rows: Array[Dictionary] = MovementTuning.rows_for_desk(index)
	var ranks: int = maxi(1, MovementTuning.DESK_RANKS[index])
	var per_rank: int = maxi(1, rows.size() / ranks)
	var pitch: float = MovementTuning.DESK_PITCH[index]
	var span: float = pitch * float(per_rank - 1)
	for i: int in rows.size():
		var row: Dictionary = rows[i]
		var id: StringName = row[MovementTuning.KEY_ID]
		var offset: float = -span * 0.5 + pitch * float(i % per_rank)
		# Ranks straddle the desk's centre line along its depth, so a one-rank desk
		# lands exactly where it did and a two-rank desk is symmetric about it.
		var depth: float = (
			(float(i / per_rank) - float(ranks - 1) * 0.5) * MovementTuning.DESK_RANK_GAP
		)
		var slider: Node3D = slider_scene.instantiate()
		slider.name = "Slider_%s" % id
		# The slider's face is its local +Z, so its Z becomes the desk top's normal
		# and its Y runs up the slope of the desk. (x, -z, y) of the top basis is
		# right-handed; the obvious (x, z, y) is not, and mirrors every knob.
		var frame_basis := Basis(top.x, -top.z, top.y)
		var at_slider: Vector3 = slab + top.x * offset + top.y * 0.09 + top.z * depth
		slider.transform = Transform3D(frame_basis, at_slider)
		slider.set(&"control_id", id)
		slider.set(&"label_text", String(row[MovementTuning.KEY_LABEL]))
		slider.set(&"min_value", float(row[MovementTuning.KEY_LOW]))
		slider.set(&"max_value", float(row[MovementTuning.KEY_HIGH]))
		slider.set(&"step", float(row[MovementTuning.KEY_STEP]))
		slider.set(&"value_format", String(row[MovementTuning.KEY_FORMAT]))
		parent.add_child(slider)
		_dress(slider, 0.0021)


## The master column and the gantry over it: preset dial, reset cap, slow-motion
## lever and the screen. Pedestal, shelf, back plate, posts and head beam each overlap
## the one below and differ from it on every axis, so the column is one solid with no
## shared plane in it. THE SCREEN HANGS OFF THE FRAME, NOT OFF NOTHING: it used to sit
## on a 10 cm bracket a metre and a half up, which reads as a panel in the sky.
func _column(console: Node3D, frame: StaticBody3D) -> Node3D:
	var back_z: float = MASTER_Z - 0.30
	var pedestal := Vector3(0.0, PAD_TOP + 0.30, MASTER_Z)
	var shelf := Vector3(0.0, PAD_TOP + 0.79, MASTER_Z)
	var back_plate := Vector3(0.0, PAD_TOP + 1.14, back_z)
	_kit.box(frame, pedestal, Vector3(0.70, 0.45, 0.38), _kit.steel(), _METAL)
	_kit.box(frame, shelf, Vector3(0.78, 0.055, 0.44), _kit.steel(), _METAL)
	_kit.box(frame, back_plate, Vector3(0.74, 0.34, 0.07), _kit.rusty(), _METAL)
	for s: float in [-1.0, 1.0]:
		var post := Vector3(GANTRY_HALF_X * s, (GANTRY_TOP - 0.3) * 0.5, back_z)
		_kit.box(frame, post, Vector3(0.13, (GANTRY_TOP + 0.3) * 0.5, 0.13), _kit.steel(), _METAL)
		# Corner brace on the diagonal: a stub reads as a mistake, a gusset as welded.
		var knee := Vector3((GANTRY_HALF_X - 0.46) * s, GANTRY_TOP - 0.76, back_z + 0.02)
		var lean: float = PI * 0.25 if s < 0.0 else PI * 0.75
		var gusset := Basis(Vector3.BACK, lean)
		_kit.solid(frame, knee, gusset, Vector3(0.60, 0.07, 0.08), _kit.rusty(), _METAL)
	# Head beam: wider than the posts, shallower than them, and stopping short of
	# their tops, so it lands inside the frame on all three axes.
	var beam := Vector3(0.0, GANTRY_TOP - 0.22, back_z)
	_kit.box(frame, beam, Vector3(GANTRY_HALF_X + 0.30, 0.20, 0.11), _kit.rusty(), _METAL)
	# Two hangers from the beam down to the top of the screen.
	var hang_at := Vector3(0.0, GANTRY_TOP - 0.60, back_z - 0.05)
	for s: float in [-1.0, 1.0]:
		var hang: Vector3 = hang_at + Vector3(0.44 * s, 0.0, 0.0)
		_kit.box(frame, hang, Vector3(0.045, 0.30, 0.045), _kit.steel(), _METAL)

	var dial: Node3D = (load(DIAL_SCENE) as PackedScene).instantiate()
	dial.name = "Preset"
	dial.position = Vector3(-0.36, PAD_TOP + 1.14, back_z + 0.085)
	dial.set(&"control_id", MovementTuning.ID_PRESET)
	dial.set(&"label_text", "PRESET")
	dial.set(&"options", MovementTuning.PRESET_NAMES)
	dial.set(&"wraps", false)
	console.add_child(dial)
	_dress(dial, 0.0016)

	var reset: Node3D = (load(BUTTON_SCENE) as PackedScene).instantiate()
	reset.name = "Reset"
	reset.position = Vector3(0.36, PAD_TOP + 1.14, back_z + 0.085)
	reset.set(&"control_id", MovementTuning.ID_RESET)
	reset.set(&"label_text", "RESET")
	console.add_child(reset)
	_dress(reset, 0.0016)

	var lever: Node3D = (load(LEVER_SCENE) as PackedScene).instantiate()
	lever.name = "SlowMotion"
	lever.position = Vector3(0.40, PAD_TOP + 0.845, MASTER_Z + 0.06)
	lever.set(&"control_id", MovementTuning.ID_SLOWMO)
	lever.set(&"label_text", "SLOW")
	lever.set(&"off_text", "1.00x")
	lever.set(&"on_text", "0.32x")
	console.add_child(lever)
	_dress(lever, 0.0016)

	var readout: Node3D = (load(READOUT_SCENE) as PackedScene).instantiate()
	readout.name = "Readout"
	# Tilted DOWN toward the reader, and HUNG rather than seated: the hangers reach down
	# to meet its top edge, so `PanelMount` proves the clearance instead of solving a
	# standoff that would leave them in mid-air. The lean swings the panel's foot
	# 176 mm back at this scale, which is what the check is for.
	var lean := Basis(Vector3.RIGHT, 0.16).scaled(Vector3.ONE * READOUT_SCALE)
	readout.transform = Transform3D(lean, Vector3(0.0, READOUT_Y, back_z + 0.10))
	readout.set(&"glow", 1.9)
	console.add_child(readout)
	var hangers: AABB = PanelMount.half_box(hang_at, Vector3(0.485, 0.30, 0.045))
	PanelMount.new().hang(readout, hangers, "GantryHangers")

	# Painted on the head beam itself, which is where a yard paints its own name.
	var name_at: Vector3 = beam + Vector3(0.0, 0.0, 0.13)
	_kit.plate(console, "MOVEMENT BENCH", name_at, 0.0, 0.30, _HOT, RANGE_SIGN)
	return readout


## Per-instance dressing a baked control scene cannot carry: label scale and range.
func _dress(control: Node3D, label_pixel_size: float) -> void:
	for key: String in ["Label", "Readout", "State"]:
		var text := control.get_node_or_null(NodePath(key)) as Label3D
		if text != null:
			text.pixel_size = label_pixel_size
	CourseKit.set_draw_range(control, RANGE_SLIDER)


# ---------------------------------------------------------------- speed loop


## Five arches and the clock that reads them. Only the posts collide; the opening
## between them is genuinely open and the trigger volume fills it. Each arch carries a
## marker lamp and a flare on its lintel; the clock lights exactly one of them.
func _loop(root: Node3D) -> Node:
	var loop := Node3D.new()
	loop.name = "SpeedLoop"
	root.add_child(loop)

	var body: StaticBody3D = _kit.static_body(loop, "Arches")
	var script: Script = load(SCRIPT_GATE)
	var n: int = GATE_POSITIONS.size()
	for i: int in n:
		var at: Vector3 = GATE_POSITIONS[i]
		var run: Vector3 = at - GATE_POSITIONS[(i - 1 + n) % n]
		# Heading such that a runner arriving from the previous gate is looking at
		# the board. Yaw 0 faces -Z, hence the reversed direction.
		var heading: float = atan2(-run.x, -run.z)
		var b := Basis(Vector3.UP, heading)
		for s: float in [-1.0, 1.0]:
			var post: Vector3 = at + b.x * (2.2 * s) + Vector3(0.0, 1.45, 0.0)
			_kit.box(body, post, Vector3(0.18, 1.75, 0.18), _kit.rusty(), _METAL, heading)
		# Narrower than the posts' outer faces and deeper than them, so the lintel
		# lands inside both and shares no plane with either.
		var lintel: Vector3 = at + Vector3(0.0, GATE_LINTEL_Y, 0.0)
		_kit.box(body, lintel, GATE_LINTEL, _kit.rusty(), _METAL, heading)
		_gate(loop, script, i, Transform3D(b, at))
	var timer: Node = load(SCRIPT_TIMER).new()
	timer.name = "RunTimer"
	loop.add_child(timer)
	return timer


func _gate(loop: Node3D, script: Script, index: int, pose: Transform3D) -> void:
	var gate: Area3D = script.new()
	gate.name = "Gate%d" % index
	gate.transform = pose
	gate.set(&"gate_index", index)
	gate.set(&"gate_name", GATE_NAMES[index])
	gate.set(&"pass_sound", _pass_sound)
	gate.set(&"lap_sound", _lap_sound)
	loop.add_child(gate)
	gate.add_child(CourseMarks.sound_node())
	CourseMarks.beacon(gate, _holo, GATE_LINTEL_Y + GATE_LINTEL.y)

	var shape := BoxShape3D.new()
	shape.size = Vector3(4.4, 2.9, 0.7)
	var hit := CollisionShape3D.new()
	hit.name = "Hit"
	hit.shape = shape
	hit.position = Vector3(0.0, 1.45, 0.0)
	gate.add_child(hit)

	var board: Label3D = _kit.label(
		gate,
		"%s\n- - . - -" % GATE_NAMES[index],
		Vector3(0.0, GATE_LINTEL_Y, GATE_LINTEL.z + 0.004),
		0.26,
		Palette.GOLD,
		RANGE_SIGN
	)
	board.name = "Board"


func _interactor(root: Node3D) -> void:
	var hands := Node3D.new()
	hands.name = "Hands"
	hands.set_script(load(SCRIPT_INTERACTOR))
	hands.set(&"eye_path", NodePath("../Player/Eye"))
	root.add_child(hands)


# ----------------------------------------------------------------- reporting


## Every assertion worth making about this bake, printed. The tuning table is
## checked against the ACTUAL baked player, so a renamed export on the controller
## fails the build instead of shipping a desk of dead knobs.
func _report(mesh: ArrayMesh, player: Node) -> void:
	var problems: PackedStringArray = MovementTuning.verify(player)
	for line: String in problems:
		push_error("build_movement: %s" % line)
	var verts: int = 0
	if mesh.get_surface_count() > 0:
		verts = mesh.surface_get_array_len(0)
	print("build_movement: %s, %d vertices" % [_kit.report(), verts])
	var counted: int = MovementTuning.rows().size()
	print(
		(
			"build_movement: %d labels, %d tuning rows, %d problems"
			% [_kit.labels, counted, problems.size()]
		)
	)
	print("build_movement: baked %s" % SCENE_PATH)
