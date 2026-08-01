class_name GunAudio
extends Node3D
## The one thing in the scene that plays gun sounds.
##
## Every weapon in the level — the player's, and every raider's — speaks through
## this single pooled service rather than owning players of its own. Forty enemies
## with six voices each would be two hundred and forty `AudioStreamPlayer3D` nodes
## mixing silence; this is `pool_size` of them, round-robined, and the oldest one
## loses when the pool runs dry. That is also the correct behaviour musically: in a
## firefight the newest shot is the one you need to hear.
##
## Resolution is by group, with a lazy fallback. A demo that wants to place the
## service (to park it under a pause-immune node, say) adds a `GunAudio` to the
## `gun_audio` group; a demo that does not gets one made for it the first time
## something fires. Either way `service()` returns the same node for the whole
## scene, so the pool is genuinely shared.
##
## Deferred cues — the shell-at-a-time reload, and the speed-of-sound delay on a
## distant impact — run off a fixed-size queue that is walked once a frame. It is
## preallocated: a reload must not allocate, because a reload happens while the
## player is being shot at.

## Group a scene-placed service joins. Also what `service()` searches.
const GROUP: StringName = &"gun_audio"
## Bus the whole weapon voice mixes into. Baked by `res://tools/bake_gun_audio.gd`
## with the reference's compressor, its 85 ms berm slapback and its 2.6 s tail.
## Missing, everything falls back to Master and only loses the room.
const BUS: StringName = &"Guns"
## Where the baked bank lives.
const BANK_PATH: String = "res://data/audio/gun_audio_bank.tres"
## Speed of sound, m/s. A hit at 200 m is heard six-tenths of a second after it is
## seen, and that gap is most of what sells distance on a range.
const SOUND_SPEED: float = 340.0
## Longest that delay is allowed to get. The reference's clamp.
const MAX_SOUND_DELAY: float = 1.2
## Actions that make a noise of their own behind the shot. A pump, a bolt and a
## break-action are worked by hand, so their clatter belongs to the reload, not to
## the round going off.
const CLATTERING_ACTIONS: Array[StringName] = [&"auto", &"semi", &"burst"]
## How far behind the shot that clatter sits, seconds.
const ACTION_DELAY: float = 0.030

## The scene's service. Held statically as well as by group because a weapon asks
## for it from inside `_ready`, which is exactly when the node it would be parented
## to is mid-`add_child` and the new service is therefore not yet findable by
## group. Cleared in `_exit_tree`, so a scene change gets a fresh pool.
static var _instance: GunAudio = null

## Voices mixing at once. Sixteen covers a four-way firefight with reloads.
@export_range(4, 64, 1) var pool_size: int = 16
## Deferred cues in flight. A tube reload alone queues eleven.
@export_range(8, 128, 1) var queue_size: int = 48
## Master trim for the whole weapon voice, decibels.
@export_range(-40.0, 12.0, 0.5) var volume_db: float = 0.0
## Distance at which a shot has fallen to half power, metres.
@export_range(2.0, 200.0, 1.0) var unit_size: float = 26.0
## Beyond this a shot is not mixed at all.
@export_range(50.0, 2000.0, 5.0) var max_distance: float = 900.0
## Impacts are attenuated by `clamp(1 - dist/attenuation_range, floor, 1)` on top
## of the ordinary distance falloff, which is the reference's own extra roll-off.
@export_range(50.0, 2000.0, 5.0) var attenuation_range: float = 420.0
@export_range(0.0, 1.0, 0.01) var attenuation_floor: float = 0.12
## Random pitch spread per shot, as a fraction. Identical repeats of one sample are
## what makes a baked gun sound like a baked gun.
@export_range(0.0, 0.2, 0.001) var pitch_jitter: float = 0.022

var _bank: GunAudioBank = null
var _players: Array[AudioStreamPlayer3D] = []
var _cues: Array[Cue] = []
var _next: int = 0
var _rand: XorShift32 = XorShift32.new(0x9E3779B9)


## The scene's service, made on first use if nobody placed one.
##
## The made-on-demand node is parented deferred. A weapon calls this from its own
## `_ready`, and a node whose children are still being set up refuses an immediate
## `add_child`; deferring costs one frame of silence at scene load and nothing
## else, and is the only way this can be called from where it is actually needed.
static func service(tree: SceneTree) -> GunAudio:
	if tree == null:
		return null
	if _instance != null and is_instance_valid(_instance):
		return _instance
	var found := tree.get_first_node_in_group(GROUP) as GunAudio
	if found != null:
		_instance = found
		return found
	var root: Node = tree.current_scene if tree.current_scene != null else tree.root
	if root == null:
		return null
	var made := GunAudio.new()
	made.name = "GunAudio"
	_instance = made
	root.add_child.call_deferred(made)
	return made


func _ready() -> void:
	add_to_group(GROUP)
	_instance = self
	if ResourceLoader.exists(BANK_PATH):
		_bank = ResourceLoader.load(BANK_PATH) as GunAudioBank
	if _bank == null or not _bank.is_complete():
		push_warning("GunAudio: no complete bank at %s — run bake_gun_audio.gd." % BANK_PATH)
		_bank = null
	var bus: StringName = BUS if AudioServer.get_bus_index(BUS) >= 0 else &"Master"
	for i: int in pool_size:
		var p := AudioStreamPlayer3D.new()
		p.bus = bus
		p.unit_size = unit_size
		p.max_distance = max_distance
		p.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
		add_child(p)
		_players.append(p)
	for i: int in queue_size:
		_cues.append(Cue.new())
	set_process(false)


func _exit_tree() -> void:
	if _instance == self:
		_instance = null


func _process(delta: float) -> void:
	var live: bool = false
	for cue: Cue in _cues:
		if not cue.active:
			continue
		cue.left -= delta
		if cue.left > 0.0:
			live = true
			continue
		cue.active = false
		_play(cue.stream, cue.at, cue.db, cue.pitch)
	if not live:
		set_process(false)


## One round leaving `at`. The band, the payload variant and the pitch bend all
## come out of the weapon's own derived voice.
##
## The shot samples are rendered with their band's own `lvl` already printed into
## them — the reference's saturation is level-dependent, so a shot baked flat and
## turned down afterwards would be the wrong shape, not just the wrong size. Only
## the clatter, whose level is a plain multiple of `lvl`, is trimmed at play time.
func shot(spec: GunSpec, at: Vector3) -> void:
	if _bank == null:
		return
	var voice: GunVoice = GunVoice.from_spec(spec)
	var sample: AudioStreamWAV = _bank.shot_for(voice)
	if sample == null:
		return
	_play(sample, at, volume_db, voice.pitch_scale() * _jitter())
	if _bank.action != null and GunTables.action_for(spec.fire_mode) in CLATTERING_ACTIONS:
		_queue_stream(
			_bank.action,
			at,
			ACTION_DELAY,
			volume_db + voice.volume_db(),
			voice.mech_hz / _bank.action_reference_hz
		)


## The trigger came back on nothing.
func dry_fire(at: Vector3) -> void:
	if _bank != null:
		_play(_bank.dry, at, volume_db, _jitter())


## The action is stuck.
func jammed(at: Vector3) -> void:
	if _bank != null:
		_play(_bank.jam, at, volume_db, _jitter())


func footstep(at: Vector3) -> void:
	if _bank != null:
		_play(_bank.step, at, volume_db - 4.0, _jitter())


## A diegetic control being worked. `hz` is the control's own note.
func click(hz: float, at: Vector3) -> void:
	if _bank == null:
		return
	_play(_bank.ui, at, volume_db, maxf(hz, 60.0) / _bank.ui_reference_hz)


## The reload of `spec`, spread over `seconds`. Range spec 19: a tube gun is a run
## of shells and a final bolt drop, a cylinder is three distinct movements, and
## everything else is a magazine out, in and home. The pattern is the feed's, so
## you can hear what somebody is reloading before you see it.
func reload_sequence(spec: GunSpec, seconds: float, at: Vector3) -> void:
	if _bank == null or _bank.clack == null or spec == null or seconds <= 0.0:
		return
	var feed := String(spec.feed)
	if feed == "tube":
		var n: int = clampi(spec.magazine, 1, 10)
		for i: int in n:
			var hz: float = 1500.0 + _rand.next() * 500.0
			_clack(_bank.clack, at, seconds * (0.08 + 0.82 * float(i) / float(n)), hz, 0.16)
		_clack(_bank.clack, at, seconds * 0.96, 900.0, 0.22)
		return
	if feed == "cylinder":
		_clack(_bank.clack, at, 0.05, 700.0, 0.20)
		_clack(_bank.clack, at, seconds * 0.45, 1200.0, 0.18)
		_clack(_bank.clack, at, seconds * 0.9, 520.0, 0.26)
		return
	_clack(_bank.clack, at, 0.04, 850.0, 0.22)
	_clack(_bank.clack, at, seconds * 0.55, 620.0, 0.24)
	_clack(_bank.clack, at, seconds * 0.92, 1700.0, 0.20)


## A round arriving. `listener_distance` is how far the hit is from the ear, and it
## buys the delay and the extra roll-off; `size` is the struck thing's scale in
## metres, which sets the ring of a steel plate.
func impact(kind: GunAudioBank.Impact, at: Vector3, listener_distance: float, size: float) -> void:
	if _bank == null:
		return
	var sample: AudioStreamWAV = _bank.impact_sample(kind)
	if sample == null:
		return
	var dist: float = maxf(listener_distance, 0.0)
	var att: float = clampf(1.0 - dist / attenuation_range, attenuation_floor, 1.0)
	var pitch: float = 1.0
	if kind == GunAudioBank.Impact.STEEL:
		# `f = clamp(1100/max(size,0.2), 220, 1700)` — a small plate rings high.
		pitch = clampf(1100.0 / maxf(size, 0.2), 220.0, 1700.0) / _bank.impact_reference_hz
	var db: float = volume_db + linear_to_db(att)
	var delay: float = clampf(dist / SOUND_SPEED, 0.0, MAX_SOUND_DELAY)
	if delay <= 0.0:
		_play(sample, at, db, pitch * _jitter())
	else:
		_queue_stream(sample, at, delay, db, pitch * _jitter())


## Where the ear is, for the impact delay. Returns 0 when there is no listener,
## which makes every impact instant — correct for a headless run.
func listener_distance(to: Vector3) -> float:
	var cam: Camera3D = get_viewport().get_camera_3d() if is_inside_tree() else null
	return 0.0 if cam == null else cam.global_position.distance_to(to)


## Silence everything and drop the queue. For a scene change or a hard pause.
func stop_all() -> void:
	for p: AudioStreamPlayer3D in _players:
		p.stop()
	for cue: Cue in _cues:
		cue.active = false
	set_process(false)


func has_bank() -> bool:
	return _bank != null


func _jitter() -> float:
	return 1.0 + (_rand.next() - 0.5) * 2.0 * pitch_jitter


func _clack(sample: AudioStreamWAV, at: Vector3, delay: float, hz: float, peak: float) -> void:
	var db: float = volume_db + linear_to_db(clampf(peak / _bank.clack_reference_peak, 0.02, 4.0))
	_queue_stream(sample, at, delay, db, hz / _bank.clack_reference_hz)


func _queue_stream(
	sample: AudioStreamWAV, at: Vector3, delay: float, db: float, pitch: float
) -> void:
	for cue: Cue in _cues:
		if cue.active:
			continue
		cue.stream = sample
		cue.at = at
		cue.left = maxf(delay, 0.0)
		cue.db = db
		cue.pitch = pitch
		cue.active = true
		set_process(true)
		return


## Round-robin. Taking the next slot unconditionally means a busy pool drops its
## oldest voice, which in a firefight is exactly the one you have stopped caring
## about.
func _play(sample: AudioStreamWAV, at: Vector3, db: float, pitch: float) -> void:
	if sample == null or _players.is_empty():
		return
	var p: AudioStreamPlayer3D = _players[_next]
	_next = (_next + 1) % _players.size()
	p.global_position = at
	p.stream = sample
	p.volume_db = db
	p.pitch_scale = clampf(pitch, 0.25, 4.0)
	p.play()


## One deferred sound. Preallocated, reused, never freed.
class Cue:
	extends RefCounted

	var stream: AudioStreamWAV = null
	var at: Vector3 = Vector3.ZERO
	var left: float = 0.0
	var db: float = 0.0
	var pitch: float = 1.0
	var active: bool = false
