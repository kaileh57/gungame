class_name GunTables
extends RefCounted
## The constant tables the gun derivation reads, and the handful of helpers that
## exist only to make JavaScript's numeric behaviour reproducible in GDScript.
##
## Everything here is transcribed from `reference/scav_range.html` via
## docs/spec/range.md. Nothing in this file is invented and nothing is tuned —
## balance departures live in `GunTuning`, applied by `GunAssembler`.
##
## Two traps worth restating, because they silently change every stat:
##   * `Math.log` is the NATURAL log. `Math.log2` appears once (the raw cone) and
##     `Math.log10` six times, hence `LN2` / `LN10` below.
##   * `(+x.toFixed(n))` rounds the stored double, so `(1.15).toFixed(1)` is
##     `"1.1"`, not `"1.2"`. `to_fixed()` reproduces that; `snapped()` does not.

## Index into a `TUNE` row.
enum Tune { DMG = 0, RPM = 1, CAP = 2, SPR = 3, REL = 4 }

## Millimetres per model unit. Weapon geometry is authored in model units and the
## whole ballistics chain consumes millimetres.
const MM: float = 90.0
## Model units cubed to cubic centimetres: `(MM / 10) ^ 3`.
const CM3: float = 729.0
## Radians per minute of arc. The reference's literal, not `PI / (180 * 60)`.
const MOA_RAD: float = 0.000290888

const LN2: float = 0.6931471805599453
const LN10: float = 2.302585092994046

## Deliberate interpenetration at each joint, in model units. These overlaps are
## the only reason an assembled gun has no air gaps at its seams — see the
## project's mesh rules. Never "clean them up".
const OVL: Dictionary = {&"barrel": 0.07, &"stock": 0.07, &"grip": 0.15, &"sight": 0.08}
## Hard scale limits per kind, `x` = minimum, `y` = maximum.
const LIM: Dictionary = {
	&"barrel": Vector2(0.50, 1.62),
	&"stock": Vector2(0.45, 1.80),
	&"grip": Vector2(0.24, 1.60),
	&"sight": Vector2(0.34, 1.60),
}
## Absolute body-size ceilings in model units, applied before `LIM`. A grip that
## would have to grow to fill a huge socket is capped instead, and eats the error.
const FIT_CAP_HEIGHT: Dictionary = {&"barrel": 1.85, &"stock": 2.10, &"grip": 1.95, &"sight": 0.95}
## Stocks alone also cap on length.
const FIT_CAP_STOCK_LENGTH: float = 4.0

## Real cartridges, in match order. `[bore mm, case length mm, name]`. The FIRST
## row within tolerance wins, so `.38 Special` is tested before `.357 Magnum`.
const KNOWN: Array = [
	[5.7, 28.0, "5.7×28"],
	[9.0, 19.0, "9×19"],
	[9.0, 29.0, ".38 Special"],
	[11.4, 23.0, ".45 ACP"],
	[10.9, 33.0, ".44 Magnum"],
	[9.1, 33.0, ".357 Magnum"],
	[5.45, 39.0, "5.45×39"],
	[5.56, 45.0, "5.56×45"],
	[7.62, 39.0, "7.62×39"],
	[7.62, 51.0, "7.62×51"],
	[7.92, 57.0, "7.92×57"],
	[8.6, 70.0, ".338 Lapua"],
	[12.7, 99.0, ".50 BMG"],
	[18.5, 70.0, "12 gauge"],
	[15.6, 70.0, "20 gauge"],
	[20.0, 80.0, "20 mm"],
	[40.0, 46.0, "40 mm HE"],
]
## Relative tolerance on bore, strict less-than.
const CARTRIDGE_BORE_TOL: float = 0.09
## Relative tolerance on case length, strict less-than.
const CARTRIDGE_LENGTH_TOL: float = 0.13

## Per-archetype multipliers: damage, rate, capacity, cone, reload.
const TUNE: Dictionary = {
	"Launcher": [1.00, 0.80, 0.75, 1.10, 1.35],
	"Machine gun": [0.95, 0.80, 1.30, 1.20, 1.35],
	"Submachine gun": [0.82, 0.86, 1.15, 0.92, 0.85],
	"Assault rifle": [1.05, 0.68, 1.05, 0.92, 1.00],
	"Auto battle rifle": [1.18, 0.62, 0.85, 1.10, 1.05],
	"Battle rifle": [1.14, 1.00, 0.90, 0.80, 1.00],
	"Sniper": [1.34, 0.85, 0.70, 0.50, 1.10],
	"Marksman carbine": [1.14, 1.00, 0.85, 0.62, 1.00],
	"Shotgun": [1.12, 1.00, 0.85, 1.15, 1.05],
	"Auto shotgun": [0.92, 1.05, 1.10, 1.25, 1.10],
	"Slug gun": [1.30, 0.90, 0.75, 0.55, 1.05],
	"Hand cannon": [1.22, 0.90, 0.85, 1.05, 1.00],
	"Sidearm": [1.00, 0.85, 0.90, 1.00, 0.85],
	"Carbine": [0.95, 0.80, 1.05, 0.95, 0.95],
	"Chopped auto": [0.92, 0.92, 1.05, 1.30, 0.85],
	"Snubnose": [0.90, 1.00, 0.90, 1.45, 0.85],
	"Hybrid": [1.00, 1.00, 1.00, 1.00, 1.00],
}

## How much a poor donor match is allowed to open the cone, per archetype.
const LOOSE: Dictionary = {
	"Sniper": 0.15,
	"Marksman carbine": 0.22,
	"Battle rifle": 0.40,
	"Assault rifle": 0.44,
	"Auto battle rifle": 0.46,
	"Carbine": 0.46,
	"Machine gun": 0.48,
	"Hand cannon": 0.50,
	"Launcher": 0.52,
	"Slug gun": 0.55,
	"Sidearm": 0.55,
	"Hybrid": 0.55,
	"Submachine gun": 0.58,
	"Shotgun": 0.58,
	"Chopped auto": 0.60,
	"Snubnose": 0.60,
	"Auto shotgun": 0.62,
}
const LOOSE_DEFAULT: float = 0.5

## Minimum cone in MOA before the fit-quality widening, per archetype.
const FLOOR: Dictionary = {
	"Auto shotgun": 120.0,
	"Shotgun": 90.0,
	"Slug gun": 22.0,
	"Snubnose": 20.0,
	"Chopped auto": 16.0,
	"Launcher": 14.0,
	"Submachine gun": 11.0,
	"Sidearm": 9.0,
	"Hybrid": 9.0,
	"Hand cannon": 8.0,
	"Machine gun": 7.0,
	"Auto battle rifle": 7.0,
	"Carbine": 6.0,
	"Assault rifle": 6.0,
	"Battle rifle": 4.5,
	"Marksman carbine": 3.0,
	"Sniper": 1.8,
}
const FLOOR_DEFAULT: float = 8.0

## Minimum score for each tier. Index 0 is the `-1` sentinel: Hazard is skipped
## by the score loop and is only reachable through the reliability clamp.
## Rounds per minute a class is EXPECTED to run at, as [slow end, fast end].
##
## THE POINT OF THIS TABLE. Rate was graded on an absolute scale, so "fast" was
## simply good everywhere and a pump shotgun was marked down for being a pump
## shotgun. It is judged against its OWN class now: a weapon at the slow end of its
## band is unremarkable there and a weapon at the fast end is a find. That is why a
## slow shotgun is fine and a fast one is a prize, while a slow rifle is just a bad
## rifle.
##
## The bands are the cadence a class is RECOGNISED by, not a clamp — nothing here
## limits what the geometry produces, it only decides how the result is read.
const CLASS_RATE: Dictionary = {
	# Slow is normal. These are worked by hand or by a heavy action.
	"Launcher": [18.0, 40.0],
	"Slug gun": [55.0, 110.0],
	"Shotgun": [60.0, 140.0],
	"Snubnose": [90.0, 170.0],
	"Hand cannon": [80.0, 160.0],
	"Sniper": [35.0, 90.0],
	# Middling. A shooter's cadence, trigger-limited more often than not.
	"Marksman carbine": [90.0, 220.0],
	"Battle rifle": [120.0, 320.0],
	"Carbine": [150.0, 420.0],
	"Sidearm": [140.0, 380.0],
	"Assault rifle": [400.0, 750.0],
	# Fast is normal. A cyclic action is the whole point of these.
	"Auto battle rifle": [450.0, 780.0],
	"Machine gun": [500.0, 900.0],
	"Chopped auto": [550.0, 1000.0],
	"Submachine gun": [600.0, 1150.0],
	"Auto shotgun": [180.0, 330.0],
}
## Used when an archetype is missing from the table above.
const CLASS_RATE_DEFAULT: Array = [120.0, 600.0]

const TIER_MIN: PackedFloat32Array = [-1.0, 0.0, 62.4, 69.9, 73.1, 75.1, 77.2]
## Optics rank per tier index, used by the magnification ladder.
const TIER_RANK: PackedInt32Array = [0, 0, 1, 1, 2, 3, 4]
## Below this reliability a gun is Hazard, or Field-Grade at best.
const REL_CLAMP_HAZARD: int = 14
## Below this reliability a gun cannot climb past Gunsmithed.
const REL_CLAMP_GUNSMITHED: int = 30

## What the world actually hands out, as percentages — the weights sum to 100.
## `Hybrid` is deliberately absent: it only ever appears as a roll fallback.
const CLASS_MIX: Array = [
	["Assault rifle", 15],
	["Shotgun", 10],
	["Submachine gun", 8],
	["Sniper", 7],
	["Machine gun", 7],
	["Battle rifle", 7],
	["Marksman carbine", 6],
	["Launcher", 6],
	["Sidearm", 6],
	["Carbine", 5],
	["Hand cannon", 5],
	["Slug gun", 5],
	["Chopped auto", 5],
	["Auto battle rifle", 4],
	["Snubnose", 3],
	["Auto shotgun", 1],
]
const MIX_TOTAL: int = 100

const PREF: PackedStringArray = [
	"Rusted",
	"Scabbed",
	"Welded",
	"Zip-Tied",
	"Cracked",
	"Bootleg",
	"Coffin",
	"Tetanus",
	"Foundry",
	"Cinder",
	"Bastard",
	"Orphan",
	"Crooked",
	"Reclaimed",
	"Slagged",
	"Hexbolt",
	"Secondhand",
	"Half-Blind",
	"Overbored",
	"Undersprung",
	"Widowed",
	"Grave-Dug",
	"Pig-Iron",
	"Twice-Stolen",
	"Left-Handed",
]
const NOUN: PackedStringArray = [
	"Widow",
	"Preacher",
	"Kettle",
	"Sermon",
	"Cough",
	"Whistle",
	"Kicker",
	"Argument",
	"Divorce",
	"Apology",
	"Grudge",
	"Tantrum",
	"Handshake",
	"Verdict",
	"Nailfile",
	"Debt",
	"Rumour",
	"Migraine",
	"Toothache",
	"Loudmouth",
	"Last Word",
	"Bad News",
	"Fair Warning",
	"Second Opinion",
	"Change of Heart",
]
const ROM: PackedStringArray = [
	"I", "II", "III", "IV", "V", "VI", "VII", "VIII", "IX", "X", "XI", "XII"
]

## Feed labels for the stat card. The raw keys are what `GunSpec.feed` holds.
const FEED_LABEL: Dictionary = {
	&"box": "box mag",
	&"tube": "tube",
	&"cylinder": "cylinder",
	&"internal": "internal",
	&"breech": "breech",
}

## What the trigger and the action actually do, keyed by the display mode string
## that `GunSpec.fire_mode` carries. The display string is stored rather than the
## action id because it is the lossless one — several modes map to `auto`.
const ACTION: Dictionary = {
	&"Full-auto": &"auto",
	&"Machine pistol": &"auto",
	&"3-round burst": &"burst",
	&"Semi-auto": &"semi",
	&"Bolt-action": &"bolt",
	&"Pump-action": &"pump",
	&"Double-action": &"double",
	&"Break-action": &"break",
	&"Single-shot": &"single",
}


## `Math.log2`. GDScript's `log()` is natural, like JavaScript's.
## Where `rpm` sits inside its class's expected band, 0 at the slow end and 1 at the
## fast end. Outside the band it keeps going, so a genuinely freakish rate still
## reads as freakish rather than saturating.
## Classes that have no business carrying a sniper scope: everything you fight with
## inside fifty metres. `docs/GUN_DESIGN.md` §4 asks for irons to be far more common on
## shotguns and pistols, and for a scoped bullet hose to stay a rare joke rather than
## the default.
const CLOSE_QUARTERS: Array = [
	"Shotgun",
	"Auto shotgun",
	"Slug gun",
	"Snubnose",
	"Sidearm",
	"Hand cannon",
	"Submachine gun",
	"Chopped auto",
	"Launcher",
]

## Share of otherwise-eligible weapons that keep a scope they have no use for. Two
## rates: a close-quarters weapon almost never keeps one, which is what makes a scoped
## machine pistol a story rather than a Tuesday, and everything else keeps one
## sometimes.
const SCOPE_STRAY: float = 0.20
const SCOPE_STRAY_CLOSE: float = 0.06


## A deterministic 0..1 draw for a weapon, off its own config word.
##
## Not an RNG: the same five parts must produce the same weapon every time on every
## machine, or two players quoting a seed would see different guns and the golden
## vectors would stop meaning anything. `salt` separates independent decisions that
## would otherwise correlate.
static func draw01(cfg: int, salt: int) -> float:
	var h: int = (cfg ^ salt) & 0x7FFFFFFF
	h = (h * 374761393 + 668265263) & 0x7FFFFFFF
	h = ((h ^ (h >> 13)) * 1274126177) & 0x7FFFFFFF
	return float(h & 0xFFFF) / 65535.0


## Whether this weapon ends up carrying a real scope.
##
## SCOPES WERE SPRAYED ACROSS THE LIBRARY. The rule was "marksman, OR a good battle
## rifle, OR any ladder topping SCOPE_ZOOM" — and that last clause caught everything,
## so 235 weapons were scoped and only 51 of them were marksman weapons. 78% of every
## scope in the game sat on a gun with no use for one, which is both what
## `docs/GUN_DESIGN.md` §4 complains about and why a player hunting a sniper could not
## find one worth carrying.
##
## Marksman glass is scoped outright and a rank-2 battle rifle has earned it. Anything
## else only KEEPS a scope on a deterministic draw, and that draw is far harsher for a
## close-quarters weapon — so a scoped machine pistol stays the joke the design asks
## for rather than the ordinary case.
static func scope_fitted(
	spec: GunSpec, marksman: bool, battle: bool, rank: int, top_zoom: float
) -> bool:
	if marksman or (rank >= 2 and battle):
		return true
	if top_zoom < 4.2:
		return false
	var arch: String = String(spec.archetype)
	var limit: float = SCOPE_STRAY_CLOSE if CLOSE_QUARTERS.has(arch) else SCOPE_STRAY
	return draw01(spec.cfg, 0x5C09E) < limit


static func rate_position(archetype: String, rpm: float) -> float:
	var band: Array = CLASS_RATE.get(archetype, CLASS_RATE_DEFAULT)
	var lo: float = float(band[0])
	var hi: float = maxf(float(band[1]), lo + 1.0)
	return clampf((rpm - lo) / (hi - lo), -0.6, 1.6)


static func log2(x: float) -> float:
	return log(x) / LN2


## `Math.log10`.
static func log10(x: float) -> float:
	return log(x) / LN10


## `(+x.toFixed(n))`. `printf` rounds half-to-even on the exact double, which
## agrees with JavaScript on every value this system produces. Do not substitute
## `snapped()`: it rounds the decimal you meant, not the double you have.
static func to_fixed(x: float, n: int) -> float:
	return float(("%." + str(n) + "f") % x)


## JavaScript's number-to-string for a value already rounded to `n` decimals:
## `22` prints as `"22"`, `3.8` as `"3.8"`, `9.0` as `"9"`.
static func num_text(x: float, n: int) -> String:
	var s: String = ("%." + str(n) + "f") % x
	if s.contains("."):
		s = s.rstrip("0").rstrip(".")
	return s


## Name a cartridge from its unrounded bore and case length. Falls through to a
## wildcat designation when nothing in `KNOWN` is within tolerance.
##
## The wildcat bore keeps its trailing zero — the reference concatenates the
## `toFixed(1)` STRING here, with no numeric coercion, so 11.0 mm is "11.0" and
## not "11". The separator is U+00D7, not the letter x.
static func cartridge_name(bore: float, case_len: float, shot: bool) -> String:
	for row: Array in KNOWN:
		var b: float = row[0]
		var l: float = row[1]
		if absf(bore - b) / b < CARTRIDGE_BORE_TOL:
			if absf(case_len - l) / l < CARTRIDGE_LENGTH_TOL:
				return row[2]
	var suffix: String = " shot" if shot else " wildcat"
	return "%.1f×%d%s" % [bore, roundi(case_len), suffix]


## Tier index for a score and a reliability, 0 Hazard through 6 Relic.
##
## A gun that eats itself is never a prize, but one that merely jams a lot is not
## scrap either — it just cannot climb past the middle of the ladder.
static func tier_index_for(score: float, reliability: float) -> int:
	var i: int = 1
	for k: int in TIER_MIN.size():
		if TIER_MIN[k] >= 0.0 and score >= TIER_MIN[k]:
			i = k
	if reliability < REL_CLAMP_HAZARD:
		return 0 if score < TIER_MIN[2] else mini(i, 3)
	if reliability < REL_CLAMP_GUNSMITHED:
		return mini(i, 4)
	return i


## Weighted archetype draw from a single uniform in [0, 1).
static func wanted_class(u: float) -> String:
	var x: float = u * float(MIX_TOTAL)
	for row: Array in CLASS_MIX:
		var weight: float = float(row[1])
		if x < weight:
			return row[0]
		x -= weight
	return "Assault rifle"


## The reference's `nameFor`. `groups` is the distinct donor families in assembly
## order, receiver first. Consumes 1 to 3 draws — the count is part of the
## contract, so the branches below must not be collapsed.
static func name_for(rand: XorShift32, groups: Array[StringName]) -> String:
	var a: String = String(groups[0])
	var b: String = String(groups[1]) if groups.size() > 1 else a
	match int(floor(rand.next() * 5.0)):
		0:
			return "%s %s" % [draw(rand, PREF), a]
		1:
			return "%s-%s" % [a, b]
		2:
			return "The %s" % draw(rand, NOUN)
		3:
			return "%s Mk.%s" % [a, draw(rand, ROM)]
	return "%s %s" % [draw(rand, PREF), draw(rand, NOUN)]


## The reference's `pick(r, a)` over a packed string array: one draw, floor-indexed.
static func draw(rand: XorShift32, words: PackedStringArray) -> String:
	return words[int(floor(rand.next() * float(words.size())))]


## Trigger behaviour for a display fire mode: `auto`, `burst`, `semi`, `bolt`,
## `pump`, `double`, `break` or `single`.
static func action_for(mode: StringName) -> StringName:
	return ACTION.get(mode, &"semi")


## Stat-card label for a feed key.
static func feed_label(feed: StringName) -> String:
	return FEED_LABEL.get(feed, String(feed))
