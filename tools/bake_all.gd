extends SceneTree
## Runs every bake in dependency order and reports what survived.
##
## Run headless:
##   godot --headless --path <project> --script res://tools/bake_all.gd
##   ... -- --list
##   ... -- --only=art,vfx,ui
##   ... -- --from=player
##   ... -- --skip=ash_flats --missing-only --stop-on-fail
##
## Options (after a bare `--`):
##   --list           print the plan and exit without baking.
##   --only=a,b,c     run only these step ids, in plan order.
##   --skip=a,b,c     run everything except these ids.
##   --from=id        start at this id and run to the end.
##   --to=id          stop after this id.
##   --missing-only   skip a step whose declared outputs are all already on disk.
##   --stop-on-fail   abort at the first failure. Default is to run the whole
##                    plan and report every failure at once, which is what you
##                    want when you are trying to find out how broken things are.
##   --report=<path>  where the summary goes. Default res://data/bake_report.txt.
##
## EACH STEP IS ITS OWN PROCESS. Every builder is a `SceneTree` main loop that
## calls `quit()`, so they cannot be composed in one run; and they must not be,
## because a builder that leaves a half-registered singleton or a stale
## `ResourceLoader` cache behind would poison the next one. One process per step
## also means one step crashing costs exactly that step.
##
## DEPENDENCY ORDER IS NOT ALPHABETICAL. Read `PLAN` top to bottom: art before
## anything that names a material, terrain before the town that grades into it,
## the town's `layout.res` before the terrain re-run that paints its roads, every
## prefab before the demo scenes that instance them, and the main menu last
## because it is the boot scene and should be rebuilt against a finished project.

## Shared with `verify_scenes.gd`: what a broken headless run looks like in the
## console. Preloaded rather than named, because it carries no `class_name`.
const ToolLog := preload("res://tools/tool_log.gd")

## Where the plan is written. Each entry:
##   id      short name for --only/--skip/--from/--to
##   script  the builder, run as `--script <path>`
##   args    user args appended after a bare `--`
##   out     artifacts it writes; --missing-only skips the step when all exist
##   note    why it sits here and not somewhere else
const PLAN: Array[Dictionary] = [
	{
		"id": "art",
		"script": "res://tools/build_art.gd",
		"out": ["res://art/environment.tres", "res://art/scav_world.tscn"],
		"note": "materials, sky, environment, the world scene every demo instances",
	},
	{
		"id": "gun_parts",
		"script": "res://tools/bake_gun_parts.gd",
		"out": ["res://data/guns/part_library.tres", "res://data/guns/meshes/part_94.res"],
		"note": "95 part meshes; already baked and repaired, skipped unless missing",
		"missing_only": true,
	},
	{
		"id": "gun_tuning",
		"script": "res://tools/build_gun_tuning.gd",
		"out": ["res://data/guns/gun_tuning.tres"],
		"note": "ballistics knob box, read by GunFactory",
	},
	{
		"id": "gun_audio",
		"script": "res://tools/bake_gun_audio.gd",
		"out": ["res://data/audio/gun_audio_bank.tres", "res://default_bus_layout.tres"],
		"note": "derived weapon voice — 26 samples and the bus the reference's master chain became",
	},
	{
		"id": "vfx",
		"script": "res://tools/build_vfx_assets.gd",
		"out": ["res://data/vfx/vfx.tscn"],
		"note": "textures, materials, the effect hub every demo instances",
	},
	{
		"id": "ui_assets",
		"script": "res://tools/build_ui_assets.gd",
		"out": ["res://ui/hud/combat_hud.tscn", "res://ui/diegetic/diegetic_button.tscn"],
		"note": "fonts, diegetic controls, combat HUD — demos instance these",
	},
	{
		"id": "ai_tuning",
		"script": "res://tools/build_ai_tuning.gd",
		"out": ["res://data/ai/perception_tuning.tres"],
		"note": "perception defaults",
	},
	{
		"id": "ai_roles",
		"script": "res://tools/build_ai_roles.gd",
		"out": ["res://data/ai/role_doctrine.tres"],
		"note": "squad doctrine",
	},
	{
		"id": "terrain",
		"script": "res://tools/build_terrain.gd",
		"out": ["res://data/world/terrain_data.res", "res://data/world/terrain/terrain.tscn"],
		"note": "height field first pass — the town needs it to grade against",
	},
	{
		"id": "town",
		"script": "res://tools/build_town.gd",
		"out": ["res://data/world/layout.res", "res://data/world/town/town.tscn"],
		"note": "layout, colliders, fused chunks, nav, the six kits",
	},
	{
		"id": "terrain_roads",
		"script": "res://tools/build_terrain.gd",
		"out": [],
		"note": "terrain again: road paint only exists once layout.res does",
	},
	{
		"id": "props",
		"script": "res://tools/build_props.gd",
		"out": ["res://data/world/props/props.tres"],
		"note": "standalone prop assets for scenes with no town around them",
	},
	{
		"id": "enemies",
		"script": "res://tools/build_enemies.gd",
		"out": ["res://data/enemies/husk.res"],
		"note": "twelve species welded to one skinned mesh each",
	},
	{
		"id": "player",
		"script": "res://tools/build_player.gd",
		"out": ["res://data/player/player.tscn", "res://data/player/freecam.tscn"],
		"note": "the player and freecam prefabs every demo instances",
	},
	{
		"id": "gun_cache",
		"script": "res://tools/build_gun_cache.gd",
		"out": ["res://data/guns/cache/viewmodel_rig.tscn"],
		"note": "seeded example weapons and the viewmodel rig",
	},
	{
		"id": "range",
		"script": "res://tools/build_range.gd",
		"out": ["res://demos/range/range.tscn"],
		"note": "demo",
	},
	{
		"id": "bestiary",
		"script": "res://tools/build_bestiary.gd",
		"out": ["res://demos/bestiary/bestiary.tscn"],
		"note": "demo",
	},
	{
		"id": "gunbench",
		"script": "res://tools/build_gunbench.gd",
		"out": ["res://demos/gunbench/gunbench.tscn"],
		"note": "demo",
	},
	{
		"id": "movement",
		"script": "res://tools/build_movement.gd",
		"out": ["res://demos/movement/movement.tscn"],
		"note": "demo",
	},
	{
		"id": "arena",
		"script": "res://tools/build_arena.gd",
		"out": ["res://demos/arena/arena.tscn"],
		"note": "demo — bakes its own nav and cover, needs the bestiary actors",
	},
	{
		"id": "firefight",
		"script": "res://tools/build_firefight.gd",
		"out": ["res://demos/firefight/firefight.tscn"],
		"note": "demo — needs enemies, props and the compound kit",
	},
	{
		"id": "nav_links",
		"script": "res://tools/bake_nav_links.gd",
		"out":
		[
			"res://data/ai/links/town_links.res",
			"res://data/ai/links/arena_links.res",
			"res://data/ai/links/firefight_links.res",
		],
		"note": "off-mesh links — MUST follow town, arena and firefight; it reads their navmesh",
	},
	{
		"id": "visuals",
		"script": "res://tools/build_visuals.gd",
		"out": ["res://demos/visuals/visuals.tscn"],
		"note": "demo — instances terrain, kits, props, guns and creatures",
	},
	{
		"id": "ash_flats",
		"script": "res://tools/build_ash_flats.gd",
		"out": ["res://demos/ash_flats/ash_flats.tscn"],
		"note": "demo — the open world, last of the levels because it uses all of them",
	},
	{
		"id": "main_menu",
		"script": "res://tools/build_main_menu.gd",
		"out": ["res://ui/main_menu.tscn", "res://ui/pause_menu.tscn"],
		"note": "boot scene, theme, settings page — built against a finished project",
	},
	{
		"id": "verify_multimesh",
		"script": "res://tools/verify_multimesh.gd",
		"out": [],
		"note": "gate: every baked instance buffer is populated, not silently empty",
	},
]

## Not `bake_report.txt` — that name belongs to the gun-part bake, which writes
## its own 95-row table there and would be clobbered by this summary.
const DEFAULT_REPORT: String = "res://data/bake_all_report.txt"

var _report_path: String = DEFAULT_REPORT
var _only: PackedStringArray = []
var _skip: PackedStringArray = []
var _from: String = ""
var _to: String = ""
var _missing_only: bool = false
var _stop_on_fail: bool = false
var _list_only: bool = false


func _initialize() -> void:
	_parse_args(OS.get_cmdline_user_args())
	var plan: Array[Dictionary] = _select()
	if _list_only:
		_print_plan(plan)
		quit(0)
		return
	if plan.is_empty():
		printerr("bake_all: the filters selected no steps.")
		quit(1)
		return
	quit(_run(plan))


# --- planning ----------------------------------------------------------------


func _select() -> Array[Dictionary]:
	var picked: Array[Dictionary] = []
	var started: bool = _from.is_empty()
	for step: Dictionary in PLAN:
		var id: String = str(step["id"])
		if not started:
			if id != _from:
				continue
			started = true
		if _only.size() > 0 and not _only.has(id):
			continue
		if _skip.has(id):
			continue
		picked.push_back(step)
		if not _to.is_empty() and id == _to:
			break
	if not _from.is_empty() and not started:
		printerr("bake_all: --from=%s is not a step id." % _from)
		return []
	return picked


func _print_plan(plan: Array[Dictionary]) -> void:
	print("bake_all plan — %d step(s), in order:" % plan.size())
	for i: int in plan.size():
		var step: Dictionary = plan[i]
		var file: String = str(step["script"]).trim_prefix("res://tools/")
		print("  %2d  %-14s %-30s  %s" % [i + 1, str(step["id"]), file, str(step.get("note", ""))])


## True when every declared output already exists, so `--missing-only` (or the
## step's own `missing_only` flag, which the gun-part bake sets) can skip it.
func _outputs_present(step: Dictionary) -> bool:
	var outs: Array = step.get("out", []) as Array
	if outs.is_empty():
		return false
	for path: Variant in outs:
		if not ResourceLoader.exists(str(path)) and not FileAccess.file_exists(str(path)):
			return false
	return true


# --- running -----------------------------------------------------------------


func _run(plan: Array[Dictionary]) -> int:
	var exe: String = OS.get_executable_path()
	var project: String = ProjectSettings.globalize_path("res://")
	var lines: PackedStringArray = []
	lines.push_back("bake_all — %s" % Time.get_datetime_string_from_system())
	lines.push_back("engine %s" % Engine.get_version_info()["string"])
	lines.push_back("")
	var failed: PackedStringArray = []
	var skipped: PackedStringArray = []
	var total_ms: int = 0

	for i: int in plan.size():
		var step: Dictionary = plan[i]
		var id: String = str(step["id"])
		var script_path: String = str(step["script"])
		var label: String = "[%d/%d] %s" % [i + 1, plan.size(), id]

		if (_missing_only or bool(step.get("missing_only", false))) and _outputs_present(step):
			print("%s  SKIP (outputs present)" % label)
			lines.push_back("SKIP  %-14s outputs already on disk" % id)
			skipped.push_back(id)
			continue

		if not FileAccess.file_exists(script_path):
			printerr("%s  MISSING %s" % [label, script_path])
			lines.push_back("FAIL  %-14s missing builder %s" % [id, script_path])
			failed.push_back(id)
			if _stop_on_fail:
				break
			continue

		print("%s  %s" % [label, script_path])
		var argv: PackedStringArray = ["--headless", "--path", project, "--script", script_path]
		var extra: Array = step.get("args", []) as Array
		if extra.size() > 0:
			argv.push_back("--")
			for a: Variant in extra:
				argv.push_back(str(a))

		var out: Array = []
		var started_ms: int = Time.get_ticks_msec()
		var code: int = OS.execute(exe, argv, out, true, false)
		var took: int = Time.get_ticks_msec() - started_ms
		total_ms += took
		var text: String = ToolLog.joined(out)
		var problems: PackedStringArray = ToolLog.problems(text)

		if code == 0 and problems.is_empty():
			print("      ok  %.1fs" % (took / 1000.0))
			lines.push_back("OK    %-14s %6.1fs" % [id, took / 1000.0])
			continue

		failed.push_back(id)
		printerr("      FAIL  exit=%d  %.1fs" % [code, took / 1000.0])
		lines.push_back("FAIL  %-14s %6.1fs  exit=%d" % [id, took / 1000.0, code])
		for p: String in problems:
			printerr("        %s" % p)
			lines.push_back("        %s" % p)
		if problems.is_empty():
			for tail: String in ToolLog.tail(text, 24):
				printerr("        %s" % tail)
				lines.push_back("        %s" % tail)
		if _stop_on_fail:
			break

	var ok_count: int = plan.size() - failed.size() - skipped.size()
	lines.push_back("")
	lines.push_back(
		(
			"%d ok, %d failed, %d skipped, %.1fs total"
			% [ok_count, failed.size(), skipped.size(), total_ms / 1000.0]
		)
	)
	if failed.size() > 0:
		lines.push_back("failed: %s" % ", ".join(failed))
	_write_report(lines)

	print("")
	print(lines[lines.size() - 1] if failed.is_empty() else lines[lines.size() - 2])
	if failed.size() > 0:
		printerr("bake_all: FAILED — %s" % ", ".join(failed))
		return 1
	print("bake_all: all steps green.")
	return 0


func _write_report(lines: PackedStringArray) -> void:
	DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path(_report_path.get_base_dir())
	)
	var f: FileAccess = FileAccess.open(_report_path, FileAccess.WRITE)
	if f == null:
		printerr("bake_all: cannot write %s" % _report_path)
		return
	f.store_string("\n".join(lines) + "\n")
	f.close()
	print("bake_all: report -> %s" % _report_path)


# --- args --------------------------------------------------------------------


func _parse_args(args: PackedStringArray) -> void:
	for a: String in args:
		if a == "--list":
			_list_only = true
		elif a == "--missing-only":
			_missing_only = true
		elif a == "--stop-on-fail":
			_stop_on_fail = true
		elif a.begins_with("--only="):
			_only = a.substr(7).split(",", false)
		elif a.begins_with("--skip="):
			_skip = a.substr(7).split(",", false)
		elif a.begins_with("--from="):
			_from = a.substr(7)
		elif a.begins_with("--to="):
			_to = a.substr(5)
		elif a.begins_with("--report="):
			_report_path = a.substr(9)
		else:
			printerr("bake_all: unknown option %s" % a)
