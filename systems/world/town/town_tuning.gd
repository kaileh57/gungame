class_name TownTuning
extends PropTuning
## Every knob the town LAYOUT turns, on top of the ones every generator turns.
##
## The building and clutter knobs — joint overlap, ladder pitch, stair riser,
## round-prop segment counts, wire sag, the three `fix_*` corrections — are
## inherited from `PropTuning`, because the town is built out of exactly the
## generators in `res://systems/world/props/` and there is only one set of them.
## What is added here is the plan: extents, streets, lots, the wilds, the pads and
## the bake parameters.
##
## These are not cosmetic. The generator draws from a single xorshift stream and
## most of these values sit upstream of a draw, so nudging one re-rolls the town
## from that point on. That is the intent: this is the dial box for the fine-tune
## pass, not a set of runtime options. Bake after every change.

## The seed the whole map follows from. The reference ships 4471.
@export_range(0, 4294967295, 1) var world_seed: int = 4471

@export_group("Extent")
## Half-width of the built-up quadrants, metres. The BSP never leaves this box.
@export_range(40.0, 240.0, 0.5) var town_half_extent: float = 118.0
## Centre of the plaza, metres.
@export var plaza_center: Vector2 = Vector2(4.0, 6.0)
## Plaza keep-out radius. Blocks whose centre falls inside get gravel and props
## instead of buildings.
@export_range(8.0, 60.0, 0.5) var plaza_radius: float = 26.0

@export_group("Streets")
## The north-south main strip.
@export_range(4.0, 20.0, 0.1) var main_strip_width: float = 11.5
## The east-west cross street.
@export_range(4.0, 20.0, 0.1) var cross_street_width: float = 9.5
## How many times the BSP may cut a quadrant.
@export_range(1, 6, 1) var bsp_depth: int = 4
## A cut that would leave either side thinner than this is refused.
@export_range(8.0, 40.0, 0.5) var bsp_min_keep: float = 20.0
## A rectangle smaller than this in BOTH axes is never cut again.
@export_range(16.0, 80.0, 0.5) var bsp_min_split: float = 34.0
## Carriageway width per BSP level, coarsest first.
##
## The reference indexes this list one place late and never reads entry 0; that
## is reproduced, because the whole street hierarchy — and every rng draw after
## it — hangs off the widths that actually come out. Entry 0 is therefore dead
## weight kept for shape, and the real widths are 6.5 / 5.0 / 4.0 / 3.4 / 3.4.
@export var road_widths: PackedFloat32Array = [8.5, 6.5, 5.0, 4.0, 3.4]

@export_group("Lots")
## Smallest lot the subdivider will cut towards.
@export_range(4.0, 20.0, 0.5) var lot_min_size: float = 9.5
## Chance a lot stops subdividing early and stays large.
@export_range(0.0, 1.0, 0.01) var lot_stop_chance: float = 0.16
## Block roll below which a big enough block becomes a warehouse.
@export_range(0.0, 1.0, 0.01) var warehouse_chance: float = 0.20
## Block roll below which a big enough block becomes a walled compound.
@export_range(0.0, 1.0, 0.01) var compound_chance: float = 0.30

@export_group("Houses")
## Storey-count probability floors, far from the core.
@export_range(0.0, 1.0, 0.01) var floor2_base: float = 0.22
@export_range(0.0, 1.0, 0.01) var floor3_base: float = 0.07
@export_range(0.0, 1.0, 0.01) var floor4_base: float = 0.02
## How much the town core adds to each of those.
@export_range(0.0, 1.0, 0.01) var floor2_core: float = 0.44
@export_range(0.0, 1.0, 0.01) var floor3_core: float = 0.28
@export_range(0.0, 1.0, 0.01) var floor4_core: float = 0.10
## The band over which "near the core" falls off, metres.
@export_range(0.0, 200.0, 1.0) var core_near: float = 20.0
@export_range(0.0, 400.0, 1.0) var core_far: float = 110.0

@export_group("Roof links")
## Chance a viable roof-to-roof gap actually gets a plank.
@export_range(0.0, 1.0, 0.01) var roof_link_chance: float = 0.72
## Largest roof-height difference a plank will bridge, metres.
@export_range(0.0, 4.0, 0.05) var roof_link_max_step: float = 1.35
## Chance a plank gets a handrail.
@export_range(0.0, 1.0, 0.01) var roof_rail_chance: float = 0.45

@export_group("Clutter")
## Items strewn along the two main streets.
@export_range(0, 200, 1) var street_clutter: int = 46
## Keep-out radius around the plaza centre for street clutter, metres.
@export_range(0.0, 40.0, 0.5) var street_clutter_keepout: float = 13.0

@export_group("Wilds")
## Scatter attempts outside the town.
@export_range(0, 1200, 1) var wilds_count: int = 260
## Inner radius of the scatter annulus, metres.
@export_range(60.0, 400.0, 1.0) var wilds_inner: float = 140.0
## Radial span added to the inner radius, metres.
@export_range(50.0, 600.0, 1.0) var wilds_span: float = 300.0
## Exponent on the radial draw. Below 1 biases outward.
@export_range(0.2, 3.0, 0.01) var wilds_radius_bias: float = 0.6
## Hard clamp on |x| and |z| for scattered props, metres.
@export_range(100.0, 880.0, 1.0) var wilds_bound: float = 430.0
## Minimum ground normal Y a scatter site must have. Nothing sits on a dune face.
@export_range(0.0, 1.0, 0.01) var wilds_min_normal: float = 0.72
## Minimum ground normal Y inside an outlying camp — camps want flatter ground.
@export_range(0.0, 1.0, 0.01) var camp_min_normal: float = 0.80

@export_group("Exfil")
## Trigger radius and painted-ring radius of an extraction pad, metres.
@export_range(1.0, 20.0, 0.1) var exfil_radius: float = 4.6
## A rooftop LZ must be inside this radius of the origin.
@export_range(20.0, 300.0, 1.0) var rooftop_max_radius: float = 105.0
## A rooftop LZ must be at least this wide in its narrow axis, metres.
@export_range(4.0, 40.0, 0.5) var rooftop_min_width: float = 11.0

@export_group("Bake")
## Edge of a town chunk, metres. One draw call per chunk, so bigger is cheaper to
## draw and coarser to cull; 48 m puts a street block or two in each.
@export_range(16.0, 160.0, 1.0) var chunk_size: float = 48.0
## Half-extent of the square the navmesh is baked over, metres. Recast cost grows
## with the square of this, and the AI never fights out in the deep wilds.
@export_range(50.0, 440.0, 5.0) var nav_half_extent: float = 150.0
## Recast voxel size, metres. Recast rounds the agent envelope to whole voxels,
## so these two are chosen to divide it exactly: 0.21 puts the 0.42 m radius at
## two cells and 0.145 puts the 0.58 m step at four. Off-multiples silently
## inflate the agent — a radius rounded up to 0.80 m fences the AI out of every
## alley in town.
@export_range(0.05, 1.0, 0.005) var nav_cell_size: float = 0.21
@export_range(0.05, 1.0, 0.005) var nav_cell_height: float = 0.145
## Smallest island Recast will keep, in voxel cells. Low values leave a scrap of
## navmesh on every crate lid; the AI cannot reach those and pathfinding pays for
## them on every query.
@export_range(1.0, 64.0, 1.0) var nav_region_min: float = 10.0
@export_range(1.0, 128.0, 1.0) var nav_region_merge: float = 24.0
## Agent envelope the navmesh is carved for. Matches the player capsule so the AI
## cannot path anywhere the player could not follow.
@export_range(0.1, 2.0, 0.01) var nav_agent_radius: float = 0.42
@export_range(0.5, 4.0, 0.01) var nav_agent_height: float = 1.80
@export_range(0.0, 1.5, 0.01) var nav_agent_max_climb: float = 0.58
@export_range(5.0, 80.0, 0.5) var nav_agent_max_slope: float = 46.0
## How far a building's occluder is pulled inside its own walls, metres. An
## occluder that pokes through a facade culls what is standing in front of it.
@export_range(0.0, 2.0, 0.05) var occluder_inset: float = 0.35
## Buildings narrower than this contribute no occluder — the cost of testing them
## outweighs what they hide.
@export_range(0.0, 20.0, 0.5) var occluder_min_size: float = 5.0
