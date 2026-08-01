class_name GunDamage
extends Resource
## What a round does when it arrives: falloff, zones, impulse and blast.
##
## Range spec 13.1 gives the falloff — `1 - (d/range)^1.7 * 0.88`, floored at 0.10.
## The exponent is the interesting part: it keeps damage near-flat over the first
## half of the effective range and then drops it off a cliff, so `effective_range`
## reads as a real number rather than a slow fade. At exactly `range` a round does
## 12 % of its damage.
##
## Zones come from 13.2. A head hit takes the full `GunSpec.crit_multiplier`; a core
## hit takes 45 % of the bonus. The reference never sets `core` — the branch exists
## for the creature port, and it is used here.
##
## What a hit collider must advertise, all optional, all read through `get_meta`:
##   `zone`    — `head` / `core` / `limb` / `body`. Absent reads as `body`.
##   `surface` — any key `VFXSurface.ALIASES` knows. Absent reads as `metal`.
## What a damageable node may implement, first match up the parent chain wins:
##   `apply_bullet_damage(amount, at, normal, direction, zone, crit)`
##   `take_damage(amount)`
##
## `zone` is only what the collider advertised; a receiver that can resolve the
## zone better from `at` — a posed creature rig, say — should ignore it. `crit` is
## the weapon's headshot multiplier, forwarded untouched so a receiver doing its
## own zone maths applies the same bonus this class would have.

## Zone ids a collider may carry.
const ZONE_HEAD: StringName = &"head"
const ZONE_CORE: StringName = &"core"
const ZONE_LIMB: StringName = &"limb"
const ZONE_BODY: StringName = &"body"
## Methods tried, in order, on the collider and then its ancestors.
const DAMAGE_METHODS: PackedStringArray = ["apply_bullet_damage", "take_damage"]
## How far up the parent chain to look for something that can take damage.
const RECEIVER_SEARCH_DEPTH: int = 4

## Falloff curve exponent. Above 1 the near half of the range stays lethal.
@export_range(0.5, 4.0, 0.05) var falloff_exponent: float = 1.7
## How much damage the curve removes by the time it reaches the effective range.
@export_range(0.0, 1.0, 0.01) var falloff_depth: float = 0.88
## Damage floor past the effective range. A round is never harmless.
@export_range(0.0, 1.0, 0.01) var falloff_floor: float = 0.10
## Shortest effective range the curve is evaluated against, metres. Stops a
## derringer with an 8 m range from falling off inside its own muzzle blast.
@export_range(1.0, 40.0, 0.5) var falloff_minimum_range: float = 8.0
## Share of the crit bonus a centre-mass hit collects.
@export_range(0.0, 1.0, 0.01) var core_crit_share: float = 0.45
## Multiplier on a limb hit. The reference has no limbs and would use 1.0.
@export_range(0.1, 1.0, 0.01) var limb_scale: float = 0.85
## Newton-seconds of push per unit of `GunSpec.impulse` landed on a rigid body.
@export_range(0.0, 20.0, 0.05) var impulse_scale: float = 3.0
## Blast falloff exponent. 1.0 is the reference's linear `1 - d/radius`.
@export_range(0.25, 4.0, 0.05) var blast_exponent: float = 1.0
## What a blast does to something it cannot see. 0 makes cover absolute.
@export_range(0.0, 1.0, 0.01) var blast_occluded_scale: float = 0.25
## Slack, metres, before an occluder between the blast and a target counts.
@export_range(0.0, 1.0, 0.01) var blast_occlusion_slack: float = 0.15
## Ceiling on bodies one blast resolves against.
@export_range(1, 128, 1) var blast_max_bodies: int = 48

var _sphere: SphereShape3D = SphereShape3D.new()
var _shape_query: PhysicsShapeQueryParameters3D = PhysicsShapeQueryParameters3D.new()
var _ray_query: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.new()
var _no_exclude: Array[RID] = []


func _init() -> void:
	resource_local_to_scene = true
	_shape_query.shape = _sphere
	_shape_query.collide_with_bodies = true
	_shape_query.collide_with_areas = true
	_ray_query.collide_with_bodies = true
	_ray_query.collide_with_areas = false


## Damage multiplier at `distance` metres for a weapon with `effective_range`.
func falloff(distance: float, effective_range: float) -> float:
	var span: float = maxf(effective_range, falloff_minimum_range)
	var t: float = pow(maxf(distance, 0.0) / span, falloff_exponent) * falloff_depth
	return clampf(1.0 - t, falloff_floor, 1.0)


## Zone id a collider advertises.
func zone_of(collider: Object) -> StringName:
	var node: Node = collider as Node
	if node == null:
		return ZONE_BODY
	return StringName(node.get_meta(&"zone", ZONE_BODY))


## Surface key a collider advertises, folded onto a `VFXSurface.Kind`.
func surface_of(collider: Object) -> int:
	var node: Node = collider as Node
	if node == null:
		return VFXSurface.Kind.METAL
	return VFXSurface.from_key(StringName(node.get_meta(&"surface", &"metal")))


## Multiplier a zone applies for a weapon with this crit multiplier.
func zone_multiplier(zone: StringName, crit: float) -> float:
	if zone == ZONE_HEAD:
		return crit
	if zone == ZONE_CORE:
		return 1.0 + (crit - 1.0) * core_crit_share
	if zone == ZONE_LIMB:
		return limb_scale
	return 1.0


## Final damage for one round arriving at `distance` on `zone`.
func resolve(base: float, distance: float, spec: GunSpec, zone: StringName) -> float:
	var amount: float = base * falloff(distance, float(spec.effective_range))
	return amount * zone_multiplier(zone, spec.crit_multiplier)


## Hand `amount` to whatever owns `collider`. Returns true when something took it.
func apply(
	collider: Object, amount: float, at: Vector3, normal: Vector3, dir: Vector3, crit: float = 1.0
) -> bool:
	var zone: StringName = zone_of(collider)
	var node: Node = collider as Node
	var depth: int = 0
	while node != null and depth <= RECEIVER_SEARCH_DEPTH:
		if node.has_method(DAMAGE_METHODS[0]):
			node.call(DAMAGE_METHODS[0], amount, at, normal, dir, zone, crit)
			return true
		if node.has_method(DAMAGE_METHODS[1]):
			node.call(DAMAGE_METHODS[1], amount)
			return true
		node = node.get_parent()
		depth += 1
	return false


## Push a loose body. Static geometry and characters ignore this by construction.
func push(collider: Object, at: Vector3, dir: Vector3, impulse: float) -> void:
	var body: RigidBody3D = collider as RigidBody3D
	if body == null or impulse <= 0.0:
		return
	body.apply_impulse(dir * impulse * impulse_scale, at - body.global_position)


## Resolve an explosion. Every body inside `radius` takes `damage` scaled by
## distance and by whether the blast could see it. Returns how many were hit.
func blast(
	space: PhysicsDirectSpaceState3D,
	center: Vector3,
	damage: float,
	radius: float,
	exclude: Array[RID]
) -> int:
	if space == null or radius <= 0.0:
		return 0
	_sphere.radius = radius
	_shape_query.transform = Transform3D(Basis(), center)
	_shape_query.collision_mask = GameLayers.MASK_PROJECTILE
	_shape_query.exclude = exclude
	var found: Array[Dictionary] = space.intersect_shape(_shape_query, blast_max_bodies)
	var seen: Dictionary = {}
	var hits: int = 0
	for entry: Dictionary in found:
		if _resolve_blast_body(space, center, damage, radius, entry, seen):
			hits += 1
	return hits


## One candidate body inside the blast sphere. `seen` deduplicates the several
## hitboxes a single creature presents to the sphere query.
func _resolve_blast_body(
	space: PhysicsDirectSpaceState3D,
	center: Vector3,
	damage: float,
	radius: float,
	entry: Dictionary,
	seen: Dictionary
) -> bool:
	var collider: Node3D = entry.get("collider") as Node3D
	if collider == null:
		return false
	var key: int = collider.get_instance_id()
	if seen.has(key):
		return false
	seen[key] = true
	var at: Vector3 = collider.global_position
	var offset: Vector3 = at - center
	var distance: float = offset.length()
	var reach: float = clampf(1.0 - distance / radius, 0.0, 1.0)
	if reach <= 0.0:
		return false
	var scale: float = pow(reach, blast_exponent)
	if _is_occluded(space, center, at, distance):
		scale *= blast_occluded_scale
	if scale <= 0.0:
		return false
	var dir: Vector3 = offset.normalized() if distance > 0.001 else Vector3.UP
	push(collider, at, dir, damage * scale * 0.02)
	return apply(collider, damage * scale, at, -dir, dir)


## True when solid geometry stands between the blast and the point.
func _is_occluded(
	space: PhysicsDirectSpaceState3D, center: Vector3, at: Vector3, distance: float
) -> bool:
	if distance <= blast_occlusion_slack:
		return false
	_ray_query.from = center
	_ray_query.to = at
	_ray_query.collision_mask = GameLayers.MASK_BLAST_OCCLUDER
	_ray_query.exclude = _no_exclude
	var hit: Dictionary = space.intersect_ray(_ray_query)
	if hit.is_empty():
		return false
	var blocked: float = center.distance_to(hit.get("position", at) as Vector3)
	return blocked < distance - blast_occlusion_slack
