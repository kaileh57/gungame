class_name AIPathService
extends Node
## The population's path budget, the level's off-mesh link set, and the clock that
## drives every crossing in progress.
##
## A `NavigationAgent3D` path query is not free — it is a corridor search plus a
## funnel, on the navigation server, and sixty agents each firing one every frame
## will show up as a spike whether or not the server threads it. Costing them out
## at a fixed rate per frame turns a spike into a flat line, and because a stale
## path is only ever a couple of metres wrong, nobody can see the difference.
##
## Requests coalesce: an agent that asks three times before it is served is still
## one queue entry, holding whatever the highest urgency was. Waiting entries age
## upward, so a patroller behind a wall of gunfights still gets its turn.
##
## LINKS. The baked `AILinkBaker` for this level is loaded and turned into real
## `NavigationLink3D` nodes here, once, on ready. It happens in the path service
## rather than in each demo's director because this is the one node every scene
## with agents in it already owns, and because the links and the path budget are
## the same subsystem: a link is a path edge.
##
## CROSSINGS ARE STEPPED HERE, AT THE PHYSICS RATE. An agent thinks between four
## and thirty times a second depending on how far away it is, and a ladder climbed
## at four hertz is a body teleporting up a wall in half-metre jumps. The scripted
## motion therefore runs off this node's own `_physics_process` and not off the
## agent's tick, on a list that is empty — and costs nothing — whenever nobody is
## climbing anything.
##
## The service also owns the tuning for every navigator it registers. Change a
## number here and the whole population moves — that is deliberate, because these
## are population-level feel knobs, not per-species ones.

## Emitted the frame a queued request is actually spent. The debug overlay draws
## the served agent's corridor off this.
signal path_committed(agent_id: int)
## Emitted when the queue is full and a request had to be thrown away. If this
## fires in normal play the queue is too short for the population.
signal request_dropped(agent_id: int)
## Emitted when an agent finishes crossing an off-mesh link, with the
## `AILinkBaker.Kind` it crossed. The harnesses count these.
signal link_crossed(agent_id: int, kind: int)

## Where `tools/bake_nav_links.gd` writes its output. A scene called `firefight`
## finds `firefight_links.res` here without anyone wiring it up.
const LINK_DIR: String = "res://data/ai/links"

@export_group("Budget")
## Path queries granted per frame across the whole population. Eight at sixty
## frames is 480 a second, which comfortably re-paths a hundred agents twice
## over per second.
@export_range(1, 64, 1) var requests_per_frame: int = 8
## Hard cap on outstanding requests. Beyond this the newest is dropped, since a
## request that cannot be served inside a second is not worth remembering.
@export_range(16, 1024, 8) var max_queue: int = 256
## Urgency added per second of waiting. Stops a low-priority request starving
## behind a permanent supply of urgent ones.
@export_range(0.0, 8.0, 0.05) var priority_aging: float = 0.8

@export_group("Links")
## Baked link set for this level. Left empty, the service looks for
## `LINK_DIR/<scene name>_links.res` on ready.
@export_file("*.res") var link_set_path: String = ""
## Turn the baked links into real navigation links on ready. Off means the level
## runs on the flat navmesh alone — the state everything was in before traversal.
@export var install_links: bool = true

@export_group("Re-path")
## Metres the goal must move before a re-path is worth asking for.
@export_range(0.1, 8.0, 0.05) var repath_tolerance: float = 1.1
## Seconds between re-paths for an agent that is not fighting.
@export_range(0.1, 8.0, 0.05) var repath_interval: float = 1.6
## Seconds between re-paths while engaged. Contacts move, so this is shorter.
@export_range(0.05, 4.0, 0.05) var combat_repath_interval: float = 0.55
## Corridor simplification epsilon in metres. Zero disables it.
##
## ZERO IS THE DEFAULT AND IT MATTERS. Simplification is Ramer-Douglas-Peucker
## over the returned points, and a climb link's three points — the approach, the
## entry at the foot of the wall and the exit two metres above it — are very
## nearly collinear in XZ. At 0.18 m the entry is simplified out, the agent never
## comes within `path_desired_distance` of it, and `link_reached` never fires.
## Measured with it on: over two levels and forty-eight bodies, every crossing
## that started was a JUMP — the one link kind whose ends are far apart on the
## ground — and not one ladder, mantle or drop was ever entered.
@export_range(0.0, 1.0, 0.01) var simplify_epsilon: float = 0.0
## Polygons one corridor search may expand before it gives up.
##
## LEAVE THIS ALONE UNLESS YOU MEASURE. It is not a safety net, it is a per-query
## ALLOCATION: the navigation server reserves this many polygon records for every
## search it runs. Raised to 32,768 on the theory that a 30,000-polygon town needs
## the headroom, `firefight` went from 163 fps to 7 — sixty agents at eight
## queries a frame, each reserving and clearing a couple of megabytes. It also
## bought nothing: the town's links were failing for an unrelated reason and the
## measured pathable rate did not move by one link between 4,096 and 32,768.
@export_range(256, 262144, 256) var path_search_polygons: int = 4096

@export_group("Steering")
## Metres down the corridor the steering target sits.
@export_range(0.2, 12.0, 0.05) var look_ahead: float = 2.2
## Blend from the exact next waypoint (0) to the look-ahead point (1).
@export_range(0.0, 1.0, 0.01) var corner_cut: float = 0.55
## Exponent on the heading-error cosine when scaling speed into turns.
@export_range(0.25, 6.0, 0.05) var turn_sharpness: float = 1.4
## Floor on the speed scale, so a turning agent still creeps forward.
@export_range(0.0, 1.0, 0.01) var min_speed_fraction: float = 0.25

@export_group("Avoidance")
## Metres of neighbourhood the solver considers.
@export_range(1.0, 20.0, 0.1) var avoid_neighbour_distance: float = 4.5
## Neighbours weighed per agent.
@export_range(2, 32, 1) var avoid_max_neighbours: int = 8
## Seconds ahead the solver looks. Longer makes bodies pick a side earlier, which
## is what stops a doorway becoming a queue.
@export_range(0.2, 6.0, 0.05) var avoid_time_horizon: float = 1.6
## Seconds after a crossing before an agent may start another one.
@export_range(0.0, 6.0, 0.05) var link_cooldown: float = 0.9
## Metres from a link's mouth at which steering walks straight in rather than
## cutting the corner past it.
@export_range(0.5, 12.0, 0.05) var link_approach: float = 2.5
## Multiple of an agent's own `path_desired_distance` at which it commits to a
## crossing. Scaled per body rather than fixed, because the roster's radii differ
## by half again and the foot of a ladder is against a wall.
@export_range(0.5, 6.0, 0.05) var link_entry_scale: float = 2.0

@export_group("Recovery")
## Ground speed below which an agent counts as making no progress.
@export_range(0.0, 3.0, 0.01) var stuck_speed: float = 0.35
## Seconds of no progress before an agent is declared stuck.
@export_range(0.1, 5.0, 0.05) var stuck_time: float = 0.9
## Base sidestep distance for a recovery detour.
@export_range(0.5, 12.0, 0.1) var detour_distance: float = 2.4
## Seconds a recovery detour is held before the real goal is restored.
@export_range(0.2, 8.0, 0.05) var detour_time: float = 1.4

@export_group("Traversal")
## Metres a second climbed on a ladder.
@export_range(0.3, 8.0, 0.05) var climb_speed: float = 1.9
## Metres a second walked onto a link's entry point.
@export_range(0.5, 8.0, 0.05) var mount_speed: float = 2.4
## Metres a second over a vault.
@export_range(0.5, 12.0, 0.05) var vault_speed: float = 3.1
## Metres a second pulling up onto a ledge.
@export_range(0.3, 8.0, 0.05) var mantle_speed: float = 2.0
## Metres a second across a gap jump, along the ground.
@export_range(1.0, 16.0, 0.05) var jump_speed: float = 5.2
## Metres a second stepping off a ledge, along the ground.
@export_range(0.5, 10.0, 0.05) var drop_speed: float = 2.6
## Metres a second across a plank or girder.
@export_range(0.5, 8.0, 0.05) var bridge_speed: float = 2.2
## Apex of a gap jump as a fraction of its span.
@export_range(0.0, 0.6, 0.01) var jump_arc: float = 0.16
## Apex of a vault or a mantle, metres.
@export_range(0.0, 1.5, 0.01) var vault_arc: float = 0.42
## Radians a second a crossing body may swing its facing.
@export_range(1.0, 20.0, 0.1) var traverse_turn_rate: float = 7.0
## Seconds held at a crossing's exit before the motor is handed back.
@export_range(0.0, 1.0, 0.01) var traverse_settle: float = 0.10

var _navs: Dictionary = {}
var _row: Dictionary = {}
var _q_id: PackedInt32Array = PackedInt32Array()
var _q_priority: PackedFloat32Array = PackedFloat32Array()
var _q_wait: PackedFloat32Array = PackedFloat32Array()
var _active: PackedInt32Array = PackedInt32Array()
var _links: AILinkBaker = null
var _link_nodes: int = 0
var _used: int = 0
var _committed: int = 0
var _dropped: int = 0
var _crossings: int = 0
var _map_dirty: bool = false


func _ready() -> void:
	if not NavigationServer3D.map_changed.is_connected(_on_map_changed):
		NavigationServer3D.map_changed.connect(_on_map_changed)
	if install_links:
		var found: AILinkBaker = _discover_links()
		if found != null:
			install_link_set(found)
	set_physics_process(true)


func _exit_tree() -> void:
	if NavigationServer3D.map_changed.is_connected(_on_map_changed):
		NavigationServer3D.map_changed.disconnect(_on_map_changed)


## Step every crossing in progress. The list is empty in the overwhelming
## majority of frames, which is why this can afford to be per-frame at all.
func _physics_process(delta: float) -> void:
	var i: int = 0
	while i < _active.size():
		var id: int = _active[i]
		var nav: AINavigator = _navs.get(id, null)
		# The kind is read BEFORE the step, because the step that returns false is
		# the one that cleared it.
		var kind: int = -1 if nav == null else nav.traverse.kind
		if nav == null or not nav.traverse.step(delta):
			# Only a crossing that ran to its exit counts. One that was aborted —
			# the body died on the rungs — is not a ladder anybody climbed.
			if nav != null and nav.traverse.completed:
				_crossings += 1
				link_crossed.emit(id, kind)
			var last: int = _active.size() - 1
			_active[i] = _active[last]
			_active.resize(last)
			continue
		i += 1


## Take ownership of an agent's navigator and stamp the population tuning onto
## it. Registration is what makes the agent visible to map invalidation, so an
## unregistered navigator will happily walk a corridor through a rebaked wall.
func register(agent_id: int, nav: AINavigator) -> void:
	if nav == null:
		return
	_navs[agent_id] = nav
	nav.on_traverse_begin = _on_traverse_begin.bind(agent_id)
	apply_tuning(nav)


func unregister(agent_id: int) -> void:
	var nav: AINavigator = _navs.get(agent_id, null)
	if nav != null:
		nav.traverse.abort()
		nav.on_traverse_begin = Callable()
	_navs.erase(agent_id)
	var r: int = _row.get(agent_id, -1)
	if r >= 0:
		_drop(r)
	for i: int in _active.size():
		if _active[i] == agent_id:
			var last: int = _active.size() - 1
			_active[i] = _active[last]
			_active.resize(last)
			break


## Push the exported tuning onto one navigator. Called on registration and again
## whenever the inspector values change during a tuning pass.
func apply_tuning(nav: AINavigator) -> void:
	nav.repath_tolerance = repath_tolerance
	nav.repath_interval = repath_interval
	nav.combat_repath_interval = combat_repath_interval
	nav.look_ahead = look_ahead
	nav.corner_cut = corner_cut
	nav.turn_sharpness = turn_sharpness
	nav.min_speed_fraction = min_speed_fraction
	nav.stuck_speed = stuck_speed
	nav.stuck_time = stuck_time
	nav.detour_distance = detour_distance
	nav.detour_time = detour_time
	nav.avoid_neighbour_distance = avoid_neighbour_distance
	nav.avoid_max_neighbours = avoid_max_neighbours
	nav.avoid_time_horizon = avoid_time_horizon
	nav.link_cooldown = link_cooldown
	nav.link_approach = link_approach
	nav.link_entry_scale = link_entry_scale
	nav.apply_agent_limits(simplify_epsilon, path_search_polygons)
	var t: AITraversal = nav.traverse
	t.climb_speed = climb_speed
	t.mount_speed = mount_speed
	t.vault_speed = vault_speed
	t.mantle_speed = mantle_speed
	t.jump_speed = jump_speed
	t.drop_speed = drop_speed
	t.bridge_speed = bridge_speed
	t.jump_arc = jump_arc
	t.vault_arc = vault_arc
	t.turn_rate = traverse_turn_rate
	t.settle_time = traverse_settle


## Re-stamp every registered navigator. The tuning pass calls this after moving
## a slider; nothing in the running game needs it.
func retune_all() -> void:
	for nav: AINavigator in _navs.values():
		apply_tuning(nav)


## Turn a baked link set into live navigation links on this node's map. Replaces
## whatever was installed before. Returns how many links went in.
func install_link_set(links: AILinkBaker) -> int:
	var old: Node = get_node_or_null(^"AILinks")
	if old != null:
		# Renamed before it is freed: `queue_free` is deferred, and a node that
		# still holds the name would push the replacement to "AILinks2".
		old.name = "AILinksRetired"
		old.queue_free()
	_links = links
	_link_nodes = 0
	if links == null:
		return 0
	_link_nodes = links.instantiate_into(self)
	return _link_nodes


## The link set in force, or null when the level runs on flat navmesh alone.
func link_set() -> AILinkBaker:
	return _links


func link_count() -> int:
	return _link_nodes


## How many agents are mid-crossing right now.
func traversing() -> int:
	return _active.size()


## Crossings completed since the service was made.
func crossings_total() -> int:
	return _crossings


## Ask for a path slot. Safe to call every tick — a second call for an agent
## already queued raises its urgency rather than adding a second entry.
## Returns false only when the queue was full.
func submit(agent_id: int, urgency: float) -> bool:
	var r: int = _row.get(agent_id, -1)
	if r >= 0:
		_q_priority[r] = maxf(_q_priority[r], urgency)
		return true
	if _used >= max_queue:
		_dropped += 1
		request_dropped.emit(agent_id)
		return false
	if _used >= _q_id.size():
		var grow: int = mini(maxi(_used * 2, 32), max_queue)
		_q_id.resize(grow)
		_q_priority.resize(grow)
		_q_wait.resize(grow)
	_q_id[_used] = agent_id
	_q_priority[_used] = urgency
	_q_wait[_used] = 0.0
	_row[agent_id] = _used
	_used += 1
	return true


## Spend this frame's slots, highest effective urgency first. Returns how many
## paths were actually committed.
##
## Selection is `requests_per_frame` linear scans of the queue rather than a
## heap. At the eight-by-two-hundred-and-fifty-six worst case that is two
## thousand float compares, which is cheaper than the heap's pointer chasing at
## this size and has no allocation at all.
func service(delta: float) -> int:
	if _map_dirty:
		_map_dirty = false
		_invalidate_all()
	for i: int in _used:
		_q_wait[i] += delta
	var granted: int = 0
	var slots: int = requests_per_frame
	while granted < slots and _used > 0:
		var best: int = 0
		var best_score: float = _q_priority[0] + _q_wait[0] * priority_aging
		for i: int in range(1, _used):
			var score: float = _q_priority[i] + _q_wait[i] * priority_aging
			if score > best_score:
				best_score = score
				best = i
		var id: int = _q_id[best]
		_drop(best)
		var nav: AINavigator = _navs.get(id, null)
		if nav == null:
			continue
		nav.commit_path()
		_committed += 1
		granted += 1
		path_committed.emit(id)
	return granted


## Drop every queued request without serving it. For a scene teardown or a
## teleport, where the pending goals are all about to be wrong anyway.
func flush() -> void:
	for id: int in _active:
		var nav: AINavigator = _navs.get(id, null)
		if nav != null:
			nav.traverse.abort()
	_active.resize(0)
	_row.clear()
	_used = 0


func queued() -> int:
	return _used


func registered() -> int:
	return _navs.size()


func committed_total() -> int:
	return _committed


func dropped_total() -> int:
	return _dropped


func reset_stats() -> void:
	_committed = 0
	_dropped = 0
	_crossings = 0


## The link set for whatever scene this service is running in.
##
## Explicit path wins. Failing that the current scene's own file name picks the
## set, which is what lets `firefight.tscn` and `arena.tscn` both get their links
## without either builder knowing this class exists.
func _discover_links() -> AILinkBaker:
	if not link_set_path.is_empty() and ResourceLoader.exists(link_set_path):
		return ResourceLoader.load(link_set_path) as AILinkBaker
	var tree: SceneTree = get_tree()
	if tree == null or tree.current_scene == null:
		return null
	var file: String = tree.current_scene.scene_file_path
	if file.is_empty():
		return null
	var guess: String = "%s/%s_links.res" % [LINK_DIR, file.get_file().get_basename()]
	if not ResourceLoader.exists(guess):
		return null
	return ResourceLoader.load(guess) as AILinkBaker


func _on_traverse_begin(agent_id: int) -> void:
	for id: int in _active:
		if id == agent_id:
			return
	_active.push_back(agent_id)


## A rebake replaces the map's polygons, so every corridor built against the old
## ones is suspect. Deferred to the next `service` because the signal fires from
## the server's thread-sync point, not from our frame.
func _on_map_changed(_map: RID) -> void:
	_map_dirty = true


func _invalidate_all() -> void:
	for id: int in _navs:
		var nav: AINavigator = _navs[id]
		nav.invalidate()


func _drop(r: int) -> void:
	var id: int = _q_id[r]
	var last: int = _used - 1
	if r != last:
		_q_id[r] = _q_id[last]
		_q_priority[r] = _q_priority[last]
		_q_wait[r] = _q_wait[last]
		_row[_q_id[r]] = r
	_row.erase(id)
	_used = last
