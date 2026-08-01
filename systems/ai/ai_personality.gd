class_name AIPersonality
extends RefCounted
## The dozen numbers that make two bodies of the same species behave differently.
##
## Everything here is drawn once, deterministically, from one integer. Give the
## same agent the same seed and it is the same fighter across a reload, which is
## what makes a bad peek debuggable; give two agents of one species different
## seeds and they react at different speeds, hold different amounts of ground and
## lose their nerve at different times. Without this a firing line of twelve
## scavengers is one scavenger drawn twelve times, and that is most of what reads
## as "the AI is basic" before any tactic is even considered.
##
## The species profile supplies the MEAN of every trait and
## `AISpeciesProfile.personality_variance` supplies the spread. An apex predator
## and a rat are not two draws from the same distribution: the rat's nerve is
## centred low and varies widely, the apex's is centred high and barely moves.
##
## `phase` deserves its own note. It is a per-agent angle in [0, TAU) and it is
## the single cheapest fix for the worst tell in a crowd — twelve bodies peeking,
## scanning and re-checking on the same frame because they all tick off the same
## clock. Anything periodic should be offset by it.
##
## Instances are cached by key, so perception, combat, the squad solver and the
## debug overlay all read the SAME personality for one body without plumbing it
## through four constructors. `clear()` on scene teardown.

## Traits are drawn in this order and the order is load-bearing: change it and
## every agent in every demo re-rolls. Appending is safe, inserting is not.
const TRAIT_COUNT: int = 11
## Cached personalities live until this many are held, after which the cache is
## dropped wholesale rather than evicted one at a time. A scene never approaches
## it; a long session that cycles demos without calling `clear` will.
const CACHE_LIMIT: int = 512

static var _cache: Dictionary = {}

## The integer this personality was drawn from. Stable for the life of the body.
var key: int = 0
## 0 timid, 1 rabid. Pushes, closes, leaves cover early, takes the first shot.
var aggression: float = 0.5
## 0 reckless, 1 wary. Prefers cover, hangs back, peeks less and shorter.
var caution: float = 0.5
## 0 brittle, 1 unshakeable. Resists morale pressure; see `AIMorale`.
var nerve: float = 0.5
## 0 freelance, 1 professional. Holds fire without a target, keeps its place in
## the squad, obeys a bounding token instead of running the street.
var discipline: float = 0.5
## Multiplier on reaction time. Below 1 is quick on the draw, above 1 is slow.
var reaction_scale: float = 1.0
## Multiplier on awareness gained per second. Sharp eyes versus dull ones.
var acuity: float = 1.0
## Multiplier on the aim cone. Below 1 shoots tighter than the species average.
var marksmanship: float = 1.0
## Multiplier on every dwell: how long it stares, searches, and holds a post.
var patience: float = 1.0
## 0 checks the doorway, 1 clears the whole room. Widens the search spiral.
var curiosity: float = 0.5
## 0 silent, 1 calls out everything. Gates callouts so a squad is not a choir.
var chatter: float = 0.5
## Radians in [0, TAU). Offsets anything periodic so no two agents share a frame.
var phase: float = 0.0
## 0.8 to 1.25. Multiplier on idle scan and fidget rates.
var tempo: float = 1.0


func _init(seed_value: int = 1, profile: AISpeciesProfile = null) -> void:
	key = seed_value
	roll(seed_value, profile)


## The personality for `id`, drawn on first ask and remembered after. Every system
## that wants one should come through here rather than constructing its own, so
## that perception and combat agree about who this body is.
static func of(id: int, profile: AISpeciesProfile) -> AIPersonality:
	var found: AIPersonality = _cache.get(id, null)
	if found != null:
		return found
	if _cache.size() >= CACHE_LIMIT:
		_cache.clear()
	var made := AIPersonality.new(id, profile)
	_cache[id] = made
	return made


## Drop the whole cache. Scene teardown, and nowhere else. Safe at any time: the
## draw is a pure function of the key and the profile, so anything that asks again
## gets the same fighter back.
static func clear() -> void:
	_cache.clear()


## Re-draw every trait from `seed_value`. Public because a pooled body that is
## revived as a different species has to become a different fighter.
func roll(seed_value: int, profile: AISpeciesProfile) -> void:
	key = seed_value
	var rng := XorShift32.new((seed_value * 2654435761) & 0x7FFFFFFF)
	var spread: float = 0.35 if profile == null else profile.personality_variance
	var tier: float = 1.0 if profile == null else float(profile.tier)
	var bold: float = 0.5 if profile == null else profile.base_aggression
	var steady: float = 0.5 if profile == null else profile.base_nerve
	var drilled: float = 0.5 if profile == null else profile.base_discipline
	if profile != null:
		# A thing that closes to detonate has no cautious variant. Rolling one and
		# then ignoring it downstream is how a trait quietly stops meaning anything.
		if profile.suicide_charge:
			bold = 1.0
		bold += 0.09 * (profile.bias_advancer - profile.bias_suppressor)
		steady += 0.06 * (tier - 2.0)
	aggression = _draw(rng, bold, spread, 0.05, 1.0)
	caution = _draw(rng, 1.05 - bold, spread, 0.0, 1.0)
	nerve = _draw(rng, steady, spread * 0.85, 0.02, 1.0)
	discipline = _draw(rng, drilled, spread * 0.8, 0.05, 1.0)
	reaction_scale = _draw(rng, 1.0, spread * 0.9, 0.55, 1.85)
	acuity = _draw(rng, 1.0, spread * 0.55, 0.7, 1.35)
	marksmanship = _draw(rng, 1.0, spread * 0.7, 0.7, 1.4)
	patience = _draw(rng, 1.0, spread * 0.8, 0.55, 1.6)
	curiosity = _draw(rng, 0.5, spread, 0.05, 1.0)
	chatter = _draw(rng, 0.5, spread, 0.0, 1.0)
	phase = rng.next() * TAU
	# Derived, not drawn: a quick body fidgets quickly. One fewer draw and it means
	# the scan rate never contradicts the reaction time.
	tempo = clampf(1.0 / maxf(reaction_scale, 0.4), 0.8, 1.25)


## Seconds this body waits before acting on something it has just noticed, given
## the species' own figure. Alerted bodies react faster because they are already
## looking; that scale is the species' `reaction_time_alerted` fraction.
func reaction_time(profile: AISpeciesProfile, alerted: bool) -> float:
	if profile == null:
		return 0.28 * reaction_scale
	var base: float = profile.reaction_time
	if alerted:
		base *= profile.reaction_time_alerted
	return maxf(base * reaction_scale, 0.0)


## How far from a lead this body is willing to wander, as a multiplier on the
## search spiral. A curious, bold agent clears the room; a cautious one checks the
## doorway it can see and comes back.
func search_reach() -> float:
	return clampf(0.65 + 0.5 * curiosity + 0.25 * aggression - 0.2 * caution, 0.5, 1.5)


## Whether this body is the one that says something, given how many of its squad
## already have. Keeps a callout to one voice without any coordination.
func speaks(roll_value: float) -> bool:
	return roll_value < chatter * chatter


## A short word for the overlay. Ten characters at most, upper case, no padding.
func label() -> String:
	var word: String = "EVEN"
	if reaction_scale > 1.35:
		word = "SLOW"
	elif nerve > 0.74 and discipline > 0.6:
		word = "STEADY"
	elif nerve < 0.3:
		word = "JUMPY"
	elif caution > 0.68:
		word = "CAGEY"
	elif aggression > 0.68:
		word = "BOLD"
	if reaction_scale < 0.82 and aggression > 0.58:
		word = "TRIGGERY"
	return word


## One line for the F3 panel and for harness output.
func summary() -> String:
	return (
		"%s agg %.2f cau %.2f nrv %.2f rct %.2fx acu %.2fx"
		% [label(), aggression, caution, nerve, reaction_scale, acuity]
	)


## One uniform draw about `mean`, clamped. Kept private and kept in one place so
## every trait costs exactly one draw and the stream stays reproducible.
func _draw(rng: XorShift32, mean: float, spread: float, lo: float, hi: float) -> float:
	return clampf(mean + (rng.next() - 0.5) * 2.0 * spread, lo, hi)
