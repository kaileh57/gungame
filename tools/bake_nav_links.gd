extends SceneTree
## Off-mesh link bake. Reads a level's navmesh and its collision, works out where
## a fighter would climb, drop, vault, hop or cross, and writes the link set the
## AI paths through.
##
## Produces
##   res://data/ai/link_rules.tres               the bake's knob box, made if absent
##   res://data/ai/links/<id>_links.res           one `AILinkBaker` per level
##   res://data/ai/links/link_bake_report.txt     what was found, and what it bought
##
## Run headless:
##   godot --headless --path <project> --script res://tools/bake_nav_links.gd
##
## Run it AFTER `build_town.gd`, `build_arena.gd` and `build_firefight.gd`: it
## reads the navmesh and the collision those three write, and a link baked against
## last week's geometry is a link into a wall.
##
## WHY THE LEVEL IS INSTANTIATED. Two of the five kinds cannot be told apart from
## the navmesh alone: a chest-high barricade and a four-metre wall carve it
## identically, and only air at head height separates "vault it" from "walk round
## it"; a roof plank and a five-metre void are both a hole, and only whether a
## foot lands separates them. So the scene goes into a live tree with real
## colliders and the classifier asks the physics server. Nothing at runtime does.
##
## WHY NOT `map_get_closest_point`. It is O(polygons) per call — the town has
## 41,774 and this bake makes hundreds of thousands of probes. The flat XZ grid
## below answers in constant time, and answers a better question: not "where is
## the nearest navmesh" but "what is walkable AT this point, at what heights".

const NavIndex := preload("res://tools/nav_index.gd")

const RULES_PATH: String = "res://data/ai/link_rules.tres"
const OUT_DIR: String = "res://data/ai/links"
const REPORT_PATH: String = "res://data/ai/links/link_bake_report.txt"

## `id`, scene, and the town layout that carries the ladders (empty for none).
const TARGETS: Array[Array] = [
	["town", "res://data/world/town/town.tscn", "res://data/world/layout.res"],
	["arena", "res://demos/arena/arena.tscn", ""],
	["firefight", "res://demos/firefight/firefight.tscn", ""],
]

## Physics frames the level is given to settle before anything is probed. Deferred
## spawns, gate transforms and the navigation map's own merge all land inside it.
const SETTLE_FRAMES: int = 40
## Frames waited after the links go in, before the reachability check runs.
const LINK_SYNC_FRAMES: int = 40
## Random source/destination pairs the reachability check draws.
const REACH_SAMPLES: int = 240
## Metres above the level's ground band a destination has to sit to count as
## "upper level" for the reachability report.
const UPPER_LEVEL_MARGIN: float = 2.5
## How close a path's last point must land to the destination to count as arrived.
const ARRIVE_TOLERANCE: float = 2.0
## Polygon budget every corridor query in this tool runs with. Matches what
## `AIPathService` stamps onto the agents, so the report measures what ships —
## and it has to, because the budget is a per-query allocation and not a free
## safety margin. See `AIPathService.path_search_polygons`.
const SEARCH_POLYGONS: int = 4096
## Links sampled when measuring how many of them the server will path through.
const AUDIT_SAMPLES: int = 220
## Fraction of installed links the server must path through before the set ships.
const MIN_PATHABLE: float = 0.9
## Budget floor. Below this a level is better off with no links than with a set
## small enough to be arbitrary.
const MIN_BUDGET: int = 48
## Installs one level may spend finding its own link ceiling. Each costs a
## rebuild, forty sync frames and `AUDIT_SAMPLES` path queries.
const MAX_BUDGET_PROBES: int = 8
## How close the search has to get to the ceiling before it settles. Finer than
## this is a link or two, and another install to find them.
const BUDGET_STEP: int = 32

var _rules: AILinkBaker = null
var _root: Node3D = null
var _scene: Node = null
var _report: PackedStringArray = PackedStringArray()
var _links: AILinkBaker = null
var _index: NavIndex = null
var _region: NavigationRegion3D = null
var _map: RID = RID()
var _query: PhysicsRayQueryParameters3D = null
var _dedupe: Dictionary = {}
var _target: int = 0
var _phase: int = 0
var _wait: int = 0
var _boot: int = 0
var _failures: int = 0
var _samples: int = 0
var _rng: XorShift32 = null
var _discovered: AILinkBaker = null
var _budget: int = 0
## Bisection state: the largest budget measured pathable, the smallest measured
## unpathable (-1 for none yet), and how many installs have been spent.
var _lo: int = 0
var _hi: int = -1
var _probes: int = 0
var _settled: bool = false
## Faces the discovery found and refused because they are taller than
## `climb_max`, and how tall they were. See `_report_unclimbable`.
var _too_tall: int = 0
var _too_tall_min: float = INF
var _too_tall_max: float = 0.0


## DRIVEN OFF PHYSICS, and it has to be.
##
## Every wait in this tool is counted in frames, and every one of them is waiting
## on the NAVIGATION SERVER — for a region to merge, for a set of links to be
## joined to polygons. The server does that work on the physics tick. Headless,
## with no vsync and nothing to draw, the main loop spins as fast as the machine
## will go while physics stays pinned to its 60 Hz of real time, so forty
## `_process` iterations are a handful of milliseconds and almost no sync at all.
##
## Measured on the town: the same budget of 224 links audited 100% pathable on
## one install and 64% on the very next, and the budget search read that noise as
## a cliff — which is where the belief that "a 29,942-polygon map stops pathing
## through links somewhere above 600" came from. It was never a link ceiling. It
## was the audit running before the map had finished joining them.
func _physics_process(_delta: float) -> bool:
	_boot += 1
	if _boot < 2:
		return false
	if _boot == 2:
		_begin()
		return false
	if _wait > 0:
		_wait -= 1
		return false
	if _target >= TARGETS.size():
		_finish()
		return true
	match _phase:
		0:
			_load_target()
		1:
			_bake_target()
		2:
			_measure_target()
		_:
			_drop_target()
	return false


## One line of the report.
##
## A helper rather than an inline `push_back` because `gdformat` explodes a
## formatted string argument into a dozen lines apiece, and this file writes
## fifteen of them.
func _say(text: String, args: Array = []) -> void:
	_report.push_back(text if args.is_empty() else text % args)


func _begin() -> void:
	_rng = XorShift32.new(20260731)
	_root = Node3D.new()
	_root.name = "LinkBake"
	get_root().add_child(_root)
	_query = PhysicsRayQueryParameters3D.create(Vector3.ZERO, Vector3.ZERO)
	_query.collision_mask = GameLayers.WORLD | GameLayers.PROP
	_rules = _load_rules()
	var overrides: String = _apply_overrides()
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	_report.push_back("NAV LINK BAKE")
	if not overrides.is_empty():
		_report.push_back("overridden: %s" % overrides)
	_report.push_back("")


## Let the command line move a bake rule for one run, without editing the
## resource or the source.
##
##     godot --headless --path <proj> --script res://tools/bake_nav_links.gd -- \
##         --ladder-cost=6 --ledge-cost=5 --max-links=900 --climb-max=3.4
##
## This exists because tuning a link set is a bake-and-measure loop — bake, run
## `verify_ai_traversal`, read the roof-reach rate, change one number — and a
## loop you have to hand-edit a file in the middle of is a loop nobody runs more
## than twice. The value that ships is still the default on `AILinkBaker`;
## whatever was used is written at the top of the report so no measurement can be
## quoted without it.
func _apply_overrides() -> String:
	const KNOBS: Dictionary = {
		"--ladder-cost=": &"ladder_enter_cost",
		"--ledge-cost=": &"ledge_enter_cost",
		"--max-links=": &"max_links",
		"--climb-max=": &"climb_max",
		"--mantle-max=": &"mantle_max",
		"--island-pairs=": &"links_per_island_pair",
	}
	var used := PackedStringArray()
	for arg: String in OS.get_cmdline_user_args():
		for prefix: String in KNOBS:
			if not arg.begins_with(prefix):
				continue
			var text: String = arg.substr(prefix.length())
			if not text.is_valid_float():
				continue
			var key: StringName = KNOBS[prefix]
			var was: Variant = _rules.get(key)
			_rules.set(key, int(text.to_float()) if was is int else text.to_float())
			used.push_back("%s = %s (was %s)" % [key, str(_rules.get(key)), str(was)])
	return ", ".join(used)


## Put the level in a live tree and give it its settle frames.
func _load_target() -> void:
	var id: String = TARGETS[_target][0]
	var path: String = TARGETS[_target][1]
	if not ResourceLoader.exists(path):
		_report.push_back("%-10s MISSING %s" % [id, path])
		_failures += 1
		_phase = 3
		return
	var packed: PackedScene = ResourceLoader.load(path) as PackedScene
	if packed == null:
		_report.push_back("%-10s FAILED to load %s" % [id, path])
		_failures += 1
		_phase = 3
		return
	_scene = packed.instantiate()
	_root.add_child(_scene)
	_phase = 1
	_wait = SETTLE_FRAMES


## Find the navmesh, discover the links, save the set.
func _bake_target() -> void:
	var id: String = TARGETS[_target][0]
	var layout_path: String = TARGETS[_target][2]
	_region = _find_region(_scene)
	if _region == null or _region.navigation_mesh == null:
		_report.push_back("%-10s no NavigationRegion3D with a mesh" % id)
		_failures += 1
		_phase = 3
		return
	var navmesh: NavigationMesh = _region.navigation_mesh
	_map = _region.get_navigation_map()
	NavigationServer3D.map_force_update(_map)
	_index = NavIndex.new()
	_index.build(navmesh, _region.global_transform)
	_links = _fresh_set()
	_dedupe.clear()
	_samples = 0
	_too_tall = 0
	_too_tall_min = INF
	_too_tall_max = 0.0

	var t0: int = Time.get_ticks_msec()
	var ladders: int = 0
	if not layout_path.is_empty() and ResourceLoader.exists(layout_path):
		var layout: WorldLayoutData = ResourceLoader.load(layout_path) as WorldLayoutData
		ladders = _links.bake_ladders(layout, _index.height_at)
	ladders += _bake_kit_ladders(_scene)
	var edges: Dictionary = AILinkBaker.border_edges(navmesh)
	_discover(edges, _region.global_transform)
	_index.comps = AILinkBaker.polygon_components(navmesh)
	var orphaned: int = _prune_orphans()
	var ms: int = Time.get_ticks_msec() - t0
	_discovered = _links
	_budget = _rules.max_links
	_lo = 0
	_hi = -1
	_probes = 0
	_settled = false
	_say(
		(
			"%-10s %d polys, %d border edges, %d probes, %d ms"
			% [
				id,
				navmesh.get_polygon_count(),
				(edges["a"] as PackedVector3Array).size(),
				_samples,
				ms
			]
		)
	)
	_say(
		(
			"           %d ladders from layout, %d ends unusable, %d discovered"
			% [ladders, orphaned, _discovered.size()]
		)
	)
	_install_budget()


## Thin the discovered set to the current budget, put it on the map and give the
## server its sync frames.
func _install_budget() -> void:
	_links = _fresh_set()
	for i: int in _discovered.size():
		_links.start_positions.push_back(_discovered.start_positions[i])
		_links.end_positions.push_back(_discovered.end_positions[i])
		_links.kinds.push_back(_discovered.kinds[i])
		_links.flags.push_back(_discovered.flags[i])
		_links.layers.push_back(_discovered.layers[i])
		_links.enter_costs.push_back(_discovered.enter_costs[i])
		_links.travel_costs.push_back(_discovered.travel_costs[i])
	_thin_to_budget(_budget)
	var stale: Node = _root.get_node_or_null(^"AILinks")
	if stale != null:
		stale.name = "AILinksRetired"
		stale.queue_free()
	_links.instantiate_into(_root, _map)
	NavigationServer3D.map_force_update(_map)
	_phase = 2
	_wait = LINK_SYNC_FRAMES


## Close in on the largest link budget this navigation map will actually path
## through. True when another probe was installed and the caller should come back
## after the sync frames.
##
## THE OLD SEARCH ONLY HALVED, and stopped at the first budget that worked. For
## the town that is the whole story of its link set: 900 measured 11% pathable,
## 450 measured 100%, and every budget in between — where the ceiling actually is
## — was never tried. Bisecting costs three or four more installs and ships the
## largest set that measures good; the result is re-measured after it is
## re-installed, so the reported rate is always the saved set's rate.
func _narrow(rate: float) -> bool:
	if _probes >= MAX_BUDGET_PROBES:
		return _settle()
	_probes += 1
	if rate >= MIN_PATHABLE:
		_lo = _budget
		# Nothing has failed yet, so this IS the ceiling the rules allow.
		if _hi < 0:
			return false
	else:
		_hi = _budget
	if _hi - _lo <= BUDGET_STEP or _hi <= MIN_BUDGET:
		return _settle()
	var next: int = maxi((_lo + _hi) / 2, MIN_BUDGET)
	if next == _budget:
		return _settle()
	_say(
		(
			"           %d links -> %.0f%% pathable; trying %d (good %d, bad %d)"
			% [_links.size(), rate * 100.0, next, _lo, _hi]
		)
	)
	_budget = next
	_install_budget()
	return true


## Put the largest known-good budget back on the map. Returns true when that
## needed a re-install.
func _settle() -> bool:
	_settled = true
	var want: int = maxi(_lo, MIN_BUDGET)
	if want == _budget:
		return false
	_report.push_back("           settling on %d links" % want)
	_budget = want
	_install_budget()
	return true


## Fraction of the installed links the navigation server will actually path
## through, sampled.
func _pathable_rate() -> float:
	var n: int = _links.size()
	if n == 0:
		return 1.0
	var stride: int = maxi(1, n / AUDIT_SAMPLES)
	var tried: int = 0
	var ok: int = 0
	var i: int = 0
	while i < n:
		var a: Vector3 = _links.start_positions[i]
		var b: Vector3 = _links.end_positions[i]
		var path: PackedVector3Array = _path(a, b, _links.layers[i] | AILinkBaker.LAYER_WALK)
		tried += 1
		if path.size() >= 2 and path[path.size() - 1].distance_to(b) <= 1.0:
			ok += 1
		i += stride
	return float(ok) / float(maxi(tried, 1))


## Path queries through the finished map, with the links in and with them out.
## This is the number the whole exercise exists to move.
##
## THE BUDGET IS FOUND, NOT ASSUMED — see `_narrow`.
func _measure_target() -> void:
	NavigationServer3D.map_force_update(_map)
	var rate: float = _pathable_rate()
	if not _settled and _narrow(rate):
		return
	var id: String = TARGETS[_target][0]
	var out_path: String = "%s/%s_links.res" % [OUT_DIR, id]
	var err: Error = ResourceSaver.save(_links, out_path)
	if err != OK:
		_report.push_back("%-10s SAVE FAILED (%d)" % [id, err])
		_failures += 1
	if rate < MIN_PATHABLE:
		# Shipping links the navigation server will not path through is worse than
		# shipping none: every report downstream counts them and no agent uses one.
		_say(
			(
				"           FAIL: only %.0f%% pathable at the budget floor of %d"
				% [rate * 100.0, _budget]
			)
		)
		_failures += 1
	_say("           shipped: %s  (%d links, budget %d)" % [_links.tally(), _links.size(), _budget])
	var walk_only: int = AILinkBaker.LAYER_WALK
	var climber: int = AILinkBaker.LAYER_ALL
	var pairs: Array[PackedVector3Array] = _draw_pairs()
	var before: int = 0
	var after: int = 0
	var down_before: int = 0
	var down_after: int = 0
	var rise: float = 0.0
	for pair: PackedVector3Array in pairs:
		if _arrives(pair[0], pair[1], walk_only):
			before += 1
		if _arrives(pair[0], pair[1], climber):
			after += 1
		if _arrives(pair[1], pair[0], walk_only):
			down_before += 1
		if _arrives(pair[1], pair[0], climber):
			down_after += 1
		rise += pair[1].y - pair[0].y
	var n: int = maxi(pairs.size(), 1)
	_say(
		(
			"           map valid %s, %d regions, %d links, iteration %d"
			% [
				str(_map.is_valid()),
				NavigationServer3D.map_get_regions(_map).size(),
				NavigationServer3D.map_get_links(_map).size(),
				NavigationServer3D.map_get_iteration_id(_map)
			]
		)
	)
	(
		_report
		. push_back(
			(
				"           navmesh y %.1f .. %.1f, %d roof goals, mean rise %.1f m"
				% [
					_index.bounds.position.y,
					_index.bounds.end.y,
					pairs.size(),
					rise / float(n),
				]
			)
		)
	)
	_say(
		(
			"           reach a roof: walk-only %d/%d (%.0f%%) -> with links %d/%d (%.0f%%)"
			% [
				before,
				pairs.size(),
				100.0 * float(before) / float(n),
				after,
				pairs.size(),
				100.0 * float(after) / float(n)
			]
		)
	)
	_say(
		(
			"           get off a roof: walk-only %d/%d (%.0f%%) -> with links %d/%d (%.0f%%)"
			% [
				down_before,
				pairs.size(),
				100.0 * float(down_before) / float(n),
				down_after,
				pairs.size(),
				100.0 * float(down_after) / float(n)
			]
		)
	)
	_audit_links()
	_report_unclimbable()
	_report.push_back("")
	_phase = 3


## Per-kind: how many baked links the server actually routes through, and how
## many of those join two places nothing else joined. A link the server will not
## path through is worse than no link — it is a line in a report claiming the
## traversal works — so this is what catches an end floating off the deck.
func _audit_links() -> void:
	var usable := PackedInt32Array()
	var joining := PackedInt32Array()
	var total := PackedInt32Array()
	var orphan := PackedInt32Array()
	usable.resize(AILinkBaker.Kind.size())
	joining.resize(AILinkBaker.Kind.size())
	total.resize(AILinkBaker.Kind.size())
	orphan.resize(AILinkBaker.Kind.size())
	var radius: float = NavigationServer3D.map_get_link_connection_radius(_map)
	for i: int in _links.size():
		var kind: int = _links.kinds[i]
		var a: Vector3 = _links.start_positions[i]
		var b: Vector3 = _links.end_positions[i]
		total[kind] += 1
		if (
			NavigationServer3D.map_get_closest_point(_map, a).distance_to(a) > radius
			or NavigationServer3D.map_get_closest_point(_map, b).distance_to(b) > radius
		):
			orphan[kind] += 1
		var span: float = a.distance_to(b)
		var with_link: PackedVector3Array = _path(a, b, _links.layers[i] | AILinkBaker.LAYER_WALK)
		if with_link.size() < 2 or with_link[with_link.size() - 1].distance_to(b) > 1.0:
			continue
		usable[kind] += 1
		var walked: PackedVector3Array = _path(a, b, AILinkBaker.LAYER_WALK)
		var detour: bool = walked.size() < 2 or walked[walked.size() - 1].distance_to(b) > 1.0
		if not detour:
			detour = _path_length(walked) > maxf(span * 3.0, span + 6.0)
		if detour:
			joining[kind] += 1
	for k: int in AILinkBaker.Kind.size():
		if total[k] == 0:
			continue
		(
			_report
			. push_back(
				(
					"           %-7s %4d baked, %4d pathable (%3.0f%%), %4d join new ground, %d orphan ends"
					% [
						AILinkBaker.kind_name(k),
						total[k],
						usable[k],
						100.0 * float(usable[k]) / float(total[k]),
						joining[k],
						orphan[k]
					]
				)
			)
		)


## The faces the discovery walked up to and refused because they are taller than
## anything in the roster can climb.
##
## THIS IS THE LEVEL-DESIGN NUMBER. When a level's upper storey is unreachable it
## is almost never the link rules that are wrong — it is that the only way up is
## a face nothing has hands for, and no amount of tuning a bake produces a link
## across it. Printing the count and the height band says exactly how tall a
## ladder the level is missing, which is a thing a builder can act on and "0 of
## 240 roof goals reachable" is not.
func _report_unclimbable() -> void:
	if _too_tall == 0:
		return
	_say(
		(
			"           %d faces too tall to climb, %.1f m to %.1f m (climb_max %.1f m)"
			% [_too_tall, _too_tall_min, _too_tall_max, _rules.climb_max]
		)
	)


static func _path_length(path: PackedVector3Array) -> float:
	var total: float = 0.0
	for i: int in range(1, path.size()):
		total += path[i].distance_to(path[i - 1])
	return total


func _drop_target() -> void:
	if _scene != null:
		_scene.queue_free()
		_scene = null
	var stale: Node = _root.get_node_or_null(^"AILinks")
	if stale != null:
		stale.name = "AILinksRetired"
		stale.queue_free()
	_index = null
	_region = null
	_links = null
	_target += 1
	_phase = 0
	_wait = 4


func _finish() -> void:
	_report.push_back("RESULT: %s" % ("PASS" if _failures == 0 else "FAIL - %d" % _failures))
	var text: String = "\n".join(_report) + "\n"
	DirAccess.make_dir_recursive_absolute(REPORT_PATH.get_base_dir())
	var f := FileAccess.open(REPORT_PATH, FileAccess.WRITE)
	if f != null:
		f.store_string(text)
		f.close()
	print(text)
	_root.free()
	quit(0 if _failures == 0 else 1)


# ------------------------------------------------------------------- discovery


## Ladders that came into the level inside an environment kit.
##
## A kit's ladders live in its own layout resource at the kit's local origin, so
## each instance's world transform has to be pushed through them. `firefight`
## builds its three faction homes out of `compound.tscn`; measured, that kit
## carries no ladders at all, which is why it contributes none.
func _bake_kit_ladders(node: Node) -> int:
	var made: int = 0
	var node3d := node as Node3D
	if node3d != null and node3d.has_meta(&"kit_id"):
		var id: String = String(node3d.get_meta(&"kit_id"))
		var path: String = "res://data/world/kits/%s_layout.res" % id
		if ResourceLoader.exists(path):
			var layout: WorldLayoutData = ResourceLoader.load(path) as WorldLayoutData
			made += _links.bake_ladders(layout, _index.height_at, node3d.global_transform)
	for child: Node in node.get_children():
		made += _bake_kit_ladders(child)
	return made


## Walk every border edge of the navmesh and bake whatever crossing the geometry
## on the other side of it turns out to be.
func _discover(edges: Dictionary, xform: Transform3D) -> void:
	var ea: PackedVector3Array = edges["a"]
	var eb: PackedVector3Array = edges["b"]
	var ei: PackedVector3Array = edges["inside"]
	for e: int in ea.size():
		var a: Vector3 = xform * ea[e]
		var b: Vector3 = xform * eb[e]
		var inside: Vector3 = xform * ei[e]
		var along := Vector3(b.x - a.x, 0.0, b.z - a.z)
		var length: float = along.length()
		if length < _rules.edge_min_length:
			continue
		var perp := Vector3(along.z, 0.0, -along.x) / length
		var mid: Vector3 = (a + b) * 0.5
		if perp.dot(mid - inside) < 0.0:
			perp = -perp
		var count: int = maxi(1, int(length / _rules.edge_sample_step))
		for k: int in count:
			var u: float = (float(k) + 0.5) / float(count)
			_probe(a.lerp(b, u), perp)


## One sample point on a border edge. Steps outward until it finds somewhere to
## land, classifies the crossing and bakes it.
func _probe(p: Vector3, out: Vector3) -> void:
	var d: float = _rules.probe_near
	while d <= _rules.probe_far:
		_samples += 1
		var probe: Vector3 = p + out * d
		var y: float = _index.height_at(probe.x, probe.z, p.y)
		d += _rules.probe_step
		if is_nan(y):
			continue
		var land := Vector3(probe.x, y, probe.z)
		var fall: float = p.y - y
		if fall > _rules.drop_min:
			_bake_drop(p, land, out, fall)
			return
		if fall < -_rules.drop_min:
			_bake_step_up(p, land, out, -fall)
			return
		_bake_level(p, land, out, d - _rules.probe_step)
		return


## A landing above the edge: a lip to pull over, or a face to climb. The face has
## to BE a face — a rise on the far side of a ramp is walked, not climbed, and the
## navmesh would have joined it — so the chest-height probe must hit something.
func _bake_step_up(p: Vector3, land: Vector3, out: Vector3, rise: float) -> void:
	if rise <= _rules.mantle_max:
		_bake(AILinkBaker.Kind.MANTLE, p, land, out, AILinkBaker.LAYER_MANTLE, false)
		return
	if rise > _rules.climb_max:
		_too_tall += 1
		_too_tall_min = minf(_too_tall_min, rise)
		_too_tall_max = maxf(_too_tall_max, rise)
		return
	var chest: float = minf(_rules.vault_clear_height, rise - 0.1)
	var eye: Vector3 = p + Vector3.UP * chest
	if not _hits(eye, Vector3(land.x, eye.y, land.z)):
		return
	_bake(AILinkBaker.Kind.LADDER, p, land, out, AILinkBaker.LAYER_CLIMB, true)


## A landing below the edge. Bake the fall, and its reverse when the step back up
## is short enough to be pulled rather than climbed.
func _bake_drop(p: Vector3, land: Vector3, out: Vector3, fall: float) -> void:
	if fall > _rules.drop_max:
		return
	# Head height over the lip has to be clear, or this is a drop through a wall.
	# The probe is HORIZONTAL, out from the ledge: run it down to the landing
	# instead and it hits the face of the building on every ledge in the town.
	var head: Vector3 = p + Vector3.UP * 1.2
	if _hits(head, Vector3(land.x, head.y, land.z)):
		return
	var bit: int = AILinkBaker.drop_bit_for(fall)
	if bit == 0:
		return
	_bake(AILinkBaker.Kind.DROP, p, land, out, bit, false)
	# The way back up. A drop is one-way because falling is; getting back onto the
	# ledge is a different capability and a different motion, so it is a different
	# link rather than a `bidirectional` flag.
	_bake_step_up(land, p, -out, fall)


## A landing at the same height as the edge: a barricade, a plank or a void, and
## the physics server is the only thing that knows which.
func _bake_level(p: Vector3, land: Vector3, out: Vector3, span: float) -> void:
	var low_a: Vector3 = p + Vector3.UP * _rules.vault_probe_height
	var low_b: Vector3 = land + Vector3.UP * _rules.vault_probe_height
	if _hits(low_a, low_b):
		var high_a: Vector3 = p + Vector3.UP * _rules.vault_clear_height
		var high_b: Vector3 = land + Vector3.UP * _rules.vault_clear_height
		if _hits(high_a, high_b) or span > _rules.vault_max_span:
			return
		_bake(AILinkBaker.Kind.VAULT, p, land, out, AILinkBaker.LAYER_VAULT, true)
		return
	var mid: Vector3 = (p + land) * 0.5 + Vector3.UP * 0.05
	if _hits(mid, mid - Vector3.UP * _rules.bridge_probe_drop):
		# Ground under the gap: the hole is navmesh erosion and the body can walk
		# it. Nothing to bake.
		return
	var bit: int = AILinkBaker.jump_bit_for(span)
	if bit != 0:
		_bake(AILinkBaker.Kind.JUMP, p, land, out, bit, true)


## Record one link, once. The grid bucket plus the outward octant is what stops a
## twenty-metre roof edge becoming forty identical drops.
func _bake(kind: int, from: Vector3, to: Vector3, out: Vector3, mask: int, both: bool) -> void:
	var cx: int = floori(from.x / _rules.dedupe_cell)
	var cy: int = floori(from.y / maxf(_rules.dedupe_cell, 1.0))
	var cz: int = floori(from.z / _rules.dedupe_cell)
	var octant: int = posmod(int(round(atan2(out.x, out.z) / TAU * 8.0)), 8)
	var key: int = ((cx * 73856093) ^ (cy * 19349663) ^ (cz * 83492791)) * 64 + octant * 8 + kind
	if _dedupe.has(key):
		return
	_dedupe[key] = true
	_links.add(kind, _inset(from, -out), _inset(to, out), mask, both)


## Pull a link end off the navmesh border it was found on and onto the polygon
## behind it, keeping the original when there is nothing walkable there.
func _inset(p: Vector3, along: Vector3) -> Vector3:
	if _rules.link_inset <= 0.0:
		return p
	var moved: Vector3 = p + along * _rules.link_inset
	var y: float = _index.height_at(moved.x, moved.z, p.y)
	if is_nan(y) or absf(y - p.y) > _rules.snap_tolerance:
		return p
	return Vector3(moved.x, y, moved.z)


## Throw away links whose ends the server will not join to a polygon.
##
## Discovered links come off the navmesh by construction, so this fires for
## ladders: theirs come out of the town layout, and one that tops out over a
## parapet with no walkable deck behind it is a link into the sky. The server
## joins an end to the closest polygon inside `map_get_link_connection_radius`
## and silently drops it otherwise — the worst failure there is, because the bake
## then reports 62 ladders and the town gains nothing. Returns how many went.
func _prune_orphans() -> int:
	var order := PackedInt32Array()
	var dropped: int = 0
	for i: int in _links.size():
		if _walkable_here(_links.start_positions[i]) and _walkable_here(_links.end_positions[i]):
			order.push_back(i)
		else:
			dropped += 1
	_rebuild(order)
	return dropped


## Cut the set down to `budget`, keeping the links that carry the level.
##
## A link joining two different walkable islands is the only way between them and
## is kept unconditionally; every other link is a shortcut across ground its own
## island already reaches, and is spent out of what is left. One link every three
## metres along every roof edge is not traversal, it is noise. Returns how many
## were thrown away.
func _thin_to_budget(budget: int) -> int:
	if _links.size() <= budget:
		return 0
	var essential := PackedInt32Array()
	var spare := PackedInt32Array()
	var seen: Dictionary = {}
	for i: int in _links.size():
		var ca: int = _index.component_at(_links.start_positions[i])
		var cb: int = _index.component_at(_links.end_positions[i])
		if ca == cb and ca >= 0:
			spare.push_back(i)
			continue
		var key: int = (mini(ca, cb) * 100003 + maxi(ca, cb)) * 8 + _links.kinds[i]
		var used: int = int(seen.get(key, 0))
		if used >= _rules.links_per_island_pair:
			spare.push_back(i)
			continue
		seen[key] = used + 1
		essential.push_back(i)
	var order := PackedInt32Array()
	# A hard cap is a hard cap: past the budget even the island joins are strided,
	# because a set the navigation map will not carry connects nothing at all.
	if essential.size() <= budget:
		order = PackedInt32Array(essential)
	else:
		var step: float = float(essential.size()) / float(budget)
		var at: float = 0.0
		while at < float(essential.size()) and order.size() < budget:
			order.push_back(essential[int(at)])
			at += step
	var room: int = budget - order.size()
	# Spare links are taken on an even stride rather than from the front, so what
	# survives is spread across the level instead of piled into whichever corner
	# the border-edge walk happened to start in.
	if room > 0 and not spare.is_empty():
		var stride: float = maxf(float(spare.size()) / float(room), 1.0)
		var t: float = 0.0
		while t < float(spare.size()) and order.size() < budget:
			order.push_back(spare[int(t)])
			t += stride
	var dropped: int = _links.size() - order.size()
	_rebuild(order)
	return dropped


## Rewrite the link set as the given indices, in the given order.
func _rebuild(order: PackedInt32Array) -> void:
	var keep := AILinkBaker.new()
	keep.clear_links()
	for i: int in order:
		keep.start_positions.push_back(_links.start_positions[i])
		keep.end_positions.push_back(_links.end_positions[i])
		keep.kinds.push_back(_links.kinds[i])
		keep.flags.push_back(_links.flags[i])
		keep.layers.push_back(_links.layers[i])
		keep.enter_costs.push_back(_links.enter_costs[i])
		keep.travel_costs.push_back(_links.travel_costs[i])
	_links.start_positions = keep.start_positions
	_links.end_positions = keep.end_positions
	_links.kinds = keep.kinds
	_links.flags = keep.flags
	_links.layers = keep.layers
	_links.enter_costs = keep.enter_costs
	_links.travel_costs = keep.travel_costs


## Whether there is walkable navmesh within `snap_tolerance` of this point.
##
## The four sideways offsets are correctness, not padding. Most link ends sit
## exactly ON a polygon border — that is where the discovery found them — and a
## point-in-polygon test at a vertex is a coin flip in floating point. Asked
## without them, the town pruned 1,461 of its 1,461 links. Asking the index
## rather than `map_get_closest_point` is deliberate too: the answer must not
## depend on how many frames the map has had to sync.
func _walkable_here(p: Vector3) -> bool:
	const NUDGE: float = 0.12
	const OFFSETS: Array[Vector2] = [
		Vector2(0.0, 0.0),
		Vector2(NUDGE, 0.0),
		Vector2(-NUDGE, 0.0),
		Vector2(0.0, NUDGE),
		Vector2(0.0, -NUDGE),
	]
	for o: Vector2 in OFFSETS:
		var y: float = _index.height_at(p.x + o.x, p.z + o.y, p.y)
		if not is_nan(y) and absf(y - p.y) <= _rules.snap_tolerance:
			return true
	return false


func _hits(from: Vector3, to: Vector3) -> bool:
	_query.from = from
	_query.to = to
	var space: PhysicsDirectSpaceState3D = _root.get_world_3d().direct_space_state
	return not space.intersect_ray(_query).is_empty()


# ----------------------------------------------------------------- measurement


## Random street-to-roof pairs, both ends on real navmesh. A roof is a walkable
## surface with another at least `UPPER_LEVEL_MARGIN` below it at the same XZ,
## and a street is the bottom of its own stack — which is what makes the number
## comparable across a flat arena and a town on a hillside.
func _draw_pairs() -> Array[PackedVector3Array]:
	var out: Array[PackedVector3Array] = []
	var box: AABB = _index.bounds
	var tries: int = 0
	while out.size() < REACH_SAMPLES and tries < REACH_SAMPLES * 400:
		tries += 1
		var from: Vector3 = _draw_ground(box)
		var to: Vector3 = _draw_roof(box)
		if is_nan(from.y) or is_nan(to.y):
			continue
		out.push_back(PackedVector3Array([from, to]))
	return out


func _draw_ground(box: AABB) -> Vector3:
	var x: float = _rng.next_range(box.position.x, box.end.x)
	var z: float = _rng.next_range(box.position.z, box.end.z)
	var stack: PackedFloat32Array = _index.stack_at(x, z)
	if stack.is_empty():
		return Vector3(x, NAN, z)
	return Vector3(x, stack[0], z)


func _draw_roof(box: AABB) -> Vector3:
	var x: float = _rng.next_range(box.position.x, box.end.x)
	var z: float = _rng.next_range(box.position.z, box.end.z)
	var stack: PackedFloat32Array = _index.stack_at(x, z)
	var top: int = stack.size() - 1
	if top < 1 or stack[top] - stack[0] < UPPER_LEVEL_MARGIN:
		return Vector3(x, NAN, z)
	return Vector3(x, stack[top], z)


func _arrives(from: Vector3, to: Vector3, layers: int) -> bool:
	var path: PackedVector3Array = _path(from, to, layers)
	if path.size() < 2:
		return false
	return path[path.size() - 1].distance_to(to) <= ARRIVE_TOLERANCE


## One corridor query, at the same polygon budget the agents run with.
func _path(from: Vector3, to: Vector3, layers: int) -> PackedVector3Array:
	var params := NavigationPathQueryParameters3D.new()
	params.map = _map
	params.start_position = from
	params.target_position = to
	params.navigation_layers = layers
	params.path_search_max_polygons = SEARCH_POLYGONS
	var result := NavigationPathQueryResult3D.new()
	NavigationServer3D.query_path(params, result)
	return result.path


# ------------------------------------------------------------------------ misc


func _find_region(node: Node) -> NavigationRegion3D:
	var region := node as NavigationRegion3D
	if region != null and region.navigation_mesh != null:
		return region
	for child: Node in node.get_children():
		var found: NavigationRegion3D = _find_region(child)
		if found != null:
			return found
	return null


## A copy of the rules with no links in it, so each level starts clean and every
## saved set still records the thresholds it was baked with.
func _fresh_set() -> AILinkBaker:
	var out: AILinkBaker = _rules.duplicate() as AILinkBaker
	out.clear_links()
	out.resource_name = "AILinkBaker"
	return out


func _load_rules() -> AILinkBaker:
	if ResourceLoader.exists(RULES_PATH):
		var res: AILinkBaker = ResourceLoader.load(RULES_PATH) as AILinkBaker
		if res != null:
			return res
	var fresh := AILinkBaker.new()
	fresh.resource_name = "AILinkRules"
	DirAccess.make_dir_recursive_absolute(RULES_PATH.get_base_dir())
	ResourceSaver.save(fresh, RULES_PATH)
	return fresh
