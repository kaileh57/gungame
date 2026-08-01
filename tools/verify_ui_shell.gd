extends SceneTree
## Headless acceptance test for the menu shell: the pause menu, the baked control
## sounds, every diegetic control scene and the main menu itself. Loads them for
## real, drives them, and reports counts rather than opinions.
##
##   godot --headless --path <project> --script res://tools/verify_ui_shell.gd
##
## Exit code 0 only when every check passes.
##
## Autoloads and the UI classes that name them are reached through `root` and
## `call` rather than by identifier: a `--script` main loop is compiled before the
## SceneTree has its autoloads, so naming `DebugHUD` or `MainMenu` as a type here
## fails the whole file at load.

const MENU: String = "res://ui/main_menu.tscn"
## Every baked control that actuates. The readout is display-only and has no hit.
const CONTROL_SCENES: PackedStringArray = [
	"res://ui/diegetic/diegetic_button.tscn",
	"res://ui/diegetic/diegetic_lever.tscn",
	"res://ui/diegetic/diegetic_dial.tscn",
	"res://ui/diegetic/diegetic_slider.tscn",
]

var _fails: int = 0
var _checks: int = 0
var _settings: Node = null
var _router: Node = null
var _hud: Node = null


func _initialize() -> void:
	_settings = root.get_node_or_null(^"GameSettings")
	_router = root.get_node_or_null(^"SceneRouter")
	_hud = root.get_node_or_null(^"DebugHUD")
	_ok(_settings != null and _router != null and _hud != null, "every UI autoload is live")
	# Autoloads are parented before `_initialize`, but their `_ready` is deferred to
	# the first frame — DebugHUD has not mounted the pause menu yet.
	await process_frame
	_check_pause()
	await _check_sounds()
	await _check_menu()
	print("\nchecks %d   failures %d   %s" % [_checks, _fails, "PASS" if _fails == 0 else "FAIL"])
	quit(0 if _fails == 0 else 1)


func _check_pause() -> void:
	var menu: Node = _hud.call("pause_menu") as Node
	_ok(menu != null, "DebugHUD mounted the pause menu")
	if menu == null:
		return
	for path: String in [
		"Scrim",
		"Root/Frame",
		"Root/Frame/Body/Subtitle",
		"Root/Frame/Body/Resume",
		"Root/Frame/Body/SettingsButton",
		"Root/Frame/Body/MainMenuButton",
		"SettingsHost",
		"SettingsHost/SettingsPanel",
	]:
		_ok(menu.get_node_or_null(NodePath(path)) != null, "pause menu has %s" % path)

	var panel: Node = menu.get_node_or_null(^"SettingsHost/SettingsPanel")
	if panel == null:
		return
	var expected: int = (
		(load("res://ui/settings_panel.gd") as GDScript).get_script_constant_map()["ROWS"].size()
	)
	var rows: Node = panel.get_node(^"Frame/Body/Scroll/Rows")
	_ok(
		rows.get_child_count() == expected,
		"settings rows built: %d of %d" % [rows.get_child_count(), expected]
	)
	_ok((panel as Control).theme != null, "settings page carries the baked theme")

	# The router is the only writer of the pause state; the menu only listens.
	_ok(not (menu as CanvasLayer).visible, "the pause menu starts hidden")
	_router.call("set_paused", true)
	_ok((menu as CanvasLayer).visible, "pause_changed(true) showed the pause menu")
	var resume := menu.get_node(^"Root/Frame/Body/Resume") as Button
	resume.emit_signal(&"pressed")
	_ok(not bool(_router.call("is_paused")), "the resume button unpaused through the router")

	var before: float = float(_settings.get("fov"))
	_settings.call("set_value", &"fov", 91.0)
	_ok(is_equal_approx(float(_settings.get("fov")), 91.0), "the store accepted a new fov")
	panel.call("sync_all")
	_settings.call("set_value", &"fov", before)


## The controls are meant to click, and a control that only flashes reads as
## broken rather than as quiet. This loads the baked pair, then actuates one of
## every control scene and confirms the stream reached its player.
func _check_sounds() -> void:
	var click: AudioStream = UiStyle.click_sound()
	var deny: AudioStream = UiStyle.deny_sound()
	_ok(click != null, "the baked control click loads (%s)" % UiStyle.CLICK_SOUND_PATH)
	_ok(deny != null, "the baked control knock loads (%s)" % UiStyle.DENY_SOUND_PATH)
	for stream: AudioStream in [click, deny]:
		var wav := stream as AudioStreamWAV
		if wav == null:
			continue
		_ok(
			wav.data.size() > 0, "%s carries %d bytes of pcm" % [wav.resource_path, wav.data.size()]
		)
		_ok(wav.get_length() > 0.05, "%s is %.3f s long" % [wav.resource_path, wav.get_length()])

	for path: String in CONTROL_SCENES:
		var packed: PackedScene = ResourceLoader.load(path, "PackedScene") as PackedScene
		_ok(packed != null, "%s loads" % path)
		if packed == null:
			continue
		var control := packed.instantiate() as DiegeticControl
		_ok(control != null, "%s is a DiegeticControl" % path.get_file())
		if control == null:
			continue
		root.add_child(control)
		await process_frame
		var player := control.get_node_or_null(^"Sound") as AudioStreamPlayer3D
		_ok(player != null, "%s carries a Sound player" % path.get_file())
		_ok(control.sound != null, "%s resolved a default click" % path.get_file())
		_ok(control.deny_sound != null, "%s resolved a default knock" % path.get_file())
		if player != null:
			_ok(control.interact(), "%s actuates" % path.get_file())
			_ok(player.stream == click, "%s played the click" % path.get_file())
			control.enabled = false
			control.interact()
			_ok(player.stream == deny, "%s played the knock when refusing" % path.get_file())
		control.queue_free()


func _check_menu() -> void:
	var packed: PackedScene = ResourceLoader.load(MENU, "PackedScene") as PackedScene
	_ok(packed != null, "%s loads" % MENU)
	if packed == null:
		return
	var menu := packed.instantiate() as Node3D
	_ok(menu != null and menu.get_script() != null, "the main menu root carries its script")
	if menu == null:
		return
	root.add_child(menu)
	await process_frame
	await process_frame

	var eye := menu.get_node_or_null(^"Eye") as Camera3D
	_ok(eye != null and eye.current, "the camera is current")
	_ok(
		is_equal_approx(eye.fov, float(_settings.get("fov"))),
		"camera fov tracks GameSettings (%.0f)" % eye.fov
	)
	_ok(menu.get_node_or_null(^"ScavWorld") != null, "scav_world is instanced")
	_ok(menu.get_node_or_null(^"Bench/Board") != null, "the blurb board exists")
	_ok(menu.get_node_or_null(^"Lamp/Bulb/Light") != null, "the work lamp exists")

	var cards := menu.get_node(^"Cards") as Node3D
	print(
		(
			"  menu geometry: %d mesh instances, %d triangles, %d nodes"
			% [_meshes(menu), _triangles(menu), _nodes(menu)]
		)
	)

	var seen := PackedStringArray()
	for node: Node in cards.get_children():
		var control := node as DiegeticControl
		_ok(control != null, "%s is a DiegeticControl" % node.name)
		if control == null:
			continue
		seen.append(String(control.control_id))
		_ok(control.collision_layer == GameLayers.PROP, "%s is on the PROP layer" % node.name)
		for child: String in ["Plate", "Label", "Tag", "Shape"]:
			_ok(
				control.get_node_or_null(NodePath(child)) != null,
				"%s has a %s" % [node.name, child]
			)

	for id: String in _router.call("demo_ids") as PackedStringArray:
		_ok(seen.has(id), "demo '%s' has a plate" % id)
		var info: Dictionary = _router.call("demo_info", id)
		_ok(not info.is_empty(), "demo '%s' resolves through SceneRouter" % id)
		if info.is_empty():
			continue
		var built: bool = ResourceLoader.exists(String(info["scene"]))
		print("  route %-10s -> %-44s %s" % [id, info["scene"], "built" if built else "NOT BUILT"])

	var settings_plate: DiegeticControl = null
	for node: Node in cards.get_children():
		var control := node as DiegeticControl
		if control != null and control.control_id == &"settings":
			settings_plate = control
	_ok(settings_plate != null, "a settings plate exists")
	_ok(seen.has("quit"), "a quit plate exists")

	var panel := menu.get_node(^"Ui/SettingsPanel") as Control
	_ok(not panel.visible, "the settings page starts closed")
	if settings_plate != null:
		_ok(settings_plate.interact(), "the settings plate actuates")
		_ok(panel.visible, "actuating it opened the settings page")
		panel.call("close")
		await process_frame
		_ok(not panel.visible, "closing it closed the settings page")

	# The plates must be reachable by the same ray the menu casts every frame.
	var space: PhysicsDirectSpaceState3D = menu.get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.new()
	query.collision_mask = GameLayers.PROP
	var reached: int = 0
	for node: Node in cards.get_children():
		var control := node as DiegeticControl
		if control == null:
			continue
		query.from = eye.global_position
		query.to = (control.get_node(^"Plate") as Node3D).global_position
		var hit: Dictionary = space.intersect_ray(query)
		if not hit.is_empty() and hit["collider"] == control:
			reached += 1
	_ok(
		reached == cards.get_child_count(),
		"every plate is hit by a ray from the eye (%d of %d)" % [reached, cards.get_child_count()]
	)

	menu.queue_free()


func _ok(condition: bool, label: String) -> void:
	_checks += 1
	if condition:
		print("  ok   %s" % label)
		return
	_fails += 1
	print("  FAIL %s" % label)


func _triangles(node: Node) -> int:
	var total: int = 0
	var mi := node as MeshInstance3D
	if mi != null and mi.mesh != null:
		for s: int in mi.mesh.get_surface_count():
			total += mi.mesh.surface_get_array_len(s) / 3
	for child: Node in node.get_children():
		total += _triangles(child)
	return total


func _meshes(node: Node) -> int:
	var total: int = 1 if node is MeshInstance3D else 0
	for child: Node in node.get_children():
		total += _meshes(child)
	return total


func _nodes(node: Node) -> int:
	var total: int = 1
	for child: Node in node.get_children():
		total += _nodes(child)
	return total
