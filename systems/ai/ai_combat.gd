class_name AICombat
extends Resource
## Trigger discipline for one agent: what range it wants to fight at, when to
## lean out, when to shoot, how badly, when to stop and reload, when to throw
## something, and when to keep its head down.
##
## A Resource rather than a plain object so every number below is an inspector
## knob. A species owns one authored template; `instantiate()` deep duplicates it
## per body, so each agent gets its own suppression state and its own aim bias
## while the tuning stays shared and editable in one place.
##
## SIX things move the cone, and they are what makes an AI feel fair. SETTLE: a
## fresh target is worth `settle_spread_multiplier` times the spread until it has
## been tracked for `AISpeciesProfile.aim_settle` seconds, so nobody is snapped the
## instant they break cover. BIAS: each body carries a small fixed aim error for
## life, so a squad is a spread of shooters rather than one shooter copied.
## `aim_scale`: who this body is (`AIPersonality.marksmanship`) and how it is
## holding up (`AIMorale.spread_scale`), so that spread is authored rather than
## accidental. RECOIL: the cone climbs with every round and recovers between
## bursts. SUPPRESSION: incoming fire widens the cone, eats the settle back down so
## a pinned shooter never finishes ramping, and past the species' tolerance stops
## it firing. SUPPRESSIVE INTENT: fire aimed at a remembered position is
## deliberately wide, because the point of it is the sound.
##
## Lead is solved against the target's velocity, MEASURED here rather than taken
## on trust: `EnemyActor.engage` has no argument for it, so every caller hands this
## class a bare point and differencing it between ticks recovers the lead. A jump
## past `velocity_estimate_max` is a caller switching targets, not a body
## accelerating, and it throws the estimate away.
##
## Where the agent STANDS is `AIEngagement`'s job — the band, the posture and the
## fighting withdrawal. `engagement_band()` is the one channel
## `FirefightAgent._standoff`, `ArenaBrain` and `AICoverMap.query` all steer off.
##
## The weapon comes from the species: `configure()` reads the armament declaration
## and rolls that archetype out of `GunFactory`, and `bind_gun` overrides it. With
## a `GunSpec` the agent inherits the player's ballistics wholesale — same rate,
## magazine, reload, cone and effective range, the shot thrown through the same
## `GunHitscan`/`GunDamage` pair — so an agent and a player firing the same scrap
## rifle are firing the same scrap rifle. `fire_hook` goes further and hands the
## whole trigger pull to a body that owns a live `Weapon` node. A species with no
## gun falls back to its own numbers, which is what a thing with claws needs.

## A round left the barrel. `hit` is the collider or null for a clean miss.
signal fired(origin: Vector3, direction: Vector3, hit_position: Vector3, hit: Object)
## A melee attack connected.
signal struck(target: AITarget, damage: float)
## A grenade was released with a solved velocity. Fuse and payload come from the
## species; whoever owns projectiles decides what that payload LOOKS like. What
## it DOES is resolved here — see `_blast` — so a throw is a real event with real
## casualties in a headless harness that has no projectile system at all.
signal grenade_thrown(origin: Vector3, velocity: Vector3, payload: StringName, fuse: float)
## Something went off: a detonator species that reached its target, or a thrown
## grenade reaching the end of its fuse. Damage has already been applied.
signal detonated(origin: Vector3, radius: float, damage: float)
## A weapon was put in this agent's hands, or taken out of them (`spec` null).
## Whoever owns the body listens for this to hang the right gun off the rig.
signal gun_bound(spec: GunSpec)
signal reload_started(duration: float)
signal reload_finished
signal ammo_changed(current: int, capacity: int)

## What the agent wants its feet to do about the current range.
enum Posture { HOLD, ADVANCE, RETREAT }

## Gravity the grenade arc is solved under. The player controller's own figure —
## a lobbed frag that falls at a different rate to the player reads as wrong.
const THROW_GRAVITY: float = 21.5

@export_group("Engagement")
## Range policy: the band, the posture and the fighting withdrawal. Deep
## duplicated by `instantiate()`, so each body owns its own withdrawal clock.
@export var engagement: AIEngagement = null

@export_group("Aim")
## How much of the target's velocity is led. One is a perfect solution, which no
## species gets; the shortfall is what makes strafing work.
@export_range(0.0, 1.5, 0.01) var lead_fraction: float = 0.85
## Seconds of flight the lead is allowed to solve for. Past this the guess is
## worse than not guessing.
@export_range(0.0, 2.0, 0.01) var lead_max_seconds: float = 0.9
## Cone multiplier on a target that has just been acquired, decaying to the
## settled cone over the species' settle time.
@export_range(1.0, 6.0, 0.05) var settle_spread_multiplier: float = 2.0
## Fraction of the authored cone that remains at full time-on-target. Below one
## so that holding an aim is rewarded; above zero so that it is never free.
@export_range(0.05, 1.0, 0.01) var settle_floor: float = 0.55
## Half-width of the fixed per-body aim error, degrees. Rolled once per agent.
@export_range(0.0, 3.0, 0.01) var bias_degrees: float = 0.45
## Degrees the cone climbs with every round fired. This is what makes the tenth
## round of a burst worse than the first and the first burst better than a held
## trigger — without it an automatic weapon in an agent's hands is a laser.
@export_range(0.0, 3.0, 0.01) var recoil_degrees: float = 0.22
## Degrees of accumulated climb bled off per second between rounds.
@export_range(0.1, 30.0, 0.1) var recoil_recover: float = 5.5
## Ceiling on the climb, degrees. Past this a burst stops getting worse.
@export_range(0.0, 12.0, 0.05) var recoil_max: float = 2.6
## Time-on-target destroyed per second at full suppression, as a fraction of the
## whole. At one, a body under maximum fire can never finish settling.
@export_range(0.0, 4.0, 0.01) var suppression_settle_loss: float = 1.15
## Metres per second above which an apparent target movement is read as the
## caller changing its mind rather than as the target running, and the velocity
## estimate is thrown away.
@export_range(2.0, 200.0, 0.5) var velocity_estimate_max: float = 24.0
## How fast the measured target velocity chases the newest sample. Low enough to
## survive one noisy tick, high enough to catch a target that changed direction.
@export_range(0.05, 1.0, 0.01) var velocity_blend: float = 0.45
## Margin added to a teammate's silhouette before the corridor test will clear a
## shot. Half a metre of doubt is cheaper than shooting your own suppressor.
@export_range(0.0, 3.0, 0.01) var friendly_margin: float = 0.55
## Whether `configure()` may go to `GunFactory` for the weapon the species says
## it carries. Off puts every agent back on its authored species numbers, which
## is what a headless harness with no autoloads and no part library gets anyway.
@export var scavenge_guns: bool = true
## Floor on the cone when firing a `GunSpec`. A match barrel in an agent's hands
## is still an agent's hands.
@export_range(0.0, 6.0, 0.01) var gun_spread_floor_degrees: float = 0.55
## Multiplier on `GunSpec.damage` when an agent pulls the trigger. The player's
## damage numbers are tuned for the player's uptime, not for a squad's.
@export_range(0.05, 2.0, 0.01) var gun_damage_scale: float = 0.55

@export_group("Peeking")
## Seconds the agent stays leaned out of cover before ducking back.
@export_range(0.2, 6.0, 0.05) var peek_seconds: float = 1.4
## Random spread on the exposure, either way. Squads that peek in unison read as
## a machine.
@export_range(0.0, 3.0, 0.05) var peek_variance: float = 0.5
## Seconds it stays down between peeks.
@export_range(0.1, 6.0, 0.05) var hide_seconds: float = 1.1
@export_range(0.0, 3.0, 0.05) var hide_variance: float = 0.45
## Fraction of the magazine below which it reloads the moment it is behind
## something, rather than waiting to run dry in the open.
@export_range(0.0, 1.0, 0.01) var reload_at_fraction: float = 0.34

@export_group("Suppression")
## Per-agent suppression model. Deep duplicated by `instantiate()`.
@export var suppress: AISuppression = null

@export_group("Grenades")
## Seconds the agent must have known where something is without being able to see
## it before it throws to flush it out. Measured in "how long has that doorway
## been a problem", not in "is there an enemy".
@export_range(0.2, 12.0, 0.05) var grenade_flush_seconds: float = 1.8
## Metres below which nothing is thrown: inside this the blast is the thrower's
## problem too.
@export_range(2.0, 30.0, 0.5) var grenade_min_range: float = 6.0
## Multiple of the blast radius kept clear of friendly bodies before the pin is
## pulled. Above one, because the men near the aim point were walking somewhere
## while the charge was in the air.
@export_range(1.0, 3.0, 0.05) var grenade_friendly_scale: float = 1.45
## Fraction of the blast damage still landing at the edge of the radius.
@export_range(0.0, 1.0, 0.01) var grenade_edge_damage: float = 0.25
## Multiplier on the species' `damage` at the centre of the blast. A thrown
## charge is worth several rifle rounds or it is not worth the throw.
@export_range(0.5, 12.0, 0.1) var grenade_damage_scale: float = 3.5

@export_group("Ballistics")
## Falloff, zones, impulse — the player's own arrival maths, so an agent's round
## does what the player's round would do. Deep duplicated by `instantiate()`.
@export var ballistics: GunDamage = null
## The ray and what it goes through, configured from the bound `GunSpec`. Same
## class the player's weapon traces with, so cover stops an agent's rifle exactly
## as hard as it stops the player's.
@export var penetration: GunHitscan = null
## What an agent's rounds may hit. `MASK_BULLET` is written from the player's side
## of the fight and deliberately omits the player's own body, so an agent firing
## it back puts every round straight through whoever it is aiming at. This is the
## one mask in the project that adds `PLAYER`, and the reason it exists.
@export_flags_3d_physics var shot_mask: int = GameLayers.MASK_BULLET | GameLayers.PLAYER

var profile: AISpeciesProfile = null
## The gun the agent is holding, or null for a species that fights with its body.
var gun: GunSpec = null
## Optional whole-pull resolver, so a body that owns a live `Weapon` node fires
## through it and this class only keeps the trigger discipline. Signature
## `func(origin: Vector3, direction: Vector3) -> Variant`; a returned Dictionary
## carrying `position` and `collider` reports the shot, and anything else falls
## back to the shell this class throws itself.
var fire_hook: Callable = Callable()
## Optional veto on throwing, so a faction can hold one grenade in the air at a
## time. Signature `func(agent_id: int, hold_seconds: float) -> bool`, which is
## exactly `AIBlackboard.request_grenade`. Unset means nobody is rationing them.
var grenade_gate: Callable = Callable()
## 0-1 tracking quality. Zero the instant a target is acquired or lost.
var settle: float = 0.0
var ammo: int = 0
var reloading: bool = false
var grenades_left: int = 0
## Whether the behaviour currently has something solid between it and the threat.
## Drives the peek cycle and the decision to reload early.
var in_cover: bool = false
## Set by a detonator species that has closed to blast range. The agent reads it,
## detonates, and dies.
var ready_to_detonate: bool = false
## Total rounds this body has put downrange. Read by the debug overlay.
var shots_fired: int = 0
## Cone multiplier for who this body is and how it is holding up: its
## `AIPersonality.marksmanship` and its `AIMorale.spread_scale`, composed by
## whoever owns the body (`EnemyActor.engage`) and pushed in here. 1.0 is a
## species-average individual with steady nerve; above 1 is a worse shot.
##
## Both inputs were computed per body and read by NOBODY before this — two agents
## of one species shot inside the same cone however frightened or however sharp
## their stat block said they were.
var aim_scale: float = 1.0

var _faction: int = 0
var _agent_id: int = 0
var _shot_timer: float = 0.0
var _burst_left: int = 0
var _reload_timer: float = 0.0
var _grenade_timer: float = 0.0
var _reaction_timer: float = 0.0
var _peek_timer: float = 0.0
var _exposed: bool = true
var _bias_yaw: float = 0.0
var _bias_pitch: float = 0.0
## Accumulated recoil climb, radians. Grows per round, bleeds off per second.
var _recoil: float = 0.0
## Seconds this agent has known where something is without being able to see it.
## What decides a grenade is worth throwing.
var _blind_seconds: float = 0.0
## Last believed target position and the velocity differenced out of it.
var _last_target: Vector3 = Vector3.ZERO
var _target_velocity: Vector3 = Vector3.ZERO
var _have_last_target: bool = false
## The one grenade this body has in the air: where it will go off, and when.
## Negative timer means nothing is live.
var _nade_at: Vector3 = Vector3.ZERO
var _nade_timer: float = -1.0
## The index handed down by the last `tick`. Kept so a fuse that runs out, or a
## detonator that goes off, still has something to hurt.
var _targets: AITargetIndex = null
var _query: PhysicsRayQueryParameters3D = null
var _rng: RandomNumberGenerator = null
## Live for the duration of one trigger pull, read by `_on_pellet_hit`. Null
## outside a shot, which is what tells a stray callback to do nothing.
var _shot_targets: AITargetIndex = null
var _shot_origin: Vector3 = Vector3.ZERO
var _pellet_damage: float = 0.0
var _pellet_dir: Vector3 = Vector3.FORWARD
var _pellet_collider: Object = null
## Never populated: a muzzle is authored in front of the body holding it, and the
## target index assigns its own ids, so there is no honest way to name the
## shooter's collider from in here. `GunHitscan.trace` still wants an array.
var _exclude: Array[RID] = []


func _init(species: AISpeciesProfile = null, faction: int = 0, agent_id: int = 0) -> void:
	_query = PhysicsRayQueryParameters3D.new()
	_query.collide_with_areas = true
	_rng = RandomNumberGenerator.new()
	if suppress == null:
		suppress = AISuppression.new()
	if engagement == null:
		engagement = AIEngagement.new()
	if ballistics == null:
		ballistics = GunDamage.new()
	if penetration == null:
		penetration = GunHitscan.new()
	penetration.on_hit = _on_pellet_hit
	penetration.collision_mask = shot_mask
	_query.collision_mask = shot_mask
	if species != null:
		configure(species, faction, agent_id)


## A live per-agent copy of this template. Deep, so the copy gets its own
## suppression resource; the tuning values ride along unchanged.
func instantiate(species: AISpeciesProfile, faction: int, agent_id: int) -> AICombat:
	var copy: AICombat = duplicate(true) as AICombat
	copy.configure(species, faction, agent_id)
	return copy


func configure(species: AISpeciesProfile, faction: int, agent_id: int) -> void:
	profile = species
	_faction = faction
	_agent_id = agent_id
	# Seeded off the body id so a given agent's aim bias is stable across a
	# reload of the scene, which makes a bad shooter debuggable.
	_rng.seed = hash(agent_id * 2654435761 + 17)
	# `duplicate(true)` hands the copy fresh sub-resources with no callback on
	# them — the binding is not an exported property and does not ride along.
	if engagement == null:
		engagement = AIEngagement.new()
	if ballistics == null:
		ballistics = GunDamage.new()
	if penetration == null:
		penetration = GunHitscan.new()
	penetration.on_hit = _on_pellet_hit
	penetration.collision_mask = shot_mask
	_query.collision_mask = shot_mask
	suppress.gain = 1.0 if species == null else species.suppression_gain
	_bias_yaw = _rng.randf_range(-1.0, 1.0) * deg_to_rad(bias_degrees)
	_bias_pitch = _rng.randf_range(-1.0, 1.0) * deg_to_rad(bias_degrees)
	reset()
	_scavenge()


## Hand the agent a gun. Pass null to put it back on its own claws. Resets the
## magazine, because a scavenged weapon comes loaded.
func bind_gun(spec: GunSpec) -> void:
	gun = spec
	if spec != null:
		penetration.configure(spec, ballistics)
	ammo = _magazine()
	_burst_left = _burst()
	reloading = false
	_reload_timer = 0.0
	gun_bound.emit(spec)
	ammo_changed.emit(ammo, _magazine())


## Roll the weapon the species says it turns up carrying and bind it. This is the
## whole point of the seam: an agent and a player firing the same scrap rifle are
## firing the same `GunSpec`, off the same factory, with the same rate, magazine,
## reload, cone and effective range. Silent when the species fights with its body,
## when the switch is off, or when there is no factory to ask — a headless harness
## has no autoloads and a species profile still has to work there.
func _scavenge() -> void:
	bind_gun(_roll_species_gun())


## The roll itself, or null for every reason an agent ends up empty-handed.
func _roll_species_gun() -> GunSpec:
	if not scavenge_guns or profile == null:
		return null
	var want: String = profile.gun_archetype()
	if want.is_empty():
		return null
	if not is_instance_valid(GunFactory) or not GunFactory.is_ready():
		return null
	return GunFactory.roll(profile.gun_roll_seed(_agent_id), want)


## Muzzle energy of this body's report, joules — what the hearing model prices a
## shot at. The gun's own figure when it is holding one; a rifle-sized round when
## it is not, because a species profile has no ballistics of its own.
func report_energy() -> float:
	if gun != null and gun.muzzle_energy > 0.0:
		return float(gun.muzzle_energy)
	return 1750.0


func reset() -> void:
	suppress.reset()
	engagement.reset()
	settle = 0.0
	reloading = false
	ready_to_detonate = false
	in_cover = false
	_exposed = true
	_recoil = 0.0
	_blind_seconds = 0.0
	_have_last_target = false
	_target_velocity = Vector3.ZERO
	_nade_timer = -1.0
	_shot_timer = 0.0
	_reload_timer = 0.0
	_grenade_timer = 0.0
	_peek_timer = 0.0
	# A body that has just been handed a target has not reacted to it yet. Without
	# this an agent that is configured mid-fight fires on its very first tick.
	_reaction_timer = 0.0 if profile == null else profile.reaction_time
	if profile != null:
		ammo = _magazine()
		grenades_left = profile.grenade_count
		_burst_left = _burst()


## One decision step. `target_pos` is where the agent believes the enemy is;
## `has_los` says whether it can actually see that point right now. Firing at a
## believed position with no line of sight is legal and is what `suppressive`
## means — it is how a squad pins something it cannot see. `target_velocity` is
## what the lead is solved against; zero is a valid answer and disables it.
func tick(
	delta: float,
	muzzle: Vector3,
	target_pos: Vector3,
	has_los: bool,
	targets: AITargetIndex,
	space: PhysicsDirectSpaceState3D,
	suppressive: bool,
	target_velocity: Vector3 = Vector3.ZERO
) -> void:
	_targets = targets
	_advance(delta)
	if profile == null:
		return
	_advance_grenade(delta)
	var dist: float = muzzle.distance_to(target_pos)
	_blind_seconds = 0.0 if has_los else _blind_seconds + delta
	_measure_velocity(delta, target_pos)
	# The band is updated whatever else happens this tick: a body halfway through a
	# magazine change still has feet, and a withdrawal starts while the gun is empty.
	var pressure: float = suppress.level / maxf(profile.suppression_tolerance, 0.01)
	var mag: float = float(ammo) / float(maxi(_magazine(), 1))
	engagement.update(delta, _reach(), dist, has_los, pressure, mag, profile.flee_health)
	if reloading:
		_advance_reload(delta)
		return
	if dist < 1e-3:
		return
	if profile.suicide_charge:
		ready_to_detonate = dist <= maxf(profile.blast_radius * 0.75, 1.0) and has_los
		return
	_track(delta, dist, has_los)
	_consider_grenade(muzzle, target_pos, dist)
	if _may_fire(dist, has_los, suppressive):
		var lead: Vector3 = target_velocity if target_velocity != Vector3.ZERO else _target_velocity
		_engage(muzzle, target_pos, lead, dist, targets, space, suppressive)


## Whether a target at `dist` is inside the usable band. A marksman's band reaches
## past its own eyesight on purpose — that is what spotters are for.
func can_engage(dist: float) -> bool:
	if profile == null:
		return false
	return dist <= _engage_limit() and dist >= profile.min_range


## THE STEERING CHANNEL: the band the agent wants to fight in, closing above `y`
## and backing off below `x`. Driven by the gun's effective range when it is
## holding one — which is what makes a scavenged shotgun a different fighter to a
## scavenged marksman rifle — and pushed outward by an active withdrawal.
func engagement_band() -> Vector2:
	if profile == null:
		return Vector2.ZERO
	if gun == null or gun.effective_range <= 0:
		return engagement.widen(profile.engagement_band())
	return engagement.band(_reach(), profile.min_range)


## What the feet should do at `dist`. Losing sight is worth closing for even from
## inside the band — a wall between you and the target is not a firing position.
func posture(dist: float, has_los: bool) -> Posture:
	return engagement.posture(dist, has_los, engagement_band()) as Posture


## Where to point, given where the target is and how fast it is going. Lead is
## scaled by tracking quality: a shooter that has not settled has not worked out
## which way the target is moving either.
func aim_solution(target_pos: Vector3, target_velocity: Vector3, dist: float) -> Vector3:
	var flight: float = clampf(dist / _projectile_speed(), 0.0, lead_max_seconds)
	return target_pos + target_velocity * flight * lead_fraction * (0.35 + 0.65 * settle)


## Cone half-angle in radians, everything applied. Also drives the debug overlay's
## sight cone so what you see is what the agent is actually shooting inside.
## Recoil is ADDED, not multiplied: it is a fixed number of degrees the muzzle has
## climbed, so a tight rifle and a loose one walk off the target by the same
## amount and only the tight one notices.
func current_spread(suppressive: bool) -> float:
	if profile == null:
		return 0.0
	var settle_k: float = lerpf(settle_spread_multiplier, settle_floor, settle)
	var wide: float = suppress.suppressive_spread_multiplier if suppressive else 1.0
	return _base_spread() * settle_k * suppress.spread_multiplier() * wide + _recoil


## Incoming fire landed close. `severity` is 1 for a round through the silhouette
## and falls off with miss distance; use `register_incoming` to have it measured.
func take_suppression(severity: float, from_direction: Vector3 = Vector3.ZERO) -> void:
	suppress.apply(severity, from_direction)


## Measure a round that passed this body and apply whatever suppression it is
## worth. Returns the severity, so a director can skip the cheap ones.
func register_incoming(origin: Vector3, dir: Vector3, travel: float, at: Vector3) -> float:
	var radius: float = 0.36 if profile == null else profile.body_radius
	return suppress.register_shot(origin, dir, travel, at, radius)


func start_reload() -> void:
	if reloading or profile == null or ammo >= _magazine():
		return
	reloading = true
	_reload_timer = _reload_time()
	reload_started.emit(_reload_timer)


## True when the agent has a reason to be behind something rather than in a
## position it can shoot from: pinned, dry, reloading, down to the last rounds,
## or breaking contact. `AICoverMap.query` reads it as "want a hole, not a firing
## step", so a body that is nearly out walks to deep cover BEFORE it runs dry and
## changes magazines there instead of in the street.
func wants_cover() -> bool:
	if profile == null:
		return false
	if reloading or ammo <= 0 or engagement.withdrawing:
		return true
	if ammo < int(ceil(float(_magazine()) * reload_at_fraction)):
		return true
	return suppress.is_pressured(profile.suppression_tolerance)


## Whether the behaviour should be leaning out right now. Always true in the
## open — the peek cycle only means anything when there is something to peek from.
func wants_exposure() -> bool:
	if not in_cover:
		return true
	return _exposed and not reloading and ammo > 0


## Tell the agent whether it currently has cover. Entering cover starts the cycle
## hidden, so a body that has just dived behind a barrel is behind the barrel.
func set_in_cover(value: bool) -> void:
	if value == in_cover:
		return
	in_cover = value
	_exposed = not value
	_peek_timer = _hide_duration() if value else 0.0


func has_ammo() -> bool:
	return ammo > 0


## Try to put a grenade on `target_pos`. Returns true if one was released.
##
## Arc, fuse and detonation point are solved here and now — a charge that lands
## before its fuse runs out goes off where it landed, one whose fuse runs out first
## airbursts along the arc — so it lands in the right place whether the agent
## thinks at sixty hertz or at four. Whoever draws the projectile integrates its
## own arc off `grenade_thrown` and nothing about the damage depends on it. One in
## the air per body; `grenade_gate` is the faction's ration on top of that.
func try_grenade(origin: Vector3, target_pos: Vector3) -> bool:
	if profile == null or not profile.has_grenades or grenades_left <= 0:
		return false
	if _grenade_timer > 0.0 or _nade_timer >= 0.0 or profile.blast_radius <= 0.5:
		return false
	var d: Vector3 = target_pos - origin
	var flat: float = Vector2(d.x, d.z).length()
	if flat < grenade_min_range or flat > profile.grenade_range:
		return false
	var v: Vector3 = solve_arc(origin, target_pos, profile.grenade_speed)
	if v == Vector3.ZERO:
		return false
	grenades_left -= 1
	_grenade_timer = profile.grenade_cooldown
	var flight: float = flat / maxf(Vector2(v.x, v.z).length(), 0.01)
	_nade_timer = minf(profile.grenade_fuse, flight)
	if _nade_timer >= flight:
		_nade_at = target_pos
	else:
		var t: float = _nade_timer
		_nade_at = origin + v * t - Vector3.UP * (0.5 * THROW_GRAVITY * t * t)
	grenade_thrown.emit(origin, v, profile.grenade_payload, profile.grenade_fuse)
	return true


## Launch velocity that puts a projectile of speed `speed` on `to` under gravity,
## taking the flatter of the two solutions. Returns zero when the throw is out of
## reach, which is the caller's cue to move closer rather than lob it short.
static func solve_arc(from: Vector3, to: Vector3, speed: float) -> Vector3:
	var d: Vector3 = to - from
	var flat: Vector2 = Vector2(d.x, d.z)
	var l: float = flat.length()
	if l < 0.1:
		return Vector3.ZERO
	var v2: float = speed * speed
	var disc: float = v2 * v2 - THROW_GRAVITY * (THROW_GRAVITY * l * l + 2.0 * d.y * v2)
	if disc < 0.0:
		return Vector3.ZERO
	var angle: float = atan((v2 - sqrt(disc)) / (THROW_GRAVITY * l))
	var horiz: Vector2 = flat / l * (speed * cos(angle))
	return Vector3(horiz.x, speed * sin(angle), horiz.y)


## A detonator species that has closed to blast range going off. Same resolution
## as a grenade, at the species' own damage rather than the thrown multiple.
func detonate(origin: Vector3) -> void:
	if profile == null:
		return
	ready_to_detonate = false
	_blast(origin, profile.damage)


## Whether this tick is the one to throw, and the throw itself. The trigger is
## not "there is an enemy" — it is "I have known where that thing is for
## `grenade_flush_seconds` and still cannot see it", which is a contact behind a
## wall and the one case a rifle cannot answer.
func _consider_grenade(muzzle: Vector3, target_pos: Vector3, dist: float) -> void:
	if profile == null or not profile.has_grenades or grenades_left <= 0:
		return
	if _nade_timer >= 0.0 or _grenade_timer > 0.0 or _blind_seconds < grenade_flush_seconds:
		return
	# The species' authored range is a wish; `speed^2 / g` is what the arm can do.
	# Without the second half a profile whose `grenade_range` outruns its
	# `grenade_speed` — which the shipped defaults do, 24 m asked of a 14 m/s throw
	# that reaches 9 — spends the whole fight solving an arc that has no solution.
	var throwable: float = profile.grenade_speed * profile.grenade_speed / THROW_GRAVITY
	if dist < grenade_min_range or dist > minf(profile.grenade_range, throwable):
		return
	if not _grenade_clear(target_pos):
		return
	if grenade_gate.is_valid() and not grenade_gate.call(_agent_id, profile.grenade_fuse + 1.5):
		return
	try_grenade(muzzle, target_pos)


## Nobody friendly, and not this body either, inside the blast.
func _grenade_clear(at: Vector3) -> bool:
	if _targets == null:
		return false
	var keep2: float = pow(profile.blast_radius * grenade_friendly_scale, 2.0)
	for row: int in _targets.size():
		if not _targets.is_alive(row):
			continue
		if _targets.id(row) != _agent_id and not Factions.allied(_faction, _targets.faction(row)):
			continue
		if _targets.aim_point(row).distance_squared_to(at) < keep2:
			return false
	return true


## Run the fuse down and go off, whether or not the thrower still has a target.
func _advance_grenade(delta: float) -> void:
	if _nade_timer < 0.0:
		return
	_nade_timer -= delta
	if _nade_timer <= 0.0:
		_nade_timer = -1.0
		_blast(_nade_at, profile.damage * grenade_damage_scale)


## One blast against the target index: linear falloff from `full` at the centre
## to `grenade_edge_damage` of it at the radius, hostiles only. Applied here
## rather than left to a projectile system, because a charge that is only a
## signal never kills anybody and the harnesses have no projectiles at all.
func _blast(at: Vector3, full: float) -> void:
	var radius: float = profile.blast_radius
	detonated.emit(at, radius, full)
	if _targets == null or radius <= 0.0:
		return
	for row: int in _targets.size():
		if not _targets.is_alive(row) or not Factions.hostile(_faction, _targets.faction(row)):
			continue
		var d: float = _targets.aim_point(row).distance_to(at)
		if d <= radius:
			var k: float = lerpf(1.0, grenade_edge_damage, d / radius)
			_targets.node(row).receive_damage(full * k, at, null)


## Rounds the magazine holds: the gun's, or the species' own.
func _magazine() -> int:
	if gun != null and gun.magazine > 0:
		return gun.magazine
	return 1 if profile == null else profile.magazine


func _reload_time() -> float:
	if gun != null and gun.reload_time > 0.0:
		return gun.reload_time
	return 2.4 if profile == null else profile.reload_time


## Seconds between rounds inside a burst.
func _shot_interval() -> float:
	if gun != null and gun.rpm > 0:
		return 60.0 / float(gun.rpm)
	return 1.0 if profile == null else profile.shot_interval()


## Rounds per trigger pull. A semi-automatic gun is one, whatever the species
## would like; an automatic one gets the species' own burst discipline.
func _burst() -> int:
	if profile == null:
		return 1
	if gun == null:
		return profile.burst
	return profile.burst if gun.automatic else 1


func _damage() -> float:
	if gun != null and gun.damage > 0.0:
		return gun.damage * gun_damage_scale
	return 0.0 if profile == null else profile.damage


## How far this body can usefully fight with what it is holding: the shorter of
## the gun's effective range and the species' own reach. A scavenged marksman
## rifle does not give a dog eyes, and the species stat is where that lives.
func _reach() -> float:
	if profile == null:
		return 0.0
	if gun == null or gun.effective_range <= 0:
		return profile.weapon_range
	return minf(float(gun.effective_range), profile.weapon_range)


## Metres past which the agent will not pull the trigger at all.
func _engage_limit() -> float:
	if gun == null:
		return 0.0 if profile == null else profile.weapon_range
	return engagement.engage_limit(_reach())


## Speed the lead is solved against. Hitscan weapons still need a finite number
## here or the lead collapses to nothing and strafing becomes free.
func _projectile_speed() -> float:
	if gun != null and gun.sim_velocity > 0:
		return float(gun.sim_velocity)
	if gun != null and gun.muzzle_velocity > 0:
		return float(gun.muzzle_velocity)
	return 420.0


func _base_spread() -> float:
	if gun == null:
		return deg_to_rad(profile.spread_degrees) * aim_scale
	return maxf(gun.spread_rad, deg_to_rad(gun_spread_floor_degrees)) * aim_scale


func _advance(delta: float) -> void:
	_shot_timer = maxf(_shot_timer - delta, 0.0)
	_grenade_timer = maxf(_grenade_timer - delta, 0.0)
	_reaction_timer = maxf(_reaction_timer - delta, 0.0)
	_recoil = maxf(_recoil - deg_to_rad(recoil_recover) * delta, 0.0)
	suppress.advance(delta)
	_advance_peek(delta)


## Lean out, shoot, duck, repeat. Only cycles behind cover; the timers are
## jittered per flip so a squad never surfaces together.
func _advance_peek(delta: float) -> void:
	if not in_cover:
		_exposed = true
		return
	_peek_timer -= delta
	if _peek_timer > 0.0:
		return
	_exposed = not _exposed
	_peek_timer = _peek_duration() if _exposed else _hide_duration()
	# Behind cover with the magazine half gone is the only free moment there is.
	var floor_rounds: int = int(ceil(float(_magazine()) * reload_at_fraction))
	if not _exposed and not reloading and ammo < floor_rounds:
		start_reload()


func _peek_duration() -> float:
	return maxf(peek_seconds + _rng.randf_range(-peek_variance, peek_variance), 0.15)


func _hide_duration() -> float:
	return maxf(hide_seconds + _rng.randf_range(-hide_variance, hide_variance), 0.1)


## Integrate time-on-target. Losing the mark rewinds the reaction timer too, so a
## target that ducks and reappears costs the agent its reaction time again.
##
## Incoming fire is subtracted from the same integrator rather than applied as a
## separate cone multiplier, which is why a suppressed agent reads as flinching
## rather than as a wider circle: it never reaches the settled end of the ramp.
func _track(delta: float, dist: float, has_los: bool) -> void:
	var tracking: bool = has_los and can_engage(dist)
	var rate: float = delta / maxf(profile.aim_settle, 0.01) if tracking else -delta * 2.2
	rate -= suppression_settle_loss * suppress.normalized() * delta
	settle = clampf(settle + rate, 0.0, 1.0)
	if not tracking:
		_reaction_timer = profile.reaction_time


## Difference the believed position into a velocity, so the lead has something to
## solve against. The guard is what makes it safe: a caller switching targets
## looks exactly like a body crossing twenty metres in a frame.
func _measure_velocity(delta: float, target_pos: Vector3) -> void:
	if not _have_last_target or delta <= 1e-4:
		_last_target = target_pos
		_have_last_target = true
		return
	var v: Vector3 = (target_pos - _last_target) / delta
	_last_target = target_pos
	if v.length_squared() > velocity_estimate_max * velocity_estimate_max:
		_target_velocity = Vector3.ZERO
		return
	_target_velocity = _target_velocity.lerp(v, velocity_blend)


func _advance_reload(delta: float) -> void:
	_reload_timer -= delta
	if _reload_timer > 0.0:
		return
	reloading = false
	ammo = _magazine()
	_burst_left = _burst()
	reload_finished.emit()
	ammo_changed.emit(ammo, _magazine())


## Every gate between wanting to shoot and shooting, in the order they cost.
func _may_fire(dist: float, has_los: bool, suppressive: bool) -> bool:
	if _shot_timer > 0.0 or _reaction_timer > 0.0:
		return false
	if ammo <= 0:
		start_reload()
		return false
	if suppress.is_pinned(profile.suppression_tolerance) or not wants_exposure():
		return false
	if has_los and can_engage(dist):
		return true
	return suppressive and dist <= _engage_limit()


func _engage(
	muzzle: Vector3,
	target_pos: Vector3,
	target_velocity: Vector3,
	dist: float,
	targets: AITargetIndex,
	space: PhysicsDirectSpaceState3D,
	suppressive: bool
) -> void:
	if profile.weapon == AISpeciesProfile.Weapon.MELEE:
		_swing(dist, target_pos, targets)
		return
	var to_aim: Vector3 = aim_solution(target_pos, target_velocity, dist) - muzzle
	var aim_dist: float = to_aim.length()
	if aim_dist < 1e-3:
		return
	var dir: Vector3 = to_aim / aim_dist
	if not _corridor_clear(muzzle, dir, aim_dist, targets):
		return
	_shoot(muzzle, dir, aim_dist, targets, space, suppressive)


## One trigger pull. `fire_hook` gets first refusal for the whole pull, so a body
## that owns a real `Weapon` node fires through it and this only keeps the books;
## otherwise the shell is thrown here, and with a `GunSpec` in hand it is thrown
## through the same `GunHitscan`/`GunDamage` pair the player's weapon uses.
func _shoot(
	muzzle: Vector3,
	dir: Vector3,
	dist: float,
	targets: AITargetIndex,
	space: PhysicsDirectSpaceState3D,
	suppressive: bool
) -> void:
	var aimed: Vector3 = _apply_bias(dir)
	var cone: float = current_spread(suppressive)
	var reach: float = maxf(_engage_limit() * 1.25, dist + 2.0)
	var lead: Dictionary = _throw_payload(muzzle, aimed, cone, reach, targets, space)
	ammo -= 1
	shots_fired += 1
	_recoil = minf(_recoil + deg_to_rad(recoil_degrees), deg_to_rad(recoil_max))
	_burst_left -= 1
	if _burst_left <= 0:
		_burst_left = _burst()
		_shot_timer = profile.burst_pause + _shot_interval()
	else:
		_shot_timer = _shot_interval()
	fired.emit(muzzle, lead["direction"], lead["position"], lead["collider"])
	ammo_changed.emit(ammo, _magazine())


## Every pellet in the shell, each down its own line inside the cone, exactly as
## `Weapon._throw_payload` does it — a scavenged shotgun in an agent's hands puts
## the same nine pellets in the air as one in the player's, and each of them is
## worth a ninth of the shell. Returns the first pellet's line, which is the one
## a tracer is drawn along.
func _throw_payload(
	muzzle: Vector3,
	aimed: Vector3,
	cone: float,
	reach: float,
	targets: AITargetIndex,
	space: PhysicsDirectSpaceState3D
) -> Dictionary:
	if fire_hook.is_valid():
		var reported: Variant = fire_hook.call(muzzle, aimed)
		if reported is Dictionary and (reported as Dictionary).has("position"):
			var d: Dictionary = reported
			return {
				"position": d["position"], "collider": d.get("collider", null), "direction": aimed
			}
	if gun == null:
		return _trace_bare(muzzle, _scatter(aimed, cone), reach, targets, space)
	_shot_targets = targets
	_shot_origin = muzzle
	var pellets: int = maxi(gun.pellets, 1)
	_pellet_damage = _damage() / float(pellets)
	var lead: Dictionary = {"position": muzzle + aimed * reach, "collider": null}
	for i: int in pellets:
		var line: Vector3 = _scatter(aimed, cone)
		_pellet_dir = line
		_pellet_collider = null
		var end: Vector3 = penetration.trace(space, muzzle, line, reach, _exclude)
		if i == 0:
			lead = {"position": end, "collider": _pellet_collider, "direction": line}
	_shot_targets = null
	return lead


## The claws-and-teeth path: one ray, the species' own damage, no falloff and no
## zones, because a species profile has no ballistics to run them off.
func _trace_bare(
	muzzle: Vector3,
	line: Vector3,
	reach: float,
	targets: AITargetIndex,
	space: PhysicsDirectSpaceState3D
) -> Dictionary:
	_query.from = muzzle
	_query.to = muzzle + line * reach
	var hit: Dictionary = {} if space == null else space.intersect_ray(_query)
	if hit.is_empty():
		return {"position": _query.to, "collider": null, "direction": line}
	var collider: Object = hit["collider"]
	var row: int = targets.row_of_collider(collider)
	if row >= 0 and Factions.hostile(_faction, targets.faction(row)):
		targets.node(row).receive_damage(_damage(), muzzle, null)
	return {"position": hit["position"], "collider": collider, "direction": line}


## One surface a pellet resolved against. `scale` is what the round has left after
## whatever it punched through; `distance` is what the falloff curve is evaluated
## at, so an agent's rifle loses range the way the player's does. Hostiles carrying
## an `AITarget` are damaged through the index so the squad's bookkeeping sees the
## hit; anything else takes it through `GunDamage`.
func _on_pellet_hit(
	collider: Object, at: Vector3, normal: Vector3, distance: float, scale: float, _surface: int
) -> void:
	if _pellet_collider == null:
		_pellet_collider = collider
	if _shot_targets == null:
		return
	var zone: StringName = ballistics.zone_of(collider)
	var amount: float = ballistics.resolve(_pellet_damage * scale, distance, gun, zone)
	var row: int = _shot_targets.row_of_collider(collider)
	if row >= 0:
		if _shot_targets.id(row) == _agent_id:
			return
		if Factions.hostile(_faction, _shot_targets.faction(row)):
			_shot_targets.node(row).receive_damage(amount, _shot_origin, null)
		return
	ballistics.apply(collider, amount, at, normal, _pellet_dir, gun.crit_multiplier)
	ballistics.push(collider, at, _pellet_dir, float(gun.impulse))


func _swing(dist: float, target_pos: Vector3, targets: AITargetIndex) -> void:
	_shot_timer = _shot_interval()
	if dist > profile.weapon_range:
		return
	var best: int = -1
	var best_d: float = profile.body_radius + 0.9
	for row: int in targets.size():
		if not targets.is_alive(row) or not Factions.hostile(_faction, targets.faction(row)):
			continue
		var d: float = targets.aim_point(row).distance_to(target_pos)
		if d < best_d:
			best_d = d
			best = row
	if best < 0:
		return
	shots_fired += 1
	targets.node(best).receive_damage(_damage(), target_pos, null)
	struck.emit(targets.node(best), _damage())


## Nobody friendly inside the shot corridor. Point-to-segment distance against
## every ally in range: exact, allocation-free, and cheap at these counts.
func _corridor_clear(muzzle: Vector3, dir: Vector3, dist: float, targets: AITargetIndex) -> bool:
	for row: int in targets.size():
		if not targets.is_alive(row) or targets.id(row) == _agent_id:
			continue
		if not Factions.allied(_faction, targets.faction(row)):
			continue
		var rel: Vector3 = targets.aim_point(row) - muzzle
		var along: float = rel.dot(dir)
		if along <= 0.3 or along >= dist:
			continue
		if (rel - dir * along).length() < targets.body_radius(row) + friendly_margin:
			return false
	return true


## The body's own fixed error, applied before scatter. Constant for the life of
## the agent, so a bad shooter is consistently a bad shooter.
func _apply_bias(dir: Vector3) -> Vector3:
	if is_zero_approx(_bias_yaw) and is_zero_approx(_bias_pitch):
		return dir
	var up: Vector3 = Vector3.UP if absf(dir.y) < 0.95 else Vector3.RIGHT
	var right: Vector3 = dir.cross(up).normalized()
	return (dir + right * tan(_bias_yaw) + right.cross(dir) * tan(_bias_pitch)).normalized()


## Uniform sample inside a cone of half-angle `spread` about `dir`. Square-rooting
## the radius keeps the distribution even across the disc instead of piling every
## shot into the centre, which is what makes a wide cone read as wide.
func _scatter(dir: Vector3, spread: float) -> Vector3:
	if spread <= 1e-5:
		return dir
	var up: Vector3 = Vector3.UP if absf(dir.y) < 0.95 else Vector3.RIGHT
	var right: Vector3 = dir.cross(up).normalized()
	var lift: Vector3 = right.cross(dir)
	var a: float = _rng.randf() * TAU
	var r: float = tan(spread) * sqrt(_rng.randf())
	return (dir + right * (cos(a) * r) + lift * (sin(a) * r)).normalized()
