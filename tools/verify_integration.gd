extends SceneTree
## Cross-system acceptance test: the seams between the systems, not the systems.
##
##   godot --headless --path <project> --script res://tools/verify_integration.gd
##
## Every other verifier under `res://tools/` proves one system correct on its own.
## This one proves the joins, which is where parallel agents actually go wrong: a
## service nothing can find, a `Transform3D` handed to something that wanted a
## `Node3D`, a damage method nobody implements. None of those cost anything at parse
## time and all of them cost everything at play time, so they are checked for real —
## scenes loaded, a gun rolled, a round fired, a creature's health read afterwards.
##
## NOTHING HERE NAMES A PROJECT CLASS. A `--script` main loop is compiled before the
## SceneTree has resolved its autoloads, so any class that names `GameSettings`,
## `Factions`, `GunFactory`, `PartLibrary`, `SceneRouter` or `DebugHUD` — and most
## of the project legitimately does — fails to compile if it is pulled into this
## file's static dependencies, and every node carrying it silently arrives with no
## script at all. Everything below therefore loads scripts by path at runtime,
## identifies nodes by `get_script().resource_path`, and calls through `call()`.
## Any headless tool that instances a baked scene owes the demo phase the same care.
##
## Exit code 0 only when every check passes.

## Everything that ships. `res://tools/` is excluded on purpose: a builder is
## allowed to name whatever it likes because it never ends up in a scene.
const SCRIPT_ROOTS: PackedStringArray = ["res://core", "res://art", "res://systems", "res://ui"]

const WORLD_SCENE: String = "res://art/scav_world.tscn"
const VFX_SCENE: String = "res://data/vfx/vfx.tscn"
const PLAYER_SCENE: String = "res://data/player/player.tscn"
## Big enough that a spread cone cannot miss it at point-blank.
const TARGET_SPECIES: String = "res://data/enemies/foreman.res"

const WEAPON_SCRIPT: String = "res://systems/guns/weapon.gd"
const BRIDGE_SCRIPT: String = "res://systems/guns/firing/gun_vfx_bridge.gd"
const VFX_SCRIPT: String = "res://systems/vfx/vfx_service.gd"
## The group `GunVfxBridge` searches for a scene-local VFX hub. Duplicated from
## both sides on purpose: if either renames it, this check fails and says so.
const VFX_GROUP: StringName = &"vfx_service"

## Which script every scripted node of the baked player must be carrying.
const PLAYER_PARTS: Dictionary = {
	".": "res://systems/player/player_controller.gd",
	"Eye": "res://systems/player/player_camera.gd",
	"Eye/Holster": "res://systems/player/weapon_holster.gd",
	"Effects": "res://systems/player/player_view_effects.gd",
	"Viewmodel": "res://systems/player/viewmodel/viewmodel_pass.gd",
	"Freecam": "res://systems/player/freecam_controller.gd",
}

## Metres between the muzzle and the creature. Inside every weapon's hitscan
## window, so the shot resolves as a ray rather than going ballistic.
const SHOT_RANGE: float = 2.5
## Health the target is given, well above any single round's damage.
const TARGET_HEALTH: float = 4000.0
## Trigger time. Long enough for the slowest cyclic rate to let one round out.
const TRIGGER_SECONDS: float = 1.5
const TRIGGER_STEP: float = 0.05

var _checks: int = 0
var _fails: int = 0
## Counted in a member rather than a captured local: a lambda closes over a copy of
## a local, so the increment would land somewhere nobody can read.
var _shots: int = 0


func _initialize() -> void:
	# Autoloads are parented before `_initialize` but their `_ready` is deferred to
	# the first frame, so nothing may be asked anything before this.
	await process_frame
	_compiles()
	_autoloads()
	await _scenes()
	await _vfx_seam()
	await _shot_lands()
	print("\nchecks %d   failures %d   %s" % [_checks, _fails, "PASS" if _fails == 0 else "FAIL"])
	quit(0 if _fails == 0 else 1)


# --- every script, once -------------------------------------------------------


## Load every shipping script and make sure no two claim the same `class_name`.
##
## `gdparse` proves a file is syntactically legal one file at a time and knows
## nothing about the rest of the project; a global name claimed twice only fails
## when both files are in memory at once. When it happens the loser does not load
## at all, every scene referencing it bakes and instances without its script, and
## nothing says so louder than one line buried in a build log. It is the single
## most likely way parallel authorship breaks a project, so it is checked first.
func _compiles() -> void:
	_say("-- scripts --")
	var files: Array[String] = []
	for dir_path: String in SCRIPT_ROOTS:
		_walk(dir_path, files)
	files.sort()
	var owners: Dictionary = {}
	var unloadable: PackedStringArray = PackedStringArray()
	var collisions: PackedStringArray = PackedStringArray()
	for path: String in files:
		var script := load(path) as GDScript
		if script == null:
			unloadable.push_back(path)
			continue
		var global_name: String = script.get_global_name()
		if global_name == "":
			continue
		if owners.has(global_name):
			collisions.push_back("%s: %s and %s" % [global_name, owners[global_name], path])
			continue
		owners[global_name] = path
	_ok(
		unloadable.is_empty(),
		"all %d scripts load (%s)" % [files.size(), ", ".join(unloadable) if unloadable else "none"]
	)
	_ok(
		collisions.is_empty(),
		(
			"%d class names, none claimed twice (%s)"
			% [owners.size(), ", ".join(collisions) if collisions else "none"]
		)
	)


func _walk(dir_path: String, out: Array[String]) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry: String = dir.get_next()
	while entry != "":
		if dir.current_is_dir():
			if not entry.begins_with("."):
				_walk(dir_path + "/" + entry, out)
		elif entry.ends_with(".gd"):
			out.push_back(dir_path + "/" + entry)
		entry = dir.get_next()
	dir.list_dir_end()


# --- the autoload floor -------------------------------------------------------


func _autoloads() -> void:
	_say("-- autoloads --")
	var settings: Node = _autoload("GameSettings")
	var factions: Node = _autoload("Factions")
	var parts: Node = _autoload("PartLibrary")
	var factory: Node = _autoload("GunFactory")
	var router: Node = _autoload("SceneRouter")
	var hud: Node = _autoload("DebugHUD")
	if settings == null or factions == null or parts == null:
		return
	if factory == null or router == null or hud == null:
		return
	_ok(
		(settings.get(&"quality_preset") as String) != "", "GameSettings answers with a live preset"
	)
	_ok(int(factions.call("stance", 0, 1)) >= 0, "Factions answers a stance query")
	_ok(int(parts.call("count")) > 0, "PartLibrary reports %d parts" % int(parts.call("count")))
	_ok(bool(factory.call("is_ready")), "GunFactory reports the part library is ready")
	_ok(not bool(router.call("is_paused")), "SceneRouter starts unpaused")
	_ok(hud.call("drawer") != null, "DebugHUD built its debug drawer")


# --- the scenes every demo instances -----------------------------------------


func _scenes() -> void:
	_say("")
	_say("-- shared scenes --")
	var world: Node = _instance(WORLD_SCENE)
	if world != null:
		_ok(world.has_method("sun") and world.call("sun") != null, "scav_world resolved its sun")

	var player: Node = _instance(PLAYER_SCENE)
	if player == null:
		return
	await process_frame
	for path: String in PLAYER_PARTS:
		var node: Node = player if path == "." else player.get_node_or_null(NodePath(path))
		_ok(
			_script_of(node) == String(PLAYER_PARTS[path]),
			"player.tscn '%s' carries %s" % [path, String(PLAYER_PARTS[path]).get_file()]
		)
	player.queue_free()
	await process_frame


# --- the VFX seam -------------------------------------------------------------


## `GunVfxBridge` is late-bound by design, which means a mismatch between it and
## `VfxService` is invisible until a round is fired in front of a player. Both
## halves are checked: that the hub can be found at all, and that every entry point
## the bridge offers is one the service will actually accept.
func _vfx_seam() -> void:
	_say("")
	_say("-- guns/vfx seam --")
	var hub: Node = _instance(VFX_SCENE)
	if hub == null:
		return
	await process_frame
	_ok(_script_of(hub) == VFX_SCRIPT, "vfx.tscn root carries VfxService")
	_ok(hub.is_in_group(VFX_GROUP), "the hub joined the '%s' group the bridge searches" % VFX_GROUP)

	var bridge_script := load(BRIDGE_SCRIPT) as GDScript
	if bridge_script == null:
		_ok(false, "GunVfxBridge did not load")
		return
	var bridge: RefCounted = bridge_script.new()
	_ok(bool(bridge.call("bind", self)), "GunVfxBridge bound to the hub")

	# Service entry point -> the argument types the bridge sends it, in order.
	var expected: Dictionary = {
		&"spawn_tracer": [TYPE_VECTOR3, TYPE_VECTOR3, TYPE_FLOAT],
		&"spawn_impact": [TYPE_VECTOR3, TYPE_VECTOR3, TYPE_INT, TYPE_FLOAT],
		&"spawn_decal": [TYPE_VECTOR3, TYPE_VECTOR3, TYPE_FLOAT],
		&"spawn_muzzle_flash": [TYPE_OBJECT, TYPE_FLOAT],
		&"spawn_explosion": [TYPE_VECTOR3, TYPE_FLOAT],
	}
	for method: StringName in expected:
		_check_signature(hub, method, expected[method] as Array)

	var min_flash: float = float(bridge_script.get(&"FLASH_MIN"))
	var max_flash: float = float(bridge_script.get(&"FLASH_MAX"))
	var shot_gain: float = float(bridge_script.get(&"FLASH_SHOT_GAIN"))
	_ok(
		is_equal_approx(float(bridge_script.call("flash_scale", 0.0, 1)), min_flash),
		"a zero-energy round gets the reference's minimum flash"
	)
	_ok(
		is_equal_approx(float(bridge_script.call("flash_scale", 1.0e9, 2)), max_flash * shot_gain),
		"a shot load's flash is capped at 1.35x the reference maximum"
	)
	hub.queue_free()
	await process_frame


## One service entry point against the arguments the bridge sends it. A declared
## parameter of `TYPE_NIL` is an untyped `Variant` and accepts anything.
func _check_signature(service: Object, method: StringName, sends: Array) -> void:
	if not service.has_method(method):
		_ok(false, "VfxService is missing %s" % method)
		return
	var args: Array = []
	for entry: Dictionary in service.get_method_list():
		if StringName(entry.get("name", "")) == method:
			args = entry.get("args", []) as Array
			break
	if args.size() < sends.size():
		_ok(
			false,
			"%s takes %d arguments, the bridge sends %d" % [method, args.size(), sends.size()]
		)
		return
	for i: int in sends.size():
		var want: int = int((args[i] as Dictionary).get("type", TYPE_NIL))
		if want == TYPE_NIL or want == int(sends[i]):
			continue
		_ok(
			false,
			(
				"%s argument %d is %s, the bridge sends %s"
				% [method, i + 1, type_string(want), type_string(int(sends[i]))]
			)
		)
		return
	_ok(true, "%s accepts what the bridge sends it" % method)


# --- the shot -----------------------------------------------------------------


## The whole chain in one go: `GunFactory` rolls a weapon, `Weapon` fires it,
## `GunHitscan` traces it, `GunDamage` routes it and `EnemyActor` takes it. Break
## any link and the creature's health does not move.
func _shot_lands() -> void:
	_say("")
	_say("-- guns/enemies seam --")
	var factory: Node = root.get_node_or_null(^"GunFactory")
	var scene := load(TARGET_SPECIES) as PackedScene
	var weapon_script := load(WEAPON_SCRIPT) as GDScript
	if factory == null or scene == null or weapon_script == null:
		_ok(false, "the shot test needs GunFactory, the Weapon script and %s" % TARGET_SPECIES)
		return

	var target := scene.instantiate() as CharacterBody3D
	if target == null:
		_ok(false, "%s does not instantiate as a body" % TARGET_SPECIES)
		return
	root.add_child(target)
	await physics_frame
	_ok(
		target.has_method(&"apply_bullet_damage"),
		"EnemyActor implements the receiver GunDamage looks for"
	)
	target.set(&"max_health", TARGET_HEALTH)
	target.set(&"health", TARGET_HEALTH)

	var chest: Vector3 = target.global_position + Vector3(0.0, 1.2, 0.0)
	var aim := Node3D.new()
	root.add_child(aim)
	aim.global_position = chest + Vector3(0.0, 0.0, SHOT_RANGE)
	aim.look_at(chest, Vector3.UP)

	var spec: Resource = factory.call("roll", 20260728, "Rifle")
	_ok(spec != null, "GunFactory rolled a rifle for the shot test")
	if spec == null:
		return
	var weapon: Node3D = weapon_script.new()
	weapon.set(&"self_driven", false)
	root.add_child(weapon)
	weapon.call("setup", spec)
	weapon.call("set_rig", aim, aim, null)
	weapon.call("set_aim_blend", 1.0)
	_shots = 0
	(weapon.get(&"fired") as Signal).connect(_on_test_shot)
	# One physics step so the creature's collider is in the space the ray queries.
	await physics_frame

	weapon.call("trigger_down")
	var elapsed: float = 0.0
	while elapsed < TRIGGER_SECONDS and float(target.get(&"health")) >= TARGET_HEALTH:
		weapon.call("tick", TRIGGER_STEP)
		elapsed += TRIGGER_STEP
		await physics_frame
	weapon.call("trigger_up")

	var left: float = float(target.get(&"health"))
	_ok(_shots > 0, "the weapon put %d round(s) downrange" % _shots)
	_ok(
		left < TARGET_HEALTH,
		"the creature took %.1f damage through the full chain" % (TARGET_HEALTH - left)
	)
	weapon.queue_free()
	aim.queue_free()
	target.queue_free()
	await process_frame


# --- plumbing -----------------------------------------------------------------


func _on_test_shot(_origin: Vector3, _dir: Vector3, _spec: Resource) -> void:
	_shots += 1


## Autoloads are children of `root`, and the path must stay relative: an absolute
## one is illegal until this tree is the active one.
func _autoload(autoload_name: String) -> Node:
	var found: Node = root.get_node_or_null(NodePath(autoload_name))
	_ok(found != null, "%s autoload is registered" % autoload_name)
	return found


## Which script a node is carrying, by path. Empty when it has none — which is what
## a scene whose scripts failed to compile looks like, and the failure this whole
## file is written to make visible.
func _script_of(node: Node) -> String:
	if node == null:
		return ""
	var script := node.get_script() as Script
	return "" if script == null else script.resource_path


func _instance(path: String) -> Node:
	var packed := load(path) as PackedScene
	if packed == null:
		_ok(false, "%s did not load as a PackedScene" % path)
		return null
	var node: Node = packed.instantiate()
	if node == null:
		_ok(false, "%s did not instantiate" % path)
		return null
	root.add_child(node)
	_ok(true, "%s instanced" % path)
	return node


func _ok(passed: bool, message: String) -> void:
	_checks += 1
	if passed:
		print("  ok    ", message)
		return
	_fails += 1
	print("  FAIL  ", message)


func _say(text: String) -> void:
	print(text)
