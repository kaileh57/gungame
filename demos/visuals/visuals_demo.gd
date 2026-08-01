class_name VisualsDemo
extends Node3D
## The showpiece. One scav settlement on the ash flats under a low sun, and a
## control post on the rise above it from which you can change how it looks.
##
## The demo owns no geometry. `res://tools/build_visuals.gd` bakes the pad, the
## post, the rack and every mesh under this node into `visuals.tscn`; this script
## does five things and nothing else:
##
##   - actuates the control post when you look at a control and press `interact`,
##   - applies what the post says to `GameSettings`, the sun, the lamps and the ash,
##   - writes the live frame numbers onto the post's readout four times a second,
##   - hands the viewport to the camera rig when the RIDE lever is thrown,
##   - puts the other players on the rise with you.
##
## MULTIPLAYER is one line, and deliberately only one. Everybody stands on the
## same parapet and sees each other and each other's laser dots; the post stays
## LOCAL, because the thing it mostly changes is `GameSettings`, and a quality
## preset belongs to the machine rendering it and not to the session. So four
## people can stand here and each drive their own comparison of the same view.
##
## There is no screen-space text anywhere in this scene. The quality preset, the
## frame time and the draw count are on a physical panel bolted to the post; what
## the controls do is stencilled on the controls. If you want the engine overlay,
## F3 still works, because `DebugHUD` is an autoload and this scene never touches it.
##
## The interact ray is cast once per frame from whichever camera is current, using
## one reusable query object. A control is only actuated when you are close enough
## to touch it, so the post cannot be operated from across the settlement.

## Registered with `SceneRouter` on load, because the shipped `DEMOS` table
## predates this demo. Frozen: the main menu and any bookmark use this string.
const DEMO_ID: String = "visuals"
const DEMO_TITLE: String = "THE FLATS AT DUSK"
const DEMO_BLURB: String = "Nothing to shoot. Stand on the rise and look at it."

## Control ids on the post. These are stamped onto the controls by the builder.
const ID_QUALITY: StringName = &"quality"
const ID_SUN: StringName = &"sun"
const ID_LAMPS: StringName = &"lamps"
const ID_RIDE: StringName = &"ride"
const ID_ASH: StringName = &"ash"

## Lamp meshes and lights join this group so the LAMPS lever can find them without
## a node path apiece.
const GROUP_LAMP: StringName = &"visuals_lamp"

## Milliseconds of frame time the readout's budget bar calls full. 8.33 ms is the
## 120 fps the project holds itself to, and a bar that pegs at 60 would read green
## while the game missed its target by half.
const FRAME_BUDGET_MS: float = 8.333

@export_group("Site")
## World Y of the settlement floor. The VFX hub uses it to decide where drifting
## ash settles and where a decal lies flat; the builder writes the pad's top here.
@export_range(-100.0, 200.0, 0.01) var ground_y: float = 0.0
## Where the player stands, and which way they face. Written here rather than onto
## the player node because `PlayerController` owns its own yaw — the camera reads
## that, not the body's transform — so a spawn set by moving the node leaves you
## standing in the right place looking the wrong way.
@export var player_spawn: Vector3 = Vector3.ZERO
@export_range(-6.3, 6.3, 0.001) var player_yaw: float = 0.0
## Degrees the eye is tipped at spawn. `teleport` sets the yaw and leaves the pitch
## alone, which is right for a respawn mid-fight and wrong for the one frame this
## scene is judged on: level with the horizon spends the top third of the frame on
## empty sky and pushes the settlement onto the bottom edge.
@export_range(-60.0, 60.0, 0.1) var player_pitch_degrees: float = 0.0

@export_group("Interaction")
## Metres you can reach a control from. Arm's length plus a step.
@export_range(0.5, 6.0, 0.05) var reach: float = 3.2

@export_group("Sun")
## Azimuth is fixed — it is what puts the settlement between you and the light —
## and the slider moves elevation only, between these two degrees.
@export_range(1.0, 30.0, 0.5) var sun_elevation_min: float = 3.0
@export_range(10.0, 80.0, 0.5) var sun_elevation_max: float = 46.0
## Where the slider starts. Low enough to throw the shadows the length of the pan.
@export_range(1.0, 80.0, 0.5) var sun_elevation_start: float = 12.5
## Compass bearing the sun sits on, degrees, measured the same way the baked
## `Palette.SUN_DIRECTION` is. Not on a control: moving it wrecks the composition.
@export_range(-180.0, 180.0, 0.5) var sun_azimuth_degrees: float = -130.5

@export_group("Light")
## The world scene ships a balance for a mid-afternoon sun. This one is twelve
## degrees off the horizon, where a horizontal surface receives about a fifth of
## the key — so with the shipped fill the settlement floor turns pale blue and the
## shot loses its contrast. These four numbers restore it: more key, much less
## sky, a little more warm bounce off the sand.
@export_range(0.0, 6.0, 0.01) var sun_energy: float = 2.35:
	set = _set_light
@export_range(0.0, 1.0, 0.01) var ambient_energy: float = 0.17:
	set = _set_light
@export_range(0.0, 1.0, 0.01) var sky_fill_energy: float = 0.06:
	set = _set_light
@export_range(0.0, 1.0, 0.01) var bounce_energy: float = 0.30:
	set = _set_light

@export_group("Lamps")
## Lamps are lit at load. The lever kills them, which is the interesting half of
## the comparison: it shows how much of the scene is bounce and haze.
@export var lamps_start_on: bool = true
## Fraction of a lamp's baked energy it fades to when switched off. Not zero: the
## bulbs stay warm for a beat, which is cheaper than a filament sim and reads the
## same at this distance.
@export_range(0.0, 0.5, 0.01) var lamp_off_energy: float = 0.0
@export_range(0.05, 3.0, 0.01) var lamp_fade_seconds: float = 0.55

@export_group("Ash")
## Motes in the drifting ash field when the ASH lever is on. Zero switches the
## field off outright rather than shrinking it, so it costs nothing when unused.
@export_range(0, 4000, 10) var ash_motes: int = 420
@export var ash_start_on: bool = true

@export_group("Readout")
## Refreshes per second on the post's panel. The panel re-renders its viewport on
## exactly these ticks and is free in between, so this is the whole cost.
@export_range(1.0, 20.0, 0.5) var readout_hz: float = 4.0

var _controls: Dictionary = {}
var _lamp_lights: Array[OmniLight3D] = []
var _lamp_energy: PackedFloat32Array = PackedFloat32Array()
var _lamp_on: bool = true
var _lamp_mix: float = 1.0
var _lamp_target: float = 1.0
var _sun_elevation: float = 12.5
var _readout_clock: float = 0.0
## The post's hands. Latches the press in `_unhandled_input` and casts that press's
## own ray on the next physics frame, so the click is resolved against the eye that
## made it and a press inside a control's debounce is held rather than dropped.
var _hands: DiegeticInteractor = null

@onready var _world: ScavWorldEnvironment = $World
@onready var _post: Node3D = $Post
@onready var _readout: DiegeticReadout = $Post/Readout
@onready var _rig: VisualsCameraRig = $CameraRig
@onready var _player: PlayerController = $Player
@onready var _ash: VFXAshField = get_node_or_null(^"Vfx/Ash") as VFXAshField


func _ready() -> void:
	if not SceneRouter.has_demo(DEMO_ID):
		SceneRouter.register_demo(
			DEMO_ID, DEMO_TITLE, "res://demos/visuals/visuals.tscn", DEMO_BLURB
		)
	GameSettings.register_viewport(get_viewport())
	VfxService.set_ground_y(ground_y)

	_build_hands()
	_place_player()
	_collect_controls()
	_collect_lamps()
	_paint_creatures()
	_enter_presence.call_deferred()
	_rig.riding_changed.connect(_on_riding_changed)
	GameSettings.preset_applied.connect(_on_preset_applied)

	_sun_elevation = sun_elevation_start
	_apply_light()
	_apply_sun()
	_apply_lamps(lamps_start_on, true)
	_apply_ash(ash_start_on)
	_sync_controls()
	_write_readout()


func _process(delta: float) -> void:
	# On the ride the same button means "give me the camera back", so the post must
	# not also take the press.
	_hands.enabled = not _rig.is_riding()
	_tick_lamps(delta)
	_readout_clock += delta
	var period: float = 1.0 / readout_hz
	if _readout_clock >= period:
		_readout_clock = fmod(_readout_clock, period)
		_write_readout()


## The only input this scene reads directly. The post belongs to `_hands`; what is
## left is the ride, and anything that means "I want to be somewhere else" ends it.
## Leaving a cinematic running while the player fights a camera they cannot steer is
## the one way a cinematic becomes a bug report.
func _unhandled_input(event: InputEvent) -> void:
	if not _rig.is_riding():
		return
	if event.is_action_pressed(&"interact") or event.is_action_pressed(&"fire"):
		get_viewport().set_input_as_handled()
		_set_ride(false)


## The other three, as capsules with their name over them and their laser dot on
## whatever they are pointing at. In single-player it costs nothing: the roster is
## one player long, no avatar is built, and all you get is your own dim dot.
##
## THE EYE IS NAMED, rather than left as "whatever camera is live". The RIDE lever
## hands the viewport to the camera rig for a pass along the settlement, and a
## camera on a rail is not where the player is standing — left to resolve the live
## camera, presence would walk everybody's avatar off the parapet and along the
## crane shot. The player's own eye is the one thing in this scene that always
## says where its player is.
##
## CALLED DEFERRED, AND IT HAS TO BE. `NetPresence.instance()` parents itself to
## `/root`, and `_ready` runs INSIDE the root's own `add_child` of this demo — so a
## direct call is refused with "Parent node is busy setting up children" and leaves
## the singleton orphaned, which is a settlement with nobody visible in it. One
## frame later the tree is idle and the add lands.
func _enter_presence() -> void:
	NetPresence.enter(NetPresence.FULL, _player.get_node_or_null(^"Eye") as Camera3D)


## The post's hands. Only the PROP layer, as the old probe had it, so the post
## answers from anywhere you can see it. Nothing here draws a highlight, so the
## per-frame hover ray would be a ray cast for nobody.
func _build_hands() -> void:
	_hands = DiegeticInteractor.new()
	_hands.name = "Hands"
	_hands.collision_mask = GameLayers.PROP
	_hands.interact_reach = reach
	_hands.handle_fire = false
	_hands.track_hover = false
	add_child(_hands)
	CombatReticle.mount(self).watch(_hands)


# --- wiring -----------------------------------------------------------------


func _collect_controls() -> void:
	for node: Node in _post.get_children():
		var control := node as DiegeticControl
		if control == null or control.control_id == &"":
			continue
		_controls[control.control_id] = control
	var dial := _controls.get(ID_QUALITY) as DiegeticDial
	if dial != null:
		dial.option_selected.connect(_on_quality_selected)
	var sun := _controls.get(ID_SUN) as DiegeticSlider
	if sun != null:
		sun.value_changed.connect(_on_sun_changed)
	var lamps := _controls.get(ID_LAMPS) as DiegeticLever
	if lamps != null:
		lamps.toggled.connect(_on_lamps_toggled)
	var ash := _controls.get(ID_ASH) as DiegeticLever
	if ash != null:
		ash.toggled.connect(_apply_ash)
	var ride := _controls.get(ID_RIDE) as DiegeticLever
	if ride != null:
		ride.toggled.connect(_set_ride)


## Push the live state onto the controls without firing their handlers, so the
## post reads the truth on the first frame instead of the builder's defaults.
func _sync_controls() -> void:
	var dial := _controls.get(ID_QUALITY) as DiegeticDial
	if dial != null:
		var i: int = GameSettings.PRESET_NAMES.find(GameSettings.quality_preset)
		dial.set_value(float(maxi(i, 0)), false)
	var sun := _controls.get(ID_SUN) as DiegeticSlider
	if sun != null:
		sun.set_value(_sun_elevation, false)
	var lamps := _controls.get(ID_LAMPS) as DiegeticLever
	if lamps != null:
		lamps.set_on(_lamp_on, false)
	var ash := _controls.get(ID_ASH) as DiegeticLever
	if ash != null:
		ash.set_on(ash_start_on, false)


func _on_quality_selected(_index: int, text: String) -> void:
	GameSettings.apply_preset(text)


func _on_preset_applied(preset_name: String) -> void:
	var dial := _controls.get(ID_QUALITY) as DiegeticDial
	if dial != null:
		var i: int = GameSettings.PRESET_NAMES.find(preset_name)
		if i >= 0:
			dial.set_value(float(i), false)
	if _ash != null and _ash.emitting:
		_apply_ash(true)
	_write_readout()


func _on_sun_changed(degrees: float) -> void:
	_sun_elevation = degrees
	_apply_sun()


func _on_lamps_toggled(on: bool) -> void:
	_apply_lamps(on, false)


func _on_riding_changed(riding: bool) -> void:
	_player.set_input_suspended(riding)
	var lever := _controls.get(ID_RIDE) as DiegeticLever
	if lever != null and lever.is_on() != riding:
		lever.set_on(riding, false)


func _set_ride(on: bool) -> void:
	if on:
		_rig.set_riding(true)
		return
	_rig.set_riding(false)
	# The rig does not know what it interrupted; the player's eye is the only
	# camera this scene ever hands back to.
	var eye := _player.get_node_or_null(^"Eye") as Camera3D
	if eye != null:
		eye.make_current()


# --- the knobs themselves ---------------------------------------------------


## Rebuild the sun vector from the fixed azimuth and the slider's elevation. The
## world environment owns the light, the sky disc and the fog together, so writing
## one property here moves all three and they cannot disagree.
func _apply_sun() -> void:
	var el: float = deg_to_rad(clampf(_sun_elevation, sun_elevation_min, sun_elevation_max))
	var az: float = deg_to_rad(sun_azimuth_degrees)
	var horizontal: float = cos(el)
	_world.sun_direction = Vector3(sin(az) * horizontal, sin(el), -cos(az) * horizontal)


## Live in the inspector: any of the four writes all four, because they only make
## sense as a set.
func _set_light(_value: float) -> void:
	if is_node_ready():
		_apply_light()


func _apply_light() -> void:
	_world.sun_energy = sun_energy
	_world.ambient_energy = ambient_energy
	_world.sky_fill_energy = sky_fill_energy
	_world.bounce_energy = bounce_energy


func _apply_lamps(on: bool, instant: bool) -> void:
	_lamp_on = on
	_lamp_target = 1.0 if on else lamp_off_energy
	if instant:
		_lamp_mix = _lamp_target
		_push_lamp_energy()
	set_process(true)


func _tick_lamps(delta: float) -> void:
	if is_equal_approx(_lamp_mix, _lamp_target):
		return
	var k: float = 1.0 - exp(-delta / maxf(lamp_fade_seconds, 0.001))
	_lamp_mix = lerpf(_lamp_mix, _lamp_target, k)
	if absf(_lamp_mix - _lamp_target) < 0.002:
		_lamp_mix = _lamp_target
	_push_lamp_energy()


func _push_lamp_energy() -> void:
	for i: int in _lamp_lights.size():
		var light: OmniLight3D = _lamp_lights[i]
		light.light_energy = _lamp_energy[i] * _lamp_mix
		light.visible = _lamp_mix > 0.001


## Stand the player at the parapet facing the settlement, and make that the respawn.
func _place_player() -> void:
	if player_spawn.is_zero_approx():
		return
	_player.teleport(player_spawn, player_yaw)
	_player.set_spawn(player_spawn, player_yaw)
	_player.pitch = deg_to_rad(player_pitch_degrees)


## The creatures are baked without a profile — nothing here configures a brain or
## a weapon — and a profile is what normally hands a body its faction colour. So
## the demo hands it over instead, or every one of them stands there bone white.
func _paint_creatures() -> void:
	var tint: Color = Palette.faction_color(Factions.F.SCAV)
	for node: Node in $Creatures.get_children():
		var actor := node as EnemyActor
		if actor == null:
			continue
		var body: EnemyBody = actor.body()
		if body != null:
			body.set_faction_color(tint)


func _collect_lamps() -> void:
	for node: Node in get_tree().get_nodes_in_group(GROUP_LAMP):
		var light := node as OmniLight3D
		if light == null:
			continue
		_lamp_lights.append(light)
		_lamp_energy.append(light.light_energy)


func _apply_ash(on: bool) -> void:
	if _ash == null:
		return
	# Ash is the cheapest thing on screen at Ultra and the first thing to go on a
	# Potato, so the count follows the preset the same way the VFX budget does.
	var i: int = GameSettings.PRESET_NAMES.find(GameSettings.quality_preset)
	var scale: float = [0.25, 0.45, 0.7, 1.0, 1.0][maxi(i, 0)] if i >= 0 else 1.0
	_ash.resize(int(float(ash_motes) * scale) if on else 0)


# --- the panel --------------------------------------------------------------


func _write_readout() -> void:
	var fps: float = Performance.get_monitor(Performance.TIME_FPS)
	var frame_ms: float = Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
	var draws: int = int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
	var prims: int = int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME))
	var scale_pct: int = int(round(GameSettings.render_scale * 100.0))

	_readout.set_title(GameSettings.quality_preset.to_upper())
	(
		_readout
		. set_lines(
			[
				"%3d fps   %5.2f ms" % [int(round(fps)), frame_ms],
				"%4d draws   %d k tris" % [draws, prims / 3000],
				"scale %d %%   sun %.0f deg" % [scale_pct, _sun_elevation],
			]
		)
	)
	var load_fraction: float = clampf(frame_ms / FRAME_BUDGET_MS, 0.0, 1.0)
	_readout.set_bars(
		["FRAME", "SUN"],
		[load_fraction, _sun_fraction()],
		[_budget_color(load_fraction), UiStyle.GOLD]
	)


func _sun_fraction() -> float:
	var span: float = sun_elevation_max - sun_elevation_min
	if absf(span) < 0.001:
		return 0.0
	return clampf((_sun_elevation - sun_elevation_min) / span, 0.0, 1.0)


static func _budget_color(fraction: float) -> Color:
	if fraction < 0.7:
		return UiStyle.GOOD
	if fraction < 1.0:
		return UiStyle.GOLD
	return UiStyle.WARN
