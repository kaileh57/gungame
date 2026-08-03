class_name VfxService
extends Node3D
## The one door into the effect system. Guns, enemies, projectiles and demos call
## the statics on this class; nothing else in the project ever touches a particle
## field, a decal pool or a muzzle light directly.
##
## It is not an autoload — the autoload list is frozen — so it works the way the
## world scene does: instance `res://data/vfx/vfx.tscn` once per demo and the
## statics find it. Two hubs at once is a mistake and says so; none at all is not,
## because a bench or an editor preview should not have to care.
##
## Everything under it is baked. The textures, the materials, the billboard quad,
## the brass casing and the node tree itself all come out of
## `res://tools/build_vfx_assets.gd`, and this file loads them and writes numbers
## into them. There is no image, mesh or material construction anywhere below.
##
## Per-frame cost is one camera fetch, one clock write, four shader-uniform
## writes and three pool steps that early-out when their pools are empty. Per-shot
## cost is zero allocations: every write lands in a packed array, a MultiMesh
## buffer or a particle emit call.

const SHADER_TIME: StringName = &"vfx_time"

## How code that must not depend on this class finds the hub. `GunVfxBridge` is
## late-bound on purpose — the weapon has to fire in a headless test with no VFX at
## all — so it resolves the service by group rather than by type. Without this the
## bridge silently binds to nothing and every shot in the game is invisible.
const SERVICE_GROUP: StringName = &"vfx_service"

## Reference tracer life, 45 ms (range spec 16.4).
const TRACER_LIFE: float = 0.045

static var _hub: VfxService = null

@export_group("Tracers")
## Ribbon width in metres. The reference draws a 1 px line; a line is one pixel
## wide at any distance in Godot, which reads as a scratch on the lens.
@export_range(0.005, 0.3, 0.001) var tracer_width: float = 0.05
## Below this muzzle-to-impact distance a tracer is not worth a slot.
@export_range(0.0, 20.0, 0.1) var tracer_min_length: float = 1.2
## Width multiplier on a tracer coming AT the player rather than leaving their own
## muzzle. Incoming fire is drawn end-on — a round on a collision course with your
## eye subtends almost no screen area at any width, and at the shipped 0.05 m it is
## a scratch two pixels long that nobody reported ever seeing. Widening it is the
## only lever the ribbon geometry gives; the pool has no colour channel free (the
## four custom-data floats are birth, life, speed and path), so this is what
## distinguishes hostile fire until somebody bakes a second tracer material.
@export_range(1.0, 8.0, 0.1) var hostile_tracer_gain: float = 2.8
## Lifetime multiplier on the same. A 45 ms streak read across your view is fine;
## the same streak read down its own axis is gone before the eye finds it.
@export_range(1.0, 8.0, 0.1) var hostile_tracer_life_gain: float = 2.4
## Minimum length for a hostile tracer, metres. Far shorter than `tracer_min_length`
## because a body shooting you at three metres is the case that most needs drawing.
@export_range(0.0, 20.0, 0.1) var hostile_tracer_min_length: float = 0.35

@export_group("Impacts")
## Multiplier on every surface's spark count. The per-surface numbers live in
## `VFXSurface`; this is the one knob that turns the whole lot up or down.
@export_range(0.0, 4.0, 0.05) var spark_density: float = 1.0
@export_range(0.0, 4.0, 0.05) var dust_density: float = 1.0
## Cap on the particles one impact may ask for, whatever intensity it passes.
@export_range(1, 400, 1) var impact_spark_cap: int = 96

@export_group("Shells")
## World velocity given to a case when the caller passes none: up and to the
## right of the ejection port, in the port's own frame.
@export var shell_default_velocity: Vector3 = Vector3(2.4, 1.6, 0.4)

@export_group("Budget")
## Pool sizes are multiplied by this, indexed by `GameSettings.PRESET_NAMES`.
## A custom preset leaves the scale where it was.
@export var preset_budget_scale: PackedFloat32Array = [0.30, 0.50, 0.75, 1.0, 1.0]

var _clock: float = 0.0
var _ground_y: float = 0.0
var _camera_pos: Vector3 = Vector3.ZERO

var _sparks: VFXSparkField = null
var _spray: VFXSparkField = null
var _smoke_fine: VFXSmokeField = null
var _smoke_heavy: VFXSmokeField = null
var _decals: VFXDecalPool = null
var _tracers: VFXTracerPool = null
var _ash: VFXAshField = null
var _motes: VFXAshField = null
var _muzzles: VfxMuzzle = null
var _shells: VfxShellEject = null
var _blasts: VfxExplosion = null

var _decal_material: ShaderMaterial = null
var _tracer_material: ShaderMaterial = null

var _base_budget: PackedInt32Array = PackedInt32Array()
var _tracer_count: int = 0
var _decal_count: int = 0
var _impact_count: int = 0
var _shot_count: int = 0

# --- the frozen API ---------------------------------------------------------


## The live hub, or null in a scene that has none.
static func hub() -> VfxService:
	return _hub


static func spawn_tracer(from: Vector3, to: Vector3, speed: float) -> void:
	if _hub != null:
		_hub.tracer(from, to, speed)


## `surface` is a `VFXSurface.Kind`, which for ids 0-8 is byte-identical to the
## world material table, so a terrain raycast can pass its surface id straight in.
static func spawn_impact(
	pos: Vector3, normal: Vector3, surface: int, intensity: float = 1.0
) -> void:
	if _hub != null:
		_hub.impact(pos, normal, surface, intensity)


static func spawn_decal(pos: Vector3, normal: Vector3, size: float) -> void:
	if _hub != null:
		_hub.decal(pos, normal, size, false, 0.0)


## A round coming toward the player: wider, longer-lived, and drawn at ranges an
## outgoing tracer is not worth a slot at. See `hostile_tracer_gain`.
static func spawn_hostile_tracer(from: Vector3, to: Vector3, speed: float) -> void:
	if _hub != null:
		_hub.hostile_tracer(from, to, speed)


static func spawn_muzzle_flash(at: Node3D, scale: float) -> void:
	if _hub != null:
		_hub.muzzle_flash(at, scale)


## A flash from a muzzle that is a point and a direction rather than a node — every
## weapon the AI carries. `VfxMuzzle.flash_at` documents why that case exists.
static func spawn_muzzle_flash_at(pos: Vector3, bore: Vector3, scale: float) -> void:
	if _hub != null:
		_hub.muzzle_flash_at(pos, bore, scale)


static func spawn_explosion(pos: Vector3, radius: float) -> void:
	if _hub != null:
		_hub.explosion(pos, radius)


static func spawn_shell(at: Node3D, velocity: Vector3) -> void:
	if _hub != null:
		_hub.shell(at, velocity)


static func spawn_shell_from(position: Vector3, velocity: Vector3) -> void:
	if _hub != null:
		_hub.shell_from(position, velocity)


## Powder smoke, dust, a rocket trail. `heavy` picks the 2.10 m sprite cloud over
## the 0.62 m one, and with it the wider near-camera cull.
static func spawn_puff(
	pos: Vector3, count: int, spread: float, dark: float, life: float, heavy: bool = false
) -> void:
	if _hub != null:
		_hub.puff(pos, count, spread, dark, life, heavy)


## A patch of hot air over something that is still burning.
static func spawn_heat(pos: Vector3, size: float, life: float) -> void:
	if _hub != null:
		_hub.heat(pos, size, life)


## The height spent brass and blast debris come to rest on. Whoever owns the
## player's footing writes this; it costs one float and saves a raycast a shot.
static func set_ground_y(y: float) -> void:
	if _hub != null:
		_hub._ground_y = y


# --- lifecycle --------------------------------------------------------------


func _enter_tree() -> void:
	if _hub != null and _hub != self:
		push_error("VfxService: a second hub entered the tree; the first one still owns the API.")
		return
	_hub = self
	# In the tree rather than in the bake, so a hub built by hand — a bench, an
	# editor preview — is findable on exactly the same terms as the baked one.
	add_to_group(SERVICE_GROUP)


func _exit_tree() -> void:
	if _hub == self:
		_hub = null


func _ready() -> void:
	_sparks = get_node_or_null(^"Sparks") as VFXSparkField
	_spray = get_node_or_null(^"Spray") as VFXSparkField
	_smoke_fine = get_node_or_null(^"SmokeFine") as VFXSmokeField
	_smoke_heavy = get_node_or_null(^"SmokeHeavy") as VFXSmokeField
	_decals = get_node_or_null(^"Decals") as VFXDecalPool
	_tracers = get_node_or_null(^"Tracers") as VFXTracerPool
	_ash = get_node_or_null(^"Ash") as VFXAshField
	_motes = get_node_or_null(^"Motes") as VFXAshField
	_muzzles = get_node_or_null(^"Muzzles") as VfxMuzzle
	_shells = get_node_or_null(^"Shells") as VfxShellEject
	_blasts = get_node_or_null(^"Blasts") as VfxExplosion
	for node: Node in [
		_sparks,
		_spray,
		_smoke_fine,
		_smoke_heavy,
		_decals,
		_tracers,
		_ash,
		_motes,
		_muzzles,
		_shells,
		_blasts
	]:
		if node == null:
			push_error("VfxService: the hub scene is missing a pool. Re-run build_vfx_assets.")
			return

	_decal_material = _decals.material_override as ShaderMaterial
	_tracer_material = _tracers.material_override as ShaderMaterial
	_blasts.bind(_sparks, _smoke_heavy)
	_capture_budget()
	_connect_settings()
	set_process(true)


func _process(delta: float) -> void:
	_clock += delta
	var camera: Camera3D = get_viewport().get_camera_3d()
	if camera != null:
		_camera_pos = camera.global_position

	if _decal_material != null:
		_decal_material.set_shader_parameter(SHADER_TIME, _clock)
	if _tracer_material != null:
		_tracer_material.set_shader_parameter(SHADER_TIME, _clock)
	_ash.follow(_camera_pos, _clock)
	_motes.follow(_camera_pos, _clock)
	_muzzles.step(delta)
	_shells.step(delta)
	_blasts.step(delta, _clock)


# --- instance side of the API ----------------------------------------------


## Muzzle to impact. `speed` is the round's own speed; pass 0 for a streak that
## appears whole, which is what a hitscan shot wants at close range.
func tracer(from: Vector3, to: Vector3, speed: float) -> void:
	if from.distance_squared_to(to) < tracer_min_length * tracer_min_length:
		return
	_tracer_count += 1
	_tracers.add(from, to, speed, _camera_pos, _clock, TRACER_LIFE, tracer_width)


## The same ribbon, drawn for a round travelling toward the eye.
func hostile_tracer(from: Vector3, to: Vector3, speed: float) -> void:
	if from.distance_squared_to(to) < hostile_tracer_min_length * hostile_tracer_min_length:
		return
	_tracer_count += 1
	_tracers.add(
		from,
		to,
		speed,
		_camera_pos,
		_clock,
		TRACER_LIFE * hostile_tracer_life_gain,
		tracer_width * hostile_tracer_gain
	)


## Sparks, spray, dust and a hole, all keyed off the surface that was hit.
func impact(pos: Vector3, normal: Vector3, surface: int, intensity: float = 1.0) -> void:
	var kind: int = VFXSurface.valid(surface)
	var gain: float = maxf(intensity, 0.0)
	_impact_count += 1

	var count: int = mini(
		int(round(float(VFXSurface.SPARK_COUNT[kind]) * gain * spark_density)), impact_spark_cap
	)
	if count > 0:
		var field: VFXSparkField = _spray if VFXSurface.SPARK_WET[kind] != 0 else _sparks
		field.burst(
			pos,
			count,
			VFXSurface.SPARK_SPEED[kind],
			VFXSurface.SPARK_COLOR[kind],
			VFXSurface.SPARK_LIFE[kind],
			VFXSurface.SPARK_GRAVITY[kind],
			_ground_y,
			normal
		)

	var dust: int = int(round(float(VFXSurface.DUST_COUNT[kind]) * gain * dust_density))
	if dust > 0 and not _smoke_fine.too_close(pos, _camera_pos):
		_smoke_fine.puff(
			pos,
			dust,
			VFXSurface.DUST_SPREAD[kind],
			VFXSurface.DUST_DARK[kind],
			VFXSurface.DUST_LIFE,
			VFXSurface.DUST_RISE,
			VFXSurface.DUST_TINT[kind]
		)

	var hole: float = VFXSurface.DECAL_SIZE[kind]
	if hole > 0.0:
		decal(pos, normal, hole, VFXSurface.DECAL_HOT[kind] != 0, 0.0)


## A hole on its own. `life` of 0 keeps it until its slot comes round again,
## which for a 280-slot ring is the only lifetime a bullet hole needs.
func decal(
	pos: Vector3, normal: Vector3, size: float, hot: bool = false, life: float = 0.0
) -> void:
	_decal_count += 1
	_decals.add(pos, normal, size, hot, _clock, life)


func muzzle_flash(at: Node3D, scale: float) -> void:
	_shot_count += 1
	_muzzles.flash(at, scale)


func muzzle_flash_at(pos: Vector3, bore: Vector3, scale: float) -> void:
	_shot_count += 1
	_muzzles.flash_at(pos, bore, scale)


func explosion(pos: Vector3, radius: float) -> void:
	_blasts.blast(pos, radius, _camera_pos, _ground_y)


## `velocity` is world-space. A zero vector means "use the port's own frame",
## which is what a gun that has not been tuned yet should pass.
func shell(at: Node3D, velocity: Vector3) -> void:
	if at == null or not at.is_inside_tree():
		return
	var v: Vector3 = velocity
	if v.length_squared() < 1.0e-6:
		v = at.global_transform.basis * shell_default_velocity
	_shells.eject(at.global_position, v, _ground_y)


## A case from a bare position and a world-space velocity, for a shot somebody else fired.
## A remote round arrives as a line and a surface id, not as a node, so there is no eject
## port to read a basis off.
func shell_from(position: Vector3, velocity: Vector3) -> void:
	_shells.eject(position, velocity, _ground_y)


func puff(
	pos: Vector3, count: int, spread: float, dark: float, life: float, heavy: bool = false
) -> void:
	var field: VFXSmokeField = _smoke_heavy if heavy else _smoke_fine
	if field.too_close(pos, _camera_pos):
		return
	field.puff(pos, count, spread, dark, life, 0.14 if heavy else 0.35)


func heat(pos: Vector3, size: float, life: float) -> void:
	_blasts.heat(pos, size, life)


## Drop everything on the floor. Demos call this on reset so a reload does not
## start with the last run's holes still in the walls.
func clear_all() -> void:
	_decals.clear()
	_tracers.clear()
	_shells.clear()
	_muzzles.clear()
	_blasts.clear()
	_sparks.restart()
	_spray.restart()
	_smoke_fine.restart()
	_smoke_heavy.restart()


## The shared VFX clock, in seconds since the hub entered the tree. Every shader
## that fades on age is driven from this and not from the engine clock, so a
## paused demo does not age its own bullet holes.
func now() -> float:
	return _clock


## Live counts for the F3 overlay and the stress harness, in the order
## tracers, decals, impacts, shots, live shells, peak shells, peak flashes,
## peak blast lights, peak heat quads.
func counters() -> PackedInt32Array:
	return PackedInt32Array(
		[
			_tracer_count,
			_decal_count,
			_impact_count,
			_shot_count,
			_shells.live_count(),
			_shells.peak_count(),
			_muzzles.peak_count(),
			_blasts.light_peak(),
			_blasts.shimmer_peak_count(),
		]
	)


# --- budget -----------------------------------------------------------------


## Remember what the bake asked for. Every quality scale is a fraction of these,
## never a fraction of whatever the last preset left behind.
func _capture_budget() -> void:
	_base_budget = PackedInt32Array(
		[
			_sparks.amount,
			_spray.amount,
			_smoke_fine.amount,
			_smoke_heavy.amount,
			_decals.multimesh.instance_count,
			_tracers.multimesh.instance_count,
			_ash.motes,
			_motes.motes,
			_shells.budget,
			_muzzles.budget,
		]
	)


func _connect_settings() -> void:
	var settings: Node = get_tree().root.get_node_or_null(^"GameSettings")
	if settings == null:
		return
	if not settings.is_connected(&"preset_applied", _on_preset_applied):
		settings.connect(&"preset_applied", _on_preset_applied)
	_on_preset_applied(String(settings.get(&"quality_preset")))


func _on_preset_applied(preset_name: String) -> void:
	var index: int = GameSettings.PRESET_NAMES.find(preset_name)
	if index < 0 or index >= preset_budget_scale.size():
		return
	_apply_budget_scale(preset_budget_scale[index])


## Resize every pool. This reallocates particle buffers and MultiMesh instance
## arrays, so it happens on a preset change and never on a frame that fires.
func _apply_budget_scale(scale: float) -> void:
	var k: float = clampf(scale, 0.05, 1.0)
	if _base_budget.size() < 10:
		return
	_sparks.resize(int(_base_budget[0] * k))
	_spray.resize(int(_base_budget[1] * k))
	_smoke_fine.resize(int(_base_budget[2] * k))
	_smoke_heavy.resize(int(_base_budget[3] * k))
	_decals.resize(int(_base_budget[4] * k))
	_tracers.resize(int(_base_budget[5] * k))
	_ash.resize(int(_base_budget[6] * k))
	_motes.resize(int(_base_budget[7] * k))
	_shells.resize(int(_base_budget[8] * k))
	_muzzles.budget = maxi(int(_base_budget[9] * k), 1)
