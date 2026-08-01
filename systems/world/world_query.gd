class_name WorldQuery
extends RefCounted
## The one object gameplay code holds to ask the world anything: how high is the
## ground, what is it made of, is there room to stand, what did this bullet hit.
##
## Binds the three baked resources together. Construct it once per scene and hand
## it to the player controller, the AI and the impact effects — it caches scratch
## buffers and allocates nothing per query.

const TERRAIN_PATH: String = "res://data/world/terrain_data.res"
const COLLIDER_PATH: String = "res://data/world/colliders.res"
const LAYOUT_PATH: String = "res://data/world/layout.res"

var terrain: WorldTerrainData
var colliders: WorldColliderSet
var layout: WorldLayoutData

## Surface id of the last `raycast` hit.
var hit_surface: int = WorldSurface.Kind.SAND
## True when the last `raycast` hit terrain rather than a collider.
var hit_terrain: bool = false


func _init(
	terrain_data: WorldTerrainData = null,
	collider_set: WorldColliderSet = null,
	layout_data: WorldLayoutData = null
) -> void:
	terrain = terrain_data
	colliders = collider_set
	layout = layout_data
	if colliders != null:
		colliders.prepare()


## Load the baked set. Returns null when the world has not been baked yet, which
## is a hard error for a demo but a survivable one for a tool.
static func load_baked() -> WorldQuery:
	if not ResourceLoader.exists(TERRAIN_PATH) or not ResourceLoader.exists(COLLIDER_PATH):
		push_error("WorldQuery: no baked world at res://data/world. Run build_world.gd.")
		return null
	var lay: WorldLayoutData = null
	if ResourceLoader.exists(LAYOUT_PATH):
		lay = load(LAYOUT_PATH) as WorldLayoutData
	return WorldQuery.new(
		load(TERRAIN_PATH) as WorldTerrainData, load(COLLIDER_PATH) as WorldColliderSet, lay
	)


func ground_h(x: float, z: float) -> float:
	return terrain.ground_h(x, z)


func ground_normal(x: float, z: float) -> Vector3:
	return terrain.ground_normal(x, z)


func surface_at_ground(x: float, z: float) -> int:
	return terrain.surface_at_ground(x, z)


## Highest walkable surface at (x, z) inside [lo, hi] — terrain or collider top.
## Returns NAN when there is nothing, because valid tops are often negative.
func top_at(x: float, z: float, lo: float, hi: float) -> float:
	var best: float = NAN
	var g: float = terrain.ground_h(x, z)
	if g >= lo and g <= hi:
		best = g
	var t: float = colliders.top_at(x, z, lo, hi)
	if not is_nan(t) and (is_nan(best) or t > best):
		best = t
	return best


## Room for a body `h` tall with its feet at `y`? `r` defaults to 92 % of the
## player capsule radius, which is the clearance the reference vaults through.
func can_stand(x: float, z: float, y: float, h: float, r: float = 0.3128) -> bool:
	if y < terrain.ground_h(x, z) - WorldColliderSet.GROUND_SLACK:
		return false
	return colliders.clear_above(x, z, y, h, r)


## Nearest hit along a ray against colliders and terrain both. Returns the
## distance, or `max_d` when nothing was hit; `hit_surface` and `hit_terrain`
## describe what was struck.
func raycast(origin: Vector3, dir: Vector3, max_d: float) -> float:
	var best: float = colliders.raycast_boxes(origin, dir, max_d)
	hit_surface = colliders.hit_surface
	hit_terrain = false
	var ground: float = terrain.raycast_terrain(origin, dir, minf(best, max_d))
	if ground < best:
		best = ground
		hit_terrain = true
		hit_surface = terrain.surface_at_ground(origin.x + dir.x * best, origin.z + dir.z * best)
	return best


## Convenience for spawners: a point on the ground with its normal, or `false`
## when the spot is occupied by a collider.
func ground_spot(x: float, z: float, clearance: float = 1.8) -> Vector3:
	return (
		Vector3(x, terrain.ground_h(x, z), z)
		if can_stand(x, z, terrain.ground_h(x, z), clearance)
		else Vector3(x, NAN, z)
	)
