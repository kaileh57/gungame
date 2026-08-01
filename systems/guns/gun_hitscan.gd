class_name GunHitscan
extends Resource
## The instant half of the ballistics: a ray, and what it goes through.
##
## Range spec 12.2 is blunt about it — the reference has no penetration model, a
## round stops at the first valid surface, always. That is reproduced exactly by
## leaving `max_penetrations` at 0.
##
## Above 0 this spends the round's muzzle energy: each surface costs joules to punch
## through, taken from `PENETRATION_COST` and scaled by how far the ray travelled
## inside the last thing it hit. A 300 J pistol round stops in the first sheet of
## tin. A 4,000 J rifle round goes through the tin, the crate behind it and the
## thing hiding behind the crate, arriving each time with less to give.
##
## Callers set `on_hit` once and then call `trace()`. Every surface the round
## resolves against, in order, comes back through that callable; the return value is
## the point the tracer should be drawn to.

## Joules it costs to pass through one metre of each `VFXSurface.Kind`. Index
## aligned with `VFXSurface.NAMES`; paper and cloth barely notice a bullet.
const PENETRATION_COST: PackedFloat32Array = [
	900.0,
	250.0,
	200.0,
	420.0,
	1400.0,
	150.0,
	60.0,
	900.0,
	1800.0,
	760.0,
	80.0,
	15.0,
	400.0,
	260.0,
	620.0,
	540.0,
	180.0
]

## Longest a ray is traced, metres. The reference uses 2,000.
@export_range(50.0, 4000.0, 10.0) var max_distance: float = 2000.0
## How far a tracer is drawn when the round hits nothing.
@export_range(50.0, 2000.0, 10.0) var miss_distance: float = 1200.0
## Surfaces a single round may punch through. 0 is the reference's behaviour.
@export_range(0, 6, 1) var max_penetrations: int = 2
## Damage a round keeps after each surface it goes through.
@export_range(0.05, 1.0, 0.01) var penetration_damage_retained: float = 0.62
## Assumed thickness, metres, of a surface the ray cannot measure. Every cost in
## `PENETRATION_COST` is per metre, so this is what one wall actually charges.
@export_range(0.01, 1.0, 0.01) var assumed_thickness: float = 0.12
## Nudge past a surface before re-casting, metres. Below the physics contact
## margin the ray re-hits the face it just left and the loop stalls.
@export_range(0.001, 0.2, 0.001) var advance_epsilon: float = 0.02
## What a ray is allowed to hit.
@export_flags_3d_physics var collision_mask: int = GameLayers.MASK_BULLET

## `on_hit(collider, position, normal, distance, damage_scale, surface)`.
## `damage_scale` is falloff-free: it is 1.0 on the first surface and drops with
## each one penetrated. The caller applies range falloff from `distance`.
var on_hit: Callable = Callable()

var _query: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.new()
var _energy: float = 0.0
var _damage_owner: GunDamage = null


func _init() -> void:
	resource_local_to_scene = true
	_query.collide_with_bodies = true
	_query.collide_with_areas = true


## `damage` is borrowed to read surface ids off colliders; it is never mutated.
func configure(spec: GunSpec, damage: GunDamage) -> void:
	_energy = maxf(float(spec.muzzle_energy), 0.0)
	_damage_owner = damage


## Joules this round has to spend punching through things.
func energy() -> float:
	return _energy


## Cost, in joules, of getting through one surface of `kind`.
func surface_cost(kind: int) -> float:
	var i: int = clampi(kind, 0, PENETRATION_COST.size() - 1)
	return PENETRATION_COST[i] * assumed_thickness


## Cast one round. Reports every surface it resolves against through `on_hit` and
## returns the point a tracer should end at.
func trace(
	space: PhysicsDirectSpaceState3D,
	origin: Vector3,
	dir: Vector3,
	limit: float,
	exclude: Array[RID]
) -> Vector3:
	var reach: float = minf(limit, max_distance)
	var end: Vector3 = origin + dir * minf(miss_distance, reach)
	if space == null:
		return end
	var from: Vector3 = origin
	var travelled: float = 0.0
	var budget: float = _energy
	var scale: float = 1.0
	for pass_index: int in max_penetrations + 1:
		var hit: Dictionary = _cast(space, from, dir, reach - travelled, exclude)
		if hit.is_empty():
			return end if pass_index == 0 else from
		var at: Vector3 = hit["position"]
		travelled += from.distance_to(at)
		_report(hit, at, travelled, scale)
		if pass_index >= max_penetrations:
			return at
		var cost: float = surface_cost(_surface_of(hit))
		if cost > budget:
			return at
		budget -= cost
		scale *= penetration_damage_retained
		from = at + dir * advance_epsilon
		travelled += advance_epsilon
		end = at
	return end


## Single ray, no penetration. For line-of-sight tests and the projectile sweep.
func cast_segment(
	space: PhysicsDirectSpaceState3D, from: Vector3, to: Vector3, exclude: Array[RID]
) -> Dictionary:
	if space == null:
		return {}
	_query.from = from
	_query.to = to
	_query.collision_mask = collision_mask
	_query.exclude = exclude
	return space.intersect_ray(_query)


func _cast(
	space: PhysicsDirectSpaceState3D, from: Vector3, dir: Vector3, reach: float, exclude: Array[RID]
) -> Dictionary:
	if reach <= 0.0:
		return {}
	return cast_segment(space, from, from + dir * reach, exclude)


func _report(hit: Dictionary, at: Vector3, travelled: float, scale: float) -> void:
	if not on_hit.is_valid():
		return
	var normal: Vector3 = hit.get("normal", Vector3.UP)
	on_hit.call(hit.get("collider"), at, normal, travelled, scale, _surface_of(hit))


func _surface_of(hit: Dictionary) -> int:
	if _damage_owner == null:
		return VFXSurface.Kind.METAL
	return _damage_owner.surface_of(hit.get("collider"))
