extends RefCounted
## Where the firefight's cover and vantage sets come from: a collision-only copy
## of the arena, put in a live tree just long enough for the navigation server to
## answer questions about it, and then thrown away.
##
## BAKE-TIME ONLY. `tools/build_firefight.gd` is the only caller.
##
## DELIBERATELY NOT THE SHIPPING SCENE. Adding that to the tree would start the
## director, the three spawners and seventy creatures, and none of them have any
## bearing on where a barrel is. This builds the same solids with none of the
## behaviour, samples them, and frees the lot.
##
## Split out of the builder when the raised decks went in — that file sits on
## `gdlintrc`'s 1,000-line ceiling — and it is the natural seam: `firefight_nav.gd`
## owns what Recast is fed, this owns what is measured on the result.

## Grid spacing for the cover sample, in metres.
const SPACING: float = 2.0
## Physics frames waited before touching the navigation map at all, so every
## deferred collision shape has entered the tree.
const SETTLE_FRAMES: int = 6
## Map iteration the cover bake waits for. Iteration 1 is the empty map the
## server publishes before it has merged anything; 2 is the first that has the
## region in it.
const SYNC_ITERATION: int = 2
## Physics frames the bake will wait for that, before giving up and failing.
const SYNC_FRAMES: int = 240


## Sample cover and vantage over `navmesh`.
##
## `bodies` is every collision node the probe should stand up — the arena, the
## three compound kits and one static body per prop type — and `bounds` the box
## the sampler walks. Returns `[AICoverSet, PackedStringArray of report lines]`;
## the set is empty when the navigation map refused the region, which is the one
## failure here that is otherwise completely silent.
static func bake(
	tree: SceneTree, bodies: Array[Node], navmesh: NavigationMesh, bounds: AABB
) -> Array:
	var log_lines := PackedStringArray()
	var probe := Node3D.new()
	probe.name = "CoverProbe"
	for body: Node in bodies:
		probe.add_child(body)
	var region := NavigationRegion3D.new()
	region.name = "Nav"
	region.navigation_mesh = navmesh
	probe.add_child(region)
	tree.root.add_child(probe)
	for _i: int in SETTLE_FRAMES:
		await tree.physics_frame
	var map: RID = region.get_navigation_map()
	var iterations: int = await _await_navigation(tree, map)
	var region_bounds: AABB = NavigationServer3D.region_get_bounds(region.get_region_rid())

	var probe_point := Vector3(0.0, bounds.position.y + bounds.size.y * 0.5, 0.0)
	var snapped: Vector3 = NavigationServer3D.map_get_closest_point(map, probe_point)
	(
		log_lines
		. push_back(
			(
				"nav map               %.3f/%.3f, iteration %d, region %.0f x %.0f m, snap y %.2f"
				% [
					NavigationServer3D.map_get_cell_size(map),
					NavigationServer3D.map_get_cell_height(map),
					iterations,
					region_bounds.size.x,
					region_bounds.size.z,
					snapped.y,
				]
			)
		)
	)
	var started: int = Time.get_ticks_msec()
	var cfg: Dictionary = {"spacing": SPACING, "cell_size": 5.0}
	var cover: AICoverSet = AICoverSampler.sample(
		probe.get_world_3d().direct_space_state, map, bounds, cfg
	)
	log_lines.push_back("cover sample time     %d ms" % (Time.get_ticks_msec() - started))
	# The vantage pass is the half of this bake that answers "is there anywhere
	# worth climbing to", and it reports through `cfg` rather than through the
	# resource. Printing it is the only way a bake that silently found no elevated
	# ground — which is exactly what this demo used to do, 44 points and every one
	# of them at y = 0.50 — shows up in the report instead of in a live run.
	log_lines.push_back("vantage               %s" % str(cfg.get("vantage_log", "")))
	log_lines.push_back(
		(
			"vantage height        %d of %d points above 2 m, highest %.2f m"
			% [_high_count(cover), cover.vantage_positions.size(), _highest(cover)]
		)
	)
	probe.free()
	return [cover, log_lines]


## Wait until the navigation map has actually merged the region, and return the
## iteration it got to.
##
## This is not paranoia and it is not a fixed settle: the server syncs on its own
## clock and, measured here, a region of four thousand polygons takes about ten
## physics frames to land. `map_force_update` does not shorten it. Query the map
## before then and every answer is the origin — `map_get_closest_point` says so
## once, in an error, and then goes quiet — so a bake that guessed a frame count
## would write an empty cover set and report success. `map_get_iteration_id` is
## the documented way to know, and it is the only thing here that does.
static func _await_navigation(tree: SceneTree, map: RID) -> int:
	var deadline: int = SYNC_FRAMES
	while NavigationServer3D.map_get_iteration_id(map) < SYNC_ITERATION and deadline > 0:
		deadline -= 1
		await tree.physics_frame
	return NavigationServer3D.map_get_iteration_id(map)


static func _high_count(cover: AICoverSet) -> int:
	var n: int = 0
	for p: Vector3 in cover.vantage_positions:
		if p.y > 2.0:
			n += 1
	return n


static func _highest(cover: AICoverSet) -> float:
	var top: float = 0.0
	for p: Vector3 in cover.vantage_positions:
		top = maxf(top, p.y)
	return top
