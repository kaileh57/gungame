class_name ScopeOverlay
extends Control
## The sniper scope picture: everything outside the tube goes black, and what is left
## is a circle of magnified world with a reticle in it.
##
## THIS IS WHAT `scoped` WAS ALWAYS SUPPOSED TO MEAN. `GunSpec.scoped` has existed since
## the port, `PlayerCamera` emitted `zoom_changed(level, index, scoped)`, and nothing
## anywhere listened to it — there was no tube, no mask and no reticle, so a scope was a
## word on a stat card. The camera even declined to magnify on the grounds that "the
## magnification happens inside the tube", which made a scope worse than irons.
##
## DRAWN, NOT TEXTURED. The mask is one `draw_arc` with a width wider than the screen,
## which paints an annulus from the tube edge outward and covers every corner however
## the window is resized. A baked texture would need one asset per aspect ratio and
## would resample badly on a 4K display; this is exact at any size and costs a handful
## of primitives. `_draw` only runs when `queue_redraw` is called, which is on a state
## change rather than per frame.
##
## The reticle is chosen by magnification, so a 4x marksman optic and a 12x sniper tube
## do not draw the same picture. See `RETICLE_MIL_MIN`.

## Reticle styles, in ascending magnification.
enum Reticle { CROSS, MIL_DOT }

## Above this magnification the reticle gains ranging dots. Below it the tube gets a
## plain cross, because dots you cannot use are just clutter.
const RETICLE_MIL_MIN: float = 6.0
## Tube diameter as a fraction of the SHORTER screen axis. Under 1.0 so the mask always
## has something to cover on a square window.
@export_range(0.3, 1.0, 0.01) var tube_fraction: float = 0.86
## How far into the shoulder the tube is fully up. Below this it fades, so raising a
## scope reads as raising it rather than as a cut.
@export_range(0.05, 1.0, 0.01) var full_ads: float = 0.72
@export var mask_color: Color = Color(0.02, 0.02, 0.025, 1.0)
@export var ring_color: Color = Color(0.10, 0.10, 0.11, 1.0)
@export var reticle_color: Color = Color(0.86, 0.84, 0.78, 0.92)
## Gap at the centre, in pixels, so the reticle never hides what you are shooting.
@export_range(0.0, 60.0, 1.0) var center_gap: float = 9.0
## Spacing of the ranging dots, as a fraction of the tube radius.
@export_range(0.05, 0.5, 0.01) var mil_step: float = 0.19

var _amount: float = 0.0
var _reticle: int = Reticle.CROSS


func _ready() -> void:
	# The tube is scenery. It must never eat a click or a hover.
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)
	visible = false


## Drive the tube. `ads` is the shoulder blend, `scoped` whether the weapon carries a
## real scope, `zoom` the selected rung of its ladder.
##
## Cheap to call every frame: it returns without touching anything unless the picture
## would actually change, so holding a scope steady costs one comparison.
func set_state(ads: float, scoped: bool, zoom: float) -> void:
	var want: float = 0.0
	if scoped and full_ads > 0.0:
		want = clampf(ads / full_ads, 0.0, 1.0)
	var style: int = Reticle.MIL_DOT if zoom >= RETICLE_MIL_MIN else Reticle.CROSS
	if absf(want - _amount) < 0.01 and style == _reticle:
		return
	_amount = want
	_reticle = style
	visible = _amount > 0.001
	if visible:
		queue_redraw()


func _draw() -> void:
	if _amount <= 0.001:
		return
	var mid: Vector2 = size * 0.5
	# The tube opens up as the weapon comes to the shoulder: at half-shoulder the circle
	# is wider than the screen, so the mask is invisible and only closes in as you commit.
	var full: float = minf(size.x, size.y) * 0.5 * tube_fraction
	var wide: float = maxf(size.x, size.y)
	var radius: float = lerpf(wide, full, _amount)

	# One annulus, from the tube edge out past every corner. `draw_arc` centres its
	# stroke on the radius it is given, hence the half-width offset.
	var band: float = wide * 2.0
	draw_arc(mid, radius + band * 0.5, 0.0, TAU, 128, mask_color, band, false)
	draw_arc(mid, radius, 0.0, TAU, 128, ring_color, 3.0, true)

	var ink: Color = reticle_color
	ink.a *= _amount
	_draw_cross(mid, radius, ink)
	if _reticle == Reticle.MIL_DOT:
		_draw_mils(mid, radius, ink)


## The crosshair: four spokes from the tube wall toward the middle, stopping short so
## the point of aim itself is never covered.
func _draw_cross(mid: Vector2, radius: float, ink: Color) -> void:
	var gap: float = center_gap
	var arm: float = radius - 2.0
	draw_line(mid + Vector2(-arm, 0.0), mid + Vector2(-gap, 0.0), ink, 1.5, true)
	draw_line(mid + Vector2(gap, 0.0), mid + Vector2(arm, 0.0), ink, 1.5, true)
	draw_line(mid + Vector2(0.0, -arm), mid + Vector2(0.0, -gap), ink, 1.5, true)
	draw_line(mid + Vector2(0.0, gap), mid + Vector2(0.0, arm), ink, 1.5, true)


## Ranging dots down the lower spoke and across the horizontal, which is where a real
## mil-dot reticle puts them: holdover below, wind either side.
func _draw_mils(mid: Vector2, radius: float, ink: Color) -> void:
	var step: float = radius * mil_step
	var dot: float = maxf(1.6, radius * 0.008)
	for i in range(1, 5):
		var d: float = step * float(i)
		if d >= radius - 4.0:
			break
		draw_circle(mid + Vector2(0.0, d), dot, ink)
		draw_circle(mid + Vector2(-d, 0.0), dot, ink)
		draw_circle(mid + Vector2(d, 0.0), dot, ink)


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED and visible:
		queue_redraw()
