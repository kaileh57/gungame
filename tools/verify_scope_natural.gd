extends Node
## The in-game path, untouched: let the range's own bench hand the player weapons and
## watch whether the camera ever learns one is scoped.
##   "<godot>" --headless --path <proj> res://tools/verify_scope_natural.tscn

const RANGE_SCENE := "res://demos/range/range.tscn"

var _f := 0
var _root: Node = null
var _cam: Node = null
var _bench: Node = null
var _holster: Node = null
var _pulls := 0
var _seen_scoped := 0
var _adopted := 0
var _log: Array = []


func _ready() -> void:
	_root = (load(RANGE_SCENE) as PackedScene).instantiate()
	add_child(_root)


func _process(_d: float) -> void:
	_f += 1
	if _f == 8:
		_cam = _find(_root, &"is_scoped")
		_bench = _find(_root, &"scavenge")
		_holster = _find(_root, &"roll_into")
		if _cam == null or _bench == null or _holster == null:
			_out(["FAIL  cam=%s bench=%s holster=%s" % [_cam, _bench, _holster]], 1)
		return
	if _f < 8:
		return
	# Pull the lever, then give the swap a full second to land, exactly as a player does.
	if _f % 70 == 0 and _pulls < 14:
		_pulls += 1
		var s = _bench.call(&"scavenge")
		if s != null and s.scoped:
			_seen_scoped += 1
			_log.append("pull %2d  SCOPED   %s" % [_pulls, s.weapon_name])
	if _f % 70 == 60:
		var held = _holster.call(&"active_spec")
		if held != null and held.scoped:
			var learned: bool = bool(_cam.call(&"is_scoped"))
			if learned:
				_adopted += 1
			_log.append(
				"         holding %s  camera knows=%s  zoom=%.2f"
				% [held.weapon_name, learned, float(_cam.call(&"current_zoom"))]
			)
	if _f > 70 * 15:
		_finish()


func _finish() -> void:
	_log.append("")
	_log.append("pulls %d   scoped rolled %d   camera adopted %d" % [_pulls, _seen_scoped, _adopted])
	var bad := 0
	if _seen_scoped > 0 and _adopted == 0:
		bad = 1
		_log.append("FAIL  a scoped weapon was in hand and the camera never learned it")
	_log.append("result   %s" % ("FAIL" if bad else "PASS"))
	_out(_log, bad)


func _out(lines: Array, code: int) -> void:
	print("\n===== SCOPE NATURAL =====")
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
