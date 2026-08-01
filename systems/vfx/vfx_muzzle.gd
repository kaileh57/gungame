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
##
## WHERE THE FLARE GOES, AND WHICH PASS DRAWS IT. Both answers come from the geometry
## sitting beside the anchor, and neither can come from the anchor's own axes.
##
##   * A muzzle marker built by `GunFactory` is a bare `Marker3D` parented to the
##     assembly at `GunSpec.muzzle_local`, so it inherits the ASSEMBLY's frame — and a
##     gun in this project is built down its model +X, which is the axis
##     `muzzle_local` is measured along. An anchor a demo aims with
##     `Basis.looking_at` points its -Z down the shot instead. Leading along -Z on a
##     gun assembly threw the flare out of the SIDE of the barrel: six centimetres,
##     on a muzzle half a metre from the eye, which is the off-centre flash that was
##     reported. So the barrel answers instead of the axis — the meshes beside the
##     anchor ARE the gun, a muzzle is by definition the far end of them, and the
##     vector from their centre to the anchor is the bore whichever way the model was
##     authored. With no geometry beside it there is nothing to measure and -Z is the
##     honest default.
##   * A held gun is not rendered by the world camera at all. It sits on
##     `GameLayers.VIEWMODEL` and a second camera at 58 degrees composites it over a
##     world drawn at 78, so a world-space point does NOT land in the same place on
##     the screen in the two passes. A flash left in the world pass therefore cannot
##     line up with a muzzle drawn in the viewmodel pass however exactly it is
##     positioned. It follows its anchor's geometry into whichever pass that is in.
##
## The LIGHT stays in the world pass either way and gains the viewmodel pass on top
## when the flare went there, so a shot both washes the wall in front of you and lights
## the gun that fired it.

## Opacity and roll are per-instance shader uniforms, so the whole pool shares one
## material and still gets a different flare per shot.
const P_OPACITY: StringName = &"opacity"
const P_ROLL: StringName = &"roll"

## Children of the anchor's parent examined for the pass and the bore. A gun assembly
## is five meshes and two markers; anything longer than this is not one, and a bare
## anchor parented to a busy node must not cost a walk of it.
const ANCHOR_FANOUT: int = 12

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
## Metres the flare sits ahead of the muzzle node ALONG THE BORE, so the sprite's
## centre is not buried inside the crown of the barrel. Six centimetres is a
## barrel-crown's worth; it is small on purpose, because everything past the crown is
## the flare's own texture and not its position.
@export_range(0.0, 0.5, 0.005) var muzzle_lead: float = 0.06
## Visual layers a flash falls back to when there is no geometry beside its anchor to
## take them from — an enemy's shot, a turret, any anchor a demo re-aims itself.
@export_flags_3d_render var world_layers: int = GameLayers.WORLD
@export var rng_seed: int = 0x0f1a51

var _sprites: Array[MeshInstance3D] = []
var _lights: Array[OmniLight3D] = []
var _timer := PackedFloat32Array()
var _energy := PackedFloat32Array()
var _head: int = 0
var _live: int = 0
var _peak: int = 0
var _rng := RandomNumberGenerator.new()
## Scratch for `_seat`. Members rather than a returned Dictionary because a flash is
## fired up to fifteen times a second per gun and this file allocates nothing per shot.
var _seat_bore: Vector3 = Vector3.FORWARD
var _seat_layers: int = 0


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

	_seat(at)
	var origin: Vector3 = at.global_position + _seat_bore * muzzle_lead

	var sprite: MeshInstance3D = _sprites[slot]
	sprite.transform = Transform3D(Basis.IDENTITY.scaled(Vector3(size, size, size)), origin)
	sprite.layers = _seat_layers
	sprite.set_instance_shader_parameter(P_OPACITY, 1.0)
	sprite.set_instance_shader_parameter(P_ROLL, _rng.randf() * TAU)
	sprite.visible = true

	var light: OmniLight3D = _lights[slot]
	light.position = origin
	# The world always, plus the viewmodel when that is where the flare went, so one
	# shot lights the wall in front of you AND the gun that fired it.
	light.layers = _seat_layers | world_layers
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


## Read the bore and the render pass off the geometry beside `at`, into `_seat_bore`
## (world space, unit length) and `_seat_layers`. See the class doc for why neither can
## be taken from the anchor's own axes.
##
## THE BORE IS ONLY DERIVED FOR A `Marker3D`, and that is the whole of the test. A
## marker is by definition a POSITION inside somebody else's frame — it carries no
## orientation of its own, which is exactly why its -Z is meaningless and the geometry
## has to answer. Anything else here is a node its owner aims: `Basis.looking_at` down
## the shot, or a `Weapon` standing in for a muzzle it was never rigged with. Those
## mean their -Z, and it is taken at their word.
##
## Recomputed per shot rather than cached against the anchor. The walk is at most a
## dozen children and five `get_aabb` calls against a mesh that is already resident,
## which is far below the cost of the spawn it is part of — and a cache keyed on an
## anchor that a demo re-aims every shot would be wrong more often than it was right.
func _seat(at: Node3D) -> void:
	_seat_bore = -at.global_transform.basis.z.normalized()
	_seat_layers = world_layers
	var parent := at.get_parent() as Node3D
	if parent == null:
		return
	var box := AABB()
	var found: int = 0
	var seen: int = 0
	for child: Node in parent.get_children():
		seen += 1
		if seen > ANCHOR_FANOUT:
			break
		var geom := child as VisualInstance3D
		if geom == null or not geom.visible:
			continue
		var local: AABB = geom.transform * geom.get_aabb()
		box = local if found == 0 else box.merge(local)
		if found == 0:
			_seat_layers = geom.layers
		found += 1
	if found == 0 or not (at is Marker3D):
		return
	# `at.position` and `box` are both in the parent's frame, so their difference is the
	# bore in that frame and one basis multiply puts it in the world's.
	var along: Vector3 = at.position - box.get_center()
	if along.length_squared() < 1.0e-8:
		return
	_seat_bore = (parent.global_transform.basis * along).normalized()


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
		sprite.layers = world_layers
		sprite.top_level = true
		sprite.visible = false
		add_child(sprite)
		_sprites.append(sprite)

		var light := OmniLight3D.new()
		light.name = "FlashLight%d" % i
		light.layers = world_layers
		light.light_color = light_color
		light.light_specular = 0.4
		light.shadow_enabled = false
		light.omni_range = light_range
		light.omni_attenuation = 2.0
		light.top_level = true
		light.visible = false
		add_child(light)
		_lights.append(light)
