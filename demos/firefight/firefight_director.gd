class_name FirefightDirector
extends Node3D
## The war. Three factions, seven pieces of ground, and a body economy tuned so
## that neither a stalemate nor a wipe is reachable from here.
##
## Everything below the squad is production AI running unmodified: `AIPerception`
## looks, `AICombat` shoots, `AINavigator` walks, `AISquad` decides who crosses
## the street. This node is only the layer above that — who exists, whose squad
## they are in, and which zone that squad has been told to take. It is the same
## shape as `res://systems/ai/verify/faction_war_harness.gd`, which proves the
## territory rules over fifteen simulated minutes without ever drawing a frame;
## the difference here is that the bodies are real and the shots are traced.
##
## THE TWO FAILURE MODES, AND WHAT STOPS THEM.
## A stalemate is when the map stops changing hands. It is prevented by the
## ledger's underdog term — pressure applied by a faction holding little ground
## counts for more — and by objective scoring that pays for probing a zone whose
## owner is not standing on it.
## A wipe is when one faction runs out of bodies. It is prevented by the
## reinforcement rate scaling with a faction's DEFICIT as well as its holdings.
## Without that second term the leader simply fields three times the rifles.
## Neither rule is a clamp on the outcome; both are pressures on the inputs.
##
## PERFORMANCE. Every per-frame cost here is bounded by a constant, not by the
## population. The tick scheduler hands out a fixed number of thinks; the path
## service a fixed number of queries; the target index refreshes a fixed number
## of rows; the ray pool is fixed. Adding forty more bodies makes each of them
## think less often. It does not make the frame longer.
##
## MULTIPLAYER: THIS WHOLE FILE IS THE HOST'S AND ON A GUEST IT DOES NOTHING.
## `_physics_process` and `_on_spawned` are the only two ways anything in here
## happens, and both stop at `NetGame.is_authority()` — so no think, path,
## perception, enrolment, spawn, reinforcement or ledger push occurs anywhere but
## on the host. A guest's bodies are puppets driven by `FirefightWarLink`.
##
## THE CHECK IS PER FRAME AND NOT LATCHED IN `_ready`, and that is not caution.
## `NetGame` applies `--host` / `--join` a frame AFTER the main scene is up, so a
## build launched straight into this demo reads `is_authority()` as true in
## `_ready` and false a moment later. MEASURED with it latched: a guest ran its
## own war of 71 bodies underneath the 66 it was being sent.
##
## Single player is untouched — `is_authority()` is true with no session at all.

## Emitted on the slow tick with the current standings, for the diegetic banners
## and the debug overlay. `owned` is indexed by `Factions.F`.
signal standings_changed(owned: PackedInt32Array, bodies: PackedInt32Array)

## Callouts kept in the rolling transcript the overlay prints.
const CALL_LOG_SIZE: int = 6

@export_group("Wiring")
## `AITerritoryZone` nodes this director fights over. They register themselves
## with the ledger; the director only needs to know which ones are its business.
@export var zone_group: StringName = &"firefight_zone"
## One `EnemySpawner` per faction, in `Factions.F` order.
@export var spawner_paths: Array[NodePath] = []
@export var scheduler_path: NodePath = NodePath("Scheduler")
@export var path_service_path: NodePath = NodePath("Paths")
## Baked cover for this arena. Without it bodies fight in the open, which works
## but reads as a parade.
@export var cover_set: AICoverSet = null
## Perception tuning shared by every body.
@export var perception_tuning: AIPerceptionTuning = null
## Role doctrine. Shared — it is read-only at runtime.
@export var doctrine: AIRoles = null

@export_group("Population")
## Bodies each faction tries to keep standing. Three squads of eight is the
## ceiling `AISquad.MAX_MEMBERS` allows; below about twelve a faction cannot hold
## two zones at once and the map degenerates into a chase.
@export_range(6, 24, 1) var target_population: int = 21
@export_range(1, 4, 1) var squads_per_faction: int = 3
## Seconds between reinforcement waves at neutral rate. The rate itself is scaled
## by holdings and by how badly the faction has been hurt.
##
## Sized against the rate bodies actually die at rather than against a feeling.
## A faction knocked from twenty-two to five — which is what the opening exchange
## does to whoever loses it — has to be back on its feet in tens of seconds, not
## in the two and a half minutes the old 14 s / 2 bodies took. Nothing here is a
## drip feed at full strength: `_release` stops at `target_population`, so a
## faction that is whole spends its wave on nothing.
@export_range(4.0, 60.0, 0.5) var reinforce_period: float = 9.0
## Bodies released per wave at full strength. A hurt faction gets more.
@export_range(1, 6, 1) var wave_size: int = 3
## Metres a reinforcement point has to be clear of hostiles before a wave will
## land on it. Below this the ground counts as contested and the wave falls back
## to the next holding behind it. See `_spawn_transform`.
@export_range(4.0, 80.0, 1.0) var muster_clearance: float = 26.0
## Fraction of `target_population` each faction is given the moment the map is
## navigable. Without an opening deployment the demo takes a minute to become a
## war, and the first thing a spectator sees is an empty valley.
@export_range(0.0, 1.0, 0.05) var opening_fraction: float = 1.0
## Deterministic seed for species draw, spawn scatter and picket offsets.
@export_range(1, 2147483647, 1) var seed_value: int = 0x5CA71E

@export_group("Opening")
## Deploy the opening garrisons on their approaches to the contested ground
## instead of at home. Off is the cold start: three garrisons in three yards and
## a minute of walking before anything happens.
@export var opening_in_contact: bool = true
## Nearest the contested centre an opening body is placed, in metres. Well inside
## the capture radius, so the ground is disputed from the first tick.
@export_range(2.0, 60.0, 0.5) var front_inner: float = 5.0
## Furthest back an opening body is placed. The depth of each faction's line, and
## with it the radius of the whole battle: sixty-six bodies inside thirty metres
## is one every forty square metres, which is dense enough to read as three sides
## meeting and open enough that a rifle has a lane. Pulled tighter, the corridor
## test in `AICombat` refuses most shots because a friendly is in the way.
@export_range(4.0, 90.0, 0.5) var front_outer: float = 30.0
## Width of a faction's arc of the front, in degrees. Three of these plus the
## gaps between them make the ring; at 108 the seams are about 12 degrees wide,
## which is close enough that the flanks are in contact at once.
@export_range(20.0, 120.0, 1.0) var front_arc_degrees: float = 108.0
## Bias on the radial draw. Below 1 crowds the line forward onto the objective;
## above 1 holds it back. Just under 1 spreads a faction near-evenly over the
## depth of its line, which is what fills the ground between the spectator and
## the objective; at 0.62 two thirds of every faction crowded onto the centre and
## the near third of the frame was empty sand.
@export_range(0.2, 3.0, 0.01) var front_forward_bias: float = 0.88

@export_group("Command")
## Seconds between squad ticks. Everything a squad decides moves on a scale of
## seconds; running it per frame would cost sixty times as much to reach the same
## answer.
@export_range(0.05, 1.0, 0.01) var command_period: float = 0.25
## Seconds a squad keeps an objective before it is allowed to reconsider.
##
## This has to be longer than it takes a squad to WALK to the objective, and at
## the pace these bodies actually move a 48 m leg is about thirty-five seconds.
## At the eleven seconds this was set to first, every squad reconsidered three
## times per crossing — and because the objective score divides by how many of
## the faction's own bodies are already committed to a zone, a squad that had
## just committed to one always found somewhere else looked better. Three
## factions walked back and forth between two objectives for six minutes and
## never arrived at either.
@export_range(2.0, 90.0, 0.5) var retarget_period: float = 30.0
## Metres from the objective at which a squad counts as having arrived, and so is
## free to be given a new one.
@export_range(4.0, 60.0, 0.5) var objective_arrival: float = 18.0
## Seconds a squad is allowed to sit on its rally point before it is stood back
## up whether or not its losses have been made good. See `_restore`.
@export_range(2.0, 120.0, 0.5) var regroup_patience: float = 25.0
## Squads a faction may have sitting on ground it already owns. Everyone else has
## to be pointed at somebody else's.
##
## Without a cap the objective score turns every faction into a garrison the
## moment its own ground is touched: a zone you already hold and that is being
## contested scores 1.5 with no distance penalty, because you are standing on it,
## and an enemy zone forty-eight metres away with a full garrison on it scores
## 0.35 times aggression over 1.74 of distance. Measured with the cap off: all
## three factions parked on their own capitals, the ledger sat at 1/4/2 for four
## minutes, and the contested middle — the ground the whole map is arranged
## around — was empty concrete.
@export_range(0, 4, 1) var max_defending_squads: int = 1
## The director's thumb on how hard bodies standing in a zone push its ledger.
@export_range(0.1, 4.0, 0.05) var pressure_scale: float = 1.0
## How much a zone's score is cut per body of this faction already committed to it:
## the spread-out term, deciding whether a faction attacks three pieces of ground
## with seven bodies each or one with twenty-one. IT WAS 0.45, WHICH IS TOO MUCH
## NOW THE LEDGER IS A CONTEST OF PRESENCE — eight bodies committed cut a zone to
## a fifth, so every squad went where its own faction was not, and against a
## garrison at its ceiling an attacker needs about twice the bodies on the ground.
## Zero is the other failure: the faction converges and six zones are unattended.
## Swept, five 150 s trials each: 0.45 gave 2/2/4/5/5 flips over two or three
## zones, 0.18 gave 2/2/2/3/4, and 0.06 gives 3/5/6/7/8 over three or four.
@export_range(0.0, 2.0, 0.01) var objective_crowding: float = 0.06
## Contact confidence bled off the faction blackboard per second.
@export_range(0.0, 0.5, 0.005) var contact_decay: float = 0.06

@export_group("Budget")
## Target index rows re-read per physics frame. At 70 bodies this is a full sweep
## every three frames, which is finer than any agent's tick rate needs.
@export_range(4, 256, 1) var index_rows_per_frame: int = 24
## Broad-phase cell size for the target grid, in metres. Roughly the median
## sight range divides the arena into useful buckets.
@export_range(4.0, 64.0, 1.0) var target_cell_size: float = 18.0

@export_group("Instrumentation")
## Seconds between printing `AICoverMap`'s rejection ledger to the log. Zero is
## off, which is the shipping setting — the same line is on the F3 overlay every
## command tick and costs nothing there.
##
## Turn it up when the cover meter reads low and you need to know WHY: the line
## says how many queries were asked, how many were answered, and which of the
## scoring gates ate the candidates. `tools/watch.gd` copies stdout into its
## trace, so a run with this set to a few seconds leaves a time series behind.
@export_range(0.0, 60.0, 0.5) var cover_report_period: float = 0.0

var _targets: AITargetIndex = AITargetIndex.new()
var _ctx: AITickContext = AITickContext.new()
var _cover: AICoverMap = AICoverMap.new()
var _boards: Array[AIBlackboard] = []
var _squads: Array[AISquad] = []
var _spawners: Array[EnemySpawner] = []
var _agents: Array[FirefightAgent] = []
var _by_actor: Dictionary = {}
var _scheduler: AITickScheduler = null
var _paths: AIPathService = null
var _rng: XorShift32 = null
var _ledger: Factions.Territory = null
var _home: PackedInt32Array = PackedInt32Array()
var _retarget: PackedFloat32Array = PackedFloat32Array()
## Seconds each squad has spent broken. Parallel to `_retarget`.
var _broken: PackedFloat32Array = PackedFloat32Array()
var _reinforce: PackedFloat32Array = PackedFloat32Array()
var _command_accum: float = 0.0
var _viewer_pos: Vector3 = Vector3.ZERO
var _viewer_fwd: Vector3 = Vector3.FORWARD
var _serial: int = 0
var _opening_pending: bool = true
## Agents that died or were pooled away during the tick, retired after it.
var _retire_queue: Array[FirefightAgent] = []
## Callouts made since the demo started, indexed by `AIComms` kind. Squads talk
## through `AIComms` whether or not anybody is listening to the local signal; this
## is the only place the talking is COUNTED, and without it "do callouts propagate"
## is unanswerable from outside the AI module.
var _calls: PackedInt32Array = PackedInt32Array()
## The last few things said, newest last, for the overlay note.
var _call_log: PackedStringArray = PackedStringArray()
## Seconds until the next cover-ledger line is printed. Idle at zero period.
var _cover_report: float = 0.0


func _ready() -> void:
	_rng = XorShift32.new(seed_value)
	_ledger = Factions.territory
	_targets.grid.cell_size = target_cell_size
	_cover.bind(cover_set)
	_scheduler = get_node_or_null(scheduler_path) as AITickScheduler
	_paths = get_node_or_null(path_service_path) as AIPathService
	if _scheduler == null or _paths == null:
		push_error("FirefightDirector: scheduler_path and path_service_path must resolve.")
		set_physics_process(false)
		return
	if doctrine == null:
		doctrine = AIRoles.new()
	_collect_zones()
	_collect_spawners()
	_build_commands()
	_ctx.targets = _targets
	_ctx.cover = _cover
	set_physics_process(true)


func _exit_tree() -> void:
	_retire_queue.clear()
	_paths.flush()
	_agents.clear()
	_by_actor.clear()


func _physics_process(delta: float) -> void:
	if not NetGame.is_authority():
		return
	if _opening_pending:
		_try_opening()
	_read_viewer()
	_targets.refresh_budgeted(delta, index_rows_per_frame)
	_cover.advance(delta)
	_ctx.space = get_world_3d().direct_space_state

	for a: FirefightAgent in _agents:
		if a.handle >= 0:
			_scheduler.set_agent_position(a.handle, a.position())
	_scheduler.begin_frame(delta, _viewer_pos, _viewer_fwd)
	_scheduler.begin_context(_ctx)
	for d: int in _scheduler.due_count():
		var agent := _scheduler.due_agent(d) as FirefightAgent
		if agent == null or not agent.is_alive():
			continue
		_ctx.blackboard = _boards[agent.faction]
		agent.think(_ctx, _scheduler.due_delta(d), _scheduler.due_kind(d), _cover)
	_drain_retirements()
	_paths.service(delta)

	_command_accum += delta
	if _command_accum >= command_period:
		_command(_command_accum)
		_command_accum = 0.0


## Bodies of a faction standing. Zero on a guest, which enrols none: the counts
## there come off the wire, through `FirefightWarLink.standings`.
func body_count(faction: int) -> int:
	var n: int = 0
	for a: FirefightAgent in _agents:
		if a.is_alive() and a.faction == faction:
			n += 1
	return n


## Total live bodies across all three factions.
func live_count() -> int:
	var n: int = 0
	for a: FirefightAgent in _agents:
		if a.is_alive():
			n += 1
	return n


func zones_owned(faction: int) -> int:
	var n: int = 0
	for i: int in _ledger.count():
		if _ledger.owner_at(i) == faction:
			n += 1
	return n


## The shared perception table. Anything that needs to ask "what is standing near
## here, hostile to whom" reads it through this rather than keeping its own.
func targets() -> AITargetIndex:
	return _targets


## Callouts made since the demo started, indexed by `AIComms` kind. A watcher
## reads this to tell a silent war from a talking one.
func callouts() -> PackedInt32Array:
	return _calls


## The last few things said, oldest first. Formatted for a single overlay line.
func callout_log() -> PackedStringArray:
	return _call_log


## Vantage and cover leases currently held across the whole battle, as
## `[vantage, cover]`. The acceptance test for "ranged units seek vantage".
func cover_claims() -> Vector2i:
	return _cover.claims_held()


## Why the cover map has been answering the way it has, since the level loaded.
## Empty until something has asked it for a position. See `AICoverMap.R_NAMES`.
func cover_report() -> String:
	return _cover.rejection_line()


func scheduler() -> AITickScheduler:
	return _scheduler


func path_service() -> AIPathService:
	return _paths


## Where the war is loudest right now: the centroid of the most contested zone,
## weighted by how many bodies are near it. The spectator's "follow the fight"
## marker steers off this.
func hotspot() -> Vector3:
	var best: Vector3 = global_position
	var best_score: float = -1.0
	for i: int in _ledger.count():
		var c: Vector3 = _ledger.center_at(i)
		var factions_present: float = 0.0
		for f: int in Factions.COUNT:
			factions_present += minf(_ledger.pressure_at(i, f) * 4.0, 1.0)
		var bodies: float = 0.0
		for a: FirefightAgent in _agents:
			if a.is_alive() and a.position().distance_squared_to(c) < 900.0:
				bodies += 1.0
		var score: float = factions_present * (1.0 + bodies)
		if score > best_score:
			best_score = score
			best = c
	return best


# ------------------------------------------------------------------ setup


## Find each faction's capital, and check the zones actually registered.
##
## `AITerritoryZone` registers itself with the ledger on `_ready`, and `_ready`
## runs children before parents — so by the time this does, every zone in the
## scene is already in the ledger and the home each faction started with is
## readable from it. The group walk is here to catch the case where that ordering
## assumption is wrong, because the symptom otherwise is a war with no capitals
## and no obvious cause.
func _collect_zones() -> void:
	var registered: int = get_tree().get_nodes_in_group(zone_group).size()
	if registered == 0 or _ledger.count() == 0:
		push_error(
			(
				"FirefightDirector: %d zones in group '%s' but %d in the ledger."
				% [registered, zone_group, _ledger.count()]
			)
		)
	_home.resize(Factions.COUNT)
	for f: int in Factions.COUNT:
		_home[f] = -1
	for i: int in _ledger.count():
		var owner_faction: int = _ledger.home_at(i)
		if owner_faction >= 0 and owner_faction < Factions.COUNT and _home[owner_faction] < 0:
			_home[owner_faction] = i


func _collect_spawners() -> void:
	_spawners.resize(Factions.COUNT)
	for f: int in mini(spawner_paths.size(), Factions.COUNT):
		var s := get_node_or_null(spawner_paths[f]) as EnemySpawner
		_spawners[f] = s
		if s == null:
			push_error("FirefightDirector: spawner %d does not resolve to an EnemySpawner." % f)
			continue
		s.spawned.connect(_on_spawned)
		s.despawned.connect(_on_despawned)


func _build_commands() -> void:
	_calls.resize(AIComms.KIND_COUNT)
	_boards.resize(Factions.COUNT)
	_retarget.resize(Factions.COUNT * squads_per_faction)
	_broken.resize(Factions.COUNT * squads_per_faction)
	_reinforce.resize(Factions.COUNT)
	for f: int in Factions.COUNT:
		_boards[f] = AIBlackboard.new()
		_reinforce[f] = _rng.next() * reinforce_period
		var home: Vector3 = _home_point(f)
		for s: int in squads_per_faction:
			var id := StringName("%s_%d" % [Factions.NAMES[f], s])
			var squad := AISquad.new(id, f, doctrine, _boards[f])
			# No objective, deliberately. Handing a squad its own capital to start
			# with puts it straight into HOLD, and it then sits there until the
			# retarget timer expires — up to half a minute of three factions
			# standing in their own yards before the war begins. An empty
			# objective means `_may_retarget` grants one on the first command
			# tick, and the small stagger keeps all nine squads from choosing on
			# the same tick and picking the same ground.
			squad.set_objective(&"", home, home)
			squad.callout_made.connect(_on_callout.bind(id))
			_squads.append(squad)
			_retarget[f * squads_per_faction + s] = _rng.next() * command_period * 4.0


func _home_point(faction: int) -> Vector3:
	var i: int = _home[faction]
	return global_position if i < 0 else _ledger.center_at(i)


func _squad_at(faction: int, s: int) -> AISquad:
	return _squads[faction * squads_per_faction + s]


# ------------------------------------------------------------- slow command


func _command(delta: float) -> void:
	for f: int in Factions.COUNT:
		_boards[f].strength = body_count(f)
		for s: int in squads_per_faction:
			var squad: AISquad = _squad_at(f, s)
			var k: int = f * squads_per_faction + s
			_restore(f, squad, k, delta)
			_retarget[k] -= delta
			if _may_retarget(squad, _retarget[k]):
				_retarget[k] = retarget_period
				_choose_objective(f, squad, _defending(f, s) < max_defending_squads)
			squad.tick(delta)
		_boards[f].decay(delta, contact_decay)
		_boards[f].interest.flush(f, pressure_scale)
	_reinforce_step(delta)
	_publish(delta)


## Stand a squad back up once its losses have been made good, or once it has sat
## on its rally point long enough.
##
## THIS IS WHY THE WAR USED TO STOP. `AISquad` measures how broken it is against
## the most bodies it has EVER held, and that peak ratchets up with every
## replacement the director sends — `add_member` raises it by the running loss
## count. So a squad that has taken and replaced ten bodies reads as two thirds
## destroyed while standing at full strength, drops into REGROUP, and
## `FirefightAgent._choose_goal` then walks every one of its members to the rally
## point and leaves them there. Measured over six minutes on the old build: SCAV
## parked all twenty-two bodies inside eight metres of its own capital by t=140 s
## and CHOIR did the same, the ledger froze at 1/4/2, and the last two minutes of
## the run produced two kills between sixty-six armed bodies.
##
## `AISquad.reform` is the documented cure and its own comment says the director
## owns the call — but the only place that called it was `_join_squad`, which
## fires on ROUT only and only when a body is actually joining, and a full squad
## in REGROUP is neither. This is the director making the call it was supposed to
## make. It is not a clamp on the outcome: a squad still routs, still falls back,
## and still holds its rally while it is short of bodies. It just cannot stay
## broken once it is whole again.
func _restore(faction: int, squad: AISquad, k: int, delta: float) -> void:
	var state: int = squad.state()
	if state != AISquad.State.REGROUP and state != AISquad.State.ROUT:
		_broken[k] = 0.0
		return
	_broken[k] += delta
	if squad.size() < _establishment() and _broken[k] < regroup_patience:
		return
	_broken[k] = 0.0
	squad.reform(_rally_for(faction, squad.centroid()))


## Bodies one squad is entitled to: the faction's target population split evenly,
## capped at what `AISquad` will hold. A squad back at this strength has had its
## casualties replaced and has no business still lying down.
func _establishment() -> int:
	var share: int = target_population / maxi(squads_per_faction, 1)
	return clampi(share, 2, AISquad.MAX_MEMBERS)


## Whether a squad may be given a new objective.
##
## Never before its timer is up. After that, not until it has actually reached
## the ground it was sent to — a squad that keeps being re-tasked mid-crossing
## never arrives anywhere. The second period is a hard ceiling on that patience,
## so a squad that cannot reach its objective at all is eventually re-tasked
## rather than walking into the same wall forever.
##
## This is called from `_command` and it has to be: the loop used to re-task on
## the bare timer, which is the mid-crossing re-tasking this function exists to
## stop. At the pace these bodies move a 48 m leg is about thirty-five seconds
## and the timer is thirty, so every squad was re-choosing before it arrived
## anywhere — the exact failure `retarget_period`'s comment describes as fixed.
func _may_retarget(squad: AISquad, timer: float) -> bool:
	if squad.objective() == &"":
		return true
	if timer > 0.0:
		return false
	if timer <= -retarget_period:
		return true
	return squad.centroid().distance_to(squad.objective_point()) <= objective_arrival


## Squads of `faction` other than `except` that are pointed at ground the faction
## already holds. The defence cap counts against this.
func _defending(faction: int, except: int) -> int:
	var n: int = 0
	for s: int in squads_per_faction:
		if s == except:
			continue
		var id: StringName = _squad_at(faction, s).objective()
		if id != &"" and _ledger.zone_owner(id) == faction:
			n += 1
	return n


## Where a squad goes next. Enemy and unclaimed ground first, its own contested
## ground when it is being taken off it, and never where its own faction already
## has bodies enough. Lifted from the headless harness, where it is what produces
## a war rather than a border.
##
## `may_defend` is the cap: false means this squad is not allowed to pick its own
## faction's ground at all, because enough of the faction is already sitting on
## it. See `max_defending_squads`.
func _choose_objective(faction: int, squad: AISquad, may_defend: bool = true) -> void:
	var from: Vector3 = squad.centroid()
	if squad.size() == 0:
		from = _home_point(faction)
	var best: int = -1
	var best_s: float = -INF
	var aggro: float = Factions.aggression(faction)
	var span: float = maxf(_arena_span(), 1.0)
	for i: int in _ledger.count():
		var id: StringName = _ledger.id_at(i)
		var owner_faction: int = _ledger.owner_at(i)
		var dist: float = from.distance_to(_ledger.center_at(i))
		var s: float = 0.0
		if owner_faction == faction:
			if not may_defend:
				continue
			s = 1.5 if _ledger.is_contested(id) else 0.10
		elif owner_faction < 0:
			s = 1.2 * aggro
		else:
			# GROUND THE LEDGER WILL NEVER HAND OVER. `Territory._tick_zone`
			# returns before the capture test when the owner is down to its last
			# zone, so a faction reduced to its capital cannot be finished off —
			# and a squad sent at that capital is parked on an impossible
			# objective for the rest of the run. Measured over six and a half
			# minutes with this line missing: the Foundry held full pressure on
			# `scav_yard` from t=200 s onward and never took it, the Scavs spent
			# the whole run pinned inside eight metres of their own flagpole with
			# 21 of 22 bodies in contact, and the ledger sat at 1/4/2 for four
			# minutes. The siege is unwinnable by construction; the director
			# should not order it.
			if _ledger.home_at(i) == owner_faction and zones_owned(owner_faction) <= 1:
				continue
			# Probe the weak point. A zone whose holder is not standing on it is
			# worth nearly three of a zone that is properly garrisoned.
			#
			# The floor used to be 0.35, and 0.35 is close enough to nothing that
			# a well-held zone stopped being a target at all: three factions took
			# whichever ring zone happened to be empty and nobody ever pushed the
			# contested middle once somebody had a garrison on it. A floor of 0.55
			# against a 1.6-value objective is 0.88 — still half of what an
			# undefended zone is worth, and no longer zero.
			s = aggro * (0.55 + 1.00 * (1.0 - _ledger.pressure_at(i, owner_faction)))
			# A capital costs `home_margin_scale` — 2.1 — times the usual margin
			# to take. It is worth attacking; it is not worth the same as open
			# ground, and scoring it the same is what turns a war into two sieges.
			if _ledger.home_at(i) == owner_faction:
				s *= 0.45
		s *= 1.0 + 0.8 * _ledger.pressure_at(i, faction)
		s *= float(_ledger.shape(id)[3])
		s /= 1.0 + dist / span
		s /= 1.0 + float(_boards[faction].roster.committed_to(id)) * objective_crowding
		if s > best_s:
			best_s = s
			best = i
	if best < 0:
		return
	squad.set_objective(_ledger.id_at(best), _ledger.center_at(best), _rally_for(faction, from))


## A squad falls back to the nearest ground its own faction actually holds, not
## all the way home. Rallying to the capital is how a faction stops fighting.
func _rally_for(faction: int, from: Vector3) -> Vector3:
	var best: Vector3 = _home_point(faction)
	var best_d: float = INF
	for i: int in _ledger.count():
		if _ledger.owner_at(i) != faction:
			continue
		var d: float = from.distance_squared_to(_ledger.center_at(i))
		if d < best_d:
			best_d = d
			best = _ledger.center_at(i)
	return best


## Mean distance between zone centres, used to normalise the distance term in the
## objective score so the same doctrine works on any size of arena.
func _arena_span() -> float:
	var n: int = _ledger.count()
	if n < 2:
		return 1.0
	var sum: float = 0.0
	var pairs: int = 0
	for i: int in n:
		for j: int in range(i + 1, n):
			sum += _ledger.center_at(i).distance_to(_ledger.center_at(j))
			pairs += 1
	return sum / float(maxi(pairs, 1))


## Reinforcement scales with holdings — ground is where bodies come from — but it
## scales harder with how badly a faction has been hurt. Without that second term
## the body economy runs away on its own and no ledger rule can catch it.
func _reinforce_step(delta: float) -> void:
	var full: float = float(target_population)
	for f: int in Factions.COUNT:
		var spawner: EnemySpawner = _spawners[f]
		if spawner == null:
			continue
		var standing: int = body_count(f)
		var deficit: float = clampf(1.0 - float(standing) / full, 0.0, 1.0)
		var holdings: float = 0.6 * _ledger.share(f) * float(Factions.COUNT)
		_reinforce[f] -= delta * (0.7 + holdings + 1.2 * deficit)
		if _reinforce[f] > 0.0:
			continue
		_reinforce[f] = reinforce_period
		var wave: int = wave_size + int(deficit * float(wave_size))
		_release(f, wave)


## Deploy the opening garrisons, but not before the navigation map can actually
## answer a query.
##
## `EnemySpawner` snaps every spawn onto the navmesh, and a navigation map that
## has not merged its region answers every query with the origin. Land the
## opening wave one frame early and the bodies appear stacked on the world
## origin, inside each other, and neither the physics solver nor the avoidance
## solver can untangle a pile like that — measured, seven of the sixty-six spent
## the whole run wedged there.
##
## Waiting on `map_get_iteration_id >= 2` is NOT enough, which is what this used
## to do: the map publishes the iteration that owns the region before every query
## against it is answering off it, and the wave still landed on the origin. The
## test below is the one that cannot be early — ask the map for the nearest
## navigable point to somewhere far off the origin, and require the answer to be
## near where it was asked about rather than at zero.
func _try_opening() -> void:
	var map: RID = get_world_3d().navigation_map
	if not map.is_valid() or NavigationServer3D.map_get_iteration_id(map) < 2:
		return
	if not _map_answers(map):
		return
	_opening_pending = false
	var wanted: int = int(round(float(target_population) * opening_fraction))
	for f: int in Factions.COUNT:
		if _spawners[f] == null:
			continue
		if opening_in_contact:
			_deploy_front(f, wanted)
		else:
			_release(f, wanted)


## Whether the navigation map is really serving queries yet. Probes each home
## point, because those are the furthest-flung places a spawn will be asked to
## snap to and the ones an unmerged map fails on.
func _map_answers(map: RID) -> bool:
	for f: int in Factions.COUNT:
		var p: Vector3 = _home_point(f)
		if p.length_squared() < 1.0:
			continue
		if NavigationServer3D.map_get_closest_point(map, p).distance_to(p) > 8.0:
			return false
	return true


## Stand a faction's opening garrison up on its own approach to the contested
## ground, already in weapons range of the other two.
##
## The demo is a war, and a war a spectator arrives at is a war already in
## progress. Deploying every faction at home instead — which is what this did —
## is a cold start: three garrisons stand in three yards forty-eight metres from
## anything worth fighting over, and at the pace these bodies actually cross
## ground it is the better part of a minute before the first round is fired.
## Measured on the old opening: sixty seconds of simulation, two shots, and all
## three faction centroids still within fifteen metres of their own capitals.
## Worse, twenty-two bodies dropped into one seven-metre spawn disc gridlock
## their own avoidance solver and crawl out of it at a tenth of a walk.
##
## Each faction gets the arc of the front that faces its own capital, so the ring
## still reads as three sides that came from somewhere, and the radial draw is
## biased forward so the weight of each faction is inside the capture cylinder
## with its reserve strung out behind it.
func _deploy_front(faction: int, count: int) -> void:
	var hub: Vector3 = _contest_point()
	var home: Vector3 = _home_point(faction)
	var out: Vector3 = home - hub
	out.y = 0.0
	if out.length_squared() < 1.0:
		out = Vector3.FORWARD
	var bearing: float = atan2(out.x, out.z)
	var half_arc: float = deg_to_rad(front_arc_degrees) * 0.5
	var span: int = maxi(count, 1)
	for n: int in count:
		if body_count(faction) >= target_population:
			return
		# Stratified over the depth of the line, so the draw cannot pile the whole
		# garrison into one band the way an unstratified one does at this count.
		var t: float = (float(n) + _rng.next()) / float(span)
		var r: float = lerpf(front_inner, front_outer, pow(t, front_forward_bias))
		var a: float = bearing + _rng.next_range(-half_arc, half_arc)
		var p: Vector3 = hub + Vector3(sin(a), 0.0, cos(a)) * r
		var facing: Vector3 = hub - p
		facing.y = 0.0
		if facing.length_squared() < 1e-4:
			facing = Vector3.FORWARD
		if not _spawn_one(faction, Transform3D(Basis.looking_at(facing.normalized()), p)):
			return


## The ground the war is about: the most valuable piece nobody was born holding.
## Read off the ledger rather than named here, so moving a zone in the bake moves
## the front with it.
func _contest_point() -> Vector3:
	var best: Vector3 = global_position
	var best_value: float = -INF
	for i: int in _ledger.count():
		if _ledger.home_at(i) >= 0:
			continue
		var shape: Array = _ledger.shape(_ledger.id_at(i))
		var value: float = 1.0 if shape.is_empty() else float(shape[3])
		if value > best_value:
			best_value = value
			best = _ledger.center_at(i)
	return best


## Put up to `count` bodies of `faction` into play at its quietest holding.
func _release(faction: int, count: int) -> void:
	var where: Transform3D = _spawn_transform(faction)
	for _n: int in count:
		if body_count(faction) >= target_population:
			return
		if not _spawn_one(faction, where):
			return


## One body of `faction` at `where`. False once the whole roster is dry.
##
## The retry loop is the whole of this function and it is not defensive coding.
## The species draw is weighted, so the fodder slot comes up four times in five,
## and the spawner's per-species pool is a hard ceiling; once nine Rats are
## standing every Rat draw comes back null. Taking that as "the wave is over"
## caps a faction at whatever its commonest species can field, which measured out
## at 24 bodies across the whole map instead of 66. Rolling again — and only
## giving up once the whole roster is dry — is what makes the weights a
## preference rather than a limit.
func _spawn_one(faction: int, where: Transform3D) -> bool:
	var spawner: EnemySpawner = _spawners[faction]
	var roster: int = FirefightRoster.ROSTERS[faction].size()
	for _try: int in roster * 2:
		if spawner.spawn(FirefightRoster.draw(faction, _rng.next()), where) != null:
			return true
	return false


## Reinforcements march to the sound of the guns: they come in on whichever
## ground the faction holds that is NEAREST the fighting and still clear of it.
##
## Both halves of that matter and the demo has now been run with each half
## missing. Landing a wave on the quietest holding — which is what this did, and
## the safe-looking choice — is what kills the demo after the opening: measured
## over two simulated minutes, the front burns down in the first minute, every
## replacement is then born at a capital forty-eight metres behind it, and at the
## pace a body actually crosses ground it does not arrive. From about a hundred
## seconds the population is back to sixty and the rate of fire is zero. Landing
## it on the nearest holding regardless of who is standing there is the opposite
## failure and the reason the old comment was written: bodies appear inside an
## enemy squad, in ones and twos, and are killed as they arrive.
##
## Nearest-that-is-clear is both. `muster_clearance` is the whole of the rule.
func _spawn_transform(faction: int) -> Transform3D:
	var hub: Vector3 = hotspot()
	var clear2: float = muster_clearance * muster_clearance
	var best: Vector3 = _home_point(faction)
	var best_score: float = INF
	# Fallback for a faction whose every holding is already being fought over:
	# the quietest one, which is the old rule and the right one in that case.
	var fallback: Vector3 = best
	var fallback_gap: float = -1.0
	for i: int in _ledger.count():
		if _ledger.owner_at(i) != faction:
			continue
		var c: Vector3 = _ledger.center_at(i)
		var nearest: float = INF
		for a: FirefightAgent in _agents:
			if a.is_alive() and Factions.hostile(faction, a.faction):
				nearest = minf(nearest, c.distance_squared_to(a.position()))
		if nearest > fallback_gap:
			fallback_gap = nearest
			fallback = c
		if nearest < clear2:
			continue
		var score: float = c.distance_to(hub)
		if score < best_score:
			best_score = score
			best = c
	if best_score == INF:
		best = fallback
	var toward: Vector3 = hub - best
	toward.y = 0.0
	if toward.length_squared() < 1e-4:
		toward = Vector3.FORWARD
	return Transform3D(Basis.looking_at(toward.normalized(), Vector3.UP), best)


## A squad said something. Counted by kind and kept as a short rolling transcript,
## which is the only way to watch the comms layer work without a debugger.
func _on_callout(kind: int, _p: Vector3, _target_id: int, squad_id: StringName) -> void:
	if kind < 0 or kind >= AIComms.KIND_COUNT:
		return
	_calls[kind] += 1
	_call_log.append("%s:%s" % [squad_id, AIComms.KIND_NAMES[kind]])
	if _call_log.size() > CALL_LOG_SIZE:
		_call_log.remove_at(0)


## THE COMMS AND COVER OVERLAY LINES THIS USED TO WRITE NOW LIVE ON THE DEMO
## ROOT, built out of the public accessors above. They moved because this node
## wrote them whether or not the overlay was up and never took them down, leaving
## three stale lines on an autoload after the scene unloaded. The stdout copy
## stays: it is a time series a `tools/watch.gd` run scrapes out of the log.
func _publish(delta: float) -> void:
	if cover_report_period > 0.0:
		var ledger: String = _cover.rejection_line()
		_cover_report -= delta
		if _cover_report <= 0.0 and not ledger.is_empty():
			_cover_report = cover_report_period
			print("cover  ", ledger)
	var owned := PackedInt32Array()
	var bodies := PackedInt32Array()
	owned.resize(Factions.COUNT)
	bodies.resize(Factions.COUNT)
	for f: int in Factions.COUNT:
		owned[f] = zones_owned(f)
		bodies[f] = body_count(f)
	standings_changed.emit(owned, bodies)


# ------------------------------------------------------------- body lifecycle


func _on_spawned(actor: EnemyActor) -> void:
	if not NetGame.is_authority():
		return
	var agent: FirefightAgent = _by_actor.get(actor)
	if agent == null:
		agent = _enrol(actor)
		if agent == null:
			return
	else:
		agent.reset()
	agent.handle = _scheduler.add_agent(agent, actor.global_position)
	_paths.register(agent.agent_id, agent.nav)
	_paths.apply_tuning(agent.nav)
	_join_squad(agent)


## First sight of a pooled actor: give it a head, a stable id and a place in the
## target index. Pooled bodies keep their row forever — the index filters on the
## `AITarget.alive` flag, so a parked corpse costs one dead row and no ids churn.
func _enrol(actor: EnemyActor) -> FirefightAgent:
	var target: AITarget = actor.target()
	if target == null or actor.profile == null:
		push_error("FirefightDirector: actor '%s' has no AITarget or profile." % actor.name)
		return null
	var id: int = _targets.add(target)
	_serial += 1
	var agent := FirefightAgent.new(
		actor, actor.profile, perception_tuning, id, seed_value + _serial * 7919
	)
	agent.path_submit = _submit_path
	agent.reset()
	# Re-key the weapon to the index id so the friendly-fire corridor test and the
	# faction grenade token agree with everything else about who this body is.
	actor.configure(actor.profile, actor.faction, id)
	actor.died.connect(_on_died)
	_agents.append(agent)
	_by_actor[actor] = agent
	return agent


func _join_squad(agent: FirefightAgent) -> void:
	var f: int = agent.faction
	var weakest: AISquad = null
	var fewest: int = AISquad.MAX_MEMBERS
	for s: int in squads_per_faction:
		var squad: AISquad = _squad_at(f, s)
		if squad.size() < fewest:
			fewest = squad.size()
			weakest = squad
	if weakest == null:
		return
	if weakest.state() == AISquad.State.ROUT or weakest.size() == 0:
		weakest.reform(_rally_for(f, agent.position()))
	if weakest.add_member(agent.agent_id, agent.profile) < 0:
		return
	agent.squad = weakest


func _submit_path(agent_id: int, urgency: float) -> void:
	_paths.submit(agent_id, urgency)


## A body died, and it died INSIDE the due-walk: an agent's own `think` fires the
## shot that kills another agent, whose `died` signal lands here synchronously.
##
## Retiring it there and then calls `AITickScheduler.remove_agent`, which
## swap-removes a row — and the due list the walk is halfway through holds ROW
## indices, so every entry after the removed one now points somewhere else or off
## the end. Measured, once bodies finally started killing each other: "Out of
## bounds get index '65'" out of `due_agent`, every frame a casualty landed.
## Queueing the retirement and doing it after the walk costs one array append.
func _on_died(actor: EnemyActor) -> void:
	_queue_retire(actor)


## Pooled away without dying — a capacity cut, or a teardown. Same bookkeeping.
func _on_despawned(actor: EnemyActor) -> void:
	_queue_retire(actor)


func _queue_retire(actor: EnemyActor) -> void:
	var agent: FirefightAgent = _by_actor.get(actor)
	if agent != null and agent.handle >= 0 and not _retire_queue.has(agent):
		_retire_queue.append(agent)


func _drain_retirements() -> void:
	if _retire_queue.is_empty():
		return
	for agent: FirefightAgent in _retire_queue:
		_retire(agent)
	_retire_queue.clear()


func _retire(agent: FirefightAgent) -> void:
	if agent.squad != null:
		agent.squad.remove_member(agent.agent_id, true)
		agent.squad = null
	if agent.handle >= 0:
		_scheduler.remove_agent(agent.handle)
		agent.handle = -1
	_paths.unregister(agent.agent_id)


## The viewer the tick LOD is measured against. In this demo that is always the
## spectator camera, and re-reading it per frame is what makes the scheduler
## follow a freecam through a wall without any wiring between the two.
func _read_viewer() -> void:
	var cam: Camera3D = get_viewport().get_camera_3d()
	if cam == null:
		return
	_viewer_pos = cam.global_position
	_viewer_fwd = -cam.global_transform.basis.z
