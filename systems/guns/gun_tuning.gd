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
@export_range(0, 1900, 10) var auto_rpm_ceiling: int = 1200
## Rounds per minute. HARD floor on the MECHANICAL cycle rate, and now a backstop
## rather than a shaper — `cyclic_pivot_rpm` does the shaping. Reference: 320, which
## is also the reference's semi-auto ceiling, so the slowest full-auto in the game
## and the fastest semi were the same weapon in the hand.
##
## Set this ABOVE the pivot map's own low end and it collapses the heavy autos onto
## one number again: at 470 every one of the 26 Auto battle rifles in a 2 000-build
## sample came out at exactly 380 rpm. 360 leaves the geometry room to speak and
## still clears the 215 rpm semi ceiling by a wide margin once the archetype
## multiplier has taken its cut.
@export_range(60, 900, 10) var cyclic_floor_rpm: int = 360
## Exponent on the bolt stroke the cartridge forces, in units of the shortest
## stroke any action has (`GunAssembler.CYCLIC_STROKE_FLOOR`, 30 mm of case).
## Reference: 0.0 — the reference's cycle rate knew the carrier's MASS but not how
## far it had to travel, so a pistol-case action and a rifle-case action of the
## same mass cycled at the same rate. This is most of what separates an SMG from a
## battle rifle: at 0.75 a 100 mm case makes the same bolt turn 2.4× slower than a
## 30 mm one, and the contrast map below keeps about 0.46 of that in the final rate.
@export_range(0.0, 1.5, 0.01) var cyclic_stroke_power: float = 0.75
## Rounds per minute the contrast map leaves untouched, and the switch for the map.
## Zero restores the reference, where the physical terms were simply clamped into
## the band — and a clamp is what flattened the heavy end of the auto roster.
##
## Above the pivot the map pulls rates in, below it the map lifts them; because it
## is a power law and not a clamp, the ordering and the spacing survive at both
## ends. 1140 puts the median action near 700 rpm.
@export_range(0, 2000, 10) var cyclic_pivot_rpm: int = 1140
## Exponent of that power law: `cyclic = pivot * (raw / pivot) ^ contrast`. 1.0 is a
## no-op, below 1.0 squeezes the band towards the pivot, above 1.0 stretches it.
## 0.62 turns the physical band's 120-1900 rpm into roughly 390-1540 without a
## single weapon landing on a limit. Only read when `cyclic_pivot_rpm` is non-zero.
@export_range(0.05, 2.0, 0.01) var cyclic_contrast: float = 0.62
## Share of cycle rate lost per unit of `fit_error`. Reference: 0.0 — the
## reference's rate did not care how squarely the parts met, which is most of why
## a Scrap gun shot like a Gunsmithed one.
@export_range(0.0, 1.0, 0.01) var cyclic_fit_penalty: float = 0.15
## How much of the archetype's rate multiplier a BOLT-DRIVEN rate takes.
## Reference: 1.0, in full — and that is what flattened the autos, because the
## multiplier is smallest exactly where the geometry is already slowest (Auto
## battle rifle 0.62, Assault rifle 0.68) and largest where it is already fastest
## (Auto shotgun 1.05, Chopped auto 0.92). Every point of it is a point of the
## band spent on saying something the geometry has already said, so it is taken at
## 0.30: enough for an archetype to read as a family, not enough to squeeze the
## 390-1540 rpm mechanical band back into the middle.
@export_range(0.0, 1.0, 0.01) var archetype_rate_on_cyclic: float = 0.3
## Rounds per minute. Ceiling on a semi-auto, and the switch for the whole semi
## rate model. Zero restores the reference's `320 - impulse * 7`, whose ceiling is
## the cyclic floor. Non-zero prices a semi by RECOVERY instead: what paces aimed
## single shots is getting the muzzle back down, so the rate falls with the gun's
## own recoil velocity.
@export_range(0, 400, 5) var semi_rate_ceiling: int = 215
## Metres per second of free recoil velocity (`impulse / mass`) that halves a
## semi-auto's rate: `rpm = ceiling / (1 + recoil_velocity / scale)`. Small values
## make every big-bore semi a slow deliberate gun; large values flatten the semi
## band back towards its ceiling. Only read when `semi_rate_ceiling` is non-zero.
@export_range(0.2, 8.0, 0.05) var semi_recovery_scale: float = 3.2

@export_group("Handling")
## Blend from the reference's handling — length and mass subtracted separately —
## to the swing model, where they multiply. Reference: 0.0. The reference's sum
## scores a 1.9-metre launcher above a sniper rifle for being slightly lighter;
## what a shooter fights is mass out at the end of its own length.
@export_range(0.0, 1.0, 0.01) var handling_from_swing: float = 1.0

@export_group("Recoil")
## Blend from the reference's recoil — one magnitude, `impulse / mass`, with the
## other five fields either constant or rolled — to the character model, where
## rise, lateral share, drift bias, walk period, spice and settle rate each come
## off a different piece of the geometry. Reference: 0.0.
@export_range(0.0, 1.0, 0.01) var recoil_character: float = 1.0
## Radians of muzzle rise per metre-per-second of free recoil velocity, before the
## stock and muzzle-weight terms. The reference's own constant is 0.0032 and this
## keeps it, so `recoil_character` alone decides whether the SHAPE changes.
@export_range(0.0005, 0.012, 0.0001) var recoil_rise_scale: float = 0.0032

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
	t.cyclic_floor_rpm = 320
	t.cyclic_stroke_power = 0.0
	t.cyclic_pivot_rpm = 0
	t.cyclic_contrast = 1.0
	t.cyclic_fit_penalty = 0.0
	t.archetype_rate_on_cyclic = 1.0
	t.semi_rate_ceiling = 0
	t.handling_from_swing = 0.0
	t.recoil_character = 0.0
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
