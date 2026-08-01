class_name EnemyActor
extends CharacterBody3D
## One live creature: a body that animates, a weapon that fires, health that runs
## out, and a faction that decides who it runs out for.
##
## The actor is deliberately brainless. It owns the motor, the shell and the gun;
## the director owns the decisions and drives this through `steer()`, `engage()`
## and `look_at_point()`. That split is what lets the AI tick at its own budgeted
## rate while the body still moves and animates every physics frame.
##
## Locomotion never runs faster than the gait it is playing. `EnemyBody.clip_travel()`
## reports the metres per second the stride actually covers, and the motor clamps
## to it, so a foot can never skate — the classic tell of a creature moving at a
## number instead of at its animation.

## Health crossed zero. The corpse is still in the scene and still collides with
## bullets; the spawner recycles it once the collapse settles.
signal died(actor: EnemyActor)
## Damage landed and the body survived it.
signal hurt(amount: float, remaining: float, from_position: Vector3)
## The weapon fired. Mirrors `AICombat.fired` so VFX can hook one node.
signal fired(origin: Vector3, direction: Vector3, hit_position: Vector3, hit: Object)
## Ready for reuse: the fall has finished and the linger has elapsed.
signal recyclable(actor: EnemyActor)

## Below this speed the body idles rather than walking. A hair under the slowest
## species' walk so nothing dithers between clips.
const IDLE_SPEED: float = 0.18
## Hysteresis on the walk/run switch, as a fraction of the gap between them.
const RUN_HYSTERESIS: float = 0.12

@export_group("Species")
@export var species_id: StringName = &""
## Perception, weapon and courage numbers. Also the source of health and speed:
## the actor never reads the rig's derived stats directly, so a designer can tune
## an encounter without re-running the bestiary bake.
@export var profile: AISpeciesProfile = null

@export_group("Nodes")
@export var body_path: NodePath = NodePath("Body")
@export var target_path: NodePath = NodePath("Target")
@export var agent_path: NodePath = NodePath("NavAgent")
@export var shape_path: NodePath = NodePath("Shape")

@export_group("Motor")
## Downward acceleration. Hovering species ignore it entirely.
@export_range(0.0, 40.0, 0.1) var gravity: float = 22.0
## How hard the motor chases its requested velocity, in 1/s.
@export_range(1.0, 40.0, 0.1) var accel: float = 9.0
## Extra braking when the requested speed is zero, as a multiple of `accel`.
@export_range(1.0, 6.0, 0.05) var brake_scale: float = 1.6
## Yaw slew when no explicit look target is set, in rad/s. The profile's own
## `turn_rate` wins when a profile is present.
@export_range(0.5, 16.0, 0.05) var turn_rate: float = 4.5
## Ray length used to hold a hovering species off the floor.
@export_range(1.0, 40.0, 0.5) var hover_probe: float = 12.0
## How quickly a hovering body corrects its height, in 1/s.
@export_range(0.5, 20.0, 0.1) var hover_gain: float = 4.0

@export_group("Damage")
## Seconds a corpse lies there before the spawner may reclaim it.
@export_range(0.0, 60.0, 0.5) var corpse_linger: float = 8.0
## Loudness this body radiates at full sprint, for enemy hearing.
@export_range(0.0, 2.0, 0.01) var sprint_loudness: float = 1.0

## The weapon. Created on `configure()` and driven by `engage()`.
var weapon: AICombat = null
## Set by whoever owns the decisions. The actor never calls into it.
var brain: RefCounted = null
## Faction this body fights for, indexed as `Factions.F`. Mirrored onto the
## `AITarget`. Held as a plain int rather than read off the autoload so the bake
## can attach this script headlessly, where no autoload exists.
var faction: int = 0
var health: float = 1.0
var max_health: float = 1.0
var alive: bool = true

var _body: EnemyBody = null
var _target: AITarget = null
var _agent: NavigationAgent3D = null
var _shape: CollisionShape3D = null
var _want_dir: Vector3 = Vector3.ZERO
var _want_speed: float = 0.0
var _face_dir: Vector3 = Vector3.FORWARD
var _running: bool = false
var _hovering: bool = false
var _hover_height: float = 0.0
var _corpse_timer: float = 0.0
var _recycled: bool = false
var _hover_query: PhysicsRayQueryParameters3D = null
## This body's `AIPersonality.marksmanship`, resolved once in `configure`. Divides
## the aim cone; 0.7 to 1.4, so the best shot in a squad fires inside about half
## the cone of the worst one holding the same gun.
var _aim_quality: float = 1.0


func _ready() -> void:
	_resolve_nodes()
	collision_layer = GameLayers.ENEMY
	collision_mask = GameLayers.MASK_ENEMY_MOVE
	_hover_query = PhysicsRayQueryParameters3D.create(Vector3.ZERO, Vector3.ZERO)
	_hover_query.collision_mask = GameLayers.WORLD | GameLayers.PROP
	if _body != null:
		_body.collapse_settled.connect(_on_collapse_settled)
	if profile != null:
		configure(profile, faction, 0)


func _physics_process(delta: float) -> void:
	if not alive:
		_tick_corpse(delta)
		return
	_tick_motor(delta)
	_tick_facing(delta)
	_tick_clip()
	if _target != null:
		_target.motion_loudness = _loudness()


## Bind a species profile and a faction, and build the weapon. Safe to call again
## on a pooled actor: nothing is allocated twice.
func configure(species: AISpeciesProfile, new_faction: int, agent_id: int) -> void:
	profile = species
	faction = new_faction
	species_id = species.species_id
	max_health = maxf(1.0, species.health)
	health = max_health
	turn_rate = species.turn_rate
	# One body, one personality: the same key `AIPerception` is seeded with and the
	# same one `AITarget` draws its `AIMorale` against.
	_aim_quality = maxf(AIPersonality.of(maxi(agent_id, 1), species).marksmanship, 0.4)
	_hovering = species.hover_height > 0.0
	_hover_height = species.hover_height
	if weapon == null:
		weapon = AICombat.new(species, new_faction, agent_id)
		weapon.fired.connect(_on_weapon_fired)
		weapon.struck.connect(_on_weapon_struck)
	else:
		weapon.configure(species, new_faction, agent_id)
		weapon.reset()
	if _target != null:
		_target.faction = new_faction
		_target.body_radius = species.body_radius
		_target.aim_offset = Vector3(0.0, species.height * 0.62, 0.0)
		_target.eye_offset = Vector3(0.0, species.eye_height, 0.0)
	if _agent != null:
		_agent.radius = species.body_radius
		_agent.height = species.height
		_agent.max_speed = species.run_speed
	if _body != null:
		_body.set_faction_color(Palette.faction_color(new_faction))


## Requested heading and speed in world space. The direction is flattened; the
## motor supplies its own vertical.
func steer(direction: Vector3, speed: float) -> void:
	var flat := Vector3(direction.x, 0.0, direction.z)
	var l: float = flat.length()
	_want_dir = flat / l if l > 1e-4 else Vector3.ZERO
	_want_speed = maxf(0.0, speed)


## Stop moving without changing what the body is looking at.
func halt() -> void:
	_want_dir = Vector3.ZERO
	_want_speed = 0.0


## Face a world point. Overrides the default "face where you are going".
func look_at_point(p: Vector3) -> void:
	var d: Vector3 = p - global_position
	d.y = 0.0
	if d.length_squared() > 1e-6:
		_face_dir = d.normalized()


## Run one weapon step at the given believed target position. The muzzle comes
## from the rig, so the shot leaves the barrel the player can see.
func engage(
	delta: float,
	target_pos: Vector3,
	has_los: bool,
	targets: AITargetIndex,
	space: PhysicsDirectSpaceState3D,
	suppressive: bool
) -> void:
	if not alive or weapon == null:
		return
	var nerve: AIMorale = null if _target == null else _target.morale
	weapon.aim_scale = _aim_scale(nerve)
	# A routing body does not stop to shoot. Handing the weapon "no line of sight,
	# no suppressive intent" is the whole of it — `AICombat._may_fire` needs one of
	# the two to pull a trigger at all — and it costs no state inside the weapon.
	# ROUTING is the only state `AIMorale.may_shoot` refuses, so this is rare.
	if nerve != null and not nerve.may_shoot():
		has_los = false
		suppressive = false
	if _body != null:
		_body.aim_at(target_pos)
	weapon.tick(delta, muzzle_point(), target_pos, has_los, targets, space, suppressive)


## The cone multiplier this body earns: its own marksmanship, and how badly its
## nerve has gone. This is the ONLY place either reaches the trigger — both were
## rolled and ticked per body and read by nobody before it. `spread_scale` is
## bounded at 2.2 by `AIMorale`, so the worst a body coming apart can do is roughly
## double its own cone.
func _aim_scale(nerve: AIMorale) -> float:
	return (1.0 if nerve == null else nerve.spread_scale()) / _aim_quality


## Stop tracking: the body goes back to the clip's own rehearsal aim.
func disengage() -> void:
	if _body != null:
		_body.clear_aim()


## `AITarget` routes every hit here. `attacker` may be null for blast damage.
func apply_damage(amount: float, from_position: Vector3, _attacker: Node) -> void:
	if not alive:
		return
	var armour: float = 0.0 if profile == null else profile.armour
	var taken: float = amount * (1.0 - clampf(armour, 0.0, 95.0) * 0.01)
	health -= taken
	if health <= 0.0:
		health = 0.0
		_die(from_position)
		return
	hurt.emit(taken, health, from_position)
	if _body != null:
		_body.react_to_hit(taken, max_health)
	if weapon != null:
		weapon.take_suppression(taken / max_health)


## Damage with a known impact point, so the head, core and limb multipliers the
## bestiary derived actually apply. This is the path a shooter that traced a ray
## should use; `apply_damage` is the blunt fallback for blast and script damage.
func apply_damage_at(
	amount: float, hit_point: Vector3, from_position: Vector3, attacker: Node, crit: float = 1.0
) -> void:
	if not alive or _body == null or _body.species_stats == null:
		apply_damage(amount, from_position, attacker)
		return
	var zone: StringName = _body.zone_at(hit_point)
	apply_damage(_body.species_stats.apply_damage(amount, zone, crit), from_position, attacker)


## The entry point `GunDamage` looks for, and the only route a bullet takes into a
## creature. The zone it offers came off collider metadata this body does not carry;
## the rig resolves the zone from the impact point instead, which is finer than any
## capsule, so the argument is accepted and dropped.
##
## `dir` is the round's unit direction, so a metre back along it is a point on the
## shot line. Every consumer of `from_position` wants the bearing and not the range,
## so one metre is as good as the true muzzle and costs nothing to know.
func apply_bullet_damage(
	amount: float, at: Vector3, _normal: Vector3, dir: Vector3, _zone: StringName, crit: float
) -> void:
	apply_damage_at(amount, at, at - dir, null, crit)


## Kill outright, skipping the damage maths. Used by scripted removals.
func kill(from_position: Vector3 = Vector3.ZERO) -> void:
	if alive:
		health = 0.0
		_die(from_position)


## Take a pooled actor out of service: the mirror of `revive()`. Every clock this
## actor owns stops, including the rig's — a parked body that keeps posing costs a
## skeleton write per bone for nothing.
func sleep() -> void:
	set_physics_process(false)
	velocity = Vector3.ZERO
	visible = false
	if _body != null:
		_body.sleep()


## Put a pooled actor back into service at `where`, facing `facing`.
func revive(where: Transform3D, seed_value: int, take: int) -> void:
	global_transform = where
	velocity = Vector3.ZERO
	_want_dir = Vector3.ZERO
	_want_speed = 0.0
	_face_dir = -where.basis.z
	_corpse_timer = 0.0
	_recycled = false
	alive = true
	health = max_health
	if weapon != null:
		weapon.reset()
	if _shape != null:
		_shape.disabled = false
	collision_layer = GameLayers.ENEMY
	if _target != null:
		_target.alive = true
		_target.motion_loudness = 0.0
	if _body != null:
		_body.revive(seed_value, take)
	set_physics_process(true)
	visible = true


## World-space bore origin, straight off the rig.
func muzzle_point() -> Vector3:
	if _body != null:
		return _body.muzzle_point()
	var h: float = 1.2 if profile == null else profile.eye_height
	return global_position + Vector3(0.0, h, 0.0)


func body() -> EnemyBody:
	return _body


func target() -> AITarget:
	return _target


func nav_agent() -> NavigationAgent3D:
	return _agent


## Fraction of maximum health remaining, in [0, 1].
func health_fraction() -> float:
	return clampf(health / max_health, 0.0, 1.0)


func _tick_motor(delta: float) -> void:
	var want: Vector3 = _want_dir * _clamped_speed()
	var rate: float = accel * (brake_scale if _want_speed <= 0.0 else 1.0)
	var k: float = clampf(rate * delta, 0.0, 1.0)
	velocity.x = lerpf(velocity.x, want.x, k)
	velocity.z = lerpf(velocity.z, want.z, k)
	if _hovering:
		velocity.y = lerpf(velocity.y, _hover_correction(), clampf(hover_gain * delta, 0.0, 1.0))
	elif is_on_floor():
		velocity.y = minf(velocity.y, 0.0)
	else:
		velocity.y -= gravity * delta
	move_and_slide()


## The gait, not the request, decides how fast the body actually travels.
func _clamped_speed() -> float:
	if _body == null:
		return _want_speed
	var stride: float = _body.clip_travel()
	if stride <= 0.0:
		return _want_speed
	return minf(_want_speed, stride)


func _hover_correction() -> float:
	if _hover_height <= 0.0:
		return 0.0
	_hover_query.from = global_position + Vector3(0.0, 0.4, 0.0)
	_hover_query.to = global_position - Vector3(0.0, hover_probe, 0.0)
	var hit: Dictionary = get_world_3d().direct_space_state.intersect_ray(_hover_query)
	if hit.is_empty():
		return -gravity * 0.05
	var want_y: float = Vector3(hit["position"]).y + _hover_height
	return clampf(want_y - global_position.y, -4.0, 4.0) * hover_gain


func _tick_facing(delta: float) -> void:
	if _want_speed > IDLE_SPEED and _want_dir.length_squared() > 1e-6:
		_face_dir = _want_dir
	if _face_dir.length_squared() < 1e-6:
		return
	var want: float = atan2(_face_dir.x, _face_dir.z)
	rotation.y = rotate_toward(rotation.y, want, turn_rate * delta)


func _tick_clip() -> void:
	if _body == null or _body.is_dead():
		return
	var speed: float = Vector2(velocity.x, velocity.z).length()
	if speed <= IDLE_SPEED:
		_running = false
		_body.play_clip(String(BeastClips.IDLE))
		return
	var walk: float = 1.2 if profile == null else profile.walk_speed
	var run: float = 3.4 if profile == null else profile.run_speed
	var band: float = (run - walk) * RUN_HYSTERESIS
	var gate: float = (walk + run) * 0.5 + (-band if _running else band)
	_running = speed >= gate
	_body.play_clip(String(BeastClips.RUN if _running else BeastClips.WALK))


func _loudness() -> float:
	var speed: float = Vector2(velocity.x, velocity.z).length()
	var run: float = 3.4 if profile == null else profile.run_speed
	return clampf(speed / maxf(run, 0.1), 0.0, 1.0) * sprint_loudness


func _die(from_position: Vector3) -> void:
	alive = false
	_corpse_timer = 0.0
	_want_speed = 0.0
	_want_dir = Vector3.ZERO
	velocity = Vector3.ZERO
	if _target != null:
		_target.mark_dead()
		_target.motion_loudness = 0.0
	if _shape != null:
		_shape.disabled = true
	if _body != null:
		_body.clear_aim()
		_body.collapse()
	died.emit(self)
	if from_position != Vector3.ZERO:
		look_at_point(from_position)


func _tick_corpse(delta: float) -> void:
	if _recycled:
		return
	_corpse_timer += delta
	if _corpse_timer < corpse_linger:
		return
	if _body != null and not _body.has_settled():
		return
	_recycled = true
	recyclable.emit(self)


func _on_collapse_settled() -> void:
	if _corpse_timer >= corpse_linger and not _recycled:
		_recycled = true
		recyclable.emit(self)


func _on_weapon_fired(
	origin: Vector3, direction: Vector3, hit_position: Vector3, hit: Object
) -> void:
	if _body != null:
		_body.play_clip(String(BeastClips.ATTACK))
	fired.emit(origin, direction, hit_position, hit)


func _on_weapon_struck(_hit: AITarget, _damage: float) -> void:
	if _body != null:
		_body.play_clip(String(BeastClips.ATTACK))


func _resolve_nodes() -> void:
	_body = get_node_or_null(body_path) as EnemyBody
	_target = get_node_or_null(target_path) as AITarget
	_agent = get_node_or_null(agent_path) as NavigationAgent3D
	_shape = get_node_or_null(shape_path) as CollisionShape3D
	if _body == null:
		push_error("EnemyActor '%s': body_path does not resolve to an EnemyBody." % name)
	if _target == null:
		push_error("EnemyActor '%s': target_path does not resolve to an AITarget." % name)
