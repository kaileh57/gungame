@tool
extends SceneTree
## Cover and vantage bake. Loads a built level, samples every navigable square
## metre of it for places worth standing, works out which of those places command
## the ground, and writes both fields as one `AICoverSet`.
##
## This is the whole reason `AICoverSampler` exists on the bake side of the line:
## sixteen rays per candidate over a town is a few hundred thousand intersections,
## and the vantage pass adds a sightline test from a few hundred candidates to a
## few hundred ground samples on top of that. Nothing offline, unthinkable in a
## frame. At runtime `AICoverMap` binds the saved resource and does nothing but
## index it.
##
## Run headless:
##   godot --headless --path <project> --script res://tools/bake_ai_cover.gd -- \
##       scene=res://demos/ash_flats/ash_flats.tscn out=res://data/ai/ash_flats_cover.tres
##
## Optional overrides, same `key=value` form: spacing, low_height, high_height,
## probe_distance, cell_size, margin, refine_passes, and `vantage=off` to bake
## cover only. Everything else comes from the level.

## Physics frames waited before touching the navigation map at all, so every
## deferred collision shape has actually entered the tree.
const SETTLE_FRAMES: int = 6
## Physics frames the bake will wait for the navigation map to start answering,
## before giving up and failing. A three-thousand-polygon region takes about ten.
const NAV_SYNC_FRAMES: int = 240
## Metres added around the navigation mesh's own bounds before gridding, so a
## point on the very edge of the mesh still gets sampled.
const DEFAULT_MARGIN: float = 2.0


func _initialize() -> void:
	_run()


func _run() -> void:
	var args: Dictionary = _parse_args()
	var scene_path: String = str(args.get("scene", ""))
	var out_path: String = str(args.get("out", ""))
	if scene_path.is_empty() or out_path.is_empty():
		push_error("bake_ai_cover: both scene=<res://...> and out=<res://...> are required.")
		quit(1)
		return
	var packed: PackedScene = load(scene_path) as PackedScene
	if packed == null:
		push_error("bake_ai_cover: %s is not a PackedScene." % scene_path)
		quit(1)
		return
	var level: Node = packed.instantiate()
	root.add_child(level)
	for _i: int in SETTLE_FRAMES:
		await physics_frame

	var region: NavigationRegion3D = _find_region(level)
	if region == null:
		push_error("bake_ai_cover: %s contains no NavigationRegion3D." % scene_path)
		quit(1)
		return
	var margin: float = float(args.get("margin", DEFAULT_MARGIN))
	var bounds: AABB = _region_bounds(region).grow(margin)
	if not await _await_navigation(region.get_navigation_map(), bounds):
		push_error("bake_ai_cover: the navigation map never began answering queries.")
		quit(1)
		return
	var space: PhysicsDirectSpaceState3D = (level as Node3D).get_world_3d().direct_space_state
	var cfg: Dictionary = _sampler_cfg(args)
	var started: int = Time.get_ticks_msec()
	var cover: AICoverSet = AICoverSampler.sample(space, region.get_navigation_map(), bounds, cfg)
	var msec: int = Time.get_ticks_msec() - started

	DirAccess.make_dir_recursive_absolute(out_path.get_base_dir())
	var err: int = ResourceSaver.save(cover, out_path)
	if err != OK:
		push_error("bake_ai_cover: could not write %s (error %d)." % [out_path, err])
		quit(1)
		return
	print(_report(scene_path, out_path, bounds, cover, cfg, msec))
	quit(0)


## Sampler configuration, level defaults overridden by anything on the command
## line. Keys the sampler does not know about are ignored by it.
func _sampler_cfg(args: Dictionary) -> Dictionary:
	var cfg: Dictionary = {}
	for key: String in ["spacing", "low_height", "high_height", "probe_distance", "cell_size"]:
		if args.has(key):
			cfg[key] = float(args[key])
	if args.has("refine_passes"):
		cfg["refine_passes"] = int(args["refine_passes"])
	if str(args.get("vantage", "on")) == "off":
		cfg["bake_vantage"] = false
	return cfg


## Wait until the navigation map is really serving queries.
##
## A fixed settle is not enough and neither is `map_get_iteration_id`: the server
## publishes the iteration that owns a region before every query against it is
## answered off it, and a query put to a map that has not merged comes back as the
## world origin. Measured on the firefight arena, a fixed four-frame settle
## sampled ONE point out of a three-hundred-metre level and wrote an empty cover
## set while reporting success. The test that cannot be early is asking the map
## for the nearest navigable point to the middle of the region and requiring the
## answer to be somewhere near where it was asked about.
func _await_navigation(map: RID, bounds: AABB) -> bool:
	var probe: Vector3 = bounds.get_center()
	for _i: int in NAV_SYNC_FRAMES:
		if map.is_valid() and NavigationServer3D.map_get_iteration_id(map) >= 2:
			var got: Vector3 = NavigationServer3D.map_get_closest_point(map, probe)
			if Vector2(got.x - probe.x, got.z - probe.z).length() <= bounds.size.x * 0.5:
				return true
		await physics_frame
	return false


func _parse_args() -> Dictionary:
	var out: Dictionary = {}
	for raw: String in OS.get_cmdline_user_args():
		var bits: PackedStringArray = raw.split("=", true, 1)
		if bits.size() == 2:
			out[bits[0].lstrip("-")] = bits[1]
	return out


func _find_region(node: Node) -> NavigationRegion3D:
	if node is NavigationRegion3D:
		return node as NavigationRegion3D
	for child: Node in node.get_children():
		var found: NavigationRegion3D = _find_region(child)
		if found != null:
			return found
	return null


## World-space extent of the region's own mesh. Sampling the whole level's AABB
## instead would spend most of the bake proving that the sky is not cover.
func _region_bounds(region: NavigationRegion3D) -> AABB:
	var mesh: NavigationMesh = region.navigation_mesh
	if mesh == null or mesh.get_vertices().is_empty():
		return AABB(region.global_position - Vector3.ONE * 32.0, Vector3.ONE * 64.0)
	var verts: PackedVector3Array = mesh.get_vertices()
	var box := AABB(region.global_transform * verts[0], Vector3.ZERO)
	for i: int in range(1, verts.size()):
		box = box.expand(region.global_transform * verts[i])
	return box


func _report(
	scene_path: String,
	out_path: String,
	bounds: AABB,
	cover: AICoverSet,
	cfg: Dictionary,
	msec: int
) -> String:
	var firing: int = 0
	var full: int = 0
	for i: int in cover.size():
		var high: int = cover.high_mask(i)
		if high == 0:
			firing += 1
		elif high == cover.low_mask(i):
			full += 1
	var lines := PackedStringArray()
	lines.append("cover bake")
	lines.append("  scene            %s" % scene_path)
	lines.append("  bounds           %.1f x %.1f m" % [bounds.size.x, bounds.size.z])
	lines.append("  nav samples      %d" % int(cfg.get("ground_samples", 0)))
	lines.append("  probe reach      %.2f m" % float(cfg.get("probe_used", 0.0)))
	# Split out, because "the level has more cover" and "the walk looked harder at
	# the cover the level already had" are different claims, and only the second is
	# what the refinement pass is allowed to buy.
	var coarse: int = int(cfg.get("coarse_points", cover.size()))
	lines.append(
		(
			"  points           %d  (%d uniform, %d refined at %.2f m)"
			% [cover.size(), coarse, cover.size() - coarse, float(cfg.get("refine_step", 0.0))]
		)
	)
	lines.append("  firing positions %d  (blocked low, open high)" % firing)
	lines.append("  full cover       %d  (blocked at both heights)" % full)
	lines.append("  grid cells       %d at %.1f m" % [cover.cell_keys.size(), cover.cell_size])
	lines.append_array(_vantage_report(cover, cfg))
	lines.append("  bake time        %d ms" % msec)
	lines.append("  written          %s" % out_path)
	return "\n".join(lines)


## What the overwatch pass found, and how high and how far it reaches. Elevation
## and reach are the two numbers worth staring at: a set whose elevation column
## is all zeros is a level with no navigable relief, and one whose reach is short
## is a level where nothing commands anything.
func _vantage_report(cover: AICoverSet, cfg: Dictionary) -> PackedStringArray:
	var lines := PackedStringArray()
	var n: int = cover.vantage_count()
	lines.append("  vantage points   %d" % n)
	if n == 0:
		lines.append("  vantage note     %s" % str(cfg.get("vantage_log", "not baked")))
		return lines
	var lift: float = 0.0
	var reach: float = 0.0
	var top: float = 0.0
	var elevated: int = 0
	for i: int in n:
		lift += cover.vantage_elevation[i]
		reach += cover.vantage_reach[i]
		top = maxf(top, cover.vantage_elevation[i])
		if cover.vantage_elevation[i] >= 1.0:
			elevated += 1
	lines.append(
		(
			"  vantage lift     mean %.2f m, best %.2f m, %d at or above 1 m"
			% [lift / float(n), top, elevated]
		)
	)
	lines.append("  vantage reach    mean %.1f m" % (reach / float(n)))
	lines.append("  vantage note     %s" % str(cfg.get("vantage_log", "")))
	return lines
