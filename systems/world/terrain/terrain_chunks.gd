@tool
class_name TerrainChunks
extends Node3D
## Root of the baked terrain. Owns nothing but the LOD switch distances.
##
## The mesh is 100 chunks deep, each carrying three baked levels of detail and
## one concave collider built from the finest of them. Nothing here generates
## geometry — `res://tools/build_terrain.gd` did that once and wrote it to
## `res://data/world/terrain/`. All this script does is push the switch distances
## onto the `MeshInstance3D` visibility ranges, which is the whole of the runtime
## cost: Godot's renderer does the distance test itself, on its own thread.
##
## The distances are expressed as MULTIPLES OF THE CHUNK'S OWN RADIUS, not in
## metres. The sampling axis is warped by a quintic, so a chunk at the town is
## 37 m across and one at the rim is 246 m; a fixed metre threshold would hold
## the rim at full detail forever and flip the town chunks a step out from the
## player. Each chunk's radius is baked into its metadata.
##
## LOD switching is a hard swap. Godot's fade modes need a transparent pass and
## `world_material.gdshader` is opaque; at these distances the coarse level
## differs from the fine one by centimetres of silhouette, and paying for
## alpha-blended terrain to hide that would be a bad trade.

## Distance at which a chunk drops to the medium level, in chunk radii.
@export_range(1.0, 24.0, 0.1) var lod1_radii: float = 3.5:
	set(v):
		lod1_radii = v
		_apply()
## Distance at which a chunk drops to the coarse level, in chunk radii.
@export_range(1.0, 40.0, 0.1) var lod2_radii: float = 9.0:
	set(v):
		lod2_radii = v
		_apply()
## Distance at which a chunk stops drawing entirely, in chunk radii. Zero never
## culls, which is the default — the map is bounded and the horizon is the edge
## of the mesh, so a culled rim chunk is a hole in the skyline.
@export_range(0.0, 80.0, 0.5) var cull_radii: float = 0.0:
	set(v):
		cull_radii = v
		_apply()
## Terrain receives shadows but does not cast them: it is the ground plane, and
## every shadow it could cast lands on itself at a grazing angle.
@export var cast_shadows: bool = false:
	set(v):
		cast_shadows = v
		_apply()
## Global multiplier on all three distances, for the quality presets.
@export_range(0.25, 4.0, 0.05) var lod_scale: float = 1.0:
	set(v):
		lod_scale = v
		_apply()

var _levels: Array[MeshInstance3D] = []
var _radii: PackedFloat32Array = PackedFloat32Array()
var _lods: PackedInt32Array = PackedInt32Array()


func _ready() -> void:
	_collect()
	_apply()


## Cache every baked level once. The metadata is written by the builder and
## survives the pack, so this never looks at a node name.
func _collect() -> void:
	_levels.clear()
	_radii = PackedFloat32Array()
	_lods = PackedInt32Array()
	for chunk in get_children():
		var radius: float = float(chunk.get_meta(&"chunk_radius", 1.0))
		for child in chunk.get_children():
			var mi := child as MeshInstance3D
			if mi == null or not mi.has_meta(&"lod"):
				continue
			_levels.push_back(mi)
			_radii.push_back(radius)
			_lods.push_back(int(mi.get_meta(&"lod")))


func _apply() -> void:
	if _levels.is_empty():
		return
	var shadow: int = (
		GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		if cast_shadows
		else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	)
	for k in _levels.size():
		var mi: MeshInstance3D = _levels[k]
		var r: float = _radii[k] * lod_scale
		var near: float = 0.0
		var far: float = 0.0
		match _lods[k]:
			0:
				far = lod1_radii * r
			1:
				near = lod1_radii * r
				far = lod2_radii * r
			_:
				near = lod2_radii * r
				far = cull_radii * r
		mi.visibility_range_begin = near
		mi.visibility_range_end = far
		mi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED
		mi.cast_shadow = shadow


## Triangles currently eligible to draw, summed over the levels that would be
## chosen for a viewer at `from`. The F3 overlay reads this.
##
## Chunk vertices are in world space and every chunk node sits at the origin, so
## the distance has to come off the mesh bounds — which is also what the renderer
## measures `visibility_range` against.
func triangle_estimate(from: Vector3) -> int:
	var total: int = 0
	for k in _levels.size():
		var mi: MeshInstance3D = _levels[k]
		var mesh: Mesh = mi.mesh
		if mesh == null:
			continue
		var box: AABB = mi.global_transform * mesh.get_aabb()
		var d: float = box.get_center().distance_to(from)
		if d < mi.visibility_range_begin:
			continue
		if mi.visibility_range_end > 0.0 and d >= mi.visibility_range_end:
			continue
		total += mesh.surface_get_array_len(0) / 3
	return total
