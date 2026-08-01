@tool
extends SceneTree
## Bakes the shared art contract: the Environment, the sky, the surface materials
## and the world-lighting scene every demo instances.
##
## Run once by the bake phase. Nothing here happens at runtime; the committed
## `.tres` and `.tscn` are the shipped artifacts and this file is only how they
## are reproduced. Editing a material by hand and editing this script are both
## fine — but if they disagree, the next bake wins, so change it here.
##
## Run headless:
##   godot --headless --path <project> --script res://tools/build_art.gd

const SHADER_SCRAP: String = "res://art/shaders/scrap_surface.gdshader"
const SHADER_WORLD: String = "res://art/world_material.gdshader"
const SHADER_SKY: String = "res://art/sky.gdshader"
const SCRIPT_WORLD_ENV: String = "res://art/world_environment.gd"

const MATERIAL_DIR: String = "res://art/materials"
const ENV_PATH: String = "res://art/environment.tres"
const SKY_MATERIAL_PATH: String = "res://art/materials/sky_material.tres"
const WORLD_SCENE_PATH: String = "res://art/scav_world.tscn"

# The lighting values are owned by `ScavWorldEnvironment`, which writes them over
# the Environment at `_ready()`. Baking anything else here would be baking a value
# that never survives contact with a running demo.
const AMBIENT_ENERGY: float = ScavWorldEnvironment.AMBIENT_ENERGY
const CONTRAST: float = ScavWorldEnvironment.CONTRAST
const EXPOSURE: float = ScavWorldEnvironment.EXPOSURE
const FOG_AERIAL: float = ScavWorldEnvironment.FOG_AERIAL
const FOG_BEGIN: float = ScavWorldEnvironment.FOG_BEGIN
const FOG_END: float = ScavWorldEnvironment.FOG_END
const FOG_ENERGY: float = ScavWorldEnvironment.FOG_ENERGY
const FOG_SKY_AFFECT: float = ScavWorldEnvironment.FOG_SKY_AFFECT
const FOG_SUN_SCATTER: float = ScavWorldEnvironment.FOG_SUN_SCATTER
const SATURATION: float = ScavWorldEnvironment.SATURATION
const TONEMAP_WHITE: float = ScavWorldEnvironment.TONEMAP_WHITE

## Level of the sky dome. The four palette stops are authored as the radiance a
## neutral exposure wants, and measured against this frame they sat a full stop
## too high: `SKY_MID` — an achromatic light grey — was rendering at sRGB 195
## across the entire visible sky, and `SKY_HORIZON` at 245. The sky was the
## brightest object in every exterior shot and it filled half the frame, which is
## the whole of what "washed out" meant here.
##
## This is deliberately NOT folded into `AMBIENT_ENERGY` even though the two
## multiply on every surface, because they are answers to different questions:
## this one is how bright the sky looks and that one is how much of it lands on
## geometry. Halving the dome and raising the ambient to compensate is exactly
## how the horizon came out of white-out without the shadows going to black.
const SKY_ENERGY: float = 0.46

## Object units per metre for world- and creature-scale geometry.
const DETAIL_WORLD: float = 3.2
## Gun parts are modelled at 1 unit = 90 mm and the reference's noise frequencies
## are already expressed in those units, so they take the detail field raw.
const DETAIL_GUN: float = 1.0


func _initialize() -> void:
	build()
	quit()


static func build() -> void:
	DirAccess.make_dir_recursive_absolute(MATERIAL_DIR)
	_build_sky_material()
	_build_environment()
	_build_scrap_materials()
	_build_gun_materials()
	_build_effect_materials()
	_build_world_material()
	_build_world_scene()
	print("build_art: baked environment, 13 materials and scav_world.tscn")


static func _save(res: Resource, path: String) -> void:
	res.resource_path = ""
	var err: Error = ResourceSaver.save(res, path)
	if err != OK:
		push_error("build_art: could not save %s (error %d)." % [path, err])


## The sky shader consumes linear colour. The palette is sRGB. Converting here is
## the whole of the contract: hand a `Color` straight to a sky uniform and it
## renders roughly a stop and a half too bright and half as saturated, which is
## what turned the dome into flat cream.
static func _sky_rgb(color: Color) -> Vector3:
	var linear: Color = color.srgb_to_linear()
	return Vector3(linear.r, linear.g, linear.b)


static func _build_sky_material() -> void:
	var mat := ShaderMaterial.new()
	mat.shader = load(SHADER_SKY)
	mat.set_shader_parameter("sun_direction", Palette.SUN_DIRECTION)
	mat.set_shader_parameter("zenith_color", _sky_rgb(Palette.SKY_ZENITH))
	mat.set_shader_parameter("mid_color", _sky_rgb(Palette.SKY_MID))
	mat.set_shader_parameter("horizon_color", _sky_rgb(Palette.SKY_HORIZON))
	mat.set_shader_parameter("ground_color", _sky_rgb(Palette.SKY_GROUND))
	mat.set_shader_parameter("horizon_band", 0.18)
	mat.set_shader_parameter("sky_energy", SKY_ENERGY)
	# The disc is small and very bright rather than large and merely white: 0.57
	# degrees of half-width at nine units of radiance clips its core and nothing
	# else, where the old 1.3-degree disc at five units clipped a saucer and then
	# fed that saucer to the glow. `sun_halo` drives two terms, a 6.4-degree
	# aureole and a 1.8-degree ring; together they are a fifth of what the old
	# 18-degree halo was laying across the sky.
	mat.set_shader_parameter("sun_disc", 9.0)
	mat.set_shader_parameter("sun_halo", 0.075)
	mat.set_shader_parameter("sun_glow", 0.022)
	mat.set_shader_parameter("cloud_amount", 1.0)
	_save(mat, SKY_MATERIAL_PATH)


static func _build_environment() -> void:
	var sky := Sky.new()
	sky.sky_material = load(SKY_MATERIAL_PATH)
	sky.radiance_size = Sky.RADIANCE_SIZE_128
	sky.process_mode = Sky.PROCESS_MODE_REALTIME

	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_sky_contribution = 1.0
	env.ambient_light_energy = AMBIENT_ENERGY
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY

	# Godot's ACES divides the fitted curve by rrt_odt(white), and that function
	# asymptotes at 1.0165 — so every white point from 2.6 upward is worth at most
	# a fifth of a stop of level, and raising it is NOT how headroom is bought.
	# What it moves is the clip point, because the curve reaches 1.0 at linear
	# 1.44 with white 2.6 and at linear 3.9 with white 7.0. Under the old value a
	# sunlit adobe wall, a hot specular and the sun disc were all exactly 255.
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.tonemap_exposure = EXPOSURE
	env.tonemap_white = TONEMAP_WHITE

	# Depth fog, not exponential: the reference's haze is exp(-(density*depth)^2),
	# which is quadratic in depth. The ramp is aimed at the map, which is 1760 m
	# across, so the far rim sits about 880 m out: haze starts at 120 m, is a
	# seventh of the way in at 300 m, a third at 500 m and total by 900 m. Ending
	# at 1100 m with a curve of 2.0 put the whole ramp in the last three hundred
	# metres and left the dunes at 400 m reading at full contrast against a sky
	# they should already be melting into.
	env.fog_enabled = true
	env.fog_mode = Environment.FOG_MODE_DEPTH
	env.fog_light_color = Palette.HAZE
	env.fog_light_energy = FOG_ENERGY
	env.fog_sun_scatter = FOG_SUN_SCATTER
	env.fog_density = 1.0
	env.fog_depth_begin = FOG_BEGIN
	env.fog_depth_end = FOG_END
	env.fog_depth_curve = 1.35
	env.fog_sky_affect = FOG_SKY_AFFECT
	# Let the far haze pick up the sky it is standing in front of. Without this the
	# terrain rim is a flat swatch of HAZE and the horizon is a hard seam.
	env.fog_aerial_perspective = FOG_AERIAL
	env.fog_height_density = 0.0

	# `GameSettings` turns this on for High and Ultra, so these numbers ship. At
	# 0.012 per metre over a 128 m volume the froxel grid reached 78% opacity at
	# its far face — and because everything past the volume inherits that far face,
	# the sky, the dunes and the props were all being replaced by four fifths of
	# flat haze. That, not the depth fog, was the veil. 0.0010 over 240 m is 21% at
	# the far face: aerial perspective you can see, not a lid on the whole frame.
	env.volumetric_fog_enabled = false
	env.volumetric_fog_density = 0.0006
	env.volumetric_fog_albedo = Palette.HAZE
	env.volumetric_fog_anisotropy = 0.20
	env.volumetric_fog_length = 240.0
	env.volumetric_fog_detail_spread = 2.0
	env.volumetric_fog_ambient_inject = 0.1
	env.volumetric_fog_sky_affect = 0.1

	env.ssao_enabled = true
	env.ssao_radius = 1.4
	env.ssao_intensity = 1.6
	env.ssao_power = 1.5
	env.ssao_detail = 0.5
	env.ssao_horizon = 0.06
	env.ssao_sharpness = 0.98
	env.ssao_light_affect = 0.1
	env.ssao_ao_channel_affect = 0.0

	env.ssil_enabled = false
	env.ssil_radius = 5.0
	env.ssil_intensity = 1.0
	env.ssil_sharpness = 0.98
	env.ssil_normal_rejection = 1.0

	# Just enough bloom for a muzzle flash and an exfil lamp to bleed. Anything
	# more and the whole desert starts to glow, which is the wrong desert — and a
	# sun this low is in frame constantly, so the weight has to sit on the small
	# radii.
	#
	# `glow_bloom` was the real offender and it is now zero. It is not a strength
	# dial: the downsample takes `max(smoothstep(threshold, threshold + scale,
	# luminance), glow_bloom)`, so 0.02 fed two per cent of EVERY pixel in the
	# frame — the whole sky included — into the glow chain regardless of the
	# threshold, and screen-blending that back over the image is a flat veil. With
	# it at zero only what actually clears 1.6 blooms, which is the disc, the
	# muzzle flash and the ember lamps, and nothing else in the game reaches it.
	#
	# The weights also move inward one level. The two widest were what turned the
	# disc into a white quarter-frame; the new smallest level is what keeps a
	# muzzle flash reading as a flash rather than as a soft patch.
	env.glow_enabled = true
	env.glow_intensity = 0.45
	env.glow_strength = 1.0
	env.glow_bloom = 0.0
	env.glow_blend_mode = Environment.GLOW_BLEND_MODE_SCREEN
	env.glow_hdr_threshold = 1.6
	env.glow_hdr_scale = 2.0
	env.set_glow_level(0, 0.28)
	env.set_glow_level(1, 0.60)
	env.set_glow_level(2, 0.42)
	env.set_glow_level(3, 0.14)
	env.set_glow_level(4, 0.05)
	env.set_glow_level(5, 0.0)

	env.adjustment_enabled = true
	env.adjustment_brightness = 1.0
	env.adjustment_contrast = CONTRAST
	env.adjustment_saturation = SATURATION

	_save(env, ENV_PATH)


static func _scrap_material(
	surface: int,
	color: Color,
	metal: float,
	rough: float,
	detail: float,
	bump_scale: float,
	bump_amount: float,
	detail_gain: float = 1.0
) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = load(SHADER_SCRAP)
	mat.set_shader_parameter("surface_type", surface)
	mat.set_shader_parameter("albedo", color)
	mat.set_shader_parameter("metallic_base", metal)
	mat.set_shader_parameter("roughness_base", rough)
	mat.set_shader_parameter("detail_scale", detail)
	mat.set_shader_parameter("detail_gain", detail_gain)
	mat.set_shader_parameter("bump_scale", bump_scale)
	mat.set_shader_parameter("bump_amount", bump_amount)
	mat.set_shader_parameter("emission_color", Color.BLACK)
	mat.set_shader_parameter("emission_energy", 0.0)
	mat.set_shader_parameter("flat_shaded", false)
	return mat


## The six world- and creature-scale surfaces. Per-object colour comes from the
## `tint` instance uniform or from MultiMesh instance colour — never from a
## duplicated material.
##
## `bump_scale` is cycles per object unit, and for these materials one unit is one
## metre, so 26.0 is a 3.8 cm micro-relief. It used to be 9.0 — an 11 cm relief,
## which is not grime, it is topography, and it is half of why every scavenged
## surface in the game read as smeared cloud rather than material.
static func _build_scrap_materials() -> void:
	_save(
		_scrap_material(
			Palette.Surface.STEEL, Palette.STEEL, 0.74, 0.50, DETAIL_WORLD, 26.0, 0.011
		),
		"res://art/materials/scrap_steel.tres"
	)
	_save(
		_scrap_material(
			Palette.Surface.TIMBER, Palette.TIMBER, 0.04, 0.82, DETAIL_WORLD, 22.0, 0.012
		),
		"res://art/materials/scrap_timber.tres"
	)
	_save(
		_scrap_material(
			Palette.Surface.POLYMER, Color("26282b"), 0.05, 0.78, DETAIL_WORLD, 28.0, 0.009
		),
		"res://art/materials/scrap_polymer.tres"
	)
	_save(
		_scrap_material(
			Palette.Surface.CANVAS, Palette.CANVAS, 0.02, 0.95, DETAIL_WORLD, 34.0, 0.012
		),
		"res://art/materials/scrap_canvas.tres"
	)
	_save(
		_scrap_material(
			Palette.Surface.FLESH, Color("836158"), 0.02, 0.62, DETAIL_WORLD, 18.0, 0.014
		),
		"res://art/materials/scrap_flesh.tres"
	)
	_save(
		_scrap_material(
			Palette.Surface.CHITIN, Color("3a352e"), 0.10, 0.38, DETAIL_WORLD, 24.0, 0.013
		),
		"res://art/materials/scrap_chitin.tres"
	)


## Three materials cover all 95 gun parts: hot metal, held timber, moulded polymer.
## Per-weapon tint rides on the `tint` instance uniform.
##
## One gun unit is 90 mm, so `bump_scale` 11.0 is an 8 mm relief — the scale of
## bead-blasting and checkering on something held at arm's length. The old 3.0-3.6
## was a 25 mm relief, which on a receiver is a dent, not a finish.
##
## These three carry a `detail_gain` above one and the six world materials do not.
## A gun part fills a quarter of the screen at forty centimetres, where the four
## per cent modulation that reads perfectly as grain on a drum three metres away is
## under the threshold at which anything reads as material at all: the magazine of
## the range's shotgun was coming back as a blank grey plate, which is the single
## most placeholder-looking thing a first-person game can put in front of the eye.
##
## Steel is also stepped back off a mirror. At 0.72 metallic and 0.50 rough a flat
## receiver flank is a sky reflector, and in the viewmodel pass the sky is the only
## thing there is to reflect, so the part came back as one smooth gradient with its
## whole albedo — mill tooth, rust, scratches, pitting — multiplied away to nothing.
static func _build_gun_materials() -> void:
	_save(
		_scrap_material(
			Palette.Surface.STEEL, Palette.STEEL, 0.62, 0.56, DETAIL_GUN, 12.0, 0.013, 2.1
		),
		"res://art/materials/gun_steel.tres"
	)
	_save(
		_scrap_material(
			Palette.Surface.TIMBER, Palette.TIMBER, 0.05, 0.82, DETAIL_GUN, 10.0, 0.011, 2.1
		),
		"res://art/materials/gun_timber.tres"
	)
	_save(
		_scrap_material(
			Palette.Surface.POLYMER, Color("26282b"), 0.05, 0.82, DETAIL_GUN, 11.0, 0.010, 2.1
		),
		"res://art/materials/gun_polymer.tres"
	)


static func _build_effect_materials() -> void:
	var ember := _scrap_material(
		Palette.Surface.POLYMER, Color("12140f"), 0.0, 0.40, DETAIL_WORLD, 28.0, 0.008
	)
	ember.set_shader_parameter("emission_color", Palette.EMISSIVE[&"glow"]["color"])
	ember.set_shader_parameter("emission_energy", Palette.EMISSIVE[&"glow"]["energy"])
	_save(ember, "res://art/materials/glow_ember.tres")

	var sensor := _scrap_material(
		Palette.Surface.POLYMER, Color("0f1416"), 0.0, 0.40, DETAIL_WORLD, 28.0, 0.008
	)
	sensor.set_shader_parameter("emission_color", Palette.EMISSIVE[&"glowc"]["color"])
	sensor.set_shader_parameter("emission_energy", Palette.EMISSIVE[&"glowc"]["energy"])
	_save(sensor, "res://art/materials/glow_sensor.tres")

	# Muzzle flare. Unshaded and additive, alpha 0.85, no shadow interaction, and
	# excluded from every mass and hitbox query by the systems that spawn it.
	var flash := StandardMaterial3D.new()
	flash.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	flash.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	flash.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	flash.cull_mode = BaseMaterial3D.CULL_DISABLED
	flash.albedo_color = Color(Palette.EMISSIVE[&"flash"]["color"], 0.85)
	flash.disable_receive_shadows = true
	flash.disable_ambient_light = true
	flash.no_depth_test = false
	_save(flash, "res://art/materials/muzzle_flash.tres")


## One material for the whole map. Surface id and road blend ride in on CUSTOM0.
static func _build_world_material() -> void:
	var mat := ShaderMaterial.new()
	mat.shader = load(SHADER_WORLD)
	mat.set_shader_parameter("u_seed", 0.37)
	mat.set_shader_parameter("metallic_base", 0.0)
	mat.set_shader_parameter("roughness_base", 0.9)
	_save(mat, "res://art/materials/world_surface.tres")


static func _build_world_scene() -> void:
	var root := WorldEnvironment.new()
	root.name = "ScavWorld"
	root.set_script(load(SCRIPT_WORLD_ENV))
	root.environment = load(ENV_PATH)

	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	_aim(sun, Palette.SUN_DIRECTION)
	sun.light_color = Palette.SUN
	sun.light_energy = ScavWorldEnvironment.SUN_ENERGY
	sun.light_angular_distance = ScavWorldEnvironment.SUN_ANGULAR_SIZE
	sun.light_specular = 0.9
	sun.shadow_enabled = true
	# A sixteen-degree sun rakes across the ground, and a raking sun is where depth
	# bias runs out: the depth slope under the shadow texel is huge, so the constant
	# term has to grow with it. These are tuned against the range demo's rail posts,
	# which are the worst case in the project — thin, vertical, on flat sand.
	sun.shadow_bias = 0.06
	sun.shadow_normal_bias = 1.6
	sun.shadow_blur = 0.8
	# Two cascades, not four. A cascade is a whole extra draw of every caster it
	# touches, so the split count multiplies the scene's draw-call cost directly:
	# measured on the firefight demo, four splits over sixty bodies cost 1232 calls
	# against a budget of 800, and two cost 767 for a shadow nobody can tell apart
	# at 1080p. The near split ends at 0.12 * 140 m = 17 m, which keeps full
	# resolution over the bodies and props the camera is actually standing among.
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
	sun.directional_shadow_split_1 = 0.12
	sun.directional_shadow_blend_splits = true
	sun.directional_shadow_max_distance = ScavWorldEnvironment.SHADOW_DISTANCE
	sun.directional_shadow_fade_start = 0.85
	root.add_child(sun)
	sun.owner = root

	# Ground bounce: warm, comes from below, casts nothing.
	var bounce := DirectionalLight3D.new()
	bounce.name = "Bounce"
	_aim(bounce, Vector3(0.3, -1.0, 0.2))
	bounce.light_color = Palette.BOUNCE
	bounce.light_energy = ScavWorldEnvironment.BOUNCE_ENERGY
	bounce.light_specular = 0.0
	bounce.shadow_enabled = false
	bounce.sky_mode = DirectionalLight3D.SKY_MODE_LIGHT_ONLY
	root.add_child(bounce)
	bounce.owner = root

	# Sky fill: cold, from the opposite quarter, casts nothing.
	var fill := DirectionalLight3D.new()
	fill.name = "SkyFill"
	_aim(fill, Vector3(0.6, 0.5, 0.8))
	fill.light_color = Palette.SKY_FILL
	fill.light_energy = ScavWorldEnvironment.SKY_FILL_ENERGY
	fill.light_specular = 0.0
	fill.shadow_enabled = false
	fill.sky_mode = DirectionalLight3D.SKY_MODE_LIGHT_ONLY
	root.add_child(fill)
	fill.owner = root

	var packed := PackedScene.new()
	var err: Error = packed.pack(root)
	if err != OK:
		push_error("build_art: packing scav_world failed (error %d)." % err)
		root.free()
		return
	_save(packed, WORLD_SCENE_PATH)
	root.free()


## Aim a light so that it shines FROM `from_dir` toward the origin. Godot lights
## emit along local -Z. Near-vertical directions swap the up vector so the basis
## stays well-conditioned.
static func _aim(light: DirectionalLight3D, from_dir: Vector3) -> void:
	var d: Vector3 = from_dir.normalized()
	var up: Vector3 = Vector3.UP
	if absf(d.y) > 0.98:
		up = Vector3.BACK
	light.look_at_from_position(d * 40.0, Vector3.ZERO, up)
