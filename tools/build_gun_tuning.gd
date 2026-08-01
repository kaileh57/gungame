@tool
extends SceneTree
## Writes the shipped gun balance resource.
##
## `GunTuning`'s defaults ARE the shipped balance; this bake exists so the knobs
## show up in the inspector as an editable resource instead of living only in
## code, which is what the fine-tuning pass needs. The saved file records only
## the fields that differ from the code defaults, so a fresh bake is nearly empty
## and inherits everything; once the inspector has been used, the departures are
## what is on disk. Re-running discards them, so run this when a knob is added,
## not after tuning.
##
## Run headless:
##   godot --headless --path <project> --script res://tools/build_gun_tuning.gd

const OUT_PATH := "res://data/guns/gun_tuning.tres"


func _init() -> void:
	var dir := OUT_PATH.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir):
		var err := DirAccess.make_dir_recursive_absolute(dir)
		if err != OK:
			push_error("build_gun_tuning: cannot create %s (%d)." % [dir, err])
			quit(1)
			return
	var tuning := GunTuning.new()
	tuning.resource_name = "Shipped gun balance"
	var err := ResourceSaver.save(tuning, OUT_PATH)
	if err != OK:
		push_error("build_gun_tuning: could not write %s (%d)." % [OUT_PATH, err])
		quit(1)
		return
	print("wrote %s" % OUT_PATH)
	quit(0)
