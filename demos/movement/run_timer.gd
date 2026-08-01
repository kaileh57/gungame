class_name RunTimer
extends Node
## The speed loop's clock. Gates fire in order; each one writes its split onto its
## own post and the finish writes the lap.
##
## There is no screen. Every number this produces lands on a physical board at the
## gate that produced it, which is the only place you can read it from anyway —
## you are running past at eight metres a second.
##
## Time is measured with `Time.get_ticks_usec` rather than accumulated deltas, so
## the slow-motion lever scales the world without lying about the lap.

## A gate other than the start was passed. `split` is seconds since the start line.
signal split_taken(index: int, split: float)
## The lap closed. `lap` is the total; `best` is the best lap so far.
signal lap_finished(lap: float, best: float)
## The start line was crossed and a new attempt began.
signal run_started

## Runs slower than this are ignored as a stumble back through the start line.
@export_range(0.5, 20.0, 0.1) var minimum_lap: float = 4.0
## A run this stale is abandoned; crossing the start line again restarts it rather
## than closing a lap you gave up on ten minutes ago.
@export_range(10.0, 600.0, 5.0) var run_expiry: float = 180.0
## Board text before anything has been run.
@export var idle_text: String = "- - . - -"

var _gates: Array[SplitGate] = []
var _start_usec: int = 0
var _running: bool = false
var _best_lap: float = 0.0
var _best_splits: PackedFloat32Array = PackedFloat32Array()
var _splits: PackedFloat32Array = PackedFloat32Array()


func _ready() -> void:
	_collect(get_parent())
	if _gates.size() < 2:
		push_error("RunTimer: the loop needs a start gate and at least one more.")
		return
	_gates.sort_custom(func(a: SplitGate, b: SplitGate) -> bool: return a.gate_index < b.gate_index)
	_splits.resize(_gates.size())
	_best_splits.resize(_gates.size())
	_best_splits.fill(0.0)
	for gate: SplitGate in _gates:
		gate.passed.connect(_on_gate_passed)
		gate.set_board(idle_text)


## Best lap in seconds, or 0 when nothing has been completed.
func best_lap() -> float:
	return _best_lap


## Throw away the best time and blank every board.
func clear_best() -> void:
	_best_lap = 0.0
	_best_splits.fill(0.0)
	_running = false
	for gate: SplitGate in _gates:
		gate.set_board(idle_text)
		gate.arm()


func _collect(root: Node) -> void:
	if root == null:
		return
	for child: Node in root.get_children():
		var gate := child as SplitGate
		if gate != null:
			_gates.append(gate)
		_collect(child)


func _on_gate_passed(index: int, gate: SplitGate) -> void:
	_rearm_others(gate)
	var elapsed: float = float(Time.get_ticks_usec() - _start_usec) * 1.0e-6
	if index == 0:
		_close_or_restart(elapsed)
		return
	if not _running:
		# A split with no start behind it is someone wandering the course. Say so
		# rather than showing a number measured from an arbitrary zero.
		gate.set_board("NO RUN")
		return
	_splits[index] = elapsed
	split_taken.emit(index, elapsed)
	gate.set_board(_split_line(index, elapsed))


## The start gate is also the finish. Crossing it closes a live lap that is old
## enough to be real, and in every other case starts a fresh one.
func _close_or_restart(elapsed: float) -> void:
	var start: SplitGate = _gates[0]
	if _running and elapsed >= minimum_lap and elapsed <= run_expiry:
		var improved: bool = _best_lap <= 0.0 or elapsed < _best_lap
		if improved:
			_best_lap = elapsed
			for i: int in _splits.size():
				_best_splits[i] = _splits[i]
		lap_finished.emit(elapsed, _best_lap)
		start.set_board("%s  BEST %s" % [_clock(elapsed), _clock(_best_lap)])
		_running = false
		return
	_start_usec = Time.get_ticks_usec()
	_running = true
	_splits.fill(0.0)
	start.set_board("RUNNING  BEST %s" % _clock(_best_lap))
	run_started.emit()


func _rearm_others(fired: SplitGate) -> void:
	for gate: SplitGate in _gates:
		if gate != fired:
			gate.arm()


func _split_line(index: int, elapsed: float) -> String:
	var best: float = _best_splits[index]
	if best <= 0.0:
		return _clock(elapsed)
	var delta: float = elapsed - best
	return "%s  %s%.2f" % [_clock(elapsed), "+" if delta >= 0.0 else "-", absf(delta)]


func _clock(seconds: float) -> String:
	if seconds <= 0.0:
		return idle_text
	return "%d:%05.2f" % [int(seconds) / 60, fmod(seconds, 60.0)]
