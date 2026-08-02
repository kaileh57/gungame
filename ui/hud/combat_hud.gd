class_name CombatHud
extends CanvasLayer
## The whole of the in-combat screen UI: sight picture, hit markers, damage
## numbers, a health vignette and a one-line warning banner. Nothing else.
##
## Ammunition is deliberately absent — it belongs on the weapon, where
## `AmmoCounter` puts it. Health is a vignette rather than a number because a
## number is something you read and a closing frame is something you feel.
##
## A demo instances `res://ui/hud/combat_hud.tscn`, hands it the camera, and pushes
## the sight picture every frame:
## [codeblock]
## hud.set_camera($Head/Camera)
## hud.watch_hands(_hands)
## hud.set_picture(weapon.effective_spread(), weapon.cycle_fraction(), camera.fov)
## hud.hit_mark(killed, was_head)
## hud.pop(hit_point, "37", &"crit")
## hud.set_health(health / max_health)
## hud.set_dead(true)
## [/codeblock]
##
## In play, `PlayerHealth` drives all four of `set_camera`, `set_health`,
## `damage_from` and `set_dead` — it finds this node by method rather than by class,
## so a demo gets the whole feedback loop by owning a HUD and nothing else.
##
## THE THREAT LAYER IS ADOPTED OR BUILT, not required of the scene. `combat_hud.tscn`
## is a bake output of `tools/build_ui_assets.gd`, so a HUD that only worked when the
## bake had been re-run would be a HUD that silently lost its damage indicator on
## every checkout. `_ready` takes a `Threat` child if one is there and makes one if it
## is not — the same rule `PlayerHealth.install` follows, and for the same reason:
## every demo that owns a HUD gets the whole of it, not the demo whose `.tscn`
## somebody remembered to edit. `damage_from` feeds it, so a demo that already drives
## the vignette gets the directional arc for free.

## Seconds a directional damage lobe takes to fall away.
const PULSE_SECONDS: float = 0.55
## Blink period of the banner, from the reference's 0.55 s two-step.
const BANNER_BLINK: float = 0.275
## Rate the sustained vignette chases the real health value, per second.
const HARM_RATE: float = 6.0
## Units per second the death iris closes and re-opens at. 3.2 shuts the frame in
## about a third of a second, which reads as a body dropping rather than a fade.
const DEATH_RATE: float = 3.2

## Health fraction the vignette starts to close in at. Above this the frame is
## clean; a scratch should not decorate the screen.
@export_range(0.2, 1.0, 0.01) var harm_threshold: float = 0.75
## Health fraction below which the frame starts to breathe. Distinct from
## `harm_threshold` on purpose: the vignette closing tells you that you are hurt,
## and the breathing tells you that the next round is the last one.
@export_range(0.0, 1.0, 0.01) var pulse_below: float = 0.34
## Breaths per second at zero health, easing to nothing at `pulse_below`.
@export_range(0.1, 4.0, 0.05) var pulse_hz: float = 1.35
## How much harm one breath is worth on top of the sustained value.
@export_range(0.0, 0.5, 0.01) var pulse_depth: float = 0.14
## Build the screen-edge threat layer when the scene did not bake one. Off leaves
## the HUD exactly as it was before the layer existed.
@export var spawn_threat_layer: bool = true
## Fraction of full health a hit has to cost to be worth a full-weight arc. A hit
## for a fifth of your bar at 0.35 draws at a bit over half weight, which is the
## curve that keeps a graze legible without making it shout.
@export_range(0.02, 1.0, 0.01) var threat_reference_damage: float = 0.35

var _camera: Camera3D = null
var _health: float = 1.0
var _harm: float = 0.0
var _harm_target: float = 0.0
var _pulse: float = 0.0
var _pulse_dir: Vector2 = Vector2.ZERO
var _beat: float = 0.0
var _beat_clock: float = 0.0
var _death: float = 0.0
var _death_target: float = 0.0
var _banner_left: float = 0.0
var _banner_blink: float = 0.0
var _shader: ShaderMaterial = null
var _threat: ThreatIndicator = null

@onready var _vignette: ColorRect = $Vignette
@onready var _reticle: CombatReticle = $Reticle
@onready var _pops: DamagePops = $Pops
@onready var _banner: Label = $Banner


func _ready() -> void:
	_shader = _vignette.material as ShaderMaterial
	if _shader == null:
		push_error("CombatHud: the Vignette carries no ShaderMaterial.")
	_banner.visible = false
	_resolve_threat_layer()
	_write_shader()


## Take the baked threat layer, or make one. Added LAST so it draws over the
## reticle and the numbers: an arc that is behind a damage pop is an arc you did
## not see.
func _resolve_threat_layer() -> void:
	_threat = get_node_or_null(^"Threat") as ThreatIndicator
	if _threat != null or not spawn_threat_layer:
		return
	_threat = ThreatIndicator.new()
	_threat.name = "Threat"
	add_child(_threat)


func _process(delta: float) -> void:
	_tick_harm(delta)
	_tick_banner(delta)


## The camera damage pops project through and the vignette takes its bearings
## from. Without it pops are silently dropped rather than drawn at the origin, and
## the aim indicator falls back to the viewport's live camera.
func set_camera(camera: Camera3D) -> void:
	_camera = camera
	_pops.set_camera(camera)
	_reticle.set_camera(camera)
	if _threat != null:
		_threat.set_camera(camera)


## Push the sight picture. `spread` is the cone half-angle in radians, `cycle` the
## 0..1 action progress, `fov` the camera's current vertical field of view — which
## changes when you lean into a scope, and the crosshair must follow it.
func set_picture(spread: float, cycle: float, fov: float) -> void:
	_reticle.set_picture(spread, cycle, fov)


func hit_mark(kill: bool, crit: bool) -> void:
	_reticle.hit_mark(kill, crit)


## Hand the aim indicator the demo's own hands, so the world-space highlight agrees
## with what a click would actuate rather than with what a ray could reach. Optional
## — without it the indicator still works, off the bullet mask.
func watch_hands(hands: DiegeticInteractor) -> void:
	_reticle.watch(hands)


## The aim indicator itself, for a demo that wants to change its style or read what
## is under the crosshair.
func reticle() -> CombatReticle:
	return _reticle


func pop(world_point: Vector3, text: String, kind: StringName = &"hit") -> void:
	_pops.add_pop(world_point, text, kind)


## Current health as a 0..1 fraction. The vignette lags it slightly so a burst of
## damage reads as one closing rather than as three flickers.
func set_health(fraction: float) -> void:
	_health = clampf(fraction, 0.0, 1.0)
	_harm_target = clampf((harm_threshold - _health) / maxf(harm_threshold, 0.001), 0.0, 1.0)
	if _threat != null:
		_threat.set_health(_health)


## Down, or back up. Closes a hard iris over the frame rather than cutting to black,
## because the point of a death state is that you can see what killed you inside it.
func set_dead(down: bool) -> void:
	_death_target = 1.0 if down else 0.0
	if not down:
		return
	# A corpse does not breathe and does not flinch. Both are cleared so the iris is
	# the only thing moving, which is what makes it read.
	_beat = 0.0
	_beat_clock = 0.0
	_pulse = 0.0
	if _threat != null:
		_threat.clear_threats()


## Flash the edge of the screen on the side the damage came from.
##
## `amount` and `maximum` are optional and only reach the threat arc: the shader
## lobe has always been binary and stays that way, because it is a flinch rather
## than a reading. A caller that knows what the hit cost gets an arc sized by it;
## one that does not — `PlayerHealth` calls this with the point alone — gets a
## middling arc, which is still the right bearing.
func damage_from(world_point: Vector3, amount: float = -1.0, maximum: float = 0.0) -> void:
	_pulse = 1.0
	_pulse_dir = _screen_bearing(world_point)
	_write_shader()
	if _threat == null:
		return
	var sized: bool = amount > 0.0 and maximum > 0.0
	var weight: float = 0.55
	if sized:
		var share: float = amount / maximum
		weight = clampf(share / maxf(threat_reference_damage, 0.001), 0.12, 1.0)
	# `sized` is passed through so the indicator can tell this call from the other one
	# the same round makes. `PlayerHealth` reports the bearing the instant it resolves
	# the damage; `ArenaThreat` reports what it cost a moment later in the same frame,
	# and the arc has to be sized off the second without being inflated by the first.
	_threat.add_threat(world_point, weight, ThreatIndicator.Kind.HIT, null, sized)


## A round went past without landing, or a body opened up on you from `world_point`.
## `source` is the shooter when the caller knows which body it was, which is what
## puts a caret on it for a moment.
func near_miss(world_point: Vector3, weight: float = 0.4, source: Node3D = null) -> void:
	if _threat != null:
		_threat.add_threat(world_point, weight, ThreatIndicator.Kind.NEAR, source)


## Name the body that just shot you, after the fact. Separate from `damage_from`
## because `PlayerHealth` resolves the damage and the arena resolves the shooter,
## and neither knows the other's half.
func mark_shooter(world_point: Vector3, weight: float, source: Node3D) -> void:
	if _threat != null:
		_threat.add_threat(world_point, weight, ThreatIndicator.Kind.HIT, source)


## The threat layer itself, for a demo that wants to restyle it or read it.
func threat() -> ThreatIndicator:
	return _threat


## One line of warning, centred, blinking. `JAM — hold R` is what this is for.
func banner(text: String, seconds: float = 1.6) -> void:
	_banner.text = text
	_banner.visible = true
	_banner_left = seconds
	_banner_blink = 0.0
	_banner.modulate.a = 1.0


func clear_banner() -> void:
	_banner_left = 0.0
	_banner.visible = false


## Hide the crosshair without hiding the rest — for a scope, whose reticle is
## drawn inside the optic, or for a cutscene.
func set_reticle_visible(shown: bool) -> void:
	_reticle.visible = shown


func _tick_harm(delta: float) -> void:
	var moved: bool = false
	if not is_equal_approx(_harm, _harm_target):
		_harm = lerpf(_harm, _harm_target, 1.0 - pow(0.5, delta * HARM_RATE))
		if absf(_harm - _harm_target) < 0.002:
			_harm = _harm_target
		moved = true
	if _pulse > 0.0:
		_pulse = maxf(0.0, _pulse - delta / PULSE_SECONDS)
		moved = true
	if not is_equal_approx(_death, _death_target):
		_death = move_toward(_death, _death_target, DEATH_RATE * delta)
		moved = true
	moved = _tick_beat(delta) or moved
	if moved:
		_write_shader()


## The breath. Amplitude rises from nothing at `pulse_below` to `pulse_depth` at
## zero health, and the rate rises with it, so the frame does not merely get darker
## as you run out — it gets faster. Returns true when the value moved.
func _tick_beat(delta: float) -> bool:
	var want: float = 0.0
	if _death_target <= 0.0 and _health < pulse_below and pulse_below > 0.0:
		var depth: float = (1.0 - _health / pulse_below) * pulse_depth
		_beat_clock = fmod(
			_beat_clock + delta * pulse_hz * (0.6 + 0.8 * depth / maxf(pulse_depth, 0.001)), 1.0
		)
		want = depth * (0.5 - 0.5 * cos(_beat_clock * TAU))
	if is_equal_approx(want, _beat):
		return false
	_beat = want
	return true


func _tick_banner(delta: float) -> void:
	if _banner_left <= 0.0:
		return
	_banner_left -= delta
	if _banner_left <= 0.0:
		_banner.visible = false
		return
	_banner_blink += delta
	if _banner_blink >= BANNER_BLINK:
		_banner_blink -= BANNER_BLINK
		_banner.modulate.a = 0.25 if _banner.modulate.a > 0.6 else 1.0


func _write_shader() -> void:
	if _shader == null:
		return
	_shader.set_shader_parameter(&"harm", _harm)
	_shader.set_shader_parameter(&"pulse", _pulse)
	_shader.set_shader_parameter(&"hit_direction", _pulse_dir)
	_shader.set_shader_parameter(&"heartbeat", _beat)
	_shader.set_shader_parameter(&"death", _death)


## Where a world point sits relative to the middle of the screen, as a unit
## vector with +X right and +Y down. Works for points behind the camera, where
## unprojecting would give a mirrored answer.
func _screen_bearing(world_point: Vector3) -> Vector2:
	if _camera == null or not is_instance_valid(_camera):
		return Vector2.DOWN
	var to_hit: Vector3 = world_point - _camera.global_position
	var basis: Basis = _camera.global_transform.basis
	var bearing := Vector2(to_hit.dot(basis.x), -to_hit.dot(basis.y))
	if bearing.length() < 0.0001:
		return Vector2.DOWN
	return bearing.normalized()
