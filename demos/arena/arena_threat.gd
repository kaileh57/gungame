class_name ArenaThreat
extends Node
## Incoming fire, made legible. The answer to "I genuinely can't tell who's
## shooting at me or where it's coming from."
##
## THE CAUSE WAS NOT SUBTLE. `AICombat` fires through `GunHitscan` exactly as the
## player's `Weapon` does, and then does nothing else: it emits `fired` and moves on.
## `Weapon` follows its own shot with a tracer, a muzzle flash, an impact and a
## voice through `GunVfxBridge` and `GunAudio`; nothing in `systems/ai/` or
## `systems/enemies/` names either of them, and the arena's only listener for
## `EnemyActor.fired` was `ArenaNet.note_fire`, which begins
## `if NetGame.is_networked() and NetGame.is_authority()`. So in single player a
## wave of ninety-six bodies shooting at you produced no tracer, no flash, no
## impact and no sound whatsoever. Health went down and the screen went red and
## that was the entire signal.
##
## This is the missing half of the loop, and it lives in the demo rather than in
## the AI because the AI must stay renderable-from-nowhere: `verify_ai_combat`
## fires thousands of rounds headless, and a weapon that reached for a VFX hub on
## every trigger pull would pay for it there too.
##
## Four things come off one `fired`:
##   * a MUZZLE FLASH at the shooter, which is what makes a body in the dark
##     resolve into a body that is shooting;
##   * a TRACER from that muzzle to wherever the round stopped, drawn on the
##     hostile path — wider and longer-lived, because a round coming end-on at
##     your eye subtends nothing at the outgoing width;
##   * an IMPACT where it landed, so a round that misses you still cracks the wall
##     beside your head;
##   * the SHOT ITSELF, positional, through the same pooled `GunAudio` the player's
##     gun speaks with. A body forty metres away is quiet and off to your left, and
##     that alone answers "where from" for anything you cannot see.
##
## And two things go to the HUD: a screen-edge arc on the bearing of any round that
## came at you, and a caret on the body that sent it.
##
## Both seams feed it. `note_shot` is the real trigger pull, on the machine
## simulating the body — the host, and also single player. `note_replayed_shot` is
## the same shot arriving on a CLIENT as a replicated event, reconstructed from the
## puppet's own muzzle. Neither is a special case of the other and the demo wires
## both, so the fourth player in a lobby is not the one player who cannot see the
## firefight.
##
## WHAT COUNTS AS "AT YOU" IS GEOMETRY, NOT INTENT. The arena is a three-way brawl
## and most of the fire in it is not aimed at the player; flagging every trigger
## pull would paint the whole ring and mean nothing. A shot is registered only when
## its own line passes within `near_miss_radius` of your eye, which is the same test
## a player makes by ear.

## Metres from the eye inside which the round is treated as having hit you rather
## than passed you. The damage path already owns that case — `PlayerHealth.damaged`
## raises the arc with a real weight — so this only stops it being counted twice.
const BODY_RADIUS: float = 0.5
## Muzzle energy a species with no gun is priced at, matching `AICombat.report_energy`.
const BARE_ENERGY: float = 1750.0

@export_group("Incoming fire")
## Draw enemy fire at all. Off restores the pre-fix behaviour exactly, which is the
## only honest way to A/B a legibility change.
@export var draw_enemy_fire: bool = true
## Metres from the camera beyond which an enemy shot is not drawn. The compound is
## 76 by 60 m, so at the shipped figure nothing inside it is ever culled; it exists
## so this stays cheap if the arena is ever made bigger.
@export_range(10.0, 400.0, 5.0) var draw_range: float = 140.0
## Enemy shots given a tracer, a flash and an impact per physics tick. The tracer
## pool is a thirty-slot ring, so ninety-six bodies firing at once would overwrite
## it several times inside one frame and nothing would survive long enough to read.
## Shots that pass close to you are drawn FIRST and are exempt from this — see
## `note_shot` — so the budget only ever sheds fire that was not about you.
@export_range(1, 64, 1) var draw_budget: int = 10
## Play the shooter's own gun voice. Positional, pooled, and the same bank the
## player's weapon uses.
@export var play_enemy_fire: bool = true
## Enemy shots given a voice per physics tick. Lower than `draw_budget` because
## `GunAudio` mixes sixteen at once and a hundred triggers a second past that is
## audibly mush rather than a firefight.
@export_range(1, 32, 1) var audio_budget: int = 6

@export_group("Near miss")
## Metres from the eye a round has to pass inside to register as incoming.
@export_range(0.5, 12.0, 0.1) var near_miss_radius: float = 2.4
## Arc weight a round that grazes `BODY_RADIUS` is worth, falling to nothing at
## `near_miss_radius`. Deliberately well under a hit's: a miss is a warning.
@export_range(0.05, 1.0, 0.01) var near_miss_weight: float = 0.5
## Camera shake a maximally close miss adds, through `PlayerViewEffects.add_trauma`.
## Zero switches it off.
@export_range(0.0, 0.6, 0.005) var near_miss_trauma: float = 0.055

@export_group("Impacts")
## Surface a round is assumed to have struck when it did not hit a body. The seam
## the AI fires through reports a collider and a point and no material, so this is
## the compound's own answer rather than a lookup: concrete walls, concrete floor.
@export_range(0, 16, 1) var default_surface: int = VFXSurface.Kind.CONCRETE
@export_range(0.0, 4.0, 0.05) var impact_intensity: float = 0.85
## Sound the arrival of a round that came at you, where it landed. See
## `_sound_impact` for why this is the closest honest thing to a round cracking past.
@export var play_near_impact: bool = true

var _player: PlayerController = null
var _hud: CombatHud = null
var _health: PlayerHealth = null
var _eye: Node3D = null
var _effects: Node = null
var _audio: GunAudio = null
var _drawn: int = 0
var _voiced: int = 0


## Wire the reader. Everything is optional and every consumer is null-checked, so a
## harness that binds a player and no HUD still gets the world-space half.
func bind(player: PlayerController, hud: CombatHud, health: PlayerHealth) -> void:
	_player = player
	_hud = hud
	_health = health
	if player != null:
		_eye = player.get_node_or_null(^"Eye") as Node3D
		_effects = _child_answering(player, &"add_trauma")
	if health != null and not health.damaged.is_connected(_on_damaged):
		health.damaged.connect(_on_damaged)
	set_physics_process(true)


## The per-tick budgets are refilled here rather than on a timer, so a frame that
## drops does not also lose its fire.
func _physics_process(_delta: float) -> void:
	_drawn = 0
	_voiced = 0


## One body pulled its trigger. `origin` is the muzzle, `direction` the line the
## lead pellet actually took, `hit_position` where it stopped and `hit` what it
## stopped on — all four straight off `EnemyActor.fired`.
func note_shot(
	actor: EnemyActor, origin: Vector3, direction: Vector3, hit_position: Vector3, hit: Object
) -> void:
	if actor == null or _eye == null:
		return
	var eye: Vector3 = _eye.global_position
	var miss: float = _distance_to_segment(eye, origin, hit_position)
	# A round that passed close is drawn whatever the budget says. It is the only
	# fire the player has any reason to care about, and it is also the rarest.
	var personal: bool = miss <= near_miss_radius
	_draw_fire(actor, origin, direction, hit_position, hit, eye, personal)
	_voice_fire(actor, origin, personal)
	if personal and hit_position.distance_squared_to(eye) > BODY_RADIUS * BODY_RADIUS:
		_sound_impact(hit_position)
	if personal and miss > BODY_RADIUS:
		_register_near_miss(actor, origin, miss)
	elif personal:
		# It reached you. `_on_damaged` sizes the arc off what it cost; this only
		# names the body, so the arc the damage raised gets a caret on it.
		if _hud != null:
			_hud.mark_shooter(origin, 0.12, actor)


## A shot the HOST resolved, replayed on a CLIENT. The wire carries the body and the
## aim point and nothing else — no muzzle, no impact point, no collider — so the line
## is reconstructed from what this machine already has: the muzzle is where its own
## puppet is holding the weapon, and the round is treated as having stopped where it
## was aimed.
##
## That is the same line the host drew, to within the puppet's own position error,
## which `ArenaNetBodies` holds under `SNAP_DISTANCE` by construction. It is the
## difference between a client seeing the firefight and a client watching thirty-two
## bodies mime at each other, which is what it did before: `apply_events` played the
## attack clip and nothing else.
func note_replayed_shot(actor: EnemyActor, aim: Vector3) -> void:
	if actor == null or not is_instance_valid(actor):
		return
	var origin: Vector3 = actor.muzzle_point()
	var line: Vector3 = aim - origin
	if line.length_squared() < 1.0e-6:
		return
	note_shot(actor, origin, line.normalized(), aim, null)


## A round landed on the player. `PlayerHealth` already drove the vignette lobe, the
## view punch and the hit cue; what it cannot do is size the arc, because it does not
## know what a maximum is worth. This does.
func _on_damaged(amount: float, from_position: Vector3, _attacker: Node) -> void:
	if _hud == null or _health == null:
		return
	_hud.damage_from(from_position, amount, _health.max_health)


func _draw_fire(
	actor: EnemyActor,
	origin: Vector3,
	direction: Vector3,
	hit_position: Vector3,
	hit: Object,
	eye: Vector3,
	personal: bool
) -> void:
	if not draw_enemy_fire:
		return
	if not personal:
		if _drawn >= draw_budget:
			return
		if eye.distance_squared_to(origin) > draw_range * draw_range:
			return
		_drawn += 1
	VfxService.spawn_muzzle_flash_at(origin, direction, _flash_scale(actor))
	VfxService.spawn_hostile_tracer(origin, hit_position, 0.0)
	if hit_position.distance_squared_to(eye) <= BODY_RADIUS * BODY_RADIUS:
		return
	var normal: Vector3 = -direction if direction.length_squared() > 1.0e-6 else Vector3.UP
	var surface: int = default_surface
	if _actor_of(hit) != null:
		surface = VFXSurface.Kind.FLESH
	VfxService.spawn_impact(hit_position, normal.normalized(), surface, impact_intensity)


## The shooter's own gun, positional. A species with no `GunSpec` — anything with
## claws — has no report to play and is silently skipped rather than borrowed a
## rifle's voice.
func _voice_fire(actor: EnemyActor, origin: Vector3, personal: bool) -> void:
	if not play_enemy_fire:
		return
	if not personal and _voiced >= audio_budget:
		return
	var weapon: AICombat = actor.weapon
	if weapon == null or weapon.gun == null:
		return
	var audio: GunAudio = _gun_audio()
	if audio == null:
		return
	_voiced += 1
	audio.shot(weapon.gun, origin)


## The round ARRIVING, where it landed, for fire that came at you. This is the
## nearest honest thing to the crack of a round going past: `GunAudioBank` holds no
## supersonic-crack sample and one is not being faked here. What it does hold is the
## impact, and a round that misses your head buries itself in the wall a metre behind
## it — close, instant, and behind you, which is the cue a player actually localises.
##
## `GunAudio.impact` already owns the speed-of-sound delay and the extra roll-off, so
## a shot that lands forty metres away is correctly quiet and correctly late. Only
## fire that passed inside `near_miss_radius` gets one; the compound's other two
## factions shooting each other would otherwise be a wall of gravel.
func _sound_impact(at: Vector3) -> void:
	if not play_near_impact:
		return
	var audio: GunAudio = _gun_audio()
	if audio == null:
		return
	audio.impact(GunAudioBank.Impact.DEFAULT, at, audio.listener_distance(at), 1.0)


## The pooled gun voice, resolved once and re-resolved if the scene changed under us.
func _gun_audio() -> GunAudio:
	if _audio == null or not is_instance_valid(_audio):
		_audio = GunAudio.service(get_tree())
	return _audio


## A round went past. The arc is weighted by how close, so a shot that parts your
## hair is louder on the ring than one that clears you by two metres.
func _register_near_miss(actor: EnemyActor, origin: Vector3, miss: float) -> void:
	var span: float = maxf(near_miss_radius - BODY_RADIUS, 0.001)
	var close: float = clampf(1.0 - (miss - BODY_RADIUS) / span, 0.0, 1.0)
	if _hud != null:
		_hud.near_miss(origin, near_miss_weight * close, actor)
	if near_miss_trauma > 0.0 and _effects != null and is_instance_valid(_effects):
		_effects.call(&"add_trauma", near_miss_trauma * close)


## Flash size for a shot whose weapon we are not holding. `GunVfxBridge` owns the
## curve — range spec 16.5's `fs` — so a scavenged cannon in a sentinel's hands
## throws the same flare it would in yours. A body with no gun is priced at the
## same rifle-sized round `AICombat.report_energy` uses for its noise.
static func _flash_scale(actor: EnemyActor) -> float:
	var weapon: AICombat = null if actor == null else actor.weapon
	if weapon == null:
		return GunVfxBridge.flash_scale(BARE_ENERGY, 1)
	var pellets: int = 1 if weapon.gun == null else maxi(weapon.gun.pellets, 1)
	return GunVfxBridge.flash_scale(weapon.report_energy(), pellets)


## Perpendicular distance from `point` to the segment `a`-`b`, clamped to the
## segment so a round that stopped short of you is measured from where it stopped.
static func _distance_to_segment(point: Vector3, a: Vector3, b: Vector3) -> float:
	var line: Vector3 = b - a
	var length_squared: float = line.length_squared()
	if length_squared < 1.0e-9:
		return point.distance_to(a)
	var t: float = clampf((point - a).dot(line) / length_squared, 0.0, 1.0)
	return point.distance_to(a + line * t)


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


static func _child_answering(parent: Node, method: StringName) -> Node:
	for child: Node in parent.get_children():
		if child.has_method(method):
			return child
	return null
