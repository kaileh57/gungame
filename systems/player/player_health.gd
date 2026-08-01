class_name PlayerHealth
extends Node
## The player's side of the fight: what a round takes off you, what that feels like,
## what happens when it runs out, and how you come back.
##
## Before this existed the player was a target the AI could see, aim at and hit, and
## every round that landed on it was silently thrown away. `AITarget.receive_damage`
## resolves `receiver_path` and forwards damage only `if _receiver.has_method(
## "apply_damage")`; nothing in `systems/player/` answered to that name, so the hit
## registered on the AI's side — the `damaged` signal fired, the shooter kept its
## mark — and cost the player nothing. MEASURED on the shipped arena, eight bodies,
## sixty seconds: **17 of 17 AI trigger pulls reached the player's `AITarget` and
## 518.25 points of damage were discarded**, with six bodies holding line of sight.
##
## So the fix is not "add a health int". The seam already existed and was already
## carrying traffic; what was missing was everything on this side of it.
##
## INSTALLED BY THE CONTROLLER, NOT BY A SCENE. `PlayerController` calls
## `PlayerHealth.install(self)` from its own `@onready`, which is what makes this
## work in EVERY demo that has a player rather than only in the one demo whose
## `.tscn` somebody remembered to edit. `install` is idempotent and adopts an
## authored `Health` node if a scene ever grows one.
##
## WHAT IT WIRES, ALL DUCK-TYPED so nothing here depends on the AI module, the HUD
## or the view rig compiling:
##
## - an `AITarget`, adopted if the scene baked one (the arena does) and built if not,
##   so the AI's target index sees a hittable body with a real silhouette;
## - `CombatHud.set_health()` — documented and unwired since the HUD was written —
##   plus its directional damage lobe and its camera, which the arena never set, so
##   the arena's damage numbers never drew either;
## - `PlayerViewEffects.add_damage()`, a full trauma-plus-punch model that has been
##   in the tree the whole time with no caller anywhere in the project;
## - the player's own `PlayerState`, so `state.health` and `state.dead` are readable
##   by anything that already reads the snapshot.
##
## REGENERATION POLICY: delayed, and it is deliberately unable to help you in a
## firefight. `regen_delay` is restarted by every single hit. MEASURED with the loop
## closed, same arena, 116 s, a player standing still and not shooting back: 74
## rounds landed for 1,700 points, one every ~1.6 s while upright, **14.7 hp/s
## sustained**. At the shipped 6.0 s delay the regen therefore NEVER starts while
## anybody is shooting at you — watched live, health falls 100 to 0 with no plateau
## in it — and 12 hp/s could not out-heal 14.7 even if it did. What it is for is the
## lull: in the same run health walked 51.7 to 68.5 across an eight-second gap
## between contacts. Without it the only way to reset health in a demo you re-enter
## over and over is to die, and with regen-during-contact the arena stops mattering.

## A hit landed and was resolved. `amount` is what actually came off after armour.
signal damaged(amount: float, from_position: Vector3, attacker: Node)
## Health changed for any reason, including regeneration and respawn.
signal health_changed(current: float, maximum: float)
## Health hit zero. The controller suspends input on this; a demo can react to it
## to run a score, a fade, or its own respawn.
signal died(from_position: Vector3, attacker: Node)
## Back on your feet with a full bar. Fires after `PlayerController.respawned`.
signal revived

## Sample rate of the synthesised feedback cues. A body thump is all bottom end;
## 22 kHz is more than the content needs and a quarter of the memory.
const CUE_RATE: int = 22050
## Nodes one lazy walk will look at while hunting for a HUD. Bounded because a
## town's node count is not.
const HUD_WALK_LIMIT: int = 1200
## How many times that walk is allowed to come back empty before it gives up. More
## than one because a demo may mount its HUD from code after the player exists —
## `RangeShooter` does — and one because a demo with no HUD must not pay for a walk
## on every hit for the rest of the level.
const HUD_ATTEMPTS: int = 6
## Nodes walked while hunting for the player's gun. The gun hangs off
## `Eye/Holster/Hand`, so this counts the whole player subtree down to it.
const WEAPON_WALK_LIMIT: int = 256

## Built once per process, shared by every player that ever exists. Two of them
## never share a scene; this is here so a demo reload does not re-synthesise.
static var _hit_cue: AudioStreamWAV = null
static var _death_cue: AudioStreamWAV = null

@export_group("Body")
## Full health. MEASURED per-round damage arriving at this node across 74 landed
## rounds in the arena: min 4.2, mean 23.0, max 88.7 — so 100 is a mean of 4.3
## rounds and a worst case of two. Turn this, `armour` or `damage_scale` if the
## arena is too sharp; the measurement is in the class doc so you can do it with a
## number rather than a feeling.
@export_range(1.0, 1000.0, 1.0) var max_health: float = 100.0
## Percentage of incoming damage plate turns away. IDENTICAL formula to
## `EnemyActor.apply_damage` — `amount * (1 - clamp(armour, 0, 95) * 0.01)` — so a
## point of damage means the same thing on both sides of the fight. Zero by
## default: the player wears none until a demo hands some out.
@export_range(0.0, 95.0, 1.0) var armour: float = 0.0
## Blanket multiplier on everything that reaches this node, before armour. The
## difficulty dial, and the one knob to turn if the arena is too sharp.
@export_range(0.0, 4.0, 0.05) var damage_scale: float = 1.0

@export_group("Regeneration")
## Off restores the pure attrition model. See the policy note in the class doc.
@export var regen_enabled: bool = true
## Seconds without taking a hit before health starts coming back. Restarted by
## every hit, which is what keeps regeneration out of a live firefight.
@export_range(0.0, 60.0, 0.1) var regen_delay: float = 6.0
## Health per second once it starts.
@export_range(0.0, 200.0, 0.5) var regen_rate: float = 12.0
## Fraction of `max_health` regeneration will climb to. Below one leaves a wound
## that only a respawn clears.
@export_range(0.0, 1.0, 0.01) var regen_ceiling: float = 1.0

@export_group("Death")
## Seconds the death state is held before the respawn. Long enough to read what
## killed you, short enough that it is not a punishment.
@export_range(0.0, 20.0, 0.05) var death_seconds: float = 2.4
## Seconds after a respawn during which damage is refused. MEASURED need: six
## bodies hold line of sight on the arena's spawn mark, so without this you can be
## killed again inside a second and never see the level.
@export_range(0.0, 20.0, 0.05) var spawn_protection: float = 1.5
## Drive the respawn from here. Off leaves the body dead and hands the whole
## sequence to whatever listens to `died`.
@export var auto_respawn: bool = true

@export_group("Feedback")
## Screen-edge vignette, directional lobe and damage numbers, if the demo has one.
@export var drive_hud: bool = true
## Trauma, punch and field-of-view kick through `PlayerViewEffects`.
@export var drive_view_effects: bool = true
## Leave null to use the synthesised thump. A baked sample overrides it.
@export var hit_sound: AudioStream = null
@export var death_sound: AudioStream = null
@export_range(-60.0, 12.0, 0.5) var hit_volume_db: float = -7.0
## Random pitch spread per cue, as a fraction. Identical repeats of one sample are
## the fastest way to make a hit sound like a sample.
@export_range(0.0, 0.4, 0.005) var pitch_jitter: float = 0.075

@export_group("Spawn")
## Take the player's position on the first physics tick as the respawn point.
##
## `PlayerController._ready` records the position the SCENE authored, and three demos
## — `ash_flats`, `visuals` and every movement harness — then call `teleport()` from
## their own `_ready` to put the player where the DEMO wants them. Without this a
## death in those demos returns you to the prefab's position rather than to the mark
## you started on. One physics frame is late enough for every `_ready` in the tree to
## have run and early enough that nothing has moved you since. A demo that wants a
## different mark calls `PlayerController.set_spawn()` and turns this off.
@export var claim_spawn_point: bool = true

@export_group("Target")
## Build an `AITarget` when the scene did not bake one. Without a target the AI
## cannot see the player at all, let alone shoot it.
@export var spawn_ai_target: bool = true
## Silhouette radius handed to a target this node builds. Matches the body.
@export_range(0.1, 3.0, 0.01) var target_radius: float = 0.34

var health: float = 100.0
var alive: bool = true
## A REMOTE AUTHORITY OWNS THIS BODY. Set by a demo's networking layer on a CLIENT,
## and never on the host or in single player, where `NetGame.is_authority()` is true
## and this node is the authority it names.
##
## The AI that shoots you only exists on the host: it is the host's raycast that
## reached your silhouette and the host's ledger that says what came off. So on a
## client this node stops being a simulation and becomes a display — `apply_damage`
## refuses, regeneration and the respawn clock stop, and `sync_health` is the only
## thing that moves the number. Everything downstream of the number is unchanged,
## which is the point: the vignette, the directional lobe, the damage numbers, the
## trauma, the death banner and the weapon reload all run exactly as they do in
## single player, because they are driven from the same three places they always
## were.
var network_driven: bool = false
## The player's own snapshot, held so `AITarget._refresh_stance` keeps working when
## a scene points `receiver_path` at this node instead of at the controller.
var state: PlayerState = null

var _player: CharacterBody3D = null
var _target: Node3D = null
var _hud: Node = null
var _effects: Node = null
var _voice: AudioStreamPlayer = null
var _published: float = -1.0
var _since_damage: float = 1.0e9
var _death_clock: float = 0.0
var _invulnerable: float = 0.0
var _hud_tries: int = 0
var _claim_due: bool = true
var _rng: XorShift32 = XorShift32.new(0x50D1E5)


## Create or adopt the player's health node and wire everything to it. Idempotent:
## calling it twice returns the same node, so a scene that authors a `Health` child
## and a controller that installs one cannot end up with two.
static func install(player: CharacterBody3D) -> PlayerHealth:
	if player == null:
		return null
	for child: Node in player.get_children():
		var found := child as PlayerHealth
		if found != null:
			found.bind(player)
			return found
	var node := PlayerHealth.new()
	node.name = "Health"
	player.add_child(node)
	node.bind(player)
	return node


func _ready() -> void:
	health = max_health
	if _player == null:
		bind(get_parent() as CharacterBody3D)


func _physics_process(delta: float) -> void:
	if _claim_due:
		_claim_due = false
		if claim_spawn_point and _player != null:
			_player.call(&"set_spawn", _player.global_position, _player.get(&"yaw"))
	_invulnerable = maxf(_invulnerable - delta, 0.0)
	if not alive:
		_tick_death(delta)
		return
	_since_damage += delta
	_regenerate(delta)
	_publish()


## Attach to a player. Called by `install`; safe to call again.
func bind(player: CharacterBody3D) -> void:
	if player == null or _player == player:
		return
	_player = player
	state = player.get(&"state") as PlayerState
	_effects = _child_answering(player, &"add_damage")
	_resolve_target()
	if not player.is_connected(&"respawned", _on_respawned):
		player.respawned.connect(_on_respawned)


## THE SEAM. `AITarget.receive_damage` calls this through `receiver_path`, and it is
## the exact signature `EnemyActor.apply_damage` answers to — a round does not care
## which side of the fight it landed on. Returns the damage actually taken, which is
## zero for a refused hit, so a caller that wants to know can ask.
func apply_damage(amount: float, from_position: Vector3, attacker: Node = null) -> float:
	if not alive or amount <= 0.0 or _invulnerable > 0.0 or network_driven:
		return 0.0
	var taken: float = amount * damage_scale * (1.0 - clampf(armour, 0.0, 95.0) * 0.01)
	if taken <= 0.0:
		return 0.0
	taken = minf(taken, health)
	health -= taken
	_since_damage = 0.0
	_feedback(taken, from_position)
	damaged.emit(taken, from_position, attacker)
	_publish()
	if health <= 0.0:
		health = 0.0
		_go_down(from_position, attacker)
	return taken


## Fraction of maximum health left, in [0, 1]. `AITarget.health_fraction` reads this
## to size the flinch a hit produces and to feed the morale model.
func health_fraction() -> float:
	return clampf(health / maxf(max_health, 1.0e-3), 0.0, 1.0)


func is_dead() -> bool:
	return not alive


## True while a respawn's grace period is still running.
func is_invulnerable() -> bool:
	return _invulnerable > 0.0


## Put health back without any of the death sequence. Clamped at `max_health`.
func heal(amount: float) -> void:
	if not alive or amount <= 0.0:
		return
	health = minf(health + amount, max_health)
	_publish()


## Kill outright, skipping the damage maths. Scripted removals and the void plane.
func kill(from_position: Vector3 = Vector3.ZERO, attacker: Node = null) -> void:
	if not alive:
		return
	health = 0.0
	_publish()
	_go_down(from_position, attacker)


## Back to a full bar, upright, with the grace period running. Called from the
## controller's `respawned` signal, so the void plane's existing teleport heals too.
func restore() -> void:
	health = max_health
	alive = true
	_death_clock = 0.0
	_since_damage = 0.0
	_invulnerable = spawn_protection
	if _target != null and is_instance_valid(_target):
		_target.set(&"alive", true)
		_target.call(&"reset_senses")
	if _effects != null and is_instance_valid(_effects):
		_effects.call(&"reset")
	_reload_weapon()
	_publish()
	var hud: Node = _find_hud()
	if hud != null:
		hud.call(&"set_dead", false)
	revived.emit()


## The `AITarget` this player is seen and shot through, adopted or built.
func target() -> Node3D:
	return _target


## THE NETWORK SEAM, the mirror of `apply_damage`. A remote authority says what this
## body has left, what came off to get there, where from, and whether it is still
## standing. Ignored unless `network_driven` is set, so nothing can drive a body that
## belongs to this machine.
##
## The order is the same order a local hit runs in and for the same reason: the
## feedback fires against the health the hit was measured at, then the number moves,
## then the state change. Doing it the other way round pops the vignette after the
## bar has already emptied.
##
## `alive` is what the two state changes hang off, and both are edge triggered. A
## repeated "you are dead" message — which a re-send or a late packet is — must not
## restart the death cue, and a revive is the host's respawn clock finishing, which
## goes through `PlayerController.respawn()` so the body is put back on the demo's
## own spawn mark exactly as a local death does it.
func sync_health(now: float, took: float, from_position: Vector3, standing: bool) -> void:
	if not network_driven:
		return
	if took > 0.0 and alive:
		_feedback(took, from_position)
		damaged.emit(took, from_position, null)
	health = clampf(now, 0.0, max_health)
	_since_damage = 0.0 if took > 0.0 else _since_damage
	_publish()
	if standing == alive:
		return
	if not standing:
		_go_down(from_position, null)
		return
	if _player != null:
		_player.call(&"respawn")
	else:
		restore()


func _tick_death(delta: float) -> void:
	if not auto_respawn or _player == null or network_driven:
		return
	_death_clock += delta
	if _death_clock < death_seconds:
		return
	_death_clock = 0.0
	_player.call(&"respawn")


func _regenerate(delta: float) -> void:
	if not regen_enabled or _since_damage < regen_delay or network_driven:
		return
	var ceiling: float = max_health * clampf(regen_ceiling, 0.0, 1.0)
	if health >= ceiling:
		return
	health = minf(health + regen_rate * delta, ceiling)


## Everything a hit is allowed to do to the view and the screen. Each consumer is
## optional and each is resolved by method rather than by class, so a demo without
## a HUD, without a view rig or without either still takes damage correctly.
func _feedback(taken: float, from_position: Vector3) -> void:
	var from_direction: Vector3 = from_position - _body_position()
	if drive_view_effects and _effects != null and is_instance_valid(_effects):
		_effects.call(&"add_damage", taken, from_direction)
	if drive_hud:
		var hud: Node = _find_hud()
		if hud != null:
			hud.call(&"damage_from", from_position)
	_play(hit_sound if hit_sound != null else _hit_stream())


## Push health at everything that shows it. The snapshot is rewritten unconditionally
## because it is three field writes on an object that is rewritten in place anyway;
## the HUD call and the signal are gated on the value actually moving, because those
## two are a dynamic dispatch and a signal emission and this runs at 60 Hz for the
## whole life of every demo whether or not anything is shooting at you.
func _publish() -> void:
	if state != null:
		state.health = health
		state.health_max = max_health
		state.dead = not alive
	if is_equal_approx(health, _published):
		return
	_published = health
	if drive_hud:
		var hud: Node = _find_hud()
		if hud != null:
			hud.call(&"set_health", health_fraction())
	health_changed.emit(health, max_health)


## Zero health. The order matters: the target is marked down FIRST so the AI stops
## putting rounds into a corpse and picks a new mark on its very next tick.
func _go_down(from_position: Vector3, attacker: Node) -> void:
	if not alive:
		return
	alive = false
	_death_clock = 0.0
	if _target != null and is_instance_valid(_target):
		_target.call(&"mark_dead")
	if _player != null:
		_player.call(&"set_input_suspended", true)
	var hud: Node = _find_hud()
	if hud != null:
		hud.call(&"set_dead", true)
		hud.call(&"banner", "YOU ARE DEAD", maxf(death_seconds, 0.4))
	_play(death_sound if death_sound != null else _death_stream())
	_publish()
	died.emit(from_position, attacker)


## The controller finished a respawn — its own teleport, or the void plane's.
func _on_respawned() -> void:
	if _player != null:
		_player.call(&"set_input_suspended", false)
	restore()


## Adopt the scene's `AITarget` if it baked one, build one if it did not. The script
## is loaded at RUNTIME rather than preloaded: preloading it would drag the whole AI
## module into every `--script` harness that constructs a bare player.
func _resolve_target() -> void:
	if _player == null:
		return
	for child: Node in _player.get_children():
		if child.has_method(&"receive_damage") and child.has_method(&"mark_dead"):
			_target = child as Node3D
			return
	if not spawn_ai_target:
		return
	var script: Script = load("res://systems/ai/ai_target.gd") as Script
	if script == null:
		return
	var node := script.new() as Node3D
	if node == null:
		return
	node.name = "Target"
	node.set(&"faction", -1)
	node.set(&"body_radius", target_radius)
	node.set(&"aim_offset", Vector3(0.0, _player.get(&"stand_eye") * 0.76, 0.0))
	node.set(&"eye_offset", Vector3(0.0, _player.get(&"stand_eye"), 0.0))
	_player.add_child(node)
	_target = node


## Put the gun back the way a fresh spawn finds it: loaded, unjammed, idle.
##
## Hunted by `trigger_down` and NOT by `is_ready_to_fire`, which was the first thing
## tried and is wrong: `WeaponHolster` answers to that name too and sits nearer the
## player in the walk, so the search found the holster — which has no `reset` — and a
## respawned player came back with whatever was left in the magazine. `trigger_down`
## is `Weapon`'s alone. The walk budget is a NODE count, not a depth, and the gun
## hangs off `Eye/Holster/Hand`, so it has to be generous enough to get there.
func _reload_weapon() -> void:
	if _player == null:
		return
	var weapon: Node = _descendant_answering(_player, &"trigger_down", WEAPON_WALK_LIMIT)
	if weapon == null:
		# Only two of the four armed demos put the gun where `WeaponHolster` parents
		# it. MEASURED: `range` keeps its at `/root/Range/Shooter/Weapon` and
		# `gunbench` at `/root/Gunbench/Weapon`. The player's own subtree is still
		# searched first, so a level holding a second gun cannot hand you somebody
		# else's when you have one of your own.
		var tree: SceneTree = get_tree()
		var root: Node = null if tree == null else tree.current_scene
		if root != null:
			weapon = _descendant_answering(root, &"trigger_down", HUD_WALK_LIMIT)
	if weapon != null and weapon.has_method(&"reset"):
		weapon.call(&"reset")


## Where the body is, for the bearing a directional indicator needs. The eye rather
## than the feet: a lobe measured from the ankles points down for a close shooter.
func _body_position() -> Vector3:
	if _player == null:
		return Vector3.ZERO
	if state != null:
		return state.eye
	return _player.global_position


## The scene's combat HUD, or null. Searched lazily and at most once: the arena
## hangs its HUD off the demo root and the range mounts one from code in its own
## `_ready`, so neither is reliably present when the player is built.
func _find_hud() -> Node:
	if _hud != null and is_instance_valid(_hud):
		return _hud
	if _hud_tries >= HUD_ATTEMPTS:
		return null
	_hud_tries += 1
	var tree: SceneTree = get_tree()
	if tree == null:
		return null
	var root: Node = tree.current_scene if tree.current_scene != null else tree.root
	if root == null:
		return null
	_hud = _descendant_answering(root, &"set_health", HUD_WALK_LIMIT)
	if _hud != null:
		var eye: Node = _player.get_node_or_null(^"Eye") if _player != null else null
		if eye is Camera3D:
			# Never set by the arena, which is why its damage numbers never drew.
			_hud.call(&"set_camera", eye)
		_hud.call(&"set_health", health_fraction())
	return _hud


## First direct child answering to `method`. Used for the view rig, which is always
## a child of the player and must not be found somewhere else in the level.
static func _child_answering(parent: Node, method: StringName) -> Node:
	for child: Node in parent.get_children():
		if child.has_method(method):
			return child
	return null


## Breadth-first walk under `root` for the first node answering to `method`, bounded
## so a town-sized scene cannot turn a lookup into a stall.
static func _descendant_answering(root: Node, method: StringName, limit: int) -> Node:
	var queue: Array[Node] = [root]
	var looked: int = 0
	while not queue.is_empty() and looked < limit:
		var node: Node = queue.pop_front()
		looked += 1
		if node != root and node.has_method(method):
			return node
		for child: Node in node.get_children():
			queue.push_back(child)
	return null


func _play(stream: AudioStream) -> void:
	if stream == null:
		return
	if _voice == null:
		_voice = AudioStreamPlayer.new()
		_voice.name = "Voice"
		add_child(_voice)
	_voice.stream = stream
	_voice.volume_db = hit_volume_db
	_voice.pitch_scale = 1.0 + _rng.next_range(-pitch_jitter, pitch_jitter)
	_voice.play()


## A hit on the body, synthesised rather than sampled. The project bakes its gun
## voice the same way (`tools/gun_audio/gun_synth.gd`) and ships no player-hit
## sample, so this is the honest default: assign `hit_sound` to override it.
static func _hit_stream() -> AudioStreamWAV:
	if _hit_cue == null:
		_hit_cue = _synth(0.20, 118.0, 0.55, 14.0, 0x5CA71E)
	return _hit_cue


static func _death_stream() -> AudioStreamWAV:
	if _death_cue == null:
		_death_cue = _synth(1.05, 62.0, 0.30, 3.4, 0xD1E10)
	return _death_cue


## One cue: a decaying sine thump at `hz` with `noise` of band-limited grit mixed
## over it, the whole thing under an exponential envelope of rate `decay`. Rendered
## once into 16-bit mono, which is what a two-tenths-of-a-second body impact needs.
static func _synth(
	seconds: float, hz: float, noise: float, decay: float, seed_value: int
) -> AudioStreamWAV:
	var count: int = int(seconds * float(CUE_RATE))
	var rand := XorShift32.new(seed_value)
	var data := PackedByteArray()
	data.resize(count * 2)
	var phase: float = 0.0
	var low: float = 0.0
	for i: int in count:
		var t: float = float(i) / float(CUE_RATE)
		var env: float = exp(-decay * t)
		# The thump slides down a fifth as it decays, which is what a struck body
		# does and what stops a fixed sine reading as a test tone.
		phase += TAU * hz * (1.0 - 0.35 * (1.0 - env)) / float(CUE_RATE)
		low = lerpf(low, rand.next_range(-1.0, 1.0), 0.22)
		var s: float = sin(phase) * (1.0 - noise) + low * noise
		var v: int = clampi(int(s * env * 26000.0), -32767, 32767)
		data.encode_s16(i * 2, v)
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = CUE_RATE
	stream.stereo = false
	stream.data = data
	return stream
