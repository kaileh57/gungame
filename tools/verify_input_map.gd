@tool
extends SceneTree
## THE INPUT MAP, MEASURED AT THE KEY AND NOT AT THE ACTION.
##
##   godot --headless --path <project> --script res://tools/verify_input_map.gd
##   godot --path <project> --resolution 1600x900 --script res://tools/verify_input_map.gd
##
## The second form is windowed and additionally writes PNGs to `SHOT_DIR`, so the
## crouch and the slide can be looked at rather than believed.
##
## WHY THIS EXISTS SEPARATELY FROM `verify_slide_jump.gd`. That harness drives the
## slide with `Input.action_press(&"crouch")`, which moves the polled action state
## directly and never touches a key. It therefore passes identically whether crouch
## is bound to Ctrl, to C, or to nothing that exists on a keyboard — it cannot see a
## binding at all. Every press here goes in as a real `InputEventKey` carrying a
## PHYSICAL keycode through `Input.parse_input_event`, which is the same path a key
## from the OS takes, so what is measured is the binding plus everything downstream
## of it. The control that proves the harness is honest is `KEY_CTRL`: it must NOT
## crouch, and if it ever does, this file is reading the action and lying about it.
##
## WHAT IT CHECKS
##   * the full binding table, printed, with a duplicate scan across every action
##   * every action the project's scripts poll exists and is reachable from the
##     keyboard or mouse without a gamepad
##   * the live `InputMap` still matches `project.godot`, i.e. nothing remapped it
##   * no persisted profile under `user://` can pin an action to a stale key
##   * C crouches, sprint-then-C slides, and a slide-jump out of it beats a run-jump,
##     all on the real movement demo with real key events
##   * Ctrl does nothing, and C actuates NOTHING except crouch

const DEMO_SCENE: String = "res://demos/movement/movement.tscn"
const SHOT_DIR: String = "res://_shots/input_map"
const SETTINGS_SCRIPT: String = "res://core/game_settings.gd"
const HZ: float = 60.0
## Clear west apron of the movement yard, borrowed from `verify_slide_jump.gd`: it is
## the one stretch of the course with forty metres of nothing in front of it.
const APRON: Vector3 = Vector3(-36.5, 0.2, 18.0)
## Physics frames the demo gets to build itself and settle the body.
const WARM_FRAMES: int = 90
const SETTLE_FRAMES: int = 20
## Seconds of held sprint before a case takes its measurement. Long enough that the
## body is at terminal walk/sprint speed rather than still accelerating.
const RUN_UP: float = 2.6
## Seconds between the crouch key going down and the slide being sampled.
const SLIDE_SETTLE: float = 0.18

## Every action name that appears inside an `Input.*` or `InputMap.*` call anywhere
## under the project, plus the three `weapon_N` slots `WeaponHolster` builds at run
## time from its slot count. Kept as a literal so a REMOVED binding fails loudly
## instead of quietly reducing what gets checked.
const REQUIRED_ACTIONS: PackedStringArray = [
	"move_forward",
	"move_back",
	"move_left",
	"move_right",
	"jump",
	"crouch",
	"sprint",
	"fire",
	"aim",
	"reload",
	"interact",
	"weapon_1",
	"weapon_2",
	"weapon_3",
	"weapon_next",
	"weapon_prev",
	"freecam_toggle",
	"pause",
	"debug_toggle",
	"screenshot",
]

## Keys pressed by name in the live cases. Physical codes, because that is what the
## map stores: on a keyboard laid out differently these are still the same buttons.
const K_FORWARD: Key = KEY_W
const K_SPRINT: Key = KEY_SHIFT
const K_CROUCH: Key = KEY_C
const K_JUMP: Key = KEY_SPACE
## The key crouch used to be on. Held for a beat in `_case_ctrl_is_free`, which is
## the control case for the whole file.
const K_OLD_CROUCH: Key = KEY_CTRL

var _failures: int = 0
var _cases: int = 0
var _demo: Node = null
var _player: PlayerController = null
var _down: Array[Key] = []
var _windowed: bool = false
var _shot_index: int = 0
var _fps_samples: PackedFloat32Array = []
## Filled by `_case_slide_from_c` and read by `_case_slide_jump_from_c`.
var _run_jump: float = 0.0
var _slide_jump: float = 0.0


func _initialize() -> void:
	Engine.physics_ticks_per_second = int(HZ)
	Engine.max_fps = 0
	_windowed = DisplayServer.get_name() != "headless"
	if _windowed:
		DirAccess.make_dir_recursive_absolute(SHOT_DIR)
	print("")
	print("=== BINDING TABLE ===")
	_print_table()
	print("")
	print("=== STATIC CHECKS ===")
	_case_actions_exist()
	_case_no_duplicate_bindings()
	_case_crouch_is_c()
	_case_map_matches_project()
	_case_no_persisted_remap()
	print("")
	print("=== LIVE KEY CHECKS (real InputEventKey, physical keycodes) ===")
	await _run_live()
	print("")
	if not _fps_samples.is_empty():
		var total: float = 0.0
		for f: float in _fps_samples:
			total += f
		print(
			(
				"FPS over the live cases: %.1f mean, %.1f min"
				% [total / _fps_samples.size(), _min_fps()]
			)
		)
	if _failures == 0:
		print("PASS - %d/%d cases" % [_cases, _cases])
		quit(0)
	else:
		print("FAIL - %d of %d cases failed" % [_failures, _cases])
		quit(1)


# --- the table -----------------------------------------------------------------------


## Every project action and what it is bound to, keyboard/mouse first. The `ui_*`
## actions Godot installs are left out: nothing in this project reads them and
## listing forty of them buries the twenty that matter.
func _print_table() -> void:
	for action: StringName in _project_actions():
		var keyboard: PackedStringArray = []
		var pad: PackedStringArray = []
		for ev: InputEvent in InputMap.action_get_events(action):
			if ev is InputEventKey or ev is InputEventMouseButton:
				keyboard.append(_describe(ev))
			else:
				pad.append(_describe(ev))
		print(
			(
				"  %-16s %-22s %s"
				% [
					action,
					"/".join(keyboard) if not keyboard.is_empty() else "-",
					"/".join(pad) if not pad.is_empty() else "-",
				]
			)
		)


static func _describe(ev: InputEvent) -> String:
	var key := ev as InputEventKey
	if key != null:
		var code: int = key.physical_keycode if key.physical_keycode != 0 else key.keycode
		var kind: String = "phys" if key.physical_keycode != 0 else "unicode"
		return "%s (%s %d)" % [OS.get_keycode_string(code as Key), kind, code]
	var mouse := ev as InputEventMouseButton
	if mouse != null:
		return "mouse %d" % mouse.button_index
	var button := ev as InputEventJoypadButton
	if button != null:
		return "pad btn %d" % button.button_index
	var motion := ev as InputEventJoypadMotion
	if motion != null:
		return "pad axis %d %s" % [motion.axis, "+" if motion.axis_value > 0.0 else "-"]
	return ev.as_text()


## A signature two actions must not share. Modifiers are deliberately ignored,
## because `Input` matches actions with `exact_match` off: while crouch sat on Ctrl,
## the debug HUD's ctrl+1 channel toggle also ducked the player, and a scan that
## treated "Ctrl" and "Ctrl+1" as different things would have called that clean.
static func _signature(ev: InputEvent) -> String:
	var key := ev as InputEventKey
	if key != null:
		var code: int = key.physical_keycode if key.physical_keycode != 0 else key.keycode
		return "key:%d" % code
	var mouse := ev as InputEventMouseButton
	if mouse != null:
		return "mouse:%d" % mouse.button_index
	var button := ev as InputEventJoypadButton
	if button != null:
		return "pad:%d" % button.button_index
	var motion := ev as InputEventJoypadMotion
	if motion != null:
		return "axis:%d%s" % [motion.axis, "+" if motion.axis_value > 0.0 else "-"]
	return "other:%s" % ev.as_text()


static func _project_actions() -> Array[StringName]:
	var out: Array[StringName] = []
	for action: StringName in InputMap.get_actions():
		if not String(action).begins_with("ui_"):
			out.append(action)
	return out


# --- static cases --------------------------------------------------------------------


func _case_actions_exist() -> void:
	var missing: PackedStringArray = []
	var unreachable: PackedStringArray = []
	for name_text: String in REQUIRED_ACTIONS:
		var action := StringName(name_text)
		if not InputMap.has_action(action):
			missing.append(name_text)
			continue
		var reachable: bool = false
		for ev: InputEvent in InputMap.action_get_events(action):
			reachable = reachable or ev is InputEventKey or ev is InputEventMouseButton
		if not reachable:
			unreachable.append(name_text)
	_report("every polled action exists", missing.is_empty(), "missing %s" % str(missing))
	_report(
		"every polled action is reachable without a gamepad",
		unreachable.is_empty(),
		"gamepad-only %s" % str(unreachable)
	)


func _case_no_duplicate_bindings() -> void:
	var owners: Dictionary = {}
	var clashes: PackedStringArray = []
	for action: StringName in _project_actions():
		for ev: InputEvent in InputMap.action_get_events(action):
			var sig: String = _signature(ev)
			if owners.has(sig):
				clashes.append("%s: %s and %s" % [sig, owners[sig], action])
			else:
				owners[sig] = String(action)
	_report("no two actions share a binding", clashes.is_empty(), "; ".join(clashes))


func _case_crouch_is_c() -> void:
	var codes: PackedInt32Array = []
	var pads: int = 0
	for ev: InputEvent in InputMap.action_get_events(&"crouch"):
		var key := ev as InputEventKey
		if key != null:
			codes.append(key.physical_keycode)
		elif ev is InputEventJoypadButton:
			pads += 1
	_report("crouch is on C", codes.has(int(KEY_C)), "physical codes %s" % str(codes))
	_report(
		"crouch is no longer on Ctrl",
		not codes.has(int(KEY_CTRL)),
		"physical codes %s" % str(codes)
	)
	_report("crouch kept its gamepad binding", pads > 0, "%d pad button(s)" % pads)


## The live map against the file on disk. Anything that called `InputMap.add_action`
## or `action_add_event` at boot would show up here as a difference, which is the
## only way a remap layer could exist without appearing in `project.godot`.
func _case_map_matches_project() -> void:
	var drifted: PackedStringArray = []
	for action: StringName in _project_actions():
		var setting: Variant = ProjectSettings.get_setting("input/%s" % action)
		if typeof(setting) != TYPE_DICTIONARY:
			drifted.append("%s: not in project.godot" % action)
			continue
		var want: PackedStringArray = []
		for ev: InputEvent in (setting as Dictionary).get("events", [] as Array):
			want.append(_signature(ev))
		var have: PackedStringArray = []
		for ev: InputEvent in InputMap.action_get_events(action):
			have.append(_signature(ev))
		if str(want) != str(have):
			drifted.append("%s: file %s, live %s" % [action, str(want), str(have)])
	_report("live InputMap matches project.godot", drifted.is_empty(), "; ".join(drifted))


## Could an existing install still be on Ctrl? Only if something persisted outside
## `project.godot` carries bindings. `GameSettings` is the only thing in the project
## that writes `user://`, so its key set and every config file actually on this
## machine are read and searched for anything binding-shaped.
func _case_no_persisted_remap() -> void:
	var script: GDScript = load(SETTINGS_SCRIPT)
	var defaults: Dictionary = {} if script == null else script.get(&"DEFAULTS")
	var suspect: PackedStringArray = []
	for key: Variant in defaults:
		var text: String = String(key)
		for needle: String in ["bind", "input", "action", "key", "crouch"]:
			if text.contains(needle):
				suspect.append(text)
	_report(
		"the settings store holds no bindings",
		suspect.is_empty(),
		"%d keys, suspicious: %s" % [defaults.size(), str(suspect)]
	)
	var dirty: PackedStringArray = []
	for file_name: String in _user_files():
		if not file_name.ends_with(".cfg"):
			continue
		var cfg := ConfigFile.new()
		if cfg.load("user://%s" % file_name) != OK:
			continue
		for section: String in cfg.get_sections():
			if section == "input":
				dirty.append("%s [input]" % file_name)
			for key_text: String in cfg.get_section_keys(section):
				if key_text.contains("crouch") or key_text.contains("bind"):
					dirty.append("%s %s/%s" % [file_name, section, key_text])
	_report(
		"no persisted profile pins a key",
		dirty.is_empty(),
		"scanned %s; found %s" % [str(_user_files()), str(dirty)]
	)


static func _user_files() -> PackedStringArray:
	var dir: DirAccess = DirAccess.open("user://")
	return PackedStringArray() if dir == null else dir.get_files()


# --- live cases ----------------------------------------------------------------------


func _run_live() -> void:
	if not await _load_demo():
		return
	await _case_c_crouches()
	await _case_slide_from_c()
	await _case_slide_jump_from_c()
	await _case_ctrl_is_free()
	await _case_c_touches_nothing_else()
	_teardown()


func _load_demo() -> bool:
	var packed: PackedScene = load(DEMO_SCENE) as PackedScene
	if packed == null:
		_report("movement demo loads", false, DEMO_SCENE)
		return false
	_demo = packed.instantiate()
	root.add_child(_demo)
	current_scene = _demo
	for _i: int in WARM_FRAMES:
		await physics_frame
	_player = _demo.get_node_or_null(^"Player") as PlayerController
	_report("movement demo has a player", _player != null, DEMO_SCENE)
	return _player != null


## Press C. The action must go down, the body must duck, and the eye must actually
## drop — `crouch_t` alone would pass on a controller that moved a number and left
## the collider and the camera where they were.
func _case_c_crouches() -> void:
	await _park()
	var eye_up: float = _player.view_anchor().y
	await _shot("standing")
	_key(K_CROUCH, true)
	var held: bool = false
	for _i: int in int(HZ * 0.5):
		await physics_frame
		held = held or Input.is_action_pressed(&"crouch")
	var eye_down: float = _player.view_anchor().y
	var ducked: float = _player.crouch_t
	await _shot("crouched")
	_key(K_CROUCH, false)
	for _i: int in int(HZ * 0.6):
		await physics_frame
	var stood: float = _player.crouch_t
	print(
		(
			"      C: crouch_t %.3f down, %.3f back up; eye %.3f -> %.3f m (%.3f m drop)"
			% [ducked, stood, eye_up, eye_down, eye_up - eye_down]
		)
	)
	_report("C presses the crouch action", held, str(held))
	_report("C ducks the body", ducked > 0.9, "crouch_t %.3f" % ducked)
	_report("C drops the eye", eye_up - eye_down > 0.6, "%.3f m" % (eye_up - eye_down))
	_report("releasing C stands back up", stood < 0.05, "crouch_t %.3f" % stood)


## Sprint on real keys, then C. The slide must take, and it must take at a speed
## above the sprint it was entered from, which is the whole point of the entry boost.
func _case_slide_from_c() -> void:
	await _park()
	await _hold([K_FORWARD, K_SPRINT], RUN_UP)
	var sprint_speed: float = _player.speed
	await _shot("sprinting")
	_key(K_CROUCH, true)
	var slid: bool = false
	var peak: float = 0.0
	for _i: int in int(HZ * 0.6):
		await physics_frame
		slid = slid or _player.sliding
		peak = maxf(peak, _player.speed)
	await _shot("sliding")
	_release()
	for _i: int in int(HZ * 0.5):
		await physics_frame
	print(
		(
			"      sprint+C: %.2f m/s sprint -> slide, peak %.2f m/s, slid %s"
			% [sprint_speed, peak, slid]
		)
	)
	_report("sprint then C enters a slide", slid, str(slid))
	_report(
		"the slide is entered boosted",
		peak > sprint_speed + 0.5,
		"%.2f -> %.2f m/s" % [sprint_speed, peak]
	)


## The user's own link: crouch, therefore slide. A slide-jump taken off C has to
## carry further than the run-jump taken off the same run-up, or C is reaching the
## crouch but not the mechanic behind it.
func _case_slide_jump_from_c() -> void:
	await _park()
	await _hold([K_FORWARD, K_SPRINT], RUN_UP)
	_key(K_FORWARD, true)
	_key(K_SPRINT, true)
	_run_jump = await _arc()
	_release()

	await _park()
	await _hold([K_FORWARD, K_SPRINT], RUN_UP)
	_key(K_FORWARD, true)
	_key(K_CROUCH, true)
	for _i: int in int(HZ * SLIDE_SETTLE):
		await physics_frame
	_slide_jump = await _arc()
	_release()
	for _i: int in int(HZ * 0.5):
		await physics_frame
	print("      arcs: run-jump %.3f m, slide-jump off C %.3f m" % [_run_jump, _slide_jump])
	_report(
		"C produces a slide-jump that beats a run-jump",
		_slide_jump > _run_jump * 1.10,
		"%.3f m vs %.3f m (want > %.3f)" % [_slide_jump, _run_jump, _run_jump * 1.10]
	)


## The control. Ctrl is where crouch used to live; if this case ever passes with the
## body ducking, every other case above is reading the action and not the key.
func _case_ctrl_is_free() -> void:
	await _park()
	_key(K_OLD_CROUCH, true)
	var pressed: bool = false
	var ducked: float = 0.0
	for _i: int in int(HZ * 0.5):
		await physics_frame
		pressed = pressed or Input.is_action_pressed(&"crouch")
		ducked = maxf(ducked, _player.crouch_t)
	_key(K_OLD_CROUCH, false)
	for _i: int in int(HZ * 0.2):
		await physics_frame
	print("      Ctrl: crouch action %s, crouch_t peaked at %.3f" % [pressed, ducked])
	_report("Ctrl no longer crouches", not pressed, "action pressed %s" % pressed)
	_report("Ctrl no longer ducks the body", ducked < 0.05, "crouch_t %.3f" % ducked)


## C, held, against every action in the map including Godot's own `ui_*` set. Exactly
## one of them may respond.
func _case_c_touches_nothing_else() -> void:
	await _park()
	_key(K_CROUCH, true)
	for _i: int in 4:
		await physics_frame
	var lit: PackedStringArray = []
	for action: StringName in InputMap.get_actions():
		if Input.is_action_pressed(action):
			lit.append(String(action))
	_key(K_CROUCH, false)
	for _i: int in int(HZ * 0.4):
		await physics_frame
	_report("C actuates crouch and nothing else", str(lit) == str(["crouch"]), "lit %s" % str(lit))


# --- rig ---------------------------------------------------------------------------


## Put the body back on the clear apron with every key up and let it settle.
func _park() -> void:
	_release()
	_player.teleport(APRON, 0.0)
	for _i: int in SETTLE_FRAMES:
		await physics_frame
	_fps_samples.append(Engine.get_frames_per_second())


## A real key-down or key-up on a PHYSICAL keycode, through the same call the OS's
## own events arrive on. `Input.action_press` is deliberately never used in this file.
func _key(code: Key, down: bool) -> void:
	var ev := InputEventKey.new()
	ev.physical_keycode = code
	ev.pressed = down
	Input.parse_input_event(ev)
	if down:
		if not _down.has(code):
			_down.append(code)
	else:
		_down.erase(code)


func _hold(codes: Array[Key], seconds: float) -> void:
	for code: Key in codes:
		_key(code, true)
	for _i: int in int(seconds * HZ):
		await physics_frame
	for code: Key in codes:
		_key(code, false)


func _release() -> void:
	for code: Key in _down.duplicate():
		_key(code, false)


## Press jump on the real key and follow the body until the feet are back down.
## The take-off sample is the LAST grounded tick, matching `verify_slide_jump.gd`,
## so the two harnesses' distances are directly comparable.
func _arc() -> float:
	_key(K_JUMP, true)
	var from: Vector3 = _player.global_position
	var left: bool = false
	var to: Vector3 = from
	for _i: int in int(3.0 * HZ):
		await physics_frame
		_key(K_JUMP, false)
		if not left:
			if _player.grounded:
				from = _player.global_position
				continue
			left = true
			continue
		to = _player.global_position
		if _player.grounded:
			break
	return Vector2(to.x - from.x, to.z - from.z).length()


## A frame of the running demo, saved where it can be opened and looked at. Headless
## has nothing to read back, so it is skipped rather than saving a black rectangle.
func _shot(label: String) -> void:
	if not _windowed:
		return
	await RenderingServer.frame_post_draw
	var image: Image = root.get_texture().get_image()
	if image == null:
		return
	var path: String = "%s/%02d_%s.png" % [SHOT_DIR, _shot_index, label]
	_shot_index += 1
	if image.save_png(path) != OK:
		printerr("verify_input_map: could not write %s" % path)
	else:
		print("      shot -> %s" % path)


func _min_fps() -> float:
	var low: float = 1e9
	for f: float in _fps_samples:
		low = minf(low, f)
	return low


func _teardown() -> void:
	_release()
	if _demo == null:
		return
	root.remove_child(_demo)
	_demo.free()
	_demo = null
	_player = null


func _report(label: String, ok: bool, detail: String) -> void:
	_cases += 1
	if not ok:
		_failures += 1
	print("%s  %-48s %s" % ["ok  " if ok else "FAIL", label, detail])
