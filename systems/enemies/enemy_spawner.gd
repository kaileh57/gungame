class_name EnemySpawner
extends Node3D
## Pooled spawning for baked species, with a hard cap the settings own.
##
## Nothing is instantiated during play if it can be avoided: every species keeps a
## free list of dead actors, and a spawn takes one off it and calls `revive()`.
## Instantiating a creature costs a scene tree, a skeleton, a skin and a physics
## body; recycling one costs a transform write. At the Ultra cap of 64 enemies
## that difference is the entire hitch budget.
##
## The cap is `min(max_alive, GameSettings.max_enemies)` and it is re-read live —
## dropping the quality preset mid-fight thins the crowd instead of waiting for a
## reload. Requests that arrive over cap queue rather than fail, so a door that
## opens during a peak still delivers its occupants a moment later.

## An actor entered play. Register it with the director's target index here.
signal spawned(actor: EnemyActor)
## An actor left play and went back to the pool. Unregister it here.
signal despawned(actor: EnemyActor)
## The live cap changed, because the quality preset did.
signal capacity_changed(capacity: int)
## A request could not be honoured because the species has no baked scene.
signal spawn_failed(species_id: StringName, reason: String)

## Where the bake writes its species scenes.
const SPECIES_DIR: String = "res://data/enemies"

@export_group("Roster")
## Species ids to serve. Each needs `res://data/enemies/<id>.res` from the bake.
@export var species: Array[StringName] = []
## Perception, weapon and courage numbers, keyed by species id.
@export var profiles: AISpeciesProfileSet = null
## Faction every actor from this spawner fights for.
@export_range(-2, 2, 1) var faction: int = 0

@export_group("Budget")
## Ceiling this spawner will never exceed, whatever the settings allow.
@export_range(1, 128, 1) var max_alive: int = 24
## Pooled actors kept per species. Beyond this a spawn waits for a corpse.
@export_range(1, 64, 1) var pool_per_species: int = 8
## Build the pools on `_ready` instead of on first use. Costs load time, buys a
## hitch-free first contact.
@export var prewarm: bool = true
## Actors instantiated per prewarm frame, so a big pool does not stall the load.
@export_range(1, 32, 1) var prewarm_batch: int = 2

@export_group("Placement")
## Markers a spawn may appear at. Any `Node3D` works; a door node's own transform
## is the intended case.
@export var spawn_points: Array[NodePath] = []
## Doors that emit `door_signal` when they open. The spawner connects to each and
## releases one queued actor per opening.
@export var door_paths: Array[NodePath] = []
## Signal name a door emits when it opens.
@export var door_signal: StringName = &"opened"
## Metres a door-spawned actor is pushed along the door's forward axis, clearing
## the frame before the body appears.
@export_range(0.0, 6.0, 0.05) var door_clearance: float = 0.9
## Snap spawn positions onto the navigation mesh. Off for arena demos with no nav.
@export var snap_to_navmesh: bool = true
## Random yaw spread applied to a spawn, in radians.
@export_range(0.0, 3.15, 0.01) var yaw_jitter: float = 0.35
## Radial scatter applied around a spawn point, in metres.
@export_range(0.0, 8.0, 0.05) var spread_radius: float = 0.0

@export_group("Waves")
## Spawn automatically up to the cap. Off means the director calls `spawn()`.
@export var auto_spawn: bool = false
## Seconds between automatic spawns.
@export_range(0.05, 60.0, 0.05) var spawn_interval: float = 2.5
## Deterministic seed for species choice, scatter and death takes.
@export_range(1, 2147483647, 1) var seed_value: int = 1013

var _pool: Dictionary = {}
var _live: Array[EnemyActor] = []
var _scenes: Dictionary = {}
var _points: Array[Node3D] = []
var _queue: Array[StringName] = []
var _rng: XorShift32 = null
var _timer: float = 0.0
var _prewarm_left: Array = []
var _spawn_serial: int = 0


func _ready() -> void:
	_rng = XorShift32.new(seed_value)
	_load_scenes()
	_resolve_points()
	_connect_doors()
	GameSettings.settings_changed.connect(_on_settings_changed)
	if prewarm:
		for id in _scenes.keys():
			_prewarm_left.append(id)
	set_process(auto_spawn or prewarm)


func _process(delta: float) -> void:
	if not _prewarm_left.is_empty():
		_prewarm_step()
	_drain_queue()
	if not auto_spawn:
		if _prewarm_left.is_empty() and _queue.is_empty():
			set_process(false)
		return
	_timer -= delta
	if _timer > 0.0:
		return
	_timer = spawn_interval
	if alive_count() < capacity() and not _points.is_empty():
		spawn(_pick_species(), _point_transform(_points[_rng.next_int(0, _points.size() - 1)]))


## Live cap: this spawner's ceiling, clamped by the quality preset.
func capacity() -> int:
	return mini(max_alive, GameSettings.max_enemies)


func alive_count() -> int:
	return _live.size()


## Actors currently in play. Do not hold this across a frame; it is the live array.
func live_actors() -> Array[EnemyActor]:
	return _live


## Put one actor of `species_id` into play at `where`. Returns null when the cap
## is reached, the species is unknown, or the pool is exhausted.
func spawn(species_id: StringName, where: Transform3D) -> EnemyActor:
	if _live.size() >= capacity():
		return null
	if not _scenes.has(species_id):
		spawn_failed.emit(species_id, "no baked scene at %s/%s.res" % [SPECIES_DIR, species_id])
		return null
	var actor: EnemyActor = _take(species_id)
	if actor == null:
		return null
	_spawn_serial += 1
	actor.revive(_scatter(where), seed_value + _spawn_serial * 7919, _rng.next_int(0, 4))
	_live.append(actor)
	spawned.emit(actor)
	return actor


## Spawn at one of the configured markers, chosen at random.
func spawn_at_point(species_id: StringName) -> EnemyActor:
	if _points.is_empty():
		spawn_failed.emit(species_id, "no spawn points configured")
		return null
	return spawn(species_id, _point_transform(_points[_rng.next_int(0, _points.size() - 1)]))


## Spawn just inside a real door, facing out of it. `door` may be the door node
## itself or any marker: the actor is pushed `door_clearance` along the node's
## forward axis so it is never born inside the frame.
func spawn_from_door(door: Node3D, species_id: StringName) -> EnemyActor:
	var x: Transform3D = door.global_transform
	var fwd: Vector3 = -x.basis.z
	fwd.y = 0.0
	if fwd.length_squared() < 1e-6:
		fwd = Vector3.FORWARD
	fwd = fwd.normalized()
	var origin: Vector3 = x.origin + fwd * door_clearance
	return spawn(species_id, Transform3D(Basis.looking_at(fwd, Vector3.UP), origin))


## Ask for a spawn that may have to wait for capacity or for a door to open.
func request(species_id: StringName) -> void:
	_queue.append(species_id)
	set_process(true)


## Take an actor out of play and return it to its pool. Idempotent.
func despawn(actor: EnemyActor) -> void:
	var i: int = _live.find(actor)
	if i < 0:
		return
	_live.remove_at(i)
	_park(actor)
	despawned.emit(actor)


## Return every live actor to the pool. The demo teardown path.
func despawn_all() -> void:
	for actor in _live.duplicate():
		despawn(actor)


func _take(species_id: StringName) -> EnemyActor:
	var free: Array = _pool[species_id]
	if not free.is_empty():
		return free.pop_back() as EnemyActor
	if _count_of(species_id) >= pool_per_species:
		return null
	return _instantiate(species_id)


func _instantiate(species_id: StringName) -> EnemyActor:
	var scene: PackedScene = _scenes[species_id]
	var actor := scene.instantiate() as EnemyActor
	if actor == null:
		spawn_failed.emit(species_id, "baked scene root is not an EnemyActor")
		return null
	add_child(actor)
	var profile: AISpeciesProfile = null
	if profiles != null:
		profile = profiles.get_profile(species_id)
	if profile != null:
		actor.configure(profile, faction, _next_agent_id())
	else:
		spawn_failed.emit(species_id, "no AISpeciesProfile for this species")
	actor.recyclable.connect(despawn)
	_deactivate(actor)
	return actor


## Take an actor out of play. It stays in the tree — re-adding a scene costs far
## more than a hidden node with its processing off.
func _deactivate(actor: EnemyActor) -> void:
	actor.sleep()
	actor.global_position = global_position + Vector3(0.0, -1000.0, 0.0)


func _park(actor: EnemyActor) -> void:
	_deactivate(actor)
	var free: Array = _pool[actor.species_id]
	if not free.has(actor):
		free.append(actor)


func _count_of(species_id: StringName) -> int:
	var n: int = (_pool[species_id] as Array).size()
	for a in _live:
		if a.species_id == species_id:
			n += 1
	return n


func _prewarm_step() -> void:
	var id: StringName = _prewarm_left[0]
	var made: int = 0
	while made < prewarm_batch and _count_of(id) < pool_per_species:
		var actor: EnemyActor = _instantiate(id)
		if actor == null:
			break
		(_pool[id] as Array).append(actor)
		made += 1
	if _count_of(id) >= pool_per_species or made == 0:
		_prewarm_left.pop_front()


func _drain_queue() -> void:
	while not _queue.is_empty() and _live.size() < capacity():
		var id: StringName = _queue[0]
		if spawn_at_point(id) == null:
			return
		_queue.pop_front()


func _pick_species() -> StringName:
	if _scenes.is_empty():
		return &""
	var ids: Array = _scenes.keys()
	return ids[_rng.next_int(0, ids.size() - 1)]


func _point_transform(p: Node3D) -> Transform3D:
	return p.global_transform


func _scatter(where: Transform3D) -> Transform3D:
	var out := where
	if yaw_jitter > 0.0:
		out.basis = out.basis.rotated(Vector3.UP, _rng.next_range(-yaw_jitter, yaw_jitter))
	if spread_radius > 0.0:
		var a: float = _rng.next_range(0.0, TAU)
		var r: float = spread_radius * sqrt(_rng.next())
		out.origin += Vector3(cos(a) * r, 0.0, sin(a) * r)
	if snap_to_navmesh:
		out.origin = _snap(out.origin)
	return out


func _snap(p: Vector3) -> Vector3:
	var map: RID = get_world_3d().navigation_map
	if not map.is_valid():
		return p
	return NavigationServer3D.map_get_closest_point(map, p)


func _next_agent_id() -> int:
	_spawn_serial += 1
	return _spawn_serial


func _load_scenes() -> void:
	for id in species:
		var path: String = "%s/%s.res" % [SPECIES_DIR, id]
		if not ResourceLoader.exists(path):
			spawn_failed.emit(id, "missing %s; run res://tools/build_enemies.gd" % path)
			continue
		var scene := load(path) as PackedScene
		if scene == null:
			spawn_failed.emit(id, "%s is not a PackedScene" % path)
			continue
		_scenes[id] = scene
		_pool[id] = []


func _resolve_points() -> void:
	_points.clear()
	for p in spawn_points:
		var n := get_node_or_null(p) as Node3D
		if n != null:
			_points.append(n)


func _connect_doors() -> void:
	for p in door_paths:
		var d := get_node_or_null(p) as Node3D
		if d == null:
			continue
		if not d.has_signal(door_signal):
			push_warning("EnemySpawner: '%s' has no signal '%s'." % [d.name, door_signal])
			continue
		d.connect(door_signal, _on_door_opened.bind(d))


func _on_door_opened(door: Node3D) -> void:
	if _queue.is_empty():
		return
	var id: StringName = _queue[0]
	if spawn_from_door(door, id) != null:
		_queue.pop_front()


func _on_settings_changed(key: StringName, _value: Variant) -> void:
	if key != &"max_enemies":
		return
	var cap: int = capacity()
	capacity_changed.emit(cap)
	while _live.size() > cap:
		despawn(_live[_live.size() - 1])
