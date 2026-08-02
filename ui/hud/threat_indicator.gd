class_name ThreatIndicator
extends Control
## "Who is shooting me, and from where." The screen-edge answer.
##
## Three things are drawn here and they are three answers to the same question at
## three different ranges of certainty:
##
##   * a screen-edge ARC on the bearing of whatever just put a round into or past
##     you, scaled by how much it cost and fading over a couple of seconds. This
##     is the only part that has to work when the shooter is behind you, which is
##     also the only case where nothing in the 3D scene can help;
##   * a CARET on the shooter itself for a moment after it fires at you, so the
##     arc resolves into a body rather than into a direction. It is deliberately
##     short — a moment, not a wallhack — and it is only ever raised for a shot
##     that came at YOU, so a three-way brawl does not paint the whole compound;
##   * a minimal VITALS strip, because the vignette tells you that you are hurt
##     and does not tell you how nearly dead you are.
##
## THE BEARING IS HORIZONTAL AND NOTHING ELSE. Projecting the source point and
## taking its screen offset is the obvious implementation and it is wrong in the
## one case the indicator exists for: a point behind the camera unprojects to a
## mirrored position, so the arrow points at the wrong half of the screen exactly
## when you cannot see the shooter. `atan2(right, forward)` has no such case —
## dead ahead is the top of the ring, dead behind is the bottom, and turning your
## head sweeps every live arc round it continuously.
##
## Nothing here allocates after `_ready`. The pool is fixed, the arrays are packed,
## and a threat arriving on a full pool takes the oldest slot.

## What raised a threat, which is what picks its colour and its weight curve.
enum Kind {
	## A round landed on you. The loudest thing this draws.
	HIT,
	## A round went past close enough to hear. Thinner, dimmer, shorter.
	NEAR,
}

## Slots. Twelve arcs is more distinct bearings than a screen can carry; past that
## the merge is what keeps the display readable, not the pool size.
const SLOTS: int = 12

@export_group("Arcs")
## Distance from the middle of the screen to the arc, as a fraction of the shorter
## screen axis. Far enough out to be peripheral, in far enough to survive a
## letterboxed window.
@export_range(0.3, 1.1, 0.01) var ring_fraction: float = 0.66
## Angular width of a full-weight arc, degrees.
@export_range(4.0, 90.0, 1.0) var arc_degrees: float = 26.0
## Fraction of that width the lightest possible threat still gets, so a graze is
## still a shape and not a dot.
@export_range(0.1, 1.0, 0.01) var arc_floor: float = 0.42
@export_range(1.0, 24.0, 0.5) var arc_thickness: float = 7.0
## Seconds a hit arc takes to fade out.
@export_range(0.2, 8.0, 0.05) var hit_seconds: float = 2.2
## Seconds a near-miss arc takes to fade out. Shorter on purpose: a miss is news
## for less time than a wound is.
@export_range(0.2, 8.0, 0.05) var near_seconds: float = 1.1
## Two threats whose bearings agree within this are ONE arc with a heavier weight
## rather than two arcs on top of each other. This is what makes four bodies on a
## firing line read as "that way, hard" instead of as a smear.
@export_range(1.0, 60.0, 1.0) var merge_degrees: float = 13.0
@export var hit_color: Color = Color(0.878, 0.243, 0.196)
@export var near_color: Color = Color(0.902, 0.757, 0.310)

@export_group("Shooter caret")
## Draw a caret over the body that fired at you.
@export var show_carets: bool = true
## Seconds the caret is held. Shorter than the arc: the arc is a bearing you may
## need for a while, the caret is an introduction.
@export_range(0.1, 4.0, 0.05) var caret_seconds: float = 0.9
## Half-width of the caret in pixels at `caret_reference` metres, scaled by range
## so a body across the compound still gets a mark you can see.
@export_range(4.0, 60.0, 1.0) var caret_size: float = 15.0
@export_range(4.0, 120.0, 1.0) var caret_reference: float = 26.0
@export_range(1.0, 8.0, 0.5) var caret_thickness: float = 2.5
## Metres above the source point the caret sits, so it clears the head rather than
## sitting on the chest where the muzzle is.
@export_range(0.0, 4.0, 0.05) var caret_lift: float = 1.1

@export_group("Vitals")
## The minimal health readout. The vignette is the feel; this is the number.
@export var show_vitals: bool = true
## Pips in the strip. Ten is one pip per ten per cent, which is readable without
## being a bar you stare at.
@export_range(4, 24, 1) var vital_pips: int = 10
@export_range(2.0, 40.0, 0.5) var vital_pip_width: float = 13.0
@export_range(1.0, 20.0, 0.5) var vital_pip_height: float = 4.0
@export_range(0.0, 12.0, 0.5) var vital_gap: float = 4.0
## Pixels up from the bottom of the screen the strip sits.
@export_range(8.0, 240.0, 1.0) var vital_margin: float = 34.0
## Health fraction at or below which the strip turns to the warning colour.
@export_range(0.0, 1.0, 0.01) var vital_warn_below: float = 0.34

var _camera: Camera3D = null
var _health: float = 1.0
var _point: PackedVector3Array = PackedVector3Array()
var _bearing: PackedFloat32Array = PackedFloat32Array()
var _weight: PackedFloat32Array = PackedFloat32Array()
var _age: PackedFloat32Array = PackedFloat32Array()
var _life: PackedFloat32Array = PackedFloat32Array()
var _kind: PackedInt32Array = PackedInt32Array()
## Whether the slot's weight came from a caller that knew what the hit COST, as
## opposed to one that only knew the bearing. See `add_threat` for why one round
## reaches this node twice and why the sized report has to win.
var _sized: PackedInt32Array = PackedInt32Array()
var _tag: Array[Node3D] = []
var _next: int = 0
var _live: int = 0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_point.resize(SLOTS)
	_bearing.resize(SLOTS)
	_weight.resize(SLOTS)
	_age.resize(SLOTS)
	_life.resize(SLOTS)
	_kind.resize(SLOTS)
	_sized.resize(SLOTS)
	_tag.resize(SLOTS)
	for i: int in SLOTS:
		_life[i] = 1.0
		_age[i] = 1.0
		_tag[i] = null
	set_process(true)


## The arcs are re-bearinged every frame rather than cached, because the whole
## point of them is that they sweep when you turn. That is `SLOTS` dot products
## and one `atan2` on the live ones only.
func _process(delta: float) -> void:
	var live: int = 0
	for i: int in SLOTS:
		if _age[i] >= _life[i]:
			continue
		_age[i] += delta
		if _age[i] < _life[i]:
			_bearing[i] = _bearing_to(_point[i])
			live += 1
	# A quiet screen costs nothing. The vitals strip is NOT a reason to redraw every
	# frame — a `Control`'s drawing persists until something asks for another one, and
	# the only thing that changes the strip is `set_health`, which queues its own.
	# The frame after the last arc dies still redraws, which is what erases it.
	if live == 0 and _live == 0:
		return
	_live = live
	queue_redraw()


## The camera bearings are taken from. Without one every arc points down, which is
## the honest failure — a direction that is obviously wrong beats one that looks
## right and is not.
func set_camera(camera: Camera3D) -> void:
	_camera = camera


## Health as a 0..1 fraction, for the vitals strip.
func set_health(fraction: float) -> void:
	var value: float = clampf(fraction, 0.0, 1.0)
	if is_equal_approx(value, _health):
		return
	_health = value
	queue_redraw()


## Something came at you from `world_point`. `weight` is 0..1 — for a hit, the
## fraction of your health it cost; for a near miss, how close it went. `source`
## is the body itself when the caller knows it, which is what raises the caret.
##
## `sized` says the weight was computed from real damage rather than assumed. ONE
## ROUND REACHES THIS NODE TWICE and that is not a bug to be fixed upstream: the
## health system knows the bearing and calls first, the demo's threat reader knows
## what the hit cost and calls second, and neither can be made to know the other's
## half without wiring the arena into `PlayerHealth`. What is fixed here is the
## arithmetic — see the merge below.
func add_threat(
	world_point: Vector3, weight: float, kind: int, source: Node3D = null, sized: bool = false
) -> void:
	var w: float = clampf(weight, 0.0, 1.0)
	var bearing: float = _bearing_to(world_point)
	var slot: int = _merge_slot(bearing, kind)
	if slot < 0:
		slot = _next
		_next = (_next + 1) % SLOTS
		_weight[slot] = w
		_sized[slot] = 1 if sized else 0
	elif _age[slot] > 0.0:
		# ACROSS frames, merging ADDS: a firing line reads heavier than one rifle on
		# the same bearing, and saturates rather than growing without limit.
		_weight[slot] = clampf(_weight[slot] + w * 0.65, 0.0, 1.0)
		_sized[slot] = _sized[slot] | (1 if sized else 0)
	else:
		# WITHIN one frame it is the same round reported twice, so adding would make
		# every hit read as half again what it cost — and a graze, whose unsized
		# report is a middling 0.55, would shout. The sized report wins outright;
		# with neither or both sized, the larger does.
		if sized and _sized[slot] == 0:
			_weight[slot] = w
			_sized[slot] = 1
		elif sized or _sized[slot] == 0:
			_weight[slot] = maxf(_weight[slot], w)
	_point[slot] = world_point
	_bearing[slot] = bearing
	_age[slot] = 0.0
	_life[slot] = hit_seconds if kind == Kind.HIT else near_seconds
	_kind[slot] = kind
	if source != null and is_instance_valid(source):
		_tag[slot] = source
	_live += 1
	queue_redraw()


## Drop every arc. A respawn, a scene reset, or the death iris closing.
func clear_threats() -> void:
	for i: int in SLOTS:
		_age[i] = _life[i]
		_tag[i] = null
	_live = 0
	queue_redraw()


func live_count() -> int:
	var n: int = 0
	for i: int in SLOTS:
		if _age[i] < _life[i]:
			n += 1
	return n


func _draw() -> void:
	var centre: Vector2 = size * 0.5
	var radius: float = minf(size.x, size.y) * 0.5 * ring_fraction
	for i: int in SLOTS:
		if _age[i] >= _life[i]:
			continue
		var fade: float = 1.0 - _age[i] / maxf(_life[i], 0.001)
		_draw_arc_for(i, centre, radius, fade)
		if show_carets and _age[i] < caret_seconds:
			_draw_caret(i, 1.0 - _age[i] / maxf(caret_seconds, 0.001))
	if show_vitals:
		_draw_vitals()


func _draw_arc_for(slot: int, centre: Vector2, radius: float, fade: float) -> void:
	var w: float = _weight[slot]
	var span: float = deg_to_rad(arc_degrees) * lerpf(arc_floor, 1.0, w)
	# Screen angles run clockwise from +X, and the ring is measured from straight
	# up, so the bearing is rotated back by a quarter turn to land on the screen.
	var mid: float = _bearing[slot] - PI * 0.5
	var tint: Color = hit_color if _kind[slot] == Kind.HIT else near_color
	# Fades on a square: the last third of the life is nearly gone rather than
	# lingering as a grey smear that reads as a live threat.
	tint.a = fade * fade * lerpf(0.45, 1.0, w)
	var thickness: float = arc_thickness * lerpf(0.55, 1.0, w)
	draw_arc(centre, radius, mid - span * 0.5, mid + span * 0.5, 24, tint, thickness, true)


func _draw_caret(slot: int, fade: float) -> void:
	var node: Node3D = _tag[slot]
	if node == null or not is_instance_valid(node) or not node.is_inside_tree():
		return
	if _camera == null or not is_instance_valid(_camera):
		return
	var at: Vector3 = node.global_position + Vector3(0.0, caret_lift, 0.0)
	if _camera.is_position_behind(at):
		return
	var p: Vector2 = _camera.unproject_position(at)
	var range_m: float = maxf(_camera.global_position.distance_to(at), 0.5)
	var half: float = caret_size * clampf(caret_reference / range_m, 0.35, 1.6)
	var tint: Color = hit_color if _kind[slot] == Kind.HIT else near_color
	tint.a = fade
	# A pair of brackets rather than a box: it reads as a mark placed ON something
	# instead of as a UI element floating in front of it.
	var arm: float = half * 0.45
	for sx: float in [-1.0, 1.0]:
		var corner := Vector2(p.x + half * sx, p.y - half)
		var foot := Vector2(p.x + half * sx, p.y + half)
		draw_line(corner, corner + Vector2(-arm * sx, 0.0), tint, caret_thickness, true)
		draw_line(corner, corner + Vector2(0.0, arm), tint, caret_thickness, true)
		draw_line(foot, foot + Vector2(-arm * sx, 0.0), tint, caret_thickness, true)
		draw_line(foot, foot + Vector2(0.0, -arm), tint, caret_thickness, true)


func _draw_vitals() -> void:
	var pips: int = maxi(vital_pips, 1)
	var span: float = float(pips) * vital_pip_width + float(pips - 1) * vital_gap
	var x: float = size.x * 0.5 - span * 0.5
	var y: float = size.y - vital_margin
	var lit: float = _health * float(pips)
	var on: Color = UiStyle.WARN if _health <= vital_warn_below else UiStyle.TEXT
	var pip := Vector2(vital_pip_width, vital_pip_height)
	var socket: Color = UiStyle.TEXT_FAINT
	socket.a = 0.45
	for i: int in pips:
		var corner := Vector2(x + float(i) * (vital_pip_width + vital_gap), y)
		draw_rect(Rect2(corner, pip), socket, true)
		var fill: float = clampf(lit - float(i), 0.0, 1.0)
		if fill <= 0.0:
			continue
		draw_rect(Rect2(corner, Vector2(pip.x * fill, pip.y)), Color(on.r, on.g, on.b, 0.92), true)


## Horizontal bearing of `world_point` from the camera: 0 straight ahead, positive
## to the right, +/-PI directly behind. See the class doc for why this is not a
## screen projection.
func _bearing_to(world_point: Vector3) -> float:
	if _camera == null or not is_instance_valid(_camera):
		return PI
	var to: Vector3 = world_point - _camera.global_position
	var basis: Basis = _camera.global_transform.basis
	var right: float = to.dot(basis.x)
	var forward: float = to.dot(-basis.z)
	if absf(right) < 1.0e-5 and absf(forward) < 1.0e-5:
		return PI
	return atan2(right, forward)


## A live slot of the same kind already pointing this way, or -1.
func _merge_slot(bearing: float, kind: int) -> int:
	var window: float = deg_to_rad(merge_degrees)
	for i: int in SLOTS:
		if _age[i] >= _life[i] or _kind[i] != kind:
			continue
		if absf(wrapf(_bearing[i] - bearing, -PI, PI)) <= window:
			return i
	return -1
