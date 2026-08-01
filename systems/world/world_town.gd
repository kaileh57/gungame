class_name WorldTown
extends PropContext
## The town build context: a `PropContext` that also remembers what it has built.
##
## Everything a generator needs — the mesher, the collider set, the layout record,
## the rng, the noise field and the tuning — is the base class's. What the town
## adds is the building register: `roof_at` and `link_roofs` walk it,
## `place_exfils` ranks it, and the bake writes it into the layout for the AI and
## the compass to read.
##
## The generators themselves live in `res://systems/world/props/`. There is one
## transcription of them and this is one of its two callers; the other is
## `res://tools/build_props.gd`, which bakes the same generators standalone on
## flat ground. Nothing here re-implements a building or a prop.
##
## Bake-time only. Nothing in this file runs in a shipped frame.

## The town's own tuning, typed. `tuning` on the base class is the same object
## seen through its `PropTuning` face, which is all a generator ever needs.
var town_tuning: TownTuning

var buildings: Array[BuildingRecord] = []


func _init(
	town_rng: XorShift32,
	tuning_res: TownTuning,
	terrain_data: WorldTerrainData = null,
	layout_data: WorldLayoutData = null
) -> void:
	super(
		WorldMesher.new(),
		town_rng,
		WorldColliderSet.new(),
		layout_data if layout_data != null else WorldLayoutData.new(),
		terrain_data,
		WorldNoise.new(tuning_res.world_seed),
		tuning_res
	)
	town_tuning = tuning_res
	layout.world_seed = tuning_res.world_seed


## The building whose roof deck covers (x, z), or null. The 0.3 m inset keeps a
## plank from being anchored on a parapet.
func roof_at(x: float, z: float) -> BuildingRecord:
	for b in buildings:
		if not b.has_deck():
			continue
		var dx: float = x - b.x
		var dz: float = z - b.z
		var co: float = cos(-b.ry)
		var si: float = sin(-b.ry)
		var u: float = dx * co + dz * si
		var v: float = -dx * si + dz * co
		if absf(u) < b.w * 0.5 - 0.3 and absf(v) < b.d * 0.5 - 0.3:
			return b
	return null


## Record a finished structure with both the build context and the layout.
func register(b: BuildingRecord) -> BuildingRecord:
	buildings.push_back(b)
	b.publish(layout)
	return b
