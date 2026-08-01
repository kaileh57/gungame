@tool
extends SceneTree
## Mesh validator. Walks every baked mesh under a directory and reports, per
## surface: shells, signed volume, inverted shells, boundary edges, non-manifold
## edges, degenerate triangles and coplanar duplicate faces.
##
## Run headless:
##   godot --headless --path <project> --script res://tools/validate_meshes.gd
##   ... -- --dir=res://data/world/props --report=res://data/props_validation.txt
##   ... -- --verbose --quiet-pass
##
## Options (all optional, `--key=value` after a bare `--`):
##   --dir=<res path>     root to scan. Default res://data. Repeatable.
##   --report=<res path>  where to write. Default res://data/mesh_validation.txt.
##   --open=<substring>   paths containing this are open surfaces (a heightfield
##                        has boundary edges by definition and is not a defect).
##                        Repeatable. Default: "terrain".
##   --verbose            list every mesh, not just the ones with findings.
##   --quiet-pass         suppress the per-mesh table entirely; summary only.
##
## WINDING. Godot's rasteriser treats CLOCKWISE triangles as front-facing, so an
## outward-facing closed shell has NEGATIVE volume under the textbook right-hand
## form `p0 . (p1 x p2) / 6`. Everything below reports the negated value, i.e.
## POSITIVE MEANS OUTWARD, and a shell whose reported volume is negative is
## inside out: from the outside you see through it, from the inside you see its
## walls. That is the #1 defect this file exists to catch.
##
## SHELLS, NOT MESHES. Props are built from overlapping solids that interpenetrate
## without sharing vertices, so each solid stays its own edge-connected component
## and is validated on its own. Two solids that were butted rather than overlapped
## weld into one component with a four-triangle edge, which is reported as
## non-manifold — which is exactly the seam you wanted to hear about.
##
## CHUNKS ARE NOT MESHES EITHER. The town is one fused triangle soup cut into 48 m
## cells by `WorldMesher.chunk_triangles`, which buckets whole triangles by their
## centroid. Every cell boundary therefore slices through closed solids along a
## ragged line of triangle edges, and each chunk on its own is a lidless fragment:
## thousands of boundary edges and half-shells whose volume about their own
## centroid means nothing. Scoring a chunk alone reports the cut, not a hole. Any
## file or node named `chunk_*` is accumulated with its siblings in the same
## directory (or under the same parent node) and the union is scored once — the
## union is what the player stands in, and the union is what must be closed.

const DEFAULT_ROOT: String = "res://data"
const DEFAULT_REPORT: String = "res://data/mesh_validation.txt"
const DEFAULT_OPEN: PackedStringArray = ["terrain"]
## Files and nodes whose name starts with this are fragments of one larger solid
## and are validated fused. See the note above.
const CHUNK_PREFIX: String = "chunk_"

## The per-shell auditor. Shared with the builders so a bake gates on the same
## arithmetic this sweep grades it by, rather than on a decorative volume sum.
const MeshAudit := preload("res://tools/mesh_audit.gd")

var _roots: PackedStringArray = PackedStringArray()
var _open_marks: PackedStringArray = PackedStringArray()
var _report_path: String = DEFAULT_REPORT
var _verbose: bool = false
var _quiet_pass: bool = false
var _started: bool = false


## The scan waits for the first idle frame. It instances every `PackedScene` it
## finds, and those carry scripts that name autoloads — which `--script` has not
## registered yet while `_initialize` runs.
func _process(_delta: float) -> bool:
	if _started:
		return true
	_started = true
	_run()
	return true


func _run() -> void:
	_parse_args(OS.get_cmdline_user_args())
	if _roots.is_empty():
		_roots.push_back(DEFAULT_ROOT)
	if _open_marks.is_empty():
		_open_marks = DEFAULT_OPEN

	var t0: int = Time.get_ticks_msec()
	var paths: PackedStringArray = PackedStringArray()
	for root: String in _roots:
		_collect(root, paths)
	paths.sort()

	var lines: PackedStringArray = PackedStringArray()
	lines.push_back("mesh validation")
	lines.push_back("roots     " + ", ".join(_roots))
	lines.push_back("open      " + ", ".join(_open_marks))
	lines.push_back(
		"weld %s  area %s  volume %s" % [MeshAudit.WELD, MeshAudit.AREA_EPS, MeshAudit.VOLUME_EPS]
	)
	lines.push_back("")
	lines.push_back(
		(
			"%-52s %-5s %7s %7s %6s %6s %6s %6s %6s %6s %12s"
			% [
				"mesh",
				"surf",
				"tris",
				"verts",
				"shell",
				"bnd",
				"nonmf",
				"degen",
				"dupe",
				"flip",
				"volume"
			]
		)
	)
	lines.push_back("-".repeat(132))

	var totals: Dictionary = {
		"meshes": 0,
		"surfaces": 0,
		"tris": 0,
		"shells": 0,
		"inverted": 0,
		"boundary": 0,
		"nonmanifold": 0,
		"degenerate": 0,
		"duplicate": 0,
		"flat": 0,
		"flip": 0,
		"empty": 0,
		"unreadable": 0,
	}
	var failures: PackedStringArray = PackedStringArray()

	# Chunks are held back and scored fused. Insertion order of the dictionary is
	# the order the groups are reported in, which follows the sorted path list.
	var groups: Dictionary = {}
	var group_order: PackedStringArray = PackedStringArray()

	for path: String in paths:
		var res: Resource = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
		if res == null:
			totals["unreadable"] += 1
			continue
		for entry: Dictionary in _meshes_in(res):
			var label: String = String(entry["label"])
			var mesh: Mesh = entry["mesh"] as Mesh
			var key: String = _chunk_group(path, label)
			if key.is_empty():
				_check_mesh(path, label, mesh, totals, lines, failures)
				continue
			if not groups.has(key):
				groups[key] = []
				group_order.push_back(key)
			(groups[key] as Array).push_back(mesh)

	for key: String in group_order:
		_check_group(key, groups[key] as Array, totals, lines, failures)

	lines.push_back("")
	lines.push_back("meshes                %d" % int(totals["meshes"]))
	lines.push_back("surfaces              %d" % int(totals["surfaces"]))
	lines.push_back("triangles             %d" % int(totals["tris"]))
	lines.push_back("shells                %d" % int(totals["shells"]))
	lines.push_back("flat shells           %d" % int(totals["flat"]))
	lines.push_back("inverted shells       %d" % int(totals["inverted"]))
	lines.push_back("boundary edges        %d" % int(totals["boundary"]))
	lines.push_back("non-manifold edges    %d" % int(totals["nonmanifold"]))
	lines.push_back("degenerate triangles  %d" % int(totals["degenerate"]))
	lines.push_back("duplicate faces       %d" % int(totals["duplicate"]))
	lines.push_back("winding/normal flips  %d" % int(totals["flip"]))
	lines.push_back("empty surfaces        %d" % int(totals["empty"]))
	lines.push_back("unreadable files      %d" % int(totals["unreadable"]))
	lines.push_back("scan time             %d ms" % (Time.get_ticks_msec() - t0))
	lines.push_back("")
	if failures.is_empty():
		lines.push_back(
			(
				"RESULT: PASS - %d meshes, %d shells, all closed and outward"
				% [int(totals["meshes"]), int(totals["shells"])]
			)
		)
	else:
		lines.push_back("RESULT: FAIL - %d surfaces with findings" % failures.size())
		for f: String in failures:
			lines.push_back("  " + f)

	var text: String = "\n".join(lines) + "\n"
	DirAccess.make_dir_recursive_absolute(_report_path.get_base_dir())
	var fh := FileAccess.open(_report_path, FileAccess.WRITE)
	if fh != null:
		fh.store_string(text)
		fh.close()
	print(text)
	quit(0 if failures.is_empty() else 1)


## Every mesh reachable from a saved resource: the resource itself when it is one,
## any mesh held in an exported property of it, and — the case that matters most —
## every mesh inside a `PackedScene`.
##
## MOST OF THIS PROJECT'S GEOMETRY LIVES IN A SCENE, not in a bare `.res`. The
## twelve creatures, the player, the cached weapons and every demo are packed
## scenes with their meshes buried in `_bundled`, so a validator that only reads
## top-level resources scores them all as clean by never looking. It did, and an
## entire inside-out roster went unnoticed behind a PASS. Instancing costs a few
## seconds and is the only way to see what actually ships.
func _meshes_in(res: Resource) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var direct: Mesh = res as Mesh
	if direct != null:
		out.push_back({"label": "", "mesh": direct})
		return out
	var scene: PackedScene = res as PackedScene
	if scene != null:
		var root: Node = scene.instantiate(PackedScene.GEN_EDIT_STATE_DISABLED)
		if root != null:
			_meshes_in_node(root, "", out)
			root.free()
		return out
	for prop: Dictionary in res.get_property_list():
		if int(prop["usage"]) & PROPERTY_USAGE_STORAGE == 0:
			continue
		if int(prop["type"]) != TYPE_OBJECT:
			continue
		var held: Mesh = res.get(String(prop["name"])) as Mesh
		if held != null:
			out.push_back({"label": String(prop["name"]), "mesh": held})
	return out


## Walks an instanced scene for anything carrying geometry. `MultiMeshInstance3D`
## is unwrapped to its source mesh — the instance buffer is a transform list, and
## a mesh that is inside out is inside out however many times it is drawn.
func _meshes_in_node(node: Node, prefix: String, out: Array[Dictionary]) -> void:
	var label: String = prefix + String(node.name)
	var mi := node as MeshInstance3D
	if mi != null and mi.mesh != null:
		out.push_back({"label": label, "mesh": mi.mesh})
	var mm := node as MultiMeshInstance3D
	if mm != null and mm.multimesh != null and mm.multimesh.mesh != null:
		out.push_back({"label": label, "mesh": mm.multimesh.mesh})
	for child: Node in node.get_children():
		_meshes_in_node(child, label + "/", out)


## The group a chunk belongs to, or "" for anything that is a solid in its own
## right. Siblings in one directory fuse; siblings under one parent node fuse.
## `res://data/world/town/chunk_n01_p01.res` and the same chunk reached as
## `res://demos/ash_flats/ash_flats.tscn:AshFlats/Town/chunk_n01_p01` are two
## different groups on purpose — the second is what the demo actually ships, and
## a demo that instanced only half a town should say so.
##
## Open surfaces never fuse. The terrain is chunked too, but each of its cells is
## a heightfield that already validates as open, and its cells carry a LOD ladder
## whose levels occupy the same ground — fusing those would stack three copies of
## the same hillside and report the stack as non-manifold.
func _chunk_group(path: String, label: String) -> String:
	if _is_open(path) or _is_open(label):
		return ""
	if label.is_empty():
		if not path.get_file().begins_with(CHUNK_PREFIX):
			return ""
		return path.get_base_dir() + "/" + CHUNK_PREFIX + "*"
	var parts: PackedStringArray = label.split("/")
	for i in parts.size():
		if parts[i].begins_with(CHUNK_PREFIX):
			var head: PackedStringArray = parts.slice(0, i)
			head.push_back(CHUNK_PREFIX + "*")
			return "%s:%s" % [path, "/".join(head)]
	return ""


## Scores one fused chunk group. The triangles of every member are concatenated
## into a single de-indexed soup and audited once, so a cell boundary — which is
## an interior edge of the union — pairs up instead of counting as a hole.
##
## Surfaces are fused together as well as chunks. The town's cells carry one
## surface each; where a group's members carry several, they are still one solid
## split by material and the shell they bound is only closed when all of them are
## present.
func _check_group(
	key: String,
	meshes: Array,
	totals: Dictionary,
	lines: PackedStringArray,
	failures: PackedStringArray
) -> void:
	var pos := PackedVector3Array()
	var nrm := PackedVector3Array()
	var has_normals: bool = true
	for mesh: Mesh in meshes:
		totals["meshes"] += 1
		for si in mesh.get_surface_count():
			var arrays: Array = mesh.surface_get_arrays(si)
			if arrays.is_empty() or arrays[Mesh.ARRAY_VERTEX] == null:
				continue
			var p: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var n: PackedVector3Array = (
				arrays[Mesh.ARRAY_NORMAL]
				if arrays[Mesh.ARRAY_NORMAL] != null
				else PackedVector3Array()
			)
			if n.size() != p.size():
				has_normals = false
			var idx: PackedInt32Array = (
				arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
			)
			if idx.is_empty():
				pos.append_array(p)
				if n.size() == p.size():
					nrm.append_array(n)
			else:
				for c in idx.size():
					pos.push_back(p[idx[c]])
					if n.size() == p.size():
						nrm.push_back(n[idx[c]])

	var fused: Array = []
	fused.resize(Mesh.ARRAY_MAX)
	fused[Mesh.ARRAY_VERTEX] = pos
	if has_normals and nrm.size() == pos.size():
		fused[Mesh.ARRAY_NORMAL] = nrm
	var row: Dictionary = MeshAudit.check_surface(fused)
	_record(key + " (%d fused)" % meshes.size(), -1, row, totals, lines, failures)


func _check_mesh(
	path: String,
	label: String,
	mesh: Mesh,
	totals: Dictionary,
	lines: PackedStringArray,
	failures: PackedStringArray
) -> void:
	totals["meshes"] += 1
	# The node path counts as well as the file path. The same terrain chunk is
	# reached both as `res://data/world/terrain/chunk_01_00.res` and as
	# `res://demos/ash_flats/ash_flats.tscn:AshFlats/Terrain/chunk_01_00/lod0`,
	# and it is an open heightfield either way.
	var where: String = path if label == "" else "%s:%s" % [path, label]
	for si in mesh.get_surface_count():
		var row: Dictionary = MeshAudit.check_surface(mesh.surface_get_arrays(si))
		_record(where, si, row, totals, lines, failures)


## One audited surface into the totals, the table and the failure list. `surface`
## is -1 for a fused chunk group, which has no single surface index to name.
func _record(
	where: String,
	surface: int,
	row: Dictionary,
	totals: Dictionary,
	lines: PackedStringArray,
	failures: PackedStringArray
) -> void:
	var open: bool = _is_open(where)
	totals["surfaces"] += 1
	totals["tris"] += int(row["tris"])
	totals["shells"] += int(row["shells"])
	totals["inverted"] += int(row["inverted"])
	totals["nonmanifold"] += int(row["nonmanifold"])
	totals["degenerate"] += int(row["degenerate"])
	totals["duplicate"] += int(row["duplicate"])
	totals["flat"] += int(row["flat"])
	totals["flip"] += int(row["flip"])
	if int(row["tris"]) == 0:
		totals["empty"] += 1
	if not open:
		totals["boundary"] += int(row["boundary"])

	var bad: bool = (
		int(row["nonmanifold"]) > 0
		or int(row["degenerate"]) > 0
		or int(row["duplicate"]) > 0
		or int(row["flip"]) > 0
		or int(row["tris"]) == 0
		or (not open and int(row["boundary"]) > 0)
		or (not open and int(row["inverted"]) > 0)
	)
	var surf_label: String = "fused" if surface < 0 else str(surface)
	if bad:
		failures.push_back("%s surface %s: %s" % [where, surf_label, _why(row, open)])
	if _quiet_pass or (not bad and not _verbose):
		return
	(
		lines
		. push_back(
			(
				"%-52s %-5s %7d %7d %6d %6d %6d %6d %6d %6d %12.5f"
				% [
					_short(where),
					"open" if open else surf_label,
					int(row["tris"]),
					int(row["verts"]),
					int(row["shells"]),
					int(row["boundary"]),
					int(row["nonmanifold"]),
					int(row["degenerate"]),
					int(row["duplicate"]),
					int(row["flip"]),
					float(row["volume"]),
				]
			)
		)
	)


func _parse_args(args: PackedStringArray) -> void:
	for a: String in args:
		if a == "--verbose":
			_verbose = true
		elif a == "--quiet-pass":
			_quiet_pass = true
		elif a.begins_with("--dir="):
			_roots.push_back(a.substr(6))
		elif a.begins_with("--report="):
			_report_path = a.substr(9)
		elif a.begins_with("--open="):
			_open_marks.push_back(a.substr(7))


## Case-insensitive: the same heightfield is `res://data/world/terrain/...` on
## disk and a node called `Terrain` inside a demo, and `--open=terrain` means
## both.
func _is_open(path: String) -> bool:
	var lower: String = path.to_lower()
	for m: String in _open_marks:
		if m != "" and lower.contains(m.to_lower()):
			return true
	return false


static func _short(path: String) -> String:
	var s: String = path.trim_prefix("res://data/")
	return s if s.length() <= 58 else "..." + s.substr(s.length() - 55)


static func _why(row: Dictionary, open: bool) -> String:
	return MeshAudit.why(row, open)


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
			if ext == "res" or ext == "tres" or ext == "mesh" or ext == "tscn":
				out.push_back(full)
		entry = dir.get_next()
	dir.list_dir_end()
