class_name ArenaController
extends Node3D
## The enemy test arena. A walled compound, a control desk you shoot, and four
## gates that everything hostile has to walk through.
##
## This node is the wiring and nothing else: the geometry is baked, the AI belongs
## to `ArenaDirector`, the desk belongs to `ArenaStation`, and the gun belongs to
## `ArenaLoadout`. What lives here is the sequence — a lever goes over, a gate
## grinds up, bodies trickle out of the dark behind it, the director adopts each
## one and gives it somewhere to stand.
##
## Nothing spawns in the open. That rule is the reason the gates exist and the
## reason the trickle is a timer rather than a loop: bodies appearing at once
## reads as a cheat even when the maths is identical.
##
## THERE ARE THREE SPAWNERS AND NOT ONE, one per faction, and that is what makes
## this a combat sandbox rather than a shooting gallery. Two things come out of
## it. First the ceiling: `EnemySpawner.capacity()` is
## `min(max_alive, GameSettings.max_enemies)` and the quality preset's figure is
## the binding half of that — 44 on the settings this project ships with, 64 at
## Ultra — so ONE spawner cannot hold a hundred bodies whatever its own
## `max_alive` says. Three of them hold three times that, which is exactly the
## arrangement `tools/build_firefight.gd` already uses to field ~100. Second, and
## more important: a spawner's `faction` is a property of the spawner, so a body
## recycled out of the SCAV pool is a Scav on the frame it is instantiated as well
## as on the frame the director adopts it, and a three-way brawl gets three
## independent pools instead of three factions fighting over one.
##
## The arena's own total is `population_cap`, which is the number the COUNT dial's
## last detent reads, so the knob can always be turned to the stop and the stop is
## always true.

## Id `SceneRouter` routes this demo under.
const DEMO_ID: String = "arena"
const DEMO_TITLE: String = "ENEMY TEST ARENA"
const DEMO_BLURB: String = "Walls, cover and a lever. Put every animal in front of every gun."

@export_group("Wiring")
@export var director_path: NodePath = NodePath("Director")
## One `EnemySpawner` per faction, indexed BY FACTION ID. A missing or wrongly
## ordered entry is refused loudly on `_ready` rather than quietly delivering
## Scavs out of the Choir's pool.
@export var spawner_paths: Array[NodePath] = []
@export var station_path: NodePath = NodePath("Compound/Station")
@export var loadout_path: NodePath = NodePath("Loadout")
@export var player_path: NodePath = NodePath("Player")
@export var hud_path: NodePath = NodePath("CombatHud")
## Gates bodies come through. Each keeps its OWN trickle clock.
@export var gate_paths: Array[NodePath] = []

## Holding positions a spawned body walks in to take up, handed out round robin.
## A wave that stopped in the gateway would be a wave that never found anybody:
## these are spread across the compound so the walk in is also the sweep.
##
## They are handed out without regard to faction, ON PURPOSE. Interleaving three
## factions across the same ten anchors is what puts hostile bodies within sight
## of each other, and a body that has walked into a rival is the whole of the
## "if they get too close to each other they fight each other" behaviour.
@export var patrol_anchors: PackedVector3Array = PackedVector3Array()

@export_group("Population")
## Ceiling on live bodies across all three spawners. The COUNT dial's last detent
## reads this, and `_release` refuses to cross it whatever the spawners allow.
##
## MEASURED, not chosen, and the machinery would serve more. Three spawners at
## `min(64, GameSettings.max_enemies)` is **132** on the settings this project
## ships with; 96 is what was priced. Delivered and held 96 of 96 asked, at
## **10.4 ms mean physics** with a 58 ms worst frame while the wave was still
## walking in — against a 16.7 ms budget at the 60 Hz physics tick.
##
## What was NOT measured is 96 rendered and held: a three-way brawl eats itself
## down to sixty inside twenty seconds and one faction alone is capped at 44 by
## the quality preset, so the highest RENDERED steady population priced is 59, at
## 199-227 fps. Raise this if you want to push past that and re-read
## `demos/arena/arena_verify.txt` afterwards; the COUNT dial's last detent follows
## it automatically.
@export_range(1, 256, 1) var population_cap: int = 96
## Seconds ONE gate waits between the two bodies it releases. Four gates run their
## own copy of this clock, so the compound fills at four times the rate one gate
## does.
##
## MEASURED DOWN FROM 0.45. The old figure was one global clock for all four
## gates, which is 2.2 bodies a second — fine for a wave of eight and useless for
## a wave of ninety-six, which took forty-four seconds to walk in. Per gate at
## 0.28 s it is 14 a second and the same wave is in the room in seven, which
## matters because a three-way brawl starts killing the moment the first two
## factions meet: measured on a rendered run at the old rate, the compound peaked
## at 64 alive of 96 asked because attrition outran the fill.
##
## 0.28 s is still two distinguishable objects. A gate is 4.4 m wide and a body
## clears it at roughly 2 m/s, so consecutive bodies leave half a metre apart —
## tight, and visibly two things rather than one thing splitting.
@export_range(0.05, 4.0, 0.01) var trickle_seconds: float = 0.28
## Seconds a gate stays open after the last body of a wave has walked through.
@export_range(0.0, 12.0, 0.1) var gate_linger: float = 2.5
## Queued bodies one gate will try before giving up for this tick. The head of
## the queue can be blocked by its own faction's species pool while the entry
## behind it is not; without a retry the whole wave stalls on the first one that
## cannot be served, which at a hundred bodies over twelve species happens often.
@export_range(1, 32, 1) var release_retries: int = 6

@export_group("Feel")
## Damage numbers float off things you hit.
@export var show_damage_pops: bool = true

var _director: ArenaDirector = null
## Indexed by faction id. Entries may be null if the scene was built wrong; every
## read goes through `_spawner_for`.
var _spawners: Array[EnemySpawner] = []
var _station: ArenaStation = null
var _loadout: ArenaLoadout = null
var _player: PlayerController = null
var _hud: CombatHud = null
var _gates: Array[ArenaGate] = []
## The wave still to walk in, as two parallel queues: what species, and which
## faction it fights for. Parallel rather than an array of dictionaries because a
## hundred-entry queue is drained one entry per gate per tick and allocating a
## dictionary per body to do it is a hundred allocations for two integers.
var _queue_species: Array[StringName] = []
var _queue_faction: PackedInt32Array = PackedInt32Array()
## Seconds until each gate may release again, index aligned with `_gates`.
var _gate_ready: PackedFloat32Array = PackedFloat32Array()
var _linger: float = 0.0
var _profiles: AISpeciesProfileSet = null
var _freecam: FreecamController = null
var _rng: XorShift32 = XorShift32.new(20260728)
var _anchor_cursor: int = 0
## Where the ANY species draw is up to. A cycle rather than a uniform roll: a
## hundred-body wave drawn uniformly over twelve species starves some pools and
## over-serves others, and a starved pool is a body that never arrives.
var _species_cursor: int = 0
## The desk. It latches the press in `_unhandled_input` and casts that press's own
## ray in `_physics_process`. The desk used to be selected by angle — whichever
## control was nearest the middle of the view within 0.55 of a dot product — which
## reached through the desk's own casing and could not tell one end of a slider
## from the other. A ray does both.
var _hands: DiegeticInteractor = null


func _ready() -> void:
	if not SceneRouter.has_demo(DEMO_ID):
		SceneRouter.register_demo(DEMO_ID, DEMO_TITLE, "res://demos/arena/arena.tscn", DEMO_BLURB)
	_director = get_node_or_null(director_path) as ArenaDirector
	_station = get_node_or_null(station_path) as ArenaStation
	_loadout = get_node_or_null(loadout_path) as ArenaLoadout
	_player = get_node_or_null(player_path) as PlayerController
	_hud = get_node_or_null(hud_path) as CombatHud
	_resolve_spawners()
	if _director == null or _station == null or _player == null or _spawner_for(0) == null:
		push_error("ArenaController: the baked scene is missing one of its own nodes.")
		return
	_profiles = _spawners[0].profiles
	_resolve_gates()
	_wire()
	_build_hands()
	_director.register_viewer(_player.get_node_or_null(^"Eye") as Node3D)
	_director.set_aggression(_station.selected_aggression())
	_station.set_count_ceiling(capacity())
	_station.set_roster(0, capacity())
	set_physics_process(true)


## The desk's hands. World geometry is in the mask so the compound wall stops the
## press, and only `interact` is latched: the fire button belongs to the gun, and
## the desk is meant to be operable by shooting it, which `ArenaStation.bullet_hit`
## already does off the round itself.
func _build_hands() -> void:
	_hands = DiegeticInteractor.new()
	_hands.name = "Hands"
	_hands.collision_mask = GameLayers.WORLD | GameLayers.PROP
	_hands.interact_reach = _station.interact_reach
	_hands.handle_fire = false
	_hands.track_hover = false
	add_child(_hands)


func _physics_process(delta: float) -> void:
	_advance_wave(delta)
	_director.set_hunt_point(_player.global_position)
	_station.set_roster(alive_count(), capacity())
	_station.set_status(_director.summary())
	DebugHUD.note(
		&"arena_hold", "arena  %s  %s" % [_station.selected_species_label(), _loadout_line()]
	)


## Live bodies across every spawner.
func alive_count() -> int:
	var n: int = 0
	for spawner: EnemySpawner in _spawners:
		if spawner != null:
			n += spawner.alive_count()
	return n


## What this arena can actually hold: what the three spawners between them allow,
## held under the demo's own cap. Both halves matter — the spawners answer to the
## quality preset and the cap answers to the frame budget.
func capacity() -> int:
	var n: int = 0
	for spawner: EnemySpawner in _spawners:
		if spawner != null:
			n += spawner.capacity()
	return mini(n, population_cap)


## Bodies still queued to walk in. The harness reads it to tell "the wave has not
## arrived yet" from "the wave was refused".
func pending_count() -> int:
	return _queue_species.size()


func _resolve_spawners() -> void:
	_spawners.clear()
	for path: NodePath in spawner_paths:
		_spawners.append(get_node_or_null(path) as EnemySpawner)
	for f: int in _spawners.size():
		var spawner: EnemySpawner = _spawners[f]
		if spawner == null:
			push_error("ArenaController: spawner %d is missing from the baked scene." % f)
		elif spawner.faction != f:
			push_error(
				(
					"ArenaController: spawner %d fights for faction %d; the array is indexed by faction."
					% [f, spawner.faction]
				)
			)


func _resolve_gates() -> void:
	_gates.clear()
	for path: NodePath in gate_paths:
		var gate := get_node_or_null(path) as ArenaGate
		if gate != null:
			_gates.append(gate)
	_gate_ready.resize(_gates.size())
	_gate_ready.fill(0.0)
	if _gates.is_empty():
		push_error("ArenaController: no gates wired; nothing could enter the compound.")


func _wire() -> void:
	_station.spawn_requested.connect(_on_spawn_requested)
	_station.clear_requested.connect(_on_clear_requested)
	_station.aggression_changed.connect(_director.set_aggression)
	_station.debug_toggled.connect(_director.set_debug_draw)
	for f: int in _spawners.size():
		var spawner: EnemySpawner = _spawners[f]
		if spawner == null:
			continue
		# The faction rides on the binding rather than being read back off the
		# actor: the actor has not been configured yet at this point in the spawn.
		spawner.spawned.connect(_on_spawned.bind(f))
		spawner.despawned.connect(_on_despawned)
		spawner.spawn_failed.connect(_on_spawn_failed)
		spawner.capacity_changed.connect(_on_capacity_changed)
	if _loadout != null:
		_loadout.round_landed.connect(_on_round_landed)
	_freecam = _player.get_node_or_null(^"Freecam") as FreecamController
	if _freecam != null:
		_freecam.freecam_changed.connect(_on_freecam_changed)
	var target: AITarget = _player.get_node_or_null(^"Target") as AITarget
	if target != null:
		_director.register_target(target)
	else:
		push_error("ArenaController: the player carries no AITarget; nothing can see it.")


## Feed the wave through the gates, each gate on its own clock, so a four-gate
## compound fills four times as fast as a one-gate queue would and a wave arrives
## from four directions at once instead of in single file.
func _advance_wave(delta: float) -> void:
	for i: int in _gate_ready.size():
		_gate_ready[i] = maxf(_gate_ready[i] - delta, 0.0)
	if _queue_species.is_empty():
		if _linger > 0.0:
			_linger -= delta
			if _linger <= 0.0:
				_close_gates()
		return
	for i: int in _gates.size():
		if _queue_species.is_empty():
			break
		if _gate_ready[i] > 0.0 or not _gates[i].is_open():
			continue
		if _release(_gates[i]):
			_gate_ready[i] = trickle_seconds
	if _queue_species.is_empty():
		_linger = gate_linger


## Put one queued body through `gate`. Returns whether anything went through.
##
## The queue is ROTATED rather than held on a refusal. A refusal means one of
## three things — the arena is at its cap, that faction's spawner is at its own,
## or that species' pool is exhausted — and only the first is a reason to stop
## trying. Holding the whole wave on the head of the queue turned a ninety-body
## ANY wave into a stall the moment one species ran short, and it did it in
## silence because a corpse recycling a second later would have cleared it.
func _release(gate: ArenaGate) -> bool:
	if alive_count() >= population_cap:
		return false
	var tries: int = mini(_queue_species.size(), release_retries)
	for _t: int in tries:
		var spawner: EnemySpawner = _spawner_for(_queue_faction[0])
		if spawner != null and spawner.spawn_from_door(gate, _queue_species[0]) != null:
			_queue_species.remove_at(0)
			_queue_faction.remove_at(0)
			return true
		_queue_species.append(_queue_species[0])
		_queue_species.remove_at(0)
		_queue_faction.append(_queue_faction[0])
		_queue_faction.remove_at(0)
	return false


func _spawner_for(faction: int) -> EnemySpawner:
	if faction < 0 or faction >= _spawners.size():
		return null
	return _spawners[faction]


## The desk asked for a wave. `mix` is how many factions to deal it across,
## starting from `faction` and wrapping — so THREE WAY starting on CHOIR is
## CHOIR, SCAV, FOUNDRY in rotation and every gate delivers a different side.
func _on_spawn_requested(species: StringName, faction: int, count: int, mix: int) -> void:
	var sides: int = clampi(mix, 1, Factions.COUNT)
	var room: int = maxi(capacity() - alive_count() - _queue_species.size(), 0)
	var wanted: int = mini(count, room)
	# Start the ANY cycle somewhere different each wave, so two waves of the same
	# size are not the same twelve animals in the same order.
	_species_cursor = _rng.next_int(0, maxi(_species_count() - 1, 0))
	for i: int in wanted:
		_queue_species.append(species if not species.is_empty() else _next_species())
		_queue_faction.append((faction + i % sides) % Factions.COUNT)
	_linger = 0.0
	_gate_ready.fill(0.0)
	for gate: ArenaGate in _gates:
		gate.set_open(true)
	_station.rearm()
	if _hud != null:
		_hud.banner(_wave_banner(faction, sides, wanted, count), 1.6)


## What the wave is, said once. A refusal has to say so — asking for 96 on a full
## compound and getting nothing with a cheerful banner is the failure mode the
## `--spawn` detent trap taught this demo about.
func _wave_banner(faction: int, sides: int, wanted: int, asked: int) -> String:
	if wanted <= 0:
		return "COMPOUND FULL"
	var names := PackedStringArray()
	for i: int in sides:
		names.append(Factions.NAMES[(faction + i) % Factions.COUNT])
	var line: String = "%s  x%d" % ["/".join(names), wanted]
	return line if wanted == asked else "%s  (of %d)" % [line, asked]


func _species_count() -> int:
	return 0 if _spawners.is_empty() or _spawners[0] == null else _spawners[0].species.size()


## The next species in the cycle. Cycling rather than rolling is what keeps the
## pools even: twelve species drawn uniformly a hundred times leaves some at
## fourteen and some at four, and the ones at fourteen refuse.
func _next_species() -> StringName:
	var n: int = _species_count()
	if n <= 0:
		return &""
	_species_cursor = (_species_cursor + 1) % n
	return _spawners[0].species[_species_cursor]


func _on_clear_requested() -> void:
	_queue_species.clear()
	_queue_faction.clear()
	_linger = 0.0
	for spawner: EnemySpawner in _spawners:
		if spawner != null:
			spawner.despawn_all()
	_director.clear_all()
	_close_gates()
	_station.rearm()


func _close_gates() -> void:
	for gate: ArenaGate in _gates:
		gate.set_open(false)


## The quality preset moved and a spawner's cap moved with it. The COUNT dial's
## last detent is the arena's cap, so it has to be re-cut or the knob is lying.
func _on_capacity_changed(_capacity: int) -> void:
	_station.set_count_ceiling(capacity())


## A body entered play. Give it a brain, a faction colour and a post to fall back
## to — one of the patrol anchors, which keeps a stood-down wave off the middle of
## the floor and puts the three factions in each other's way.
## NOTHING IS RE-CONFIGURED HERE, and that is a change with two separate reasons.
##
## The demo used to call `actor.configure(profile, faction, 0)` on every spawn,
## because with ONE spawner serving every faction a recycled body genuinely could
## come back on the wrong side. With a spawner per faction it cannot: the pool a
## body comes out of is the pool of its own faction and its own species, and
## `EnemySpawner._instantiate` already configured it with both.
##
## Calling it anyway cost real money and told a real lie. `EnemyActor.configure`
## runs `AICombat.configure` -> `_scavenge()` -> `GunFactory.roll`, so it rolled a
## weapon per body per spawn — ninety-six gun rolls inside the seven seconds a
## full wave takes to walk in. And it rolled them all with **agent id zero**,
## while `AISpeciesProfile.gun_roll_seed(agent_id)` is what makes a firing line of
## scavengers a firing line of DIFFERENT scrap: every sentinel in the arena was
## carrying the same rifle and every marksman the same rifle, which is exactly the
## thing the seed exists to prevent. The spawner's own call passes a real serial.
func _on_spawned(actor: EnemyActor, faction: int) -> void:
	var profile: AISpeciesProfile = null
	if _profiles != null:
		profile = _profiles.get_profile(actor.species_id)
	if profile == null:
		push_error("ArenaController: no AISpeciesProfile for '%s'." % actor.species_id)
		return
	if actor.faction != faction:
		push_error(
			(
				"ArenaController: '%s' came out of the faction-%d pool as faction %d."
				% [actor.species_id, faction, actor.faction]
			)
		)
		actor.configure(profile, faction, actor.get_instance_id())
	_director.adopt(actor, profile, _next_anchor(actor.global_position))


## The next holding position in the rotation, or the body's own feet when the
## scene was built without any.
func _next_anchor(fallback: Vector3) -> Vector3:
	if patrol_anchors.is_empty():
		return fallback
	_anchor_cursor = (_anchor_cursor + 1) % patrol_anchors.size()
	return patrol_anchors[_anchor_cursor]


func _on_despawned(actor: EnemyActor) -> void:
	_director.release(actor)


func _on_spawn_failed(species_id: StringName, reason: String) -> void:
	push_error("ArenaController: cannot spawn '%s' — %s" % [species_id, reason])
	if _hud != null:
		_hud.banner("SPAWN FAULT", 1.2)


## Every round the player lands. Controls first, because a knob is not a target and
## must not eat a damage number; then the feedback for everything else.
func _on_round_landed(collider: Object, at: Vector3, _normal: Vector3, damage: float) -> void:
	if _station.bullet_hit(collider, at, _loadout.control_power):
		return
	if _hud == null:
		return
	var actor: EnemyActor = _actor_of(collider)
	if actor == null:
		return
	_hud.hit_mark(not actor.alive, false)
	if show_damage_pops:
		_hud.pop(at, str(roundi(damage)))


static func _actor_of(collider: Object) -> EnemyActor:
	var node: Node = collider as Node
	var depth: int = 0
	while node != null and depth < 4:
		var actor := node as EnemyActor
		if actor != null:
			return actor
		node = node.get_parent()
		depth += 1
	return null


## The level-of-detail clock measures from whoever is looking. In freecam that is
## the freecam, or every agent behind you drops to a crawl while you fly at them.
func _on_freecam_changed(active: bool) -> void:
	if active:
		_director.register_viewer(_freecam)
		return
	_director.register_viewer(_player.get_node_or_null(^"Eye") as Node3D)


func _loadout_line() -> String:
	return "no gun" if _loadout == null else _loadout.weapon_line()
