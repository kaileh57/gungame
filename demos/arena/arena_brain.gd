class_name ArenaBrain
extends RefCounted
## One body's decisions. Perception in, a heading and a trigger out.
##
## The AI module ships the parts — sight, memory, the alert machine, the
## navigator, cover, trigger discipline — and an `EnemyActor` that is deliberately
## brainless. This is the thing between them: the per-agent policy that reads the
## senses, picks somewhere to stand, and tells the body to go there and shoot.
##
## Nothing here allocates after `bind`. Every service it touches arrives through
## the `AITickContext` the director fills, so the brain never holds a reference to
## the director and cannot reach past what it was given.
##
## The order below is not arbitrary. Senses first, because the alert machine reads
## them; the alert state next, because it decides what the feet are for; cover
## after that, because a firing position is a function of where the threat is; and
## the trigger last, because it wants the muzzle already pointed.

## The agent believes it is behind something once it is this close to the cover
## point it claimed. Wider than the navigator's arrival radius on purpose — the
## barrel protects a body standing near it, not only one standing on the mark.
const COVER_ARRIVE: float = 1.15
## Seconds a claimed cover point is held before the brain will look for a better
## one. Re-querying every tick makes a body dither between two barrels.
const COVER_HOLD: float = 2.4
## Metres of slack on the engagement band before the feet bother moving. Without
## it an agent inside its own band still shuffles a few centimetres a second.
const BAND_SLACK: float = 2.0
## Awareness at which a body will turn and look at something it has not confirmed.
const GLANCE_AWARENESS: float = 0.08
## Ceiling on rays one brain asks the frame pool for.
const RAY_REQUEST: int = 3
## Cover search radius, metres.
const COVER_SEARCH: float = 18.0
## Hand the intended velocity to the navigation server's avoidance solver.
##
## OFF, and deliberately. RVO returns last frame's safe velocity, and an agent
## that ticks at fifteen hertz reads a solution computed for a heading it no
## longer has — the observed result is a wave that wedges in its own doorway and
## then spends its detour budget walking into the desert. The bodies already push
## past each other through `move_and_slide`, which at this population is both
## cheaper and correct.
const AVOIDANCE: bool = false
## Metres from its post beyond which an idle body picks up the pace. Walking forty
## metres at a gasman's 0.86 m/s is three quarters of a minute.
const POST_HUSTLE: float = 12.0

var actor: EnemyActor = null
var profile: AISpeciesProfile = null
var perception: AIPerception = null
var memory: AIMemory = null
var alertness: AIAlertness = null
var navigator: AINavigator = null
var agent_id: int = 0
var faction: int = 0
## Where this body stands when it has nothing to fight. Its arrival gate.
var post: Vector3 = Vector3.ZERO
## Where a body with nothing to fight drifts, and how. Written by the director;
## see `_prowl`. `hunt_step` at or below zero switches the whole behaviour off and
## puts the body back to standing its post for ever.
var hunt_point: Vector3 = Vector3.ZERO
var hunt_standoff: float = 9.0
var hunt_step: float = 7.0
var hunt_delay: float = 2.5
## Squad slot, or -1 when the body fights alone.
var squad: AISquad = null

## Last resolved contact position, for the debug overlay and the director's notes.
var focus_position: Vector3 = Vector3.ZERO
var focus_id: int = -1
var has_los: bool = false
var cover_index: int = -1
## What the chosen contact scored, and whether it is the player. Both are written
## by `_choose_slot` every tick and read by the director's readout and by the
## arena's acceptance harness — "how many of these bodies are actually coming for
## me" is the one number this demo exists to answer and it must not be inferred.
var focus_score: float = 0.0
var focus_is_player: bool = false

var _rng: XorShift32 = null
var _noise_cursor: int = 0
var _search_phase: float = 0.0
var _cover_timer: float = 0.0
var _aggression: float = 0.5
## Seconds left before this body may creep its post toward `hunt_point` again.
var _prowl_wait: float = 0.0
var _reported_arrival: bool = false


## Wire the brain to a live actor. Called once per spawn; a recycled actor is
## re-bound rather than rebuilt, so nothing here may allocate per frame.
func bind(
	body: EnemyActor,
	species: AISpeciesProfile,
	body_faction: int,
	id: int,
	tuning: AIPerceptionTuning
) -> void:
	actor = body
	profile = species
	faction = body_faction
	agent_id = id
	_rng = XorShift32.new(id * 7919 + 13)
	_search_phase = _rng.next() * TAU
	if perception == null:
		perception = AIPerception.new(species, body_faction, id)
		memory = AIMemory.new()
		alertness = AIAlertness.new()
		navigator = AINavigator.new()
	perception.configure(species, body_faction, tuning)
	if tuning != null:
		memory.apply_tuning(tuning)
		alertness.apply_tuning(tuning)
	memory.clear()
	alertness.reset()
	navigator.setup(body.nav_agent(), species, AVOIDANCE)
	navigator.stop()
	post = body.global_position
	cover_index = -1
	_cover_timer = 0.0
	_noise_cursor = AINoiseBus.cursor()
	_reported_arrival = false
	_prowl_wait = hunt_delay
	focus_id = -1
	focus_score = 0.0
	focus_is_player = false
	has_los = false


## 0 cowed, 1 rabid. Scales how far a body will push, how readily it leaves cover
## and how wide a band it will fight in. The station's dial writes this.
func set_aggression(value: float) -> void:
	_aggression = clampf(value, 0.0, 1.0)


## Which way this body is actually looking, in world space.
##
## Beast rigs are authored in rig space — "+Y up, +Z forward", bestiary spec §5 —
## and `EnemyActor` yaws to `atan2(face.x, face.z)`, which puts the intended
## heading on local **+Z**. Reading `-basis.z` here, as one would for any ordinary
## Godot node, gives the exact opposite and every sight cone points at the wall
## behind the creature. Measured: a wasp with a 200-degree field standing thirty
## metres from the player reported `facing = -0.97`.
func facing() -> Vector3:
	return actor.global_basis.z


func state() -> int:
	return AIAlertness.State.IDLE if alertness == null else alertness.state


func is_alive() -> bool:
	return actor != null and actor.alive


## Being shot from somewhere unseen. Grants suppression and a reason to be
## alarmed, never a target — the alert machine is forced to ENGAGED only when the
## body already had eyes on something.
func on_hurt(from_position: Vector3) -> void:
	if alertness == null:
		return
	var to: Vector3 = from_position - actor.global_position
	if to.length_squared() > 1e-4:
		actor.look_at_point(from_position)
	if alertness.state == AIAlertness.State.IDLE:
		alertness.force(AIAlertness.State.SUSPICIOUS)
	memory.report(-1, from_position, 0.5, 1.4)


## One decision step. `cheap` is the scheduler's far-LOD kind: hearing, memory and
## the feet still run, sight and cover do not.
func tick(ctx: AITickContext, cheap: bool) -> void:
	if actor == null or not actor.alive:
		return
	var delta: float = maxf(ctx.delta, 1e-4)
	var eye: Vector3 = actor.global_position + Vector3(0.0, profile.eye_height, 0.0)
	_sense(ctx, delta, eye, cheap)
	var slot: int = _choose_slot(ctx.targets)
	_resolve_focus(ctx, slot, eye, cheap)
	var awareness: float = 0.0 if slot < 0 else memory.slot_awareness(slot)
	var visible: bool = slot >= 0 and memory.slot_visible(slot)
	alertness.tick(delta, awareness, visible, slot >= 0)
	_act(ctx, delta, slot, cheap)
	_report_to_squad(ctx)
	# Fading LAST is not tidiness. `AIMemory.fade` clears every contact's seen-this-
	# tick flag on its way through, so anything that reads `slot_visible` after it
	# is told the target is out of sight — and the alert machine promotes to ENGAGED
	# only on a contact it can currently see. Measured: a rat with awareness 1.03 and
	# a clear line sat in SUSPICIOUS forever.
	memory.fade(delta, profile.awareness_decay)


## Which remembered contact this body is going to fight, by
## `AITargetIndex.contact_priority` rather than by `AIMemory.best_slot`.
##
## The memory ranks on belief alone, which is the right answer for "is anything
## happening" and the wrong one for "who do I shoot". In a room holding the player
## and two rival factions, belief alone hands the body whichever contact it most
## recently laid eyes on — so a wave walks in, notices each other, and never gets
## round to the player. The index scores the same slots with range and with who
## the contact IS folded in, and that is what makes the arena read as a test
## arena: the player is the target when they are known about, and the factions
## brawl among themselves when they are not.
##
## Falls back to the memory's own ranking with no index bound, which is what a
## harness that drives a brain without a director gets.
##
## ONE THING IS DELIBERATELY LOST HERE. `AIMemory` keeps a per-contact `threat`
## and publishes no accessor for it, so the 1.4 a contact earns by shooting this
## body is not in the score. It only ever applies to the `id -1` contact
## `on_hurt` files, which carries no row and cannot be resolved to a body anyway;
## the alert machine still promotes off it and the body still turns to look.
func _choose_slot(targets: AITargetIndex) -> int:
	focus_score = 0.0
	focus_is_player = false
	if targets == null:
		return memory.best_slot()
	var here: Vector3 = actor.global_position
	var best: int = -1
	for i: int in memory.count():
		var row: int = targets.row_of(memory.slot_id(i))
		var s: float = targets.contact_priority(
			row, here, memory.slot_position(i), memory.slot_awareness(i), memory.slot_confidence(i)
		)
		if s > focus_score:
			focus_score = s
			best = i
			focus_is_player = row >= 0 and targets.is_player(row)
	return best


func _sense(ctx: AITickContext, delta: float, eye: Vector3, cheap: bool) -> void:
	perception.set_space(ctx.space)
	perception.sight_enabled = not cheap
	if not cheap:
		var granted: int = ctx.take_rays(RAY_REQUEST)
		var spent: int = perception.look(delta, eye, facing(), ctx.targets, memory, granted, 1.0)
		ctx.refund_rays(granted - spent)
	_noise_cursor = perception.listen(memory, eye, _noise_cursor)


## Turn the best remembered contact into a world point and a line-of-sight answer.
## The believed position is the dead-reckoned one, so a body that ducked behind a
## crate keeps being shot at for as long as the memory is worth anything.
func _resolve_focus(ctx: AITickContext, slot: int, eye: Vector3, cheap: bool) -> void:
	if slot < 0:
		focus_id = -1
		has_los = false
		return
	focus_id = memory.slot_id(slot)
	focus_position = memory.predicted_position(slot)
	if memory.slot_visible(slot):
		has_los = true
		return
	if cheap or ctx.take_rays(1) <= 0:
		has_los = false
		return
	has_los = perception.line_of_sight(eye, focus_position)


func _act(ctx: AITickContext, delta: float, slot: int, cheap: bool) -> void:
	match alertness.state:
		AIAlertness.State.IDLE:
			_hold_post(ctx, delta)
		AIAlertness.State.SUSPICIOUS:
			_stare(ctx, delta, slot)
		AIAlertness.State.SEARCHING:
			_search(ctx, delta, slot)
		_:
			_fight(ctx, delta, cheap)


## Nothing to do: stand the post, look along it. A body that has drifted off its
## mark walks back, which is what keeps a cleared arena tidy between waves.
func _hold_post(ctx: AITickContext, delta: float) -> void:
	actor.disengage()
	var offset: Vector3 = post - actor.global_position
	offset.y = 0.0
	var away: float = offset.length()
	if away < 1.4:
		_prowl(delta)
		actor.halt()
		navigator.stop()
		return
	navigator.set_goal(post)
	var pace: float = profile.walk_speed
	if away > POST_HUSTLE:
		pace = lerpf(profile.walk_speed, profile.run_speed, 0.55)
	_walk(ctx, delta, pace)


## A body that has arrived and has nothing to fight moves its own post a step
## closer to `hunt_point`, waits, and does it again.
##
## THIS IS THE ARENA'S ANSWER TO "THEY SHOULD PRIORITISE YOU", and it is a
## movement rule rather than a targeting one, because measurement said the
## targeting was already right. With ninety-four bodies deployed across a 76 by
## 60 m compound, only **15 of them ever carried any contact on the player at
## all** — and ten of those fifteen chose the player over the rival they were
## standing next to, so `AITargetIndex.contact_priority` was doing its job on
## every body that had the evidence to do it with. The other seventy-nine were
## standing at a post forty metres away with the player outside their species'
## sight range. No weight fixes that. Walking does.
##
## It grants NOTHING but a heading. No awareness, no contact, no aim: a body that
## has crept to within nine metres of the dais still has to see the player before
## `AIMemory` has anything in it and still has to build awareness at its own
## species' rate. What it removes is the standoff that made the evidence
## impossible to get.
##
## It is off in every other level in the project, because it is a statement about
## an arena — you released these things into a pen with you in it — and would be
## nonsense in a three-faction war the player is a bystander in.
func _prowl(delta: float) -> void:
	if hunt_step <= 0.0:
		return
	# Only while genuinely idle. A body that is staring, searching or fighting is
	# not here, and one that has just lost a contact should finish looking for it.
	_prowl_wait -= delta
	if _prowl_wait > 0.0:
		return
	_prowl_wait = hunt_delay
	var to: Vector3 = hunt_point - actor.global_position
	to.y = 0.0
	var gap: float = to.length()
	if gap <= hunt_standoff or gap < 1e-3:
		return
	post = actor.global_position + to / gap * minf(hunt_step, gap - hunt_standoff)


func _stare(ctx: AITickContext, delta: float, slot: int) -> void:
	actor.halt()
	navigator.advance(delta, actor.global_position)
	if slot >= 0 and memory.slot_awareness(slot) > GLANCE_AWARENESS:
		actor.look_at_point(memory.slot_position(slot))
	_pump_path(ctx, false)


func _search(ctx: AITickContext, delta: float, slot: int) -> void:
	actor.disengage()
	if slot < 0:
		_hold_post(ctx, delta)
		return
	var target: Vector3 = memory.search_point(slot, alertness.search_step, _search_phase)
	navigator.set_goal(target)
	_walk(ctx, delta, lerpf(profile.walk_speed, profile.run_speed, 0.45 + 0.4 * _aggression))


## The fight. Cover first, then the band, then the trigger.
func _fight(ctx: AITickContext, delta: float, cheap: bool) -> void:
	if focus_id < 0:
		_hold_post(ctx, delta)
		return
	var weapon: AICombat = actor.weapon
	var muzzle: Vector3 = actor.muzzle_point()
	var dist: float = muzzle.distance_to(focus_position)
	if weapon != null:
		_choose_ground(ctx, delta, weapon, dist, cheap)
	actor.look_at_point(focus_position)
	var suppressive: bool = not has_los and dist <= profile.weapon_range
	actor.engage(delta, focus_position, has_los, ctx.targets, ctx.space, suppressive)
	_walk(ctx, delta, _fight_speed(weapon, dist))
	if not has_los and not cheap:
		# Firing at a place rather than a body is what pins a player behind a
		# barrel, and it is the only thing that makes a squad feel like a squad.
		AINoiseBus.emit_noise(muzzle, 22.0, 0.4, faction, agent_id)


## Where the feet want to be: a claimed cover point when the body wants cover and
## the map has one, otherwise a spot inside the engagement band.
func _choose_ground(
	ctx: AITickContext, delta: float, weapon: AICombat, dist: float, cheap: bool
) -> void:
	_cover_timer -= delta
	# Pinned, dry or reloading is a hard want. Below that, a body prefers to shoot
	# from behind something — but only once it is close enough to shoot at all.
	# Without the band test a creature with a thirty-metre reach standing at
	# thirty-five metres walks sideways into cover it has no use for and the fight
	# never starts; measured, that was one round fired in twenty seconds.
	var in_band: bool = dist <= weapon.engagement_band().y + BAND_SLACK
	var want_cover: bool = weapon.wants_cover() or (in_band and (1.0 - _aggression) > 0.35)
	if cheap or ctx.cover == null or not ctx.cover.is_ready():
		weapon.set_in_cover(false)
		_band_move(weapon, dist)
		return
	if want_cover and _cover_timer <= 0.0:
		_cover_timer = COVER_HOLD
		var band: Vector2 = weapon.engagement_band()
		var found: int = ctx.cover.query(
			actor.global_position, focus_position, band, COVER_SEARCH, agent_id, true
		)
		if found != cover_index:
			_release_cover(ctx)
			cover_index = found
	if not want_cover:
		_release_cover(ctx)
	if cover_index < 0:
		weapon.set_in_cover(false)
		_band_move(weapon, dist)
		return
	ctx.cover.claim(cover_index, agent_id)
	var stand: Vector3 = ctx.cover.point(cover_index)
	var here: float = actor.global_position.distance_to(stand)
	var settled: bool = here <= COVER_ARRIVE
	weapon.set_in_cover(settled)
	if settled and not _reported_arrival and squad != null:
		_reported_arrival = true
		squad.report_arrived(agent_id)
	if settled and weapon.wants_exposure():
		stand = ctx.cover.lean_position(cover_index, focus_position, 0.75)
	navigator.set_goal(stand)


## No cover worth having: close or back off until the range is inside the band.
func _band_move(weapon: AICombat, dist: float) -> void:
	var band: Vector2 = weapon.engagement_band()
	var to: Vector3 = focus_position - actor.global_position
	to.y = 0.0
	var l: float = to.length()
	if l < 1e-3:
		return
	var dir: Vector3 = to / l
	if dist > band.y + BAND_SLACK and _may_advance(dist > band.y * 1.5):
		navigator.set_goal(focus_position - dir * band.y * 0.9)
		return
	if dist < band.x - BAND_SLACK:
		navigator.set_goal(actor.global_position - dir * (band.x - dist))
		return
	navigator.set_goal(actor.global_position)


## Bounding overwatch: the squad hands out a small number of moving tokens and
## everybody else holds and shoots. A lone body always has permission.
##
## `forced` overrides the token. Overwatch is about crossing exposed ground toward
## something you can already shoot; a body half again beyond its own reach is not
## covering anybody by standing still, it is only failing to arrive. Without this
## a squad in HOLD parked itself thirty-five metres from a thirty-metre weapon and
## fired nothing for twenty seconds.
func _may_advance(forced: bool = false) -> bool:
	if squad == null or forced:
		return true
	return squad.may_advance(agent_id)


func _fight_speed(weapon: AICombat, dist: float) -> float:
	if weapon == null:
		return profile.walk_speed
	var band: Vector2 = weapon.engagement_band()
	if dist > band.y * 1.4:
		return profile.run_speed
	return lerpf(profile.walk_speed, profile.run_speed, 0.35 + 0.5 * _aggression)


## Advance the navigator, spend a path slot if one is owed, and push the resulting
## heading onto the actor. The only place the feet are written.
func _walk(ctx: AITickContext, delta: float, speed: float) -> void:
	navigator.advance(delta, actor.global_position)
	_pump_path(ctx, alertness.is_fighting())
	if navigator.is_stuck():
		navigator.unstick(_rng)
	var dir: Vector3 = navigator.steer_direction(actor.global_position)
	if dir.length_squared() < 1e-6:
		actor.halt()
		return
	var scale: float = navigator.speed_scale(facing(), dir)
	var wanted: Vector3 = navigator.avoid(dir * speed * scale)
	var flat := Vector3(wanted.x, 0.0, wanted.z)
	actor.steer(flat, flat.length())
	_reported_arrival = false


func _pump_path(ctx: AITickContext, fighting: bool) -> void:
	if not navigator.wants_path(fighting) or not ctx.take_path():
		return
	navigator.commit_path()


func _release_cover(ctx: AITickContext) -> void:
	if cover_index >= 0 and ctx.cover != null:
		ctx.cover.release(cover_index, agent_id)
	cover_index = -1


func _report_to_squad(ctx: AITickContext) -> void:
	if squad == null or actor.weapon == null:
		return
	var weapon: AICombat = actor.weapon
	var magazine: float = maxf(float(profile.magazine), 1.0)
	squad.report(
		agent_id,
		actor.global_position,
		actor.health_fraction(),
		clampf(float(weapon.ammo) / magazine, 0.0, 1.0),
		has_los,
		weapon.in_cover,
		weapon.suppress.normalized()
	)
	if focus_id >= 0 and ctx.blackboard != null:
		var confidence: float = 1.0 if has_los else 0.5
		ctx.blackboard.report(focus_id, focus_position, Vector3.ZERO, confidence, 1.0)
