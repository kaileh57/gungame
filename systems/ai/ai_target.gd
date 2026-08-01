class_name AITarget
extends Node3D
## Marks a body as something the AI can see, hear, shoot at and hurt. Add one as a
## child of the player and of every agent; nothing else in the world is a target.
##
## This node is deliberately passive: it has no `_process`, and everything below
## that looks like it needs a clock is driven from `AITargetIndex`'s own budgeted
## refresh instead. Sixty of these must cost nothing when nobody is looking, and a
## node that ticks itself sixty times a second is the opposite of that.
##
## It carries four things beyond a position and a faction, and they are the four
## the perception model actually argues about:
##
## - **Stance.** A crouched silhouette is genuinely harder to pick out than a
##   standing one and a prone one harder still. The player's crouch is read
##   straight off its controller, so ducking behind a crate is worth something
##   without anybody having to remember to tell the AI about it.
## - **Exposure.** One rate-limited ray toward the sun says whether this body is
##   standing in light or in shadow. It is a property of the TARGET, not of the
##   observer, so sixty agents share one answer instead of casting sixty rays.
## - **Footfall.** Distance travelled is accumulated and turned into real noise
##   events on `AINoiseBus` at a stride cadence, scaled by speed and stance. This
##   is what makes sprinting past a patrol a mistake and creeping past it a plan.
## - **Morale and flinch.** Damage arrives here, so this is where a body's nerve
##   and its stagger are kept. `AIMorale` reads the health off whatever takes the
##   damage; the flinch is measured from the size of the bite the hit took.

## A shot or a blast landed. `attacker` may be null for environmental damage.
signal damaged(amount: float, from_position: Vector3, attacker: Node)
## The target stopped being a target. Emitted once, on the transition.
signal died

enum Stance { STAND, CROUCH, PRONE }

const STANCE_NAMES: PackedStringArray = ["STAND", "CROUCH", "PRONE"]
## Crouch blend above which a body counts as ducked. Matches `PlayerState`.
const CROUCH_THRESHOLD: float = 0.55
## Nodes one scene walk will look at while hunting for the sun and the fog.
const WORLD_WALK_LIMIT: int = 900
## Metres the sun probe reaches. Long enough to clear a building, short enough
## that it does not charge for the whole map.
const SUN_PROBE: float = 26.0

## Sun and haze are scene properties, resolved once per scene and shared by every
## body in it. Held statically because there is exactly one of each.
static var _sun_to: Vector3 = Vector3.UP
static var _has_sun: bool = false
static var _scene_stamp: int = 0

## Faction this body fights for. `-1` is the player, `-2` is nobody's business.
@export_range(-2, 2, 1) var faction: int = -1
## Aim point relative to this node — chest height for a humanoid. The AI shoots at
## this, not at the node origin, so a target parented at the feet still works.
@export var aim_offset: Vector3 = Vector3(0.0, 1.25, 0.0)
## Eye point relative to this node. Perception traces to here.
@export var eye_offset: Vector3 = Vector3(0.0, 1.62, 0.0)
## Silhouette radius, metres. Feeds hit resolution and the do-not-shoot-through-
## a-teammate corridor test.
@export_range(0.1, 3.0, 0.01) var body_radius: float = 0.36
## Multiplier on how fast an observer builds awareness. Below 1 is hard to see.
## This is the AUTHORED value; `effective_visibility` folds stance and light in.
@export_range(0.05, 4.0, 0.01) var visibility: float = 1.0
## Collider the AI's shots will actually hit. Defaults to the parent node.
@export var body_path: NodePath = NodePath("..")
## Node that takes damage. Must expose `apply_damage(amount, from_position,
## attacker)`. Defaults to the parent node.
@export var receiver_path: NodePath = NodePath("..")

@export_group("Silhouette")
## Visibility multipliers for the two ducked stances.
@export_range(0.05, 1.0, 0.01) var crouch_visibility: float = 0.6
@export_range(0.05, 1.0, 0.01) var prone_visibility: float = 0.34
## Visibility floor for a body holding perfectly still, reached at zero speed.
@export_range(0.1, 1.0, 0.01) var still_visibility: float = 0.72
## Speed, m/s, at which the stillness penalty is fully paid off.
@export_range(0.2, 8.0, 0.05) var motion_reference: float = 2.0
## Visibility multiplier while the sun cannot reach this body.
@export_range(0.05, 1.0, 0.01) var shadow_visibility: float = 0.62
## Seconds between sun probes. Ten bodies at 0.7 s is fourteen rays a second.
@export_range(0.1, 8.0, 0.05) var shadow_interval: float = 0.7
## Off for anything that should never pay for a probe — a training dummy, a
## target in a room with no sun.
@export var shadow_probe_enabled: bool = true

@export_group("Footfall")
## Emit real noise events as this body covers ground. Off for anything that
## floats, and for props that are targets without being bodies.
@export var footsteps_enabled: bool = true
## Metres between steps at a walk. Scales up with speed, as a real stride does.
@export_range(0.3, 4.0, 0.05) var footstep_stride: float = 1.55
## Metres at which a walking step and a sprinting one stop being audible.
@export_range(1.0, 40.0, 0.5) var footstep_radius_walk: float = 7.5
@export_range(2.0, 90.0, 0.5) var footstep_radius_run: float = 24.0
## Strength at the source of a full-speed step.
@export_range(0.05, 2.0, 0.01) var footstep_loudness: float = 0.55
## Below this ground speed nothing is loud enough to file.
@export_range(0.0, 4.0, 0.05) var footstep_min_speed: float = 0.55
## Multipliers on step radius and loudness while ducked. Creeping should work.
@export_range(0.05, 1.0, 0.01) var crouch_quiet: float = 0.42
@export_range(0.02, 1.0, 0.01) var prone_quiet: float = 0.22

@export_group("Reaction")
## Seconds a flinch takes to bleed away to nothing.
@export_range(0.05, 4.0, 0.01) var flinch_decay: float = 0.55
## Flinch produced by a hit that took the whole health bar. Scaled by the real
## fraction taken, so a graze barely moves the aim and a mauling ruins it.
@export_range(0.0, 4.0, 0.01) var flinch_scale: float = 2.4
## Morale shock per unit of health fraction lost in one hit.
@export_range(0.0, 4.0, 0.01) var shock_scale: float = 1.6
## Morale shock a body takes from a friend dying within earshot.
@export_range(0.0, 2.0, 0.01) var witness_shock: float = 0.42

## Cleared by whatever owns the body when it dies. A dead target is skipped by
## every query without being unregistered, so contacts can still reference it.
var alive: bool = true
## Extra noise this body is making right now, 0 quiet, 1 sprinting on gravel.
## Written by the agent's own locomotion; `effective_loudness` takes the louder
## of this and what the index measured, so a body nobody writes still makes noise.
var motion_loudness: float = 0.0
## Assigned by the index on registration. Stable for the life of the node.
var target_id: int = -1
## One of `Stance`. Resolved from the player's controller when there is one, and
## settable directly by anything that knows better.
var stance: int = Stance.STAND
## Nerve. Created on the first sense refresh, once the species profile is known.
var morale: AIMorale = null

var _body: Node3D = null
var _receiver: Node = null
var _resolved: bool = false
var _lit: bool = true
var _shadow_clock: float = 0.0
var _travel: float = 0.0
var _speed: float = 0.0
var _auto_loudness: float = 0.0
var _flinch: float = 0.0
var _hit_from: Vector3 = Vector3.ZERO
var _hit_at: float = -1.0e9
var _last_health: float = 1.0
var _stance_readable: bool = true
var _morale_possible: bool = true
var _query: PhysicsRayQueryParameters3D = null


func _ready() -> void:
	_resolve()
	add_to_group(&"ai_target")


## Collider node, resolved once and cached.
func body() -> Node3D:
	if not _resolved:
		_resolve()
	return _body


func aim_point() -> Vector3:
	return global_position + aim_offset


func eye_point() -> Vector3:
	return global_position + eye_offset


## Route incoming damage to whatever owns the body, then announce it. Returns
## false when the target was already down, so a shooter can pick a new mark.
func receive_damage(amount: float, from_position: Vector3, attacker: Node) -> bool:
	if not alive:
		return false
	if not _resolved:
		_resolve()
	var before: float = health_fraction()
	if _receiver != null and _receiver.has_method(&"apply_damage"):
		_receiver.call(&"apply_damage", amount, from_position, attacker)
	# The bite this hit took, measured rather than guessed. A body with no health
	# to read falls back to a fixed nick, which is the right answer for a prop.
	var bite: float = maxf(before - health_fraction(), 0.0)
	if bite <= 0.0:
		bite = 0.08
	_flinch = clampf(bite * flinch_scale, 0.0, 1.0)
	_hit_from = from_position
	_hit_at = float(Time.get_ticks_msec())
	if morale != null:
		morale.shock(bite * shock_scale, from_position)
	damaged.emit(amount, from_position, attacker)
	return true


## Mark the body down. Idempotent.
func mark_dead() -> void:
	if not alive:
		return
	alive = false
	_flinch = 0.0
	_auto_loudness = 0.0
	died.emit()


## Somebody friendly went down within earshot. The single largest thing that
## breaks a squad, and the reason a wiped fire team routs rather than fighting on.
func witness_death(where: Vector3) -> void:
	if morale != null and alive:
		morale.shock(witness_shock, where)


## One budgeted sense step, called by `AITargetIndex` when it reads this row.
## `dt` is seconds since THIS row was last read, not since the last frame.
func refresh_senses(dt: float, velocity: Vector3, allies: int, hostiles: int) -> void:
	if not alive:
		return
	_speed = Vector2(velocity.x, velocity.z).length()
	_refresh_stance()
	_refresh_exposure(dt)
	_refresh_footfall(dt)
	_refresh_morale(dt, allies, hostiles)


## Visibility as an observer actually experiences it: the authored figure, times
## the stance, times the light, times how much the body is moving.
func effective_visibility() -> float:
	var k: float = visibility
	if stance == Stance.CROUCH:
		k *= crouch_visibility
	elif stance == Stance.PRONE:
		k *= prone_visibility
	if not _lit:
		k *= shadow_visibility
	var moving: float = clampf(_speed / maxf(motion_reference, 0.1), 0.0, 1.0)
	# A body that has just been hit is thrashing, and thrashing is the easiest
	# thing in the world to see. Short-lived, and it decays with the flinch.
	return k * lerpf(still_visibility, 1.0, moving) * (1.0 + flinch_now() * 0.5)


## Movement noise for the perception model. The louder of what the body reported
## and what its own travel says, so nothing is silent for want of a writer.
func effective_loudness() -> float:
	return maxf(motion_loudness, _auto_loudness)


## Fraction of maximum health left, read off whatever takes the damage. Anything
## without a `health_fraction` reads as untouched, which is right for scenery.
func health_fraction() -> float:
	if not _resolved:
		_resolve()
	if _receiver != null and _receiver.has_method(&"health_fraction"):
		return clampf(float(_receiver.call(&"health_fraction")), 0.0, 1.0)
	return 1.0


## Stagger left in this body right now, 0 to 1, decaying from the last hit. A
## shooter should be widening its cone by this and an observer should find a
## flinching body easier to see.
func flinch_now() -> float:
	if _flinch <= 0.0:
		return 0.0
	var age: float = (float(Time.get_ticks_msec()) - _hit_at) * 0.001
	if age >= flinch_decay:
		return 0.0
	return _flinch * (1.0 - age / flinch_decay)


## Unit direction the last hit came FROM, in world space. Zero when untouched.
func hit_direction() -> Vector3:
	if _hit_from == Vector3.ZERO:
		return Vector3.ZERO
	var to: Vector3 = _hit_from - global_position
	to.y = 0.0
	return to.normalized() if to.length_squared() > 1e-6 else Vector3.ZERO


## Force a stance. Anything that knows better than the automatic read — a scripted
## ambush, a creature that flattens itself — should call this.
func set_stance(which: int) -> void:
	stance = clampi(which, 0, Stance.PRONE)


func is_lit() -> bool:
	return _lit


func stance_name() -> String:
	return STANCE_NAMES[stance]


## Put a pooled body back to a clean slate: no flinch, no travel, morale restored.
func reset_senses() -> void:
	_flinch = 0.0
	_hit_at = -1.0e9
	_hit_from = Vector3.ZERO
	_travel = 0.0
	_auto_loudness = 0.0
	_lit = true
	_last_health = 1.0
	if morale != null:
		morale.reset()


## The player's crouch, read straight off its controller. Everything else stands
## unless something told it otherwise.
##
## Whether this body HAS a crouch to read is decided once, on the first refresh,
## and remembered. Without that every creature in the game pays a failed property
## lookup on every row read for ever, to learn the same thing it learned the first
## time: that it does not have knees the AI is allowed to see.
func _refresh_stance() -> void:
	if not _stance_readable:
		return
	if _receiver == null:
		_stance_readable = false
		return
	var carrier: Variant = _receiver.get(&"state")
	if not (carrier is Object):
		_stance_readable = false
		return
	var blend: Variant = (carrier as Object).get(&"crouch_t")
	if not (blend is float):
		_stance_readable = false
		return
	stance = Stance.CROUCH if float(blend) > CROUCH_THRESHOLD else Stance.STAND


## One ray at the sun, at most every `shadow_interval`. Skipped outside a physics
## step, because a raycast taken from `_process` is measuring an error message.
func _refresh_exposure(dt: float) -> void:
	if not shadow_probe_enabled:
		return
	_shadow_clock -= dt
	if _shadow_clock > 0.0:
		return
	_shadow_clock = shadow_interval
	_resolve_world()
	if not _has_sun or not Engine.is_in_physics_frame():
		return
	if _query == null:
		_query = PhysicsRayQueryParameters3D.new()
		_query.collision_mask = GameLayers.WORLD | GameLayers.PROP
		_query.collide_with_areas = false
	var from: Vector3 = aim_point()
	_query.from = from
	_query.to = from + _sun_to * SUN_PROBE
	_lit = get_world_3d().direct_space_state.intersect_ray(_query).is_empty()


## Turn ground covered into steps, and steps into noise. Accumulating distance
## rather than counting time is what keeps the cadence honest when the index is
## reading this row every fourth tick instead of every one.
func _refresh_footfall(dt: float) -> void:
	var reference: float = maxf(motion_reference * 2.0, 0.5)
	var pace: float = clampf(_speed / reference, 0.0, 1.0)
	var quiet: float = 1.0
	if stance == Stance.CROUCH:
		quiet = crouch_quiet
	elif stance == Stance.PRONE:
		quiet = prone_quiet
	_auto_loudness = pace * footstep_loudness * quiet * 1.4
	if not footsteps_enabled or _speed < footstep_min_speed:
		_travel = 0.0
		return
	_travel += _speed * dt
	var stride: float = footstep_stride * (0.8 + 0.45 * pace)
	if _travel < stride:
		return
	_travel -= stride
	var radius: float = lerpf(footstep_radius_walk, footstep_radius_run, pace) * quiet
	var loud: float = footstep_loudness * (0.45 + 0.55 * pace) * quiet
	AINoiseBus.emit_noise(global_position, radius, loud, faction, target_id)


## Nerve, once there is a species profile to read it from. The player has none and
## never gets a morale object, which is correct: nothing models the player's will.
func _refresh_morale(dt: float, allies: int, hostiles: int) -> void:
	if morale == null:
		if not _morale_possible:
			return
		_morale_possible = false
		if _receiver == null:
			return
		var profile: Variant = _receiver.get(&"profile")
		if not (profile is AISpeciesProfile):
			return
		var species := profile as AISpeciesProfile
		morale = AIMorale.new(species, AIPersonality.of(maxi(target_id, 1), species))
		if morale == null:
			return
	var health: float = health_fraction()
	# Damage that arrived without coming through `receive_damage` — a blast, a
	# scripted removal — still counts as a shock. Diffing catches it for free.
	if health < _last_health - 0.001:
		morale.shock((_last_health - health) * shock_scale * 0.6, _hit_from)
	_last_health = health
	morale.tick(dt, health, minf(effective_loudness() * 0.2, 1.0), allies, hostiles)


## Find the scene's sun and its haze once. Re-walked only when the current scene
## changes, so a demo swap picks up the new sky and a steady scene never pays
## again. Bounded, because a town's node count is not.
func _resolve_world() -> void:
	var tree: SceneTree = get_tree()
	if tree == null:
		return
	var scene: Node = tree.current_scene
	if scene == null:
		return
	var stamp: int = int(scene.get_instance_id())
	if stamp == _scene_stamp:
		return
	_scene_stamp = stamp
	_has_sun = false
	AIPerception.haze_range = 0.0
	# The module's only scene-change hook, so the two static registries are dropped
	# here. Personalities are safe to drop: they are a pure function of the agent
	# key and its species, so the next `of` re-rolls an identical one. Idle
	# positions are not — a body in the old scene is a conversation partner
	# standing in a street that no longer exists.
	AIPersonality.clear()
	AIPatrol.clear()
	var looked: int = 0
	var stack: Array[Node] = [scene]
	while not stack.is_empty() and looked < WORLD_WALK_LIMIT:
		var node: Node = stack.pop_back()
		looked += 1
		var light := node as DirectionalLight3D
		if light != null and not _has_sun:
			# A DirectionalLight3D shines down its own -Z, so the way BACK to the
			# sun is +Z. Getting this backwards probes the ground and reports every
			# body in the game as standing in shadow.
			_sun_to = light.global_transform.basis.z.normalized()
			_has_sun = true
		else:
			var host := node as WorldEnvironment
			if host != null and host.environment != null:
				_read_haze(host.environment)
		for child: Node in node.get_children():
			stack.push_back(child)


## Turn the scene's depth fog into a perception range. The fog's own far plane is
## where the world goes solid; contrast is already gone well before that, so the
## half-detection distance is taken as a fraction of it.
static func _read_haze(env: Environment) -> void:
	if not env.fog_enabled:
		AIPerception.haze_range = 0.0
		return
	var far: float = maxf(env.fog_depth_end, env.fog_depth_begin + 1.0)
	AIPerception.haze_range = maxf(far * 0.35, 1.0)


func _resolve() -> void:
	_resolved = true
	var b: Node = get_node_or_null(body_path)
	_body = b as Node3D
	_receiver = get_node_or_null(receiver_path)
	if _body == null:
		push_warning("AITarget '%s': body_path does not resolve to a Node3D." % name)
