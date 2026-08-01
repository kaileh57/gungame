class_name AshFlatsCourse
extends Node
## THE ASH LINE's clock. Four gates down the main drag: the first arms it, the two
## in the middle take a split, the last stops it.
##
## This is the only thing in the demo that keeps score, and it keeps it about
## MOVEMENT — the run time, the split, and the fastest you were going while you did
## it. That is the whole reason the course exists: a gap you can clear is a fact, a
## gap you can clear *without losing the line* is the skill.
##
## COST. One gate is armed at a time, so a tick is two distance tests — the armed
## gate and the start, the second so that running back through the start line
## re-arms the run without a menu. No areas, no bodies, no signals from the physics
## server. The reference used a screen-space stopwatch; the project's rule is that a
## number you can read is a thing you can walk up to, so it is painted on the yard
## board and nowhere else.

## A gate was crossed. `index` is its position in `gate_names`, `seconds` the run
## clock at the moment of crossing.
signal gate_passed(index: int, gate_name: String, seconds: float)
## The last gate was crossed. `improved` is true when this beat the standing best.
signal finished(seconds: float, improved: bool)
## The clock started, either from a fresh crossing of the start gate or a reset.
signal armed

## How the gate name plates are shown. The dial on the yard board writes this.
enum Lamps { OFF, NEXT, ALL }

## A run this long has been abandoned; the clock stands itself down rather than
## counting into the minutes while somebody sightsees.
const MAX_RUN: float = 240.0
## Vertical slack on a gate, metres. Generous, because the crest gate is crossed by
## somebody who may be a stride above the deck and still travelling.
const HEIGHT_SLACK: float = 5.0

@export var gate_names: PackedStringArray = PackedStringArray()
@export var gate_positions: PackedVector3Array = PackedVector3Array()
@export_range(1.0, 20.0, 0.1) var gate_radius: float = 4.6
## The node holding one child per gate, each with a `Name` label. Optional — the
## clock runs without any signage at all.
@export var gates_path: NodePath = NodePath("../Gates")

## Seconds on the current run, or the time of the last completed one.
var elapsed: float = 0.0
var running: bool = false
## Best completed run, seconds. Zero until one is finished.
var best: float = 0.0
var last: float = 0.0
## Fastest planar speed seen during the current run, m/s.
var top_speed: float = 0.0
var last_top_speed: float = 0.0
## Index of the gate the clock is waiting for.
var next_gate: int = 0
var clock_enabled: bool = true
var lamp_mode: int = Lamps.NEXT

var _player: PlayerController = null
var _gates: Node = null
var _splits: PackedFloat32Array = PackedFloat32Array()


func _ready() -> void:
	_gates = get_node_or_null(gates_path)
	set_physics_process(false)


func _physics_process(delta: float) -> void:
	var p: Vector3 = _player.global_position
	if running:
		elapsed += delta
		top_speed = maxf(top_speed, _player.speed)
		if elapsed > MAX_RUN:
			reset_run()
			return
		# Re-crossing the start line while a run is live restarts it. Without this the
		# only way to take a second attempt is to finish the first one.
		if next_gate > 1 and _at(0, p):
			_start()
			return
	elif not _at(0, p):
		return
	elif next_gate == 0:
		_start()
		return
	if not _at(next_gate, p):
		return
	var index: int = next_gate
	gate_passed.emit(index, gate_names[index], elapsed)
	_splits.push_back(elapsed)
	next_gate += 1
	if next_gate < gate_positions.size():
		_show_lamps()
		return
	running = false
	last = elapsed
	last_top_speed = top_speed
	var improved: bool = best <= 0.0 or elapsed < best
	if improved:
		best = elapsed
	next_gate = 0
	_show_lamps()
	finished.emit(elapsed, improved)


## Give the course the body it watches and start it. Until this is called it costs
## nothing at all.
func watch(player: PlayerController) -> void:
	_player = player
	set_physics_process(player != null and clock_enabled and gate_positions.size() >= 2)
	_show_lamps()


func set_clock_enabled(value: bool) -> void:
	clock_enabled = value
	if not value:
		running = false
		next_gate = 0
		elapsed = 0.0
	set_physics_process(_player != null and value and gate_positions.size() >= 2)
	_show_lamps()


func set_lamp_mode(mode: int) -> void:
	lamp_mode = clampi(mode, Lamps.OFF, Lamps.ALL)
	_show_lamps()


## Splits taken so far on the live run, or on the last completed one.
func splits() -> PackedFloat32Array:
	return _splits


## Name of the gate the clock is waiting for.
func next_gate_name() -> String:
	if next_gate < 0 or next_gate >= gate_names.size():
		return ""
	return gate_names[next_gate]


## Fraction of the course crossed, 0..1.
func progress() -> float:
	if gate_positions.size() < 2:
		return 0.0
	return clampf(float(next_gate) / float(gate_positions.size() - 1), 0.0, 1.0)


func reset_run() -> void:
	running = false
	elapsed = 0.0
	top_speed = 0.0
	next_gate = 0
	_splits.clear()
	_show_lamps()


func _start() -> void:
	running = true
	elapsed = 0.0
	top_speed = 0.0
	next_gate = 1
	_splits.clear()
	_show_lamps()
	armed.emit()


func _at(index: int, p: Vector3) -> bool:
	var g: Vector3 = gate_positions[index]
	if absf(p.y - g.y) >= HEIGHT_SLACK:
		return false
	var dx: float = p.x - g.x
	var dz: float = p.z - g.z
	return dx * dx + dz * dz < gate_radius * gate_radius


## Show the gate plates the dial asked for. Called only when something changed, so
## the per-frame cost of the signage is zero.
func _show_lamps() -> void:
	if _gates == null:
		return
	var children: Array[Node] = _gates.get_children()
	for i: int in children.size():
		var label: Node = children[i].get_node_or_null(^"Name")
		if label == null:
			continue
		var on: bool = lamp_mode == Lamps.ALL
		if lamp_mode == Lamps.NEXT:
			on = i == next_gate or (not running and i == 0)
		(label as Node3D).visible = on
