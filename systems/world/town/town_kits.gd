class_name TownKits
extends RefCounted
## Six self-contained pieces of environment, built on a flat pan at y = 0 and
## centred on their own origin, so a demo can drop one anywhere with a single
## `instantiate()` and never author geometry.
##
## Each kit is built by the same generators the town uses, from its own rng
## stream — nothing here perturbs the map. The pan is flat because a kit does not
## know what ground it will land on; place one so its origin sits on the terrain
## and the foundations, which all reach 0.5 to 1.0 m below zero, swallow the
## mismatch.
##
## Bake-time only. `tools/build_town.gd` turns what these produce into the scenes
## under `res://data/world/kits/`.

## Kit stream salt. Each kit adds its index, so adding one never re-rolls the
## others.
const SALT_KITS: int = 0x4B17

## Kit identifiers, in bake order. These strings are the scene basenames.
const IDS: PackedStringArray = [
	"compound", "street_block", "range_bay", "plaza", "watchtower", "ruin_cluster"
]

## One-line descriptions, indexed to `IDS`. The bake writes these into the report
## and onto the scene root so an editor session can read them.
const BLURBS: PackedStringArray = [
	"Walled yard, 24 x 24 m, one gate on -Z, single-storey shack inside.",
	"Three adobe houses along +X with a paved frontage on -Z.",
	"Firing bay, 20 x 40 m, stepped earth berms on three sides, open to -Z.",
	"Town square: gutted road hauler, loading ramp, signpost, market row.",
	"Water tower on four braced legs, railed platform, ladder to the top.",
	"Three collapsed blocks with rubble ramps, dead trees and a wreck.",
]

## Range bay: half-width of the lane, and how far up and down range it runs.
const BAY_HALF_W: float = 7.0
const BAY_HALF_L: float = 17.0
## Berm thickness at the foot, and the height of its three courses.
const BERM_THICK: float = 3.0
const BERM_STEPS: PackedFloat32Array = [1.2, 2.2, 3.2]
## How far every kit's slab and berm reach below zero. Deep enough that placing a
## kit on real terrain never opens a gap at the hem.
const KIT_SKIRT: float = 0.30


## Build one kit. `index` must be its position in `IDS`.
static func build(index: int, tuning: TownTuning) -> WorldTown:
	var r := XorShift32.new((tuning.world_seed ^ SALT_KITS) + index * 7919)
	var town := WorldTown.new(r, tuning, null)
	match IDS[index]:
		"compound":
			_compound(town)
		"street_block":
			_street_block(town)
		"range_bay":
			_range_bay(town)
		"plaza":
			TownLayout.plaza(town, 0.0, 0.0)
		"watchtower":
			_watchtower(town)
		"ruin_cluster":
			_ruin_cluster(town)
	return town


# ------------------------------------------------------------------- compound


static func _compound(town: WorldTown) -> void:
	town.register(PropBuildings.compound(town, 0.0, 0.0, 24.0, 24.0, 0.0))


# ---------------------------------------------------------------- street block


static func _street_block(town: WorldTown) -> void:
	var r: XorShift32 = town.rng
	# Frontage first: the houses sit back from it, so the slab is under them and
	# there is no seam where the two meet.
	town.solid(
		Vector3(0.0, -KIT_SKIRT, -9.5),
		Vector3(17.0, KIT_SKIRT, 3.0),
		0.0,
		Palette.WORLD_ASPHALT[0],
		WorldSurface.Kind.ASPHALT
	)
	var floors: PackedInt32Array = [2, 1, 3]
	for i in 3:
		var x: float = -11.0 + float(i) * 11.0
		town.register(PropBuildings.adobe(town, x, 0.0, 9.0, 9.0, floors[i], 0.0, 0.0, 0))
	for _i in 6:
		var px: float = r.next_range(-16.0, 16.0)
		var pz: float = r.next_range(-7.0, -6.0)
		if r.chance(0.5):
			PropClutter.barrel(town, px, 0.0, pz)
		else:
			PropClutter.crate(town, px, 0.0, pz, r.next() * 3.0)
	PropClutter.wreck(town, 12.0, -8.0, 0.15)
	PropClutter.sandbags(town, -14.0, 0.0, -6.5, 0.0)


# ------------------------------------------------------------------ range bay


## A firing bay: a hard pad, a stepped earth bank on three sides, a bench at the
## firing line and three target frames down range.
##
## The bank is three courses of boxes that all reach below zero, so it steps up
## like a graded berm with nothing single-sided anywhere.
##
## Every course is grown outward, downward and inward by one more `joint_overlap`
## than the one under it, and the end wall reaches past the inner face of the side
## walls rather than up to it. Butted, the two walls of a corner share the vertical
## line where four faces meet, and four faces on one edge is a non-manifold seam
## that opens the moment anything moves. Nothing in this bay shares a plane with
## anything else.
static func _range_bay(town: WorldTown) -> void:
	var pad_c: Color = Palette.WORLD_CONCRETE[2]
	town.solid(
		Vector3(0.0, -KIT_SKIRT, 0.0),
		Vector3(BAY_HALF_W, KIT_SKIRT, BAY_HALF_L),
		0.0,
		pad_c,
		WorldSurface.Kind.CONCRETE
	)
	var earth: Color = Palette.WORLD_ROCK[2]
	var ov: float = town.tuning.joint_overlap
	for k in BERM_STEPS.size():
		var lift: float = float(k) * ov
		var outer_x: float = BAY_HALF_W + BERM_THICK + lift
		var outer_z: float = BAY_HALF_L + BERM_THICK + lift
		var top: float = BERM_STEPS[k]
		var inset: float = BERM_THICK * float(k) / float(BERM_STEPS.size())
		var foot: float = KIT_SKIRT + lift
		var half_y: float = (top + foot) * 0.5
		var cy: float = (top - foot) * 0.5
		var hx: float = (BERM_THICK - inset) * 0.5 + ov
		for sg: float in [-1.0, 1.0]:
			town.solid(
				Vector3(sg * (outer_x - hx), cy, 0.0),
				Vector3(hx, half_y, outer_z),
				0.0,
				earth,
				WorldSurface.Kind.ROCK
			)
		# Reaches `ov` into both side walls, and its own outer face stops short of
		# theirs by an odd multiple of `ov` so no two courses line up either.
		town.solid(
			Vector3(0.0, cy, outer_z - hx - ov * float(2 * k + 1)),
			Vector3(outer_x - hx * 2.0 + ov, half_y, hx),
			0.0,
			earth,
			WorldSurface.Kind.ROCK
		)

	# Firing bench, set into the open end.
	town.solid(
		Vector3(0.0, 0.45, -BAY_HALF_L + 2.4),
		Vector3(BAY_HALF_W - 1.0, 0.45, 0.45),
		0.0,
		Palette.WORLD_CONCRETE[0],
		WorldSurface.Kind.CONCRETE
	)
	for i in 3:
		var x: float = -4.0 + float(i) * 4.0
		for sg: float in [-1.0, 1.0]:
			town.solid(
				Vector3(x + sg * 0.85, 1.05, BAY_HALF_L - 3.0),
				Vector3(0.07, 1.05, 0.07),
				0.0,
				WorldPalette.RAIL,
				WorldSurface.Kind.METAL
			)
		town.solid(
			Vector3(x, 1.55, BAY_HALF_L - 3.0),
			Vector3(0.9, 0.6, 0.06),
			0.0,
			Palette.WORLD_WOOD[2],
			WorldSurface.Kind.WOOD
		)
	# Lane kerbs, low enough to step over and high enough to read as lanes.
	for sg: float in [-1.0, 1.0]:
		town.solid(
			Vector3(sg * 2.35, 0.06, 1.0),
			Vector3(0.12, 0.12, BAY_HALF_L - 3.0),
			0.0,
			WorldPalette.EXFIL,
			WorldSurface.Kind.CONCRETE
		)


# ----------------------------------------------------------------- watchtower


static func _watchtower(town: WorldTown) -> void:
	town.register(PropBuildings.tower(town, 0.0, 0.0))
	for i in 4:
		var a: float = float(i) / 4.0 * TAU + 0.6
		PropClutter.sandbags(town, cos(a) * 4.6, 0.0, sin(a) * 4.6, -a)


# ---------------------------------------------------------------- ruin cluster


static func _ruin_cluster(town: WorldTown) -> void:
	var r: XorShift32 = town.rng
	town.register(PropBuildings.ruin(town, -8.0, -6.0, 10.0, 8.0, 0.0))
	town.register(PropBuildings.ruin(town, 7.0, 4.0, 9.0, 9.0, 0.35))
	town.register(PropBuildings.ruin(town, 0.0, 11.0, 8.0, 7.0, -0.2))
	PropClutter.dead_tree(town, -12.0, 8.0)
	PropClutter.dead_tree(town, 11.0, -9.0)
	PropClutter.rock_cluster(town, 2.0, -11.0)
	PropClutter.wreck(town, -3.0, 2.0, r.next() * 3.0)
