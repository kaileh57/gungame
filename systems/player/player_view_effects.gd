class_name PlayerViewEffects
extends Node
## Transient view perturbation: shake, damage punch, blast wallop.
##
## The camera rig owns the *steady* view — bob, lean, dip, FOV, recoil springs. This
## node owns the things that happen TO you, and it owns them separately because they
## have a different failure mode. Bob at the wrong amplitude looks bad; shake at the
## wrong amplitude makes people put the controller down. So everything here is scaled
## by a single `intensity` knob that a settings pass can drop to zero without touching
## the numbers underneath.
##
## Shake follows the trauma model: callers add trauma, trauma decays linearly, and the
## displacement is `trauma^exponent`. The square is the whole trick — a half-full
## trauma buffer shakes at a quarter strength, so small hits stay small and only a
## point-blank blast throws the view around. Linear trauma would make every scratch
## feel like a mortar.
##
## The noise is three summed sines per axis with irrational frequency ratios and phases
## drawn once from `XorShift32`. It costs nine sines a frame, allocates nothing, and
## never repeats inside a shake long enough to notice. A texture lookup would be
## cheaper and worse: sampled noise is what gives cheap shake its stuttery, jelly look.
##
## Damage punch is a second-order spring, not a shake: a hit from the left rotates the
## view right and it swings back. That reads as direction, which is information the
## player can act on, unlike shake which is only ever texture.

## Fired when trauma crosses from zero to non-zero and back, for anything that wants to
## duck out of the way of a shake (an idle animation, a scope overlay).
signal shaking_changed(is_shaking: bool)

## Below this, trauma is treated as spent and the springs are parked.
const EPSILON: float = 0.0005
## Fixed sub-step for the punch spring. Explicit Euler on a stiffness of 120 rings at
## 30 fps; four cheap iterations make the punch identical at every frame rate.
const SPRING_HZ: float = 240.0
const MAX_SPRING_STEPS: int = 16

@export_group("Master")
## Global scale on every effect in this node. The settings menu's "camera shake" slider
## drives this; 0 disables shake and punch entirely without disabling the node.
@export_range(0.0, 2.0, 0.01) var intensity: float = 1.0

@export_group("Shake")
## Trauma lost per second. 1.6 means a full-strength shake is visually gone in about
## half a second and fully spent in 0.62 s.
@export_range(0.1, 6.0, 0.05) var trauma_decay: float = 1.6
## Displacement is trauma raised to this. 2 is the standard square; below 2 small hits
## start to feel mushy, above 2 only the biggest hits register at all.
@export_range(1.0, 4.0, 0.05) var trauma_exponent: float = 2.0
## Angular shake at full trauma, radians.
@export_range(0.0, 0.15, 0.001) var shake_pitch: float = 0.028
@export_range(0.0, 0.15, 0.001) var shake_yaw: float = 0.034
@export_range(0.0, 0.20, 0.001) var shake_roll: float = 0.052
## Positional shake at full trauma, metres, applied in view space.
@export_range(0.0, 0.30, 0.001) var shake_offset: float = 0.045
## Base frequency of the shake, Hz. The upper octaves sit at 2.17x and 4.61x this.
@export_range(1.0, 40.0, 0.1) var shake_frequency: float = 13.5
## Ceiling on accumulated trauma. Without it, a burst of five grenades stacks into a
## shake that outlives the fight.
@export_range(0.1, 2.0, 0.01) var trauma_max: float = 1.0

@export_group("Damage")
## Trauma per point of damage taken. A 25-damage hit lands at 0.30 trauma, which after
## the square is a ninth of full strength: a jolt, not a blackout.
@export_range(0.0, 0.1, 0.0005) var damage_trauma_per_hp: float = 0.012
## Ceiling on the trauma any single hit may add.
@export_range(0.0, 1.0, 0.01) var damage_trauma_max: float = 0.55
## Radians of upward view punch per point of damage.
@export_range(0.0, 0.02, 0.0001) var damage_punch_pitch: float = 0.0022
## Radians of sideways punch per point of damage, signed by which side the hit came
## from. The view swings AWAY from the shooter, the way a shoved head goes.
@export_range(0.0, 0.02, 0.0001) var damage_punch_yaw: float = 0.0030
## Radians of roll per point of damage, same sign convention as yaw.
@export_range(0.0, 0.03, 0.0001) var damage_punch_roll: float = 0.0042
## Degrees of FOV widening per point of damage. Small: a wide-angle flinch.
@export_range(0.0, 0.4, 0.005) var damage_fov_punch: float = 0.055
@export_range(20.0, 400.0, 1.0) var punch_stiffness: float = 120.0
@export_range(1.0, 60.0, 0.5) var punch_damping: float = 15.0
@export_range(1.0, 30.0, 0.5) var fov_punch_damp: float = 8.0

@export_group("Landing")
## Trauma per metre of fall above the threshold. The camera rig already dips on every
## landing; this only adds grit to the ones that hurt.
@export_range(0.0, 0.2, 0.001) var land_trauma_per_metre: float = 0.020
## Fall height, metres, below which a landing adds no trauma at all. A jump off the
## controller's 6.8 m/s hop clears about 1.1 m, so 3 leaves ordinary jumping clean.
@export_range(0.0, 20.0, 0.1) var land_trauma_threshold: float = 3.0
## Trauma added by a landing hard enough for the controller to call it hard. The
## controller's severity tops out at 0.9, so this is very nearly the full amount.
@export_range(0.0, 1.5, 0.01) var hard_landing_trauma: float = 0.55

@export_group("Blast")
## Trauma at the centre of an explosion, before falloff.
@export_range(0.0, 2.0, 0.01) var blast_trauma: float = 0.85
## Falloff exponent over the blast radius. 2 keeps the shake tight to the blast.
@export_range(0.5, 4.0, 0.05) var blast_falloff: float = 2.0
## Distance past the blast radius that still registers, as a multiple of the radius.
@export_range(1.0, 4.0, 0.05) var blast_reach: float = 2.2

@export_group("Wiring")
## The body whose landings feed the shake. Empty means no automatic landing trauma.
@export var controller_path: NodePath = NodePath("..")
## Seed for the noise phase table. Two players in one scene with the same seed would
## shake in lockstep; they never share a scene, so this is only here to make a
## recorded shake reproducible.
@export var noise_seed: int = 0x51F3A7

var trauma: float = 0.0

var _player: PlayerController = null
var _t: float = 0.0
var _phase: PackedFloat32Array = PackedFloat32Array()
var _punch: Vector3 = Vector3.ZERO
var _punch_vel: Vector3 = Vector3.ZERO
var _fov_punch: float = 0.0
var _angles: Vector3 = Vector3.ZERO
var _offset: Vector3 = Vector3.ZERO
var _was_shaking: bool = false


func _ready() -> void:
	var rand := XorShift32.new(noise_seed)
	_phase.resize(12)
	for i: int in 12:
		_phase[i] = rand.next_range(0.0, TAU)
	_player = get_node_or_null(controller_path) as PlayerController
	if _player != null:
		_player.landed.connect(_on_landed)
		_player.hard_landing.connect(_on_hard_landing)


func _process(delta: float) -> void:
	var dt: float = minf(delta, 0.1)
	_t += dt
	_step_punch(dt)
	if trauma > EPSILON:
		trauma = maxf(0.0, trauma - trauma_decay * dt)
	_compose()
	var now: bool = trauma > EPSILON
	if now != _was_shaking:
		_was_shaking = now
		shaking_changed.emit(now)


## Radians to add to the camera's pitch, yaw and roll this frame. Already scaled by
## `intensity`; the camera adds it and asks no questions.
func angles() -> Vector3:
	return _angles


## Metres to add to the camera position, expressed in VIEW space: x right, y up,
## z backwards. The camera rotates it by its own basis.
func offset() -> Vector3:
	return _offset


## Degrees to add to the camera's field of view this frame.
func fov_offset() -> float:
	return _fov_punch * intensity


## Raw trauma, before the exponent. Useful for a scope that should black out.
func shake_amount() -> float:
	return trauma


func add_trauma(amount: float) -> void:
	if amount <= 0.0:
		return
	trauma = minf(trauma_max, trauma + amount)


## Took a hit. `from_direction` is the world-space direction the damage came FROM
## (shooter minus victim); pass `Vector3.ZERO` for damage with no direction, such as
## fall damage or a burn, and only the pitch punch is applied.
func add_damage(amount: float, from_direction: Vector3 = Vector3.ZERO) -> void:
	if amount <= 0.0:
		return
	add_trauma(minf(damage_trauma_max, amount * damage_trauma_per_hp))
	_punch_vel.x += amount * damage_punch_pitch
	_fov_punch += amount * damage_fov_punch
	var flat := Vector2(from_direction.x, from_direction.z)
	if flat.length_squared() < 1e-6 or _player == null:
		return
	# Right of the eye in the XZ plane. yaw = 0 looks down -Z, so right is +X.
	flat = flat.normalized()
	var side: float = flat.x * cos(_player.yaw) - flat.y * sin(_player.yaw)
	_punch_vel.y += amount * damage_punch_yaw * side
	_punch_vel.z += amount * damage_punch_roll * side


## An explosion went off at `world_position`. Falls off over `radius`, reaching zero at
## `radius * blast_reach`, so a distant shell is felt as a thump rather than ignored.
func add_blast(world_position: Vector3, radius: float, strength: float = 1.0) -> void:
	if _player == null or radius <= 0.0:
		return
	var reach: float = radius * blast_reach
	var d: float = _player.global_position.distance_to(world_position)
	if d >= reach:
		return
	var k: float = pow(1.0 - d / reach, blast_falloff)
	add_trauma(blast_trauma * strength * k)


## Wipe every effect. Call on respawn or on a scene cut so the new view starts still.
func reset() -> void:
	trauma = 0.0
	_punch = Vector3.ZERO
	_punch_vel = Vector3.ZERO
	_fov_punch = 0.0
	_angles = Vector3.ZERO
	_offset = Vector3.ZERO


func _compose() -> void:
	if intensity <= 0.0:
		_angles = Vector3.ZERO
		_offset = Vector3.ZERO
		return
	var s: float = 0.0
	if trauma > EPSILON:
		s = pow(trauma, trauma_exponent) * intensity
	if s <= 0.0:
		_angles = _punch * intensity
		_offset = Vector3.ZERO
		return
	var f: float = _t * shake_frequency
	_angles = Vector3(
		_punch.x * intensity + _noise(f, 0) * shake_pitch * s,
		_punch.y * intensity + _noise(f, 3) * shake_yaw * s,
		_punch.z * intensity + _noise(f, 6) * shake_roll * s
	)
	var lateral: float = _noise(f, 9) * shake_offset * s
	var vertical: float = _noise(f * 1.31, 1) * shake_offset * s
	_offset = Vector3(lateral, vertical, 0.0)


## Three octaves at 1x, 2.17x and 4.61x, weighted 0.6/0.3/0.1. The ratios are chosen
## irrational relative to each other so the sum has no short period.
func _noise(t: float, base: int) -> float:
	return (
		sin(t + _phase[base]) * 0.6
		+ sin(t * 2.17 + _phase[base + 1]) * 0.3
		+ sin(t * 4.61 + _phase[base + 2]) * 0.1
	)


func _step_punch(dt: float) -> void:
	if _fov_punch != 0.0:
		_fov_punch = lerpf(_fov_punch, 0.0, 1.0 - exp(-fov_punch_damp * dt))
		if absf(_fov_punch) < 1e-4:
			_fov_punch = 0.0
	if _punch == Vector3.ZERO and _punch_vel == Vector3.ZERO:
		return
	var steps: int = clampi(ceili(dt * SPRING_HZ), 1, MAX_SPRING_STEPS)
	var sdt: float = dt / float(steps)
	for _i: int in steps:
		_punch_vel -= (_punch * punch_stiffness + _punch_vel * punch_damping) * sdt
		_punch += _punch_vel * sdt
	if _punch.length_squared() < 1e-10 and _punch_vel.length_squared() < 1e-10:
		_punch = Vector3.ZERO
		_punch_vel = Vector3.ZERO


func _on_landed(_surface: int, _impact: float, fall_height: float) -> void:
	var over: float = fall_height - land_trauma_threshold
	if over > 0.0:
		add_trauma(over * land_trauma_per_metre)


func _on_hard_landing(severity: float) -> void:
	add_trauma(hard_landing_trauma * clampf(severity, 0.0, 1.0))
