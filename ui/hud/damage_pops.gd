class_name DamagePops
extends Control
## Damage numbers that rise off the thing you hit.
##
## Every slot is allocated once, at ready, and reused forever: a firefight against
## twenty enemies must not allocate a Label per bullet. A pop that runs out of
## slots overwrites the oldest, which is correct — the newest number is the one
## you are looking at.
##
## Positions are world points projected through the camera each frame, so a pop
## stays welded to the ribcage it came off while both of you move.

## Colours and sizes by kind, from the reference's HUD.
const KINDS: Dictionary = {
	&"hit": {"color": Color(0.886, 0.867, 0.831), "size": 15},
	&"crit": {"color": Color(1.0, 0.427, 0.290), "size": 18},
	&"down": {"color": Color(0.902, 0.757, 0.310), "size": 17},
	&"boom": {"color": Color(0.878, 0.478, 0.208), "size": 17},
	&"break": {"color": Color(0.498, 0.753, 0.659), "size": 15},
}
## Seconds a pop lives, and the pixels it climbs in that time.
const LIFETIME: float = 1.0
const RISE_PIXELS: float = 46.0

## How many pops can be on screen at once.
@export_range(8, 96, 1) var pool_size: int = 40
## Pops further than this from the camera are dropped rather than drawn as
## unreadable specks.
@export_range(10.0, 600.0, 5.0) var max_distance: float = 220.0

var _camera: Camera3D = null
var _points: PackedVector3Array = PackedVector3Array()
var _ages: PackedFloat32Array = PackedFloat32Array()
var _texts: PackedStringArray = PackedStringArray()
var _colors: PackedColorArray = PackedColorArray()
var _sizes: PackedInt32Array = PackedInt32Array()
var _next: int = 0
var _live: int = 0
var _font: Font = null


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_font = UiStyle.display_font()
	_points.resize(pool_size)
	_ages.resize(pool_size)
	_texts.resize(pool_size)
	_colors.resize(pool_size)
	_sizes.resize(pool_size)
	_ages.fill(LIFETIME)


func _process(delta: float) -> void:
	if _live == 0:
		return
	_live = 0
	for i: int in pool_size:
		if _ages[i] >= LIFETIME:
			continue
		_ages[i] += delta
		if _ages[i] < LIFETIME:
			_live += 1
	queue_redraw()


func set_camera(camera: Camera3D) -> void:
	_camera = camera


## Add a number at a world point. `kind` is one of the keys in KINDS; anything
## else falls back to a plain hit, because a typo should still show the damage.
func add_pop(world_point: Vector3, text: String, kind: StringName = &"hit") -> void:
	if _camera == null or not is_instance_valid(_camera):
		return
	if _camera.global_position.distance_to(world_point) > max_distance:
		return
	var style: Dictionary = KINDS.get(kind, KINDS[&"hit"])
	_points[_next] = world_point
	_ages[_next] = 0.0
	_texts[_next] = text
	_colors[_next] = style["color"]
	_sizes[_next] = int(style["size"])
	_next = (_next + 1) % pool_size
	_live += 1
	queue_redraw()


func _draw() -> void:
	if _camera == null or not is_instance_valid(_camera):
		return
	if _font == null:
		_font = UiStyle.display_font()
	var bounds := Rect2(-Vector2(80.0, 40.0), size + Vector2(160.0, 80.0))
	for i: int in pool_size:
		var age: float = _ages[i]
		if age >= LIFETIME:
			continue
		var world: Vector3 = _points[i]
		if _camera.is_position_behind(world):
			continue
		var screen: Vector2 = _camera.unproject_position(world)
		if not bounds.has_point(screen):
			continue
		var t: float = age / LIFETIME
		var color: Color = _colors[i]
		# Hold full opacity for the first third, then fall away — a number that
		# starts fading immediately reads as a rendering glitch.
		color.a = clampf((1.0 - t) * 1.5, 0.0, 1.0)
		var text: String = _texts[i]
		var half: float = (
			_font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, _sizes[i]).x * 0.5
		)
		draw_string(
			_font,
			screen + Vector2(-half, -RISE_PIXELS * t),
			text,
			HORIZONTAL_ALIGNMENT_LEFT,
			-1.0,
			_sizes[i],
			color
		)
