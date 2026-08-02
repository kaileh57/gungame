extends RefCounted
## The rolls worth telling somebody about, counted off a census pass.
##
## BAKE-TIME ONLY. `tools/verify_guns.gd` is the only caller; it preloads this file by
## path rather than naming a global class, because a `--script` main loop cannot see a
## `class_name` until the editor has rewritten its class cache.
##
## WHY THESE ARE NOT FLAGS. The flag census answers "how many weapons are scoped" and
## "how many are automatic" separately, and multiplying those two together does NOT
## give the rate of weapons that are both — the assembler's fit rules actively push
## optics and rate apart, so the joint rate is far below the independent estimate and
## the only way to know it is to count it. Every entry here is a COMBINATION, and each
## one is a thing a player would stop and look at rather than a statistic.

## Rate at or above which a scoped weapon stops being a marksman rifle and starts being
## a joke. `docs/GUN_DESIGN.md` §4 asks for this roll to exist and to still be bad at
## range, which the spread model is what enforces.
const HOSE_RPM: float = 500.0
## Damage at or above which a weapon you can holster is doing a long gun's job.
const POCKET_CANNON_DAMAGE: float = 200.0
## Magazine at or above which an automatic has stopped needing to be reloaded.
const BELT_MAGAZINE: int = 60


## Add this weapon to every bucket it belongs in. `flags` is the census dictionary
## `verify_guns` prints; keys are created on demand so a bucket nothing landed in is
## absent from the report rather than reported as a zero.
static func count(flags: Dictionary, w: GunSpec) -> void:
	# The classes DEFINED by carrying a scope, kept apart from the whole-population
	# scope rate — which cannot answer "do snipers have scopes" at all, because
	# snipers are under one percent of what the factory rolls.
	if w.archetype == &"Sniper" or w.archetype == &"Marksman carbine":
		_bump(flags, "marksman")
		_bump(flags, "marksman_scoped" if w.scoped else "marksman_irons")
	if w.scoped and w.rpm >= HOSE_RPM:
		_bump(flags, "odd:scoped bullet hose")
	if w.pellets > 1 and w.automatic:
		_bump(flags, "odd:automatic shot")
	if w.explosive and w.automatic:
		_bump(flags, "odd:automatic explosive")
	if w.sidearm and w.damage >= POCKET_CANNON_DAMAGE:
		_bump(flags, "odd:pocket cannon")
	if w.automatic and w.magazine >= BELT_MAGAZINE:
		_bump(flags, "odd:belt-fed hose")
	if w.runaway:
		_bump(flags, "odd:runaway")
	if String(w.tier_name) == "Relic":
		_bump(flags, "odd:relic")
	# WHAT A HAZARD ACTUALLY IS. The tier means "this may hurt the person holding it",
	# so most of them should be a weapon that cannot stop firing or one that throws a
	# charge — not merely a bad gun, which is what Scrap is for. Broken out because the
	# composition of the tier is the design target, not how many land in it.
	if String(w.tier_name) == "Hazard":
		_bump(flags, "hazard")
		if w.runaway:
			_bump(flags, "hazard:runaway")
		if w.explosive:
			_bump(flags, "hazard:explosive")
		if not w.runaway and not w.explosive:
			_bump(flags, "hazard:tame")


static func _bump(d: Dictionary, key: String) -> void:
	d[key] = int(d.get(key, 0)) + 1
