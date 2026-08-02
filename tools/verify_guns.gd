@tool
extends SceneTree
## Gun roll verifier: checks the port against the reference's golden vectors and
## then measures what the shipped balance actually produces.
##
## Two passes. The first runs `GunTuning.reference_exact()` and compares every
## published field of the golden builds in docs/spec/range.md §10 — a mismatch
## there means the derivation drifted and every downstream number is void. The
## second rolls `SAMPLES` weapons through the shipped tuning and reports the class
## and tier census, the range of every stat, and anything non-finite or absurd.
##
## Run headless:
##   godot --headless --path <project> --script res://tools/verify_guns.gd

## Joint-distribution counting; see that file for why it is not a flag census.
const GunOdds := preload("res://tools/gun_odds.gd")
## The reference's published builds. Data only; see that file before editing one.
const GOLD_SEEDS := preload("res://tools/gun_golden.gd").GOLD_SEEDS
const MANIFEST_PATH := "res://data/guns/part_library.tres"
## Must match `GunFactory.TUNING_PATH`. Naming the autoload here instead would
## compile its whole dependency tree, which a `--script` run has no autoloads for.
const TUNING_PATH := "res://data/guns/gun_tuning.tres"
const REPORT_PATH := "res://data/gun_balance_report.txt"
const SAMPLES := 2000
## Class-targeted rolls on top of the raw pass, to exercise `roll_typed`.
const TYPED_SAMPLES := 400
## Raw builds used to measure how often each archetype occurs at all.
const DEEP_SAMPLES := 40000
## Independent 420-attempt budgets a targeted roll gets before it counts as a miss.
const TARGET_BUDGETS := 5
## Tolerance for a published (already rounded) field. These must land exactly.
const GOLD_EPS := 1.0e-6
## Relative tolerance for the RAW floats — mass, impulse, the recoil constants.
##
## `GunPart.ext` is a `Vector3`, so part extents carry single-precision. The fit caps
## divide by `ext.y`, which puts ~1e-7 of relative error into `k` before the derivation
## has done anything, and mass, energy, impulse and the recoil constants inherit it.
## Every rounded field still lands on the golden integer, which is the bar that
## matters; this tolerance says how much slack the storage width buys.
const GOLD_REL := 4.0e-7

## Every scalar field the census tracks.
const STAT_FIELDS := [
	"score",
	"damage",
	"spread",
	"rpm",
	"cyclic",
	"magazine",
	"reload_time",
	"muzzle_velocity",
	"muzzle_energy",
	"effective_range",
	"burst_dps",
	"sustained_dps",
	"precision",
	"reach",
	"kick",
	"handling",
	"reliability",
	"mass",
	"impulse",
	"barrel_length",
	"overall_length",
	"bore",
	"case_length",
	"pellets",
	"crit_multiplier",
	"zoom",
	"recoil_vertical",
	"recoil_horizontal",
	"blast_radius",
	"headshot_range",
	"fit_error",
]

## Per-bucket character columns, as `GunSpec field:decimals`. `rpm` is reported as a
## min/mean/max band, because how WIDE that band is inside one bucket is the whole
## question the rate work has to answer.
const CHAR_COLS := (
	"cyclic:0 recoil_vertical:4 recoil_horizontal:4 recoil_settle:3"
	+ " recoil_period:2 kick:0 handling:0"
)

## The rows the before/after and ablation tables report. Deliberately only the
## metrics the shipped departures are meant to move, so a surprise is visible.
const COMPARE_ROWS := [
	"min effective_range",
	"mean effective_range",
	"max effective_range",
	"min spread",
	"mean spread",
	"max spread",
	"min precision",
	"mean precision",
	"max mass",
	"mean mass",
	"min handling",
	"mean handling",
	"max kick",
	"mean kick",
	"max recoil_vertical",
	"mean recoil_vertical",
	"max rpm",
	"mean rpm",
	"max burst_dps",
	"mean burst_dps",
	"max sustained_dps",
	"mean sustained_dps",
	"max magazine",
	"mean magazine",
	"max reload_time",
	"mean reload_time",
	"min reliability",
	"mean reliability",
	"mean score",
	"max fit_error",
	"tier Hazard",
	"tier Scrap",
	"tier Relic",
	"quirk crew-served",
	"quirk blunderbuss",
	"quirk jam-prone",
	"quirk drum-fed",
]

var _lines := PackedStringArray()
var _failures := 0
var _done := false


## Runs on the first frame rather than in `_init`: the autoload nodes this verifies
## do not exist until the main loop has started.
func _process(_delta: float) -> bool:
	if _done:
		return true
	_done = true
	_run()
	return true


func _run() -> void:
	var started := Time.get_ticks_msec()
	var pools := _load_pools()
	if pools.is_empty():
		quit(1)
		return

	_say("gun roll verification — %d part pools" % pools.size())
	_check_rng()
	_check_golden(pools)
	_check_hand_picked(pools)
	var shipped := _shipped_tuning()
	var before := _census(pools, GunTuning.reference_exact(), "reference_exact")
	var after := _census(pools, shipped, "shipped")
	_compare(before, after)
	_ablate(pools, before)
	_typed_census(pools, shipped)
	_check_factory()

	_say("")
	_say("elapsed              %d ms" % (Time.get_ticks_msec() - started))
	_say("FAILURES             %d" % _failures)
	var text := "\n".join(_lines) + "\n"
	print(text)
	var f := FileAccess.open(REPORT_PATH, FileAccess.WRITE)
	if f != null:
		f.store_string(text)
		f.close()
	quit(1 if _failures > 0 else 0)


## What the game actually rolls through: the baked balance resource if the bake
## has written one, otherwise the code defaults, exactly as `GunFactory` decides.
func _shipped_tuning() -> GunTuning:
	if ResourceLoader.exists(TUNING_PATH):
		var res := ResourceLoader.load(TUNING_PATH, "GunTuning") as GunTuning
		if res != null:
			return res
	return GunTuning.new()


func _load_pools() -> Dictionary:
	if not ResourceLoader.exists(MANIFEST_PATH):
		push_error("verify_guns: %s missing. Run res://tools/bake_gun_parts.gd." % MANIFEST_PATH)
		return {}
	var set_res := ResourceLoader.load(MANIFEST_PATH) as GunPartSet
	if set_res == null or set_res.parts.size() != 95:
		push_error("verify_guns: %s is not a 95-part GunPartSet." % MANIFEST_PATH)
		return {}
	var pools: Dictionary = {}
	for kind: StringName in [&"barrel", &"stock", &"grip", &"receiver", &"sight"]:
		var bucket: Array[GunPart] = []
		pools[kind] = bucket
	for p: GunPart in set_res.parts:
		var bucket: Array[GunPart] = pools[p.kind]
		bucket.append(p)
	return pools


func _check_rng() -> void:
	var expect := [
		0.00006295018829405308,
		0.015739798778668046,
		0.42266560392454267,
		0.8155057488474995,
		0.6551597700454295,
	]
	var r := XorShift32.new(1)
	var worst := 0.0
	for v: float in expect:
		worst = maxf(worst, absf(r.next() - v))
	_assert(worst < 1.0e-15, "XorShift32(1) stream, worst delta %s" % String.num_scientific(worst))


func _check_golden(pools: Dictionary) -> void:
	var t := GunTuning.reference_exact()
	_say("")
	_say("-- golden vectors (reference_exact) --")
	var head := "%-7s %-20s %-18s %-14s %-17s %5s %4s %5s %6s %4s %5s"
	_say(
		head % ["seed", "name", "arch", "tier", "cal", "rpm", "cap", "dmg", "spread", "rel", "oal"]
	)
	for seed_key: int in GOLD_SEEDS.keys():
		var want: Dictionary = GOLD_SEEDS[seed_key]
		var w := GunAssembler.build(seed_key, pools, t)
		if w == null:
			_assert(false, "seed %d produced no spec at all" % seed_key)
			continue
		_say(
			(
				head
				% [
					seed_key,
					w.weapon_name,
					w.archetype,
					w.tier_name,
					w.caliber,
					w.rpm,
					w.magazine,
					w.damage,
					w.spread,
					w.reliability,
					w.overall_length,
				]
			)
		)
		for field: String in want.keys():
			var got: Variant = w.get(field)
			var exp: Variant = want[field]
			var ok: bool = (
				absf(float(got) - float(exp)) < GOLD_EPS
				if (exp is float or exp is int)
				else String(got) == String(exp)
			)
			_assert(ok, "seed %d %s: got %s want %s" % [seed_key, field, got, exp])

	# §10.1 publishes the full record for seed 1; check the fields the table omits.
	var g1 := GunAssembler.build(1, pools, t)
	_assert(g1.cfg == 3710188260, "seed 1 cfg %d want 3710188260" % g1.cfg)
	_close(g1.score, 70.71991707780789, "seed 1 score")
	_close(g1.mass, 5.900794746439747, "seed 1 mass")
	_close(g1.impulse, 9.528200281999123, "seed 1 impulse")
	_close(g1.spread_rad, 0.006473800524395552, "seed 1 spread_rad")
	_assert(g1.cyclic == 430, "seed 1 cyclic %d want 430" % g1.cyclic)
	_assert(g1.feed == &"box", "seed 1 feed %s want box" % g1.feed)
	_assert(g1.fire_mode == &"Full-auto", "seed 1 mode %s want Full-auto" % g1.fire_mode)
	_assert(absf(g1.reload_time - 2.7) < GOLD_EPS, "seed 1 reload %.2f want 2.7" % g1.reload_time)
	_assert(g1.effective_range == 153, "seed 1 range %d want 153" % g1.effective_range)
	_assert(g1.burst_dps == 410, "seed 1 burst %d want 410" % g1.burst_dps)
	_assert(g1.sustained_dps == 296, "seed 1 sust %d want 296" % g1.sustained_dps)
	_assert(g1.precision == 50, "seed 1 precision %d want 50" % g1.precision)
	_assert(g1.reach == 72, "seed 1 reach %d want 72" % g1.reach)
	_assert(g1.kick == 30, "seed 1 kick %d want 30" % g1.kick)
	_assert(g1.handling == 54, "seed 1 hand %d want 54" % g1.handling)
	_assert(
		absf(g1.crit_multiplier - 2.31) < GOLD_EPS,
		"seed 1 crit %.3f want 2.31" % g1.crit_multiplier
	)
	_assert(g1.sim_velocity == 309, "seed 1 simVel %d want 309" % g1.sim_velocity)
	_assert(
		absf(g1.headshot_range - 44.0) < GOLD_EPS, "seed 1 hsRange %.1f want 44" % g1.headshot_range
	)
	_close(g1.recoil_vertical, 0.005167141412738263, "seed 1 recV")
	_close(g1.recoil_horizontal, 0.003402152582684378, "seed 1 recH")
	_assert(
		absf(g1.recoil_drift - 0.539) < GOLD_EPS,
		"seed 1 recDrift %.4f want 0.539" % g1.recoil_drift
	)
	_assert(g1.recoil_period == 5, "seed 1 recPeriod %d want 5" % g1.recoil_period)
	_close(g1.recoil_random, 0.4159491800620321, "seed 1 recRand")
	_close(g1.recoil_settle, 0.33603178985758986, "seed 1 recSettle")
	_assert(g1.barrel_length == 310, "seed 1 barrel %d want 310" % g1.barrel_length)
	# `tint` keys off `cfg`, which is pure integer arithmetic, so it is exact.
	_assert(absf(g1.tint - 0.9720909090712666) < 1.0e-15, "seed 1 tint %.16f" % g1.tint)
	_assert(
		Array(g1.zoom_levels) == [1.100000023841858] or absf(g1.zoom_levels[0] - 1.1) < 1.0e-6,
		"seed 1 zoomLevels %s want [1.1]" % str(Array(g1.zoom_levels))
	)
	_assert(g1.quirks.is_empty(), "seed 1 quirks %s want []" % str(Array(g1.quirks)))
	_assert(
		Array(g1.part_indices) == [3, 0, 38, 80], "seed 1 parts %s" % str(Array(g1.part_indices))
	)


func _check_hand_picked(pools: Dictionary) -> void:
	var t := GunTuning.reference_exact()
	var lib: Array[GunPart] = []
	lib.resize(95)
	for kind: StringName in pools.keys():
		for p: GunPart in pools[kind]:
			lib[p.index] = p
	_say("")
	_say("-- hand-picked selections (spec 10.3, reference_exact) --")

	var hazard := GunAssembler.fit_optics(
		GunAssembler.assemble(lib[3], lib[0], lib[70], lib[80], null, 1, t)
	)
	_say(
		(
			"serpent-stock hazard  tier %-8s score %.3f rel %d spread %s quirks %s"
			% [
				hazard.tier_name,
				hazard.score,
				hazard.reliability,
				hazard.spread_text,
				str(Array(hazard.quirks))
			]
		)
	)
	_assert(hazard.tier_name == &"Hazard", "hazard tier %s" % hazard.tier_name)
	_assert(hazard.reliability == 1, "hazard rel %d want 1" % hazard.reliability)
	_assert(absf(hazard.spread - 264.0) < GOLD_EPS, "hazard spread %.1f want 264" % hazard.spread)
	_assert(absf(hazard.score - 44.937) < 5.0e-4, "hazard score %.4f want 44.937" % hazard.score)

	var boom := GunAssembler.fit_optics(
		GunAssembler.assemble(lib[90], lib[86], lib[87], lib[88], lib[89], 1, t)
	)
	_say(
		(
			"explosive launcher    bore %.1f cap %d dmg %.0f blastR %.1f range %d zoom %s"
			% [
				boom.bore,
				boom.magazine,
				boom.damage,
				boom.blast_radius,
				boom.effective_range,
				str(Array(boom.zoom_levels))
			]
		)
	)
	_assert(boom.explosive, "launcher not explosive")
	_assert(absf(boom.bore - 27.9) < GOLD_EPS, "launcher bore %.2f want 27.9" % boom.bore)
	_assert(boom.magazine == 2, "launcher cap %d want 2" % boom.magazine)
	_assert(absf(boom.damage - 90.0) < GOLD_EPS, "launcher dmg %.1f want 90" % boom.damage)
	_assert(
		absf(boom.blast_radius - 4.1) < GOLD_EPS,
		"launcher blastR %.2f want 4.1" % boom.blast_radius
	)
	_assert(boom.fire_mode == &"Break-action", "launcher mode %s" % boom.fire_mode)
	_assert(boom.effective_range == 113, "launcher range %d want 113" % boom.effective_range)

	var shot := GunAssembler.fit_optics(
		GunAssembler.assemble(lib[53], lib[50], lib[51], lib[52], null, 1, t)
	)
	_say(
		(
			"shot payload          cal %-16s pellets %d dmg %.0f spread %s range %d"
			% [shot.caliber, shot.pellets, shot.damage, shot.spread_text, shot.effective_range]
		)
	)
	_assert(shot.pellets == 7, "shot pellets %d want 7" % shot.pellets)
	_assert(shot.caliber == "16.1×38 shot", "shot cal %s" % shot.caliber)
	_assert(absf(shot.damage - 207.0) < GOLD_EPS, "shot dmg %.1f want 207" % shot.damage)
	_assert(absf(shot.spread - 1070.0) < GOLD_EPS, "shot spread %.1f want 1070" % shot.spread)

	var pumper := GunAssembler.fit_optics(
		GunAssembler.assemble(lib[19], lib[15], lib[16], lib[17], lib[18], 1, t)
	)
	_say(
		(
			"matched pumper        cal %-10s arch %-14s tier %-14s zoom %s scoped %s"
			% [
				pumper.caliber,
				pumper.archetype,
				pumper.tier_name,
				str(Array(pumper.zoom_levels)),
				pumper.scoped
			]
		)
	)
	_assert(pumper.caliber == "7.92×57", "pumper cal %s want 7.92×57" % pumper.caliber)
	_assert(pumper.archetype == &"Battle rifle", "pumper arch %s" % pumper.archetype)
	_assert(pumper.tier_name == &"Warlord-Grade", "pumper tier %s" % pumper.tier_name)
	_assert(pumper.scoped, "pumper should be scoped")
	_assert(
		absf(pumper.reload_time - 14.0) < GOLD_EPS,
		"pumper reload %.1f want 14" % pumper.reload_time
	)

	var boxgun := GunAssembler.fit_optics(
		GunAssembler.assemble(lib[94], lib[91], lib[92], lib[93], null, 1, t)
	)
	_say(
		(
			"matched boxgun        cal %-18s arch %-9s cyclic %d oal %d rel %d sidearm %s"
			% [
				boxgun.caliber,
				boxgun.archetype,
				boxgun.cyclic,
				boxgun.overall_length,
				boxgun.reliability,
				boxgun.sidearm
			]
		)
	)
	_assert(boxgun.cyclic == 1850, "boxgun cyclic %d want 1850" % boxgun.cyclic)
	_assert(boxgun.overall_length == 243, "boxgun oal %d want 243" % boxgun.overall_length)
	_assert(boxgun.reliability == 98, "boxgun rel %d want 98" % boxgun.reliability)
	_assert(boxgun.sidearm, "boxgun should be a sidearm")
	_assert(boxgun.tier_name == &"Field-Grade", "boxgun tier %s" % boxgun.tier_name)


## Roll `SAMPLES` weapons through one tuning and report everything measurable.
## Returns the headline metrics so the two tunings can be diffed side by side.
func _census(pools: Dictionary, tuning: GunTuning, label: String) -> Dictionary:
	var arch_count: Dictionary = {}
	var tier_count: Dictionary = {}
	var mode_count: Dictionary = {}
	var feed_count: Dictionary = {}
	var quirk_count: Dictionary = {}
	var lo: Dictionary = {}
	var hi: Dictionary = {}
	var sum: Dictionary = {}
	var flags := {
		"explosive": 0, "shot": 0, "sidearm": 0, "auto": 0, "runaway": 0, "optic": 0, "scoped": 0
	}
	var mode_char: Dictionary = {}
	var arch_char: Dictionary = {}
	var bad := PackedStringArray()

	for i: int in SAMPLES:
		var seed_value: int = (i * 2654435761 + 1013904223) & 0xFFFFFFFF
		var w := GunAssembler.build(seed_value, pools, tuning)
		if w == null:
			bad.append("seed %d produced no spec at all" % seed_value)
			continue
		# GRADE IT. Every mechanism calls `ensure` as it configures, so the gun a player
		# holds is graded: tier pushed down into Hazard, sear condemned. This census read
		# the raw record, describing a weapon that never reaches a hand. The golden
		# vectors run before this, ungraded, so they are unaffected.
		GunGrading.ensure(w)
		_tally(arch_count, String(w.archetype))
		_tally(tier_count, String(w.tier_name))
		_tally(mode_count, String(w.fire_mode))
		_tally(feed_count, String(w.feed))
		_char_tally(mode_char, String(w.fire_mode), w)
		_char_tally(arch_char, String(w.archetype), w)
		for q: String in w.quirks:
			_tally(quirk_count, q)
		if w.explosive:
			flags["explosive"] += 1
		if w.pellets > 1:
			flags["shot"] += 1
		if w.sidearm:
			flags["sidearm"] += 1
		if w.automatic:
			flags["auto"] += 1
		if w.runaway:
			flags["runaway"] += 1
		if w.has_optic:
			flags["optic"] += 1
		if w.scoped:
			flags["scoped"] += 1
		GunOdds.count(flags, w)
		for field: String in STAT_FIELDS:
			var v := float(w.get(field))
			if not is_finite(v):
				bad.append("seed %d: %s is %s" % [seed_value, field, v])
				continue
			lo[field] = minf(lo.get(field, INF), v)
			hi[field] = maxf(hi.get(field, -INF), v)
			sum[field] = float(sum.get(field, 0.0)) + v
		if w.zoom_levels.is_empty():
			bad.append("seed %d: empty zoom ladder" % seed_value)
		if w.magazine < 1 or w.rpm < 8 or w.reload_time <= 0.0:
			bad.append(
				(
					"seed %d: cap %d rpm %d reload %.2f"
					% [seed_value, w.magazine, w.rpm, w.reload_time]
				)
			)
		if w.part_indices.size() < 4 or w.part_scales.size() != w.part_indices.size():
			bad.append("seed %d: malformed assembly" % seed_value)

	_say("")
	_say("== %d raw builds, %s tuning ==" % [SAMPLES, label])
	_say("")
	_say("archetype census")
	_dump_counts(arch_count)
	_say("")
	_say("tier census")
	_dump_counts(tier_count)
	_say("")
	_say("fire mode census")
	_dump_counts(mode_count)
	_say("")
	_say("feed census")
	_dump_counts(feed_count)
	_char_dump(mode_char, "by fire mode")
	_char_dump(arch_char, "by archetype")
	_say("")
	_say("quirk census")
	_dump_counts(quirk_count)
	_say("")
	_say("flags")
	for k: String in flags.keys():
		_say("  %-12s %5d  %5.1f%%" % [k, flags[k], 100.0 * float(flags[k]) / float(SAMPLES)])
	_say("")
	_say("stat ranges          %12s %12s %12s" % ["min", "mean", "max"])
	for field: String in STAT_FIELDS:
		_say(
			(
				"  %-18s %12.4f %12.4f %12.4f"
				% [field, lo[field], float(sum[field]) / float(SAMPLES), hi[field]]
			)
		)
	_say("")
	if bad.is_empty():
		_say("non-finite / absurd values: none")
	else:
		for line: String in bad:
			_say("  ABSURD %s" % line)
		_failures += bad.size()

	var out: Dictionary = {}
	for field: String in STAT_FIELDS:
		out["min " + field] = lo[field]
		out["mean " + field] = float(sum[field]) / float(SAMPLES)
		out["max " + field] = hi[field]
	for k: String in ["Hazard", "Scrap", "Relic"]:
		out["tier " + k] = float(tier_count.get(k, 0))
	for k: String in ["crew-served", "blunderbuss", "jam-prone", "drum-fed", "runaway"]:
		out["quirk " + k] = float(quirk_count.get(k, 0))
	out["arch Shotgun"] = float(arch_count.get("Shotgun", 0))
	out["arch Slug gun"] = float(arch_count.get("Slug gun", 0))
	return out


## The before/after table docs/balance.md quotes. Only the rows the shipped
## departures are supposed to move, so a surprise elsewhere is visible.
func _compare(before: Dictionary, after: Dictionary) -> void:
	_say("")
	_say("== reference_exact -> shipped, %d samples ==" % SAMPLES)
	_say("  %-24s %12s %12s %10s" % ["metric", "reference", "shipped", "delta"])
	for row: String in COMPARE_ROWS:
		var b: float = float(before.get(row, 0.0))
		var a: float = float(after.get(row, 0.0))
		_say("  %-24s %12.3f %12.3f %+10.3f" % [row, b, a, a - b])


## One departure at a time, each measured against the reference baseline, so a
## number in docs/balance.md can be attributed to the knob that produced it.
## Only the rows a knob actually moves are printed.
func _ablate(pools: Dictionary, before: Dictionary) -> void:
	var knobs: Array = [
		["shot cone 15.0 -> 4.0", "shot_spread_multiplier", 4.0],
		["shot choke cap 0.72 -> 0.62", "shot_spread_barrel_cap", 0.62],
		["shot range cap none -> 55 m", "shot_range_cap", 55.0],
		["zero fit height 0 -> 0.39", "zero_fit_height_ratio", 0.39],
		["mass ceiling 26 -> 12 kg", "mass_ceiling", 12.0],
		["auto rate ceiling -> 1100", "auto_rpm_ceiling", 1100],
		["range floor 4 -> 25 m", "min_effective_range", 25.0],
		["box cap none -> 60", "capacity_box", 60],
		["tube cap none -> 10", "capacity_tube", 10],
		["internal cap none -> 12", "capacity_internal", 12],
		["MG cap none -> 150", "capacity_machine_gun", 150],
		["auto shotgun cap -> 32", "capacity_auto_shotgun", 32],
		["reload from final cap", "reload_uses_final_capacity", true],
	]
	_say("")
	_say("== one departure at a time, vs reference_exact, %d samples ==" % SAMPLES)
	for knob: Array in knobs:
		var t := GunTuning.reference_exact()
		t.set(knob[1], knob[2])
		var after := _census_quiet(pools, t)
		var moved := PackedStringArray()
		for row: String in COMPARE_ROWS:
			var b: float = float(before.get(row, 0.0))
			var a: float = float(after.get(row, 0.0))
			if absf(a - b) > 1.0e-9:
				moved.append("      %-24s %12.3f -> %12.3f  %+.3f" % [row, b, a, a - b])
		_say("")
		_say("  %s" % knob[0])
		if moved.is_empty():
			_say("      no measured effect on any tracked metric")
		for line: String in moved:
			_say(line)


## `_census` without the printed tables — the ablation only wants the metrics.
func _census_quiet(pools: Dictionary, tuning: GunTuning) -> Dictionary:
	var mark := _lines.size()
	var out := _census(pools, tuning, "ablation")
	_lines.resize(mark)
	return out


func _typed_census(pools: Dictionary, tuning: GunTuning) -> void:
	var hits := 0
	var sidearm_hits := 0
	var worst_attempts := 0
	var total_attempts := 0
	for i: int in TYPED_SAMPLES:
		var rand := XorShift32.new((i * 747796405 + 2891336453) & 0xFFFFFFFF)
		var want := GunTables.wanted_class(rand.next())
		var res := _roll_typed(rand, pools, tuning, false, want)
		total_attempts += int(res["attempts"])
		worst_attempts = maxi(worst_attempts, int(res["attempts"]))
		var spec: GunSpec = res["spec"]
		if String(spec.archetype) == want:
			hits += 1
		var srand := XorShift32.new((i * 2246822519 + 374761393) & 0xFFFFFFFF)
		var sres := _roll_typed(srand, pools, tuning, true, "Sidearm")
		var sspec: GunSpec = sres["spec"]
		if sspec.sidearm:
			sidearm_hits += 1
	_say("")
	_say("-- %d class-targeted rolls --" % TYPED_SAMPLES)
	_say(
		(
			"  wanted class hit     %d / %d  (%.1f%%)"
			% [hits, TYPED_SAMPLES, 100.0 * float(hits) / float(TYPED_SAMPLES)]
		)
	)
	_say("  mean attempts        %.1f" % (float(total_attempts) / float(TYPED_SAMPLES)))
	_say("  worst attempts       %d" % worst_attempts)
	_say("  holster filter kept  %d / %d" % [sidearm_hits, TYPED_SAMPLES])

	# Every archetype in the mix has to be reachable on demand, or a request for
	# one silently hands the player something else.
	_say("")
	_say(
		(
			"  archetype reachability: raw incidence over %d builds, then %d targeted budgets"
			% [DEEP_SAMPLES, TARGET_BUDGETS]
		)
	)
	var incidence: Dictionary = {}
	for i: int in DEEP_SAMPLES:
		var seed_value: int = (i * 3266489917 + 374761393) & 0xFFFFFFFF
		_tally(incidence, String(GunAssembler.build(seed_value, pools, tuning).archetype))
	for arch: String in GunTables.TUNE.keys():
		var raw: int = int(incidence.get(arch, 0))
		var attempts := 0
		var hit := false
		var spec: GunSpec = null
		for b: int in TARGET_BUDGETS:
			var rand := XorShift32.new(
				(0x5EED0000 + arch.length() * 7919 + b * 104729) & 0xFFFFFFFF
			)
			var res := _roll_typed(rand, pools, tuning, false, arch)
			attempts += int(res["attempts"])
			spec = res["spec"]
			if String(spec.archetype) == arch:
				hit = true
				break
		_say(
			(
				"    %-18s raw %5d (%6.3f%%)  %-11s in %4d attempts  mag %3d  %s"
				% [
					arch,
					raw,
					100.0 * float(raw) / float(DEEP_SAMPLES),
					"targeted ok" if hit else "UNREACHABLE",
					attempts,
					spec.magazine,
					spec.caliber,
				]
			)
		)
		# A class the geometry never produces cannot be rolled for; that is a
		# documented limitation, not a bug. A class it DOES produce but the retry
		# loop cannot find is a broken roll.
		if raw > 0:
			_assert(hit, "archetype '%s' occurs raw but no targeted roll found it" % arch)
	_assert(
		sidearm_hits == TYPED_SAMPLES,
		"holster filter leaked %d non-sidearms" % (TYPED_SAMPLES - sidearm_hits)
	)


## Exercise the `GunFactory` autoload end to end: roll, assemble the node from
## the baked meshes, and check the muzzle marker lands past the breech.
##
## The autoload is reached through the tree rather than by name — naming it would
## drag `PartLibrary` into this script's compile, and a `--script` run resolves no
## autoload identifiers at compile time even though the nodes exist at runtime.
func _check_factory() -> void:
	var factory: Node = root.get_node_or_null("/root/GunFactory")
	if factory == null:
		_assert(false, "GunFactory autoload is not registered")
		return
	_say("")
	_say("-- GunFactory autoload --")
	_assert(bool(factory.call("is_ready")), "GunFactory reports the part library is not ready")

	var built := 0
	var meshes := 0
	for seed_value: int in [1, 4242, 991733, 0xDEADBEEF]:
		var spec: GunSpec = factory.call("roll", seed_value)
		if spec == null:
			_assert(false, "GunFactory.roll(%d) returned null" % seed_value)
			continue
		var node: Node3D = factory.call("build_node", spec)
		var mesh_kids := 0
		for child: Node in node.get_children():
			if child is MeshInstance3D:
				var mi := child as MeshInstance3D
				mesh_kids += 1
				_assert(mi.mesh != null, "seed %d: %s has no mesh" % [seed_value, mi.name])
				_assert(
					mi.material_override != null,
					"seed %d: %s has no material" % [seed_value, mi.name]
				)
		_assert(
			mesh_kids == spec.part_count(),
			"seed %d: %d mesh instances for %d parts" % [seed_value, mesh_kids, spec.part_count()]
		)
		_assert(
			node.get_node_or_null("Muzzle") != null and node.get_node_or_null("Eject") != null,
			"seed %d: missing Muzzle or Eject marker" % seed_value
		)
		var box: AABB = factory.call("assembly_aabb", spec)
		_assert(box.size.x > 0.0, "seed %d: degenerate assembly AABB" % seed_value)
		_assert(
			spec.muzzle_local.x > box.position.x, "seed %d: muzzle behind the assembly" % seed_value
		)
		_say(
			(
				"  %-10s %-22s %-18s %-14s oal %4d mm  aabb %s"
				% [
					seed_value,
					spec.weapon_name,
					spec.archetype,
					spec.tier_name,
					spec.overall_length,
					str(box.size.snappedf(0.001))
				]
			)
		)
		built += 1
		meshes += mesh_kids
		node.free()
	_say("  built %d weapons, %d mesh instances" % [built, meshes])

	var holstered: GunSpec = factory.call("roll_holstered", 20260728)
	_assert(holstered != null and holstered.sidearm, "roll_holstered returned a non-sidearm")
	var rand := RandomNumberGenerator.new()
	rand.seed = 7
	# One draw in 22 lands back on the same barrel, so sample until it moves.
	var swapped: GunSpec = null
	var changed := false
	for _i: int in 20:
		swapped = factory.call("reroll_slot", holstered, &"barrel", rand)
		_assert(swapped != null, "reroll_slot returned null")
		if swapped == null:
			return
		_assert(swapped.zoom_levels.is_empty(), "reroll_slot should skip fit_optics")
		_assert(
			not swapped.zoom_ladder().is_empty(),
			"zoom_ladder fallback is empty after a bench reroll"
		)
		_assert(
			swapped.receiver_index() == holstered.receiver_index(),
			"reroll_slot changed the receiver as well as the barrel"
		)
		if swapped.barrel_index() != holstered.barrel_index():
			changed = true
			break
	_assert(changed, "reroll_slot never changed the barrel in 20 draws")
	_say(
		(
			"  holstered %s (%.2f kg, %d mm), rerolled barrel %d -> %d, name %s"
			% [
				holstered.weapon_name,
				holstered.mass,
				holstered.overall_length,
				holstered.barrel_index(),
				swapped.barrel_index(),
				swapped.weapon_name
			]
		)
	)


## The factory's retry loop, reproduced here so the verifier does not need the
## autoload. Returns `{spec, attempts}`.
func _roll_typed(
	rand: XorShift32, pools: Dictionary, tuning: GunTuning, need_sidearm: bool, want: String
) -> Dictionary:
	var fallback: GunSpec = null
	for i: int in 420:
		var seed_value: int = int(rand.next() * 4294967295.0) & 0xFFFFFFFF
		var spec := GunAssembler.build(seed_value, pools, tuning)
		if need_sidearm and not spec.sidearm:
			continue
		if fallback == null:
			fallback = spec
		if String(spec.archetype) == want:
			return {"spec": spec, "attempts": i + 1}
	if fallback == null:
		fallback = GunAssembler.build(int(rand.next() * 4294967295.0) & 0xFFFFFFFF, pools, tuning)
	return {"spec": fallback, "attempts": 420}


func _tally(d: Dictionary, key: String) -> void:
	d[key] = int(d.get(key, 0)) + 1


## Accumulate one bucket of the rate-and-recoil character table. Two guns of
## different classes are meant to land on visibly different ROWS here.
func _char_tally(d: Dictionary, key: String, w: GunSpec) -> void:
	var row: Dictionary = d.get(key, {"n": 0, "lo": INF, "hi": -INF, "rpm": 0.0, "mean": 0.0})
	d[key] = row
	row["n"] = int(row["n"]) + 1
	row["lo"] = minf(float(row["lo"]), float(w.rpm))
	row["hi"] = maxf(float(row["hi"]), float(w.rpm))
	row["rpm"] = float(row["rpm"]) + float(w.rpm)
	row["mean"] = float(row["rpm"]) / float(row["n"])
	for c: String in CHAR_COLS.split(" "):
		row[c] = float(row.get(c, 0.0)) + float(w.get(c.get_slice(":", 0)))


## Print one character table, fastest mean rate first.
func _char_dump(d: Dictionary, title: String) -> void:
	var keys: Array = d.keys()
	keys.sort_custom(func(a: String, b: String) -> bool: return d[a]["mean"] > d[b]["mean"])
	var head: String = "  %-19s %5s %6s %7s %6s" % [title, "n", "rpmLo", "rpmMean", "rpmHi"]
	for c: String in CHAR_COLS.split(" "):
		head += " %10s" % c.get_slice(":", 0).trim_prefix("recoil_")
	_say("")
	_say(head)
	for k: String in keys:
		var r: Dictionary = d[k]
		var n: float = float(r["n"])
		var line: String = (
			"  %-19s %5d %6.0f %7.0f %6.0f"
			% [k, int(n), float(r["lo"]), float(r["mean"]), float(r["hi"])]
		)
		for c: String in CHAR_COLS.split(" "):
			line += ("%%10.%sf" % c.get_slice(":", 1)) % (float(r[c]) / n)
		_say(line)


func _dump_counts(d: Dictionary) -> void:
	var keys: Array = d.keys()
	keys.sort_custom(func(a: String, b: String) -> bool: return d[a] > d[b])
	for k: String in keys:
		_say("  %-20s %5d  %5.1f%%" % [k, d[k], 100.0 * float(d[k]) / float(SAMPLES)])


## Compare a raw derived float against its golden value, in relative terms.
func _close(got: float, want: float, label: String) -> void:
	var rel: float = absf(got - want) / maxf(absf(want), 1.0e-12)
	var shown: String = String.num(got, 17)
	_assert(
		rel < GOLD_REL,
		(
			"%s: got %s want %s (rel %s)"
			% [label, shown, String.num(want, 17), String.num_scientific(rel)]
		)
	)
	if rel < GOLD_REL:
		_say("  ok   %-18s %-22s rel %s" % [label, shown, String.num_scientific(rel)])


func _assert(ok: bool, message: String) -> void:
	if not ok:
		_failures += 1
		_say("  FAIL %s" % message)


func _say(line: String) -> void:
	_lines.append(line)
