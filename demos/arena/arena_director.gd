class_name ArenaDirector
extends Node
## The thing that runs the AI. Owns every service an agent is allowed to touch and
## hands them down one tick at a time.
##
## The AI module is a box of parts with a deliberate hole in the middle: a
## scheduler that says who thinks, an index that says what exists, a path service
## that rations queries, a cover map, a blackboard and a squad per faction — and
## nothing that puts them together. This is that. `ArenaBrain` is the policy; this
## is the plumbing, and the split is what keeps the policy testable.
##
## Everything is budgeted. `AITickScheduler` caps thinks per frame, `AITickContext`
## caps rays and paths per frame, and `AITargetIndex.refresh_budgeted` caps how
## many bodies are re-read. At the Ultra enemy cap the whole director is a fixed
## slice of the frame rather than a curve that bends with the population.

## A body joined the fight. The demo hooks its readout off this.
signal roster_changed(alive: int)

## Ids the F3 overlay knows this director draws.
const CHANNEL_PATHS: StringName = &"ai_paths"
const CHANNEL_CONES: StringName = &"sight_cones"
const CHANNEL_COVER: StringName = &"cover_points"
const CHANNEL_STATE: StringName = &"alert_state"

## Awareness of the player at or above which a body counts as ALERT to them,
## rather than merely carrying a stale contact. `AIPerceptionTuning.suspicious_enter`
## is the same number and the same meaning: it is where the alert machine starts
## taking a contact seriously.
const PLAYER_ALERT_AWARENESS: float = 0.30

const STATE_COLORS: PackedColorArray = [
	Color(0.45, 0.44, 0.41, 0.55),
	Color(0.90, 0.72, 0.22, 0.85),
	Color(0.95, 0.52, 0.14, 0.90),
	Color(0.92, 0.20, 0.15, 0.95),
	Color(0.62, 0.28, 0.55, 0.90),
]

@export_group("Services")
## Baked cover for this arena. Without it agents fight in the open, which is
## correct behaviour and a visibly worse fight.
@export var cover_set: AICoverSet = null
## Global perception feel. Shared by every agent in the level.
@export var perception_tuning: AIPerceptionTuning = null
## Role quotas and squad doctrine.
@export var role_doctrine: AIRoles = null

@export_group("Budget")
## Bodies whose index row is re-read per frame. Zero means the whole table.
##
## At the arena's population this is also how fresh the broad-phase grid is: a
## row read every fourth frame has its position 66 ms old, which `AIM_SLACK`
## covers several times over. Raised from 24 with the cap, so a hundred bodies
## still get their whole table swept twice a second.
@export_range(0, 256, 1) var index_rows_per_frame: int = 48
## Agent ticks the scheduler will grant per frame, pushed onto `AITickScheduler`.
## THE ONE NUMBER THAT DECIDES THE AI'S FRAME COST. The scheduler's own default
## is 48, which was chosen for a 24-body arena; a hundred bodies in a compound
## small enough that all of them are NEAR the viewer need more or half the room
## thinks at a quarter rate.
@export_range(1, 512, 1) var agents_per_frame: int = 128
## Perception raycasts for the whole scene per frame, pushed onto the scheduler.
## A body asks for three and hands back what it did not spend.
@export_range(0, 512, 1) var ray_budget_per_frame: int = 256
## Path requests handed to the path service per frame, pushed onto the scheduler.
@export_range(0, 128, 1) var path_budget_per_frame: int = 16
## Seconds between squad ticks. Squad decisions move on a scale of seconds and
## running them per frame buys nothing.
@export_range(0.05, 2.0, 0.01) var squad_interval: float = 0.25
## Fire teams one faction may field. `AISquad.MAX_MEMBERS` is 8, so this times
## eight is how many bodies of one faction get roles, bounding overwatch and
## reload calls; the rest fight alone. See `_enlist`.
@export_range(1, 32, 1) var max_squads_per_faction: int = 8
## Cover points drawn by the debug channel, nearest the viewer first.
@export_range(8, 512, 8) var cover_draw_limit: int = 96

@export_group("Behaviour")
## 0 cowed, 1 rabid. Pushed onto every brain; the station's dial writes it.
@export_range(0.0, 1.0, 0.01) var aggression: float = 0.5:
	set = set_aggression

@export_group("Target priority")
## The five terms `AITargetIndex.contact_priority` scores a contact with, pushed
## into the index on `_ready`. They live here because the index is a `RefCounted`
## and cannot carry an `@export` of its own, and because this is the node a
## playtester actually has in front of them.
##
## Read the doc comment on `AITargetIndex.contact_priority` before turning any of
## them: the behaviour the user asked for — prioritise the player, but let two
## hostiles that have got close to each other while nobody is aware of the player
## fight each other — is the CROSSING of two curves, and these are the two curves.
##
## Extra weight the player is worth over an ordinary hostile at contact range.
@export_range(0.0, 24.0, 0.1) var player_bias: float = 7.0
## Metres at which that weight has fallen to half.
@export_range(2.0, 200.0, 0.5) var player_bias_range: float = 30.0
## Awareness at which the player bias is paid in full. This is the knob that
## decides how sure of you a body has to be before it stops brawling.
@export_range(0.05, 1.35, 0.01) var player_bias_awareness: float = 0.55
## Extra weight any contact is worth for being close. The brawl term.
@export_range(0.0, 12.0, 0.05) var proximity_bias: float = 2.2
## Metres at which the closeness weight has fallen to half.
@export_range(1.0, 60.0, 0.5) var proximity_range: float = 9.0
## Spend each body's FIRST perception raycast on the player, ahead of whatever
## else is in range. See `AITargetIndex.player_first` — this is the term that
## decides whether the five weights above ever get a contact to score, and in a
## test arena holding ninety bodies it is worth more than all of them.
@export var player_first: bool = true

@export_group("Hunt")
## Idle bodies close on the player instead of standing their post. See
## `ArenaBrain._prowl` for what this is for and what it deliberately does not do.
## Off puts the arena back to a static deployment.
@export var hunt_the_player: bool = true
## Metres from the player an idle body stops closing at. Below about six a
## hundred bodies stack on the dais ramp; above about fifteen the short-sighted
## half of the bestiary still cannot see you.
@export_range(1.0, 40.0, 0.5) var hunt_standoff: float = 9.0
## Metres a body moves its post each time it creeps. One walk, not a teleport.
@export_range(0.5, 30.0, 0.5) var hunt_step: float = 7.0
## Seconds a body stands still between creeps. This is the pacing knob: at zero
## the whole wave walks in as one line, and at ten it reads as a slow tide.
@export_range(0.0, 20.0, 0.1) var hunt_delay: float = 2.5

var _index: AITargetIndex = AITargetIndex.new()
var _scheduler: AITickScheduler = null
var _paths: AIPathService = null
var _cover: AICoverMap = AICoverMap.new()
var _ctx: AITickContext = AITickContext.new()
var _brains: Dictionary = {}
var _handles: Dictionary = {}
var _squads: Dictionary = {}
var _boards: Dictionary = {}
var _viewer: Node3D = null
var _squad_clock: float = 0.0
## The one player, cached. See `set_hunt_points`, which is the only writer.
var _hunt_point: Vector3 = Vector3.ZERO
## Every player's position, when there is more than one. Empty in single player,
## where `_hunt_point` is the whole answer and no distance has to be measured.
var _hunt_points: PackedVector3Array = PackedVector3Array()
## The player's own target row, so "is this body coming for me" is a comparison
## and not a guess. Zero until `register_target` is handed a PLAYER-faction node.
var _player_id: int = 0
var _player_target: AITarget = null
## Rounds that reached the player and what they carried. Counted off the player's
## own `AITarget.damaged`, which every path into the player — rifle, shotgun
## pellet, claw, blast — has to go through.
var _player_hits: int = 0
var _player_damage: float = 0.0
## One frame's census of the brain table, taken once and read by everybody. See
## `_take_census`.
var _census_alive: int = 0
var _census_engaged: int = 0
var _census_searching: int = 0
var _census_on_player: int = 0
var _census_on_rivals: int = 0
var _census_shots: int = 0
var _census_faction: PackedInt32Array = PackedInt32Array()
var _census_knows_player: int = 0
var _census_alert_to_player: int = 0
## Agent ids that have chosen the player at least once since the last clear.
var _ever_on_player: Dictionary = {}


func _ready() -> void:
	_scheduler = AITickScheduler.new()
	_scheduler.name = "Scheduler"
	_scheduler.agents_per_frame = agents_per_frame
	_scheduler.ray_budget_per_frame = ray_budget_per_frame
	_scheduler.path_budget_per_frame = path_budget_per_frame
	add_child(_scheduler)
	_paths = AIPathService.new()
	_paths.name = "Paths"
	add_child(_paths)
	_cover.bind(cover_set)
	_apply_priority()
	AINoiseBus.reset()
	_register_channels()


## Push the inspector's priority terms into the index. Called on `_ready` and
## safe to call again after a knob moves during a playtest.
func _apply_priority() -> void:
	_index.player_bias = player_bias
	_index.player_bias_range = player_bias_range
	_index.player_bias_awareness = player_bias_awareness
	_index.proximity_bias = proximity_bias
	_index.proximity_range = proximity_range
	_index.player_first = player_first


func _exit_tree() -> void:
	for id: StringName in [CHANNEL_PATHS, CHANNEL_CONES, CHANNEL_COVER, CHANNEL_STATE]:
		DebugHUD.remove_channel(id)


func _physics_process(delta: float) -> void:
	_index.refresh_budgeted(delta, index_rows_per_frame)
	_cover.advance(delta)
	var eye: Vector3 = Vector3.ZERO
	var forward: Vector3 = Vector3.FORWARD
	if _viewer != null and is_instance_valid(_viewer):
		eye = _viewer.global_position
		forward = -_viewer.global_basis.z
	_scheduler.begin_frame(delta, eye, forward)
	_scheduler.begin_context(_ctx)
	_ctx.targets = _index
	_ctx.space = get_viewport().world_3d.direct_space_state
	_ctx.cover = _cover
	for i: int in _scheduler.due_count():
		var brain: ArenaBrain = _scheduler.due_agent(i) as ArenaBrain
		if brain == null or not brain.is_alive():
			continue
		_ctx.delta = _scheduler.due_delta(i)
		_ctx.blackboard = _board_for(brain.faction)
		# Pushed on the tick rather than at adopt: the hunt point moves with the
		# player, and a body holding a stale one walks at where you used to be.
		brain.hunt_point = _nearest_hunt_point(brain.actor.global_position)
		brain.hunt_standoff = hunt_standoff
		brain.hunt_step = hunt_step if hunt_the_player else 0.0
		brain.hunt_delay = hunt_delay
		brain.tick(_ctx, _scheduler.due_kind(i) == AITickScheduler.KIND_CHEAP)
		_scheduler.set_agent_position(
			_handles[brain.actor.get_instance_id()], brain.actor.global_position
		)
	_paths.service(delta)
	_tick_squads(delta)
	_take_census()
	_publish_notes()


## Walk every brain ONCE a frame and cache what the readouts, the station and the
## acceptance harness all want.
##
## They used to walk it themselves. `_publish_notes` alone called `alive_count`
## and `summary`, and `summary` called `shots_fired` — three full sweeps of the
## brain table per frame before anybody outside asked a question, and the station
## asks two more from `ArenaController._physics_process`. At twenty-four bodies
## that is invisible. At ninety-six it is five hundred dictionary iterations a
## frame to produce numbers that cannot change between them.
func _take_census() -> void:
	_census_faction.resize(Factions.COUNT)
	_census_faction.fill(0)
	_census_alive = 0
	_census_engaged = 0
	_census_searching = 0
	_census_on_player = 0
	_census_on_rivals = 0
	_census_shots = 0
	_census_knows_player = 0
	_census_alert_to_player = 0
	for brain: ArenaBrain in _brains.values():
		if brain.actor != null and brain.actor.weapon != null:
			_census_shots += brain.actor.weapon.shots_fired
		if not brain.is_alive() or not _handles.has(brain.actor.get_instance_id()):
			continue
		_census_alive += 1
		if brain.faction >= 0 and brain.faction < Factions.COUNT:
			_census_faction[brain.faction] += 1
		var s: int = brain.state()
		if s == AIAlertness.State.ENGAGED or s == AIAlertness.State.LOSING:
			_census_engaged += 1
		elif s == AIAlertness.State.SEARCHING or s == AIAlertness.State.SUSPICIOUS:
			_census_searching += 1
		# What this body knows about the PLAYER specifically, separately from who it
		# chose. "Nobody is coming for me" has two completely different causes —
		# nobody has noticed me, or everybody has noticed me and prefers the rival
		# they are standing next to — and only one of them is the priority solve's
		# fault. Without this the two are indistinguishable from the outside.
		var aware: float = brain.memory.awareness_of(_player_id)
		if aware > 0.0:
			_census_knows_player += 1
			if aware >= PLAYER_ALERT_AWARENESS:
				_census_alert_to_player += 1
		if brain.focus_id < 0:
			continue
		if brain.focus_is_player:
			_census_on_player += 1
			# DISTINCT bodies, not an instantaneous count. "Twelve are coming for you
			# right now" and "sixty of the ninety-four have come for you at some
			# point in this fight" are different claims and the second is the one
			# that says whether the priority solve is working across a whole wave.
			_ever_on_player[brain.agent_id] = true
		else:
			_census_on_rivals += 1


## Whoever the level-of-detail clock measures distance from. The player's eye in
## play, the freecam when it is up.
func register_viewer(node: Node3D) -> void:
	_viewer = node


## Where idle bodies drift: every player in the compound. The demo writes the live
## positions here every frame; anything else — a zone marker, the middle of the
## floor — would work and would read as a patrol instead of a hunt.
##
## A LIST AND NOT A POINT, because there can be four of them. An idle body creeps
## toward the NEAREST, which is the only sensible reading of "hunt the player" once
## the compound holds more than one: a single shared point would send the whole wave
## past three people to converge on a midpoint nobody is standing on.
func set_hunt_points(points: PackedVector3Array) -> void:
	_hunt_points = points
	if points.size() == 1:
		_hunt_point = points[0]


## Put a target into the world's table. The player calls this for itself; the
## spawner's `spawned` signal calls it for everything else.
##
## A PLAYER-faction target is also remembered by row and hooked for damage, so
## `focus_counts` and `player_hits` can answer the two questions this demo is
## for — how many of them are coming for you, and are their rounds arriving.
##
## `own` FALSE is the other three people in a networked compound. They are targets
## in every way that matters to a brain — `AITargetIndex` flags a row as a player
## off `AITarget.faction`, so `player_first`, `player_bias` and the whole priority
## solve treat them exactly as they treat you. What they are not is the body THIS
## machine is looking through, and `focus_counts`, `player_hits` and the awareness
## census all answer "is the wave coming for ME". Letting whoever registered last
## claim `_player_id` would quietly re-aim every one of those readouts at somebody
## else's screen.
func register_target(t: AITarget, own: bool = true) -> int:
	var id: int = _index.add(t)
	if t != null and t.faction == Factions.PLAYER and own:
		_player_id = id
		_player_target = t
		if not t.damaged.is_connected(_on_player_damaged):
			t.damaged.connect(_on_player_damaged)
	return id


func unregister_target(t: AITarget) -> void:
	_index.remove(t)


## Give a spawned body a brain, a squad and a place to stand. Returns the brain so
## a caller that wants to watch one agent can hold it.
##
## Brains are keyed by the actor's instance id, which survives the spawner
## recycling a corpse; the AI's own `agent_id` is the target table's id, which does
## not, because a body that left the table and came back is a new contact to
## everything that remembered the old one.
func adopt(actor: EnemyActor, profile: AISpeciesProfile, post: Vector3) -> ArenaBrain:
	if actor == null or profile == null:
		return null
	var target: AITarget = actor.target()
	if target == null:
		push_error("ArenaDirector: '%s' has no AITarget; it cannot be perceived." % actor.name)
		return null
	var key: int = actor.get_instance_id()
	var id: int = _index.add(target)
	var brain: ArenaBrain = _brains.get(key, null)
	if brain == null:
		brain = ArenaBrain.new()
		_brains[key] = brain
	brain.bind(actor, profile, actor.faction, id, perception_tuning)
	brain.post = post
	brain.set_aggression(aggression)
	_paths.register(id, brain.navigator)
	brain.squad = _enlist(actor.faction, id, profile)
	if _handles.has(key):
		_scheduler.remove_agent(_handles[key])
	_handles[key] = _scheduler.add_agent(brain, actor.global_position)
	if not actor.has_meta(&"arena_wired"):
		actor.set_meta(&"arena_wired", true)
		actor.hurt.connect(_on_actor_hurt.bind(brain))
		actor.fired.connect(_on_actor_fired.bind(brain))
	_take_census()
	roster_changed.emit(alive_count())
	return brain


## Take a body back out. Called when the spawner recycles it, and on a full clear.
func release(actor: EnemyActor) -> void:
	var key: int = actor.get_instance_id()
	var brain: ArenaBrain = _brains.get(key, null)
	if brain == null:
		return
	if brain.squad != null:
		brain.squad.remove_member(brain.agent_id, not actor.alive)
		brain.squad = null
	if _handles.has(key):
		_scheduler.remove_agent(_handles[key])
		_handles.erase(key)
	_paths.unregister(brain.agent_id)
	_index.remove(actor.target())
	_take_census()
	roster_changed.emit(alive_count())


## Empty the director without touching the bodies. The demo's CLEAR lever calls
## this after the spawner has parked everything.
func clear_all() -> void:
	_scheduler.clear()
	_handles.clear()
	_brains.clear()
	_squads.clear()
	_boards.clear()
	_paths.flush()
	_player_hits = 0
	_ever_on_player.clear()
	_player_damage = 0.0
	AINoiseBus.reset()
	roster_changed.emit(0)


func alive_count() -> int:
	return _census_alive


func set_aggression(value: float) -> void:
	aggression = clampf(value, 0.0, 1.0)
	for brain: ArenaBrain in _brains.values():
		brain.set_aggression(aggression)


## A one-line summary of what the AI is doing, for the arena's own readout.
##
## `on you` is the count this demo exists to publish: bodies whose own priority
## solve picked the PLAYER over everything else in the room. Without it "engaged"
## is ambiguous at a hundred bodies — a compound full of factions shooting each
## other reads exactly the same as one coming for you.
func summary() -> String:
	return (
		"%d engaged  %d hunting  %d on you  %d brawling  %d rounds  %d hits on you"
		% [
			_census_engaged,
			_census_searching,
			_census_on_player,
			_census_on_rivals,
			_census_shots,
			_player_hits,
		]
	)


## How the room has divided itself: `x` bodies whose chosen contact is the
## player, `y` bodies fighting somebody else. Read off `ArenaBrain.focus_is_player`,
## which is written by the priority solve itself, so this cannot drift out of step
## with what the bodies are actually doing.
func focus_counts() -> Vector2i:
	return Vector2i(_census_on_player, _census_on_rivals)


## Distinct bodies that have chosen the player at least once since the last clear.
## The instantaneous count answers "how many are on me now"; this answers "did the
## wave come for me", which is the question the priority solve is judged on.
func ever_on_player() -> int:
	return _ever_on_player.size()


## `x` live bodies carrying ANY contact on the player, `y` of them alert enough to
## act on it. Read this before turning a priority knob: a low "coming for you"
## with a low `x` is a perception problem and no weight will fix it, and with a
## high `x` it is a scoring problem and the weights are exactly the fix.
func player_awareness_counts() -> Vector2i:
	return Vector2i(_census_knows_player, _census_alert_to_player)


## Rounds this director's bodies have put downrange since the last clear.
func shots_fired() -> int:
	return _census_shots


## Hits that reached the player and the damage they carried, since the last
## clear. Counted off the player's own `AITarget.damaged`, which is downstream of
## every way an agent can hurt anybody — a traced pellet, a claw, a blast — so a
## non-zero count is proof the rounds ARRIVED and not merely that they left.
func player_hits() -> int:
	return _player_hits


func player_damage() -> float:
	return _player_damage


## Live bodies of each faction, indexed by faction id. The faction-mix readout,
## and what tells a three-way brawl from a one-sided one.
func faction_counts() -> PackedInt32Array:
	return _census_faction


## The player this body should be creeping toward. One comparison per player per
## agent tick, and in single player the list is empty and it is not even that.
func _nearest_hunt_point(from: Vector3) -> Vector3:
	if _hunt_points.size() < 2:
		return _hunt_point
	var best: Vector3 = _hunt_points[0]
	var best_d: float = from.distance_squared_to(best)
	for i: int in range(1, _hunt_points.size()):
		var d: float = from.distance_squared_to(_hunt_points[i])
		if d < best_d:
			best_d = d
			best = _hunt_points[i]
	return best


func _on_player_damaged(amount: float, _from: Vector3, _attacker: Node) -> void:
	_player_hits += 1
	_player_damage += amount


## One line per live body: what it is, what it thinks, where it is going. The
## arena's verify harness reports this, and it is the first thing worth reading
## when a wave stands in the gateway doing nothing.
func describe_agents() -> PackedStringArray:
	var out := PackedStringArray()
	(
		out
		. append(
			(
				"targets %d  player id %d %s  space %s  due %d"
				% [
					_index.size(),
					_player_id,
					(
						"live"
						if _player_target != null and is_instance_valid(_player_target)
						else "MISSING"
					),
					"bound" if _ctx.space != null else "NULL",
					_scheduler.due_count(),
				]
			)
		)
	)
	for brain: ArenaBrain in _brains.values():
		if not brain.is_alive():
			continue
		var slot: int = brain.memory.best_slot()
		(
			out
			. append(
				(
					"%-4s %-9s %-10s at %.0v  aware %.2f  seen %d  focus %d %-6s pri %.2f  los %s"
					% [
						Factions.mark(brain.faction),
						brain.profile.species_id,
						AIAlertness.STATE_NAMES[brain.state()],
						brain.actor.global_position,
						0.0 if slot < 0 else brain.memory.slot_awareness(slot),
						brain.perception.visible_ids.size(),
						brain.focus_id,
						"PLAYER" if brain.focus_is_player else "rival",
						brain.focus_score,
						"y" if brain.has_los else "n",
					]
				)
			)
		)
	return out


func _tick_squads(delta: float) -> void:
	_squad_clock += delta
	if _squad_clock < squad_interval:
		return
	var step: float = _squad_clock
	_squad_clock = 0.0
	for teams: Array in _squads.values():
		for squad: AISquad in teams:
			squad.tick(step)
	for board: AIBlackboard in _boards.values():
		board.decay(step, 0.35)


## Find this body a fire team. `AISquad.MAX_MEMBERS` is 8 and it is a hard
## constant, so ONE squad per faction — which is what this director used to make
## — silently drops every body past the eighth into `squad == null`. That is not
## a crash and it is not even obviously wrong (a lone body always has permission
## to advance), but it means role assignment, bounding overwatch and the reload
## calls stop happening for everybody after the first eight. At a cap of eight
## bodies nobody noticed; at a hundred it is 92% of the room.
##
## So a faction gets as many squads as it needs, up to `max_squads_per_faction`.
## Past that a body genuinely does fight alone, and that is a bounded, stated
## fallback rather than an accident of a constant nobody read.
func _enlist(squad_faction: int, agent_id: int, profile: AISpeciesProfile) -> AISquad:
	var teams: Array = _squads.get(squad_faction, [])
	for squad: AISquad in teams:
		if squad.add_member(agent_id, profile) >= 0:
			return squad
	if teams.size() >= max_squads_per_faction:
		return null
	var fresh := AISquad.new(
		StringName("arena_%d_%d" % [squad_faction, teams.size()]),
		squad_faction,
		role_doctrine,
		_board_for(squad_faction)
	)
	teams.append(fresh)
	_squads[squad_faction] = teams
	return fresh if fresh.add_member(agent_id, profile) >= 0 else null


func _board_for(board_faction: int) -> AIBlackboard:
	var board: AIBlackboard = _boards.get(board_faction, null)
	if board != null:
		return board
	board = AIBlackboard.new()
	_boards[board_faction] = board
	return board


func _on_actor_hurt(_amount: float, _remaining: float, from: Vector3, brain: ArenaBrain) -> void:
	brain.on_hurt(from)


## A body fired: the shot is a noise every hostile ear in range gets to react to.
## Without this a firefight on the far side of the compound never pulls anybody.
func _on_actor_fired(
	origin: Vector3, _dir: Vector3, _hit_position: Vector3, _hit: Object, brain: ArenaBrain
) -> void:
	AINoiseBus.emit_gunshot(origin, 900.0, brain.faction, brain.agent_id)


func _publish_notes() -> void:
	DebugHUD.note(&"arena_ai", "ai  %d agents  %s" % [alive_count(), summary()])
	DebugHUD.note(
		&"arena_budget",
		(
			"ai budget  %d due  %d queued paths  cover %d"
			% [
				_scheduler.due_count(),
				_paths.queued(),
				0 if cover_set == null else cover_set.size()
			]
		)
	)


func _register_channels() -> void:
	DebugHUD.add_channel(CHANNEL_PATHS, "ai paths", _draw_paths)
	DebugHUD.add_channel(CHANNEL_CONES, "sight cones", _draw_cones)
	DebugHUD.add_channel(CHANNEL_COVER, "cover points", _draw_cover)
	DebugHUD.add_channel(CHANNEL_STATE, "alert state", _draw_state)


## Turn every debug channel this director owns on or off in one call. The AI
## DEBUG lever on the control station is wired straight to this.
func set_debug_draw(on: bool) -> void:
	for id: StringName in [CHANNEL_PATHS, CHANNEL_CONES, CHANNEL_COVER, CHANNEL_STATE]:
		DebugHUD.set_channel_enabled(id, on)


func _draw_paths(target: UiDebugDraw) -> void:
	for brain: ArenaBrain in _brains.values():
		if not brain.is_alive():
			continue
		var points: PackedVector3Array = brain.navigator.path_points()
		if points.size() < 2:
			continue
		var lifted := PackedVector3Array()
		lifted.resize(points.size())
		for i: int in points.size():
			lifted[i] = points[i] + Vector3(0.0, 0.12, 0.0)
		target.polyline(lifted, STATE_COLORS[brain.state()])


func _draw_cones(target: UiDebugDraw) -> void:
	for brain: ArenaBrain in _brains.values():
		if not brain.is_alive():
			continue
		var eye: Vector3 = brain.actor.global_position + Vector3(0.0, brain.profile.eye_height, 0.0)
		var forward: Vector3 = brain.facing()
		var reach: float = minf(brain.perception.sight_far, 30.0)
		var half: float = acos(clampf(brain.perception.cone_cos, -1.0, 1.0))
		target.cone(eye, forward, half, reach, STATE_COLORS[brain.state()])


func _draw_cover(target: UiDebugDraw) -> void:
	if cover_set == null or _viewer == null or not is_instance_valid(_viewer):
		return
	var here: Vector3 = _viewer.global_position
	var drawn: int = 0
	for i: int in cover_set.size():
		if drawn >= cover_draw_limit:
			break
		var p: Vector3 = cover_set.positions[i]
		if p.distance_squared_to(here) > 3600.0:
			continue
		drawn += 1
		var lift: Vector3 = p + Vector3(0.0, 0.06, 0.0)
		target.ring(lift, Vector3.RIGHT, Vector3.BACK, 0.35, Color(0.30, 0.72, 0.86, 0.7))
		target.line(lift, lift + cover_set.normals[i] * 0.8, Color(0.30, 0.72, 0.86, 0.5))


func _draw_state(target: UiDebugDraw) -> void:
	for brain: ArenaBrain in _brains.values():
		if not brain.is_alive():
			continue
		var head: Vector3 = (
			brain.actor.global_position + Vector3(0.0, brain.profile.height + 0.4, 0.0)
		)
		var color: Color = STATE_COLORS[brain.state()]
		target.cross_mark(head, 0.34, color)
		if brain.focus_id >= 0:
			target.line(head, brain.focus_position, Color(color, 0.35))
