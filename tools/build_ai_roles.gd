extends SceneTree
## Bakes the shared squad doctrine resource.
##
##     godot --headless --path <project> --script res://tools/build_ai_roles.gd
##
## One `AIRoles` for the whole game: the role mix, the scoring weights and the
## squad-behaviour thresholds every `AISquad` reads. The defaults written here
## are the ones the headless war in `systems/ai/verify/sim_factions.gd` was tuned
## against, so re-running that sim after editing this file tells you whether the
## edit broke the war.

const OUT_PATH: String = "res://data/ai/role_doctrine.tres"


func _initialize() -> void:
	var dir: String = OUT_PATH.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir):
		var err: int = DirAccess.make_dir_recursive_absolute(dir)
		if err != OK:
			push_error("build_ai_roles: cannot create %s (%d)." % [dir, err])
			quit(1)
			return
	var doctrine: AIRoles = AIRoles.new()
	doctrine.resource_name = "role_doctrine"
	var err: int = ResourceSaver.save(doctrine, OUT_PATH)
	if err != OK:
		push_error("build_ai_roles: save failed (%d)." % err)
		quit(1)
		return
	print("build_ai_roles: wrote %s" % OUT_PATH)
	print(
		(
			"  mix anchor_min=%d suppressor=%.2f flanker=%.2f advancer=%.2f scout=%.2f"
			% [
				doctrine.anchor_min,
				doctrine.suppressor_fraction,
				doctrine.flanker_fraction,
				doctrine.advancer_fraction,
				doctrine.scout_fraction,
			]
		)
	)
	print(
		(
			"  squad reassign=%.2fs bound=%.1fs movers=%d coverers=%d engage=%.0fm"
			% [
				doctrine.reassign_interval,
				doctrine.bound_duration,
				doctrine.bound_max_movers,
				doctrine.bound_min_coverers,
				doctrine.engage_range,
			]
		)
	)
	quit()
