class_name PlayerProbe
extends RefCounted
## The queries the kinematic controller needs that `move_and_collide` cannot answer:
## "would a body this tall fit here", "what is the highest solid surface over this
## point", "is that ledge actually just a ramp I could have walked up".
##
## The reference implements these against its own oriented-box array (`canStand`,
## `topAt`, `groundH`). Here they are physics-server queries, so they work against
## whatever colliders a demo actually contains — terrain, props, a baked town — with
## the same semantics and the same constants.
##
## One instance per controller. Both query objects and the sweep shape are allocated
## once and rewritten in place; a frame of movement adds no heap traffic beyond the
## result dictionaries the physics server hands back.

## Vertical slack at the feet when testing head room, metres. Straight from `canStand`.
const STAND_SLACK: float = 0.04
## Extra distance the downward probe starts above `hi`, so a surface exactly at `hi`
## is still hit rather than lost to the ray origin sitting on the plane.
const TOP_BIAS: float = 0.02

## Surface normal of the last `top_at` hit. Only meaningful when `top_at` returned a
## number; it is how the mantle tells a chest-high ledge from a steep bank.
var last_normal: Vector3 = Vector3.UP

var _space: PhysicsDirectSpaceState3D = null
var _shape_query: PhysicsShapeQueryParameters3D = PhysicsShapeQueryParameters3D.new()
var _ray_query: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.new()
var _cylinder: CylinderShape3D = CylinderShape3D.new()
var _hits: Array[Dictionary] = []


func _init() -> void:
	_shape_query.shape = _cylinder
	_shape_query.collide_with_bodies = true
	_shape_query.collide_with_areas = false
	_shape_query.margin = 0.0
	_ray_query.collide_with_bodies = true
	_ray_query.collide_with_areas = false
	_ray_query.hit_from_inside = false


## Point the probe at a space and tell it what to ignore. Call once per physics frame
## from the controller — `PhysicsDirectSpaceState3D` is only valid inside the physics
## step, so it must never be cached across frames.
func bind(space: PhysicsDirectSpaceState3D, exclude: Array[RID], mask: int) -> void:
	_space = space
	_shape_query.exclude = exclude
	_shape_query.collision_mask = mask
	_ray_query.exclude = exclude
	_ray_query.collision_mask = mask


func is_bound() -> bool:
	return _space != null


## Room for a body `height` tall standing on `feet`? The 0.04 slack at both ends is
## what stops the surface you are already standing on, and a ceiling you are already
## brushing, from reading as a blocker.
func can_stand(feet: Vector3, height: float, radius: float) -> bool:
	if _space == null:
		return false
	var clear: float = height - STAND_SLACK * 2.0
	if clear <= 0.02:
		return false
	_cylinder.radius = radius
	_cylinder.height = clear
	_shape_query.transform = Transform3D(
		Basis.IDENTITY, feet + Vector3(0.0, STAND_SLACK + clear * 0.5, 0.0)
	)
	_hits = _space.intersect_shape(_shape_query, 1)
	return _hits.is_empty()


## Highest solid surface over (x, z) within [lo, hi], or NAN when there is nothing.
## NAN rather than -INF because a valid top can legitimately be negative.
##
## A ray whose origin sits inside a collider reports nothing for that collider, which
## is exactly the reference's `if (t < lo || t > hi) continue` — geometry taller than
## `hi` is not a ledge you can reach, so it should not be found.
func top_at(x: float, z: float, lo: float, hi: float) -> float:
	if _space == null or hi <= lo:
		return NAN
	_ray_query.from = Vector3(x, hi + TOP_BIAS, z)
	_ray_query.to = Vector3(x, lo, z)
	var hit: Dictionary = _space.intersect_ray(_ray_query)
	if hit.is_empty():
		return NAN
	var point: Vector3 = hit["position"]
	if point.y < lo - 0.001 or point.y > hi + 0.001:
		return NAN
	last_normal = hit["normal"]
	return point.y


## Is the rise between `feet` and the surface at (to_x, to_z, top_y) something you
## could have walked up anyway?
##
## The reference answers this with `abs(t - groundH(px, pz)) < 0.07` — it knows which
## surfaces are terrain. With real colliders there is no such distinction, so the test
## becomes geometric: walk `samples` probes along the line and refuse to call it a
## ledge if every one of them is within a single step of the last. A ramp is a
## staircase with infinitely small steps; a ledge is the one that is not.
func is_walkable_ramp(feet: Vector3, to_x: float, to_z: float, top_y: float, step: float) -> bool:
	if _space == null:
		return false
	var prev: float = feet.y
	var samples: int = 3
	for i: int in range(1, samples + 1):
		var f: float = float(i) / float(samples)
		var sx: float = lerpf(feet.x, to_x, f)
		var sz: float = lerpf(feet.z, to_z, f)
		var here: float = top_at(sx, sz, prev - step, prev + step)
		if is_nan(here):
			return false
		prev = here
	return absf(prev - top_y) < 0.12
