class_name CourseInteractor
extends DiegeticInteractor
## The player's hands at the movement bench, and the highlight that goes with them.
##
## Everything about resolving a press — latching it, freezing the ray it was made
## on, casting that ray on the physics frame, retrying a control that is still
## inside its debounce — belongs to `DiegeticInteractor`. What is left here is the
## bench's own feedback: the readout label on the control under the cursor
## brightens, and nothing is drawn on the screen.
##
## The playground ships without a weapon, so the guns' hit path never runs and
## something has to actuate the desk. Keeping it in the demo also gets the
## behaviour the desk wants: a slider is set ABSOLUTELY by where you point, which
## is how you dial in a number, and stepped by `interact`, which is how you nudge
## one. That split is `fire_presses_at_point`.
##
## WHAT THIS USED TO DO, AND WHY IT LOST CLICKS. It cast its ray in `_process` and
## cached the answer, then read the cache back in `_unhandled_input`. Input is
## flushed at the top of the engine iteration and `_process` runs at the bottom of
## it, so the cache was always a frame behind the eye: look at a control and click
## in the same motion and the press was resolved against the empty air you were
## pointing at a frame earlier. Measured, that was thirty flick-presses in a row
## and none of them registered.

## Emitted when the control under the cursor changes. Empty id means nothing.
signal hover_changed_id(control_id: StringName)

## Emphasis applied to the hovered control's readout label.
@export_range(1.0, 4.0, 0.05) var hover_glow: float = 1.9

var _hovered_label: Label3D = null
var _label_rest: Color = Color.WHITE


func _ready() -> void:
	# WORLD is in the mask so the ray stops at geometry; PROP is where every
	# diegetic control sits. Triggers are left out — the loop gates are areas and
	# this query does not look at areas anyway.
	collision_mask = GameLayers.WORLD | GameLayers.PROP
	fire_reach = interact_reach
	fire_presses_at_point = true
	super()
	if eye_path.is_empty():
		push_error("CourseInteractor: eye_path is unset; there is nothing to aim from.")
	hover_changed.connect(_on_hover_changed)


func _on_hover_changed(control: DiegeticControl) -> void:
	_release_hover()
	if control == null:
		hover_changed_id.emit(&"")
		return
	_hovered_label = control.get_node_or_null(^"Readout") as Label3D
	if _hovered_label != null:
		_label_rest = _hovered_label.modulate
		_hovered_label.modulate = _label_rest * hover_glow
	hover_changed_id.emit(control.control_id)


func _release_hover() -> void:
	if _hovered_label != null and is_instance_valid(_hovered_label):
		_hovered_label.modulate = _label_rest
	_hovered_label = null
