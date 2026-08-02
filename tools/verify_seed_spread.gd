@tool
extends SceneTree
## Does walking the seed by one give you the same gun over and over?
##
##   godot --headless --path <project> --script res://tools/verify_seed_spread.gd
##
## The scav range stepped its seed with `_seed += 1` from a fixed start, while the gun
## bench drew a fresh 32-bit value per roll. Both call the same `GunFactory.roll`, so
## the two were assumed to be equivalent and the range's guns were reported as "fixed"
## on the strength of the class dial being wired correctly. They are not equivalent,
## and this measures the gap rather than arguing about it.
##
## Rolls the same number of weapons both ways and prints the archetype spread, the
## share that came out automatic, and how many DISTINCT weapons each produced. A
## sequence that keeps handing you the same class is the defect the player reported as
## "it is genuinely ALL MACHINE GUNS".

const MANIFEST_PATH := "res://data/guns/part_library.tres"
const TUNING_PATH := "res://data/guns/gun_tuning.tres"
## What a player actually does at the bench: a few dozen pulls in a sitting.
const DRAWS := 60
## The range's shipped starting seed, from `WeaponBench.start_seed`.
const RANGE_START := 4711


func _process(_delta: float) -> bool:
	var pools := _pools()
	if pools.is_empty():
		quit(1)
		return true
	var tuning := _tuning()

	var walk: Array[int] = []
	for i in DRAWS:
		walk.append(RANGE_START + i)

	var rng := XorShift32.new(RANGE_START)
	var spread: Array[int] = []
	for i in DRAWS:
		spread.append(int(rng.next() * 4294967295.0) & 0xFFFFFFFF)

	print("\n===== SEED SPREAD =====")
	print("%d draws each, shipped tuning\n" % DRAWS)
	_report("range   (_seed += 1)", walk, pools, tuning)
	_report("bench   (32-bit draw)", spread, pools, tuning)
	print("=====  END  =====")
	quit(0)
	return true


func _report(label: String, seeds: Array[int], pools: Dictionary, tuning: GunTuning) -> void:
	var arch: Dictionary = {}
	var names: Dictionary = {}
	var autos := 0
	var scoped := 0
	for s in seeds:
		var w := GunAssembler.build(s, pools, tuning)
		if w == null:
			continue
		GunGrading.ensure(w)
		var a := String(w.archetype)
		arch[a] = int(arch.get(a, 0)) + 1
		names[String(w.weapon_name)] = true
		if w.automatic:
			autos += 1
		if w.scoped:
			scoped += 1
	var keys: Array = arch.keys()
	keys.sort_custom(func(x, y): return int(arch[x]) > int(arch[y]))
	var top: String = String(keys[0]) if keys.size() > 0 else "-"
	var top_n: int = int(arch[keys[0]]) if keys.size() > 0 else 0
	print(label)
	print(
		(
			"  distinct classes %2d   distinct names %2d   automatic %2d/%d   scoped %d"
			% [keys.size(), names.size(), autos, seeds.size(), scoped]
		)
	)
	print("  most common      %s x%d (%.0f%%)" % [top, top_n, 100.0 * top_n / seeds.size()])
	var line := "  spread          "
	for k in keys:
		line += " %s:%d" % [k, int(arch[k])]
	print(line)
	print("")


func _tuning() -> GunTuning:
	if ResourceLoader.exists(TUNING_PATH):
		var res := ResourceLoader.load(TUNING_PATH, "GunTuning") as GunTuning
		if res != null:
			return res
	return GunTuning.new()


func _pools() -> Dictionary:
	if not ResourceLoader.exists(MANIFEST_PATH):
		push_error("verify_seed_spread: %s missing." % MANIFEST_PATH)
		return {}
	var set_res := ResourceLoader.load(MANIFEST_PATH) as GunPartSet
	if set_res == null:
		return {}
	var pools: Dictionary = {}
	for kind: StringName in [&"barrel", &"stock", &"grip", &"receiver", &"sight"]:
		var bucket: Array[GunPart] = []
		pools[kind] = bucket
	for p: GunPart in set_res.parts:
		var bucket: Array[GunPart] = pools[p.kind]
		bucket.append(p)
	return pools
