@tool
extends RefCounted
## THE FINISH GANTRY and THE CHECKPOINT MASTS — everything the race puts in the world so
## that the route reads on sight and the end of it is unmistakable.
##
## Split out of `ash_flats_race_build.gd` because it is signage, not wiring: nothing in
## here is driven at runtime, nothing here decides anything, and all of it is baked.
##
## WHY IT IS THIS LOUD. The line is 190 m of dead town and the last thirty of them are a
## flat carriageway that looks exactly like the ninety before it. A painted stripe on that
## is invisible from the last pitch, which is where you are when you need to know how much
## is left. So the finish is a STRUCTURE: two lattice towers, a hazard-striped banner at
## head height, a lit beam under it, two twelve-metre pennant masts either side, and a
## threshold of lit bars laid across the road on the run in. From the roofline deck, fifty
## metres back and eight metres up, it is the only vertical thing on the carriageway.
##
## THE PALETTE IS THE WHOLE OF THE SIGNAGE. Desaturated warm-neutral steel everywhere,
## the world's own exfil orange for hazard, and GOLD — which appears on the finish, on the
## checkpoint chevrons and nowhere else in this demo. Green is not used here at all: it is
## GO on the start lamps, it means one thing, and it means it because it is used once.

const RAIL: Color = WorldPalette.RAIL
const SLAB: Color = WorldPalette.SLAB
const DECK: Color = WorldPalette.DECK
## The world's exfil orange, which is already the demo's "this one matters" colour.
const AMBER: Color = WorldPalette.EXFIL
## The dark bar of a hazard stripe. Warm-neutral, near black, so the orange carries.
const HAZARD: Color = Color("2b2724")
## The finish's own gold. On the banner, on the line across the road, on the chevrons,
## and nowhere else.
const GOLD: Color = Color("e6c14f")

const S_METAL: int = WorldSurface.Kind.METAL
const S_CONCRETE: int = WorldSurface.Kind.CONCRETE
const S_TIN: int = WorldSurface.Kind.TIN

# --- THE FINISH GANTRY ------------------------------------------------------------
#
# Local origin is on the ground, on the centre line, ON the finish. Racers arrive from
# -Z and leave through +Z, which is the direction the whole line runs.

## Half-span between the tower centres, and the depth of one tower's two posts.
const TOWER_HALF: float = 5.6
const TOWER_DEPTH: float = 0.62
## Tower height, and the heights of the beam under the banner, the banner itself, the
## lintel over it and the gold nameplate.
const TOWER_TOP: float = 8.30
const UNDER_BEAM: float = 5.55
const BANNER_Y: float = 6.15
const LINTEL_Y: float = 6.85
const NAME_Y: float = 7.45
## Half-height of the hazard banner, and how wide one stripe of it is.
const BANNER_HALF: float = 0.52
const STRIPE_W: float = 0.92
## Pennant masts: how far outside the towers they stand, how tall, and the flag.
const MAST_X: float = 6.6
const MAST_TOP: float = 12.0
const FLAG_Y: float = 10.6
## Lamps under the beam: how many, how far apart and how big.
const LAMP_COUNT: int = 9
const LAMP_STEP: float = 1.15
const LAMP_R: float = 0.16
## The threshold laid across the road on the run in: how many bars, their spacing and
## their half-width. They are instanced one at a time onto sampled ground, because the
## carriageway falls about 15 cm across the six metres they cover.
const BAR_COUNT: int = 6
const BAR_STEP: float = 1.55
const BAR_HALF_X: float = 6.0

# --- A CHECKPOINT MAST ------------------------------------------------------------
#
# Local origin is on the deck. One at each edge of the run, so the pair frames the line
# you are meant to take.

## Mast height, and the heights of the gold chevron plate and the orange collar.
const MAST_H: float = 4.60
const PLATE_Y: float = 3.55
const COLLAR_Y: float = 1.30
## Where the lamp on the mast head sits.
const MAST_LAMP_Y: float = 4.74


## The finish gantry, as three baked meshes and a threshold of lit bars.
##
## `meshes` carries `finish`, `finish_gold` and `finish_lamp`; `lamps` carries the three
## baked lamp materials the start line already uses. The gold band and the lamp bar are
## separate meshes ONLY because emission is a material uniform in `scrap_surface` — one
## mesh cannot be lit amber in one place and gold in another.
static func build_finish(
	root: Node3D, query: WorldQuery, meshes: Dictionary, lamps: Dictionary, at: Vector3
) -> Node3D:
	var group := Node3D.new()
	group.name = "Finish"
	group.position = at
	root.add_child(group)
	group.add_child(_mesh_node("Frame", meshes["finish"], 520.0))
	var gold := _mesh_node("Gold", meshes["finish_gold"], 520.0)
	gold.set_surface_override_material(0, lamps["gold"])
	group.add_child(gold)
	var lit := _mesh_node("Lamps", meshes["finish_lamp"], 400.0)
	lit.set_surface_override_material(0, lamps["armed"])
	group.add_child(lit)
	group.add_child(_word("Name", "FINISH", Vector3(0.0, NAME_Y, -0.07), 132, HAZARD, 340.0))

	var legs := StaticBody3D.new()
	legs.name = "Legs"
	legs.collision_layer = GameLayers.WORLD
	legs.collision_mask = 0
	for side: float in [-TOWER_HALF, TOWER_HALF]:
		var box := BoxShape3D.new()
		box.size = Vector3(0.46, TOWER_TOP, TOWER_DEPTH * 2.0 + 0.3)
		var cs := CollisionShape3D.new()
		cs.name = "tower_%d" % int(side)
		cs.shape = box
		cs.position = Vector3(side, TOWER_TOP * 0.5, 0.0)
		cs.set_meta(&"surf", S_METAL)
		legs.add_child(cs)
	group.add_child(legs)

	# The threshold. Each bar is placed on the ground UNDER IT rather than on the
	# gantry's own ground, because the carriageway is still falling here.
	var bars := Node3D.new()
	bars.name = "Threshold"
	group.add_child(bars)
	for i: int in BAR_COUNT:
		var z: float = -BAR_STEP * float(i + 1)
		var bar := _mesh_node("bar_%d" % i, meshes["finish_bar"], 260.0)
		bar.position = Vector3(0.0, query.ground_h(at.x, at.z + z) - at.y + 0.035, z)
		bar.set_surface_override_material(0, lamps["armed" if i % 2 == 0 else "dark"])
		bars.add_child(bar)
	return group


## One checkpoint's pair of masts, and its name when nothing else is carrying it.
##
## `half` is the half-width of the run at that point, so the masts stand ON the edges of
## the deck the checkpoint is on: a pair of posts you run between says "through here" in
## a way a post to one side does not. An empty `label` builds the pair with no name at
## all, which is what a checkpoint whose name is carried by something else asks for.
static func build_check_mast(
	parent: Node3D, meshes: Dictionary, lamps: Dictionary, at: Vector3, half: float, label: String
) -> void:
	var group := Node3D.new()
	group.name = "check_%s" % label.to_lower().replace(" ", "_")
	group.position = at
	parent.add_child(group)
	for side: float in [-half, half]:
		var mast := Node3D.new()
		mast.name = "mast_%d" % int(side * 10.0)
		mast.position = Vector3(side, 0.0, 0.0)
		mast.add_child(_mesh_node("Post", meshes["check_mast"], 300.0))
		var lit := _mesh_node("Lamp", meshes["check_lamp"], 300.0)
		lit.set_surface_override_material(0, lamps["armed"])
		mast.add_child(lit)
		group.add_child(mast)
	if label.is_empty():
		return
	group.add_child(_word("Name", label, Vector3(0.0, MAST_H + 0.55, 0.0), 96, GOLD, 180.0))


## One stencilled word, turned to face the way a racer is coming from.
##
## A Label3D faces its own +Z and the whole line runs +Z, so a name left alone is read
## from behind by everybody who matters — which, double-sided, is the word backwards.
static func _word(
	node_name: String, text: String, at: Vector3, size: int, tint: Color, sight: float
) -> Label3D:
	var label := Label3D.new()
	label.name = node_name
	label.text = text
	label.font = ResourceLoader.load("res://data/ui/font_display.tres") as Font
	label.font_size = size
	label.pixel_size = 0.0034
	label.position = at
	label.modulate = tint
	label.outline_size = 20
	label.outline_modulate = Color(0.05, 0.045, 0.04, 1.0)
	label.visibility_range_end = sight
	label.billboard = BaseMaterial3D.BILLBOARD_DISABLED
	label.double_sided = false
	label.rotation = Vector3(0.0, PI, 0.0)
	return label


## The gantry proper: two lattice towers on plinths, a lintel, a hazard-striped banner
## under it with a backing plate so it is not a row of floating bars, and the beam the
## lamps hang off. Everything overlaps what it is bolted to, so no two faces are coplanar.
static func emit_finish(m: WorldMesher) -> void:
	for side: float in [-TOWER_HALF, TOWER_HALF]:
		_emit_tower(m, side)
	m.box(Vector3(0, LINTEL_Y, 0), Vector3(TOWER_HALF + 0.5, 0.24, 0.16), 0.0, RAIL, S_METAL)
	m.box(Vector3(0, UNDER_BEAM, 0), Vector3(TOWER_HALF + 0.3, 0.15, 0.13), 0.0, RAIL, S_METAL)
	# The banner: a plate, then the stripes stood proud of it on the arriving side.
	m.box(
		Vector3(0, BANNER_Y, 0.02), Vector3(TOWER_HALF + 0.2, BANNER_HALF, 0.05), 0.0, DECK, S_TIN
	)
	var stripes: int = int(floor((TOWER_HALF + 0.2) * 2.0 / STRIPE_W))
	for i: int in stripes:
		var x: float = -TOWER_HALF - 0.2 + STRIPE_W * (float(i) + 0.5)
		m.box(
			Vector3(x, BANNER_Y, -0.045),
			Vector3(STRIPE_W * 0.5, BANNER_HALF - 0.04, 0.035),
			0.0,
			AMBER if i % 2 == 0 else HAZARD,
			S_TIN
		)
	for side: float in [-MAST_X, MAST_X]:
		m.cylinder(Vector3(side, MAST_TOP * 0.5, 0), 0.085, 0.06, MAST_TOP * 0.5, 8, RAIL, S_METAL)
		m.box(Vector3(side, 0.22, 0), Vector3(0.34, 0.22, 0.34), 0.0, SLAB, S_CONCRETE)
		m.box(Vector3(side + 0.52, FLAG_Y, 0.0), Vector3(0.52, 0.62, 0.03), 0.0, GOLD, S_TIN)


## One tower: two posts, a plinth, five rungs and four braces. A solid post reads as a
## pipe from thirty metres; a lattice reads as a gantry, which is the point.
static func _emit_tower(m: WorldMesher, side: float) -> void:
	for depth: float in [-TOWER_DEPTH, TOWER_DEPTH]:
		m.cylinder(
			Vector3(side, TOWER_TOP * 0.5, depth), 0.13, 0.10, TOWER_TOP * 0.5, 8, RAIL, S_METAL
		)
	m.box(Vector3(side, 0.26, 0), Vector3(0.58, 0.26, TOWER_DEPTH + 0.34), 0.0, SLAB, S_CONCRETE)
	for i: int in 5:
		var y: float = 1.15 + 1.72 * float(i)
		m.box(Vector3(side, y, 0), Vector3(0.075, 0.065, TOWER_DEPTH), 0.0, RAIL, S_METAL)
		if i == 4:
			continue
		m.strut(
			Vector3(side, y, -TOWER_DEPTH),
			Vector3(side, y + 1.72, TOWER_DEPTH),
			0.055,
			RAIL,
			S_METAL
		)


## The gold: the nameplate over the lintel and the line painted across the road. Its own
## mesh because it wears its own emissive material.
static func emit_finish_gold(m: WorldMesher) -> void:
	m.box(Vector3(0, NAME_Y, 0.0), Vector3(TOWER_HALF - 0.6, 0.34, 0.06), 0.0, GOLD, S_TIN)
	m.box(Vector3(0, 0.035, 0.0), Vector3(BAR_HALF_X, 0.035, 0.36), 0.0, GOLD, S_TIN)


## The lit parts: the lamp bar under the beam, its lenses, and a beacon on each tower.
static func emit_finish_lamp(m: WorldMesher) -> void:
	m.box(
		Vector3(0, UNDER_BEAM - 0.20, 0), Vector3(TOWER_HALF - 0.2, 0.06, 0.05), 0.0, AMBER, S_METAL
	)
	for i: int in LAMP_COUNT:
		var x: float = (float(i) - float(LAMP_COUNT - 1) * 0.5) * LAMP_STEP
		m.cylinder(Vector3(x, UNDER_BEAM - 0.30, -0.04), LAMP_R, LAMP_R, 0.05, 12, AMBER, S_METAL)
	for side: float in [-TOWER_HALF, TOWER_HALF]:
		m.cylinder(Vector3(side, TOWER_TOP + 0.16, 0), 0.20, 0.14, 0.16, 10, AMBER, S_METAL)


## One bar of the threshold. Instanced, not baked in place, because the road falls under
## it — see `build_finish`.
static func emit_finish_bar(m: WorldMesher) -> void:
	m.box(Vector3(0, 0, 0), Vector3(BAR_HALF_X, 0.035, 0.30), 0.0, AMBER, S_TIN)


## A checkpoint mast: a post on a foot, an orange collar low down where it is read from
## the deck, and a gold chevron plate at head height where it is read from up the course.
static func emit_check_mast(m: WorldMesher) -> void:
	m.box(Vector3(0, 0.11, 0), Vector3(0.27, 0.11, 0.27), 0.0, SLAB, S_CONCRETE)
	m.cylinder(Vector3(0, MAST_H * 0.5, 0), 0.078, 0.062, MAST_H * 0.5, 8, RAIL, S_METAL)
	m.box(Vector3(0, COLLAR_Y, 0), Vector3(0.135, 0.44, 0.135), 0.0, AMBER, S_TIN)
	m.box(Vector3(0, PLATE_Y, 0.0), Vector3(0.50, 0.46, 0.035), 0.0, GOLD, S_TIN)
	m.box(Vector3(0, PLATE_Y, 0.0), Vector3(0.56, 0.07, 0.055), 0.0, RAIL, S_METAL)


## The lamp on a mast head. Its own mesh for the same reason the gantry's is.
static func emit_check_lamp(m: WorldMesher) -> void:
	m.cylinder(Vector3(0, MAST_LAMP_Y, 0), 0.135, 0.10, 0.10, 10, AMBER, S_METAL)


## A non-GI mesh that stops drawing past `sight` metres.
static func _mesh_node(node_name: String, mesh: ArrayMesh, sight: float) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = node_name
	mi.mesh = mesh
	mi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	mi.visibility_range_end = sight
	return mi
