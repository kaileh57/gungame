class_name AshFlats
extends Node3D
## ASH FLATS. One dead town on one dry river, and THE RACE that is run through it.
##
## THIS IS A RACE TRACK FIRST. Up to four people, one start line under a light gantry,
## one route, one clock, and the standings on a steel board turned to face the line you
## spawn on. It did not use to be: this was also the demo you came to LOOK at the world
## in, and it carried a signpost at every named place in three hundred metres of map and
## an extraction pad two hundred metres from anything. `demos/visuals` is where the world
## is the point now, so what is left here is the race, the ground it is run on, and the
## one pad you can walk to from the finish to be lifted back to the start.
##
## THE ASH LINE runs 190 m down the main carriageway: down the berm and the three gaps
## into the dry river, UP the viaduct that climbs out of it over the market, and down one
## more pitch and gap to the finish gantry on the far carriageway. All of it is built to
## be taken at speed — a slide off a fourteen-degree roof leaves the lip at nearly
## thirteen metres a second against a sprint's seven and a half, and that difference is
## exactly what the gaps are cut to.
##
## `AshFlatsRace` owns the race and the host owns `AshFlatsRace`; this file is the wiring
## between it and everything in the demo that has to get out of its way — the extraction
## pad, which would otherwise fly a racer home mid-run, and the presence mode, which
## becomes GHOST for the duration so nobody can body-block anybody and everybody stays
## findable.
##
## THERE IS NOTHING TO FIGHT HERE. No spawner, no patrol, no AI.
##
## The scene is assembly, not authorship: the terrain, the town, the props, the
## player and the course were all baked by their own builders and are instanced here
## as they were shipped. What this script adds is the wiring nothing else owns —
## which pad the player is standing on, what the board in the yard says, and how
## much of that the F3 overlay gets to repeat.
##
## There is no screen-space text in this demo. The pads carry their own gauges, the
## yard board carries the clock, the gantry carries the countdown, the leaderboard
## carries the result, and the gates carry their own names on the lintel. If the player
## needs to know something it is because they can see it.

## The player was put back on their feet, at `where`, for `reason` — "extracted" or
## "reset".
signal respawned(where: Vector3, reason: StringName)

const DEMO_ID: String = "ash_flats"
const DEMO_TITLE: String = "ASH FLATS"
const DEMO_BLURB: String = "Four on the line, one dead town, one clock. Race it."
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
@export var race_path: NodePath = NodePath("Race")
@export var gantry_path: NodePath = NodePath("StartLine")
@export var leaderboard_path: NodePath = NodePath("Leaderboard")
@export var marks_path: NodePath = NodePath("Marks")

var _player: PlayerController = null
var _course: AshFlatsCourse = null
var _pads: Array[AshFlatsPad] = []
var _board: DiegeticReadout = null
var _lever: DiegeticLever = null
var _dial: DiegeticDial = null
var _race: AshFlatsRace = null
var _marks: AshFlatsMarks = null
## The presence singleton, held from `_ready`. Resolved once and never re-fetched: the
## static accessor CREATES the node if it is missing, and doing that from `_exit_tree`
## would parent a node to a tree that is being torn down.
var _presence: NetPresence = null
var _pads_live: bool = true
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
	_bind_race()
	_build_hands()
	_enter_presence.call_deferred()


func _exit_tree() -> void:
	DebugHUD.clear_note(&"ash_flats")
	DebugHUD.clear_note(&"ash_flats_run")
	DebugHUD.clear_note(&"ash_flats_race")
	# Leaving mid-race must not export GHOST to whatever loads next. The presence mode is
	# global and the next demo is not obliged to set it.
	if is_instance_valid(_presence):
		_presence.set_mode(NetPresence.FULL)


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
	# ANYONE'S BUTTON, not the host's. A client's press is turned into one packet by
	# `AshFlatsRace.request_start`; nothing here asks who pressed it.
	var start := root.get_node_or_null(^"Race") as DiegeticButton
	if start != null:
		start.pressed.connect(_on_race_pressed)
	if _dial == null:
		return
	_dial.set_options(LAMP_STEPS)
	_dial.set_value(float(AshFlatsCourse.Lamps.NEXT if _course == null else _course.lamp_mode))
	_dial.option_selected.connect(_on_lamps_selected)


## The race, the gantry that counts it in, the board that reports it, and the marks that
## stand over everybody the rest of the time.
func _bind_race() -> void:
	_race = get_node_or_null(race_path) as AshFlatsRace
	_marks = get_node_or_null(marks_path) as AshFlatsMarks
	var gantry := get_node_or_null(gantry_path) as AshFlatsGantry
	var leaderboard := get_node_or_null(leaderboard_path) as AshFlatsBoard
	if _race == null:
		return
	_race.bind(_player)
	_race.state_changed.connect(_on_race_state)
	if gantry != null:
		gantry.watch(_race)
	if leaderboard != null:
		leaderboard.watch(_race)


func _on_race_pressed() -> void:
	if _race != null:
		_race.request_start()


## Everything in the demo that has to get out of a race's way, in one place. The pads go
## out of service because an extraction is a teleport home, and the marks stand down
## because GHOST mode is already wearing the same beacon.
func _on_race_state(_state: int) -> void:
	var live: bool = _race.is_live()
	if _marks != null:
		_marks.set_racing(live)
	var want: bool = not live
	if _pads_live == want:
		return
	_pads_live = want
	for pad: AshFlatsPad in _pads:
		pad.set_active(want)


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


## Everyone walks around as a body with a name over it, and the race turns that into
## GHOST for its duration. `NetPresence` costs nothing in single-player: the roster is one
## player long and the only thing drawn is your own dot.
##
## DEFERRED, AND IT HAS TO BE. `NetPresence.instance()` parents itself to `/root`, and a
## demo's `_ready` runs INSIDE the root's own `add_child` of that demo — so calling it
## straight from `_ready` is refused with "Parent node is busy setting up children" and
## leaves the singleton orphaned. Measured: four leaked objects and a leaked script at
## exit, and no presence at all. One frame later the tree is idle and the add lands.
func _enter_presence() -> void:
	_presence = NetPresence.enter(NetPresence.FULL, _player_eye())


## The eye the presence system casts this machine's aim ray from and measures every
## distance against. The baked player carries its camera at `Player/Eye`.
func _player_eye() -> Camera3D:
	return null if _player == null else _player.get_node_or_null(^"Eye") as Camera3D


## The yard board carries whichever clock is the one that matters. A race takes it over
## for its duration, because a solo split time is not what you are looking at while four
## people are on the line.
func _write_board() -> void:
	if _board == null:
		return
	_board.set_title("ASH LINE")
	var speed: float = 0.0 if _player == null else _player.speed
	if _race != null and _race.is_showing():
		_write_race_board(speed)
		return
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


## The race's own face on the yard board: the host's clock, where you are on the line,
## and how many of you are still down there.
func _write_race_board(speed: float) -> void:
	var rows: Array = _race.standings()
	var mine: Dictionary = {}
	var running: int = 0
	for row: Dictionary in rows:
		if bool(row[&"racing"]) and not bool(row[&"finished"]):
			running += 1
		if bool(row[&"local"]):
			mine = row
	var gate: String = "" if mine.is_empty() else _race.next_checkpoint_name(int(mine[&"id"]))
	var seat: String = "--" if mine.is_empty() else _place_text(mine, rows)
	_board.set_lines(
		PackedStringArray(
			[_race.status_text(), "PLACE %s   NEXT %s" % [seat, gate if gate != "" else "LINE"]]
		)
	)
	_board.set_bars(
		PackedStringArray(["SPEED", "RUNNING"]),
		PackedFloat32Array(
			[clampf(speed / 18.0, 0.0, 1.0), float(running) / float(maxi(rows.size(), 1))]
		),
		PackedColorArray([WorldPalette.EXFIL, Palette.BONE])
	)


## Where a player sits on the board right now — their finishing place once they have one,
## otherwise their position in the live order.
func _place_text(mine: Dictionary, rows: Array) -> String:
	if int(mine[&"place"]) > 0:
		return "%d" % int(mine[&"place"])
	for i: int in rows.size():
		if bool((rows[i] as Dictionary)[&"local"]):
			return "%d" % (i + 1)
	return "--"


## Race state on F3, including which side of the wire this build is on — the one thing a
## two-instance run needs to see and the one thing no in-world board should ever say.
func _write_race_note() -> void:
	if _race == null or not _race.is_showing():
		DebugHUD.clear_note(&"ash_flats_race")
		return
	DebugHUD.note(
		&"ash_flats_race",
		(
			"race %-14s %5.2f s   next %-8s %s"
			% [
				_race.status_text(),
				_race.clock,
				_race.next_checkpoint_name(NetAvatarLink.local_id(get_tree())),
				"HOST" if _race.is_authority() else "client"
			]
		)
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
	_write_race_note()
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
