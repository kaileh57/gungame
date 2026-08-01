extends SceneTree
## Runs the baked arena for real and reports what happened.
##
## Loading a scene proves the resources resolve. It does not prove the demo works,
## and the failures that matter here are all runtime ones: a spawner with no
## profiles, a gate facing the wrong way, a brain that never leaves IDLE because
## nothing was ever added to the target index. So this throws the levers the
## player would throw and then watches.
##
## Run headless:
##   godot --headless --path <project> --script res://demos/arena/tests/verify_arena.gd
##
## Headless has no rasteriser, so the millisecond figures below are the CPU side
## only — physics, the director and the rigs. That is the half this demo can
## actually blow, and it is the half worth measuring here.

const SCENE_PATH: String = "res://demos/arena/arena.tscn"
const REPORT_PATH: String = "res://demos/arena/arena_verify.txt"

## The three faction spawners, by node name, in faction order.
##
## SPELLED OUT RATHER THAN READ OFF `Factions`. A script handed to `--script`
## compiles before any autoload exists, and naming one fails the whole dependency
## chain behind this file. Same reason `tools/build_arena.gd` carries its own
## copy — and if these two ever disagree, the "one spawner per faction" check
## below is what says so.
const SPAWNER_NAMES: PackedStringArray = ["SpawnerScav", "SpawnerFoundry", "SpawnerChoir"]
## `Factions.NAMES`, for the same reason.
const FACTION_LABELS: PackedStringArray = ["SCAV", "FOUNDRY", "CHOIR"]

## Frames given to the scene before anything is asked of it.
const WARMUP_FRAMES: int = 20
## Frames the wave is watched for. Ninety seconds: long enough for the slowest
## thing in the bestiary to walk in from a gate, cross the compound, find cover
## and open fire, with a big wave still trickling for the first fifteen.
const FIGHT_FRAMES: int = 5400
## Detent the COUNT dial is turned to for the main wave. Negative counts back from
## the stop, so this asks for the LAST rung — whatever this arena's measured
## `population_cap` turns out to be — without the harness carrying a copy of it.
const WAVE_DETENT: int = -1
## MIX dial detent for the main wave. 2 is THREE WAY: the wave is dealt across all
## three factions, which is what makes the faction-versus-faction bars meaningful.
const MIX_DETENT: int = 2
## Share of the asked-for wave that has to be standing in the compound before the
## population is called delivered. Not 100%: a body that walks in and is killed by
## a rival before the sample is taken is the demo working, not the spawner failing.
const POPULATION_BAR: float = 0.80
## Bodies that must have picked the PLAYER as their target at the peak. The arena
## is a test arena and the player is the interesting target; if a hundred bodies
## walk in and none of them come for you, the priority solve is not doing its job.
const ON_PLAYER_BAR: int = 4
## Bodies that must have been fighting somebody OTHER than the player at the peak.
## Both bars have to pass in the same run: prioritising the player is only correct
## if the factions still fight each other.
const BRAWL_BAR: int = 4
## Frames the live-fire phase gets to put a body down. The slowest thing the
## primary seed rolls is a 62 rpm semi-auto, and the target is moving and takes
## cover, so this is deliberately loose: a measured kill lands near 960.
const LIVE_FIRE_FRAMES: int = 1600
## Second of the soak the first occupancy plan is printed at. Ten: the wave is in
## the room by then and the first casualties have not yet thinned it.
const PLAN_AT_SECOND: int = 10
## Physics frames one aim-then-click cycle spends. One to turn the eye, two with the
## button down, one to release — the shortest pull a `_unhandled_input` rig can see.
const PULL_FRAMES: int = 4

var _lines: PackedStringArray = PackedStringArray()
var _failed: bool = false
var _started: bool = false
var _shots: int = 0
var _enemy_hits: int = 0
var _enemy_damage: float = 0.0
## Soak options, off unless `--soak` was given. See the header.
var _soak: bool = false
var _soak_count: int = 0
var _soak_mix: int = 1
var _soak_seconds: float = 60.0
var _soak_warm: bool = false


func _process(_delta: float) -> bool:
	if not _started:
		_started = true
		_parse_args(OS.get_cmdline_user_args())
		_run()
	return false


func _parse_args(args: PackedStringArray) -> void:
	for a: String in args:
		if a == "--soak":
			_soak = true
		elif a.begins_with("--count="):
			# Zero means "whatever the arena's cap is", which is the usual ask.
			_soak_count = maxi(a.substr(8).to_int(), 0)
		elif a.begins_with("--mix="):
			_soak_mix = clampi(a.substr(6).to_int(), 1, 3)
		elif a.begins_with("--seconds="):
			_soak_seconds = maxf(a.substr(10).to_float(), 1.0)
		elif a == "--warm":
			_soak_warm = true


func _run() -> void:
	var packed: PackedScene = load(SCENE_PATH) as PackedScene
	if packed == null:
		_fail("%s did not load" % SCENE_PATH)
		_finish()
		return
	var arena: Node = packed.instantiate()
	root.add_child(arena)
	current_scene = arena
	for _i: int in WARMUP_FRAMES:
		await physics_frame
	if _soak:
		await _soak_population(arena)
		_finish()
		return

	var station: Node = arena.get_node_or_null(^"Compound/Station")
	var director: Node = arena.get_node_or_null(^"Director")
	var player: Node = arena.get_node_or_null(^"Player")
	var spawners: Array[Node] = []
	for node_name: String in SPAWNER_NAMES:
		var s: Node = arena.get_node_or_null(NodePath(node_name))
		if s != null:
			spawners.append(s)
	_check(station != null, "control station is in the scene")
	_check(spawners.size() == SPAWNER_NAMES.size(), "one spawner per faction is in the scene")
	_check(director != null, "director is in the scene")
	_check(player != null, "baked player is in the scene")
	_check(
		player != null and player.get_node_or_null(^"Target") != null,
		"the player carries an AITarget"
	)
	_check(
		player != null and player.get_node_or_null(^"Eye/Holster") != null,
		"the player carries a holster"
	)
	if station == null or spawners.is_empty() or director == null:
		_finish()
		return

	# The player's own gun, before anything else happens. `WeaponHolster` only emits
	# `weapon_changed` at the end of a SWAP, and rolling the first gun into an empty
	# slot is not a swap — a rig that listens for that signal alone never calls
	# `Weapon.setup`, so `_spec` stays null, `tick()` returns before the fire control
	# and the trigger is dead from spawn to the first weapon change. That is a silent
	# failure with no error in the console, which is exactly what a gate is for.
	var loadout: Node = arena.get_node_or_null(^"Loadout")
	var weapon: Node = null if loadout == null else loadout.call(&"weapon") as Node
	_check(weapon != null, "the loadout built a Weapon")
	_check(weapon != null and weapon.call(&"spec") != null, "the gun has a spec from spawn")
	_check(
		weapon != null and bool(weapon.call(&"is_ready_to_fire")),
		"the gun is ready to fire from spawn"
	)
	if weapon != null and weapon.call(&"spec") != null:
		var spec: Resource = weapon.call(&"spec") as Resource
		_say(
			(
				"primary               %s  %d rnd  %s rpm  %s"
				% [
					spec.get(&"weapon_name"),
					int(weapon.call(&"ammo").capacity()),
					str(spec.get(&"rpm")),
					"auto" if bool(spec.get(&"automatic")) else "semi",
				]
			)
		)
		_say("muzzle                %s" % str(weapon.call(&"muzzle_node")))

	_say("cover points          %d" % _cover_size(director))
	_say("station selection     %s" % station.call(&"selected_species_label"))
	var idle_cpu: Vector2 = await _sample(120)
	_say("empty compound cpu    %.3f ms physics  %.3f ms idle" % [idle_cpu.x, idle_cpu.y])

	# Throw the levers a player would: turn COUNT to its stop, MIX to THREE WAY,
	# then SPAWN. The stop is whatever `population_cap` is, read back off the dial
	# rather than assumed, so this harness cannot fall out of step with the cap.
	var count_dial: Node = station.get_node(^"CountDial")
	var detents: int = (count_dial.get(&"options") as PackedStringArray).size()
	var detent: int = detents + WAVE_DETENT if WAVE_DETENT < 0 else WAVE_DETENT
	count_dial.call(&"set_value", float(clampi(detent, 0, detents - 1)))
	station.get_node(^"MixDial").call(&"set_value", float(MIX_DETENT))
	var asked: int = int(station.call(&"selected_count"))
	var arena_cap: int = int(arena.call(&"capacity"))
	_say("count detents         %d, stop reads %s" % [detents, count_dial.call(&"selected_text")])
	_say("arena capacity        %d" % arena_cap)
	_check(asked > 0, "the COUNT dial's stop asks for a wave")
	_check(asked == arena_cap, "the COUNT dial's stop IS the arena's capacity")
	station.get_node(^"SpawnLever").call(&"set_on", true)
	await physics_frame

	var peak: int = 0
	var gate_seen: bool = false
	var engaged_peak: int = 0
	var on_player_peak: int = 0
	var brawl_peak: int = 0
	var factions_seen: int = 0
	var knows_peak: int = 0
	var alert_peak: int = 0
	var physics_ms: float = 0.0
	var process_ms: float = 0.0
	var worst_physics: float = 0.0
	for _i: int in FIGHT_FRAMES:
		await physics_frame
		peak = maxi(peak, int(arena.call(&"alive_count")))
		gate_seen = gate_seen or _any_gate_moved(arena)
		engaged_peak = maxi(engaged_peak, _engaged(director))
		var focus: Vector2i = director.call(&"focus_counts")
		on_player_peak = maxi(on_player_peak, focus.x)
		brawl_peak = maxi(brawl_peak, focus.y)
		factions_seen = maxi(factions_seen, _factions_present(director))
		var known: Vector2i = director.call(&"player_awareness_counts")
		knows_peak = maxi(knows_peak, known.x)
		alert_peak = maxi(alert_peak, known.y)
		# Wall time between two awaited frames is the physics tick rate, not the
		# work; the engine's own monitors are the only honest source here.
		var step: float = Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
		physics_ms += step
		worst_physics = maxf(worst_physics, step)
		process_ms += Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0

	var n: float = float(FIGHT_FRAMES)
	var counts: PackedInt32Array = director.call(&"faction_counts")
	_say("wave requested        %d over %d factions" % [asked, MIX_DETENT + 1])
	_say("peak alive            %d of %d asked" % [peak, asked])
	_say("still queued          %d" % int(arena.call(&"pending_count")))
	_say("bodies by faction     %s" % ", ".join(_ints(counts)))
	_say("peak engaged          %d" % engaged_peak)
	_say("peak knowing you      %d  (alert to you %d)" % [knows_peak, alert_peak])
	_say("peak coming for you   %d" % on_player_peak)
	_say("ever came for you     %d" % int(director.call(&"ever_on_player")))
	_say("peak fighting rivals  %d" % brawl_peak)
	_say(
		(
			"rounds on the player  %d for %.1f damage"
			% [int(director.call(&"player_hits")), float(director.call(&"player_damage"))]
		)
	)
	_say("director summary      %s" % director.call(&"summary"))
	for line: String in director.call(&"describe_agents"):
		_say("  %s" % line)
	_say("mean physics cpu      %.3f ms" % (physics_ms / n))
	_say("worst physics frame   %.3f ms" % worst_physics)
	_say("mean idle cpu         %.3f ms" % (process_ms / n))
	_say("cpu budget at 120 fps 8.333 ms")
	_check(peak > 0, "the wave walked in through the gates")
	_check(gate_seen, "at least one gate opened")
	_check(
		float(peak) >= float(asked) * POPULATION_BAR,
		"the compound held %d%% of the wave it was asked for" % roundi(POPULATION_BAR * 100.0)
	)
	_check(factions_seen == MIX_DETENT + 1, "the wave arrived as a %d-way brawl" % (MIX_DETENT + 1))
	_check(engaged_peak > 0, "the wave found something and engaged")
	_check(
		on_player_peak >= ON_PLAYER_BAR, "at least %d bodies came for the player" % ON_PLAYER_BAR
	)
	_check(brawl_peak >= BRAWL_BAR, "at least %d bodies fought each other" % BRAWL_BAR)
	_check(int(director.call(&"shots_fired")) > 0, "the wave opened fire")
	_check(int(director.call(&"player_hits")) > 0, "their rounds reached the player")

	station.get_node(^"ClearLever").call(&"set_on", true)
	for _i: int in 60:
		await physics_frame
	_check(int(arena.call(&"alive_count")) == 0, "the clear lever emptied the compound")

	if weapon != null:
		await _live_fire(arena, station, spawners[0], weapon)
		await _reroll(loadout, weapon)
	_finish()


## Hold a population and report what it costs, once a second.
##
## THIS IS THE MODE THAT FINDS THE CEILING, and it is separate from the gate above
## because the two want opposite things: the gate wants a three-way brawl, and a
## three-way brawl eats itself — measured, ninety-four bodies fall to twenty-one
## inside eighty seconds, so the population is never held long enough to price.
## `--mix=1` puts the whole wave on ONE faction, which nothing kills but the
## player, and the number on the left of the table below is then a real
## population rather than the top of a decay curve.
##
## RUN IT WITH THE RENDERER UP. `--script` without `--headless` gives a real
## window and a real frame rate; headless reports fps 0 and only the CPU columns
## mean anything, which is stated in the report rather than left to be noticed.
##
##   godot --path <project> --resolution 1600x900 \
##       --script res://demos/arena/tests/verify_arena.gd -- \
##       --soak --count=64 --mix=1 --seconds=60
func _soak_population(arena: Node) -> void:
	var station: Node = arena.get_node_or_null(^"Compound/Station")
	var director: Node = arena.get_node_or_null(^"Director")
	if station == null or director == null:
		_fail("the soak needs a station and a director")
		return
	var cap: int = int(arena.call(&"capacity"))
	var want: int = mini(_soak_count if _soak_count > 0 else cap, cap)
	station.call(&"set_count_ceiling", cap)
	station.get_node(^"MixDial").call(&"set_value", float(_soak_mix - 1))
	# The ladder is coarse, so ask for the detent nearest what was requested and
	# report what was actually asked for rather than what was typed.
	var dial: Node = station.get_node(^"CountDial")
	var labels: PackedStringArray = dial.get(&"options")
	var best: int = 0
	for i: int in labels.size():
		if absi(labels[i].to_int() - want) < absi(labels[best].to_int() - want):
			best = i
	dial.call(&"set_value", float(best))
	if _soak_warm:
		await _warm_pools(station, arena)
	station.get_node(^"SpawnLever").call(&"set_on", true)
	_say(
		(
			"soak                  %s bodies, mix %d, %.0f s%s  (cpu only; fps via watch.tscn)"
			% [
				dial.call(&"selected_text"),
				_soak_mix,
				_soak_seconds,
				", pools pre-warmed" if _soak_warm else ", pools COLD",
			]
		)
	)
	_say("   t   alive  engaged  on you  brawl  rounds  hits   phys ms   worst")
	var seconds: int = int(ceil(_soak_seconds))
	for s: int in seconds:
		var phys: float = 0.0
		var worst: float = 0.0
		for _f: int in 60:
			await physics_frame
			var step: float = Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
			phys += step
			worst = maxf(worst, step)
		var focus: Vector2i = director.call(&"focus_counts")
		var parts: PackedStringArray = director.call(&"summary").split(" ", false)
		# The plan, twice: once while the wave is still walking in and once at the
		# end. Piling in a doorway and deploying across the compound produce the
		# same population count and completely different plans.
		if s == PLAN_AT_SECOND or s == seconds - 1:
			for line: String in _occupancy(arena):
				_say(line)
		_say(
			(
				"%4d   %5d  %7d  %6d  %5d  %6d  %4d  %8.3f  %7.3f"
				% [
					s + 1,
					int(arena.call(&"alive_count")),
					int(parts[0]),
					focus.x,
					focus.y,
					int(director.call(&"shots_fired")),
					int(director.call(&"player_hits")),
					phys / 60.0,
					worst,
				]
			)
		)


## Where the bodies actually ARE, as a coarse plan of the compound.
##
## A frame cannot answer this. The arena is 76 by 60 metres and the player stands
## at one end of it with a 78-degree lens, so the two side doors are outside the
## field of view entirely and a body at the far wall is twenty pixels tall — a
## screenshot of sixty bodies and a screenshot of six look the same. What a
## ninety-body wave actually fails at is piling in a doorway, and that is a
## question about the plan, so this prints the plan: one character per 8 by 6
## metre cell, `.` empty, digits, `+` for ten or more, `P` where the player is.
func _occupancy(arena: Node) -> PackedStringArray:
	const COLS: int = 10
	const ROWS: int = 10
	const HALF_X: float = 40.0
	const HALF_Z: float = 32.0
	var counts := PackedInt32Array()
	counts.resize(COLS * ROWS)
	for n: Node in get_nodes_in_group(&"ai_target"):
		var t := n as Node3D
		if t == null or not bool(t.get(&"alive")):
			continue
		var c: int = clampi(
			int((t.global_position.x + HALF_X) / (HALF_X * 2.0 / COLS)), 0, COLS - 1
		)
		var r: int = clampi(
			int((t.global_position.z + HALF_Z) / (HALF_Z * 2.0 / ROWS)), 0, ROWS - 1
		)
		counts[r * COLS + c] += 1
	var out := PackedStringArray()
	out.append("  plan, north (-z) at the top, one cell = 8 x 6 m")
	for r: int in ROWS:
		var line: String = "  "
		for c: int in COLS:
			var k: int = counts[r * COLS + c]
			line += "." if k == 0 else ("+" if k >= 10 else str(k))
		out.append(line)
	var player := arena.get_node_or_null(^"Player") as Node3D
	if player != null:
		out.append("  player at %.0v" % player.global_position)
	return out


## Run the wave once and throw it away, so the measured wave finds a full pool.
##
## THE FIRST BIG WAVE IS NOT THE SAME EVENT AS THE SECOND and the difference is
## worth isolating. `EnemySpawner` builds its actors on demand — twelve species
## across three spawners, nothing prewarmed — so the first ninety-six bodies to
## walk in are ninety-six creature rigs being instantiated at fourteen a second.
## Measured on a quiet machine, that is 40-60 ms of physics and a frame rate of
## 22-30 fps for about six seconds, reproducibly, in all three runs. Everything
## after it comes off a free list. Without this flag the soak prices the pool and
## the population together and reports the pool.
func _warm_pools(station: Node, arena: Node) -> void:
	station.get_node(^"SpawnLever").call(&"set_on", true)
	for _i: int in 1200:
		await physics_frame
		if int(arena.call(&"pending_count")) == 0:
			break
	_say("warm-up wave          %d bodies built" % int(arena.call(&"alive_count")))
	station.call(&"rearm")
	station.get_node(^"ClearLever").call(&"set_on", true)
	for _i: int in 120:
		await physics_frame
	station.call(&"rearm")


## How many factions have a live body in the compound. A THREE WAY wave that
## arrives as one faction is a mix control that is not working.
func _factions_present(director: Node) -> int:
	var present: int = 0
	for c: int in director.call(&"faction_counts") as PackedInt32Array:
		if c > 0:
			present += 1
	return present


func _ints(values: PackedInt32Array) -> PackedStringArray:
	var out := PackedStringArray()
	for i: int in values.size():
		out.append(
			"%s %d" % [FACTION_LABELS[i] if i < FACTION_LABELS.size() else str(i), values[i]]
		)
	return out


## The half of the demo the AI harness cannot see: the PLAYER shooting. Brings in a
## fresh body on an empty compound, points the eye at it, clicks the mouse until it
## is down, and gates on the whole chain — trigger, magazine, tracer, damage, death.
func _live_fire(arena: Node, station: Node, spawner: Node, weapon: Node) -> void:
	var player := arena.get_node_or_null(^"Player") as Node3D
	var eye := arena.get_node_or_null(^"Player/Eye") as Camera3D
	if player == null or eye == null:
		_fail("the baked player has no Eye to aim down")
		return
	station.call(&"rearm")
	# One side only, so every body in this pass comes out of the spawner this
	# function is watching. The main pass leaves the MIX dial on THREE WAY.
	station.get_node(^"MixDial").call(&"set_value", 0.0)
	station.get_node(^"FactionDial").call(&"set_value", 0.0)
	station.get_node(^"CountDial").call(&"set_value", 2.0)
	station.get_node(^"SpawnLever").call(&"set_on", true)
	var actor: Node3D = null
	for _i: int in 900:
		await physics_frame
		var live: Array = spawner.call(&"live_actors")
		if not live.is_empty():
			actor = live[0] as Node3D
			break
	if actor == null:
		_fail("no body came in for the live-fire pass")
		return

	var hub: VfxService = VfxService.hub()
	var tracers_before: int = 0 if hub == null else hub.counters()[0]
	var loaded_before: int = int(weapon.call(&"ammo").loaded())
	var loaded_low: int = loaded_before
	var health_before: float = float(actor.get(&"health"))
	var species: String = String(actor.get(&"species_id"))
	_shots = 0
	_enemy_hits = 0
	_enemy_damage = 0.0
	weapon.connect(&"fired", _on_player_fired)
	weapon.connect(&"hit", _on_player_hit)

	var killed: bool = false
	var frames: int = 0
	var reach: float = 0.0
	while frames < LIVE_FIRE_FRAMES:
		if not is_instance_valid(actor) or not bool(actor.get(&"alive")):
			killed = true
			break
		# Track it: an AI closing on the player has to be re-laid every pull.
		_aim_at(player, eye, actor.global_position + Vector3(0.0, 0.7, 0.0))
		reach = eye.global_position.distance_to(actor.global_position)
		await physics_frame
		_click(true)
		await physics_frame
		await physics_frame
		_click(false)
		await physics_frame
		frames += PULL_FRAMES
		loaded_low = mini(loaded_low, int(weapon.call(&"ammo").loaded()))
	_click(false)
	weapon.disconnect(&"fired", _on_player_fired)
	weapon.disconnect(&"hit", _on_player_hit)

	var health_after: float = float(actor.get(&"health")) if is_instance_valid(actor) else 0.0
	var tracers: int = (0 if hub == null else hub.counters()[0]) - tracers_before
	_say("live fire target      %s at %.1f m" % [species, reach])
	_say("player shots          %d in %d frames" % [_shots, frames])
	_say("magazine              %d -> %d" % [loaded_before, loaded_low])
	_say("rounds on the body    %d for %.1f damage" % [_enemy_hits, _enemy_damage])
	_say("tracers drawn         %d" % tracers)
	_say("target health         %.1f -> %.1f" % [health_before, health_after])
	_check(_shots > 0, "the player's gun put rounds downrange")
	_check(loaded_low < loaded_before, "firing spent the magazine")
	_check(tracers > 0, "the shots reached the tracer pool")
	_check(_enemy_hits > 0, "the player's rounds landed on the body")
	_check(_enemy_damage > 0.0, "those rounds carried damage")
	_check(health_after < health_before, "the body lost health")
	_check(killed, "the body went down under the player's gun")


## Scavenging a fresh primary is what this demo is for, and it takes the other path
## through the holster — a real stow-and-draw ending in `_exchange()`. A gun that
## came up on that path has to be as live as the one the demo booted with.
func _reroll(loadout: Node, weapon: Node) -> void:
	var was: Resource = weapon.call(&"spec") as Resource
	var rolled: Resource = loadout.call(&"reroll_primary", "") as Resource
	# The swap is stow-then-draw and mass-scaled; two seconds covers the heaviest.
	for _i: int in 150:
		await physics_frame
	var now: Resource = weapon.call(&"spec") as Resource
	_say("rerolled              %s -> %s" % [was.get(&"weapon_name"), rolled.get(&"weapon_name")])
	_check(now == rolled, "the rerolled gun reached the weapon")
	_check(bool(weapon.call(&"is_ready_to_fire")), "the rerolled gun is ready to fire")
	_shots = 0
	weapon.connect(&"fired", _on_player_fired)
	for _i: int in 4:
		_click(true)
		for _f: int in 40:
			await physics_frame
		_click(false)
		for _f: int in 8:
			await physics_frame
	weapon.disconnect(&"fired", _on_player_fired)
	_say("shots after reroll    %d" % _shots)
	_check(_shots > 0, "the rerolled gun fires")


func _on_player_fired(_origin: Vector3, _direction: Vector3, _spec: GunSpec) -> void:
	_shots += 1


## Only rounds that reached a creature count. The compound wall is behind every
## target in this demo, so counting every impact would pass on a total miss.
func _on_player_hit(collider: Object, _at: Vector3, _normal: Vector3, damage: float) -> void:
	var node: Node = collider as Node
	var depth: int = 0
	while node != null and depth < 4:
		if node.has_method(&"apply_bullet_damage") and node.get(&"species_id") != null:
			_enemy_hits += 1
			_enemy_damage += damage
			return
		node = node.get_parent()
		depth += 1


## Lay the eye on a world point the way the mouse would. `PlayerController` defines
## yaw 0 as facing -Z with forward `(-sin yaw, 0, -cos yaw)`, so the yaw that points
## at an offset is `atan2(-x, -z)` and nothing else.
func _aim_at(player: Node3D, eye: Camera3D, at: Vector3) -> void:
	var to: Vector3 = at - eye.global_position
	if to.length_squared() < 1.0e-6:
		return
	player.set(&"yaw", atan2(-to.x, -to.z))
	player.set(&"pitch", atan2(to.y, Vector2(to.x, to.z).length()))


## A real left mouse button, which is what `fire` is bound to in `project.godot`.
## `Input.action_press` would move the polled action state but never raise an
## `InputEvent`, so a rig that reads its trigger in `_unhandled_input` would look
## broken when it is not — the arena polls, the ash flats rig does not.
func _click(down: bool) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = down
	event.button_mask = MOUSE_BUTTON_MASK_LEFT if down else 0
	Input.parse_input_event(event)


func _cover_size(director: Node) -> int:
	var cover: Resource = director.get(&"cover_set") as Resource
	return 0 if cover == null else int(cover.call(&"size"))


## Mean physics and idle CPU over `frames`, in milliseconds. Wall time between two
## awaited frames is the tick rate rather than the work, so the engine's own
## monitors are the only honest source.
func _sample(frames: int) -> Vector2:
	var physics: float = 0.0
	var idle: float = 0.0
	for _i: int in frames:
		await physics_frame
		physics += Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
		idle += Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
	return Vector2(physics / float(frames), idle / float(frames))


func _engaged(director: Node) -> int:
	var text: String = director.call(&"summary")
	return int(text.split(" ")[0])


func _any_gate_moved(arena: Node) -> bool:
	for node: Node in arena.get_node(^"Compound").get_children():
		if node.has_method(&"is_open") and bool(node.call(&"is_open")):
			return true
	return false


func _check(condition: bool, what: String) -> void:
	_say("%s  %s" % ["pass" if condition else "FAIL", what])
	if not condition:
		_failed = true


func _fail(message: String) -> void:
	_failed = true
	_say("FAIL  %s" % message)


func _say(line: String) -> void:
	_lines.append(line)
	print(line)


func _finish() -> void:
	var text: String = "\n".join(_lines) + "\n"
	var file: FileAccess = FileAccess.open(REPORT_PATH, FileAccess.WRITE)
	if file != null:
		file.store_string(text)
		file.close()
	print("verify_arena: %s" % ("FAILED" if _failed else "PASS"))
	quit(1 if _failed else 0)
