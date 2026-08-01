class_name AshFlatsPad
extends Node3D
## An extraction pad: the painted ring the town bake already laid down, plus the
## gauge bolted to the post beside it.
##
## The reference held the timer in a screen-space SVG arc. The project's rule is
## that a control you can read is a thing you can walk up to, so the charge lives
## on a `DiegeticReadout` — a real panel on a real post, lit by its own tube,
## which you can see filling from across the plaza and cannot see at all with your
## back to it. That is the correct trade.
##
## The trigger is a distance test, not an `Area3D`. There are three pads in a
## three-hundred-metre town and the test is two subtractions and a compare; a
## monitoring area would cost the physics server more than this costs GDScript,
## and it would answer the wrong question — the reference's rule is a cylinder
## with a generous vertical slack, which is not a shape an area gives you for free.

## The hold reached full and the run ended. `seconds` is time on the ground.
signal extracted(pad_name: String, seconds: float)
## Hold fraction changed, 0..1. Fires only while somebody is on the pad or
## bleeding off one, so a cold pad is silent.
signal hold_changed(fraction: float)
## The player stepped onto or off the pad.
signal occupancy_changed(occupied: bool)

## Seconds of unbroken standing that extracts you. The reference's number.
const HOLD_SECONDS: float = 6.0
## Multiple of real time the charge bleeds off at once you leave. 2.2 gives you
## about 2.7 seconds of grace to duck behind the post and come back.
const DECAY_RATE: float = 2.2
## Vertical slack on the trigger, metres. A rooftop pad has to catch somebody who
## just mantled onto it and is still a stride above the deck.
const HEIGHT_SLACK: float = 3.2
## Seconds the pad holds its finished state before it re-arms.
const RESET_SECONDS: float = 2.6

## Shown on the gauge and emitted with `extracted`.
@export var pad_name: String = "CULVERT"
## Trigger and painted-ring radius, metres. The town bake paints 4.6.
@export_range(1.0, 20.0, 0.1) var radius: float = 4.6
## Gauge to drive. Optional — a pad with no panel still extracts.
@export var readout_path: NodePath = NodePath("Gauge")
## Smallest change in the hold fraction that redraws the gauge. The panel is a
## render target, so this is the difference between a repaint every frame and
## about twenty over the whole six seconds.
@export_range(0.005, 0.5, 0.005) var readout_step: float = 0.05

var held: float = 0.0
var occupied: bool = false

var _player: Node3D = null
var _readout: DiegeticReadout = null
var _drawn: float = -1.0
var _armed: bool = true
var _reset_timer: float = 0.0
var _run_clock: float = 0.0


func _ready() -> void:
	_readout = get_node_or_null(readout_path) as DiegeticReadout
	set_physics_process(false)


func _physics_process(delta: float) -> void:
	_run_clock += delta
	if not _armed:
		_reset_timer -= delta
		if _reset_timer <= 0.0:
			_armed = true
			held = 0.0
			_paint(0.0, "STAND BY")
		return
	var inside: bool = _contains(_player.global_position)
	if inside != occupied:
		occupied = inside
		occupancy_changed.emit(inside)
	if inside:
		held = minf(HOLD_SECONDS, held + delta)
		if held >= HOLD_SECONDS:
			_finish()
			return
	else:
		if held <= 0.0:
			return
		held = maxf(0.0, held - delta * DECAY_RATE)
	var fraction: float = held / HOLD_SECONDS
	hold_changed.emit(fraction)
	_paint(fraction, "HOLD POSITION" if inside else "CHARGE BLEEDING")


## Give the pad the body it watches and start it. Until this is called the pad
## costs nothing at all.
func watch(player: Node3D) -> void:
	_player = player
	set_physics_process(player != null)
	if player != null:
		_paint(0.0, "STAND BY")


## Seconds the player has been on the ground since the last extraction.
func run_seconds() -> float:
	return _run_clock


func reset_run() -> void:
	_run_clock = 0.0


func _contains(p: Vector3) -> bool:
	if absf(p.y - global_position.y) >= HEIGHT_SLACK:
		return false
	var dx: float = p.x - global_position.x
	var dz: float = p.z - global_position.z
	return dx * dx + dz * dz < radius * radius


func _finish() -> void:
	_armed = false
	occupied = false
	_reset_timer = RESET_SECONDS
	hold_changed.emit(1.0)
	_paint(1.0, "LIFT INBOUND")
	extracted.emit(pad_name, _run_clock)
	_run_clock = 0.0


func _paint(fraction: float, line: String) -> void:
	if _readout == null:
		return
	if _drawn >= 0.0 and absf(fraction - _drawn) < readout_step and fraction < 1.0:
		return
	_drawn = fraction
	_readout.set_title(pad_name)
	_readout.set_lines(PackedStringArray([line]))
	_readout.set_bars(
		PackedStringArray(["CHARGE"]),
		PackedFloat32Array([fraction]),
		PackedColorArray([WorldPalette.EXFIL])
	)
