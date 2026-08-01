extends SceneTree
## Every mounted panel in every baked scene, tested against the support it is
## mounted on. Run headless with `--script res://tools/verify_mounts.gd`.
##
## Two gates, because a geometric test only covers what it is pointed at:
##
## 1. INTERSECTION. For every node carrying `PanelMount` metadata, the panel's
##    oriented box is rebuilt from the bounds and the transform that were actually
##    written into the scene, and tested against the support box with a full
##    separating-axis test — fifteen axes, exact for two boxes. Any overlap is a
##    failure, and the report prints the depth in millimetres. The along-axis gap is
##    printed next to it and must come back at the clearance the mount asked for; a
##    gap that has drifted means somebody moved the panel after mounting it.
##
##    An AABB test would do here too, and be conservative in the safe direction, but
##    it reports a panel raked toward a nearby bracket as touching when it is not.
##    The SAT is the true answer and it costs thirty lines.
##
## 2. CENSUS. Every readable face in every scene — a `DiegeticReadout`, or a mesh or
##    `Label3D` whose name says sign, plate, placard, card, board or panel — counted,
##    and the ones with no mount metadata named. That is what stops a new sign from
##    quietly reintroducing the bug: an undeclared panel is not a silent pass, it is
##    a line in this report.
##
## Exit code is non-zero if any declared mount intersects its support.

const OUT_REPORT: String = "res://data/mount_report.txt"

const Mount := preload("res://ui/diegetic/panel_mount.gd")

const SCENES: Array[Array] = [
	["main_menu", "res://ui/main_menu.tscn"],
	["range", "res://demos/range/range.tscn"],
	["bestiary", "res://demos/bestiary/bestiary.tscn"],
	["ash_flats", "res://demos/ash_flats/ash_flats.tscn"],
	["arena", "res://demos/arena/arena.tscn"],
	["firefight", "res://demos/firefight/firefight.tscn"],
	["gunbench", "res://demos/gunbench/gunbench.tscn"],
	["movement", "res://demos/movement/movement.tscn"],
	["visuals", "res://demos/visuals/visuals.tscn"],
]

## Names that mean "this node carries something a player reads". Used by the census
## only — a false positive here costs a line in a report, a false negative costs a
## sign nobody checked.
const FACE_WORDS: PackedStringArray = [
	"sign", "plate", "placard", "card", "readout", "board", "panel", "title"
]

## Words that make a MESH structure rather than a readable face: the board a card
## hangs on, the lip that catches it, the mast it is bolted to, the wall planks the
## menu's shed is built out of. Meshes only — a `Label3D` called `Board` is the
## speed loop's gate sign and does count.
const NOT_A_FACE: PackedStringArray = [
	"board", "panel", "lip", "stud", "mount", "post", "slat", "cap", "shelf", "rail"
]

## Overlap under this is round-off in a float32 scene file rather than a clip.
const EPSILON: float = 0.00002

var _built: bool = false
var _report: PackedStringArray = PackedStringArray()
var _mounts: int = 0
var _clips: int = 0
var _loose: int = 0
var _faces: int = 0


func _process(_delta: float) -> bool:
	if _built:
		return true
	_built = true
	_run()
	return true


func _run() -> void:
	_line("verify_mounts")
	_line("")
	for entry: Array in SCENES:
		_scene(String(entry[0]), String(entry[1]))
	_line("")
	_line("readable faces found   %d" % _faces)
	_line("declared mounts        %d" % _mounts)
	_line("undeclared faces       %d" % _loose)
	_line("INTERSECTIONS          %d" % _clips)
	_line("RESULT: %s" % ("PASS" if _clips == 0 else "FAIL"))
	var text: String = "\n".join(_report) + "\n"
	var f: FileAccess = FileAccess.open(OUT_REPORT, FileAccess.WRITE)
	if f != null:
		f.store_string(text)
		f.close()
	print(text)
	quit(0 if _clips == 0 else 1)


func _scene(id: String, path: String) -> void:
	var packed := ResourceLoader.load(path, "PackedScene") as PackedScene
	if packed == null:
		_line("%-10s  MISSING %s" % [id, path])
		_clips += 1
		return
	var root: Node = packed.instantiate()
	var found: Array[String] = []
	var missing: Array[String] = []
	_walk(root, "", found, missing)
	_line("%-10s  %d mounted, %d undeclared" % [id, found.size(), missing.size()])
	for text: String in found:
		_line("    " + text)
	for text: String in missing:
		_line("    undeclared  " + text)
	root.free()


func _walk(node: Node, path: String, found: Array[String], missing: Array[String]) -> void:
	var here: String = node.name if path.is_empty() else path + "/" + node.name
	var spatial := node as Node3D
	if spatial != null:
		if spatial.has_meta(Mount.META_SUPPORT):
			_faces += 1
			_mounts += 1
			found.append(_check(spatial, here))
		elif _is_face(spatial):
			_faces += 1
			_loose += 1
			missing.append(here)
	for child: Node in node.get_children():
		# An instanced sub-scene is a unit. A `DiegeticButton`'s own label is the
		# button's business and is placed by the button's scene, not by a builder;
		# descending into one would fill this report with parts nobody mounts.
		if child.scene_file_path.is_empty():
			_walk(child, here, found, missing)
		else:
			_walk_root(child as Node3D, here + "/" + child.name, found, missing)


## An instanced sub-scene root: counted, never descended into.
func _walk_root(node: Node3D, here: String, found: Array[String], missing: Array[String]) -> void:
	if node == null:
		return
	if node.has_meta(Mount.META_SUPPORT):
		_faces += 1
		_mounts += 1
		found.append(_check(node, here))
	elif node is DiegeticReadout:
		_faces += 1
		_loose += 1
		missing.append(here)


## One mount, re-derived from what the scene file actually holds.
func _check(panel: Node3D, path: String) -> String:
	var bounds: AABB = panel.get_meta(Mount.META_BOUNDS)
	var support: AABB = panel.get_meta(Mount.META_SUPPORT)
	var support_name: String = String(panel.get_meta(Mount.META_SUPPORT_NAME))
	var want: float = float(panel.get_meta(Mount.META_CLEARANCE))
	var axis: int = int(panel.get_meta(Mount.META_AXIS))
	var direction: int = int(panel.get_meta(Mount.META_DIRECTION))
	var frame: Transform3D = panel.get_meta(Mount.META_FRAME)
	# Back into the frame the support box is described in. For a mount that is not
	# turned relative to its parent this is the identity and costs nothing.
	var xf: Transform3D = frame.affine_inverse() * panel.transform

	var depth: float = _penetration(xf, bounds, support)
	var reach: AABB = Mount.swept(xf.basis, bounds)
	reach.position += xf.origin
	var gap: float = (
		reach.position[axis] - support.end[axis]
		if direction >= 0
		else support.position[axis] - reach.end[axis]
	)
	var verdict: String = "ok"
	if depth > EPSILON:
		_clips += 1
		verdict = "CLIPS %.1f mm" % (depth * 1000.0)
	elif want > 0.0 and absf(gap - want) > 0.0005:
		# A solved mount must land on the clearance it asked for. A hung one asks for
		# zero, which means "prove it does not touch" and leaves the gap to the frame.
		verdict = "drifted"
	return (
		"%-44s on %-18s gap %+6.1f mm (asked %.1f)  %s"
		% [path, support_name, gap * 1000.0, want * 1000.0, verdict]
	)


## Penetration depth of an oriented box against an axis-aligned one, by separating
## axes. Zero means they do not touch. Fifteen candidate axes: the three world axes,
## the three box axes, and the nine cross products, which is the complete set for
## two convex boxes.
func _penetration(xf: Transform3D, bounds: AABB, support: AABB) -> float:
	var half: Vector3 = bounds.size * 0.5
	var centre: Vector3 = xf * (bounds.position + half)
	var arms: Array[Vector3] = [xf.basis.x * half.x, xf.basis.y * half.y, xf.basis.z * half.z]
	var delta: Vector3 = centre - (support.position + support.size * 0.5)
	var support_half: Vector3 = support.size * 0.5

	var axes: Array[Vector3] = [Vector3.RIGHT, Vector3.UP, Vector3.BACK]
	for arm: Vector3 in arms:
		if arm.length_squared() > 1e-12:
			axes.append(arm.normalized())
	for world: int in 3:
		for arm: Vector3 in arms:
			var cross: Vector3 = (
				Vector3(
					1.0 if world == 0 else 0.0,
					1.0 if world == 1 else 0.0,
					1.0 if world == 2 else 0.0
				)
				. cross(arm)
			)
			if cross.length_squared() > 1e-12:
				axes.append(cross.normalized())

	var least: float = INF
	for probe: Vector3 in axes:
		var spread: float = (
			absf(probe.x) * support_half.x
			+ absf(probe.y) * support_half.y
			+ absf(probe.z) * support_half.z
		)
		for arm: Vector3 in arms:
			spread += absf(probe.dot(arm))
		var overlap: float = spread - absf(probe.dot(delta))
		if overlap <= 0.0:
			return 0.0
		least = minf(least, overlap)
	return least


## Does this node carry something a player reads? Meshes and labels only — an empty
## `Node3D` called "Sign" is a holder, and its children are what get counted.
func _is_face(node: Node3D) -> bool:
	if node is DiegeticReadout:
		return true
	if not (node is Label3D or node is MeshInstance3D):
		return false
	var lowered: String = node.name.to_lower()
	if node is MeshInstance3D:
		for skip: String in NOT_A_FACE:
			if lowered.contains(skip):
				return false
	for word: String in FACE_WORDS:
		if lowered.contains(word):
			return true
	return false


func _line(text: String) -> void:
	_report.append(text)
