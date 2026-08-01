extends RefCounted
## The firefight's vertical structure: six raised decks with parapets and walk-up
## ramps, and the three ramps that reach the shack roof inside each compound.
##
## BAKE-TIME ONLY. `tools/build_firefight.gd` is the only caller. Nothing here
## touches the tree; every routine returns a list of SOLIDS in the shape
## `[centre, ex, ey, ez, colour, surface]` — three half-extent vectors forming a
## right-handed frame, exactly what `WorldMesher.oriented_box` takes — and the
## builder emits them into the same mesh and the same collider list as the
## ground, so a deck you can see and a deck you can stand on are one box or
## neither exists.
##
## WHY THIS EXISTS AT ALL. Measured before it did: `aloft 0/98` over a full 120 s
## run of the demo, `reach a roof: with links 0/240 (0%)` over 1,510 baked links,
## and a vantage set of 44 points EVERY ONE OF WHICH sat at y = 0.50. The
## traversal layer, the vantage bake and the cover map all worked; the level gave
## them nothing to work with. 97.6 per cent of this arena's 82,723 m2 of
## navigation mesh was one flat pan, and the only thing standing over it was the
## rim wall at 6.4 m, which nothing in the roster can climb.
##
## THE ACCESS IS A WALKABLE RAMP, NOT A LADDER, AND THAT IS THE WHOLE TRICK.
## Three separate things in this project only accept a roof the navigation mesh
## itself reaches:
##   * `AIVantage.bake` gates every candidate on a real `map_get_path`, and the
##     map it is handed at bake time has NO off-mesh links on it — see
##     `build_firefight.gd::_bake_cover` — so a deck reachable only by a ladder
##     link bakes zero vantage points and no marksman ever hears about it.
##   * `AICoverSampler` samples whatever the navigation map answers with, so a
##     parapet only becomes cover once its deck is navigable.
##   * The A* budget (`AIPathService.path_search_polygons`, 4,096) is spent per
##     query; a corridor that walks up is cheaper than one that has to find a
##     link and enter it.
## A ramp under `agent_max_slope` costs one box, one collider and no link at all.

## The zone table, for the one thing this file needs from it: where the flagpoles
## and the fly-to posts stand, so no deck is packed on top of one.
const Zones := preload("res://tools/firefight/firefight_zones.gd")
## Metres of daylight a fixture is given. A mast is a few centimetres thick; the
## flag on top of it is not, and it flies at 5.2 m, which is deck height.
const FIXTURE_CLEAR: float = 2.0

## Degrees of pitch on every access ramp. Recast's `agent_max_slope` is 46 and its
## rasteriser quantises a slope into `cell_height` steps, so anything under about
## 45 degrees walks.
##
## 36 WAS TRIED AND IT DOES NOT WORK, WHICH IS NOT WHAT THE SLOPE LIMIT PREDICTS.
## Baked at 36 degrees, with every other number the same, NOT ONE of the six decks
## was joined to the ground — `map_get_path` from the middle of the pan stopped
## ten metres short of each of them, which is the foot of the ramp. 34 works, 28
## works. Whatever the rasteriser is doing between 34 and 36 it is not the slope
## test, and the lesson is that this number is measured with
## `NavigationServer3D.map_get_path` and not reasoned about from
## `agent_max_slope`.
##
## 28 also happens to be the one that bakes the most overwatch: 31 of 56 vantage
## points elevated, against 25 of 52 at 34 degrees with the decks 0.8 m lower.
const RAMP_DEGREES: float = 28.0
## Width of an access ramp, in metres. Recast erodes `agent_radius` (0.62 m) off
## each side and `filter_ledge_spans` takes another cell, so 4.0 m of slab is
## about 2.2 m of walkable corridor — two bodies abreast, and wide enough that a
## squad does not queue at the foot of it.
const RAMP_WIDTH: float = 4.6
const RAMP_THICKNESS: float = 0.55
## How far a ramp head is driven INTO the deck it lands on.
##
## Butting the head against the deck edge leaves two faces on the same plane. The
## head is buried by this much instead, and the slab is NOT dropped to split the
## rise across the join: the walkable face passes exactly through the deck rim at
## exactly deck height, so the step at the rim is zero and the only lip is the
## `RAMP_BITE * tan(RAMP_DEGREES)` = 0.21 m the head rises INSIDE the deck, where
## the deck is solid underneath it.
##
## It used to split the rise, and half a voxel either side of the rim turned out
## to be the difference between a deck the navigation mesh joins and one it does
## not — measured, three of six decks were unreachable on an otherwise identical
## bake, decided by where the 0.25 m grid happened to fall.
const RAMP_BITE: float = 0.4
## How far under the pan a ramp buries its foot, so the slope grows out of the
## ground rather than resting on it and there is no seam to see.
const RAMP_SINK: float = 0.4

## Parapet: how far in from the deck edge it stands, how thick, how tall.
##
## 0.95 m is chosen against the cover sampler rather than by eye. That pass probes
## at 0.55 m and at 1.50 m; a wall between those two blocks the low ray and passes
## the high one, which is exactly the `peek` term in
## `AICoverSampler._probe_point` that scores a point as a FIRING position rather
## than as a hole to hide in.
const PARAPET_INSET: float = 0.30
const PARAPET_THICK: float = 0.36
const PARAPET_HEIGHT: float = 0.95
## Metres of embrasure left in the middle of each parapet run.
const PARAPET_GAP: float = 2.2

## Every raised post: id, radius, bearing in degrees, deck half-extent, deck
## height, and the bearings its ramps leave on RELATIVE to its own — 0 is straight
## out from the middle of the arena, 180 straight in, ±90 along the ring.
##
## THE BEARINGS ARE THE TACTICS. `FirefightDirector` deploys each faction over a
## 100-degree arc centred on its own home bearing — Scav 40..140, Foundry
## 160..260, Choir 280..20 — so 30, 150 and 270 degrees are the three SEAMS where
## two factions' opening lines touch. The pan ring stands on those seams at 21 m,
## which puts its near edge 13 m from the objective and inside the 14 m
## `FirefightAgent.COVER_SEARCH` scans. The zone ring stands beside the three
## NEUTRAL anchors, turned 18 degrees off each zone's own bearing — the flagpoles
## are offset in world +Z rather than radially, so a post on the bearing sits on
## one of them, and `clearance()` refuses that bake.
##
## THE THREE HOME ZONES GET NO POST. They already have a roof: the compound kit's
## own shack deck at 3.70 m, which `compound_stairs` now reaches.
##
## TWO RAMPS EACH, and that is not decoration. A body only ever climbs the one it
## happens to be near, so a second one halves the walk for whoever approaches from
## the other side, and it costs one box.
const RING: Array = [
	["pan_east", 21.0, 30.0, 7.5, 5.4, [0.0, 90.0]],
	["pan_west", 21.0, 150.0, 7.5, 5.4, [0.0, 90.0]],
	["pan_north", 21.0, 270.0, 7.5, 5.4, [0.0, 90.0]],
	["farm_post", 42.0, 48.0, 7.5, 5.4, [-90.0, 0.0]],
	["bank_post", 42.0, 176.0, 7.5, 5.4, [-90.0, 0.0]],
	["road_post", 42.0, 288.0, 7.5, 5.4, [-90.0, 0.0]],
]
## Metres of ground a post claims beyond its own deck. Berms and clutter are kept
## out of it so nothing grows through a ramp.
const CLEAR: float = 5.0
## Plinth: how far it stands proud of the pan and how far past the block it
## reaches.
##
## 1.4 m is deliberately between two thresholds. It is well over `agent_max_climb`
## (0.5 m, see `tune_navmesh`) so nothing walks onto it, and its 0.65 m shoulder is
## well under the 1.5 m the erosion pass needs before it will leave a walkable
## strip — so it breaks the silhouette of a six-metre block without opening a
## navigation island nothing can reach.
const PLINTH_SHOULDER: float = 0.65
const PLINTH_TOP: float = 1.4


## Where every post stands and which way it is climbed.
##
## Draws no random numbers, deliberately. The berm and clutter streams have to
## come out of the builder's rng in the order they always did or the whole arena
## re-rolls, and a keep-out list that costs nothing to compute up front is the
## cheapest way to have one without touching that order.
##
## The ramp bearings in `RING` are hand-packed and `clearance()` is what proves
## the packing, not this comment: nine blocks and eighteen ramps on three rings
## have plenty of ways to end up inside each other, and the bake FAILS when they
## do rather than shipping a ramp Recast stops rasterising halfway along.
static func plan() -> Array:
	var out: Array = []
	for spec: Array in RING:
		var bearing: float = deg_to_rad(float(spec[2]))
		var outward := Vector3(sin(bearing), 0.0, cos(bearing))
		var ramps: Array[Vector3] = []
		for offset: float in spec[5]:
			var a: float = bearing + deg_to_rad(offset)
			ramps.push_back(Vector3(sin(a), 0.0, cos(a)))
		(
			out
			. push_back(
				{
					"id": String(spec[0]),
					"pos": outward * float(spec[1]),
					"yaw": bearing,
					"half": float(spec[3]),
					"deck": float(spec[4]),
					"ramps": ramps,
				}
			)
		)
	return out


## Discs no berm and no prop may be placed in: the deck itself, and the length of
## every ramp off it.
static func keepout(posts: Array) -> Array:
	var out: Array = []
	for post: Dictionary in posts:
		var half: float = post["half"]
		var pos: Vector3 = post["pos"]
		out.push_back([pos, half + CLEAR])
		var run: float = ramp_run(post["deck"])
		for dir: Vector3 in post["ramps"]:
			for k: int in 3:
				var t: float = (float(k) + 0.5) / 3.0
				out.push_back([pos + dir * (half + run * t), RAMP_WIDTH * 0.75])
	return out


## Horizontal run of a ramp that climbs `rise` metres and buries its foot.
static func ramp_run(rise: float) -> float:
	var t: float = tan(deg_to_rad(RAMP_DEGREES))
	return (rise + RAMP_BITE * t * 0.5 + RAMP_SINK) / t


## Roughly how much walkable deck the posts add, once Recast has eroded
## `agent_radius` plus a ledge cell off every edge and the parapet has taken its
## own inset. Reported so the roof-goal counts in the link bake can be read
## against something.
static func deck_area(posts: Array) -> float:
	var total: float = 0.0
	for post: Dictionary in posts:
		var edge: float = PARAPET_INSET + PARAPET_THICK + 0.75
		var w: float = maxf(float(post["half"]) * 2.0 - edge * 2.0, 0.0)
		total += w * w
	return total


# ---------------------------------------------------------------------- solids


## Every solid the nine posts are made of: a plinth, a block, eight parapet runs
## and one ramp apiece.
##
## All of it lands in the SAME `ArrayMesh` surface the ground and the rim already
## share, so the whole set costs the frame no draw call at all. That is why this
## is built out of `WorldMesher` boxes here and not out of instanced kit scenes.
static func solids(posts: Array) -> Array:
	var out: Array = []
	for post: Dictionary in posts:
		var pos: Vector3 = post["pos"]
		var yaw: float = post["yaw"]
		var half: float = post["half"]
		var deck: float = post["deck"]
		var ramps: Array = post["ramps"]
		out.push_back(
			_upright(
				pos + Vector3.UP * ((PLINTH_TOP - 1.6) * 0.5),
				Vector3(half + PLINTH_SHOULDER, (PLINTH_TOP + 1.6) * 0.5, half + PLINTH_SHOULDER),
				yaw,
				Palette.WORLD_ROCK[1],
				WorldSurface.Kind.ROCK
			)
		)
		out.push_back(
			_upright(
				pos + Vector3.UP * ((deck - 0.8) * 0.5),
				Vector3(half, (deck + 0.8) * 0.5, half),
				yaw,
				Palette.WORLD_CONCRETE[0],
				WorldSurface.Kind.CONCRETE
			)
		)
		out.append_array(_parapet(pos, yaw, half, deck, ramps))
		for dir: Vector3 in ramps:
			out.push_back(
				ramp(
					pos + dir * half + Vector3.UP * deck,
					dir,
					RAMP_WIDTH,
					RAMP_THICKNESS,
					Palette.WORLD_CONCRETE[2],
					WorldSurface.Kind.CONCRETE
				)
			)
	return out


## One pitched slab a body walks up.
##
## `edge` is the point on the deck's rim the ramp lands on and `out_dir` the
## horizontal direction it descends in. The slab is defined by its TOP FACE — the
## surface Recast will rasterise — and the box is then dropped half its thickness
## along its own normal, which is the only way the walkable plane ends up where
## this function says it does.
static func ramp(
	edge: Vector3,
	out_dir: Vector3,
	width: float,
	thick: float,
	col: Color,
	surface: int,
	degrees: float = RAMP_DEGREES
) -> Array:
	var t: float = tan(deg_to_rad(degrees))
	var lift: float = RAMP_BITE * t
	var head: Vector3 = edge - out_dir * RAMP_BITE + Vector3.UP * lift
	var drop: float = edge.y + RAMP_SINK
	var foot: Vector3 = edge - Vector3.UP * drop + out_dir * (drop / t)
	return _pitched(head, foot, width, thick, col, surface)


## A slab from `head` down to `foot`, both given on the walkable face.
##
## `dir.cross(UP)`, in that order, is the flank that makes `ex x ey = +ez`, which
## is what `oriented_box` requires. The other order builds the slab inside out and
## nothing downstream notices until the frame is on screen.
static func _pitched(
	head: Vector3, foot: Vector3, width: float, thick: float, col: Color, surface: int
) -> Array:
	var run: Vector3 = foot - head
	var dir: Vector3 = run.normalized()
	var flank: Vector3 = dir.cross(Vector3.UP).normalized()
	var normal: Vector3 = flank.cross(dir)
	return [
		(head + foot) * 0.5 - normal * (thick * 0.5),
		dir * (run.length() * 0.5),
		normal * (thick * 0.5),
		flank * (width * 0.5),
		col,
		surface,
	]


## A yaw-only box, in the same shape as everything else here.
static func _upright(centre: Vector3, half: Vector3, yaw: float, col: Color, surface: int) -> Array:
	return [
		centre,
		Vector3(cos(yaw), 0.0, -sin(yaw)) * half.x,
		Vector3(0.0, half.y, 0.0),
		Vector3(sin(yaw), 0.0, cos(yaw)) * half.z,
		col,
		surface,
	]


## A parapet round a deck: two runs per side with an embrasure between them, and
## a wide opening on whichever side the ramp arrives at.
##
## Every run reaches the full half-extent so the four corners OVERLAP rather than
## butt. A corner where two walls meet on the same plane is the one join in this
## arena that would z-fight, and it is free to avoid.
static func _parapet(pos: Vector3, yaw: float, half: float, deck: float, ramps: Array) -> Array:
	var out: Array = []
	var span: float = half - PARAPET_INSET
	var stand: float = half - PARAPET_INSET - PARAPET_THICK * 0.5
	var cy: float = deck + PARAPET_HEIGHT * 0.5 - 0.25
	var hy: float = (PARAPET_HEIGHT + 0.5) * 0.5
	var faces: Array[Vector3] = [
		Vector3(sin(yaw), 0.0, cos(yaw)),
		Vector3(-sin(yaw), 0.0, -cos(yaw)),
		Vector3(cos(yaw), 0.0, -sin(yaw)),
		Vector3(-cos(yaw), 0.0, sin(yaw)),
	]
	for k: int in faces.size():
		var face: Vector3 = faces[k]
		var along := Vector3(face.z, 0.0, -face.x)
		var gap: float = PARAPET_GAP
		for dir: Vector3 in ramps:
			if face.dot(dir) > 0.9:
				gap = RAMP_WIDTH + 1.6
		if gap >= span * 2.0:
			continue
		var seg: float = (span - gap * 0.5) * 0.5
		var off: float = (span + gap * 0.5) * 0.5
		var extents := Vector3(seg, hy, PARAPET_THICK * 0.5)
		if k >= 2:
			extents = Vector3(PARAPET_THICK * 0.5, hy, seg)
		for sg: float in [-1.0, 1.0]:
			out.push_back(
				_upright(
					pos + face * stand + along * (off * sg) + Vector3.UP * cy,
					extents,
					yaw,
					Palette.WORLD_CONCRETE[(k + 1) % Palette.WORLD_CONCRETE.size()],
					WorldSurface.Kind.CONCRETE
				)
			)
	return out


# ------------------------------------------------------------ compound access


## Access to the shack roof inside each compound.
##
## The compound kit is SHARED with `build_town.gd` and is not edited here. What it
## already has is a flat roof deck at 3.70 m with a 0.94 m parapet round it —
## measured, and Recast already walks it, at 78 m2 over the three homes. What it
## does not have is any way up: the adobe's internal flight is 0.48 m wide and no
## body in the roster fits through it.
##
## So the access is bolted on from outside, in the arena's own geometry: a ramp up
## the flank of the shack, a landing slab laid ACROSS the parapet coping, and a
## short ramp down onto the deck behind it. Three boxes per home, nothing in the
## kit touched.
static func compound_stairs(roof: Array, homes: Array[Transform3D]) -> Array:
	var out: Array = []
	if roof.is_empty():
		return out
	var local_pos: Vector3 = roof[0]
	var local_half: Vector3 = roof[1]
	var basis: Basis = roof[2]
	var top: float = local_pos.y + local_half.y
	var chosen: Vector3 = Vector3.ZERO
	var reach: float = 0.0
	var best_room: float = -INF
	# Four candidate landings, one per edge of the deck. The one with the most
	# clear yard behind it wins, because the ramp needs its whole run of it and the
	# compound wall is only 12 m out.
	for axis: int in 4:
		var along_z: bool = axis < 2
		var n: Vector3 = basis.z.normalized() if along_z else basis.x.normalized()
		if axis % 2 == 1:
			n = -n
		var half_here: float = local_half.z if along_z else local_half.x
		var edge: Vector3 = local_pos + n * half_here
		var room: float = minf(12.0 - absf(edge.x), 12.0 - absf(edge.z))
		if room > best_room:
			best_room = room
			chosen = n
			reach = half_here
	var lip_y: float = top + 1.06
	# The pitch is SOLVED against the yard, not chosen. The compound is 24 m across
	# with an 8 m shack near the middle of it, so a flight off the roof has about
	# nine metres of yard to land in; at the 28 degrees the open arena uses it would
	# need eleven and would come through the perimeter wall two metres up, which is
	# a ramp Recast simply stops rasterising halfway along. Steeper is fine — Recast
	# walks anything under `agent_max_slope` (46) and this is capped well inside it.
	var room: float = maxf(best_room - 2.4, 3.0)
	var pitch: float = clampf(rad_to_deg(atan(lip_y / room)), RAMP_DEGREES, 40.0)
	for home: Transform3D in homes:
		var n: Vector3 = home.basis * chosen
		n.y = 0.0
		n = n.normalized()
		var edge: Vector3 = home * (local_pos + chosen * reach)
		var lip := Vector3(edge.x, lip_y, edge.z)
		# The landing straddles the coping: half of it hangs outside the shack, half
		# sits over the deck, and its top clears the 4.64 m parapet by 8 cm.
		out.push_back(
			_upright(
				Vector3(edge.x, lip_y - 0.45, edge.z),
				Vector3(1.7, 0.45, 1.3),
				atan2(n.x, n.z),
				Palette.WORLD_WOOD[1],
				WorldSurface.Kind.WOOD
			)
		)
		out.push_back(
			ramp(lip + n * 1.3, n, 3.0, 0.5, Palette.WORLD_WOOD[0], WorldSurface.Kind.WOOD, pitch)
		)
		out.push_back(_step_down(lip - n * 1.3, -n, top, 2.6))
	return out


## A short ramp DOWN from `from_point` onto a deck at `to_y`. Same construction as
## `ramp`, but the run is fixed by the two heights rather than by burying a foot.
static func _step_down(from_point: Vector3, dir_flat: Vector3, to_y: float, width: float) -> Array:
	var t: float = tan(deg_to_rad(24.0))
	var fall: float = maxf(from_point.y - to_y, 0.1)
	var head: Vector3 = from_point + dir_flat * (fall / t) - Vector3.UP * fall
	return _pitched(from_point, head, width, 0.4, Palette.WORLD_WOOD[2], WorldSurface.Kind.WOOD)


## The compound kit's roof deck, in kit-local space, as `[centre, half, basis]`.
##
## FOUND RATHER THAN HARD-CODED. The shack inside the compound is placed and
## turned by the kit's own rng, so its roof is not on an axis anybody can write
## down, and a number copied out of a scene file today is a ramp into a wall the
## next time `build_town.gd` runs.
static func kit_roof(compound: PackedScene) -> Array:
	var kit := compound.instantiate() as Node3D
	var best: Array = []
	var best_area: float = 0.0
	var stack: Array[Array] = [[kit, Transform3D.IDENTITY]]
	while not stack.is_empty():
		var entry: Array = stack.pop_back()
		var node: Node = entry[0]
		var here: Transform3D = entry[1]
		var n3 := node as Node3D
		if n3 != null:
			here = here * n3.transform
		var cs := node as CollisionShape3D
		if cs != null:
			var box := cs.shape as BoxShape3D
			if box != null and not cs.disabled:
				var half: Vector3 = box.size * 0.5
				var top: float = here.origin.y + half.y
				var area: float = half.x * half.z * 4.0
				if half.y <= 0.4 and top > 2.5 and top < 6.0 and area > best_area:
					best_area = area
					best = [here.origin, half, here.basis]
		for child: Node in node.get_children():
			stack.push_back([child, here])
	kit.free()
	return best


# ------------------------------------------------------------------- self-test


## Whether a ridge of half-length `reach` centred on `c` and turned to `yaw`
## touches any keep-out disc. Sampled along the ridge rather than tested as a box:
## five points over a rubble bank is finer than the discs it is tested against,
## and this runs twenty-one times in the whole bake.
static func crosses(discs: Array, c: Vector3, yaw: float, reach: float) -> bool:
	var along := Vector3(cos(yaw), 0.0, -sin(yaw))
	for k: int in 5:
		var t: float = (float(k) / 4.0 - 0.5) * 2.0
		if inside(discs, c + along * (reach * t)):
			return true
	return false


static func inside(discs: Array, p: Vector3) -> bool:
	for entry: Array in discs:
		var c: Vector3 = entry[0]
		var r: float = entry[1]
		if Vector2(p.x - c.x, p.z - c.z).length_squared() < r * r:
			return true
	return false


## Smallest gap between one post's solid and another's — or between any of them
## and a fixture that must stay clear — in metres. Negative fails the bake.
##
## `keep_clear` is `[[centre, radius], ...]`: the flagpoles, the fly-to posts and
## the gantry. This is not belt and braces. The first packing of the zone ring put
## a 13 m block straight through the CUT BANK banner, which is a five-metre
## flagpole buried inside a solid, and nothing else in the bake would have said a
## word about it — the fixtures are added to the scene long after the arena mesh
## is closed, so no solidity or winding check can see the collision.
##
## Every footprint is yaw-only, so four separating axes are exact for a pair of
## blocks; the ramps are sampled along their centre line against the same test.
## Recast settings this level's ramps need, applied to the navmesh before it is
## baked.
##
## `agent_max_climb` DECIDES WHETHER A RAMP IS A RAMP. Godot turns it into voxels
## with `floor(agent_max_climb / cell_height)`, and at the 0.45 m the kit ships
## with, over a 0.25 m cell, that is ONE voxel — so every join on a slope sits
## exactly on the limit `rcFilterLedgeSpans` compares against, and whether a deck
## is joined to the ground comes down to where the grid fell. Measured on an
## otherwise identical bake: three of six decks reachable, three not, with the same
## ramp on all six.
##
## 0.5 m is two voxels and doubles that margin. Nothing else in the level moves:
## the gantry deck is 1.2 m and stays unwalkable by design, the zone aprons are
## 0.12 m and were always walkable, and the plinths are 1.4 m.
static func tune_navmesh(navmesh: NavigationMesh) -> void:
	navmesh.agent_max_climb = 0.5


## Every fixture the posts must stay off: the seven banner masts and the seven
## fly-to posts, in the same `[centre, radius]` shape `clearance` takes. Derived
## from the zone table rather than copied out of it, so moving a zone moves this.
static func fixture_keepouts() -> Array:
	var out: Array = []
	for i: int in Zones.ZONES.size():
		var c: Vector3 = Zones.center(i)
		out.push_back([c + Vector3(0.0, 0.0, 4.6), FIXTURE_CLEAR])
		var outward: Vector3 = c.normalized() if c.length_squared() > 1.0 else Vector3.BACK
		out.push_back([c + outward * (Zones.ZONE_RADIUS + 5.0), FIXTURE_CLEAR])
		# And the compound itself, on the three home zones: a 24 m square kit, taken
		# at its circumscribed radius because it is turned to face the middle and this
		# is a guard rail rather than a fit.
		if int(Zones.ZONES[i][2]) >= 0:
			out.push_back([c, 17.0])
	# The spectator gantry. Nothing at war can reach it and nothing should be built
	# on it either.
	out.push_back([Vector3(0.0, 0.0, 74.0), 12.0])
	return out


static func clearance(posts: Array, keep_clear: Array = []) -> float:
	var best: float = INF
	for post: Dictionary in posts:
		for entry: Array in keep_clear:
			var c: Vector3 = entry[0]
			var r: float = entry[1]
			best = minf(best, _point_gap(c, post) - r)
			for p: Vector3 in _ramp_line(post):
				best = minf(best, Vector2(p.x - c.x, p.z - c.z).length() - r - RAMP_WIDTH * 0.5)
	for i: int in posts.size():
		var a: Dictionary = posts[i]
		for j: int in posts.size():
			if i == j:
				continue
			var b: Dictionary = posts[j]
			if j > i:
				best = minf(best, _block_gap(a, b))
			for p: Vector3 in _ramp_line(a):
				best = minf(best, _point_gap(p, b) - RAMP_WIDTH * 0.5)
				# Two ramp feet on the same patch of ground is the other way this
				# packing goes wrong, and it does not show up against the blocks.
				if j > i:
					for q: Vector3 in _ramp_line(b):
						best = minf(best, p.distance_to(q) - RAMP_WIDTH)
	return 0.0 if is_inf(best) else best


## Points along every ramp's centre line, from the deck edge to the foot.
static func _ramp_line(post: Dictionary) -> PackedVector3Array:
	var out := PackedVector3Array()
	var run: float = ramp_run(post["deck"])
	for dir: Vector3 in post["ramps"]:
		for k: int in 8:
			var t: float = float(post["half"]) + run * (float(k) + 0.5) / 8.0
			out.push_back((post["pos"] as Vector3) + dir * t)
	return out


static func _block_gap(a: Dictionary, b: Dictionary) -> float:
	var gap: float = -INF
	for pair: Array in [[a, b], [b, a]]:
		var near: Dictionary = pair[0]
		var far: Dictionary = pair[1]
		var d: Vector3 = (far["pos"] as Vector3) - (near["pos"] as Vector3)
		var span: float = float(near["half"]) + PLINTH_SHOULDER
		var far_half: float = float(far["half"]) + PLINTH_SHOULDER
		for axis: Vector3 in _axes(near["yaw"]):
			# The far square's radius ON THIS AXIS, not its diagonal. Using the
			# diagonal is the easy mistake and it reads two blocks on the SAME bearing
			# — which the pan ring and the zone ring are, by design — as overlapping
			# by a metre when they are two metres apart.
			var reach: float = 0.0
			for far_axis: Vector3 in _axes(far["yaw"]):
				reach += absf(axis.dot(far_axis)) * far_half
			gap = maxf(gap, absf(d.dot(axis)) - span - reach)
	return gap


static func _axes(yaw: float) -> Array[Vector3]:
	return [Vector3(cos(yaw), 0.0, -sin(yaw)), Vector3(sin(yaw), 0.0, cos(yaw))]


## How far a point lies outside a post's block footprint.
static func _point_gap(p: Vector3, post: Dictionary) -> float:
	var yaw: float = post["yaw"]
	var h: float = float(post["half"]) + PLINTH_SHOULDER
	var d: Vector3 = p - (post["pos"] as Vector3)
	var dx: float = absf(d.dot(Vector3(cos(yaw), 0.0, -sin(yaw)))) - h
	var dz: float = absf(d.dot(Vector3(sin(yaw), 0.0, cos(yaw)))) - h
	if dx <= 0.0 and dz <= 0.0:
		return maxf(dx, dz)
	return Vector2(maxf(dx, 0.0), maxf(dz, 0.0)).length()
