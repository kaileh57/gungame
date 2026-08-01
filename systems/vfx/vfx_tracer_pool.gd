class_name VFXTracerPool
extends MultiMeshInstance3D
## Pooled tracers: one MultiMesh, one draw call, thirty slots by default (range
## spec 16.4).
##
## The instance transform carries the whole flight path - X spans muzzle to
## impact scaled to its true length, Y is the ribbon width, Z faces the camera -
## and the shader walks a short lit section along it. So a tracer costs one
## transform write when it is fired and nothing at all after that.
##
## The camera-facing axis is computed once, at the moment of the shot, from the
## camera position passed in. That is exact rather than approximate: billboarding
## depends on where the eye is, not where it is looking, and the eye does not
## travel far in the forty-five milliseconds a tracer lives.

var _head: int = 0


func _ready() -> void:
	top_level = true
	clear()


## `speed` is the projectile's speed in m/s; pass 0 for a streak that appears
## whole. `born` is the shared VFX clock.
func add(
	from: Vector3,
	to: Vector3,
	speed: float,
	camera_pos: Vector3,
	born: float,
	life: float,
	width: float
) -> void:
	if multimesh == null or multimesh.instance_count <= 0:
		return
	var segment: Vector3 = to - from
	var path: float = segment.length()
	if path < 0.05 or not segment.is_finite():
		return
	var dir: Vector3 = segment / path
	var mid: Vector3 = from + segment * 0.5
	var side: Vector3 = dir.cross(mid - camera_pos)
	if side.length_squared() < 1.0e-9:
		side = dir.cross(Vector3.UP)
	if side.length_squared() < 1.0e-9:
		side = dir.cross(Vector3.RIGHT)
	side = side.normalized()
	# Right-handed on purpose: X cross Y must equal Z or the quad is mirrored.
	var facing: Vector3 = dir.cross(side)

	var slot: int = _head
	_head = (_head + 1) % multimesh.instance_count
	multimesh.set_instance_transform(
		slot, Transform3D(Basis(dir * path, side * width, facing), mid)
	)
	multimesh.set_instance_custom_data(slot, Color(born, maxf(life, 0.001), maxf(speed, 0.0), path))


func clear() -> void:
	if multimesh == null:
		return
	var flat := Transform3D(Basis().scaled(Vector3.ZERO), Vector3.ZERO)
	for i: int in multimesh.instance_count:
		multimesh.set_instance_transform(i, flat)
		multimesh.set_instance_custom_data(i, Color(0.0, 0.001, 0.0, 0.0))
	_head = 0


func resize(slots: int) -> void:
	if multimesh == null:
		return
	var wanted: int = maxi(slots, 4)
	if multimesh.instance_count != wanted:
		multimesh.instance_count = wanted
	clear()
