class_name VFXSparkField
extends GPUParticles3D
## A pooled burst-particle cloud: impact sparks, blast fire, blast debris, and
## the blood and oil spray that share the same integrator.
##
## `burst()` is a direct port of the reference's `spawnP` (range spec 16.1). The
## direction roll is the same upward-biased hemisphere - `acos(2r-1)` then a
## mirrored vertical component - except that the bias axis is a parameter rather
## than world up, so a hit on a wall throws its sparks off the wall instead of
## straight into the sky.
##
## Emission is manual. `emitting` is left on only so the system is guaranteed to
## be stepped every frame; the process shader kills anything the node emits by
## itself, and with a 60 s node lifetime that is a slot every few seconds. When
## every slot is busy a new burst is dropped rather than stealing a live
## particle - a bounded cost either way, which is the point of the pool.
##
## Nothing here allocates: `burst()` is a loop of value types around
## `emit_particle`, which is one buffered write into the particle system.

const EMIT_FLAGS: int = (
	GPUParticles3D.EMIT_FLAG_POSITION
	| GPUParticles3D.EMIT_FLAG_VELOCITY
	| GPUParticles3D.EMIT_FLAG_COLOR
	| GPUParticles3D.EMIT_FLAG_CUSTOM
)
## Longest lifetime any single particle may ask for. Blast debris rolls up to
## 2.6 * 1.4 s, so this has room to spare.
const MAX_PARTICLE_LIFE: float = 4.0

## Sprite edge length in metres. The reference draws sparks at 0.055.
@export_range(0.002, 2.0, 0.001) var particle_size: float = 0.055:
	set = _set_particle_size
## Opacity handed to every particle. The reference's spark material sits at 0.95.
@export_range(0.0, 1.0, 0.01) var particle_alpha: float = 0.95
## Seed for the direction roll. Fixed so a replay of the same shots looks the same.
@export var rng_seed: int = 0x2f1b7c

var _rng := RandomNumberGenerator.new()
var _xform := Transform3D.IDENTITY
var _custom := Color(1.0, 0.0, 0.5, 0.0)


func _ready() -> void:
	_rng.seed = rng_seed
	top_level = true
	_set_particle_size(particle_size)


## The reference's `spawnP(p, n, spd, col, life, grav)`, with the hemisphere's
## bias axis exposed. `floor_y` is the world height the bounce plane sits at for
## this burst; `axis` is normally the surface normal.
func burst(
	origin: Vector3,
	count: int,
	speed: float,
	tint: Color,
	life: float,
	gravity_scale: float = 1.0,
	floor_y: float = 0.0,
	axis: Vector3 = Vector3.UP
) -> void:
	if count <= 0 or speed <= 0.0 or life <= 0.0:
		return
	var up: Vector3 = axis.normalized()
	if not up.is_finite() or up.length_squared() < 0.5:
		up = Vector3.UP
	var tangent: Vector3 = up.cross(Vector3.UP)
	if tangent.length_squared() < 1.0e-6:
		tangent = up.cross(Vector3.RIGHT)
	tangent = tangent.normalized()
	var binormal: Vector3 = up.cross(tangent)

	_xform.origin = origin
	_custom.r = gravity_scale
	_custom.g = 0.0
	_custom.a = floor_y
	var color := Color(tint.r, tint.g, tint.b, particle_alpha)
	for _i: int in count:
		var yaw: float = _rng.randf() * TAU
		var pitch: float = acos(2.0 * _rng.randf() - 1.0)
		var speed_roll: float = speed * (0.35 + _rng.randf())
		var ring: float = sin(pitch) * speed_roll
		var velocity: Vector3 = (
			tangent * (ring * cos(yaw))
			+ up * (absf(cos(pitch)) * speed_roll * 0.9)
			+ binormal * (ring * sin(yaw))
		)
		_custom.b = minf(life * (0.6 + _rng.randf() * 0.8), MAX_PARTICLE_LIFE)
		emit_particle(_xform, velocity, color, _custom, EMIT_FLAGS)


## Resize the pool. Costs one buffer reallocation, so this is a load-time and
## quality-preset-change operation, never a per-frame one.
func resize(slots: int) -> void:
	var wanted: int = maxi(slots, 8)
	if amount != wanted:
		amount = wanted


func _set_particle_size(value: float) -> void:
	particle_size = value
	var mat := process_material as ShaderMaterial
	if mat != null:
		mat.set_shader_parameter(&"particle_size", value)
