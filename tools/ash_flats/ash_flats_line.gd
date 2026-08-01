@tool
extends RefCounted
## THE ASH LINE: the geometry of the traversal course in `demos/ash_flats`, and the
## table of numbers it is cut from.
##
## Split out of `tools/build_ash_flats.gd` because it is the part of that bake with
## an opinion. Everything else in the builder places something somebody else made;
## this authors a level, and it is the file to open when a gap feels wrong.
##
## `tools/verify_ash_flats.gd` preloads this, calls `course_colliders()`, and drives
## the real `PlayerController` over the result — so the tables below are not a
## description of the course, they are the course.

## The four kinds of run the course is made of: an earth ramp you go up, a pitched
## roof you slide down, a flat deck you land on, and a plank catwalk you balance along.
enum L { RAMP, PITCH, DECK, PLANK }

## The course's own shade-jitter stream, kept apart from the town clutter's so that
## re-tuning a gap length can never re-colour a barrel.
const LINE_SEED: int = 4471 ^ 0x11FE

const RAIL: Color = WorldPalette.RAIL
const SLAB: Color = WorldPalette.SLAB
const S_METAL: int = WorldSurface.Kind.METAL
const S_CONCRETE: int = WorldSurface.Kind.CONCRETE
const S_TIN: int = WorldSurface.Kind.TIN
const S_WOOD: int = WorldSurface.Kind.WOOD
const S_SAND: int = WorldSurface.Kind.SAND

# --- THE ASH LINE ---------------------------------------------------------------------
#
# One descending run down the main carriageway, from the spoil heap at the south end
# to the dry river at the bottom. Every number in `LINE` was chosen against measured
# controller behaviour, not by eye:
#
#   * A SPRINT tops out at 7.50 m/s on any grade, because `ground_target_speed` caps
#     it and no slope adds to it. A SLIDE does not: `slide_step` resolves gravity
#     along the ground plane, so a pitched roof is the only thing in the game that
#     makes you faster than running. Measured off the real controller: a 12 m roof at
#     14 degrees leaves the lip at 11.76 m/s against a sprint's 7.50, an 18 m roof at
#     14 degrees at 12.76, and an 18 m roof at 20 degrees at 14.99.
#   * Every gap therefore has TWO reaches, and the gap sits between them. Measured,
#     jump released at take-off so no vault can rescue it:
#         12 m at 14 deg, landing level        sprint 5.11   slide  6.69
#         12 m at 14 deg, landing 2.0 m below  sprint 6.62   slide  8.70
#         18 m at 14 deg, landing level        sprint 5.15   slide  7.23
#         18 m at 14 deg, landing 2.5 m below  sprint 6.96   slide  9.87
#     `tools/verify_ash_flats.gd` re-measures all of it against the geometry this
#     file actually emits and fails if any gap leaves those bounds.
#   * EVERY LANDING IS AT OR BELOW ITS TAKE-OFF. A landing above the lip is a wall,
#     and a wall with jump held is a manual vault — 7.40 m of free reach that would
#     make every gap on the line trivial. Descending is not a theme here, it is the
#     mechanism.
#
# Widths are generous on the decks and tight on the pitches: the deck is where you
# change line, the pitch is where you commit.

## kind, z0, z1, x centre, width, top y at z0, top y at z1. Everything on the spine
## sits at x -8, which is the centre of the main carriageway: the one strip 230 m
## long that the town bake provably leaves clear at every height a roof can be at.
const LINE: Array[Array] = [
	[L.RAMP, -110.7, -92.7, -8.0, 7.0, 1.40, 11.15],
	[L.DECK, -92.7, -86.7, -8.0, 8.0, 11.15, 11.15],
	[L.PITCH, -86.7, -74.7, -8.0, 6.5, 11.15, 8.16],
	# GAP ONE, 10.00 m, landing 1.85 m down.
	[L.DECK, -64.7, -58.7, -8.0, 8.5, 6.31, 6.31],
	[L.PITCH, -58.7, -44.7, -8.0, 6.5, 6.31, 2.82],
	# GAP TWO, 10.80 m, landing 1.40 m down.
	[L.DECK, -33.9, -28.9, -8.0, 9.0, 1.42, 1.42],
	[L.PITCH, -28.9, -14.9, -8.0, 6.5, 1.42, -2.07],
	# GAP THREE, 10.40 m, landing 1.20 m down, onto the stage in the riverbed.
	[L.DECK, -4.5, -0.6, -8.0, 8.0, -3.27, -3.27],
	# Landing aprons: a plank ledge 0.90 m under each landing deck and just outside
	# it, both sides. They are LATERAL, never in the gap — a jump that is long enough
	# but wide catches one instead of going to the street, and a gap length still
	# means what the table says it means.
	[L.PLANK, -64.7, -58.7, -3.05, 1.4, 5.41, 5.41],
	[L.PLANK, -64.7, -58.7, -12.95, 1.4, 5.41, 5.41],
	[L.PLANK, -33.9, -28.9, -2.80, 1.2, 0.52, 0.52],
	[L.PLANK, -33.9, -28.9, -13.20, 1.2, 0.52, 0.52],
	# Recovery. One rubble ramp back up to the low deck, standing in the second gap's
	# void where nothing is overhead and 2.5 m clear of the flight line. Off the top
	# half there is no shortcut back: you run to the berm, which is forty metres and
	# about six seconds, and that is what missing costs.
	[L.RAMP, -39.5, -34.1, -12.2, 2.6, -0.30, 1.42],
]
## Column indices into a `LINE` row.
const P_KIND: int = 0
const P_Z0: int = 1
const P_Z1: int = 2
const P_X: int = 3
const P_W: int = 4
const P_Y0: int = 5
const P_Y1: int = 6

## Deck and pitch thickness, metres. Thick enough that the underside reads as a
## roof slab rather than as paper when you are standing in the street below it.
const LINE_THICK: float = 0.62
const PLANK_THICK: float = 0.26
## Metres between piers along a run, and pier half-width.
const PIER_STEP: float = 5.0
const PIER_HALF: float = 0.40
## Edge rail height and thickness. The rail is a kerb you can stand on, not a wall.
const RAIL_H: float = 0.34
const RAIL_T: float = 0.11

## The three gaps, as (take-off z, landing z). They are the holes between the LINE
## rows above and are listed again here because they are the numbers the design is
## actually about — and because `verify_ash_flats.gd` reads them.
const GAPS: Array[Array] = [
	["GAP ONE", -74.7, -64.7, 8.16, 6.31],
	["GAP TWO", -44.7, -33.9, 2.82, 1.42],
	["GAP THREE", -14.9, -4.5, -2.07, -3.27],
]
const G_NAME: int = 0
const G_Z0: int = 1
const G_Z1: int = 2
const G_Y0: int = 3
const G_Y1: int = 4

## The timing gates, in order: name, x, z, deck top y (NAN means stand on the
## ground). The first arms the clock, the last stops it, the middle two are splits.
## START sits 6.5 m from the spawn, which is further than `GATE_RADIUS`: spawn inside
## your own start line and the clock is running before you have decided to go.
const GATES: Array[Array] = [
	["START", -8.0, -112.0, NAN],
	["CREST", -8.0, -89.7, 11.15],
	["MIDWAY", -8.0, -31.4, 1.42],
	["FINISH", -8.0, 10.0, NAN],
]
const T_NAME: int = 0
const T_X: int = 1
const T_Z: int = 2
const T_Y: int = 3
## Radius the course watcher trips a gate at, metres.
const GATE_RADIUS: float = 4.6


## The course, as one mesh and one static body.
##
## ONE MESH for the whole thing, because the alternative is fourteen decks and forty
## piers as forty-odd `MeshInstance3D`s and a demo that draws the course more times
## than it draws the town. The colliders have to stay separate boxes — a trimesh of
## the same soup would cost the player controller a triangle query per substep where
## a box costs a plane test.
static func build(
	root: Node3D, query: WorldQuery, material: Material, mesh_dir: String
) -> Dictionary:
	var group := Node3D.new()
	group.name = "AshLine"
	root.add_child(group)
	var body := StaticBody3D.new()
	body.name = "Colliders"
	body.collision_layer = GameLayers.WORLD
	body.collision_mask = 0
	group.add_child(body)

	var rng := XorShift32.new(LINE_SEED)
	var m := WorldMesher.new()
	var shapes: int = 0
	var piers: int = 0
	var skipped: int = 0
	var lines: Array[String] = []
	for row: Array in LINE:
		var kind: int = int(row[P_KIND])
		var thick: float = PLANK_THICK if kind == L.PLANK else LINE_THICK
		var col: Color = _line_colour(kind, rng)
		var surf: int = _line_surface(kind)
		shapes += _slab_piece(m, body, row, thick, col, surf)
		shapes += _batter(m, body, row, rng)
		var made: Array[int] = _piers(m, body, row, thick, query, rng)
		piers += made[0]
		skipped += made[1]
		shapes += made[0]
		if kind != L.PITCH:
			shapes += _edge_rails(m, body, row, thick, rng)
		lines.append(
			(
				"  %-6s z %7.1f -> %7.1f  x %6.1f  w %4.1f  y %6.2f -> %6.2f  %5.1f deg"
				% [
					["ramp", "pitch", "deck", "plank"][kind],
					row[P_Z0],
					row[P_Z1],
					row[P_X],
					row[P_W],
					row[P_Y0],
					row[P_Y1],
					rad_to_deg(
						atan2(
							float(row[P_Y0]) - float(row[P_Y1]),
							absf(float(row[P_Z1]) - float(row[P_Z0]))
						)
					)
				]
			)
		)
	for gap: Array in GAPS:
		lines.append(
			(
				"  GAP    %-10s  %5.2f m across, landing %4.2f m below the lip"
				% [
					gap[G_NAME],
					float(gap[G_Z1]) - float(gap[G_Z0]),
					float(gap[G_Y0]) - float(gap[G_Y1])
				]
			)
		)

	var mesh: ArrayMesh = m.build_mesh(material)
	var path: String = "%s/ash_line.res" % mesh_dir
	_save(mesh, path)
	var mi := MeshInstance3D.new()
	mi.name = "Mesh"
	mi.mesh = ResourceLoader.load(path) as ArrayMesh
	mi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	group.add_child(mi)
	(
		lines
		. append(
			(
				"  built  %d tris, vol %+.3f, conflicts %d, degenerate %d, %d shapes, %d piers (%d refused)"
				% [
					m.triangle_count(),
					m.signed_volume(),
					m.normal_conflicts(),
					m.degenerate_count(),
					shapes,
					piers,
					skipped
				]
			)
		)
	)
	return {"lines": lines}


## One deck, pitch, ramp or plank: a slab whose top face runs from (z0, y0) to
## (z1, y1). Emitted as an oriented box so the pitch is a real inclined solid rather
## than a staircase of level boxes, and matched by one `BoxShape3D` on the same frame.
static func _slab_piece(
	m: WorldMesher, body: StaticBody3D, row: Array, thick: float, col: Color, surf: int
) -> int:
	var frame: Dictionary = _frame(row, thick)
	m.oriented_box(frame["centre"], frame["ex"], frame["ey"], frame["ez"], col, surf)
	_shape(
		body,
		frame,
		"%s_%d" % [["ramp", "pitch", "deck", "plank"][int(row[P_KIND])], int(row[P_Z0])],
		surf
	)
	return 1


## The oriented frame of a run. `ey` is the slab's own up — the surface normal — so
## the solid is a prism about the sloped plane and its underside is parallel to its
## top, which is what makes a chain of them read as one roof line.
static func _frame(row: Array, thick: float) -> Dictionary:
	var z0: float = row[P_Z0]
	var z1: float = row[P_Z1]
	var y0: float = row[P_Y0]
	var y1: float = row[P_Y1]
	# Always walk the run in +Z. A row written the other way round (the recovery
	# ramps are, because they climb back south) describes the same solid, and
	# normalising here is what keeps `ex x ey = +ez` — the right-handed frame
	# `oriented_box` needs — true for every row without a second case.
	if z1 < z0:
		var tz: float = z0
		var ty: float = y0
		z0 = z1
		y0 = y1
		z1 = tz
		y1 = ty
	var dz: float = z1 - z0
	var dy: float = y1 - y0
	var run: float = sqrt(dz * dz + dy * dy)
	var along := Vector3(0.0, dy / run, dz / run)
	# The surface normal is `along` turned a quarter turn in the YZ plane. With
	# `along.z` positive by construction this always points up.
	var up := Vector3(0.0, along.z, -along.y)
	var centre := Vector3(row[P_X], (y0 + y1) * 0.5, (z0 + z1) * 0.5) - up * (thick * 0.5)
	return {
		"centre": centre,
		"ex": Vector3(float(row[P_W]) * 0.5, 0.0, 0.0),
		"ey": up * (thick * 0.5),
		"ez": along * (run * 0.5),
		"size": Vector3(float(row[P_W]), thick, run),
		"basis": Basis(Vector3.RIGHT, up.normalized(), along.normalized()),
	}


static func _shape(body: StaticBody3D, frame: Dictionary, shape_name: String, surf: int) -> void:
	var box := BoxShape3D.new()
	box.size = frame["size"]
	var cs := CollisionShape3D.new()
	cs.name = shape_name
	cs.shape = box
	cs.transform = Transform3D(frame["basis"], frame["centre"])
	cs.set_meta(&"surf", surf)
	body.add_child(cs)


## Adobe piers under a run, down to whatever the world is at that spot. A pier whose
## foot is inside a baked collider is refused rather than shoved through it — the same
## rule the clutter scatter follows, for the same reason.
static func _piers(
	m: WorldMesher, body: StaticBody3D, row: Array, thick: float, query: WorldQuery, rng: XorShift32
) -> Array[int]:
	if int(row[P_KIND]) == L.RAMP:
		return [0, 0]
	var z0: float = minf(float(row[P_Z0]), float(row[P_Z1]))
	var z1: float = maxf(float(row[P_Z0]), float(row[P_Z1]))
	var half_w: float = float(row[P_W]) * 0.5 - PIER_HALF - 0.15
	var steps: int = maxi(1, int(round((z1 - z0) / PIER_STEP)))
	var made: int = 0
	var refused: int = 0
	for i: int in steps + 1:
		var z: float = lerpf(z0 + 0.6, z1 - 0.6, float(i) / float(steps))
		var top: float = top_at(row, z) - thick
		for side: float in [-half_w, half_w]:
			var x: float = float(row[P_X]) + side
			var g: float = query.ground_h(x, z)
			if top - g < 0.35:
				continue
			if not query.can_stand(x, z, g, minf(top - g, 2.0), PIER_HALF):
				refused += 1
				continue
			var h: float = (top - g) * 0.5
			var centre := Vector3(x, g + h, z)
			var col: Color = WorldPalette.vary(
				WorldPalette.pick(Palette.WORLD_ADOBE, rng), rng, 0.08
			)
			m.box(centre, Vector3(PIER_HALF, h, PIER_HALF), 0.0, col, S_CONCRETE)
			var frame: Dictionary = {
				"centre": centre,
				"size": Vector3(PIER_HALF * 2.0, h * 2.0, PIER_HALF * 2.0),
				"basis": Basis.IDENTITY,
			}
			_shape(body, frame, "pier_%d_%d" % [int(z * 10.0), int(x * 10.0)], S_CONCRETE)
			made += 1
	return [made, refused]


## Two stepped shoulders of spoil under a wide earth ramp, each one wider and lower
## than the last. Without them the berm is a seven-metre plank of sand standing on
## nothing, which is what it looked like in the first render: a wedge, not a heap.
## Narrow ramps get none — the recovery ramp is a rubble pile against a kerb and does
## not need a skirt, and a skirt on it would reach into the second gap.
static func _batter(m: WorldMesher, body: StaticBody3D, row: Array, rng: XorShift32) -> int:
	if int(row[P_KIND]) != L.RAMP or float(row[P_W]) < 6.0:
		return 0
	var made: int = 0
	for step: int in 2:
		var wide: float = float(row[P_W]) + 1.7 + 1.7 * float(step)
		var down: float = 0.55 + 0.70 * float(step)
		var skirt: Array = [
			L.RAMP,
			row[P_Z0],
			row[P_Z1],
			row[P_X],
			wide,
			float(row[P_Y0]) - down,
			float(row[P_Y1]) - down
		]
		var frame: Dictionary = _frame(skirt, LINE_THICK + down)
		var col: Color = WorldPalette.vary(WorldPalette.pick(Palette.WORLD_SAND, rng), rng, 0.07)
		m.oriented_box(frame["centre"], frame["ex"], frame["ey"], frame["ez"], col, S_SAND)
		_shape(body, frame, "batter_%d_%d" % [int(row[P_Z0]), step], S_SAND)
		made += 1
	return made


## A timber kerb rail down both long edges of a deck. It is 0.34 m tall, which is a
## step-up the controller takes silently — you can land on it, stand on it and run off
## it, and it still reads from the street as the edge of a roof.
static func _edge_rails(
	m: WorldMesher, body: StaticBody3D, row: Array, thick: float, rng: XorShift32
) -> int:
	var made: int = 0
	for rail_row: Array in rail_rows(row):
		var frame: Dictionary = _frame(rail_row, RAIL_H + thick * 0.5)
		var col: Color = WorldPalette.vary(WorldPalette.pick(Palette.WORLD_WOOD, rng), rng, 0.1)
		m.oriented_box(frame["centre"], frame["ex"], frame["ey"], frame["ez"], col, S_WOOD)
		_shape(
			body,
			frame,
			"rail_%d_%d" % [int(rail_row[P_Z0]), int(float(rail_row[P_X]) * 10.0)],
			S_WOOD
		)
		made += 1
	return made


## The two rail runs down the long edges of a deck, as `LINE` rows in their own right.
## Shared with `course_colliders`, so the harness lands on the same kerbs the player does.
static func rail_rows(row: Array) -> Array[Array]:
	var z0: float = minf(float(row[P_Z0]), float(row[P_Z1]))
	var z1: float = maxf(float(row[P_Z0]), float(row[P_Z1]))
	var y0: float = top_at(row, z0)
	var y1: float = top_at(row, z1)
	var out: Array[Array] = []
	for side: float in [-1.0, 1.0]:
		var x: float = float(row[P_X]) + side * (float(row[P_W]) * 0.5 - RAIL_T)
		out.append([L.DECK, z0, z1, x, RAIL_T * 2.0, y0 + RAIL_H, y1 + RAIL_H])
	return out


## The walkable set of the course as a bare `StaticBody3D` — every deck, pitch, ramp,
## plank and kerb, and nothing else. `tools/verify_ash_flats.gd` drops the real player
## onto exactly this, which is the only way the numbers in `GAPS` mean anything: the
## harness is not measuring a model of the course, it is measuring the course.
static func course_colliders() -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = "AshLine"
	body.collision_layer = GameLayers.WORLD
	body.collision_mask = 0
	for row: Array in LINE:
		var kind: int = int(row[P_KIND])
		var thick: float = PLANK_THICK if kind == L.PLANK else LINE_THICK
		_shape(
			body,
			_frame(row, thick),
			"%s_%d" % [["ramp", "pitch", "deck", "plank"][kind], int(row[P_Z0])],
			_line_surface(kind)
		)
		if kind != L.DECK and kind != L.PLANK:
			continue
		for rail_row: Array in rail_rows(row):
			_shape(
				body,
				_frame(rail_row, RAIL_H + thick * 0.5),
				"rail_%d_%d" % [int(rail_row[P_Z0]), int(float(rail_row[P_X]) * 10.0)],
				S_WOOD
			)
	return body


## Top surface height of a run at a given z. Public because the harness sites its
## run-ups off it.
static func top_at(row: Array, z: float) -> float:
	var z0: float = row[P_Z0]
	var z1: float = row[P_Z1]
	if absf(z1 - z0) < 1e-5:
		return row[P_Y0]
	return lerpf(float(row[P_Y0]), float(row[P_Y1]), clampf((z - z0) / (z1 - z0), 0.0, 1.0))


static func _line_colour(kind: int, rng: XorShift32) -> Color:
	match kind:
		L.RAMP:
			return WorldPalette.vary(WorldPalette.pick(Palette.WORLD_SAND, rng), rng, 0.08)
		L.PLANK:
			return WorldPalette.vary(WorldPalette.pick(Palette.WORLD_WOOD, rng), rng, 0.10)
		_:
			return WorldPalette.vary(WorldPalette.pick(Palette.WORLD_ADOBE, rng), rng, 0.09)


static func _line_surface(kind: int) -> int:
	match kind:
		L.RAMP:
			return S_SAND
		L.PLANK:
			return S_WOOD
		_:
			return S_CONCRETE


## A steel goalpost over the line at each timing gate, with the gate's name
## stencilled across the lintel. This is the whole of the course's signage: no
## screen-space overlay, no floating arrow, a thing you run through.
static func build_gates(
	root: Node3D, material: Material, mesh_dir: String, course_script: GDScript
) -> int:
	var group := Node3D.new()
	group.name = "Gates"
	root.add_child(group)
	var query: WorldQuery = WorldQuery.load_baked()
	# One mesh resource, four instances of it. Building four `ArrayMesh`es here would
	# embed four copies of the same 200 triangles in the .tscn.
	var m := WorldMesher.new()
	_emit_gate(m)
	var gate_path: String = "%s/gate.res" % mesh_dir
	_save(m.build_mesh(material), gate_path)
	var gate_mesh := ResourceLoader.load(gate_path) as ArrayMesh
	var positions := PackedVector3Array()
	var names := PackedStringArray()
	for i: int in GATES.size():
		var row: Array = GATES[i]
		var x: float = row[T_X]
		var z: float = row[T_Z]
		var y: float = row[T_Y]
		if is_nan(y):
			y = query.ground_h(x, z)
		var gate := Node3D.new()
		gate.name = "gate_%d_%s" % [i, String(row[T_NAME]).to_lower()]
		gate.position = Vector3(x, y, z)
		gate.add_child(_mesh_node("Frame", gate_mesh, 220.0))
		# The two legs are solid. A post you can run through is the kind of defect
		# that is invisible in a screenshot and obvious the first time you clip one.
		var legs := StaticBody3D.new()
		legs.name = "Legs"
		legs.collision_layer = GameLayers.WORLD
		legs.collision_mask = 0
		for side: float in [-3.3, 3.3]:
			var box := BoxShape3D.new()
			box.size = Vector3(0.20, 4.20, 0.20)
			var cs := CollisionShape3D.new()
			cs.name = "leg_%d" % int(side)
			cs.shape = box
			cs.position = Vector3(side, 2.1, 0.0)
			cs.set_meta(&"surf", S_METAL)
			legs.add_child(cs)
		gate.add_child(legs)
		var label := Label3D.new()
		label.name = "Name"
		label.text = row[T_NAME]
		label.font_size = 110
		# Stencilled ON the lintel's painted band rather than floating over it: you
		# spawn four metres from the start gate, and a name above the beam at that
		# range is off the top of the screen.
		label.pixel_size = 0.0026
		label.position = Vector3(0.0, 3.86, -0.075)
		label.modulate = WorldPalette.EXFIL if i == 0 or i == GATES.size() - 1 else Palette.BONE
		label.outline_size = 20
		label.outline_modulate = Color(0.05, 0.045, 0.04, 1.0)
		label.visibility_range_end = 150.0
		label.billboard = BaseMaterial3D.BILLBOARD_DISABLED
		# A Label3D's text faces its own +Z. The line runs +Z, so a runner arrives
		# looking at the back of one — which, double-sided, is the name spelled
		# backwards. Turn it to face the way they are coming from.
		label.rotation = Vector3(0.0, PI, 0.0)
		label.double_sided = false
		gate.add_child(label)
		group.add_child(gate)
		positions.push_back(Vector3(x, y, z))
		names.push_back(row[T_NAME])

	var course := Node.new()
	course.name = "Course"
	course.set_script(course_script)
	course.set(&"gate_names", names)
	course.set(&"gate_positions", positions)
	course.set(&"gate_radius", GATE_RADIUS)
	root.add_child(course)
	return GATES.size()


## Two legs on two feet, a lintel, and a painted band across the deck under it.
static func _emit_gate(m: WorldMesher) -> void:
	for side: float in [-3.3, 3.3]:
		m.box(Vector3(side, 2.1, 0.0), Vector3(0.10, 2.1, 0.10), 0.0, RAIL, S_METAL)
		m.box(Vector3(side, 0.14, 0.0), Vector3(0.30, 0.14, 0.30), 0.0, SLAB, S_CONCRETE)
	m.box(Vector3(0.0, 4.14, 0.0), Vector3(3.4, 0.16, 0.09), 0.0, RAIL, S_METAL)
	m.box(Vector3(0.0, 3.86, 0.0), Vector3(3.4, 0.13, 0.05), 0.0, WorldPalette.EXFIL, S_TIN)
	m.box(Vector3(0.0, 0.045, 0.0), Vector3(3.3, 0.045, 0.34), 0.0, WorldPalette.EXFIL, S_TIN)


## A non-GI mesh that stops drawing past `sight` metres.
static func _mesh_node(node_name: String, mesh: ArrayMesh, sight: float) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = node_name
	mi.mesh = mesh
	mi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	mi.visibility_range_end = sight
	return mi


static func _save(res: Resource, path: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var err: Error = ResourceSaver.save(res, path)
	if err != OK:
		push_error("ash_flats_line: could not save %s (%d)" % [path, err])
