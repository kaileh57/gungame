extends Node
## Does the sniper scope actually draw? Runs the real range and drives the real rig.
##   "<godot>" --headless --path <proj> res://tools/verify_scope.tscn

const RANGE_SCENE := "res://demos/range/range.tscn"

var _f := 0
var _root: Node = null


func _ready() -> void:
	_root = (load(RANGE_SCENE) as PackedScene).instantiate()
	add_child(_root)


func _process(_d: float) -> void:
	_f += 1
	if _f != 12:
		return
	var cam: Node = _find(_root, &"is_scoped")
	if cam == null:
		_out(["FAIL  no PlayerCameraRig"], 1)
		return
	var scope: Node = cam.get_node_or_null(^"ScopeLayer/ScopeOverlay")
	var lines: Array = []
	if scope == null:
		_out(["FAIL  no ScopeLayer/ScopeOverlay was mounted"], 1)
		return
	lines.append("mounted            ScopeLayer/ScopeOverlay on %s" % cam.name)
	lines.append("ignores input      %s" % (scope.mouse_filter == Control.MOUSE_FILTER_IGNORE))
	lines.append("hidden at rest     %s" % (not scope.visible))
	var bad := 0
	# Hip fire with a scope: no tube.
	scope.call(&"set_state", 0.0, true, 8.0)
	if scope.visible:
		bad += 1
		lines.append("FAIL  tube is up at ads=0")
	# Shouldered, scoped: tube up, mil-dot reticle at high magnification.
	scope.call(&"set_state", 1.0, true, 8.0)
	lines.append("ads=1 scoped 8x    visible=%s" % scope.visible)
	if not scope.visible:
		bad += 1
		lines.append("FAIL  no tube when shouldering a scope")
	# Shouldered, NOT scoped: never a tube on irons.
	scope.call(&"set_state", 1.0, false, 1.15)
	if scope.visible:
		bad += 1
		lines.append("FAIL  tube drawn for an unscoped weapon")
	else:
		lines.append("irons at ads=1     no tube (correct)")
	lines.append("result             %s" % ("FAIL" if bad else "PASS"))
	_out(lines, 1 if bad else 0)


func _out(lines: Array, code: int) -> void:
	print("\n===== SCOPE =====")
	for l in lines:
		print(l)
	print("=====  END  =====")
	get_tree().quit(code)


func _find(n: Node, m: StringName) -> Node:
	if n.has_method(m):
		return n
	for c: Node in n.get_children():
		var f: Node = _find(c, m)
		if f != null:
			return f
	return null
