extends SceneTree
## Gun cache bake, entry point.
##
##   godot --headless --path <project> --script res://tools/build_gun_cache.gd
##
## Bakes seeded example weapons, the viewmodel environment and the viewmodel rig
## into res://data/guns/cache/, then verifies that every cached weapon's shouldered
## pose actually looks down its own sights. Exits non-zero if it does not.
##
## The work is in `res://tools/gun_cache/gun_cache_bake.gd` and not here for two
## reasons, both about when things exist. `--script` compiles this file before the
## autoload singletons are bound to GDScript, so a script naming `PartLibrary` at
## compile time cannot be the entry point. And the autoloads' `_ready` has not run
## when `_initialize` would fire, so `PartLibrary` would report zero parts. Waiting
## for the first process frame and loading the bake then solves both at once.

const BAKE_SCRIPT: String = "res://tools/gun_cache/gun_cache_bake.gd"

var _done: bool = false


func _process(_delta: float) -> bool:
	if _done:
		return true
	_done = true
	var script := load(BAKE_SCRIPT) as GDScript
	if script == null:
		push_error("build_gun_cache: could not load %s" % BAKE_SCRIPT)
		quit(1)
		return true
	var bake: RefCounted = script.new()
	quit(0 if bool(bake.call("run")) else 1)
	return true
