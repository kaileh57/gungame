class_name AINavigator
extends RefCounted
## Path following, local avoidance and off-mesh traversal for one agent, with the
## path requests put on a budget.
##
## `NavigationAgent3D.target_position` is a setter that kicks off a path query the
## moment you write it, so the only way to stop sixty agents from re-pathing every
## frame is to not write it. A goal set here is held as *pending* until the
## director hands out a path slot, and pending goals that are barely different
## from the current one are dropped outright. In practice an engaged agent
## re-paths about twice a second and a patrolling one about once every two.
##
## Local avoidance is the navigation server's RVO, which is the right place for
## it: sixty agents avoiding each other on the server's own threads costs nothing
## in GDScript, and it is what keeps a squad from walking through itself in a
## doorway.
##
## Steering aims at a point some distance *down* the corridor rather than at the
## next corner, which is what stops an agent nailing itself to every waypoint and
## walking a visible dogleg. Speed is then scaled by how far it has to turn, so a
## hard corner is taken slowly instead of being pivoted on the spot.
##
## TRAVERSAL. Ladders, drops, vaults and jumps are baked `NavigationLink3D`s
## (see `AILinkBaker`), so the corridor search routes through them without this
## class doing anything at all. What this class does is notice — the agent emits
## `link_reached` when it arrives at a link's entry — and hand the body to
## `AITraversal`, which takes the motor off it and plays the crossing. Which links
## an agent is *allowed* to route through is a navigation layer mask taken from
## its species, so a quadruped's search never even sees the ladder.
##
## The tunables below are plain vars rather than `@export`s because this is a
## RefCounted owned by an agent, not a node. `AIPathService` carries the exported
## copies and stamps them onto every navigator it registers — one set of knobs in
## the inspector, applied to the whole population.

## Detour headings are drawn from this many evenly spaced sidesteps, alternating
## left and right, so a wedged agent probes both walls before giving up.
const DETOUR_BACKOFF: float = 0.35
## Preloaded rather than named. `AITraversal` is constructed in this class's
## member initialiser, and a global class name is only bound once its script has
## finished loading — during a scene's first frames it can still resolve to null,
## which shows up as `Nonexistent function 'is_running' in base 'Nil'` on the
## first few agents a director builds and on nobody after. `preload` makes the
## dependency part of this script's own load.
const Traversal := preload("res://systems/ai/ai_traversal.gd")

## Metres the goal must move before a re-path is worth asking for.
var repath_tolerance: float = 1.1
## Seconds between re-paths even when the goal has not moved. Covers doors
## opening, a region rebaking, and paths that were stale when they were built.
var repath_interval: float = 1.6
## Seconds between re-paths while actually fighting. Contacts move.
var combat_repath_interval: float = 0.55
## Metres down the corridor the steering target sits. Roughly one stride and a
## half; larger cuts corners harder and clips walls.
var look_ahead: float = 2.2
## Blend between the exact next waypoint (0) and the look-ahead point (1).
var corner_cut: float = 0.55
## Exponent on the cosine of the heading error when scaling speed. Higher means
## a sharper slow-down into turns.
var turn_sharpness: float = 1.4
## Floor on the speed scale, so a turning agent still creeps forward.
var min_speed_fraction: float = 0.25
## Below this ground speed the agent counts as making no progress.
var stuck_speed: float = 0.35
## Seconds of no progress before the agent is declared stuck.
var stuck_time: float = 0.9
## Base sidestep distance for a recovery detour. Escalates with repeat offences.
var detour_distance: float = 2.4
## Seconds a recovery detour is held before the real goal is restored.
var detour_time: float = 1.4
## Metres of neighbourhood the avoidance solver considers. Too small and a queue
## forms before anyone reacts; too large and everyone dodges everyone.
var avoid_neighbour_distance: float = 4.5
## Neighbours the solver weighs. The cost is per agent per neighbour.
var avoid_max_neighbours: int = 8
## Seconds ahead the solver looks for agent-on-agent collisions. Longer values
## make bodies commit to a side early, which is what un-jams a doorway.
var avoid_time_horizon: float = 1.6
## Seconds after finishing a crossing during which this agent will not start
## another. Without it an agent that steps across a plank re-paths, is handed a
## corridor back over the same plank, and crosses it again forever: measured in
## the arena at 1,107 crossings in seventy seconds over twenty-four bodies, and
## not one goal reached.
var link_cooldown: float = 0.9
## Metres from an off-mesh link's mouth at which the steering stops cutting the
## corner and walks straight in.
var link_approach: float = 2.5
## Multiple of `path_desired_distance` at which a crossing may actually be
## entered. The traversal's own first leg walks the body from wherever it is to
## the entry, so this is a commitment radius, not a tolerance on an arrival.
##
## A MULTIPLE RATHER THAN A DISTANCE, because `path_desired_distance` is derived
## from the body's own radius and the roster runs from 0.40 m scavengers to the
## 0.62 m bodies `firefight` bakes its navmesh for. A metre figure written for
## the small ones is a gate the big ones cannot fit through.
var link_entry_scale: float = 2.0
## True while a goal is waiting on a path slot. Read-only outside this class.
var pending: bool = false
## True while a recovery detour is overriding the behaviour's goal. Read-only.
var detouring: bool = false
## Consecutive wedges without a clean run in between. Past two or three the
## behaviour should stop detouring and pick a different objective. Read-only.
var stuck_streak: int = 0
## The goal the behaviour last asked for, which differs from `goal()` only while
## a detour is running. Read-only.
var requested_goal: Vector3 = Vector3.ZERO
## The scripted off-mesh crossing this agent plays. Owned here because the body it
## drives is this navigator's body; stepped by `AIPathService` at the physics rate
## so a climb is smooth whatever the agent's think rate.
var traverse: AITraversal = Traversal.new()
## Off-mesh links crossed since the navigator was made. Read by the harnesses.
var links_crossed: int = 0
## Times a crossing was refused because the agent had only just finished one.
## Read by `tools/verify_ai_traversal.gd`; three integers, incremented only on the
## frames an agent is stood at a link mouth, which is why they can live here.
var link_refused_cooldown: int = 0
## Times the agent was walking at a link mouth and was still too far out to enter.
var link_refused_reach: int = 0
## Times the corridor said "link" and the owning `NavigationLink3D` could not be
## resolved. Non-zero means the path metadata and the scene disagree.
var link_refused_owner: int = 0
## Turn on the traversal trace. OFF in the game, because the corridor scan it
## enables allocates a copy of the path's type array; ON in
## `tools/verify_ai_traversal.gd`, which is the only thing that has to tell "A*
## never offered this body a link" apart from "the body never got to the mouth",
## and which cannot see either from outside this class.
var trace_links: bool = false
## Read-only, and only written while `trace_links` is on. Whether the corridor
## the agent is walking routes through an off-mesh link at all.
var trace_corridor_link: bool = false
## Read-only. Metres to the mouth of the link the agent is walking at, INF when
## the next waypoint is not one.
var trace_mouth_gap: float = INF
## Read-only. Metres from a mouth at which this body commits to a crossing.
var trace_entry_reach: float = 0.0
## Called with this navigator's agent id the moment a crossing starts, so the
## path service can put it on its active list without polling every agent.
## Bound by `AIPathService.register`.
var on_traverse_begin: Callable = Callable()

var _nav: NavigationAgent3D = null
var _body: CharacterBody3D = null
var _goal: Vector3 = Vector3.ZERO
var _applied_goal: Vector3 = Vector3(INF, INF, INF)
var _since_path: float = 999.0
var _safe_velocity: Vector3 = Vector3.ZERO
var _avoidance_used: bool = false
var _avoid_written: bool = false
var _urgent: bool = false
var _pos: Vector3 = Vector3.ZERO
var _last_pos: Vector3 = Vector3.ZERO
var _has_last: bool = false
var _stuck_timer: float = 0.0
var _clear_timer: float = 0.0
var _detour_timer: float = 0.0
var _was_traversing: bool = false
var _link_hold: float = 0.0


## Bind the agent's `NavigationAgent3D` and size it from the species. Called once,
## at bind time; nothing here runs per frame.
##
## `navigation_layers` is the mobility contract. The region carries
## `AILinkBaker.LAYER_WALK` and so does every agent; each link carries the one bit
## its geometry demands and the agent carries the bits its species has. Godot
## intersects the two inside the corridor search, which is why nothing downstream
## ever has to ask "could this body have climbed that".
func setup(nav: NavigationAgent3D, profile: AISpeciesProfile, avoid: bool) -> void:
	_nav = nav
	if _nav == null:
		return
	_avoidance_used = avoid
	var layers: int = AILinkBaker.LAYER_WALK
	if profile != null:
		_nav.radius = profile.body_radius
		_nav.height = profile.height
		_nav.max_speed = profile.run_speed
		_nav.path_height_offset = profile.hover_height
		layers = profile.navigation_layer_mask()
	_nav.navigation_layers = layers
	_nav.path_desired_distance = maxf(_nav.radius * 1.4, 0.5)
	_nav.target_desired_distance = maxf(_nav.radius * 2.0, 0.8)
	# The corridor is only worth following while the body is on it. Past this the
	# agent has been shoved off by avoidance or a crossing and needs a new one.
	_nav.path_max_distance = maxf(_nav.radius * 8.0, 4.0)
	_nav.path_postprocessing = NavigationPathQueryParameters3D.PATH_POSTPROCESSING_CORRIDORFUNNEL
	# Segment types are what tell the steering that the next waypoint is the mouth
	# of a ladder rather than a corner. Without them the look-ahead cuts the corner
	# past it and `link_reached` never fires — measured in the arena: 31 routable
	# roof goals, 74 climb links in the map, and not one climb taken.
	_nav.path_metadata_flags = (
		NavigationPathQueryParameters3D.PATH_METADATA_INCLUDE_TYPES
		| NavigationPathQueryParameters3D.PATH_METADATA_INCLUDE_OWNERS
	)
	_nav.avoidance_enabled = avoid
	_nav.neighbor_distance = avoid_neighbour_distance
	_nav.max_neighbors = avoid_max_neighbours
	_nav.time_horizon_agents = avoid_time_horizon
	_nav.time_horizon_obstacles = avoid_time_horizon * 0.5
	if avoid and not _nav.velocity_computed.is_connected(_on_velocity_computed):
		_nav.velocity_computed.connect(_on_velocity_computed)
	if not _nav.link_reached.is_connected(_on_link_reached):
		_nav.link_reached.connect(_on_link_reached)
	_bind_body()


## Corridor simplification and the corridor search's own budget.
##
## `epsilon` collapses near-collinear corridor points before they reach the
## steering code. The funnel already produces a taut path; this only removes the
## jitter left by polygon edges that are almost in line, which otherwise reads as
## a twitch.
##
## `search_polygons` is the A* budget, and its Godot default of 4,096 is a real
## ceiling on a real level rather than a safety net. The town's navmesh is 29,942
## polygons over 305 metres; a query from a street to a roof on the far side runs
## out of budget and comes back with a truncated path or none at all. Measured at
## the default: of 798 baked ladder links in the town the server would path
## through 73 — 9% — while `arena` at 563 polygons and `firefight` at 3,307 both
## managed 100%. Nothing about the links was wrong; the search gave up.
func apply_agent_limits(epsilon: float, search_polygons: int) -> void:
	if _nav == null:
		return
	_nav.simplify_path = epsilon > 0.0
	_nav.simplify_epsilon = maxf(epsilon, 0.0)
	_nav.path_search_max_polygons = maxi(search_polygons, 256)


## Ask to go somewhere. Cheap and idempotent — call it every tick with wherever
## the behaviour currently wants to be, and let the budget decide when it lands.
## While a recovery detour or a crossing is running the request is remembered but
## not acted on.
func set_goal(p: Vector3, urgent: bool = false) -> void:
	requested_goal = p
	if _detour_timer > 0.0 or traverse.is_running():
		return
	if p.distance_squared_to(_goal) < 1e-4 and pending:
		return
	_goal = p
	_urgent = _urgent or urgent
	pending = true


## Force the next granted slot to be spent even if the goal has not moved. The
## path service calls this when the navigation map rebakes underneath us.
func invalidate() -> void:
	if _nav == null:
		return
	pending = true
	_urgent = true
	_applied_goal = Vector3(INF, INF, INF)


## Run this agent's clocks: the re-path timer, the recovery detour, and the
## no-progress detector. `from` is the body's current position. One call per
## agent tick, before `wants_path` and `steer`.
##
## A body on a ladder makes no horizontal progress along its corridor and never
## will, so the whole recovery machine is held off for the duration — left
## running, the no-progress detector fires part-way up, `unstick` re-paths to a
## sidestep, and the agent is asked to leave the ladder in mid-air. The corridor
## it comes back to is stale by definition, which is why finishing a crossing
## forces a re-path rather than trusting the path it had at the bottom.
func advance(delta: float, from: Vector3) -> void:
	_pos = from
	_since_path += delta
	if traverse.is_running():
		_was_traversing = true
		_stuck_timer = 0.0
		_last_pos = from
		return
	if _was_traversing:
		_was_traversing = false
		_last_pos = from
		_link_hold = link_cooldown
		# Ask for a fresh corridor, but do NOT jump the queue for it. The one the
		# agent already has still ends where it was going, and forcing an urgent
		# re-path on every crossing turns a busy level into a path storm.
		pending = true
	_link_hold = maxf(_link_hold - delta, 0.0)
	_track_progress(delta, from)
	if _avoidance_used and not _avoid_written and _nav != null:
		# Nothing was handed to the solver since the last tick, so hand it a zero
		# rather than leaving it steering everyone else around a velocity from a
		# second ago. A body that has arrived stops writing one — the behaviour
		# returns before `avoid` — and without this it stays in the avoidance
		# solution as a ghost still walking, carving a hole in the traffic behind
		# a squad that is standing still on its objective.
		_nav.velocity = Vector3.ZERO
	_avoid_written = false
	if _detour_timer > 0.0:
		_detour_timer -= delta
		if _detour_timer <= 0.0 or is_finished():
			_detour_timer = 0.0
			detouring = false
			_goal = requested_goal
			_applied_goal = Vector3(INF, INF, INF)
			pending = true
			_urgent = true


## Report whether a path slot is worth spending. Returns false when the pending
## goal is close enough to the applied one that re-pathing would only churn the
## server. `advance` must have been called this tick.
func wants_path(fighting: bool) -> bool:
	if _nav == null or not pending or traverse.is_running():
		return false
	if _urgent:
		return true
	var interval: float = combat_repath_interval if fighting else repath_interval
	if _goal.distance_squared_to(_applied_goal) < repath_tolerance * repath_tolerance:
		return _since_path >= interval * 2.0
	return _since_path >= interval * 0.25


## How badly this agent wants the next slot, for the service's queue ordering.
## Urgency beats staleness beats a merely moved goal.
func path_urgency() -> float:
	if _urgent:
		return 4.0
	var moved: float = _goal.distance_to(_applied_goal)
	if not is_finite(moved):
		return 3.0
	return minf(_since_path, 4.0) + minf(moved * 0.25, 2.0)


## Spend the granted slot. Only ever called by the path service, which is the
## whole point of the two-step.
func commit_path() -> void:
	if _nav == null:
		return
	_nav.target_position = _goal
	_applied_goal = _goal
	_since_path = 0.0
	pending = false
	_urgent = false


## Unit direction the agent should be moving in, flattened to the ground plane.
## Aims at a blend of the next waypoint and a point `look_ahead` metres further
## along the corridor, which is what cuts the corner. Zero when there is nowhere
## left to go.
##
## Mid-crossing it points at the far end of the link instead. The motor is off and
## the value moves nothing, but the behaviour above reads a zero here as "arrived"
## — a climbing body would report itself onto an objective it is still six metres
## below.
func steer_direction(from: Vector3) -> Vector3:
	if traverse.is_running():
		var away: Vector3 = traverse.exit_point() - from
		away.y = 0.0
		return away.normalized() if away.length_squared() > 1e-6 else Vector3.FORWARD
	if trace_links:
		trace_corridor_link = false
		trace_mouth_gap = INF
		trace_entry_reach = _entry_reach()
	if _nav == null or _nav.is_navigation_finished():
		return Vector3.ZERO
	var next: Vector3 = _nav.get_next_path_position()
	var aim: Vector3 = next
	var at_link: bool = _next_is_link()
	if trace_links:
		trace_mouth_gap = from.distance_to(next) if at_link else INF
		trace_corridor_link = at_link or _corridor_has_link()
	# You do not cut the corner into a ladder — but only once you are at it. The
	# look-ahead is what stops an agent nailing itself to every waypoint, and
	# switching it off for the whole approach to a link makes the walk there worse
	# without making the arrival any better. Inside `link_approach` metres of the
	# mouth it goes off, so the body actually gets close enough for the navigation
	# agent to call the link reached.
	var straight_in: bool = (
		from.distance_squared_to(next) < link_approach * link_approach and at_link
	)
	if straight_in:
		_try_link(from, next)
	if corner_cut > 0.0 and look_ahead > 0.0 and not straight_in:
		aim = next.lerp(_look_ahead_point(next), corner_cut)
	var d: Vector3 = aim - from
	d.y = 0.0
	var l: float = d.length()
	return Vector3.ZERO if l < 1e-3 else d / l


## Fraction of top speed to use given where the body currently faces and where
## the path wants it to go. A right-angle corner comes out near the floor value,
## a straight run at 1. This is what keeps agents from pivoting on the spot.
func speed_scale(facing: Vector3, desired: Vector3) -> float:
	var f: Vector3 = Vector3(facing.x, 0.0, facing.z)
	var d: Vector3 = Vector3(desired.x, 0.0, desired.z)
	if f.length_squared() < 1e-6 or d.length_squared() < 1e-6:
		return 1.0
	var c: float = maxf(f.normalized().dot(d.normalized()), 0.0)
	return min_speed_fraction + (1.0 - min_speed_fraction) * pow(c, turn_sharpness)


## Hand the intended velocity to the avoidance solver and get last frame's safe
## velocity back. Without avoidance this is a pass-through. A body mid-crossing
## contributes nothing: it is on a ladder, and an agent at the foot of that ladder
## should walk to the rungs rather than around a phantom.
func avoid(intended: Vector3) -> Vector3:
	if traverse.is_running():
		return Vector3.ZERO
	if _nav == null or not _avoidance_used:
		return intended
	_nav.velocity = intended
	_avoid_written = true
	return _safe_velocity


## True when the agent has a path it is not finishing and has stopped moving.
## Checked by the behaviour, which decides whether to spend a detour or simply
## pick a different objective.
func is_stuck() -> bool:
	return _stuck_timer >= stuck_time and not traverse.is_running()


## Sidestep out of whatever it is caught on. Alternates sides and widens with
## each repeat, holds the detour for `detour_time`, then restores the real goal.
func unstick(rng: XorShift32) -> void:
	if _nav == null or traverse.is_running():
		return
	stuck_streak += 1
	_stuck_timer = 0.0
	var forward: Vector3 = _goal - _pos
	forward.y = 0.0
	if forward.length_squared() < 1e-6:
		forward = Vector3.FORWARD
	forward = forward.normalized()
	var side: Vector3 = forward.cross(Vector3.UP)
	if rng != null and rng.chance(0.5):
		side = -side
	var reach: float = minf(
		detour_distance * (1.0 + 0.6 * float(stuck_streak - 1)), detour_distance * 3.0
	)
	var probe: Vector3 = _pos + side * reach - forward * (reach * DETOUR_BACKOFF)
	_goal = snap_to_mesh(probe)
	_applied_goal = Vector3(INF, INF, INF)
	_detour_timer = detour_time
	detouring = true
	pending = true
	_urgent = true


func is_finished() -> bool:
	return _nav == null or (_nav.is_navigation_finished() and not traverse.is_running())


func is_reachable() -> bool:
	return _nav != null and _nav.is_target_reachable()


func goal() -> Vector3:
	return _goal


## The current path, for the debug overlay. Returns the server's own array; do
## not hold onto it across a re-path.
func path_points() -> PackedVector3Array:
	if _nav == null:
		return PackedVector3Array()
	return _nav.get_current_navigation_path()


## Snap a point onto the navigation mesh. Used by far-LOD agents, which move
## kinematically and need a floor without paying for a physics query.
func snap_to_mesh(p: Vector3) -> Vector3:
	if _nav == null:
		return p
	var map: RID = _nav.get_navigation_map()
	if not map.is_valid():
		return p
	return NavigationServer3D.map_get_closest_point(map, p)


## Priority for the avoidance solver: a flanker on a timer yields to nobody, a
## body holding overwatch yields to everyone.
func set_priority(priority: float) -> void:
	if _nav != null:
		_nav.avoidance_priority = clampf(priority, 0.0, 1.0)


func stop() -> void:
	pending = false
	_urgent = false
	_detour_timer = 0.0
	detouring = false
	_stuck_timer = 0.0
	traverse.abort()
	if _nav != null:
		_nav.velocity = Vector3.ZERO


## Find the `CharacterBody3D` the navigation agent belongs to and the rig hanging
## off it, once, so a crossing costs no node lookups.
##
## `EnemyActor` puts its `NavigationAgent3D` directly under the body and exposes
## the rig through `body()`. Both are reached by capability rather than by class
## so this file keeps no compile-time dependency on the ENEMIES module — which
## matters, because the AI harnesses run under `--script` where autoloads that
## `EnemyActor` chains to do not exist yet.
func _bind_body() -> void:
	var node: Node = _nav.get_parent()
	while node != null and _body == null:
		_body = node as CharacterBody3D
		node = node.get_parent()
	if _body == null:
		return
	var rig: Node = null
	if _body.has_method(&"body"):
		rig = _body.call(&"body") as Node
	traverse.bind(_body, rig)


## The agent has walked onto a link's entry. Take the motor off the body and play
## the crossing.
##
## Starting here rather than on the next agent tick is deliberate: a far-LOD body
## thinks four times a second, and four times a second is a quarter of a second of
## walking past the foot of the ladder before anyone notices.
func _on_link_reached(details: Dictionary) -> void:
	if _body == null or traverse.is_running() or _link_hold > 0.0:
		return
	var owner_node: Node = details.get("owner", null) as Node
	var kind: int = AILinkBaker.Kind.JUMP
	if owner_node != null:
		kind = int(owner_node.get_meta(AILinkBaker.META_KIND, AILinkBaker.Kind.JUMP))
	var entry: Vector3 = details.get("link_entry_position", _body.global_position)
	var exit_point: Vector3 = details.get("link_exit_position", entry)
	# The path may enter the link from either end when it is bidirectional, and
	# the server reports the link's own start and end, not the agent's direction
	# of travel. Whichever end the body is standing at is the entry.
	if (
		_body.global_position.distance_squared_to(exit_point)
		< _body.global_position.distance_squared_to(entry)
	):
		var swap: Vector3 = entry
		entry = exit_point
		exit_point = swap
	_begin_crossing(kind, entry, exit_point)


## Hand the body to the traversal and tell the path service to start stepping it.
func _begin_crossing(kind: int, entry: Vector3, exit_point: Vector3) -> void:
	if not traverse.begin(kind, entry, exit_point):
		return
	links_crossed += 1
	if _avoidance_used and _nav != null:
		_nav.velocity = Vector3.ZERO
	if on_traverse_begin.is_valid():
		on_traverse_begin.call()


## Start the crossing when the body has actually arrived at a link's mouth.
##
## THE SIGNAL IS NOT ENOUGH. `NavigationAgent3D.link_reached` is the obvious hook
## and it fires reliably for a link whose two ends are metres apart on the ground
## — a gap jump — and not at all for one that mostly goes up. Measured over two
## levels and forty-eight bodies: 27 crossings started, all 27 of them JUMPs, and
## not one ladder, mantle or drop entered, while the same corridors demonstrably
## routed through those links. Reading the corridor directly costs one dictionary
## lookup on the frames where the next waypoint is a link, and does not depend on
## the engine noticing anything.
func _try_link(from: Vector3, next: Vector3) -> void:
	if _body == null or traverse.is_running():
		return
	if _link_hold > 0.0:
		link_refused_cooldown += 1
		return
	# Generous, on purpose. The traversal's first leg walks the body to the entry
	# anyway, so starting a metre early costs nothing and starting late costs
	# everything: the foot of a ladder is against a wall, with avoidance and the
	# wall itself both pushing the body away from it, and a body held eight tenths
	# of a metre off the mouth never enters a link it is standing at.
	if from.distance_to(next) > _entry_reach():
		link_refused_reach += 1
		return
	var link: NavigationLink3D = _link_owner()
	if link == null:
		link_refused_owner += 1
		return
	var entry: Vector3 = link.global_transform * link.start_position
	var exit_point: Vector3 = link.global_transform * link.end_position
	if from.distance_squared_to(exit_point) < from.distance_squared_to(entry):
		var swap: Vector3 = entry
		entry = exit_point
		exit_point = swap
	_begin_crossing(
		int(link.get_meta(AILinkBaker.META_KIND, AILinkBaker.Kind.JUMP)), entry, exit_point
	)


## Metres from a link mouth at which this agent will commit to the crossing.
func _entry_reach() -> float:
	if _nav == null:
		return 0.0
	return _nav.path_desired_distance * link_entry_scale


## Whether the corridor the agent is walking routes through an off-mesh link
## anywhere along it. Allocates a copy of the type array; only reached with
## `trace_links` on.
func _corridor_has_link() -> bool:
	var result: NavigationPathQueryResult3D = _nav.get_current_navigation_result()
	if result == null:
		return false
	for t: int in result.get_path_types():
		if t == NavigationPathQueryResult3D.PATH_SEGMENT_TYPE_LINK:
			return true
	return false


## The `NavigationLink3D` the current corridor segment belongs to, or null.
func _link_owner() -> NavigationLink3D:
	var result: NavigationPathQueryResult3D = _nav.get_current_navigation_result()
	if result == null:
		return null
	var owners: PackedInt64Array = result.get_path_owner_ids()
	var i: int = _nav.get_current_navigation_path_index()
	if i < 0 or i >= owners.size():
		return null
	return instance_from_id(owners[i]) as NavigationLink3D


## Whether the waypoint the agent is currently walking to is an off-mesh link.
func _next_is_link() -> bool:
	var result: NavigationPathQueryResult3D = _nav.get_current_navigation_result()
	if result == null:
		return false
	var types: PackedInt32Array = result.get_path_types()
	var i: int = _nav.get_current_navigation_path_index()
	if i < 0 or i >= types.size():
		return false
	return types[i] == NavigationPathQueryResult3D.PATH_SEGMENT_TYPE_LINK


## Walk the remaining corridor from `next` until `look_ahead` metres are spent,
## and return where that lands. Falls back to the corridor's end when the path
## is shorter than the look-ahead, which is correct: there is nothing past it.
func _look_ahead_point(next: Vector3) -> Vector3:
	var path: PackedVector3Array = _nav.get_current_navigation_path()
	var n: int = path.size()
	var i: int = _nav.get_current_navigation_path_index() + 1
	if n == 0 or i >= n:
		return next
	var budget: float = look_ahead
	var prev: Vector3 = next
	while i < n:
		var seg: Vector3 = path[i] - prev
		var l: float = seg.length()
		if l >= budget:
			return prev + seg * (budget / maxf(l, 1e-5))
		budget -= l
		prev = path[i]
		i += 1
	return prev


## Accumulate no-progress time. A stationary agent with nowhere to go is not
## stuck, so this only runs while there is a corridor left to walk.
func _track_progress(delta: float, from: Vector3) -> void:
	if delta <= 0.0:
		return
	if not _has_last:
		_last_pos = from
		_has_last = true
		return
	var moved: Vector3 = from - _last_pos
	moved.y = 0.0
	var speed: float = moved.length() / delta
	_last_pos = from
	if _nav == null or _nav.is_navigation_finished():
		_stuck_timer = 0.0
		return
	if speed < stuck_speed:
		_stuck_timer += delta
		_clear_timer = 0.0
		return
	_stuck_timer = 0.0
	_clear_timer += delta
	if _clear_timer >= stuck_time * 2.0:
		_clear_timer = 0.0
		stuck_streak = 0


func _on_velocity_computed(safe_velocity: Vector3) -> void:
	_safe_velocity = safe_velocity
