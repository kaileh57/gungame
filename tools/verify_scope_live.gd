extends Node
## Aim a real scoped weapon in the real range and see whether the sight picture appears.
##   "<godot>" --headless --path <proj> res://tools/verify_scope_live.tscn
##
## The earlier scope test called `set_state` by hand, which proved the overlay DRAWS but
## not that anything drives it. The player then aimed a scoped weapon in the shipped
## build and got no tube and no magnification at all. This drives the whole chain the
## way play does: roll a scoped gun, put it in the holster, hold the shoulder, and read
## the overlay and the camera's field of view back.

const RANGE_SCENE := "res://demos/range/range.tscn"

var _f := 0
var _root: Node = null
var _cam: Node = null
var _player: Node = null
var _spec = null
var _log: Array = []


func _ready() -> void:
	_root = (load(RANGE_SCENE) as PackedScene).instantiate()
	add_child(_root)


func _process(_d: float) -> void:
	_f += 1
	if _f == 6:
		_setup()
	elif _f > 6:
		# Hold the shoulder. Written every frame before the rig's own priority-100 pass.
		if _player != null:
			_player.set(&"ads", 1.0)
		if _f == 200:
			_check()


func _setup() -> void:
	_cam = _find(_root, &"is_scoped")
	_player = _find(_root, &"freecam_active") if _cam == null else _cam.get_parent()
	var holster: Node = _find(_root, &"roll_into")
	if _cam == null or holster == null:
		_out(["FAIL  camera=%s holster=%s" % [_cam, holster]], 1)
		return
	# Hunt a genuinely scoped weapon out of the factory.
	for i in 4000:
		var s = GunFactory.roll(i * 2654435761 & 0x7FFFFFFF)
		if s != null and s.scoped:
			_spec = s
			break
	if _spec == null:
		_out(["FAIL  could not roll a scoped weapon at all"], 1)
		return
	_log.append("weapon             %s (%s)" % [_spec.weapon_name, _spec.archetype])
	_log.append("spec.scoped        %s   zoom ladder %s" % [_spec.scoped, _spec.zoom_ladder()])
	holster.call(&"equip", 0, _spec)


func _check() -> void:
	var bad := 0
	var scoped_flag: bool = bool(_cam.call(&"is_scoped"))
	var holster: Node = _find(_root, &"roll_into")
	var live = holster.call(&"active_spec") if holster != null else null
	_log.append("holster bound      %s" % (_cam.get(&"_holster") != null))
	_log.append("holster.active     %s" % (live.weapon_name if live != null else "<null>"))
	_log.append("active is scoped   %s" % (live.scoped if live != null else "n/a"))
	_log.append("is_swapping        %s" % holster.call(&"is_swapping"))
	_log.append("camera zoom now    %.2f" % float(_cam.call(&"current_zoom")))
	var overlay: Node = _cam.get_node_or_null(^"ScopeLayer/ScopeOverlay")
	var ads: float = float(_player.get(&"ads")) if _player != null else -1.0
	var fov_now: float = float(_cam.get(&"fov"))
	var fov_want: float = float(_cam.call(&"ads_fov"))

	_log.append("camera._scoped     %s   (must be true)" % scoped_flag)
	_log.append("player.ads         %.2f" % ads)
	_log.append("overlay node       %s" % ("present" if overlay != null else "MISSING"))
	if overlay != null:
		_log.append("overlay.visible    %s   (must be true)" % overlay.visible)
	_log.append("camera.fov         %.1f   ads_fov() says %.1f" % [fov_now, fov_want])

	if not scoped_flag:
		bad += 1
		_log.append("FAIL  the camera never learned the weapon is scoped")
	if overlay == null:
		bad += 1
		_log.append("FAIL  no overlay mounted")
	elif not overlay.visible:
		bad += 1
		_log.append("FAIL  overlay did not come up while shouldering a scope")
	if fov_now > fov_want + 6.0:
		bad += 1
		_log.append("FAIL  the world never zoomed in")
	_log.append("result             %s" % ("FAIL" if bad else "PASS"))
	_out(_log, 1 if bad else 0)


func _out(lines: Array, code: int) -> void:
	print("\n===== SCOPE LIVE =====")
	for l in lines:
		print(l)
	print("=====  END  =====")
	get_tree().quit(code)


func _find(n: Node, m: StringName) -> Node:
	if n.has_method(m) or (n.get(m) != null and n.get_script() != null):
		if n.has_method(m):
			return n
	for c: Node in n.get_children():
		var f: Node = _find(c, m)
		if f != null:
			return f
	return null
