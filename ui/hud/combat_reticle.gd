class_name CombatReticle
extends Control
## The aim indicator. Where you are pointing, what is under it, and what a click or
## a round would do to it — in every demo, with or without a weapon in your hands.
##
## The project's UI rule is that a control is a physical object you shoot, and this
## is the one deliberate exception to it: you cannot aim a first-person weapon at
## something you cannot see yourself aiming at. So the exception is kept as small as
## it can be, and as much of it as possible is made to point at the WORLD rather
## than at the middle of the screen. Two styles, and the player picks:
##
##   DOT       a centre pip with a dark halo — it has to survive pale sand and pale
##             sky in the same frame — plus the weapon's real cone as four ticks and
##             the action cycle as an arc. The gap between the ticks is where the
##             round can land, so a bad gun visibly opens up and an optic closes it.
##   SELECTOR  the bestiary's selector bead, generalised. One ray from the eye finds
##             what is under the aim point and THE THING ITSELF is bracketed: gold
##             for a control a press would actuate, hot accent for something that
##             can be shot, dim bone for bare ground with the range beside it. A dot
##             says where the middle of the screen is; a bracket says what you are
##             about to hit.
##
## Both together is the default, and `GameSettings.aim_style` persists the choice.
##
## MOUNTING. `CombatHud` already carries one. Anything else takes one line:
## [codeblock]
## CombatReticle.mount(self).watch(_hands)
## [/codeblock]
## `watch` is what makes the highlight agree with the click path: the reticle takes a
## copy of the interactor's mask, reach and pointer mode and casts the press ray
## itself, so gold means "this press lands here" and not "a ray got there". It also
## goes dark when the hands do, so a reticle is never live over a menu.
##
## ADS. The sight picture takes over when the sights come up, so the whole
## indicator fades out between `ads_fade_start` and `ads_fade_full` — everything but
## the hit markers, which are the one thing you still need with a scope on your eye.
## The blend is read off whatever owns the eye rather than pushed in, so no demo has
## to remember to forward it.
##
## COST. One ray cast per physics frame, which is the same budget
## `DiegeticInteractor` already spends, plus eight unprojections and about thirty
## short lines a frame. Nothing is allocated per frame: the query object, the
## geometry list and the corner buffer are rebuilt only when the thing under the aim
## point changes.

## Which of the two indicators are drawn. Stored in `GameSettings.aim_style`.
enum Style { DOT = 0, SELECTOR = 1, BOTH = 2 }

## What the aim ray found, in the order the selector colours it.
enum Kind { NONE = 0, SURFACE = 1, OBJECT = 2, HOSTILE = 3, CONTROL = 4, REFUSED = 5 }

## The persisted style key. `GameSettings` owns the default; this is the name.
const SETTING_KEY: StringName = &"aim_style"
## Group every live reticle joins.
##
## The multiplayer presence system needs exactly one thing from this file — the world
## point your aim ray landed on, so it can send that point to the other three players
## and they can draw your laser dot on it. That ray is ALREADY cast here, on every
## physics frame, against the bullet mask, through the same pixel the click path uses.
## Casting a second one would be a second ray with a second answer, and the two would
## disagree the moment a demo pointed the reticle somewhere the click path does not.
##
## So the answer is published instead: `aim_point`, `aim_normal`, `aim_valid` and
## `aim_control` below, and this group so a system that wants them can find the reticle
## without this file naming that system. Nothing about the group couples the two
## directions — a reticle in a single-player demo joins it and nobody ever looks.
const GROUP: StringName = &"aim_indicator"
## Layer `mount` puts its canvas on. Below `CombatHud` (10) so a demo that somehow
## has both draws them in the sane order, and far below the main menu's own UI (100).
const MOUNT_LAYER: int = 9

const MARKER_SECONDS: float = 0.30
const MARKER_R0: float = 5.0
const MARKER_R1: float = 12.0
const MARKER_R0_CRIT: float = 6.0
const MARKER_R1_CRIT: float = 16.0
const MARKER_RING_CRIT: float = 19.0
## Kill markers go gold, crits go hot orange, everything else stays bone white.
const MARKER_COLOR: Color = Color(0.94, 0.92, 0.88)
const MARKER_KILL: Color = Color(0.902, 0.757, 0.310)
const MARKER_CRIT: Color = Color(1.0, 0.427, 0.290)

## Everything is drawn over its own dark stroke, because a bone-white line on pale
## sand is invisible and a dark line on a dark wall is too. Nothing in this game is
## black; this is the project's ink.
const INK: Color = Color(0.035, 0.031, 0.028, 0.80)
## Extra width the dark stroke carries beyond the line it backs, in pixels.
const INK_BLEED: float = 1.8

## Geometry instances merged into one subject's bounds before the walk gives up. A
## creature rig is a dozen; a fused town chunk would be thousands and is not a thing
## you bracket.
const GEOMETRY_LIMIT: int = 32
## Nodes visited looking for those instances.
const NODE_LIMIT: int = 128
## Children the node ABOVE a bare collider may have before the walk refuses to go up
## to it. A target or a creature root has a handful; a level root has hundreds.
const PARENT_FANOUT: int = 12
## Ancestors walked from a collider looking for the `DiegeticControl` that owns it.
## Same depth `DiegeticInteractor` uses, for the same reason.
const OWNER_DEPTH: int = 4
## Ancestors walked from the eye looking for whatever publishes an ADS blend.
const ADS_OWNER_DEPTH: int = 6
## Seconds after the last `set_picture` that the cone and the cycle arc keep being
## drawn. A demo that stops pushing a sight picture has put the gun away.
const PICTURE_MEMORY: float = 0.5

## Which indicators are drawn. Overwritten from `GameSettings.aim_style` on ready.
@export var style: Style = Style.BOTH:
	set = set_style
## Cone half-angle actually drawn. Set every frame by the weapon.
@export_range(0.0, 0.6, 0.0001) var spread_radians: float = 0.004
## Camera vertical FOV in degrees. Drives the radians-to-pixels conversion.
@export_range(20.0, 130.0, 0.5) var fov_degrees: float = 78.0
## 0..1 progress of the action cycle. 1 means ready to fire.
@export_range(0.0, 1.0, 0.001) var cycle: float = 1.0
## Smallest crosshair the reticle will draw, so a 0.2 MOA relic is still visible.
@export_range(2.0, 40.0, 0.5) var min_radius: float = 7.0
@export_range(0.5, 4.0, 0.1) var tick_width: float = 1.6
@export var reticle_color: Color = Color(0.94, 0.92, 0.88, 0.85)

@export_group("Dot")
## Radius of the centre pip. Two pixels reads at 1600x900 without becoming chrome.
@export_range(0.5, 6.0, 0.1) var dot_radius: float = 2.1
## Length of the four cone ticks, in pixels.
@export_range(2.0, 24.0, 0.5) var tick_length: float = 7.0

@export_group("Selector")
## Cast the aim ray at all. Off leaves the dot and the cone and costs nothing.
@export var probe_enabled: bool = true
## Metres the LOOK ray reaches — the one that answers "what am I pointed at".
@export_range(1.0, 500.0, 1.0) var probe_distance: float = 160.0
## What the LOOK ray may stop on. The bullet mask: the honest answer to "what would
## this shot hit", and the reason a wall between you and a body hides the body.
@export_flags_3d_physics var probe_mask: int = GameLayers.MASK_BULLET
## Seconds between casts. 0 casts on every physics frame, which is what the click
## path does and what a fast flick needs.
@export_range(0.0, 0.5, 0.005) var probe_period: float = 0.0
## Metres the PRESS ray reaches, and what it may stop on. Written by `watch` off the
## demo's own `DiegeticInteractor`; zero means there are no hands and the ray is not
## cast at all.
##
## THERE ARE TWO RAYS AND THEY ARE NOT THE SAME QUESTION. The press ray is a copy of
## what `DiegeticInteractor` will actually resolve a click against — the same mask,
## the same reach — so a gold bracket means "this press lands here" and never merely
## "a ray got there". It is cast first and wins. But it is a short, narrow query by
## design: several demos hand their hands PROP only so a press reaches past their own
## timber, and a walk-up desk reaches 2.6 m. Answering the whole indicator with it
## would leave you with no aim indicator at all the moment you looked at the horizon.
## So when the press ray finds no control, the look ray answers instead, and what it
## finds is coloured as scenery rather than as something you can work.
@export_range(0.0, 500.0, 1.0) var press_distance: float = 0.0
@export_flags_3d_physics var press_mask: int = GameLayers.PROP
## Follow the mouse cursor instead of the centre of the screen. On for a scene whose
## cursor is loose; `watch` copies it off the interactor.
@export var aim_at_pointer: bool = false
## Width of the bracket arms.
@export_range(0.5, 5.0, 0.1) var bracket_width: float = 2.0
## Arm length as a fraction of the bracketed rectangle's short side.
@export_range(0.05, 0.5, 0.01) var bracket_arm_fraction: float = 0.26
@export_range(2.0, 40.0, 0.5) var bracket_arm_min: float = 8.0
@export_range(4.0, 120.0, 0.5) var bracket_arm_max: float = 26.0
## Pixels the bracket stands off the projected bounds, so it frames the thing
## instead of cutting into it.
@export_range(0.0, 24.0, 0.5) var bracket_pad: float = 5.0
## Smallest bracket drawn. A body at 90 m projects to a few pixels and still has to
## be findable.
@export_range(4.0, 60.0, 0.5) var bracket_min_size: float = 26.0
## Half-span of the mark drawn on bare ground, where there is nothing to frame.
@export_range(4.0, 40.0, 0.5) var surface_mark_size: float = 11.0
## Fraction of the viewport past which a subject stops being an object you bracket
## and becomes scenery you mark. The terrain is one collider; so is a town chunk.
@export_range(0.1, 1.0, 0.01) var bracket_max_fraction: float = 0.62
## Print the range under the selector.
@export var show_range: bool = true
## Print what the selector is on, when it can be named.
@export var show_label: bool = true
@export_range(6, 24, 1) var label_size: int = 13

@export_group("Aim down sights")
## ADS blend the indicator starts fading at.
@export_range(0.0, 1.0, 0.01) var ads_fade_start: float = 0.35
## ADS blend the indicator is fully gone at. The sight picture owns the screen from
## here; the hit markers stay, because they are the only feedback a scope leaves you.
@export_range(0.0, 1.0, 0.01) var ads_fade_full: float = 0.85

var _marker_age: float = 999.0
var _marker_kill: bool = false
var _marker_crit: bool = false
var _ads: float = 0.0
var _ads_source: Node = null
var _camera: Camera3D = null
var _camera_id: int = 0
var _hands: DiegeticInteractor = null
var _settings: Node = null
var _since_picture: float = 999.0
var _since_probe: float = 0.0
## Allocated once. A query object per cast is a per-frame allocation.
var _query: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.new()
var _kind: int = Kind.NONE
var _subject_id: int = 0
var _control: DiegeticControl = null
var _geometry: Array[GeometryInstance3D] = []
var _hit_distance: float = 0.0
var _hit_point: Vector3 = Vector3.ZERO
var _hit_normal: Vector3 = Vector3.UP
var _label: String = ""
var _rect: Rect2 = Rect2()
var _rect_valid: bool = false


## Hang an indicator on any node in one line. Returns it so the call can be chained
## into `watch`. The canvas is its own layer rather than a bare Control so the demo's
## own 3D transform can never end up multiplying into a screen-space overlay.
static func mount(host: Node, layer: int = MOUNT_LAYER) -> CombatReticle:
	var canvas := CanvasLayer.new()
	canvas.name = "AimIndicator"
	canvas.layer = layer
	var reticle := CombatReticle.new()
	reticle.name = "Reticle"
	canvas.add_child(reticle)
	host.add_child(canvas)
	return reticle


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_query.collide_with_areas = false
	_query.collide_with_bodies = true
	add_to_group(GROUP)
	_bind_settings()
	set_physics_process(true)


func _process(delta: float) -> void:
	_since_picture += delta
	if _marker_age < MARKER_SECONDS:
		_marker_age += delta
	# Resolved HERE and not only inside the probe. The DOT style casts no ray and
	# brackets nothing, so both of those paths return early — and the ADS blend hangs
	# off whatever owns the camera, which is found while resolving it. Without this
	# line the dot never faded when the sights came up, but only in the one style
	# where nothing else was reading the camera.
	_resolve_camera()
	_read_ads()
	_project()
	queue_redraw()


func _physics_process(delta: float) -> void:
	_since_probe += delta
	if _since_probe < probe_period:
		return
	_since_probe = 0.0
	_probe()


## Punch a hit marker. `kill` colours it gold, `crit` adds the ring.
func hit_mark(kill: bool, crit: bool) -> void:
	_marker_age = 0.0
	_marker_kill = kill
	_marker_crit = crit
	queue_redraw()


## Push a new sight picture. Called every frame by the weapon. Also what tells the
## reticle a weapon is in hand at all — stop calling it and the cone goes away.
func set_picture(spread: float, cycle_fraction: float, fov: float) -> void:
	spread_radians = spread
	cycle = cycle_fraction
	fov_degrees = fov
	_since_picture = 0.0


## Aim-down-sights blend, 0 hip to 1 fully in. Only needed where nothing upstream of
## the camera publishes one; the eye's owner is read automatically otherwise.
func set_ads(blend: float) -> void:
	_ads = clampf(blend, 0.0, 1.0)


## The eye the aim ray is cast from. Left unset, the viewport's live camera is used
## every frame, which is what a demo with an F8 freecam wants.
func set_camera(camera: Camera3D) -> void:
	_camera = camera
	_camera_id = 0
	_resolve_camera()


func set_style(new_style: Style) -> void:
	style = new_style
	queue_redraw()


## Borrow the click path's own aim. The reticle takes the interactor's mask, reach
## and pointer mode, and goes dark whenever the hands do, so the highlight and the
## press can never disagree about what is under the aim point.
func watch(interactor: DiegeticInteractor) -> CombatReticle:
	_hands = interactor
	if interactor == null:
		return self
	press_mask = interactor.collision_mask
	aim_at_pointer = interactor.aim_at_pointer
	var reach: float = interactor.interact_reach
	if interactor.handle_fire:
		reach = maxf(reach, interactor.fire_reach)
	press_distance = clampf(reach, 0.0, 500.0)
	return self


## What the aim ray found, as a `Kind`. Public so a harness can assert that an
## indicator is actually on something rather than merely visible.
func aim_kind() -> int:
	return _kind


## Metres to whatever is under the aim point. Zero when the ray found nothing.
func aim_distance() -> float:
	return _hit_distance


## The WORLD POINT under the aim indicator — where the ray actually landed, not the
## middle of the screen. Meaningless unless `aim_valid` is true; the last good point is
## kept rather than zeroed, so a reader that forgets the check gets a stale answer
## instead of the origin of the world.
func aim_point() -> Vector3:
	return _hit_point


## Surface normal at that point. Up when nothing was hit.
func aim_normal() -> Vector3:
	return _hit_normal


## Whether the aim ray is on anything at all. False over open sky, and false whenever
## the indicator is not live — hands switched off, a menu up, the freecam in charge —
## because an aim point published from a dead click path is a lie in the same way a
## drawn indicator over one is.
func aim_valid() -> bool:
	return _kind != Kind.NONE and _live()


## The `DiegeticControl` under the aim point, or null. This is the diegetic-control
## highlight, published: the selector already brackets it in gold, and this is how a
## demo acts on the same answer instead of casting its own ray to re-derive it.
func aim_control() -> DiegeticControl:
	return _control


## What the selector is naming, or `""`.
func aim_label() -> String:
	return _label


## The bracket in control pixels. An empty rect means the selector is drawing the
## surface mark rather than framing an object.
func aim_rect() -> Rect2:
	return _rect if _rect_valid else Rect2()


func _draw() -> void:
	var centre: Vector2 = _aim_centre()
	var fade: float = _fade()
	if fade > 0.004:
		if style != Style.DOT:
			_draw_selector(centre, fade)
		if _weapon_live():
			_draw_cone(centre, fade)
		if style != Style.SELECTOR:
			_draw_dot(centre, fade)
	_draw_marker(centre)


# --- the ray ----------------------------------------------------------------


## One cast from the aim pixel. Everything downstream reads the cached answer, so
## this is the only place in the file that touches the physics space.
func _probe() -> void:
	if not probe_enabled or style == Style.DOT or not _live():
		_clear_subject()
		return
	var camera: Camera3D = _resolve_camera()
	if camera == null:
		_clear_subject()
		return
	var world: World3D = camera.get_world_3d()
	var space: PhysicsDirectSpaceState3D = null if world == null else world.direct_space_state
	if space == null:
		_clear_subject()
		return
	var pixel: Vector2 = _aim_pixel(camera)
	var from: Vector3 = camera.project_ray_origin(pixel)
	var direction: Vector3 = camera.project_ray_normal(pixel)
	_query.from = from
	if _press_hit(space, from, direction):
		return
	_query.to = from + direction * probe_distance
	_query.collision_mask = probe_mask
	var hit: Dictionary = space.intersect_ray(_query)
	if hit.is_empty():
		_clear_subject()
		return
	_adopt(hit)


## The press ray, cast exactly as the hands will cast it. True only when it landed on
## a control, because that is the only answer this ray is allowed to give: anything
## else it hits is a wall or a crate that the look ray will describe better.
func _press_hit(space: PhysicsDirectSpaceState3D, from: Vector3, direction: Vector3) -> bool:
	if press_distance <= 0.0:
		return false
	_query.to = from + direction * press_distance
	_query.collision_mask = press_mask
	var hit: Dictionary = space.intersect_ray(_query)
	if hit.is_empty():
		return false
	if _owner_control(hit["collider"] as Node) == null:
		return false
	_adopt(hit, true)
	return true


## Take a hit. The expensive half — walking for the owning control and collecting
## the geometry to bound — only runs when the collider actually changed, which for a
## player standing still looking at a wall is once.
func _adopt(hit: Dictionary, from_press: bool = false) -> void:
	_hit_point = hit["position"]
	_hit_normal = hit.get("normal", Vector3.UP)
	_hit_distance = _query.from.distance_to(_hit_point)
	var collider := hit["collider"] as Node
	if collider == null:
		_clear_subject()
		return
	var id: int = collider.get_instance_id()
	if id != _subject_id:
		_subject_id = id
		_control = _owner_control(collider)
		_geometry.clear()
		_collect_geometry(_control if _control != null else collider)
		_label = _name_of(collider)
	_kind = _classify(collider, from_press)


func _clear_subject() -> void:
	if _subject_id == 0 and _kind == Kind.NONE:
		return
	_subject_id = 0
	_control = null
	_geometry.clear()
	_label = ""
	_kind = Kind.NONE
	_hit_distance = 0.0


## Colour class of what was hit. A control the hands would refuse reads differently
## from one they would actuate, because "this does nothing" is the single most useful
## thing a highlight can tell you — and so does a control you can see but are still
## too far away to work, which goes to the dim object colour and brightens to gold as
## you walk up to it.
func _classify(collider: Node, from_press: bool) -> int:
	if _control != null:
		if not _control.enabled:
			return Kind.REFUSED
		return Kind.CONTROL if from_press or press_distance <= 0.0 else Kind.OBJECT
	var body := collider as CollisionObject3D
	var layer: int = 0 if body == null else body.collision_layer
	if (layer & (GameLayers.ENEMY | GameLayers.ENEMY_HITBOX)) != 0:
		return Kind.HOSTILE
	if (layer & GameLayers.PROP) != 0 and not _geometry.is_empty():
		return Kind.OBJECT
	return Kind.SURFACE


## The control a collider belongs to. Nearly always the collider itself, but a
## control whose shape hangs off a child still has to resolve, and the group is the
## contract rather than the class — the same rule `DiegeticInteractor` follows.
static func _owner_control(node: Node) -> DiegeticControl:
	var walk: Node = node
	var depth: int = 0
	while walk != null and depth < OWNER_DEPTH:
		if walk.is_in_group(DiegeticControl.GROUP):
			return walk as DiegeticControl
		walk = walk.get_parent()
		depth += 1
	return null


## Everything under the subject that has bounds worth merging. A collider often owns
## its own meshes — every `DiegeticControl` does — but plenty do not: a range target's
## body and its board are siblings, and a creature's rig hangs beside its capsule. So
## when the collider's own subtree is bare, its PARENT's subtree is tried once.
##
## The ascent is fenced two ways, because the node above a collider can just as
## easily be the whole level: the parent must be a `Node3D` with a small fanout, and
## the walk is bounded by node count and by geometry count whichever way it goes. A
## bracket that came out wrong anyway is caught at projection time by
## `bracket_max_fraction`, which is the backstop for exactly this.
func _collect_geometry(root: Node) -> void:
	_walk_geometry(root)
	if not _geometry.is_empty():
		return
	var parent := root.get_parent() as Node3D
	if parent == null or parent.get_child_count() > PARENT_FANOUT:
		return
	_walk_geometry(parent)


func _walk_geometry(root: Node) -> void:
	var stack: Array[Node] = [root]
	var visited: int = 0
	while not stack.is_empty() and visited < NODE_LIMIT:
		var node: Node = stack.pop_back()
		visited += 1
		var geom := node as GeometryInstance3D
		if geom != null and geom.visible:
			_geometry.append(geom)
			if _geometry.size() >= GEOMETRY_LIMIT:
				return
		for child: Node in node.get_children():
			stack.push_back(child)


## What to call the thing. A control says what it is stencilled with; a creature
## says its species. Duck-typed on purpose — naming `EnemyActor` here would drag the
## whole enemy system into the compile graph of a HUD widget that
## `tools/build_ui_assets.gd` instantiates under `--script`.
func _name_of(collider: Node) -> String:
	if _control != null:
		if not _control.label_text.is_empty():
			return _control.label_text.to_upper()
		return String(_control.control_id).to_upper()
	var species: Variant = collider.get(&"species_id")
	if species != null and typeof(species) == TYPE_STRING_NAME:
		return String(species).to_upper()
	return ""


# --- projection -------------------------------------------------------------


## Merge the subject's bounds and put them on the screen. Runs every drawn frame
## because the camera moves every drawn frame; the node walk behind it does not.
func _project() -> void:
	_rect_valid = false
	if _kind == Kind.NONE or _kind == Kind.SURFACE or _geometry.is_empty():
		return
	var camera: Camera3D = _resolve_camera()
	if camera == null:
		return
	var bounds: AABB = _world_bounds()
	if bounds.size == Vector3.ZERO and bounds.position == Vector3.ZERO:
		return
	var rect: Rect2 = _screen_rect(bounds, camera)
	if rect.size.x <= 0.0:
		return
	rect = rect.grow(bracket_pad)
	var short: float = minf(rect.size.x, rect.size.y)
	if short < bracket_min_size:
		rect = rect.grow((bracket_min_size - short) * 0.5)
	if rect.size.x > size.x * bracket_max_fraction:
		return
	if rect.size.y > size.y * bracket_max_fraction:
		return
	_rect = rect
	_rect_valid = true


func _world_bounds() -> AABB:
	var box := AABB()
	var got: bool = false
	for geom: GeometryInstance3D in _geometry:
		if not is_instance_valid(geom) or not geom.is_inside_tree():
			continue
		var world_box: AABB = geom.global_transform * geom.get_aabb()
		box = world_box if not got else box.merge(world_box)
		got = true
	return box


## The eight corners, unprojected. Any corner behind the eye makes the whole answer
## meaningless — `unproject_position` mirrors it — so the selector falls back to the
## surface mark rather than drawing a bracket somewhere it is not.
func _screen_rect(box: AABB, camera: Camera3D) -> Rect2:
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	var viewport: Viewport = camera.get_viewport()
	for i: int in 8:
		var corner: Vector3 = box.get_endpoint(i)
		if camera.is_position_behind(corner):
			return Rect2()
		var point: Vector2 = _to_local(camera.unproject_position(corner), viewport)
		lo.x = minf(lo.x, point.x)
		lo.y = minf(lo.y, point.y)
		hi.x = maxf(hi.x, point.x)
		hi.y = maxf(hi.y, point.y)
	return Rect2(lo, hi - lo)


## Camera pixels to this control's pixels. Identity in every demo here, and not in a
## demo that renders its eye into a SubViewport — which is exactly the mistake trap
## 24 in STATUS is about, so it is converted rather than assumed.
func _to_local(point: Vector2, viewport: Viewport) -> Vector2:
	if viewport == null:
		return point
	var span: Vector2 = viewport.get_visible_rect().size
	if span.x < 1.0 or span.y < 1.0:
		return point
	return Vector2(point.x / span.x * size.x, point.y / span.y * size.y)


# --- drawing ----------------------------------------------------------------


func _draw_dot(centre: Vector2, fade: float) -> void:
	var color: Color = reticle_color
	color.a *= fade
	var ink: Color = INK
	ink.a *= fade
	draw_circle(centre, dot_radius + 1.5, ink, true, -1.0, true)
	draw_circle(centre, dot_radius, color, true, -1.0, true)


func _draw_cone(centre: Vector2, fade: float) -> void:
	var radius: float = _cone_radius()
	var color: Color = reticle_color
	color.a *= fade
	var ink: Color = INK
	ink.a *= fade
	for i: int in 4:
		var dir := Vector2.RIGHT.rotated(TAU * float(i) / 4.0)
		var a: Vector2 = centre + dir * radius
		var b: Vector2 = centre + dir * (radius + tick_length)
		draw_line(a, b, ink, tick_width + INK_BLEED)
		draw_line(a, b, color, tick_width)
	if cycle < 0.999:
		var arc: Color = UiStyle.ACCENT
		arc.a = 0.8 * fade
		draw_arc(
			centre,
			radius + tick_length + 5.0,
			-PI * 0.5,
			-PI * 0.5 + TAU * clampf(cycle, 0.0, 1.0),
			24,
			arc,
			2.0,
			true
		)


## The bestiary's bead, in two dimensions. A framed object when there is one, and a
## mark on the surface when there is not — which is still an aim indicator, and is
## the reason this style alone never leaves the screen empty.
func _draw_selector(centre: Vector2, fade: float) -> void:
	var color: Color = _selector_color()
	color.a *= fade
	if not _rect_valid:
		_draw_surface_mark(centre, color, fade)
		_draw_caption(Rect2(centre + Vector2(0.0, surface_mark_size), Vector2.ZERO), color)
		return
	var arm: float = clampf(
		minf(_rect.size.x, _rect.size.y) * bracket_arm_fraction, bracket_arm_min, bracket_arm_max
	)
	var ink: Color = INK
	ink.a *= fade
	_draw_brackets(_rect, arm, ink, bracket_width + INK_BLEED)
	_draw_brackets(_rect, arm, color, bracket_width)
	_draw_caption(_rect, color)


func _draw_brackets(rect: Rect2, arm: float, color: Color, width: float) -> void:
	var lo: Vector2 = rect.position
	var hi: Vector2 = rect.position + rect.size
	for i: int in 4:
		var x: float = lo.x if (i & 1) == 0 else hi.x
		var y: float = lo.y if (i & 2) == 0 else hi.y
		var sx: float = 1.0 if (i & 1) == 0 else -1.0
		var sy: float = 1.0 if (i & 2) == 0 else -1.0
		var corner := Vector2(x, y)
		draw_line(corner, corner + Vector2(arm * sx, 0.0), color, width)
		draw_line(corner, corner + Vector2(0.0, arm * sy), color, width)


## Bare ground, a wall, or the open sky. Four separated diagonal ticks around the aim
## point — the same corner idea as the bracket, shrunk to nothing — so the two read as
## one family, and so this never turns into a second dot sitting on the first.
func _draw_surface_mark(centre: Vector2, color: Color, fade: float) -> void:
	var ink: Color = INK
	ink.a *= fade
	var r0: float = surface_mark_size * 0.42
	var r1: float = surface_mark_size
	for i: int in 4:
		var dir := Vector2.RIGHT.rotated(PI * 0.25 + TAU * float(i) / 4.0)
		var a: Vector2 = centre + dir * r0
		var b: Vector2 = centre + dir * r1
		draw_line(a, b, ink, bracket_width + INK_BLEED)
		draw_line(a, b, color, bracket_width)


## What it is and how far away, under the frame. Small and the first thing turned off
## if it ever starts reading as chrome — but not dim: a range you have to squint at is
## a range nobody reads.
func _draw_caption(rect: Rect2, color: Color) -> void:
	var text: String = _caption()
	if text.is_empty():
		return
	var font: Font = UiStyle.mono_font()
	if font == null:
		return
	var width: float = font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, label_size).x
	var at := Vector2(
		rect.position.x + rect.size.x * 0.5 - width * 0.5,
		rect.position.y + rect.size.y + float(label_size) + 6.0
	)
	# A one-pixel ring of ink on all four sides, not a drop shadow. The caption sits
	# over whatever the selector is on — sand, sky, rusted steel — and a shadow only
	# helps against one of those. Four draws is cheaper than an outlined font.
	var ink: Color = INK
	ink.a = color.a
	for i: int in 4:
		var offset := Vector2.RIGHT.rotated(TAU * float(i) / 4.0)
		draw_string(font, at + offset, text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, label_size, ink)
	draw_string(font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, label_size, color)


func _caption() -> String:
	if _kind == Kind.NONE:
		return ""
	var parts := PackedStringArray()
	if show_label and not _label.is_empty():
		parts.append(_label)
	if show_range and _hit_distance > 0.0:
		parts.append("%.0f m" % _hit_distance)
	return "  ".join(parts)


func _draw_marker(centre: Vector2) -> void:
	if _marker_age >= MARKER_SECONDS:
		return
	var t: float = _marker_age / MARKER_SECONDS
	var alpha: float = 1.0 - t * t
	var r0: float = MARKER_R0_CRIT if _marker_crit else MARKER_R0
	var r1: float = MARKER_R1_CRIT if _marker_crit else MARKER_R1
	# The ticks spring outward as they fade, which is what makes a hit register in
	# peripheral vision instead of needing to be looked at.
	var spring: float = 1.0 + t * 0.5
	var color: Color = MARKER_COLOR
	if _marker_crit:
		color = MARKER_CRIT
	elif _marker_kill:
		color = MARKER_KILL
	color.a = alpha
	var ink: Color = INK
	ink.a = alpha * 0.8
	for i: int in 4:
		var dir := Vector2.RIGHT.rotated(PI * 0.25 + TAU * float(i) / 4.0)
		var a: Vector2 = centre + dir * r0 * spring
		var b: Vector2 = centre + dir * r1 * spring
		draw_line(a, b, ink, 2.0 + INK_BLEED)
		draw_line(a, b, color, 2.0)
	if _marker_crit:
		draw_arc(centre, MARKER_RING_CRIT * spring, 0.0, TAU, 28, color, 1.5, true)


## Gold for something a press would work, hot accent for something a round would,
## warn for a control that would refuse, and dim bone for ground. Every one of them
## is out of `Palette` — the selector invents no hue.
func _selector_color() -> Color:
	match _kind:
		Kind.CONTROL:
			return Color(UiStyle.GOLD, 0.95)
		Kind.REFUSED:
			return Color(UiStyle.WARN, 0.85)
		Kind.HOSTILE:
			return Color(UiStyle.ACCENT, 0.92)
		Kind.OBJECT:
			return Color(UiStyle.GOLD, 0.55)
	return Color(0.94, 0.92, 0.88, 0.58)


# --- state ------------------------------------------------------------------


## Half-angle to pixels. A vertical FOV of `f` maps `h` pixels onto `2*tan(f/2)`
## of tangent, so one radian of cone half-angle is `tan(spread/2)` times that.
func _cone_radius() -> float:
	var half_fov: float = deg_to_rad(fov_degrees) * 0.5
	var px_per_tan: float = size.y * 0.5 / maxf(tan(half_fov), 0.0001)
	return maxf(min_radius, tan(spread_radians * 0.5) * px_per_tan)


## Something is pushing a sight picture, so there is a gun in frame and its cone is
## worth drawing. A spectator or a walk-around demo gets the indicator without it.
func _weapon_live() -> bool:
	return _since_picture < PICTURE_MEMORY


## Whether the indicator is answerable for anything at all. Hands that have been
## switched off — a menu is up, the freecam has it, a swap is in progress — mean the
## click path is not live, and an indicator over a dead click path is a lie.
func _live() -> bool:
	if not is_visible_in_tree():
		return false
	if _hands != null and is_instance_valid(_hands) and not _hands.enabled:
		return false
	return true


func _fade() -> float:
	if not _live():
		return 0.0
	var span: float = maxf(ads_fade_full - ads_fade_start, 0.001)
	return clampf(1.0 - (_ads - ads_fade_start) / span, 0.0, 1.0)


## The ADS blend, read off whatever owns the eye. Pushed values survive: a demo that
## calls `set_ads` and has no such owner keeps what it pushed.
func _read_ads() -> void:
	if _ads_source == null or not is_instance_valid(_ads_source):
		return
	var value: Variant = _ads_source.get(&"ads")
	if typeof(value) == TYPE_FLOAT:
		_ads = clampf(value, 0.0, 1.0)


func _aim_centre() -> Vector2:
	if not aim_at_pointer:
		return size * 0.5
	var viewport: Viewport = get_viewport()
	if viewport == null:
		return size * 0.5
	return _to_local(viewport.get_mouse_position(), viewport)


## The viewport pixel the ray goes through. Read from the CAMERA'S viewport rather
## than this node's, because the two are not the same coordinate space when a demo
## renders its eye into a SubViewport.
func _aim_pixel(camera: Camera3D) -> Vector2:
	var viewport: Viewport = camera.get_viewport()
	if viewport == null:
		return Vector2.ZERO
	if aim_at_pointer:
		return viewport.get_mouse_position()
	return viewport.get_visible_rect().size * 0.5


## The eye, and whatever owns it. Re-resolved whenever the live camera changes, so a
## demo that swaps to a freecam mid-run gets the freecam's ray and correctly loses
## the ADS blend along with the gun.
func _resolve_camera() -> Camera3D:
	var camera: Camera3D = _camera
	if camera == null or not is_instance_valid(camera):
		var viewport: Viewport = get_viewport()
		camera = null if viewport == null else viewport.get_camera_3d()
	if camera == null:
		return null
	var id: int = camera.get_instance_id()
	if id != _camera_id:
		_camera_id = id
		_ads_source = _find_ads_source(camera)
	return camera


## Walk up from the eye looking for whatever publishes an ADS blend.
## `PlayerController` does and nothing else in the project does. Duck-typed on
## purpose: naming the class here would drag the whole player system into the
## compile graph of a widget `tools/build_ui_assets.gd` instantiates under
## `--script`, which is trap 21 in STATUS waiting to happen.
static func _find_ads_source(from: Node) -> Node:
	var walk: Node = from
	var depth: int = 0
	while walk != null and depth < ADS_OWNER_DEPTH:
		if typeof(walk.get(&"ads")) == TYPE_FLOAT:
			return walk
		walk = walk.get_parent()
		depth += 1
	return null


## The store, BY NODE PATH and not by name. A script handed to `--script` compiles
## before the autoloads exist and `tools/build_ui_assets.gd` instantiates this class,
## so naming `GameSettings` here would take the whole UI bake down with it — trap 21
## in STATUS. `PlayerController` solves it the same way, and now so does this.
##
## `Engine.get_singleton` is the workaround STATUS actually recommends, and it does
## NOT work: measured on Godot 4.7.1, `Engine.has_singleton(&"GameSettings")` is
## FALSE while `/root/GameSettings` resolves to the live node. This function was
## written the recommended way first, and the style setting silently did nothing —
## the store moved 2 -> 0 -> 1 -> 2 and the reticle sat at 2 the whole time —
## because the guard returned before anything was connected.
func _bind_settings() -> void:
	_settings = get_node_or_null(^"/root/GameSettings")
	if _settings == null or not bool(_settings.call(&"has_key", SETTING_KEY)):
		_settings = null
		return
	set_style(_style_from(_settings.call(&"get_value", SETTING_KEY, int(style))))
	_settings.connect(&"settings_changed", _on_setting_changed)


func _on_setting_changed(key: StringName, value: Variant) -> void:
	if key == SETTING_KEY:
		set_style(_style_from(value))


static func _style_from(value: Variant) -> Style:
	return clampi(int(value), int(Style.DOT), int(Style.BOTH)) as Style
