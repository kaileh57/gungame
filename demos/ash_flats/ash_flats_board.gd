class_name AshFlatsBoard
extends Node3D
## THE STANDINGS BOARD. A stencilled steel board on two legs at the head of the line,
## angled at whoever is stood on it, carrying the result of the last race and the order
## of the one that is running.
##
## IT IS A BOARD, NOT A PANEL. There is no screen-space scoreboard in this demo and there
## is not going to be: the project's rule is that a number you can read is a thing you can
## walk up to. That rule costs something here and it is worth naming — you cannot check
## the standings from the bottom of the line, you have to come back up. That is the
## trade, and the cross-map marks are what make it survivable, because knowing WHERE
## everyone is turns out to matter more mid-race than knowing what order they are in.
##
## WHY LABELS AND NOT A `DiegeticReadout`. The readout is a 512x320 render target through
## a CRT shader and it is the right answer for the yard board's own clock. It is the
## wrong answer here for two reasons: a row has to be in ITS PLAYER'S COLOUR, which is the
## whole reason four names read apart at a glance, and a canvas draws one accent for the
## lot; and this board has to be legible from the start line, which is fifteen metres of
## dust away and past the width at which a 512-wide tube stays sharp. Stencilled type on
## steel scales; a render target does not.
##
## Each row is three labels at fixed offsets rather than one padded string, because the
## display font is proportional — `%-12s` aligns nothing, and a column of times that does
## not line up reads as broken even when every number in it is right.
##
## PURELY A DISPLAY. It reads `AshFlatsRace.standings()` and paints it. It decides
## nothing, and on a client it is exactly as correct as on the host because every number
## in a row arrived from the host.

## Node names inside the baked scene.
const HEAD_NODE: NodePath = ^"Head"
const STATUS_NODE: NodePath = ^"Status"
const ROWS_NODE: NodePath = ^"Rows"

## Seconds between repaints of the LIVE clock. The order itself repaints on the signal;
## this is only the running number, and five times a second is a readable clock.
const TICK: float = 0.2
## What an empty row says. A board with three blank lines reads as broken; a board that
## says the slot is open reads as a board.
const EMPTY: String = "--"

var _head: Label3D = null
var _status: Label3D = null
var _rows: Array[Node3D] = []
var _race: AshFlatsRace = null
var _clock: float = 0.0


func _ready() -> void:
	_head = get_node_or_null(HEAD_NODE) as Label3D
	_status = get_node_or_null(STATUS_NODE) as Label3D
	var root: Node = get_node_or_null(ROWS_NODE)
	if root != null:
		for child: Node in root.get_children():
			var row := child as Node3D
			if row != null:
				_rows.append(row)
	set_process(false)


func _process(delta: float) -> void:
	_clock -= delta
	if _clock > 0.0:
		return
	_clock = TICK
	_repaint()


## Give the board the race it reports. Until this is called it costs nothing at all.
func watch(race: AshFlatsRace) -> void:
	_race = race
	set_process(race != null and not _rows.is_empty())
	if race == null:
		return
	race.standings_changed.connect(_repaint)
	race.state_changed.connect(_on_state_changed)
	if _head != null:
		_head.text = "ASH LINE"
	_repaint()


func _repaint() -> void:
	if _race == null:
		return
	if _status != null:
		_status.text = _race.status_text()
	var rows: Array = _race.standings()
	for i: int in _rows.size():
		if i < rows.size():
			_write_row(_rows[i], i + 1, rows[i])
		else:
			_blank_row(_rows[i])


## One player's line. The place number is the RACE's place while a race is on and the
## board's own ranking otherwise, which is the distinction between "you came third" and
## "you are third on this board".
func _write_row(row: Node3D, rank: int, entry: Dictionary) -> void:
	row.visible = true
	var color: Color = NetColors.text(Color(entry[&"color"]))
	var place: int = int(entry[&"place"])
	_write_cell(row, ^"Place", "%d" % (place if place > 0 else rank), color)
	_write_cell(row, ^"Name", String(entry[&"name"]), color)
	_write_cell(row, ^"Time", _time_text(entry), color)


func _blank_row(row: Node3D) -> void:
	row.visible = false


## What goes in the right-hand column, and it changes with the phase because the useful
## number does: mid-race it is where they are, afterwards it is what they did.
func _time_text(entry: Dictionary) -> String:
	var racing: bool = bool(entry[&"racing"])
	var finished: bool = bool(entry[&"finished"])
	var seconds: float = float(entry[&"time"])
	if racing and finished:
		return "%6.2f" % seconds if seconds > 0.0 else "DNF"
	if racing and _race.state == AshFlatsRace.State.RUNNING:
		var gate: String = _race.next_checkpoint_name(int(entry[&"id"]))
		return gate if not gate.is_empty() else EMPTY
	var best: float = float(entry[&"best"])
	return "%6.2f" % best if best > 0.0 else EMPTY


func _write_cell(row: Node3D, path: NodePath, text: String, color: Color) -> void:
	var label := row.get_node_or_null(path) as Label3D
	if label == null:
		return
	label.text = text
	label.modulate = Color(color.r, color.g, color.b, label.modulate.a)


func _on_state_changed(_state: int) -> void:
	_repaint()
