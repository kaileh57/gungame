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
## Largest share of stoppages that are the strip-it-down kind.
const HARD_SHARE: float = 0.72
## Largest share of stoppages that are a tap and a rack.
const LIGHT_SHARE: float = 0.80

## How hard tier hits per-shot bloom.
const BLOOM_EXP: float = 0.85
## How hard tier hits the ceiling accumulated bloom can reach.
const CEILING_EXP: float = 0.70
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
## Handling below which a reload is something the shooter can drop.
const HAND_FUMBLE: float = 38.0
## Magazine size below which a wear ramp has nowhere to build.
const HOT_CAPACITY: int = 18
## `action_load` below which the reference's own runaway sear fires.
const RUNAWAY_LOAD: float = 0.20
## Rate stress at which a worn sear runs away on its own.
const RUNAWAY_STRESS: float = 0.55
## Ceiling on how many tags a stat card carries. The reference's own quirks are
## never dropped; the character tags fill whatever room is left.
const MAX_QUIRKS: int = 7

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
	return 0 if condition(spec) < HAZARD_CONDITION else base


## Emergent traits, read off the finished record. The first eleven are the
## reference's own, in its push order; the rest are this port's character tags,
## each gated on the same threshold the matching profile uses.
static func quirks(spec: GunSpec) -> PackedStringArray:
	var out: PackedStringArray = _reference_quirks(spec)
	for tag: String in _character_quirks(spec):
		if out.size() >= MAX_QUIRKS:
			break
		out.append(tag)
	return out


## True when the action cannot stop itself. The reference's own case is a light
## impulse against a heavy carrier (`action_load` under 0.20); this port adds the
## worn sear — a rough weapon geared far past what it can carry does not care
## that you let go of the trigger.
static func runs_away(spec: GunSpec) -> bool:
	if not spec.automatic:
		return false
	if spec.action_load > 0.0 and spec.action_load < RUNAWAY_LOAD:
		return true
	return rate_stress(spec) > RUNAWAY_STRESS and quality(spec) < Q_GRITTY


## Write the grading onto a finished record: tier, character, runaway sear.
## Called once at the end of `GunAssembler.assemble()`, when every number it
## reads is already on the spec.
static func grade(spec: GunSpec) -> void:
	spec.tier_index = tier_of(spec)
	spec.tier_name = StringName(Palette.GUN_TIER_NAMES[spec.tier_index])
	spec.tier_color = Palette.TIER_COLORS[spec.tier_index]
	spec.quirks = quirks(spec)
	spec.runaway = runs_away(spec)


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
static func jam_profile(spec: GunSpec) -> Dictionary:
	var q: float = quality(spec)
	var tilt: float = PIVOT / maxf(q, 0.05)
	var rough: float = 1.0 - q
	return {
		&"chance_scale": pow(tilt, JAM_QUALITY_EXP) * (1.0 + JAM_STRESS_WEIGHT * rate_stress(spec)),
		&"clear_scale": pow(tilt, CLEAR_EXP),
		&"wear": WEAR_MAX * pow(rough, WEAR_QUALITY_EXP),
		&"tail": TAIL_MAX * pow(1.0 - feed_quality(spec), WEAR_QUALITY_EXP),
		&"hard": HARD_SHARE * pow(rough, SEVERITY_EXP),
		&"light": LIGHT_SHARE * pow(q, SEVERITY_EXP),
	}


## What `GunSpread` needs.
##   bloom_scale    on the per-shot bloom
##   ceiling_scale  on how far accumulated bloom may go
##   settle         exponent on the per-second retention: above 1 the weapon
##                  settles faster than the resource's base, below 1 slower
##   sight          0..1, how much of the resource's ADS tightening is earned
##   relief         on how much of the bloom shouldering absorbs
static func spread_profile(spec: GunSpec) -> Dictionary:
	var q: float = quality(spec)
	var tilt: float = PIVOT / maxf(q, 0.05)
	return {
		&"bloom_scale": pow(tilt, BLOOM_EXP),
		&"ceiling_scale": pow(tilt, CEILING_EXP),
		&"settle": q / PIVOT,
		&"sight": pow(q, SIGHT_EXP),
		&"relief": pow(q / PIVOT, RELIEF_EXP),
	}


## What `GunReload` needs.
##   time_scale   on the rolled reload time
##   cycle_scale  on a hand-worked action's cycle, so a rough bolt is slow
##   fumble       chance a reload goes wrong and has to be started over
static func reload_profile(spec: GunSpec) -> Dictionary:
	var q: float = quality(spec)
	var tilt: float = PIVOT / maxf(q, 0.05)
	return {
		&"time_scale": pow(tilt, RELOAD_EXP),
		&"cycle_scale": pow(tilt, CYCLE_EXP),
		&"fumble": FUMBLE_MAX * pow(1.0 - q, FUMBLE_EXP),
	}


## What `GunAmmo` needs.
##   short    largest share of the magazine a reload may fail to seat
##   misfeed  per-shot chance the stack strips two rounds instead of one
static func feed_profile(spec: GunSpec) -> Dictionary:
	var rough: float = 1.0 - feed_quality(spec)
	return {
		&"short": SHORT_MAX * pow(rough, SHORT_EXP),
		&"misfeed": MISFEED_MAX * pow(rough, MISFEED_EXP),
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


## This port's character tags. Every one is gated OUTSIDE the middle of the
## quality band, so an unremarkable Field-Grade weapon carries none of them and
## the tags stay a statement about the object rather than noise on every card.
static func _character_quirks(spec: GunSpec) -> PackedStringArray:
	var q: float = quality(spec)
	var tags := PackedStringArray()
	if rate_stress(spec) > STRESS_MARK:
		tags.append("over-revved")
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
	if q < Q_ROUGH:
		tags.append("bent sights")
	if q >= Q_SLICK:
		tags.append("slick")
		if spec.fit_error <= FIT_MATCH:
			tags.append("crisp")
	return tags
