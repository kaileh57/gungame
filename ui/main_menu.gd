class_name MainMenu
extends Node3D
## The front page, as a place rather than a page.
##
## A corner of a scav workshop: a bench under two work-lamps, and a board standing
## behind it carrying the whole menu. Each demo is a stencilled plate resting in a
## lip on that board, four to a row. Look at one and the readout strip under the
## bottom row says what it is; click it — or shoot it, the same call either way —
## and you go there. Two smaller plates lie back on the bench itself for settings
## and for leaving.
##
## The readout has a lane of its own. It used to sit at plate height BEHIND the
## plates, where its text came out through the gaps between them and read as one
## label bleeding into another.
##
## Every plate is a `DiegeticControl`, so the menu is operated by exactly the same
## code path a demo's in-world panel uses — down to `DiegeticInteractor`, which is
## the same node the bench, the hall and the arena console are driven by. Nothing
## here writes `get_tree().paused` or the mouse mode; `SceneRouter` owns both and
## has already released the cursor by the time this scene exists.
##
## THE CURSOR IS THE POINTER HERE, not the crosshair, which is why the interactor is
## built with `aim_at_pointer`. Everything else about it is the same latch every
## demo uses, and it is here for the same reason: this file used to cast its pick
## ray in `_process` and read the cached answer back in `_unhandled_input`. Input is
## flushed at the top of the engine iteration and `_process` runs at the bottom of
## it, so the cache was always one frame behind the cursor — flick the mouse onto a
## plate and click in the same motion and the press resolved against the empty board
## the cursor had been over a frame earlier, and was dropped in silence. It is the
## first thing anybody clicks in this project, so it was also the worst place for it.
##
## A demo whose scene has not been built yet is not hidden. Its plate goes dark and
## its tag reads NOT BUILT, because a menu that silently omits a demo is a menu you
## cannot debug.
##
## THE LOBBY LIVES ON THE SAME BENCH. `res://ui/lobby/` owns the JOIN console, the
## HOST plate, the roster tags and the falling signs; this file owns the plates, the
## board and the hands, and hands the lobby the eye and the interactor once. Two
## things cross the line in the other direction: `say()`, which is how the lobby puts
## a sentence on the bench readout, and `blurb_for()`, which is how the readout knows
## what the lobby's own controls do.
##
## WHO MAY PICK. Only the host routes. On a client every demo plate is disabled — it
## still hovers, so its description still reads, and it still KNOCKS when pressed —
## and a bar drops across the board so the reason is legible from across the room.
## Single-player is a session of one and is therefore always the authority, so none of
## this is in the way when there is no network.
##
## THE HOST'S CHOICE IS VISIBLE TO EVERYONE. The plate the host's cursor is on lifts
## and goes red on every machine, and the plate the host actually presses flashes on
## every machine, so a guest can see what is about to happen instead of being
## teleported. Those are the only two RPCs on this screen and they live HERE, on the
## scene root, because `/root/MainMenu` is the one node path that is identical on
## every machine while anybody is allowed to join.

## Ids the plates carry that are not demos.
const ID_SETTINGS: StringName = &"settings"
const ID_QUIT: StringName = &"quit"

const TAG_READY: String = "READY"
const TAG_MISSING: String = "NOT BUILT"
## What a demo plate's tag reads on a machine that is not allowed to pick one.
const TAG_LOCKED: String = "HOST ONLY"
const BOARD_IDLE: String = "PICK ONE."
## How far a plate the HOST is pointing at is dragged toward the host's colour on
## everybody else's screen. High, because it has to beat the hover glow it sits under.
const PICK_BLEND: float = 0.85

@export_group("Plates")
## Metres a plate rises off the board when the cursor is on it. A centimetre
## reads clearly at bench distance and costs nothing to animate.
@export_range(0.0, 0.06, 0.001) var hover_lift: float = 0.014
## Seconds for a plate to reach its hovered position. Exponential, so this is the
## time to close 95 % of the gap.
@export_range(0.02, 0.40, 0.01) var hover_seconds: float = 0.09
## Label brightness multiplier while hovered.
@export_range(1.0, 3.0, 0.05) var hover_glow: float = 1.65

@export_group("Camera")
## Degrees the camera leans toward the cursor. Enough to feel like a head, not
## enough to fight the mouse.
@export_range(0.0, 6.0, 0.1) var sway_degrees: float = 1.6
## Seconds for the camera to reach the cursor's lean.
@export_range(0.02, 1.00, 0.01) var sway_seconds: float = 0.22

@export_group("Lamp")
## Peak fraction the work-lamp dips by. Zero switches the flicker off entirely.
@export_range(0.0, 0.4, 0.01) var flicker_depth: float = 0.06
@export_range(0.1, 12.0, 0.1) var flicker_speed: float = 3.7

@export_group("Reach")
## Metres the pick ray reaches. The far corner plate is 2.2 m from the eye and the
## whole menu lives inside one shed, so this only has to clear the room.
@export_range(0.5, 40.0, 0.1) var pick_reach: float = 6.0

var _controls: Array[DiegeticControl] = []
var _labels: Array[Label3D] = []
## Per control, everything that rides out of the board together: the plate and the
## two labels stencilled on it. The labels are SIBLINGS of the plate rather than
## children of it, because `DiegeticControl` and the shell test both address
## `Label` and `Tag` at the top level — so the lift has to be applied to all three
## by hand. Move only the plate and it slides out from under its own title, which
## ends up inside the plate and disappears the moment you look at it.
var _riders: Array[Array] = []
## Resting local z of each rider, in the same order.
var _rider_rest: Array[PackedFloat32Array] = []
## How far each control is currently lifted out of its rest, in metres.
var _lift: PackedFloat32Array = PackedFloat32Array()
var _label_rest: PackedColorArray = PackedColorArray()
var _hovered: int = -1
## The plate the HOST is pointing at, on a client. -1 anywhere else, including on the
## host itself: the host has its own hover and does not need to be told about it.
var _host_pick: int = -1
## Last id announced to the guests, so a hover that has not moved sends nothing.
var _picked_id: StringName = &""
## True when this machine is a client, and therefore may not pick a demo.
var _locked: bool = false
var _eye_rest: Vector3 = Vector3.ZERO
var _sway: Vector2 = Vector2.ZERO
var _lamp_energy: float = 1.0
var _flicker_phase: float = 0.0
## The hands. Owns the ray, the latch and the queue.
var _hands: DiegeticInteractor = null
## The multiplayer half of the bench. Null in a menu baked before it existed, which
## is the one state this file has to survive without it.
var _lobby: LobbyBench = null

@onready var _eye: Camera3D = $Eye
@onready var _board: Label3D = $Bench/Board
@onready var _lamp: SpotLight3D = $Lamp/Bulb/Light
@onready var _cards: Node3D = $Cards
@onready var _settings_panel: SettingsPanel = $Ui/SettingsPanel


func _ready() -> void:
	_eye_rest = _eye.rotation
	_lamp_energy = _lamp.light_energy
	_build_hands()
	GameSettings.register_viewport(get_viewport())
	_eye.fov = GameSettings.fov
	GameSettings.settings_changed.connect(_on_setting_changed)
	SceneRouter.route_failed.connect(_on_route_failed)
	_settings_panel.closed.connect(_on_settings_closed)
	_settings_panel.visible = false
	_collect_controls()
	_lobby = get_node_or_null(^"Lobby") as LobbyBench
	if _lobby != null:
		_lobby.bind(self, _eye, _hands)
	_bind_network()
	_refresh_authority()
	_board.text = BOARD_IDLE


func _process(delta: float) -> void:
	_animate_plates(delta)
	_animate_camera(delta)
	_animate_lamp(delta)


func _unhandled_input(event: InputEvent) -> void:
	# Only the panel's own escape hatch is left here. Presses on the plates are
	# latched by `_hands` at the instant the button goes down.
	if _settings_panel.visible and event.is_action_pressed(&"pause"):
		get_viewport().set_input_as_handled()
		_settings_panel.close()


## Which plate the cursor is over, or -1. Public because the F3 overlay and the
## traversal test both want to know without reaching into the ray.
func hovered_id() -> StringName:
	if _hovered < 0:
		return &""
	return _controls[_hovered].control_id


## Put a sentence on the bench readout. The lobby's one way into this screen's own
## voice; an empty string puts the board back to its resting line.
func say(text: String) -> void:
	_board.text = BOARD_IDLE if text.is_empty() else text.to_upper()


# --- what the guests are shown ----------------------------------------------
#
# Two RPCs, both host to everyone, both purely cosmetic: nothing here decides
# anything. They are on this node because `/root/MainMenu` is the same path on every
# machine, which is what Godot needs to route an RPC at all.

## The plate under the host's cursor. Reliable rather than unreliable: a highlight is
## an event and not a stream, and a dropped one would stick forever.
@rpc("authority", "reliable")
func _rs_pick(id: StringName) -> void:
	_set_host_pick(_index_of(id))


## The plate the host actually pressed, so a guest sees the choice land the instant
## before the fade takes the screen away from them.
@rpc("authority", "reliable")
func _rs_press(id: StringName) -> void:
	var index: int = _index_of(id)
	if index >= 0:
		_controls[index].flash()


func _collect_controls() -> void:
	for node: Node in _cards.get_children():
		var control := node as DiegeticControl
		if control == null:
			continue
		var plate := control.get_node_or_null(^"Plate") as Node3D
		var label := control.get_node_or_null(^"Label") as Label3D
		if plate == null or label == null:
			push_error("MainMenu: plate '%s' is missing its Plate or Label child." % control.name)
			continue
		var riders: Array[Node3D] = [plate, label]
		var tag := control.get_node_or_null(^"Tag") as Node3D
		if tag != null:
			riders.append(tag)
		var rest := PackedFloat32Array()
		for rider: Node3D in riders:
			rest.append(rider.position.z)
		_controls.append(control)
		_labels.append(label)
		_riders.append(riders)
		_rider_rest.append(rest)
		_lift.append(0.0)
		_label_rest.append(label.modulate)
		control.pressed.connect(_on_control_pressed.bind(control))
		_check_availability(control)


## A demo plate is only live if the router knows the id, the scene exists on disk,
## and this machine is allowed to route at all. The tag says which of those failed
## without opening a log.
func _check_availability(control: DiegeticControl) -> void:
	var id: String = String(control.control_id)
	if id == ID_SETTINGS or id == ID_QUIT:
		return
	var tag := control.get_node_or_null(^"Tag") as Label3D
	var info: Dictionary = SceneRouter.demo_info(id)
	var live: bool = not info.is_empty() and ResourceLoader.exists(String(info["scene"]))
	# A locked plate is DISABLED rather than hidden: it still hovers, so it still
	# reads, and it knocks when pressed instead of doing nothing in silence.
	control.enabled = live and not _locked
	if tag == null:
		return
	if _locked:
		tag.text = TAG_LOCKED
		tag.modulate = UiStyle.TEXT_FAINT
		return
	tag.text = TAG_READY if live else TAG_MISSING
	tag.modulate = UiStyle.GOOD if live else UiStyle.WARN


# --- who is allowed to pick --------------------------------------------------


func _bind_network() -> void:
	NetGame.players_changed.connect(_refresh_authority)
	NetGame.joined.connect(_refresh_authority)
	NetGame.lobby_opened.connect(_refresh_authority)
	NetGame.lobby_closed.connect(_refresh_authority)
	NetGame.disconnected.connect(_on_disconnected)


## `is_authority()` is true on the host AND in single-player, so this is false in
## every state except "guest in somebody else's game" — which is exactly the state
## the board is locked in.
func _refresh_authority() -> void:
	if not NetGame.is_networked():
		_set_host_pick(-1)
		_picked_id = &""
	var locked: bool = NetGame.is_networked() and not NetGame.is_authority()
	if locked == _locked:
		return
	_locked = locked
	for control: DiegeticControl in _controls:
		_check_availability(control)
	if _lobby != null:
		_lobby.set_locked(locked)


func _on_disconnected(_reason: String) -> void:
	_refresh_authority()


func _set_host_pick(index: int) -> void:
	if index == _host_pick:
		return
	_host_pick = index
	_repaint_labels()


## Tell the guests where the host is pointing. Only on a hover CHANGE, so a cursor
## resting on one plate costs nothing at all.
func _publish_pick() -> void:
	if not NetGame.is_networked() or not NetGame.is_host():
		return
	var id: StringName = &"" if _hovered < 0 else _controls[_hovered].control_id
	if id == _picked_id:
		return
	_picked_id = id
	rpc(&"_rs_pick", id)


func _index_of(id: StringName) -> int:
	if id == &"":
		return -1
	for i: int in _controls.size():
		if _controls[i].control_id == id:
			return i
	return -1


## The hands. The cursor is loose in this scene, so the rays follow it rather than
## the middle of the screen; a plate that is not built is still hovered, because the
## readout's job is to say WHY it cannot be picked.
func _build_hands() -> void:
	_hands = DiegeticInteractor.new()
	_hands.name = "Hands"
	_hands.aim_at_pointer = true
	# PROP only. Every plate is on it, the whole menu is one small room, and the
	# shed's own timber sits between the eye and the bench plates at grazing angles.
	_hands.collision_mask = GameLayers.PROP
	_hands.interact_reach = pick_reach
	_hands.fire_reach = pick_reach
	# A plate is a plate: clicking its corner is the same press as clicking its
	# middle, so both buttons give the centred nudge rather than a point hit.
	_hands.fire_presses_at_point = false
	_hands.hover_skips_disabled = false
	_hands.set_eye(_eye)
	_hands.hover_changed.connect(_on_hover_changed)
	add_child(_hands)
	CombatReticle.mount(self).watch(_hands)


func _on_hover_changed(control: DiegeticControl) -> void:
	_hovered = -1 if control == null else _controls.find(control)
	_publish_pick()
	# The lobby's own controls are not on the board and are not in `_controls`, so
	# they answer for themselves before the plate lookup gets a chance to fail.
	if control != null and _lobby != null:
		var mine: String = _lobby.blurb_for(control)
		if not mine.is_empty():
			_board.text = mine
			return
	if _hovered < 0:
		_board.text = BOARD_IDLE
		return
	_board.text = _blurb_for(_controls[_hovered])


func _blurb_for(control: DiegeticControl) -> String:
	var id: String = String(control.control_id)
	if id == ID_SETTINGS:
		return "QUALITY, FIELD OF VIEW, SENSITIVITY. THE FRAME COUNTER RUNS WHILE YOU TURN THINGS."
	if id == ID_QUIT:
		return "CLOSE IT DOWN."
	var info: Dictionary = SceneRouter.demo_info(id)
	if info.is_empty():
		return "NO DEMO IS REGISTERED UNDER '%s'." % id.to_upper()
	if _locked:
		return "%s — THE HOST PICKS WHERE EVERYONE GOES." % String(info["title"])
	if not control.enabled:
		return "%s HAS NOT BEEN BUILT YET. RUN ITS BUILDER." % String(info["title"])
	return String(info["blurb"]).to_upper()


func _animate_plates(delta: float) -> void:
	# exp(-dt/tau) is the frame-rate independent form of a lerp; at 240 fps the
	# plate takes exactly as long to rise as it does at 60.
	var k: float = 1.0 - exp(-delta / maxf(hover_seconds, 0.001))
	for i: int in _controls.size():
		var target: float = hover_lift if (i == _hovered or i == _host_pick) else 0.0
		if is_equal_approx(_lift[i], target):
			continue
		_lift[i] = lerpf(_lift[i], target, k)
		var riders: Array = _riders[i]
		var rest: PackedFloat32Array = _rider_rest[i]
		for j: int in riders.size():
			(riders[j] as Node3D).position.z = rest[j] + _lift[i]
		_paint_label(i)


## One plate's title colour, at its current lift. Pulled out of the animation loop
## because the HOST'S pick can change while a plate is already sitting at full lift,
## and that loop skips anything that has stopped moving.
func _paint_label(i: int) -> void:
	var lit: float = _lift[i] / maxf(hover_lift, 0.0001)
	_labels[i].modulate = _label_base(i) * lerpf(1.0, hover_glow, clampf(lit, 0.0, 1.0))


## The host's colour on the plate the host is pointing at — but never on the one YOU
## are pointing at, because your own hover has already claimed that plate and two
## highlights on one object say nothing.
func _label_base(i: int) -> Color:
	if i != _host_pick or i == _hovered:
		return _label_rest[i]
	return _label_rest[i].lerp(NetPlayer.SLOT_COLORS[0].lightened(0.30), PICK_BLEND)


func _repaint_labels() -> void:
	for i: int in _labels.size():
		_paint_label(i)


func _animate_camera(delta: float) -> void:
	var rect: Vector2 = get_viewport().get_visible_rect().size
	var mouse: Vector2 = get_viewport().get_mouse_position()
	var want := Vector2(
		clampf(mouse.x / maxf(rect.x, 1.0) * 2.0 - 1.0, -1.0, 1.0),
		clampf(mouse.y / maxf(rect.y, 1.0) * 2.0 - 1.0, -1.0, 1.0)
	)
	_sway = _sway.lerp(want, 1.0 - exp(-delta / maxf(sway_seconds, 0.001)))
	var amount: float = deg_to_rad(sway_degrees)
	_eye.rotation = Vector3(
		_eye_rest.x - _sway.y * amount, _eye_rest.y - _sway.x * amount, _eye_rest.z
	)


## Two detuned sines, so the dip never repeats on a beat you can count.
func _animate_lamp(delta: float) -> void:
	if flicker_depth <= 0.0:
		return
	_flicker_phase = fmod(_flicker_phase + delta * flicker_speed, TAU)
	var dip: float = sin(_flicker_phase) * 0.6 + sin(_flicker_phase * 2.37) * 0.4
	_lamp.light_energy = _lamp_energy * (1.0 - flicker_depth * (0.5 + 0.5 * dip))


func _on_control_pressed(control: DiegeticControl) -> void:
	var id: String = String(control.control_id)
	if id == ID_SETTINGS:
		# The hands come off the board while the panel is up. That drops the hover
		# and clears any press still queued, so a click aimed at the panel's own
		# buttons cannot also land on the plate behind it.
		_hands.enabled = false
		_settings_panel.open()
		_hovered = -1
		_board.text = BOARD_IDLE
		return
	if id == ID_QUIT:
		get_tree().quit()
		return
	# Cosmetic, and sent before the route so it lands while everyone can still see
	# the board. `SceneRouter.go` refuses a client, so only a host ever gets here.
	if NetGame.is_networked() and NetGame.is_host():
		rpc(&"_rs_press", control.control_id)
	SceneRouter.go(id)


func _on_settings_closed() -> void:
	_hands.enabled = true
	_board.text = BOARD_IDLE


func _on_route_failed(_demo_id: String, message: String) -> void:
	_board.text = message.to_upper()


func _on_setting_changed(key: StringName, value: Variant) -> void:
	if key == &"fov":
		_eye.fov = float(value)
