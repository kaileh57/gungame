@tool
extends RefCounted
## THE ASH LINE RACE, as geometry: the start line, the starter's gantry over it, the
## standings board beside it, the cross-map marks, and the `AshFlatsRace` node that owns
## the lot.
##
## Split out of `tools/build_ash_flats.gd` for the same reason `ash_flats_line.gd` was —
## it is the part of that bake with an OPINION. Everything in the builder proper places
## something somebody else made; this decides where four people stand, what they look at
## while they wait, and which points on the line a run has to touch to count.
##
## NOTHING IN THE ROUTE IS TAKEN ON TRUST. Every checkpoint is resolved against the ash
## line's own table and then against the baked collider set before it is written, and
## what it is standing on is printed in the bake report — see `_support`.
##
## THE RACE NODE CARRIES THE WHOLE ROUTE AS BAKED ARRAYS and knows no geometry of its
## own — the same split `AshFlatsCourse` already uses for the solo clock. Moving the
## route is editing `CHECKS` and re-running the builder; nothing under `demos/` follows.

## THE ASH LINE itself. The route is checked against its table, not described beside it:
## every checkpoint has to sit on a run this file can name, or on the baked town.
const Line := preload("res://tools/ash_flats/ash_flats_line.gd")
## The finish gantry and the checkpoint masts — the race's signage, all of it baked.
const Finish := preload("res://tools/ash_flats/ash_flats_finish.gd")

const RACE_SCRIPT: String = "res://demos/ash_flats/ash_flats_race.gd"
const GANTRY_SCRIPT: String = "res://demos/ash_flats/ash_flats_gantry.gd"
const LEADERBOARD_SCRIPT: String = "res://demos/ash_flats/ash_flats_board.gd"
const MARKS_SCRIPT: String = "res://demos/ash_flats/ash_flats_marks.gd"
const SCRAP_SHADER: String = "res://art/shaders/scrap_surface.gdshader"
const FONT_PATH: String = "res://data/ui/font_display.tres"
## The avatar system's baked cross-map mark. `AshFlatsMarks` wears the same one GHOST
## mode does, so a player learns one mark and it means one thing.
const BEACON_MATERIAL: String = "res://data/net/beacon.tres"
const MARK_SCENE: String = "res://demos/ash_flats/meshes/mark.tscn"

const RAIL: Color = WorldPalette.RAIL
const SLAB: Color = WorldPalette.SLAB
const DECK: Color = WorldPalette.DECK
const S_METAL: int = WorldSurface.Kind.METAL
const S_CONCRETE: int = WorldSurface.Kind.CONCRETE
const S_TIN: int = WorldSurface.Kind.TIN
## Metres a racer stands above the ground on the line, matching the demo's own spawn lift.
const LANE_LIFT: float = 0.2
## Which way every racer is turned on the line. PI faces +Z, and +Z is down the line.
const LANE_YAW: float = PI

# --- THE RACE ---------------------------------------------------------------------
#
# The start line sits on the flat carriageway between the yard board and the foot of
# the berm, which is the one stretch down here with nothing on it. The gantry stands
# 3.4 m DOWN-LINE of the line itself and carries its lamps on a low bar rather than on
# the span: a racer on the line is looking down the road, and a light five metres over
# their head is a light they have to stop looking at the road to read.

## Where the four racers stand, and where the gantry stands relative to them.
const LINE_Z: float = -118.0
const GANTRY_AHEAD: float = 3.4
## Lane offsets from the carriageway centre. Inside the berm's 7 m width, so every lane
## takes the ramp square rather than one of them starting on the batter.
const LANE_X: PackedFloat32Array = [-3.3, -1.1, 1.1, 3.3]
## Post half-span, post height, lintel height, lamp-bar height and half-span.
const GANTRY_HALF: float = 5.6
const GANTRY_TOP: float = 5.00
const GANTRY_LINTEL: float = 4.85
const LAMP_BAR_Y: float = 2.55
const LAMP_BAR_HALF: float = 3.60
## Lamp lens radius and how far the five of them are spaced along the bar.
const LAMP_R: float = 0.155
const LAMP_STEP: float = 1.50
const LAMP_COUNT: int = 5

## The route, as the race reads it: name, x, z, deck top y (NAN stands on the ground),
## and the metres below and above that top which still count as having been there.
##
## THE ROUTE IS TWO LEGS AND A CLIMB BETWEEN THEM. CREST to RIVER is the original run
## down the berm and the three gaps into the dry river — a hundred and twenty metres,
## all of it downhill, which was the whole race and was over in half a minute. ROOFLINE
## and LAST DROP are the second leg: out of the riverbed on the viaduct that climbs over
## the market, along the high deck, and down one more pitch and gap to a finish on the
## far carriageway. It is a hundred and ninety metres of z now and the shape of it is
## DOWN, UP, DOWN, so a race is won on both halves and not on the first gap.
##
## THE FINISH IS NOT IN THIS TABLE. It is wherever the gantry could stand — see
## `finish_point` — and it is appended to the route with the ground under it.
##
## THE `below` COLUMN IS THE ANTI-SHORTCUT and it is the only interesting number in the
## table. Two of these decks have a street running directly under them, so a checkpoint
## that were a plain cylinder would be crossed by somebody who never left the ground.
## MIDWAY's deck stands about 1.7 m over its own street and LAST DROP's about 2.8 m,
## which is why those two bands are the tight ones; everything else on the line is at
## least four metres up and can afford to be generous.
const CHECKS: Array[Array] = [
	["CREST", -8.0, -89.7, 11.15, 2.5, 7.0],
	["GAP ONE", -8.0, -61.7, 6.31, 2.5, 7.0],
	["MIDWAY", -8.0, -31.4, 1.42, 1.0, 7.0],
	["RIVER", -8.0, -2.5, -3.27, 2.5, 7.0],
	["ROOFLINE", -8.0, 24.4, 7.94, 2.5, 7.0],
	["LAST DROP", -8.0, 54.5, 3.05, 1.5, 7.0],
]
const C_NAME: int = 0
const C_X: int = 1
const C_Z: int = 2
const C_Y: int = 3
const C_BELOW: int = 4
const C_ABOVE: int = 5
## The finish checkpoint's own band. Generous overhead: you arrive off the last pitch
## still a stride in the air, and nobody should cross a finish line and not be told.
const FINISH_BELOW: float = 3.0
const FINISH_ABOVE: float = 8.0

## Where the finish gantry may stand, best first, as a z on the carriageway. Every
## candidate is put through the baked collider set's own standing test at all four post
## positions — the two towers and the two pennant masts — and the first that survives is
## used. The last is the fallback. This is the same rule the board spots and the course
## piers follow, and it is the reason the gantry is never found half inside a wall.
const FINISH_SPOTS: PackedFloat32Array = [73.0, 72.0, 74.0, 71.0, 60.0]
const FINISH_X: float = -8.0
## How much clear air a gantry post needs, and the radius it is tested at.
const FINISH_CLEAR: float = 8.6
const FINISH_POST_R: float = 0.55

## Metres a checkpoint's own height may differ from what is under it before the bake
## calls it unsupported. A checkpoint stands ON something; this is the slack for a kerb.
const SUPPORT_SLACK: float = 0.45
## Half-width used for a checkpoint's masts when nothing on the line owns that spot.
const MAST_HALF_FALLBACK: float = 4.0
## Metres outside the run's own edge the masts stand.
const MAST_MARGIN: float = 0.45

## Where the standings board may stand, best first. Every candidate is put through the
## baked collider set's own standing test and the first one that survives is used, which
## is the same rule the clutter scatter and the course piers follow. The last is the
## fallback and is on the carriageway itself, which the town bake provably leaves clear.
##
## THEY ARE ALL DOWN-LINE OF THE LINE NOW. You spawn on the start line facing +Z and the
## first thing you should see is what everyone else has run — a board behind your back is
## a board nobody reads. The first two candidates put it forward and to one side, clear
## of the outside lane, and `_build_leaderboard` turns it back to face the line.
const BOARD_SPOTS: Array[Vector2] = [
	Vector2(-14.2, -113.4),
	Vector2(-1.8, -113.4),
	Vector2(-15.8, -112.6),
	Vector2(-0.2, -112.6),
	Vector2(-13.8, -116.6),
	Vector2(-2.2, -116.6),
	Vector2(-15.6, -121.0),
	Vector2(-8.0, -122.6),
]
## Where the board is turned to look: the middle of the start line, a stride behind it,
## which is where four people are stood when it matters.
const BOARD_AIM: Vector2 = Vector2(-8.0, LINE_Z - 1.2)
## Metres between the four standing rows on the board.
const BOARD_ROW_STEP: float = 0.42
## Half-width, half-height and centre height of the board's plate, and its leg span. The
## board grew by half when the demo became mostly a race: it is the first thing you are
## meant to read on arrival, from the line, which is seven metres of dust away.
const BOARD_HALF_W: float = 2.00
const BOARD_HALF_H: float = 1.35
const BOARD_MID: float = 2.85
const BOARD_LEG_X: float = 2.05
const BOARD_TOP: float = 4.20

## Lamp lens colours. Amber is the project's own exfil orange, which already means "this
## one matters" everywhere else in the demo. Green appears NOWHERE else in ash_flats and
## that is the entire reason it is legible as GO.
const LAMP_DARK: Color = Color(0.15, 0.135, 0.125)
const LAMP_GO: Color = Color(0.31, 0.78, 0.36)


## Everything the race is made of: the line, the gantry over it, the standings board
## beside it, the cross-map marks, and the `AshFlatsRace` node that owns all of it.
##
## The race node carries the whole route as baked arrays and knows no geometry of its
## own — the same split `AshFlatsCourse` already uses. That is what lets the route move
## by editing `CHECKS` and re-running this builder, with nothing in `demos/` to follow.
static func build(
	root: Node3D, query: WorldQuery, meshes: Dictionary, mesh_dir: String, finish: Vector3
) -> Dictionary:
	var lines: Array[String] = []
	var lamps: Dictionary = _lamp_materials(mesh_dir)
	var lanes := PackedVector3Array()
	for offset: float in LANE_X:
		var x: float = -8.0 + offset
		lanes.push_back(Vector3(x, query.ground_h(x, LINE_Z) + LANE_LIFT, LINE_Z))
	_build_gantry(root, query, meshes["gantry"], lamps, mesh_dir)
	var route: Dictionary = _route(query, finish)
	var race := Node.new()
	race.name = "Race"
	race.set_script(load(RACE_SCRIPT))
	race.set(&"checkpoint_names", route["names"])
	race.set(&"checkpoint_points", route["points"])
	race.set(&"checkpoint_below", route["below"])
	race.set(&"checkpoint_above", route["above"])
	race.set(&"lane_points", lanes)
	race.set(&"lane_yaw", LANE_YAW)
	root.add_child(race)
	lines.append_array(route["lines"] as Array[String])
	_build_masts(root, meshes, lamps, route)
	Finish.build_finish(root, query, meshes, lamps, finish)
	var spot: Vector2 = board_spot(query)
	_build_leaderboard(root, query, meshes["board_frame"], spot)
	var marked: bool = _build_marks(root, mesh_dir)
	lines.append(
		(
			"  line   z %6.1f   %d lanes x %.1f .. %.1f   gantry %.1f m down-line"
			% [LINE_Z, lanes.size(), lanes[0].x, lanes[lanes.size() - 1].x, GANTRY_AHEAD]
		)
	)
	lines.append(
		(
			"  finish x %6.1f  z %6.1f  y %6.2f   gantry and %d threshold bars"
			% [finish.x, finish.z, finish.y, Finish.BAR_COUNT]
		)
	)
	lines.append("  board  %6.1f %6.1f   %d rows" % [spot.x, spot.y, NetPlayer.MAX_PLAYERS])
	lines.append("  marks  %s" % ("baked" if marked else "NO BEACON - run build_avatar.gd"))
	return {"lines": lines, "unsupported": route["unsupported"]}


## The route as the four baked arrays, with the finish appended and EVERY CHECKPOINT
## PROVED TO STAND ON SOMETHING before it is written.
##
## The proof is the point of this function. A checkpoint is a number in a table and the
## world is a bake; nothing stops the two drifting apart, and a checkpoint hanging two
## metres over its own deck is invisible in a screenshot and a race nobody can finish.
## So each one is resolved against the ash line's own table first — which is the geometry
## this same bake is about to emit — and then against the baked collider set, exactly the
## way the course piers and the board spot are. What it finds is written into the report.
static func _route(query: WorldQuery, finish: Vector3) -> Dictionary:
	var names := PackedStringArray()
	var points := PackedVector3Array()
	var below := PackedFloat32Array()
	var above := PackedFloat32Array()
	var lines: Array[String] = []
	var halves := PackedFloat32Array()
	var rows: Array[Array] = []
	rows.append_array(CHECKS)
	rows.append(["FINISH", finish.x, finish.z, finish.y, FINISH_BELOW, FINISH_ABOVE])
	var unsupported: int = 0
	for row: Array in rows:
		var x: float = row[C_X]
		var z: float = row[C_Z]
		var y: float = row[C_Y]
		if is_nan(y):
			y = query.ground_h(x, z)
		var support: Dictionary = _support(query, x, z, y)
		if not bool(support["ok"]):
			unsupported += 1
			push_warning(
				(
					"ash_flats_race_build: %s at (%.1f, %.1f) has nothing under y %.2f."
					% [row[C_NAME], x, z, y]
				)
			)
		names.push_back(String(row[C_NAME]))
		points.push_back(Vector3(x, y, z))
		below.push_back(float(row[C_BELOW]))
		above.push_back(float(row[C_ABOVE]))
		halves.push_back(float(support["half"]))
		lines.append(
			(
				"  check  %-9s x %6.1f  z %7.1f  y %6.2f   band %.1f/%.1f   on %s"
				% [row[C_NAME], x, z, y, float(row[C_BELOW]), float(row[C_ABOVE]), support["what"]]
			)
		)
	return {
		"names": names,
		"points": points,
		"below": below,
		"above": above,
		"halves": halves,
		"lines": lines,
		"unsupported": unsupported,
	}


## What a checkpoint is standing on: a run of the ash line, a baked town roof, or the
## ground. Returns the half-width of whatever it found, which is where the masts go.
##
## THE ASH LINE IS CHECKED FIRST AND IT HAS TO BE. Its decks are not in
## `colliders.res` — they are emitted by this same bake — so the baked collider set
## alone would call every checkpoint on the line unsupported and be wrong six times out
## of seven. The table this reads is the one the geometry is cut from, so the two cannot
## disagree: move a deck and the answer here moves with it.
static func _support(query: WorldQuery, x: float, z: float, y: float) -> Dictionary:
	for row: Array in Line.LINE:
		var half: float = float(row[Line.P_W]) * 0.5
		if absf(x - float(row[Line.P_X])) > half:
			continue
		var z0: float = minf(float(row[Line.P_Z0]), float(row[Line.P_Z1]))
		var z1: float = maxf(float(row[Line.P_Z0]), float(row[Line.P_Z1]))
		if z < z0 - 0.01 or z > z1 + 0.01:
			continue
		var top: float = Line.top_at(row, z)
		if absf(top - y) > SUPPORT_SLACK:
			continue
		var kind: String = ["ramp", "pitch", "deck", "plank"][int(row[Line.P_KIND])]
		return {"ok": true, "half": half, "what": "ash line %s %.2f" % [kind, top]}
	var town: float = query.top_at(x, z, y - 2.0, y + 2.0)
	if not is_nan(town) and absf(town - y) <= SUPPORT_SLACK:
		var standing: bool = query.can_stand(x, z, town, 2.2, 1.2)
		return {
			"ok": standing,
			"half": MAST_HALF_FALLBACK,
			"what": "town top %.2f%s" % [town, "" if standing else "  NO ROOM"]
		}
	return {"ok": false, "half": MAST_HALF_FALLBACK, "what": "NOTHING at %.2f" % y}


## Where the finish gantry stands. The first candidate whose four post positions are all
## clear in the baked collider set wins; the last is the fallback, on the carriageway,
## which the town bake provably leaves open.
static func finish_point(query: WorldQuery) -> Vector3:
	for z: float in FINISH_SPOTS:
		var clear: bool = true
		for dx: float in [-Finish.MAST_X, -Finish.TOWER_HALF, Finish.TOWER_HALF, Finish.MAST_X]:
			var x: float = FINISH_X + dx
			if not query.can_stand(x, z, query.ground_h(x, z), FINISH_CLEAR, FINISH_POST_R):
				clear = false
				break
		if clear:
			return Vector3(FINISH_X, query.ground_h(FINISH_X, z), z)
	var last: float = FINISH_SPOTS[FINISH_SPOTS.size() - 1]
	return Vector3(FINISH_X, query.ground_h(FINISH_X, last), last)


## A pair of masts at every checkpoint, so the route reads on sight from the deck you are
## stood on and from the one before it.
##
## EVERY MAST CARRIES ITS NAME, INCLUDING THE THREE THAT ALSO HAVE A TIMING GATE OVER
## them. The arch's own plate is driven by the yard board's lamp dial and its default is
## NEXT — it shows the name of the gate the SOLO clock is waiting for and hides the other
## three. That is the right behaviour for a stopwatch and the wrong one for a route: a
## racer who has never been here needs to know what the deck under them is called whether
## or not a clock is running. So the mast says it always, in gold, a metre above the
## arch's plate and in a colour the arch never uses.
static func _build_masts(
	root: Node3D, meshes: Dictionary, lamps: Dictionary, route: Dictionary
) -> void:
	var group := Node3D.new()
	group.name = "Checkpoints"
	root.add_child(group)
	var names: PackedStringArray = route["names"]
	var points: PackedVector3Array = route["points"]
	var halves: PackedFloat32Array = route["halves"]
	for i: int in names.size():
		# The finish is a gantry, not a pair of masts.
		if i == names.size() - 1:
			continue
		Finish.build_check_mast(group, meshes, lamps, points[i], halves[i] + MAST_MARGIN, names[i])


## The gantry: a span over the line with five lamps on a low bar, and the painted line
## itself. `AshFlatsGantry` drives all six from the race's state; this only places them
## and hands over the three baked lamp materials.
static func _build_gantry(
	root: Node3D, query: WorldQuery, mesh: ArrayMesh, lamps: Dictionary, mesh_dir: String
) -> void:
	var group := Node3D.new()
	group.name = "StartLine"
	group.position = Vector3(-8.0, query.ground_h(-8.0, LINE_Z), LINE_Z)
	group.set_script(load(GANTRY_SCRIPT))
	group.set(&"dark_material", lamps["dark"])
	group.set(&"armed_material", lamps["armed"])
	group.set(&"go_material", lamps["go"])
	root.add_child(group)

	var strip := BoxMesh.new()
	strip.size = Vector3(GANTRY_HALF * 2.2, 0.07, 0.70)
	var paint := MeshInstance3D.new()
	paint.name = "Paint"
	paint.mesh = _saved(strip, "%s/start_paint.res" % mesh_dir) as Mesh
	paint.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	paint.set_surface_override_material(0, lamps["dark"])
	group.add_child(paint)

	# The span stands on its own ground, which is a few centimetres off the line's.
	var lift: float = query.ground_h(-8.0, LINE_Z + GANTRY_AHEAD) - group.position.y
	var span := _mesh_node("Span", mesh, 300.0)
	span.position = Vector3(0.0, lift, GANTRY_AHEAD)
	group.add_child(span)
	var legs := StaticBody3D.new()
	legs.name = "Legs"
	legs.collision_layer = GameLayers.WORLD
	legs.collision_mask = 0
	for side: float in [-GANTRY_HALF, GANTRY_HALF]:
		var box := BoxShape3D.new()
		box.size = Vector3(0.24, GANTRY_TOP, 0.24)
		var cs := CollisionShape3D.new()
		cs.name = "leg_%d" % int(side)
		cs.shape = box
		cs.position = Vector3(side, lift + GANTRY_TOP * 0.5, GANTRY_AHEAD)
		cs.set_meta(&"surf", S_METAL)
		legs.add_child(cs)
	group.add_child(legs)

	var lens := CylinderMesh.new()
	lens.top_radius = LAMP_R
	lens.bottom_radius = LAMP_R
	lens.height = 0.08
	lens.radial_segments = 16
	lens.rings = 1
	var lens_mesh: Mesh = _saved(lens, "%s/start_lamp.res" % mesh_dir) as Mesh
	var bank := Node3D.new()
	bank.name = "Lamps"
	bank.position = Vector3(0.0, lift, GANTRY_AHEAD)
	group.add_child(bank)
	for i: int in LAMP_COUNT:
		var lamp := MeshInstance3D.new()
		lamp.name = "lamp_%d" % i
		lamp.mesh = lens_mesh
		lamp.position = Vector3((float(i) - 2.0) * LAMP_STEP, LAMP_BAR_Y, -0.21)
		# A cylinder's axis is +Y; a quarter turn back about X points the lens at the
		# racers, who are always on the -Z side of the gantry.
		lamp.rotation = Vector3(-PI * 0.5, 0.0, 0.0)
		lamp.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
		lamp.set_surface_override_material(0, lamps["dark"])
		bank.add_child(lamp)


## The standings board: a stencilled steel board beside the line. Four rows of three
## labels each, because a row has to be in its player's colour and the columns have to
## line up under a proportional font — see `AshFlatsBoard` for why that rules out a
## `DiegeticReadout` here and only here.
static func _build_leaderboard(
	root: Node3D, query: WorldQuery, frame_mesh: ArrayMesh, spot: Vector2
) -> void:
	var board := Node3D.new()
	board.name = "Leaderboard"
	board.position = Vector3(spot.x, query.ground_h(spot.x, spot.y), spot.y)
	board.rotation = Vector3(0.0, atan2(BOARD_AIM.x - spot.x, BOARD_AIM.y - spot.y), 0.0)
	board.set_script(load(LEADERBOARD_SCRIPT))
	root.add_child(board)
	board.add_child(_mesh_node("Frame", frame_mesh, 300.0))
	board.add_child(
		_board_label("Head", "ASH LINE", Vector3(0.0, 3.76, 0.10), 112, 0, Palette.BONE)
	)
	board.add_child(
		_board_label("Status", "PRESS START RACE", Vector3(0.0, 3.40, 0.06), 76, 0, Palette.BONE)
	)
	var rows := Node3D.new()
	rows.name = "Rows"
	board.add_child(rows)
	for i: int in NetPlayer.MAX_PLAYERS:
		var row := Node3D.new()
		row.name = "row_%d" % i
		row.position = Vector3(0.0, 2.98 - BOARD_ROW_STEP * float(i), 0.0)
		row.add_child(_board_label("Place", "", Vector3(-1.72, 0.0, 0.06), 92, 0, Palette.BONE))
		row.add_child(_board_label("Name", "", Vector3(-1.44, 0.0, 0.06), 92, -1, Palette.BONE))
		row.add_child(_board_label("Time", "", Vector3(1.86, 0.0, 0.06), 92, 1, Palette.BONE))
		rows.add_child(row)


## One stencilled line on the board. `align` is -1 left, 0 centre, +1 right; the enum
## constants are picked here rather than cast from an int, because a cast to a global
## enum is not a cast GDScript accepts. Right-aligning the time column is what makes four
## times read as a column instead of as four strings.
static func _board_label(
	node_name: String, text: String, at: Vector3, size: int, align: int, tint: Color
) -> Label3D:
	var label := Label3D.new()
	label.name = node_name
	label.text = text
	label.font = ResourceLoader.load(FONT_PATH) as Font
	label.font_size = size
	label.pixel_size = 0.0026
	label.position = at
	if align < 0:
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	elif align > 0:
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	else:
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.modulate = tint
	label.outline_size = 16
	label.outline_modulate = Color(0.05, 0.045, 0.04, 1.0)
	label.visibility_range_end = 160.0
	label.billboard = BaseMaterial3D.BILLBOARD_DISABLED
	label.double_sided = false
	return label


## The cross-map marks. They wear `res://data/net/beacon.tres`, which `build_avatar.gd`
## bakes — without it there is no mark and the demo says so rather than drawing nothing
## and leaving somebody to wonder.
static func _build_marks(root: Node3D, mesh_dir: String) -> bool:
	var marks := Node3D.new()
	marks.name = "Marks"
	marks.set_script(load(MARKS_SCRIPT))
	root.add_child(marks)
	var prefab: PackedScene = _build_mark_scene(mesh_dir)
	marks.set(&"mark_scene", prefab)
	return prefab != null


## The mark prefab: a billboard quad on the avatar system's beacon shader, and a name
## over it. Saved as a scene rather than assembled at runtime, so the demo instances a
## baked thing per player exactly like everything else here does.
static func _build_mark_scene(mesh_dir: String) -> PackedScene:
	var beacon := ResourceLoader.load(BEACON_MATERIAL) as ShaderMaterial
	if beacon == null:
		push_warning("ash_flats_race_build: no %s. Run build_avatar.gd." % BEACON_MATERIAL)
		return null
	var mark := Node3D.new()
	mark.name = "Mark"
	var quad := QuadMesh.new()
	quad.size = Vector2(1.0, 1.0)
	# Foot of the quad at the node origin, so scaling the node grows the mark upward.
	quad.center_offset = Vector3(0.0, 0.5, 0.0)
	var shaft := MeshInstance3D.new()
	shaft.name = "Shaft"
	shaft.mesh = _saved(quad, "%s/mark_quad.res" % mesh_dir) as Mesh
	shaft.material_override = beacon
	shaft.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	shaft.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	mark.add_child(shaft)
	var label := _board_label("Name", "", Vector3(0.0, 1.0, 0.0), 64, 0, Palette.BONE)
	label.pixel_size = 0.0030
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.double_sided = true
	label.shaded = false
	label.no_depth_test = true
	label.render_priority = 4
	label.visibility_range_end = 0.0
	mark.add_child(label)
	for child: Node in mark.get_children():
		child.owner = mark
	var packed := PackedScene.new()
	if packed.pack(mark) != OK:
		mark.free()
		return null
	mark.free()
	return _saved(packed, MARK_SCENE) as PackedScene


## The lamp lenses, baked once. Dark is a dead bulb; amber is the demo's own exfil
## orange; green is a signal colour that appears nowhere else in ash_flats, which is the
## whole reason it reads as GO without a word written anywhere; and gold is the finish,
## which is the only other thing here allowed to glow on its own.
static func _lamp_materials(mesh_dir: String) -> Dictionary:
	var out: Dictionary = {}
	for row: Array in [
		["dark", LAMP_DARK, 0.0],
		["armed", WorldPalette.EXFIL, 4.2],
		["go", LAMP_GO, 5.0],
		["gold", Finish.GOLD, 3.4]
	]:
		var mat := ShaderMaterial.new()
		mat.shader = ResourceLoader.load(SCRAP_SHADER) as Shader
		mat.set_shader_parameter(&"surface_type", WorldSurface.Kind.METAL)
		mat.set_shader_parameter(&"albedo", row[1])
		mat.set_shader_parameter(&"metallic_base", 0.0)
		mat.set_shader_parameter(&"roughness_base", 0.30)
		mat.set_shader_parameter(&"emission_color", row[1])
		mat.set_shader_parameter(&"emission_energy", row[2])
		out[String(row[0])] = _saved(mat, "%s/lamp_%s.tres" % [mesh_dir, row[0]])
	return out


## Where the standings board may stand. The first candidate the baked collider set has
## room for wins; the last is on the carriageway and always survives.
##
## THE TEST IS THE BOARD, NOT A MAN. It used to ask whether a person could stand on the
## spot, which is the wrong question for four metres of steel four metres wide: the old
## board cleared it and then grew by half. What is asked now is whether a column of the
## board's own height is clear at the centre and at four points a leg-span out — four,
## and not the two legs, because the board is turned to face the line and its yaw is not
## known until after the spot is chosen.
static func board_spot(query: WorldQuery) -> Vector2:
	for spot: Vector2 in BOARD_SPOTS:
		if _board_fits(query, spot):
			return spot
	return BOARD_SPOTS[BOARD_SPOTS.size() - 1]


static func _board_fits(query: WorldQuery, spot: Vector2) -> bool:
	for step: int in 5:
		var angle: float = float(step - 1) * PI * 0.5
		var at: Vector2 = spot
		if step > 0:
			at += Vector2(cos(angle), sin(angle)) * BOARD_LEG_X
		if not query.can_stand(at.x, at.y, query.ground_h(at.x, at.y), BOARD_TOP + 0.2, 0.4):
			return false
	return true


## The starter's gantry: two posts, a span with a painted band across it, and the low
## lamp bar the five lenses sit on. The bar is at 2.55 m — high enough to run under and
## low enough that a racer reads it without looking away from the road.
static func emit_gantry(m: WorldMesher) -> void:
	for side: float in [-GANTRY_HALF, GANTRY_HALF]:
		m.box(
			Vector3(side, GANTRY_TOP * 0.5, 0),
			Vector3(0.12, GANTRY_TOP * 0.5, 0.12),
			0.0,
			RAIL,
			S_METAL
		)
		m.box(Vector3(side, 0.18, 0), Vector3(0.36, 0.18, 0.36), 0.0, SLAB, S_CONCRETE)
		m.box(Vector3(side, LAMP_BAR_Y, -0.09), Vector3(0.09, 0.30, 0.09), 0.0, RAIL, S_METAL)
	m.box(Vector3(0, GANTRY_LINTEL, 0), Vector3(GANTRY_HALF, 0.17, 0.11), 0.0, RAIL, S_METAL)
	m.box(
		Vector3(0, GANTRY_LINTEL - 0.30, 0),
		Vector3(GANTRY_HALF, 0.14, 0.06),
		0.0,
		WorldPalette.EXFIL,
		S_TIN
	)
	m.box(Vector3(0, LAMP_BAR_Y, -0.10), Vector3(LAMP_BAR_HALF, 0.24, 0.10), 0.0, RAIL, S_METAL)


## The standings board: two legs the full height, a backing plate between them, a rail
## top and bottom, and a painted head band in the demo's own orange so it reads as the
## race's board and not as another notice. Four metres of steel, because it is the first
## thing you should see when you arrive and it is read from the line.
static func emit_board_frame(m: WorldMesher) -> void:
	for side: float in [-BOARD_LEG_X, BOARD_LEG_X]:
		m.box(
			Vector3(side, BOARD_TOP * 0.5, 0),
			Vector3(0.08, BOARD_TOP * 0.5, 0.08),
			0.0,
			RAIL,
			S_METAL
		)
		m.box(Vector3(side, 0.14, 0), Vector3(0.28, 0.14, 0.28), 0.0, SLAB, S_CONCRETE)
	m.box(Vector3(0, BOARD_MID, 0.02), Vector3(BOARD_HALF_W, BOARD_HALF_H, 0.04), 0.0, DECK, S_TIN)
	m.box(
		Vector3(0, 3.76, 0.045),
		Vector3(BOARD_HALF_W - 0.04, 0.26, 0.028),
		0.0,
		WorldPalette.EXFIL,
		S_TIN
	)
	m.box(Vector3(0, 1.42, 0.02), Vector3(BOARD_LEG_X + 0.06, 0.06, 0.06), 0.0, RAIL, S_METAL)
	m.box(Vector3(0, BOARD_TOP, 0.02), Vector3(BOARD_LEG_X + 0.06, 0.06, 0.06), 0.0, RAIL, S_METAL)


## A non-GI mesh that stops drawing past `sight` metres.
static func _mesh_node(node_name: String, mesh: ArrayMesh, sight: float) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = node_name
	mi.mesh = mesh
	mi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	mi.visibility_range_end = sight
	return mi


## Save something and hand back the copy that came off disk. Everything a baked scene
## references has to be the ON-DISK resource, or `pack` embeds the in-memory object and
## the .tscn carries a copy of it instead of a reference to it.
static func _saved(res: Resource, path: String) -> Resource:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var err: Error = ResourceSaver.save(res, path)
	if err != OK:
		push_error("ash_flats_race_build: could not save %s (%d)" % [path, err])
	return ResourceLoader.load(path)
