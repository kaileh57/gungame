extends RefCounted
## Writes instance data into a `MultiMesh` in a way that survives a headless bake.
##
## `MultiMesh.set_instance_transform()` is a **silent no-op under `--headless`**.
## The setters forward to the RenderingServer, and the dummy renderer a headless
## run installs accepts the call and drops it; `MultiMesh.buffer` stays empty, so
## `ResourceSaver.save()` writes a resource with an `instance_count` and no data.
## The result loads without error and draws every instance stacked at the node
## origin. Nothing warns you. Assigning `MultiMesh.buffer` directly does not go
## through the server, so it is the only packing path a builder may use.
##
## The layout below is the engine's own, verified bit-exact (max abs diff 0.0)
## against `set_instance_transform` under a real D3D12 renderer, for scaled and
## rotated bases alike: per instance, a row-major 3x4 transform, then RGBA colour
## if `use_colors`, then RGBA custom data if `use_custom_data`. The basis rows are
## transposed out of the axis columns -- `Basis.x` is the X *axis*, i.e. column 0,
## so row `i` is `(b.x[i], b.y[i], b.z[i])`.

## Floats per instance for a TRANSFORM_3D row-major 3x4.
const XFORM_3D: int = 12

## Floats in one RGBA block, for either the colour or the custom-data slot.
const RGBA: int = 4


## Packs `transforms` (plus optional per-instance `colors` and `customs`) into
## `mm`, setting `instance_count`, `use_colors` and `use_custom_data` to match.
## Pass an empty array for a channel to leave it off. Returns the instance count
## so a caller can log it.
static func fill(
	mm: MultiMesh,
	transforms: Array,
	colors: PackedColorArray = PackedColorArray(),
	customs: PackedColorArray = PackedColorArray()
) -> int:
	var n: int = transforms.size()
	assert(colors.is_empty() or colors.size() == n, "colour count must match transform count")
	assert(customs.is_empty() or customs.size() == n, "custom count must match transform count")
	var has_col: bool = not colors.is_empty()
	var has_cus: bool = not customs.is_empty()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = has_col
	mm.use_custom_data = has_cus
	mm.instance_count = n
	if n == 0:
		return 0

	var stride: int = XFORM_3D + (RGBA if has_col else 0) + (RGBA if has_cus else 0)
	var buf := PackedFloat32Array()
	buf.resize(n * stride)
	for i: int in n:
		var t: Transform3D = transforms[i]
		var b: Basis = t.basis
		var o: int = i * stride
		buf[o + 0] = b.x.x
		buf[o + 1] = b.y.x
		buf[o + 2] = b.z.x
		buf[o + 3] = t.origin.x
		buf[o + 4] = b.x.y
		buf[o + 5] = b.y.y
		buf[o + 6] = b.z.y
		buf[o + 7] = t.origin.y
		buf[o + 8] = b.x.z
		buf[o + 9] = b.y.z
		buf[o + 10] = b.z.z
		buf[o + 11] = t.origin.z
		o += XFORM_3D
		if has_col:
			var c: Color = colors[i]
			buf[o + 0] = c.r
			buf[o + 1] = c.g
			buf[o + 2] = c.b
			buf[o + 3] = c.a
			o += RGBA
		if has_cus:
			var d: Color = customs[i]
			buf[o + 0] = d.r
			buf[o + 1] = d.g
			buf[o + 2] = d.b
			buf[o + 3] = d.a
	mm.buffer = buf
	return n


## Reads instance `i` back out of a baked `mm` without touching the RenderingServer,
## which the headless dummy renderer would otherwise answer with identity. Bake
## verifiers use this; nothing at runtime needs it.
static func read_transform(mm: MultiMesh, i: int) -> Transform3D:
	var stride: int = (
		XFORM_3D + (RGBA if mm.use_colors else 0) + (RGBA if mm.use_custom_data else 0)
	)
	var buf: PackedFloat32Array = mm.buffer
	var o: int = i * stride
	if o + XFORM_3D > buf.size():
		return Transform3D()
	return Transform3D(
		Basis(
			Vector3(buf[o + 0], buf[o + 4], buf[o + 8]),
			Vector3(buf[o + 1], buf[o + 5], buf[o + 9]),
			Vector3(buf[o + 2], buf[o + 6], buf[o + 10])
		),
		Vector3(buf[o + 3], buf[o + 7], buf[o + 11])
	)
