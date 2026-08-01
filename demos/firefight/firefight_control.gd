class_name FirefightControl
extends Node3D
## Base for the things a spectator can actually operate: a physical object bolted
## to the ground that answers to being looked at.
##
## There is no screen-space UI in this demo and no crosshair to put one under. A
## control is selected by pointing the camera at it from within reach, which the
## spectator resolves once every few frames against everything in the
## `firefight_control` group. Selection is shown two ways, because one is never
## enough at a distance: the object's albedo brightens through the `tint`
## instance uniform, and the whole thing physically rises a few centimetres on
## its mount. The second cue is the one that reads across a hundred metres.
##
## Subclasses override `activate`. Everything else here is presentation.

## The spectator operated this control.
signal activated(control: FirefightControl)

## Meshes whose `tint` instance uniform is driven by focus. Any mesh using
## `scrap_surface.gdshader` works; anything else is skipped silently.
@export var tinted_paths: Array[NodePath] = []
## The node that lifts when focused. Usually the head of the post, not its base.
@export var lift_path: NodePath = NodePath()
## Metres the lifted node rises when this control has focus.
@export_range(0.0, 0.5, 0.005) var lift_height: float = 0.075
## How fast the lift and the tint chase their targets, in 1/s.
@export_range(1.0, 40.0, 0.5) var response: float = 12.0
## Albedo multiplier at full focus. Above about 2.5 the object blows out and
## stops reading as metal.
@export_range(1.0, 3.0, 0.05) var focus_gain: float = 1.85
## Base tint, before focus. Faction-coloured controls set this at bake time.
@export var base_tint: Color = Color(1.0, 1.0, 1.0, 1.0)
## Metres beyond which the spectator cannot operate this. Deliberately generous:
## a marker you have to land on is a marker you never use.
@export_range(2.0, 120.0, 0.5) var reach: float = 26.0

var _tinted: Array[GeometryInstance3D] = []
var _lift: Node3D = null
var _rest_y: float = 0.0
var _focus: float = 0.0
var _target: float = 0.0


func _ready() -> void:
	add_to_group(&"firefight_control")
	for p: NodePath in tinted_paths:
		var g := get_node_or_null(p) as GeometryInstance3D
		if g != null:
			_tinted.append(g)
	_lift = get_node_or_null(lift_path) as Node3D
	if _lift != null:
		_rest_y = _lift.position.y
	_apply(0.0)
	set_process(false)


func _process(delta: float) -> void:
	var k: float = 1.0 - exp(-response * minf(delta, 0.1))
	_focus = lerpf(_focus, _target, k)
	_apply(_focus)
	if absf(_focus - _target) < 0.002:
		_focus = _target
		_apply(_focus)
		set_process(false)


## Called by the spectator as the selection changes. Cheap enough to call every
## scan, but it only wakes `_process` when the value actually moves.
func set_focused(value: bool) -> void:
	var want: float = 1.0 if value else 0.0
	if is_equal_approx(want, _target):
		return
	_target = want
	set_process(true)


func is_focused() -> bool:
	return _target > 0.5


## What a physical sign next to this control would say. The spectator does not
## draw it; the bake puts it on a `Label3D` bolted to the post.
func caption() -> String:
	return ""


## Operate it. The base implementation only announces; subclasses do the work and
## should call `super()` so the announcement still happens.
func activate(_spectator: Node) -> void:
	activated.emit(self)


func _apply(f: float) -> void:
	var c: Color = base_tint.lerp(base_tint * focus_gain, f)
	c.a = base_tint.a
	for g: GeometryInstance3D in _tinted:
		g.set_instance_shader_parameter(&"tint", c)
	if _lift != null:
		_lift.position.y = _rest_y + lift_height * f
