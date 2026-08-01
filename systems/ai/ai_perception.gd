class_name AIPerception
extends RefCounted
## Sight and hearing for one agent.
##
## Sight is the expensive sense and it is metered four ways: the broad-phase grid
## hands back only the hostiles inside sight range, a squared-distance reject
## catches the rest, a cone test runs before any physics call, and a hard per-tick
## cap limits raycasts that the director tops up from a per-frame pool. When the
## pool is dry the loop stops early rather than degrading — a contact the agent
## already remembers stays remembered, so the visible effect of a starved frame is
## that acquisition takes one more tick, not that anybody goes blind.
##
## The occlusion mask is WORLD and PROP only. Bodies live on the player and enemy
## layers, so a ray never has to be told to ignore the thing it is aimed at, and a
## crate correctly hides whoever is crouched behind it.
##
## DETECTION IS NOT BINARY. A clear line of sight is the beginning of the answer,
## not the end. Awareness accrues at a rate scaled by six separate things, and
## every one of them is something a player can act on:
##
## - **Distance**, falling off across the species' own sight range.
## - **Where in the cone**, from full at the centre to `rim_falloff` at the edge.
## - **Haze**, from the scene's own fog. Free at contact, real at range.
## - **The target's silhouette** — stance, sunlight and how much it is moving,
##   all folded into `AITargetIndex.visibility` by the body itself.
## - **Noise the target is making**, which draws the eye toward it.
## - **The reaction window.** A contact that has only just come into view is
##   choked to `reaction_choke` of its rate until the body has had eyes on it for
##   its species' reaction time. This is the difference between a guard who turns
##   and kills you in one frame and one who takes a moment to work out what he is
##   looking at, and it is the single largest contributor to the AI reading as
##   fair rather than as psychic.
##
## Hearing is free and instant, and it is the reason a firefight in the next
## street pulls a patrol in. It grants awareness and a position, never a target: a
## heard contact tops out below the confirm threshold on purpose, and the position
## it grants is wrong by a fraction of the distance it travelled — less when the
## sound was loud at the ear, because a loud sound is an easy one to place.
##
## IDLE LIFE. When there is nothing in memory worth being alert about, `look`
## drives `AIPatrol` and takes its gaze direction instead of the body's shoulders.
## That is not decoration: the swept direction is what the cone is tested against,
## so a guard on a scan genuinely covers an arc over time and can pick something
## up from a bearing it was not originally facing.

## Haze, taken from the scene's own depth fog by `AITarget` when it resolves the
## world. Zero means clear air and costs nothing. Held statically because there is
## one atmosphere and sixty agents should not each hold a copy of it.
static var haze_range: float = 0.0
## The `Factions` autoload, resolved on first use. See `_hostile`.
static var _factions: Object = null

var profile: AISpeciesProfile = null
var tuning: AIPerceptionTuning = null
## This body's temperament. Drawn from the seed handed to `_init`, so it is stable
## across a reload and shared with anything else that asks `AIPersonality.of`.
var personality: AIPersonality = null
## What this body does with itself when nothing is happening.
var idle: AIPatrol = null
## Ceiling on rays this agent may spend in one tick, before the director's own
## per-frame pool is consulted. Stops one agent starving fifty.
var max_rays_per_tick: int = 3
## Set false for far-LOD agents: they keep hearing and keep their memory, but stop
## paying for line-of-sight tests until something brings them closer.
var sight_enabled: bool = true
## Run the idle machine. Off costs one branch and gives a scene with no idle time
## in it — an arena wave, a duel harness — back the gaze sweep's small per-tick
## price. On is right for anything the player walks up on.
var idle_enabled: bool = true
## Half-angle cosine of the sight cone, and the ranges that bound it. Derived from
## the species profile at `configure`; read-only, and exactly what the F3 overlay
## needs to draw the cone.
var cone_cos: float = -1.0
var sight_far: float = 40.0
var peripheral: float = 4.0

## Rows the agent could see this tick, for the debug overlay. Reused, never grown
## past the number of hostiles that were actually in range.
var visible_ids: PackedInt32Array = PackedInt32Array()
## Set true to have the last tick's line-of-sight tests recorded below. Off by
## default: the overlay turns it on for the handful of agents it is drawing.
var debug_capture: bool = false
var debug_ray_from: PackedVector3Array = PackedVector3Array()
var debug_ray_to: PackedVector3Array = PackedVector3Array()
## One per recorded ray: 1 if the line was clear, 0 if scenery blocked it.
var debug_ray_clear: PackedInt32Array = PackedInt32Array()
## Where the last noise this agent reacted to seemed to come from, and how loud it
## was at the ear. Zero loudness means nothing has been heard yet.
var debug_heard_at: Vector3 = Vector3.ZERO
var debug_heard_strength: float = 0.0
## The direction actually looked along last tick, after the idle sweep. This is
## what the overlay must draw the cone about; the body's shoulders are not it.
var debug_gaze: Vector3 = Vector3.FORWARD
## True while nothing in memory is worth being alert about — the idle machine is
## running and the body is living its life.
var debug_calm: bool = true
## Contacts seen last tick that are still inside their reaction window.
var debug_reacting: int = 0

var _query: PhysicsRayQueryParameters3D = null
var _space: PhysicsDirectSpaceState3D = null
var _rng: XorShift32 = null
var _rows: PackedInt32Array = PackedInt32Array()
var _faction: int = 0
var _agent_key: int = 1
var _sight_sq: float = 1600.0
var _peripheral_sq: float = 16.0
var _rim: float = 0.34
var _player_threat: float = 1.15
var _motion_draw: float = 0.55
var _motion_cap: float = 1.5
var _loc_error: float = 0.12
var _heard_scale: float = 0.9
var _heard_cap: float = 0.85
var _hearing_floor: float = 0.01
var _alert_floor: float = 0.30
var _haze_k: float = 1.0
var _alarm_until: float = 0.0


func _init(species: AISpeciesProfile, faction: int, seed_value: int = 1) -> void:
	_query = PhysicsRayQueryParameters3D.new()
	_query.collision_mask = GameLayers.WORLD | GameLayers.PROP
	_query.collide_with_areas = false
	_query.collide_with_bodies = true
	_agent_key = maxi(seed_value, 1)
	_rng = XorShift32.new(_agent_key)
	idle = AIPatrol.new(_agent_key)
	configure(species, faction, null)


## Re-read the profile and the tuning. Called at bind and whenever a species is
## swapped in. Passing null tuning keeps whatever was already applied.
func configure(species: AISpeciesProfile, faction: int, tune: AIPerceptionTuning) -> void:
	profile = species
	_faction = faction
	if tune != null:
		tuning = tune
		max_rays_per_tick = tune.ray_budget_per_tick
		_rim = tune.rim_falloff
		_player_threat = tune.player_threat
		_motion_draw = tune.motion_draw
		_motion_cap = tune.motion_draw_cap
		_loc_error = tune.localisation_error
		_heard_scale = tune.heard_awareness_scale
		_heard_cap = tune.heard_confidence_cap
		_hearing_floor = tune.hearing_floor
		_alert_floor = tune.suspicious_enter
	if species == null:
		cone_cos = -1.0
		sight_far = 40.0
		peripheral = 4.0
	else:
		cone_cos = species.cos_half_fov()
		sight_far = species.sight_range
		peripheral = species.peripheral_range
	_sight_sq = sight_far * sight_far
	_peripheral_sq = peripheral * peripheral
	personality = AIPersonality.of(_agent_key, species)
	idle.configure(species, personality)


## Bind the space state once per tick. Kept separate from `look` so combat can
## reuse the same cached state for its own line checks.
func set_space(space: PhysicsDirectSpaceState3D) -> void:
	_space = space


## Sweep the hostiles in range and write what was seen into `memory`. Returns the
## number of raycasts actually spent so the agent can bill the director.
##
## `forward` is where the body's shoulders point. What is actually looked along is
## `gaze()`, which is the same thing until the idle machine starts sweeping it.
func look(
	delta: float,
	eye: Vector3,
	forward: Vector3,
	targets: AITargetIndex,
	memory: AIMemory,
	ray_budget: int,
	alert_gain: float
) -> int:
	visible_ids.clear()
	debug_reacting = 0
	if debug_capture:
		debug_ray_from.clear()
		debug_ray_to.clear()
		debug_ray_clear.clear()
	if profile == null:
		return 0
	debug_gaze = forward
	# Idle life is near-only, and this is where that is enforced. A far-LOD agent
	# has `sight_enabled` false, so it pays for none of it and simply holds its
	# last posture until something brings it close enough to matter.
	if not sight_enabled or ray_budget <= 0:
		return 0
	# Always, even with the idle machine off: this is also what decides whether the
	# body pays the alerted reaction time or the cold one, and a body that never
	# learns it is alerted reacts like a sleeper for the whole fight.
	debug_calm = _is_calm(memory)
	var gaze: Vector3 = forward
	if idle_enabled:
		idle.tick(delta, eye - Vector3(0.0, profile.eye_height, 0.0), debug_calm)
		gaze = idle.look_direction(forward)
		debug_gaze = gaze
	memory.reaction_choke = profile.reaction_choke
	memory.reacquire_grace = profile.reacquire_grace
	var latency: float = personality.reaction_time(profile, not debug_calm)
	var budget: int = mini(ray_budget, max_rays_per_tick)
	var spent: int = 0
	var n: int = targets.hostiles_near(eye, sight_far, _faction, _rows)
	for k: int in n:
		if spent >= budget:
			break
		var row: int = _rows[k]
		var aim: Vector3 = targets.aim_point(row)
		var to_target: Vector3 = aim - eye
		var d2: float = to_target.length_squared()
		if d2 > _sight_sq or d2 < 1e-6:
			continue
		var d: float = sqrt(d2)
		var dir: Vector3 = to_target / d
		var facing: float = gaze.dot(dir)
		if facing < cone_cos and d2 > _peripheral_sq:
			continue
		spent += 1
		var clear: bool = _clear_line(eye, aim)
		if debug_capture:
			debug_ray_from.append(eye)
			debug_ray_to.append(aim)
			debug_ray_clear.append(1 if clear else 0)
		if not clear:
			continue
		visible_ids.append(targets.id(row))
		var gain: float = _gain(delta, d, facing, targets.visibility(row), targets.loudness(row))
		var threat: float = _player_threat if targets.is_player(row) else 1.0
		var slot: int = memory.observe(
			targets.id(row), aim, targets.velocity(row), gain * alert_gain, threat, latency
		)
		if memory.slot_exposure(slot) < latency:
			debug_reacting += 1
	return spent


## Drain the global noise bus from `cursor` and react to everything hostile in it.
## Returns the cursor to pass back next tick. An agent that slept through a
## firefight catches up here in one pass; one that slept longer than the ring is
## deep starts from the oldest event still held, which is the right kind of loss.
##
## Two kinds arrive here and they are not the same event. A NOISE is a thing that
## happened somewhere and grants a place to look. A CRACK is a round going past
## THIS body's head, and it grants alarm without a position, because a supersonic
## crack tells you that you are being shot at and nothing whatever about where the
## shooter is standing.
func listen(memory: AIMemory, ear: Vector3, cursor: int) -> int:
	var head: int = AINoiseBus.cursor()
	if profile == null:
		return head
	var s: int = maxi(cursor, AINoiseBus.oldest())
	while s < head:
		var kind: int = AINoiseBus.event_kind(s)
		if kind >= 0 and _hostile(AINoiseBus.event_faction(s)):
			if kind == AINoiseBus.KIND_NOISE:
				hear(
					memory,
					ear,
					AINoiseBus.event_position(s),
					AINoiseBus.event_radius(s),
					AINoiseBus.event_loudness(s),
					AINoiseBus.event_source(s)
				)
			else:
				_take_crack(ear, AINoiseBus.event_position(s), AINoiseBus.event_radius(s))
		s += 1
	return head


## Whether a noise made by `other` is worth reacting to.
##
## THE AUTOLOAD IS RESOLVED BY NAME, NOT NAMED. Writing `Factions.hostile(...)`
## here is a compile-time reference to a singleton that does not exist while a
## `--script` tool is compiling, and GDScript answers `Identifier not found:
## Factions` and fails the WHOLE dependency chain behind it — `AITarget`,
## `EnemyActor`, and with them `tools/build_enemies.gd` and `tools/build_arena.gd`.
## Measured: two of twenty-six `bake_all` steps red, over a bake that was
## otherwise producing correct output. `ui/debug/debug_draw.gd` and
## `tools/verify_ai_combat.gd` both already work around the same thing.
##
## The fallback only fires with no autoload in the process, which is a bake tool —
## and no bake tool listens to a noise bus, so it is a definition rather than a
## behaviour.
func _hostile(other: int) -> bool:
	if _factions == null:
		if not Engine.has_singleton(&"Factions"):
			return _faction != other
		_factions = Engine.get_singleton(&"Factions")
	return bool(_factions.call(&"hostile", _faction, other))


## A noise reached this agent. `loudness` is the event's strength at its source,
## `radius` the distance at which it is inaudible. Returns the awareness granted,
## which is zero when the agent is out of earshot.
func hear(
	memory: AIMemory, ear: Vector3, event_pos: Vector3, radius: float, loudness: float, id: int
) -> float:
	if profile == null:
		return 0.0
	var reach: float = radius * profile.hearing_sensitivity
	var d: float = ear.distance_to(event_pos)
	if d >= reach or reach <= 0.01:
		return 0.0
	var strength: float = loudness * (1.0 - d / reach)
	if strength <= _hearing_floor:
		return 0.0
	# A sound locates its source badly and worse with distance, and the error is
	# drawn on the agent's own stream so two agents hearing one shot disagree
	# about where it came from — which is what makes a converging search look
	# like a search rather than a formation. A sound that is LOUD at the ear is
	# easier to place, so the error shrinks with strength and with sharp ears.
	var sharp: float = clampf(strength, 0.0, 1.0) * 0.55
	var err: float = d * _loc_error * (1.0 - sharp) / maxf(personality.acuity, 0.4)
	var jitter: Vector3 = Vector3(_rng.next() - 0.5, 0.0, _rng.next() - 0.5) * err
	var guess: Vector3 = event_pos + jitter
	memory.report(id, guess, minf(strength * _heard_scale, _heard_cap), 1.0)
	debug_heard_at = guess
	debug_heard_strength = strength
	return strength


## Whether `to` can be seen from `from`. Public because combat needs the same test
## before it will pull a trigger, and there is no reason to own two of them.
func line_of_sight(from: Vector3, to: Vector3) -> bool:
	return _clear_line(from, to)


## The direction this body is actually looking, which is the body's own facing
## until the idle machine sweeps it. Anything drawing or reasoning about the sight
## cone wants this and not the transform.
func gaze() -> Vector3:
	return debug_gaze


## Fraction of a target's contrast that survives the scene's haze at `d` metres.
## One over a quadratic rather than an exponential: it is free at contact, has a
## definite half-way point, and never reaches zero, which is what stops a foggy
## demo turning every agent blind rather than short-sighted.
func haze_at(d: float) -> float:
	if haze_range <= 0.0 or profile == null:
		return 1.0
	var sensitivity: float = profile.haze_sensitivity
	if sensitivity <= 0.0:
		return 1.0
	var t: float = d / haze_range
	return clampf(1.0 / (1.0 + t * t * sensitivity), 0.05, 1.0)


func _clear_line(from: Vector3, to: Vector3) -> bool:
	if _space == null:
		return false
	_query.from = from
	_query.to = to
	return _space.intersect_ray(_query).is_empty()


## Nothing in memory is worth being alert about, and nothing has been shot at this
## body recently. Cheap — it walks at most the memory's eight slots and it is the
## only input the idle machine needs.
func _is_calm(memory: AIMemory) -> bool:
	if float(Time.get_ticks_msec()) < _alarm_until:
		return false
	var best: int = memory.best_slot()
	if best < 0:
		return true
	return memory.slot_awareness(best) < _alert_floor


## A round went past. It grants no contact and no position — putting one in memory
## would have the body open fire on its own feet, which is what the first version
## of this did. All it does is end the idle routine: the head comes up, the gaze
## starts sweeping, and the body's own eyes do the rest.
func _take_crack(ear: Vector3, at: Vector3, radius: float) -> void:
	if profile.crack_alarm_time <= 0.0:
		return
	if ear.distance_to(at) > maxf(radius, 0.5):
		return
	_alarm_until = float(Time.get_ticks_msec()) + profile.crack_alarm_time * 1000.0


## Awareness per tick. Falls off with distance, falls off toward the rim of the
## cone, falls off through haze, and rises with anything the target is doing to
## draw attention. `target_vis` already carries the target's stance, its light and
## how much it is moving.
func _gain(delta: float, d: float, facing: float, target_vis: float, noise: float) -> float:
	var dist_k: float = clampf(1.0 - d / maxf(sight_far, 1.0), 0.06, 1.0)
	var span: float = maxf(1.0 - cone_cos, 1e-3)
	var angle_k: float = clampf((facing - cone_cos) / span, 0.0, 1.0)
	angle_k = _rim + (1.0 - _rim) * angle_k
	_haze_k = haze_at(d)
	var draw: float = target_vis * (1.0 + minf(noise, _motion_cap) * _motion_draw)
	return profile.awareness_gain * personality.acuity * dist_k * angle_k * _haze_k * draw * delta
