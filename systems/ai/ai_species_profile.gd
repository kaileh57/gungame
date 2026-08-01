class_name AISpeciesProfile
extends Resource
## Everything the AI needs to know about one species, and nothing about how it
## looks or animates — that is ENEMIES' half of the contract.
##
## Sight, hearing and weapon reach come straight from the bestiary's own derived
## stats: `detect` is read as metres of sight, `reach` as metres of weapon reach,
## `speed`/`run` as the gait solver's derived locomotion speeds. Damage does not:
## the reference's `dps` is a beast-versus-beast threat budget assuming perfect
## uptime, and using it directly against a player makes every species lethal in
## under two seconds. Per-hit damage here is authored at roughly half the
## reference budget and the shortfall is deliberate — see `reference_dps`.

enum Weapon { MELEE, RIFLE, AUTO, CONE, DETONATOR }

@export_group("Identity")
@export var species_id: StringName = &""
@export var display_name: String = ""
## Which of the three this species fights for by default. A spawner may override.
@export_range(0, 2, 1) var faction: int = 0
## Bestiary threat score. Drives tier, courage and how much weight the squad gives
## this body when it assigns roles.
@export_range(0.0, 99.0, 0.001) var threat: float = 0.0
## Index into the six bestiary tiers, Vermin 0 through Apex 5.
@export_range(0, 5, 1) var tier: int = 1

@export_group("Body")
@export_range(0.1, 5.0, 0.0001) var height: float = 1.75
@export_range(0.1, 3.0, 0.01) var body_radius: float = 0.36
@export_range(1.0, 4000.0, 1.0) var health: float = 60.0
## 0-95, the bestiary's armour stat. Read as flat percentage damage reduction.
@export_range(0.0, 95.0, 1.0) var armour: float = 0.0
## Metres above the origin the perception ray starts from.
@export_range(0.1, 5.0, 0.001) var eye_height: float = 1.62

@export_group("Locomotion")
@export_range(0.1, 12.0, 0.001) var walk_speed: float = 1.2
@export_range(0.1, 16.0, 0.001) var run_speed: float = 3.4
## Radians per second the body can swing its facing. Big things turn slowly.
@export_range(0.3, 12.0, 0.05) var turn_rate: float = 4.5
## Legless species hover: the navigator holds them this far off the mesh.
@export_range(0.0, 4.0, 0.01) var hover_height: float = 0.0

@export_group("Perception")
## Metres. The bestiary's `detect` stat, read literally.
@export_range(4.0, 400.0, 0.5) var sight_range: float = 40.0
## Full cone angle, degrees. Machines get wide sensor arcs, mutants narrow ones.
@export_range(20.0, 360.0, 1.0) var fov_degrees: float = 130.0
## Inside this radius the cone stops mattering — you can feel something behind you.
@export_range(0.0, 20.0, 0.1) var peripheral_range: float = 4.0
## Awareness gained per second at point-blank range with a clean line of sight.
@export_range(0.2, 12.0, 0.01) var awareness_gain: float = 2.2
## Awareness bled off per second with nothing in sight.
@export_range(0.05, 4.0, 0.01) var awareness_decay: float = 0.42
## Multiplier on the radius of every noise event this species hears.
@export_range(0.1, 3.0, 0.01) var hearing_sensitivity: float = 1.0
## Seconds between seeing something and doing anything about it.
@export_range(0.0, 2.0, 0.01) var reaction_time: float = 0.28
## Fraction of `reaction_time` an already-alerted body pays. A squad that has
## been shot at once is hard to surprise twice.
@export_range(0.05, 1.0, 0.01) var reaction_time_alerted: float = 0.45
## Awareness multiplier applied for the duration of the reaction window. Zero
## makes the delay a hard blindfold and reads as a bug; this is the double take.
@export_range(0.0, 1.0, 0.01) var reaction_choke: float = 0.22
## Seconds a contact may be out of sight before it has to be noticed again from
## scratch. Blinking behind a barrel does not cost the reaction a second time.
@export_range(0.0, 6.0, 0.05) var reacquire_grace: float = 0.9
## Visibility multiplier for a crouched target, and for a prone one. A crouched
## silhouette at range should be genuinely hard to pick out of clutter.
@export_range(0.05, 1.0, 0.01) var crouch_detect_scale: float = 0.62
@export_range(0.05, 1.0, 0.01) var prone_detect_scale: float = 0.34
## Visibility multiplier for a target that is holding still. Movement is most of
## what makes a shape read as a body.
@export_range(0.05, 1.0, 0.01) var still_detect_scale: float = 0.7
## Visibility multiplier for a target the sun cannot reach.
@export_range(0.05, 1.0, 0.01) var shadow_detect_scale: float = 0.58
## Multiplier on how much the scene's own haze costs this species. Machines with
## thermal sensors are near zero; eyes are 1.
@export_range(0.0, 3.0, 0.01) var haze_sensitivity: float = 1.0
## Seconds a round cracking past keeps this body out of its idle routine. It gets
## the head up and the gaze sweeping; it never grants a position to shoot at,
## because a supersonic crack says you are being shot at and nothing else.
@export_range(0.0, 12.0, 0.1) var crack_alarm_time: float = 3.0

@export_group("Idle life")
## Full sweep of a deliberate idle scan, degrees. Wide sensor arcs sweep wide.
@export_range(0.0, 300.0, 1.0) var idle_scan_arc_degrees: float = 100.0
## Metres the generated patrol beat is thrown around the body's post. Zero posts
## the body on its mark and it never walks.
@export_range(0.0, 40.0, 0.1) var patrol_radius: float = 4.5
## Seconds one idle activity is held, before patience and phase are applied.
@export_range(0.5, 30.0, 0.1) var post_dwell: float = 4.0
## Metres within which two idle bodies of the same faction will stand and talk.
@export_range(0.0, 12.0, 0.1) var converse_radius: float = 4.0
## Chance per activity choice that a body with somebody to talk to takes it.
@export_range(0.0, 1.0, 0.01) var converse_chance: float = 0.3
## Multiplier on walk speed while patrolling.
@export_range(0.1, 1.0, 0.01) var patrol_speed_scale: float = 0.72

@export_group("Temperament")
## Half-width of the uniform draw around every personality trait. Zero makes
## every body of this species identical, which is what a hive should be.
@export_range(0.0, 0.6, 0.01) var personality_variance: float = 0.35
## Centre of the aggression, nerve and discipline draws for this species.
@export_range(0.0, 1.0, 0.01) var base_aggression: float = 0.5
@export_range(0.0, 1.0, 0.01) var base_nerve: float = 0.5
@export_range(0.0, 1.0, 0.01) var base_discipline: float = 0.5

@export_group("Morale")
## Morale units gained or lost per second at unit pressure. Higher breaks and
## rallies faster; this is the single dial for how volatile the species is.
@export_range(0.05, 4.0, 0.01) var morale_rate: float = 0.5
## Seconds a rout runs before the body will consider stopping.
@export_range(0.0, 20.0, 0.1) var rout_minimum: float = 3.5
## Multiplier on run speed while routing. Above 1 for anything that panics.
@export_range(0.5, 2.0, 0.01) var rout_speed_scale: float = 1.0
## Weight suppression carries in the morale sum, before `suppression_gain`.
@export_range(0.0, 2.0, 0.01) var morale_suppression_weight: float = 0.62

@export_group("Weapon")
## One of `Weapon`, held as a plain int. Godot 4.7 cannot resolve an enum-typed
## property across a script boundary — `p.weapon = AISpeciesProfile.Weapon.AUTO`
## fails to parse from another file — so the enum stays for the names and the
## storage stays an int. Compare against `Weapon.*` as normal.
@export_enum("Melee", "Rifle", "Auto", "Cone", "Detonator") var weapon: int = Weapon.MELEE
## Metres. The bestiary's `reach`. A marksman's 120 m exceeds its 82 m of sight on
## purpose: it can shoot what the squad calls out but cannot find it alone.
@export_range(0.5, 400.0, 0.1) var weapon_range: float = 1.5
## Below this the species tries to back off. Zero for anything that bites.
@export_range(0.0, 200.0, 0.1) var min_range: float = 0.0
@export_range(1.0, 400.0, 0.5) var damage: float = 12.0
## Rounds per minute inside a burst. Melee species read this as swings.
@export_range(6.0, 1200.0, 1.0) var rpm: float = 60.0
@export_range(1, 60, 1) var burst: int = 1
## Seconds between bursts, before reaction and suppression are added.
@export_range(0.0, 6.0, 0.01) var burst_pause: float = 1.0
@export_range(1, 400, 1) var magazine: int = 12
@export_range(0.4, 8.0, 0.05) var reload_time: float = 2.4
## Cone half-angle in degrees at a settled aim, before suppression.
@export_range(0.0, 20.0, 0.01) var spread_degrees: float = 1.4
## Seconds of tracking before the cone reaches `spread_degrees`. Until then it is
## twice as wide, which is what stops an agent snapping onto a sprinting player.
@export_range(0.05, 4.0, 0.01) var aim_settle: float = 0.7
## Blast radius for DETONATOR and for grenades, metres.
@export_range(0.0, 20.0, 0.1) var blast_radius: float = 0.0

@export_group("Armament")
## What this species scavenges, as a `GunTables.CLASS_MIX` archetype name. Empty
## derives it from `weapon` and `weapon_range` — see `gun_archetype()`. The
## literal `"none"` means this species never picks a gun up whatever it is
## holding its reach with, which is how a machine keeps its integral emitter.
@export var gun_class: StringName = &""
## Seed for the roll. Zero rolls per body off the species id and the agent id, so
## a firing line of scavengers is a firing line of different scrap. Any non-zero
## value pins the whole species to one weapon — issued kit, not salvage.
@export_range(0, 2147483646, 1) var gun_seed: int = 0

@export_group("Grenades")
@export var has_grenades: bool = false
@export_range(0, 12, 1) var grenade_count: int = 0
@export_range(4.0, 60.0, 0.5) var grenade_range: float = 24.0
@export_range(4.0, 90.0, 0.5) var grenade_cooldown: float = 16.0
@export_range(6.0, 30.0, 0.5) var grenade_speed: float = 14.0
@export_range(1.0, 12.0, 0.1) var grenade_fuse: float = 2.6
## Payload tag handed to whoever builds the projectile: frag, gas, incendiary.
@export var grenade_payload: StringName = &"frag"

@export_group("Courage")
## Health fraction below which this species starts thinking about leaving. Zero
## for anything that has never had the thought.
@export_range(0.0, 1.0, 0.01) var flee_health: float = 0.0
## Suppression it will absorb before it stops shooting and gets its head down.
@export_range(0.1, 1.0, 0.01) var suppression_tolerance: float = 0.6
## Multiplier on how fast suppression builds. Machines barely notice.
@export_range(0.0, 3.0, 0.01) var suppression_gain: float = 1.0
## Fraction of a squad that can die before the survivors reconsider.
@export_range(0.0, 1.0, 0.01) var rout_fraction: float = 0.7

@export_group("Role bias")
## Weights the squad's role solver multiplies its scores by. Higher wins.
@export_range(0.0, 3.0, 0.01) var bias_suppressor: float = 1.0
@export_range(0.0, 3.0, 0.01) var bias_flanker: float = 1.0
@export_range(0.0, 3.0, 0.01) var bias_advancer: float = 1.0
@export_range(0.0, 3.0, 0.01) var bias_scout: float = 0.0
## True for anything that closes and detonates. Overrides every other behaviour.
@export var suicide_charge: bool = false

@export_group("Mobility")
## Derive the four mobility limits below from the body rather than reading them.
##
## ON by default and it matters: the twelve shipped species profiles are baked
## resources written before these fields existed, and a baked resource loads the
## code default for anything it does not carry. With this on they get mobility
## that follows from what they are — see `_derived_climb` — instead of twelve
## copies of whatever the defaults happen to say. Turn it off to hand-author.
@export var mobility_auto: bool = true
## Ladders and other hand-over-hand climbs. A quadruped has no hands.
@export var can_climb: bool = true
## Over a chest-high barricade. Heavy things go round.
@export var can_vault: bool = true
## Pull up onto a ledge.
@export var can_mantle: bool = true
## Metres this species will drop off a ledge under its own steam.
@export_range(0.0, 20.0, 0.1) var drop_height: float = 3.2
## Metres of gap this species will jump. Zero for anything that will not leave
## the ground.
@export_range(0.0, 12.0, 0.1) var jump_gap: float = 2.2

@export_group("Provenance")
## The bestiary's raw `dps`, kept for reference and for the threat maths. Not the
## number the player is actually hit with.
@export_range(0.0, 400.0, 0.1) var reference_dps: float = 0.0


## Seconds between shots inside a burst.
func shot_interval() -> float:
	return 60.0 / maxf(rpm, 1.0)


## Sustained damage per second at a perfect hit rate, after the balance haircut.
func effective_dps() -> float:
	var cycle: float = float(burst) * shot_interval() + burst_pause
	return float(burst) * damage / maxf(cycle, 0.05)


func is_ranged() -> bool:
	return weapon == Weapon.RIFLE or weapon == Weapon.AUTO


## The gun archetype this species turns up carrying, or empty for a thing that
## fights with its body. Authored `gun_class` wins; otherwise the species' own
## natural weapon and reach pick the class, because a 120 m marksman and a 20 m
## trench sweeper are not looking for the same rifle. Anything that bites or
## detonates gets nothing — a scavenged barrel does not give a dog hands.
func gun_archetype() -> String:
	if not gun_class.is_empty():
		return "" if gun_class == &"none" else String(gun_class)
	var out: String = ""
	match weapon:
		Weapon.RIFLE:
			if weapon_range >= 90.0:
				out = "Sniper"
			else:
				out = "Marksman carbine" if weapon_range >= 55.0 else "Carbine"
		Weapon.AUTO:
			if weapon_range >= 60.0:
				out = "Machine gun"
			else:
				out = "Assault rifle" if weapon_range >= 30.0 else "Submachine gun"
		Weapon.CONE:
			out = "Shotgun"
	return out


## Seed for this body's weapon roll. Stable across a scene reload either way, so
## a squad that shot well once shoots well again and a bad gun stays debuggable.
func gun_roll_seed(agent_id: int) -> int:
	if gun_seed != 0:
		return gun_seed
	return (hash(species_id) ^ (agent_id * 2654435761)) & 0x7FFFFFFF


## The band this species wants to fight in: it closes below `x`, backs off above
## `y`. Melee species collapse to a single point at their reach.
func engagement_band() -> Vector2:
	if weapon == Weapon.MELEE or weapon == Weapon.DETONATOR:
		return Vector2(0.0, weapon_range * 0.85)
	return Vector2(min_range, weapon_range * 0.86)


func cos_half_fov() -> float:
	return cos(deg_to_rad(clampf(fov_degrees, 20.0, 360.0)) * 0.5)


## The navigation layer mask this species searches with.
##
## Every agent walks, so `LAYER_WALK` is unconditional. Each further bit is one
## capability, and a baked off-mesh link carries exactly the bit it demands — so
## an agent that cannot climb does not path up the ladder and then fail at the
## bottom of it, its corridor search never contains the ladder at all. That is the
## whole per-species mobility system, and it costs one integer per agent.
##
## Anything that hovers gets the lot. A wasp does not need a ladder, but the link
## is the shortest way from the street to the roof and it can fly it.
func navigation_layer_mask() -> int:
	if hover_height > 0.0:
		return AILinkBaker.LAYER_ALL
	var mask: int = AILinkBaker.LAYER_WALK
	if can_climb and (not mobility_auto or _derived_climb()):
		mask |= AILinkBaker.LAYER_CLIMB
	if can_vault and (not mobility_auto or _derived_vault()):
		mask |= AILinkBaker.LAYER_VAULT
	if can_mantle and (not mobility_auto or _derived_vault()):
		mask |= AILinkBaker.LAYER_MANTLE
	var drop: float = drop_height if not mobility_auto else _derived_drop()
	var gap: float = jump_gap if not mobility_auto else _derived_gap()
	mask |= AILinkBaker.drop_tier_bits(drop)
	mask |= AILinkBaker.jump_tier_bits(gap)
	return mask


## Whether this body has hands, which is the question a ladder actually asks.
##
## `gun_archetype()` is already the project's answer to it — "a scavenged barrel
## does not give a dog hands" — so climbing reads off the same fact rather than
## inventing a second, disagreeing one. A biter or a walking bomb has no hands and
## no business on a ladder.
func _derived_climb() -> bool:
	return not gun_archetype().is_empty()


## Vaulting and mantling need hands and a body that can fold. A tall, wide, heavy
## thing goes round: the width test is the one that keeps a Foreman off the
## barricades the scavengers are hopping.
func _derived_vault() -> bool:
	return _derived_climb() and body_radius <= 0.60 and height <= 2.6


## Metres this body will drop. It scales with leg length, which is what stops a
## rat taking a fall a scavenger would walk away from, and it is capped so nothing
## steps off a four-storey roof because it happens to be tall.
func _derived_drop() -> float:
	return clampf(height * 2.0, 0.8, 5.0)


## Metres of gap this body will clear. Run-up matters more than size, so this is
## driven by run speed and only trimmed by height.
func _derived_gap() -> float:
	if weapon == Weapon.DETONATOR:
		return 0.0
	return clampf(run_speed * 0.62 + height * 0.35, 0.0, 4.5)
