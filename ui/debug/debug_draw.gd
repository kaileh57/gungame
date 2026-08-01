class_name UiDebugDraw
extends MeshInstance3D
## Immediate-mode line drawing for the F3 overlay's 3D channels, and the three AI
## channels themselves.
##
## This is the one place in the project that builds geometry at runtime, and it is
## allowed to because it draws no assets: it draws lines that describe assets. An
## AI path, a sight cone, a cover point and a collision hull have no baked form —
## they exist only for the frame you are looking at them.
##
## Cost is zero when nothing is drawn: `flush()` with an empty surface clears the
## mesh and the instance renders nothing. One material, one surface, one draw call
## for every channel combined.
##
## Usage, from inside a channel drawer:
## [codeblock]
## func _draw_paths(d: UiDebugDraw) -> void:
##     d.polyline(agent.path_points, Color.CYAN)
##     d.cone(eye, forward, deg_to_rad(55.0), 18.0, Color.YELLOW)
## [/codeblock]
##
## THE STROKE FONT. Everything the AI channels have to say is a word — SEARCHING,
## SUPPRESSOR, ROUTING — and a line renderer that cannot write cannot say any of
## them. `billboard_text` draws a five-by-seven stroke font out of the same line
## batch, so a label costs a handful of vertices in the surface that was already
## being built and needs no second material, no sprite atlas and no Control. It is
## the difference between an overlay that shows you coloured sticks and one you
## can read a squad's intentions off.
##
## THE AI CHANNELS. They are registered here rather than by a demo director on
## purpose: every scene with bodies in it should get them, and a demo that forgets
## to publish its own is exactly the demo you need them in. They are read-only —
## they walk the `ai_target` group, resolve each body's head through the
## documented `EnemyActor.brain` slot when it is filled, and degrade to what the
## body itself knows when it is not.

const MATERIAL_PATH: String = "res://data/ui/debug_lines.tres"
## Segments in a debug circle. Sixteen reads as round and costs 32 vertices.
const RING_SEGMENTS: int = 16
## Characters the stroke font knows, in the order `GLYPHS` defines them.
const CHARS: String = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 .:-/+()?!%*"
## One entry per character of `CHARS`. Space-separated runs; each run is a
## polyline and each pair of digits is an (x, y) point on a 4 wide by 6 tall grid
## with y up. Empty draws nothing, which is what a space is.
const GLYPHS: PackedStringArray = [
	"0004264440 0242",
	"00063645443303 3342413000",
	"4536160501103041",
	"00062644422000",
	"46060040 0333",
	"460600 0333",
	"453616050110304143 4323",
	"0006 4046 0343",
	"1030 2026 1636",
	"3631201001",
	"0006 460340",
	"060040",
	"0006234640",
	"00064046",
	"011030414536160501",
	"00063645443303",
	"011030414536160501 2240",
	"00063645443303 2340",
	"45361605044241301001",
	"0646 2620",
	"060110304146",
	"062046",
	"0610233046",
	"0046 0640",
	"062346 2320",
	"06460040",
	"011030414536160501 0440",
	"142620 1030",
	"05163645440040",
	"0646234241301001",
	"30360242",
	"460604344341301001",
	"453616050110304142331302",
	"064610",
	"13040516364544331302011030414233",
	"011030414536160504133344",
	"",
	"2021",
	"2122 2425",
	"0343",
	"0046",
	"0343 2125",
	"36141230",
	"16343210",
	"05163645442322 2021",
	"2622 2021",
	"0046 0506 3040",
	"2125 0244 0442",
]
## Grid the glyphs are authored on. Width includes the inter-character gap.
const GLYPH_W: float = 6.0
const GLYPH_H: float = 6.0

## Debug-draw channel ids this class publishes. The four well-known ids on
## `DebugHUD` are left for a demo director that wants to draw its own.
const CHANNEL_BODIES: StringName = &"ai bodies"
const CHANNEL_VISION: StringName = &"ai vision"
const CHANNEL_NOISE: StringName = &"ai noise"
## Seconds between re-walks of the `ai_target` group.
const AGENT_REFRESH: float = 0.5
## Bodies drawn per channel, nearest first. An overlay is a diagnostic, not a
## renderer, and sixty labelled agents is unreadable as well as expensive.
const AGENT_LIMIT: int = 18
## Metres past which a body is not worth annotating.
const AGENT_RADIUS: float = 70.0
## Bodies whose PATH, goal and target line are drawn, nearest first. Far below
## `AGENT_LIMIT` on purpose: eighteen solved corridors across a two-hundred-metre
## pad is a spiderweb over the whole frame and it buries the labels underneath it.
## Four is what you can follow.
const DETAIL_LIMIT: int = 4
## Metres past which a goal or a route point is not labelled.
const DETAIL_RANGE: float = 30.0
## World height of one line of label text, metres.
const LABEL_SIZE: float = 0.19
## Noise-bus events shown, newest first, and the seconds one stays on screen.
const NOISE_LIMIT: int = 24
const NOISE_LIFE: float = 1.6
## Largest audible radius still drawn as an outline, metres.
const NOISE_OUTLINE_MAX: float = 34.0
## Metres past which a noise event is not labelled.
const NOISE_LABEL_RANGE: float = 38.0
## Levels below the scene root searched for a director holding the agent heads.
const HEAD_DEPTH: int = 4

## Alert state names, indexed by `AIAlertness.State`. Restated here rather than
## read from the class for the reason `_invoke` sets out: this drawer is built by
## an autoload and must not be able to fail to compile because an AI file is being
## edited. Five display strings is a cheap price for that.
const STATE_WORDS: PackedStringArray = ["IDLE", "SUSPICIOUS", "SEARCHING", "ENGAGED", "LOSING"]
## Names the two shipped brains give the same three members. Tried in order.
const ALERT_NAMES: PackedStringArray = ["alert", "alertness"]
const NAV_NAMES: PackedStringArray = ["nav", "navigator"]
const PERCEPTION_NAMES: PackedStringArray = ["perception"]

## Alert state colours, indexed by `AIAlertness.State`.
const STATE_COLORS: PackedColorArray = [
	Color(0.42, 0.46, 0.38),
	Color(0.86, 0.74, 0.30),
	Color(0.88, 0.52, 0.18),
	Color(0.85, 0.24, 0.20),
	Color(0.62, 0.32, 0.52),
]
## Morale colours, indexed by `AIMorale.State`.
const MORALE_COLORS: PackedColorArray = [
	Color(0.50, 0.62, 0.42),
	Color(0.80, 0.72, 0.34),
	Color(0.86, 0.48, 0.22),
	Color(0.90, 0.20, 0.28),
]

var _mesh: ImmediateMesh = null
var _material: Material = null
var _open: bool = false
var _vertices: int = 0
var _agents: Array[Node3D] = []
## Perceptions currently recording their rays for the vision channel.
var _captured: Array[Object] = []
## Actor instance id to the head driving it, rebuilt with the agent list.
var _heads: Dictionary = {}
## Seconds-since-boot the group was last walked. Negative so the first ask walks.
var _agent_age: float = -999.0
var _camera_x: Vector3 = Vector3.RIGHT
var _camera_y: Vector3 = Vector3.UP


func _ready() -> void:
	_mesh = ImmediateMesh.new()
	mesh = _mesh
	_material = _load_material()
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	# The AABB of an immediate mesh trails a frame behind its contents; a generous
	# cull margin is cheaper than the flicker that comes from getting it wrong.
	extra_cull_margin = 16384.0
	visible = false
	# Deferred so the host autoload has finished registering its own channels
	# first: the ctrl+number shortcuts are positional, and collision and nav have
	# been ctrl+1 and ctrl+2 since before this file drew anything.
	_register_channels.call_deferred()


## Start a frame. Everything drawn before the matching `flush()` lands in one
## surface. Calling this twice without a flush discards the first batch.
func begin() -> void:
	# clear_surfaces() closes an open surface as well as dropping the finished
	# ones. surface_end() would be wrong here: on an empty surface it errors, and a
	# channel that had nothing to say this frame is the common case, not a fault.
	_mesh.clear_surfaces()
	_mesh.surface_begin(Mesh.PRIMITIVE_LINES, _material)
	_open = true
	_vertices = 0


## Close the frame and show the result. Safe to call when nothing was drawn.
func flush() -> void:
	if not _open:
		return
	_open = false
	if _vertices == 0:
		_mesh.clear_surfaces()
		visible = false
		return
	_mesh.surface_end()
	visible = true


func vertex_count() -> int:
	return _vertices


func line(a: Vector3, b: Vector3, color: Color) -> void:
	if not _open:
		return
	_mesh.surface_set_color(color)
	_mesh.surface_add_vertex(a)
	_mesh.surface_set_color(color)
	_mesh.surface_add_vertex(b)
	_vertices += 2


## An open polyline through every point, in order. Fewer than two points draws
## nothing rather than erroring — a path that has not been solved yet is normal.
func polyline(points: PackedVector3Array, color: Color) -> void:
	for i: int in range(1, points.size()):
		line(points[i - 1], points[i], color)


## Wire box. `basis` carries rotation and scale; `size` is the full extent.
func box(origin: Vector3, basis: Basis, size: Vector3, color: Color) -> void:
	var h: Vector3 = size * 0.5
	var c: Array[Vector3] = []
	c.resize(8)
	for i: int in 8:
		var s := Vector3(
			-h.x if (i & 1) == 0 else h.x,
			-h.y if (i & 2) == 0 else h.y,
			-h.z if (i & 4) == 0 else h.z
		)
		c[i] = origin + basis * s
	const EDGES: Array[int] = [
		0, 1, 2, 3, 4, 5, 6, 7, 0, 2, 1, 3, 4, 6, 5, 7, 0, 4, 1, 5, 2, 6, 3, 7
	]
	for i: int in range(0, EDGES.size(), 2):
		line(c[EDGES[i]], c[EDGES[i + 1]], color)


## Circle of `radius` about `center`, lying in the plane spanned by `u` and `v`.
func ring(center: Vector3, u: Vector3, v: Vector3, radius: float, color: Color) -> void:
	var prev: Vector3 = center + u * radius
	for i: int in range(1, RING_SEGMENTS + 1):
		var a: float = TAU * float(i) / float(RING_SEGMENTS)
		var p: Vector3 = center + (u * cos(a) + v * sin(a)) * radius
		line(prev, p, color)
		prev = p


func sphere(center: Vector3, radius: float, color: Color) -> void:
	ring(center, Vector3.RIGHT, Vector3.UP, radius, color)
	ring(center, Vector3.RIGHT, Vector3.BACK, radius, color)
	ring(center, Vector3.UP, Vector3.BACK, radius, color)


## Upright capsule, Y-aligned in the given basis, matching CapsuleShape3D's layout
## where `height` is the total tip-to-tip length.
func capsule(origin: Vector3, basis: Basis, radius: float, height: float, color: Color) -> void:
	var up: Vector3 = basis.y.normalized()
	var right: Vector3 = basis.x.normalized()
	var fwd: Vector3 = basis.z.normalized()
	var mid: float = maxf(height * 0.5 - radius, 0.0)
	var top: Vector3 = origin + up * mid
	var bot: Vector3 = origin - up * mid
	ring(top, right, fwd, radius, color)
	ring(bot, right, fwd, radius, color)
	for i: int in 4:
		var a: float = TAU * float(i) / 4.0
		var d: Vector3 = (right * cos(a) + fwd * sin(a)) * radius
		line(top + d, bot + d, color)
	line(top + up * radius, top + right * radius, color)
	line(top + up * radius, top - right * radius, color)
	line(bot - up * radius, bot + fwd * radius, color)
	line(bot - up * radius, bot - fwd * radius, color)


func cylinder(origin: Vector3, basis: Basis, radius: float, height: float, color: Color) -> void:
	var up: Vector3 = basis.y.normalized()
	var right: Vector3 = basis.x.normalized()
	var fwd: Vector3 = basis.z.normalized()
	var top: Vector3 = origin + up * height * 0.5
	var bot: Vector3 = origin - up * height * 0.5
	ring(top, right, fwd, radius, color)
	ring(bot, right, fwd, radius, color)
	for i: int in 4:
		var a: float = TAU * float(i) / 4.0
		var d: Vector3 = (right * cos(a) + fwd * sin(a)) * radius
		line(top + d, bot + d, color)


## A perception cone: four rays out to `distance` and the cap ring they subtend.
## `half_angle` is in radians, which is how every sight solver stores it.
func cone(
	origin: Vector3, direction: Vector3, half_angle: float, distance: float, color: Color
) -> void:
	var f: Vector3 = direction.normalized()
	if f.is_zero_approx():
		return
	var up: Vector3 = Vector3.UP if absf(f.y) < 0.95 else Vector3.BACK
	var r: Vector3 = f.cross(up).normalized()
	var u: Vector3 = r.cross(f).normalized()
	var cap: Vector3 = origin + f * (distance * cos(half_angle))
	var rad: float = distance * sin(half_angle)
	ring(cap, r, u, rad, color)
	for i: int in 4:
		var a: float = TAU * float(i) / 4.0
		line(origin, cap + (r * cos(a) + u * sin(a)) * rad, color)


## Three-axis tick. The cheapest way to say "something is here".
func cross_mark(point: Vector3, size: float, color: Color) -> void:
	line(point - Vector3.RIGHT * size, point + Vector3.RIGHT * size, color)
	line(point - Vector3.UP * size, point + Vector3.UP * size, color)
	line(point - Vector3.BACK * size, point + Vector3.BACK * size, color)


## A line with a head on it. Says which way a relationship points, which a plain
## segment between two agents cannot.
func arrow(from: Vector3, to: Vector3, color: Color) -> void:
	line(from, to, color)
	var d: Vector3 = to - from
	var l: float = d.length()
	if l < 1e-3:
		return
	d /= l
	var side: Vector3 = d.cross(Vector3.UP)
	if side.length_squared() < 1e-6:
		side = d.cross(Vector3.BACK)
	side = side.normalized() * minf(l * 0.12, 0.35)
	var back: Vector3 = to - d * minf(l * 0.22, 0.7)
	line(to, back + side, color)
	line(to, back - side, color)


## A horizontal meter, drawn facing the camera. `fraction` fills from the left.
func bar(at: Vector3, fraction: float, width: float, color: Color) -> void:
	_face_camera()
	var half: float = width * 0.5
	var a: Vector3 = at - _camera_x * half
	var b: Vector3 = at + _camera_x * half
	var tick: Vector3 = _camera_y * (width * 0.09)
	line(a - tick, a + tick, color)
	line(b - tick, b + tick, color)
	line(a, b, Color(color, 0.35))
	var f: float = clampf(fraction, 0.0, 1.0)
	if f > 0.0:
		line(a, a + _camera_x * (width * f), color)


## Stroke text, centred on `at`, always square to the camera. Unknown characters
## are skipped rather than boxed: a missing glyph should cost nothing to read past.
func billboard_text(at: Vector3, text: String, size: float, color: Color) -> void:
	_face_camera()
	text_at(at, _camera_x, _camera_y, text, size, color)


## Stroke text on an arbitrary plane. `right` and `up` are unit vectors; the run
## is centred on `origin`, which is what makes a label sit over a body rather than
## trailing off to one side of it.
func text_at(
	origin: Vector3, right: Vector3, up: Vector3, text: String, size: float, color: Color
) -> void:
	var upper: String = text.to_upper()
	var scale: float = size / GLYPH_H
	var advance: float = GLYPH_W * scale
	var start: Vector3 = origin - right * (advance * float(upper.length()) * 0.5)
	for i: int in upper.length():
		var index: int = CHARS.find(upper[i])
		if index >= 0:
			_stroke(start + right * (advance * float(i)), right, up, scale, GLYPHS[index], color)


## Draw one CollisionShape3D in world space. Concave trimeshes are drawn as their
## bounding box: a town's collision soup is a hundred thousand edges and drawing
## it honestly would cost more than the game it is meant to debug.
func collision_shape(node: CollisionShape3D, color: Color) -> void:
	var shape: Shape3D = node.shape
	if shape == null:
		return
	var xf: Transform3D = node.global_transform
	if shape is BoxShape3D:
		box(xf.origin, xf.basis, (shape as BoxShape3D).size, color)
	elif shape is SphereShape3D:
		sphere(xf.origin, (shape as SphereShape3D).radius * xf.basis.get_scale().x, color)
	elif shape is CapsuleShape3D:
		var cap := shape as CapsuleShape3D
		capsule(xf.origin, xf.basis, cap.radius, cap.height, color)
	elif shape is CylinderShape3D:
		var cyl := shape as CylinderShape3D
		cylinder(xf.origin, xf.basis, cyl.radius, cyl.height, color)
	elif shape is WorldBoundaryShape3D:
		var plane: Plane = (shape as WorldBoundaryShape3D).plane
		var centre: Vector3 = xf * (plane.normal * plane.d)
		ring(centre, xf.basis.x.normalized(), xf.basis.z.normalized(), 20.0, color)
	elif shape is SeparationRayShape3D:
		line(xf.origin, xf * (Vector3.UP * (shape as SeparationRayShape3D).length), color)
	else:
		var aabb: AABB = shape.get_debug_mesh().get_aabb()
		box(xf * aabb.get_center(), xf.basis, aabb.size, color)


## Publish the AI channels to whoever owns this drawer.
##
## Through `get_parent()` and not through the `DebugHUD` autoload identifier, and
## that is not a stylistic preference. `debug_hud.gd` names `UiDebugDraw` to build
## this node; naming `DebugHUD` back from here closes a compile cycle, and the
## symptom is that every `--script` harness that statically references either
## class dies with "Identifier not found: DebugHUD" before it runs a line. The
## host is this node's parent by construction, so asking it directly is both
## cycle-free and more honest about the relationship.
func _register_channels() -> void:
	var host: Node = get_parent()
	if host == null or not host.has_method(&"add_channel"):
		return
	host.call(&"add_channel", CHANNEL_BODIES, "ai bodies", _draw_bodies)
	host.call(&"add_channel", CHANNEL_VISION, "ai vision", _draw_vision)
	host.call(&"add_channel", CHANNEL_NOISE, "ai noise", _draw_noise)
	if host.has_signal(&"channel_toggled"):
		if host.connect(&"channel_toggled", _on_channel_toggled) != OK:
			push_error("UiDebugDraw: could not connect to the host's channel_toggled.")


## Ray capture costs every watched agent two array appends per ray for as long as
## it is on, so it is switched off the moment the channel that asked for it is.
func _on_channel_toggled(id: StringName, enabled: bool) -> void:
	if id != CHANNEL_VISION or enabled:
		return
	_release_capture()


func _release_capture() -> void:
	for eyes: Object in _captured:
		if is_instance_valid(eyes):
			eyes.set(&"debug_capture", false)
	_captured.clear()


## One glyph, as one or more polyline runs of two-digit points.
func _stroke(
	origin: Vector3, right: Vector3, up: Vector3, scale: float, glyph: String, color: Color
) -> void:
	for run: String in glyph.split(" ", false):
		var count: int = run.length() / 2
		var prev: Vector3 = Vector3.ZERO
		for k: int in count:
			var x: float = float(run.unicode_at(k * 2) - 48) * scale
			var y: float = float(run.unicode_at(k * 2 + 1) - 48) * scale
			var p: Vector3 = origin + right * x + up * y
			if k > 0:
				line(prev, p, color)
			prev = p


func _face_camera() -> void:
	var camera: Camera3D = get_viewport().get_camera_3d()
	if camera == null:
		_camera_x = Vector3.RIGHT
		_camera_y = Vector3.UP
		return
	var b: Basis = camera.global_transform.basis
	_camera_x = b.x.normalized()
	_camera_y = b.y.normalized()


## Nearest living bodies, refreshed on a timer rather than every frame. The group
## walk allocates and this runs behind a toggle nobody leaves on.
func _visible_agents(eye: Vector3) -> Array[Node3D]:
	var tree: SceneTree = get_tree()
	if tree == null:
		return _agents
	var now: float = float(Time.get_ticks_msec()) * 0.001
	if now - _agent_age >= AGENT_REFRESH:
		_agent_age = now
		_refresh_heads(tree)
		_agents.clear()
		for node: Node in tree.get_nodes_in_group(&"ai_target"):
			var t := node as Node3D
			if t != null:
				_agents.append(t)
		_agents.sort_custom(
			func(a: Node3D, b: Node3D) -> bool:
				return (
					a.global_position.distance_squared_to(eye)
					< b.global_position.distance_squared_to(eye)
				)
		)
	return _agents


## The head driving this body.
##
## `EnemyActor.brain` is the documented slot and is tried first. Neither shipped
## director fills it, so there is a fallback: the directors keep their heads in a
## member called `_agents` or `_brains`, each entry carrying the `actor` it drives,
## and `_refresh_heads` builds the reverse map from that. Reaching a private
## member is not something shipping code should do, and this is not shipping code
## — it is the overlay the AI is judged by, and an overlay that cannot name a
## body's state prints IDLE over a body that is sprinting at you, which is worse
## than grubby. The moment a director assigns `brain`, the first branch wins and
## the fallback stops being consulted for that body.
func _brain_of(t: Node3D) -> Object:
	var actor: Node = t.get_parent()
	if actor == null:
		return null
	var held: Object = actor.get(&"brain") as Object
	if held != null:
		return held
	return _heads.get(actor.get_instance_id(), null) as Object


## Build the actor-to-head map from whatever director is in the scene. Shallow on
## purpose: a director sits within a few levels of the scene root, and probing a
## property on all eight thousand nodes of a town twice a second would cost more
## than everything else the overlay does put together.
func _refresh_heads(tree: SceneTree) -> void:
	_heads.clear()
	var scene: Node = tree.current_scene
	if scene == null:
		return
	var level: Array[Node] = [scene]
	for depth: int in HEAD_DEPTH:
		var next: Array[Node] = []
		for node: Node in level:
			_harvest(node.get(&"_agents"))
			_harvest(node.get(&"_brains"))
			for child: Node in node.get_children():
				next.append(child)
		if next.is_empty():
			break
		level = next


## Take every entry of an array or dictionary that carries an `actor`, and key it
## by that actor. Anything else in the container is ignored.
func _harvest(held: Variant) -> void:
	var rows: Array = []
	if held is Array:
		rows = held
	elif held is Dictionary:
		rows = (held as Dictionary).values()
	else:
		return
	for row: Variant in rows:
		var head: Object = row as Object
		if head == null:
			continue
		var actor: Object = head.get(&"actor") as Object
		if actor != null:
			_heads[actor.get_instance_id()] = head


## The first of `names` that this object actually carries, as an Object.
func _member(host: Object, names: PackedStringArray) -> Object:
	if host == null:
		return null
	for name: String in names:
		var found: Object = host.get(StringName(name)) as Object
		if found != null:
			return found
	return null


## A float off an object that may not have the property, with a stated fallback.
func _number(host: Object, name: StringName, fallback: float) -> float:
	if host == null:
		return fallback
	var held: Variant = host.get(name)
	if held is float or held is int:
		return float(held)
	return fallback


## Method call on an object that may not have the method. Everything the AI
## channels read goes through here or `_number`, and none of it names a class in
## `systems/ai/`. That is deliberate: this drawer is built by the `DebugHUD`
## autoload, so a compile error anywhere it statically referenced would take the
## whole game down to draw a debug line — and the AI module is the part of the
## project most likely to be mid-edit when you go looking for a debug line.
func _invoke(host: Object, name: StringName, fallback: Variant) -> Variant:
	if host == null or not host.has_method(name):
		return fallback
	return host.call(name)


## What every body is thinking, in words: alert state, morale, temperament,
## condition, and a line to whatever it believes it is fighting.
func _draw_bodies(target: UiDebugDraw) -> void:
	var camera: Camera3D = get_viewport().get_camera_3d()
	var eye: Vector3 = camera.global_position if camera != null else Vector3.ZERO
	var radius_sq: float = AGENT_RADIUS * AGENT_RADIUS
	var drawn: int = 0
	for t: Node3D in _visible_agents(eye):
		if drawn >= AGENT_LIMIT:
			break
		if not is_instance_valid(t) or not bool(t.get(&"alive")):
			continue
		var here: Vector3 = t.global_position
		if camera != null and here.distance_squared_to(eye) > radius_sq:
			continue
		_draw_one_body(target, t, here, drawn < DETAIL_LIMIT, eye)
		drawn += 1


func _draw_one_body(
	target: UiDebugDraw, t: Node3D, here: Vector3, detail: bool, eye: Vector3
) -> void:
	var brain: Object = _brain_of(t)
	var alert: Object = _member(brain, ALERT_NAMES)
	var state: int = clampi(int(_number(alert, &"state", 0.0)), 0, STATE_WORDS.size() - 1)
	var tint: Color = STATE_COLORS[state]
	var radius: float = _number(t, &"body_radius", 0.4)
	var lift: float = 0.55
	var offset: Variant = t.get(&"aim_offset")
	if offset is Vector3:
		lift += (offset as Vector3).y
	var top: Vector3 = here + Vector3(0.0, lift, 0.0)
	target.line(here, top, tint)
	target.ring(here + Vector3(0.0, 0.05, 0.0), Vector3.RIGHT, Vector3.BACK, radius, tint)
	var morale: Object = t.get(&"morale") as Object
	var head: String = "%s  %s" % [_species_of(t), STATE_WORDS[state]]
	if morale != null:
		head += "  " + String(_invoke(morale, &"state_name", "-"))
	target.billboard_text(top + Vector3(0.0, LABEL_SIZE * 2.6, 0.0), head, LABEL_SIZE, tint)
	target.billboard_text(
		top + Vector3(0.0, LABEL_SIZE * 1.3, 0.0), _detail_of(t, brain), LABEL_SIZE * 0.82, tint
	)
	var health: float = float(_invoke(t, &"health_fraction", 1.0))
	target.bar(top, health, 0.9, UiStyle.meter_color(health))
	if morale != null:
		var nerve: int = clampi(int(_number(morale, &"state", 0.0)), 0, MORALE_COLORS.size() - 1)
		target.bar(
			top - Vector3(0.0, LABEL_SIZE * 0.7, 0.0),
			_number(morale, &"morale", 1.0),
			0.9,
			MORALE_COLORS[nerve]
		)
	var flinch: float = float(_invoke(t, &"flinch_now", 0.0))
	if flinch > 0.01:
		var from: Vector3 = _invoke(t, &"hit_direction", Vector3.ZERO)
		target.arrow(top, top - from * (0.5 + flinch), UiStyle.WARN)
	if detail:
		_draw_intent(target, brain, here, tint, eye)


## Where the body has been told to go and what it thinks it is shooting at.
func _draw_intent(
	target: UiDebugDraw, brain: Object, here: Vector3, tint: Color, eye: Vector3
) -> void:
	if brain == null:
		return
	var believed: Variant = brain.get(&"_believed")
	if not (believed is Vector3):
		believed = brain.get(&"focus_position")
	if believed is Vector3 and (believed as Vector3) != Vector3.ZERO:
		var aim: Vector3 = believed
		target.arrow(here + Vector3(0.0, 1.0, 0.0), aim, UiStyle.WARN)
		target.cross_mark(aim, 0.3, UiStyle.WARN)
	var navigator: Object = _member(brain, NAV_NAMES)
	if navigator == null or not navigator.has_method(&"path_points"):
		return
	var path: PackedVector3Array = navigator.call(&"path_points")
	var up := Vector3(0.0, 0.1, 0.0)
	for i: int in range(1, path.size()):
		target.line(path[i - 1] + up, path[i] + up, tint)
	var goal: Vector3 = _invoke(navigator, &"goal", Vector3.ZERO)
	if goal == Vector3.ZERO:
		return
	target.ring(goal + up, Vector3.RIGHT, Vector3.BACK, 0.45, tint)
	if goal.distance_squared_to(eye) < DETAIL_RANGE * DETAIL_RANGE:
		target.billboard_text(goal + Vector3(0.0, 0.6, 0.0), "GOAL", LABEL_SIZE * 0.7, tint)


## What each body can actually see: the cone it is looking down — the SWEPT
## direction, not the shoulders — the lines it spent rays on, and where the last
## sound it reacted to seemed to come from.
func _draw_vision(target: UiDebugDraw) -> void:
	var camera: Camera3D = get_viewport().get_camera_3d()
	var eye: Vector3 = camera.global_position if camera != null else Vector3.ZERO
	var radius_sq: float = AGENT_RADIUS * AGENT_RADIUS
	var drawn: int = 0
	_release_capture()
	for t: Node3D in _visible_agents(eye):
		if drawn >= AGENT_LIMIT:
			break
		if not is_instance_valid(t) or not bool(t.get(&"alive")):
			continue
		var here: Vector3 = t.global_position
		if camera != null and here.distance_squared_to(eye) > radius_sq:
			continue
		var eyes: Object = _member(_brain_of(t), PERCEPTION_NAMES)
		if eyes == null or not eyes.has_method(&"gaze"):
			continue
		eyes.set(&"debug_capture", true)
		_captured.append(eyes)
		_draw_one_cone(target, t, eyes, drawn < DETAIL_LIMIT, eye)
		drawn += 1


func _draw_one_cone(
	target: UiDebugDraw, t: Node3D, eyes: Object, detail: bool, eye: Vector3
) -> void:
	var from: Vector3 = _invoke(t, &"eye_point", t.global_position)
	var half: float = acos(clampf(_number(eyes, &"cone_cos", -1.0), -1.0, 1.0))
	var calm: bool = bool(eyes.get(&"debug_calm"))
	var tint: Color = UiStyle.COOL if calm else UiStyle.ACCENT
	var gaze: Vector3 = _invoke(eyes, &"gaze", Vector3.FORWARD)
	if not detail:
		# A stick, not a cone. Eighteen thirty-metre cones is a wire ball that hides
		# the bodies it is drawn over; a two-metre stick still says where a guard is
		# looking, which is the only part of it you can act on at that range.
		target.line(from, from + gaze * 2.2, tint)
		return
	var reach: float = minf(_number(eyes, &"sight_far", 30.0), 30.0)
	target.cone(from, gaze, half, reach, tint)
	var near: float = _number(eyes, &"peripheral", 0.0)
	if near > 0.1:
		target.ring(from, Vector3.RIGHT, Vector3.BACK, near, Color(tint, 0.5))
	var starts: Variant = eyes.get(&"debug_ray_from")
	var ends: Variant = eyes.get(&"debug_ray_to")
	var clears: Variant = eyes.get(&"debug_ray_clear")
	if starts is PackedVector3Array and ends is PackedVector3Array:
		var rays: PackedVector3Array = starts
		var hits: PackedVector3Array = ends
		var flags: PackedInt32Array = clears
		for i: int in mini(rays.size(), hits.size()):
			var clear: bool = i < flags.size() and flags[i] != 0
			target.line(rays[i], hits[i], UiStyle.GOOD if clear else UiStyle.TEXT_FAINT)
	if _number(eyes, &"debug_heard_strength", 0.0) > 0.01:
		var at: Variant = eyes.get(&"debug_heard_at")
		if at is Vector3:
			target.cross_mark(at, 0.5, UiStyle.GOLD)
			target.line(from, at, Color(UiStyle.GOLD, 0.4))
	var routine: Object = eyes.get(&"idle") as Object
	var word: String = String(_invoke(routine, &"activity_name", "ALERT"))
	target.billboard_text(from + Vector3(0.0, 0.35, 0.0), word, LABEL_SIZE * 0.7, tint)
	if calm and detail:
		_draw_routine(target, t, routine, eye)


## The idle beat this body walks, where on it the body is headed, and who it is
## standing talking to. Only drawn while the body is calm, because none of it
## means anything once it is fighting.
func _draw_routine(target: UiDebugDraw, t: Node3D, routine: Object, eye: Vector3) -> void:
	if routine == null:
		return
	var beat: Variant = _invoke(routine, &"route", null)
	var up := Vector3(0.0, 0.12, 0.0)
	if beat is PackedVector3Array:
		var points: PackedVector3Array = beat
		for i: int in points.size():
			var a: Vector3 = points[i] + up
			target.ring(a, Vector3.RIGHT, Vector3.BACK, 0.25, Color(UiStyle.TEXT_DIM, 0.7))
			target.line(a, points[(i + 1) % points.size()] + up, Color(UiStyle.TEXT_DIM, 0.4))
	if bool(_invoke(routine, &"has_goal", false)):
		var goal: Vector3 = _invoke(routine, &"goal", Vector3.ZERO)
		target.cross_mark(goal + up, 0.3, UiStyle.GOOD)
		var pace: float = float(_invoke(routine, &"speed_scale", 0.0))
		if goal.distance_squared_to(eye) < DETAIL_RANGE * DETAIL_RANGE:
			target.billboard_text(
				goal + Vector3(0.0, 0.55, 0.0),
				"WALK %.0f%%" % (pace * 100.0),
				LABEL_SIZE * 0.6,
				UiStyle.GOOD
			)
	var friend: Vector3 = _invoke(routine, &"partner_position", Vector3.ZERO)
	if friend != Vector3.ZERO:
		var chest: Vector3 = t.global_position + Vector3(0.0, 1.2, 0.0)
		target.line(chest, friend + Vector3(0.0, 1.2, 0.0), Color(UiStyle.GOLD, 0.6))


## The global noise bus, as expanding rings. Nothing in the AI is more invisible
## than sound, and nothing explains a patrol walking off toward an empty street
## faster than seeing the gunshot it heard.
func _draw_noise(target: UiDebugDraw) -> void:
	var camera: Camera3D = get_viewport().get_camera_3d()
	var eye: Vector3 = camera.global_position if camera != null else Vector3.ZERO
	var head: int = AINoiseBus.cursor()
	var oldest: int = maxi(AINoiseBus.oldest(), head - NOISE_LIMIT)
	var now: float = float(Time.get_ticks_msec())
	for s: int in range(head - 1, oldest - 1, -1):
		if not AINoiseBus.has(s):
			continue
		var age: float = (now - AINoiseBus.event_time(s)) * 0.001
		if age > NOISE_LIFE:
			continue
		var at: Vector3 = AINoiseBus.event_position(s)
		var reach: float = AINoiseBus.event_radius(s)
		var fade: float = 1.0 - age / NOISE_LIFE
		var tint := Color(Palette.faction_color(AINoiseBus.event_faction(s)), fade)
		# A stalk, because a flat ring on the ground seen from head height is a
		# horizontal line and tells you nothing about where the sound came from.
		target.line(at, at + Vector3(0.0, 1.6 * fade, 0.0), tint)
		target.ring(at, Vector3.RIGHT, Vector3.BACK, reach * (1.0 - fade), tint)
		# The audible edge, but only when it is small enough to read as a circle. A
		# rifle's sixty-metre ring at eye level is a line across the whole frame and
		# it buries everything else the channel is trying to say.
		if reach <= NOISE_OUTLINE_MAX:
			target.ring(at, Vector3.RIGHT, Vector3.BACK, reach, Color(tint, fade * 0.25))
		if at.distance_squared_to(eye) > NOISE_LABEL_RANGE * NOISE_LABEL_RANGE:
			continue
		target.billboard_text(
			at + Vector3(0.0, 1.9, 0.0),
			"%.2f  %.0fM" % [AINoiseBus.event_loudness(s), reach],
			LABEL_SIZE * 0.7,
			tint
		)


func _species_of(t: Node3D) -> String:
	var actor: Node = t.get_parent()
	var profile: Object = null if actor == null else actor.get(&"profile") as Object
	if profile == null:
		return "PLAYER" if _number(t, &"faction", 0.0) < 0.0 else "BODY"
	return String(profile.get(&"species_id"))


## The second label line: stance, light, temperament and whatever the weapon is
## doing. Everything on it is readable without a head being wired up.
func _detail_of(t: Node3D, brain: Object) -> String:
	var out: String = String(_invoke(t, &"stance_name", "STAND"))
	if not bool(_invoke(t, &"is_lit", true)):
		out += " SHADE"
	var eyes: Object = _member(brain, PERCEPTION_NAMES)
	if eyes != null:
		var who: Object = eyes.get(&"personality") as Object
		if who != null:
			out += " " + String(_invoke(who, &"label", ""))
		# The reaction window, made visible. A body labelled SPOTTING has something
		# in view and has not decided about it yet, and that is the single most
		# useful second in the whole state machine to be able to see.
		if _number(eyes, &"debug_reacting", 0.0) > 0.0:
			out += " SPOTTING"
	var actor: Node = t.get_parent()
	if actor == null:
		return out
	var gun: Object = null if actor == null else actor.get(&"weapon") as Object
	if gun == null:
		return out
	var rounds: Variant = gun.get(&"ammo")
	if rounds is int:
		out += " %d RD" % int(rounds)
	if bool(gun.get(&"in_cover")):
		out += " COVER"
	return out


func _load_material() -> Material:
	if ResourceLoader.exists(MATERIAL_PATH):
		var mat: Material = ResourceLoader.load(MATERIAL_PATH, "Material") as Material
		if mat != null:
			return mat
	push_warning("UiDebugDraw: %s is missing. Run res://tools/build_ui_assets.gd." % MATERIAL_PATH)
	var fallback := StandardMaterial3D.new()
	fallback.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	fallback.vertex_color_use_as_albedo = true
	fallback.disable_receive_shadows = true
	return fallback
