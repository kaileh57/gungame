extends SceneTree
## Acceptance harness for AI traversal: put bodies in a real level, give them
## goals on the roofs, and count how many actually get there.
##
## Run headless:
##   godot --headless --path <project> --script res://tools/verify_ai_traversal.gd
##
## Exits non-zero on a finding. Three things are asserted rather than reported:
##
##   1. A body that CAN climb reaches a roof goal, most of the time, in a sane
##      length of time.
##   2. A body that CANNOT climb reaches essentially none of them — the mobility
##      layers have to be real, not decorative. A quadruped that gets onto a roof
##      is as wrong as a scavenger that cannot.
##   3. Nothing ends up underground or in the air. A scripted crossing that hands
##      the motor back at the wrong moment shows up here and nowhere else.
##
## The bodies are real `CharacterBody3D`s with a gravity-and-`move_and_slide`
## motor of their own, because that is the thing `AITraversal` has to take away
## and give back. A kinematic marker would prove nothing about the handover.

## Where a routable roof goal was lost, worst first. A percentage on its own says
## the traversal does not work; this says which of five different things is
## broken, and they have nothing to do with each other.
enum Stage {
	## The corridor the agent was handed never routed through an off-mesh link at
	## all. A* is going the long way round, or there is no route in the set.
	NO_LINK_IN_CORRIDOR,
	## The corridor routed through a link and the body never got to its mouth.
	NEVER_REACHED_MOUTH,
	## The body stood at the mouth and never entered. The entry gate, the cooldown
	## or the owner lookup.
	NEVER_ENTERED,
	## The body crossed at least one link and still ran out of time.
	CROSSED_BUT_LOST,
	## Arrived.
	ARRIVED,
}

const NavIndex := preload("res://tools/nav_index.gd")

const REPORT_PATH: String = "res://data/ai/links/traversal_report.txt"

## `id`, scene, link set, and anything else the level needs under it.
##
## The town ships as buildings only — the ground it stands on is a separate
## scene. Without it the navmesh is there and the floor is not, and twenty-four
## bodies spend the run falling through the world: measured, 69,798 body-frames
## more than four metres off the mesh and not one goal reached.
const TARGETS: Array[Array] = [
	["arena", "res://demos/arena/arena.tscn", "res://data/ai/links/arena_links.res", ""],
	[
		"town",
		"res://data/world/town/town.tscn",
		"res://data/ai/links/town_links.res",
		"res://data/world/terrain/terrain.tscn"
	],
]

## Names for the trace, in `Stage` order.
const STAGE_NAMES: PackedStringArray = [
	"corridor had no link",
	"never reached the mouth",
	"stood at the mouth, never entered",
	"crossed, did not arrive",
	"arrived",
]

## Bodies per level. Half are given hands, half are not.
##
## The run is bound by the physics rate rather than by the agent count — the
## whole harness costs well under a millisecond of a 16 ms tick — so bodies are
## nearly free and each one is another independent sample. Forty is what makes
## the town's routable count large enough for a percentage to mean anything.
const AGENTS: int = 40
## Physics frames a level gets to settle before the bodies go in.
const SETTLE_FRAMES: int = 40
## Seconds a goal is allowed on top of the walk to it. This is the part of the
## budget that is about traversal rather than about distance: get to the mouth,
## climb it, top out, and cross the roof to the goal.
const GOAL_OVERHEAD: float = 20.0
## Metres a second a body is expected to make good in a straight line towards its
## goal. Deliberately well under the 3.6 m/s top speed, because a corridor is not
## a straight line and a climb is not a walk. Measured: bodies hold 3.24 m/s of
## ground speed and arrive at a nineteen-metre goal in a median of 1.7 s, so this
## is about a factor of two of slack — which is what a timeout is for.
##
## The pair is set from the arrival times of goals that SUCCEED, which is the
## only defensible way to set a timeout: measured, the slowest arrival across
## both levels was 40.4 s and the medians were 4.1 s and 18.9 s. A budget that
## does not clear the tail of the successes is not a timeout, it is a race, and
## it decides the result instead of measuring it.
const GOAL_PACE: float = 1.4
## Ceiling on one goal, so a single unlucky draw cannot eat a body's whole run.
const GOAL_TIMEOUT_MAX: float = 55.0
## Metres from the body a roof goal is drawn within.
##
## NOT COSMETIC. Drawn uniformly over the whole navmesh, the median town goal was
## 146 metres away and the median body walked 94 metres at it before the clock
## ran out — the harness was measuring how big the town is, not whether anything
## climbs. A body picks a roof it can use; this is that radius.
const GOAL_RADIUS: float = 55.0
## Simulated seconds the whole run lasts per level.
const RUN_SECONDS: float = 70.0
## Fixed step, so times are per simulated second rather than per headless frame.
const STEP: float = 1.0 / 60.0
## Metres from the goal, IN PLAN, that counts as arrived.
const ARRIVE_RADIUS: float = 2.6
## Metres of height difference allowed at an arrival.
##
## WITHOUT A SEPARATE HEIGHT TEST THE HARNESS MARKS ITS OWN ANSWER WRONG.
## `ARRIVE_RADIUS` used to be a 3D distance, and it is larger than `ROOF_RISE` —
## so a body standing in the street directly under the shallowest kind of roof
## goal was inside it and was scored as having got up there. The routability
## query had the same hole, which is how bodies with no hands came to be credited
## with nine routable roof goals in an arena whose own link bake reports zero
## walk-only roof access.
const ARRIVE_HEIGHT: float = 1.2
## Metres a roof has to stand above the ground under it to count as a roof.
const ROOF_RISE: float = 2.5
## Metres off the walkable surface before a body counts as off the mesh.
const MESH_GAP: float = 4.0
## Seconds a body may be that far ABOVE the mesh before it is a finding. A body
## that walks off a six-metre roof is in the air for about 0.7 s and that is the
## motor doing its job; one that is still there after this was put in the air by
## something that should have put it on the ground.
const MESH_AIR_GRACE: float = 1.5
## Fraction of roof goals a climbing body must reach for the run to pass.
const MIN_CLIMBER_SUCCESS: float = 0.55
## Fraction of roof goals a body without hands may reach before it is a bug.
const MAX_WALKER_SUCCESS: float = 0.12


## A body with a motor, so the traversal has something real to take away.
class TestBody:
	extends CharacterBody3D

	var alive: bool = true
	var want_dir: Vector3 = Vector3.ZERO
	var want_speed: float = 0.0
	var top_speed: float = 3.6

	func _physics_process(delta: float) -> void:
		var want: Vector3 = want_dir * want_speed
		velocity.x = lerpf(velocity.x, want.x, clampf(9.0 * delta, 0.0, 1.0))
		velocity.z = lerpf(velocity.z, want.z, clampf(9.0 * delta, 0.0, 1.0))
		if is_on_floor():
			velocity.y = minf(velocity.y, 0.0)
		else:
			velocity.y -= 22.0 * delta
		move_and_slide()

	func steer(dir: Vector3, speed: float) -> void:
		want_dir = Vector3(dir.x, 0.0, dir.z).normalized()
		want_speed = speed

	func halt() -> void:
		want_dir = Vector3.ZERO
		want_speed = 0.0


var _root: Node3D = null
var _scene: Node = null
var _ground: Node = null
var _service: AIPathService = null
var _index: NavIndex = null
var _bodies: Array[TestBody] = []
var _navs: Array[AINavigator] = []
var _climber: PackedByteArray = PackedByteArray()
var _goal: PackedVector3Array = PackedVector3Array()
var _elapsed: PackedFloat32Array = PackedFloat32Array()
var _rng: XorShift32 = null
var _map: RID = RID()
var _report: PackedStringArray = PackedStringArray()
var _crossed: PackedInt32Array = PackedInt32Array()
var _tries: PackedInt32Array = PackedInt32Array()
var _wins: PackedInt32Array = PackedInt32Array()
var _routable: PackedInt32Array = PackedInt32Array()
## Goals reached that the agent's own layer mask said were not routable. For a
## body without hands this is the whole mobility contract: it may walk to a roof
## the navmesh joins to the street, and it may not get onto one it cannot.
var _cheated: PackedInt32Array = PackedInt32Array()
var _masks: PackedInt32Array = PackedInt32Array()
## Per-agent trace of the goal currently in flight. Reset by `_finish_goal`.
var _was_routable: PackedByteArray = PackedByteArray()
var _saw_link: PackedByteArray = PackedByteArray()
var _at_mouth: PackedByteArray = PackedByteArray()
var _nearest_mouth: PackedFloat32Array = PackedFloat32Array()
var _cross_mark: PackedInt32Array = PackedInt32Array()
## One bucket per `STAGE_*`, counting routable roof goals given to climbers.
var _stage: PackedInt32Array = PackedInt32Array()
## Closest a body came to a link mouth on a goal it then lost at that mouth.
var _mouth_gaps: PackedFloat32Array = PackedFloat32Array()
## Per lost goal: closest the body came in 3D, closest it came in plan, and how
## far it walked. Three numbers that separate "wedged", "walked to the wrong
## place" and "stood underneath the roof it was sent to".
var _lost_near: PackedFloat32Array = PackedFloat32Array()
var _lost_flat: PackedFloat32Array = PackedFloat32Array()
var _lost_walk: PackedFloat32Array = PackedFloat32Array()
var _lost_start: PackedFloat32Array = PackedFloat32Array()
var _start_gap: PackedFloat32Array = PackedFloat32Array()
var _near: PackedFloat32Array = PackedFloat32Array()
var _flat: PackedFloat32Array = PackedFloat32Array()
var _walked: PackedFloat32Array = PackedFloat32Array()
var _prev: PackedVector3Array = PackedVector3Array()
## Seconds each body has been continuously more than `MESH_GAP` above the mesh.
var _air: PackedFloat32Array = PackedFloat32Array()
## Body-frames with no steering direction at all, body-frames where the agent
## believed it had finished, and recovery detours spent.
var _halt_frames: int = 0
var _done_frames: int = 0
var _unreachable_frames: int = 0
var _body_frames: int = 0
var _unsticks: int = 0
## Ground speed actually achieved, and the two multipliers between top speed and
## it: the turn penalty and the avoidance solver.
var _speed_sum: float = 0.0
var _scale_sum: float = 0.0
var _avoid_sum: float = 0.0
var _move_frames: int = 0
var _times: PackedFloat32Array = PackedFloat32Array()
var _cost_us: PackedFloat32Array = PackedFloat32Array()
var _target: int = 0
var _phase: int = 0
var _wait: int = 0
var _boot: int = 0
var _clock: float = 0.0
var _failures: int = 0
var _under: int = 0
var _stranded: int = 0
var _under_who: PackedByteArray = PackedByteArray()
var _stranded_who: PackedByteArray = PackedByteArray()


## THE WHOLE HARNESS RUNS OFF PHYSICS, and it has to.
##
## `SceneTree._process` is called once per main-loop iteration and
## `_physics_process` once per physics tick, and headless those two rates are
## nothing like each other: with no vsync and nothing to draw the loop spins as
## fast as the machine will go while physics stays pinned to its 60 Hz of REAL
## time. Ticked from `_process`, this harness advanced its own clock by 1/60 s
## per iteration, gave every goal 32 of those "seconds", and moved the bodies
## through `move_and_slide` only when a physics tick happened to land — measured
## on this machine at a ratio of 2.4 to 1. Every body was therefore given about
## thirteen real seconds to walk forty metres and then failed for it, and the
## number the gate printed depended on how fast the computer was.
##
## `SceneTree::physics_process` calls this before it propagates `_physics_process`
## to the nodes, so the order within a tick is: think, serve the path queue, step
## the crossings, then move the bodies. That is the same order the game runs in.
func _physics_process(_delta: float) -> bool:
	_boot += 1
	if _boot < 2:
		return false
	if _boot == 2:
		Engine.physics_ticks_per_second = int(round(1.0 / STEP))
		_rng = XorShift32.new(20260731)
		_root = Node3D.new()
		get_root().add_child(_root)
		_report.push_back("AI TRAVERSAL")
		_report.push_back("")
		return false
	if _wait > 0:
		_wait -= 1
		return false
	if _target >= TARGETS.size():
		_finish()
		return true
	match _phase:
		0:
			_load_level()
		1:
			_spawn()
		2:
			_run_frame()
		_:
			_teardown()
	return false


func _load_level() -> void:
	var path: String = TARGETS[_target][1]
	var packed: PackedScene = ResourceLoader.load(path) as PackedScene
	if packed == null:
		_report.push_back("%-10s FAILED to load %s" % [TARGETS[_target][0], path])
		_failures += 1
		_phase = 3
		return
	_scene = packed.instantiate()
	_root.add_child(_scene)
	var extra: String = TARGETS[_target][3]
	if not extra.is_empty() and ResourceLoader.exists(extra):
		var ground: PackedScene = ResourceLoader.load(extra) as PackedScene
		if ground != null:
			_ground = ground.instantiate()
			_root.add_child(_ground)
	_phase = 1
	_wait = SETTLE_FRAMES


func _spawn() -> void:
	var id: String = TARGETS[_target][0]
	var link_path: String = TARGETS[_target][2]
	var region: NavigationRegion3D = _find_region(_scene)
	if region == null or region.navigation_mesh == null:
		_report.push_back("%-10s no navmesh" % id)
		_failures += 1
		_phase = 3
		return
	_index = NavIndex.new()
	_index.build(region.navigation_mesh, region.global_transform)
	_map = region.get_navigation_map()
	NavigationServer3D.map_force_update(_map)

	_service = AIPathService.new()
	_service.name = "Paths"
	_service.link_set_path = link_path
	_root.add_child(_service)
	_service.link_crossed.connect(_on_link_crossed)

	_crossed = PackedInt32Array()
	_crossed.resize(AILinkBaker.Kind.size())
	_tries = PackedInt32Array([0, 0])
	_wins = PackedInt32Array([0, 0])
	_routable = PackedInt32Array([0, 0])
	_cheated = PackedInt32Array([0, 0])
	_masks = PackedInt32Array()
	_times = PackedFloat32Array()
	_cost_us = PackedFloat32Array()
	_was_routable = PackedByteArray()
	_saw_link = PackedByteArray()
	_at_mouth = PackedByteArray()
	_nearest_mouth = PackedFloat32Array()
	_cross_mark = PackedInt32Array()
	_stage = PackedInt32Array()
	_stage.resize(Stage.size())
	_mouth_gaps = PackedFloat32Array()
	_lost_near = PackedFloat32Array()
	_lost_flat = PackedFloat32Array()
	_lost_walk = PackedFloat32Array()
	_lost_start = PackedFloat32Array()
	_start_gap = PackedFloat32Array()
	_near = PackedFloat32Array()
	_flat = PackedFloat32Array()
	_walked = PackedFloat32Array()
	_prev = PackedVector3Array()
	_air = PackedFloat32Array()
	_start_gap = PackedFloat32Array()
	_halt_frames = 0
	_done_frames = 0
	_unreachable_frames = 0
	_body_frames = 0
	_unsticks = 0
	_speed_sum = 0.0
	_scale_sum = 0.0
	_avoid_sum = 0.0
	_move_frames = 0
	_under = 0
	_stranded = 0
	_under_who = PackedByteArray()
	_under_who.resize(AGENTS)
	_stranded_who = PackedByteArray()
	_stranded_who.resize(AGENTS)
	_clock = 0.0

	for i: int in AGENTS:
		var climbs: bool = i % 2 == 0
		var body := TestBody.new()
		body.collision_layer = GameLayers.ENEMY
		body.collision_mask = GameLayers.WORLD | GameLayers.PROP
		var shape := CollisionShape3D.new()
		var capsule := CapsuleShape3D.new()
		capsule.radius = 0.4
		capsule.height = 1.8
		shape.shape = capsule
		shape.position = Vector3(0.0, 0.9, 0.0)
		body.add_child(shape)
		_root.add_child(body)
		body.global_position = _ground_point() + Vector3(0.0, 0.2, 0.0)

		var agent := NavigationAgent3D.new()
		body.add_child(agent)
		var profile := AISpeciesProfile.new()
		profile.body_radius = 0.4
		profile.height = 1.8
		profile.run_speed = 3.6
		profile.mobility_auto = false
		profile.can_climb = climbs
		profile.can_vault = climbs
		profile.can_mantle = climbs
		profile.drop_height = 3.4 if climbs else 1.2
		profile.jump_gap = 2.4 if climbs else 0.0
		var nav := AINavigator.new()
		nav.setup(agent, profile, true)
		nav.trace_links = true
		_service.register(i, nav)
		_bodies.append(body)
		_navs.append(nav)
		_climber.append(1 if climbs else 0)
		_masks.append(profile.navigation_layer_mask())
		_goal.append(_roof_point(body.global_position))
		_elapsed.append(0.0)
		_was_routable.append(0)
		_saw_link.append(0)
		_at_mouth.append(0)
		_nearest_mouth.append(INF)
		_cross_mark.append(0)
		_near.append(INF)
		_flat.append(INF)
		_walked.append(0.0)
		_prev.append(body.global_position)
		_air.append(0.0)
		_start_gap.append(body.global_position.distance_to(_goal[i]))
		_count_goal(i)
		nav.set_goal(_goal[i], true)
	_report.push_back(
		(
			"%-10s %d links installed, %d bodies (%d with hands)"
			% [id, _service.link_count(), AGENTS, AGENTS / 2]
		)
	)
	_phase = 2


func _run_frame() -> void:
	var t0: int = Time.get_ticks_usec()
	_clock += STEP
	for i: int in AGENTS:
		_tick_agent(i)
	_service.service(STEP)
	_cost_us.append(float(Time.get_ticks_usec() - t0))
	if _clock >= RUN_SECONDS:
		_score()
		_phase = 3


func _tick_agent(i: int) -> void:
	var body: TestBody = _bodies[i]
	var nav: AINavigator = _navs[i]
	var here: Vector3 = body.global_position
	nav.advance(STEP, here)
	_elapsed[i] += STEP

	if _arrived(here, _goal[i]):
		_wins[_climber[i]] += 1
		if _was_routable[i] == 0:
			_cheated[_climber[i]] += 1
		_times.append(_elapsed[i])
		_new_goal(i, true)
		return
	if _elapsed[i] >= _budget(i):
		_new_goal(i, false)
		return
	# A body that has fallen through the world, or is standing on nothing, is the
	# failure a scripted crossing causes when it hands the motor back badly.
	# Mid-crossing it is legitimately in the air — halfway up a ten-metre ladder is
	# five metres from anything walkable — so the check only runs on a body the
	# motor owns.
	if not nav.traverse.is_running():
		# MEASURED AGAINST THE LEVEL, NOT AGAINST THE POLYGON UNDERFOOT. The
		# obvious test — compare the body's height to the walkable surface at its
		# own (x, z) — cannot be made to work, because navmesh coverage is holey
		# by construction: Recast erodes it by an agent radius from every wall, so
		# a body standing legitimately in a street a few centimetres from a
		# building sits at an (x, z) whose only walkable surface is the roof six
		# metres above it. Measured two ways, against the nearest surface and
		# against the whole stack, and both read hundreds of frames of bodies
		# standing in town streets as bodies six metres underground.
		#
		# Below the lowest navmesh vertex in the entire level has no such reading.
		# It is the failure this harness was built to catch — twenty-four bodies
		# falling through a town whose ground scene was not loaded — and nothing
		# else puts a body there.
		if here.y < _index.bounds.position.y - MESH_GAP:
			_under += 1
			_under_who[i] = 1
			_air[i] = 0.0
		elif here.y > _index.bounds.end.y + MESH_GAP:
			# Above every walkable surface in the level. Transiently that is a body
			# that has walked off a roof and is falling, which is the motor doing
			# its job. Held for longer than a fall takes, it is a crossing that
			# handed the motor back in mid-air.
			_air[i] += STEP
			if _air[i] > MESH_AIR_GRACE:
				_stranded += 1
				_stranded_who[i] = 1
		else:
			_air[i] = 0.0

	if nav.is_stuck():
		nav.unstick(_rng)
		_unsticks += 1
	else:
		nav.set_goal(_goal[i])
	if nav.wants_path(false):
		_service.submit(i, nav.path_urgency())
	# Climbers only. Half the population has no hands and its roof goals are
	# unreachable by design, so a population-wide average of these is 50% noise.
	if _climber[i] != 0:
		_body_frames += 1
		if nav.is_finished():
			_done_frames += 1
		if not nav.is_reachable():
			_unreachable_frames += 1
	var dir: Vector3 = nav.steer_direction(here)
	if dir.length_squared() <= 1e-6:
		if _climber[i] != 0:
			_halt_frames += 1
		_trace(i, here)
		body.halt()
		return
	var facing: Vector3 = body.global_transform.basis.z
	var scale: float = nav.speed_scale(facing, dir)
	var wanted: Vector3 = dir * body.top_speed * scale
	var safe: Vector3 = nav.avoid(wanted)
	if safe.length_squared() < 1e-6:
		safe = wanted
	if _climber[i] != 0 and not nav.traverse.is_running():
		_move_frames += 1
		_scale_sum += scale
		_avoid_sum += safe.length() / maxf(wanted.length(), 1e-3)
		_speed_sum += Vector2(body.velocity.x, body.velocity.z).length()
	body.steer(safe, safe.length())
	if not nav.traverse.is_running():
		body.rotation.y = rotate_toward(body.rotation.y, atan2(dir.x, dir.z), 6.0 * STEP)
	_trace(i, here)


## Sample where this agent is in the chain that ends on a roof: was it offered a
## corridor through a link, did it get to the mouth, did it get in.
##
## Sampled after the steering, because the steering is what advances the agent's
## path index and what tries the entry.
func _trace(i: int, here: Vector3) -> void:
	var nav: AINavigator = _navs[i]
	if nav.trace_corridor_link:
		_saw_link[i] = 1
	var d: float = nav.trace_mouth_gap
	if d < _nearest_mouth[i]:
		_nearest_mouth[i] = d
	if d <= nav.trace_entry_reach:
		_at_mouth[i] = 1
	var g: Vector3 = _goal[i]
	_near[i] = minf(_near[i], here.distance_to(g))
	_flat[i] = minf(_flat[i], Vector2(here.x - g.x, here.z - g.z).length())
	_walked[i] += Vector2(here.x - _prev[i].x, here.z - _prev[i].z).length()
	_prev[i] = here


func _new_goal(i: int, reached: bool) -> void:
	_bucket(i, reached)
	_elapsed[i] = 0.0
	_saw_link[i] = 0
	_at_mouth[i] = 0
	_nearest_mouth[i] = INF
	_near[i] = INF
	_flat[i] = INF
	_walked[i] = 0.0
	_prev[i] = _bodies[i].global_position
	_cross_mark[i] = _navs[i].links_crossed
	_goal[i] = _roof_point(_prev[i])
	_start_gap[i] = _prev[i].distance_to(_goal[i])
	_count_goal(i)
	_navs[i].set_goal(_goal[i], true)


## File the goal that just ended under the furthest stage it got to. Only a
## climber's routable goals are counted: the pass bar is measured against those
## and nothing else, so the trace has to be measured against the same set or it
## explains a different number from the one that failed.
func _bucket(i: int, reached: bool) -> void:
	if _climber[i] == 0 or _was_routable[i] == 0:
		return
	# Only a goal that ran its full timeout says anything about how far a body got.
	# One cut off by the end of the run has had an arbitrary slice of a chance, and
	# there is one of those per body — enough to swing a median on its own.
	if not reached and _elapsed[i] >= _budget(i):
		_lost_near.append(_near[i])
		_lost_flat.append(_flat[i])
		_lost_walk.append(_walked[i])
		_lost_start.append(_start_gap[i])
	if reached:
		_stage[Stage.ARRIVED] += 1
	elif _navs[i].links_crossed > _cross_mark[i]:
		_stage[Stage.CROSSED_BUT_LOST] += 1
	elif _at_mouth[i] != 0:
		_stage[Stage.NEVER_ENTERED] += 1
	elif _saw_link[i] != 0:
		_stage[Stage.NEVER_REACHED_MOUTH] += 1
		if is_finite(_nearest_mouth[i]):
			_mouth_gaps.append(_nearest_mouth[i])
	else:
		_stage[Stage.NO_LINK_IN_CORRIDOR] += 1


## Book one goal, and record whether a route to it exists at all under this
## body's own mobility.
##
## Success has to be measured against what is REACHABLE, not against what was
## asked for. Half the bodies in this run have no hands and cannot be expected to
## reach a roof; a roof with no route to it is not a failure of the AI either. The
## question the harness answers is "given a route, does the body walk it".
func _count_goal(i: int) -> void:
	var c: int = _climber[i]
	_tries[c] += 1
	var params := NavigationPathQueryParameters3D.new()
	params.map = _map
	params.start_position = _bodies[i].global_position
	params.target_position = _goal[i]
	params.navigation_layers = _masks[i]
	var result := NavigationPathQueryResult3D.new()
	NavigationServer3D.query_path(params, result)
	var path: PackedVector3Array = result.path
	var ok: bool = path.size() >= 2 and _arrived(path[path.size() - 1], _goal[i])
	_was_routable[i] = 1 if ok else 0
	if ok:
		_routable[c] += 1


## A point on the lowest walkable surface of its stack: a street, not a roof.
func _ground_point() -> Vector3:
	var box: AABB = _index.bounds
	for _try: int in 400:
		var x: float = _rng.next_range(box.position.x, box.end.x)
		var z: float = _rng.next_range(box.position.z, box.end.z)
		var stack: PackedFloat32Array = _index.stack_at(x, z)
		if not stack.is_empty():
			return Vector3(x, stack[0], z)
	return box.get_center()


## Seconds this agent's current goal is allowed, from how far away it was drawn.
##
## A fixed timeout measures the map, not the AI: thirty-two seconds is four times
## what an arena goal needs and two thirds of what a town goal needs, so the same
## number gates two completely different questions.
func _budget(i: int) -> float:
	return minf(GOAL_OVERHEAD + _start_gap[i] / GOAL_PACE, GOAL_TIMEOUT_MAX)


## A point on a surface with another walkable surface well below it — a roof —
## within `GOAL_RADIUS` of `from`.
func _roof_point(from: Vector3) -> Vector3:
	var box: AABB = _index.bounds
	var lo := Vector2(
		maxf(box.position.x, from.x - GOAL_RADIUS), maxf(box.position.z, from.z - GOAL_RADIUS)
	)
	var hi := Vector2(minf(box.end.x, from.x + GOAL_RADIUS), minf(box.end.z, from.z + GOAL_RADIUS))
	for _try: int in 2000:
		var x: float = _rng.next_range(lo.x, hi.x)
		var z: float = _rng.next_range(lo.y, hi.y)
		var stack: PackedFloat32Array = _index.stack_at(x, z)
		var top: int = stack.size() - 1
		if top >= 1 and stack[top] - stack[0] >= ROOF_RISE:
			return Vector3(x, stack[top], z)
	return _ground_point()


func _score() -> void:
	# The goal each body still had in flight when the clock ran out was booked by
	# `_count_goal` and never filed, so file it as lost. Without this the trace
	# explains fewer goals than the percentage above it was measured over.
	for i: int in AGENTS:
		_bucket(i, false)
	var id: String = TARGETS[_target][0]
	# Denominator is every goal that DEMONSTRABLY had a route: one the pre-flight
	# query found, or one the body went and walked. The pre-flight query is asked
	# once, from wherever the body happens to be standing when the goal is booked,
	# and on a 29,942-polygon town it runs out of search budget from some of those
	# positions and not from others — so on its own it is a lower bound, and a
	# body that arrives at a goal it said was unroutable has disproved it.
	var climb_rate: float = float(_wins[1]) / float(maxi(_routable[1] + _cheated[1], 1))
	var walk_rate: float = float(_wins[0]) / float(maxi(_routable[0] + _cheated[0], 1))
	var sorted: Array = Array(_times)
	sorted.sort()
	var mean: float = 0.0
	for t: float in _times:
		mean += t
	mean /= float(maxi(_times.size(), 1))
	var kinds := PackedStringArray()
	for k: int in AILinkBaker.Kind.size():
		if _crossed[k] > 0:
			kinds.push_back("%d %s" % [_crossed[k], AILinkBaker.kind_name(k)])
	var cost: Array = Array(_cost_us)
	cost.sort()
	_report.push_back(
		(
			"           with hands  %d goals, %d had a route, %d reached (%.0f%% of routable)"
			% [_tries[1], _routable[1] + _cheated[1], _wins[1], climb_rate * 100.0]
		)
	)
	_report.push_back(
		(
			"           no hands    %d goals, %d had a route, %d reached (%.0f%% of routable)"
			% [_tries[0], _routable[0] + _cheated[0], _wins[0], walk_rate * 100.0]
		)
	)
	_report.push_back(
		(
			"           time to arrive: mean %.1f s, median %.1f s, worst %.1f s over %d arrivals"
			% [
				mean,
				float(sorted[sorted.size() / 2]) if not sorted.is_empty() else 0.0,
				float(sorted[sorted.size() - 1]) if not sorted.is_empty() else 0.0,
				_times.size()
			]
		)
	)
	var begun: int = 0
	for nav: AINavigator in _navs:
		begun += nav.links_crossed
	_report.push_back(
		(
			"           crossings started %d, completed %s"
			% [begun, "none" if kinds.is_empty() else ", ".join(kinds)]
		)
	)
	_report.push_back(
		(
			"           ai cost %d bodies: mean %.3f ms, p95 %.3f ms, max %.3f ms"
			% [
				AGENTS,
				float(cost[cost.size() / 2]) / 1000.0,
				float(cost[int(float(cost.size()) * 0.95)]) / 1000.0,
				float(cost[cost.size() - 1]) / 1000.0
			]
		)
	)
	var filed: int = 0
	for n: int in _stage:
		filed += n
	for s: int in Stage.size():
		if _stage[s] == 0:
			continue
		_report.push_back(
			(
				"             %-34s %4d (%3.0f%%)"
				% [STAGE_NAMES[s], _stage[s], 100.0 * float(_stage[s]) / float(maxi(filed, 1))]
			)
		)
	if not _mouth_gaps.is_empty():
		var gaps: Array = Array(_mouth_gaps)
		gaps.sort()
		(
			_report
			. push_back(
				(
					"           closest approach on those: min %.2f m, median %.2f m, worst %.2f m"
					% [
						float(gaps[0]),
						float(gaps[gaps.size() / 2]),
						float(gaps[gaps.size() - 1]),
					]
				)
			)
		)
	if not _lost_near.is_empty():
		_report.push_back(
			(
				(
					"           timed out on %d goals: started %.0f m out,"
					+ " closed to %.0f m (%.0f m in plan), walked %.0f m"
				)
				% [
					_lost_near.size(),
					_median(_lost_start),
					_median(_lost_near),
					_median(_lost_flat),
					_median(_lost_walk)
				]
			)
		)
	var bf: float = float(maxi(_body_frames, 1))
	_report.push_back(
		(
			(
				"           body-frames: %.0f%% steering nowhere, %.0f%% agent says"
				+ " finished, %.0f%% target unreachable, %d detours"
			)
			% [
				100.0 * float(_halt_frames) / bf,
				100.0 * float(_done_frames) / bf,
				100.0 * float(_unreachable_frames) / bf,
				_unsticks
			]
		)
	)
	var mf: float = float(maxi(_move_frames, 1))
	_report.push_back(
		(
			"           climber speed %.2f m/s of %.2f top: turn penalty x%.2f, avoidance x%.2f"
			% [_speed_sum / mf, 3.6, _scale_sum / mf, _avoid_sum / mf]
		)
	)
	var refused_hold: int = 0
	var refused_reach: int = 0
	var refused_owner: int = 0
	for nav: AINavigator in _navs:
		refused_hold += nav.link_refused_cooldown
		refused_reach += nav.link_refused_reach
		refused_owner += nav.link_refused_owner
	_report.push_back(
		(
			"           entries refused: %d on the cooldown, %d out of reach, %d no owner"
			% [refused_hold, refused_reach, refused_owner]
		)
	)
	var under_n: int = 0
	var stranded_n: int = 0
	for b: int in _under_who:
		under_n += b
	for b: int in _stranded_who:
		stranded_n += b
	(
		_report
		. push_back(
			(
				"           off the mesh: %d frames under it (%d bodies), %d stranded above it (%d bodies)"
				% [_under, under_n, _stranded, stranded_n]
			)
		)
	)
	if _routable[1] + _cheated[1] > 0 and climb_rate < MIN_CLIMBER_SUCCESS:
		_report.push_back(
			(
				"           FAIL: climbers reached %.0f%% of routable roof goals, wanted %.0f%%"
				% [climb_rate * 100.0, MIN_CLIMBER_SUCCESS * 100.0]
			)
		)
		_failures += 1
	_report.push_back(
		"           reached without a route: %d with hands, %d without" % [_cheated[1], _cheated[0]]
	)
	if float(_cheated[0]) > MAX_WALKER_SUCCESS * float(maxi(_tries[0], 1)):
		_report.push_back(
			(
				(
					"           FAIL: %d of %d roof goals were reached by a body whose"
					+ " own layer mask said there was no route"
				)
				% [_cheated[0], _tries[0]]
			)
		)
		_failures += 1
	if _under + _stranded > 0:
		_report.push_back("           FAIL: a body left the navigation mesh vertically")
		_failures += 1
	_report.push_back("")


## Whether `p` counts as standing on `goal`. Plan distance and height are two
## separate tests on purpose — see `ARRIVE_HEIGHT`.
static func _arrived(p: Vector3, goal: Vector3) -> bool:
	if absf(p.y - goal.y) > ARRIVE_HEIGHT:
		return false
	return Vector2(p.x - goal.x, p.z - goal.z).length() <= ARRIVE_RADIUS


static func _median(values: PackedFloat32Array) -> float:
	if values.is_empty():
		return 0.0
	var sorted: Array = Array(values)
	sorted.sort()
	return float(sorted[sorted.size() / 2])


func _teardown() -> void:
	for nav: AINavigator in _navs:
		nav.stop()
	_navs.clear()
	for body: TestBody in _bodies:
		body.queue_free()
	_bodies.clear()
	_climber = PackedByteArray()
	_goal = PackedVector3Array()
	_elapsed = PackedFloat32Array()
	_was_routable = PackedByteArray()
	_saw_link = PackedByteArray()
	_at_mouth = PackedByteArray()
	_nearest_mouth = PackedFloat32Array()
	_cross_mark = PackedInt32Array()
	if _service != null:
		_service.flush()
		_service.queue_free()
		_service = null
	if _scene != null:
		_scene.queue_free()
		_scene = null
	if _ground != null:
		_ground.queue_free()
		_ground = null
	_index = null
	_target += 1
	_phase = 0
	_wait = 6


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


func _on_link_crossed(_agent_id: int, kind: int) -> void:
	if kind >= 0 and kind < _crossed.size():
		_crossed[kind] += 1


func _find_region(node: Node) -> NavigationRegion3D:
	var region := node as NavigationRegion3D
	if region != null and region.navigation_mesh != null:
		return region
	for child: Node in node.get_children():
		var found: NavigationRegion3D = _find_region(child)
		if found != null:
			return found
	return null
