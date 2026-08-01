class_name SplitGate
extends Area3D
## One arch on the speed loop. Passing between its posts reports an index to the
## `RunTimer`; the arch itself is welded into the course mesh and only the posts
## carry collision, so the opening is genuinely open.
##
## Ordering is the gate's business, not the timer's: a gate re-arms only after a
## different gate has fired, which is what stops standing in the finish line from
## logging a lap every physics tick.

## Someone ran through. `index` is this gate's place in the loop.
signal passed(index: int, gate: SplitGate)

## Position in the loop. 0 is the start line; the highest index is the finish.
@export_range(0, 15, 1) var gate_index: int = 0
## Stencilled name, echoed onto the post's own board by `RunTimer`.
@export var gate_name: String = "SPLIT"
## Seconds this gate ignores a second body after firing. Only a backstop — the
## real guard is `arm()`.
@export_range(0.0, 4.0, 0.05) var refire_lockout: float = 0.75

var _armed: bool = true
var _last_ms: int = -100000

@onready var _board: Label3D = get_node_or_null(^"Board") as Label3D


func _ready() -> void:
	# The player's body is the only thing on PLAYER, and the arch never moves, so
	# monitorable is dead weight here.
	collision_layer = 0
	collision_mask = GameLayers.PLAYER
	monitorable = false
	body_entered.connect(_on_body_entered)


## Ready to fire again. The timer calls this on every OTHER gate when one trips.
func arm() -> void:
	_armed = true


func disarm() -> void:
	_armed = false


## Write the board bolted to this gate's post. Two lines: the gate's name and
## whatever the timer wants to say about it.
func set_board(line: String) -> void:
	if _board == null:
		return
	_board.text = "%s\n%s" % [gate_name, line]


func _on_body_entered(body: Node3D) -> void:
	if not _armed or body is not PlayerController:
		return
	var now: int = Time.get_ticks_msec()
	if now - _last_ms < int(refire_lockout * 1000.0):
		return
	_last_ms = now
	_armed = false
	passed.emit(gate_index, self)
