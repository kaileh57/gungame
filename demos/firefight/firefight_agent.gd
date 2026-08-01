class_name FirefightAgent
extends RefCounted
## One body's head. Binds an `EnemyActor` to the perception, memory, navigation
## and squad machinery, and spends exactly as much of the frame on it as the tick
## scheduler says it is worth.
##
## Nothing here runs per frame. `think` is called by `FirefightDirector` when the
## scheduler says this agent is due, with `delta` meaning "seconds since THIS
## agent last thought" — a quarter second for something across the valley, a
## sixtieth for something in your face. Between thinks the actor's own motor
## keeps walking on the last heading it was handed, which is why a four-hertz
## agent still animates smoothly.
##
## The FULL/CHEAP split is where the saving actually is. A cheap tick spends no
## raycasts: it does not look, it does not query cover, and it borrows the squad's
## belief about where the enemy is instead of forming its own. It still fights,
## because a fight that stops the moment the camera turns away is not a war, it is
## a diorama. `AICombat` fires at most one burst per call, so a cheap agent is
## capped at `far_hz` shots a second by construction and cannot spend more than
## one ray in `_resolve_shot` doing it.

## Metres either side of the objective a body will spread itself over so a squad
## holding ground stands in a picket rather than a pile.
const PICKET_SPREAD: float = 9.0
## Search radius handed to the cover map, in metres.
##
## MEASURED, do not raise this to reach the decks. The raised decks stand about
## 21 m off the zone anchors, so 14 m cannot offer a body a deck top — but 24 m
## does not fix it either: `aloft` went 1-3 -> 2-4 of ~103, inside noise, while
## bodies in the spectator frame fell from ~50% to ~27% because a wider search
## lets a body drift off the ground its picket was sent to hold. Cover leases did
## improve (10.4 -> 16), so if that trade is ever wanted, take it knowingly.
## The real blocker on the decks is that `_choose_goal` has no height term, so a
## deck top competes with ground cover on distance alone and loses.
const COVER_SEARCH: float = 14.0
## Seconds a claimed cover point is held before the field is re-scored. Matches
## `ArenaBrain.COVER_HOLD`; below about two seconds bodies visibly dither.
const COVER_HOLD: float = 2.4
## Squared metres from its picket inside which a body counts as having ARRIVED on
## the objective and may go looking for a firing position. One picket spread, so a
## body cannot use "taking cover" as an excuse to leave the ground it was sent to.
const HOLD_RADIUS_SQ: float = PICKET_SPREAD * PICKET_SPREAD
## Awareness below which the body is not considered to have a lead worth walking
## toward. Mirrors `AIAlertness.suspicious_enter`.
const LEAD_FLOOR: float = 0.30

var actor: EnemyActor = null
var profile: AISpeciesProfile = null
var squad: AISquad = null
var faction: int = 0
## Stable id shared by the squad, the path service and the blackboard. This is
## the actor's `AITarget.target_id`, so a contact reported by one agent resolves
## to the same body everywhere.
var agent_id: int = 0
## Handle into the tick scheduler. Kept so the director can drop it on death.
var handle: int = -1

var perception: AIPerception = null
var memory: AIMemory = null
var alert: AIAlertness = null
var nav: AINavigator = null
## Set by the director so the agent can reach the shared path service without
## holding a node reference of its own. `func(agent_id: int, urgency: float)`.
var path_submit: Callable = Callable()

var _rng: XorShift32 = null
var _noise_cursor: int = 0
var _cover_index: int = -1
var _in_cover: bool = false
var _goal: Vector3 = Vector3.ZERO
var _picket: Vector3 = Vector3.ZERO
var _has_los: bool = false
var _believed: Vector3 = Vector3.ZERO
var _has_contact: bool = false
var _rows: PackedInt32Array = PackedInt32Array()
## Role the cover lane was last set from, so `_apply_lane` writes only on a change.
var _lane_role: int = -1
## Seconds left on the current cover claim before the field is re-scored.
var _cover_hold: float = 0.0


func _init(
	body: EnemyActor,
	species: AISpeciesProfile,
	tuning: AIPerceptionTuning,
	id: int,
	seed_value: int
) -> void:
	actor = body
	profile = species
	faction = body.faction
	agent_id = id
	_rng = XorShift32.new(maxi(seed_value, 1))
	# `id`, not `seed_value`. `AIPerception` keys the personality registry off what
	# it is seeded with, and `AITarget` keys ITS copy off `target_id` — which is
	# this same `id`. Seeded off the spawn serial instead, one body drew two
	# unrelated personalities: the eyes belonged to a sharp, quick individual and
	# the nerve and the trigger to a different one. `ArenaBrain` has always passed
	# the index id here; this makes the two demos agree.
	perception = AIPerception.new(species, faction, id)
	if tuning != null:
		perception.configure(species, faction, tuning)
	memory = AIMemory.new(8)
	if tuning != null:
		memory.apply_tuning(tuning)
	alert = AIAlertness.new()
	if tuning != null:
		alert.apply_tuning(tuning)
	nav = AINavigator.new()
	# Avoidance ON. Sixty-six bodies converging on seven objectives with it off is
	# a traffic jam: `MASK_ENEMY_MOVE` includes ENEMY, so they collide, and
	# `move_and_slide` writes the blocked velocity back as zero. Measured with it
	# off, a squad ordered 48 m to the next zone covered 8 m in ninety seconds —
	# individual bodies hit their full 1.33 m/s in bursts while the mass of the
	# squad stood still shoving itself.
	nav.setup(body.nav_agent(), species, true)
	# A picket offset drawn once and kept, so a body holds the same slice of the
	# objective every time it comes back to it rather than shuffling.
	var a: float = _rng.next() * TAU
	var r: float = PICKET_SPREAD * sqrt(_rng.next())
	_picket = Vector3(cos(a) * r, 0.0, sin(a) * r)


## Put a recycled agent back to a clean slate. The actor itself is revived by the
## spawner; this is only the head.
func reset() -> void:
	memory.clear()
	alert.reset()
	nav.invalidate()
	_noise_cursor = AINoiseBus.cursor()
	_cover_index = -1
	_cover_hold = 0.0
	_in_cover = false
	_has_los = false
	_has_contact = false


func position() -> Vector3:
	return actor.global_position


func is_alive() -> bool:
	return actor != null and actor.alive


## One decision step. `kind` is `AITickScheduler.KIND_FULL` or `KIND_CHEAP`.
func think(ctx: AITickContext, delta: float, kind: int, cover: AICoverMap) -> void:
	if not is_alive():
		return
	var full: bool = kind == AITickScheduler.KIND_FULL
	var here: Vector3 = actor.global_position
	var eye: Vector3 = here + Vector3(0.0, profile.eye_height, 0.0)

	perception.set_space(ctx.space)
	if full:
		_sense(ctx, delta, eye)
	_noise_cursor = perception.listen(memory, eye, _noise_cursor)
	memory.fade(delta, profile.awareness_decay)
	_cover_hold -= delta
	_resolve_contact(delta, here)
	_choose_goal(here, full, cover)
	_drive(ctx, delta, here)
	_report_to_squad(here)


## Look, and push whatever was seen onto the faction blackboard. The blackboard is
## the only route by which one body's eyes become the squad's plan.
func _sense(ctx: AITickContext, delta: float, eye: Vector3) -> void:
	var wanted: int = perception.max_rays_per_tick
	var granted: int = ctx.take_rays(wanted)
	if granted <= 0:
		return
	# `_facing()`, not `-basis.z`. Point the sight cone out of the back of the
	# body and it can only see what it has already walked past, which reads as an
	# AI that never notices anything and is nearly invisible in a log.
	var forward: Vector3 = _facing()
	# An alerted body notices things faster than an idle one. This is the only
	# place alertness feeds back into perception, and it is what makes a squad
	# that has already been shot at hard to flank twice.
	var gain: float = 1.35 if alert.is_alerted() else 1.0
	var spent: int = perception.look(delta, eye, forward, ctx.targets, memory, granted, gain)
	ctx.refund_rays(granted - spent)
	if ctx.blackboard == null:
		return
	for id: int in perception.visible_ids:
		var slot: int = memory.slot_of(id)
		if slot < 0:
			continue
		ctx.blackboard.report(
			id,
			memory.slot_position(slot),
			memory.slot_velocity(slot),
			memory.slot_confidence(slot),
			1.0
		)


## Settle on what this body believes it is fighting. Its own eyes win; failing
## that it takes the squad's focus, which is how a cheap agent stays in the fight
## without spending a ray on it.
func _resolve_contact(delta: float, here: Vector3) -> void:
	var slot: int = memory.best_slot()
	var awareness: float = 0.0
	var visible: bool = false
	_has_contact = false
	if slot >= 0:
		awareness = memory.slot_awareness(slot)
		visible = memory.slot_visible(slot)
		# The predicted position already carries the lead: `AIMemory` extrapolates
		# the contact's own velocity forward. `EnemyActor.engage` has no argument
		# for target velocity, so this is the only place the aim gets any.
		_believed = memory.predicted_position(slot)
		_has_contact = awareness >= LEAD_FLOOR or visible
	if not _has_contact and squad != null and squad.focus_target() >= 0:
		_believed = squad.focus_position()
		_has_contact = true
		visible = false
	_has_los = visible
	alert.tick(delta, awareness, visible, _has_contact)
	if not _has_contact:
		actor.disengage()
		return
	var flat: Vector3 = _believed - here
	flat.y = 0.0
	if flat.length_squared() > 1e-4:
		actor.look_at_point(Vector3(_believed.x, here.y, _believed.z))


## Where the feet go.
##
## THE SQUAD STEERS, NOT THE EYES. A body walks to where its squad is going and
## nowhere else; what it personally believes it can see only decides what it
## shoots at. That split is the whole reason `AISquad` exists, and it is the
## shape `res://systems/ai/verify/faction_war_harness.gd` proves over fifteen
## simulated minutes.
##
## Steering off each body's own best contact instead — which is the obvious thing
## to write, and what this did first — dissolves the squad. Every marksman on the
## faction blackboard is a contact somewhere, each body picks whichever one its
## own memory rates highest, and eight men who were told to take one zone walk
## off toward eight different enemies a hundred metres apart. Measured: nav
## targets scattered from (23,-43) to (-48,-3) inside one squad, three factions
## crossing each other in open ground without ever closing, and not one round
## fired in six minutes of simulated war.
func _choose_goal(here: Vector3, full: bool, cover: AICoverMap) -> void:
	if squad == null:
		_release_cover(cover)
		_goal = here
		return
	var state: int = squad.state()
	if state == AISquad.State.ROUT or state == AISquad.State.REGROUP:
		_release_cover(cover)
		_goal = squad.rally_point() + _picket * 0.5
		return
	# An anchor holds the ground the squad came from while the rest push. Anyone
	# else, in anything short of an assault, walks to the objective.
	var anchored: bool = squad.role_of(agent_id) == AIRoles.Role.ANCHOR
	if state != AISquad.State.ASSAULT or anchored:
		var stand: Vector3 = squad.objective_point() + _picket
		# A body that has ARRIVED on its slice of the objective and has something to
		# shoot at fights from behind something, rather than from whatever open
		# ground the picket offset happened to drop it on.
		#
		# Cover used to be reachable ONLY from the assault branch below, and a squad
		# is almost never assaulting: measured over 100 s of the live demo, 0 to 1
		# cover leases were held across sixty-six armed bodies and 350 baked cover
		# points, and the frame reads as three factions standing in the open shooting
		# at each other. This does not move the squad — the gate is that the body is
		# already inside its own picket radius of the objective, and `COVER_SEARCH` is
		# well inside `FirefightDirector.objective_arrival` — it only decides which
		# metre of that ground the body stands on.
		if full and _has_contact and here.distance_squared_to(stand) < HOLD_RADIUS_SQ:
			if _take_cover(here, _believed, cover):
				return
		_release_cover(cover)
		_goal = stand
		return
	var focus: Vector3 = squad.focus_position()
	if full and _take_cover(here, focus, cover):
		return
	_release_cover(cover)
	_goal = _standoff(here, focus)


## Claim the best cover point between here and the fight, and take it as the
## goal. False when there is nothing better than open ground.
func _take_cover(here: Vector3, focus: Vector3, cover: AICoverMap) -> bool:
	if cover == null or not cover.is_ready() or actor.weapon == null:
		return false
	# Hold a claimed point for a while instead of re-scoring the field every full
	# tick. Two reasons, and the first is behaviour: a body that re-queries at
	# fifteen hertz dithers between two barrels a metre apart and never settles
	# behind either. The second is cost — the query is a grid scan over every cell
	# inside `COVER_SEARCH` and this is now reachable from every state, so without
	# a hold the whole population would pay for it on every full tick.
	# `ArenaBrain` has had the same throttle, under the same name, from the start.
	if _cover_index >= 0 and _cover_hold > 0.0 and cover.claim(_cover_index, agent_id):
		_settle_cover(here, cover.point(_cover_index))
		return true
	_apply_lane(cover)
	var found: int = cover.query(
		here,
		focus,
		actor.weapon.engagement_band(),
		COVER_SEARCH,
		agent_id,
		not actor.weapon.wants_cover()
	)
	if found < 0 or not cover.claim(found, agent_id):
		return false
	if found != _cover_index:
		cover.release(_cover_index, agent_id)
	_cover_index = found
	_cover_hold = COVER_HOLD
	_settle_cover(here, cover.point(found))
	return true


## Take a cover point as the goal and tell the weapon whether the body is actually
## behind it yet. Shared by both exits of `_take_cover`, because the held-claim
## path has to answer `in_cover` too — leaving it to the query path alone means a
## body that reached its barrel and then stopped re-querying is told it is in the
## open for as long as it holds the lease, and `AICombat` never starts the peek
## cycle or reloads early.
func _settle_cover(here: Vector3, point: Vector3) -> void:
	_goal = point
	_in_cover = here.distance_squared_to(point) < 2.25
	actor.weapon.set_in_cover(_in_cover)


## Put this body's SQUAD ROLE onto the cover map's approach lane.
##
## `AICoverMap.set_agent_lane` existed and nothing in the project called it, so the
## flanker role decided who got a bounding token and who shouted "flanking" and
## then had no effect at all on where the body actually walked — every role
## arrived on the stable pseudo-random lane the map hands out by agent id. A body
## told to flank now arrives on an arc; everybody else comes straight down the
## middle, which is what makes the flank read as a flank rather than as noise.
##
## The side is drawn once off the agent id and never changes, so a flanker that
## has committed to the left keeps going left.
func _apply_lane(cover: AICoverMap) -> void:
	if squad == null or _lane_role == squad.role_of(agent_id):
		return
	_lane_role = squad.role_of(agent_id)
	if _lane_role != AIRoles.Role.FLANKER:
		cover.set_agent_lane(agent_id, 0.0)
		return
	var side: float = 1.0 if (hash(agent_id * 2654435761 + 101) & 1) == 0 else -1.0
	cover.set_agent_lane(agent_id, cover.flank_degrees * side)


## Where to stand relative to the squad's focus: close to the top of the weapon's
## band, back off below the bottom of it, hold inside it. The bounding token only
## gates the approach inside weapons range, for the reason `_bounding_applies`
## sets out.
func _standoff(here: Vector3, focus: Vector3) -> Vector3:
	var band: Vector2 = Vector2(1.0, 2.0)
	if actor.weapon != null:
		band = actor.weapon.engagement_band()
	var to: Vector3 = here - focus
	to.y = 0.0
	var d: float = to.length()
	if d < 1e-3:
		return here
	if d > band.y:
		if _bounding_applies() and not squad.may_advance(agent_id):
			return here
		return focus + to / d * band.y + _picket * 0.4
	if d < band.x:
		return focus + to / d * band.x
	return here


## Which way the body is actually pointing.
##
## `+Z`, not the `-Z` Godot normally calls forward. `EnemyActor._tick_facing`
## turns the body with `atan2(face.x, face.z)`, and that yaw puts `+basis.z`
## along the requested heading — so `-basis.z` is the body's back. Reading the
## conventional axis here costs nothing visible and everything mechanical: the
## dot product against the steering direction comes out at about -1, the
## navigator's `speed_scale` pins to its 0.25 floor, and a whole faction crosses
## the map at a quarter of a walk. Measured: 0.33 m/s against a 1.33 m/s walk,
## which over a 66 m advance is the difference between three minutes and fifty
## seconds, and reads on screen as an AI that does not work.
func _facing() -> Vector3:
	return actor.global_transform.basis.z


## How fast this body is willing to move right now.
##
## A squad crossing open ground under orders runs; a squad standing on the
## objective it already holds walks. A body without a bounding token creeps,
## because somebody else is crossing and its job this moment is to be still and
## looking down the street.
func _top_speed() -> float:
	if squad != null and _bounding_applies() and not squad.may_advance(agent_id):
		return profile.walk_speed * 0.15
	var state: int = AISquad.State.ADVANCE if squad == null else squad.state()
	var pressing: bool = (
		alert.is_alerted()
		or state == AISquad.State.ADVANCE
		or state == AISquad.State.ASSAULT
		or state == AISquad.State.ROUT
	)
	var base: float = profile.run_speed if pressing else profile.walk_speed
	# Nerve on the feet. `AIMorale.speed_scale` is 1.0 in every state but ROUTING,
	# where it is the `rout_speed` dial — so this is the knob that decides whether a
	# broken body walks away or runs, and it is a no-op until somebody turns it up.
	var nerve: AIMorale = _morale()
	return base if nerve == null else base * nerve.speed_scale()


## This body's nerve, or null before `AITarget` has built it.
func _morale() -> AIMorale:
	var t: AITarget = null if actor == null else actor.target()
	return null if t == null else t.morale


## Whether bounding overwatch is the right thing to be doing at this range.
##
## You do not bound across eighty metres of open ground; you march until you are
## in contact and then you bound. Enforcing that here is not a flourish, it is
## what stops a deadlock: `AISquad` commits to ASSAULT off the FACTION
## blackboard, so one marksman's sighting from across the map puts every squad
## in the faction into an assault on something none of their members can see.
## Tokens are only handed out while somebody has eyes on — `_covering()` counts
## exactly that — so with nobody in line of sight no token is ever issued, every
## body creeps at a seventh of a walk, and the squad never closes far enough to
## get the line of sight that would release it. Measured over a six-minute run
## before this: three squads sat eighty metres apart in permanent ASSAULT and
## fired nothing, and the ledger moved only because bodies were standing on
## ground they had walked to before contact.
func _bounding_applies() -> bool:
	if not _has_contact or actor.weapon == null:
		return false
	return actor.global_position.distance_to(_believed) <= actor.weapon.engagement_band().y * 1.35


func _release_cover(cover: AICoverMap) -> void:
	if _cover_index < 0:
		return
	if cover != null:
		cover.release(_cover_index, agent_id)
	_cover_index = -1
	_cover_hold = 0.0
	if _in_cover and actor.weapon != null:
		actor.weapon.set_in_cover(false)
	_in_cover = false


## Move, then fight. Two separate jobs, because a body that has arrived is still
## in the fight.
func _drive(ctx: AITickContext, delta: float, here: Vector3) -> void:
	_walk(ctx, delta, here)
	if not _has_contact:
		return
	_pick_engagement(ctx, here)
	# Firing on a believed position with no line of sight is suppression, and it
	# is the difference between a squad pinning a doorway and a squad standing in
	# the street waiting for permission.
	actor.engage(delta, _believed, _has_los, ctx.targets, ctx.space, not _has_los)


## Path and steer.
##
## The path request is rationed twice over: the navigator refuses to ask when the
## goal has not moved far enough to be worth a query, and the frame's path pool
## refuses to grant more than the service can chew.
##
## Arriving returns from THIS function and not from `_drive`. When the early
## return lived one level up, every body that had reached its objective — which
## in a fight over a zone is most of them — silently stopped engaging, and the
## whole demo ran six minutes of war without a round fired.
func _walk(ctx: AITickContext, delta: float, here: Vector3) -> void:
	nav.advance(delta, here)
	if nav.is_stuck():
		nav.unstick(_rng)
	else:
		nav.set_goal(nav.snap_to_mesh(_goal), alert.is_fighting())
	if nav.wants_path(alert.is_fighting()) and ctx.take_path() and path_submit.is_valid():
		path_submit.call(agent_id, nav.path_urgency())

	var dir: Vector3 = nav.steer_direction(here)
	if dir.length_squared() <= 1e-6:
		if squad != null:
			squad.report_arrived(agent_id)
		actor.halt()
		return
	var wanted: Vector3 = dir * _top_speed() * nav.speed_scale(_facing(), dir)
	# Hand the intent to the avoidance solver and take back what it will allow.
	# It answers with last frame's solution, which at these tick rates is close
	# enough to be worth having and is the only thing that keeps a squad from
	# arriving as a single wedge.
	var safe: Vector3 = nav.avoid(wanted)
	if safe.length_squared() < 1e-6:
		safe = wanted
	actor.steer(safe, safe.length())


## Prefer whatever is actually in reach over whatever this body has been thinking
## about.
##
## `AIMemory.best_slot` scores contacts by awareness, confidence and threat and
## has no distance term at all, so a body that has been tracking something across
## the valley for a minute keeps engaging THAT while an enemy stands at its
## elbow. `AICombat._swing` measures its reach against the believed position and
## returns without swinging when that is out of range, however close the body
## really is to something — so for a Choir tide with 1.3 m of reach this is the
## difference between a faction that fights and one that walks through its
## enemies without touching them.
##
## One broad-phase query, and one ray only when it finds something, and only
## while in contact.
func _pick_engagement(ctx: AITickContext, here: Vector3) -> void:
	if actor.weapon == null:
		return
	var reach: float = actor.weapon.engagement_band().y
	var found: int = ctx.targets.hostiles_near(here, reach, faction, _rows)
	if found == 0:
		return
	var best: int = -1
	var best_d: float = INF
	for k: int in found:
		var d: float = here.distance_squared_to(ctx.targets.position_at(_rows[k]))
		if d < best_d:
			best_d = d
			best = _rows[k]
	if best < 0:
		return
	var aim: Vector3 = ctx.targets.aim_point(best)
	if aim.distance_squared_to(_believed) < 1.0:
		return
	_believed = aim
	_has_los = perception.line_of_sight(here + Vector3(0.0, profile.eye_height, 0.0), aim)
	actor.look_at_point(Vector3(aim.x, here.y, aim.z))


func _report_to_squad(here: Vector3) -> void:
	if squad == null:
		return
	var ammo: float = 1.0
	if actor.weapon != null and profile.magazine > 0:
		ammo = clampf(float(actor.weapon.ammo) / float(profile.magazine), 0.0, 1.0)
	var suppression: float = 0.0
	if actor.weapon != null and actor.weapon.suppress != null:
		suppression = clampf(actor.weapon.suppress.level, 0.0, 1.0)
	squad.report(agent_id, here, actor.health_fraction(), ammo, _has_los, _in_cover, suppression)
