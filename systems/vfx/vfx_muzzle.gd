class_name VfxMuzzle
extends Node3D
## Muzzle flashes: a pooled additive sprite and a pooled short-range light
## (range spec 16.5).
##
## The reference keeps its flash inside the viewmodel scene, so a shot lights the
## gun and nothing else. That is cheap and it is also wrong in a dark building, so
## this adds a world light — shadowless, six metres of range, and alive for a
## twentieth of a second, which is short enough that the cost is a rounding error
## and long enough that a muzzle blast washes the wall in front of you.
##
## The decay is the reference's: `intensity *= pow(0.00005, dt)`, which is a
## ninety-nine-per-cent drop in the first 25 ms. The sprite fades linearly over
## `flash_life` on top of that.
##
## The pool is built once when the hub scene loads and never grows. A flash fired
## while every slot is lit steals the oldest — the same ring the reference uses
## everywhere else, and the same bounded cost.

## Opacity and roll are per-instance shader uniforms, so the whole pool shares one
## material and still gets a different flare per shot.
const P_OPACITY: StringName = &"opacity"
const P_ROLL: StringName = &"roll"

@export var flash_mesh: Mesh = null
@export var flash_material: Material = null
## Simultaneous flashes. Eight covers a squad firing at once; a ninth steals the
## oldest, which by then is 20 ms into a 50 ms life.
@export_range(1, 32, 1) var budget: int = 8:
	set = _set_budget
## Multiplier on the caller's scale, which is already a sprite edge length in
## metres. One knob to turn every flash in the game up or down at once.
@export_range(0.1, 4.0, 0.01) var flash_size: float = 1.0
@export_range(0.005, 0.4, 0.005) var flash_life: float = 0.05
## The scale a full-power flash is quoted at. The reference's `fs` tops out at
## 0.34, so that is what `light_energy` is calibrated against.
@export_range(0.01, 2.0, 0.005) var reference_scale: float = 0.34
## Light energy at `reference_scale`. Square-rooted against the flash scale, so a
## cannon is brighter than a pistol without being seven times brighter.
@export_range(0.0, 40.0, 0.1) var light_energy: float = 5.0
@export_range(0.5, 40.0, 0.1) var light_range: float = 6.0
@export var light_color: Color = Color(1.0, 0.784, 0.502)
## Metres the flare sits ahead of the muzzle node along its local -Z, so the
## sprite's centre is not buried inside the crown of the barrel.
@export_range(0.0, 0.5, 0.005) var muzzle_lead: float = 0.06
@export var rng_seed: int = 0x0f1a51

var _sprites: Array[MeshInstance3D] = []
var _lights: Array[OmniLight3D] = []
var _timer := PackedFloat32Array()
var _energy := PackedFloat32Array()
var _head: int = 0
var _live: int = 0
var _peak: int = 0
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	_rng.seed = rng_seed
	_build(budget)


## Fire a flash at `at`'s muzzle. `scale` is the reference's `fs`: 0.05 for a
## pistol, 0.34 for a cannon, times 1.35 for a shot load.
func flash(at: Node3D, scale: float) -> void:
	if _sprites.is_empty() or at == null or not at.is_inside_tree():
		return
	var size: float = maxf(scale, 0.001) * flash_size
	var slot: int = _head
	_head = (_head + 1) % _sprites.size()

	var basis: Basis = at.global_transform.basis
	var origin: Vector3 = at.global_position - basis.z.normalized() * muzzle_lead

	var sprite: MeshInstance3D = _sprites[slot]
	sprite.transform = Transform3D(Basis.IDENTITY.scaled(Vector3(size, size, size)), origin)
	sprite.set_instance_shader_parameter(P_OPACITY, 1.0)
	sprite.set_instance_shader_parameter(P_ROLL, _rng.randf() * TAU)
	sprite.visible = true

	var light: OmniLight3D = _lights[slot]
	light.position = origin
	light.omni_range = light_range
	light.light_energy = (
		light_energy * sqrt(clampf(scale / maxf(reference_scale, 0.001), 0.05, 4.0))
	)
	light.visible = true

	if _timer[slot] <= 0.0:
		_live += 1
		_peak = maxi(_peak, _live)
	_timer[slot] = flash_life
	_energy[slot] = light.light_energy


## Advance every lit slot. Called once per frame by the hub; nothing here polls.
func step(delta: float) -> void:
	if _live <= 0:
		return
	var decay: float = pow(0.00005, delta)
	for i: int in _timer.size():
		if _timer[i] <= 0.0:
			continue
		var t: float = _timer[i] - delta
		if t <= 0.0:
			_timer[i] = 0.0
			_sprites[i].visible = false
			_lights[i].visible = false
			_live -= 1
			continue
		_timer[i] = t
		_energy[i] *= decay
		_lights[i].light_energy = _energy[i]
		_sprites[i].set_instance_shader_parameter(P_OPACITY, clampf(t / flash_life, 0.0, 1.0))


## Extinguish everything. Used on a demo reset.
func clear() -> void:
	for i: int in _timer.size():
		_timer[i] = 0.0
		_sprites[i].visible = false
		_lights[i].visible = false
	_live = 0
	_head = 0


func live_count() -> int:
	return _live


## Highest number of slots lit at once since the pool was built. The stress
## harness reads this to prove the cap holds.
func peak_count() -> int:
	return _peak


func _set_budget(value: int) -> void:
	budget = maxi(value, 1)
	if is_inside_tree() and _sprites.size() != budget:
		_build(budget)


func _build(slots: int) -> void:
	for sprite: MeshInstance3D in _sprites:
		sprite.queue_free()
	for light: OmniLight3D in _lights:
		light.queue_free()
	_sprites.clear()
	_lights.clear()
	_timer.resize(slots)
	_energy.resize(slots)
	_head = 0
	_live = 0
	_peak = 0
	for i: int in slots:
		_timer[i] = 0.0
		_energy[i] = 0.0
		var sprite := MeshInstance3D.new()
		sprite.name = "Flash%d" % i
		sprite.mesh = flash_mesh
		sprite.material_override = flash_material
		sprite.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		sprite.top_level = true
		sprite.visible = false
		add_child(sprite)
		_sprites.append(sprite)

		var light := OmniLight3D.new()
		light.name = "FlashLight%d" % i
		light.light_color = light_color
		light.light_specular = 0.4
		light.shadow_enabled = false
		light.omni_range = light_range
		light.omni_attenuation = 2.0
		light.top_level = true
		light.visible = false
		add_child(light)
		_lights.append(light)
