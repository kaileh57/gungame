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
## Metres from the baked spawn mark the other three players are stood, so four
## people do not start the demo inside one another. `MASK_PLAYER_MOVE` does not
## include `PLAYER`, so overlapping is not a collision problem — it is a "whose
## capsule am I looking at" problem, and one and a half metres solves it.
const SPAWN_RING: float = 1.5

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
## Ceiling on live bodies while there is a session, which replaces `population_cap`
## for as long as there is one. FAR LOWER, and the reason is bandwidth rather than
## frame time.
##
## Every body is a row in a snapshot fifteen times a second: an id, a species and
## faction byte, a position, a yaw and a health byte, which is 26 bytes on the wire.
## Ninety-six of them is 37 kB/s to ONE client and 112 kB/s to three, which is more
## upstream than a domestic connection reliably has and all of it on the machine
## that is also running every brain in the compound. Thirty-two is 12 kB/s a client,
## 37 kB/s to a full lobby, and still more bodies than four people can hold a line
## against. The COUNT dial's last detent follows this automatically, so the knob
## still cannot ask for a wave the arena will not deliver.
@export_range(1, 256, 1) var network_population_cap: int = 32
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
## Draw and sound the fire coming AT you, and put it on the HUD's threat ring. See
## `ArenaThreat` for what was wrong without it, which was everything.
@export var show_incoming_fire: bool = true

var _director: ArenaDirector = null
## The multiplayer half of this demo. Always built, and idle when there is no
## session — see `ArenaNet`. Everything below routes its intent through it rather
## than testing for a network itself.
var _net: ArenaNet = null
## The local player's own health node, installed by `PlayerController`. Held so the
## host can read its tuning for everybody and so a client can be told what it is.
var _health: PlayerHealth = null
## Every player's position, rewritten in place each tick and handed to the director
## as the set of things idle bodies creep toward.
var _hunt_points: PackedVector3Array = PackedVector3Array()
## Indexed by faction id. Entries may be null if the scene was built wrong; every
## read goes through `_spawner_for`.
var _spawners: Array[EnemySpawner] = []
var _station: ArenaStation = null
var _loadout: ArenaLoadout = null
var _player: PlayerController = null
var _hud: CombatHud = null
var _gates: Array[ArenaGate] = []
## Incoming fire: the VFX, the voice and the HUD threat ring for every round that
## comes at the player. Built here rather than baked so a re-bake of the scene
## cannot lose it.
var _threat: ArenaThreat = null
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
	_health = _find_health()
	_resolve_gates()
	_wire()
	_build_threat()
	_build_hands()
	_net = ArenaNet.attach(self)
	_net.bind(self, _director, _station, _spawners, _player, _health, _hud)
	# A client's puppets do not pull their own triggers; their fire arrives as a
	# replicated event. This is the seam that turns those events back into rounds you
	# can see and hear, so the fourth player in a lobby gets the same answer to
	# "who is shooting me" the host does.
	_net.watch_incoming(_threat)
	_place_player()
	_enter_presence.call_deferred()
	_director.register_viewer(_player.get_node_or_null(^"Eye") as Node3D)
	_director.set_aggression(_station.selected_aggression())
	if NetGame.is_authority():
		_station.set_count_ceiling(capacity())
		_station.set_roster(0, capacity())
	set_physics_process(true)


## FULL presence: capsules with sunglasses, nameplates, laser dots and a collider
## the compound's own bodies walk around. The arena is a room four people stand in
## and shoot across, which is exactly what full presence is for.
##
## DEFERRED, and it has to be. `NetPresence.instance()` adds itself to `/root`, and
## `/root` is in the middle of adding THIS scene while `_ready` runs — Godot refuses
## an `add_child` on a parent that is busy setting up children, so calling it inline
## leaves the presence node orphaned and every avatar with it. MEASURED on a direct
## launch of `arena.tscn`: "Parent node is busy setting up children" out of
## `net_presence.gd:141`, and four leaked objects at exit. One frame later the swap
## has finished, which is still before anything could have seen an avatar.
func _enter_presence() -> void:
	NetPresence.enter(NetPresence.FULL, _player.get_node_or_null(^"Eye"))


## The player's own health node. `PlayerController` installs one from its own
## `@onready`, so it exists by the time this runs whatever the scene authored.
func _find_health() -> PlayerHealth:
	for child: Node in _player.get_children():
		var found := child as PlayerHealth
		if found != null:
			return found
	return null


## Four people cannot start on one mark. The host keeps the baked spawn and the
## other three are dealt positions around it, which is also where each of them
## respawns: `set_spawn` is the mark `PlayerController.respawn` teleports to, and
## `PlayerHealth.claim_spawn_point` reads the body's position on the first physics
## tick — after this — so the two cannot disagree.
func _place_player() -> void:
	if not NetGame.is_networked() or _player == null:
		return
	var slot: int = NetGame.local_player().slot
	if slot <= 0:
		return
	var angle: float = TAU * float(slot) / float(NetPlayer.MAX_PLAYERS)
	var to: Vector3 = _player.global_position + Vector3(sin(angle), 0.0, cos(angle)) * SPAWN_RING
	_player.teleport(to, _player.yaw)
	_player.set_spawn(to, _player.yaw)


## The incoming-fire reader. Fed from two seams and it needs both: `_on_actor_fired`
## on the AUTHORITY — the host, and also single player — where a real body really
## pulled a trigger, and `ArenaNetBodies.apply_events` on a CLIENT, where the same
## shot arrives as a replicated event and is reconstructed by
## `ArenaThreat.note_replayed_shot`. Built before `ArenaNet` so it can be handed
## down, and built here rather than baked so a re-bake of the scene cannot lose it.
func _build_threat() -> void:
	if not show_incoming_fire:
		return
	_threat = ArenaThreat.new()
	_threat.name = "Threat"
	add_child(_threat)
	_threat.bind(_player, _hud, _health)


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
	_hands.actuated.connect(_on_hands_actuated)
	add_child(_hands)


## THE HOST RUNS THE COMPOUND. A client's copy of this node holds a player, a gun
## and a desk it can work, and nothing else: the wave, the director and the numbers
## on the screen all arrive over the wire. `is_authority()` is true in single player,
## so this is the same one path the demo has always taken.
func _physics_process(delta: float) -> void:
	if NetGame.is_authority():
		_advance_wave(delta)
		_director.set_hunt_points(_player_points())
		_station.set_roster(alive_count(), capacity())
		_station.set_status(_director.summary())
	DebugHUD.note(
		&"arena_hold", "arena  %s  %s" % [_station.selected_species_label(), _loadout_line()]
	)


## Where everybody is standing, rewritten in place. In single player this is the one
## body and the array never grows; in a session it is however many avatars
## `NetPresence` has built, which is the roster minus anyone who has not arrived.
func _player_points() -> PackedVector3Array:
	var n: int = 1
	_hunt_points.resize(1)
	_hunt_points[0] = _player.global_position
	if not NetGame.is_networked():
		return _hunt_points
	var presence: NetPresence = NetPresence.instance()
	if presence == null:
		return _hunt_points
	for who: NetPlayer in NetGame.players():
		if who.peer_id == NetGame.peer_id():
			continue
		var avatar: PlayerAvatar = presence.avatar_of(who.peer_id)
		if avatar == null or not avatar.visible:
			continue
		n += 1
		_hunt_points.resize(n)
		_hunt_points[n - 1] = avatar.global_position
	return _hunt_points


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
	var cap: int = population_cap
	if NetGame.is_networked():
		cap = mini(cap, network_population_cap)
	return mini(n, cap)


## Bodies still queued to walk in. The harness reads it to tell "the wave has not
## arrived yet" from "the wave was refused".
func pending_count() -> int:
	return _queue_species.size()


## Which gates are under orders to be open, one bit per gate in wiring order. Four
## bits of the desk packet, and the reason a client sees the doors a wave walks in
## through actually open.
func gate_mask() -> int:
	var mask: int = 0
	for i: int in _gates.size():
		if _gates[i].wants_open():
			mask |= 1 << i
	return mask


## Put the gates where the host says they are. `set_open` is idempotent on a settled
## gate, so this is free on every packet that changes nothing.
func apply_gates(mask: int) -> void:
	for i: int in _gates.size():
		_gates[i].set_open((mask & (1 << i)) != 0)


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
		# Every shot, not every hit: a round that reaches nothing is still a noise
		# the compound hears and a tracer the other three players see leave your
		# muzzle. `round_landed` only fires when something was struck.
		var weapon: Weapon = _loadout.weapon()
		if weapon != null:
			weapon.fired.connect(_on_weapon_fired)
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
	# `capacity()` and not `population_cap`: in a session the networked ceiling is
	# the binding one, and the gate has to refuse at the same number the COUNT
	# dial's stop promises.
	if alive_count() >= capacity():
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
	# A client's lever throw moves its own lever for the feel of it and is sent to
	# the host as a request; the wave itself is dealt once, here, on the machine
	# that owns the spawners.
	if not NetGame.is_authority():
		return
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
	if not NetGame.is_authority():
		return
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
	# A client's ladder is cut to the HOST's cap, which arrives with the desk state.
	# Its own quality preset decides how many bodies its own machine will hold, and
	# that is not a number the COUNT dial is allowed to promise.
	if NetGame.is_authority():
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
	# On a client this signal is `ArenaNetBodies` hatching a puppet out of the same
	# pool. It gets no brain, no squad and no post: it is a picture of a body the
	# host is simulating, and the snapshot is what moves it.
	if not NetGame.is_authority():
		return
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
	_net.note_spawn(actor)
	_watch(actor)


## Hook a body's death and its trigger so both reach the other three machines. Once
## per actor and not once per spawn: the pool recycles bodies, and `died` and
## `fired` survive the recycle exactly as the director's own hooks do.
func _watch(actor: EnemyActor) -> void:
	if actor.has_meta(&"arena_net_watched"):
		return
	actor.set_meta(&"arena_net_watched", true)
	actor.died.connect(_on_actor_died)
	actor.fired.connect(_on_actor_fired.bind(actor))


func _on_actor_died(actor: EnemyActor) -> void:
	_net.note_death(actor)


## A body pulled its trigger. Two consumers and they want different things: the
## network wants the aim point so the other machines can turn the body, and the
## threat reader wants the whole line so it can draw the round, sound it, and decide
## whether it came at you.
func _on_actor_fired(
	origin: Vector3, direction: Vector3, hit_position: Vector3, hit: Object, actor: EnemyActor
) -> void:
	_net.note_fire(actor, hit_position)
	if _threat != null:
		_threat.note_shot(actor, origin, direction, hit_position, hit)


## The next holding position in the rotation, or the body's own feet when the
## scene was built without any.
func _next_anchor(fallback: Vector3) -> Vector3:
	if patrol_anchors.is_empty():
		return fallback
	_anchor_cursor = (_anchor_cursor + 1) % patrol_anchors.size()
	return patrol_anchors[_anchor_cursor]


func _on_despawned(actor: EnemyActor) -> void:
	_net.note_despawn(actor)
	if NetGame.is_authority():
		_director.release(actor)


func _on_spawn_failed(species_id: StringName, reason: String) -> void:
	push_error("ArenaController: cannot spawn '%s' — %s" % [species_id, reason])
	if _hud != null:
		_hud.banner("SPAWN FAULT", 1.2)


## Every round the player lands. Controls first, because a knob is not a target and
## must not eat a damage number; then the feedback for everything else.
func _on_round_landed(collider: Object, at: Vector3, _normal: Vector3, damage: float) -> void:
	var control: DiegeticControl = _station.control_of(collider)
	if control != null:
		if _station.bullet_hit(collider, at, _loadout.control_power):
			_net.report_control(control, at, _loadout.control_power, false)
		return
	var actor: EnemyActor = _actor_of(collider)
	if actor == null:
		return
	# PREDICTION, on a client: the round has already been resolved against this
	# machine's own copy of the body, which is what makes the hit mark and the
	# number instant. The report is what makes it true. See `ArenaNet`.
	_net.report_hit(actor, damage, at, _shot_bearing(at), _crit())
	if _hud == null:
		return
	_hud.hit_mark(not actor.alive, false)
	if show_damage_pops:
		# What the body ACTUALLY took, not what the weapon offered. `report_hit` has
		# already resolved the round against this machine's copy, so armour and the zone
		# multiplier are both in by now.
		var landed: float = actor.damage_taken()
		_hud.pop(at, str(roundi(landed if landed > 0.0 else damage)))


## The direction the round was travelling, near enough for the host to reproduce
## the shot: eye to impact. Every consumer of it wants the bearing and not the
## range — `EnemyActor.apply_bullet_damage` steps one metre back along it to get a
## from-position — so the muzzle and the eye are interchangeable here.
func _shot_bearing(at: Vector3) -> Vector3:
	var eye: Node3D = _player.get_node_or_null(^"Eye") as Node3D
	var from: Vector3 = _player.global_position if eye == null else eye.global_position
	var dir: Vector3 = at - from
	return dir.normalized() if dir.length_squared() > 1.0e-6 else Vector3.FORWARD


## The headshot multiplier of the gun that fired, so the host applies the same zone
## bonus this machine just showed the shooter.
func _crit() -> float:
	var spec: GunSpec = _loadout.active_spec()
	return 1.0 if spec == null else spec.crit_multiplier


## A walk-up press landed on one of the desk's controls. It has already actuated
## here; the host is told so its own desk agrees, and everybody else is told by the
## host's next desk broadcast.
func _on_hands_actuated(control: DiegeticControl, _action: StringName) -> void:
	_net.report_control(control, control.global_position, 1.0, true)


## Every round this machine's gun sends downrange, wherever it ends up. The aim
## point is the one `NetPresence` already cast for the laser dot, so a tracer for
## the other three players costs no ray of its own.
func _on_weapon_fired(origin: Vector3, direction: Vector3, spec: GunSpec) -> void:
	if _net == null:
		return
	var to: Vector3 = origin + direction * ArenaNet.MISS_REACH
	var presence: NetPresence = NetPresence.instance()
	if presence != null and presence.aim_valid():
		to = presence.aim_point()
	_net.report_shot(to, float(spec.muzzle_energy))


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
