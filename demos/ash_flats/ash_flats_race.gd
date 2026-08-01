class_name AshFlatsRace
extends Node
## THE ASH LINE RACE. Up to four people, one start line, one route, one clock.
##
## The route is THE ASH LINE itself — the berm, the crest, and the three slide-jump gaps
## down to the riverbed. That is deliberate and it is the whole point of racing here: the
## line is the only place in the game where a slide beats a sprint, so the fast way down
## is the mechanics and not the geometry. The checkpoints are baked by
## `tools/build_ash_flats.gd` onto the landing decks, each with a HEIGHT BAND, so running
## the street underneath a deck does not count as having been on it.
##
## HOST AUTHORITATIVE, and the split is the usual one:
##
##   the host decides   who is racing, when the lights go out, who crossed what, when,
##                      in what order, and what the standing best is.
##   everybody draws    their own lamps, their own board, their own countdown, and
##                      teleports their OWN body to the lane the host gave them.
##
## Nobody ever sends a time. A client's only outbound message is "let us race" and "I am
## in the scene"; every number on every board came off the host's clock.
##
## ANYONE CAN START IT. The button on the yard board is not the host's button — a client
## pressing it sends `_rq_start` and the host opens the lights. That is a deliberate
## design call from the brief and it is why `request_start` is public and unguarded.
##
## HOW THE HOST SEES A CLIENT. It does not run their body. It reads the avatar
## `NetPresence` already stands where they stand — `NetPlayer.avatar` — which is pushed
## at about 18 Hz. At the line's top speed of ~13 m/s that is a 0.7 m sample against a
## 6.5 m checkpoint radius, so a crossing cannot be missed; what it costs is up to one
## sample of resolution on the recorded time. Measuring it any better than that means
## replicating movement properly, which is NET-CORE's job and not this file's.
##
## SINGLE-PLAYER IS THE SAME PATH. `NetAvatarLink` answers every session question with a
## one-player roster when there is no session, `is_host` is true, and every `.rpc()` is
## skipped rather than branched around. A race of one is a countdown time trial, which
## is a perfectly good thing to have on your own.

## The race changed phase. `state` is one of `State`.
signal state_changed(state: int)
## The order or any racer's numbers changed. The board redraws on this and nothing else.
signal standings_changed
## Somebody crossed the last checkpoint. `place` is 1-based.
signal racer_finished(peer_id: int, seconds: float, place: int)

## IDLE waits for a press. COUNTDOWN holds everyone on the line under the lights.
## RUNNING is the race. FINISHED shows the result before it re-arms itself.
enum State { IDLE, COUNTDOWN, RUNNING, FINISHED }

## Peer id the server always has. Also this machine's id with no session at all, which is
## what makes single-player the host-alone case and not a second code path.
const HOST_ID: int = NetPlayer.HOST_ID
## A racer whose position has not been readable for this long is dead to the clock. Four
## seconds is about seventy position packets: this is a player who left, not one who
## dropped a packet.
const LOST_SECONDS: float = 4.0
## Seconds after this scene loads before a client tells the host it is here. The host
## routes first and therefore builds this node first, so the message cannot land early —
## but it is one variable to be sure of it, against an RPC that fails loudly on the host
## for something that is nobody's fault.
const ANNOUNCE_GRACE: float = 0.6

@export_group("Course")
## Checkpoint names, in order. The last one is the finish.
@export var checkpoint_names: PackedStringArray = PackedStringArray()
## Checkpoint centres, world space. Baked from the ASH LINE decks.
@export var checkpoint_points: PackedVector3Array = PackedVector3Array()
## Metres below and above a checkpoint's own height that still count as crossing it. The
## lower number is the anti-shortcut: on the low decks it is under two metres, which is
## the difference between standing on the roof and running the street beneath it.
@export var checkpoint_below: PackedFloat32Array = PackedFloat32Array()
@export var checkpoint_above: PackedFloat32Array = PackedFloat32Array()
## Horizontal radius of every checkpoint, metres.
@export_range(1.0, 20.0, 0.1) var checkpoint_radius: float = 6.5

@export_group("Line")
## Where the four lanes are, in slot order. Baked across the carriageway at the gantry.
@export var lane_points: PackedVector3Array = PackedVector3Array()
## Yaw every racer is turned to on the line. PI faces +Z, which is down the line.
@export_range(-6.29, 6.29, 0.01) var lane_yaw: float = PI

@export_group("Timing")
## Seconds under the lights. One lamp goes out a second, and the last one going out is
## the start — see `AshFlatsGantry`.
@export_range(1.0, 12.0, 1.0) var countdown_seconds: float = 5.0
## A race longer than this is over whether or not everyone got down. Nobody is left
## holding a running clock because one person went sightseeing.
@export_range(30.0, 600.0, 5.0) var race_limit: float = 210.0
## Seconds the result stands on the board before the line re-arms itself.
@export_range(2.0, 60.0, 1.0) var cooldown_seconds: float = 16.0
## How often the host restates the order. Four players; this is not a hot path.
@export_range(1.0, 20.0, 0.5) var standings_hz: float = 4.0

var state: int = State.IDLE
## Seconds remaining in COUNTDOWN, elapsed in RUNNING, elapsed in FINISHED.
var clock: float = 0.0

var _player: PlayerController = null
var _local_id: int = HOST_ID
## peer id -> {next, time, place, progress, lost, lane, done}. The live field.
var _racers: Dictionary = {}
## peer id -> best seconds this session. The host's copy is the one of record.
var _bests: Dictionary = {}
## Display order, best first. Rebuilt whenever anything moves.
var _order: PackedInt32Array = PackedInt32Array()
## Host only: who has told us they have the scene loaded. A peer still fading in cannot
## be teleported to a line it does not have, so it is not entered.
var _present: Dictionary = {}
var _announced: bool = false
var _announce_clock: float = 0.0
var _places: int = 0
var _standings_clock: float = 0.0


func _ready() -> void:
	set_physics_process(false)


func _physics_process(delta: float) -> void:
	_local_id = NetAvatarLink.local_id(get_tree())
	_announce(delta)
	match state:
		State.COUNTDOWN:
			_tick_countdown(delta)
		State.RUNNING:
			_tick_running(delta)
		State.FINISHED:
			_tick_finished(delta)


## Give the race the body it teleports and watches, and start it. Until this is called it
## costs nothing at all.
func bind(player: PlayerController) -> void:
	_player = player
	set_physics_process(player != null and checkpoint_points.size() >= 2)


## Start a race. ANYONE may call this, on any machine, at any time — that is the brief.
## A client turns it into one reliable packet to the host and then waits like everybody
## else; the host is the only thing that ever decides a race is on.
func request_start() -> void:
	if not _may_arm():
		return
	if _networked() and not is_authority():
		_rq_start.rpc_id(HOST_ID)
		return
	_begin()


## True while the line is under the lights or the race is on. The demo hangs the
## extraction pads and the presence mode off this one answer.
func is_live() -> bool:
	return state == State.COUNTDOWN or state == State.RUNNING


## True while a result is worth showing — the race is on, or its board is still up.
func is_showing() -> bool:
	return state != State.IDLE


## This machine decides things. True on the host and true with no session at all.
func is_authority() -> bool:
	return NetAvatarLink.is_host(get_tree())


## Lamps that should still be lit on the gantry, `countdown_seconds` down to 0.
func lamps_lit() -> int:
	if state != State.COUNTDOWN:
		return 0
	return clampi(ceili(clock), 0, int(countdown_seconds))


## The board's whole content, best first. One dictionary per player in the session:
## `id`, `name`, `color`, `place`, `time`, `best`, `progress`, `finished`, `racing`.
func standings() -> Array:
	var out: Array = []
	var rows: Dictionary = {}
	for row: Dictionary in NetAvatarLink.roster(get_tree()):
		rows[int(row[&"id"])] = row
	for id: int in _order:
		if rows.has(id):
			out.append(_row_for(id, rows[id]))
	for id: int in rows:
		if not _order.has(id):
			out.append(_row_for(id, rows[id]))
	return out


## Name of the checkpoint a player is running at, or "" when they are not racing.
func next_checkpoint_name(peer_id: int) -> String:
	var racer: Dictionary = _racers.get(peer_id, {})
	if racer.is_empty() or bool(racer[&"done"]):
		return ""
	var index: int = int(racer[&"next"])
	if index < 0 or index >= checkpoint_names.size():
		return ""
	return checkpoint_names[index]


## One line for the debug overlay and for the board's strapline.
func status_text() -> String:
	match state:
		State.COUNTDOWN:
			return "ON THE LINE  %d" % lamps_lit()
		State.RUNNING:
			return "RACE  %5.2f s" % clock
		State.FINISHED:
			return "RESULT"
		_:
			return "LINE OPEN"


# --- the phases, on every machine ---------------------------------------------


func _tick_countdown(delta: float) -> void:
	clock = maxf(0.0, clock - delta)
	if clock > 0.0 or not is_authority():
		return
	_fan_go()


func _tick_running(delta: float) -> void:
	clock += delta
	if not is_authority():
		return
	_track()
	_standings_clock += delta
	if _standings_clock >= 1.0 / maxf(standings_hz, 1.0):
		_standings_clock = 0.0
		_push_standings()
	if clock >= race_limit or _all_done():
		_fan_end()


func _tick_finished(delta: float) -> void:
	clock += delta
	if is_authority() and clock >= cooldown_seconds:
		_fan_idle()


## True once every racer still in the session has crossed the last checkpoint.
func _all_done() -> bool:
	for id: int in _racers:
		if not bool((_racers[id] as Dictionary)[&"done"]):
			return false
	return not _racers.is_empty()


# --- the host's job -----------------------------------------------------------


## Open the lights. The roster is snapshotted here and never re-read: somebody joining
## the session mid-race is impossible by design, and somebody LEAVING is handled by the
## tracker rather than by re-entering everybody.
func _begin() -> void:
	var ids := PackedInt32Array()
	for row: Dictionary in NetAvatarLink.roster(get_tree()):
		var id: int = int(row[&"id"])
		if id == _local_id or not _networked() or _present.has(id):
			ids.push_back(id)
	if ids.is_empty():
		return
	_fan_begin(ids)


## Every racer's position, against the checkpoint they are running at. Host only.
func _track() -> void:
	for id: int in _racers:
		var racer: Dictionary = _racers[id]
		if bool(racer[&"done"]):
			continue
		var here: Vector3 = _position_of(id)
		if not here.is_finite():
			racer[&"lost"] = float(racer[&"lost"]) + get_physics_process_delta_time()
			if float(racer[&"lost"]) > LOST_SECONDS:
				_finish(id, -1.0)
			continue
		racer[&"lost"] = 0.0
		var index: int = int(racer[&"next"])
		if _inside(index, here):
			index += 1
			racer[&"next"] = index
			if index >= checkpoint_points.size():
				_finish(id, clock)
				continue
		racer[&"progress"] = _progress_of(id, index, here)


## Record a crossing of the last checkpoint, or a DNF at `seconds` below zero.
func _finish(peer_id: int, seconds: float) -> void:
	var racer: Dictionary = _racers[peer_id]
	racer[&"done"] = true
	racer[&"time"] = seconds
	racer[&"progress"] = float(checkpoint_points.size())
	var place: int = 0
	if seconds > 0.0:
		_places += 1
		place = _places
		var best: float = float(_bests.get(peer_id, 0.0))
		if best <= 0.0 or seconds < best:
			_bests[peer_id] = seconds
	racer[&"place"] = place
	_fan_finish(peer_id, seconds, place)


## Where a player is, or `Vector3.INF` when this machine cannot see them. Your own body
## is read straight off the controller; everybody else's off the avatar `NetPresence`
## stands where they stand.
func _position_of(peer_id: int) -> Vector3:
	if peer_id == _local_id:
		return Vector3.INF if _player == null else _player.global_position
	var who: NetPlayer = NetAvatarLink.player(get_tree(), peer_id)
	if who == null or not is_instance_valid(who.avatar):
		return Vector3.INF
	return who.avatar.global_position


## Is `p` inside checkpoint `index`. A cylinder with an ASYMMETRIC height band: generous
## overhead because you arrive off a roof still airborne, tight underneath because the
## street runs directly below two of the landing decks.
func _inside(index: int, p: Vector3) -> bool:
	if index < 0 or index >= checkpoint_points.size():
		return false
	var c: Vector3 = checkpoint_points[index]
	var lift: float = p.y - c.y
	if lift < -_band(checkpoint_below, index, 2.0) or lift > _band(checkpoint_above, index, 6.0):
		return false
	var dx: float = p.x - c.x
	var dz: float = p.z - c.z
	return dx * dx + dz * dz < checkpoint_radius * checkpoint_radius


## Checkpoints crossed, plus how far along the current leg. This is the ordering key and
## nothing else; it is never shown as a number.
func _progress_of(peer_id: int, index: int, here: Vector3) -> float:
	if index >= checkpoint_points.size():
		return float(checkpoint_points.size())
	var from: Vector3 = checkpoint_points[index - 1] if index > 0 else _lane_of(peer_id)
	var leg: float = maxf(from.distance_to(checkpoint_points[index]), 0.001)
	var left: float = here.distance_to(checkpoint_points[index])
	return float(index) + clampf(1.0 - left / leg, 0.0, 1.0)


# --- fan-out ------------------------------------------------------------------
#
# Every host-to-everybody message is sent the same way: run it locally, then `rpc_id` it
# at each peer that has SAID it has this scene. Deliberately not `rpc()` with
# `call_local`, because a broadcast also reaches a client that is still fading into the
# demo, and an RPC addressed to a node that machine has not built yet fails loudly on
# their screen for something that is nobody's fault. `_rq_here` is what closes that
# window, and `_targets` is where it is honoured.


func _fan_begin(ids: PackedInt32Array) -> void:
	_rs_begin(ids)
	for id: int in _targets():
		_rs_begin.rpc_id(id, ids)


func _fan_go() -> void:
	_rs_go()
	for id: int in _targets():
		_rs_go.rpc_id(id)


func _fan_finish(peer_id: int, seconds: float, place: int) -> void:
	_rs_finish(peer_id, seconds, place)
	for id: int in _targets():
		_rs_finish.rpc_id(id, peer_id, seconds, place)


func _fan_end() -> void:
	var ids := PackedInt32Array()
	var times := PackedFloat32Array()
	var bests := PackedFloat32Array()
	for id: int in _racers:
		var racer: Dictionary = _racers[id]
		if not bool(racer[&"done"]):
			_finish(id, -1.0)
		ids.push_back(id)
		times.push_back(float(racer[&"time"]))
		bests.push_back(float(_bests.get(id, 0.0)))
	_rs_end(ids, times, bests)
	for id: int in _targets():
		_rs_end.rpc_id(id, ids, times, bests)


func _fan_idle() -> void:
	_rs_idle()
	for id: int in _targets():
		_rs_idle.rpc_id(id)


func _push_standings() -> void:
	var ids := PackedInt32Array()
	var progress := PackedFloat32Array()
	for id: int in _racers:
		ids.push_back(id)
		progress.push_back(float((_racers[id] as Dictionary)[&"progress"]))
	_resort()
	standings_changed.emit()
	for id: int in _targets():
		_rs_standings.rpc_id(id, ids, progress)


## Peers the host may address: in the session, and having announced they hold this scene.
## Empty in single-player and on a client, which is what makes every `_fan_*` above a
## plain local call when there is nobody to tell.
func _targets() -> PackedInt32Array:
	var out := PackedInt32Array()
	if not _networked() or not is_authority():
		return out
	for row: Dictionary in NetAvatarLink.roster(get_tree()):
		var id: int = int(row[&"id"])
		if id != _local_id and _present.has(id):
			out.push_back(id)
	return out


# --- the wire -----------------------------------------------------------------

## A client saying it has this scene loaded. Until it does it cannot be put on the line,
## because an RPC to a node it has not built yet fails noisily on its machine.
@rpc("any_peer", "reliable")
func _rq_here() -> void:
	if is_authority():
		_present[multiplayer.get_remote_sender_id()] = true


## Anyone asking for a race. Refused silently when one is already live — the presser's
## own button has already clunked, and a second race is not a thing to explain twice.
@rpc("any_peer", "reliable")
func _rq_start() -> void:
	if is_authority() and _may_arm():
		_begin()


## Everybody on the line, lights on. Runs on every machine including the host's.
@rpc("authority", "reliable")
func _rs_begin(ids: PackedInt32Array) -> void:
	_racers.clear()
	_order = ids.duplicate()
	_places = 0
	for i: int in ids.size():
		_racers[ids[i]] = {
			&"next": 0,
			&"time": 0.0,
			&"place": 0,
			&"progress": 0.0,
			&"lost": 0.0,
			&"lane": i,
			&"done": false,
		}
	clock = countdown_seconds
	_standings_clock = 0.0
	_set_state(State.COUNTDOWN)
	_place_local()
	standings_changed.emit()


## The lights are out. Everybody gets their hands back on the same frame they see it.
@rpc("authority", "reliable")
func _rs_go() -> void:
	clock = 0.0
	_set_state(State.RUNNING)
	_hold_local(false)
	standings_changed.emit()


@rpc("authority", "reliable")
func _rs_finish(peer_id: int, seconds: float, place: int) -> void:
	var racer: Dictionary = _racers.get(peer_id, {})
	if not racer.is_empty():
		racer[&"done"] = true
		racer[&"time"] = seconds
		racer[&"place"] = place
		racer[&"progress"] = float(checkpoint_points.size())
	if seconds > 0.0:
		var best: float = float(_bests.get(peer_id, 0.0))
		if best <= 0.0 or seconds < best:
			_bests[peer_id] = seconds
	_resort()
	racer_finished.emit(peer_id, seconds, place)
	standings_changed.emit()


@rpc("authority", "reliable")
func _rs_end(ids: PackedInt32Array, times: PackedFloat32Array, bests: PackedFloat32Array) -> void:
	for i: int in ids.size():
		var id: int = ids[i]
		if i < times.size() and _racers.has(id):
			var racer: Dictionary = _racers[id]
			racer[&"done"] = true
			racer[&"time"] = times[i]
		if i < bests.size() and bests[i] > 0.0:
			_bests[id] = bests[i]
	clock = 0.0
	_set_state(State.FINISHED)
	_hold_local(false)
	_resort()
	standings_changed.emit()


@rpc("authority", "unreliable_ordered")
func _rs_standings(ids: PackedInt32Array, progress: PackedFloat32Array) -> void:
	for i: int in ids.size():
		var racer: Dictionary = _racers.get(ids[i], {})
		if not racer.is_empty() and i < progress.size():
			racer[&"progress"] = progress[i]
	_resort()
	standings_changed.emit()


@rpc("authority", "reliable")
func _rs_idle() -> void:
	clock = 0.0
	# Forgotten, not kept: with no live race the board falls back to standing bests, which
	# is what an open line should be showing.
	_racers.clear()
	_order = PackedInt32Array()
	_places = 0
	_set_state(State.IDLE)
	_hold_local(false)
	_present_mode(NetPresence.FULL)
	standings_changed.emit()


# --- local effects ------------------------------------------------------------


## Put THIS machine's body in ITS lane and hold it there. Every machine does this for
## itself: the host never moves anybody else's body, it only says which lane is whose.
func _place_local() -> void:
	_present_mode(NetPresence.GHOST)
	if _player == null or not _racers.has(_local_id):
		return
	_player.teleport(_lane_of(_local_id), lane_yaw)
	_hold_local(true)


## Hands off during the countdown. `set_input_suspended` is the player controller's own
## door and it takes the weapon with it, so nobody jumps the lights and nobody shoots the
## board out from under the countdown either.
func _hold_local(on: bool) -> void:
	if _player != null:
		_player.set_input_suspended(on)


func _lane_of(peer_id: int) -> Vector3:
	if lane_points.is_empty():
		return Vector3.ZERO
	var racer: Dictionary = _racers.get(peer_id, {})
	var index: int = 0 if racer.is_empty() else int(racer[&"lane"])
	return lane_points[posmod(index, lane_points.size())]


## How everyone appears while the race is on. GHOST is the brief in one call: translucent
## bodies, no collider to block anybody with, and the cross-map beacon that makes four
## people findable through a town.
func _present_mode(want: int) -> void:
	var presence: NetPresence = NetPresence.instance()
	if presence != null:
		presence.set_mode(want)


func _set_state(next: int) -> void:
	if state == next:
		return
	state = next
	state_changed.emit(state)


# --- bookkeeping --------------------------------------------------------------


## Best first: finishers by time, then everybody still running by how far down the line
## they are, then the dead-and-lost. A DNF sorts below a finisher and above nothing.
func _resort() -> void:
	var live: Array[int] = []
	for id: int in _racers:
		live.append(id)
	live.sort_custom(_before)
	_order = PackedInt32Array(live)


func _before(a: int, b: int) -> bool:
	var ra: Dictionary = _racers[a]
	var rb: Dictionary = _racers[b]
	var ta: float = float(ra[&"time"])
	var tb: float = float(rb[&"time"])
	var fa: bool = bool(ra[&"done"]) and ta > 0.0
	var fb: bool = bool(rb[&"done"]) and tb > 0.0
	if fa != fb:
		return fa
	if fa and fb:
		return ta < tb
	return float(ra[&"progress"]) > float(rb[&"progress"])


func _row_for(peer_id: int, roster_row: Dictionary) -> Dictionary:
	var racer: Dictionary = _racers.get(peer_id, {})
	return {
		&"id": peer_id,
		&"name": String(roster_row[&"name"]),
		&"color": Color(roster_row[&"color"]),
		&"local": bool(roster_row[&"local"]),
		&"racing": not racer.is_empty(),
		&"finished": not racer.is_empty() and bool(racer[&"done"]),
		&"place": 0 if racer.is_empty() else int(racer[&"place"]),
		&"time": 0.0 if racer.is_empty() else float(racer[&"time"]),
		&"best": float(_bests.get(peer_id, 0.0)),
		&"progress": 0.0 if racer.is_empty() else float(racer[&"progress"]),
	}


func _band(table: PackedFloat32Array, index: int, fallback: float) -> float:
	return table[index] if index < table.size() else fallback


## Whether a press can open the lights. FINISHED counts: pressing the button while the
## last result is still up is somebody saying "again", and making them wait out a
## cooldown they can see no reason for is the kind of refusal that reads as a broken
## button. A race that is actually on refuses, and the presser has already heard the
## clunk that says the board took the press.
func _may_arm() -> bool:
	if state != State.IDLE and state != State.FINISHED:
		return false
	return checkpoint_points.size() >= 2 and not lane_points.is_empty()


## Tell the host once that this machine has the scene. Cheap enough to test every frame
## and it has to be: the transport comes up after `_ready` on a client that is still
## following the host into the demo.
func _announce(delta: float) -> void:
	if _announced or is_authority() or not _networked():
		return
	_announce_clock += delta
	if _announce_clock < ANNOUNCE_GRACE:
		return
	_announced = true
	_rq_here.rpc_id(HOST_ID)


func _networked() -> bool:
	var tree: SceneTree = get_tree()
	return NetAvatarLink.is_networked(tree) and NetAvatarLink.transport_ready(tree)
