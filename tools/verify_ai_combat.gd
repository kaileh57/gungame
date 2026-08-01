extends SceneTree
## Runner for the AI combat harness.
##
## It does nothing but load `ai_duel_harness.gd` at runtime and print what it
## reports. The indirection is load order and nothing else: a script handed to
## `--script` is compiled before the autoloads are registered, and the harness
## rolls real guns through `GunFactory`, so it has to be loaded after the tree
## exists rather than resolved while this file is being compiled.
##
## Run headless:
##   godot --headless --path <project> --script res://tools/verify_ai_combat.gd

const HARNESS_PATH: String = "res://tools/ai_duel_harness.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	await physics_frame
	var script: GDScript = load(HARNESS_PATH)
	if script == null:
		push_error("verify_ai_combat: could not load %s." % HARNESS_PATH)
		quit(1)
		return
	var harness: Node = script.new()
	root.add_child(harness)
	# The harness prints each measurement as it takes it, so a run that wedges
	# still says how far it got. Waiting on the signal is all that is left.
	await harness.finished
	quit(0)
