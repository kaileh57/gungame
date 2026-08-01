class_name VfxExplosion
extends Node3D
## Blasts: the fire, the slow grey debris, the smoke column, the flash of light
## and the heat that hangs over the crater afterwards (range spec 13.3, 16.1).
##
## The particle work is the reference's, verbatim — 80 fire at 13 m/s on 0.7
## gravity, 32 debris at 5.5 m/s on 0.2 gravity, a 26-sprite heavy puff — pushed
## into the shared spark and smoke fields rather than into pools of its own. The
## counts do not scale with the radius because they do not in the reference
## either; a bigger warhead throws its fire further and lights more of the room,
## it does not throw more pieces.
##
## The light is a 130 ms point light with `radius * 4` of range. That is long
## enough to be seen and short enough that six of them going off at once is still
## six lights for a fifth of a second.
##
## The heat shimmer is the part the reference does not have. A quad of refracted
## screen over the crater, fading over a second, which is what actually sells a
## fireball as having been hot. It is also the one effect here that reads the
## screen texture, so the pool is small and the quads never overlap for long.

const P_OPACITY: StringName = &"opacity"
const P_TIME: StringName = &"vfx_time"

@export var shimmer_mesh: Mesh = null
@export var shimmer_material: Material = null

@export_group("Light")
@export_range(1, 24, 1) var light_budget: int = 6:
	set = _set_light_budget
@export_range(0.02, 1.0, 0.005) var light_life: float = 0.13
@export_range(0.0, 60.0, 0.5) var light_energy: float = 9.0
## Light range as a multiple of the blast radius, per the reference's `radius*4`.
@export_range(1.0, 10.0, 0.1) var light_range_scale: float = 4.0
@export var light_color: Color = Color(1.0, 0.627, 0.251)

@export_group("Fire and debris")
@export_range(0, 240, 1) var fire_count: int = 80
@export_range(0.5, 60.0, 0.5) var fire_speed: float = 13.0
@export_range(0.05, 8.0, 0.05) var fire_life: float = 1.5
@export_range(0.0, 2.0, 0.01) var fire_gravity: float = 0.7
@export var fire_color: Color = Color(1.0, 0.6, 0.2)
@export_range(0, 160, 1) var debris_count: int = 32
@export_range(0.5, 40.0, 0.5) var debris_speed: float = 5.5
@export_range(0.05, 8.0, 0.05) var debris_life: float = 2.6
@export_range(0.0, 2.0, 0.01) var debris_gravity: float = 0.2
@export var debris_color: Color = Color(0.36, 0.34, 0.31)

@export_group("Smoke")
@export_range(0, 120, 1) var smoke_count: int = 26
@export_range(0.05, 8.0, 0.05) var smoke_spread: float = 1.1
@export_range(0.0, 1.0, 0.01) var smoke_dark: float = 0.9
@export_range(0.1, 12.0, 0.1) var smoke_life: float = 3.2
@export_range(0.0, 2.0, 0.01) var smoke_rise: float = 0.14

@export_group("Heat")
@export_range(0, 24, 1) var shimmer_budget: int = 6:
	set = _set_shimmer_budget
@export_range(0.1, 12.0, 0.05) var shimmer_life: float = 1.2
## Quad edge length as a multiple of the blast radius.
@export_range(0.2, 6.0, 0.05) var shimmer_scale: float = 1.7
@export_range(0.0, 1.0, 0.01) var shimmer_peak: float = 0.85
## Metres per second the heat column drifts upward while it fades.
@export_range(0.0, 6.0, 0.05) var shimmer_rise: float = 0.9

var _sparks: VFXSparkField = null
var _smoke: VFXSmokeField = null

var _lights: Array[OmniLight3D] = []
var _light_timer := PackedFloat32Array()
var _light_head: int = 0
var _lights_live: int = 0
var _lights_peak: int = 0

var _quads: Array[MeshInstance3D] = []
var _quad_timer := PackedFloat32Array()
var _quad_head: int = 0
var _quads_live: int = 0
var _quads_peak: int = 0


func _ready() -> void:
	_build_lights(light_budget)
	_build_quads(shimmer_budget)


## Wire the shared fields in. The hub does this once; nothing here goes looking
## for a sibling by name at fire time.
func bind(sparks: VFXSparkField, smoke: VFXSmokeField) -> void:
	_sparks = sparks
	_smoke = smoke


## Set one off. `camera_pos` is only used for the smoke field's near-camera cull;
## `ground_y` is the bounce plane the debris lands on.
func blast(pos: Vector3, radius: float, camera_pos: Vector3, ground_y: float) -> void:
	var r: float = maxf(radius, 0.1)
	if _sparks != null:
		_sparks.burst(pos, fire_count, fire_speed, fire_color, fire_life, fire_gravity, ground_y)
		_sparks.burst(
			pos, debris_count, debris_speed, debris_color, debris_life, debris_gravity, ground_y
		)
	if _smoke != null and not _smoke.too_close(pos, camera_pos):
		_smoke.puff(pos, smoke_count, smoke_spread, smoke_dark, smoke_life, smoke_rise)
	_light(pos, r)
	heat(pos, r * shimmer_scale, shimmer_life)


## A standalone patch of hot air: a scorched barrel, a burning wreck, the ground
## a blast just left. `size` is the quad's edge length in metres.
func heat(pos: Vector3, size: float, life: float) -> void:
	if _quads.is_empty() or size <= 0.0 or life <= 0.0:
		return
	var slot: int = _quad_head
	_quad_head = (_quad_head + 1) % _quads.size()
	if _quad_timer[slot] <= 0.0:
		_quads_live += 1
		_quads_peak = maxi(_quads_peak, _quads_live)
	var quad: MeshInstance3D = _quads[slot]
	quad.transform = Transform3D(Basis.IDENTITY.scaled(Vector3(size, size, size)), pos)
	quad.set_instance_shader_parameter(P_OPACITY, shimmer_peak)
	quad.visible = true
	_quad_timer[slot] = life


## Decay the lights and the heat. One pass each, both skipped when idle.
func step(delta: float, vfx_time: float) -> void:
	if _quads_live > 0:
		var mat := shimmer_material as ShaderMaterial
		if mat != null:
			mat.set_shader_parameter(P_TIME, vfx_time)
	if _lights_live > 0:
		for i: int in _light_timer.size():
			if _light_timer[i] <= 0.0:
				continue
			var t: float = _light_timer[i] - delta
			if t <= 0.0:
				_light_timer[i] = 0.0
				_lights[i].visible = false
				_lights_live -= 1
				continue
			_light_timer[i] = t
			# Squared falloff: a fireball is at its brightest the instant it opens.
			var k: float = t / light_life
			_lights[i].light_energy = light_energy * k * k
	if _quads_live <= 0:
		return
	for i: int in _quad_timer.size():
		if _quad_timer[i] <= 0.0:
			continue
		var t: float = _quad_timer[i] - delta
		if t <= 0.0:
			_quad_timer[i] = 0.0
			_quads[i].visible = false
			_quads_live -= 1
			continue
		_quad_timer[i] = t
		var quad: MeshInstance3D = _quads[i]
		quad.position += Vector3(0.0, shimmer_rise * delta, 0.0)
		quad.set_instance_shader_parameter(
			P_OPACITY, shimmer_peak * clampf(t / shimmer_life, 0.0, 1.0)
		)


func clear() -> void:
	for i: int in _light_timer.size():
		_light_timer[i] = 0.0
		_lights[i].visible = false
	for i: int in _quad_timer.size():
		_quad_timer[i] = 0.0
		_quads[i].visible = false
	_lights_live = 0
	_quads_live = 0
	_light_head = 0
	_quad_head = 0


func light_peak() -> int:
	return _lights_peak


func shimmer_peak_count() -> int:
	return _quads_peak


func _light(pos: Vector3, radius: float) -> void:
	if _lights.is_empty():
		return
	var slot: int = _light_head
	_light_head = (_light_head + 1) % _lights.size()
	if _light_timer[slot] <= 0.0:
		_lights_live += 1
		_lights_peak = maxi(_lights_peak, _lights_live)
	var light: OmniLight3D = _lights[slot]
	light.position = pos
	light.omni_range = radius * light_range_scale
	light.light_energy = light_energy
	light.visible = true
	_light_timer[slot] = light_life


func _set_light_budget(value: int) -> void:
	light_budget = clampi(value, 1, 24)
	if is_inside_tree() and _lights.size() != light_budget:
		_build_lights(light_budget)


func _set_shimmer_budget(value: int) -> void:
	shimmer_budget = clampi(value, 0, 24)
	if is_inside_tree() and _quads.size() != shimmer_budget:
		_build_quads(shimmer_budget)


func _build_lights(slots: int) -> void:
	for light: OmniLight3D in _lights:
		light.queue_free()
	_lights.clear()
	_light_timer.resize(slots)
	_light_head = 0
	_lights_live = 0
	_lights_peak = 0
	for i: int in slots:
		_light_timer[i] = 0.0
		var light := OmniLight3D.new()
		light.name = "BlastLight%d" % i
		light.light_color = light_color
		light.light_specular = 0.5
		light.shadow_enabled = false
		light.omni_attenuation = 2.0
		light.top_level = true
		light.visible = false
		add_child(light)
		_lights.append(light)


func _build_quads(slots: int) -> void:
	for quad: MeshInstance3D in _quads:
		quad.queue_free()
	_quads.clear()
	_quad_timer.resize(slots)
	_quad_head = 0
	_quads_live = 0
	_quads_peak = 0
	for i: int in slots:
		_quad_timer[i] = 0.0
		var quad := MeshInstance3D.new()
		quad.name = "Heat%d" % i
		quad.mesh = shimmer_mesh
		quad.material_override = shimmer_material
		quad.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		quad.top_level = true
		quad.visible = false
		add_child(quad)
		_quads.append(quad)
