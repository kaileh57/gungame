class_name GunQuirks
extends RefCounted
## What is particularly wrong with this weapon, or particularly right about it.
##
## `GunGrading` decides how good a gun is on a smooth ladder. That ladder alone
## makes every Scrap gun the same Scrap gun — a bit worse at everything. This is
## the layer that gives one of them a bolt you have to lean on and the next one a
## magazine that eats a round every twenty shots.
##
## **A quirk here is never a label.** Every entry carries an `m` bundle that
## `GunGrading` folds into the profile it hands the mechanism, so "sticky bolt"
## IS a 40 % longer bolt throw inside `GunReload`, "bent feed lips" IS a short
## magazine and a double-feed inside `GunAmmo`, and "loose optic" IS most of your
## sight picture gone inside `GunSpread`. If a name appears on the stat card, a
## number moved.
##
## Traits are drawn ONCE per weapon off `GunSpec.cfg`, so a given assembly always
## has the same faults. You learn to distrust that gun specifically rather than
## learning that scrap guns are statistically worse.
##
## How many a weapon draws is a function of quality alone: a rough weapon
## collects faults, a fine weapon collects virtues, and the band between them
## mostly gets the one thing worth mentioning. The gate on each entry keeps a
## trait attached to hardware that could have it — "bent gate" only on a tube,
## "worn sear" only on something that fires by itself, "loose optic" only on a
## gun with glass on it.

## Stream salt. Kept off every other per-weapon stream so a gun's faults are not
## correlated with the reloads it fumbles or the rounds its magazine loses.
const QUIRK_SALT: int = 0x6C078965

## Mods applied as `1 + (m - 1) * strength`. These land on quantities that are
## already 1.0-ish on a Field-Grade weapon, so a multiplier has something to bite.
const SCALES: Array[StringName] = [
	&"jam",
	&"clear",
	&"hard",
	&"bloom",
	&"ceiling",
	&"settle",
	&"sight",
	&"relief",
	&"reload",
	&"cycle",
	&"shell",
]

## Mods applied as `+ m * strength`. These land on probabilities and ramps that
## sit at or near zero on a good weapon, where a multiplier would have nothing to
## work on: no multiple of a 0.2 % fumble chance is a fumble you ever see.
const ADDENDS: Array[StringName] = [
	&"wear",
	&"tail",
	&"short",
	&"misfeed",
	&"fumble",
	&"floor",
]

## Quality below which a weapon collects three faults.
const COUNT_THREE: float = 0.42
## Quality below which it collects two.
const COUNT_TWO: float = 0.58
## Quality above which a weapon is good enough to be worth two virtues.
const COUNT_FINE: float = 0.84

## Magazine size at which stack-related traits become available.
const MAG_MIN: int = 8
## Kilograms above which a weapon counts as heavy for gating.
const HEAVY_KG: float = 5.4
## Rate stress above which the action is visibly outrunning itself.
const STRESS_GATE: float = 0.18
## Actions that must be worked by hand between shots.
const MANUAL: PackedStringArray = ["bolt", "pump", "break", "single", "double"]

## Every trait in the game.
##   n   name, as it appears on the stat card
##   w   draw weight within whatever else is eligible
##   lo  lowest quality that can carry it, inclusive
##   hi  highest quality that can carry it, exclusive
##   g   hardware gate; see `_gate_ok`
##   m   what it DOES, in `SCALES` and `ADDENDS` keys
##
## The rough half is deliberately larger than the fine half. Bad guns are content
## and there has to be more than one way for a gun to be bad.
const TRAITS: Array[Dictionary] = [
	# --- the action -----------------------------------------------------------
	{
		&"n": "sticky bolt",
		&"w": 1.3,
		&"lo": 0.0,
		&"hi": 0.62,
		&"g": &"manual",
		&"m": {&"cycle": 1.42, &"clear": 1.18},
	},
	{
		&"n": "burred chamber",
		&"w": 1.2,
		&"lo": 0.0,
		&"hi": 0.60,
		&"g": &"any",
		&"m": {&"jam": 1.55, &"hard": 1.35},
	},
	{
		&"n": "grit in the works",
		&"w": 1.1,
		&"lo": 0.0,
		&"hi": 0.56,
		&"g": &"any",
		&"m": {&"jam": 1.30, &"clear": 1.12, &"wear": 0.70},
	},
	{
		&"n": "worn sear",
		&"w": 1.0,
		&"lo": 0.0,
		&"hi": 0.58,
		&"g": &"auto",
		&"m": {&"jam": 1.22, &"bloom": 1.24, &"ceiling": 1.16},
	},
	{
		&"n": "heat-warped",
		&"w": 1.0,
		&"lo": 0.0,
		&"hi": 0.66,
		&"g": &"auto",
		&"m": {&"wear": 0.85, &"bloom": 1.15},
	},
	{
		&"n": "overrun action",
		&"w": 1.8,
		&"lo": 0.0,
		&"hi": 0.78,
		&"g": &"stress",
		&"m": {&"jam": 1.38, &"ceiling": 1.22, &"wear": 0.60},
	},
	{
		&"n": "heavy trigger",
		&"w": 0.9,
		&"lo": 0.0,
		&"hi": 0.72,
		&"g": &"any",
		&"m": {&"bloom": 1.16, &"settle": 0.88},
	},
	# --- the feed -------------------------------------------------------------
	{
		&"n": "bent feed lips",
		&"w": 1.3,
		&"lo": 0.0,
		&"hi": 0.60,
		&"g": &"mag",
		&"m": {&"short": 0.070, &"misfeed": 0.020},
	},
	{
		&"n": "tired spring",
		&"w": 1.2,
		&"lo": 0.0,
		&"hi": 0.68,
		&"g": &"mag",
		&"m": {&"tail": 0.90, &"wear": 0.45},
	},
	{
		&"n": "stiff spring",
		&"w": 0.8,
		&"lo": 0.0,
		&"hi": 0.74,
		&"g": &"mag",
		&"m": {&"reload": 1.10, &"tail": 0.40},
	},
	{
		&"n": "bent gate",
		&"w": 1.4,
		&"lo": 0.0,
		&"hi": 0.70,
		&"g": &"tube",
		&"m": {&"shell": 1.45, &"fumble": 0.040},
	},
	{
		&"n": "greasy grip",
		&"w": 1.0,
		&"lo": 0.0,
		&"hi": 0.62,
		&"g": &"any",
		&"m": {&"fumble": 0.060, &"reload": 1.12},
	},
	# --- the furniture and the glass -----------------------------------------
	{
		&"n": "cracked stock",
		&"w": 1.1,
		&"lo": 0.0,
		&"hi": 0.60,
		&"g": &"any",
		&"m": {&"bloom": 1.28, &"relief": 0.72},
	},
	{
		&"n": "loose optic",
		&"w": 1.4,
		&"lo": 0.0,
		&"hi": 0.66,
		&"g": &"optic",
		&"m": {&"sight": 0.62, &"floor": 0.060},
	},
	{
		&"n": "canted sights",
		&"w": 1.2,
		&"lo": 0.0,
		&"hi": 0.60,
		&"g": &"irons",
		&"m": {&"sight": 0.70, &"floor": 0.050},
	},
	{
		&"n": "whippy barrel",
		&"w": 1.0,
		&"lo": 0.0,
		&"hi": 0.64,
		&"g": &"any",
		&"m": {&"floor": 0.050, &"settle": 0.80},
	},
	{
		&"n": "loose choke",
		&"w": 1.3,
		&"lo": 0.0,
		&"hi": 0.68,
		&"g": &"shot",
		&"m": {&"bloom": 1.30, &"ceiling": 1.18},
	},
	{
		&"n": "muzzle-heavy",
		&"w": 0.9,
		&"lo": 0.0,
		&"hi": 0.66,
		&"g": &"heavy",
		&"m": {&"settle": 0.82, &"relief": 1.18, &"reload": 1.08},
	},
	# --- the earned half ------------------------------------------------------
	{
		&"n": "broken-in",
		&"w": 1.0,
		&"lo": 0.62,
		&"hi": 1.01,
		&"g": &"any",
		&"m": {&"jam": 0.86, &"clear": 0.90},
	},
	{
		&"n": "crisp trigger",
		&"w": 1.0,
		&"lo": 0.66,
		&"hi": 1.01,
		&"g": &"any",
		&"m": {&"bloom": 0.88, &"settle": 1.14},
	},
	{
		&"n": "match barrel",
		&"w": 1.1,
		&"lo": 0.74,
		&"hi": 1.01,
		&"g": &"any",
		&"m": {&"bloom": 0.80, &"floor": -0.060},
	},
	{
		&"n": "tuned sear",
		&"w": 1.1,
		&"lo": 0.72,
		&"hi": 1.01,
		&"g": &"auto",
		&"m": {&"settle": 1.20, &"bloom": 0.88, &"ceiling": 0.88},
	},
	{
		&"n": "hand-fitted",
		&"w": 1.2,
		&"lo": 0.78,
		&"hi": 1.01,
		&"g": &"any",
		&"m": {&"jam": 0.68, &"clear": 0.80, &"hard": 0.55},
	},
	{
		&"n": "polished feed",
		&"w": 1.1,
		&"lo": 0.72,
		&"hi": 1.01,
		&"g": &"mag",
		&"m": {&"short": -0.060, &"misfeed": -0.030, &"wear": -0.50},
	},
	{
		&"n": "speed mag",
		&"w": 1.0,
		&"lo": 0.70,
		&"hi": 1.01,
		&"g": &"mag",
		&"m": {&"reload": 0.84, &"fumble": -0.050},
	},
	{
		&"n": "slick gate",
		&"w": 1.3,
		&"lo": 0.70,
		&"hi": 1.01,
		&"g": &"tube",
		&"m": {&"shell": 0.76, &"fumble": -0.040},
	},
	{
		&"n": "quick bolt",
		&"w": 1.2,
		&"lo": 0.70,
		&"hi": 1.01,
		&"g": &"manual",
		&"m": {&"cycle": 0.74},
	},
	{
		&"n": "cheek weld",
		&"w": 1.0,
		&"lo": 0.74,
		&"hi": 1.01,
		&"g": &"optic",
		&"m": {&"relief": 1.28, &"sight": 1.10},
	},
]

## Name to `m` bundle, built once on first use. The table is a const so this can
## never go stale.
static var _index: Dictionary = {}


## How many traits a weapon of this quality draws.
##
## The shape is deliberate: the bottom of the ladder gets THREE independent
## faults, which is what stops two Scrap guns reading as the same gun, and the
## top gets two virtues so a Warlord can say why it is better rather than only
## being better. Field-Grade sits on one, and a Field-Grade weapon that happens
## to be eligible for nothing carries none — which is the correct reading of an
## unremarkable object.
static func count_for(q: float) -> int:
	if q < COUNT_THREE:
		return 3
	if q < COUNT_TWO:
		return 2
	if q < COUNT_FINE:
		return 1
	return 2


## Draw this weapon's traits. Deterministic in `spec.cfg`; the same five parts
## fitted the same way always produce the same faults.
static func roll(spec: GunSpec, q: float, stress: float) -> PackedStringArray:
	var out := PackedStringArray()
	if spec == null:
		return out
	var want: int = count_for(q)
	if want <= 0:
		return out
	var pool: Array[int] = []
	var total: float = 0.0
	for i: int in TRAITS.size():
		var t: Dictionary = TRAITS[i]
		if q < float(t[&"lo"]) or q >= float(t[&"hi"]):
			continue
		if not _gate_ok(t[&"g"], spec, stress):
			continue
		pool.append(i)
		total += float(t[&"w"])
	var rand := XorShift32.new((spec.cfg ^ QUIRK_SALT) & 0xFFFFFFFF)
	while out.size() < want and not pool.is_empty():
		var pick: int = _draw(pool, total, rand)
		var t: Dictionary = TRAITS[pool[pick]]
		out.append(String(t[&"n"]))
		total -= float(t[&"w"])
		pool.remove_at(pick)
	return out


## The accumulated effect of `names`, as a full bundle with every key present.
##
## `strength` is the per-mechanism dial: 0 turns the character layer off without
## changing which names are on the card, 1 is the shipped weight, 2 doubles every
## departure from neutral. Scales compound multiplicatively and addends sum, so
## two traits that both eat the magazine eat it twice.
static func mods(names: PackedStringArray, strength: float) -> Dictionary:
	var out: Dictionary = {}
	for k: StringName in SCALES:
		out[k] = 1.0
	for k: StringName in ADDENDS:
		out[k] = 0.0
	if strength <= 0.0 or names.is_empty():
		return out
	for n: String in names:
		var m: Dictionary = mods_for(n)
		for k: StringName in m:
			var v: float = float(m[k])
			if SCALES.has(k):
				out[k] = float(out[k]) * (1.0 + (v - 1.0) * strength)
			elif ADDENDS.has(k):
				out[k] = float(out[k]) + v * strength
	return out


## What one named trait does. Empty for a name that is not a trait — the
## reference quirks and the derived character tags both pass through here and
## correctly contribute nothing, because their effect is already in the number
## they were read off.
static func mods_for(trait_name: String) -> Dictionary:
	if _index.is_empty():
		for t: Dictionary in TRAITS:
			_index[String(t[&"n"])] = t[&"m"]
	var found: Variant = _index.get(trait_name, null)
	return found if found is Dictionary else {}


## Every trait name in the game, for a census or a bestiary page.
static func names() -> PackedStringArray:
	var out := PackedStringArray()
	for t: Dictionary in TRAITS:
		out.append(String(t[&"n"]))
	return out


## One weighted draw from the surviving pool. Walks the weights rather than
## sorting, which is cheap at this table size and keeps the stream position
## dependent only on how many draws were taken.
static func _draw(pool: Array[int], total: float, rand: XorShift32) -> int:
	var u: float = rand.next() * maxf(total, 1.0e-6)
	for k: int in pool.size():
		u -= float(TRAITS[pool[k]][&"w"])
		if u <= 0.0:
			return k
	return pool.size() - 1


## Does this weapon have the hardware the trait needs?
static func _gate_ok(gate: StringName, spec: GunSpec, stress: float) -> bool:
	match gate:
		&"any":
			return true
		&"auto":
			return spec.automatic
		&"manual":
			return MANUAL.has(String(GunTables.action_for(spec.fire_mode)))
		&"mag":
			return spec.magazine >= MAG_MIN and spec.feed != &"tube"
		&"tube":
			return spec.feed == &"tube"
		&"shot":
			return spec.pellets > 1
		&"optic":
			return spec.has_optic
		&"irons":
			return not spec.has_optic
		&"heavy":
			return spec.mass >= HEAVY_KG
		&"stress":
			return stress > STRESS_GATE
	return false
