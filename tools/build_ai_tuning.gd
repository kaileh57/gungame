extends SceneTree
## Bakes the default AI perception tuning resource.
##
## The values live in the class as code defaults; this writes them out as an
## inspectable .tres so the fine-tuning pass has something to open, and so a
## change there reaches every agent without a recompile.
##
## Run headless:
##   godot --headless --path <project> --script res://tools/build_ai_tuning.gd

const OUT_DIR: String = "res://data/ai"
const OUT_PATH: String = "res://data/ai/perception_tuning.tres"


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	var script: GDScript = load("res://systems/ai/perception/ai_perception_tuning.gd")
	var tuning: Resource = script.new()
	tuning.resource_name = "AIPerceptionTuning"
	var err: int = ResourceSaver.save(tuning, OUT_PATH)
	if err != OK:
		printerr("build_ai_tuning: save failed with %d" % err)
		quit(1)
		return
	print("build_ai_tuning: wrote ", OUT_PATH)
	quit()
