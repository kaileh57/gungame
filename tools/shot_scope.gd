extends Node
## Put a scoped weapon in the player's hands, shoulder it, and SAVE THE FRAME.
##   "<godot>" --path <proj> --resolution 1280x720 res://tools/shot_scope.tscn
## Deliberately NOT headless: the whole point is to see what is actually drawn.

const RANGE_SCENE := "res://demos/range/range.tscn"
const OUT := "res://_shots/scope.png"
const OUT_HIP := "res://_shots/scope_hip.png"

var _f := 0
var _root: Node = null
var _cam: Node = null
var _player: Node = null
var _note := ""


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute("res://_shots")
	_root = (load(RANGE_SCENE) as PackedScene).instantiate()
	add_child(_root)


func _process(_d: float) -> void:
	_f += 1
	if _f == 10:
		_equip()
	if _f > 10 and _player != null and _f < 150:
		_player.set(&"ads", 0.0)
	if _f == 120:
		_save(OUT_HIP, "hip")
	if _f >= 150 and _player != null:
		_player.set(&"ads", 1.0)
	if _f == 240:
		_save(OUT, "shouldered")
		print(_note)
		get_tree().quit(0)


func _equip() -> void:
	_cam = _find(_root, &"is_scoped")
	_player = _cam.get_parent() if _cam != null else null
	var holster: Node = _find(_root, &"roll_into")
	for i in 6000:
		var s = GunFactory.roll((i * 2654435761 + 11) & 0x7FFFFFFF, "Sniper")
		if s != null and s.scoped:
			holster.call(&"equip", 0, s)
			_note = "weapon %s  scoped=%s  ladder=%s" % [s.weapon_name, s.scoped, s.zoom_ladder()]
			return
	_note = "NO SCOPED SNIPER FOUND"


func _save(path: String, label: String) -> void:
	var img: Image = get_viewport().get_texture().get_image()
	var err: int = img.save_png(path)
	var vis := "?"
	if _cam != null:
		var o = _cam.get_node_or_null(^"ScopeLayer/ScopeOverlay")
		if o != null:
			vis = "%s size=%s anchors_r=%.2f viewport=%s" % [
				o.visible, o.size, o.anchor_right, get_viewport().get_visible_rect().size
			]
		else:
			vis = "no overlay"
	_note += "\n%-11s saved=%s  overlay.visible=%s  fov=%.1f  scoped=%s" % [
		label, err == OK, vis, float(_cam.get(&"fov")), _cam.call(&"is_scoped")
	]


func _find(n: Node, m: StringName) -> Node:
	if n.has_method(m):
		return n
	for c: Node in n.get_children():
		var f: Node = _find(c, m)
		if f != null:
			return f
	return null
