class_name AshFlatsMarks
extends Node3D
## WHERE EVERYBODY IS. A coloured mark standing over every other player, drawn through
## the town, findable at a glance from anywhere on the map.
##
## ASH FLATS IS THREE HUNDRED METRES OF DEAD TOWN and the whole point of it is that you
## can go anywhere in it. Two people in that at once, with nothing but a nameplate that
## has honestly faded out by ninety metres, cannot find each other — measured against the
## map's own numbers, not guessed: the line alone runs from z −118 to z +10.
##
## SO WHY NOT JUST USE GHOST MODE. Because GHOST is the RACE's presence: it makes bodies
## translucent and takes their collider away, and both of those are wrong for four people
## wandering a town. `PlayerAvatar` binds the beacon to GHOST, correctly, and this file is
## the other half of that decision — the same mark, on the same shader, for the walking
## state. The two never run at once: `set_racing(true)` hides every mark here the instant
## the lights go on, and GHOST's own beacon takes over. One mark per player, always,
## exactly one.
##
## IT REUSES THE AVATAR SYSTEM'S BEACON RATHER THAN INVENTING A SECOND ONE. Same shader,
## same shaft-and-diamond, same angular sizing law — so a player learns one mark and it
## means one thing. `res://data/net/beacon.tres` is baked; this file duplicates it once
## per player to write `mark_color` and never touches it again.
##
## THE NAME FADES IN WHERE THE NAMEPLATE FADES OUT. `NetNameplate` is honestly gone by
## ninety metres, which is right for a name over a head. Past that the mark is the only
## thing left, so it grows a name of its own — and under that range it stays silent, or
## the same player would be labelled twice.

## The avatar system's baked cross-map mark. Shared, duplicated per player for its colour.
const BEACON_MATERIAL: String = "res://data/net/beacon.tres"
const P_MARK_COLOR: StringName = &"mark_color"
const SHAFT_NODE: NodePath = ^"Shaft"
const NAME_NODE: NodePath = ^"Name"

## Metres over the feet the mark's shaft starts at, and the quad's own height-over-width.
## Both come from `PlayerAvatar` so the walking mark and the race beacon sit at the same
## height on the same body and one does not appear to jump when the other takes over.
const BASE_HEIGHT: float = PlayerAvatar.BEACON_BASE
const ASPECT: float = PlayerAvatar.BEACON_ASPECT

## Where the mark's own name starts and finishes fading in. The start is `NetNameplate`'s
## own `fade_end`, so exactly one name is drawn over a player at every range.
const NAME_IN: float = 88.0
const NAME_FULL: float = 120.0
## Apparent cap height of that name, in pixels at a 1080-tall viewport, and its limits in
## metres. The same law `NetNameplate` scales by: a name that is honestly constant in
## world space is two pixels at three hundred metres, which is not a name.
const NAME_PIXELS: float = 19.0
const NAME_MIN: float = 0.16
const NAME_MAX: float = 2.60
## World height the label is authored at — `font_size` times `pixel_size` in the baked
## prefab. Scaling is measured against this, so the two must agree.
const NAME_BASE: float = 64.0 * 0.0030

## The mark's baked prefab: a billboard quad and a label.
@export var mark_scene: PackedScene = null
## Mark height as a fraction of range, and its limits, in metres. The same law
## `PlayerAvatar` sizes the race beacon by: an angular size, so it is the same mark at
## forty metres and at four hundred.
@export_range(0.0, 0.2, 0.001) var mark_fraction: float = 0.032
@export_range(0.5, 40.0, 0.5) var mark_min: float = 3.0
@export_range(2.0, 200.0, 1.0) var mark_max: float = 44.0
## Metres inside which the mark is not drawn at all. You are looking at the person.
@export_range(0.0, 60.0, 0.5) var near_range: float = 12.0
## How often the roster is reconciled. Four players; this is not a hot path.
@export_range(0.05, 2.0, 0.05) var roster_seconds: float = 0.25

## peer id -> the mark node.
var _marks: Dictionary = {}
var _racing: bool = false
var _roster_clock: float = 999.0


func _ready() -> void:
	if mark_scene == null:
		push_warning("AshFlatsMarks: no baked mark prefab. Run res://tools/build_ash_flats.gd.")
		set_process(false)


func _process(delta: float) -> void:
	_roster_clock += delta
	if _roster_clock >= roster_seconds:
		_roster_clock = 0.0
		_sync()
	_place()


## Hide every mark while a race is on: GHOST mode wears the same beacon and two of them
## over one head is worse than either.
func set_racing(on: bool) -> void:
	if _racing == on:
		return
	_racing = on
	if not on:
		return
	for id: int in _marks:
		(_marks[id] as Node3D).visible = false


## Add anyone new, drop anyone gone, and keep every mark the right colour. Names and
## colours are read straight off the session, so a rename lands within a quarter second.
func _sync() -> void:
	var tree: SceneTree = get_tree()
	var local: int = NetAvatarLink.local_id(tree)
	var seen: Dictionary = {}
	for row: Dictionary in NetAvatarLink.roster(tree):
		var id: int = int(row[&"id"])
		if id == local:
			continue
		seen[id] = true
		_dress(_ensure(id), Color(row[&"color"]), String(row[&"name"]))
	for id: int in _marks.keys():
		if not seen.has(id):
			(_marks[id] as Node3D).queue_free()
			_marks.erase(id)


## Put every mark over its player and size it. One distance, one scale write and one
## alpha per remote player per frame — three of them, worst case.
func _place() -> void:
	if _marks.is_empty():
		return
	var camera: Camera3D = _eye()
	if camera == null:
		return
	var tree: SceneTree = get_tree()
	for id: int in _marks:
		var mark := _marks[id] as Node3D
		var body: Node3D = _body_of(tree, id)
		if body == null or _racing:
			mark.visible = false
			continue
		var foot: Vector3 = body.global_position + Vector3(0.0, BASE_HEIGHT, 0.0)
		var range_m: float = camera.global_position.distance_to(foot)
		mark.visible = range_m > near_range
		if not mark.visible:
			continue
		mark.global_position = foot
		var height: float = clampf(range_m * mark_fraction, mark_min, mark_max)
		var shaft := mark.get_node_or_null(SHAFT_NODE) as Node3D
		if shaft != null:
			shaft.scale = Vector3(height / ASPECT, height, 1.0)
		var label := mark.get_node_or_null(NAME_NODE) as Label3D
		if label != null:
			label.position.y = height * 1.06
			label.modulate.a = smoothstep(NAME_IN, NAME_FULL, range_m)
			label.scale = Vector3.ONE * (_name_height(camera, range_m) / NAME_BASE)


## The node a player's body currently is. `NetPresence` writes `NetPlayer.avatar` when it
## spawns one, which is the documented way to find somebody else's body.
func _body_of(tree: SceneTree, peer_id: int) -> Node3D:
	var who: NetPlayer = NetAvatarLink.player(tree, peer_id)
	if who == null or not is_instance_valid(who.avatar):
		return null
	return who.avatar


func _ensure(peer_id: int) -> Node3D:
	var found := _marks.get(peer_id) as Node3D
	if found != null:
		return found
	var mark := mark_scene.instantiate() as Node3D
	mark.name = "mark_%d" % peer_id
	mark.visible = false
	add_child(mark)
	# One material per player, because `mark_color` is a plain uniform and not an instance
	# one. Three in the worst case, and the shader behind them is shared.
	var shaft := mark.get_node_or_null(SHAFT_NODE) as MeshInstance3D
	if shaft != null:
		var material := shaft.get_active_material(0) as ShaderMaterial
		if material != null:
			shaft.material_override = material.duplicate()
	_marks[peer_id] = mark
	return mark


func _dress(mark: Node3D, color: Color, text: String) -> void:
	var shaft := mark.get_node_or_null(SHAFT_NODE) as MeshInstance3D
	if shaft != null:
		var material := shaft.material_override as ShaderMaterial
		if material != null:
			material.set_shader_parameter(P_MARK_COLOR, color)
	var label := mark.get_node_or_null(NAME_NODE) as Label3D
	if label != null:
		label.text = text
		var lifted: Color = NetColors.text(color)
		label.modulate = Color(lifted.r, lifted.g, lifted.b, label.modulate.a)


## World height the mark's name should be drawn at. `2 * tan(fov/2)` is how much world
## one metre of distance spans vertically, so the product is "the world height of
## `NAME_PIXELS` at this range" — a name that holds its size on screen.
func _name_height(camera: Camera3D, range_m: float) -> float:
	var span: float = 2.0 * tan(deg_to_rad(camera.fov) * 0.5)
	return clampf(range_m * span * (NAME_PIXELS / 1080.0), NAME_MIN, NAME_MAX)


func _eye() -> Camera3D:
	var viewport: Viewport = get_viewport()
	return null if viewport == null else viewport.get_camera_3d()
