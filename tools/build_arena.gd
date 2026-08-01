extends SceneTree
## Arena bake. Authors the compound, bakes its navigation and its cover, derives a
## species profile set from the shipped bestiary, and packs the whole demo.
##
## Writes:
##   res://demos/arena/arena_shell.res     the fused compound mesh
##   res://demos/arena/arena_shape.res     its trimesh collider
##   res://demos/arena/arena_nav.res       the baked NavigationMesh
##   res://demos/arena/arena_cover.tres    the sampled AICoverSet
##   res://demos/arena/arena_species.tres  AISpeciesProfileSet for the twelve
##   res://demos/arena/arena.tscn          the demo
##   res://demos/arena/arena_report.txt    the self-test
##
## Run headless:
##   godot --headless --path <project> --script res://tools/build_arena.gd
##
## The whole compound is ONE mesh and ONE draw call. Nothing in it repeats — every
## container is a different colour and every barrier a different angle, and the
## world shader's grain is keyed to object space — so a MultiMesh would need an
## instance buffer per distinct prop and still cost a draw call each. Fusing the
## soup is strictly cheaper here, and the trimesh collider comes free with it.
##
## The scripts are pulled in with `load` rather than by `class_name`, and the work
## happens on the first idle frame: `--script` compiles the main loop and its whole
## dependency graph BEFORE the autoloads exist, and anything that names
## `GameSettings` at parse time fails to compile. By frame one the autoloads are up.

## The compound's geometry and its dimensions. Preloaded rather than named,
## because it carries no `class_name`.
const ArenaShell := preload("res://tools/build_arena_geometry.gd")

const OUT_DIR: String = "res://demos/arena"
const SHELL_PATH: String = "res://demos/arena/arena_shell.res"
const SHAPE_PATH: String = "res://demos/arena/arena_shape.res"
const NAV_PATH: String = "res://demos/arena/arena_nav.res"
const COVER_PATH: String = "res://demos/arena/arena_cover.tres"
const SPECIES_PATH: String = "res://demos/arena/arena_species.tres"
const SCENE_PATH: String = "res://demos/arena/arena.tscn"
const REPORT_PATH: String = "res://demos/arena/arena_report.txt"

const WORLD_SCENE: String = "res://art/scav_world.tscn"
const VFX_SCENE: String = "res://data/vfx/vfx.tscn"
const PLAYER_SCENE: String = "res://data/player/player.tscn"
const HUD_SCENE: String = "res://ui/hud/combat_hud.tscn"
const WORLD_MATERIAL: String = "res://art/materials/world_surface.tres"
const PERCEPTION_TUNING: String = "res://data/ai/perception_tuning.tres"
const ROLE_DOCTRINE: String = "res://data/ai/role_doctrine.tres"
const ENEMY_DIR: String = "res://data/enemies"

const DIAL_SCENE: String = "res://ui/diegetic/diegetic_dial.tscn"
const LEVER_SCENE: String = "res://ui/diegetic/diegetic_lever.tscn"
const READOUT_SCENE: String = "res://ui/diegetic/diegetic_readout.tscn"

const SCRIPT_CONTROLLER: String = "res://demos/arena/arena_controller.gd"
const SCRIPT_DIRECTOR: String = "res://demos/arena/arena_director.gd"
const SCRIPT_STATION: String = "res://demos/arena/arena_station.gd"
const SCRIPT_LOADOUT: String = "res://demos/arena/arena_loadout.gd"
const SCRIPT_GATE: String = "res://demos/arena/arena_gate.gd"
## `EnemySpawner` reads `GameSettings` for its live cap, and naming it at parse
## time would drag that autoload into a script the engine compiles before any
## autoload exists. Loaded by path on the first frame instead, like the player
## bake does with the controller.
const SCRIPT_SPAWNER: String = "res://systems/enemies/enemy_spawner.gd"
## The player's pseudo-faction. `Factions.PLAYER` for the same reason as above.
const FACTION_PLAYER: int = -1
## `Factions.COUNT` and `Factions.NAMES`, spelled out for the same reason: naming
## the autoload in a script the engine hands to `--script` fails the compile.
const FACTION_COUNT: int = 3
const FACTION_NAMES: PackedStringArray = ["Scav", "Foundry", "Choir"]

## Bodies ONE faction's spawner will hold, before the quality preset is applied.
## `EnemySpawner.capacity()` is `min(max_alive, GameSettings.max_enemies)`, and 64
## is the Ultra preset's figure — so this is deliberately set at the top of the
## preset ladder and the LIVE cap is whatever the player's quality setting allows.
## The arena's own total ceiling is `ArenaController.population_cap`, which is
## measured rather than chosen and is the number the COUNT dial reads at its stop.
const SPAWNER_MAX_ALIVE: int = 64
## Pooled actors per species per spawner. Nothing is instantiated until it is
## asked for (`prewarm` is off), so this is a ceiling and not an allocation: it
## has to cover the worst case, which is a whole wave of ONE species on ONE
## faction, and 48 covers that against any preset below Ultra.
const SPAWNER_POOL_PER_SPECIES: int = 48

## Navigation bake. Agent radius is the widest body in the bestiary plus a hand.
const NAV_AGENT_RADIUS: float = 0.55
const NAV_AGENT_HEIGHT: float = 2.7
const NAV_AGENT_CLIMB: float = 0.45
## The navigation map a region is added to has its own cell size, and a mesh baked
## at a different one is rejected outright. These are the map defaults; changing
## them means changing the map too.
const NAV_CELL_SIZE: float = 0.25
const NAV_CELL_HEIGHT: float = 0.25

## Physics frames the bake will wait for the navigation map to finish an
## iteration with the new region in it. Two is enough; the rest is headroom.
const NAV_SETTLE_FRAMES: int = 24

## Cover sampling grid, metres. Tighter than the town's because this compound is
## small and the cover is what the demo is for.
const COVER_SPACING: float = 1.5

var _report: PackedStringArray = PackedStringArray()
var _failed: bool = false
var _built: bool = false


## The bake is a coroutine — the navigation and cover passes both need real
## physics frames — so this never reports "done". `_run` calls `quit` itself.
func _process(_delta: float) -> bool:
	if not _built:
		_built = true
		_run()
	return false


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	var started: int = Time.get_ticks_msec()

	var mesher: WorldMesher = ArenaShell.build()
	_check_mesh(mesher)
	var material: Material = load(WORLD_MATERIAL) as Material
	var shell: ArrayMesh = mesher.build_mesh(material)
	_save(shell, SHELL_PATH, "compound mesh (%d tris)" % mesher.triangle_count())

	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(mesher.vertices())
	shape.backface_collision = false
	_save(shape, SHAPE_PATH, "compound collider")

	var species: AISpeciesProfileSet = _derive_profiles()
	_save(species, SPECIES_PATH, "species profiles (%d)" % species.profiles.size())

	var probe: Node3D = await _stage(shell, shape)
	var nav_mesh: NavigationMesh = _bake_nav(probe)
	_save(nav_mesh, NAV_PATH, "navmesh (%d polys)" % nav_mesh.get_polygon_count())
	var cover: AICoverSet = await _bake_cover(probe, nav_mesh)
	_save(cover, COVER_PATH, "cover set (%d points)" % cover.size())
	probe.queue_free()

	var root: Node3D = _assemble(shell, shape, nav_mesh, cover, species)
	var packed := PackedScene.new()
	var err: Error = packed.pack(root)
	if err != OK:
		_fail("packing the arena failed (error %d)" % err)
	else:
		_save(packed, SCENE_PATH, "scene (%d nodes)" % _count(root))
	root.free()

	_report.append("build time            %d ms" % (Time.get_ticks_msec() - started))
	_write_report()
	quit(1 if _failed else 0)


func _check_mesh(m: WorldMesher) -> void:
	var volume: float = m.signed_volume()
	var conflicts: int = m.normal_conflicts()
	_report.append("triangles             %d" % m.triangle_count())
	_report.append("degenerates dropped   %d" % m.degenerate_count())
	_report.append("signed volume         %.2f m3 (positive is outward)" % volume)
	_report.append("normal conflicts      %d" % conflicts)
	if volume <= 0.0:
		_fail("compound mesh is inside out")
	if conflicts != 0:
		_fail("%d triangles disagree with their own winding" % conflicts)


# =============================================================== species


## Turn the shipped bestiary into AI profiles.
##
## Every number here is read off the baked `EnemyStats` the bestiary produced —
## health, armour, both gaits, the body box, the detection radius and the reach —
## rather than authored a second time. What this adds is the handful of things the
## stats do not carry because they are behaviour and not anatomy: which end of the
## weapon enum a species is on, its burst discipline, and how much it will take
## before it stops leaning out.
func _derive_profiles() -> AISpeciesProfileSet:
	var set_res := AISpeciesProfileSet.new()
	var made: Array[AISpeciesProfile] = []
	for id: StringName in SpeciesTable.IDS:
		var path: String = "%s/%s.res" % [ENEMY_DIR, id]
		var packed: PackedScene = load(path) as PackedScene
		if packed == null:
			_fail("missing %s; run res://tools/build_enemies.gd" % path)
			continue
		var actor: Node = packed.instantiate()
		var stats: EnemyStats = _stats_of(actor)
		if stats == null:
			_fail("%s carries no EnemyStats" % path)
			actor.free()
			continue
		made.append(_profile_from(id, stats))
		actor.free()
	set_res.profiles = made
	return set_res


func _stats_of(node: Node) -> EnemyStats:
	var body := node as EnemyBody
	if body != null and body.species_stats != null:
		return body.species_stats
	for child: Node in node.get_children():
		var found: EnemyStats = _stats_of(child)
		if found != null:
			return found
	return null


func _profile_from(id: StringName, stats: EnemyStats) -> AISpeciesProfile:
	var p := AISpeciesProfile.new()
	var role: String = String(SpeciesTable.CATALOGUE[id]["role"])
	p.species_id = id
	p.display_name = stats.display_name
	p.tier = stats.tier_index
	p.threat = stats.threat
	p.height = stats.height
	p.body_radius = maxf(stats.width, stats.depth) * 0.5
	p.health = stats.health
	p.armour = stats.armour
	p.eye_height = maxf(stats.height * 0.88, 0.25)
	p.walk_speed = maxf(stats.speed, 0.35)
	p.run_speed = maxf(stats.run_speed, p.walk_speed + 0.2)
	p.hover_height = stats.alt
	# A body that turns faster than it can walk reads as a turret. Tying the slew
	# to the gait keeps a foreman ponderous and a wasp twitchy without a table.
	p.turn_rate = clampf(1.4 + p.run_speed * 0.9, 1.2, 7.5)
	p.sight_range = maxf(stats.detect, 8.0)
	p.peripheral_range = clampf(p.body_radius * 8.0, 2.5, 7.0)
	p.weapon_range = maxf(stats.reach, 1.2)
	p.damage = maxf(stats.damage, 4.0)
	p.reaction_time = clampf(0.44 - stats.threat * 0.003, 0.14, 0.6)
	p.aim_settle = clampf(1.15 - stats.threat * 0.006, 0.35, 1.2)
	_arm(p, role)
	p.suppression_tolerance = clampf(0.35 + stats.armour * 0.005, 0.3, 0.95)
	p.suppression_gain = clampf(1.35 - stats.armour * 0.006, 0.5, 1.4)
	p.rout_fraction = clampf(0.8 - stats.threat * 0.004, 0.3, 0.85)
	p.flee_health = 0.0 if stats.armour > 40.0 else 0.12
	p.reference_dps = stats.damage
	return p


## Which end of the weapon enum a species lives at. The bestiary's `role` string
## is the authority — it is what the reference calls each animal, and it is the
## only place the distinction between a rusher and a marksman is written down.
func _arm(p: AISpeciesProfile, role: String) -> void:
	match role:
		"ranged":
			p.weapon = AISpeciesProfile.Weapon.RIFLE
			p.rpm = 55.0
			p.burst = 1
			p.burst_pause = 1.35
			p.magazine = 6
			p.reload_time = 3.1
			p.spread_degrees = 0.7
			p.min_range = 12.0
			p.fov_degrees = 96.0
			p.bias_scout = 0.6
			p.bias_suppressor = 0.4
		"suppression":
			p.weapon = AISpeciesProfile.Weapon.AUTO
			p.rpm = 620.0
			p.burst = 7
			p.burst_pause = 1.1
			p.magazine = 60
			p.reload_time = 4.2
			p.spread_degrees = 2.6
			p.fov_degrees = 118.0
			p.bias_suppressor = 2.2
			p.bias_advancer = 0.5
		"recon":
			p.weapon = AISpeciesProfile.Weapon.RIFLE
			p.rpm = 180.0
			p.burst = 2
			p.burst_pause = 1.6
			p.magazine = 12
			p.reload_time = 2.4
			p.spread_degrees = 2.2
			p.fov_degrees = 200.0
			p.bias_scout = 2.4
			p.bias_flanker = 1.4
		"area denial":
			p.weapon = AISpeciesProfile.Weapon.CONE
			p.rpm = 240.0
			p.burst = 12
			p.burst_pause = 1.8
			p.magazine = 90
			p.reload_time = 3.4
			p.spread_degrees = 7.5
			p.fov_degrees = 128.0
			p.bias_advancer = 1.6
		"siege":
			p.weapon = AISpeciesProfile.Weapon.AUTO
			p.rpm = 90.0
			p.burst = 3
			p.burst_pause = 2.2
			p.magazine = 18
			p.reload_time = 5.0
			p.spread_degrees = 3.4
			p.fov_degrees = 110.0
			p.bias_suppressor = 1.5
			p.bias_flanker = 0.1
			# AN ARMED ROLE NEEDS A REACH ITS ARMAMENT CAN USE, and this is the one
			# species where the bestiary's own number cannot supply it.
			# `_profile_from` takes `weapon_range` from `EnemyStats.reach`, which is
			# how far the animal can touch you — for the three genuinely ranged
			# species that is already 120 m (marksman), 45 m (sentinel) and 30 m
			# (wasp), so the table is right about them. The Foreman's reach is
			# **3.4 m**, because it is a walker that hits things, and this branch
			# then hands it a belt-fed automatic. `AICombat._reach()` takes the
			# SHORTER of the gun and the species, so a siege machine gun would not
			# pull its trigger until the target was inside three and a half metres,
			# and measured, a foreman in the arena fired nothing at all across a
			# fifty-second wave. Only this one species moves.
			p.weapon_range = maxf(p.weapon_range, 26.0)
		"detonator":
			p.weapon = AISpeciesProfile.Weapon.DETONATOR
			p.suicide_charge = true
			p.blast_radius = 5.5
			p.rpm = 60.0
			p.magazine = 1
			p.fov_degrees = 150.0
			p.bias_advancer = 2.6
			p.bias_flanker = 0.2
		_:
			# Everything else closes and uses what it has. Reach came off the rig,
			# so a stilt swings from three metres and a husk from one.
			p.weapon = AISpeciesProfile.Weapon.MELEE
			p.rpm = 48.0
			p.burst = 1
			p.burst_pause = 0.65
			p.magazine = 1
			p.reload_time = 0.6
			p.spread_degrees = 0.0
			p.fov_degrees = 150.0
			p.bias_advancer = 2.0
			p.bias_flanker = 1.1


# =============================================================== bakes


## A throwaway tree holding only the compound's mesh and its collider. The
## navigation and cover bakes both need real geometry in a real world, and running
## them against the assembled demo would also run the demo.
func _stage(shell: ArrayMesh, shape: ConcavePolygonShape3D) -> Node3D:
	var probe := Node3D.new()
	probe.name = "BakeProbe"
	var mi := MeshInstance3D.new()
	mi.name = "Shell"
	mi.mesh = shell
	probe.add_child(mi)
	var body := StaticBody3D.new()
	body.name = "ShellBody"
	body.collision_layer = GameLayers.WORLD
	body.collision_mask = 0
	var cs := CollisionShape3D.new()
	cs.shape = shape
	body.add_child(cs)
	probe.add_child(body)
	root.add_child(probe)
	for _i: int in 4:
		await physics_frame
	return probe


func _bake_nav(probe: Node3D) -> NavigationMesh:
	var nav := NavigationMesh.new()
	nav.agent_radius = NAV_AGENT_RADIUS
	nav.agent_height = NAV_AGENT_HEIGHT
	nav.agent_max_climb = NAV_AGENT_CLIMB
	nav.agent_max_slope = 46.0
	nav.cell_size = NAV_CELL_SIZE
	nav.cell_height = NAV_CELL_HEIGHT
	nav.geometry_parsed_geometry_type = NavigationMesh.PARSED_GEOMETRY_MESH_INSTANCES
	nav.geometry_source_geometry_mode = NavigationMesh.SOURCE_GEOMETRY_ROOT_NODE_CHILDREN
	nav.filter_low_hanging_obstacles = true
	nav.filter_ledge_spans = true
	nav.filter_walkable_low_height_spans = true
	var source := NavigationMeshSourceGeometryData3D.new()
	NavigationServer3D.parse_source_geometry_data(nav, source, probe)
	NavigationServer3D.bake_from_source_geometry_data(nav, source)
	if nav.get_polygon_count() == 0:
		_fail("the navigation bake produced no polygons")
	return nav


func _bake_cover(probe: Node3D, nav: NavigationMesh) -> AICoverSet:
	var region := NavigationRegion3D.new()
	region.name = "NavProbe"
	probe.add_child(region)
	# The mesh is assigned after the region is in the tree: the setter pushes the
	# polygons at whichever map the region already belongs to, and a region that
	# has not entered the tree yet belongs to none.
	region.navigation_mesh = nav
	var map: RID = region.get_navigation_map()
	# A map answers queries only once it has run an iteration with the new region
	# in it, and forcing an update schedules that iteration rather than performing
	# it. Waiting on the iteration counter is the only honest way to know.
	var settled: int = 0
	while settled < NAV_SETTLE_FRAMES and NavigationServer3D.map_get_iteration_id(map) < 2:
		await physics_frame
		NavigationServer3D.map_force_update(map)
		settled += 1
	# A map that answers with the origin for every probe has not synchronised, and
	# every sample would then be discarded as out of tolerance. Say so once here
	# rather than reporting an empty cover set with no explanation.
	var here: Vector3 = NavigationServer3D.map_get_closest_point(map, Vector3(0.0, 1.0, 0.0))
	_report.append(
		(
			"nav map probe         (0, 1, 0) -> %.2v  cell %.3f  regions %d"
			% [
				here,
				NavigationServer3D.map_get_cell_size(map),
				NavigationServer3D.map_get_regions(map).size()
			]
		)
	)
	var bounds := AABB(
		Vector3(-ArenaShell.HALF_X - 1.0, -1.0, -ArenaShell.HALF_Z - 1.0),
		Vector3(
			ArenaShell.HALF_X * 2.0 + 2.0, ArenaShell.WALL_H + 4.0, ArenaShell.HALF_Z * 2.0 + 2.0
		)
	)
	var cover: AICoverSet = AICoverSampler.sample(
		probe.get_world_3d().direct_space_state,
		map,
		bounds,
		{"spacing": COVER_SPACING, "cell_size": 4.0}
	)
	if cover.size() == 0:
		_fail("the cover bake found nothing to hide behind")
	return cover


# =============================================================== assembly


func _assemble(
	shell: ArrayMesh,
	shape: ConcavePolygonShape3D,
	nav: NavigationMesh,
	cover: AICoverSet,
	species: AISpeciesProfileSet
) -> Node3D:
	var root: Node3D = (load(SCRIPT_CONTROLLER) as Script).new()
	root.name = "Arena"

	root.add_child(_instance(WORLD_SCENE, "World"))
	root.add_child(_instance(VFX_SCENE, "Vfx"))

	var compound := Node3D.new()
	compound.name = "Compound"
	root.add_child(compound)

	var mi := MeshInstance3D.new()
	mi.name = "Shell"
	mi.mesh = shell
	# World-space vertices, so the node stays at identity: the world shader's grain
	# is object-space and rebasing would slide it.
	mi.gi_mode = GeometryInstance3D.GI_MODE_STATIC
	compound.add_child(mi)

	var body := StaticBody3D.new()
	body.name = "ShellBody"
	body.collision_layer = GameLayers.WORLD
	body.collision_mask = 0
	var cs := CollisionShape3D.new()
	cs.name = "Shape"
	cs.shape = shape
	body.add_child(cs)
	compound.add_child(body)

	var region := NavigationRegion3D.new()
	region.name = "Nav"
	region.navigation_mesh = nav
	compound.add_child(region)

	var gates: Array[NodePath] = []
	# Each gate's local -Z points INTO the compound: the spawner pushes a body along
	# that axis to clear the frame, and a gate facing the wrong way delivers its
	# occupants into the desert.
	var wall_z: float = ArenaShell.HALF_Z + ArenaShell.WALL_HALF_T
	var wall_x: float = ArenaShell.HALF_X + ArenaShell.WALL_HALF_T
	var gate_specs: Array = [
		[
			"GateNorthWest",
			Vector3(-ArenaShell.GATE_X, 0.0, -wall_z),
			PI,
			ArenaShell.GATE_HALF_W,
			ArenaShell.GATE_H
		],
		[
			"GateNorthEast",
			Vector3(ArenaShell.GATE_X, 0.0, -wall_z),
			PI,
			ArenaShell.GATE_HALF_W,
			ArenaShell.GATE_H
		],
		[
			"DoorEast",
			Vector3(wall_x, 0.0, ArenaShell.EAST_DOOR_Z),
			PI * 0.5,
			ArenaShell.DOOR_HALF_W,
			ArenaShell.DOOR_H
		],
		[
			"DoorWest",
			Vector3(-wall_x, 0.0, ArenaShell.WEST_DOOR_Z),
			-PI * 0.5,
			ArenaShell.DOOR_HALF_W,
			ArenaShell.DOOR_H
		],
	]
	for spec: Array in gate_specs:
		var gate: Node3D = _build_gate(spec[0], spec[1], spec[2], spec[3], spec[4])
		compound.add_child(gate)
		gates.append(NodePath("Compound/%s" % spec[0]))

	compound.add_child(_build_station(species))
	compound.add_child(
		_sign(
			"StationSign",
			"ENEMY TEST ARENA",
			Vector3(0.0, ArenaShell.PANEL_Y + 0.95, ArenaShell.PANEL_Z + 0.19),
			PI,
			0.0022
		)
	)
	compound.add_child(
		_sign("RangeMark", "76 m", Vector3(0.0, 0.35, -ArenaShell.HALF_Z + 1.2), 0.0, 0.0030)
	)

	var director: Node = (load(SCRIPT_DIRECTOR) as Script).new()
	director.name = "Director"
	director.set(&"cover_set", cover)
	director.set(&"perception_tuning", load(PERCEPTION_TUNING))
	director.set(&"role_doctrine", load(ROLE_DOCTRINE))
	root.add_child(director)

	var spawner_paths: Array[NodePath] = []
	for spawner: Node in _build_spawners(species, gate_specs):
		root.add_child(spawner)
		spawner_paths.append(NodePath(String(spawner.name)))

	var player: Node3D = _instance(PLAYER_SCENE, "Player") as Node3D
	player.position = ArenaShell.PLAYER_SPAWN
	player.add_child(_player_target())
	root.add_child(player)

	root.add_child(_instance(HUD_SCENE, "CombatHud"))

	var loadout: Node = (load(SCRIPT_LOADOUT) as Script).new()
	loadout.name = "Loadout"
	root.add_child(loadout)

	root.set(&"gate_paths", gates)
	root.set(&"spawner_paths", spawner_paths)
	root.set(&"patrol_anchors", _anchors())
	_own(root, root)
	return root


## Where a wave goes when it has nothing to shoot at. Each anchor is inside sight
## of the dais, so a body that walks to one has swept a lane on the way and can
## see the desk when it arrives. They are handed out in rotation, which is what
## spreads a wave instead of queueing it.
##
## NINETEEN OF THEM AND NOT TEN, because the cap is a hundred rather than
## twenty-four. Ten anchors and a hundred bodies is ten scrums of ten standing
## inside `_hold_post`'s 1.4 m arrival radius shoving each other, which is a crowd
## rather than a deployment; nineteen puts five on each. Handing them out without
## regard to faction is deliberate — interleaving three hostile factions across
## the same ring is what puts rivals inside each other's sight cones, and that is
## the whole mechanism behind "if they get too close to each other they fight
## each other". Two of them are the elevated ones, so the climb is still offered.
func _anchors() -> PackedVector3Array:
	return PackedVector3Array(
		[
			Vector3(-29.0, 0.0, -21.0),
			Vector3(-15.0, 0.0, -23.0),
			Vector3(1.0, 0.0, -23.0),
			Vector3(16.0, 0.0, -22.0),
			Vector3(29.0, 0.0, -20.0),
			Vector3(-29.0, 0.0, -8.0),
			Vector3(-18.0, 0.0, -5.0),
			Vector3(0.0, 0.0, -10.0),
			Vector3(14.0, 0.0, -9.0),
			Vector3(28.0, 0.0, -7.0),
			Vector3(-24.0, 0.0, 9.0),
			Vector3(-12.0, 0.0, 12.0),
			Vector3(-4.0, 0.0, 6.0),
			Vector3(8.0, 0.0, 10.0),
			Vector3(13.0, 0.0, 13.0),
			Vector3(22.0, 0.0, 5.0),
			Vector3(29.0, 0.0, 12.0),
			Vector3(ArenaShell.GANTRY_X, ArenaShell.GANTRY_Y, 2.0),
			Vector3(
				ArenaShell.PLATFORM_CENTER.x, ArenaShell.PLATFORM_Y, ArenaShell.PLATFORM_CENTER.z
			),
		]
	)


func _build_gate(node_name: String, at: Vector3, ry: float, half_w: float, height: float) -> Node3D:
	var gate: Node3D = (load(SCRIPT_GATE) as Script).new()
	gate.name = node_name
	gate.position = at
	gate.rotation = Vector3(0.0, ry, 0.0)
	# The leaf rises into the lintel. A portcullis is the only door that cannot be
	# blocked by whatever a wave has just piled up in front of it.
	gate.set(&"travel", Vector3(0.0, height + 0.25, 0.0))
	gate.set(&"seconds", 1.5)

	var leaf := StaticBody3D.new()
	leaf.name = "Leaf"
	leaf.collision_layer = GameLayers.WORLD
	leaf.collision_mask = 0
	var mesh: ArrayMesh = ArenaShell.gate_leaf(half_w, height, load(WORLD_MATERIAL) as Material)
	var mi := MeshInstance3D.new()
	mi.name = "Mesh"
	mi.mesh = mesh
	leaf.add_child(mi)
	var cs := CollisionShape3D.new()
	cs.name = "Shape"
	var box := BoxShape3D.new()
	box.size = Vector3(half_w * 2.0, height, 0.4)
	cs.shape = box
	cs.position = Vector3(0.0, height * 0.5, 0.0)
	leaf.add_child(cs)
	gate.add_child(leaf)

	var sound := AudioStreamPlayer3D.new()
	sound.name = "Sound"
	sound.unit_size = 6.0
	sound.max_distance = 90.0
	gate.add_child(sound)
	return gate


## The console's controls. Every one of them is a shipped diegetic scene, placed
## on the desk and turned to face the compound — the player's back is to the desk
## while the fight is on, and they turn round to change it.
func _build_station(species: AISpeciesProfileSet) -> Node3D:
	var station: Node3D = (load(SCRIPT_STATION) as Script).new()
	station.name = "Station"
	var ids: Array[StringName] = []
	var labels := PackedStringArray()
	for p: AISpeciesProfile in species.profiles:
		ids.append(p.species_id)
		labels.append(p.display_name.to_upper())
	station.set(&"species", ids)
	station.set(&"species_labels", labels)

	# Five knobs across a 10.2 m panel. The spacing is 1.5 m rather than the 1.7 the
	# four-dial desk used, which keeps the whole row inside the hood and leaves
	# 2.1 m of clear panel between the last knob and the 0.6 m readout — the dials
	# themselves are only 0.18 m across, so the gaps are for the eye and for a round
	# arriving from ten metres, not for the geometry.
	var dials: Array = [
		["SpeciesDial", -4.4, "SPECIES"],
		["FactionDial", -2.9, "FACTION"],
		["MixDial", -1.4, "MIX"],
		["CountDial", 0.1, "COUNT"],
		["AggressionDial", 1.6, "POSTURE"],
	]
	for entry: Array in dials:
		var dial: Node3D = _instance(DIAL_SCENE, entry[0]) as Node3D
		dial.position = Vector3(entry[1], ArenaShell.PANEL_Y, ArenaShell.PANEL_Z - 0.02)
		dial.rotation = Vector3(0.0, PI, 0.0)
		dial.set(&"control_id", StringName(entry[0]))
		dial.set(&"label_text", entry[2])
		station.add_child(dial)

	var levers: Array = [
		["SpawnLever", -1.2, "SPAWN", "READY", "GO"],
		["ClearLever", 0.0, "CLEAR", "HOLD", "WIPE"],
		["DebugLever", 1.2, "AI DEBUG", "OFF", "ON"],
	]
	for entry: Array in levers:
		var lever: Node3D = _instance(LEVER_SCENE, entry[0]) as Node3D
		lever.position = Vector3(entry[1], ArenaShell.DESK_TOP_Y - 0.03, ArenaShell.DESK_Z)
		lever.rotation = Vector3(0.0, PI, 0.0)
		lever.set(&"control_id", StringName(entry[0]))
		lever.set(&"label_text", entry[2])
		lever.set(&"off_text", entry[3])
		lever.set(&"on_text", entry[4])
		station.add_child(lever)

	var readout: Node3D = _instance(READOUT_SCENE, "Readout") as Node3D
	readout.position = Vector3(3.7, ArenaShell.PANEL_Y, ArenaShell.PANEL_Z - 0.02)
	readout.rotation = Vector3(0.0, PI, 0.0)
	station.add_child(readout)
	return station


## One spawner per faction, in faction order. `ArenaController.spawner_paths` is
## INDEXED BY FACTION ID, so the order this returns them in is load bearing.
##
## Three rather than one for two reasons, both measured. The ceiling:
## `EnemySpawner.capacity()` is `min(max_alive, GameSettings.max_enemies)` and the
## preset's figure is the binding half — 44 on the settings this project ships
## with — so one spawner cannot field a hundred bodies however high its own
## `max_alive` is set. And the pools: a spawner's `faction` is a property of the
## SPAWNER, written into every actor at instantiation, so one shared pool would
## hand a Choir wave bodies that were configured as Scavs a minute earlier and
## three factions would be drawing their species out of one free list.
## `tools/build_firefight.gd` reached the same arrangement for the same reason.
func _build_spawners(species: AISpeciesProfileSet, gate_specs: Array) -> Array[Node]:
	var ids: Array[StringName] = []
	for p: AISpeciesProfile in species.profiles:
		ids.append(p.species_id)
	var points: Array[NodePath] = []
	for spec: Array in gate_specs:
		points.append(NodePath("../Compound/%s" % spec[0]))
	var out: Array[Node] = []
	for f: int in FACTION_COUNT:
		var spawner: Node3D = (load(SCRIPT_SPAWNER) as Script).new()
		spawner.name = "Spawner%s" % FACTION_NAMES[f]
		spawner.set(&"species", ids)
		spawner.set(&"profiles", species)
		spawner.set(&"faction", f)
		spawner.set(&"max_alive", SPAWNER_MAX_ALIVE)
		spawner.set(&"pool_per_species", SPAWNER_POOL_PER_SPECIES)
		# Prewarming twelve species deep is hundreds of rigs before the first frame.
		# The arena spawns on demand, so it pays that cost when it is asked to.
		spawner.set(&"prewarm", false)
		spawner.set(&"auto_spawn", false)
		spawner.set(&"snap_to_navmesh", true)
		spawner.set(&"spread_radius", 1.1)
		spawner.set(&"yaw_jitter", 0.25)
		spawner.set(&"door_clearance", 2.2)
		spawner.set(&"spawn_points", points)
		# Each faction's scatter is its own stream, or three spawners seeded alike
		# put their first three bodies on the same square metre of doorway.
		spawner.set(&"seed_value", 1013 + f * 7919)
		out.append(spawner)
	return out


## The player has to be a target or nothing can see it. The prefab does not carry
## one, because the prefab does not know it is in a fight.
func _player_target() -> AITarget:
	var target := AITarget.new()
	target.name = "Target"
	target.faction = FACTION_PLAYER
	target.body_path = NodePath("..")
	target.receiver_path = NodePath("..")
	target.aim_offset = Vector3(0.0, 1.25, 0.0)
	target.eye_offset = Vector3(0.0, 1.62, 0.0)
	target.body_radius = 0.34
	return target


## Stencilled signage. The only text this demo puts in front of the player, and it
## is painted on steel that is standing in the world.
func _sign(node_name: String, text: String, at: Vector3, ry: float, pixel: float) -> Label3D:
	var label := Label3D.new()
	label.name = node_name
	label.text = text
	label.font = UiStyle.display_font()
	label.font_size = 64
	label.pixel_size = pixel
	label.position = at
	label.rotation = Vector3(0.0, ry, 0.0)
	label.modulate = Color("c2a86a")
	label.outline_size = 12
	label.outline_modulate = Color(0.055, 0.048, 0.042, 1.0)
	label.shaded = false
	label.double_sided = false
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	return label


## Instance a shipped scene under a fixed node name. Deliberately typed to `Node`:
## the world is a `WorldEnvironment` and the HUD a `CanvasLayer`, neither of which
## is a `Node3D`, and casting them to one silently produced null.
func _instance(path: String, node_name: String) -> Node:
	var packed: PackedScene = load(path) as PackedScene
	if packed == null:
		_fail("cannot load %s" % path)
		var stub := Node.new()
		stub.name = node_name
		return stub
	var node: Node = packed.instantiate()
	node.name = node_name
	return node


# =============================================================== plumbing


## `PackedScene.pack` keeps only what the root owns. Instanced sub-scenes keep
## their own internal ownership, so only nodes that have none are claimed.
func _own(node: Node, root: Node) -> void:
	for child: Node in node.get_children():
		if child.owner == null:
			child.owner = root
		_own(child, root)


func _count(node: Node) -> int:
	var n: int = 1
	for child: Node in node.get_children():
		n += _count(child)
	return n


func _save(res: Resource, path: String, label: String) -> void:
	var err: Error = ResourceSaver.save(res, path)
	if err != OK:
		_fail("%s -> %s (error %d)" % [label, path, err])
		return
	_report.append("ok    %-22s %s" % [label, path])


func _fail(message: String) -> void:
	_failed = true
	_report.append("FAIL  %s" % message)
	push_error("build_arena: %s" % message)


func _write_report() -> void:
	var text: String = "\n".join(_report) + "\n"
	var file: FileAccess = FileAccess.open(REPORT_PATH, FileAccess.WRITE)
	if file != null:
		file.store_string(text)
		file.close()
	print(text)
	print("build_arena: %s" % ("FAILED" if _failed else "PASS"))
