class_name RunTimer
extends Node
## The speed loop's clock. Gates fire in order; each one writes its split onto its
## own post and the finish writes the lap.
##
## There is no screen. Every number this produces lands on a physical board at the
## gate that produced it, which is the only place you can read it from anyway —
## you are running past at eight metres a second. The one exception is the LAP, which
## also goes to `MovementScoreboard` beside the start line, because a best time is the
## one number you want to see when you are standing still deciding what to change.
##
## Time is measured with `Time.get_ticks_usec` rather than accumulated deltas, so
## the slow-motion lever scales the world without lying about the lap.
##
## IT ALSO POINTS AT THE NEXT GATE. Five identical arches over sixty metres of yard is a
## loop nobody can follow, so exactly one gate is lit at a time and it is the one you
## want. Passing the gate you were pointed at advances the marker; passing one out of
## order leaves it where it was, which is the honest answer — you still have to go there.
## `SplitGate.set_next` owns what "lit" looks like.

## A gate other than the start was passed. `split` is seconds since the start line.
signal split_taken(index: int, split: float)
## The lap closed. `lap` is the total; `best` is the best lap so far.
signal lap_finished(lap: float, best: float)
## The start line was crossed and a new attempt began.
signal run_started
## The gate the course is pointing at changed. Carries the gate's `gate_index`.
signal next_gate_changed(index: int)

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
## Position in `_gates`, not a `gate_index`. The two agree on this course and the
## distinction still matters, because nothing here should assume they do.
var _next_slot: int = 0


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
	_point_at(0)


## Best lap in seconds, or 0 when nothing has been completed.
func best_lap() -> float:
	return _best_lap


## `gate_index` of the gate the course is currently pointing at, or -1 with no gates.
func next_gate() -> int:
	if _gates.is_empty():
		return -1
	return _gates[_next_slot].gate_index


## Throw away the best time and blank every board.
func clear_best() -> void:
	_best_lap = 0.0
	_best_splits.fill(0.0)
	_running = false
	for gate: SplitGate in _gates:
		gate.set_board(idle_text)
		gate.arm()
	_point_at(0)


## `m:ss.hh`, the one place this project formats a lap. `MovementScoreboard` writes the
## same clock onto the holograms through here, so a rival's time and yours cannot end up
## in two different formats on two boards four metres apart.
static func clock(seconds: float) -> String:
	return "%d:%05.2f" % [int(seconds) / 60, fmod(seconds, 60.0)]


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
		_close_or_restart(elapsed, gate)
		return
	gate.play_pass()
	if not _running:
		# A split with no start behind it is someone wandering the course. Say so
		# rather than showing a number measured from an arbitrary zero.
		gate.set_board("NO RUN")
		_advance(index)
		return
	_splits[index] = elapsed
	split_taken.emit(index, elapsed)
	gate.set_board(_split_line(index, elapsed))
	_advance(index)


## The start gate is also the finish. Crossing it closes a live lap that is old
## enough to be real, and in every other case starts a fresh one.
func _close_or_restart(elapsed: float, start: SplitGate) -> void:
	if _running and elapsed >= minimum_lap and elapsed <= run_expiry:
		var improved: bool = _best_lap <= 0.0 or elapsed < _best_lap
		if improved:
			_best_lap = elapsed
			for i: int in _splits.size():
				_best_splits[i] = _splits[i]
		start.play_lap()
		lap_finished.emit(elapsed, _best_lap)
		start.set_board("%s  BEST %s" % [_clock(elapsed), _clock(_best_lap)])
		_running = false
		# Back to the start line: the lap is closed and the way to open another one is
		# to come through here again.
		_point_at(0)
		return
	_start_usec = Time.get_ticks_usec()
	_running = true
	_splits.fill(0.0)
	start.play_pass()
	start.set_board("RUNNING  BEST %s" % _clock(_best_lap))
	run_started.emit()
	_point_at(1)


## Move the marker on, but only if the gate that fired is the one it was pointing at.
func _advance(index: int) -> void:
	if _gates.is_empty() or index != _gates[_next_slot].gate_index:
		return
	_point_at(_next_slot + 1)


func _point_at(slot: int) -> void:
	if _gates.is_empty():
		return
	_next_slot = posmod(slot, _gates.size())
	var want: int = _gates[_next_slot].gate_index
	for gate: SplitGate in _gates:
		gate.set_next(gate.gate_index == want)
	next_gate_changed.emit(want)


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
	return clock(seconds)
