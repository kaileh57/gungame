extends SceneTree
## Bakes `res://demos/bestiary/bestiary.tscn`. Run headless with
## `--script res://tools/build_bestiary.gd`.
##
## A hall thirty-four metres long, three bays deep — scav, machine, mutant — with
## twelve plinths under a lamp gantry and a desk at each end. Every solid is a
## closed box or cylinder and every joint is an OVERLAP: the lamp stem sinks into
## its beam, the placard post into its plinth, the desk panels into each other. A
## union of watertight convex shells cannot open a seam. Each distinct shell is
## checked for positive volume, zero boundary edges and no degenerate triangles.
##
## The creatures are not rebuilt. `res://data/enemies/<id>.res` already holds a
## welded, joint-audited skinned shell per species; this file lifts the `Body`
## subtree out of each, swaps `EnemyBody` for `ExhibitBody` so the rack can run
## the pose clock slow, and re-bakes it to `species/<id>.scn`. Nothing here
## authors a vertex of a creature and nothing re-derives a stat.
##
## `_process`, not `_initialize`: a `--script` main loop is built before the
## autoloads `bestiary_hall.gd` names exist. By the first idle frame they do,
## which is why every script here is `load`ed by path.

const OUT_SCENE: String = "res://demos/bestiary/bestiary.tscn"
const OUT_REPORT: String = "res://demos/bestiary/build_report.txt"

const HALL_SCRIPT: String = "res://demos/bestiary/bestiary_hall.gd"
const BODY_SCRIPT: String = "res://demos/bestiary/exhibit_body.gd"
const WORLD_SCENE: String = "res://art/scav_world.tscn"
const PLAYER_SCENE: String = "res://data/player/player.tscn"
const ENEMY_DIR: String = "res://data/enemies"
const SPECIES_DIR: String = "res://demos/bestiary/species"

const READOUT_SCENE: String = "res://ui/diegetic/diegetic_readout.tscn"
const BUTTON_SCENE: String = "res://ui/diegetic/diegetic_button.tscn"
const DIAL_SCENE: String = "res://ui/diegetic/diegetic_dial.tscn"
const LEVER_SCENE: String = "res://ui/diegetic/diegetic_lever.tscn"
const SLIDER_SCENE: String = "res://ui/diegetic/diegetic_slider.tscn"

const MAT_STEEL: String = "res://art/materials/scrap_steel.tres"
const MAT_TIMBER: String = "res://art/materials/scrap_timber.tres"
const MAT_POLYMER: String = "res://art/materials/scrap_polymer.tres"
const MAT_CANVAS: String = "res://art/materials/scrap_canvas.tres"
const MAT_EMBER: String = "res://art/materials/glow_ember.tres"

# --- the hall ---------------------------------------------------------------

## Deck slab. Its top surface is y = 0 and every height in the room is measured
## off that, so a plinth height is a plinth height and not a plinth plus a floor.
const DECK: Vector3 = Vector3(16.0, 0.70, 34.0)
## Parapet. It reaches below the deck top so wall and floor overlap.
const WALL_SIZE_SIDE: Vector3 = Vector3(0.44, 1.35, 34.0)
const WALL_SIZE_END: Vector3 = Vector3(16.0, 1.35, 0.44)
const WALL_X: float = 7.78
const WALL_Z: float = 16.78
const WALL_Y: float = 0.475

## Plinth rows either side of a six-metre walkway.
const PLINTH_X: float = 4.3
## Bay centres, in roster class order: scav, machine, mutant.
const BAY_Z: PackedFloat32Array = [8.5, 0.0, -8.5]
## Plinth offset fore and aft of its bay centre.
const PLINTH_DZ: float = 2.1
const PLINTH_BASE: Vector3 = Vector3(2.44, 0.12, 2.44)
const PLINTH_BODY: Vector3 = Vector3(2.24, 0.34, 2.24)
## Plinth top, which is the floor every creature stands on.
const PLINTH_TOP: float = 0.34

const GANTRY_Y: float = 4.80
const RAIL_SIZE: Vector3 = Vector3(0.24, 0.32, 30.0)
const RAIL_X: float = 6.6
const CROSS_SIZE: Vector3 = Vector3(13.8, 0.26, 0.24)
## A cross beam over every plinth row and every bay centre: six carry lamps,
## three carry bay signs.
const CROSS_Z: PackedFloat32Array = [10.6, 8.5, 6.4, 2.1, 0.0, -2.1, -6.4, -8.5, -10.6]
const LEG_SIZE: Vector3 = Vector3(0.24, 4.96, 0.24)
const LEG_Z: PackedFloat32Array = [12.6, 0.0, -12.6]

const LAMP_STEM_R: float = 0.05
const LAMP_STEM_H: float = 0.62
const LAMP_STEM_Y: float = 4.44
const LAMP_SHADE_R: float = 0.21
const LAMP_SHADE_H: float = 0.17
const LAMP_SHADE_Y: float = 4.08
const LAMP_BULB_R: float = 0.10
const LAMP_BULB_H: float = 0.07
const LAMP_BULB_Y: float = 4.03

## Placard mount. It stands on the walkway-side corner nearest the entrance and
## faces up the walkway at forty-five degrees — readable on approach, out of the
## creature's silhouette once you are level with it.
const PLACARD_OFFSET: float = 0.92
## Waist height and steeply raked, like a museum label. Chest height put a
## half-metre screen across the exhibit it was describing.
##
## THE STAND RAKES WITH THE SCREEN. It used to stand upright while the screen was
## pitched 34 degrees and pushed out by a hand-picked 90 mm; that rake swings the
## screen's top-back corner 117 mm backwards, into a stand 110 mm deep and out
## through the far side of it. A backing plate sharing the rake is square with the
## screen in one frame, which is the frame `PanelMount` seats it in.
const PLACARD_POST: Vector3 = Vector3(0.13, 0.62, 0.13)
const PLACARD_POST_Y: float = 0.21
const PLACARD_STAND: Vector3 = Vector3(0.68, 0.32, 0.11)
const PLACARD_STAND_Y: float = 0.58
const PLACARD_PITCH_DEG: float = -34.0

const SIGN_PLATE: Vector3 = Vector3(2.0, 0.50, 0.09)
const SIGN_Y: float = 4.10
const SIGN_ROD_R: float = 0.03
const SIGN_ROD_H: float = 0.56
const SIGN_ROD_Y: float = 4.60
const SIGN_ROD_X: float = 0.70

const GATE_Z: float = 16.4
const GATE_POST: Vector3 = Vector3(0.18, 2.95, 0.18)
const GATE_POST_X: float = 2.2
const GATE_PLATE: Vector3 = Vector3(5.2, 0.95, 0.14)
const GATE_PLATE_Y: float = 2.45
const GATE_TEXT: String = "BESTIARY"
const GATE_SUB: String = "TWELVE SPECIES. NONE OF THEM FRIENDLY."

## Desks at both ends of the walkway, facing in.
const CONSOLE_Z: float = 14.6
const DESK_TILT_DEG: float = 18.0
const DESK_TOP: Vector3 = Vector3(2.20, 0.10, 0.66)
const DESK_ORIGIN: Vector3 = Vector3(0.0, 1.00, 0.06)
const DESK_SIDE: Vector3 = Vector3(0.12, 1.02, 0.62)
const DESK_SIDE_X: float = 1.04
const DESK_KICK: Vector3 = Vector3(2.20, 1.02, 0.10)
const DESK_KICK_Z: float = -0.26
const PANEL_TILT_DEG: float = -8.0
const PANEL_SIZE: Vector3 = Vector3(2.20, 1.10, 0.10)
const PANEL_ORIGIN: Vector3 = Vector3(0.0, 1.44, -0.30)
const CONSOLE_BODY: Vector3 = Vector3(2.20, 1.00, 0.70)

## Display pitch per species, in radians, POSITIVE FOR NOSE DOWN. The reference
## rotates the wasp by 0.34 in its own rack and explicitly keeps it out of the rig
## (spec 15.7: "a display-only hint — the viewer tilts the model nose-down in the
## rack"), so it lands here, on the display model, and nowhere else.
##
## The sign is positive because a body faces along +Z (see `_yaw_toward`) and
## Godot's YXZ euler applies this about the body's own X after the yaw, which
## takes that +Z face to `(0, -sin t, cos t)`. Under the -Z reading this file used
## to hold, the reference's own -0.34 was copied in verbatim and stood the wasp
## nose-UP.
const DISPLAY_TILT: Dictionary = {&"wasp": 0.34}

## Far enough back down the aisle that the nearest bay sign — plate top at 4.35 m,
## against an eye at 1.76 m — subtends 24 degrees rather than 40 and therefore sits
## inside a 78 degree lens instead of being guillotined by the top of the frame.
const PLAYER_SPAWN: Vector3 = Vector3(0.0, 0.06, 13.9)

const BEAD_R: float = 0.016
const BEAD_H: float = 0.030

## Packs instance transforms straight into `MultiMesh.buffer`. The setter API
## routes through the RenderingServer, which a headless bake answers with the
## dummy driver, so `set_instance_transform` is a silent no-op and the resource
## saves with a count and no data. See `res://tools/mm_bake.gd`.
const MmBake := preload("res://tools/mm_bake.gd")

## Closed box and cylinder primitives, cached by size and audited on the way out.
const Geom := preload("res://tools/bestiary/bestiary_geom.gd")

## Seats every screen on what carries it; no standoff here is picked by hand.
const PanelMount := preload("res://ui/diegetic/panel_mount.gd")

var _hall_script: GDScript = null
var _hall_consts: Dictionary = {}
var _body_script: GDScript = null
var _steel: Material = null
var _timber: Material = null
var _polymer: Material = null
var _canvas: Material = null
var _ember: Material = null
var _display: Font = null
var _mono: Font = null
var _geom := Geom.new()
var _shapes: Array[CollisionShape3D] = []
var _report: PackedStringArray = PackedStringArray()
var _failures: int = 0
var _built: bool = false


func _process(_delta: float) -> bool:
	if _built:
		return true
	_built = true
	_build()
	return true


func _build() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SPECIES_DIR))
	_line("build_bestiary")
	_hall_script = load(HALL_SCRIPT) as GDScript
	_hall_consts = _hall_script.get_script_constant_map()
	_body_script = load(BODY_SCRIPT) as GDScript
	_steel = ResourceLoader.load(MAT_STEEL, "Material") as Material
	_timber = ResourceLoader.load(MAT_TIMBER, "Material") as Material
	_polymer = ResourceLoader.load(MAT_POLYMER, "Material") as Material
	_canvas = ResourceLoader.load(MAT_CANVAS, "Material") as Material
	_ember = ResourceLoader.load(MAT_EMBER, "Material") as Material
	_display = ResourceLoader.load(UiStyle.FONT_DISPLAY_PATH, "Font") as Font
	_mono = ResourceLoader.load(UiStyle.FONT_MONO_PATH, "Font") as Font

	var root: Node3D = _build_hall()
	for problem: String in _geom.problems:
		_fail(problem)
	_pack(root, OUT_SCENE)
	_verify()

	_line("")
	_line("unique shells checked  %d" % _geom.shells)
	_line("collision shapes       %d" % _shapes.size())
	_line("failures               %d" % _failures)
	_line("RESULT: %s" % ("PASS" if _failures == 0 else "FAIL"))
	var text: String = "\n".join(_report) + "\n"
	var f: FileAccess = FileAccess.open(OUT_REPORT, FileAccess.WRITE)
	if f != null:
		f.store_string(text)
		f.close()
	print(text)
	quit(0 if _failures == 0 else 1)


# --- the scene --------------------------------------------------------------


func _build_hall() -> Node3D:
	var root := Node3D.new()
	root.name = "Bestiary"
	root.set_script(_hall_script)

	var world: Node = _instance(WORLD_SCENE)
	world.name = "ScavWorld"
	root.add_child(world)

	var player := _instance(PLAYER_SCENE) as Node3D
	player.name = "Player"
	player.position = PLAYER_SPAWN
	root.add_child(player)

	var structure := Node3D.new()
	structure.name = "Structure"
	root.add_child(structure)
	_build_shell(structure)
	_build_gantry(structure)
	_build_plinths(structure)
	_build_lamps(structure, root)
	_build_signs(structure)
	_build_gate(structure)

	var exhibits := Node3D.new()
	exhibits.name = "Exhibits"
	root.add_child(exhibits)
	_build_exhibits(exhibits)

	var consoles := Node3D.new()
	consoles.name = "Consoles"
	root.add_child(consoles)
	consoles.add_child(_build_console("Console_entry", CONSOLE_Z, PI))
	consoles.add_child(_build_console("Console_far", -CONSOLE_Z, 0.0))

	root.add_child(_build_focus_rig())
	_add(root, "Bead", _geom.cylinder(BEAD_R, BEAD_H), _ember, Vector3(0.0, 1.2, 0.0), 0.91)

	# One body for the whole room: the physics server is happier with one
	# broadphase entry carrying ninety shapes than with ninety carrying one.
	var body := StaticBody3D.new()
	body.name = "Collision"
	body.collision_layer = GameLayers.WORLD
	body.collision_mask = 0
	for shape: CollisionShape3D in _shapes:
		body.add_child(shape)
	root.add_child(body)
	return root


func _build_shell(structure: Node3D) -> void:
	_add(structure, "Deck", _geom.box(DECK), _canvas, Vector3(0.0, -DECK.y * 0.5, 0.0), 0.07)
	_collider("DeckShape", DECK, Vector3(0.0, -DECK.y * 0.5, 0.0))
	var side: ArrayMesh = _geom.box(WALL_SIZE_SIDE)
	var ends: ArrayMesh = _geom.box(WALL_SIZE_END)
	var seed_value: float = 0.13
	for sx: int in [-1, 1]:
		var at := Vector3(float(sx) * WALL_X, WALL_Y, 0.0)
		_add(structure, "Wall%s" % ("W" if sx < 0 else "E"), side, _steel, at, seed_value)
		_collider("Wall%sShape" % ("W" if sx < 0 else "E"), WALL_SIZE_SIDE, at)
		seed_value += 0.17
	for sz: int in [-1, 1]:
		var at := Vector3(0.0, WALL_Y, float(sz) * WALL_Z)
		_add(structure, "Wall%s" % ("N" if sz < 0 else "S"), ends, _steel, at, seed_value)
		_collider("Wall%sShape" % ("N" if sz < 0 else "S"), WALL_SIZE_END, at)
		seed_value += 0.17


func _build_gantry(structure: Node3D) -> void:
	var rail: ArrayMesh = _geom.box(RAIL_SIZE)
	for sx: int in [-1, 1]:
		var rail_at := Vector3(float(sx) * RAIL_X, GANTRY_Y, 0.0)
		var rail_name: String = "Rail%s" % ("W" if sx < 0 else "E")
		_add(structure, rail_name, rail, _steel, rail_at, 0.29 if sx < 0 else 0.41)
	var cross_xf: Array[Transform3D] = []
	var cross_seed := PackedColorArray()
	for i: int in CROSS_Z.size():
		cross_xf.push_back(Transform3D(Basis(), Vector3(0.0, GANTRY_Y, CROSS_Z[i])))
		cross_seed.push_back(Color(fposmod(0.53 + 0.07 * float(i), 1.0), 0.0, 0.0, 1.0))
	_add_batch(structure, "GantryCrossbeams", _geom.box(CROSS_SIZE), _steel, cross_xf, cross_seed)
	var leg: ArrayMesh = _geom.box(LEG_SIZE)
	var n: int = 0
	for sx: int in [-1, 1]:
		for i: int in LEG_Z.size():
			n += 1
			var at := Vector3(float(sx) * RAIL_X, LEG_SIZE.y * 0.5, LEG_Z[i])
			_add(structure, "Leg%d" % n, leg, _steel, at, 0.11 * float(n))
			_collider("Leg%dShape" % n, LEG_SIZE, at)


## Plinths and placard mounts. Twelve of each, which is what a MultiMesh is for:
## four draw calls instead of forty-eight nodes. The per-instance rust seed rides in
## INSTANCE_CUSTOM.x, which `scrap_surface.gdshader` adds to `surface_seed`, so a
## dozen plinths cut from one cached mesh still weather differently. The colliders
## stay individual — a MultiMesh has no physics and a placard is walked into.
func _build_plinths(structure: Node3D) -> void:
	var base_xf: Array[Transform3D] = []
	var body_xf: Array[Transform3D] = []
	var post_xf: Array[Transform3D] = []
	var stand_xf: Array[Transform3D] = []
	var seeds := PackedColorArray()
	for i: int in SpeciesTable.IDS.size():
		var centre: Vector3 = _plinth_position(i)
		seeds.push_back(Color(fposmod(0.137 * float(i + 1), 1.0), 0.0, 0.0, 1.0))
		var top_at: Vector3 = centre + Vector3(0.0, PLINTH_BODY.y * 0.5, 0.0)
		base_xf.push_back(Transform3D(Basis(), centre + Vector3(0.0, PLINTH_BASE.y * 0.5, 0.0)))
		body_xf.push_back(Transform3D(Basis(), top_at))
		_collider("PlinthShape%d" % i, PLINTH_BODY, top_at)
		var mount: Transform3D = _placard_mount(i)
		var post_at: Transform3D = mount * Transform3D(Basis(), Vector3(0.0, PLACARD_POST_Y, 0.0))
		post_xf.push_back(post_at)
		stand_xf.push_back(mount * _placard_frame())
		_collider("PostShape%d" % i, Vector3(0.34, PLACARD_POST.y, 0.34), post_at.origin)
	_add_batch(structure, "PlinthBases", _geom.box(PLINTH_BASE), _steel, base_xf, seeds)
	_add_batch(structure, "PlinthBodies", _geom.box(PLINTH_BODY), _polymer, body_xf, seeds)
	_add_batch(structure, "PlacardPosts", _geom.box(PLACARD_POST), _steel, post_xf, seeds)
	_add_batch(structure, "PlacardStands", _geom.box(PLACARD_STAND), _steel, stand_xf, seeds)


func _build_lamps(structure: Node3D, root: Node3D) -> void:
	var stem_xf: Array[Transform3D] = []
	var shade_xf: Array[Transform3D] = []
	var bulb_xf: Array[Transform3D] = []
	var seeds := PackedColorArray()
	var lamps := Node3D.new()
	lamps.name = "Lamps"
	root.add_child(lamps)
	for i: int in SpeciesTable.IDS.size():
		var at: Vector3 = _plinth_position(i)
		seeds.push_back(Color(fposmod(0.271 * float(i + 1), 1.0), 0.0, 0.0, 1.0))
		stem_xf.push_back(Transform3D(Basis(), Vector3(at.x, LAMP_STEM_Y, at.z)))
		shade_xf.push_back(Transform3D(Basis(), Vector3(at.x, LAMP_SHADE_Y, at.z)))
		bulb_xf.push_back(Transform3D(Basis(), Vector3(at.x, LAMP_BULB_Y, at.z)))
		# Shadows off: the sun casts the room's real shadows, and twelve shadow
		# spots over twelve animated skeletons buys nothing you can see.
		var light := SpotLight3D.new()
		light.name = "Lamp%d" % i
		light.position = Vector3(at.x, LAMP_BULB_Y - 0.05, at.z)
		light.rotation = Vector3(-PI * 0.5, 0.0, 0.0)
		light.light_color = Color(1.0, 0.878, 0.729)
		light.light_energy = 10.5
		light.light_specular = 0.6
		light.spot_range = 7.0
		light.spot_angle = 33.0
		light.spot_angle_attenuation = 1.15
		light.spot_attenuation = 1.35
		light.shadow_enabled = false
		# And out of the volumetric fog: twelve lamps injecting into the froxel
		# volume cost two thirds of the frame for a haze you cannot pick out.
		light.light_volumetric_fog_energy = 0.0
		lamps.add_child(light)
	_add_batch(
		structure, "LampStems", _geom.cylinder(LAMP_STEM_R, LAMP_STEM_H), _steel, stem_xf, seeds
	)
	_add_batch(
		structure, "LampShades", _geom.cylinder(LAMP_SHADE_R, LAMP_SHADE_H), _steel, shade_xf, seeds
	)
	var lit: MultiMeshInstance3D = _add_batch(
		structure, "LampBulbs", _geom.cylinder(LAMP_BULB_R, LAMP_BULB_H), _ember, bulb_xf, seeds
	)
	lit.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


func _build_signs(structure: Node3D) -> void:
	var plate: ArrayMesh = _geom.box(SIGN_PLATE)
	var rod: ArrayMesh = _geom.cylinder(SIGN_ROD_R, SIGN_ROD_H)
	var labels: Dictionary = _hall_consts["CLASS_LABELS"]
	var classes: Array[StringName] = [&"scav", &"machine", &"mutant"]
	for b: int in classes.size():
		var z: float = BAY_Z[b]
		var sign_node := Node3D.new()
		sign_node.name = "BaySign_%s" % classes[b]
		sign_node.position = Vector3(0.0, SIGN_Y, z)
		structure.add_child(sign_node)
		_add(sign_node, "Plate", plate, _steel, Vector3.ZERO, 0.23 + 0.19 * float(b))
		for sx: int in [-1, 1]:
			var rod_at := Vector3(float(sx) * SIGN_ROD_X, SIGN_ROD_Y - SIGN_Y, 0.0)
			_add(sign_node, "Rod%s" % ("L" if sx < 0 else "R"), rod, _steel, rod_at, 0.61)
		var text: String = String(labels[classes[b]])
		var face: float = SIGN_PLATE.z * 0.5 + 0.004
		# One label per face. `double_sided` would show the back of the texture,
		# which reads as the word spelled backwards.
		for sz: int in [-1, 1]:
			var label: Label3D = _label(text, _display, 64, 0.0042, UiStyle.TEXT)
			label.name = "Face%s" % ("N" if sz < 0 else "S")
			label.position = Vector3(0.0, 0.0, float(sz) * face)
			label.rotation.y = PI if sz < 0 else 0.0
			sign_node.add_child(label)


func _build_gate(structure: Node3D) -> void:
	var gate := Node3D.new()
	gate.name = "Gate"
	structure.add_child(gate)
	var post: ArrayMesh = _geom.box(GATE_POST)
	for sx: int in [-1, 1]:
		var at := Vector3(float(sx) * GATE_POST_X, GATE_POST.y * 0.5, GATE_Z)
		_add(gate, "Post%s" % ("L" if sx < 0 else "R"), post, _steel, at, 0.33 if sx < 0 else 0.47)
		_collider("GatePost%sShape" % ("L" if sx < 0 else "R"), GATE_POST, at)
	_add(gate, "Plate", _geom.box(GATE_PLATE), _steel, Vector3(0.0, GATE_PLATE_Y, GATE_Z), 0.57)
	gate.add_child(
		_gate_text("Title", GATE_TEXT, _display, 96, 0.0040, UiStyle.ACCENT, GATE_PLATE_Y + 0.14)
	)
	gate.add_child(
		_gate_text("Sub", GATE_SUB, _mono, 44, 0.0026, UiStyle.TEXT_DIM, GATE_PLATE_Y - 0.22)
	)


## A line on the gate plate, facing back down the hall at whoever just walked in.
func _gate_text(
	node_name: String, text: String, font: Font, size: int, pixel: float, color: Color, y: float
) -> Label3D:
	var label: Label3D = _label(text, font, size, pixel, color)
	label.name = node_name
	label.position = Vector3(0.0, y, GATE_Z - GATE_PLATE.z * 0.5 - 0.005)
	label.rotation.y = PI
	return label


# --- exhibits ---------------------------------------------------------------


func _build_exhibits(exhibits: Node3D) -> void:
	for i: int in SpeciesTable.IDS.size():
		var id: StringName = SpeciesTable.IDS[i]
		var centre: Vector3 = _plinth_position(i)
		var stand := Node3D.new()
		stand.name = "Exhibit_%s" % id
		stand.position = Vector3(centre.x, PLINTH_TOP, centre.z)
		exhibits.add_child(stand)

		var turntable := Node3D.new()
		turntable.name = "Turntable"
		stand.add_child(turntable)
		var body: Node3D = _lift_body(id)
		if body == null:
			continue
		# Sixty poses per second of CLIP time, not per second of wall clock: the
		# accumulator runs on the scaled delta, so a rack at quarter pace poses a
		# quarter as often and lands on exactly the same frames. Uncapped, twelve
		# rigs re-solve at whatever the display runs at for no visible gain.
		body.set(&"pose_hz_near", 60.0)
		# Facing the walkway: the two rows look at each other across it, so you are
		# always being watched by six of them. The row standing on -X turns toward
		# +X and the row on +X turns toward -X; `_yaw_toward` is what turns a
		# heading into the yaw that produces it.
		body.rotation.y = _yaw_toward(Vector3(-signf(centre.x), 0.0, 0.0))
		if DISPLAY_TILT.has(id):
			body.rotation.x = float(DISPLAY_TILT[id])
		turntable.add_child(body)

		var placard := _instance(READOUT_SCENE) as Node3D
		placard.name = "Placard"
		placard.set(&"painted", true)
		stand.add_child(placard)
		# Seated on its backing plate in the raked frame the two share, so the screen
		# stands 4 mm proud of the plate however steep the rake is made.
		var mount: Transform3D = _placard_mount(i)
		var frame: Transform3D = (
			Transform3D(mount.basis, mount.origin - stand.position) * _placard_frame()
		)
		var seat := PanelMount.new()
		var plate: AABB = PanelMount.centred(Vector3.ZERO, PLACARD_STAND)
		seat.apply(placard, plate, Vector3.ZERO, "PlacardStand", frame)


## The on-screen test the body sleeps behind, fitted to the measured idle box with
## a generous margin: an attack reaches well past the standing silhouette and a
## creature that vanishes mid-swing is a worse bug than the one this saves.
func _watcher(stats: EnemyStats) -> VisibleOnScreenNotifier3D:
	var pad: float = 1.2
	var w: float = maxf(stats.width, 0.4) + pad
	var d: float = maxf(stats.depth, 0.4) + pad
	var node := VisibleOnScreenNotifier3D.new()
	node.name = "Vis"
	node.aabb = AABB(Vector3(-w * 0.5, -0.6, -d * 0.5), Vector3(w, stats.height + pad + 0.6, d))
	return node


## Take the animated shell out of a baked enemy scene and hand it back as an
## `ExhibitBody`. The actor around it is for fighting, and a plinth is not a
## fight: left in, its `_physics_process` would apply gravity, walk the body off
## the plinth and overwrite the desk's clip on the very next tick.
func _lift_body(id: StringName) -> Node3D:
	var path: String = "%s/%s.res" % [ENEMY_DIR, id]
	var packed: PackedScene = ResourceLoader.load(path, "PackedScene") as PackedScene
	if packed == null:
		_fail("could not load %s" % path)
		return null
	var actor: Node = packed.instantiate()
	var body := actor.get_node_or_null(^"Body") as Node3D
	if body == null:
		_fail("%s has no Body node" % path)
		actor.free()
		return null
	# Captured before the script swap, because assigning a script resets every
	# property the old one declared.
	var carried: Dictionary = {}
	for key: StringName in [
		&"species_id",
		&"species_rig",
		&"species_stats",
		&"bone_zones",
		&"skeleton_path",
		&"shell_paths",
		&"flash_paths"
	]:
		carried[key] = body.get(key)
	actor.remove_child(body)
	_disown(body)
	body.set_script(_body_script)
	for key: StringName in carried:
		body.set(key, carried[key])
	body.set(&"species_id", id)
	body.name = "Body"
	body.add_child(_watcher(body.get(&"species_stats") as EnemyStats))
	body.set(&"notifier_path", NodePath("Vis"))
	actor.free()
	# A welded shell is most of a megabyte of vertices. Inline it would be most of
	# a megabyte of TEXT in bestiary.tscn; packed out to its own binary scene it is
	# one ext_resource and the hall's file stays small enough to read.
	var path_out: String = "%s/%s.scn" % [SPECIES_DIR, id]
	var out := PackedScene.new()
	_own(body, body)
	if out.pack(body) != OK or ResourceSaver.save(out, path_out) != OK:
		_fail("could not bake the display body for '%s'" % id)
	body.free()
	return _instance(path_out) as Node3D


# --- consoles ---------------------------------------------------------------


## One desk. `yaw` turns the whole thing to face down the walkway; every control
## below is placed in desk-local space and inherits it.
func _build_console(node_name: String, z: float, yaw: float) -> Node3D:
	var console := Node3D.new()
	console.name = node_name
	console.position = Vector3(0.0, 0.0, z)
	console.rotation.y = yaw

	_add(
		console,
		"Kick",
		_geom.box(DESK_KICK),
		_steel,
		Vector3(0.0, DESK_KICK.y * 0.5, DESK_KICK_Z),
		0.19
	)
	var side: ArrayMesh = _geom.box(DESK_SIDE)
	for sx: int in [-1, 1]:
		var at := Vector3(float(sx) * DESK_SIDE_X, DESK_SIDE.y * 0.5, 0.0)
		var side_name: String = "Side%s" % ("L" if sx < 0 else "R")
		_add(console, side_name, side, _steel, at, 0.27 if sx < 0 else 0.35)
	_add(console, "Top", _geom.box(DESK_TOP), _timber, DESK_ORIGIN, 0.43).basis = _desk_basis()
	_add(console, "Panel", _geom.box(PANEL_SIZE), _steel, PANEL_ORIGIN, 0.51).basis = _panel_basis()

	_collider(
		"%sShape" % node_name,
		CONSOLE_BODY,
		console.transform * Vector3(0.0, CONSOLE_BODY.y * 0.5, -0.05)
	)

	console.add_child(
		_plate_text("Deck", "EXHIBIT CONTROL", 24, UiStyle.TEXT_FAINT, _desk_at(-0.78, 0.09))
	)
	console.add_child(
		_plate_text("Head", "THE RACK", 44, UiStyle.ACCENT, _panel_at(0.0, 0.44, 0.004))
	)
	for spec: Array in _desk_specs():
		console.add_child(_control(spec, _desk_at(spec[3], spec[4])))
	for spec: Array in _panel_specs():
		console.add_child(_control(spec, _panel_at(spec[3], spec[4], 0.0)))

	var card := _instance(READOUT_SCENE) as Node3D
	card.name = "Card"
	console.add_child(card)
	var seat := PanelMount.new()
	var face: AABB = PanelMount.centred(Vector3.ZERO, PANEL_SIZE)
	seat.apply(card, face, Vector3(0.0, 0.06, 0.0), "Panel", _panel_frame())
	return console


## Every control on a desk top: scene, id, label, x, distance toward the viewer,
## and its own settings. A table, because the two desks are the same desk.
func _desk_specs() -> Array[Array]:
	var c: Dictionary = _hall_consts
	return [
		[DIAL_SCENE, c["ID_CLIP"], "CLIP", -0.34, 0.0, _clip_setup()],
		[SLIDER_SCENE, c["ID_PACE"], "PACE", 0.10, 0.0, _pace_setup()],
		[BUTTON_SCENE, c["ID_PREV"], "PREV", 0.50, 0.06, {}],
		[BUTTON_SCENE, c["ID_NEXT"], "NEXT", 0.74, 0.06, {}],
		[BUTTON_SCENE, c["ID_TAKE"], "TAKE", 0.98, 0.06, {}]
	]


## The levers live on the back panel, not the desk top: an arm that throws toward
## you must stand up, and on an eighteen-degree top it would lie down.
func _panel_specs() -> Array[Array]:
	var c: Dictionary = _hall_consts
	var turn: Dictionary = {&"off_text": "HELD", &"on_text": "TURN"}
	var track: Dictionary = {&"off_text": "AHEAD", &"on_text": "ON YOU"}
	return [
		[LEVER_SCENE, c["ID_TURN"], "TURN", -0.82, -0.28, turn],
		[LEVER_SCENE, c["ID_TRACK"], "TRACK", 0.82, -0.28, track]
	]


func _clip_setup() -> Dictionary:
	return {&"options": _hall_consts["CLIP_LABELS"], &"wraps": true, &"sweep_degrees": 300.0}


func _pace_setup() -> Dictionary:
	return {
		&"min_value": 0.15,
		&"max_value": 2.00,
		&"step": 0.05,
		&"track_length": 0.34,
		&"value_format": "%.2fx"
	}


func _control(spec: Array, at: Transform3D) -> Node3D:
	var node := _instance(String(spec[0])) as Node3D
	node.name = "Control_%s" % spec[1]
	node.transform = at
	node.set(&"control_id", StringName(spec[1]))
	node.set(&"label_text", String(spec[2]))
	var props: Dictionary = spec[5]
	for key: StringName in props:
		node.set(key, props[key])
	return node


func _plate_text(
	node_name: String, text: String, size: int, color: Color, at: Transform3D
) -> Label3D:
	var label: Label3D = _label(text, _display, size, 0.0018, color)
	label.name = node_name
	label.transform = at
	return label


## A point on the desk top: `x` across, `along` toward the viewer.
func _desk_at(x: float, along: float) -> Transform3D:
	return Transform3D(
		_desk_basis() * Basis(Vector3.RIGHT, -PI * 0.5),
		DESK_ORIGIN + _desk_basis() * Vector3(x, DESK_TOP.y * 0.5 + 0.002, along)
	)


## A point on the back panel, `out` metres proud of its face.
func _panel_at(x: float, y: float, out: float) -> Transform3D:
	return _panel_frame() * Transform3D(Basis(), Vector3(x, y, PANEL_SIZE.z * 0.5 + out))


## The back panel's own frame. Everything on it is placed here rather than in
## console space, which is what keeps a control square with the steel it is in.
func _panel_frame() -> Transform3D:
	return Transform3D(_panel_basis(), PANEL_ORIGIN)


func _desk_basis() -> Basis:
	return Basis(Vector3.RIGHT, deg_to_rad(DESK_TILT_DEG))


func _panel_basis() -> Basis:
	return Basis(Vector3.RIGHT, deg_to_rad(PANEL_TILT_DEG))


# --- inspection lamp --------------------------------------------------------


## The one shadow-casting spot in the room. It rides a rig the hall slides from
## plinth to plinth, hanging at a fixed offset and already aimed back at the rig
## origin, so nothing has to re-aim it per frame.
func _build_focus_rig() -> Node3D:
	var rig := Node3D.new()
	rig.name = "FocusRig"
	rig.position = Vector3(-PLINTH_X, PLINTH_TOP + 0.9, BAY_Z[0] + PLINTH_DZ)
	var offset := Vector3(0.0, 2.30, 2.60)
	var light := SpotLight3D.new()
	light.name = "Light"
	light.position = offset
	light.rotation = Vector3(-atan2(offset.y, offset.z), 0.0, 0.0)
	light.light_color = Color(1.0, 0.933, 0.827)
	light.light_energy = 15.0
	light.light_specular = 0.85
	light.spot_range = 8.0
	light.spot_angle = 25.0
	light.spot_angle_attenuation = 1.0
	light.spot_attenuation = 1.2
	light.shadow_enabled = true
	light.shadow_bias = 0.035
	light.shadow_normal_bias = 1.1
	rig.add_child(light)
	return rig


# --- layout maths -----------------------------------------------------------


## Yaw that points a creature's face along the horizontal heading `dir`.
##
## AN ENEMY BODY FACES ALONG ITS OWN +Z, NOT -Z. Three independent things say so
## and they agree: `rig_pose.gd` defines rig space as "+Y up, +Z forward";
## `RigAim.fwd` defaults to `(0, 0, 1)` and every armed species in the reference
## authors it that way; and `EnemyActor._tick_facing` yaws with
## `atan2(dir.x, dir.z)`, which is exactly the expression below — it lands the
## node's +Z on the heading, where the -Z convention would need `atan2(-x, -z)`.
## Measured on the baked rigs it is unanimous: bore direction +Z on all four
## armed species, head geometry forward of the skull pivot in +Z on all twelve,
## feet forward of the ankle in +Z on all eleven that have ankles.
##
## Assuming -Z here is what put every creature on the rack with its back to the
## walkway. Yaw a body through this function and that cannot happen again.
func _yaw_toward(dir: Vector3) -> float:
	return atan2(dir.x, dir.z)


## Where species `index` stands. Bays run scav, machine, mutant down the hall and
## inside a bay the four go left-near, right-near, left-far, right-far — roster
## order, read the way you walk it.
func _plinth_position(index: int) -> Vector3:
	var bay: int = index / 4
	var slot: int = index % 4
	var x: float = -PLINTH_X if slot % 2 == 0 else PLINTH_X
	var z: float = BAY_Z[bay] + (PLINTH_DZ if slot < 2 else -PLINTH_DZ)
	return Vector3(x, 0.0, z)


## The placard's raked frame, relative to its mount point. Plate and screen share it.
func _placard_frame() -> Transform3D:
	var rake := Basis(Vector3.RIGHT, deg_to_rad(PLACARD_PITCH_DEG))
	return Transform3D(rake, Vector3(0.0, PLACARD_STAND_Y, 0.0))


## World transform of the placard mount for species `index`.
func _placard_mount(index: int) -> Transform3D:
	var centre: Vector3 = _plinth_position(index)
	var sx: float = 1.0 if centre.x < 0.0 else -1.0
	var yaw: float = sx * PI * 0.25
	var origin := Vector3(centre.x + sx * PLACARD_OFFSET, PLINTH_TOP, centre.z + PLACARD_OFFSET)
	return Transform3D(Basis(Vector3.UP, yaw), origin)


# --- node helpers -----------------------------------------------------------


## Instance a packed scene, so `pack` stores an instance, not a flattened copy.
func _instance(path: String) -> Node:
	return (ResourceLoader.load(path, "PackedScene") as PackedScene).instantiate()


## Build a mesh instance, park it under `parent`, hand it back. `seed_value` is
## the scrap shader's per-instance variation, so a dozen plinths cut from one
## cached mesh rust differently for free.
func _add(
	parent: Node3D,
	node_name: String,
	mesh: ArrayMesh,
	material: Material,
	origin: Vector3,
	seed_value: float
) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	node.name = node_name
	node.mesh = mesh
	node.material_override = material
	node.position = origin
	node.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	node.set_instance_shader_parameter(&"surface_seed", seed_value)
	parent.add_child(node)
	return node


## One draw call for a fitting the hall repeats. `seeds` carries the scrap shader's
## per-instance rust variation in the red channel of the custom-data slot; the shader
## reads it as `INSTANCE_CUSTOM.x` and adds it to `surface_seed`, which is the
## MultiMesh equivalent of the instance uniform `_add` sets.
func _add_batch(
	parent: Node3D,
	node_name: String,
	mesh: ArrayMesh,
	material: Material,
	transforms: Array[Transform3D],
	seeds: PackedColorArray
) -> MultiMeshInstance3D:
	var mm := MultiMesh.new()
	mm.mesh = mesh
	MmBake.fill(mm, transforms, PackedColorArray(), seeds)
	var node := MultiMeshInstance3D.new()
	node.name = node_name
	node.multimesh = mm
	node.material_override = material
	node.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	parent.add_child(node)
	return node


func _collider(node_name: String, size: Vector3, origin: Vector3) -> void:
	var shape := CollisionShape3D.new()
	shape.name = node_name
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	shape.position = origin
	_shapes.append(shape)


func _label(text: String, font: Font, size: int, pixel: float, color: Color) -> Label3D:
	var label := Label3D.new()
	label.text = text
	label.font = font
	label.font_size = size
	label.pixel_size = pixel
	label.modulate = color
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.shaded = false
	label.double_sided = false
	label.alpha_cut = Label3D.ALPHA_CUT_DISCARD
	label.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	label.render_priority = 2
	return label


## Load back what was just written and confirm it is what this file meant to
## emit. A builder that never re-opens its output has told you nothing.
func _verify() -> void:
	var packed: PackedScene = ResourceLoader.load(OUT_SCENE, "PackedScene", 0) as PackedScene
	if packed == null:
		_fail("the packed scene will not load back")
		return
	var root: Node = packed.instantiate()
	_expect(root.get_script() != null, "root carries bestiary_hall.gd")
	_expect(root.get_node_or_null(^"ScavWorld") != null, "the shared world is instanced")
	_expect(root.get_node_or_null(^"Player") != null, "the baked player is instanced")
	var exhibits: Node = root.get_node_or_null(^"Exhibits")
	var bodies: int = 0
	var bones: int = 0
	for id: StringName in SpeciesTable.IDS:
		var n: int = _verify_body(exhibits, id)
		if n > 0:
			bodies += 1
			bones += n
	var facing: int = _verify_facing(exhibits)
	var controls: int = 0
	for console: Node in root.get_node(^"Consoles").get_children():
		_expect(console.get_node_or_null(^"Card") != null, "%s has a card" % console.name)
		for child: Node in console.get_children():
			controls += 1 if child.name.begins_with("Control_") else 0
	_expect(bodies == 12, "twelve creatures on the rack")
	_expect(facing == 12, "twelve creatures facing the walkway")
	_expect(controls == 14, "fourteen desk controls over two desks")
	_line(
		(
			"  bodies %d (%d facing the walkway), bones %d, controls %d, nodes %d"
			% [bodies, facing, bones, controls, _count(root)]
		)
	)
	root.free()


## Every creature is turned toward the walkway, measured off the transform that
## was actually written rather than off the expression that wrote it. The whole
## rack once stood with its back to the aisle because a yaw was signed for the
## wrong forward axis, and nothing in the bake noticed. Returns how many face it.
func _verify_facing(exhibits: Node) -> int:
	var good: int = 0
	for i: int in SpeciesTable.IDS.size():
		var id: StringName = SpeciesTable.IDS[i]
		var stand := (
			(null if exhibits == null else exhibits.get_node_or_null(NodePath("Exhibit_%s" % id)))
			as Node3D
		)
		var body := (null if stand == null else stand.get_node_or_null(^"Turntable/Body")) as Node3D
		if stand == null or body == null:
			continue
		# Exhibits sits at the origin and the turntable starts unturned, so the
		# stand times the body is the creature's world basis.
		var fwd: Vector3 = (stand.transform.basis * body.transform.basis).z
		var want_x: float = -signf(_plinth_position(i).x)
		if signf(fwd.x) != want_x or absf(fwd.x) < 0.9:
			_fail("'%s' faces (%+.2f, %+.2f, %+.2f), not the walkway" % [id, fwd.x, fwd.y, fwd.z])
			continue
		if DISPLAY_TILT.has(id) and fwd.y >= 0.0:
			_fail("'%s' carries a nose-down display tilt but its face points up" % id)
			continue
		good += 1
	return good


## One creature: it exists, it kept its rig and stats through the script swap and
## its skeleton has exactly the bones the roster asserts. Returns its bone count,
## or -1 if any of that is untrue.
func _verify_body(exhibits: Node, id: StringName) -> int:
	var body: Node = (
		null
		if exhibits == null
		else exhibits.get_node_or_null(NodePath("Exhibit_%s/Turntable/Body" % id))
	)
	if body == null:
		_fail("no body for '%s'" % id)
		return -1
	var rig: EnemyRig = body.get(&"species_rig") as EnemyRig
	if rig == null or body.get(&"species_stats") == null:
		_fail("'%s' lost its rig or stats in the script swap" % id)
		return -1
	var skel := body.get_node_or_null(^"Skeleton") as Skeleton3D
	var want: int = int(SpeciesTable.CATALOGUE[id]["bones"])
	if skel == null or skel.get_bone_count() != rig.bones.size() or rig.bones.size() != want:
		_fail("'%s' skeleton does not match its rig" % id)
		return -1
	return skel.get_bone_count()


func _expect(condition: bool, what: String) -> void:
	if not condition:
		_fail("expected: %s" % what)


func _count(node: Node) -> int:
	var n: int = 1
	for child: Node in node.get_children():
		n += _count(child)
	return n


# --- io ---------------------------------------------------------------------


func _pack(root: Node, path: String) -> void:
	_own(root, root)
	var packed := PackedScene.new()
	var err: Error = packed.pack(root)
	if err != OK:
		_fail("pack %s (error %d)" % [path, err])
		root.free()
		return
	err = ResourceSaver.save(packed, path)
	if err != OK:
		_fail("save %s (error %d)" % [path, err])
	else:
		_line("  wrote %s (%d nodes)" % [path, _count(root)])
	root.free()


## Instanced sub-scenes keep their own internals; only the instance root is ours,
## which is what makes `pack` store an instance instead of a flattened copy.
func _own(node: Node, owner_node: Node) -> void:
	for child: Node in node.get_children():
		if child.owner == null:
			child.owner = owner_node
		if child.scene_file_path.is_empty():
			_own(child, owner_node)


## Clear a subtree's owners before it leaves the scene it was instanced from.
## Left set, they point at a node this file is about to free.
func _disown(node: Node) -> void:
	node.owner = null
	for child: Node in node.get_children():
		_disown(child)


func _fail(text: String) -> void:
	_failures += 1
	_line("  FAIL  %s" % text)


func _line(text: String) -> void:
	_report.append(text)
