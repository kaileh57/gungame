extends Node
## Main menu at rest and leaned in, so the zoom can be looked at.
const MENU := "res://ui/main_menu.tscn"
var _f := 0
var _m: Node = null


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute("res://_shots")
	_m = (load(MENU) as PackedScene).instantiate()
	add_child(_m)


func _process(_d: float) -> void:
	_f += 1
	if _f == 90:
		_save("res://_shots/menu_rest.png")
	if _f > 90 and _f < 200:
		# Drive the lean directly; a synthetic button press would fight the menu's own
		# input handling and prove nothing about the zoom itself.
		_m.set(&"_zoom", 1.0)
	if _f == 200:
		_save("res://_shots/menu_zoom.png")
		var eye = _m.get_node_or_null(^"Eye")
		print("fov zoomed = %.1f   base = %.1f" % [float(eye.fov), GameSettings.fov])
		get_tree().quit(0)


func _save(path: String) -> void:
	var img: Image = get_viewport().get_texture().get_image()
	print("%s -> %s" % [path, img.save_png(path) == OK])
