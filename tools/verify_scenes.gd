extends SceneTree
## Loads every shipped scene and reports which ones are broken.
##
## Run headless:
##   godot --headless --path <project> --script res://tools/verify_scenes.gd
##   ... -- --frames=240 --only=range,bestiary
##   ... -- --report=res://data/scene_report.txt
##
## Options (after a bare `--`):
##   --frames=N       frames each demo runs before quitting. Default 120.
##   --only=a,b       run only these scene ids.
##   --skip=a,b       run everything except these ids.
##   --list           print what would be checked and exit.
##   --report=<path>  where the summary goes. Default res://data/scene_report.txt.
##   --probe          internal. Runs the prefab pass in this process rather than
##                    driving subprocesses; see below.
##
## TWO PASSES, BECAUSE THERE ARE TWO KINDS OF BROKEN.
##
## A demo root is checked by BOOTING IT AS THE MAIN SCENE in its own process, for
## `--frames` frames, with the real autoloads up. That is the only test that
## catches a demo whose `_ready` reaches a node that is not there, whose script
## fails to compile against the shipped autoloads, or whose first hundred frames
## push an error — none of which a bare `ResourceLoader.load` would notice.
##
## A prefab is checked by INSTANCING IT INTO A LIVE TREE in the `--probe` pass:
## player, freecam, VFX hub, terrain, town, the six kits, every cached weapon and
## every UI scene, all added to the root together, run for a few frames and freed.
## Booting sixty gun scenes as sixty processes would take a minute to tell you
## the same thing.
##
## Neither pass trusts the exit code. Godot exits 0 after a compile error, so the
## verdict comes from the console text via `tool_log.gd`.

## Shared with `bake_all.gd`: what a broken headless run looks like in the console.
const ToolLog := preload("res://tools/tool_log.gd")

## Demo roots, booted one process each. Ids match `SceneRouter.DEMOS` where the
## demo is a shipped one.
const DEMO_SCENES: Array[Array] = [
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

## Prefabs instanced by the probe pass. Explicit paths first, then whole
## directories, because the gun cache is sixty files that come and go with the
## roll table and listing them by hand would rot.
const PREFAB_SCENES: PackedStringArray = [
	"res://art/scav_world.tscn",
	"res://data/player/player.tscn",
	"res://data/player/freecam.tscn",
	"res://data/vfx/vfx.tscn",
	"res://data/world/terrain/terrain.tscn",
	"res://data/world/town/town.tscn",
	"res://ui/pause_menu.tscn",
	"res://ui/settings_panel.tscn",
	"res://demos/range/ammo_counter.tscn",
]
const PREFAB_DIRS: PackedStringArray = [
	"res://data/world/kits",
	"res://data/guns/cache",
	"res://ui/diegetic",
	"res://ui/hud",
]

const DEFAULT_REPORT: String = "res://data/scene_report.txt"
## Frames a demo runs before it is asked to quit. Two seconds at 60 Hz: long
## enough for a deferred spawn, a navigation sync and a first AI tick.
const DEFAULT_FRAMES: int = 120
## Frames the probe pass lets the prefabs live before freeing them.
const PROBE_FRAMES: int = 8

var _report_path: String = DEFAULT_REPORT
var _frames: int = DEFAULT_FRAMES
var _only: PackedStringArray = []
var _skip: PackedStringArray = []
var _list_only: bool = false
var _probe: bool = false
var _probe_frame: int = 0
var _probe_roots: Array[Node] = []
var _probe_bad: int = 0


func _initialize() -> void:
	_parse_args(OS.get_cmdline_user_args())
	if _probe:
		_probe_load()
		return
	if _list_only:
		for entry: Array in _selected():
			print("  %-12s %s" % [str(entry[0]), str(entry[1])])
		for path: String in _prefab_paths():
			print("  %-12s %s" % ["prefab", path])
		quit(0)
		return
	quit(_drive())


# --- the driver pass ---------------------------------------------------------


func _selected() -> Array[Array]:
	var picked: Array[Array] = []
	for entry: Array in DEMO_SCENES:
		var id: String = str(entry[0])
		if _only.size() > 0 and not _only.has(id):
			continue
		if _skip.has(id):
			continue
		picked.push_back(entry)
	return picked


func _drive() -> int:
	var exe: String = OS.get_executable_path()
	var project: String = ProjectSettings.globalize_path("res://")
	var lines: PackedStringArray = []
	lines.push_back("verify_scenes — %s" % Time.get_datetime_string_from_system())
	lines.push_back("%d frames per demo" % _frames)
	lines.push_back("")
	var failed: PackedStringArray = []
	var demos: Array[Array] = _selected()

	for i: int in demos.size():
		var id: String = str(demos[i][0])
		var path: String = str(demos[i][1])
		var label: String = "[%d/%d] %s" % [i + 1, demos.size() + 1, id]
		if not ResourceLoader.exists(path):
			printerr("%s  MISSING %s" % [label, path])
			lines.push_back("FAIL  %-12s not on disk: %s" % [id, path])
			failed.push_back(id)
			continue
		print("%s  %s" % [label, path])
		var argv: PackedStringArray = [
			"--headless", "--path", project, path, "--quit-after", str(_frames)
		]
		if not _report_step(id, exe, argv, lines):
			failed.push_back(id)

	if _only.is_empty() and not _skip.has("prefabs"):
		print("[%d/%d] prefabs" % [demos.size() + 1, demos.size() + 1])
		var argv: PackedStringArray = [
			"--headless",
			"--path",
			project,
			"--script",
			"res://tools/verify_scenes.gd",
			"--",
			"--probe"
		]
		if not _report_step("prefabs", exe, argv, lines):
			failed.push_back("prefabs")

	lines.push_back("")
	lines.push_back("%d checked, %d failed" % [demos.size() + 1, failed.size()])
	if failed.size() > 0:
		lines.push_back("failed: %s" % ", ".join(failed))
	_write_report(lines)
	if failed.size() > 0:
		printerr("verify_scenes: FAILED — %s" % ", ".join(failed))
		return 1
	print("verify_scenes: every scene loads clean.")
	return 0


## Runs one subprocess and folds its verdict into the report. Returns false when
## the run said something went wrong.
func _report_step(
	id: String, exe: String, argv: PackedStringArray, lines: PackedStringArray
) -> bool:
	var out: Array = []
	var started: int = Time.get_ticks_msec()
	var code: int = OS.execute(exe, argv, out, true, false)
	var took: float = (Time.get_ticks_msec() - started) / 1000.0
	var text: String = ToolLog.joined(out)
	var problems: PackedStringArray = ToolLog.problems(text)
	if code == 0 and problems.is_empty():
		print("      ok  %.1fs" % took)
		lines.push_back("OK    %-12s %6.1fs" % [id, took])
		return true
	printerr("      FAIL  exit=%d  %.1fs" % [code, took])
	lines.push_back("FAIL  %-12s %6.1fs  exit=%d" % [id, took, code])
	var shown: PackedStringArray = problems if problems.size() > 0 else ToolLog.tail(text, 16)
	for p: String in shown:
		printerr("        %s" % p)
		lines.push_back("        %s" % p)
	return false


func _prefab_paths() -> PackedStringArray:
	var paths: PackedStringArray = []
	for p: String in PREFAB_SCENES:
		paths.push_back(p)
	for d: String in PREFAB_DIRS:
		var dir: DirAccess = DirAccess.open(d)
		if dir == null:
			continue
		var names: PackedStringArray = dir.get_files()
		names.sort()
		for n: String in names:
			if n.get_extension() == "tscn":
				paths.push_back("%s/%s" % [d, n])
	return paths


# --- the probe pass ----------------------------------------------------------


## Instances every prefab into the live tree. Failures are printed rather than
## returned: the parent process reads the console, which is the only channel a
## subprocess and an engine error message have in common.
func _probe_load() -> void:
	var paths: PackedStringArray = _prefab_paths()
	print("verify_scenes: probing %d prefab(s)" % paths.size())
	for path: String in paths:
		var packed: PackedScene = ResourceLoader.load(path, "PackedScene") as PackedScene
		if packed == null:
			printerr("verify_scenes: failed to load %s" % path)
			_probe_bad += 1
			continue
		var node: Node = packed.instantiate()
		if node == null:
			printerr("verify_scenes: failed instantiating %s" % path)
			_probe_bad += 1
			continue
		_probe_roots.push_back(node)
		root.add_child(node)
	print("verify_scenes: %d instanced, %d bad" % [_probe_roots.size(), _probe_bad])


func _process(_delta: float) -> bool:
	if not _probe:
		return true
	_probe_frame += 1
	if _probe_frame < PROBE_FRAMES:
		return false
	for node: Node in _probe_roots:
		if is_instance_valid(node):
			node.free()
	_probe_roots.clear()
	quit(1 if _probe_bad > 0 else 0)
	return true


# --- plumbing ----------------------------------------------------------------


func _write_report(lines: PackedStringArray) -> void:
	DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path(_report_path.get_base_dir())
	)
	var f: FileAccess = FileAccess.open(_report_path, FileAccess.WRITE)
	if f == null:
		printerr("verify_scenes: cannot write %s" % _report_path)
		return
	f.store_string("\n".join(lines) + "\n")
	f.close()
	print("verify_scenes: report -> %s" % _report_path)


func _parse_args(args: PackedStringArray) -> void:
	for a: String in args:
		if a == "--list":
			_list_only = true
		elif a == "--probe":
			_probe = true
		elif a.begins_with("--frames="):
			_frames = maxi(1, a.substr(9).to_int())
		elif a.begins_with("--only="):
			_only = a.substr(7).split(",", false)
		elif a.begins_with("--skip="):
			_skip = a.substr(7).split(",", false)
		elif a.begins_with("--report="):
			_report_path = a.substr(9)
		else:
			printerr("verify_scenes: unknown option %s" % a)
