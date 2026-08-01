@tool
extends SceneTree
## CLICK REGISTRATION. Counts how many synthesised clicks actually actuate the
## diegetic control they are aimed at.
##
##   godot --headless --path <project> --script res://tools/verify_click_input.gd
##
## The user report this exists to settle is "not all clicks are registered, you
## have to HARD click". Nothing in an `InputEventMouseButton` carries pressure, so
## "hard" can only mean longer, or again — and both of those are measurable.
##
## HOW A CASE RUNS. The demo is loaded as `current_scene`, the player is stood on
## the floor in front of one of its controls and aimed at it, and the aim is proven
## with a ray cast from inside the physics callback before a single click is sent.
## The aim is proven AGAIN after every pass, so a player who slid off the mark can
## never be reported as an input fault. Clicks go in through
## `Input.parse_input_event` — real `InputEvent`s, not `Input.action_press`, which
## moves the polled state without ever raising an event.
##
## FOUR PASSES, because there are four ways to lose a click:
##   `tap`     one press+release per drawn frame, `cooldown` zeroed. Everything
##             missing here was dropped by the input or ray path itself.
##   `hold`    press, hold three frames, release. If `hold` beats `tap`, the rig
##             is polling its trigger instead of reading the event, and the player
##             is right that they have to press harder.
##   `burst`   stock `cooldown`, clicks at `BURST_HZ`. This is a person clicking
##             fast, and it is what the debounce eats.
##   `flick`   aim off the control, then aim on and click in the same frame. This
##             is what a rig that caches its hover in `_process` cannot see.
##
## The frame rate is pinned to `FRAME_CAP` so the ratio of drawn frames to physics
## ticks matches the shipping game, which runs 133-220 fps against a 60 Hz tick.
##
## A FIFTH PASS, and it is the one that answers "you have to click three times".
## Everything above sends ONE tap and then waits as long as the gun needs, so it can
## only find a click the input path lost — it can never find a click the MECHANISM
## ate, because it does not send a second one until the first has been paid. The ADS
## pass in `res://tools/click/ads_trigger_pass.gd` sends a string of taps at the
## weapon's own rated rate, shouldered and at the hip, and counts clicks per round.

const REPORT_PATH: String = "res://tools/click_input_report.txt"
## The ADS trigger pass. See its own header: three numbers per weapon, taken twice.
## Held as a PATH and `load`ed at run time, not `preload`ed. A `--script` harness is
## compiled before the autoloads and the global class cache are up, and preloading a
## file that types `Weapon` drags a third of `systems/` into that early compile — the
## measured symptom is `Could not find type "PlayerHealth"` and a player prefab that
## then instantiates with half its scripts missing. `verify_ads_occlusion.gd` reaches
## its own probe the same way and for the same reason.
const ADS_PASS_SCRIPT: String = "res://tools/click/ads_trigger_pass.gd"

## Clicks sent per pass. Enough that one lost click moves the rate by 2 points.
const CLICKS: int = 50
## Sub-frame trigger taps per gun. Fewer than `CLICKS` because each one has to
## wait out the rolled weapon's rate of fire.
const TRIGGER_TAPS: int = 30
## Clicks per second in the `burst` pass. A fast human double-click is about this.
const BURST_HZ: float = 10.0
## Drawn frames the button is held down for in the `hold` pass.
const HOLD_FRAMES: int = 3
## Repeats of the `flick` pass. Each one costs `FLICK_AWAY` frames looking away.
const FLICKS: int = 30
const FLICK_AWAY: int = 4
## Drawn frames left between passes. Longer than `DiegeticInteractor.press_patience`
## so a press still held from one pass can never be counted in the next.
const PASS_GAP: int = 90
## Frames the demo gets to build itself before anything is asked of it.
const WARMUP_FRAMES: int = 30
## Physics frames spent settling after the player is teleported.
const SETTLE_FRAMES: int = 12
## Physics frames the aim has to survive before a mark is accepted.
const HOLD_CHECK_FRAMES: int = 30
## Metres the harness's own verification ray reaches. Shorter than every demo's
## reach — 2.6 m at the tightest — so a mark this accepts is always one the demo
## could actually have pressed. Verifying at a longer range than the game reaches
## would report the reach limit as a lost click.
const AIM_REACH: float = 2.4
## Drawn frames a trigger tap will wait for the gun to finish cycling or reloading.
const READY_FRAMES: int = 2400
## Drawn frames a tap is given to become a round before it counts as lost. At the
## 200 fps cap that is a full second, which is a hundred times the longest path
## from an input flush to a discharge.
const ROUND_FRAMES: int = 200
## Frame cap during the measurement. The shipping demos run 133-220 fps.
const FRAME_CAP: int = 200
## Metres the player stands off the control, tried in order. Inside every demo's
## `interact` reach, which is 2.6 m at the tightest. A negative entry means "aim
## from where the demo already put the player", which is the least invasive of all
## and the only one that works when the floor near a control is not floor.
const STANDOFFS: PackedFloat32Array = [-1.0, 1.6, 1.1, 2.2, 0.8]
## Control classes worth measuring, best first. A button and a lever ALWAYS report
## an actuation; a dial reports one whenever it moves a detent, which it always
## does while its options wrap. A slider clicked at the same point twice correctly
## reports nothing changed, so counting `pressed` on one would measure the slider
## rather than the input path.
const PREFERRED: PackedStringArray = ["DiegeticButton", "DiegeticLever", "DiegeticDial"]
## Metres above the standoff point the floor probe starts, and how far it reaches.
const FLOOR_PROBE_UP: float = 2.5
const FLOOR_PROBE_DOWN: float = 40.0

## The demos with a diegetic control the player operates, and the action that
## operates it. `fire` is the left mouse button, `interact` is F; both are real
## bindings out of `project.godot`. `hold_fire` stands the demo's gun down for the
## duration: on the bench the same button presses the console AND fires the weapon,
## and fifty rounds of recoil walk the crosshair off the control, so the gun would
## be measuring itself. The bench's trigger is measured on its own below.
const CASES: Array[Dictionary] = [
	{
		"id": &"gunbench",
		"scene": "res://demos/gunbench/gunbench.tscn",
		"action": &"fire",
		"hold_fire": true
	},
	{"id": &"bestiary", "scene": "res://demos/bestiary/bestiary.tscn", "action": &"fire"},
	{"id": &"movement", "scene": "res://demos/movement/movement.tscn", "action": &"fire"},
	{"id": &"ash_flats", "scene": "res://demos/ash_flats/ash_flats.tscn", "action": &"interact"},
	{"id": &"visuals", "scene": "res://demos/visuals/visuals.tscn", "action": &"interact"},
	{"id": &"arena", "scene": "res://demos/arena/arena.tscn", "action": &"interact"},
]

## Controls a case must not aim at, by `control_id`. These do something the
## harness cannot undo — throw a wave into the compound, or leave the demo — and
## fifty actuations of one is not a measurement.
const AVOID: Dictionary = {
	&"gunbench": [&"to_hand"],
	&"arena": [&"SpawnLever", &"ClearLever"],
	# RIDE hands the camera to a cinematic, and the next press is then correctly
	# spent giving control back rather than on the lever. Measuring it would report
	# the demo's own rule as a lost click. QUALITY writes the project's PERSISTED
	# settings — fifty presses of it leave the machine on Potato at 0.55 render
	# scale, and a measurement must not change the game it measured.
	&"visuals": [&"ride", &"quality"],
}

## The main menu, measured on its own because it is the only scene in the project
## operated by a LOOSE CURSOR rather than a crosshair — there is no player to turn
## and no eye to aim, only a pointer to put on a plate.
const MENU_SCENE: String = "res://ui/main_menu.tscn"
## Metres the menu's pick ray reaches. Matches `MainMenu.pick_reach`.
const MENU_REACH: float = 6.0
## Plates the menu case must not aim at. `quit` closes the process outright, and
## `settings` raises a panel that would then be up for the rest of the run.
const MENU_AVOID: PackedStringArray = ["quit", "settings"]
## Viewport pixels the pointer is parked at for the menu's `flick` pass while it is
## looking away. The top-left corner of the board is well clear of every plate.
const MENU_OFF: Vector2 = Vector2(24.0, 24.0)
## Attempts at settling the pointer onto a plate, and drawn frames each one waits.
##
## Aiming at the menu is a FEEDBACK LOOP and needs to converge rather than be
## computed once: `MainMenu._animate_camera` leans the eye toward the cursor, so
## warping the cursor to where a plate is drawn moves the plate. The lean is capped
## at 1.6 degrees and has a 0.22 s time constant, so re-solving a few times walks it
## in — measured, the target moved 5 px in total and was under the pointer from the
## first attempt on. Retrying also absorbs the other reason a warp misses: the OS
## delivers it asynchronously, and `Input.warp_mouse` does nothing at all while the
## game window does not have focus.
const MENU_TRIES: int = 8
const MENU_SETTLE: int = 24

## Demos whose player carries a gun, and the node that pulls its trigger. A short
## trigger tap that never becomes a round is the same complaint from the other end.
## `ash_flats` is here because it is the ONE demo with a gun whose rig has no
## `TriggerLatch` at all — `AshFlatsGunRig` calls `trigger_down()` and `trigger_up()`
## straight out of `_unhandled_input`, so both edges of a sub-frame tap land in the
## same flush and the trigger is already back up by the time the physics tick reads
## it. It was never in this list, and it is the demo this whole pass would have
## caught first.
const TRIGGERS: Array[Dictionary] = [
	{"id": &"range", "scene": "res://demos/range/range.tscn", "node": "Shooter"},
	{"id": &"arena", "scene": "res://demos/arena/arena.tscn", "node": "Loadout"},
	{"id": &"gunbench", "scene": "res://demos/gunbench/gunbench.tscn", "node": "."},
	{"id": &"ash_flats", "scene": "res://demos/ash_flats/ash_flats.tscn", "node": "Player/GunRig"},
]

## Demos whose player can actually shoulder a weapon — a `PlayerController` with an
## `ads` blend, a `WeaponHolster` to roll into, and a rig that pulls the trigger.
## The bench is not one: it has no player and nothing to aim down.
const ADS_DEMOS: Array[Dictionary] = [
	{"id": &"range", "scene": "res://demos/range/range.tscn", "node": "Shooter"},
	{"id": &"arena", "scene": "res://demos/arena/arena.tscn", "node": "Loadout"},
	{"id": &"ash_flats", "scene": "res://demos/ash_flats/ash_flats.tscn", "node": "Player/GunRig"},
]

var _lines: PackedStringArray = PackedStringArray()
var _rows: Array[Dictionary] = []
var _trigger_rows: Array[Dictionary] = []
var _ads_rows: Array[Dictionary] = []
var _failed: bool = false
var _started: bool = false
## True when the menu case could not run because there was no display server. Not a
## failure — an uncovered case, and the report says so rather than staying silent.
var _menu_skipped: bool = false
var _presses: int = 0
var _fired: int = 0


func _process(_delta: float) -> bool:
	if not _started:
		_started = true
		_run()
	return false


func _run() -> void:
	Engine.max_fps = FRAME_CAP
	_say("CLICK REGISTRATION")
	_say(
		(
			"%d clicks per pass, %d fps cap, physics %d Hz, burst %.0f Hz"
			% [CLICKS, FRAME_CAP, Engine.physics_ticks_per_second, BURST_HZ]
		)
	)
	_say("")
	_say(
		(
			"%-10s %-14s %-9s %6s %6s %6s %6s"
			% ["demo", "control", "action", "tap", "hold", "burst", "flick"]
		)
	)
	for case: Dictionary in CASES:
		await _run_case(case)
	await _run_menu()
	_say("")
	_say("TRIGGER TAPS  (a press and a release inside one drawn frame)")
	for case: Dictionary in TRIGGERS:
		await _run_trigger(case)
	await _run_ads()
	_summarise()
	_finish()


# --- clicks per round, shouldered ---------------------------------------------


## The ADS pass. The weapon-layer sweep first, because it is cheap and covers every
## mechanism; then the same four numbers through the real input path in demos that
## are really running, which is what proves the sweep is measuring the game.
func _run_ads() -> void:
	_say("")
	_say("CLICKS PER ROUND, SHOULDERED  (cold / ready / rated / early, ADS then hip)")
	var script: GDScript = load(ADS_PASS_SCRIPT) as GDScript
	if script == null:
		_fail("ads: could not load %s" % ADS_PASS_SCRIPT)
		return
	var pass_rig: Object = script.new()
	var swept: Array[Dictionary] = await pass_rig.sweep(self, _say)
	pass_rig.summarise(swept, "SWEEP — weapon layer, %d weapons" % swept.size())
	for case: Dictionary in ADS_DEMOS:
		var id: StringName = case["id"]
		var demo: Node = await _load_demo(String(case["scene"]))
		if demo == null:
			_fail("%s ads: %s did not load" % [id, case["scene"]])
			continue
		var rows: Array[Dictionary] = await pass_rig.in_demo(self, _say, demo, String(case["node"]))
		pass_rig.summarise(rows, "%s — real input path, %d weapons" % [id, rows.size()])
		_ads_rows.append_array(rows)
		await _drop(demo)
	for line: String in pass_rig.failures():
		_fail(line)


# --- control passes -----------------------------------------------------------


func _run_case(case: Dictionary) -> void:
	var id: StringName = case["id"]
	var demo: Node = await _load_demo(String(case["scene"]))
	if demo == null:
		_fail("%s: %s did not load" % [id, case["scene"]])
		return
	var aimed: Dictionary = await _aim_at_any(demo, id)
	if aimed.is_empty():
		_fail("%s: could not put any control under the crosshair; nothing measured" % id)
		await _drop(demo)
		return
	var control: DiegeticControl = aimed["control"]
	var eye: Camera3D = aimed["eye"]
	var action: StringName = case["action"]
	if bool(case.get("hold_fire", false)):
		demo.set(&"live_fire", false)

	var stock_press: float = control.press_cooldown
	control.pressed.connect(_on_pressed)

	# `tap`, `hold` and `flick` are about the INPUT path, so the PRESS debounce comes
	# off — a click every five milliseconds is not a thing a person does and a
	# control is right to refuse it. The BULLET debounce stays on, because in a demo
	# where the same click also fires a gun it is the thing that stops the round
	# actuating the control a second time, and removing it would measure that
	# instead. `burst` puts both back and clicks at a rate a person really reaches.
	control.press_cooldown = 0.0
	var tap: int = await _pass_tap(action)
	var tap_ok: bool = _under_crosshair(eye) == control
	await _idle(PASS_GAP)

	var hold: int = await _pass_hold(action)
	var hold_ok: bool = _under_crosshair(eye) == control
	await _idle(PASS_GAP)

	var flick: int = await _pass_flick(demo, control, eye, action)
	await _idle(PASS_GAP)

	control.press_cooldown = stock_press
	var burst: int = await _pass_burst(action)
	var burst_ok: bool = _under_crosshair(eye) == control
	control.pressed.disconnect(_on_pressed)

	if not (tap_ok and hold_ok and burst_ok):
		_fail("%s: the player left the mark mid-run; the figures below are void" % id)
	var row: Dictionary = {
		"id": id,
		"control": control.control_id,
		"action": action,
		"tap": tap,
		"hold": hold,
		"burst": burst,
		"flick": flick,
	}
	_rows.append(row)
	_say(
		(
			"%-10s %-14s %-9s %5d%% %5d%% %5d%% %5d%%"
			% [
				id,
				control.control_id,
				action,
				roundi(100.0 * float(tap) / float(CLICKS)),
				roundi(100.0 * float(hold) / float(CLICKS)),
				roundi(100.0 * float(burst) / float(CLICKS)),
				roundi(100.0 * float(flick) / float(FLICKS)),
			]
		)
	)
	if tap < CLICKS or hold < CLICKS or flick < FLICKS or burst < CLICKS:
		_failed = true
	await _drop(demo)


## One press and one release inside a single drawn frame, `CLICKS` times.
func _pass_tap(action: StringName, at: Vector2 = Vector2.INF) -> int:
	_presses = 0
	for _i: int in CLICKS:
		_send(action, true, at)
		_send(action, false, at)
		await process_frame
	await _settle()
	return _presses


## Press, hold for `HOLD_FRAMES` drawn frames, release. If this beats `_pass_tap`
## the rig is polling its trigger rather than reading the event.
func _pass_hold(action: StringName, at: Vector2 = Vector2.INF) -> int:
	_presses = 0
	for _i: int in CLICKS:
		_send(action, true, at)
		for _f: int in HOLD_FRAMES:
			await process_frame
		_send(action, false, at)
		await process_frame
	await _settle()
	return _presses


## Short clicks at `BURST_HZ` against the control's shipping cooldown.
func _pass_burst(action: StringName, at: Vector2 = Vector2.INF) -> int:
	_presses = 0
	var gap: int = maxi(1, roundi(float(FRAME_CAP) / BURST_HZ))
	for _i: int in CLICKS:
		_send(action, true, at)
		_send(action, false, at)
		for _f: int in gap:
			await process_frame
	await _settle()
	return _presses


## Look away, then look back and click in the same drawn frame. A rig that caches
## what it is pointing at in `_process` resolves the click against where the eye
## was a frame ago.
func _pass_flick(demo: Node, control: DiegeticControl, eye: Camera3D, action: StringName) -> int:
	var player: Node3D = demo.get_node_or_null(^"Player") as Node3D
	if player == null:
		return FLICKS
	var on_yaw: float = float(player.get(&"yaw"))
	var on_pitch: float = float(player.get(&"pitch"))
	_presses = 0
	for _i: int in FLICKS:
		player.set(&"yaw", on_yaw + PI)
		for _f: int in FLICK_AWAY:
			await process_frame
		player.set(&"yaw", on_yaw)
		player.set(&"pitch", on_pitch)
		_send(action, true)
		_send(action, false)
		await process_frame
	await _settle()
	# Put the eye back where the next pass expects it.
	player.set(&"yaw", on_yaw)
	player.set(&"pitch", on_pitch)
	await physics_frame
	if _under_crosshair(eye) != control:
		_fail("flick pass left the crosshair off the control")
	return _presses


func _on_pressed() -> void:
	_presses += 1


# --- the menu -------------------------------------------------------------------


## The menu, measured with a pointer instead of a crosshair. Everything else in the
## project aims down the middle of the screen; here the cursor is loose, so the rig
## puts the real cursor on a plate rather than turning a player to face one.
func _run_menu() -> void:
	if DisplayServer.get_name() == "headless":
		_say("")
		_say("main_menu  NOT MEASURED - a loose pointer needs a real display server.")
		_say("           Measured: a synthesised InputEventMouseMotion does NOT move")
		_say("           Viewport.get_mouse_position(), and the dummy server answers")
		_say("           it with the desktop cursor scaled by the stretch transform.")
		_say("           Re-run this harness WITHOUT --headless to cover the menu.")
		_menu_skipped = true
		return
	# Release the cursor, which is what `SceneRouter.set_mouse_captured(false)` does on
	# the way to the menu and which this harness has to do for itself because it loads
	# scenes directly. Measured: without it the mouse is still CAPTURED from the last
	# demo, the OS re-centres it every frame, `get_mouse_position()` answers dead
	# centre whatever it is warped to, and the menu case cannot acquire anything.
	#
	# Written against `Input` rather than through the autoload on purpose. `--script`
	# compiles this file before the autoloads are bound, so naming `SceneRouter` here
	# is a compile error that takes the whole harness down — the same trap that cost
	# two bake steps last pass.
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	var demo: Node = await _load_demo(MENU_SCENE)
	if demo == null:
		_fail("main_menu: %s did not load" % MENU_SCENE)
		return
	var eye: Camera3D = demo.get_node_or_null(^"Eye") as Camera3D
	var cards: Node = demo.get_node_or_null(^"Cards")
	if eye == null or cards == null:
		_fail("main_menu: the scene has no Eye or no Cards")
		await _drop(demo)
		return
	var control: DiegeticControl = null
	var on: Vector2 = Vector2.ZERO
	for node: Node in cards.get_children():
		var plate := node as DiegeticControl
		if plate == null or not plate.enabled or MENU_AVOID.has(String(plate.control_id)):
			continue
		var settled: Vector2 = await _settle_pointer(eye, plate)
		if settled.is_finite():
			control = plate
			on = settled
			break
	if control == null:
		_fail("main_menu: could not put a plate under the pointer; nothing measured")
		_say(
			(
				"           window %s viewport %s cursor %s focused %s mouse_mode %d"
				% [
					DisplayServer.window_get_size(),
					root.get_visible_rect().size,
					root.get_mouse_position(),
					DisplayServer.window_is_focused(),
					Input.mouse_mode,
				]
			)
		)
		await _drop(demo)
		return

	# The menu's own handler routes away on the first press, and the scene this
	# harness is measuring would be gone. The question here is whether the press
	# ARRIVES, so the plate's listeners come off and the harness counts for itself.
	for link: Dictionary in control.pressed.get_connections():
		control.pressed.disconnect(link["callable"])
	control.pressed.connect(_on_pressed)

	var stock_press: float = control.press_cooldown
	control.press_cooldown = 0.0
	var tap: int = await _pass_tap(&"fire", on)
	await _idle(PASS_GAP)
	var hold: int = await _pass_hold(&"fire", on)
	await _idle(PASS_GAP)
	var flick: int = await _pass_menu_flick(control, eye)
	await _idle(PASS_GAP)
	control.press_cooldown = stock_press
	var burst: int = await _pass_burst(&"fire", on)
	control.pressed.disconnect(_on_pressed)

	(
		_rows
		. append(
			{
				"id": &"main_menu",
				"control": control.control_id,
				"action": &"fire",
				"tap": tap,
				"hold": hold,
				"burst": burst,
				"flick": flick,
			}
		)
	)
	_say(
		(
			"%-10s %-14s %-9s %5d%% %5d%% %5d%% %5d%%"
			% [
				"main_menu",
				control.control_id,
				"fire",
				roundi(100.0 * float(tap) / float(CLICKS)),
				roundi(100.0 * float(hold) / float(CLICKS)),
				roundi(100.0 * float(burst) / float(CLICKS)),
				roundi(100.0 * float(flick) / float(FLICKS)),
			]
		)
	)
	if tap < CLICKS or hold < CLICKS or flick < FLICKS or burst < CLICKS:
		_failed = true
	await _drop(demo)


## Park the pointer well off every plate, leave it there for `FLICK_AWAY` frames,
## then click AT the plate without ever settling on it. This is the same-flush case
## a real flick of the wrist makes — the motion that puts the cursor on the plate and
## the button that goes down on it arrive together — and a rig that cached what it
## was pointing at on the previous frame resolves it against the empty board.
func _pass_menu_flick(control: DiegeticControl, eye: Camera3D) -> int:
	_presses = 0
	for _i: int in FLICKS:
		await _point_at(MENU_OFF)
		for _f: int in FLICK_AWAY:
			await process_frame
		if _under_pointer(eye) == control:
			_fail("main_menu flick: the pointer never left the plate")
			return _presses
		# Aimed at where the plate is drawn RIGHT NOW rather than at a pixel solved
		# before the eye leaned away, which is what a player flicking at a plate they
		# can see actually does.
		var aim: Vector2 = eye.unproject_position(control.global_position)
		_send(&"fire", true, aim)
		_send(&"fire", false, aim)
		await process_frame
	await _settle()
	if not (await _settle_pointer(eye, control)).is_finite():
		_fail("main_menu flick pass left the pointer off the plate")
	return _presses


## Walk the pointer onto `plate` until a ray agrees it is there. Returns the viewport
## pixel it settled on, or `Vector2.INF` if it never arrived.
func _settle_pointer(eye: Camera3D, plate: DiegeticControl) -> Vector2:
	for _attempt: int in MENU_TRIES:
		# Re-solved every attempt, not once: the eye has leaned since the last warp,
		# so the pixel the plate is drawn at has moved with it.
		var pixel: Vector2 = eye.unproject_position(plate.global_position)
		Input.warp_mouse(_to_window(pixel))
		for _f: int in MENU_SETTLE:
			await process_frame
		if _under_pointer(eye) == plate:
			return pixel
	return Vector2.INF


## Put the real cursor on a viewport pixel. `Input.warp_mouse` is the only thing
## that moves `Viewport.get_mouse_position()`; a synthesised motion event does not,
## which is measured and is why this case needs a display server.
func _point_at(pixel: Vector2) -> void:
	Input.warp_mouse(_to_window(pixel))
	for _f: int in MENU_SETTLE:
		await process_frame


## What the pointer is on, cast the way the menu casts it: PROP only, because the
## whole scene is one room and the plates are the only things in it that take a
## press. This is the reference the menu's figures lean on.
func _under_pointer(eye: Camera3D) -> DiegeticControl:
	var pixel: Vector2 = root.get_mouse_position()
	var query := PhysicsRayQueryParameters3D.new()
	query.from = eye.project_ray_origin(pixel)
	query.to = query.from + eye.project_ray_normal(pixel) * MENU_REACH
	query.collision_mask = GameLayers.PROP
	query.collide_with_areas = false
	var hit: Dictionary = eye.get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return null
	return hit["collider"] as DiegeticControl


# --- trigger passes -----------------------------------------------------------


## Sub-frame trigger taps against a demo that carries a gun. A rig that reads
## `Input.is_action_pressed` in `_physics_process` cannot see a click that opened
## and closed between two physics ticks, which is exactly "you have to hold it".
func _run_trigger(case: Dictionary) -> void:
	var id: StringName = case["id"]
	var demo: Node = await _load_demo(String(case["scene"]))
	if demo == null:
		_fail("%s trigger: %s did not load" % [id, case["scene"]])
		return
	var rig: Node = demo.get_node_or_null(NodePath(String(case["node"])))
	var weapon: Object = null
	if rig != null and rig.has_method(&"weapon"):
		weapon = rig.call(&"weapon")
	elif rig != null:
		weapon = rig.get_node_or_null(^"Weapon")
	if weapon == null:
		_fail("%s trigger: no weapon on %s" % [id, case["node"]])
		await _drop(demo)
		return
	# Reserve is bottomless in both demos, but the magazine is not: reloading in
	# the middle of the pass would look exactly like a lost click.
	var ammo: Object = weapon.call(&"ammo")
	var jam: Object = weapon.get(&"jam")
	(weapon as Object).connect(&"fired", _on_fired)
	_fired = 0
	var sent: int = 0
	var jammed: int = 0
	for _i: int in TRIGGER_TAPS:
		# The magazine is topped up in place rather than by working the reload.
		# Running a gun dry is a gun fact, not an input fact, and a reload cycle
		# would show up in this column as a lost tap.
		if int(ammo.call(&"loaded")) <= 2:
			ammo.call(&"refill_reserve")
			ammo.call(&"fill")
		# Wait for the gun rather than guessing at it. Both demos carry a ROLLED
		# weapon, which may be a 40 rpm bolt gun, and pacing the taps off a fixed
		# gap would report its rate of fire as if it were lost input.
		if not await _wait_ready(weapon):
			_fail("%s trigger: the gun never came ready" % id)
			break
		var before: int = _fired
		_send(&"fire", true)
		_send(&"fire", false)
		# Then wait for the round, rather than for a fixed number of frames. The
		# question this pass asks is whether the tap EVER becomes a round, and
		# giving it a frame budget instead would fold the rate of fire back in.
		for _f: int in ROUND_FRAMES:
			await process_frame
			if _fired > before:
				break
		# A pull the mechanism ate is a gun fact, not an input fact. `GunJam` rolls
		# per pull, and a jammed pull consumes the trigger without firing; counting
		# it here would report the weapon's reliability as lost input.
		if _fired == before and jam != null and bool(jam.call(&"is_jammed")):
			jammed += 1
			continue
		sent += 1
	await _settle()
	(weapon as Object).disconnect(&"fired", _on_fired)
	_trigger_rows.append({"id": id, "sent": sent, "fired": _fired})
	_say(
		(
			"%-10s %d taps -> %d rounds (%3.0f%%)%s"
			% [
				id,
				sent,
				_fired,
				100.0 * float(_fired) / maxf(float(sent), 1.0),
				"" if jammed == 0 else "   [%d pull(s) eaten by a jam, not counted]" % jammed,
			]
		)
	)
	if _fired < sent:
		_failed = true
	await _drop(demo)


func _on_fired(_origin: Vector3, _direction: Vector3, _spec: Object) -> void:
	_fired += 1


## Spin until the weapon says a pull right now would put a round downrange AND the
## mechanism has finished cycling. `Weapon.is_ready_to_fire` answers the first
## question only — it knows about jams, reloads and an empty magazine, not about
## the rate of fire — so waiting on it alone would report a 40 rpm bolt gun's cycle
## time as lost input. A jam is worked free rather than waited out: a jam is a gun
## fact and this pass is about input.
func _wait_ready(weapon: Object) -> bool:
	var group: Object = weapon.get(&"fire_control")
	var jam: Object = weapon.get(&"jam")
	for _i: int in READY_FRAMES:
		var cycled: bool = group == null or float(group.call(&"cooldown_remaining")) <= 0.0
		if cycled and bool(weapon.call(&"is_ready_to_fire")):
			return true
		if jam != null and bool(jam.call(&"is_jammed")):
			weapon.call(&"clear_jam")
		await process_frame
	return false


# --- rig ----------------------------------------------------------------------


## A real button-down or button-up for `action`. `fire` is the left mouse button
## and `interact` is F, both straight out of the project's input map.
##
## `at` is a VIEWPORT pixel the click is made at, or `Vector2.INF` for "wherever the
## pointer already is", which is what every crosshair demo wants. It is converted to
## window pixels on the way out because `Viewport.push_input` maps an incoming event
## through the stretch transform, exactly as it does for a real click from the OS.
func _send(action: StringName, down: bool, at: Vector2 = Vector2.INF) -> void:
	if action == &"fire":
		var click := InputEventMouseButton.new()
		click.button_index = MOUSE_BUTTON_LEFT
		click.pressed = down
		click.button_mask = MOUSE_BUTTON_MASK_LEFT if down else 0
		if at.is_finite():
			click.position = _to_window(at)
			click.global_position = click.position
		Input.parse_input_event(click)
		return
	var key := InputEventKey.new()
	key.physical_keycode = KEY_F
	key.pressed = down
	Input.parse_input_event(key)


## Viewport pixels to window pixels. The project renders a fixed design resolution
## into whatever window it was given; `Input.warp_mouse` and the `position` on an
## `InputEvent` are both in WINDOW pixels, while `Viewport.get_mouse_position` and
## `Camera3D.project_ray_*` answer in VIEWPORT ones. Measured on this machine: a
## 1920x1080 viewport in a 1280x720 window puts the two a factor of 1.5 apart, so
## getting this wrong does not fail loudly, it silently aims somewhere else.
func _to_window(pixel: Vector2) -> Vector2:
	var view: Vector2 = root.get_visible_rect().size
	var window := Vector2(DisplayServer.window_get_size())
	if view.x <= 0.0 or view.y <= 0.0:
		return pixel
	return pixel * window / view


func _load_demo(path: String) -> Node:
	var packed: PackedScene = load(path) as PackedScene
	if packed == null:
		return null
	var demo: Node = packed.instantiate()
	root.add_child(demo)
	current_scene = demo
	for _i: int in WARMUP_FRAMES:
		await physics_frame
	return demo


## Try every control in the demo until one of them is provably under the
## crosshair. Returns `{control, eye}` or an empty dictionary.
func _aim_at_any(demo: Node, id: StringName) -> Dictionary:
	var player: Node3D = demo.get_node_or_null(^"Player") as Node3D
	if player == null:
		return {}
	var eye: Camera3D = player.get_node_or_null(^"Eye") as Camera3D
	if eye == null:
		return {}
	var avoid: Array = AVOID.get(id, [])
	for wanted: String in PREFERRED:
		for node: Node in demo.find_children("*", wanted, true, false):
			var control := node as DiegeticControl
			if control == null or not control.enabled or control.control_id.is_empty():
				continue
			if avoid.has(control.control_id):
				continue
			if await _stand_at(player, eye, control):
				return {"control": control, "eye": eye}
	return {}


## Put the player's feet on the floor in front of `control` and point the eye at
## it. Returns true only once a physics-frame ray cast agrees.
func _stand_at(player: Node3D, eye: Camera3D, control: DiegeticControl) -> bool:
	for standoff: float in STANDOFFS:
		# Two ways in: from the side the demo already put the player on, and from
		# the control's own face. Neither works everywhere. The visuals post stands
		# at the lip of a bluff, so 1.6 m off its face is five metres of air; a
		# console pushed into a wall has nothing behind it but the wall.
		for from_player: bool in [true, false]:
			if await _try_standoff(player, eye, control, standoff, from_player):
				return true
	return false


func _try_standoff(
	player: Node3D, eye: Camera3D, control: DiegeticControl, standoff: float, from_player: bool
) -> bool:
	var target: Vector3 = control.global_position
	var face: Vector3 = player.global_position - target if from_player else control.global_basis.z
	face.y = 0.0
	if face.length_squared() < 1.0e-4:
		return false
	face = face.normalized()
	if standoff > 0.0:
		var stand: Vector3 = target + face * standoff
		var floor_y: float = _floor_under(eye, stand)
		stand.y = player.global_position.y if is_nan(floor_y) else floor_y
		if player.has_method(&"teleport"):
			player.call(&"teleport", stand, 0.0)
		else:
			player.global_position = stand
		for _i: int in SETTLE_FRAMES:
			await physics_frame
	# Aim from where the eye actually ended up, not from where it was asked to go.
	var to: Vector3 = target - eye.global_position
	if to.length_squared() < 1.0e-6:
		return false
	player.set(&"yaw", atan2(-to.x, -to.z))
	player.set(&"pitch", atan2(to.y, Vector2(to.x, to.z).length()))
	await physics_frame
	await physics_frame
	if _under_crosshair(eye) != control:
		return false
	# And still there after another half second of standing. A player sliding off a
	# ramp passes the first check and then makes the whole run look like lost input.
	for _i: int in HOLD_CHECK_FRAMES:
		await physics_frame
	return _under_crosshair(eye) == control


## Ground height under `at`, or NAN when there is nothing to stand on.
func _floor_under(node: Node3D, at: Vector3) -> float:
	var query := PhysicsRayQueryParameters3D.new()
	query.from = at + Vector3(0.0, FLOOR_PROBE_UP, 0.0)
	query.to = query.from - Vector3(0.0, FLOOR_PROBE_DOWN, 0.0)
	# PROP is in the mask as well as WORLD: a demo may stand its console on a deck,
	# and a probe that only saw terrain would put the player through it.
	query.collision_mask = GameLayers.WORLD | GameLayers.PROP
	query.collide_with_areas = false
	var hit: Dictionary = node.get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return NAN
	return (hit["position"] as Vector3).y


## What the crosshair is on, resolved from inside the physics callback. This is
## the reference the whole harness leans on: if this says the control is there,
## every miss afterwards belongs to the game.
func _under_crosshair(eye: Camera3D) -> DiegeticControl:
	var query := PhysicsRayQueryParameters3D.new()
	query.from = eye.global_position
	query.to = eye.global_position - eye.global_basis.z * AIM_REACH
	query.collision_mask = GameLayers.WORLD | GameLayers.PROP
	query.collide_with_areas = false
	var hit: Dictionary = eye.get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return null
	return hit["collider"] as DiegeticControl


## Two physics ticks of grace, so an actuation queued on the last drawn frame is
## never counted as lost.
func _settle() -> void:
	await physics_frame
	await physics_frame


func _idle(frames: int) -> void:
	for _i: int in frames:
		await process_frame


func _drop(demo: Node) -> void:
	current_scene = null
	root.remove_child(demo)
	demo.queue_free()
	for _i: int in 4:
		await process_frame


# --- report -------------------------------------------------------------------


func _summarise() -> void:
	_say("")
	var totals: Dictionary = {"tap": 0, "hold": 0, "burst": 0, "flick": 0}
	for row: Dictionary in _rows:
		for key: String in totals:
			totals[key] = int(totals[key]) + int(row[key])
	var n: int = _rows.size()
	if n == 0:
		_say("nothing was measured")
		_failed = true
		return
	_say(
		(
			"OVERALL  tap %d%%  hold %d%%  burst %d%%  flick %d%%   over %d demos"
			% [
				roundi(100.0 * float(totals["tap"]) / float(n * CLICKS)),
				roundi(100.0 * float(totals["hold"]) / float(n * CLICKS)),
				roundi(100.0 * float(totals["burst"]) / float(n * CLICKS)),
				roundi(100.0 * float(totals["flick"]) / float(n * FLICKS)),
				n,
			]
		)
	)
	var sent: int = 0
	var fired: int = 0
	for row: Dictionary in _trigger_rows:
		sent += int(row["sent"])
		fired += int(row["fired"])
	if sent > 0:
		_say(
			(
				"TRIGGER  %d%% of sub-frame taps became a round (%d/%d)"
				% [roundi(100.0 * float(fired) / float(sent)), fired, sent]
			)
		)
	_summarise_ads()
	if _menu_skipped:
		_say("UNCOVERED  main_menu (needs a display server; run without --headless)")
	_say("RESULT: %s" % ("FAIL" if _failed else "PASS"))


## The headline the ADS pass exists for: clicks per round at the weapon's own rated
## rate, shouldered, over every weapon the real demos measured.
func _summarise_ads() -> void:
	if _ads_rows.is_empty():
		return
	var cold: float = 0.0
	var rated: float = 0.0
	var worst: float = 0.0
	var worst_gun: String = ""
	for row: Dictionary in _ads_rows:
		cold += float(row["cold_ads"])
		rated += float(row["rated_ads"])
		if float(row["rated_ads"]) > worst:
			worst = float(row["rated_ads"])
			worst_gun = "%s (%s)" % [row["weapon"], row["action"]]
	var n: float = float(_ads_rows.size())
	_say(
		(
			(
				"ADS      %.2f clicks to the first round, %.2f clicks per round at the"
				+ " rated rate, over %d weapons"
			)
			% [cold / n, rated / n, _ads_rows.size()]
		)
	)
	_say("         worst weapon %.2f clicks per round — %s" % [worst, worst_gun])


func _say(line: String) -> void:
	print(line)
	_lines.append(line)


func _fail(line: String) -> void:
	_failed = true
	_say("FAIL  %s" % line)


func _finish() -> void:
	var file := FileAccess.open(REPORT_PATH, FileAccess.WRITE)
	if file != null:
		file.store_string("\n".join(_lines) + "\n")
		file.close()
	quit(1 if _failed else 0)
