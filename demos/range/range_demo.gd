class_name RangeDemo
extends Node3D
## The scav range. Four hundred metres of dirt, twenty-two targets and a bench
## you work by shooting it.
##
## This node is wiring and scoring and nothing else. The targets score
## themselves, the bench rolls its own weapons, the shooter drives the gun; what
## lives here is the arithmetic that joins them — a running score, a hit rate, a
## streak — and the two placards that show it.
##
## SCORING follows `docs/spec/range.md` §13.2 exactly, because the numbers are
## the game: a plate is worth `round(dmg*0.35 + pts*0.25)` a hit and `pts` again
## when it falls, a spot hit multiplies the first of those by 1.6, a bottle is a
## flat 30 and a drum is worth three times its own value to whoever set it off.
## The individual formulas live on `RangeTarget`; the tally lives here.
##
## Nothing in this scene explains itself on screen. The score is a phosphor
## placard at the firing line, the rules are painted on a board over the bench,
## and the distances are on signs you can walk up to and read.
##
## FOUR PEOPLE. The tally is per player, keyed by peer id, and in single-player it
## is a table with one row in it — so there is one loop and not two, and the
## exported `score`, `hits`, `spot_hits`, `knockdowns`, `streak` and `best_streak`
## keep meaning exactly what they have always meant: yours.
##
## The host owns every decision on this range and this node is where most of them
## are made: it credits points to whoever's round it was (`RangeNet.actor()`),
## replicates what happened to each target, and answers a player who has just
## walked in with the whole state of the place. A client makes none of them: it
## takes the events, applies them, and draws the board.

## The score changed. `delta_points` is what the last event was worth.
signal score_changed(score: int, delta_points: int)
## The range was reset: every target back up, the tally back to zero.
signal range_reset

const DEMO_ID: String = "range"
const RangeNetScript := preload("res://demos/range/range_net.gd")

## How often the tally goes on the wire. It is a scoreboard, not a crosshair.
const SCORE_HZ: float = 4.0
## How often every target's standing bit and every mover's phase are reconciled.
const SYNC_HZ: float = 2.0
## Tally row layout, on the wire and in `_tally`.
const ROW_FIELDS: PackedStringArray = ["score", "hits", "spots", "downs", "streak", "best"]

## Consecutive hits before the streak counts as a run worth showing.
@export_range(2, 20, 1) var streak_threshold: int = 5
## Where the player is put on a reset, and which way they face.
@export var spawn_point: Vector3 = Vector3(0.0, 0.30, 5.5)
@export_range(-3.15, 3.15, 0.01) var spawn_yaw: float = 0.0

@export_group("Wiring")
@export var bench_path: NodePath = NodePath("Bench")
@export var targets_path: NodePath = NodePath("Targets")
@export var shooter_path: NodePath = NodePath("Shooter")
@export var player_path: NodePath = NodePath("Player")
@export var lane_readout_path: NodePath = NodePath("Lane/LaneReadout")
@export var net_path: NodePath = NodePath("RangeNet")

var score: int = 0
var hits: int = 0
var spot_hits: int = 0
var knockdowns: int = 0
var streak: int = 0
var best_streak: int = 0

var _bench: WeaponBench = null
var _shooter: RangeShooter = null
var _player: PlayerController = null
var _holster: WeaponHolster = null
var _lane: DiegeticReadout = null
var _paper: RangePaperTarget = null
var _net: RangeNetScript = null
var _targets: Array[RangeTarget] = []
var _tally: Dictionary = {}
var _guns: Dictionary = {}
var _me: int = 1
var _authority: bool = true
var _group_mm: float = 0.0
var _group_shots: int = 0
var _dirty: bool = true
var _scores_dirty: bool = false
var _score_clock: float = 0.0
var _sync_clock: float = 0.0
## True for the duration of a bulk reset, so twenty-two RESTORE events do not go
## out behind the one packet that already said "everything back up".
var _resetting: bool = false


func _ready() -> void:
	_player = get_node_or_null(player_path) as PlayerController
	_shooter = get_node_or_null(shooter_path) as RangeShooter
	_bench = get_node_or_null(bench_path) as WeaponBench
	_lane = get_node_or_null(lane_readout_path) as DiegeticReadout
	if _player != null:
		_player.set_spawn(spawn_point, spawn_yaw)
		_holster = _player.get_node_or_null(^"Eye/Holster") as WeaponHolster

	_bind_net()
	_collect_targets()
	if _bench != null:
		_bench.weapon_rolled.connect(_on_bench_rolled)
		_bench.equip_requested.connect(_on_equip_requested)
		_bench.reset_requested.connect(reset_range)
		_bench.paper_clear_requested.connect(_on_paper_clear)
	if _shooter != null:
		_shooter.weapon_changed.connect(_on_weapon_changed)

	# The bench rolled its opening weapon inside its own `_ready`, which runs
	# before this one, so the signal has already gone by. Pick it up by hand and
	# put it in the player's hands: you walk into the bay holding something. On a
	# client the host grants it instead, because the loadout is the host's to say.
	if _authority and _bench != null and _bench.current() != null:
		_on_bench_rolled(_bench.current())
		_on_equip_requested(WeaponHolster.PRIMARY_SLOT, _bench.current(), _me)

	# Everyone appears to everyone as a capsule with sunglasses, a nameplate and a
	# laser dot. One line, and it costs nothing when nobody else is here.
	#
	# DEFERRED, AND IT HAS TO BE. `NetPresence.instance()` parents itself to `/root`,
	# and this `_ready` runs INSIDE the root's own `add_child` of the demo — so calling
	# it straight from here is refused with "Parent node is busy setting up children"
	# and leaves the singleton orphaned: no avatars, no nameplates, no dots, on any
	# machine. One frame later the tree is idle and the add lands.
	_enter_presence.call_deferred()
	_register_debug()
	_write_lane()


func _process(delta: float) -> void:
	if _dirty:
		_dirty = false
		_write_lane()
	if _net == null or not _authority or not _net.is_networked():
		return
	_score_clock += delta
	if _scores_dirty and _score_clock >= 1.0 / SCORE_HZ:
		_score_clock = 0.0
		_scores_dirty = false
		_net.publish_scores(_score_rows())
	_sync_clock += delta
	if _sync_clock >= 1.0 / SYNC_HZ:
		_sync_clock = 0.0
		_push_sync()


## Stand every target back up and zero the tally. Bound to the bench's RESET cap.
func reset_range() -> void:
	if not _authority:
		return
	_resetting = true
	for target: RangeTarget in _targets:
		target.restore()
	_resetting = false
	_wipe_tally()
	range_reset.emit()
	score_changed.emit(score, 0)
	if _shooter != null:
		_shooter.banner("RANGE CLEAR", 1.2)
	if _net != null:
		_net.publish_reset()


## Every player's row, in roster order: `[id, score, hits, spots, downs, streak,
## best]`. What goes on the wire and what the placard is drawn from.
func _score_rows() -> Array:
	var rows: Array = []
	if _net == null:
		return rows
	for row: Dictionary in _net.roster():
		var id: int = int(row[&"id"])
		var tally: Dictionary = _row_for(id)
		(
			rows
			. append(
				[
					id,
					int(tally[&"score"]),
					int(tally[&"hits"]),
					int(tally[&"spots"]),
					int(tally[&"downs"]),
					int(tally[&"streak"]),
					int(tally[&"best"]),
				]
			)
		)
	return rows


# --- wiring ------------------------------------------------------------------


func _bind_net() -> void:
	_net = get_node_or_null(net_path) as RangeNetScript
	if _net == null:
		_net = RangeNetScript.of(self) as RangeNetScript
	if _net == null:
		push_error("RangeDemo: no RangeNet in the scene. Re-run tools/build_range.gd.")
		return
	_authority = _net.is_authority()
	_me = _net.local_peer()
	_net.equipped.connect(_on_equipped)
	_net.target_event.connect(_on_target_event)
	_net.scored_at.connect(_on_scored_at)
	_net.scores_changed.connect(_on_scores_changed)
	_net.sync_state.connect(_apply_sync)
	_net.range_reset.connect(_on_remote_reset)
	_net.roster_changed.connect(_on_roster_changed)
	_net.state_wanted.connect(_on_state_wanted)
	_net.state_arrived.connect(_on_state_arrived)


func _collect_targets() -> void:
	_targets.clear()
	var parent: Node = get_node_or_null(targets_path)
	if parent == null:
		push_error("RangeDemo: no target group at %s." % targets_path)
		return
	_gather(parent)
	for target: RangeTarget in _targets:
		target.set_authority(_authority)
		target.scored.connect(_on_scored.bind(target))
		target.registered.connect(_on_registered)
		target.struck.connect(_on_struck.bind(target))
		target.downed.connect(_on_downed)
		target.restored.connect(_on_restored)
	if _paper != null:
		_paper.group_measured.connect(_on_group_measured)


func _gather(node: Node) -> void:
	for child: Node in node.get_children():
		var target := child as RangeTarget
		if target != null:
			_targets.append(target)
			var paper := target as RangePaperTarget
			if paper != null:
				_paper = paper
		_gather(child)


# --- what happened, on the host ---------------------------------------------


## Points landed. `RangeNet.actor()` is whoever's round is being resolved at this
## instant — the local player on their own machine, or the peer whose shot intent
## the host is working through — so the credit lands in the right column without
## a single target having to be told who is shooting.
func _on_scored(
	points: int, at: Vector3, label: String, kind: StringName, target: RangeTarget
) -> void:
	var who: int = _net.actor() if _net != null else _me
	var tally: Dictionary = _row_for(who)
	tally[&"score"] = int(tally[&"score"]) + points
	_mirror_local(who)
	_dirty = true
	_scores_dirty = true
	score_changed.emit(score, points)
	_draw_pop(who, at, label, kind)
	if _net == null:
		return
	_net.publish_pop(who, at, points, label, kind, kind == RangeTarget.POP_CRIT)
	if kind == RangeTarget.POP_BOOM:
		_net.publish_target(_targets.find(target), RangeNetScript.Op.BOOM, at, 0.0, false)


func _on_registered(crit: bool, killed: bool) -> void:
	var who: int = _net.actor() if _net != null else _me
	var tally: Dictionary = _row_for(who)
	tally[&"hits"] = int(tally[&"hits"]) + 1
	tally[&"streak"] = int(tally[&"streak"]) + 1
	tally[&"best"] = maxi(int(tally[&"best"]), int(tally[&"streak"]))
	if crit:
		tally[&"spots"] = int(tally[&"spots"]) + 1
	if killed:
		tally[&"downs"] = int(tally[&"downs"]) + 1
	if int(tally[&"streak"]) == streak_threshold and who == _me and _shooter != null:
		_shooter.banner("%d STRAIGHT" % streak_threshold, 1.0)
	_mirror_local(who)
	_dirty = true
	_scores_dirty = true


## The damage itself, which `scored` does not carry. Replicated so a client's plate
## swings by the same amount and its paper gets the same hole.
func _on_struck(amount: float, at: Vector3, crit: bool, target: RangeTarget) -> void:
	if _net != null:
		_net.publish_target(_targets.find(target), RangeNetScript.Op.HIT, at, amount, crit)


func _on_downed(target: RangeTarget, _reset_in: float) -> void:
	_dirty = true
	# A drum never simply falls over — it goes up, and BOOM was already published
	# by the scoring event that came with it.
	if _net != null and not _resetting and target.kind != RangeTarget.Kind.BARREL:
		_net.publish_target(_targets.find(target), RangeNetScript.Op.DOWN, Vector3.ZERO, 0.0, false)


func _on_restored(target: RangeTarget) -> void:
	_dirty = true
	if _net != null and not _resetting:
		var index: int = _targets.find(target)
		_net.publish_target(index, RangeNetScript.Op.RESTORE, Vector3.ZERO, 0.0, false)


func _push_sync() -> void:
	var alive := PackedByteArray()
	var phase := PackedFloat32Array()
	alive.resize(_targets.size())
	phase.resize(_targets.size())
	for i: int in _targets.size():
		alive[i] = 1 if _targets[i].is_live() else 0
		phase[i] = _targets[i].track_phase
	_net.publish_sync(alive, phase)


# --- what the host said happened, on a client -------------------------------


func _on_target_event(index: int, op: int, at: Vector3, amount: float, crit: bool) -> void:
	if index < 0 or index >= _targets.size():
		return
	var target: RangeTarget = _targets[index]
	match op:
		RangeNetScript.Op.HIT:
			target.remote_hit(amount, at, crit)
		RangeNetScript.Op.DOWN:
			target.remote_down()
		RangeNetScript.Op.BOOM:
			target.remote_boom()
		RangeNetScript.Op.RESTORE:
			target.restore()
	_dirty = true


## Somebody scored, anywhere. The number floats up off the target on every machine
## — a range four people are shooting should look like it — but the mark on your
## crosshair only ever means your own round connected.
func _on_scored_at(
	id: int, at: Vector3, points: int, label: String, kind: StringName, _crit: bool
) -> void:
	var tally: Dictionary = _row_for(id)
	tally[&"score"] = int(tally[&"score"]) + points
	_mirror_local(id)
	_draw_pop(id, at, label, kind)
	_dirty = true


func _draw_pop(id: int, at: Vector3, label: String, kind: StringName) -> void:
	if kind == RangeTarget.POP_BREAK:
		VfxService.spawn_impact(at, Vector3.UP, VFXSurface.Kind.GLASS, 1.2)
	if _shooter == null:
		return
	var finished: bool = kind == RangeTarget.POP_DOWN or kind == RangeTarget.POP_BOOM
	_shooter.report_hit(at, label, kind, finished, kind == RangeTarget.POP_CRIT, id == _me)


## The host's tally, whole. It replaces the running total a client kept from the
## pops, because the pops are unordered cosmetics and this is the record.
func _on_scores_changed(rows: Array) -> void:
	for entry: Variant in rows:
		if typeof(entry) != TYPE_ARRAY:
			continue
		var fields: Array = entry
		if fields.size() < ROW_FIELDS.size() + 1:
			continue
		var tally: Dictionary = _row_for(int(fields[0]))
		for i: int in ROW_FIELDS.size():
			tally[StringName(ROW_FIELDS[i])] = int(fields[i + 1])
		_mirror_local(int(fields[0]))
	_dirty = true


func _apply_sync(alive: PackedByteArray, phase: PackedFloat32Array) -> void:
	for i: int in mini(alive.size(), _targets.size()):
		_targets[i].remote_sync(alive[i] != 0, phase[i] if i < phase.size() else 0.0)


func _on_remote_reset() -> void:
	for target: RangeTarget in _targets:
		target.restore()
	_wipe_tally()
	range_reset.emit()
	score_changed.emit(score, 0)
	if _shooter != null:
		_shooter.banner("RANGE CLEAR", 1.2)


# --- the loadout -------------------------------------------------------------


## A cap was knocked in, on the host. `id` is whoever's round did it, which is the
## whole point: the gun goes to the player who shot the button.
func _on_equip_requested(slot: int, spec: GunSpec, id: int) -> void:
	if not _authority or spec == null:
		return
	if _net == null:
		_take(slot, spec)
		return
	_net.grant(id, slot, spec)


## The host granted somebody a weapon. Fires on every machine, so every scoreboard
## can name what everybody is carrying and exactly one machine puts it in a hand.
func _on_equipped(id: int, slot: int, spec: GunSpec) -> void:
	_guns[id] = spec.weapon_name
	_dirty = true
	if id == _me:
		_take(slot, spec)


func _take(slot: int, spec: GunSpec) -> void:
	if _holster == null or spec == null:
		return
	_holster.equip(slot, spec)
	if slot != _holster.active_slot:
		_holster.select(slot)


func _on_bench_rolled(spec: GunSpec) -> void:
	if spec == null or _shooter == null:
		return
	_shooter.banner(
		"%s — %s" % [spec.weapon_name.to_upper(), String(spec.tier_name).to_upper()], 1.4
	)


## New gun on the board means new paper: a group is one weapon's group or it is
## not a group. The tag carries the seed, so re-rolling the same name still
## papers over.
##
## With four people shooting there is still ONE board, so it follows the HOST'S
## weapon and nobody else's — the alternative is a group made of four different
## guns, which is not a group. A client never re-papers its own copy; the clear
## arrives as an event like everything else does.
func _on_weapon_changed(spec: GunSpec) -> void:
	if _paper == null or spec == null or _shooter == null or not _authority:
		return
	var before: String = _paper.owner_tag
	_paper.set_shooter(_shooter.weapon_tag(), spec.weapon_name)
	if _paper.owner_tag != before:
		_publish_paper()
	_dirty = true


func _on_paper_clear() -> void:
	if _paper == null or not _authority:
		return
	_paper.clear_group()
	_publish_paper()


## Fresh paper, on every machine. `restore()` is what a paper target does instead
## of standing back up, so the RESTORE event already means exactly this.
func _publish_paper() -> void:
	if _net == null or _paper == null or _resetting:
		return
	var index: int = _targets.find(_paper)
	_net.publish_target(index, RangeNetScript.Op.RESTORE, Vector3.ZERO, 0.0, false)


func _on_group_measured(spread_mm: float, shots: int, _gun_name: String) -> void:
	_group_mm = spread_mm
	_group_shots = shots
	_dirty = true


# --- arriving and leaving ----------------------------------------------------


## Somebody walked in. Hand them a gun if they have none — you do not arrive at a
## range empty-handed — and then hand them the whole state of the place.
func _on_state_wanted(id: int) -> void:
	if not _authority or _net == null:
		return
	if _net.loadout_of(id) == null and _bench != null and _bench.current() != null:
		_net.grant(id, WeaponHolster.PRIMARY_SLOT, _bench.current())
	var alive := PackedByteArray()
	var phase := PackedFloat32Array()
	alive.resize(_targets.size())
	phase.resize(_targets.size())
	for i: int in _targets.size():
		alive[i] = 1 if _targets[i].is_live() else 0
		phase[i] = _targets[i].track_phase
	_net.send_state(id, _dump(alive, phase))


func _dump(alive: PackedByteArray, phase: PackedFloat32Array) -> Dictionary:
	var guns: Dictionary = {}
	for row: Dictionary in _net.roster():
		var id: int = int(row[&"id"])
		var spec: GunSpec = _net.loadout_of(id)
		if spec != null:
			guns[id] = spec
	var dial: int = 0
	var lever: bool = false
	var stand: GunSpec = null
	if _bench != null:
		stand = _bench.current()
		dial = _bench.dial_index()
		lever = _bench.lever_on()
	return {
		&"bench": stand,
		&"dial": dial,
		&"lever": lever,
		&"loadouts": guns,
		&"scores": _score_rows(),
		&"alive": alive,
		&"phase": phase,
	}


## The whole range, as the host has it, applied in one go.
func _on_state_arrived(dump: Dictionary) -> void:
	if _bench != null:
		_bench.apply_state(
			dump.get(&"bench") as GunSpec,
			int(dump.get(&"dial", 0)),
			bool(dump.get(&"lever", false))
		)
	for id: int in dump.get(&"loadouts", {}) as Dictionary:
		var spec: GunSpec = (dump[&"loadouts"] as Dictionary)[id] as GunSpec
		if spec == null:
			continue
		_guns[id] = spec.weapon_name
		if id == _me:
			_take(WeaponHolster.PRIMARY_SLOT, spec)
	_on_scores_changed(dump.get(&"scores", []) as Array)
	_apply_sync(
		dump.get(&"alive", PackedByteArray()) as PackedByteArray,
		dump.get(&"phase", PackedFloat32Array()) as PackedFloat32Array
	)
	_dirty = true


## A client's peer id is 1 until its handshake lands, so who "I" am is re-read
## whenever the roster moves rather than trusted from `_ready`.
func _on_roster_changed() -> void:
	if _net == null:
		return
	_me = _net.local_peer()
	_authority = _net.is_authority()
	_dirty = true


# --- the tally ---------------------------------------------------------------


func _row_for(id: int) -> Dictionary:
	if not _tally.has(id):
		_tally[id] = {&"score": 0, &"hits": 0, &"spots": 0, &"downs": 0, &"streak": 0, &"best": 0}
	return _tally[id]


## The exported counters follow the LOCAL player's row and nobody else's, so
## `score`, `hits` and the rest still mean what they have always meant and
## single-player is byte-for-byte the behaviour it was.
func _mirror_local(id: int) -> void:
	if id != _me:
		return
	var tally: Dictionary = _row_for(_me)
	score = int(tally[&"score"])
	hits = int(tally[&"hits"])
	spot_hits = int(tally[&"spots"])
	knockdowns = int(tally[&"downs"])
	streak = int(tally[&"streak"])
	best_streak = int(tally[&"best"])


func _wipe_tally() -> void:
	_tally.clear()
	_mirror_local(_me)
	score = 0
	hits = 0
	spot_hits = 0
	knockdowns = 0
	streak = 0
	best_streak = 0
	_group_mm = 0.0
	_group_shots = 0
	_dirty = true
	_scores_dirty = true


# --- the placard -------------------------------------------------------------


func _write_lane() -> void:
	if _lane == null:
		return
	var rows: Array = [] if _net == null else _net.roster()
	if rows.size() <= 1:
		_write_solo()
		return
	_lane.set_title("SCORE  %d" % score)
	var lines := PackedStringArray()
	for row: Dictionary in rows:
		lines.append(_scoreboard_line(row))
	lines.append("")
	lines.append("%d of %d standing" % [_standing(), _targets.size()])
	_lane.set_lines(lines)


## One player's line. The colour word is their slot's — RED is always the host —
## because a placard is read at four metres and a name is not enough on its own.
func _scoreboard_line(row: Dictionary) -> String:
	var id: int = int(row[&"id"])
	var tally: Dictionary = _row_for(id)
	var mark: String = "*" if id == _me else " "
	return (
		"%s%-4s %-10s %5d  %2dh %2ds %2dk"
		% [
			mark,
			NetColors.slot_name(int(row[&"slot"])),
			String(row[&"name"]).left(10),
			int(tally[&"score"]),
			int(tally[&"hits"]),
			int(tally[&"spots"]),
			int(tally[&"downs"]),
		]
	)


func _write_solo() -> void:
	_lane.set_title("SCORE  %d" % score)
	var lines := PackedStringArray()
	lines.append("hits %d  ·  spots %d  ·  down %d" % [hits, spot_hits, knockdowns])
	lines.append("streak %d  ·  best %d" % [streak, best_streak])
	if _group_shots >= 3:
		lines.append("group %d mm at 25 m  ·  %d shots" % [roundi(_group_mm), _group_shots])
	elif _paper != null and not _paper.gun_name().is_empty():
		lines.append("paper: %s" % _paper.gun_name())
	else:
		lines.append("paper: clean")
	lines.append("%d of %d standing" % [_standing(), _targets.size()])
	_lane.set_lines(lines)


func _standing() -> int:
	var n: int = 0
	for target: RangeTarget in _targets:
		if target.is_live():
			n += 1
	return n


## Everyone appears to everyone. Called deferred from `_ready` — see the note there.
func _enter_presence() -> void:
	if _player != null:
		NetPresence.enter(NetPresence.FULL, _player.get_node_or_null(^"Eye") as Camera3D)


## Two lines on F3 that the placards deliberately do not carry: what the shot
## actually costs and what the roll actually was.
func _register_debug() -> void:
	if _shooter == null:
		return
	var hud: Node = get_node_or_null(^"/root/DebugHUD")
	if hud == null:
		return
	_shooter.weapon_changed.connect(_note_weapon.bind(hud))
	score_changed.connect(_note_score.bind(hud))
	_note_score(score, 0, hud)


func _note_weapon(spec: GunSpec, hud: Node) -> void:
	if spec == null:
		return
	(
		hud
		. call(
			&"note",
			&"range_gun",
			(
				"%s  %s  seed %d  ·  %.0f dmg  ·  %d m  ·  %s"
				% [
					spec.weapon_name,
					String(spec.archetype),
					spec.roll_seed,
					spec.damage,
					spec.effective_range,
					spec.spread_text,
				]
			)
		)
	)


func _note_score(points: int, _delta: int, hud: Node) -> void:
	hud.call(
		&"note",
		&"range_score",
		(
			"score %d  ·  hits %d  ·  spots %d  ·  standing %d  ·  %s"
			% [points, hits, spot_hits, _standing(), String(_guns.get(_me, "—"))]
		)
	)
