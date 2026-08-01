class_name VFXSmokeField
extends GPUParticles3D
## A pooled smoke or dust cloud. Two of these exist: a fine one for muzzle wisps,
## impact dust and supersonic bullet trails, and a heavy one for rocket motors
## and blasts (range spec 16.2).
##
## `puff()` is the reference's `smokeCloud.add` plus its `puff` wrapper, including
## the near-camera cull - a sprite two metres from the eye covers half the screen,
## so smoke that would be born in the player's face is simply never born. The cull
## distance lives here as a squared radius because that is the only form it is
## ever compared in.
##
## Colour: the reference recolours every live sprite each frame toward the haze.
## That is a lerp from the birth colour to the haze colour over the particle's
## life, so the birth colour is computed once, here, and the draw shader does the
## rest.

const EMIT_FLAGS: int = (
	GPUParticles3D.EMIT_FLAG_POSITION
	| GPUParticles3D.EMIT_FLAG_VELOCITY
	| GPUParticles3D.EMIT_FLAG_COLOR
	| GPUParticles3D.EMIT_FLAG_CUSTOM
)
## The colour smoke settles to. The reference's own smoke haze, which is cooler
## than the world's sand fog on purpose - powder smoke is grey, not tan.
const HAZE: Color = Color(0.62, 0.66, 0.70)
## Darkest a fully sooty puff gets at birth.
const SOOT: Color = Color(0.10, 0.10, 0.10)
const MAX_PARTICLE_LIFE: float = 8.0

## Sprite edge length in metres. 0.62 fine, 2.10 heavy, per the reference.
@export_range(0.01, 8.0, 0.01) var particle_size: float = 0.62:
	set = _set_particle_size
## Squared distance from the camera inside which a puff is refused. 38 for the
## fine cloud, 150 for the heavy one - 6.2 m and 12.2 m.
@export_range(0.0, 400.0, 1.0) var near_cull_squared: float = 38.0
@export var rng_seed: int = 0x71c4a3

var _rng := RandomNumberGenerator.new()
var _xform := Transform3D.IDENTITY
var _custom := Color(0.5, 0.0, 1.0, 0.0)


func _ready() -> void:
	_rng.seed = rng_seed
	top_level = true
	_set_particle_size(particle_size)


## Refused when `camera_pos` is closer than the cull radius. Pass the camera
## position you already have; this class never goes looking for one.
func too_close(origin: Vector3, camera_pos: Vector3) -> bool:
	return origin.distance_squared_to(camera_pos) < near_cull_squared


## The reference's `smokeCloud.add(p, n, spread, dark, life, rise)`. `tint` with
## alpha 0 means "use the haze", which is what powder smoke wants; dust passes the
## colour of the ground it came out of.
func puff(
	origin: Vector3,
	count: int,
	spread: float,
	dark: float,
	life: float,
	rise: float = 0.35,
	tint: Color = Color(0, 0, 0, 0)
) -> void:
	if count <= 0 or life <= 0.0:
		return
	var base: Color = HAZE if tint.a <= 0.0 else Color(tint.r, tint.g, tint.b)
	var birth: Color = base.lerp(SOOT, clampf(dark, 0.0, 1.0))
	birth.a = 1.0
	_custom.r = clampf(dark, 0.0, 1.0)
	_custom.g = 0.0
	_custom.a = 0.0
	for _i: int in count:
		_xform.origin = (
			origin + Vector3(_rng.randf() - 0.5, _rng.randf() - 0.5, _rng.randf() - 0.5) * spread
		)
		var velocity := Vector3(
			(_rng.randf() - 0.5) * 0.7, rise + _rng.randf() * 0.6, (_rng.randf() - 0.5) * 0.7
		)
		_custom.b = minf(life * (0.7 + _rng.randf() * 0.6), MAX_PARTICLE_LIFE)
		emit_particle(_xform, velocity, birth, _custom, EMIT_FLAGS)


func resize(slots: int) -> void:
	var wanted: int = maxi(slots, 8)
	if amount != wanted:
		amount = wanted


func _set_particle_size(value: float) -> void:
	particle_size = value
	var mat := process_material as ShaderMaterial
	if mat != null:
		mat.set_shader_parameter(&"particle_size", value)
