extends SceneTree
## Asserts that every baked `MultiMesh` in the project actually carries its
## instance data. Run headless:
##   godot --headless --path <project> --script res://tools/verify_multimesh.gd
## Exits non-zero on the first populated-count/empty-buffer mismatch.
##
## WHY THIS EXISTS. `MultiMesh.set_instance_transform()` forwards to the
## RenderingServer, and a `--headless` run installs the dummy renderer, which
## accepts the call and drops it. `MultiMesh.buffer` stays empty, `ResourceSaver`
## writes an `instance_count` with no data, and the resource loads back without a
## single warning — every instance drawn stacked on the node origin while the
## colliders sit correctly spread across the map. Nothing in the engine tells you.
## `res://tools/mm_bake.gd` writes `buffer` directly, which does not go through
## the server; this file is the check that no builder quietly regresses to the
## setters.
##
## Readback goes through `MmBake.read_transform`, not `get_instance_transform`,
## for the same reason: the getter asks the dummy server and is answered with
## identity regardless of what the resource holds.
##
## RUNTIME POOLS ARE EXEMPT. The VFX pools size their multimeshes at bake and
## fill them frame by frame under the real driver, so an empty buffer there is
## correct. They are recognised by the script they carry, not by node name — a
## pool is called `Decals` in one scene and `Vfx/Decals` in another, and a name
## list would silently stop exempting the day someone renamed one.

const MmBake := preload("res://tools/mm_bake.gd")

## Roots walked for scenes and loose `MultiMesh` resources.
const SCAN_DIRS: PackedStringArray = ["res://demos", "res://data", "res://ui", "res://art"]

## Scripts that mark a `MultiMeshInstance3D` as a pool filled at play time.
const RUNTIME_POOLS: PackedStringArray = [
	"res://systems/vfx/vfx_decal_pool.gd",
	"res://systems/vfx/vfx_tracer_pool.gd",
	"res://systems/vfx/vfx_shell_eject.gd",
]

var _started: bool = false


func _process(_delta: float) -> bool:
	if _started:
		return true
	_started = true
	_run()
	return true


func _run() -> void:
	var paths := PackedStringArray()
	for root: String in SCAN_DIRS:
		_collect(root, paths)
	paths.sort()

	var lines := PackedStringArray()
	var failures := PackedStringArray()
	var nodes: int = 0
	var instances: int = 0
	var exempt: int = 0

	for path: String in paths:
		var res: Resource = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
		if res == null:
			continue
		if res is MultiMesh:
			var mm: MultiMesh = res
			nodes += 1
			instances += mm.instance_count
			_grade(path, "", mm, failures)
			continue
		if not (res is PackedScene):
			continue
		var root_node: Node = (res as PackedScene).instantiate()
		var found: Array[MultiMeshInstance3D] = []
		_walk(root_node, found)
		for mmi: MultiMeshInstance3D in found:
			var mesh: MultiMesh = mmi.multimesh
			if mesh == null:
				failures.push_back("%s:%s has no MultiMesh" % [path, root_node.get_path_to(mmi)])
				continue
			var label: String = String(root_node.get_path_to(mmi))
			var script: Script = mmi.get_script() as Script
			if script != null and RUNTIME_POOLS.has(script.resource_path):
				exempt += 1
				continue
			nodes += 1
			instances += mesh.instance_count
			_grade(path, label, mesh, failures)
		root_node.free()

	lines.push_back("multimesh verification")
	lines.push_back("roots     " + ", ".join(SCAN_DIRS))
	lines.push_back("")
	lines.push_back("multimeshes checked   %d" % nodes)
	lines.push_back("instances checked     %d" % instances)
	lines.push_back("runtime pools skipped %d" % exempt)
	lines.push_back("")
	if failures.is_empty():
		lines.push_back("RESULT: PASS - every instance buffer is populated")
	else:
		lines.push_back("RESULT: FAIL - %d multimesh(es) with findings" % failures.size())
		for f: String in failures:
			lines.push_back("  " + f)
	print("\n".join(lines))
	quit(0 if failures.is_empty() else 1)


## A multimesh fails if it declares instances but stores no buffer, if the buffer
## is the wrong length for its declared channels, or if every instance sits on the
## origin — the exact signature of a set_instance_transform bake.
func _grade(path: String, label: String, mm: MultiMesh, failures: PackedStringArray) -> void:
	var where: String = path if label.is_empty() else "%s:%s" % [path, label]
	if mm.instance_count == 0:
		return
	var stride: int = (
		MmBake.XFORM_3D
		+ (MmBake.RGBA if mm.use_colors else 0)
		+ (MmBake.RGBA if mm.use_custom_data else 0)
	)
	var want: int = mm.instance_count * stride
	if mm.buffer.size() == 0:
		failures.push_back(
			(
				"%s: %d instances, EMPTY buffer (bake used set_instance_transform)"
				% [where, mm.instance_count]
			)
		)
		return
	if mm.buffer.size() != want:
		failures.push_back(
			(
				"%s: buffer %d floats, expected %d for %d instances"
				% [where, mm.buffer.size(), want, mm.instance_count]
			)
		)
		return
	if mm.instance_count < 2:
		return
	var at_origin: int = 0
	for i: int in mm.instance_count:
		if MmBake.read_transform(mm, i).origin.is_equal_approx(Vector3.ZERO):
			at_origin += 1
	if at_origin == mm.instance_count:
		failures.push_back("%s: all %d instances sit on the origin" % [where, mm.instance_count])


func _walk(node: Node, out: Array[MultiMeshInstance3D]) -> void:
	if node is MultiMeshInstance3D:
		out.push_back(node)
	for child: Node in node.get_children():
		_walk(child, out)


func _collect(root: String, out: PackedStringArray) -> void:
	var dir := DirAccess.open(root)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry: String = dir.get_next()
	while entry != "":
		if entry.begins_with("."):
			entry = dir.get_next()
			continue
		var full: String = root.path_join(entry)
		if dir.current_is_dir():
			_collect(full, out)
		else:
			var ext: String = entry.get_extension().to_lower()
			if ext == "res" or ext == "tres" or ext == "tscn" or ext == "scn":
				out.push_back(full)
		entry = dir.get_next()
	dir.list_dir_end()
