class_name ExhibitBody
extends EnemyBody
## An `EnemyBody` on a plinth, running on a clock you own.
##
## A rack is for staring at. Two things a fighting body never needs become the
## whole point here: running the pose clock slower than real time, and playing a
## one-shot clip again without a fight to trigger it.
##
## `pace` scales the delta handed to the base body's clock and nothing else. A
## pose is a pure function of clip time, so a scaled clock is exact slow motion
## rather than an approximation of it — the feet land in the same places, they
## just take longer to get there.
##
## Looping is deliberately a dwell rather than an immediate restart. An attack
## that snaps back to frame zero the instant it ends reads as a stutter; a beat
## of stillness between takes reads as a rehearsal, which is what this is.

## Playback rate of the pose clock. 1.0 is real time.
@export_range(0.05, 3.0, 0.01) var pace: float = 1.0
## Replay one-shot clips — attack, stagger and death — instead of settling into
## the resume clip and staying there.
@export var loop_one_shots: bool = true
## Seconds of stillness between takes, measured on the scaled clock.
@export_range(0.0, 6.0, 0.05) var loop_dwell: float = 0.9
## Which of the five seeded collapses plays. Same seed and take fall identically.
@export_range(0, 4, 1) var take: int = 0
## A `VisibleOnScreenNotifier3D` wrapping this creature. While it is off screen
## the pose clock stops entirely — twelve rigs solving where nobody is looking is
## a third of the rack's frame spent on nothing. Stopping the clock rather than
## skipping the solve is what makes it free to resume: the clip picks up on the
## frame it was left on instead of jumping to where it would have got to.
@export var notifier_path: NodePath = NodePath()

## The clip the rack is showing, as opposed to the clip the base body happens to
## be running: after an attack ends, those differ until the dwell elapses.
var _shown: StringName = BeastClips.IDLE
var _dwell_left: float = 0.0
var _notifier: VisibleOnScreenNotifier3D = null


func _ready() -> void:
	super()
	clip_finished.connect(_on_clip_finished)
	collapse_settled.connect(_on_collapse_settled)
	_notifier = get_node_or_null(notifier_path) as VisibleOnScreenNotifier3D
	if _notifier == null:
		return
	# Start awake. `is_on_screen` is meaningless until the notifier has been
	# through a frame, and a creature that starts asleep in front of you and only
	# wakes when you look away is worse than one frame of wasted work.
	_notifier.screen_entered.connect(set_process.bind(true))
	_notifier.screen_exited.connect(set_process.bind(false))


func _process(delta: float) -> void:
	var scaled: float = delta * pace
	super._process(scaled)
	if _dwell_left <= 0.0:
		return
	_dwell_left -= scaled
	if _dwell_left <= 0.0:
		_restart()


## Show `clip`, restarting it if it is already showing. Unlike `play_clip`, asking
## for the clip you are already on is a replay, because on a rack that is the only
## way to see the first eight frames of an attack twice.
func show_clip(clip: StringName) -> void:
	_shown = clip
	_dwell_left = 0.0
	_restart()


## Pick a collapse take and, if death is what is showing, fall again on it.
func set_take(value: int) -> void:
	take = clampi(value, 0, 4)
	if _shown == BeastClips.DEATH:
		show_clip(BeastClips.DEATH)


func shown_clip() -> StringName:
	return _shown


## Put the shown clip back on frame zero. Death goes through `revive` so the
## collapse is re-seeded rather than resumed from a settled corpse; the one-shots
## bounce through idle because `play_clip` ignores a request for the current clip.
func _restart() -> void:
	if _shown == BeastClips.DEATH:
		revive(_death_seed(), take)
		collapse(take)
		return
	# A corpse refuses every clip but death, so stand it back up first. `revive`
	# leaves the body on idle, which is also the bounce the one-shots need.
	if is_dead():
		revive(_death_seed(), take)
	elif not shown_is_looping():
		play_clip(String(BeastClips.IDLE))
	play_clip(String(_shown))


## True for the clips that never end on their own, which therefore never need a
## bounce through idle to start over.
func shown_is_looping() -> bool:
	return _shown == BeastClips.IDLE or _shown == BeastClips.AIM or BeastClips.is_locomotion(_shown)


## Stable per-species collapse seed, so the same take falls the same way every
## time you press the button.
func _death_seed() -> int:
	return SpeciesTable.seed_for(species_id)


func _on_clip_finished(clip: StringName) -> void:
	if not loop_one_shots or clip == BeastClips.DEATH:
		return
	if clip != _shown:
		return
	_dwell_left = maxf(loop_dwell, 0.01)


func _on_collapse_settled() -> void:
	if not loop_one_shots or _shown != BeastClips.DEATH:
		return
	_dwell_left = maxf(loop_dwell, 0.01)
