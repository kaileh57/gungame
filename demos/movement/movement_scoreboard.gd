class_name MovementScoreboard
extends Node3D
## The lap board beside the start gate, and the three rival holograms on the mast next
## to it.
##
## THE BOARD IS YOURS AND THE HOLOGRAMS ARE THEIRS. The slab carries your name, your
## running best and your last lap in paint; every other player in the session gets a
## projected panel on the mast, in their own colour, fastest at the top. A hologram
## appears the instant that player posts a lap and not before — an empty rank of three
## grey slots would say "three people are here and nobody has run", which is a sentence
## nobody needs and which is wrong the moment somebody leaves.
##
## Nothing here decides anything. `MovementLink` owns the wire and the host owns which
## times are real; this file is told a peer and a number and draws it. In single-player
## the roster is one player long, `post()` is only ever called with your own peer id, and
## the mast stays dark for the whole session — which is correct, because there is nobody
## else to be faster than.
##
## The panels are additive quads wearing `hologram.gdshader`. Colour and brightness ride
## on instance uniforms, so three players cost three uniform writes and not three
## materials.
##
## A TIME OUTLIVES A TUNING CHANGE, DELIBERATELY. Turning a slider or throwing a preset
## does not wipe the board, even though every posted lap was set under numbers that no
## longer hold. Wiping four people's records because somebody nudged gravity is worse
## than a board that needs reading with one eye on the desk, and there is no honest way
## to keep only the times that are still valid.

## Instance uniforms declared by `hologram.gdshader`.
const P_TINT: StringName = &"holo_tint"
const P_ENERGY: StringName = &"holo_energy"
const P_SCAN: StringName = &"holo_scan"
## Metadata `CourseMarks` leaves on every emitter it builds.
const META_SCAN: StringName = &"holo_scan"
## Longest lap this will accept as a real time. A run that took an hour is a run
## somebody walked away from.
const MAX_LAP: float = 3600.0

## How often the roster is re-read and the mast rebuilt. Four players; not a hot path.
@export_range(0.05, 2.0, 0.05) var refresh_seconds: float = 0.25
## Brightness the hologram panels are driven at.
@export_range(0.2, 4.0, 0.05) var panel_energy: float = 1.30
@export var idle_text: String = "- - . - -"

## peer id -> best lap in seconds. Whoever is holding the wire writes this through
## `post()`; nothing in here invents an entry.
var _bests: Dictionary = {}
var _last: float = 0.0
var _running: bool = false
var _local: int = NetPlayer.HOST_ID
var _clock: float = 999.0
var _slots: Array[Node3D] = []

@onready var _who: Label3D = get_node_or_null(^"Who") as Label3D
@onready var _best: Label3D = get_node_or_null(^"Best") as Label3D
@onready var _last_line: Label3D = get_node_or_null(^"Last") as Label3D


func _ready() -> void:
	for i: int in NetPlayer.MAX_PLAYERS - 1:
		var slot := get_node_or_null(NodePath("Slot%d" % i)) as Node3D
		if slot == null:
			push_error("MovementScoreboard: Slot%d is missing; re-run build_movement." % i)
			continue
		slot.visible = false
		_slots.append(slot)
	_dress_emitters(self)
	_refresh()


func _process(delta: float) -> void:
	_clock += delta
	if _clock < refresh_seconds:
		return
	_clock = 0.0
	_refresh()


## Record a player's best lap. Later calls that are not an improvement are ignored, so
## a snapshot arriving out of order behind a live result cannot make somebody slower.
func post(peer_id: int, seconds: float) -> void:
	if peer_id <= 0 or not is_finite(seconds) or seconds <= 0.0 or seconds > MAX_LAP:
		return
	var held: float = float(_bests.get(peer_id, 0.0))
	if held > 0.0 and held <= seconds:
		return
	_bests[peer_id] = seconds
	_refresh()


## The lap that just closed, whether or not it was an improvement.
func set_last(seconds: float) -> void:
	_last = maxf(seconds, 0.0)
	_refresh()


## Whether a run is open. The board says so, because the board is the only thing you can
## read while you are running at it.
func set_running(on: bool) -> void:
	if _running == on:
		return
	_running = on
	_refresh()


## Every posted time, keyed by peer id. `MovementLink` hands this to a joining client.
func bests() -> Dictionary:
	return _bests.duplicate()


## This machine's own best, or 0.
func local_best() -> float:
	return float(_bests.get(_local, 0.0))


# --- drawing ----------------------------------------------------------------


func _refresh() -> void:
	var roster: Array = NetAvatarLink.roster(get_tree())
	_local = NetAvatarLink.local_id(get_tree())
	var here: Dictionary = {}
	for row: Dictionary in roster:
		here[int(row[&"id"])] = row
	_purge(here)
	_write_board(here.get(_local, {}) as Dictionary)
	_write_mast(_ranked(here))


## Drop anybody who has left. Their slot goes back to the mast the moment they do, which
## is the honest thing: a time belonging to somebody who is not here is a ghost.
func _purge(here: Dictionary) -> void:
	for id: int in _bests.keys():
		if not here.has(id):
			_bests.erase(id)


## Everyone but you who has posted, fastest first. Each row carries everything a slot
## draws, so the mast never has to go back to the roster for a name it already had.
func _ranked(here: Dictionary) -> Array:
	var out: Array = []
	for id: int in _bests:
		if id == _local or not here.has(id):
			continue
		var row: Dictionary = here[id]
		var entry: Dictionary = {
			&"seconds": float(_bests[id]),
			&"name": String(row[&"name"]),
			&"color": Color(row[&"color"]),
		}
		out.append(entry)
	out.sort_custom(_faster)
	return out


## Fastest first. A rank ordered by peer id would put the host at the top forever.
static func _faster(a: Dictionary, b: Dictionary) -> bool:
	return float(a[&"seconds"]) < float(b[&"seconds"])


func _write_board(me: Dictionary) -> void:
	if _who != null:
		var color: Color = Color(me.get(&"color", Palette.BONE))
		_who.text = String(me.get(&"name", "PLAYER 1"))
		_who.modulate = NetColors.text(color)
	if _best != null:
		var best: float = local_best()
		_best.text = idle_text if best <= 0.0 else RunTimer.clock(best)
	if _last_line == null:
		return
	if _running:
		_last_line.text = "RUNNING"
		_last_line.modulate = UiStyle.GOOD
		return
	_last_line.text = "LAST  %s" % (idle_text if _last <= 0.0 else RunTimer.clock(_last))
	_last_line.modulate = Palette.BONE


func _write_mast(ranked: Array) -> void:
	for i: int in _slots.size():
		var slot: Node3D = _slots[i]
		if i >= ranked.size():
			slot.visible = false
			continue
		var row: Dictionary = ranked[i]
		slot.visible = true
		_write_slot(slot, String(row[&"name"]), float(row[&"seconds"]), Color(row[&"color"]))


func _write_slot(slot: Node3D, who: String, seconds: float, color: Color) -> void:
	var name_label := slot.get_node_or_null(^"Name") as Label3D
	var time_label := slot.get_node_or_null(^"Time") as Label3D
	var panel := slot.get_node_or_null(^"Panel") as GeometryInstance3D
	if name_label != null:
		name_label.text = who
		name_label.modulate = NetColors.text(color)
	if time_label != null:
		time_label.text = RunTimer.clock(seconds)
		time_label.modulate = NetColors.text(color)
	if panel != null:
		panel.set_instance_shader_parameter(P_TINT, color)


## Push the shader's per-instance constants onto every emitter under this node, once.
## `holo_scan` comes off the metadata the baker left, so a lamp head and a panel wear the
## same material and still look like different things.
func _dress_emitters(node: Node) -> void:
	for child: Node in node.get_children():
		var geom := child as GeometryInstance3D
		if geom != null and geom.has_meta(META_SCAN):
			geom.set_instance_shader_parameter(P_ENERGY, panel_energy)
			geom.set_instance_shader_parameter(P_SCAN, float(geom.get_meta(META_SCAN)))
		_dress_emitters(child)
