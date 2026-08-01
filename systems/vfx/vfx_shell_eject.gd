class_name VfxShellEject
extends MultiMeshInstance3D
## Spent brass. One MultiMesh of baked casings, one draw call, a faked arc.
##
## These are not rigid bodies and they never will be. A rigid body per case means
## a physics island per case, a contact solve per bounce and a spike every time a
## belt-fed gun opens up; and the player is looking down the sights, not at the
## floor. So the arc is the same integrator the sparks use — 11 m/s^2, a bounce
## plane that keeps a third of the horizontal speed — run on thirty-two slots of
## packed float arrays, and the case shrinks out of existence once it has been
## lying there long enough for nobody to be watching.
##
## The bounce plane is a height, not a collider. The service hands it the ground
## the player is standing on, which is right in every room and wrong only on a
## catwalk, where the case would have fallen through anyway.
##
## New shell 33 steals slot 1. Zero allocation per shot: every array is packed and
## sized once, and nothing here builds a container, a string or an object.

const RESTING: float = -1.0

@export_range(4, 128, 1) var budget: int = 32:
	set = _set_budget
## Multiplier on the baked 45 mm case. Rifle brass is the bake; 0.55 is a pistol
## case, 1.6 is something you would not want to be under.
@export_range(0.2, 4.0, 0.05) var casing_scale: float = 1.0
@export_range(0.0, 40.0, 0.1) var gravity: float = 11.0
@export_range(0.0, 1.0, 0.01) var bounce_keep_horizontal: float = 0.32
@export_range(0.0, 1.0, 0.01) var bounce_keep_vertical: float = 0.22
## Vertical speed below which a bouncing case gives up and lies down.
@export_range(0.05, 4.0, 0.05) var settle_speed: float = 0.55
## Tumble rate in rad/s, before a per-case 0.6..1.4 roll.
@export_range(0.0, 80.0, 0.5) var spin_speed: float = 26.0
## Seconds a case lies on the ground before it starts shrinking away.
@export_range(0.5, 60.0, 0.5) var linger: float = 6.0
## Seconds the shrink takes. A case is 45 mm long; at any honest viewing distance
## this reads as "it is gone", not as a pop.
@export_range(0.05, 3.0, 0.01) var sink: float = 0.4
## Ejection speed jitter as a fraction of the supplied velocity.
@export_range(0.0, 1.0, 0.01) var velocity_jitter: float = 0.22
@export var rng_seed: int = 0x5be117

var _pos := PackedVector3Array()
var _vel := PackedVector3Array()
var _axis := PackedVector3Array()
var _angle := PackedFloat32Array()
var _spin := PackedFloat32Array()
var _age := PackedFloat32Array()
var _floor := PackedFloat32Array()
var _seed := PackedFloat32Array()
## 1 while the case is still in the air, 0 once it has come to rest.
var _moving := PackedByteArray()
var _head: int = 0
var _live: int = 0
var _peak: int = 0
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	_rng.seed = rng_seed
	top_level = true
	if multimesh != null and multimesh.instance_count != budget:
		multimesh.instance_count = budget
	_reset_state()


## Throw a case. `origin` is where it leaves the port, `velocity` is its world
## velocity at that moment, `ground_y` is the height it will come to rest on.
func eject(origin: Vector3, velocity: Vector3, ground_y: float) -> void:
	if multimesh == null or _age.is_empty():
		return
	var slot: int = _head
	_head = (_head + 1) % _age.size()
	if _age[slot] < 0.0:
		_live += 1
		_peak = maxi(_peak, _live)

	var jitter: float = 1.0 + (_rng.randf() - 0.5) * 2.0 * velocity_jitter
	_pos[slot] = origin
	_vel[slot] = velocity * jitter + Vector3(0.0, _rng.randf() * 0.35, 0.0)
	var axis := Vector3(_rng.randf() - 0.5, _rng.randf() - 0.5, _rng.randf() - 0.5)
	if axis.length_squared() < 1.0e-6:
		axis = Vector3.RIGHT
	_axis[slot] = axis.normalized()
	_angle[slot] = _rng.randf() * TAU
	_spin[slot] = spin_speed * (0.6 + _rng.randf() * 0.8)
	_age[slot] = 0.0
	_floor[slot] = ground_y
	_seed[slot] = _rng.randf()
	_moving[slot] = 1
	_write(slot)


## Integrate every live case and write its transform. One pass, no branches per
## case beyond the bounce test, and an early out when the pool is empty.
func step(delta: float) -> void:
	if _live <= 0:
		return
	var rest_height: float = _rest_height()
	for i: int in _age.size():
		var age: float = _age[i]
		if age < 0.0:
			continue
		age += delta
		if age >= linger + sink:
			_age[i] = RESTING
			_live -= 1
			_collapse(i)
			continue
		_age[i] = age

		if _moving[i] != 0:
			var v: Vector3 = _vel[i]
			v.y -= gravity * delta
			var p: Vector3 = _pos[i] + v * delta
			var plane: float = _floor[i] + rest_height
			if p.y <= plane:
				p.y = plane
				if absf(v.y) < settle_speed:
					v = Vector3.ZERO
					_spin[i] = 0.0
					_moving[i] = 0
					_lie_down(i)
				else:
					v.x *= bounce_keep_horizontal
					v.z *= bounce_keep_horizontal
					v.y *= -bounce_keep_vertical
					_spin[i] *= 0.6
			_vel[i] = v
			_pos[i] = p
			_angle[i] += _spin[i] * delta
		_write(i)


## Drop every case immediately. Used on a demo reset.
func clear() -> void:
	_reset_state()


func live_count() -> int:
	return _live


func peak_count() -> int:
	return _peak


## Where a slot's case is, in world space. The MultiMesh buffer is the authority
## for drawing but cannot be read back on every renderer, so the integrator's own
## state is what the debug overlay and the stress harness ask.
func origin_of(slot: int) -> Vector3:
	if slot < 0 or slot >= _pos.size():
		return Vector3.ZERO
	return _pos[slot]


## True while a slot's case is still in the air.
func is_moving(slot: int) -> bool:
	return slot >= 0 and slot < _moving.size() and _moving[slot] != 0


func resize(slots: int) -> void:
	budget = clampi(slots, 4, 128)


## Half the case diameter: the height its centre sits at when it is lying on its
## side. Reads off the baked mesh so a re-bake at different dimensions is picked
## up without touching this file.
func _rest_height() -> float:
	if multimesh == null or multimesh.mesh == null:
		return 0.005
	return multimesh.mesh.get_aabb().size.x * 0.5 * casing_scale


## Roll the case onto its side: the long axis is local Y, so a quarter turn about
## any horizontal axis lays it flat.
func _lie_down(slot: int) -> void:
	var flat := Vector3(_vel[slot].x, 0.0, _vel[slot].z)
	if flat.length_squared() < 1.0e-8:
		flat = Vector3(cos(_seed[slot] * TAU), 0.0, sin(_seed[slot] * TAU))
	_axis[slot] = flat.normalized()
	_angle[slot] = PI * 0.5


func _write(slot: int) -> void:
	var age: float = _age[slot]
	var shrink: float = 1.0
	if age > linger:
		shrink = clampf(1.0 - (age - linger) / maxf(sink, 0.001), 0.0, 1.0)
	var s: float = casing_scale * shrink
	var basis: Basis = Basis(_axis[slot], _angle[slot]).scaled(Vector3(s, s, s))
	multimesh.set_instance_transform(slot, Transform3D(basis, _pos[slot]))
	multimesh.set_instance_custom_data(slot, Color(_seed[slot], 0.0, 0.0, 1.0))


func _collapse(slot: int) -> void:
	multimesh.set_instance_transform(slot, Transform3D(Basis().scaled(Vector3.ZERO), Vector3.ZERO))


func _set_budget(value: int) -> void:
	budget = clampi(value, 4, 128)
	if is_inside_tree():
		if multimesh != null and multimesh.instance_count != budget:
			multimesh.instance_count = budget
		_reset_state()


func _reset_state() -> void:
	var slots: int = 0 if multimesh == null else multimesh.instance_count
	_pos.resize(slots)
	_vel.resize(slots)
	_axis.resize(slots)
	_angle.resize(slots)
	_spin.resize(slots)
	_age.resize(slots)
	_floor.resize(slots)
	_seed.resize(slots)
	_moving.resize(slots)
	for i: int in slots:
		_age[i] = RESTING
		_moving[i] = 0
		_axis[i] = Vector3.RIGHT
		_collapse(i)
	_head = 0
	_live = 0
	_peak = 0
