extends SceneTree
## ADS occlusion probe, entry point.
##
##   godot --headless --path <project> --script res://tools/verify_ads_occlusion.gd
##
## Rolls a wide sample of weapons — every receiver class, with irons, with an
## optic and with a scope, across every tier the roll produces — puts each one
## into the shipped shouldered pose and MEASURES how much of the sight picture
## the weapon's own geometry covers. Exits non-zero when the sample misses the
## bars in `res://tools/ads_occlusion/ads_occlusion.gd`.
##
## Split in two for the same reason the gun cache bake is: `--script` compiles
## this file before the autoload singletons are bound to GDScript, so a script
## naming `PartLibrary` at compile time cannot be the entry point, and the
## autoloads' `_ready` has not run when `_initialize` would fire.

const PROBE_SCRIPT: String = "res://tools/ads_occlusion/ads_occlusion.gd"

var _done: bool = false


func _process(_delta: float) -> bool:
	if _done:
		return true
	_done = true
	var script := load(PROBE_SCRIPT) as GDScript
	if script == null:
		push_error("verify_ads_occlusion: could not load %s" % PROBE_SCRIPT)
		quit(1)
		return true
	var probe: RefCounted = script.new()
	quit(0 if bool(probe.call("run")) else 1)
	return true
