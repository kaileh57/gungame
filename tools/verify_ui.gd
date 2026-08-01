@tool
extends SceneTree
## Acceptance test for the UI bake. Everything here is checked by running it, not
## by reading it.
##
##   godot --headless --path <project> --script res://tools/verify_ui.gd
##
## Three things are proven:
##   1. every artifact `res://tools/build_ui_assets.gd` writes loads back,
##   2. every diegetic control actuates when it is *shot* — a real ray cast
##      against its real collision layer, then the hit path it would take — and
##      when it is interacted with, and emits the frozen signals. Both debounces
##      are zeroed for these: `cooldown` gates gunfire and `press_cooldown` gates a
##      deliberate press, and a test that rattles a control as fast as a loop can
##      is neither of those,
##   3. the control solids overlap: every mesh in a control touches another one,
##      so there is no floating part and no air gap at a joint.
## Exit code 0 means all of it passed.

const BUTTON_SCENE := "res://ui/diegetic/diegetic_button.tscn"
const LEVER_SCENE := "res://ui/diegetic/diegetic_lever.tscn"
const DIAL_SCENE := "res://ui/diegetic/diegetic_dial.tscn"
const SLIDER_SCENE := "res://ui/diegetic/diegetic_slider.tscn"
const READOUT_SCENE := "res://ui/diegetic/diegetic_readout.tscn"
const COMBAT_HUD_SCENE := "res://ui/hud/combat_hud.tscn"

const ASSETS: PackedStringArray = [
	"res://data/ui/font_mono.tres",
	"res://data/ui/font_display.tres",
	"res://data/ui/ui_theme.tres",
	"res://data/ui/debug_lines.tres",
	"res://data/ui/readout_grime.res",
	"res://data/ui/lamp_off.tres",
	"res://data/ui/lamp_on.tres",
]

## The muzzle a test shot is fired from: 1.5 m out along +Z, which is the face
## normal of every panel control.
const SHOT_ORIGIN := Vector3(0.0, 0.0, 1.5)

## Mirrors `DebugHUD.CHANNEL_COLLISION`. Spelled out rather than preloaded: the
## main-loop script is compiled before the autoloads are wired up, and preloading
## an autoload's own script from here loads a second copy and leaves the real node
## script-less.
const CHANNEL_COLLISION: StringName = &"collision shapes"

var _pass := 0
var _fail := 0


func _initialize() -> void:
	_run()


func _run() -> void:
	await process_frame
	_check_assets()
	await _check_button()
	await _check_lever()
	await _check_dial()
	await _check_slider()
	await _check_readout()
	await _check_combat_hud()
	await _check_debug_hud()
	print("\nverify_ui: %d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


# --- assets -----------------------------------------------------------------


func _check_assets() -> void:
	print("-- assets")
	for path: String in ASSETS:
		var res: Resource = ResourceLoader.load(path)
		_ok(res != null, "%s loads" % path.get_file())
	var grime := ResourceLoader.load("res://data/ui/readout_grime.res") as Texture2D
	_ok(grime != null and grime.get_width() == 256, "grime is 256 px wide")
	var img: Image = grime.get_image() if grime != null else null
	# The shader samples it with filter_linear_mipmap; without the chain it aliases
	# into a moire the moment the panel is more than a couple of metres away.
	_ok(img != null and img.has_mipmaps(), "grime carries mipmaps")
	if img != null:
		# A tileable field that is flat is a bug that only shows up on the panel.
		var low := 1.0
		var high := 0.0
		for y: int in range(0, img.get_height(), 8):
			for x: int in range(0, img.get_width(), 8):
				var v: float = img.get_pixel(x, y).r
				low = minf(low, v)
				high = maxf(high, v)
		_ok(high - low > 0.35, "grime has range (%.3f..%.3f)" % [low, high])
		# Wrapping: the last column must continue into the first, not jump.
		var seam := 0.0
		for y: int in img.get_height():
			seam = maxf(seam, absf(img.get_pixel(img.get_width() - 1, y).r - img.get_pixel(0, y).r))
		_ok(seam < 0.10, "grime wraps horizontally (max seam step %.3f)" % seam)
	_ok(UiStyle.mono_font() != null, "UiStyle.mono_font resolves")
	_ok(UiStyle.ui_theme() != null, "UiStyle.ui_theme resolves")


# --- controls ---------------------------------------------------------------


func _check_button() -> void:
	print("-- diegetic button")
	var node := await _spawn(BUTTON_SCENE) as DiegeticButton
	if node == null:
		return
	_check_geometry(node, "button")
	var hit: Vector3 = _shoot_ray(node, "button")

	var presses: Array[int] = [0]
	node.pressed.connect(func() -> void: presses[0] += 1)

	_ok(node.shoot(hit, 1.0), "shoot actuates")
	_ok(presses[0] == 1, "pressed fired once (%d)" % presses[0])
	# A shotgun lands nine pellets in the same millisecond; the cooldown is what
	# stops that being nine button presses.
	_ok(not node.shoot(hit, 1.0), "second shot inside cooldown is swallowed")
	_ok(presses[0] == 1, "still one press after the burst (%d)" % presses[0])

	node.cooldown = 0.0
	node.press_cooldown = 0.0
	_ok(node.interact(), "interact actuates")
	_ok(presses[0] == 2, "interact raised the count (%d)" % presses[0])

	node.min_power = 0.5
	_ok(not node.shoot(hit, 0.2), "a weak hit is refused")
	node.min_power = 0.0
	node.enabled = false
	_ok(not node.shoot(hit, 1.0), "a disabled control is refused")
	node.enabled = true

	node.latching = true
	var values: Array[float] = [-1.0]
	node.value_changed.connect(func(v: float) -> void: values[0] = v)
	node.shoot(hit, 1.0)
	_ok(is_equal_approx(node.value(), 1.0), "latching button latches (%.1f)" % node.value())
	_ok(is_equal_approx(values[0], 1.0), "value_changed carried 1.0")
	node.shoot(hit, 1.0)
	_ok(is_equal_approx(node.value(), 0.0), "latching button releases (%.1f)" % node.value())
	_ok(node.get_node(^"Cap") != null, "cap node present")
	node.set_label("ARMED")
	_ok((node.get_node(^"Label") as Label3D).text == "ARMED", "set_label writes the Label3D")
	node.queue_free()


func _check_lever() -> void:
	print("-- diegetic lever")
	var node := await _spawn(LEVER_SCENE) as DiegeticLever
	if node == null:
		return
	_check_geometry(node, "lever")
	var hit: Vector3 = _shoot_ray(node, "lever")
	node.cooldown = 0.0
	node.press_cooldown = 0.0

	var states: Array[bool] = [false]
	var toggles: Array[int] = [0]
	node.toggled.connect(
		func(on: bool) -> void:
			states[0] = on
			toggles[0] += 1
	)
	_ok(node.shoot(hit, 1.0), "shoot throws the lever")
	_ok(toggles[0] == 1 and states[0], "toggled(true) fired (%d)" % toggles[0])
	_ok(node.is_on(), "is_on reads true")
	_ok(node.interact(), "interact throws it back")
	_ok(toggles[0] == 2 and not states[0], "toggled(false) fired (%d)" % toggles[0])
	node.set_on(true)
	_ok(node.is_on() and toggles[0] == 3, "set_on(true) throws and notifies")
	node.set_on(false, false)
	_ok(not node.is_on() and toggles[0] == 3, "set_on(false, notify=false) stays quiet")
	_ok((node.get_node(^"State") as Label3D).text == node.off_text, "state label follows")
	node.queue_free()


func _check_dial() -> void:
	print("-- diegetic dial")
	var node := await _spawn(DIAL_SCENE) as DiegeticDial
	if node == null:
		return
	_check_geometry(node, "dial")
	node.cooldown = 0.0
	node.press_cooldown = 0.0
	_ok(node.steps() == 4, "dial baked with 4 detents (%d)" % node.steps())

	var picks: Array[int] = [-1]
	node.option_selected.connect(func(i: int, _t: String) -> void: picks[0] = i)
	# Right of centre indexes up, left indexes down — the same thing a hand does.
	_ok(node.shoot(node.to_global(Vector3(0.03, 0.0, 0.03)), 1.0), "shooting the right half works")
	_ok(node.selected_index() == 1, "indexed up to 1 (%d)" % node.selected_index())
	_ok(picks[0] == 1, "option_selected carried 1")
	_ok(node.shoot(node.to_global(Vector3(-0.03, 0.0, 0.03)), 1.0), "shooting the left half works")
	_ok(node.selected_index() == 0, "indexed back to 0 (%d)" % node.selected_index())
	node.set_value(0.0, false)
	node.wraps = true
	node.set_value(-1.0)
	_ok(node.selected_index() == 3, "wraps below zero to 3 (%d)" % node.selected_index())
	node.set_steps(6)
	_ok(node.steps() == 6, "set_steps(6) grew the dial (%d)" % node.steps())
	_ok(node.options[0] == "I", "set_steps kept the existing labels (%s)" % node.options[0])
	_ok(node.options[5] == "6", "set_steps numbered the new ones (%s)" % node.options[5])
	node.set_steps(2)
	_ok(node.steps() == 2 and node.selected_index() <= 1, "shrinking clamps the selection")
	node.queue_free()


func _check_slider() -> void:
	print("-- diegetic slider")
	var node := await _spawn(SLIDER_SCENE) as DiegeticSlider
	if node == null:
		return
	_check_geometry(node, "slider")
	node.cooldown = 0.0
	node.press_cooldown = 0.0
	node.set_range(0.0, 400.0)
	node.step = 10.0
	node.set_value(0.0, false)

	var seen: Array[float] = [-1.0]
	node.value_changed.connect(func(v: float) -> void: seen[0] = v)
	# Half the track length out along +X is the far end of the travel.
	var far: Vector3 = node.to_global(Vector3(node.track_length * 0.5, 0.0, 0.03))
	_ok(node.shoot(far, 1.0), "shooting the far end works")
	_ok(is_equal_approx(node.value(), 400.0), "slid to 400 (%.1f)" % node.value())
	_ok(is_equal_approx(seen[0], 400.0), "value_changed carried 400")
	_ok(is_equal_approx(node.fraction(), 1.0), "fraction is 1.0 (%.3f)" % node.fraction())
	var mid: Vector3 = node.to_global(Vector3.ZERO)
	node.shoot(mid, 1.0)
	_ok(is_equal_approx(node.value(), 200.0), "centre of the track is 200 (%.1f)" % node.value())
	node.set_value(0.0, false)
	_ok(node.interact(), "interact steps it")
	_ok(is_equal_approx(node.value(), 10.0), "interact advanced one detent (%.1f)" % node.value())
	node.set_value(100.0, false)
	node.set_range(0.0, 40.0)
	_ok(is_equal_approx(node.max_value, 40.0), "set_range rewrote the maximum")
	_ok(
		is_equal_approx(node.fraction(), 0.25),
		"set_range kept the fraction (%.3f)" % node.fraction()
	)
	_ok(is_equal_approx(node.value(), 10.0), "re-scaled to 10 of 40 (%.1f)" % node.value())
	_ok(
		(node.get_node(^"Readout") as Label3D).text == node.value_format % node.value(),
		"readout label follows the value"
	)
	node.queue_free()


func _check_readout() -> void:
	print("-- diegetic readout")
	var node := await _spawn(READOUT_SCENE) as DiegeticReadout
	if node == null:
		return
	var screen := node.get_node(^"Screen") as MeshInstance3D
	var viewport := node.get_node(^"Screen/Display") as SubViewport
	var canvas := node.get_node(^"Screen/Display/Canvas") as ReadoutCanvas
	_ok(screen != null and viewport != null and canvas != null, "screen, viewport and canvas exist")
	_check_geometry(node, "readout")
	if screen == null or viewport == null:
		node.queue_free()
		return
	var mat := screen.get_active_material(0) as ShaderMaterial
	_ok(mat != null, "screen carries a ShaderMaterial")
	if mat != null:
		_ok(mat.resource_local_to_scene, "material is local to the scene")
		_ok(mat.get_shader_parameter(&"grime_tex") != null, "grime texture is bound")
		_ok(
			mat.get_shader_parameter(&"screen_tex") == viewport.get_texture(),
			"screen_tex points at this instance's render target"
		)
	_ok(viewport.size == Vector2i(512, 320), "render target is 512x320 (%s)" % viewport.size)
	# Aspect must match the quad or the text stretches.
	var quad := screen.mesh as QuadMesh
	var quad_ar: float = quad.size.x / quad.size.y
	var vp_ar: float = float(viewport.size.x) / float(viewport.size.y)
	_ok(
		absf(quad_ar - vp_ar) < 0.01,
		"quad and target agree on aspect (%.3f/%.3f)" % [quad_ar, vp_ar]
	)

	node.set_title("MARK 4 'SCRAPJAW'")
	node.set_lines(PackedStringArray(["9x39mm  ·  semi", "24 rnd box  ·  2.1 s reload"]))
	node.set_bars(
		PackedStringArray(["DAMAGE", "RANGE"]),
		PackedFloat32Array([0.62, 0.31]),
		PackedColorArray([UiStyle.WARN, UiStyle.GOOD])
	)
	_ok(
		viewport.render_target_update_mode == SubViewport.UPDATE_ONCE,
		"content change armed one render"
	)
	# UPDATE_ONCE clears itself only when a frame is actually rasterised, which the
	# headless dummy driver never does — so what is checked here is that the arming
	# is idempotent and that a further change re-arms rather than stacking work.
	viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	node.clear()
	_ok(
		viewport.render_target_update_mode == SubViewport.UPDATE_ONCE,
		"clearing the readout re-arms one render"
	)
	_ok(canvas != null, "canvas survived the clear")
	node.painted = true
	_ok(
		int(mat.get_shader_parameter(&"style")) == 1 if mat != null else false,
		"painted flips the shader style"
	)
	_ok(
		(
			absf(float(mat.get_shader_parameter(&"emission_energy"))) < 0.0001
			if mat != null
			else false
		),
		"a painted placard is not a light source"
	)
	node.queue_free()


func _check_combat_hud() -> void:
	print("-- combat hud")
	var node := await _spawn(COMBAT_HUD_SCENE) as CombatHud
	if node == null:
		return
	var vignette := node.get_node(^"Vignette") as ColorRect
	var mat: ShaderMaterial = vignette.material as ShaderMaterial if vignette != null else null
	_ok(mat != null, "vignette carries the shader")

	var camera := Camera3D.new()
	root.add_child(camera)
	camera.global_position = Vector3.ZERO
	camera.look_at_from_position(Vector3.ZERO, Vector3(0.0, 0.0, -1.0), Vector3.UP)
	node.set_camera(camera)

	node.set_health(1.0)
	node.set_picture(0.004, 0.5, 78.0)
	node.hit_mark(true, true)
	node.pop(Vector3(0.0, 0.0, -6.0), "37", &"crit")
	# Damage from the right must push the lobe to the right; this is the whole
	# point of the directional half of the vignette.
	node.damage_from(Vector3(6.0, 0.0, -1.0))
	var dir: Vector2 = mat.get_shader_parameter(&"hit_direction")
	_ok(dir.x > 0.7, "hit from the right lit the right lobe (%.2f, %.2f)" % [dir.x, dir.y])
	_ok(float(mat.get_shader_parameter(&"pulse")) > 0.9, "pulse is lit")
	node.set_health(0.2)
	await process_frame
	await process_frame
	var harm: float = float(mat.get_shader_parameter(&"harm"))
	_ok(harm > 0.0, "the frame closed in as health fell (harm %.3f)" % harm)
	node.set_health(1.0)
	node.banner("JAM — hold R", 1.6)
	_ok((node.get_node(^"Banner") as Label).visible, "banner shows")
	node.clear_banner()
	_ok(not (node.get_node(^"Banner") as Label).visible, "banner clears")
	var reticle := node.get_node(^"Reticle") as CombatReticle
	_ok(
		reticle != null and is_equal_approx(reticle.spread_radians, 0.004),
		"reticle took the spread"
	)
	camera.queue_free()
	node.queue_free()


func _check_debug_hud() -> void:
	print("-- debug hud")
	# Autoload singletons are not compile-time identifiers inside a script that IS
	# the main loop, so the overlay is reached the way any other node would be.
	var hud: Node = root.get_node_or_null(^"DebugHUD")
	_ok(hud != null, "the DebugHUD autoload is up")
	if hud == null:
		return
	_ok(hud.drawer() != null, "the shared line drawer exists")
	_ok(hud.is_channel_enabled(CHANNEL_COLLISION) == false, "built-in channels start off")

	# Render modes must be the engine's, not a picture of them.
	hud.set_render_debug(1)
	_ok(
		root.debug_draw == Viewport.DEBUG_DRAW_WIREFRAME,
		"F4 mode 1 is real wireframe (%d)" % root.debug_draw
	)
	hud.set_render_debug(2)
	_ok(root.debug_draw == Viewport.DEBUG_DRAW_OVERDRAW, "mode 2 is overdraw")
	hud.set_render_debug(0)
	_ok(root.debug_draw == Viewport.DEBUG_DRAW_DISABLED, "mode 0 is off again")

	var toggles: Array[int] = [0]
	var last: Array[StringName] = [&""]
	hud.channel_toggled.connect(
		func(id: StringName, _on: bool) -> void:
			toggles[0] += 1
			last[0] = id
	)
	hud.add_channel(&"verify_probe", "verify probe", _probe_draw)
	hud.set_channel_enabled(&"verify_probe", true)
	_ok(toggles[0] == 1 and last[0] == &"verify_probe", "channel_toggled fired for the probe")
	_ok(hud.is_channel_enabled(&"verify_probe"), "probe reads as on")

	# A scene with a body in it, so the collision channel has something to find.
	var stage := Node3D.new()
	var body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(2.0, 2.0, 2.0)
	shape.shape = box
	body.add_child(shape)
	stage.add_child(body)
	root.add_child(stage)
	var previous: Node = current_scene
	current_scene = stage
	hud.set_channel_enabled(CHANNEL_COLLISION, true)
	await process_frame
	await process_frame
	# 12 box edges from the shape, plus the 6 the probe draws.
	var verts: int = hud.drawer().vertex_count()
	_ok(verts >= 30, "collision + probe channels emitted %d line vertices" % verts)
	hud.set_channel_enabled(CHANNEL_COLLISION, false)
	hud.set_channel_enabled(&"verify_probe", false)
	await process_frame
	_ok(hud.drawer().vertex_count() == 0, "everything off draws nothing")

	# A channel that is on but has nothing to draw this frame is the common case —
	# an agent with no path yet, a room with no cover. It must not error.
	hud.add_channel(&"verify_silent", "verify silent", _silent_draw)
	hud.set_channel_enabled(&"verify_silent", true)
	await process_frame
	await process_frame
	_ok(hud.drawer().vertex_count() == 0, "a silent channel flushes clean")
	_ok(not hud.drawer().visible, "the drawer hides itself when empty")
	hud.set_channel_enabled(&"verify_silent", false)
	hud.remove_channel(&"verify_silent")
	hud.remove_channel(&"verify_probe")

	hud.note(&"verify", "probe")
	hud.clear_note(&"verify")
	_ok(true, "note and clear_note survive a round trip")
	current_scene = previous
	stage.queue_free()


## The probe channel: a cross is six vertices, which is a number the collision
## count can be checked against.
func _probe_draw(drawer: UiDebugDraw) -> void:
	drawer.cross_mark(Vector3.ZERO, 1.0, UiStyle.ACCENT)


## A channel with nothing to say. Draws a polyline through one point, which is
## what an agent whose path has not solved yet hands over.
func _silent_draw(drawer: UiDebugDraw) -> void:
	drawer.polyline(PackedVector3Array([Vector3.ZERO]), UiStyle.ACCENT)


# --- helpers ----------------------------------------------------------------


func _spawn(path: String) -> Node:
	var packed := ResourceLoader.load(path, "PackedScene") as PackedScene
	if packed == null:
		_ok(false, "%s loads" % path.get_file())
		return null
	var node: Node = packed.instantiate()
	root.add_child(node)
	await process_frame
	return node


## Fire a real ray at the control from in front of it, on the bullet mask, and
## report the impact. Proves the collider is on the layer a bullet can see, which
## no amount of calling `shoot()` by hand would.
func _shoot_ray(node: Node3D, label: String) -> Vector3:
	var space: PhysicsDirectSpaceState3D = node.get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(
		SHOT_ORIGIN, Vector3(0.0, 0.0, -1.5), GameLayers.MASK_BULLET
	)
	var result: Dictionary = space.intersect_ray(query)
	var collider: Object = result.get("collider")
	_ok(collider == node, "%s: a bullet ray hits it" % label)
	_ok(
		collider != null and (collider as Node).is_in_group(DiegeticControl.GROUP),
		"%s: hit object is in the diegetic group" % label
	)
	return result.get("position", node.global_position)


## Every mesh in the control must touch another mesh. A part whose bounding box
## reaches nothing else is either floating or butted with a hairline between it
## and its neighbour, and both look the same from the wrong angle.
func _check_geometry(node: Node3D, label: String) -> void:
	var boxes: Array[AABB] = []
	var names: PackedStringArray = PackedStringArray()
	_collect_boxes(node, node, boxes, names)
	_ok(boxes.size() >= 2, "%s: %d solids" % [label, boxes.size()])
	var orphans: PackedStringArray = PackedStringArray()
	for i: int in boxes.size():
		var touched := false
		for j: int in boxes.size():
			if i != j and boxes[i].intersects(boxes[j]):
				touched = true
				break
		if not touched:
			orphans.append(names[i])
	_ok(
		orphans.is_empty(),
		(
			"%s: every solid overlaps a neighbour%s"
			% [label, "" if orphans.is_empty() else " — loose: " + ", ".join(orphans)]
		)
	)


func _collect_boxes(node: Node, base: Node3D, boxes: Array[AABB], names: PackedStringArray) -> void:
	for child: Node in node.get_children():
		var mesh_node := child as MeshInstance3D
		if mesh_node != null and mesh_node.mesh != null:
			var local: Transform3D = (
				base.global_transform.affine_inverse() * mesh_node.global_transform
			)
			boxes.append(local * mesh_node.mesh.get_aabb())
			names.append(String(mesh_node.name))
		_collect_boxes(child, base, boxes, names)


func _ok(condition: bool, message: String) -> void:
	if condition:
		_pass += 1
		print("   ok    %s" % message)
	else:
		_fail += 1
		print("   FAIL  %s" % message)
