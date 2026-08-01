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
	for key: StringName in [&"firefight", &"firefight_zones", &"firefight_ai"]:
		DebugHUD.clear_note(key)


func _on_standings_changed(_owned: PackedInt32Array, _bodies: PackedInt32Array) -> void:
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
	_gunfire.bind(_vfx, _director.targets())
	for p: NodePath in _director.spawner_paths:
		var spawner := _director.get_node_or_null(p) as EnemySpawner
		if spawner != null:
			spawner.spawned.connect(_gunfire.watch)


func _publish_notes() -> void:
	var standings: String = ""
	for f: int in Factions.COUNT:
		standings += (
			"%s %d/%d  " % [Factions.MARKS[f], _director.zones_owned(f), _director.body_count(f)]
		)
	(
		DebugHUD
		. note(
			&"firefight",
			(
				"FIREFIGHT  %d bodies  %.0f fps  x%.2f"
				% [
					_director.live_count(),
					Engine.get_frames_per_second(),
					Engine.time_scale,
				]
			)
		)
	)
	DebugHUD.note(&"firefight_zones", "zones/bodies  " + standings.strip_edges())
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
