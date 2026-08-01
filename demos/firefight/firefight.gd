class_name FirefightDemo
extends Node3D
## THE FIREFIGHT. Three factions, seven pieces of ground, and no way in for you.
##
## You are a camera. Nothing in this scene can see you, shoot you or path around
## you — the spectator has no body, no collider and no `AITarget`, so as far as
## every agent here is concerned the arena is empty of people who are not at war.
## That is the point: this is the AI running with nobody's thumb on it.
##
## WHAT YOU CAN TOUCH. Six posts and a dial, all of them physical objects bolted
## to the ground. Look at one and press interact. Three of the posts sit over a
## faction's home ground, one over each neutral outpost; the tall mast in the
## middle tracks the fighting and its vane physically turns to point at whichever
## zone is most contested. The dial on the plinth beside it steps the simulation
## rate through five detents, and its needle is the only readout of what it is
## set to.
##
## The masts over every zone are the scoreboard. Full mast is held, half mast is
## contested, struck is unclaimed, and the colour is whose it is.
##
## F3 opens the engineering overlay if you want the numbers behind all that.
##
## MULTIPLAYER. Up to four of you watch the same war. The HOST runs every body,
## every shot and every capture; the other three receive them through
## `FirefightWarLink` and decide nothing — see `firefight_war_wire.gd` for what
## is actually on the wire and why it is so little. You see each other as
## translucent spheres with your names over them, because everybody here is a
## camera and not a person, and you see each other's laser dots on whatever you
## are pointing at. Fly to your friend's dot; that is the whole social mechanic
## of a spectator demo.
##
## Single player is untouched and does not open a socket.

## Router id. Registered at load if the shipped table does not already carry it.
const DEMO_ID: String = "firefight"
const DEMO_TITLE: String = "FIREFIGHT"
const DEMO_SCENE: String = "res://demos/firefight/firefight.tscn"
const DEMO_BLURB: String = "Three factions, seven pieces of ground, nobody's thumb on it."

@export var director_path: NodePath = NodePath("Director")
@export var spectator_path: NodePath = NodePath("Spectator")
@export var gunfire_path: NodePath = NodePath("Gunfire")
@export var vfx_path: NodePath = NodePath("Vfx")
var _director: FirefightDirector = null
var _spectator: FirefightSpectator = null
var _gunfire: FirefightGunfire = null
var _vfx: VfxService = null
var _war: FirefightWarLink = null


func _ready() -> void:
	if not SceneRouter.has_demo(DEMO_ID):
		SceneRouter.register_demo(DEMO_ID, DEMO_TITLE, DEMO_SCENE, DEMO_BLURB)
	_director = get_node_or_null(director_path) as FirefightDirector
	_spectator = get_node_or_null(spectator_path) as FirefightSpectator
	_gunfire = get_node_or_null(gunfire_path) as FirefightGunfire
	_vfx = get_node_or_null(vfx_path) as VfxService
	if _director == null or _spectator == null:
		push_error("FirefightDemo: director_path and spectator_path must resolve.")
		set_process(false)
		return
	_bind_markers()
	_bind_gunfire()
	_mount_war()
	_enter_presence.call_deferred()
	# Every control is in its group by now — `_ready` runs depth first and the
	# Fixtures branch is built before the Spectator is — but the spectator caches
	# that group once and never looks again, so confirming it after the wiring
	# pass is what makes the order an assertion rather than an assumption.
	_spectator.refresh_controls()
	CombatReticle.mount(self)
	# The director already publishes standings on its own slow tick. Listening to
	# that beats polling it every frame and beats keeping a second timer in step
	# with the first one.
	_director.standings_changed.connect(_on_standings_changed)


func _exit_tree() -> void:
	# Every note this demo posted, taken back down. The overlay is an autoload and
	# outlives the scene; leaving stale lines on it is how a debug HUD stops being
	# trusted.
	for key: StringName in [
		&"firefight",
		&"firefight_zones",
		&"firefight_ai",
		&"firefight_comms",
		&"firefight_cover",
		&"firefight_cover_why",
		&"firefight_net",
	]:
		DebugHUD.clear_note(key)


func _on_standings_changed(_owned: PackedInt32Array, _bodies: PackedInt32Array) -> void:
	if DebugHUD.is_overlay_visible():
		_publish_notes()


func _on_war_state() -> void:
	if DebugHUD.is_overlay_visible():
		_publish_notes()


## Markers need the director to know where the fight is. Only the tracking mast
## actually uses it, but handing it to all of them keeps the bake dumb.
func _bind_markers() -> void:
	for node in get_tree().get_nodes_in_group(&"firefight_control"):
		var marker := node as FirefightMarker
		if marker != null:
			marker.director = _director


func _bind_gunfire() -> void:
	if _gunfire == null:
		return
	# The hub is retuned for a battle on every machine — the tracer width and the
	# powder size are a matter of how far away this is watched from, and that is
	# the same everywhere. What is host-only is LISTENING to the bodies: a guest's
	# creatures never pull a trigger, and its tracers come off the wire instead.
	_gunfire.bind(_vfx, _director.targets())
	if not NetGame.is_authority():
		return
	for p: NodePath in _director.spawner_paths:
		var spawner := _director.get_node_or_null(p) as EnemySpawner
		if spawner != null:
			spawner.spawned.connect(_gunfire.watch)


## Stand the replication link up and hand it the three things it drives.
##
## MOUNTED AT RUNTIME RATHER THAN BAKED, for the same reason `CombatReticle` two
## lines below it is: it is a script and nothing else — no mesh, no shape, no
## resource — so there is nothing for a bake to write down, and
## `tools/build_firefight.gd` is already against this project's file-length
## ceiling. In single player `bind` returns having done nothing and the node
## sleeps, so the cost of it existing is one Node.
func _mount_war() -> void:
	_war = FirefightWarLink.new()
	_war.name = "War"
	add_child(_war)
	var dial: FirefightDial = null
	for node in get_tree().get_nodes_in_group(&"firefight_control"):
		if node is FirefightDial:
			dial = node
			break
	_war.bind(_director, _gunfire, dial)
	# On a guest the director's standings tick never runs, so the overlay would
	# never redraw. The state packet is the guest's equivalent heartbeat.
	_war.state_changed.connect(_on_war_state)


## Declare how players appear here: SPHERE, because everybody in this demo is a
## point of view and not a body. The eye is left null on purpose — the camera is
## a freecam that the markers fly and the viewer takes back with F8, so "whatever
## camera the viewport is using" is the only answer that stays true.
##
## DEFERRED, and it has to be. `NetPresence.instance()` parents itself to `/root`
## the first time anybody asks for it, and when this demo is the scene the engine
## was launched with, `/root` is still inside its own `add_child` while this
## `_ready` runs — measured: "Parent node is busy setting up children". One
## deferred call is the whole fix and it costs a frame nobody can see.
func _enter_presence() -> void:
	NetPresence.enter(NetPresence.SPHERE)


## Live bodies per faction, from whoever actually knows. On the host that is the
## director; a guest has no agents to count and reads the number off the wire.
## Zones are not in the same position — the ledger's OWNERS are replicated, so
## `zones_owned` is right on every machine.
func _standings() -> PackedInt32Array:
	var wire: PackedInt32Array = PackedInt32Array() if _war == null else _war.standings()
	if not wire.is_empty():
		return wire
	var out := PackedInt32Array()
	for f: int in Factions.COUNT:
		out.append(_director.body_count(f))
	return out


func _publish_notes() -> void:
	var bodies: PackedInt32Array = _standings()
	var standings: String = ""
	var live: int = 0
	for f: int in Factions.COUNT:
		var n: int = bodies[f] if f < bodies.size() else 0
		live += n
		standings += "%s %d/%d  " % [Factions.MARKS[f], _director.zones_owned(f), n]
	DebugHUD.note(
		&"firefight",
		(
			"FIREFIGHT  %d bodies  %.0f fps  x%.2f"
			% [live, Engine.get_frames_per_second(), Engine.time_scale]
		)
	)
	DebugHUD.note(&"firefight_zones", "zones/bodies  " + standings.strip_edges())
	_publish_ai_notes()
	_publish_cover_notes()


## The comms transcript and the cover ledger. These two used to be written by the
## director on its own command tick, whether or not the overlay was up and never
## taken down again; they are here now because this file is what owns the
## lifetime of every other note the demo posts. Both read public accessors only.
func _publish_cover_notes() -> void:
	var said: int = 0
	for n: int in _director.callouts():
		said += n
	var log_line: String = " ".join(_director.callout_log())
	DebugHUD.note(&"firefight_comms", "comms  %d said  %s" % [said, log_line])
	var claims: Vector2i = _director.cover_claims()
	var points: int = 0 if _director.cover_set == null else _director.cover_set.size()
	var paths: AIPathService = _director.path_service()
	DebugHUD.note(
		&"firefight_cover",
		(
			"cover  %d vantage / %d held of %d points  %d crossing  %d crossed"
			% [claims.x, claims.y, points, paths.traversing(), paths.crossings_total()]
		)
	)
	# WHY the meter above reads what it reads. A cover count on its own says
	# nothing about which of the scoring gates is eating the field, and tuning a
	# weight without this line is guessing at which one to turn.
	var why: String = _director.cover_report()
	if not why.is_empty():
		DebugHUD.note(&"firefight_cover_why", "cover  " + why)
	if _war != null and _war.is_streaming():
		DebugHUD.note(&"firefight_net", _war.wire_line())


## The tick budget. On a guest every bucket is empty and `paths queued` is zero,
## and that is the honest reading: a guest runs no AI at all.
func _publish_ai_notes() -> void:
	var sched: AITickScheduler = _director.scheduler()
	(
		DebugHUD
		. note(
			&"firefight_ai",
			(
				"AI near %d mid %d far %d dormant %d  paths queued %d  shots %d"
				% [
					sched.bucket_population(AITickScheduler.NEAR),
					sched.bucket_population(AITickScheduler.MID),
					sched.bucket_population(AITickScheduler.FAR),
					sched.bucket_population(AITickScheduler.DORMANT),
					_director.path_service().queued(),
					0 if _gunfire == null else _gunfire.shots_fired(),
				]
			)
		)
	)
