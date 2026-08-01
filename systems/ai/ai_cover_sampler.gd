class_name AICoverSampler
extends RefCounted
## Bake-time cover and vantage analysis. Never runs in a shipping frame.
##
## Walks a grid over the navigable ground, and at every point that the navigation
## mesh actually accepts, fires eight rays at crouch height and eight at standing
## height. A point that stops nothing is not cover and is discarded; a point that
## stops everything is inside a wall and is discarded too. What survives is a
## barrel you can kneel behind, a low wall you can shoot over, and the inside
## corner of a building — which is exactly the vocabulary the combat code speaks.
##
## Sixteen rays per candidate over a 200 m town is a few hundred thousand
## intersections. That is nothing offline and unthinkable at runtime, which is why
## this lives on the bake side of the line.
##
## THE WHOLE SURFACE IS KEPT, not just the points that turned out to be cover.
## Open ground is where a fight happens, and `AIVantage` needs it twice over: as
## the population it measures sightlines against, and as the pool it draws
## overwatch candidates from. Discarding it — which this used to do the moment a
## point's crouch mask came back empty — leaves the vantage pass measuring the
## level's command of its own barrels.

## Default distance the probes reach. Anything further away is scenery, not cover.
##
## THIS NUMBER DECIDES HOW MUCH COVER THE LEVEL HAS, and at 1.25 m it decided
## "almost none". Measured on the firefight pad, holding the bake's own spacing
## and cell size and varying nothing else:
##
##     probe   points   inside 30 m   in reach of a body   queries with nothing
##     1.25      350         9               4.1                  24%
##     2.00      580        19               6.8                  16%
##     2.60      946        33              10.4                   3%
##     3.20     1455        62              17.5                   0%
##
## The middle column is the one that mattered. `FirefightDirector` stands the whole
## war up inside thirty metres of the contested centre and NINE baked points were
## in it, so cover was not being refused by a weight — there was nothing there to
## refuse. The mean number of compass sectors a point blocks does not move across
## that sweep (1.95, 2.05, 1.93, 1.92) and neither does the share of points that
## shield a given bearing (20%, 23%, 25%, 23%), so the points this buys are the
## same KIND of point, not a looser one.
##
## THE HARD RULE UNDER IT: the probe reach must exceed the sample spacing. The
## band of ground around an obstruction that counts as cover is `probe` wide, and
## a grid stepping further than that walks over most obstructions without ever
## landing in their band — whether a given crate yields cover points at all
## becomes an accident of where the grid origin fell. `sample` clamps for this.
##
## 2.6 m is a stride and a half from the thing you are behind: close enough that a
## container is still between you and the fire and that the frame reads as a body
## tucked in, far enough that a two-metre grid cannot miss it.
const PROBE_DISTANCE: float = 2.6
## Multiple of the sample spacing the probe reach is never allowed below. At 1.25
## the shipped bake was sampling on a 2.0 m grid through a 1.25 m band.
##
## THIS IS ALSO WHAT MAKES THE REFINEMENT PASS BELOW SUFFICIENT. Refinement only
## looks around ground the uniform walk ALREADY called cover, so it cannot rescue
## an obstruction the uniform walk missed entirely — and this is the rule that
## guarantees it never misses one. Every square metre of the pad is within
## `spacing * sqrt(2) / 2` of a grid node, so at any multiple above 0.71 an
## obstruction is inside some node's probe reach. 1.25 clears that with room.
const MIN_PROBE_SPACINGS: float = 1.25
## Times the grid is halved around ground that turned out to be cover.
##
## THE UNIFORM GRID IS THE WRONG SHAPE FOR THE QUESTION. Cover is a property of the
## metre or two of ground hard against an obstruction, and that band is a vanishing
## fraction of a 176 m pad — so a grid fine enough to resolve it everywhere spends
## almost all of its samples proving that open sand is open, and one coarse enough
## to afford spends a handful of samples on each container. Measured on the
## firefight pad at 2.0 m spacing: 946 cover points, and a body's 14 m search disc
## came back with NOTHING on 72% of the scans its close-quarters bodies made.
##
## So the walk is uniform once, and then every point it accepted as cover has the
## ground around it re-sampled at half the step, twice. That puts the samples where
## cover can physically be — hard against the things that stop rounds — without
## needing to be told where the fight is, and it is self-targeting on any level
## rather than tuned for this one. Cost is proportional to how much cover the level
## HAS, not to its area.
##
## It also fixes the thing the sector mask gets wrong at coarse spacing. A point is
## only protection against a bearing whose 45 degree sector it blocks, so one
## sample beside a container shields one arc; the ring of samples around it shields
## every arc, and which body can use that container stops being an accident of
## where the grid origin fell. Measured: `unprotected` was refusing 42% of every
## candidate scored in the live demo.
##
## Zero restores the single uniform pass.
const REFINE_PASSES: int = 2
## Fraction of the coarse step the refinement stencil uses. Half, so two passes
## reach one coarse cell out from anything the uniform walk found.
const REFINE_STEP: float = 0.5


## Sample `bounds` and return the baked set. `space` must come from the same world
## the navigation map belongs to, and the world must be fully built — call this
## after the level's geometry and its `NavigationRegion3D` are in the tree.
##
## `cfg` overrides the defaults by key: `spacing`, `low_height`, `high_height`,
## `probe_distance`, `cell_size`, `collision_mask`, `snap_tolerance`. Pass an
## authored `AIVantage` under `vantage` to retune the overwatch bake, or `false`
## under `bake_vantage` to skip it entirely. `cfg` is written back to as well:
## `ground_samples` and `vantage_log` come out of it, so a bake tool can report
## what the pass actually did without this having to return two things.
static func sample(
	space: PhysicsDirectSpaceState3D, nav_map: RID, bounds: AABB, cfg: Dictionary = {}
) -> AICoverSet:
	var spacing: float = float(cfg.get("spacing", 1.8))
	var low_h: float = float(cfg.get("low_height", 0.55))
	var high_h: float = float(cfg.get("high_height", 1.5))
	# Clamped against the spacing, not taken on trust: a probe shorter than the
	# grid step aliases, and the caller that asks for one has no way to see it in
	# the output — the bake just quietly reports fewer points.
	var probe: float = maxf(
		float(cfg.get("probe_distance", PROBE_DISTANCE)), spacing * MIN_PROBE_SPACINGS
	)
	var cell_size: float = float(cfg.get("cell_size", 4.0))
	var mask: int = int(cfg.get("collision_mask", GameLayers.WORLD | GameLayers.PROP))
	var passes: int = int(cfg.get("refine_passes", REFINE_PASSES))
	# Every point from either pass is keyed on the FINE grid, so a refined sample
	# that lands on a coarse one is dropped rather than baked twice. Keying the
	# coarse walk on its own step instead would round two fine neighbours onto the
	# same key and throw away the resolution the second pass just bought.
	var fine: float = spacing * (REFINE_STEP if passes > 0 else 1.0)
	var snap_tol: float = float(cfg.get("snap_tolerance", spacing * 0.75))
	var fine_snap: float = fine * 0.75

	var query := PhysicsRayQueryParameters3D.new()
	query.collision_mask = mask
	query.collide_with_areas = false

	# Every navigable point the walk accepted, and its two sector masks. The cover
	# set is a subset of this — `cover_rows` names which — and the vantage pass
	# reads both: the whole surface for candidates, the cover subset for the
	# contested ground it measures sightlines against.
	var ground := PackedVector3Array()
	var ground_mask := PackedInt32Array()
	var cover_rows := PackedInt32Array()
	var raw_pos := PackedVector3Array()
	var raw_norm := PackedVector3Array()
	var raw_mask := PackedInt32Array()
	var raw_quality := PackedFloat32Array()
	var seen := {}

	var y_probe: float = bounds.position.y + bounds.size.y * 0.5
	var x: float = bounds.position.x
	while x <= bounds.end.x:
		var z: float = bounds.position.z
		while z <= bounds.end.z:
			var wanted := Vector3(x, y_probe, z)
			var p: Vector3 = NavigationServer3D.map_get_closest_point(nav_map, wanted)
			z += spacing
			if Vector2(p.x - wanted.x, p.z - wanted.z).length() > snap_tol:
				continue
			var key: Vector3i = Vector3i(roundi(p.x / fine), roundi(p.y / fine), roundi(p.z / fine))
			if seen.has(key):
				continue
			seen[key] = true
			var probed: Array = _probe_point(space, query, p, low_h, high_h, probe)
			ground.append(p)
			ground_mask.append(int(probed[0]))
			if int(probed[1]) > 0:
				cover_rows.append(ground.size() - 1)
				raw_pos.append(p)
				raw_norm.append(probed[2])
				raw_mask.append(int(probed[0]))
				raw_quality.append(float(probed[3]))
		x += spacing

	# Refinement. The frontier is the cover the last pass found; each round asks the
	# eight fine neighbours of every point on it, and whatever of those turns out to
	# be cover becomes the next frontier. So the fine grid grows outward from each
	# obstruction and stops the moment it reaches ground that stops nothing, which is
	# the only place the extra samples would have been wasted.
	var frontier: PackedVector3Array = raw_pos.duplicate()
	var coarse_points: int = raw_pos.size()
	for _pass: int in passes:
		var next := PackedVector3Array()
		for f: int in frontier.size():
			var seed_p: Vector3 = frontier[f]
			for ox: int in range(-1, 2):
				for oz: int in range(-1, 2):
					if ox == 0 and oz == 0:
						continue
					var wanted := Vector3(
						seed_p.x + float(ox) * fine, y_probe, seed_p.z + float(oz) * fine
					)
					var p: Vector3 = NavigationServer3D.map_get_closest_point(nav_map, wanted)
					if Vector2(p.x - wanted.x, p.z - wanted.z).length() > fine_snap:
						continue
					var key: Vector3i = Vector3i(
						roundi(p.x / fine), roundi(p.y / fine), roundi(p.z / fine)
					)
					if seen.has(key):
						continue
					seen[key] = true
					var probed: Array = _probe_point(space, query, p, low_h, high_h, probe)
					ground.append(p)
					ground_mask.append(int(probed[0]))
					if int(probed[1]) > 0:
						cover_rows.append(ground.size() - 1)
						raw_pos.append(p)
						raw_norm.append(probed[2])
						raw_mask.append(int(probed[0]))
						raw_quality.append(float(probed[3]))
						next.append(p)
		frontier = next

	var out: AICoverSet = _pack(raw_pos, raw_norm, raw_mask, raw_quality, cell_size)
	cfg["ground_samples"] = ground.size()
	# Reported back rather than assumed, because the clamp above can raise it and a
	# bake that silently sampled at a different reach than it was asked to is the
	# kind of thing nobody notices for a year.
	cfg["probe_used"] = probe
	cfg["refine_step"] = fine
	cfg["coarse_points"] = coarse_points
	cfg["vantage_log"] = ""
	if bool(cfg.get("bake_vantage", true)):
		var policy: AIVantage = cfg.get("vantage", null) as AIVantage
		if policy == null:
			policy = AIVantage.new()
		var packed: Dictionary = policy.bake(
			space, nav_map, ground, ground_mask, cover_rows, high_h
		)
		out.set_vantage(packed)
		cfg["vantage_log"] = packed["log"]
	return out


## Sixteen rays at one point. Returns `[mask, cover_rank, normal, quality]`, where
## `cover_rank` is zero for a point that is not cover — open ground, or the inside
## of a wall — and one for a point that is. The mask and the normal are returned
## either way, because the vantage pass wants them for every navigable point.
static func _probe_point(
	space: PhysicsDirectSpaceState3D,
	query: PhysicsRayQueryParameters3D,
	p: Vector3,
	low_h: float,
	high_h: float,
	probe: float
) -> Array:
	var low_bits: int = 0
	var high_bits: int = 0
	var low_count: int = 0
	var open_dir := Vector3.ZERO
	for k: int in AICoverSet.SECTORS:
		var dir: Vector3 = AICoverSet.sector_direction(k)
		query.from = p + Vector3(0.0, low_h, 0.0)
		query.to = query.from + dir * probe
		if not space.intersect_ray(query).is_empty():
			low_bits |= 1 << k
			low_count += 1
		else:
			open_dir += dir
		query.from = p + Vector3(0.0, high_h, 0.0)
		query.to = query.from + dir * probe
		if not space.intersect_ray(query).is_empty():
			high_bits |= 1 << k
	var mask: int = low_bits | (high_bits << 8)
	var normal: Vector3 = (
		open_dir.normalized() if open_dir.length_squared() > 1e-6 else Vector3.FORWARD
	)
	if low_count == 0 or low_count >= AICoverSet.SECTORS:
		return [mask, 0, normal, 0.0]
	# A point whose low sectors are blocked but whose high sectors are open is a
	# firing position; score it above a hole that only hides you.
	var peek: float = 1.0 - float(_bit_count(high_bits)) / float(maxi(low_count, 1))
	var span: float = float(low_count) / float(AICoverSet.SECTORS)
	return [mask, 1, normal, clampf(span * 0.6 + clampf(peek, 0.0, 1.0) * 0.4, 0.0, 1.0)]


## Sort the raw points into grid-cell runs and emit the resource. Sorting here is
## the reason the runtime index is a single Dictionary build.
static func _pack(
	pos: PackedVector3Array,
	norm: PackedVector3Array,
	mask: PackedInt32Array,
	quality: PackedFloat32Array,
	cell_size: float
) -> AICoverSet:
	var buckets: Dictionary = {}
	for i: int in pos.size():
		var key: int = AICoverSet.key_for(pos[i], cell_size)
		if not buckets.has(key):
			buckets[key] = PackedInt32Array()
		var run: PackedInt32Array = buckets[key]
		run.append(i)
		buckets[key] = run

	var keys: Array = buckets.keys()
	keys.sort()

	var out := AICoverSet.new()
	out.cell_size = cell_size
	out.cell_keys.resize(keys.size())
	out.cell_starts.resize(keys.size() + 1)
	var write: int = 0
	for slot: int in keys.size():
		var key: int = keys[slot]
		out.cell_keys[slot] = key
		out.cell_starts[slot] = write
		for i: int in buckets[key] as PackedInt32Array:
			out.positions.append(pos[i])
			out.normals.append(norm[i])
			out.masks.append(mask[i])
			out.quality.append(quality[i])
			write += 1
	out.cell_starts[keys.size()] = write
	return out


static func _bit_count(v: int) -> int:
	var n: int = 0
	var b: int = v
	while b != 0:
		n += b & 1
		b >>= 1
	return n
