class_name AIVantage
extends Resource
## Where a long weapon wants to be standing: the policy that bakes a set of
## overwatch positions and the policy that picks one at runtime.
##
## Cover answers "what is between me and the thing shooting at me". It is a local
## question and the sampler answers it with sixteen rays over one and a quarter
## metres. A vantage point is the opposite question — "from where can I see the
## most ground, from above, at my own weapon's distance" — and it cannot be
## answered locally at all. It needs sightlines measured across the whole level,
## which is a few hundred thousand rays, which is a bake.
##
## THREE TERMS, AND ALL THREE MATTER. Elevation, because shooting down at
## something is worth more than shooting across at it and because height is what
## a spectator reads as a firing position. Coverage, because a rooftop that
## overlooks a wall is not a firing position however high it is. Exposure,
## because a body standing on a bare slab with nothing to drop behind is a body
## that dies on its second magazine — a parapet is worth more than a metre of
## height.
##
## AND REACHABILITY, WHICH IS NOT A SCORE BUT A GATE. Godot's navigation server
## answers a path to an island it cannot reach with a path to the nearest point
## it can, so an agent sent to an unreachable rooftop walks to the bottom of the
## wall and stands there for the rest of the fight. Every point that survives the
## bake has had a real path solved to it from the middle of the level.
##
## The runtime half is deliberately tiny: a linear scan over a few dozen points
## with three rejections in front of the arithmetic, no raycasts and no
## allocation. It runs on FULL ticks only, inside `AICoverMap.query`.
##
## `min_band_range` is what keeps a scattergun off the roof. Selection is driven
## by the band `AICombat.engagement_band()` reports, and that band comes from the
## equipped `GunSpec.effective_range` — so a body carrying a 9 m shotgun never
## looks at a vantage point at all, and the same body that scavenged a 120 m
## marksman rifle next life will climb.

## Sectors in the protection mask. Mirrors `AICoverSet.SECTORS`; a vantage point
## carries the same crouch/standing mask a cover point does.
const SECTORS: int = 8
## Metres beyond which a sightline is not worth measuring at bake time. Longer
## than any weapon in the game reaches and long enough that the term saturates.
const MAX_SIGHTLINE: float = 180.0
## Metres below which a coverage target is too close to say anything about a
## position's command of the ground.
const MIN_SIGHTLINE: float = 6.0

@export_group("Bake")
## Samples of the CONTESTED ground the sightline test is measured against. Every
## candidate is traced to all of them, so this is one half of the bake's cost.
##
## Contested, not navigable. The firefight arena's navigation mesh is a 298 m
## square and the fight happens on a pad a third of that across; measured against
## the whole surface, the best-scoring positions in the level were out in the
## empty desert BEHIND the rim wall, because from there you can see a hundred and
## thirty metres of sand. The cover field is the honest proxy for where a fight
## happens — it is where the level has put something to fight from — so the
## targets are drawn from it and a position that overlooks no cover overlooks
## nothing.
@export_range(32, 512, 8) var coverage_samples: int = 224
## Cover points below which the level is treated as having no contested ground of
## its own and the whole navigable surface is used instead.
@export_range(8, 256, 1) var min_contested: int = 32
## Candidates carried into the sightline pass, taken off a cheap pre-score. The
## other half of the cost.
@export_range(32, 2048, 8) var candidate_limit: int = 384
## Share of those candidates drawn by the height-and-parapet pre-score. The rest
## are a plain spatial stride over the whole navigable surface.
##
## THE SPLIT IS NOT A REFINEMENT, IT IS WHAT MAKES THIS WORK ON A FLAT LEVEL.
## The pre-score is dominated by elevation, and on the firefight arena every one
## of the top three hundred and eighty-five navigable points by that measure is a
## container top or a gantry deck — a navigation island with no way up. Filtered
## for reachability, all of them go, and a pure ranked draw bakes an empty set on
## a level with three hundred and fifty cover points. The strided half is what
## still finds the long clear lane across the pad.
@export_range(0.0, 1.0, 0.01) var elevated_share: float = 0.5
## Points kept in the finished set. A few dozen is plenty — the runtime scan is
## linear over this and every one of them has to be worth walking to.
@export_range(4, 256, 1) var max_points: int = 56
## Metres two kept points must be apart. Without it the whole set lands on one
## roof, because one roof really is the best ground in the level.
@export_range(2.0, 40.0, 0.5) var min_separation: float = 7.0
## Metres above the level's median navigable height before a point counts as
## fully elevated. The elevation term saturates here.
@export_range(0.5, 30.0, 0.1) var elevation_scale: float = 4.0
## Weight on height over the ground it overlooks.
@export_range(0.0, 2.0, 0.01) var elevation_weight: float = 0.34
## Weight on the share of the level's ground the point can actually see.
@export_range(0.0, 2.0, 0.01) var coverage_weight: float = 0.46
## Weight on having something to drop behind at crouch height.
@export_range(0.0, 2.0, 0.01) var protection_weight: float = 0.22
## Penalty on standing in the open at full height.
@export_range(0.0, 2.0, 0.01) var exposure_penalty: float = 0.30
## Share of the sampled ground a point must see before it is a vantage point at
## all. Below this it is just somewhere to stand.
@export_range(0.0, 1.0, 0.01) var min_coverage: float = 0.10
## Height above a contested sample the sightline is traced TO, in metres.
##
## Not the crouch height the cover masks are probed at. A contested sample is by
## definition next to an obstruction, and a ray aimed at half a metre above one
## is a ray into the barrel the body is kneeling behind — measured on the
## firefight pad, that alone threw away most of the level's sightlines. A metre
## is the middle of a body that is using the position rather than the ground it
## is standing on.
@export_range(0.2, 2.5, 0.05) var target_height: float = 1.0
## Reject points the navigation map cannot actually route to. Off only for a
## harness with no navigation map worth the name.
@export var require_reachable: bool = true
## Metres the solved path's last point may miss the candidate by and still count
## as reachable.
@export_range(0.5, 8.0, 0.1) var reach_tolerance: float = 2.5

@export_group("Selection")
## Band top, in metres, below which an agent never considers a vantage point.
## THIS IS THE LINE THAT KEEPS A SHOTGUN OFF THE ROOF.
@export_range(2.0, 200.0, 0.5) var min_band_range: float = 22.0
## Fraction of the band's top an agent will walk to reach one, over and above
## whatever search radius the caller asked for. A marksman will cross the map for
## a good roof; nobody will cross it for a slightly better barrel.
@export_range(0.0, 3.0, 0.01) var travel_fraction: float = 0.62
## How hard the walk counts against the point. At zero a body will always take
## the best vantage in the level however far away it is.
@export_range(0.0, 2.0, 0.01) var travel_penalty: float = 0.55
## Multiplier on the finished vantage score before it is compared against a cover
## point.
##
## Well above one, and it has to be. A cover point scored by `AICoverMap` lands
## between about 0.9 and 1.7; a vantage point that is the best overwatch in the
## level scores 1.0 before its walk is charged for. At a bias of one an agent
## standing next to a barrel picks the barrel every time and nothing ever
## repositions. At 2.2 only a genuinely good position at a genuinely useful range
## wins, which is what should be able to move a body forty metres.
@export_range(0.5, 6.0, 0.01) var bias: float = 2.2
## Bonus for the point this agent already holds. Pure hysteresis, and the reason
## a marksman that has taken a roof stays on it.
@export_range(0.0, 2.0, 0.01) var keep_bonus: float = 0.55
## Fraction of the band's top a contact may sit beyond and still count as
## overlooked from a point whose measured reach falls short.
@export_range(1.0, 2.0, 0.01) var over_reach: float = 1.25
## Weight on the point's own height when an agent is choosing between two of
## them. Separate from the bake weight: this is preference, that was quality.
@export_range(0.0, 2.0, 0.01) var elevation_bonus: float = 0.30


## Whether a body whose band tops out at `band_high` metres has any business
## looking at vantage points at all.
func applies(band_high: float) -> bool:
	return max_points > 0 and band_high >= min_band_range


## Metres this body will walk for a vantage point, given whatever radius the
## caller was going to search for cover in.
func travel_limit(search_radius: float, band_high: float) -> float:
	return maxf(search_radius, band_high * travel_fraction)


## Score vantage point `i` for an agent standing at `from` fighting something at
## `threat`. Zero or less means "not this one" — out of the band, the wrong way
## round, or too far to walk. Allocation-free and raycast-free; this runs inside
## the cover query on a FULL tick.
func score_point(
	data: AICoverSet,
	i: int,
	from: Vector3,
	threat: Vector3,
	band: Vector2,
	limit: float,
	mine: bool
) -> float:
	var p: Vector3 = data.vantage_positions[i]
	var travel: float = from.distance_to(p)
	if travel > limit:
		return 0.0
	var to: Vector3 = threat - p
	to.y = 0.0
	var d: float = to.length()
	if d < band.x * 0.75 or d > band.y:
		return 0.0
	if d > data.vantage_reach[i] * over_reach:
		return 0.0
	if to.dot(data.vantage_facing[i]) < data.vantage_arc_cos[i] * d:
		return 0.0
	var pref: float = (band.x + band.y) * 0.5
	var band_k: float = 1.0 - clampf(absf(d - pref) / maxf(band.y - band.x, 1.0), 0.0, 1.0)
	var travel_k: float = 1.0 - clampf(travel / maxf(limit, 1.0), 0.0, 1.0)
	var lift: float = clampf(data.vantage_elevation[i] / maxf(elevation_scale, 0.1), 0.0, 1.0)
	var s: float = data.vantage_score[i] * (0.45 + 0.55 * band_k)
	s += lift * elevation_bonus
	s -= (1.0 - travel_k) * travel_penalty
	if mine:
		s += keep_bonus
	return maxf(s, 0.0) * bias


## Bake the vantage set.
##
## `ground` is every point the navigation mesh accepted, `masks` the crouch and
## standing protection bits the cover sampler already measured at each of them,
## `cover_rows` the indices into `ground` that qualified as cover, and `eye_h`
## the height the sightline is traced FROM. Returns the packed arrays
## `AICoverSet` stores, plus a `log` line for the bake report.
##
## Cost is `candidate_limit` times `coverage_samples` rays plus one path query
## per candidate. At the shipped settings that is about eighty thousand
## intersections, a fifth of what the cover pass already spends.
func bake(
	space: PhysicsDirectSpaceState3D,
	nav_map: RID,
	ground: PackedVector3Array,
	masks: PackedInt32Array,
	cover_rows: PackedInt32Array,
	eye_h: float
) -> Dictionary:
	var out: Dictionary = _empty()
	if ground.size() < 8 or max_points <= 0:
		out["log"] = "%d ground samples, nothing to bake" % ground.size()
		return out
	var contested: PackedInt32Array = cover_rows
	if contested.size() < min_contested:
		contested = _stride(ground.size(), ground.size())
	var datum: float = _median_height(ground)
	var targets: PackedInt32Array = _pick(contested, coverage_samples)
	var candidates: PackedInt32Array = _pre_score(ground, masks, contested, datum)
	# Reachability BEFORE the sightline pass, not after: one path query against a
	# few hundred rays, and filtering first means every ray is spent on a position
	# a body could actually be ordered to. Paths are solved from the middle of the
	# contested ground, which is where the bodies that will use these actually are.
	var origin: Vector3 = _reference_point(ground, targets)
	var routable := PackedInt32Array()
	for c: int in candidates:
		if _reachable(nav_map, origin, ground[c]):
			routable.append(c)
	var query := PhysicsRayQueryParameters3D.new()
	query.collision_mask = GameLayers.WORLD | GameLayers.PROP
	query.collide_with_areas = false

	var scored: Array[Dictionary] = []
	for c: int in routable:
		var row: Dictionary = _measure(space, query, ground, masks, targets, c, datum, eye_h)
		if not row.is_empty():
			scored.append(row)
	_finalise(scored)
	scored.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["score"] > b["score"])
	out = _select(scored, ground)
	out["log"] = (
		"%d kept, %d scored, %d routable of %d candidates, %d ground samples, datum y %.2f"
		% [
			(out["positions"] as PackedVector3Array).size(),
			scored.size(),
			routable.size(),
			candidates.size(),
			targets.size(),
			datum
		]
	)
	return out


## Empty packed arrays in the shape `bake` returns, so a level with no navigable
## ground still hands `AICoverSet` something to store.
static func _empty() -> Dictionary:
	return {
		"positions": PackedVector3Array(),
		"facing": PackedVector3Array(),
		"arc_cos": PackedFloat32Array(),
		"reach": PackedFloat32Array(),
		"score": PackedFloat32Array(),
		"elevation": PackedFloat32Array(),
		"exposure": PackedFloat32Array(),
		"masks": PackedInt32Array(),
		"log": ""
	}


## The level's own floor. A median rather than a minimum, so one sunken drain
## does not make the whole map look elevated.
func _median_height(ground: PackedVector3Array) -> float:
	var ys := PackedFloat32Array()
	ys.resize(ground.size())
	for i: int in ground.size():
		ys[i] = ground[i].y
	ys.sort()
	return ys[ys.size() / 2]


## Evenly spaced indices, at most `want` of them. A stride rather than a random
## draw so the bake is deterministic and the sample is spread over the level
## instead of clustered wherever the generator happened to land.
func _stride(count: int, want: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	if count <= 0 or want <= 0:
		return out
	var step: float = maxf(float(count) / float(want), 1.0)
	var at: float = 0.0
	while int(at) < count:
		out.append(int(at))
		at += step
	return out


## Cheap ordering over every navigable point, to decide which ones are worth
## tracing a few hundred rays from. Height and a parapet, which are the two
## things that can be known without a sightline.
##
## Bucketed rather than sorted. A comparator sort over the twenty-odd thousand
## points a 300 m level accepts is a third of a million GDScript calls through a
## lambda; a fixed histogram is one pass and answers the only question being
## asked, which is "which slice is the top few hundred". Order inside the cut-off
## bucket does not matter — every survivor is scored properly afterwards.
func _pre_score(
	ground: PackedVector3Array, masks: PackedInt32Array, contested: PackedInt32Array, datum: float
) -> PackedInt32Array:
	var n: int = ground.size()
	var want: int = clampi(int(float(candidate_limit) * elevated_share), 0, candidate_limit)
	var rank := PackedFloat32Array()
	rank.resize(n)
	var lowest: float = INF
	var highest: float = -INF
	for i: int in n:
		var lift: float = clampf((ground[i].y - datum) / maxf(elevation_scale, 0.1), 0.0, 1.0)
		var low: float = float(_bits(masks[i] & 0xFF)) / float(SECTORS)
		var high: float = float(_bits((masks[i] >> 8) & 0xFF)) / float(SECTORS)
		var r: float = lift * elevation_weight + low * protection_weight - (1.0 - high) * 0.04
		rank[i] = r
		lowest = minf(lowest, r)
		highest = maxf(highest, r)
	var span: float = maxf(highest - lowest, 1e-4)
	var bins: int = 64
	var count := PackedInt32Array()
	count.resize(bins)
	for i: int in n:
		count[_bin(rank[i], lowest, span, bins)] += 1
	var cut: int = 0
	var running: int = 0
	for b: int in range(bins - 1, -1, -1):
		running += count[b]
		if running >= want:
			cut = b
			break
	var top := PackedInt32Array()
	for i: int in n:
		if _bin(rank[i], lowest, span, bins) >= cut:
			top.append(i)
	# A level with no relief puts every point in one bucket, so the ranked draw is
	# strided down rather than traced from in full. The walk runs x then z, so a
	# stride is a spatial spread and not a corner of the map.
	var taken: Dictionary = {}
	var out := PackedInt32Array()
	for k: int in _stride(top.size(), want):
		taken[top[k]] = true
		out.append(top[k])
	# The rest come off the contested ground rather than off the whole surface,
	# for the reason `coverage_samples` sets out: most of a navigation mesh is
	# nowhere anybody fights, and tracing two hundred candidates from it is two
	# hundred candidates' worth of rays spent proving that sand overlooks sand.
	for i: int in _pick(contested, candidate_limit - out.size()):
		if not taken.has(i):
			taken[i] = true
			out.append(i)
	return out


## `want` evenly spaced entries out of `source`, which is itself a list of
## indices into the ground array.
func _pick(source: PackedInt32Array, want: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	for k: int in _stride(source.size(), want):
		out.append(source[k])
	return out


static func _bin(value: float, lowest: float, span: float, bins: int) -> int:
	return clampi(int((value - lowest) / span * float(bins)), 0, bins - 1)


## Trace one candidate against the ground sample and turn what it can see into a
## score, a mean bearing, an arc and a reach. Empty when the point sees too
## little of the level to be worth keeping.
func _measure(
	space: PhysicsDirectSpaceState3D,
	query: PhysicsRayQueryParameters3D,
	ground: PackedVector3Array,
	masks: PackedInt32Array,
	targets: PackedInt32Array,
	c: int,
	datum: float,
	eye_h: float
) -> Dictionary:
	var p: Vector3 = ground[c]
	var eye: Vector3 = p + Vector3(0.0, eye_h, 0.0)
	var seen := PackedVector3Array()
	var dists := PackedFloat32Array()
	var tested: int = 0
	for t: int in targets:
		if t == c:
			continue
		var q: Vector3 = ground[t]
		var flat := Vector3(q.x - p.x, 0.0, q.z - p.z)
		var d: float = flat.length()
		if d < MIN_SIGHTLINE or d > MAX_SIGHTLINE:
			continue
		tested += 1
		query.from = eye
		query.to = q + Vector3(0.0, target_height, 0.0)
		if not space.intersect_ray(query).is_empty():
			continue
		seen.append(flat / d)
		dists.append(d)
	if tested < 8:
		return {}
	var coverage: float = float(seen.size()) / float(tested)
	if coverage < min_coverage:
		return {}
	var arc: Array = _arc(seen)
	return {
		"index": c,
		"score": 0.0,
		"coverage": coverage,
		"facing": arc[0],
		"arc_cos": arc[1],
		"reach": _percentile(dists, 0.8),
		"elevation": maxf(p.y - datum, 0.0),
		"exposure": 1.0 - float(_bits((masks[c] >> 8) & 0xFF)) / float(SECTORS),
		"protection": float(_bits(masks[c] & 0xFF)) / float(SECTORS),
		"mask": masks[c]
	}


## Turn the raw measurements into the 0-1 quality the runtime compares against a
## cover score.
##
## COVERAGE IS NORMALISED AGAINST THE BEST POINT IN THE LEVEL, not against unity,
## and that is the difference between this working and not. The absolute share of
## the contested ground one position overlooks is small — a tenth to a third on
## the firefight pad — so weighted against a flat exposure penalty every single
## point in the level scored zero and the whole field was inert. What the
## selection actually wants to know is which position commands the MOST, and that
## is a relative question.
##
## Exposure is applied as a multiplier rather than a subtraction for the same
## reason: it should discount a good position, not be capable of erasing one.
func _finalise(scored: Array[Dictionary]) -> void:
	var best_cov: float = 0.0
	for row: Dictionary in scored:
		best_cov = maxf(best_cov, float(row["coverage"]))
	var best_raw: float = 0.0
	for row: Dictionary in scored:
		var lift: float = clampf(float(row["elevation"]) / maxf(elevation_scale, 0.1), 0.0, 1.0)
		var cov: float = float(row["coverage"]) / maxf(best_cov, 1e-4)
		var raw: float = lift * elevation_weight + cov * coverage_weight
		raw += float(row["protection"]) * protection_weight
		raw *= 1.0 - exposure_penalty * float(row["exposure"])
		row["score"] = maxf(raw, 0.0)
		best_raw = maxf(best_raw, raw)
	# Rescaled so the best position in the level is exactly one, whatever the
	# level is. That is what gives `bias` a meaning that survives being moved from
	# a flat pad to a town with rooftops: it is always "how much better than good
	# cover is the best overwatch here", never a raw weight sum.
	for row: Dictionary in scored:
		row["score"] = clampf(float(row["score"]) / maxf(best_raw, 1e-4), 0.0, 1.0)


## Mean bearing over everything the point can see, and the cosine of the
## half-angle that holds four fifths of it. Together they are the firing arc: at
## runtime a contact outside it is a contact this position does not overlook,
## and the test is one dot product.
func _arc(seen: PackedVector3Array) -> Array:
	var sum := Vector3.ZERO
	for v: Vector3 in seen:
		sum += v
	if sum.length_squared() < 1e-6:
		return [Vector3.FORWARD, -1.0]
	var facing: Vector3 = sum.normalized()
	var dots := PackedFloat32Array()
	dots.resize(seen.size())
	for i: int in seen.size():
		dots[i] = facing.dot(seen[i])
	dots.sort()
	return [facing, dots[int(float(dots.size()) * 0.2)]]


static func _percentile(values: PackedFloat32Array, t: float) -> float:
	if values.is_empty():
		return 0.0
	var copy: PackedFloat32Array = values.duplicate()
	copy.sort()
	return copy[clampi(int(float(copy.size()) * t), 0, copy.size() - 1)]


## Take the best points in order, refusing any that crowd one already taken.
## Everything reaching here has already passed the routing gate.
##
## Every array is a local. A packed array read out of a Dictionary in GDScript is
## a COPY — appending to `out["facing"]` in place appends to a temporary and
## throws it away — so the whole set is assembled in locals and handed back at
## once.
func _select(scored: Array[Dictionary], ground: PackedVector3Array) -> Dictionary:
	var sep2: float = min_separation * min_separation
	var positions := PackedVector3Array()
	var facing := PackedVector3Array()
	var arc_cos := PackedFloat32Array()
	var reach := PackedFloat32Array()
	var score := PackedFloat32Array()
	var elevation := PackedFloat32Array()
	var exposure := PackedFloat32Array()
	var kept_masks := PackedInt32Array()
	for row: Dictionary in scored:
		if positions.size() >= max_points:
			break
		var p: Vector3 = ground[int(row["index"])]
		var crowded: bool = false
		for q: Vector3 in positions:
			if q.distance_squared_to(p) < sep2:
				crowded = true
				break
		if crowded:
			continue
		positions.append(p)
		facing.append(row["facing"])
		arc_cos.append(row["arc_cos"])
		reach.append(row["reach"])
		score.append(row["score"])
		elevation.append(row["elevation"])
		exposure.append(row["exposure"])
		kept_masks.append(int(row["mask"]))
	return {
		"positions": positions,
		"facing": facing,
		"arc_cos": arc_cos,
		"reach": reach,
		"score": score,
		"elevation": elevation,
		"exposure": exposure,
		"masks": kept_masks,
		"log": ""
	}


## Somewhere an agent actually stands: the contested sample nearest the centroid
## of the contested ground. Paths are solved from here, so "reachable" means
## reachable from the middle of the fight rather than from a corner of the map.
func _reference_point(ground: PackedVector3Array, contested: PackedInt32Array) -> Vector3:
	if contested.is_empty():
		return ground[0]
	var mid := Vector3.ZERO
	for i: int in contested:
		mid += ground[i]
	mid /= float(contested.size())
	var best: Vector3 = ground[contested[0]]
	var best_d: float = INF
	for i: int in contested:
		var d: float = ground[i].distance_squared_to(mid)
		if d < best_d:
			best_d = d
			best = ground[i]
	return best


## Whether the navigation map will really route a body to `p`.
##
## `map_get_path` answers an unreachable destination with a path to the closest
## point it CAN reach rather than with nothing, which is why this compares the
## path's last point against the destination instead of testing the path for
## emptiness. A roof with no way up scores beautifully and is a trap.
func _reachable(nav_map: RID, origin: Vector3, p: Vector3) -> bool:
	if not require_reachable or not nav_map.is_valid():
		return true
	var path: PackedVector3Array = NavigationServer3D.map_get_path(nav_map, origin, p, true)
	if path.is_empty():
		return false
	return path[path.size() - 1].distance_to(p) <= reach_tolerance


static func _bits(v: int) -> int:
	var n: int = 0
	var b: int = v
	while b != 0:
		n += b & 1
		b >>= 1
	return n
