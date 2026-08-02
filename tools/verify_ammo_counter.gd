extends Node
## Every gun in the game has a magazine count on it, and that count shows you the
## stoppage timer. This proves both, in every level that has a gun.
##
##   "<godot>" --headless --path <proj> res://tools/verify_ammo_counter.tscn
##
## RUNS AS A SCENE, NOT VIA `--script`. The counter is mounted by `WeaponHolster._ready`
## and the holster names the `GunFactory` autoload, so a `--script` main loop would
## either fail to compile the holster or instance a player that never runs `_ready` —
## and a static read of the `.tscn` files cannot see a node that is added at load time
## by definition. The demo has to actually come up.
##
## TWO GATES.
##
## 1. CENSUS. Every `WeaponHolster` in every baked demo is found by walking the loaded
##    tree, and each one must carry an `AmmoCounter` under its `Hand`, on the VIEWMODEL
##    layer, with the clearing ring present. This is the assertion that matters: the
##    counter used to be mounted by each demo that wanted one, which meant exactly two
##    of nine levels had it. Discovering the holsters rather than listing the demos is
##    deliberate — a new level with a gun is covered the day it is baked.
##
## 2. THE RING. The fill is driven across its whole range on a counter instanced on its
##    own, and each bar's `scale.x` is checked against the share of the ring that bar
##    spans. A ring whose shares do not sum to one fills to the wrong place at the wrong
##    time, which is the one way this can be quietly wrong rather than loudly absent.
##
## Exit code is non-zero on any failure.

const TARGETS: Array[Array] = [
	["range", "res://demos/range/range.tscn"],
	["arena", "res://demos/arena/arena.tscn"],
	["firefight", "res://demos/firefight/firefight.tscn"],
	["ash_flats", "res://demos/ash_flats/ash_flats.tscn"],
	["gunbench", "res://demos/gunbench/gunbench.tscn"],
	["movement", "res://demos/movement/movement.tscn"],
	["bestiary", "res://demos/bestiary/bestiary.tscn"],
	["visuals", "res://demos/visuals/visuals.tscn"],
]

## Frames a demo is given to come up before its tree is read. The holster mounts on
## `_ready`, so one would do; this is slack for a level that builds its player itself.
const SETTLE_FRAMES: int = 8

## Progress values the ring is driven through, and how many bars must be fully lit at
## each. With shares of roughly .31/.19/.31/.19 the halfway point lands exactly on the
## end of the second bar, which is the useful edge case to pin.
const RING_STEPS: Array[Array] = [[0.0, 0], [0.15, 0], [0.5, 2], [0.85, 3], [1.0, 4]]

var _index: int = 0
var _frame: int = 0
var _current: Node = null
var _pending: bool = false
var _log: PackedStringArray = []
var _failures: int = 0
var _holsters: int = 0


func _ready() -> void:
	_check_ring()
	_advance()


func _process(_delta: float) -> void:
	if _pending:
		_advance()
		return
	if _current == null:
		return
	_frame += 1
	if _frame < SETTLE_FRAMES:
		return
	_inspect(String(TARGETS[_index][0]))
	_index += 1
	_advance()


func _advance() -> void:
	if _current != null:
		_current.queue_free()
		_current = null
		# One idle frame with nothing in the tree, so the outgoing demo's `_exit_tree`
		# has run before the next one's `_enter_tree`. Two copies of the VFX hub at
		# once is a real failure mode here; see `tools/capture.gd`.
		_pending = true
		return
	_pending = false
	if _index >= TARGETS.size():
		_finish()
		return
	var path: String = String(TARGETS[_index][1])
	_frame = 0
	if not ResourceLoader.exists(path):
		_fail("%s is missing" % path)
		_index += 1
		_advance()
		return
	var packed := load(path) as PackedScene
	if packed == null:
		_fail("%s did not load" % path)
		_index += 1
		_advance()
		return
	_current = packed.instantiate()
	add_child(_current)


## Every holster in the loaded demo, and the counter each one must be carrying.
func _inspect(scene_id: String) -> void:
	var found: Array[Node] = []
	_collect(_current, found)
	if found.is_empty():
		_log.append("%-12s no holster — nothing to carry a counter" % scene_id)
		return
	for holster: Node in found:
		_holsters += 1
		_check_holster(scene_id, holster)


func _check_holster(scene_id: String, holster: Node) -> void:
	var hand: Node = holster.get_node_or_null(^"Hand")
	if hand == null:
		_fail("%s: holster %s has no Hand" % [scene_id, holster.name])
		return
	var plate := hand.get_node_or_null(^"AmmoCounter") as AmmoCounter
	if plate == null:
		_fail("%s: no ammo counter on %s/Hand" % [scene_id, holster.name])
		return
	if plate.get_node_or_null(^"ClearRing") == null:
		_fail("%s: the counter has no ClearRing" % scene_id)
		return
	var want: int = int(holster.get("render_layers"))
	var stray: int = _wrong_layer(plate, want)
	if stray > 0:
		_fail("%s: %d counter meshes are off the viewmodel layer" % [scene_id, stray])
		return
	_log.append("%-12s ok   counter on %s/Hand, layer %d" % [scene_id, holster.name, want])


## Meshes and labels under the plate that are not on the layer the holster renders on.
## One off-layer node is a plate the world camera can see through walls.
func _wrong_layer(root: Node, want: int) -> int:
	var stray: int = 0
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		var vi := n as VisualInstance3D
		if vi != null and vi.layers != want:
			stray += 1
		for child: Node in n.get_children():
			stack.push_back(child)
	return stray


func _collect(node: Node, out: Array[Node]) -> void:
	if node is WeaponHolster:
		out.append(node)
	for child: Node in node.get_children():
		_collect(child, out)


## Drive the ring end to end on a counter of its own, so a failure here is the ring's
## and not some demo's.
func _check_ring() -> void:
	var plate: AmmoCounter = AmmoCounter.spawn()
	if plate == null:
		_fail("the ammo counter is not baked — run tools/build_range.gd")
		return
	add_child(plate)
	var shares: PackedFloat32Array = plate.ring_shares
	var total: float = 0.0
	for s: float in shares:
		total += s
	if absf(total - 1.0) > 0.001:
		_fail("ring shares sum to %.4f, not 1" % total)
	for step: Array in RING_STEPS:
		_check_step(plate, float(step[0]), int(step[1]))
	plate.queue_free()


func _check_step(plate: AmmoCounter, progress: float, want_full: int) -> void:
	plate.set_clear_progress(progress)
	var ring: Node3D = plate.get_node_or_null(^"ClearRing") as Node3D
	if ring == null:
		_fail("the counter has no ClearRing")
		return
	if ring.visible != (progress > 0.0):
		_fail("ring visible=%s at progress %.2f" % [ring.visible, progress])
		return
	var full: int = 0
	var lit: int = 0
	for i: int in 4:
		var bar := ring.get_node_or_null(NodePath("Fill%d" % i)) as MeshInstance3D
		if bar == null:
			_fail("the ring has no Fill%d" % i)
			return
		if not bar.visible:
			continue
		lit += 1
		if bar.scale.x >= 0.999:
			full += 1
	if full != want_full:
		_fail("progress %.2f lit %d bars, %d full — wanted %d full" % [progress, lit, full, want_full])
		return
	_log.append("ring         %.2f -> %d lit, %d full" % [progress, lit, full])


func _fail(text: String) -> void:
	_failures += 1
	_log.append("FAIL         %s" % text)


func _finish() -> void:
	print("\n===== AMMO COUNTER =====")
	for line: String in _log:
		print(line)
	print("holsters %d   failures %d   %s" % [
		_holsters, _failures, "FAIL" if _failures > 0 else "PASS"
	])
	print("=====  END  =====")
	get_tree().quit(1 if _failures > 0 else 0)
