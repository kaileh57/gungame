class_name GunTuning
extends Resource
## Every balance knob that changes what `GunAssembler.assemble()` derives.
##
## The reference prototype's derivation is ported verbatim; this resource is the
## only place it is allowed to deviate, and every field says what the reference
## did. `GunTuning.reference_exact()` returns the settings that reproduce the golden
## vectors in docs/spec/range.md §10 exactly — the part bake's verifier uses it,
## and so should anyone re-checking the port.
##
## A default-constructed `GunTuning` is the SHIPPED balance. See docs/balance.md
## for the measurements that justify each departure.

@export_group("Shot payload")
## Multiplier applied to the raw cone when the chamber throws a shot payload.
## Reference: 15.0, which produces 17-degree patterns and a four-metre effective
## range — a weapon you cannot hit anything with at any distance.
@export_range(1.0, 20.0, 0.1) var shot_spread_multiplier: float = 4.0
## How much of the shot cone a long barrel chokes away, as a fraction.
## Reference: 0.72.
@export_range(0.0, 0.95, 0.01) var shot_spread_barrel_cap: float = 0.62
## Metres. Shot payloads take their effective range from chemistry alone, capped
## here, instead of from `3400 / spread`. Zero restores the reference coupling,
## where a wide pattern also destroys the damage range.
@export_range(0.0, 400.0, 1.0) var shot_range_cap: float = 55.0

@export_group("Fitting")
## Fallback mating-face height, as a fraction of the part's own body height, for
## a part whose recorded `fit_height` is zero. Only part 70 (the Serpent stock)
## is affected: the reference divides by a 1e-6 epsilon there and lands on
## `err = 13.59`, which drags any gun carrying it to reliability 1 and a
## 264-MOA cone. 0.39 is the median `fh / ext.y` across the other 21 stocks.
## Zero restores the reference's divide-by-epsilon.
@export_range(0.0, 1.0, 0.01) var zero_fit_height_ratio: float = 0.39

@export_group("Bulk")
## Kilograms. Ceiling on assembled mass. Reference: 26.0, which is a weapon no
## character shoulders: handling is `132 - 0.062*oal - 5*mass`, so anything past
## 26 kg pins handling at its floor of 1 and the gun stops being a gun.
## Lowering this also raises kick and muzzle rise on the heaviest builds, because
## both are impulse over mass — that is the honest trade and it is intended.
@export_range(3.0, 26.0, 0.1) var mass_ceiling: float = 12.0

@export_group("Rate")
## Rounds per minute. Ceiling on a weapon whose rate comes from the bolt rather
## than the trigger — full-auto, machine pistol and 3-round burst. Reference:
## none beyond the 1850 rpm cyclic clamp, which empties a 20-round magazine in
## three quarters of a second. Zero restores the reference.
@export_range(0, 1900, 10) var auto_rpm_ceiling: int = 1100

@export_group("Range")
## Metres. Floor on effective range. Reference: 4.0, which is closer than the
## end of the firing pad.
@export_range(4.0, 400.0, 1.0) var min_effective_range: float = 25.0

@export_group("Capacity")
## Rounds. Ceiling on a box magazine, applied after the archetype multiplier.
## Zero means no ceiling, which is the reference. The reference's own clamp is
## 200, and the archetype multiplier can push a machine gun past even that.
@export_range(0, 300, 1) var capacity_box: int = 60
## Rounds. Ceiling on a tube magazine. Reference: none. A 36-shell tube is what
## produces the reference's 14-second (clamped) reloads.
@export_range(0, 300, 1) var capacity_tube: int = 10
## Rounds. Ceiling on an internal magazine fed by stripper clips. Reference: none.
@export_range(0, 300, 1) var capacity_internal: int = 12
## Rounds. Ceiling for the Machine gun archetype, which overrides the feed
## ceiling because belts and drums are the whole point of it. Reference: none.
@export_range(0, 300, 1) var capacity_machine_gun: int = 150
## Rounds. Ceiling for the Auto shotgun archetype. Reference: none.
@export_range(0, 300, 1) var capacity_auto_shotgun: int = 32
## Compute reload time from the FINAL magazine size rather than the pre-archetype
## one. The reference computes it first and clamps capacity afterwards, so a gun
## whose archetype cut it from 36 rounds to 10 still reloads as if it held 36.
@export var reload_uses_final_capacity: bool = true


## The settings that reproduce the reference prototype bit for bit. Used by the
## bake verifier against the golden vectors; not what the game ships with.
static func reference_exact() -> GunTuning:
	var t := GunTuning.new()
	t.shot_spread_multiplier = 15.0
	t.shot_spread_barrel_cap = 0.72
	t.shot_range_cap = 0.0
	t.zero_fit_height_ratio = 0.0
	t.mass_ceiling = 26.0
	t.auto_rpm_ceiling = 0
	t.min_effective_range = 4.0
	t.capacity_box = 0
	t.capacity_tube = 0
	t.capacity_internal = 0
	t.capacity_machine_gun = 0
	t.capacity_auto_shotgun = 0
	t.reload_uses_final_capacity = false
	return t


## Ceiling on magazine size for a given feed and archetype, or 0 for no ceiling.
## The machine-gun and auto-shotgun overrides beat the feed ceiling, which is why
## a belt-fed gun is allowed its belt.
func capacity_limit(feed: StringName, archetype: String) -> int:
	var limit: int = 0
	match feed:
		&"box":
			limit = capacity_box
		&"tube":
			limit = capacity_tube
		&"internal":
			limit = capacity_internal
	if archetype == "Machine gun":
		limit = maxi(limit, capacity_machine_gun)
	elif archetype == "Auto shotgun" and capacity_auto_shotgun > 0:
		limit = capacity_auto_shotgun
	return limit
