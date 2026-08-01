class_name AshFlats
extends Node3D
## ASH FLATS. One dead town on one dry river, and everything in it is walkable.
##
## THERE IS NOTHING TO FIGHT HERE. No spawner, no patrol, no AI. The demo is the
## world and the moving through it: THE ASH LINE runs down the main carriageway
## from the spoil heap at the south end to the dry river at the bottom, and the
## whole of it is built to be taken at speed. Sprint up the berm, slide the pitched
## roofs, and the three gaps open up — a slide off a fourteen-degree roof leaves the
## lip at nearly thirteen metres a second against a sprint's seven and a half, and
## that difference is exactly what the gaps are cut to.
##
## The scene is assembly, not authorship: the terrain, the town, the props, the
## player and the course were all baked by their own builders and are instanced here
## as they were shipped. What this script adds is the wiring nothing else owns —
## which pad the player is standing on, what the board in the yard says, and how
## much of that the F3 overlay gets to repeat.
##
## There is no screen-space text in this demo. The pads carry their own gauges, the
## yard board carries the clock, and the gates carry their own names on the lintel.
## If the player needs to know something it is because they can see it.

## The player was put back on their feet, at `where`, for `reason` — "extracted" or
## "reset".
signal respawned(where: Vector3, reason: StringName)

const DEMO_ID: String = "ash_flats"
const DEMO_TITLE: String = "ASH FLATS"
const DEMO_BLURB: String = "One dead town on one dry river. Take the line."
## What the gate-lamp dial steps through, in `AshFlatsCourse.Lamps` order.
const LAMP_STEPS: PackedStringArray = ["OFF", "NEXT", "ALL"]
## Seconds between refreshes of the board and the debug notes. Both are read, not
## reacted to; five times a second keeps the clock readable without repainting a
## render target every frame.
const REPORT_INTERVAL: float = 0.2

@export_group("Player")
## Where a run starts. Baked from the town layout — the main carriageway south of
## the start gate, facing north down the line.
@export var spawn_position: Vector3 = Vector3.ZERO
@export_range(-6.29, 6.29, 0.01) var spawn_yaw: float = 0.0
## Metres the interact probe reaches. Longer than an arm because the yard board is
## behind a rail — and because you are meant to shoot it from further out anyway.
@export_range(0.5, 8.0, 0.1) var interact_reach: float = 3.2

@export_group("Wiring")
@export var player_path: NodePath = NodePath("Player")
@export var course_path: NodePath = NodePath("Course")
@export var pads_path: NodePath = NodePath("Pads")
@export var board_path: NodePath = NodePath("YardBoard")

var _player: PlayerController = null
var _course: AshFlatsCourse = null
var _pads: Array[AshFlatsPad] = []
var _board: DiegeticReadout = null
var _lever: DiegeticLever = null
var _dial: DiegeticDial = null
## The yard board's hands. Latches the press and casts that press's own ray on the
## next physics frame, so a press is never resolved against a stale eye and never
## thrown away because the control was still inside its debounce.
var _hands: DiegeticInteractor = null
var _report: float = 0.0
var _last_line: String = "NO RUN LOGGED"


func _ready() -> void:
	if not SceneRouter.DEMOS.has(DEMO_ID):
		SceneRouter.register_demo(DEMO_ID, DEMO_TITLE, scene_file_path, DEMO_BLURB)
	_bind_player()
	_bind_course()
	_bind_pads()
	_bind_board()
	_build_hands()


func _exit_tree() -> void:
	DebugHUD.clear_note(&"ash_flats")
	DebugHUD.clear_note(&"ash_flats_run")


func _process(delta: float) -> void:
	if _player != null:
		_hands.enabled = not _player.freecam_active
	_report -= delta
	if _report > 0.0:
		return
	_report = REPORT_INTERVAL
	_write_board()
	_write_notes()


## The yard board is behind a rail, so the reach is longer than an arm — and the
## board is meant to be shot from further out anyway. Nothing in this demo draws a
## highlight, so the per-frame hover ray would be a ray cast for nobody.
func _build_hands() -> void:
	_hands = DiegeticInteractor.new()
	_hands.name = "Hands"
	_hands.collision_mask = GameLayers.MASK_INTERACT
	_hands.interact_reach = interact_reach
	_hands.handle_fire = false
	_hands.track_hover = false
	add_child(_hands)
	CombatReticle.mount(self).watch(_hands)


func _bind_player() -> void:
	_player = get_node_or_null(player_path) as PlayerController
	if _player == null:
		push_error("AshFlats: no player at %s." % player_path)
		return
	_player.set_spawn(spawn_position, spawn_yaw)
	_player.teleport(spawn_position, spawn_yaw)


func _bind_course() -> void:
	_course = get_node_or_null(course_path) as AshFlatsCourse
	if _course == null:
		return
	_course.watch(_player)
	_course.finished.connect(_on_course_finished)


func _bind_pads() -> void:
	var root: Node = get_node_or_null(pads_path)
	if root == null:
		return
	for child: Node in root.get_children():
		var pad := child as AshFlatsPad
		if pad == null:
			continue
		pad.watch(_player)
		pad.extracted.connect(_on_extracted)
		_pads.append(pad)


func _bind_board() -> void:
	var root: Node = get_node_or_null(board_path)
	if root == null:
		return
	_board = root.get_node_or_null(^"Readout") as DiegeticReadout
	_lever = root.get_node_or_null(^"Clock") as DiegeticLever
	_dial = root.get_node_or_null(^"Lamps") as DiegeticDial
	if _lever != null:
		_lever.set_on(_course == null or _course.clock_enabled, false)
		_lever.toggled.connect(_on_clock_toggled)
	if _dial == null:
		return
	_dial.set_options(LAMP_STEPS)
	_dial.set_value(float(AshFlatsCourse.Lamps.NEXT if _course == null else _course.lamp_mode))
	_dial.option_selected.connect(_on_lamps_selected)


func _on_clock_toggled(on: bool) -> void:
	if _course != null:
		_course.set_clock_enabled(on)


func _on_lamps_selected(index: int, _text: String) -> void:
	if _course != null:
		_course.set_lamp_mode(index)


func _on_course_finished(seconds: float, improved: bool) -> void:
	_last_line = "%.2f s%s" % [seconds, "  NEW BEST" if improved else ""]


func _on_extracted(pad_name: String, _seconds: float) -> void:
	_last_line = "LIFT FROM %s" % pad_name
	_respawn(&"extracted")


## Extraction is not a game over, it is the loop closing: it puts you back at the
## head of the line with the clock stood down.
func _respawn(reason: StringName) -> void:
	if _player == null:
		return
	_player.respawn()
	for pad: AshFlatsPad in _pads:
		pad.reset_run()
	if _course != null:
		_course.reset_run()
	respawned.emit(spawn_position, reason)


func _write_board() -> void:
	if _board == null:
		return
	_board.set_title("ASH LINE")
	var speed: float = 0.0 if _player == null else _player.speed
	if _course == null:
		_board.set_lines(PackedStringArray(["NO COURSE", _last_line]))
		return
	var clock: String = (
		"RUN  %5.2f s" % _course.elapsed if _course.running else "LAST %s" % _last_line
	)
	var best: String = "BEST %5.2f s" % _course.best if _course.best > 0.0 else "BEST      --"
	var gate: String = _course.next_gate_name()
	var second: String = "%s   NEXT %s" % [best, gate if gate != "" else "START"]
	_board.set_lines(PackedStringArray([clock, second]))
	_board.set_bars(
		PackedStringArray(["SPEED", "COURSE"]),
		PackedFloat32Array([clampf(speed / 18.0, 0.0, 1.0), _course.progress()]),
		PackedColorArray([WorldPalette.EXFIL, Palette.BONE])
	)


func _write_notes() -> void:
	if _player == null:
		return
	var p: Vector3 = _player.global_position
	DebugHUD.note(
		&"ash_flats",
		(
			"ASH FLATS  %.0f %.0f %.0f   %.1f m/s%s"
			% [p.x, p.y, p.z, _player.speed, "  SLIDE" if _player.sliding else ""]
		)
	)
	if _course == null:
		return
	DebugHUD.note(
		&"ash_flats_run",
		(
			"line %s  %5.2f s   next %s   top %.1f m/s   best %.2f"
			% [
				"RUNNING" if _course.running else "armed",
				_course.elapsed,
				_course.next_gate_name(),
				_course.top_speed,
				_course.best
			]
		)
	)
