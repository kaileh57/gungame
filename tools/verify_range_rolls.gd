extends Node
## Pull the scav range's lever sixty times and look at what actually comes off it.
##
##   "<godot>" --headless --path <proj> res://tools/verify_range_rolls.tscn
##
## RUNS AS A SCENE. `WeaponBench` calls the `GunFactory` autoload, so this drives the
## real demo rather than a model of it. That distinction is the whole point: the range
## was previously declared fixed on the strength of its class DIAL being wired to the
## right table, without anyone measuring what the lever produced. It produced six of
## seventeen classes and no scoped weapon at all, for sixty pulls running, because the
## seed advanced by one each time.
##
## The bar is deliberately about REACH rather than about matching an exact histogram: a
## random draw is allowed to be lumpy, but it is not allowed to be unable to reach most
## of the library, and "I could not find a single scope" has to be a run of bad luck
## rather than a structural impossibility.

const RANGE_SCENE := "res://demos/range/range.tscn"
## A normal session at the lever.
const PULLS := 60
## Under this many distinct classes the range is not sampling the library, it is stuck
## in a corner of it. The seed-walk scored 6.
const MIN_CLASSES := 11
## Scoped weapons are 11.8% of the population, so sixty pulls should turn up several.
## The seed-walk scored 0, which is what made scopes feel unobtainable.
const MIN_SCOPED := 3
## Any single class over this share means the draw is not spreading. The seed-walk put
## Carbine at 32%.
const MAX_SHARE := 0.30

var _frame := 0
var _done := false
var _root: Node = null


func _ready() -> void:
	var packed := load(RANGE_SCENE) as PackedScene
	if packed == null:
		_fail_out("could not load %s" % RANGE_SCENE)
		return
	_root = packed.instantiate()
	add_child(_root)


func _process(_delta: float) -> void:
	if _done or _root == null:
		return
	# Let the demo finish coming up; the bench rolls its opening gun in `_ready`.
	_frame += 1
	if _frame < 10:
		return
	_done = true
	_run()


func _run() -> void:
	var bench: Node = _find_bench(_root)
	if bench == null:
		_fail_out("no WeaponBench in the range scene")
		return

	var arch: Dictionary = {}
	var scoped := 0
	var autos := 0
	var seeds: Dictionary = {}
	var rolled := 0
	for i in PULLS:
		var spec = bench.call(&"scavenge")
		if spec == null:
			continue
		rolled += 1
		var a := String(spec.archetype)
		arch[a] = int(arch.get(a, 0)) + 1
		seeds[int(spec.roll_seed)] = true
		if spec.scoped:
			scoped += 1
		if spec.automatic:
			autos += 1

	var keys: Array = arch.keys()
	keys.sort_custom(func(x, y): return int(arch[x]) > int(arch[y]))
	var top_n: int = int(arch[keys[0]]) if keys.size() > 0 else 0
	var share: float = float(top_n) / maxf(float(rolled), 1.0)

	print("\n===== RANGE ROLLS =====")
	print("pulls              %d   distinct seeds %d" % [rolled, seeds.size()])
	print("distinct classes   %d   (need >= %d)" % [keys.size(), MIN_CLASSES])
	print("scoped             %d   (need >= %d)" % [scoped, MIN_SCOPED])
	print("automatic          %d" % autos)
	print(
		"most common        %s x%d = %.0f%%   (need <= %.0f%%)"
		% [String(keys[0]) if keys.size() > 0 else "-", top_n, share * 100.0, MAX_SHARE * 100.0]
	)
	var line := "spread            "
	for k in keys:
		line += " %s:%d" % [k, int(arch[k])]
	print(line)

	var bad := 0
	if keys.size() < MIN_CLASSES:
		bad += 1
		print("FAIL  only %d classes reachable" % keys.size())
	if scoped < MIN_SCOPED:
		bad += 1
		print("FAIL  %d scoped in %d pulls — scopes are effectively unobtainable" % [scoped, rolled])
	if share > MAX_SHARE:
		bad += 1
		print("FAIL  %s is %.0f%% of every pull" % [String(keys[0]), share * 100.0])
	if seeds.size() < rolled:
		bad += 1
		print("FAIL  %d pulls produced only %d distinct seeds" % [rolled, seeds.size()])
	print("result             %s" % ("FAIL" if bad > 0 else "PASS"))
	print("=====  END  =====")
	get_tree().quit(1 if bad > 0 else 0)


func _find_bench(node: Node) -> Node:
	if node.has_method(&"scavenge") and node.has_method(&"current"):
		return node
	for child: Node in node.get_children():
		var found: Node = _find_bench(child)
		if found != null:
			return found
	return null


func _fail_out(text: String) -> void:
	print("\n===== RANGE ROLLS =====")
	print("FAIL  %s" % text)
	print("=====  END  =====")
	get_tree().quit(1)
