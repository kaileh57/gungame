class_name SplitGate
extends Area3D
## One arch on the speed loop. Passing between its posts reports an index to the
## `RunTimer`; the arch itself is welded into the course mesh and only the posts
## carry collision, so the opening is genuinely open.
##
## Ordering is the gate's business, not the timer's: a gate re-arms only after a
## different gate has fired, which is what stops standing in the finish line from
## logging a lap every physics tick.
##
## THE ARCH ALSO SAYS WHETHER IT IS THE ONE YOU WANT. Five identical rusty frames
## scattered over a sixty-metre yard is five things you cannot tell apart, which is why
## the loop was hard to follow at all. `set_next()` lights this gate's lamp, throws an
## eight-metre flare up out of the lintel and pulses both — and `RunTimer` lights exactly
## one gate at a time, so the answer to "where do I go" is the only lit thing on the
## course. It is a marker light on a marker post: diegetic, and readable from the bench.
##
## THE CHIME IS LOCAL AND ALWAYS LOCAL. Passing a gate is cosmetic on every machine but
## the one doing the passing, so nothing here is replicated. A remote player's avatar
## walking through gets the same chime, quieter, because hearing somebody else take the
## line is worth more than the two bytes it would cost to suppress it — and it is fired
## on a path that can never reach the timer.

## Someone ran through. `index` is this gate's place in the loop.
signal passed(index: int, gate: SplitGate)

## Instance uniforms declared by `hologram.gdshader`.
const P_TINT: StringName = &"holo_tint"
const P_ENERGY: StringName = &"holo_energy"
const P_SCAN: StringName = &"holo_scan"
## Metadata `CourseMarks` leaves on every emitter it builds.
const META_SCAN: StringName = &"holo_scan"

## Position in the loop. 0 is the start line; the highest index is the finish.
@export_range(0, 15, 1) var gate_index: int = 0
## Stencilled name, echoed onto the post's own board by `RunTimer`.
@export var gate_name: String = "SPLIT"
## Seconds this gate ignores a second body after firing. Only a backstop — the
## real guard is `arm()`.
@export_range(0.0, 4.0, 0.05) var refire_lockout: float = 0.75
@export var pass_sound: AudioStream = null
@export var lap_sound: AudioStream = null

@export_group("Marker")
## Colour of the lamp and the flare while this is the gate to head for.
@export var beacon_color: Color = Palette.GOLD
## Pulses per second. Slow enough to read as a beacon and not as a strobe.
@export_range(0.1, 4.0, 0.05) var pulse_hz: float = 0.75
@export_range(0.0, 4.0, 0.05) var pulse_low: float = 0.34
@export_range(0.0, 6.0, 0.05) var pulse_high: float = 1.05
@export_range(0.0, 16.0, 0.1) var glow_low: float = 0.8
@export_range(0.0, 16.0, 0.1) var glow_high: float = 2.2
## Board colour when this gate is next, and when it is not.
@export var board_next: Color = Palette.GOLD
@export var board_rest: Color = Color(0.62, 0.60, 0.54)
## How much quieter another player's pass is than your own.
@export_range(-40.0, 0.0, 0.5) var remote_db: float = -9.0

var _armed: bool = true
var _last_ms: int = -100000
var _remote_ms: int = -100000
var _is_next: bool = false
var _phase: float = 0.0
var _line: String = ""
var _emitters: Array[GeometryInstance3D] = []

@onready var _board: Label3D = get_node_or_null(^"Board") as Label3D
@onready var _sound: AudioStreamPlayer3D = get_node_or_null(^"Sound") as AudioStreamPlayer3D
@onready var _beacon: Node3D = get_node_or_null(^"Beacon") as Node3D
@onready var _glow: OmniLight3D = get_node_or_null(^"Beacon/Glow") as OmniLight3D


func _ready() -> void:
	# The player's body is the only thing on PLAYER, and the arch never moves, so
	# monitorable is dead weight here.
	collision_layer = 0
	collision_mask = GameLayers.PLAYER
	monitorable = false
	body_entered.connect(_on_body_entered)
	_collect_emitters(_beacon)
	if _glow != null:
		_glow.light_color = beacon_color
	set_process(false)
	_paint(pulse_low, glow_low)
	_write_board()


func _process(delta: float) -> void:
	# Deliberately unscaled by nothing: the slow-motion lever slows the world and the
	# beacon slows with it, which is the honest read of a course running at 0.32x.
	_phase = fmod(_phase + delta * pulse_hz, 1.0)
	var k: float = 0.5 - 0.5 * cos(_phase * TAU)
	_paint(lerpf(pulse_low, pulse_high, k), lerpf(glow_low, glow_high, k))


## Ready to fire again. The timer calls this on every OTHER gate when one trips.
func arm() -> void:
	_armed = true


func disarm() -> void:
	_armed = false


## Make this the gate the course is pointing at, or stop being it.
func set_next(on: bool) -> void:
	if _is_next == on:
		return
	_is_next = on
	if _beacon != null:
		_beacon.visible = on
	set_process(on)
	if not on:
		_paint(pulse_low, glow_low)
	_write_board()


## Write the board bolted to this gate's post. Two lines: the gate's name and
## whatever the timer wants to say about it.
func set_board(line: String) -> void:
	_line = line
	_write_board()


## The chime for crossing this gate. Called by `RunTimer`, which is the only thing that
## knows whether a crossing was a split or a lap.
func play_pass() -> void:
	_play(pass_sound, 0.0)


func play_lap() -> void:
	_play(lap_sound, 0.0)


func _on_body_entered(body: Node3D) -> void:
	if body is not PlayerController:
		_remote_pass(body)
		return
	if not _armed:
		return
	var now: int = Time.get_ticks_msec()
	if now - _last_ms < int(refire_lockout * 1000.0):
		return
	_last_ms = now
	_armed = false
	passed.emit(gate_index, self)


## Somebody else's avatar came through. Nothing about the run changes; you just hear it.
## Rate-limited on its own clock so four avatars overlapping in an arch is one chime.
func _remote_pass(body: Node3D) -> void:
	if pass_sound == null or not _is_avatar(body):
		return
	var now: int = Time.get_ticks_msec()
	if now - _remote_ms < int(refire_lockout * 1000.0):
		return
	_remote_ms = now
	_play(pass_sound, remote_db)


## Whether a body belongs to a remote player's avatar. The collider is a couple of levels
## under the `PlayerAvatar` node, so this walks up rather than testing the body itself.
static func _is_avatar(body: Node3D) -> bool:
	var walk: Node = body
	var depth: int = 0
	while walk != null and depth < 3:
		if walk is PlayerAvatar:
			return true
		walk = walk.get_parent()
		depth += 1
	return false


func _play(stream: AudioStream, db: float) -> void:
	if _sound == null or stream == null:
		return
	_sound.stream = stream
	_sound.volume_db = db
	_sound.play()


func _write_board() -> void:
	if _board == null:
		return
	var head: String = "> %s <" % gate_name if _is_next else gate_name
	_board.text = "%s\n%s" % [head, _line]
	_board.modulate = board_next if _is_next else board_rest


## Push the pulse onto every emitter under the beacon, plus the lamp's own light.
func _paint(energy: float, light: float) -> void:
	for geom: GeometryInstance3D in _emitters:
		geom.set_instance_shader_parameter(P_ENERGY, energy)
	if _glow != null:
		_glow.light_energy = light


## The beacon's emitters, and the two constants that never change on them. `holo_scan`
## comes off the metadata the baker left, so the lamp head and the flare wear one
## material and still read as different things.
func _collect_emitters(node: Node) -> void:
	if node == null:
		return
	for child: Node in node.get_children():
		var geom := child as GeometryInstance3D
		if geom != null and geom.has_meta(META_SCAN):
			geom.set_instance_shader_parameter(P_TINT, beacon_color)
			geom.set_instance_shader_parameter(P_SCAN, float(geom.get_meta(META_SCAN)))
			_emitters.append(geom)
		_collect_emitters(child)
