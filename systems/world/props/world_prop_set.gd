class_name WorldPropSet
extends Resource
## Manifest of every baked prop. One load gets you the lot, keyed by id.
##
## The paths are stored rather than the assets so a demo that wants three props
## does not drag in the tower and the depot with them.

@export var ids: Array[StringName] = []
@export var paths: PackedStringArray = PackedStringArray()
@export var triangle_counts: PackedInt32Array = PackedInt32Array()
@export var bounds: Array[AABB] = []

var _cache: Dictionary = {}


func count() -> int:
	return ids.size()


func index_of(id: StringName) -> int:
	return ids.find(id)


func add(id: StringName, path: String, triangle_count: int, prop_bounds: AABB) -> void:
	ids.push_back(id)
	paths.push_back(path)
	triangle_counts.push_back(triangle_count)
	bounds.push_back(prop_bounds)


## The asset for `id`, loaded once and kept. Null when the id is not in the set.
func asset(id: StringName) -> WorldPropAsset:
	if _cache.has(id):
		return _cache[id]
	var i: int = ids.find(id)
	if i < 0:
		return null
	var a: WorldPropAsset = load(paths[i]) as WorldPropAsset
	_cache[id] = a
	return a
