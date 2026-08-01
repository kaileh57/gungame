@tool
class_name ScavWorldEnvironment
extends WorldEnvironment
## The look every demo uses: low warm sun, long shadows, distance haze, ACES.
##
## Instance `res://art/scav_world.tscn` — this script plus its three lights — into
## a demo and the lighting is done. The knobs below are live in the editor; the
## quality-dependent switches (SSAO, SSIL, glow, fog, volumetric fog) are not here
## because `GameSettings` owns them, and this node registers its Environment so
## they land automatically.
##
## Sun geometry is in one place. `sun_direction` points TOWARD the sun; the light
## is aimed the other way and the sky shader is told where to put its disc, so the
## disc and the shadows can never disagree.
##
## The constants below are the shipping values and they are the single source of
## truth: `_apply()` writes every one of them over the baked Environment at
## `_ready()`, and `tools/build_art.gd` reads the same constants when it bakes
## `environment.tres` and `scav_world.tscn`. They used to be two independent sets
## of literals, and because the script runs last, whatever was baked into the
## resource was silently reverted the moment a demo loaded.

## Direct light. A sixteen-degree sun only lands sin(16°) = 0.28 of its beam on
## flat ground but nearly all of it on a wall facing it, which is where the form
## shading comes from — so it has to be strong enough that the ground still reads
## at a quarter power. That factor of 0.28 is also why the fill below has to be
## small: at 1.7 against the old fill the sun was contributing 63% of the light on
## a horizontal surface, so a shadow on flat sand was only 2.7:1 down from its lit
## side — 1.4 stops, which is not a shadow, it is a smudge. This carries the
## ground at 5:1 instead.
const SUN_ENERGY: float = 2.3
## Degrees of angular size. Wider means softer shadow edges at range; the brief is
## hard shadows, and half a degree is about what the real sun subtends.
const SUN_ANGULAR_SIZE: float = 0.55
## Metres of shadow cascade. Past this, geometry is lit but casts nothing.
const SHADOW_DISTANCE: float = 140.0
## Warm light coming back up out of the sand. Nudged up as the ambient came down:
## it is the only warm thing in a shadow, and a shadow lit purely by the cold fill
## reads as slate rather than as sand out of the sun.
const BOUNCE_ENERGY: float = 0.24
## Cold light coming down out of the sky. The other half of the key, and the only
## thing separating a shadow from a hole: sky-sourced ambient integrates the whole
## dome and comes out neutral, so without a directional cold fill the shadow side
## of everything lands at the same hue as its lit side, only darker. Measured on
## the ash-flats road, which was a dead achromatic 0.095 before this went up.
const SKY_FILL_ENERGY: float = 0.30
## Sky-sourced ambient. `ambient_light_source` is the sky, so what a surface
## actually receives is this TIMES `SKY_ENERGY` in `build_art.gd` — 0.66 * 0.50 =
## 0.33 against the old 0.55, so shadows sit at 60% of the fill they used to and
## the sun-to-shade ratio on flat ground goes from 2.7:1 to about 4.5:1.
##
## The two factors are split deliberately rather than folded into one. `SKY_ENERGY`
## sets how bright the dome LOOKS and this sets how much of it lands on geometry;
## keeping them separate is what let the horizon come down out of white-out
## without taking every shadow in the game to black with it. Raised twice from an
## initial 0.45: once because a dark asphalt road in a building's shadow was
## landing at sRGB 8 — a hole, not a shadow — and again because the lamp-lit
## interiors have no sun and no sky of their own, so an ambient cut aimed at the
## desert lands on them at full strength and nothing else gives it back.
const AMBIENT_ENERGY: float = 0.78
## Metres before haze starts. Anything nearer reads at full contrast.
const FOG_BEGIN: float = 120.0
## Metres at which haze is total. The map is 1760 m across, so its far rim sits
## about 880 m out and the ramp has to be finished by then, not at 1100 m.
const FOG_END: float = 900.0
## How much of the haze lands on the sky itself. Deliberately small. The sky dome
## is a cold dark zenith over a warm bright horizon; the haze is a warm mid grey,
## so mixing any real quantity of it into the dome averages the two into a flat
## neutral and the sky loses both its gradient and its colour. At 0.3 the measured
## saturation of the top third of the frame was 0.04 — achromatic white.
const FOG_SKY_AFFECT: float = 0.08
## Brightness of the haze itself. Under one so that the far rim of the map sits
## below the sky standing behind it. At 1.0 the haze was linear 0.46 against a
## midsky of 0.21 — distant terrain was brighter than the air above it, which is
## not haze, it is glare, and it is why the horizon read as a white-out.
const FOG_ENERGY: float = 0.72
## How much of the haze colour is replaced by the actual sky behind the pixel.
## The higher this is the more the far rim dissolves into whatever it is standing
## in front of instead of being a flat swatch of `HAZE`.
const FOG_AERIAL: float = 0.55
## Forward scatter of the sun through the haze. This is not a small effect and it
## is not confined to the ground: Godot adds `light_colour * energy * pow(dot(eye,
## sun), 8) * this` straight into the fog colour, and the fog is then mixed into
## the SKY at `FOG_SKY_AFFECT`. At 0.30 against a sun of 2.3 that was putting
## about 0.06 of linear radiance into every sky pixel within twenty degrees of the
## sun — measured, it accounted for the whole of the pale wash that survived
## halving the dome and retuning the halo, and it scales with `SUN_ENERGY`, so
## raising the sun had quietly made it worse.
const FOG_SUN_SCATTER: float = 0.12
## Over one. The ground had to come up relative to a sky that has been halved;
## doing that with the sun alone would have driven the sun-facing walls into the
## clip, so a good part of it is bought here instead. This is also the only lever
## in the file that reaches the lamp-lit interiors — they see no sky and no sun —
## so it is what holds `gunbench` and the main menu where they were.
const EXPOSURE: float = 1.22
## Just over 1.0. ACES desaturates as it rolls off, so a scene shot through it
## already loses chroma at the top end; the old 0.96 was subtracting saturation a
## second time and turning the palette's warm neutrals into grey. The desaturation
## the brief asks for belongs in the palette, which already has it.
const SATURATION: float = 1.05
## One. Not a placeholder — this dial is actively harmful here. Godot's BCS
## contrast pivots on sRGB 0.5 and scales a pixel's distance from it, so on a
## frame whose subject sits low it costs the dark end far more than it gains at
## the top: at 1.10 the gunsmith bay, which lives entirely under sRGB 0.25, lost a
## third of its level and the ash-flats asphalt in shade went to 8, while the
## brightest sand in the game gained four counts. Contrast in this project is
## bought with the sun-to-fill ratio and with a sky that is no longer the
## brightest thing in frame; both are real and neither punishes the interiors.
const CONTRAST: float = 1.0
## ACES white point, and it is NOT a headroom control — Godot divides the fitted
## curve by rrt_odt(white), which asymptotes at 1.0165, so the whole range from
## 2.6 to infinity is worth a fifth of a stop of level. What it does move is the
## clip point: the curve reaches 1.0 at linear 1.44 with white 2.6 and at linear
## 3.9 with white 7.0. That is the difference between "the sun, a lit adobe wall
## and a hot specular are all 255" and "the wall is 225, the specular is 240 and
## only the disc clips". Headroom itself comes from `EXPOSURE` and from not
## letting the sky sit at linear 0.78.
const TONEMAP_WHITE: float = 7.0

@export_group("Sun")
## Direction toward the sun. Normalised on use. Late afternoon by default.
@export var sun_direction: Vector3 = Palette.SUN_DIRECTION:
	set(value):
		sun_direction = value
		_apply()
@export var sun_color: Color = Palette.SUN:
	set(value):
		sun_color = value
		_apply()
@export_range(0.0, 4.0, 0.01) var sun_energy: float = SUN_ENERGY:
	set(value):
		sun_energy = value
		_apply()
## Metres of shadow cascade. Past this, geometry is lit but casts nothing.
@export_range(32.0, 800.0, 1.0) var shadow_distance: float = SHADOW_DISTANCE:
	set(value):
		shadow_distance = value
		_apply()
## Cascades the sun splits its shadow into. This is a draw-call multiplier, not a
## quality dial: every caster inside `shadow_distance` is re-drawn once per
## cascade it touches, so four splits over a crowd is four extra passes over the
## crowd. Two is the shipping default — it holds a 1080p demo under the project's
## 800-call budget with sixty bodies on the field, where four does not.
@export_enum("Orthogonal:0", "Two splits:1", "Four splits:2") var shadow_cascades: int = 1:
	set(value):
		shadow_cascades = value
		_apply()
## Angular size of the sun in degrees. Wider means softer shadow edges at range.
@export_range(0.0, 4.0, 0.01) var sun_angular_size: float = SUN_ANGULAR_SIZE:
	set(value):
		sun_angular_size = value
		_apply()

@export_group("Fill")
## Warm light coming back up out of the sand.
@export_range(0.0, 1.0, 0.01) var bounce_energy: float = BOUNCE_ENERGY:
	set(value):
		bounce_energy = value
		_apply()
## Cold light coming down out of the sky. The other half of the key.
@export_range(0.0, 1.0, 0.01) var sky_fill_energy: float = SKY_FILL_ENERGY:
	set(value):
		sky_fill_energy = value
		_apply()
@export_range(0.0, 2.0, 0.01) var ambient_energy: float = AMBIENT_ENERGY:
	set(value):
		ambient_energy = value
		_apply()

@export_group("Haze")
@export var fog_color: Color = Palette.HAZE:
	set(value):
		fog_color = value
		_apply()
## Metres before haze starts. Anything nearer reads at full contrast.
@export_range(0.0, 400.0, 1.0) var fog_begin: float = FOG_BEGIN:
	set(value):
		fog_begin = value
		_apply()
## Metres at which haze is total. The reference's exponential-squared falloff is
## matched here by a depth fog with a curve of 1.35, not by copying its density.
@export_range(100.0, 3000.0, 1.0) var fog_end: float = FOG_END:
	set(value):
		fog_end = value
		_apply()
@export_range(0.0, 1.0, 0.01) var fog_sky_affect: float = FOG_SKY_AFFECT:
	set(value):
		fog_sky_affect = value
		_apply()
## Brightness of the haze. Under one so the far rim sits below the sky behind it.
@export_range(0.0, 2.0, 0.01) var fog_energy: float = FOG_ENERGY:
	set(value):
		fog_energy = value
		_apply()
## How much of the haze colour comes from the sky the pixel is standing against.
@export_range(0.0, 1.0, 0.01) var fog_aerial: float = FOG_AERIAL:
	set(value):
		fog_aerial = value
		_apply()
## Forward scatter of the sun through the haze. Reaches the sky, not just the
## ground, and scales with `sun_energy` — see the constant.
@export_range(0.0, 1.0, 0.01) var fog_sun_scatter: float = FOG_SUN_SCATTER:
	set(value):
		fog_sun_scatter = value
		_apply()

@export_group("Tone")
@export_range(0.1, 4.0, 0.01) var exposure: float = EXPOSURE:
	set(value):
		exposure = value
		_apply()
## ACES white point, in linear units. Anything at or above this clips.
@export_range(0.5, 8.0, 0.01) var tonemap_white: float = TONEMAP_WHITE:
	set(value):
		tonemap_white = value
		_apply()
@export_range(0.0, 2.0, 0.01) var contrast: float = CONTRAST:
	set(value):
		contrast = value
		_apply()
@export_range(0.0, 2.0, 0.01) var saturation: float = SATURATION:
	set(value):
		saturation = value
		_apply()

@export_group("Nodes")
@export var sun_path: NodePath = ^"Sun"
@export var bounce_path: NodePath = ^"Bounce"
@export var sky_fill_path: NodePath = ^"SkyFill"


func _ready() -> void:
	_apply()
	if Engine.is_editor_hint() or environment == null:
		return
	var settings: Node = _settings()
	if settings != null:
		settings.register_environment(environment)


func _exit_tree() -> void:
	if Engine.is_editor_hint() or environment == null:
		return
	var settings: Node = _settings()
	if settings != null:
		settings.unregister_environment(environment)


## The sun light, for anything that needs to know where the shadows come from.
func sun() -> DirectionalLight3D:
	return get_node_or_null(sun_path) as DirectionalLight3D


## The `GameSettings` autoload, or null when there is not one. Looked up by path
## rather than by its global identifier on purpose: the bake tools run this scene
## on a bare `SceneTree` where no autoload exists, and naming the singleton
## directly makes the whole script — and anything that imports it — fail to
## compile there. Quality settings simply do not apply during a bake.
func _settings() -> Node:
	var tree: SceneTree = get_tree()
	if tree == null or tree.root == null:
		return null
	return tree.root.get_node_or_null(^"GameSettings")


func _apply() -> void:
	if not is_inside_tree():
		return
	var dir: Vector3 = sun_direction.normalized()
	if dir.is_zero_approx():
		dir = Palette.SUN_DIRECTION
	_apply_sun(dir)
	_apply_fill()
	_apply_environment(dir)


func _apply_sun(dir: Vector3) -> void:
	var light: DirectionalLight3D = get_node_or_null(sun_path) as DirectionalLight3D
	if light == null:
		return
	_aim(light, dir)
	light.light_color = sun_color
	light.light_energy = sun_energy
	light.light_angular_distance = sun_angular_size
	light.shadow_enabled = true
	light.directional_shadow_mode = shadow_cascades as DirectionalLight3D.ShadowMode
	light.directional_shadow_max_distance = shadow_distance


func _apply_fill() -> void:
	var bounce: DirectionalLight3D = get_node_or_null(bounce_path) as DirectionalLight3D
	if bounce != null:
		bounce.light_energy = bounce_energy
	var fill: DirectionalLight3D = get_node_or_null(sky_fill_path) as DirectionalLight3D
	if fill != null:
		fill.light_energy = sky_fill_energy


func _apply_environment(dir: Vector3) -> void:
	if environment == null:
		return
	environment.ambient_light_energy = ambient_energy
	environment.tonemap_exposure = exposure
	environment.tonemap_white = tonemap_white
	environment.adjustment_contrast = contrast
	environment.adjustment_saturation = saturation
	environment.fog_light_color = fog_color
	environment.fog_light_energy = fog_energy
	environment.fog_sun_scatter = fog_sun_scatter
	environment.fog_depth_begin = fog_begin
	environment.fog_depth_end = fog_end
	environment.fog_sky_affect = fog_sky_affect
	environment.fog_aerial_perspective = fog_aerial
	environment.volumetric_fog_albedo = fog_color
	if environment.sky == null:
		return
	var sky_material: ShaderMaterial = environment.sky.sky_material as ShaderMaterial
	if sky_material != null:
		sky_material.set_shader_parameter("sun_direction", dir)


## Point a DirectionalLight3D so that it shines FROM `from_dir`. Godot lights emit
## along local -Z, so the node is placed along the incoming direction and aimed at
## the origin; near-vertical directions swap the up vector to stay well-conditioned.
static func _aim(light: DirectionalLight3D, from_dir: Vector3) -> void:
	var d: Vector3 = from_dir.normalized()
	var up: Vector3 = Vector3.UP
	if absf(d.y) > 0.98:
		up = Vector3.BACK
	light.look_at_from_position(d * 40.0, Vector3.ZERO, up)
