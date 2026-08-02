class_name VisualsDash
extends CanvasLayer
## Hold-to-dash for the dusk showpiece: the thing that turns a 1760 metre map from
## a twenty minute walk into a thirty second flight.
##
## The demo is a viewer, not a shooter — the whole ask of it is "let me see the
## scale of what exists" — and at the player's 4.35 m/s walk the far rim of the
## ash flats is six and a half minutes away. So one held button ramps the body up
## to `top_speed` and the freecam to `fly_top_speed`, and lets go smoothly.
##
## IT DOES NOT TOUCH THE PLAYER'S CODE. `PlayerController` already has everything
## needed: `walk_speed`, `sprint_speed` and `crouch_speed` are plain exports read
## fresh every physics tick by `ground_target_speed()`, so writing them IS the
## dash, and the body still moves through `move_and_slide` — which sweeps its
## capsule rather than teleporting it — so nothing clips through the town at any
## speed this offers. The originals are cached at `_ready()` and put back the
## moment the ramp reaches zero.
##
## THE RAMP IS THE FEEL. Target speed is integrated at `acceleration` m/s² rather
## than snapped, because the player's own accelerator (`ground_accel` times the
## wish speed) would otherwise take the body from a walk to sixty in two frames,
## which reads as a teleport and makes the world unreadable. Letting go decays at
## `release_deceleration`, faster than it built, so a dash stops where you meant
## it to.
##
## SENSE OF SPEED comes from three things, all of them free: the eye's own FOV
## push (written into `PlayerCameraRig.fov_base`, which is damped and rate-limited
## by the camera itself, so it is smooth by construction), an additive radial
## streak overlay that is HIDDEN — not merely transparent — whenever the ramp is
## at rest, and a readout that tells you the number.
##
## MULTIPLAYER: nothing here is gated on authority and nothing here is
## replicated, on purpose. The dash is local input driving the local body's own
## movement, exactly like the walk it scales; `PlayerController` already owns how
## a body's position reaches the other machines.

## The overlay this script drives is AUTHORED ELSEWHERE, by `VisualsDashHud`, and
## the reason is written out in full at the top of that file: the builder has to
## preload whatever it calls a static function on, a preload is compiled on a bare
## `SceneTree` with no autoloads, and the three player types declared below drag in
## scripts that name `GameSettings` and cannot compile there. Anything the bake
## calls therefore lives in a file that stays clean of all of it.
const Hud := preload("res://demos/visuals/visuals_dash_hud.gd")

## Trigger. `sprint` by default — it is the button already under the thumb and the
## finger that means "go faster", it exists on pad as well as on keyboard, and
## this demo has nothing else to sprint for.
@export var dash_action: StringName = &"sprint"

@export_group("On foot")
## Metres per second the body reaches at full dash. Sixty crosses the town in
## five seconds and the whole map corner to corner in thirty. The ceiling of the
## range is 120: past that a 60 Hz physics tick moves the capsule two metres a
## step, and while the sweep still catches the wall, the step-up and ground-snap
## probes stop being able to read the ground under it.
@export_range(6.0, 120.0, 0.5) var top_speed: float = 60.0
## Metres per second per second the target speed is integrated at. At 34 the ramp
## from a walk to the top takes 1.6 s, which is long enough to see happen.
@export_range(4.0, 200.0, 0.5) var acceleration: float = 34.0
## How fast the ramp falls when the button is let go. Faster than it built.
@export_range(4.0, 400.0, 0.5) var release_deceleration: float = 96.0

@export_group("Freecam")
## The freecam has no capsule and nothing to clip, so it gets nearly three times
## the ceiling — it is the tool for reading the whole map in one pass.
@export_range(10.0, 400.0, 1.0) var fly_top_speed: float = 170.0
@export_range(4.0, 600.0, 1.0) var fly_acceleration: float = 110.0

@export_group("Feel")
## Degrees of FOV added at full dash, on foot and in the freecam alike.
@export_range(0.0, 40.0, 0.5) var fov_push_degrees: float = 21.0
## Strength of the streak overlay at full dash. Zero switches it off outright.
@export_range(0.0, 1.0, 0.01) var streak_strength: float = 1.0
## Fraction of the ramp below which the overlay is hidden and costs nothing.
@export_range(0.0, 0.5, 0.005) var streak_floor: float = 0.02

@export_group("Wiring")
@export var player_path: NodePath = NodePath("../Player")
@export var freecam_path: NodePath = NodePath("../Player/Freecam")

var _player: PlayerController = null
var _eye: PlayerCameraRig = null
var _freecam: FreecamController = null
## The `SceneRouter` autoload, or null when there is not one. Held as a plain `Node`
## and looked up by path so that nothing in this script's own body depends on an
## autoload existing, which is what lets the bake attach it without complaint.
var _router: Node = null

## 0 at rest, 1 at the top speed. One ramp drives the body, the freecam, the FOV
## and the overlay, so they cannot disagree about how fast you are going.
var _ramp: float = 0.0
var _button_held: bool = false
var _engaged: bool = false

var _base_walk: float = 0.0
var _base_sprint: float = 0.0
var _base_crouch: float = 0.0
var _base_fov: float = 0.0
var _base_fly: float = 0.0
## The freecam's lens as it stood the moment it was switched on. Snapshotted THERE
## rather than at `_ready()` because `FreecamController._enter()` adopts the FOV and
## far plane of whatever camera was current — so the value cached at load is the
## freecam's authored default and not the one the dash has to give back.
var _base_fly_fov: float = 0.0

@onready var _streaks: ColorRect = get_node_or_null(^"Streaks") as ColorRect
@onready var _meter: ColorRect = get_node_or_null(^"Prompt/Meter/Fill") as ColorRect
@onready var _readout: Label = get_node_or_null(^"Prompt/Speed") as Label
@onready var _button: Button = get_node_or_null(^"Prompt/Hold") as Button


func _ready() -> void:
	_router = get_tree().root.get_node_or_null(^"SceneRouter")
	_player = get_node_or_null(player_path) as PlayerController
	_freecam = get_node_or_null(freecam_path) as FreecamController
	if _player != null:
		_eye = _player.get_node_or_null(^"Eye") as PlayerCameraRig
		_base_walk = _player.walk_speed
		_base_sprint = _player.sprint_speed
		_base_crouch = _player.crouch_speed
	if _eye != null:
		_base_fov = _eye.fov_base
	if _freecam != null:
		_base_fly = _freecam.base_speed
		_base_fly_fov = _freecam.fov
		_freecam.freecam_changed.connect(_on_freecam_changed)
	if _button != null:
		_button.button_down.connect(_on_button_down)
		_button.button_up.connect(_on_button_up)
	if _streaks != null:
		_streaks.visible = false
	_check_widgets()
	_write_hud()


## Refuse to be quiet about a HUD that is not there. The widgets are created by
## `VisualsDashHud` and found here by path, and those are two files — so a rename in
## one of them is a meter that stops moving and a readout that stays at zero while
## the dash itself works perfectly, which is the hardest kind of bug to notice. The
## dash still runs; it just says so.
func _check_widgets() -> void:
	var missing := PackedStringArray()
	for path: String in Hud.WIDGETS:
		if get_node_or_null(NodePath(path)) == null:
			missing.append(path)
	if not missing.is_empty():
		push_error(
			"VisualsDash: overlay is missing %s — re-run build_visuals.gd" % ", ".join(missing)
		)


func _process(delta: float) -> void:
	var dt: float = minf(delta, 0.1)
	var flying: bool = _freecam != null and _freecam.active
	var wanted: bool = _held() and not _blocked(flying)
	var rate: float = fly_acceleration if flying else acceleration
	var span: float = maxf(_top(flying) - _rest(flying), 0.001)
	# The ramp is integrated in METRES PER SECOND and normalised afterwards, so
	# `acceleration` stays an acceleration whichever of the two ceilings is live.
	var step: float = (rate if wanted else -release_deceleration) * dt / span
	_ramp = clampf(_ramp + step, 0.0, 1.0)
	if _ramp > 0.0 or _engaged:
		_apply(flying)
	_write_hud()


## The physical button, for anyone driving this on a touch screen. With the mouse
## captured — which is how the demo normally runs — a pointer cannot reach it, so
## it is a prompt first and a control second; `dash_action` is the real trigger
## and the prompt says so.
func _on_button_down() -> void:
	_button_held = true


func _on_button_up() -> void:
	_button_held = false


## The freecam has just been switched on or off. On the way IN it has adopted the
## player eye's lens, so this is the only moment the lens the dash must restore is
## knowable; on the way OUT the ramp is dropped, because a dash carried from the air
## into a body standing still is sixty metres a second of surprise.
func _on_freecam_changed(is_active: bool) -> void:
	if is_active:
		_base_fly_fov = _freecam.fov
		return
	_ramp = 0.0
	_apply(false)


func _held() -> bool:
	return _button_held or Input.is_action_pressed(dash_action)


## Nothing dashes while the camera rig owns the view or a menu owns the input.
func _blocked(flying: bool) -> bool:
	if _router != null and bool(_router.call(&"is_paused")):
		return true
	if flying:
		return false
	return _player == null or _player.input_suspended


func _top(flying: bool) -> float:
	return fly_top_speed if flying else top_speed


## The speed the ramp starts from: what the body or the freecam does anyway.
func _rest(flying: bool) -> float:
	if flying:
		return _base_fly
	return _base_sprint


func _apply(flying: bool) -> void:
	var live: bool = _ramp > 0.0005
	_engaged = live
	_apply_body(flying, live)
	_apply_fly(flying, live)
	_apply_streaks(live)


## Write the ramped speed over the body's three gaits, or put the originals back.
## All three, not just the sprint: `ground_target_speed()` picks between them on
## crouch and stamina, and a dash that dies because you ran out of breath or
## walked backwards is a dash with a bug in it.
func _apply_body(flying: bool, live: bool) -> void:
	if _player == null:
		return
	if flying or not live:
		_player.walk_speed = _base_walk
		_player.sprint_speed = _base_sprint
		_player.crouch_speed = _base_crouch
	else:
		var speed: float = lerpf(_base_sprint, top_speed, _ramp)
		_player.walk_speed = speed
		_player.sprint_speed = speed
		_player.crouch_speed = maxf(_base_crouch, speed * 0.45)
	if _eye == null:
		return
	# The camera damps and rate-limits its own FOV, so writing the target here is
	# the whole of the smoothing. Re-asserted every frame because `GameSettings`
	# writes `fov_base` back on any settings change.
	_eye.fov_base = _base_fov + (0.0 if flying or not live else fov_push_degrees * _ramp)


## The freecam multiplies `base_speed` by its own sprint multiplier while the
## sprint action is down — which, with the default binding, is the same button
## that is driving this — so the divisor has to come out or the two multiply.
func _apply_fly(flying: bool, live: bool) -> void:
	if _freecam == null:
		return
	if not flying or not live:
		_freecam.base_speed = _base_fly
		_freecam.fov = _base_fly_fov
		return
	var mul: float = 1.0
	if Input.is_action_pressed(&"sprint"):
		mul = _freecam.sprint_mul
	_freecam.base_speed = lerpf(_base_fly, fly_top_speed, _ramp) / maxf(mul, 0.01)
	_freecam.fov = _base_fly_fov + fov_push_degrees * _ramp


func _apply_streaks(live: bool) -> void:
	if _streaks == null:
		return
	var amount: float = _ramp * streak_strength
	var show: bool = live and amount > streak_floor
	_streaks.visible = show
	if not show:
		return
	var mat := _streaks.material as ShaderMaterial
	if mat != null:
		mat.set_shader_parameter("amount", amount)


func _write_hud() -> void:
	if _meter != null:
		_meter.anchor_right = clampf(_ramp, 0.0, 1.0)
	if _readout == null:
		return
	# On foot the readout is MEASURED off the body rather than read off the ramp:
	# the ramp is what was asked for and the velocity is what the world allowed,
	# and on a hill or against a wall those are not the same number.
	var speed: float = 0.0
	if _freecam != null and _freecam.active:
		speed = lerpf(_base_fly, fly_top_speed, _ramp)
	elif _player != null:
		speed = Vector2(_player.velocity.x, _player.velocity.z).length()
	_readout.text = "%3d m/s" % int(round(speed))
	_readout.modulate = UiStyle.GOLD if _engaged else UiStyle.TEXT_DIM
