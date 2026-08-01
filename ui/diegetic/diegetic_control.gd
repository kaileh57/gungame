class_name DiegeticControl
extends StaticBody3D
## Base class for every control you operate by shooting it.
##
## The project's UI rule is that controls are physical objects, so a control is a
## `StaticBody3D` on the PROP layer, which is inside `GameLayers.MASK_BULLET`.
## Whatever resolves a bullet hit calls `shoot()` on it:
## [codeblock]
## var hit: Object = result["collider"]
## if hit.is_in_group(DiegeticControl.GROUP):
##     (hit as DiegeticControl).shoot(result["position"], energy_fraction)
## [/codeblock]
## `interact()` and `press()` are the same actuation from a walk-up or a mouse
## click, which is how the main menu drives these without a gun in your hands.
##
## TWO DEBOUNCES, AND THEY ARE NOT THE SAME NUMBER. A shotgun puts nine pellets
## into a button inside the same millisecond and the button must actuate once, so
## the BULLET path is debounced hard by `cooldown`. A person clicking a button is
## not a pellet spread — the fastest anybody clicks is about ten a second — so the
## OPERATOR path is debounced by `press_cooldown`, which is short enough to be
## invisible. Both compare against the same `_last_actuate_ms`, which is what makes
## a click absorb the round that the same trigger pull sent into the same plate:
## the press lands, and the bullet arriving a few milliseconds later is inside the
## long cooldown and is correctly ignored.
##
## Used bare it is a shootable plate: it flashes, it clunks, it emits `pressed`.
## The subclasses add a state to change — a cap that depresses, a lever that
## throws, a dial that indexes, a slider that runs along a track.
##
## Physical feel comes from three things happening together and none of them
## lasting long: the mesh moves, a sound plays, and the surface flashes. The flash
## rides on the scrap shader's per-instance `tint`, so it costs no material.

## The control was actuated. Fired by every subclass on every successful hit.
signal pressed
## The control's value changed, either from a hit or from `set_value`.
signal value_changed(value: float)

## Every diegetic control joins this group. A shooter looks for it by group rather
## than by class so it never has to load the UI's scripts to fire a bullet.
const GROUP: StringName = &"diegetic_control"

## Identifies this control to whatever wired it up. Set it in the scene that
## builds the panel; handlers match on it instead of on node paths.
@export var control_id: StringName = &""
## A disabled control still takes the hit — it just refuses, audibly.
@export var enabled: bool = true:
	set = _set_enabled
## Shown on the Label3D child, when the control has one.
@export var label_text: String = "":
	set = _set_label_text
## Minimum seconds between actuations FROM GUNFIRE. A shotgun puts nine pellets
## into a button in the same millisecond; without this the button fires nine times.
@export_range(0.0, 1.0, 0.01) var cooldown: float = 0.14
## Minimum seconds between actuations FROM A DELIBERATE PRESS — a click, a walk-up,
## a key. Nobody clicks faster than about ten a second, so 40 ms never refuses a
## real press and still collapses a double-fed event into one. Raising this to
## `cooldown` is how a control gets swallowed clicks back: at 0.14 a person
## clicking at ten a second loses every other one, silently.
@export_range(0.0, 1.0, 0.01) var press_cooldown: float = 0.04
## Hits weaker than this do not actuate. Zero means anything that reaches it works.
@export_range(0.0, 1.0, 0.01) var min_power: float = 0.0
## Played on every successful actuation. Left null it falls back to the project's
## baked control clack, which is what nearly every control wants; set it only when
## a particular control needs to sound unlike the others.
@export var sound: AudioStream = null
## Played when the control refuses the hit. Null takes the baked knock.
@export var deny_sound: AudioStream = null

@export_group("Feedback")
## Peak albedo multiplier of the hit flash.
@export_range(1.0, 4.0, 0.05) var flash_strength: float = 1.9
@export_range(0.02, 0.60, 0.01) var flash_seconds: float = 0.18
## Albedo multiplier while disabled.
@export_range(0.2, 1.0, 0.01) var disabled_tint: float = 0.55

var _value: float = 0.0
var _last_actuate_ms: int = -100000
var _flash_targets: Array[GeometryInstance3D] = []
var _flash_tween: Tween = null
var _label: Label3D = null
var _player: AudioStreamPlayer3D = null


func _ready() -> void:
	add_to_group(GROUP)
	_label = get_node_or_null(^"Label") as Label3D
	_player = get_node_or_null(^"Sound") as AudioStreamPlayer3D
	# The default pair is resolved here rather than at export time so that a panel
	# baked before the sounds existed still makes a noise, and so that the exports
	# read as "unset" in the inspector instead of as a path nobody chose.
	if sound == null:
		sound = UiStyle.click_sound()
	if deny_sound == null:
		deny_sound = UiStyle.deny_sound()
	_collect_flash_targets(self)
	_set_tint(1.0)
	if not label_text.is_empty():
		_set_label_text(label_text)
	_refresh_visual(true)


## A bullet landed on this control. `point` is the world-space impact, `power` a
## 0..1 fraction of a full-strength hit. Returns true if the control actuated.
func shoot(point: Vector3, power: float = 1.0) -> bool:
	if not enabled:
		_deny()
		return false
	if power < min_power:
		_deny()
		return false
	if not is_ready_to_actuate():
		return false
	return _actuate_at(to_local(point))


## Actuate from a walk-up, a keypress or a mouse click. Equivalent to a bullet
## landing at `_interact_point()`, which subclasses place wherever using the
## control by hand would land — the centre of anything you press, one notch along
## for a slider.
func interact() -> bool:
	if not enabled:
		_deny()
		return false
	if not is_ready_to_press():
		return false
	return _actuate_at(_interact_point())


## Actuate from a deliberate press AT A POINT — a click resolved against the
## control's own geometry. Same debounce as `interact()`; the difference is that a
## slider takes the value you pointed at instead of stepping, and a dial turns the
## way the half you pressed says. `point` is world space.
func press(point: Vector3, power: float = 1.0) -> bool:
	if not enabled:
		_deny()
		return false
	if power < min_power:
		_deny()
		return false
	if not is_ready_to_press():
		return false
	return _actuate_at(to_local(point))


## True once the BULLET cooldown since the last actuation has elapsed.
func is_ready_to_actuate() -> bool:
	return Time.get_ticks_msec() - _last_actuate_ms >= int(cooldown * 1000.0)


## True once the PRESS cooldown since the last actuation has elapsed. An operator
## whose press is refused here has not lost it — `DiegeticInteractor` holds the
## press and offers it again on the next physics frame.
func is_ready_to_press() -> bool:
	return Time.get_ticks_msec() - _last_actuate_ms >= int(press_cooldown * 1000.0)


func value() -> float:
	return _value


## Write the value from code. `notify` false is for wiring a panel up to its
## initial state without every handler firing on load.
func set_value(new_value: float, notify: bool = true) -> void:
	var clamped: float = _sanitize(new_value)
	if is_equal_approx(clamped, _value):
		return
	_value = clamped
	_refresh_visual(not notify)
	if notify:
		value_changed.emit(_value)


func set_label(text: String) -> void:
	label_text = text


## Flash the surface, in the same colour it already is, only brighter. Public so a
## panel can acknowledge something the control itself did not cause.
func flash() -> void:
	if _flash_tween != null and _flash_tween.is_valid():
		_flash_tween.kill()
	_flash_tween = create_tween()
	_flash_tween.tween_method(_set_tint, flash_strength, _rest_tint(), flash_seconds)


# --- for subclasses ---------------------------------------------------------


## The actuation itself. `local_point` is the impact in this node's local space,
## or the origin when there was no impact. Return true if the control changed.
## The base plate has no state, so it simply reports the hit.
func _actuate(_local_point: Vector3) -> bool:
	return true


## Push `_value` onto the geometry. `instant` skips the animation, which is what
## the scene load and `set_value(v, false)` want.
func _refresh_visual(_instant: bool) -> void:
	pass


## Local-space point a hands-on `interact()` counts as having touched. The centre
## is right for anything you press; a slider overrides it to mean "one notch on".
func _interact_point() -> Vector3:
	return Vector3.ZERO


func _play(stream: AudioStream) -> void:
	if _player == null or stream == null:
		return
	_player.stream = stream
	_player.play()


func _actuate_at(local_point: Vector3) -> bool:
	_last_actuate_ms = Time.get_ticks_msec()
	if not _actuate(local_point):
		return false
	flash()
	_play(sound)
	pressed.emit()
	return true


func _deny() -> void:
	_play(deny_sound)


## Clamp or quantise a candidate value. The base accepts anything.
func _sanitize(raw: float) -> float:
	return raw


func _rest_tint() -> float:
	return 1.0 if enabled else disabled_tint


func _set_tint(scale: float) -> void:
	var c := Color(scale, scale, scale, 1.0)
	for target: GeometryInstance3D in _flash_targets:
		target.set_instance_shader_parameter(&"tint", c)


func _collect_flash_targets(node: Node) -> void:
	for child: Node in node.get_children():
		var geom := child as GeometryInstance3D
		if geom != null:
			_flash_targets.append(geom)
		_collect_flash_targets(child)


func _set_enabled(on: bool) -> void:
	enabled = on
	if not is_node_ready():
		return
	if _flash_tween != null and _flash_tween.is_valid():
		_flash_tween.kill()
	_set_tint(_rest_tint())


func _set_label_text(text: String) -> void:
	label_text = text
	if not is_node_ready():
		return
	if _label == null:
		_label = get_node_or_null(^"Label") as Label3D
	if _label != null:
		_label.text = text
