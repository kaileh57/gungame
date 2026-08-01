class_name VFXDecalPool
extends MultiMeshInstance3D
## Bullet holes and steel spall: one MultiMesh of unit quads, one draw call, a
## hard slot cap and least-recently-used reuse (range spec 16.3).
##
## Godot's `Decal` node projects a box and is the right answer for a handful of
## marks on awkward geometry, but two hundred and eighty of them is two hundred
## and eighty projections a frame. A quad offset 14 mm along the surface normal
## is what the reference does and what this does.
##
## Slot reuse is a plain ring: hole 281 lands on the slot hole 1 used. The new
## hole fades in over a twentieth of a second so the swap is never a pop, and the
## old one is somewhere else on the map by then anyway.

## Quads in the baked atlas: three hole variants so repeated hits on one plate do
## not stamp the same shape, plus the spall tile.
const DARK_TILES: int = 3
const SPALL_TILE: int = 3
## Metres along the normal. Any less and the quad z-fights; any more and it
## floats off a corner.
const NORMAL_OFFSET: float = 0.014

@export var rng_seed: int = 0x4d17e2

var _head: int = 0
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	_rng.seed = rng_seed
	top_level = true
	clear()


## Punch a hole. `born` is the shared VFX clock; `life` is seconds before it
## fades, or 0 to keep it until the slot comes round again.
func add(pos: Vector3, normal: Vector3, size: float, hot: bool, born: float, life: float) -> void:
	if size <= 0.0 or multimesh == null or multimesh.instance_count <= 0:
		return
	var n: Vector3 = normal.normalized()
	if not n.is_finite() or n.length_squared() < 0.5:
		n = Vector3.UP
	var reference: Vector3 = Vector3.UP if absf(n.y) < 0.985 else Vector3.FORWARD
	var x: Vector3 = reference.cross(n).normalized()
	var y: Vector3 = n.cross(x)
	var basis := Basis(x, y, n).rotated(n, _rng.randf() * TAU).scaled(Vector3.ONE * size)

	var slot: int = _head
	_head = (_head + 1) % multimesh.instance_count
	multimesh.set_instance_transform(slot, Transform3D(basis, pos + n * NORMAL_OFFSET))
	var tile: int = SPALL_TILE if hot else _rng.randi_range(0, DARK_TILES - 1)
	multimesh.set_instance_custom_data(
		slot, Color(float(tile), born, maxf(life, 0.0), 1.0 if hot else 0.0)
	)


## Collapse every slot. Used when a demo resets or the pool is resized.
func clear() -> void:
	if multimesh == null:
		return
	var flat := Transform3D(Basis().scaled(Vector3.ZERO), Vector3.ZERO)
	for i: int in multimesh.instance_count:
		multimesh.set_instance_transform(i, flat)
		multimesh.set_instance_custom_data(i, Color(0.0, 0.0, 0.0, 0.0))
	_head = 0


func resize(slots: int) -> void:
	if multimesh == null:
		return
	var wanted: int = maxi(slots, 8)
	if multimesh.instance_count != wanted:
		multimesh.instance_count = wanted
	clear()
