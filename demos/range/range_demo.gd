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

## The score changed. `delta_points` is what the last event was worth.
signal score_changed(score: int, delta_points: int)
## The range was reset: every target back up, the tally back to zero.
signal range_reset

const DEMO_ID: String = "range"

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
var _targets: Array[RangeTarget] = []
var _group_mm: float = 0.0
var _group_shots: int = 0
var _dirty: bool = true


func _ready() -> void:
	_player = get_node_or_null(player_path) as PlayerController
	_shooter = get_node_or_null(shooter_path) as RangeShooter
	_bench = get_node_or_null(bench_path) as WeaponBench
	_lane = get_node_or_null(lane_readout_path) as DiegeticReadout
	if _player != null:
		_player.set_spawn(spawn_point, spawn_yaw)
		_holster = _player.get_node_or_null(^"Eye/Holster") as WeaponHolster

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
	# put it in the player's hands: you walk into the bay holding something.
	if _bench != null and _bench.current() != null:
		_on_bench_rolled(_bench.current())
		_on_equip_requested(WeaponHolster.PRIMARY_SLOT, _bench.current())

	_register_debug()
	_write_lane()


func _process(_delta: float) -> void:
	if _dirty:
		_dirty = false
		_write_lane()


## Stand every target back up and zero the tally. Bound to the bench's RESET cap.
func reset_range() -> void:
	for target: RangeTarget in _targets:
		target.restore()
	score = 0
	hits = 0
	spot_hits = 0
	knockdowns = 0
	streak = 0
	best_streak = 0
	_group_mm = 0.0
	_group_shots = 0
	_dirty = true
	range_reset.emit()
	score_changed.emit(score, 0)
	if _shooter != null:
		_shooter.banner("RANGE CLEAR", 1.2)


func _collect_targets() -> void:
	_targets.clear()
	var parent: Node = get_node_or_null(targets_path)
	if parent == null:
		push_error("RangeDemo: no target group at %s." % targets_path)
		return
	_gather(parent)
	for target: RangeTarget in _targets:
		target.scored.connect(_on_scored.bind(target))
		target.registered.connect(_on_registered)
		target.downed.connect(_on_downed)
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


func _on_scored(
	points: int, at: Vector3, label: String, kind: StringName, _target: RangeTarget
) -> void:
	score += points
	_dirty = true
	score_changed.emit(score, points)
	if _shooter == null:
		return
	var finished: bool = kind == RangeTarget.POP_DOWN or kind == RangeTarget.POP_BOOM
	_shooter.report_hit(at, label, kind, finished, kind == RangeTarget.POP_CRIT)


func _on_registered(crit: bool, killed: bool) -> void:
	hits += 1
	streak += 1
	best_streak = maxi(best_streak, streak)
	if crit:
		spot_hits += 1
	if killed:
		knockdowns += 1
	if streak == streak_threshold and _shooter != null:
		_shooter.banner("%d STRAIGHT" % streak, 1.0)
	_dirty = true


func _on_downed(_target: RangeTarget, _reset_in: float) -> void:
	_dirty = true


func _on_group_measured(spread_mm: float, shots: int, _gun_name: String) -> void:
	_group_mm = spread_mm
	_group_shots = shots
	_dirty = true


func _on_bench_rolled(spec: GunSpec) -> void:
	if spec == null or _shooter == null:
		return
	_shooter.banner(
		"%s — %s" % [spec.weapon_name.to_upper(), String(spec.tier_name).to_upper()], 1.4
	)


func _on_equip_requested(slot: int, spec: GunSpec) -> void:
	if _holster == null or spec == null:
		return
	_holster.equip(slot, spec)
	if slot != _holster.active_slot:
		_holster.select(slot)


## New gun on the board means new paper: a group is one weapon's group or it is
## not a group. The tag carries the seed, so re-rolling the same name still
## papers over.
func _on_weapon_changed(spec: GunSpec) -> void:
	if _paper == null or spec == null or _shooter == null:
		return
	_paper.set_shooter(_shooter.weapon_tag(), spec.weapon_name)
	_dirty = true


func _on_paper_clear() -> void:
	if _paper != null:
		_paper.clear_group()


func _write_lane() -> void:
	if _lane == null:
		return
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
		"score %d  ·  hits %d  ·  spots %d  ·  standing %d" % [points, hits, spot_hits, _standing()]
	)
