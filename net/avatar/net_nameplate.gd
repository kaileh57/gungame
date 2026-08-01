class_name NetNameplate
extends Label3D
## A player's name, floating over them, facing you, readable at thirty metres and never
## in the way.
##
## Four rules, and each one is a term in `_process`:
##
##   FACES THE CAMERA. `Label3D.billboard` does it in the vertex stage for free, which
##   is why this is a Label3D and not a Sprite3D with a baked texture — no per-frame
##   `look_at`, and it is correct in every viewport at once, including a demo that
##   renders a second eye into a SubViewport.
##
##   SCALES SENSIBLY. Constant screen size up close, then a ceiling. A nameplate that
##   is honestly constant in screen space is four metres tall at a hundred metres, and
##   one that is honestly constant in WORLD space is two pixels at thirty. So it holds
##   `target_pixels` until `max_height` binds — about twenty-three metres at the
##   defaults — and shrinks with distance after that, which is exactly the range band
##   where you want to be told there IS someone rather than made to read their name.
##
##   NEVER OCCLUDES GAMEPLAY. Depth-tested by default, so a name behind a wall is not
##   drawn, and faded out entirely past `fade_end`. `through_walls` is the ONE
##   exception, and only GHOST mode turns it on.
##
##   LEGIBLE ON ANYTHING. The text is the player's colour lifted toward bone, over a
##   hard ink outline. A saturated hue at full value is unreadable as small type over
##   pale sand and bone-white alone loses its owner; the lift keeps the hue as identity
##   and the outline keeps the glyphs.
##
## The plate is baked into `res://data/net/player_avatar.tscn` and into the laser
## cursor; nothing constructs one by hand.

## Cap height the plate holds on screen, in pixels at a 1080-tall viewport. Scaled with
## the real viewport, so a 720p window gets the same apparent size.
const REFERENCE_HEIGHT: float = 1080.0

## Apparent height in reference pixels, before `max_height` binds.
@export_range(6.0, 80.0, 0.5) var target_pixels: float = 22.0
## Floor and ceiling on the plate's WORLD height, in metres. The ceiling is what stops
## a distant name growing into a billboard; the floor only guards against zero.
@export_range(0.01, 1.0, 0.01) var min_height: float = 0.05
@export_range(0.1, 6.0, 0.05) var max_height: float = 0.75
## Metres at which the plate starts to fade, and where it is gone.
@export_range(1.0, 2000.0, 1.0) var fade_start: float = 55.0
@export_range(2.0, 4000.0, 1.0) var fade_end: float = 90.0
## Alpha at full strength. Names are information, not decoration.
@export_range(0.0, 1.0, 0.01) var base_alpha: float = 0.92
## Drawn over the world instead of behind it. GHOST mode only.
@export var through_walls: bool = false:
	set = set_through_walls

## The player colour this plate belongs to, before the lift toward bone.
var player_color: Color = Color.WHITE:
	set = set_color

var _extra_fade: float = 1.0
## Cached so the scale law does not divide by a font metric every frame.
var _base_height: float = 0.1


func _ready() -> void:
	billboard = BaseMaterial3D.BILLBOARD_ENABLED
	shaded = false
	double_sided = true
	fixed_size = false
	# DISABLED and not DISCARD: the plate fades out with distance, and a discard
	# threshold turns a fade into a pop at whatever alpha the threshold sits at.
	alpha_cut = Label3D.ALPHA_CUT_DISABLED
	texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	no_depth_test = through_walls
	_base_height = maxf(float(font_size) * pixel_size, 0.0001)
	set_color(player_color)


func _process(_delta: float) -> void:
	var camera: Camera3D = _eye()
	if camera == null:
		visible = false
		return
	var distance: float = camera.global_position.distance_to(global_position)
	var fade: float = _fade_at(distance) * _extra_fade
	if fade <= 0.004 or text.is_empty():
		visible = false
		return
	visible = true
	scale = Vector3.ONE * (_world_height(camera, distance) / _base_height)
	modulate.a = base_alpha * fade
	outline_modulate.a = base_alpha * fade


## Set the owning player's colour. The text takes a lifted version of it and the
## outline stays ink, which is what keeps small type readable over pale sand.
func set_color(c: Color) -> void:
	player_color = c
	var lifted: Color = NetColors.text(c)
	lifted.a = modulate.a
	modulate = lifted
	outline_modulate = Color(0.035, 0.031, 0.028, outline_modulate.a)


func set_through_walls(on: bool) -> void:
	through_walls = on
	no_depth_test = on
	# Drawn after the world it is drawn over, so two plates behind each other still
	# sort against one another rather than flickering.
	render_priority = 3 if on else 1


## An extra multiplier on the plate's alpha, 0 to 1. Used to fade a whole avatar in and
## out without the plate arguing about it.
func set_dim(fraction: float) -> void:
	_extra_fade = clampf(fraction, 0.0, 1.0)


## World height in metres the plate should be drawn at, for a given eye and range.
## `2 * tan(fov/2)` is how much world one unit of distance spans vertically, so the
## first product is "the world height of `target_pixels` at this range".
func _world_height(camera: Camera3D, distance: float) -> float:
	var span: float = 2.0 * tan(deg_to_rad(camera.fov) * 0.5)
	var fraction: float = target_pixels / REFERENCE_HEIGHT
	return clampf(distance * span * fraction, min_height, max_height)


func _fade_at(distance: float) -> float:
	if distance <= fade_start:
		return 1.0
	return clampf(1.0 - (distance - fade_start) / maxf(fade_end - fade_start, 0.001), 0.0, 1.0)


## The live eye of whatever viewport this plate is rendered into. Read every frame
## rather than cached, because a demo that swaps to its F8 freecam swaps the camera and
## a plate that kept the old one would scale itself against a viewpoint nobody has.
func _eye() -> Camera3D:
	var viewport: Viewport = get_viewport()
	return null if viewport == null else viewport.get_camera_3d()
