extends Node
## Turn the range's real class dial and pull its real lever, exactly as a player does.
const RANGE_SCENE := "res://demos/range/range.tscn"
const PULLS := 30

var _f := 0
var _root: Node = null


func _ready() -> void:
	_root = (load(RANGE_SCENE) as PackedScene).instantiate()
	add_child(_root)


func _process(_d: float) -> void:
	_f += 1
	if _f != 10:
		return
	var bench: Node = _find(_root, &"scavenge")
	if bench == null:
		print("FAIL no bench")
		get_tree().quit(1)
		return
	var names: PackedStringArray = bench.call(&"classes")
	var dial = bench.get(&"_controls").get(&"class_dial")
	print("\n===== DIAL PATH =====")
	print("dial control      %s" % ("present" if dial != null else "*** MISSING ***"))
	print("classes()         %d entries" % names.size())
	for target: String in ["Marksman carbine", "Sniper"]:
		var idx: int = -1
		for i in names.size():
			if names[i] == target:
				idx = i
				break
		if idx < 0:
			print("%-18s NOT IN classes()" % target)
			continue
		if dial != null:
			dial.call(&"set_value", float(idx))
		var got: String = String(bench.call(&"_wanted_class"))
		var scoped := 0
		var right := 0
		for i in PULLS:
			var s = bench.call(&"scavenge")
			if s == null:
				continue
			if String(s.archetype) == target:
				right += 1
			if s.scoped:
				scoped += 1
		print(
			"%-18s detent %2d  _wanted_class()=%-18s  matched %2d/%d  SCOPED %2d"
			% [target, idx, "'" + got + "'", right, PULLS, scoped]
		)
	print("=====  END  =====")
	get_tree().quit(0)


func _find(n: Node, m: StringName) -> Node:
	if n.has_method(m):
		return n
	for c: Node in n.get_children():
		var f: Node = _find(c, m)
		if f != null:
			return f
	return null
