extends Node
## Renders the shouldered pose so a human can look at it.
##
##   "<godot>" --path <proj> --resolution 1600x900 res://tools/ads_occlusion/ads_shot.tscn
##
## `tools/capture.tscn` photographs every demo at rest, which is the HIP pose; the
## whole ADS occlusion question is invisible in those frames. This instances the
## range — the one demo that ships a player, a holster and the viewmodel pass with
## a rack of weapons behind them — equips a handful of weapons chosen to span the
## part set, and takes a hip frame and a full-ADS frame of each through the real
## viewmodel camera.
##
## The trigger is the real one: `Input.action_press(&"aim")` drives the same action
## `PlayerController` polls, so the ADS blend, the FOV lerp and the pose all run
## exactly as they do in play rather than being poked into place.
##
## Options, after a bare `--`:
##   --demo=<id>   `range` (default) or `gunbench`. Both ship a player, a holster
##                 and the viewmodel pass; the range gives you a target line to
##                 judge the sight picture against and the bench gives you a dark
##                 room to judge the silhouette against.
##   --legacy      photograph the OLD solve instead: the same resource with its two
##                 clearing stages turned off and the fallback pushed out of reach,
##                 which is exactly what the occlusion probe measures as BEFORE.
##                 That is what makes the two sets comparable — one build, one
##                 scene, three tunables.
##
## Runs as a SCENE, not through `--script`, because these demos reach for every
## autoload in the project and `--script` compiles before they exist.

const SCENES: Dictionary = {
	"range": "res://demos/range/range.tscn",
	"gunbench": "res://demos/gunbench/gunbench.tscn",
}
const OUT_DIR: String = "res://_shots/ads"
const LEGACY_DIR: String = "res://_shots/ads_before"
## Where the holster hangs off the baked player, in every demo that has one.
const HOLSTER_PATH: NodePath = NodePath("Player/Eye/Holster")
## Seeds scanned for one weapon per wanted (receiver class, optic) pair.
const SEED_BUDGET: int = 20000
## Frames the range is allowed to stall in: mesh upload, shader compilation and the
## first navigation query all land inside this.
const WARM_FRAMES: int = 150
## Frames between equipping a weapon and photographing it. The swap is stow plus
## draw and runs off `GunSpec.mass`, so the heaviest weapon here needs about 70.
const SETTLE_FRAMES: int = 90
## Frames the aim button is held before the ADS frame is taken. `ads_damp_rate` is
## 14 per second, so this is several time constants and the blend is at 1.
const AIM_FRAMES: int = 75

## The cases worth looking at: the classes whose geometry used to sit across the
## view axis, one with irons, one with an optic and one with a full scope.
const WANTED: Array[Array] = [
	["lmg", "irons"],
	["smg", "optic"],
	["pistol", "irons"],
	["sniper", "scope"],
	["rifle", "optic"],
	["launcher", "irons"],
]

var _scene: Node = null
var _holster: Node = null
var _picks: Array = []
var _index: int = 0
var _frame: int = 0
var _stage: int = 0
var _legacy: bool = false
var _demo: String = "range"
var _out: String = OUT_DIR
var _log: PackedStringArray = PackedStringArray()


func _ready() -> void:
	for arg: String in OS.get_cmdline_user_args():
		if arg == "--legacy":
			_legacy = true
		elif arg.begins_with("--demo="):
			_demo = arg.substr(7)
	if not SCENES.has(_demo):
		printerr("ads_shot: unknown demo '%s'. Known: %s" % [_demo, ", ".join(SCENES.keys())])
		get_tree().quit(1)
		return
	_out = "%s/%s" % [LEGACY_DIR if _legacy else OUT_DIR, _demo]
	DirAccess.make_dir_recursive_absolute(_out)
	var packed := load(String(SCENES[_demo])) as PackedScene
	if packed == null:
		printerr("ads_shot: could not load %s" % SCENES[_demo])
		get_tree().quit(1)
		return
	_scene = packed.instantiate()
	add_child(_scene)


func _process(_delta: float) -> void:
	_frame += 1
	if _frame < WARM_FRAMES:
		return
	if _frame == WARM_FRAMES:
		_begin()
		return
	if _holster == null:
		return
	match _stage:
		0:
			if _frame >= _stage_end(SETTLE_FRAMES):
				_shoot("hip")
				Input.action_press(&"aim")
				_stage = 1
		1:
			if _frame >= _stage_end(SETTLE_FRAMES + AIM_FRAMES):
				_shoot("ads")
				Input.action_release(&"aim")
				_index += 1
				_stage = 0
				if _index >= _picks.size():
					_finish()
				else:
					_equip()


## Find the holster the baked player ships and load the first weapon.
func _begin() -> void:
	_holster = _scene.get_node_or_null(HOLSTER_PATH)
	if _holster == null:
		printerr("ads_shot: %s has no %s." % [_demo, HOLSTER_PATH])
		get_tree().quit(1)
		return
	if _legacy:
		var pose: GunHandPose = _holster.get(&"hand_pose")
		pose.sight_clearance_units = 0.0
		pose.ads_clear_degrees = 0.0
		pose.ads_drop_limit_degrees = 40.0
	_picks = _pick()
	if _picks.is_empty():
		printerr("ads_shot: the roll produced none of the wanted weapons.")
		get_tree().quit(1)
		return
	_equip()


## Lowest seed that produces each wanted (receiver class, optic state) pair, so the
## same six weapons are photographed on every run.
func _pick() -> Array:
	var found: Dictionary = {}
	for seed_value: int in range(1, SEED_BUDGET + 1):
		if found.size() >= WANTED.size():
			break
		var spec: GunSpec = GunFactory.build(seed_value)
		if spec == null:
			continue
		var receiver: GunPart = PartLibrary.part(spec.receiver_index())
		if receiver == null:
			continue
		var optic: String = "irons"
		if spec.scoped:
			optic = "scope"
		elif spec.has_optic:
			optic = "optic"
		var key: String = "%s_%s" % [receiver.weapon_class, optic]
		if found.has(key):
			continue
		for want: Array in WANTED:
			if key == "%s_%s" % [want[0], want[1]]:
				found[key] = spec
				break
	var out: Array = []
	for want: Array in WANTED:
		var key: String = "%s_%s" % [want[0], want[1]]
		if found.has(key):
			out.append({"id": key, "spec": found[key]})
	return out


func _equip() -> void:
	var spec: GunSpec = _picks[_index]["spec"]
	_holster.call(&"equip", 0, spec)
	(
		_log
		. append(
			(
				"%-16s %-22s %s  %.2f kg  %d mm  zoom %.1f"
				% [
					_picks[_index]["id"],
					spec.weapon_name,
					spec.archetype,
					spec.mass,
					spec.overall_length,
					spec.zoom,
				]
			)
		)
	)


func _stage_end(frames: int) -> int:
	return WARM_FRAMES + 1 + _index * (SETTLE_FRAMES + AIM_FRAMES) + frames


func _shoot(suffix: String) -> void:
	var image: Image = get_viewport().get_texture().get_image()
	var path: String = "%s/%s_%s.png" % [_out, _picks[_index]["id"], suffix]
	if image.save_png(path) != OK:
		printerr("ads_shot: could not write %s" % path)
	else:
		print("ads_shot: %s" % path)


func _finish() -> void:
	print("\n".join(_log))
	get_tree().quit(0)
