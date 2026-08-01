class_name VFXAshField
extends GPUParticles3D
## Wind-blown ash and grit (world spec 21.2). The whole field is emitted once,
## never dies, and is wrapped toroidally around the camera in the process shader,
## so it follows the player across the map for the cost of one dispatch and zero
## CPU work per mote.
##
## The wind model is the reference's: a base of (1.9, 0, -1.15) m/s scaled by a
## two-sine gust envelope, plus a per-mote flutter. `wind_strength()` is exposed
## because the world's ambient audio gain is derived from the same envelope, and
## the two must not drift apart.

## Emit everything on the first cycle and then leave it alone. The cycle is an
## hour long; nothing in a run reaches the end of it.
const CYCLE_SECONDS: float = 3600.0

@export_range(0, 4000, 1) var motes: int = 1100
## Half-width of the box the field is wrapped inside, in metres.
@export_range(4.0, 200.0, 0.5) var wrap_radius: float = 46.0:
	set = _set_wrap_radius
## Vertical band relative to the camera. The reference runs -4 m to +13 m.
@export_range(-40.0, 0.0, 0.1) var band_bottom: float = -4.0:
	set = _set_band_bottom
@export_range(1.0, 80.0, 0.1) var band_top: float = 13.0:
	set = _set_band_top


func _ready() -> void:
	top_level = true
	lifetime = CYCLE_SECONDS
	one_shot = false
	explosiveness = 1.0
	_push(&"wrap_radius", wrap_radius)
	_push(&"band_bottom", band_bottom)
	_push(&"band_top", band_top)


## Called once per frame by the hub with the live camera position and the shared
## VFX clock. Two uniform writes; the field itself never touches the CPU.
func follow(camera_pos: Vector3, vfx_time: float) -> void:
	var mat := process_material as ShaderMaterial
	if mat == null:
		return
	mat.set_shader_parameter(&"camera_pos", camera_pos)
	mat.set_shader_parameter(&"vfx_time", vfx_time)


## Resize and respawn. The modulo wrap in the process shader means the new motes
## land in the right box on their first frame wherever the camera happens to be.
func resize(slots: int) -> void:
	motes = maxi(slots, 0)
	emitting = motes > 0
	if motes <= 0:
		return
	if amount != motes:
		amount = motes
	restart()


## The reference's gust envelope, in [0.03, 1.47]. The world's ambient wind audio
## reads this so the sound and the grit agree about how hard it is blowing.
static func wind_strength(vfx_time: float) -> float:
	return 0.75 + sin(vfx_time * 0.21) * 0.4 + sin(vfx_time * 0.083 + 1.3) * 0.32


func _push(key: StringName, value: float) -> void:
	var mat := process_material as ShaderMaterial
	if mat != null:
		mat.set_shader_parameter(key, value)


func _set_wrap_radius(value: float) -> void:
	wrap_radius = value
	_push(&"wrap_radius", value)


func _set_band_bottom(value: float) -> void:
	band_bottom = value
	_push(&"band_bottom", value)


func _set_band_top(value: float) -> void:
	band_top = value
	_push(&"band_top", value)
