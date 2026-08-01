class_name GunProjectilePool
extends Resource
## The slow half of the ballistics: rounds that take time to arrive.
##
## Range spec 13.4. Anything past the weapon's instant window becomes a real
## projectile, spawned at the edge of that window and integrated forward with
## gravity until it hits something, falls below the floor or runs out of range.
## Launchers are always projectiles, which is what makes a rocket something you can
## watch, lead and dodge.
##
## Two deliberate cheats are kept from the reference. Gravity is 9.0 m/s², not 9.81,
## because the arc has to read at range-sized distances. And `GunSpec.sim_velocity`
## is already half the true muzzle velocity for the same reason. Both are exported;
## setting `gravity` to 9.81 and using `muzzle_velocity` gives you real physics and
## an unreadable game.
##
## The whole pool is struct-of-arrays over a fixed ring of slots. Nothing is
## allocated after `configure()` — a launcher firing into a crowd must not stutter.

## Rounds in flight at once. Oldest is silently reused when the ring wraps.
@export_range(8, 256, 1) var pool_size: int = 64
## Downward acceleration, m/s². The reference's readability cheat is 9.0.
@export_range(0.0, 30.0, 0.1) var gravity: float = 9.0
## Velocity lost per second to air, as a rate constant. 0 is the reference exactly.
@export_range(0.0, 0.5, 0.001) var air_drag: float = 0.02
## Drag on a fin-stabilised rocket, which sheds speed faster than a bullet.
@export_range(0.0, 1.0, 0.001) var explosive_air_drag: float = 0.06
## Seconds a round stays in the air before it is written off.
@export_range(0.5, 30.0, 0.1) var lifetime: float = 6.0
## Height below which a round is considered to have buried itself.
@export_range(-100.0, 0.0, 0.5) var floor_height: float = -3.0
## Metres of travel after which a round is written off.
@export_range(100.0, 4000.0, 10.0) var max_travel: float = 1900.0
## Metres between smoke puffs from a rocket, and from a heavy bullet.
@export_range(0.2, 20.0, 0.1) var smoke_gap_explosive: float = 1.2
@export_range(1.0, 60.0, 0.5) var smoke_gap_bullet: float = 9.0
## Bore, mm, above which a plain bullet leaves a visible trail at all.
@export_range(1.0, 40.0, 0.5) var smoke_bore_threshold: float = 8.0
## Streak length is `min(step * scale + base, cap)`, metres.
@export_range(0.5, 20.0, 0.1) var streak_scale: float = 2.6
@export_range(0.0, 10.0, 0.1) var streak_base: float = 0.4
@export_range(0.5, 40.0, 0.5) var streak_cap: float = 5.0
@export_range(0.5, 20.0, 0.1) var streak_scale_explosive: float = 6.5
@export_range(0.0, 10.0, 0.1) var streak_base_explosive: float = 2.4
@export_range(0.5, 80.0, 0.5) var streak_cap_explosive: float = 26.0

## Called on arrival: `(collider, position, normal, distance, damage, spec, direction)`.
var on_impact: Callable = Callable()
## Called every step for every live round: `(index, tail, head, explosive)`.
var on_streak: Callable = Callable()
## Called when a round has travelled far enough to shed smoke: `(position, explosive)`.
var on_smoke: Callable = Callable()

var _live: PackedByteArray = PackedByteArray()
var _explosive: PackedByteArray = PackedByteArray()
var _pos: PackedVector3Array = PackedVector3Array()
var _vel: PackedVector3Array = PackedVector3Array()
var _life: PackedFloat32Array = PackedFloat32Array()
var _damage: PackedFloat32Array = PackedFloat32Array()
var _travel: PackedFloat32Array = PackedFloat32Array()
var _since_smoke: PackedFloat32Array = PackedFloat32Array()
var _spec: Array[GunSpec] = []
var _head: int = 0
var _count: int = 0


func _init() -> void:
	resource_local_to_scene = true


## Size the ring. Safe to call again; anything in flight is dropped.
func configure() -> void:
	var n: int = maxi(pool_size, 1)
	_live.resize(n)
	_explosive.resize(n)
	_pos.resize(n)
	_vel.resize(n)
	_life.resize(n)
	_damage.resize(n)
	_travel.resize(n)
	_since_smoke.resize(n)
	_spec.resize(n)
	clear()


func active_count() -> int:
	return _count


func capacity() -> int:
	return _live.size()


## Put a round in the air. `travelled` is how far it already flew as a ray, so
## damage falloff stays continuous across the hitscan-to-projectile handover.
func spawn(
	pos: Vector3, dir: Vector3, speed: float, spec: GunSpec, dmg: float, travelled: float
) -> void:
	if _live.is_empty():
		configure()
	var i: int = _head
	_head = (_head + 1) % _live.size()
	if _live[i] == 0:
		_count += 1
	_live[i] = 1
	_explosive[i] = 1 if spec.explosive else 0
	_pos[i] = pos
	_vel[i] = dir * maxf(speed, 1.0)
	_life[i] = lifetime
	_damage[i] = dmg
	_travel[i] = travelled
	_since_smoke[i] = 0.0
	_spec[i] = spec
	if spec.explosive and on_smoke.is_valid():
		on_smoke.call(pos, true)


## Integrate every live round one physics tick and sweep its path for hits.
func step(
	delta: float, space: PhysicsDirectSpaceState3D, hitscan: GunHitscan, exclude: Array[RID]
) -> void:
	if _count <= 0 or delta <= 0.0:
		return
	for i: int in _live.size():
		if _live[i] == 0:
			continue
		_step_one(i, delta, space, hitscan, exclude)


func clear() -> void:
	for i: int in _live.size():
		_live[i] = 0
		_spec[i] = null
	_count = 0
	_head = 0


func _step_one(
	i: int, delta: float, space: PhysicsDirectSpaceState3D, hitscan: GunHitscan, exclude: Array[RID]
) -> void:
	var explosive: bool = _explosive[i] == 1
	var prev: Vector3 = _pos[i]
	var vel: Vector3 = _vel[i]
	vel.y -= gravity * delta
	var drag: float = explosive_air_drag if explosive else air_drag
	if drag > 0.0:
		vel *= exp(-drag * delta)
	var next: Vector3 = prev + vel * delta
	var step_len: float = prev.distance_to(next)
	_vel[i] = vel
	_pos[i] = next
	_life[i] -= delta
	_travel[i] += step_len
	if step_len > 1.0e-4 and hitscan != null:
		var hit: Dictionary = hitscan.cast_segment(space, prev, next, exclude)
		if not hit.is_empty():
			_impact(i, hit)
			return
	if _life[i] <= 0.0 or next.y < floor_height or _travel[i] > max_travel:
		_retire(i)
		return
	_trail(i, prev, next, step_len, explosive)


func _trail(i: int, prev: Vector3, next: Vector3, step_len: float, explosive: bool) -> void:
	_since_smoke[i] += step_len
	var gap: float = smoke_gap_explosive if explosive else smoke_gap_bullet
	var spec: GunSpec = _spec[i]
	var smokes: bool = explosive or (spec != null and spec.bore >= smoke_bore_threshold)
	if smokes and _since_smoke[i] > gap:
		_since_smoke[i] = 0.0
		if on_smoke.is_valid():
			on_smoke.call(next, explosive)
	if not on_streak.is_valid():
		return
	var scale: float = streak_scale_explosive if explosive else streak_scale
	var base: float = streak_base_explosive if explosive else streak_base
	var cap: float = streak_cap_explosive if explosive else streak_cap
	var back: float = minf(step_len * scale + base, cap)
	var dir: Vector3 = (next - prev).normalized() if step_len > 1.0e-5 else Vector3.FORWARD
	on_streak.call(i, next - dir * back, next, explosive)


func _impact(i: int, hit: Dictionary) -> void:
	var at: Vector3 = hit["position"]
	var normal: Vector3 = hit.get("normal", Vector3.UP)
	var spec: GunSpec = _spec[i]
	var dmg: float = _damage[i]
	var dist: float = _travel[i]
	var vel: Vector3 = _vel[i]
	var dir: Vector3 = vel.normalized() if vel.length_squared() > 1.0e-8 else -normal
	_retire(i)
	if on_impact.is_valid():
		on_impact.call(hit.get("collider"), at, normal, dist, dmg, spec, dir)


func _retire(i: int) -> void:
	if _live[i] == 0:
		return
	_live[i] = 0
	_spec[i] = null
	_count -= 1
