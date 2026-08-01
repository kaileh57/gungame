extends Node
## Autoload `PartLibrary`. Serves the baked gun parts and their repaired meshes.
##
## THE BAKE CONTRACT — what `res://data/guns/` must contain:
##
##   res://data/guns/part_library.tres      a GunPartSet with 95 GunPart entries,
##                                          in flat reference order, `index` set
##   res://data/guns/meshes/part_00.res     one ArrayMesh per part, welded,
##   ...                                    consistently wound, outward-facing,
##   res://data/guns/meshes/part_94.res     capped and flat-shaded
##   res://data/bake_report.txt             per-part before/after counts
##
## Each `GunPart.mesh_path` points at its own mesh. Meshes load lazily and are
## cached; the bench, which shows several guns at once, should call
## `preload_meshes()` on entry rather than fault them in mid-frame.
##
## If the baked data is missing or malformed this autoload does not paper over it:
## it raises an error naming the exact file it wanted and emits `library_failed`.
## Nothing downstream should ever receive a silently empty part list.

## Emitted once the manifest and its part records have been validated.
signal library_loaded(part_count: int)
## Emitted instead of `library_loaded` when the bake is missing or inconsistent.
signal library_failed(message: String)

const DATA_DIR: String = "res://data/guns"
const MANIFEST_PATH: String = "res://data/guns/part_library.tres"
const MESH_DIR: String = "res://data/guns/meshes"
## The reference embeds exactly 95 parts. A different count means a different
## source prototype, and every golden test vector in docs/spec/range.md is void.
const EXPECTED_PART_COUNT: int = 95
const KINDS: Array[StringName] = [&"barrel", &"stock", &"grip", &"receiver", &"sight"]

## Empty while the library is healthy; otherwise the reason it is not.
var load_error: String = ""
## Parts the bake could not fully repair. Raised as an error at boot and surfaced
## on the debug overlay, but they are still served — a hole in one part is a bake
## defect to fix, not a reason to leave the whole project without guns.
var unrepaired: PackedInt32Array = PackedInt32Array()

var _set: GunPartSet = null
var _parts: Array[GunPart] = []
var _by_kind: Dictionary = {}
var _mesh_cache: Dictionary = {}


func _ready() -> void:
	_load_library()


## All parts in flat reference order. Empty only when the bake is missing, in
## which case `load_error` says so and an error was already raised at boot.
func parts() -> Array[GunPart]:
	return _parts


## The repaired ArrayMesh for a part, loaded on first use and cached.
func mesh_for(part_index: int) -> ArrayMesh:
	if _mesh_cache.has(part_index):
		return _mesh_cache[part_index]
	var part: GunPart = self.part(part_index)
	if part == null:
		return null
	if part.mesh_path.is_empty():
		push_error("PartLibrary: part %d has no mesh_path. Re-run the part bake." % part_index)
		return null
	var mesh: ArrayMesh = ResourceLoader.load(part.mesh_path, "ArrayMesh") as ArrayMesh
	if mesh == null:
		push_error("PartLibrary: could not load %s for part %d." % [part.mesh_path, part_index])
		return null
	_mesh_cache[part_index] = mesh
	return mesh


## One part by flat index, or null if the index is out of range.
func part(part_index: int) -> GunPart:
	if part_index < 0 or part_index >= _parts.size():
		push_error(
			"PartLibrary: part index %d out of range (have %d)." % [part_index, _parts.size()]
		)
		return null
	return _parts[part_index]


## Every part of one kind, preserving flat order. The gun roll indexes into these
## arrays directly, so the order is part of the determinism contract.
func by_kind(kind: StringName) -> Array[GunPart]:
	var group: Variant = _by_kind.get(kind)
	if group == null:
		push_error("PartLibrary: unknown part kind '%s'." % kind)
		return []
	return group


func count() -> int:
	return _parts.size()


func is_loaded() -> bool:
	return load_error.is_empty() and not _parts.is_empty()


## Fault every mesh in now. Call this before opening the weapon bench.
func preload_meshes() -> void:
	for p: GunPart in _parts:
		mesh_for(p.index)


## Bake provenance, for the debug overlay.
func manifest() -> GunPartSet:
	return _set


func _load_library() -> void:
	if not DirAccess.dir_exists_absolute(DATA_DIR):
		_fail(
			(
				"res://data/guns/ does not exist. The gun part bake has not been run. "
				+ "Run res://tools/bake_gun_parts.gd to produce the manifest and meshes."
			)
		)
		return
	if not ResourceLoader.exists(MANIFEST_PATH):
		_fail("%s is missing. The part bake did not finish." % MANIFEST_PATH)
		return
	var res: Resource = ResourceLoader.load(MANIFEST_PATH)
	_set = res as GunPartSet
	if _set == null:
		_fail("%s is not a GunPartSet." % MANIFEST_PATH)
		return
	if _set.parts.size() != EXPECTED_PART_COUNT:
		_fail(
			(
				"%s holds %d parts, expected %d."
				% [MANIFEST_PATH, _set.parts.size(), EXPECTED_PART_COUNT]
			)
		)
		return
	if not _index_parts():
		return
	load_error = ""
	if not unrepaired.is_empty():
		push_error(
			(
				(
					"PartLibrary: the bake shipped %d part(s) with open boundary edges: %s. "
					% [unrepaired.size(), str(Array(unrepaired))]
				)
				+ "Holes are a bake failure, not a warning — see res://data/bake_report.txt."
			)
		)
	library_loaded.emit(_parts.size())


func _index_parts() -> bool:
	_parts.clear()
	_by_kind.clear()
	unrepaired = PackedInt32Array(_set.unrepaired)
	for kind: StringName in KINDS:
		var bucket: Array[GunPart] = []
		_by_kind[kind] = bucket
	for i: int in _set.parts.size():
		var p: GunPart = _set.parts[i]
		if p == null:
			_fail("Part slot %d in the manifest is empty." % i)
			return false
		if p.index != i:
			_fail("Part slot %d claims index %d. Flat order is the part identity." % [i, p.index])
			return false
		if not _by_kind.has(p.kind):
			_fail("Part %d has unknown kind '%s'." % [i, p.kind])
			return false
		if p.mesh_path.is_empty():
			_fail("Part %d has no mesh_path. The mesh bake did not finish." % i)
			return false
		if p.boundary_edges != 0 and not unrepaired.has(i):
			unrepaired.append(i)
		_parts.append(p)
		var bucket: Array[GunPart] = _by_kind[p.kind]
		bucket.append(p)
	return true


func _fail(message: String) -> void:
	load_error = message
	_parts.clear()
	_by_kind.clear()
	unrepaired = PackedInt32Array()
	push_error("PartLibrary: " + message)
	library_failed.emit(message)
