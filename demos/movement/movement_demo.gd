class_name MovementDemo
extends Node3D
## Root of the movement playground.
##
## The course, the console and the loop gates are all baked into the scene by
## `res://tools/build_movement.gd`; this node builds nothing. It registers the
## demo with the router if the shipped table does not already carry it, publishes
## a trail channel on the F3 overlay, and pins one line of live numbers there so
## the same figures the console screen shows are readable while you are looking
## somewhere else.
##
## The trail is the reason this exists rather than being folded into the console.
## Watching the last few seconds of your own feet, in world space, from the
## freecam, is the fastest way to see what a jump arc actually did — and it is
## exactly what the F3 debug channels are for.

const DEMO_ID: String = "movement"
const DEMO_TITLE: String = "MOVEMENT BENCH"
const DEMO_BLURB: String = "Ledges, gaps, slopes, a stopwatch. Turn the dials until it feels right."
## Debug channel ids. Both off until you switch them on with ctrl+N.
const CHANNEL_TRAIL: StringName = &"movement trail"
const CHANNEL_PROBE: StringName = &"movement probe"
const NOTE_KEY: StringName = &"movement"

@export var player_path: NodePath = NodePath("Player")
@export var console_path: NodePath = NodePath("Console")
## Seconds of foot path kept. Four covers the longest jump on the course twice
## over; longer than that and the line stops reading as one movement.
@export_range(0.5, 20.0, 0.5) var trail_seconds: float = 4.0
## Trail samples per second. 30 is smooth at a sprint and costs 120 vectors.
@export_range(5.0, 120.0, 1.0) var trail_hz: float = 30.0
## How often the F3 note is rewritten. Formatting strings is the only per-frame
## cost this node has, so it is not done per frame.
@export_range(1.0, 30.0, 0.5) var note_hz: float = 6.0

var _player: PlayerController = null
var _console: MovementConsole = null
## Ring buffer of feet positions. Sized once; never reallocated.
var _trail: PackedVector3Array = PackedVector3Array()
var _trail_head: int = 0
var _trail_filled: int = 0
var _since_sample: float = 0.0
var _since_note: float = 0.0
var _scratch: PackedVector3Array = PackedVector3Array()


func _ready() -> void:
	_player = get_node_or_null(player_path) as PlayerController
	_console = get_node_or_null(console_path) as MovementConsole
	if _player == null:
		push_error("MovementDemo: player_path does not resolve to a PlayerController.")
		set_process(false)
		return
	_trail.resize(maxi(2, int(trail_seconds * trail_hz)))
	_scratch.resize(_trail.size())
	if not SceneRouter.has_demo(DEMO_ID):
		SceneRouter.register_demo(DEMO_ID, DEMO_TITLE, scene_file_path, DEMO_BLURB)
	DebugHUD.add_channel(CHANNEL_TRAIL, "movement trail", _draw_trail)
	DebugHUD.add_channel(CHANNEL_PROBE, "movement probe", _draw_probe)
	CombatReticle.mount(self).watch(get_node_or_null(^"Hands") as DiegeticInteractor)


func _exit_tree() -> void:
	# The overlay outlives the demo, so everything published to it is withdrawn
	# by hand. A channel left behind would hold a callable onto a freed node and
	# a stale trail would draw over the next demo.
	DebugHUD.clear_note(NOTE_KEY)
	DebugHUD.remove_channel(CHANNEL_TRAIL)
	DebugHUD.remove_channel(CHANNEL_PROBE)


func _process(delta: float) -> void:
	_sample_trail(delta)
	_since_note += delta
	if _since_note < 1.0 / maxf(note_hz, 1.0):
		return
	_since_note = 0.0
	DebugHUD.note(NOTE_KEY, _note_line())


func _sample_trail(delta: float) -> void:
	_since_sample += delta
	var period: float = 1.0 / maxf(trail_hz, 1.0)
	if _since_sample < period:
		return
	_since_sample = 0.0
	_trail[_trail_head] = _player.global_position
	_trail_head = (_trail_head + 1) % _trail.size()
	_trail_filled = mini(_trail_filled + 1, _trail.size())


func _note_line() -> String:
	var state: PlayerState = _player.state
	var line: String = (
		"%s  %.2f m/s  y %.2f  air %.2f s"
		% [state.name(), _player.speed, _player.global_position.y, _player.air]
	)
	if _console == null:
		return line
	var m: Dictionary = _console.measurements()
	return (
		"%s  |  peak %.2f  jump run %.2f / slide %.2f m  vault %.2f m"
		% [
			line,
			float(m[&"peak_speed"]),
			float(m[&"run_jump"]),
			float(m[&"slide_jump"]),
			float(m[&"last_vault"]),
		]
	)


## Oldest sample first, so the polyline runs the way you ran.
func _draw_trail(d: UiDebugDraw) -> void:
	if _trail_filled < 2:
		return
	_scratch.resize(_trail_filled)
	var start: int = (_trail_head - _trail_filled + _trail.size()) % _trail.size()
	for i: int in _trail_filled:
		_scratch[i] = _trail[(start + i) % _trail.size()]
	d.polyline(_scratch, UiStyle.ACCENT)
	d.cross_mark(_scratch[_trail_filled - 1], 0.14, UiStyle.GOLD)


## The body as the controller sees it: the live cylinder, the ground normal it is
## resolving against, and where the vault is aiming when one is running.
func _draw_probe(d: UiDebugDraw) -> void:
	var state: PlayerState = _player.state
	var body: Color = UiStyle.COOL if state.grounded else UiStyle.WARN
	d.cylinder(state.feet, Basis.IDENTITY, state.radius, state.height, body)
	if state.grounded:
		d.line(state.feet, state.feet + state.ground_normal * 0.9, UiStyle.GOOD)
	if not _player.is_mantling():
		return
	var mantle := _player.get(&"_mantle") as PlayerMantle
	if mantle != null:
		d.cross_mark(mantle.target(), 0.24, UiStyle.GOLD)
