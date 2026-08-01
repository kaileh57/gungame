@tool
extends SceneTree
## Firefight bake: an arena, a navmesh, a cover set, a roster and the scene that
## puts all four in the same room.
##
## Produces
##   res://demos/firefight/firefight_arena.res     ground, berms and rim wall
##   res://demos/firefight/firefight_fixtures.res  posts, masts, flags, the dial
##   res://demos/firefight/firefight_profiles.tres the twelve species as AI
##   res://demos/firefight/firefight_nav.res       the baked navigation mesh
##   res://demos/firefight/firefight_cover.tres    every place worth standing
##   res://demos/firefight/firefight.tscn          the assembled demo
##   res://demos/firefight/firefight_report.txt    the self-test output
##
## Run headless:
##   godot --headless --path <project> --script res://tools/build_firefight.gd
##
## Depends on `res://data/enemies/*.res` (build_enemies.gd), the world prop set
## (build_props.gd) and `res://data/world/kits/compound.tscn` (build_town.gd).
## All three are already baked; this reads them and never rebuilds them.
##
## WHY THE ARENA IS ONE PILE OF BOXES. Every solid here is a `WorldMesher.box`,
## and every one of them is sunk into whatever it stands on rather than butted
## against it. That is the only way to guarantee no seam, no z-fight and no gap
## at a join, and the self-test at the bottom proves it: the whole soup is
## checked for boundary edges, inverted shells and degenerate triangles, and the
## bake refuses to write a scene that fails.
##
## The physics colliders are generated FROM THE SAME BOX LIST as the mesh, in the
## same loop, so a wall you can see and a wall you can walk through cannot drift
## apart the way they do when the two are authored separately.

const MmBake := preload("res://tools/mm_bake.gd")

## The bake, split five ways. The arena and its assembly stay here; these own the
## parts that have their own vocabulary.
const Cover := preload("res://tools/firefight/firefight_cover.gd")
const Fixtures := preload("res://tools/firefight/firefight_fixtures.gd")
const Nav := preload("res://tools/firefight/firefight_nav.gd")
const Posts := preload("res://tools/firefight/firefight_posts.gd")
const Zones := preload("res://tools/firefight/firefight_zones.gd")

const OUT_DIR: String = "res://demos/firefight"
const ARENA_MESH_PATH: String = "res://demos/firefight/firefight_arena.res"
const FIXTURE_MESH_PATH: String = "res://demos/firefight/firefight_fixtures.res"
const PROFILES_PATH: String = "res://demos/firefight/firefight_profiles.tres"
const NAV_PATH: String = "res://demos/firefight/firefight_nav.res"
const COVER_PATH: String = "res://demos/firefight/firefight_cover.tres"
const SCENE_PATH: String = "res://demos/firefight/firefight.tscn"
const REPORT_PATH: String = "res://demos/firefight/firefight_report.txt"

const WORLD_SCENE: String = "res://art/scav_world.tscn"
const VFX_SCENE: String = "res://data/vfx/vfx.tscn"
const FREECAM_SCENE: String = "res://data/player/freecam.tscn"
const COMPOUND_KIT: String = "res://data/world/kits/compound.tscn"
const PROP_SET: String = "res://data/world/props/props.tres"
const ENEMY_DIR: String = "res://data/enemies"
const WORLD_MATERIAL: String = "res://art/materials/world_surface.tres"
const STEEL_MATERIAL: String = "res://art/materials/scrap_steel.tres"
const PERCEPTION_TUNING: String = "res://data/ai/perception_tuning.tres"
const ROLE_DOCTRINE: String = "res://data/ai/role_doctrine.tres"

## Scripts attached by path rather than named by `class_name`.
##
## A script handed to `--script` is compiled before any autoload exists, and
## naming a global class drags that class INTO that compile. Every script below
## reaches an autoload somewhere down its dependency chain — `Factions` for the
## director and the zones, `GameSettings` for the spawner, `SceneRouter` and
## `DebugHUD` for the demo root — so naming any one of them here fails the whole
## bake with "Identifier not found: Factions" before `_initialize` is reached.
## Loading them at run time, once the tree is up, resolves cleanly. This is the
## same reason `res://tools/build_arena.gd` loads its spawner by path.
const SCRIPT_DEMO: String = "res://demos/firefight/firefight.gd"
const SCRIPT_DIRECTOR: String = "res://demos/firefight/firefight_director.gd"
const SCRIPT_GUNFIRE: String = "res://demos/firefight/firefight_gunfire.gd"
const SCRIPT_SPECTATOR: String = "res://demos/firefight/firefight_spectator.gd"
const SCRIPT_ROSTER: String = "res://demos/firefight/firefight_roster.gd"
const SCRIPT_SCHEDULER: String = "res://systems/ai/ai_tick_scheduler.gd"
const SCRIPT_PATHS: String = "res://systems/ai/ai_path_service.gd"
const SCRIPT_SPAWNER: String = "res://systems/enemies/enemy_spawner.gd"

## `Factions.NAMES`, spelled out for the same reason. The order is the enum's.
const FACTION_NAMES: PackedStringArray = ["SCAV", "FOUNDRY", "CHOIR"]
const FACTION_COUNT: int = 3

## Half-width of the ground slab. The rim wall stands well inside it so the
## camera never sees the edge of the world from anywhere it can reach.
const GROUND_HALF: float = 150.0
## Radius of the rim wall, and so of the playable arena.
##
## Sized against the speed a body actually moves at rather than the speed its
## profile advertises. Measured on the baked rigs, a creature crosses ground at its
## WALK stride and nothing gets it above that (see the gait note in
## `firefight_agent.gd`), so a 48 m hop from a capital to the nearest neutral ground
## is about thirty-five seconds of advance. On the 66 m ring this was built at
## first, the same hop was a minute, and the map spent most of a six-minute run
## with nobody standing on anything.
const ARENA_RADIUS: float = 88.0
const SEED: int = 0x5CA71E

## Where the spectator opens: an overlook of the contested centre, off to one
## side of the axis the tracking mast stands on.
##
## THIS USED TO BE (-6, 14, 34) AND IT SHOWED TWO OF THE THREE FACTIONS. Thirty-
## four metres out is INSIDE the front, so the arc of whichever faction deployed
## toward the camera fell off the bottom of the frame, and `choir_house` at
## (-24, 0, 41.6) stood behind the eye. Counted by projecting every living body
## through the camera: at 14 s the old view held 13/21 Scav, 21/22 Foundry, 5/15
## Choir; at 150 s, once the war had spread off the objective, 3/21, 14/22 and
## 1/21. That is the whole of "i only see 2 factions".
##
## SIXTY-SEVEN METRES out is thirty-one OUTSIDE the front instead of four inside
## it, so the whole opening disc is in shot with room at the sides for the
## capitals; nearest bodies 31 px, furthest 14. Sixty-two was tried and is worse
## over a full run — it frames the opening as well but loses the flanks as the
## war walks out, at 2 per cent of the Scavs on screen against 24 from here.
## TWENTY-SIX UP is a twenty-one-degree depression, which keeps sky under a fifth
## of the frame. The offset is now in -X rather than +X — it leans toward the
## Choir instead of away, and those eleven degrees are worth ten more Choir
## bodies on screen. Measured at 14 s: 21/21 Scav, 22/22 Foundry, 12/15 Choir.
##
## The tracking mast's post at (0, 0, 29) is still reachable — 47 m from the eye
## against the sixty metres of reach it is given.
const OVERLOOK_EYE := Vector3(-12.0, 26.0, 67.0)
const OVERLOOK_AIM := Vector3(0.0, 1.0, -2.0)
## Vertical field of view the spectator's freecam is authored at, in degrees.
##
## It was 58 — a long lens, chosen when the overlook stood thirty-seven metres
## from the middle and the job was to make a body read at fifty. From the new
## sixty-seven-metre overlook the job is different and the old number cannot do
## it: at 16:9 a 58-degree lens is 44.6 degrees of half-frame, the two flanking
## capitals sit 120 degrees apart on a 48 m ring, and once the war reaches them
## one of the two is always outside the picture. Sixty-six is 49.1 degrees, which
## holds the Scav mass at 45.4 and the Choir at 38.7 with room either side. It
## costs a seventh of a body's apparent size — nearest 36 px to 31 — and that is
## the whole price of seeing three factions instead of two.
const SPECTATOR_FOV: float = 66.0

## Cover clusters scattered around the arena: prop id, count, the radius band
## they are dropped in, and whether they cast a shadow. Everything here is a baked
## world prop, instanced through a MultiMesh and collided against its own trimesh.
##
## Shadows are off for the small stuff. A barrel's shadow is a smudge a metre
## across that nobody looks at, and there are sixty of those between the three
## small kinds; the silhouettes that actually read on this ground are the
## containers, the wrecks and the crates. Same rule `build_town.gd` applies to the
## wilds, for the same reason.
const CLUTTER: Array = [
	[&"containers", 12, 20.0, 76.0, true],
	[&"sandbags", 20, 16.0, 74.0, false],
	[&"wreck", 10, 18.0, 74.0, true],
	[&"big_crate", 14, 14.0, 70.0, true],
	[&"rock_cluster", 16, 24.0, 82.0, false],
	[&"barrel", 20, 12.0, 70.0, false],
]

var _rng: XorShift32 = null
var _mesher: WorldMesher = null
## Parallel to the mesher's boxes: the collider for every solid it emitted.
var _box_centers: PackedVector3Array = PackedVector3Array()
var _box_halves: PackedVector3Array = PackedVector3Array()
var _box_bases: Array[Basis] = []
## Ground a post and its ramp occupy, as `[centre, radius]`. Filled before the
## berms and the clutter are placed so neither can land on one.
var _post_keepout: Array = []
## The raised decks, as planned. See `firefight_posts.gd`.
var _posts: Array = []
## Prop instances, keyed by prop id, as world transforms.
var _clutter: Dictionary = {}
## Fixture parts that failed their own solidity check. Non-zero fails the bake.
var _open_fixtures: int = 0
var _log: PackedStringArray = PackedStringArray()


func _initialize() -> void:
	_run()


func _run() -> void:
	var t0: int = Time.get_ticks_msec()
	_rng = XorShift32.new(SEED)
	DirAccess.make_dir_recursive_absolute(OUT_DIR)

	var props: WorldPropSet = ResourceLoader.load(PROP_SET) as WorldPropSet
	if props == null:
		_fail("no prop set at %s; run res://tools/build_props.gd" % PROP_SET)
		return
	var compound: PackedScene = ResourceLoader.load(COMPOUND_KIT) as PackedScene
	if compound == null:
		_fail("no compound kit at %s; run res://tools/build_town.gd" % COMPOUND_KIT)
		return

	# ------------------------------------------------------------- geometry
	_mesher = WorldMesher.new()
	# Planned before anything is emitted and drawing no random numbers, so the berms
	# and the clutter keep the rng stream they always had while gaining a reason to
	# stay off a ramp.
	_posts = Posts.plan()
	_post_keepout = Posts.keepout(_posts)
	_build_ground()
	_build_berms()
	_build_rim()
	_build_gantry()
	_build_posts(compound)
	_scatter_clutter(props)
	var arena_mesh: ArrayMesh = _mesher.build_mesh(ResourceLoader.load(WORLD_MATERIAL) as Material)
	_save(arena_mesh, ARENA_MESH_PATH)

	var shop := Fixtures.new(Zones.DIAL_SWEEP_DEGREES)
	var fixtures: ArrayMesh = shop.build(ResourceLoader.load(STEEL_MATERIAL) as Material)
	_log.append_array(shop.log_lines)
	_open_fixtures = shop.open_parts
	if _open_fixtures > 0:
		_fail("%d fixture meshes are not watertight; see the lines above." % _open_fixtures)
		return
	_save(fixtures, FIXTURE_MESH_PATH)

	# ---------------------------------------------------------------- roster
	var built: Resource = _build_profiles()
	if built == null:
		return
	_save(built, PROFILES_PATH)
	# Read it back before handing it to the scene. `ResourceSaver.save` does not give
	# the in-memory object a resource path, so packing THAT object inlines all twelve
	# profiles into the .tscn as sub-resources — the scene grows, and worse, the
	# shipped roster and `firefight_profiles.tres` become two copies that can drift.
	# The loaded one carries its path and is referenced.
	var profiles: Resource = ResourceLoader.load(PROFILES_PATH)

	# ------------------------------------------------- navigation and cover
	var cover: AICoverSet = await _bake_navigation(props, compound)
	if cover == null:
		return

	# ----------------------------------------------------------------- scene
	var scene_root: Node3D = _assemble(compound, props, profiles)
	var packed := PackedScene.new()
	var err: int = packed.pack(scene_root)
	if err != OK:
		_fail("PackedScene.pack failed with error %d." % err)
		return
	_save(packed, SCENE_PATH)
	_selftest(arena_mesh, fixtures, scene_root)
	scene_root.free()

	_log.push_back("bake time             %d ms" % (Time.get_ticks_msec() - t0))
	_write_report()
	quit()


## Bake the navigation mesh and, on it, the cover set. Returns null and fails the
## bake if either comes out empty — both failures are silent otherwise, and both
## produce a demo whose AI stands still for reasons that look nothing like their
## cause.
func _bake_navigation(props: WorldPropSet, compound: PackedScene) -> AICoverSet:
	var nav_faces: PackedVector3Array = _mesher.vertices()
	for entry: Array in Nav.compound_boxes(compound, _home_transforms()):
		nav_faces.append_array(Nav.box_faces(entry[0], entry[1], entry[2]))
	nav_faces.append_array(Nav.clutter_faces(props, _clutter))
	var src := NavigationMeshSourceGeometryData3D.new()
	src.add_faces(nav_faces, Transform3D.IDENTITY)
	var navmesh: NavigationMesh = Nav.make_navmesh()
	Posts.tune_navmesh(navmesh)
	NavigationServer3D.bake_from_source_geometry_data(navmesh, src)
	_save(navmesh, NAV_PATH)
	_log.push_back(
		(
			"navmesh               %d polys from %d source tris"
			% [navmesh.get_polygon_count(), nav_faces.size() / 3]
		)
	)
	if navmesh.get_polygon_count() == 0:
		_fail("navmesh baked empty; the ground faces are wound the wrong way.")
		return null
	var bodies: Array[Node] = [_arena_body()]
	for i: int in FACTION_COUNT:
		var kit := compound.instantiate() as Node3D
		kit.transform = _home_transform(i)
		bodies.push_back(kit)
	for body: StaticBody3D in _clutter_bodies(props):
		bodies.push_back(body)
	var result: Array = await Cover.bake(
		self, bodies, navmesh, Nav.navmesh_bounds(navmesh, ARENA_RADIUS).grow(2.0)
	)
	var cover: AICoverSet = result[0]
	_log.append_array(result[1])
	if cover.size() == 0:
		_fail("cover sampled empty; the navigation map did not accept the region.")
		return null
	_save(cover, COVER_PATH)
	_log.push_back(
		(
			"cover                 %d points, %d cells at %.1f m"
			% [cover.size(), cover.cell_keys.size(), cover.cell_size]
		)
	)
	return cover


# --------------------------------------------------------------------- arena


## One box into both the mesh and the collider list. Nothing in this arena is
## drawn that is not collided and nothing is collided that is not drawn.
func _solid(center: Vector3, half: Vector3, yaw: float, col: Color, surface: int) -> void:
	_mesher.box(center, half, yaw, col, surface)
	_box_centers.append(center)
	_box_halves.append(half)
	_box_bases.append(Basis(Vector3.UP, yaw))


## The same for a solid that is not upright. `ex`, `ey` and `ez` are half-extent
## vectors forming a right-handed frame, as `WorldMesher.oriented_box` takes them,
## and the collider comes off the same three, so a ramp you can see and a ramp you
## can walk up cannot drift apart.
func _solid_oriented(
	center: Vector3, ex: Vector3, ey: Vector3, ez: Vector3, col: Color, surface: int
) -> void:
	_mesher.oriented_box(center, ex, ey, ez, col, surface)
	_box_centers.append(center)
	_box_halves.append(Vector3(ex.length(), ey.length(), ez.length()))
	_box_bases.append(Basis(ex.normalized(), ey.normalized(), ez.normalized()))


## The floor: one slab, plus a gravel apron sunk into it under every zone so the
## ground reads as seven places rather than one field. The aprons overlap the
## slab by three times their own height; there is no coplanar face anywhere.
func _build_ground() -> void:
	_solid(
		Vector3(0.0, -4.0, 0.0),
		Vector3(GROUND_HALF, 4.0, GROUND_HALF),
		0.0,
		Palette.TERRAIN_SAND_LOW,
		WorldSurface.Kind.SAND
	)
	for i: int in Zones.ZONES.size():
		var c: Vector3 = Zones.center(i)
		var r: float = Zones.ZONE_RADIUS * (1.25 if i == Zones.CENTRE_ZONE else 0.92)
		# A square apron under a circular zone, deliberately: gravel does not get
		# laid in a circle, and the ledger's radius is not a thing you can see.
		_solid(
			Vector3(c.x, -0.10, c.z),
			Vector3(r, 0.22, r),
			float(i) * 0.31,
			Palette.TERRAIN_GRAVEL,
			WorldSurface.Kind.ASPHALT
		)


## Rubble ridges between the zones. These are the reason a squad crossing from
## one piece of ground to the next has a decision to make: two of them are chest
## high and can be shot over, the rest are taller than a body and cannot.
##
## Every draw is taken whether or not the ridge is emitted. A ridge that lands on
## a post's ramp is dropped — a 1.6 m rubble bank across a 28-degree slope is a
## step no body can take, and it would break the one thing the ramp exists for —
## but skipping the draws too would shift every ridge and prop after it.
func _build_berms() -> void:
	for i: int in 12:
		var a: float = TAU * float(i) / 12.0 + 0.26
		var r: float = 27.0 + _rng.next_range(-3.0, 7.0)
		var c := Vector3(sin(a) * r, 0.0, cos(a) * r)
		var tall: bool = i % 3 != 0
		var h: float = 1.62 if tall else 0.86
		var length: float = _rng.next_range(9.0, 17.0)
		var thick: float = _rng.next_range(1.3, 2.2)
		var turn: float = _rng.next_range(-0.5, 0.5)
		if Posts.crosses(_post_keepout, c, a + turn, length * 0.75):
			continue
		# Sunk by its own height, so the ridge grows out of the ground rather
		# than resting on it. The buried half is never visible from outside.
		_solid(
			Vector3(c.x, h - h * 2.0 * 0.5, c.z),
			Vector3(length * 0.75, h, thick),
			a + turn,
			Palette.WORLD_ROCK[i % Palette.WORLD_ROCK.size()],
			WorldSurface.Kind.ROCK
		)
	for i: int in 9:
		var a: float = TAU * float(i) / 9.0 + 0.9
		var r: float = 64.0 + _rng.next_range(-5.0, 5.0)
		var length: float = _rng.next_range(7.0, 14.0)
		var thick: float = _rng.next_range(1.4, 2.4)
		var turn: float = _rng.next_range(-0.7, 0.7)
		var c := Vector3(sin(a) * r, 0.4, cos(a) * r)
		if Posts.crosses(_post_keepout, c, a + turn, length):
			continue
		_solid(
			c,
			Vector3(length, 1.9, thick),
			a + turn,
			Palette.WORLD_CONCRETE[i % Palette.WORLD_CONCRETE.size()],
			WorldSurface.Kind.CONCRETE
		)


## The rim: twenty-eight overlapping slabs on a circle. Overlapping and not
## butted, so there is no gap to see the sky through and no seam to z-fight, and
## tall enough that nothing walks out of the arena and nothing shoots in.
func _build_rim() -> void:
	var count: int = 28
	var seg: float = TAU / float(count)
	# Half-length is the chord for one segment plus a quarter, which is the
	# overlap. Butting them at exactly the chord is what leaves the hairline.
	var half_len: float = ARENA_RADIUS * sin(seg * 0.5) * 1.25
	for i: int in count:
		var a: float = seg * float(i)
		var c := Vector3(sin(a) * ARENA_RADIUS, 2.2, cos(a) * ARENA_RADIUS)
		_solid(
			c,
			Vector3(half_len, 4.2, 1.6),
			a + PI * 0.5,
			Palette.WORLD_CONCRETE[i % Palette.WORLD_CONCRETE.size()],
			WorldSurface.Kind.CONCRETE
		)


## The gantry: a concrete pad inside the rim wall where the spectator starts and
## where the dial lives.
##
## Its deck stands 1.2 m off the ground, which is over `agent_max_climb`, so
## Recast never puts a polygon on it and nothing at war ever walks up here. That
## is the whole trick: the one piece of ground you own is the one piece the
## navmesh does not reach, and it costs a step instead of an invisible wall.
func _build_gantry() -> void:
	_solid(
		Vector3(0.0, 0.6, 74.0),
		Vector3(9.0, 0.62, 5.0),
		0.0,
		Palette.WORLD_CONCRETE[1],
		WorldSurface.Kind.CONCRETE
	)
	# A rail along the front edge, sunk into the deck. Nothing here can fall, but
	# a viewing platform without a rail does not read as a viewing platform.
	_solid(
		Vector3(0.0, 1.55, 69.2),
		Vector3(8.6, 0.42, 0.14),
		0.0,
		Palette.STEEL,
		WorldSurface.Kind.METAL
	)
	for i: int in 7:
		_solid(
			Vector3(-8.0 + float(i) * 2.667, 1.30, 69.2),
			Vector3(0.09, 0.66, 0.09),
			0.0,
			Palette.STEEL,
			WorldSurface.Kind.METAL
		)


# ------------------------------------------------------------------ the posts


## The nine raised decks and the three ramps onto the compound's own shack roof.
## Every solid `firefight_posts.gd` returns is an oriented box, so the ramps and
## the upright blocks take the same path into the mesh and the collider list.
func _build_posts(compound: PackedScene) -> void:
	var roof: Array = Posts.kit_roof(compound)
	var solids: Array = Posts.solids(_posts)
	solids.append_array(Posts.compound_stairs(roof, _home_transforms()))
	for e: Array in solids:
		_solid_oriented(e[0], e[1], e[2], e[3], e[4], e[5])
	(
		_log
		. push_back(
			(
				"posts                 %d decks (~%.0f m2 of roof), %d shack ramps to %.2f m"
				% [
					_posts.size(),
					Posts.deck_area(_posts),
					0 if roof.is_empty() else FACTION_COUNT,
					0.0 if roof.is_empty() else (roof[0] as Vector3).y + (roof[1] as Vector3).y,
				]
			)
		)
	)


## Cover props, dropped on a blue-noise-ish rejection sample so nothing lands
## inside a compound, on a zone anchor, or on top of another prop.
func _scatter_clutter(props: WorldPropSet) -> void:
	var placed: PackedVector3Array = PackedVector3Array()
	for entry: Array in CLUTTER:
		var id: StringName = entry[0]
		var asset: WorldPropAsset = props.asset(id)
		if asset == null:
			_log.push_back("clutter               SKIPPED %s (not in the prop set)" % id)
			continue
		var want: int = entry[1]
		var lo: float = entry[2]
		var hi: float = entry[3]
		var made: Array[Transform3D] = []
		var tries: int = 0
		while made.size() < want and tries < want * 40:
			tries += 1
			var a: float = _rng.next() * TAU
			var r: float = sqrt(_rng.next_range(lo * lo, hi * hi))
			var p := Vector3(sin(a) * r, 0.0, cos(a) * r)
			if _too_close(p, placed, 4.2) or _on_a_home(p):
				continue
			placed.append(p)
			# Props are baked sitting on y = 0 with their own base at the origin,
			# so they need no vertical fudge — dropping one by a few centimetres
			# to "make sure it is not floating" is what buries the bottom row of
			# a crate and is exactly the defect this project does not have.
			made.append(Transform3D(Basis(Vector3.UP, _rng.next() * TAU), p))
		_clutter[id] = made
	var total: int = 0
	for id: StringName in _clutter:
		total += (_clutter[id] as Array).size()
	_log.push_back("clutter               %d props over %d types" % [total, _clutter.size()])


func _casts_shadow(id: StringName) -> bool:
	for entry: Array in CLUTTER:
		if entry[0] == id:
			return bool(entry[4])
	return true


func _too_close(p: Vector3, placed: PackedVector3Array, radius: float) -> bool:
	var r2: float = radius * radius
	for q: Vector3 in placed:
		if p.distance_squared_to(q) < r2:
			return true
	return false


## Ground a prop may not land on: inside a compound footprint, on a zone anchor,
## on a post's deck or ramp, or on the gantry. The kit already fills the first, a
## marker post standing in a barrel reads as a bug in the second, a barrel
## halfway up a ramp is a step nothing can climb in the third, and a crate
## through the deck of the viewing platform reads as a bug again in the fourth.
func _on_a_home(p: Vector3) -> bool:
	for i: int in Zones.ZONES.size():
		var c: Vector3 = Zones.center(i)
		var keep: float = 15.0 if int(Zones.ZONES[i][2]) >= 0 else 7.0
		if p.distance_squared_to(c) < keep * keep:
			return true
	if Posts.inside(_post_keepout, p):
		return true
	return p.distance_squared_to(Vector3(0.0, 0.0, 74.0)) < 196.0


## Twelve `AISpeciesProfile`s, built from the baked `EnemyStats` on each species
## scene plus the behaviour table above.
##
## The body numbers are NOT re-derived here. `build_enemies.gd` already turned the
## bestiary's mass, cover and dps into health, armour, speed and reach, and this
## reads them straight off the resource — two places deriving the same health is
## two places to get it wrong, and only one of them would be the one the bullets
## use.
func _build_profiles() -> Resource:
	var roster := load(SCRIPT_ROSTER) as GDScript
	var out := AISpeciesProfileSet.new()
	var made: Array[AISpeciesProfile] = []
	for id: StringName in SpeciesTable.IDS:
		var path: String = "%s/%s.res" % [ENEMY_DIR, id]
		var packed: PackedScene = ResourceLoader.load(path) as PackedScene
		if packed == null:
			_fail("missing %s; run res://tools/build_enemies.gd first." % path)
			return null
		var actor: Node = packed.instantiate()
		var body := actor.get_node_or_null(^"Body") as EnemyBody
		var stats: EnemyStats = null if body == null else body.species_stats
		if stats == null:
			actor.free()
			_fail("%s carries no EnemyStats; re-run build_enemies.gd." % path)
			return null
		made.append(roster.profile_for(id, stats))
		actor.free()
	out.profiles = made
	_log.push_back("roster                %d species profiles" % made.size())
	return out


# --------------------------------------------------------------------- scene


## The three faction homes, in enum order — what the navmesh bake stamps the
## compound kit's collision boxes through.
func _home_transforms() -> Array[Transform3D]:
	var out: Array[Transform3D] = []
	for i: int in 3:
		out.push_back(_home_transform(i))
	return out


func _home_transform(faction: int) -> Transform3D:
	var c: Vector3 = Zones.center(faction)
	var facing: Vector3 = -c
	facing.y = 0.0
	if facing.length_squared() < 1e-4:
		facing = Vector3.FORWARD
	return Transform3D(Basis.looking_at(facing.normalized(), Vector3.UP), c)


## Every arena solid as one static body. The shapes come off the same three
## arrays the mesh was built from, in the same order, so a wall and its collider
## are the same box or neither exists.
func _arena_body() -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = "ArenaBody"
	body.collision_layer = GameLayers.WORLD
	body.collision_mask = 0
	for i: int in _box_centers.size():
		var shape := BoxShape3D.new()
		shape.size = _box_halves[i] * 2.0
		var cs := CollisionShape3D.new()
		cs.name = "box_%03d" % i
		cs.shape = shape
		cs.transform = Transform3D(_box_bases[i], _box_centers[i])
		body.add_child(cs)
	return body


## One static body per prop type, carrying every instance of it as a shape on the
## asset's shared trimesh. One shape resource, N transforms — the alternative is
## N copies of the same triangle soup in memory.
func _clutter_bodies(props: WorldPropSet) -> Array[StaticBody3D]:
	var out: Array[StaticBody3D] = []
	for id: StringName in _clutter:
		var asset: WorldPropAsset = props.asset(id)
		if asset == null or asset.shape == null:
			continue
		var body := StaticBody3D.new()
		body.name = "%s_body" % id
		body.collision_layer = GameLayers.PROP
		body.collision_mask = 0
		var n: int = 0
		for x: Transform3D in _clutter[id]:
			var cs := CollisionShape3D.new()
			cs.name = "%s_%02d" % [id, n]
			cs.shape = asset.shape
			cs.transform = x
			body.add_child(cs)
			n += 1
		out.append(body)
	return out


## One MultiMesh per prop type. Nothing in this arena repeats except these, and
## these repeat a dozen times each, so it is the one place instancing earns the
## buffer it costs.
func _clutter_visuals(props: WorldPropSet) -> Array[MultiMeshInstance3D]:
	var out: Array[MultiMeshInstance3D] = []
	for id: StringName in _clutter:
		var asset: WorldPropAsset = props.asset(id)
		if asset == null or asset.mesh == null:
			continue
		var list: Array = _clutter[id]
		var mm := MultiMesh.new()
		mm.mesh = asset.mesh
		MmBake.fill(mm, list)
		var mmi := MultiMeshInstance3D.new()
		mmi.name = "%s_mm" % id
		mmi.multimesh = mm
		mmi.cast_shadow = (
			GeometryInstance3D.SHADOW_CASTING_SETTING_ON
			if _casts_shadow(id)
			else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		)
		out.append(mmi)
	return out


## The whole scene, assembled in code. Nothing below is hand-written .tscn and
## nothing below runs at load time in the shipped build: every mesh, shape,
## navmesh and cover point referenced here was written to disk above.
func _assemble(compound: PackedScene, props: WorldPropSet, profiles: Resource) -> Node3D:
	var root_node := Node3D.new()
	root_node.name = "Firefight"
	root_node.set_script(load(SCRIPT_DEMO))

	var world: Node = (ResourceLoader.load(WORLD_SCENE) as PackedScene).instantiate()
	# This is the only demo that puts sixty animated bodies on the field at once,
	# and every one of them is six draws in the main pass and six more in each
	# cascade it stands in. Pulling the cascade reach in from the shared 140 m to
	# 60 m drops the far half of the fight out of the shadow pass entirely — worth
	# ~110 calls, and invisible behind haze that is already thickening at 60 m.
	#
	# It was 60 m while the spectator started thirty-seven metres out. From the
	# new overlook 60 m costs 825 draw calls against the 800 in
	# `demos/budget/max_draw_calls` and 46 costs 634 but strips the near berms and
	# the frame goes flat. 56 is the first build of this demo under its budget.
	world.set(&"shadow_distance", 56.0)
	_add(root_node, world, "ScavWorld")
	_add(root_node, (ResourceLoader.load(VFX_SCENE) as PackedScene).instantiate(), "Vfx")

	var arena := Node3D.new()
	_add(root_node, arena, "Arena")
	var ground := MeshInstance3D.new()
	ground.mesh = ResourceLoader.load(ARENA_MESH_PATH) as ArrayMesh
	ground.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	_add(arena, ground, "Ground")
	_add(arena, _arena_body(), "ArenaBody")
	for i: int in FACTION_COUNT:
		var kit := compound.instantiate() as Node3D
		kit.transform = _home_transform(i)
		_add(arena, kit, "Compound_%s" % FACTION_NAMES[i])
	for mmi: MultiMeshInstance3D in _clutter_visuals(props):
		_add(arena, mmi, mmi.name)
	for body: StaticBody3D in _clutter_bodies(props):
		_add(arena, body, body.name)

	var region := NavigationRegion3D.new()
	region.navigation_mesh = ResourceLoader.load(NAV_PATH) as NavigationMesh
	_add(root_node, region, "Nav")

	var zones := Node3D.new()
	_add(root_node, zones, "Zones")
	var fixtures := Node3D.new()
	_add(root_node, fixtures, "Fixtures")
	var furniture := Zones.new(ResourceLoader.load(FIXTURE_MESH_PATH) as ArrayMesh)
	for i: int in Zones.ZONES.size():
		_add(zones, furniture.zone_node(i), "Zone_%s" % Zones.ZONES[i][0])
		_add(fixtures, furniture.banner(i), "Banner_%s" % Zones.ZONES[i][0])
		var post: Node3D = furniture.marker(i)
		# The mast over the contested centre is the one control a spectator has in
		# front of them when the demo opens, and the overlook stands off it by more
		# than the twenty-six metres a post beside a zone is reachable from. It is
		# also the tallest thing on the field and the only fixture that physically
		# tracks the fighting, so operating it from a distance is what it is for.
		if i == Zones.CENTRE_ZONE:
			post.set(&"reach", 60.0)
		_add(fixtures, post, "Marker_%s" % Zones.ZONES[i][0])
	_add(fixtures, furniture.gantry_marker(), "Marker_gantry")
	_add(fixtures, furniture.dial(), "Dial")
	_add(fixtures, furniture.sign_post(), "Sign")

	_add(root_node, _director(profiles), "Director")
	var gunfire := Node.new()
	gunfire.set_script(load(SCRIPT_GUNFIRE))
	_add(root_node, gunfire, "Gunfire")

	var freecam := (ResourceLoader.load(FREECAM_SCENE) as PackedScene).instantiate() as Camera3D
	# A longer lens than the game's 75-degree default, and it is a framing decision
	# with two effects rather than one. A body is half again as tall on screen at
	# the same distance, which is the difference between a figure and a smudge at
	# fifty metres; and the horizon climbs, because the sky's share of the frame is
	# the depression angle over the field of view — the same 13-degree downward
	# tilt leaves 33 per cent sky at 75 degrees and 27 at 58. `FreecamController`
	# only overwrites this when it adopts another camera on activation, and this
	# scene has none, so the authored value is the one that ships.
	freecam.fov = SPECTATOR_FOV
	_add(root_node, freecam, "Freecam")
	var spectator := Node.new()
	spectator.set_script(load(SCRIPT_SPECTATOR))
	spectator.set(&"freecam_path", NodePath("../Freecam"))
	spectator.set(&"start_transform", _overlook_view())
	_add(root_node, spectator, "Spectator")

	_own(root_node, root_node)
	return root_node


## The director and everything it owns: its clock, its path budget and one
## spawner per faction.
func _director(profiles: Resource) -> Node3D:
	var director := Node3D.new()
	director.set_script(load(SCRIPT_DIRECTOR))
	_add(director, _scheduler_node(), "Scheduler")
	_add(director, _path_service_node(), "Paths")
	var spawner_paths: Array[NodePath] = []
	for f: int in FACTION_COUNT:
		var child_name: String = "Spawn_%s" % FACTION_NAMES[f]
		_add(director, _spawner(f, profiles), child_name)
		spawner_paths.append(NodePath(child_name))
	director.set(&"spawner_paths", spawner_paths)
	director.set(&"cover_set", ResourceLoader.load(COVER_PATH))
	if ResourceLoader.exists(PERCEPTION_TUNING):
		director.set(&"perception_tuning", ResourceLoader.load(PERCEPTION_TUNING))
	if ResourceLoader.exists(ROLE_DOCTRINE):
		director.set(&"doctrine", ResourceLoader.load(ROLE_DOCTRINE))
	director.set(&"seed_value", SEED)
	director.set(&"target_population", 22)
	# Sixty-six bodies on the field the moment the map answers a query, deployed
	# on the three approaches to the centre rather than at home. A fraction below
	# one buys nothing here: the reinforcement rate scales with the deficit, so a
	# faction that opens short simply spends its first minute filling up, and the
	# spectator spends that minute watching an empty valley.
	director.set(&"opening_fraction", 1.0)
	director.set(&"opening_in_contact", true)
	# THE OPENING IS A LINE OF BATTLE, NOT A PILE. These three used to be 5 / 30 /
	# 108, which put all sixty-six bodies inside a thirty-metre disc with twelve
	# degrees between one faction's arc and the next — every body within melee
	# reach of two enemies on the first tick. Measured on that build: forty of the
	# sixty-six died in the first fifteen seconds, all of them Scav and Choir, and
	# the Foundry did not lose one. Two factions were then five bodies apiece for
	# the whole first minute, which is exactly the "i only see 2 factions" the
	# demo was reported for.
	#
	# Twelve to thirty-six over a hundred-degree arc leaves twenty degrees of
	# no-man's-land between neighbours — about ten metres of it at the middle of
	# the line and four at the inner tips, where the flanks touch and the war
	# starts. It is still one contested disc centred on the objective, because
	# that is the one composition a spectator can read.
	director.set(&"front_inner", 12.0)
	director.set(&"front_outer", 36.0)
	director.set(&"front_arc_degrees", 100.0)
	return director


## Add a child and give it a name. Ownership is set in one pass at the end, which
## is the only way `PackedScene.pack` keeps a whole subtree.
func _add(parent: Node, child: Node, child_name: String) -> void:
	child.name = child_name
	parent.add_child(child)


## Every descendant owned by the scene root, or `pack` writes an empty shell.
## Instanced sub-scenes keep their own root's ownership and are stored as an
## instance reference rather than expanded, which is what keeps this .tscn small.
func _own(node: Node, scene_owner: Node) -> void:
	for child: Node in node.get_children():
		if child.scene_file_path != "":
			child.owner = scene_owner
			continue
		child.owner = scene_owner
		_own(child, scene_owner)


func _scheduler_node() -> Node:
	var s := Node.new()
	s.set_script(load(SCRIPT_SCHEDULER))
	# Wider than the defaults because a spectator flies. The arena is 176 m
	# across, so a far radius of 200 keeps every body on a real clock rather than
	# dropping half the war to the dormant crawl the moment the camera crosses
	# the middle.
	#
	#
	# The near radius stays at 30 and it was measured, not assumed. Widening it to
	# 65 so that the whole visible front thinks at thirty hertz is the obvious
	# thing to reach for when the battle looks quiet, and it does not work: the
	# rate of fire is gated by the friendly-fire corridor test and the engagement
	# band, not by how often a body is asked, so sixty-six bodies at thirty hertz
	# bought four rounds a second and cost sixty per cent of the frame — 185 fps
	# down to 73. Density of fire is bought in this demo by where the bodies are
	# standing, and it is free.
	s.set(&"near_radius", 30.0)
	s.set(&"mid_radius", 90.0)
	s.set(&"far_radius", 200.0)
	s.set(&"near_hz", 30.0)
	s.set(&"mid_hz", 12.0)
	s.set(&"far_hz", 4.0)
	s.set(&"dormant_hz", 1.0)
	s.set(&"agents_per_frame", 40)
	s.set(&"ray_budget_per_frame", 60)
	s.set(&"path_budget_per_frame", 10)
	s.set(&"rebucket_per_frame", 72)
	return s


func _path_service_node() -> Node:
	var p := Node.new()
	p.set_script(load(SCRIPT_PATHS))
	p.set(&"requests_per_frame", 8)
	p.set(&"max_queue", 256)
	p.set(&"combat_repath_interval", 0.7)
	p.set(&"repath_interval", 2.2)
	return p


func _spawner(faction: int, profiles: Resource) -> Node3D:
	var s := Node3D.new()
	s.set_script(load(SCRIPT_SPAWNER))
	var roster: Array[StringName] = []
	for id: StringName in _roster_constant("ROSTERS")[faction]:
		roster.append(id)
	s.set(&"species", roster)
	s.set(&"profiles", profiles)
	s.set(&"faction", faction)
	# Headroom over the director target so a wave still lands while the last
	# one's corpses are still lying there taking up capacity.
	#
	# `EnemySpawner.capacity` counts corpses: a body stays in `_live` for its
	# eight-second `corpse_linger` plus however long the collapse takes to settle.
	# At the reinforcement rate the director now runs — a hurt faction takes five
	# bodies every four seconds — a peak of ten corpses is ordinary, and at the
	# old ceiling of 30 that is eight live fighters the faction cannot field
	# because dead ones are holding their slots.
	s.set(&"max_alive", 32)
	# Ten of any one species per faction. Four species at ten is 40, over the
	# spawner's own ceiling, so the weighted draw is never limited by the pool as
	# a whole — only the commonest slot runs dry, and `_spawn_one` rolls again.
	s.set(&"pool_per_species", 10)
	s.set(&"prewarm", true)
	s.set(&"prewarm_batch", 2)
	s.set(&"auto_spawn", false)
	s.set(&"snap_to_navmesh", true)
	s.set(&"yaw_jitter", 0.7)
	s.set(&"spread_radius", 7.5)
	s.set(&"seed_value", SEED + faction * 7919)
	s.position = Zones.center(faction)
	return s


## One constant off the roster script, which is loaded by path for the same
## autoload reason everything else here is.
func _roster_constant(key: StringName) -> Variant:
	return (load(SCRIPT_ROSTER) as GDScript).get_script_constant_map()[key]


func _overlook_view() -> Transform3D:
	var to: Vector3 = (OVERLOOK_AIM - OVERLOOK_EYE).normalized()
	return Transform3D(Basis.looking_at(to, Vector3.UP), OVERLOOK_EYE)


# ----------------------------------------------------------------- self-test


## The quality bar, checked rather than asserted. A bake that fails any of these
## has already written its meshes, so the failure is loud and the evidence is on
## disk to look at.
func _selftest(arena: ArrayMesh, fixtures: ArrayMesh, scene_root: Node3D) -> void:
	var arena_pos: PackedVector3Array = _mesher.vertices()
	_log.push_back(
		(
			"arena mesh            %d tris, %d degenerate, %d normal conflicts"
			% [_mesher.triangle_count(), _mesher.degenerate_count(), _mesher.normal_conflicts()]
		)
	)
	# Two posts inside each other are two ramps running into each other, and a post
	# on a flagpole is a flagpole inside a solid. The plan is deterministic, so both
	# are checked here rather than eyeballed on an overhead render.
	var clearance: float = Posts.clearance(_posts, Posts.fixture_keepouts())
	_log.push_back("post spacing          closest keep-out pair %.1f m apart" % clearance)
	var volume: float = _mesher.signed_volume()
	var boundary: int = Fixtures.boundary_edges(arena_pos)
	_log.push_back("arena solidity        volume %+.1f m3, %d boundary edges" % [volume, boundary])
	_log.push_back(
		(
			"arena surfaces        %d colliders, %d mesh surfaces"
			% [_box_centers.size(), arena.get_surface_count()]
		)
	)
	_log.push_back("fixtures              %d surfaces" % fixtures.get_surface_count())
	_log.push_back("scene                 %d nodes" % _count_nodes(scene_root))
	var ok: bool = (
		volume > 0.0
		and boundary == 0
		and _mesher.degenerate_count() == 0
		and _mesher.normal_conflicts() == 0
		and clearance > 0.0
	)
	_log.push_back("")
	_log.push_back("POSTS CLEAR      : %s" % ("PASS" if clearance > 0.0 else "FAIL"))
	_log.push_back("OUTWARD WINDING  : %s" % ("PASS" if volume > 0.0 else "FAIL"))
	_log.push_back(
		(
			"NO OPEN SHELLS   : %s (%d boundary edges)"
			% ["PASS" if boundary == 0 else "FAIL", boundary]
		)
	)
	_log.push_back(
		(
			"NO DEGENERATES   : %s (%d)"
			% ["PASS" if _mesher.degenerate_count() == 0 else "FAIL", _mesher.degenerate_count()]
		)
	)
	_log.push_back("VERDICT          : %s" % ("PASS" if ok else "FAIL"))


func _count_nodes(node: Node) -> int:
	var n: int = 1
	for child: Node in node.get_children():
		n += _count_nodes(child)
	return n


# ------------------------------------------------------------------- output


func _save(res: Resource, path: String) -> void:
	var err: int = ResourceSaver.save(res, path)
	if err != OK:
		_log.push_back("FATAL: could not write %s (error %d)" % [path, err])
		push_error("build_firefight: could not write %s (error %d)." % [path, err])
		return
	_log.push_back("wrote                 %s" % path)


func _fail(message: String) -> void:
	push_error("build_firefight: %s" % message)
	_log.push_back("FATAL: %s" % message)
	_write_report()
	quit(1)


func _write_report() -> void:
	var text: String = "firefight bake\n" + "\n".join(_log) + "\n"
	DirAccess.make_dir_recursive_absolute(REPORT_PATH.get_base_dir())
	var f := FileAccess.open(REPORT_PATH, FileAccess.WRITE)
	if f != null:
		f.store_string(text)
		f.close()
	print(text)
