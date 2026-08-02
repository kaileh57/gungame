extends Node3D
## How high does a corpse actually go? Drops a baked ragdoll on a floor, hits it with
## the hardest shot the game can deliver, and records the peak height it reaches.
##   "<godot>" --headless --path <proj> res://tools/verify_ragdoll_launch.tscn
##
## The killing impulse is capped at `Ragdoll.max_impulse`, and the cap was verified by
## reading the constant rather than by watching a body — which is exactly the kind of
## check that passes while corpses sail over the treeline. This measures the outcome.

## A body may be thrown, but a shot should not put one on the roof.
const PEAK_LIMIT: float = 2.5
const SETTLE_SECONDS: float = 4.0

var _rag: Node = null
var _t: float = 0.0
var _start_y: float = 0.0
var _peak: float = 0.0
var _name: String = ""


func _ready() -> void:
	var floor_body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(80.0, 2.0, 80.0)
	shape.shape = box
	floor_body.add_child(shape)
	floor_body.position = Vector3(0.0, -1.0, 0.0)
	add_child(floor_body)

	var dir := DirAccess.open("res://data/enemies/ragdolls")
	var pick := ""
	if dir != null:
		for f in dir.get_files():
			if f.ends_with(".res"):
				pick = "res://data/enemies/ragdolls/" + f
				break
	if pick == "":
		_out("FAIL  no baked ragdolls", 1)
		return
	_name = pick.get_file()
	var packed := load(pick) as PackedScene
	_rag = packed.instantiate()
	add_child(_rag)
	_rag.position = Vector3(0.0, 1.0, 0.0)
	await get_tree().physics_frame
	_start_y = _highest()
	# The worst case the game can produce: a sprinting body taking the hardest shot.
	var aim: Vector3 = Vector3(0.0, 0.35, -1.0).normalized()
	# The worst case the game can hand over: the hardest shot AND a nonsense velocity of
	# the kind a depenetration shove or an accumulated fall produces. Both are capped
	# inside `begin`, and this is the test that says so.
	_rag.call(&"begin", Vector3(0.0, 120.0, -60.0), Vector3(0.0, 1.6, 0.0), aim, 1200.0)


func _physics_process(delta: float) -> void:
	if _rag == null:
		return
	_t += delta
	_peak = maxf(_peak, _highest() - _start_y)
	if _t >= SETTLE_SECONDS:
		# A corpse that never simulated cannot fly, and reporting that as PASS is how a
		# launch test lies to you. Prove the solve ran before trusting the height.
		var simulating: bool = bool(_rag.call(&"is_simulating_physics"))
		var bones: int = int(_rag.call(&"body_count"))
		var lines: Array = [
			"ragdoll            %s" % _name,
			"bodies             %d" % bones,
			"simulating         %s   (must be true or the number below is meaningless)" % simulating,
			"max_impulse        %s" % _rag.get(&"max_impulse"),
			"max_momentum       %s m/s" % _rag.get(&"max_momentum"),
			"asked for          1200 N-s and 134 m/s of momentum",
			"peak rise          %.2f m   (limit %.2f)" % [_peak, PEAK_LIMIT],
		]
		var bad: int = 0
		if not simulating or bones == 0:
			bad = 1
			lines.append("FAIL  the ragdoll never simulated, so this measured nothing")
		elif _peak > PEAK_LIMIT:
			bad = 1
			lines.append("FAIL  the corpse was launched")
		lines.append("result             %s" % ("FAIL" if bad else "PASS"))
		_out("\n".join(lines), bad)


## Highest point any solved bone has reached.
func _highest() -> float:
	var best: float = -1e9
	var stack: Array[Node] = [_rag]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		var pb := n as PhysicalBone3D
		if pb != null:
			best = maxf(best, pb.global_position.y)
		for c: Node in n.get_children():
			stack.push_back(c)
	return best if best > -1e8 else 0.0


func _out(text: String, code: int) -> void:
	print("\n===== RAGDOLL LAUNCH =====")
	print(text)
	print("=====  END  =====")
	get_tree().quit(code)
