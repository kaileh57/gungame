class_name DiegeticInteractor
extends Node3D
## THE HANDS. Turns a button press into an actuated `DiegeticControl` without
## losing one.
##
## WHY THIS EXISTS. Every demo used to resolve its own click and every one of them
## lost clicks a different way, which is what the report "not all clicks are
## registered, you have to HARD click" was describing. Measured by
## `tools/verify_click_input.gd`, fifty synthesised presses per demo, before this
## node existed:
##
##   press and release inside one drawn frame  ... 100% registered
##   look on and press in the same frame       ...   0% registered (bestiary,
##                                                   movement, main menu)
##   press ten times a second                  ...  50% registered (every demo)
##   sub-frame trigger tap becoming a round    ...   0% (range, arena)
##
## Three separate faults, none of them the physics space state, which was measured
## and is fine: 399 of 399 ray casts from an idle frame and 99 of 99 from an input
## frame came back with the collider on Godot 4.7.1 with Jolt.
##
##   1. THE STALE HOVER. A rig that cast its ray in `_process` and then read the
##      cached answer in `_unhandled_input` was always one frame late, because
##      input is flushed at the top of the iteration and `_process` runs at the
##      bottom of it. Look at a control and click in the same motion and the rig
##      resolved the click against where you were looking a frame ago — nothing.
##   2. THE SHARED DEBOUNCE. `DiegeticControl.cooldown` is 0.14 s, and it exists so
##      that nine shotgun pellets actuate a button once. Deliberate presses went
##      through the same gate, so clicking faster than seven times a second threw
##      every other click away, and threw it away SILENTLY — no flash, no refusal
##      sound, nothing. `press_cooldown` now separates the two.
##   3. THE DROPPED PRESS. Nothing queued. A press that arrived while a control was
##      inside its debounce was gone.
##
## WHAT THIS NODE DOES INSTEAD. `_unhandled_input` does no work beyond latching:
## it records the press and the ray the eye was on AT THAT INSTANT, and pushes it
## on a queue. `_physics_process` drains the queue, casts each press's own frozen
## ray, and actuates what it finds. A press that lands on a control still inside
## its debounce is HELD and offered again next frame until `press_patience` runs
## out, so two presses in one physics frame both land, in order.
##
## Freezing the ray at press time is the part that fixes the flick: the click is
## resolved against where the eye was when the button went down, not where it is
## when the queue is drained.
##
## COST. One ray cast per drawn press plus one per physics frame for the hover,
## against `collision_mask`, from a query object allocated once.
##
## ORDER. This node claims an early `process_physics_priority`, and that is load
## bearing. In a demo where the same click also pulls a trigger, the press has to
## reach the control BEFORE the round from that click does: the press debounce is
## 40 ms and the bullet debounce is 140 ms, so a press first correctly absorbs its
## own bullet, while a bullet first would leave the press waiting on a debounce it
## did not cause and actuate the control a second time.

## A control was actuated. `action` is `fire_action` or `interact_action`.
signal actuated(control: DiegeticControl, action: StringName)
## A press resolved to nothing, or to a control that would not take it.
signal refused(action: StringName)
## The control under the eye changed. Null means nothing is under it.
signal hover_changed(control: DiegeticControl)

## Walked up from a collider looking for the control that owns it. Deep enough for
## a control whose shape lives on a child, shallow enough not to find the level.
const OWNER_DEPTH: int = 4
## Where this node sits in the physics frame. Negative so it runs before the guns.
const PHYSICS_PRIORITY: int = -32

@export_group("Wiring")
## The eye the rays come from. Left empty the viewport's live camera is used every
## frame, which is what a demo with an F8 freecam wants — point the freecam at a
## control and it still works.
@export var eye_path: NodePath = NodePath()
## Stop latching and stop hovering. The demo's own gates — paused, freecam, riding
## a camera — go through this rather than through a fork in this file.
@export var enabled: bool = true
## Layers a press ray may stop on. World geometry is in it on purpose: a control
## you can see through a wall is a control you cannot reach.
@export_flags_3d_physics var collision_mask: int = GameLayers.WORLD | GameLayers.PROP

@export_group("Aim")
## Where on the screen the rays are cast from. Off — the default — is the crosshair
## at the centre of the viewport, which is what every demo wants because the mouse
## is captured and the eye IS the pointer. On, the rays follow the mouse cursor,
## which is what a scene with a released cursor needs: the main menu is operated by
## pointing at a plate on a board, and a ray down the middle of the screen would
## resolve every click against whatever the camera happens to face.
##
## The distinction is only ever about where the pixel is. Everything else — the
## latch, the frozen ray, the queue and the retry — is identical, so a pointer scene
## gets the same fix a crosshair scene does.
@export var aim_at_pointer: bool = false

@export_group("Reach")
## Metres a walk-up press reaches. Short: a desk is something you stand at.
@export_range(0.25, 16.0, 0.05) var interact_reach: float = 3.2
## Metres a press on the fire button reaches. A shot reaches as far as the bullet,
## so this is long by default and the ray is what makes the console work when the
## gun is empty, jammed or absent.
@export_range(1.0, 500.0, 1.0) var fire_reach: float = 120.0

@export_group("Buttons")
## Latch presses of `fire_action`.
@export var handle_fire: bool = true
## Latch presses of `interact_action`.
@export var handle_interact: bool = true
## The shoot-it button. Left mouse, in this project.
@export var fire_action: StringName = &"fire"
## The use-it button. F, in this project.
@export var interact_action: StringName = &"interact"
## A fire press actuates AT the point the ray landed on, the way a bullet does: a
## slider takes the value you pointed at and a dial turns the way the half you hit
## says. Off, a fire press is the same centred nudge `interact` gives, which is
## what a demo whose controls are plates rather than instruments wants.
@export var fire_presses_at_point: bool = true
## Fraction of a full-strength hit a press counts as. Controls with a `min_power`
## refuse anything under it.
@export_range(0.0, 1.0, 0.01) var press_power: float = 1.0
## Mark a handled press as consumed so no later `_unhandled_input` sees it. Off by
## default because in every demo here the same click also drives the weapon.
@export var consume_fire: bool = false
@export var consume_interact: bool = false

@export_group("Queue")
## Seconds a press keeps being offered to a control that is inside its debounce
## before it is given up on. Two presses in one physics frame are the case this
## exists for; anything past this and the player has stopped meaning it.
@export_range(0.0, 2.0, 0.01) var press_patience: float = 0.35
## Presses held at once. A ceiling, not a target — reaching it means something is
## generating input that nobody is consuming.
@export_range(1, 64, 1) var queue_limit: int = 16

@export_group("Hover")
## Resolve what the eye is on every physics frame. Off saves one ray cast a frame
## for a demo that only needs the press.
@export var track_hover: bool = true
## Refuse to hover a disabled control, so a demo's highlight never lands on
## something that will not take a press.
@export var hover_skips_disabled: bool = true

var _eye: Camera3D = null
var _queue: Array[Dictionary] = []
var _hovered: DiegeticControl = null
var _hover_point: Vector3 = Vector3.ZERO
## Allocated once. A query object per press is a per-press allocation.
var _query: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.new()


## Set here rather than in `_ready` so a scene that wants a different order can
## still override it: scene state is applied after `_init` and before `_ready`.
func _init() -> void:
	process_physics_priority = PHYSICS_PRIORITY


func _ready() -> void:
	_query.collision_mask = collision_mask
	_query.collide_with_areas = false
	_query.collide_with_bodies = true
	if not eye_path.is_empty():
		_eye = get_node_or_null(eye_path) as Camera3D
		if _eye == null:
			push_error("DiegeticInteractor: eye_path '%s' is not a Camera3D." % eye_path)
	set_physics_process(true)


func _unhandled_input(event: InputEvent) -> void:
	# Motion is the overwhelming majority of the events that reach here and none of
	# it can be a press. Rejecting it first keeps the latch off the mouse's back.
	if not enabled or event is InputEventMouseMotion:
		return
	if handle_fire and event.is_action_pressed(fire_action):
		if _latch(fire_action, fire_reach, event) and consume_fire:
			get_viewport().set_input_as_handled()
		return
	if handle_interact and event.is_action_pressed(interact_action):
		if _latch(interact_action, interact_reach, event) and consume_interact:
			get_viewport().set_input_as_handled()


func _physics_process(_delta: float) -> void:
	# A disabled rig drops what it was holding as well as refusing new presses. A
	# press latched before a menu opened must not land the instant it closes, and
	# the highlight has to come off the control the cursor was on — a demo that
	# switches to a freecam or opens a panel is saying "the hands are not on it".
	if not enabled:
		if not _queue.is_empty():
			_queue.clear()
		if _hovered != null:
			_set_hover(null, Vector3.ZERO)
		return
	if not _queue.is_empty():
		_drain()
	if track_hover:
		_update_hover()
	elif _hovered != null:
		_set_hover(null, Vector3.ZERO)


# --- what the demos ask ------------------------------------------------------


## The control under the eye, or null.
func hovered() -> DiegeticControl:
	return _hovered


## The hovered control's id, or `&""`. What an overlay and a headless check want
## without reaching into the ray.
func hovered_id() -> StringName:
	return &"" if _hovered == null else _hovered.control_id


## World-space point the hover ray landed on. Meaningless when nothing is hovered.
func hover_point() -> Vector3:
	return _hover_point


## Presses latched and not yet resolved. Anything but 0 outside a physics frame
## means a press is mid-flight, which is the only state this node holds.
func pending() -> int:
	return _queue.size()


## Point the rays at a different camera at runtime. Null goes back to the
## viewport's live camera.
func set_eye(camera: Camera3D) -> void:
	_eye = camera


func eye() -> Camera3D:
	return _camera()


# --- the latch ---------------------------------------------------------------


## Record the press and the ray the eye is on at this instant. Returns false only
## when there is no camera to cast from or the queue is full, which are the two
## states where pretending to have taken the press would be a lie.
func _latch(action: StringName, reach: float, event: InputEvent) -> bool:
	var camera: Camera3D = _camera()
	if camera == null:
		return false
	if _queue.size() >= queue_limit:
		# Drop the OLDEST. A player hammering a jammed control wants their most
		# recent press to be the one that survives.
		_queue.pop_front()
	var pixel: Vector2 = _press_pixel(camera, event)
	var from: Vector3 = camera.project_ray_origin(pixel)
	var direction: Vector3 = camera.project_ray_normal(pixel)
	var press_entry: Dictionary = {
		"action": action,
		"from": from,
		"to": from + direction * reach,
		"at_ms": Time.get_ticks_msec(),
	}
	_queue.append(press_entry)
	return true


# --- the drain ---------------------------------------------------------------


## Resolve every held press against its own frozen ray. A press whose control is
## still inside its debounce is put back rather than thrown away, which is the
## whole reason two clicks in one physics frame both land.
func _drain() -> void:
	var now: int = Time.get_ticks_msec()
	var patience_ms: int = int(press_patience * 1000.0)
	var held: Array[Dictionary] = []
	for entry: Dictionary in _queue:
		var control: DiegeticControl = _control_at(entry["from"], entry["to"])
		if control == null:
			refused.emit(entry["action"])
			continue
		if control.enabled and not control.is_ready_to_press():
			if now - int(entry["at_ms"]) <= patience_ms:
				held.append(entry)
				continue
			refused.emit(entry["action"])
			continue
		if _actuate(control, entry):
			actuated.emit(control, entry["action"])
		else:
			refused.emit(entry["action"])
	_queue = held


## Put the press through the control. A fire press lands at the point the ray
## found; an interact press is the centred nudge the subclass defines.
func _actuate(control: DiegeticControl, entry: Dictionary) -> bool:
	if entry["action"] == fire_action and fire_presses_at_point:
		return control.press(_hit_point(entry), press_power)
	return control.interact()


## Where this press's ray met the control. Recomputed rather than stored because
## the control may have moved between the latch and the drain — a lever mid-throw
## is a moving surface — and the point has to be on the geometry it actuates.
func _hit_point(entry: Dictionary) -> Vector3:
	var hit: Dictionary = _cast(entry["from"], entry["to"])
	if hit.is_empty():
		return entry["to"]
	return hit["position"]


# --- rays --------------------------------------------------------------------


func _camera() -> Camera3D:
	if _eye != null and is_instance_valid(_eye):
		return _eye
	return get_viewport().get_camera_3d()


## The pixel a press was made at. A mouse button event CARRIES ITS OWN POSITION, and
## in a pointer scene that is the truest answer available: it is where the cursor was
## when the button went down, which is not necessarily where the cursor is by the
## time this handler runs — the same motion that put the cursor on a plate can
## deliver a click behind it in the same flush. A key press carries no position, so
## it falls back to wherever the aim is now, and a crosshair scene ignores the event
## entirely because the middle of the screen is the middle of the screen.
func _press_pixel(camera: Camera3D, event: InputEvent) -> Vector2:
	if aim_at_pointer:
		var mouse := event as InputEventMouse
		if mouse != null:
			return mouse.position
	return _aim_pixel(camera)


## The viewport pixel the rays go through: the cursor when `aim_at_pointer` is on,
## the centre of the screen otherwise. Read from the CAMERA'S viewport rather than
## this node's, because a demo may render its eye into a SubViewport while this node
## sits in the main tree, and the two do not share a coordinate space.
func _aim_pixel(camera: Camera3D) -> Vector2:
	var viewport: Viewport = camera.get_viewport()
	if viewport == null:
		return Vector2.ZERO
	if aim_at_pointer:
		return viewport.get_mouse_position()
	return viewport.get_visible_rect().size * 0.5


func _cast(from: Vector3, to: Vector3) -> Dictionary:
	var world: World3D = get_world_3d()
	if world == null:
		return {}
	var space: PhysicsDirectSpaceState3D = world.direct_space_state
	if space == null:
		return {}
	_query.collision_mask = collision_mask
	_query.from = from
	_query.to = to
	return space.intersect_ray(_query)


func _control_at(from: Vector3, to: Vector3) -> DiegeticControl:
	var hit: Dictionary = _cast(from, to)
	if hit.is_empty():
		return null
	return _owner_control(hit["collider"] as Node)


## The control a collider belongs to. Nearly always the collider itself — a
## `DiegeticControl` IS the body — but a control whose shape hangs off a child
## still has to resolve, and the group is the contract, not the class.
static func _owner_control(node: Node) -> DiegeticControl:
	var walk: Node = node
	var depth: int = 0
	while walk != null and depth < OWNER_DEPTH:
		if walk.is_in_group(DiegeticControl.GROUP):
			return walk as DiegeticControl
		walk = walk.get_parent()
		depth += 1
	return null


func _update_hover() -> void:
	var camera: Camera3D = _camera()
	if camera == null:
		_set_hover(null, Vector3.ZERO)
		return
	var pixel: Vector2 = _aim_pixel(camera)
	var from: Vector3 = camera.project_ray_origin(pixel)
	var to: Vector3 = from + camera.project_ray_normal(pixel) * interact_reach
	var hit: Dictionary = _cast(from, to)
	if hit.is_empty():
		_set_hover(null, Vector3.ZERO)
		return
	var control: DiegeticControl = _owner_control(hit["collider"] as Node)
	if control != null and hover_skips_disabled and not control.enabled:
		control = null
	if control == null:
		_set_hover(null, Vector3.ZERO)
		return
	_set_hover(control, hit["position"])


func _set_hover(control: DiegeticControl, point: Vector3) -> void:
	_hover_point = point
	if control == _hovered:
		return
	_hovered = control
	hover_changed.emit(_hovered)
