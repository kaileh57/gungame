class_name AILinkBaker
extends Resource
## The baked off-mesh link set, and the rules that produced it.
##
## A navmesh only says where you can WALK. Everything that makes a fighter look
## like it knows the building — a ladder up the back wall, a drop off a container,
## a vault over a chest-high barricade, a hop across a roof plank — is an
## off-mesh link, and Godot's navigation server has a first-class object for it:
## `NavigationLink3D`. Bake the set, hand it to the server, and the corridor
## search routes through it for free. Nothing is discovered at runtime.
##
## WHY THE RULES LIVE ON THE ARTEFACT. This resource is both the link set and the
## thresholds that generated it, so a set on disk carries the geometry it was
## built from AND the numbers that decided which gap counted as a vault and which
## as a jump. `res://data/ai/link_rules.tres` is an instance with no links in it,
## kept purely as the tuning box `tools/bake_nav_links.gd` reads.
##
## MOBILITY IS A NAVIGATION LAYER, NOT AN `if`. Every link carries the capability
## bit it demands; every agent carries the union of the bits it has. Godot's path
## query already intersects the two, so a quadruped's search *never sees* the
## ladder — it does not path through it and then fail, it paths around it. That is
## the whole reason this is done with layers instead of a per-step check, and it
## costs nothing per agent per frame.

## What a link is, which decides the motion `AITraversal` plays over it.
enum Kind {
	## Bolted steel ladder. Up the rungs facing the wall, top out onto the deck.
	LADDER,
	## Pull up onto a ledge no taller than a species can reach.
	MANTLE,
	## Over a chest-high obstruction with clear air above it.
	VAULT,
	## Off a ledge and down. One-way by construction.
	DROP,
	## Across a gap with nothing under it.
	JUMP,
}

## Bit 0. Ordinary walking. Every region and every agent has it.
const LAYER_WALK: int = 1 << 0
const LAYER_CLIMB: int = 1 << 1
const LAYER_MANTLE: int = 1 << 2
const LAYER_VAULT: int = 1 << 3
## Bits 4-6, one per entry in `DROP_TIERS`.
const LAYER_DROP_BASE: int = 4
## Bits 7-8, one per entry in `JUMP_TIERS`.
const LAYER_JUMP_BASE: int = 7
## Everything an unconstrained agent may use.
const LAYER_ALL: int = (1 << 9) - 1

## Fall heights the link set quantises to, metres. A link takes the lowest tier
## that contains it and an agent takes every tier whose ceiling it can survive, so
## the rounding is always in the safe direction: an agent never takes a drop
## deeper than its own limit, it only declines one it could have made.
const DROP_TIERS: PackedFloat32Array = [1.6, 3.2, 6.0]
## Gap spans the link set quantises to, metres. Same conservative rounding.
const JUMP_TIERS: PackedFloat32Array = [2.2, 4.0]

## Bit 0 of `flags`: the link may be walked in both directions.
const FLAG_BIDIRECTIONAL: int = 1 << 0

## Metadata key the spawned `NavigationLink3D` carries its kind under, so the
## runtime traversal can ask a link what it is without a second lookup table.
const META_KIND: StringName = &"ai_link_kind"

@export_group("Links")
@export var start_positions: PackedVector3Array = PackedVector3Array()
@export var end_positions: PackedVector3Array = PackedVector3Array()
## One `Kind` per link.
@export var kinds: PackedByteArray = PackedByteArray()
## `FLAG_*` bits per link.
@export var flags: PackedByteArray = PackedByteArray()
## Navigation layer mask per link — the capability it demands.
@export var layers: PackedInt32Array = PackedInt32Array()
## Cost of entering the link, in metres-equivalent. What makes an agent prefer
## walking round to a door over hurling itself off a roof when both arrive.
@export var enter_costs: PackedFloat32Array = PackedFloat32Array()
## Cost of the link's own traverse, in metres-equivalent.
@export var travel_costs: PackedFloat32Array = PackedFloat32Array()

@export_group("Ladder rules")
## Metres out from the rung plane the mount point sits. Roughly a body radius:
## the agent stands off the ladder, not inside it.
@export_range(0.1, 2.0, 0.01) var ladder_stand_off: float = 0.62
## Metres past the top rung the dismount point starts looking for a deck. The
## navmesh is eroded by an agent radius from the parapet, so the first walkable
## roof is never level with the rungs.
@export_range(0.0, 2.0, 0.01) var ladder_top_lead: float = 0.45
## Metres past the top rung the deck search gives up.
@export_range(0.5, 6.0, 0.05) var ladder_deck_reach: float = 2.8
## Metres between deck probes.
@export_range(0.05, 1.0, 0.05) var ladder_deck_step: float = 0.25
## How far off the top rung a deck may sit and still be this ladder's deck. Past
## this the ladder ends nowhere walkable and is not baked at all — better no link
## than one that drops an agent back into the street it started from.
@export_range(0.2, 6.0, 0.05) var ladder_deck_tolerance: float = 1.6
## Metres above the recorded foot the mount point sits, to clear a kerb.
@export_range(0.0, 1.0, 0.01) var ladder_foot_lift: float = 0.05
## Ladders shorter than this are a step, not a climb, and are skipped.
@export_range(0.3, 6.0, 0.05) var ladder_min_height: float = 1.1
## Entry cost of a ladder in metres-equivalent. High: climbing is slow and a
## squad should only do it when the ladder genuinely shortens the job.
@export_range(0.0, 200.0, 0.5) var ladder_enter_cost: float = 14.0

@export_group("Ledge rules")
## Metres along a navmesh border edge between probes. Smaller finds more links and
## costs bake time roughly linearly.
@export_range(0.4, 6.0, 0.05) var edge_sample_step: float = 1.35
## Border edges shorter than this are corners and noise, and are skipped.
@export_range(0.1, 4.0, 0.05) var edge_min_length: float = 0.55
## Metres outward the first landing probe sits.
@export_range(0.3, 4.0, 0.05) var probe_near: float = 0.9
## Metres outward the last landing probe sits. The widest gap anything may cross.
@export_range(1.0, 8.0, 0.05) var probe_far: float = 4.2
## Metres between outward probes.
@export_range(0.1, 2.0, 0.05) var probe_step: float = 0.45
## How far the found navmesh point may sit from the probe and still count as the
## same place, metres. Bigger accepts sloppier landings.
@export_range(0.05, 2.0, 0.01) var probe_tolerance: float = 0.55
## Drops shallower than this are a kerb the navmesh already joined.
@export_range(0.1, 3.0, 0.01) var drop_min: float = 0.85
## Drops deeper than this are never baked at all, whatever the species.
@export_range(1.0, 24.0, 0.1) var drop_max: float = 6.0
## A step up no taller than this is a mantle: one hand on the lip and over.
@export_range(0.3, 4.0, 0.01) var mantle_max: float = 1.5
## A step up between `mantle_max` and this is a free climb — the side of a
## shipping container, a stack of crates, a loading bay. It bakes as a LADDER,
## because that is exactly what it is: hands, a vertical haul, and a step out on
## top. Anything without hands is excluded by the climb layer, so a quadruped
## still cannot get onto the container it is standing next to.
@export_range(0.5, 8.0, 0.05) var climb_max: float = 3.4
## Gaps no wider than this, with something solid low and clear air high, are
## vaults rather than jumps.
@export_range(0.4, 3.0, 0.01) var vault_max_span: float = 1.5
## Height the obstruction probe runs at, metres. Knee to waist.
@export_range(0.1, 1.6, 0.01) var vault_probe_height: float = 0.55
## Height the clearance probe runs at, metres. Anything solid here is a wall, not
## something to be vaulted.
@export_range(0.5, 3.0, 0.01) var vault_clear_height: float = 1.45
## Metres below the gap a floor probe reaches. A hit means the ground is
## continuous under the gap — the hole is navmesh erosion, not a void — and
## nothing is baked, because a link there is a scripted crossing over ground the
## body could have walked. Measured before this rule existed: 35 such links in the
## arena, 206 in `firefight`, and the bake's own audit scored every one of them
## "0 join new ground" while agents spent the run hopping back and forth over
## them and reached almost nothing.
@export_range(0.05, 1.5, 0.01) var bridge_probe_drop: float = 0.42
## How far a link end may be pulled vertically onto the navmesh before the link
## is thrown away instead. The navigation server only joins an end to a polygon
## within its own connection radius, so an end that is a metre out is an end that
## connects nothing.
@export_range(0.05, 3.0, 0.01) var snap_tolerance: float = 0.9
## Metres a discovered link's ends are pulled back from the navmesh border they
## were found on, onto the middle of the polygon behind them.
##
## Not cosmetic. The navigation server attaches a link by connecting its end to
## the closest polygon, and an end sitting exactly on a polygon BORDER — which is
## where the border-edge walk finds every one of them — lands on the seam between
## two polygons and inside the map's rasterisation of that seam. Pack a few
## hundred of those into a town and the server starts reporting "more than 2 edges
## tried to occupy the same map rasterization space", and links stop being
## traversable in whole neighbourhoods.
@export_range(0.0, 1.5, 0.01) var link_inset: float = 0.35
## Metres of grid the deduplication buckets link starts into. One link per bucket
## per kind per outward octant survives.
@export_range(0.5, 12.0, 0.1) var dedupe_cell: float = 3.0
## Hard ceiling on links of any one kind. Bake-time guard, not a runtime one.
@export_range(16, 8192, 16) var max_per_kind: int = 1600
## Ceiling the bake's budget search STARTS from, applied after the useless links
## are thinned out. Not the number that ships.
##
## There is a measured cliff here: a town navmesh of 29,942 polygons still paths
## correctly with several hundred off-mesh links installed and stops pathing
## through ANY of them past some ceiling, while `firefight` at 3,307 polygons
## carries well over a thousand. The ceiling is not a link count on its own, it is
## what that map's rasteriser will take — so `tools/bake_nav_links.gd` bisects for
## it per level rather than trusting this number, and this is only where the
## search begins. Set it above any level's honest ceiling and let the search
## find the truth; set it low and it is the search's answer instead.
@export_range(64, 8192, 32) var max_links: int = 1792
## How many links of one kind may join the same pair of walkable islands. Two is
## a way on and a way back; forty identical drops off one roof edge is the same
## information forty times, and it is what pushes a town past the ceiling above.
@export_range(1, 16, 1) var links_per_island_pair: int = 2
## Entry cost of a drop, a vault, a mantle and a jump, metres-equivalent.
@export_range(0.0, 100.0, 0.5) var ledge_enter_cost: float = 5.0


## Metres of clear air an agent that can fall `limit` metres is allowed to take,
## quantised to `DROP_TIERS`. Returns 0 when nothing is affordable.
static func drop_tier_bits(limit: float) -> int:
	var bits: int = 0
	for i: int in DROP_TIERS.size():
		if limit >= DROP_TIERS[i]:
			bits |= 1 << (LAYER_DROP_BASE + i)
	return bits


static func jump_tier_bits(limit: float) -> int:
	var bits: int = 0
	for i: int in JUMP_TIERS.size():
		if limit >= JUMP_TIERS[i]:
			bits |= 1 << (LAYER_JUMP_BASE + i)
	return bits


## The single bit a fall of `height` metres demands, or 0 when it is past the
## deepest tier and nothing may take it.
static func drop_bit_for(height: float) -> int:
	for i: int in DROP_TIERS.size():
		if height <= DROP_TIERS[i]:
			return 1 << (LAYER_DROP_BASE + i)
	return 0


static func jump_bit_for(span: float) -> int:
	for i: int in JUMP_TIERS.size():
		if span <= JUMP_TIERS[i]:
			return 1 << (LAYER_JUMP_BASE + i)
	return 0


static func kind_name(kind: int) -> String:
	match kind:
		Kind.LADDER:
			return "ladder"
		Kind.MANTLE:
			return "mantle"
		Kind.VAULT:
			return "vault"
		Kind.DROP:
			return "drop"
		_:
			return "jump"


## Every border edge of a navigation mesh, with the centroid of the polygon that
## owns it so the caller knows which way is out.
##
## Recast's detail pass re-emits boundary vertices per polygon, so raw indices
## never match across a shared edge — the weld on quantised position is what makes
## "used once" mean anything at all. Get this wrong and every edge looks like a
## border, which bakes a link off the middle of an open street.
##
## Returns `{"a": PackedVector3Array, "b": PackedVector3Array,
## "inside": PackedVector3Array}`, one entry per border edge.
static func border_edges(navmesh: NavigationMesh) -> Dictionary:
	var out_a := PackedVector3Array()
	var out_b := PackedVector3Array()
	var out_in := PackedVector3Array()
	var n: int = navmesh.get_polygon_count()
	if n == 0:
		return {"a": out_a, "b": out_b, "inside": out_in}
	var verts: PackedVector3Array = navmesh.get_vertices()
	var welded := PackedInt32Array()
	welded.resize(verts.size())
	var seen: Dictionary = {}
	for i: int in verts.size():
		var q := Vector3i(
			roundi(verts[i].x * 1000.0), roundi(verts[i].y * 1000.0), roundi(verts[i].z * 1000.0)
		)
		if not seen.has(q):
			seen[q] = i
		welded[i] = int(seen[q])

	var uses: Dictionary = {}
	for p: int in n:
		var poly: PackedInt32Array = navmesh.get_polygon(p)
		var m: int = poly.size()
		for e: int in m:
			var u: int = welded[poly[e]]
			var v: int = welded[poly[(e + 1) % m]]
			var key: int = mini(u, v) * 1000000 + maxi(u, v)
			uses[key] = int(uses.get(key, 0)) + 1

	for p: int in n:
		var poly: PackedInt32Array = navmesh.get_polygon(p)
		var m: int = poly.size()
		var centre := Vector3.ZERO
		for vi: int in poly:
			centre += verts[vi]
		centre /= float(m)
		for e: int in m:
			var i0: int = poly[e]
			var i1: int = poly[(e + 1) % m]
			var key: int = mini(welded[i0], welded[i1]) * 1000000 + maxi(welded[i0], welded[i1])
			if int(uses.get(key, 0)) != 1:
				continue
			out_a.push_back(verts[i0])
			out_b.push_back(verts[i1])
			out_in.push_back(centre)
	return {"a": out_a, "b": out_b, "inside": out_in}


## Connected-component label per navigation mesh polygon.
##
## Two polygons are in the same component when a body can walk from one to the
## other without leaving the mesh. This is what separates a link that MATTERS —
## the ladder that is the only way onto a roof — from a link that is a nicety, a
## kerb hop between two bits of the same street. On a level with more links than
## the navigation map will carry, that distinction is the difference between
## keeping the ladders and keeping the kerbs.
##
## Same weld-on-position as `border_edges`, for the same reason: Recast's detail
## pass re-emits boundary vertices per polygon, so raw indices never match.
static func polygon_components(navmesh: NavigationMesh) -> PackedInt32Array:
	var n: int = navmesh.get_polygon_count()
	var label := PackedInt32Array()
	label.resize(n)
	label.fill(-1)
	if n == 0:
		return label
	var verts: PackedVector3Array = navmesh.get_vertices()
	var welded := PackedInt32Array()
	welded.resize(verts.size())
	var seen: Dictionary = {}
	for i: int in verts.size():
		var q := Vector3i(
			roundi(verts[i].x * 1000.0), roundi(verts[i].y * 1000.0), roundi(verts[i].z * 1000.0)
		)
		if not seen.has(q):
			seen[q] = i
		welded[i] = int(seen[q])

	var neighbours: Array[PackedInt32Array] = []
	neighbours.resize(n)
	for i: int in n:
		neighbours[i] = PackedInt32Array()
	var owner_of: Dictionary = {}
	for p: int in n:
		var poly: PackedInt32Array = navmesh.get_polygon(p)
		var m: int = poly.size()
		for e: int in m:
			var u: int = welded[poly[e]]
			var v: int = welded[poly[(e + 1) % m]]
			var key: int = mini(u, v) * 1000000 + maxi(u, v)
			if owner_of.has(key):
				var q: int = int(owner_of[key])
				if q != p:
					neighbours[p].push_back(q)
					neighbours[q].push_back(p)
			else:
				owner_of[key] = p

	var next_label: int = 0
	var stack := PackedInt32Array()
	for seed: int in n:
		if label[seed] >= 0:
			continue
		stack.resize(0)
		stack.push_back(seed)
		label[seed] = next_label
		while not stack.is_empty():
			var cur: int = stack[stack.size() - 1]
			stack.remove_at(stack.size() - 1)
			for nb: int in neighbours[cur]:
				if label[nb] < 0:
					label[nb] = next_label
					stack.push_back(nb)
		next_label += 1
	return label


## Append one link. Returns its index, or -1 when the kind is already full.
func add(kind: int, from: Vector3, to: Vector3, layer_mask: int, both_ways: bool) -> int:
	if layer_mask == 0:
		return -1
	if count_of(kind) >= max_per_kind:
		return -1
	start_positions.push_back(from)
	end_positions.push_back(to)
	kinds.push_back(kind)
	flags.push_back(FLAG_BIDIRECTIONAL if both_ways else 0)
	layers.push_back(layer_mask)
	enter_costs.push_back(ladder_enter_cost if kind == Kind.LADDER else ledge_enter_cost)
	travel_costs.push_back(maxf(1.0, from.distance_to(to)))
	return kinds.size() - 1


## Drop every link but keep the rules. What the tool calls before a re-bake.
func clear_links() -> void:
	start_positions = PackedVector3Array()
	end_positions = PackedVector3Array()
	kinds = PackedByteArray()
	flags = PackedByteArray()
	layers = PackedInt32Array()
	enter_costs = PackedFloat32Array()
	travel_costs = PackedFloat32Array()


func size() -> int:
	return kinds.size()


func kind_at(i: int) -> int:
	return kinds[i]


func is_bidirectional(i: int) -> bool:
	return (flags[i] & FLAG_BIDIRECTIONAL) != 0


func count_of(kind: int) -> int:
	var n: int = 0
	for k: int in kinds:
		if k == kind:
			n += 1
	return n


## One line per kind, for a bake report.
func tally() -> String:
	var parts := PackedStringArray()
	for k: int in Kind.size():
		var c: int = count_of(k)
		if c > 0:
			parts.push_back("%d %s" % [c, kind_name(k)])
	return "none" if parts.is_empty() else ", ".join(parts)


## Build the `NavigationLink3D` nodes and hang them under `parent`, on `map` when
## one is given. Returns how many were made.
##
## The container is forced to the identity so the links' local start and end
## positions ARE world positions — a link inherits its parent's transform, and a
## parent that has been moved silently shifts every link in the set.
func instantiate_into(parent: Node, map: RID = RID()) -> int:
	if parent == null or size() == 0:
		return 0
	var container := Node3D.new()
	container.name = "AILinks"
	parent.add_child(container)
	container.transform = Transform3D.IDENTITY
	if container.is_inside_tree():
		container.global_transform = Transform3D.IDENTITY
	for i: int in size():
		var link := NavigationLink3D.new()
		link.name = "%s_%03d" % [kind_name(kinds[i]), i]
		container.add_child(link)
		if map.is_valid():
			link.set_navigation_map(map)
		link.start_position = start_positions[i]
		link.end_position = end_positions[i]
		link.bidirectional = is_bidirectional(i)
		link.navigation_layers = layers[i]
		link.enter_cost = enter_costs[i]
		link.travel_cost = travel_costs[i]
		link.set_meta(META_KIND, int(kinds[i]))
	return size()


## Bake one off-mesh link per ladder in a town layout.
##
## `WorldLayoutData` stores the foot as `(x, y0, z)` with a yaw whose local +Z
## points AWAY from whatever the ladder is bolted to — the same convention
## `PlayerLadder` uses. So the MOUNT is the foot pushed out along
## `(sin ry, cos ry)`: the agent stands in the street facing the rungs.
##
## THE DISMOUNT GOES THE OTHER WAY. The top rung sits about a metre above the
## parapet, and stepping outward from there steps into open air — you top out by
## going *over* the parapet, which is `-out`. Baking both ends outward was the
## first version of this and it produced 62 ladders in the town that connected
## nothing at all: every one of them ended in mid-air a metre off the roof, the
## navigation server joined neither end to a polygon, and the measured reachable
## roof area did not move by one square metre.
##
## `probe` is an optional `func(x: float, z: float, near_y: float) -> float`
## returning the walkable height there, or NAN. Given one, both sides of the
## parapet are tried and the one with real navmesh nearest the top rung wins,
## which handles the courtyard ladders that face inward.
##
## Returns how many were added.
func bake_ladders(
	layout: WorldLayoutData, probe: Callable = Callable(), xform: Transform3D = Transform3D.IDENTITY
) -> int:
	if layout == null:
		return 0
	var yaw_offset: float = xform.basis.get_euler(EULER_ORDER_YXZ).y
	var made: int = 0
	for i: int in layout.ladder_count():
		var foot: Vector3 = xform * layout.ladder_origin[i]
		var top: float = (xform * Vector3(0.0, layout.ladder_top[i], 0.0)).y
		if top - foot.y < ladder_min_height:
			continue
		var ry: float = layout.ladder_yaw[i] + yaw_offset
		var out := Vector3(sin(ry), 0.0, cos(ry))
		var mount: Vector3 = foot + out * ladder_stand_off + Vector3(0.0, ladder_foot_lift, 0.0)
		var deck: Vector3 = Vector3(foot.x, top, foot.z) - out * ladder_top_lead
		if probe.is_valid():
			mount = _walkable_near(foot, foot.y, out, ladder_stand_off, 1.0, probe)
			deck = _walkable_near(
				Vector3(foot.x, top, foot.z), top, out, ladder_top_lead, 0.0, probe
			)
			if is_nan(mount.y) or is_nan(deck.y):
				continue
		if add(Kind.LADDER, mount, deck, LAYER_CLIMB, true) >= 0:
			made += 1
	return made


## The nearest walkable point to `at` along `out`, swept from `start` metres to
## `ladder_deck_reach`, taking the height closest to `want_y`.
##
## `sides` picks the sweep: 1.0 for outward only — the foot of a ladder is always
## in the street it is bolted over — and 0.0 for both, because a roof deck can be
## on either side of the rungs and the courtyard ladders face inward.
##
## Sweeping matters more than it looks. The navmesh is eroded by an agent radius
## from every wall, so walkable roof does not begin at the parapet; it begins
## about a metre inside it. A single fixed lead of three quarters of a metre lands
## in the carved-out strip and finds nothing, and the fallback then snapped the
## ladder's top back down into the street. Measured: 46 town ladders baked, 41 the
## server would path, and not one of them reached a roof.
##
## Returns a point with a NAN height when nothing walkable is within tolerance.
func _walkable_near(
	at: Vector3, want_y: float, out: Vector3, start: float, sides: float, probe: Callable
) -> Vector3:
	var best := Vector3(at.x, NAN, at.z)
	var best_gap: float = ladder_deck_tolerance
	var signs: Array = [1.0] if sides > 0.0 else [-1.0, 1.0]
	for sign_of: float in signs:
		var d: float = start
		while d <= ladder_deck_reach:
			var p: Vector3 = at + out * (d * sign_of)
			d += ladder_deck_step
			var y: float = probe.call(p.x, p.z, want_y)
			if is_nan(y):
				continue
			var gap: float = absf(y - want_y)
			if gap < best_gap:
				best_gap = gap
				best = Vector3(p.x, y, p.z)
	return best
