class_name GunGrading
extends RefCounted
## What a scavenged weapon is worth in the hand.
##
## `GunAssembler` derives the physics. This decides what the physics is WORTH:
## the tier, the character tags, and the per-mechanism profiles that make a
## Scrap gun unpleasant to shoot and a Gunsmithed one feel earned. Nothing here
## is a per-tier lookup — every number is one continuous quantity raised to a
## power, so a weapon sitting between two tiers behaves between them.
##
## Three quantities, in dependency order:
##
##   `craft(spec)`        workmanship: reliability against joint fit, geometric
##                        mean of the two. Pure derivation, no tier involved.
##   `rate_stress(spec)`  how far the rated rate outruns what that workmanship
##                        can carry. This is the whole answer to "a gun that can
##                        mag dump instantly is not scrap grade": a scrappy
##                        weapon may still roll a high cyclic, and then it binds,
##                        blooms and runs away instead of being straightforwardly
##                        good. High rate is a thing a WELL-MADE gun does.
##   `quality(spec)`      what the player is actually holding: craft tilted by
##                        the tier it graded into, so the ladder Hazard→Relic
##                        runs about 0.32 → 0.96 and never crosses itself.
##
## Every profile below is `PIVOT / quality` raised to some power. `PIVOT` is the
## Field-Grade quality, so Field-Grade is 1.0 by construction and the whole tier
## ladder falls out of one number in each direction. Read the exponent as "how
## hard does tier hit this": 1.6 on jam chance is brutal, 0.55 on reload is felt
## but not punishing.
##
## THE QUIRKS AND THE BEHAVIOUR SHARE THEIR PREDICATES. A tag on the stat card is
## never decoration — `quirks()` names the same thresholds the profiles key off,
## so "worn mag" is on the card exactly when `feed_profile` is handing `GunAmmo`
## a short fill and a double-feed chance.
##
## On top of the ladder sits the character layer, `GunQuirks`. The ladder alone
## makes every Scrap gun the same Scrap gun; the traits drawn there give one of
## them a bolt you lean on and the next one a magazine that eats a round every
## twenty shots. Their effects come back through `trait_mods()` and are folded
## into every profile below, so those names are behaviour too, not vocabulary.

## Salts that give each mechanism its own deterministic stream off `GunSpec.cfg`.
## Sharing `cfg` un-salted would correlate a fumbled reload with the recoil spice
## of the same weapon, which reads as the gun having one bad frame rather than
## two independent faults.
const RELOAD_SALT: int = 0x2B7E1516
const FEED_SALT: int = 0x28AED2A6

## Joint mismatch that costs a weapon 1/e of its workmanship. `fit_error` runs
## 0 (every cut face matched) to about 5.7 on the shipped tuning.
const FIT_TAU: float = 2.2
## Highest tier index, for normalising the rank.
const TIER_TOP: float = 6.0
## Share of the quality ladder a Hazard still keeps. Below this the mechanisms
## stop being unpleasant and start being unusable.
const RANK_FLOOR: float = 0.30
## The quality every profile is measured against: a Field-Grade weapon. Each
## scale is exactly 1.0 here, which is what makes the exponents readable.
const PIVOT: float = 0.68

## Rounds per minute the worst action in the game can still carry.
const RATE_FLOOR: float = 80.0
## Rounds per minute perfect workmanship adds on top of the floor.
const RATE_SPAN: float = 1150.0
## How sharply carrying capacity falls off with workmanship. At 2.2, halving
## craft cuts what the action can carry to roughly a fifth.
const RATE_EXP: float = 2.2

## Condition below which a weapon that already failed the Cobbled score bar is
## Hazard rather than Scrap.
const HAZARD_CONDITION: float = 0.55
## A weapon at or above this reliability is never Hazard, whatever else is wrong
## with it. Hazard means it may hurt the person holding it.
const HAZARD_RELIABILITY: float = 40.0

## How hard tier hits the per-round jam chance, on top of raw reliability.
const JAM_QUALITY_EXP: float = 1.6
## Extra jam chance per unit of rate stress. An action running 50 % past what it
## can carry jams two and a half times as often.
const JAM_STRESS_WEIGHT: float = 2.6
## Ceiling on the magazine-wear ramp: extra jam chance by the last round.
const WEAR_MAX: float = 3.0
## How fast the wear ramp disappears as quality rises.
const WEAR_QUALITY_EXP: float = 1.5
## Ceiling on the extra chance over the last rounds, where a magazine binds.
const TAIL_MAX: float = 1.8
## How hard tier hits how long a stoppage takes to clear.
const CLEAR_EXP: float = 0.9
## Shape of the severity mix. Above 1 the good end of the quality scale gets
## disproportionately easy stoppages.
const SEVERITY_EXP: float = 1.4
## Largest share of stoppages that are the strip-it-down kind. At 0.72 every
## Hazard magazine contained a teardown; at 0.50 a Hazard is a third teardowns, a
## Scrap gun a fifth, and a Field-Grade weapon under a tenth.
const HARD_SHARE: float = 0.50
## Largest share of stoppages that are a tap and a rack.
const LIGHT_SHARE: float = 0.80

## How hard tier hits per-shot bloom.
const BLOOM_EXP: float = 0.85
## Extra per-shot bloom per unit of rate stress. This is the second half of the
## answer to the mag-dumping Scrap gun: it does not merely bind more often, it
## also throws its group open faster than the shooter can walk it back. An action
## running half again past its workmanship blooms 45 % harder per shot.
const BLOOM_STRESS_WEIGHT: float = 0.90
## How hard tier hits the ceiling accumulated bloom can reach.
const CEILING_EXP: float = 0.70
## Extra bloom ceiling per unit of rate stress, so the runaway string ends
## somewhere wider than the controlled one.
const CEILING_STRESS_WEIGHT: float = 0.50
## How hard tier hits how much the sights are worth.
const SIGHT_EXP: float = 0.85
## How hard tier hits how much of the bloom shouldering absorbs.
const RELIEF_EXP: float = 0.60

## How hard tier hits reload time.
const RELOAD_EXP: float = 0.55
## Largest share of reloads that go wrong on the worst weapon in the game.
const FUMBLE_MAX: float = 0.30
## How fast fumbling disappears as quality rises.
const FUMBLE_EXP: float = 1.8
## How hard tier hits a hand-worked action's cycle.
const CYCLE_EXP: float = 0.70

## Magazine size a feed is judged against. Past this, every extra round is one
## more chance for the stack to bind.
const FEED_REFERENCE_CAP: float = 12.0
## How fast a taller stack costs feed quality.
const FEED_CAP_EXP: float = 0.35
## Largest share of a magazine a worn feed can fail to seat.
const SHORT_MAX: float = 0.16
## How fast short-loading disappears as feed quality rises.
const SHORT_EXP: float = 2.0
## Largest per-shot chance a worn feed strips two rounds instead of one.
const MISFEED_MAX: float = 0.055
## How fast double-feeding disappears as feed quality rises.
const MISFEED_EXP: float = 2.6

## Largest residual bloom a weapon's decay can never clear, in multiples of the
## base cone. A rough gun does not come back to its bench group between shots.
const FLOOR_MAX: float = 0.34
## How fast the residual bloom disappears as quality rises.
const FLOOR_EXP: float = 2.4

## How hard feed quality hits the per-shell time of a tube top-up. Negative in
## effect: a clean feed gate takes shells faster than a bent one.
const SHELL_EXP: float = 0.65

## Quality below which the sights stop being worth shouldering.
const Q_ROUGH: float = 0.46
## Quality below which a weapon reads as rough in the hand.
const Q_GRITTY: float = 0.56
## Quality above which a weapon reads as quick and clean.
const Q_SLICK: float = 0.78
## Rate stress at which the weapon is visibly outrunning its own action.
const STRESS_MARK: float = 0.22
## Joint mismatch below which an assembly counts as matched.
const FIT_MATCH: float = 0.30
## Feed quality below which the magazine itself is the problem.
const FEED_WORN: float = 0.40
## Feed quality above which the gate takes shells as fast as you can push them.
const FEED_QUICK: float = 0.74
## Handling below which a reload is something the shooter can drop.
const HAND_FUMBLE: float = 38.0
## Magazine size below which a wear ramp has nowhere to build.
const HOT_CAPACITY: int = 18
## Rate stress at which a worn sear runs away on its own.
const RUNAWAY_STRESS: float = 0.55
## Residual bloom above which the weapon never returns to its own bench group.
const WANDER_MARK: float = 0.10
## Share of stoppages that must be the strip-it-down kind to be worth a tag.
## Tracks `HARD_SHARE`: at a third of stoppages the teardown is the thing the
## player will remember about the weapon.
const HARD_MARK: float = 0.24
## Reload time multiplier above which the reload itself is the weapon's problem.
const SLOW_LOAD_MARK: float = 1.22
## Per-shot double-feed chance worth warning the player about.
const MISFEED_MARK: float = 0.012
## Ceiling on how many tags a stat card carries. The reference's own quirks are
## never dropped; the character tags fill whatever room is left.
const MAX_QUIRKS: int = 8

## Metadata key marking a spec whose grading has already been written. `GunSpec`
## is `GunAssembler`'s schema, so the guard rides in Object metadata rather than
## costing a field this system does not own.
const GRADED_META: StringName = &"gun_graded"
## Metadata key holding this weapon's drawn traits, separately from the stat
## card's `quirks`. The card is truncated for width; the mechanisms must see the
## whole draw, and re-rolling it on every profile call would cost four draws per
## configure for no gain.
const TRAITS_META: StringName = &"gun_traits"

## The reference prototype's eleven emergent traits, in its own push order. Kept
## separate so a census can tell what this port added from what it inherited.
const REFERENCE_QUIRKS: PackedStringArray = [
	"runaway",
	"blunderbuss",
	"explosive",
	"flat-shooting",
	"overbore",
	"hand cannon",
	"jam-prone",
	"drum-fed",
	"reach-out",
	"crew-served",
	"sidearm",
]

## Actions that have to be worked by hand between shots.
const MANUAL_ACTIONS: PackedStringArray = ["bolt", "pump", "break", "single"]


## Workmanship, 0..1. Reliability and joint fit, geometric mean — a weapon needs
## BOTH to be well made, and either one at the floor drags the other down.
static func craft(spec: GunSpec) -> float:
	var rel: float = clampf(float(spec.reliability) / 100.0, 0.01, 1.0)
	var fit: float = exp(-maxf(spec.fit_error, 0.0) / FIT_TAU)
	return clampf(sqrt(rel * fit), 0.02, 1.0)


## Rounds per minute this weapon's workmanship can carry without eating itself.
static func rate_carried(spec: GunSpec) -> float:
	return RATE_FLOOR + RATE_SPAN * pow(craft(spec), RATE_EXP)


## How far the rated rate outruns the build, as a fraction. Zero for anything
## running inside its means; 0.5 for an action turning half again as fast as its
## workmanship supports. A hand-worked gun can never reach it, which is right —
## a bolt gun cannot outrun anything.
static func rate_stress(spec: GunSpec) -> float:
	return maxf(float(spec.rpm) / maxf(rate_carried(spec), 1.0) - 1.0, 0.0)


## Workmanship discounted by how hard the action is being pushed, 0..1. This is
## the grading axis: a competent weapon geared far past itself grades down.
static func condition(spec: GunSpec) -> float:
	return craft(spec) * pow(1.0 / (1.0 + rate_stress(spec)), 1.0 / 3.0)


## What the player is holding, 0..1 — craft tilted by the tier it graded into,
## so the two never disagree about which of two weapons is the better object.
## Every mechanism profile below keys off this and nothing else.
static func quality(spec: GunSpec) -> float:
	var rank: float = clampf(float(spec.tier_index) / TIER_TOP, 0.0, 1.0)
	return clampf(sqrt(craft(spec) * (RANK_FLOOR + (1.0 - RANK_FLOOR) * rank)), 0.02, 1.0)


## How well the magazine feeds, 0..1. A tall stack on a rough gun is where rounds
## actually bind: quality falls off with the square-root-ish of capacity past a
## reference twelve, so a scavenged 60-round drum is a liability and a six-shot
## cylinder is not.
static func feed_quality(spec: GunSpec) -> float:
	var cap: float = maxf(float(spec.magazine), FEED_REFERENCE_CAP)
	return clampf(quality(spec) * pow(FEED_REFERENCE_CAP / cap, FEED_CAP_EXP), 0.02, 1.0)


## Final tier. The score ladder and the reliability clamps are still
## `GunTables.tier_index_for`; this only pushes the bottom of Scrap down into
## Hazard, and only for a weapon that already failed the Cobbled score bar.
##
## The clamp `GunTables` applies fires at reliability 14, which was calibrated
## against a reference where one stock's mating face was recorded as zero and
## every gun carrying it landed on `fit_error = 13.59`. With that data defect
## fixed the clamp catches 15 weapons in 2,000 and the junk tail collapses. Bad
## guns are content; this is where they come from now.
static func tier_of(spec: GunSpec) -> int:
	var base: int = GunTables.tier_index_for(spec.score, float(spec.reliability))
	if base == 0 or spec.score >= GunTables.TIER_MIN[2]:
		return base
	if float(spec.reliability) >= HAZARD_RELIABILITY:
		return base
	if condition(spec) >= HAZARD_CONDITION:
		return base
	return 0 if is_dangerous(spec) else base


## Whether this weapon can hurt the person holding it, as opposed to merely shooting
## badly. The gate on the Hazard push-down.
##
## HAZARD IS NOT "VERY BAD" — Scrap already covers that, and there are 663 of those.
## The push-down used to take any weapon that failed the Cobbled bar with poor
## reliability and poor condition, which made the tier 95-of-126 guns that were simply
## awful, and left the name saying something the weapon did not do. It now needs a
## mechanism that can turn on you: a charge that goes off where the gun is rather than
## where you aimed, or an action that keeps cycling after you let go — every Hazard
## automatic runs away, see `runs_away`.
##
## Reads only fields the assembler has already published, so it is safe to call from
## `tier_of` before any grading exists.
static func is_dangerous(spec: GunSpec) -> bool:
	return spec.explosive or spec.automatic


## This weapon's drawn traits — the named faults and virtues from `GunQuirks`.
##
## Cached in metadata by `grade()`. The fallback draw exists so a caller that
## reaches a profile on an ungraded record still gets the same answer rather than
## a neutral one; it is the same deterministic draw, taken again.
static func traits(spec: GunSpec) -> PackedStringArray:
	if spec == null:
		return PackedStringArray()
	var cached: Variant = spec.get_meta(TRAITS_META, null)
	if cached is PackedStringArray:
		return cached
	return GunQuirks.roll(spec, quality(spec), rate_stress(spec))


## The accumulated effect of this weapon's traits, at a mechanism's own dial.
## Every profile below multiplies or adds this in, which is what makes a trait a
## behaviour rather than a word.
static func trait_mods(spec: GunSpec, strength: float) -> Dictionary:
	return GunQuirks.mods(traits(spec), strength)


## Emergent traits, read off the finished record.
##
## Three groups, in display order. The first eleven are the reference's own, in
## its push order. Then this weapon's DRAWN traits, which are the ones with an
## independent effect. Then this port's derived character tags, each gated on the
## same threshold the matching profile uses.
##
## The first two groups are never truncated, because every one of them is a
## statement about a number a mechanism is currently using and a card that hid
## one would be lying. `MAX_QUIRKS` only limits how many derived tags get to
## describe the result.
static func quirks(spec: GunSpec) -> PackedStringArray:
	var out: PackedStringArray = _reference_quirks(spec)
	out.append_array(traits(spec))
	for tag: String in _character_quirks(spec):
		if out.size() >= MAX_QUIRKS:
			break
		out.append(tag)
	return out


## `quirks()` packed into card-width lines, longest-fitting-first, in order.
##
## THIS EXISTS BECAUSE THE TAGS OUTGREW THE CARD. Before grading was wired into
## `GunFactory` a stat card showed only the reference's eleven emergent quirks and
## the mean weapon carried well under one, so both card builders joined the whole
## list onto a single line. With the character layer live the mean is 4.4 of a
## possible `MAX_QUIRKS`, which is 60-100 characters — and `ReadoutCanvas` draws a
## line through `draw_string` with a width limit, which CLIPS rather than wraps. A
## single joined line therefore loses tags silently, which is the one thing
## `quirks()` promises never to happen: every name on that card is a number a
## mechanism is currently using.
##
## `budget` is in characters and is compared against the mono font the diegetic
## readouts use, so it is a true width. A tag longer than the whole budget still
## gets its own line rather than being dropped — losing it would be the bug this
## function exists to prevent.
static func quirk_lines(spec: GunSpec, budget: int = 34) -> PackedStringArray:
	var out := PackedStringArray()
	var line: String = ""
	for tag: String in quirks(spec):
		if line.is_empty():
			line = tag
		elif line.length() + 2 + tag.length() <= budget:
			line += ", " + tag
		else:
			out.append(line)
			line = tag
	if not line.is_empty():
		out.append(line)
	return out


## True when the action cannot stop itself.
##
## The reference's own case is a light impulse against a heavy carrier, which
## `GunAssembler` tests as `cyc < 0.20` and has already published as
## `spec.runaway` — the cycle load it tests on is a derivation local and never
## reaches this resource, so the flag IS the reading. This port adds the second
## case: a worn sear. A rough weapon geared far past what its workmanship can
## carry does not care that you let go of the trigger.
##
## Monotone in `spec.runaway`, so re-grading an already-graded record is a no-op
## rather than a flag that flickers.
static func runs_away(spec: GunSpec) -> bool:
	if not spec.automatic:
		return false
	if spec.runaway:
		return true
	# A HAZARD AUTOMATIC ALWAYS RUNS AWAY. Hazard is the one tier defined by what the
	# weapon does to the person holding it rather than by how well it shoots, and a
	# sear that cannot be trusted is the plainest version of that. Without this the
	# tier was mostly just bad guns — 9 of 15 were neither runaway nor explosive,
	# which is Scrap's job. Reads `tier_index`, which `grade()` sets before it asks.
	if spec.tier_index == 0:
		return true
	return rate_stress(spec) > RUNAWAY_STRESS and quality(spec) < Q_GRITTY


## Write the grading onto a finished record: tier, traits, character, runaway sear.
##
## Belongs at the end of `GunAssembler.assemble()`, where every number it reads
## is already on the spec. Until that call site exists this is reached through
## `ensure()`, which every mechanism resource calls as it configures — so a gun
## in a hand is always fully graded even though a census row may not be.
##
## The tier goes down FIRST: `quality()` reads it, and the trait draw and every
## profile past this line are keyed off quality.
static func grade(spec: GunSpec) -> void:
	spec.tier_index = tier_of(spec)
	spec.tier_name = StringName(Palette.GUN_TIER_NAMES[spec.tier_index])
	spec.tier_color = Palette.TIER_COLORS[spec.tier_index]
	spec.runaway = runs_away(spec)
	spec.set_meta(TRAITS_META, GunQuirks.roll(spec, quality(spec), rate_stress(spec)))
	spec.quirks = quirks(spec)
	spec.set_meta(GRADED_META, true)


## Grade `spec` unless it already carries the grading. Idempotent and cheap on
## the second call, which is what lets all four mechanism resources ask for it
## without any of them having to be the one that owns the ordering.
static func ensure(spec: GunSpec) -> void:
	if spec == null or spec.has_meta(GRADED_META):
		return
	grade(spec)


## A deterministic per-weapon stream. Two weapons built from the same five parts
## fumble the same reloads; the same weapon rolled twice does too.
static func stream(spec: GunSpec, salt: int) -> XorShift32:
	return XorShift32.new((spec.cfg ^ salt) & 0xFFFFFFFF)


## What `GunJam` needs. All six are multipliers or probabilities, so the
## resource's own exports stay the global shape and this is the per-weapon tilt.
##   chance_scale  on the reliability-derived per-round chance
##   clear_scale   on the seconds an ordinary stoppage costs
##   wear          extra chance by the time the magazine is empty
##   tail          extra chance over the last rounds
##   hard / light  severity mix; the remainder is an ordinary stoppage
##
## `strength` is `GunJam.quirk_strength`: how much of the character layer this
## particular resource wants. Zero leaves the smooth tier ladder alone.
static func jam_profile(spec: GunSpec, strength: float = 1.0) -> Dictionary:
	var q: float = quality(spec)
	var tilt: float = PIVOT / maxf(q, 0.05)
	var rough: float = 1.0 - q
	var m: Dictionary = trait_mods(spec, strength)
	var stressed: float = 1.0 + JAM_STRESS_WEIGHT * rate_stress(spec)
	var wear: float = WEAR_MAX * pow(rough, WEAR_QUALITY_EXP) + float(m[&"wear"])
	var tail: float = TAIL_MAX * pow(1.0 - feed_quality(spec), WEAR_QUALITY_EXP)
	var hard: float = HARD_SHARE * pow(rough, SEVERITY_EXP) * float(m[&"hard"])
	return {
		&"chance_scale": pow(tilt, JAM_QUALITY_EXP) * stressed * float(m[&"jam"]),
		&"clear_scale": pow(tilt, CLEAR_EXP) * float(m[&"clear"]),
		&"wear": maxf(wear, 0.0),
		&"tail": maxf(tail + float(m[&"tail"]), 0.0),
		&"hard": clampf(hard, 0.0, 1.0),
		&"light": LIGHT_SHARE * pow(q, SEVERITY_EXP),
	}


## What `GunSpread` needs.
##   bloom_scale    on the per-shot bloom
##   ceiling_scale  on how far accumulated bloom may go
##   settle         exponent on the per-second retention: above 1 the weapon
##                  settles faster than the resource's base, below 1 slower
##   sight          0..1, how much of the resource's ADS tightening is earned
##   relief         on how much of the bloom shouldering absorbs
##   floor          residual bloom the decay can never clear. This is the one that
##                  makes a rough weapon feel rough between shots rather than only
##                  during a burst: it never comes back to its own bench group.
static func spread_profile(spec: GunSpec, strength: float = 1.0) -> Dictionary:
	var q: float = quality(spec)
	var tilt: float = PIVOT / maxf(q, 0.05)
	var m: Dictionary = trait_mods(spec, strength)
	var stress: float = rate_stress(spec)
	var bloom: float = pow(tilt, BLOOM_EXP) * (1.0 + BLOOM_STRESS_WEIGHT * stress)
	var ceiling: float = pow(tilt, CEILING_EXP) * (1.0 + CEILING_STRESS_WEIGHT * stress)
	var floor_rad: float = FLOOR_MAX * pow(1.0 - q, FLOOR_EXP) + float(m[&"floor"])
	return {
		&"bloom_scale": bloom * float(m[&"bloom"]),
		&"ceiling_scale": ceiling * float(m[&"ceiling"]),
		&"settle": (q / PIVOT) * float(m[&"settle"]),
		&"sight": pow(q, SIGHT_EXP) * float(m[&"sight"]),
		&"relief": pow(q / PIVOT, RELIEF_EXP) * float(m[&"relief"]),
		&"floor": maxf(floor_rad, 0.0),
	}


## What `GunReload` needs.
##   time_scale   on the rolled reload time
##   cycle_scale  on a hand-worked action's cycle, so a rough bolt is slow
##   fumble       chance a reload goes wrong and has to be started over
static func reload_profile(spec: GunSpec, strength: float = 1.0) -> Dictionary:
	var q: float = quality(spec)
	var tilt: float = PIVOT / maxf(q, 0.05)
	var m: Dictionary = trait_mods(spec, strength)
	var fumble: float = FUMBLE_MAX * pow(1.0 - q, FUMBLE_EXP) + float(m[&"fumble"])
	return {
		&"time_scale": pow(tilt, RELOAD_EXP) * float(m[&"reload"]),
		&"cycle_scale": pow(tilt, CYCLE_EXP) * float(m[&"cycle"]),
		&"fumble": maxf(fumble, 0.0),
	}


## What `GunAmmo` needs, plus the one number `GunReload` takes from the feed
## rather than from the action.
##   short        largest share of the magazine a reload may fail to seat
##   misfeed      per-shot chance the stack strips two rounds instead of one
##   shell_scale  on a tube's per-shell time — a bent loading gate takes them one
##                reluctant push at a time, a clean one swallows them
static func feed_profile(spec: GunSpec, strength: float = 1.0) -> Dictionary:
	var fq: float = feed_quality(spec)
	var rough: float = 1.0 - fq
	var m: Dictionary = trait_mods(spec, strength)
	var short_fill: float = SHORT_MAX * pow(rough, SHORT_EXP) + float(m[&"short"])
	var misfeed: float = MISFEED_MAX * pow(rough, MISFEED_EXP) + float(m[&"misfeed"])
	return {
		&"short": maxf(short_fill, 0.0),
		&"misfeed": maxf(misfeed, 0.0),
		&"shell_scale": pow(PIVOT / maxf(fq, 0.05), SHELL_EXP) * float(m[&"shell"]),
	}


## The reference's eleven, read off the finished record rather than off the
## derivation's locals. The two agree except where a published field was rounded
## across the threshold — which is the honest reading, since the rounded number
## is the one the stat card shows.
static func _reference_quirks(spec: GunSpec) -> PackedStringArray:
	var q := PackedStringArray()
	if runs_away(spec):
		q.append("runaway")
	if spec.spread > 150.0:
		q.append("blunderbuss")
	if spec.explosive:
		q.append("explosive")
	if not spec.explosive and spec.headshot_range >= 110.0:
		q.append("flat-shooting")
	if spec.muzzle_velocity > 1150:
		q.append("overbore")
	if spec.damage > 190.0:
		q.append("hand cannon")
	if spec.reliability < 32:
		q.append("jam-prone")
	if spec.magazine >= 60:
		q.append("drum-fed")
	if spec.effective_range > 700:
		q.append("reach-out")
	if spec.mass > 8.5:
		q.append("crew-served")
	if spec.sidearm:
		q.append("sidearm")
	return q


## This port's character tags.
##
## EVERY TAG HERE IS READ OFF A PROFILE THIS FILE ALSO HANDS TO A MECHANISM, at
## the same threshold that mechanism keys off — not off a parallel set of
## conditions that happen to look similar. "worn mag" is on the card exactly when
## `feed_profile` is handing `GunAmmo` a short fill and a double-feed chance;
## "wandering zero" exactly when `spread_profile` is handing `GunSpread` a bloom
## floor it cannot decay through. There is no such thing here as a tag that only
## prints.
##
## Each is also gated OUTSIDE the middle of the quality band, so an unremarkable
## Field-Grade weapon carries none of them and a tag stays a statement about the
## object rather than noise on every card.
static func _character_quirks(spec: GunSpec) -> PackedStringArray:
	var q: float = quality(spec)
	var tags := PackedStringArray()
	if rate_stress(spec) > STRESS_MARK and not traits(spec).has("overrun action"):
		tags.append("over-revved")
	tags.append_array(_rough_quirks(spec, q))
	tags.append_array(_fine_quirks(spec, q))
	return tags


## The unpleasant half. Split out only to keep either branch readable.
static func _rough_quirks(spec: GunSpec, q: float) -> PackedStringArray:
	var tags := PackedStringArray()
	var feed: Dictionary = feed_profile(spec)
	var spread: Dictionary = spread_profile(spec)
	if q < Q_GRITTY:
		tags.append("gritty")
		if feed_quality(spec) < FEED_WORN and spec.magazine > 4:
			tags.append("worn mag")
		if spec.magazine >= HOT_CAPACITY:
			tags.append("binds hot")
		if float(spec.handling) < HAND_FUMBLE:
			tags.append("fumbly")
		if MANUAL_ACTIONS.has(String(GunTables.action_for(spec.fire_mode))):
			tags.append("sluggish action")
	if float(spread[&"floor"]) > WANDER_MARK:
		tags.append("wandering zero")
	if float(feed[&"misfeed"]) > MISFEED_MARK:
		tags.append("double-feeding")
	if float(jam_profile(spec)[&"hard"]) > HARD_MARK:
		tags.append("hard-jamming")
	if float(reload_profile(spec)[&"time_scale"]) > SLOW_LOAD_MARK:
		tags.append("slow to load")
	if q < Q_ROUGH:
		tags.append("bent sights")
	return tags


## The earned half. A Gunsmithed weapon and up should be able to say WHY it is
## better in the same vocabulary the bad ones use.
static func _fine_quirks(spec: GunSpec, q: float) -> PackedStringArray:
	var tags := PackedStringArray()
	if q >= Q_SLICK:
		tags.append("slick")
		if spec.fit_error <= FIT_MATCH:
			tags.append("crisp")
	if feed_quality(spec) >= FEED_QUICK:
		tags.append("quick-feeding")
	return tags
