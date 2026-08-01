extends SceneTree
## Runner for the three-faction war harness.
##
##     godot --headless --path <project> --script res://systems/ai/verify/sim_factions.gd
##
## It does nothing but load the harness once the tree exists and print what it
## reports. The indirection is load order and nothing else: a script handed to
## `--script` is compiled before the autoloads are registered, and every line of
## the harness leans on `Factions`.
##
## Append `-- <seed>` to fight the same war with a different roll of the dice.

const HARNESS_PATH: String = "res://systems/ai/verify/faction_war_harness.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	await physics_frame
	var script: GDScript = load(HARNESS_PATH)
	if script == null:
		push_error("sim_factions: could not load %s." % HARNESS_PATH)
		quit(1)
		return
	var harness: Node = script.new()
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if args.size() > 0 and args[0].is_valid_int():
		harness.seed_value = args[0].to_int()
	root.add_child(harness)
	var report: String = await harness.finished
	print("")
	print(report)
	harness.queue_free()
	quit(0 if report.begins_with("VERDICT PASS") else 1)
