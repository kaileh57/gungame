class_name MovementConsole
extends Node3D
## The tuning bank at the centre of the playground: six desks of shot-operated
## sliders wired straight onto the live `PlayerController`, a master dial of
## presets, a slow-motion lever, and a screen that reports what the body is
## actually doing.
##
## Nothing is built here. `build_movement.gd` welds the desks and stencils every
## label; this only finds them and connects them, matching each control's
## `control_id` to a `MovementTuning` row. A slider whose id names no row is a
## loud error, because a silently dead knob on a tuning rig is worse than none.
##
## Writing an `@export` on the controller is enough for almost everything — it
## reads its own properties every tick. Two are copied into helper resources at
## `_ready` and would otherwise go stale, so they are mirrored here; see
## `_mirror_derived`.
##
## THE BENCH IS SHARED. In a session every knob on it is replicated and anybody may turn
## anything, which is what makes it a tuning table rather than four separate benches.
## The split that makes that work is `knob_actuated` versus `tuning_changed`:
## `knob_actuated` fires ONLY when a physical control on this machine was operated, and
## `MovementLink` puts that on the wire; `receive()` is the other end and deliberately
## does not fire it, so there is no echo to break. Everything a remote turn touches —
## the property, the knob position, the readout — moves exactly as it does locally, and
## the control flashes, because a dial that moves on its own with no acknowledgement
## reads as a bug rather than as somebody else's hand.

## Emitted after any knob, preset or reset changes the controller.
signal tuning_changed(prop: StringName, value: float)
## Emitted when a control ON THIS MACHINE was operated. Never fired for a value that
## arrived over the wire. This is the signal that goes on the wire.
signal knob_actuated(id: StringName, value: float)

## Ids of the three controls that are not sliders. `MovementTuning` owns them so
## the builder can name them without loading this file.
const ID_PRESET: StringName = MovementTuning.ID_PRESET
const ID_SLOWMO: StringName = MovementTuning.ID_SLOWMO
const ID_RESET: StringName = MovementTuning.ID_RESET

## `Engine.time_scale` while the slow-motion lever is thrown. Slow enough to read
## a jump arc frame by frame, fast enough that walking to the next station is not
## a punishment.
const SLOW_SCALE: float = 0.32

@export var player_path: NodePath = NodePath()
@export var readout_path: NodePath = NodePath()
## Screen refresh rate. The readout re-renders its SubViewport once per update, so
## this is a real cost and it is deliberately low.
@export_range(1.0, 30.0, 0.5) var readout_hz: float = 8.0
## Speed the readout's speed bar treats as full scale.
@export_range(4.0, 40.0, 0.5) var speed_bar_full: float = 20.0

var _player: PlayerController = null
var _readout: DiegeticReadout = null
var _preset: DiegeticDial = null
var _slowmo: DiegeticLever = null
var _reset: DiegeticControl = null
var _sliders: Dictionary = {}
## Property values as the controller was baked, captured before anything is
## written. "REFERENCE" means exactly this. Keyed by control id.
var _defaults: Dictionary = {}
## Control id -> `MovementTuning` row, so a slider or a preset key resolves to the
## host object and property behind it in one lookup.
var _rows: Dictionary = {}
var _since_refresh: float = 0.0
## Peak planar speed since the last reset, and the deepest fall survived.
var _peak_speed: float = 0.0
var _last_fall: float = 0.0
var _last_vault: float = 0.0
var _last_air: float = 0.0
var _air_running: float = 0.0
## The jump ruler. The bench's whole reason for existing is that you can feel the
## difference between a run-jump and a slide-jump; this is so you can also read it.
## Armed on `jumped`, closed on `landed`, and kept separately for the two kinds so
## the screen can show them side by side instead of one replacing the other.
var _jump_from: Vector3 = Vector3.ZERO
var _jump_open: bool = false
var _jump_slid: bool = false
var _run_jump: float = 0.0
var _slide_jump: float = 0.0


func _ready() -> void:
	_player = get_node_or_null(player_path) as PlayerController
	if _player == null:
		push_error("MovementConsole: player_path does not resolve to a PlayerController.")
		return
	_readout = get_node_or_null(readout_path) as DiegeticReadout
	_capture_defaults()
	# One sweep of the whole subtree: the desks hang under this node, so walking
	# them separately as well would bind every slider twice.
	_collect_controls(self)
	_check_coverage()
	_push_all_to_sliders()
	_connect_player()
	_refresh_readout()


func _process(delta: float) -> void:
	if _player == null:
		return
	_peak_speed = maxf(_peak_speed, _player.speed)
	if _player.grounded:
		_air_running = 0.0
	else:
		_air_running += delta
		_last_air = maxf(_last_air, _air_running)
	_since_refresh += delta
	if _since_refresh < 1.0 / maxf(readout_hz, 1.0):
		return
	_since_refresh = 0.0
	_refresh_readout()


func _exit_tree() -> void:
	# The lever writes a global. Leaving it thrown would follow the player back to
	# the menu and into the next demo.
	Engine.time_scale = 1.0


## Write one knob by its control id and echo it onto its slider. Public so the preset
## dial, the reset lever and a future scripted sweep all go through one door.
func apply(id: StringName, value: float, echo: bool = true) -> void:
	if _player == null:
		return
	if _rows.has(id):
		var row: Dictionary = _rows[id]
		var host: Object = MovementTuning.host_of(_player, row)
		if host == null:
			return
		host.set(row[MovementTuning.KEY_PROP], value)
	elif _player.get(id) != null:
		# A preset reaching past the desks, `terminal_velocity` being the one that does.
		_player.set(id, value)
	else:
		return
	_mirror_derived(id, value)
	if echo and _sliders.has(id):
		(_sliders[id] as DiegeticSlider).set_value(value, false)
	tuning_changed.emit(id, value)


## Restore every row to the value the controller was baked with.
func reset_to_reference() -> void:
	for id: StringName in _defaults:
		apply(id, float(_defaults[id]))
	_clear_measurements()


## Apply preset `index` from `MovementTuning`: reference first, then its overrides,
## so a preset never inherits the last one's leftovers.
func apply_preset(index: int) -> void:
	reset_to_reference()
	var over: Dictionary = MovementTuning.preset(index)
	for id: StringName in over:
		apply(id, float(over[id]))


## Apply a knob somebody else turned. Identical to operating it here, except that it
## does not go back on the wire. The control is moved to match and flashed when the value
## really changed, so a knob turning under your nose is legible as a hand and not a
## glitch.
func receive(id: StringName, value: float) -> void:
	if _player == null:
		return
	if id == ID_PRESET:
		var index: int = int(round(value))
		apply_preset(index)
		if _preset != null:
			_preset.set_value(float(index), false)
			_preset.flash()
		return
	if id == ID_RESET:
		reset_to_reference()
		if _preset != null:
			_preset.set_value(0.0, false)
		if _reset != null:
			_reset.flash()
		return
	if id == ID_SLOWMO:
		_set_slow(value > 0.5)
		if _slowmo != null:
			_slowmo.set_on(value > 0.5, false)
			_slowmo.flash()
		return
	var before: float = _value_of(id)
	apply(id, value)
	if not is_equal_approx(before, _value_of(id)) and _sliders.has(id):
		(_sliders[id] as DiegeticSlider).flash()


## Every replicated value on this bench, in APPLY ORDER. The preset is first on purpose:
## selecting one resets everything under it, so a snapshot that applied it last would
## wipe the very numbers it was sent to carry.
func snapshot() -> Dictionary:
	var ids := PackedStringArray()
	var values := PackedFloat32Array()
	ids.append(String(ID_PRESET))
	values.append(float(_preset.selected_index()) if _preset != null else 0.0)
	for id: StringName in _defaults:
		ids.append(String(id))
		values.append(_value_of(id))
	ids.append(String(ID_SLOWMO))
	values.append(1.0 if _slowmo != null and _slowmo.is_on() else 0.0)
	return {&"ids": ids, &"values": values}


## Peak speed, deepest fall, longest hang, last vault rise and the two jump rulers,
## cleared by a reset or by the dial. The signs on the course tell you the distances;
## this tells you what you did with them.
func measurements() -> Dictionary:
	return {
		&"peak_speed": _peak_speed,
		&"last_fall": _last_fall,
		&"last_vault": _last_vault,
		&"last_air": _last_air,
		&"run_jump": _run_jump,
		&"slide_jump": _slide_jump,
	}


# --- wiring -----------------------------------------------------------------


## Every row's value as the scene was baked, keyed by control id.
func _capture_defaults() -> void:
	_rows = MovementTuning.by_id()
	for id: StringName in _rows:
		var row: Dictionary = _rows[id]
		var host: Object = MovementTuning.host_of(_player, row)
		if host == null:
			push_error("MovementConsole: row '%s' has no host object." % id)
			continue
		_defaults[id] = float(host.get(row[MovementTuning.KEY_PROP]))
	# Presets reach past the desks; those properties need a reference value too or
	# leaving a preset would strand them.
	for i: int in range(1, MovementTuning.PRESET_NAMES.size()):
		for id: StringName in MovementTuning.preset(i):
			if not _defaults.has(id) and _player.get(id) != null:
				_defaults[id] = float(_player.get(id))


func _collect_controls(root: Node) -> void:
	if root == null:
		return
	for child: Node in root.get_children():
		var control := child as DiegeticControl
		if control != null:
			_bind_control(control)
		_collect_controls(child)


func _bind_control(control: DiegeticControl) -> void:
	var id: StringName = control.control_id
	if id == ID_PRESET:
		_preset = control as DiegeticDial
		if _preset != null:
			_preset.option_selected.connect(_on_preset_selected)
		return
	if id == ID_SLOWMO:
		_slowmo = control as DiegeticLever
		if _slowmo != null:
			_slowmo.toggled.connect(_on_slowmo)
		return
	if id == ID_RESET:
		_reset = control
		control.pressed.connect(_on_reset)
		return
	var slider := control as DiegeticSlider
	if slider == null:
		return
	if not _defaults.has(id):
		push_error("MovementConsole: slider '%s' names no MovementTuning row." % id)
		return
	_sliders[id] = slider
	slider.value_changed.connect(_on_slider_changed.bind(id))


func _check_coverage() -> void:
	for id: StringName in _rows:
		if not _sliders.has(id):
			push_error("MovementConsole: no slider was built for '%s'." % id)


func _push_all_to_sliders() -> void:
	for id: StringName in _sliders:
		(_sliders[id] as DiegeticSlider).set_value(float(_defaults[id]), false)


func _connect_player() -> void:
	_player.landed.connect(_on_landed)
	_player.mantle_started.connect(_on_mantle)
	_player.jumped.connect(_on_jumped)


## `PlayerController._ready` copies three of its own exports into `PlayerMantle`,
## which then owns them. Turning the STEP or CROUCH H knob has to update both, or
## the vault keeps planning against the height the body had at load.
func _mirror_derived(id: StringName, value: float) -> void:
	var mantle: PlayerMantle = _player.get(&"_mantle") as PlayerMantle
	if mantle == null:
		return
	match id:
		&"step_height":
			mantle.step_height = value
		&"crouch_height":
			mantle.clear_height = value + 0.06
		_:
			pass


# --- handlers ---------------------------------------------------------------


## The four handlers below are the ONLY places a local hand reaches the bench: every one
## of them is wired to a signal a physical control emits on actuation, and none of them
## can be reached from `set_value(v, false)`, which is what `apply()` and `receive()` use.
## That is why emitting `knob_actuated` here cannot loop back through the wire.
func _on_slider_changed(value: float, id: StringName) -> void:
	apply(id, value, false)
	knob_actuated.emit(id, value)


func _on_preset_selected(index: int, _text: String) -> void:
	apply_preset(index)
	knob_actuated.emit(ID_PRESET, float(index))


func _on_reset() -> void:
	reset_to_reference()
	if _preset != null:
		_preset.set_value(0.0, false)
	knob_actuated.emit(ID_RESET, 0.0)


func _on_slowmo(on: bool) -> void:
	_set_slow(on)
	knob_actuated.emit(ID_SLOWMO, 1.0 if on else 0.0)


func _set_slow(on: bool) -> void:
	Engine.time_scale = SLOW_SCALE if on else 1.0


## What a knob currently reads, straight off the object that owns it rather than out of a
## cache. Rows live on the controller or on `PlayerSlide`; a preset-only property such as
## `terminal_velocity` lives on the controller and has no row at all.
func _value_of(id: StringName) -> float:
	if _player == null:
		return 0.0
	if _rows.has(id):
		var row: Dictionary = _rows[id]
		var host: Object = MovementTuning.host_of(_player, row)
		return 0.0 if host == null else float(host.get(row[MovementTuning.KEY_PROP]))
	var raw: Variant = _player.get(id)
	return 0.0 if raw == null else float(raw)


func _on_landed(_surface: int, _impact: float, fall_height: float) -> void:
	_last_fall = maxf(_last_fall, fall_height)
	if not _jump_open:
		return
	_jump_open = false
	var to: Vector3 = _player.global_position
	var span: float = Vector2(to.x - _jump_from.x, to.z - _jump_from.z).length()
	if _jump_slid:
		_slide_jump = span
	else:
		_run_jump = span


## Armed on the tick the feet leave. `jumped_from_slide` lives on `PlayerSlide` and is
## still true here — the controller clears it on the landing that closes the arc.
func _on_jumped() -> void:
	_jump_from = _player.global_position
	_jump_slid = _player.slide.from_slide
	_jump_open = true


func _on_mantle(rise: float) -> void:
	_last_vault = rise


func _clear_measurements() -> void:
	_peak_speed = 0.0
	_last_fall = 0.0
	_last_vault = 0.0
	_last_air = 0.0
	_air_running = 0.0
	_run_jump = 0.0
	_slide_jump = 0.0
	_jump_open = false


# --- screen -----------------------------------------------------------------


func _refresh_readout() -> void:
	if _readout == null or _player == null:
		return
	var state: PlayerState = _player.state
	_readout.set_title(_preset_title())
	(
		_readout
		. set_lines(
			PackedStringArray(
				[
					"%s   %5.2f m/s" % [_state_name(state), _player.speed],
					"peak %5.2f   hang %4.2f s" % [_peak_speed, _last_air],
					"jump  run %5.2f   slide %5.2f m" % [_run_jump, _slide_jump],
					"vault %4.2f m   fall %5.2f m" % [_last_vault, _last_fall],
					(
						"feet %6.2f m   slope %4.1f deg"
						% [_player.global_position.y, _slope_degrees()]
					),
				]
			)
		)
	)
	_readout.set_bars(
		PackedStringArray(["SPEED", "STAMINA"]),
		PackedFloat32Array(
			[clampf(_player.speed / maxf(speed_bar_full, 0.1), 0.0, 1.0), _player.stamina * 0.01]
		),
		PackedColorArray([UiStyle.ACCENT, UiStyle.GOOD])
	)


func _preset_title() -> String:
	if _preset == null:
		return "MOVEMENT BENCH"
	return "BENCH — %s" % _preset.selected_text()


func _slope_degrees() -> float:
	return rad_to_deg(acos(clampf(_player.ground_normal.y, -1.0, 1.0)))


## `PlayerState` already owns the names; padding them keeps the columns on the
## screen from jumping every time the state changes.
func _state_name(state: PlayerState) -> String:
	return state.name().rpad(6)
