class_name AISpeciesProfileSet
extends Resource
## The baked roster of AI species profiles, keyed by species id.
##
## One resource, twelve embedded profiles, built once by `tools/build_ai.gd`. The
## lookup table is rebuilt on load rather than serialised, because a Dictionary of
## StringName to int is cheaper to make than to store and this happens exactly
## once per scene.

@export var profiles: Array[AISpeciesProfile] = []

var _by_id: Dictionary = {}


func get_profile(species_id: StringName) -> AISpeciesProfile:
	if _by_id.is_empty() and not profiles.is_empty():
		_reindex()
	var i: int = _by_id.get(species_id, -1)
	return null if i < 0 else profiles[i]


func has_profile(species_id: StringName) -> bool:
	return get_profile(species_id) != null


func ids() -> Array[StringName]:
	if _by_id.is_empty() and not profiles.is_empty():
		_reindex()
	var out: Array[StringName] = []
	for p: AISpeciesProfile in profiles:
		out.append(p.species_id)
	return out


func _reindex() -> void:
	_by_id.clear()
	for i: int in profiles.size():
		_by_id[profiles[i].species_id] = i
