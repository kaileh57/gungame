class_name VisualsDusk
extends RefCounted
## The dusk look, and ONLY this demo's dusk look.
##
## `res://art/scav_world.tscn` and `res://art/environment.tres` are shared by all
## nine demos and they are a mid-afternoon balance: a sixteen-degree sun, a pale
## warm dome, a neutral haze. Editing them to make one demo dusky would make the
## other eight dusky too, so the visuals showpiece gets its own Environment, its
## own sky material and its own three lights, baked here by
## `res://tools/build_visuals.gd` into `res://demos/visuals/`.
##
## WHAT MAKES A SUNSET READ, in the order it matters:
##
##  1. THE SUN IS ON THE HORIZON. Three and a half degrees, not twelve. A surface
##     facing straight up then receives sin(3.5) = 0.061 of the beam and a wall
##     facing the sun receives nearly all of it, so the ground goes dark, the
##     west faces go molten, and every upright object throws a shadow sixteen
##     times its own height. That ratio IS the look; nothing else here can fake
##     it, and it is why `SUN_ENERGY` has to be most of a stop over the shared
##     value just to keep the flats off black.
##  2. THE DOME HAS A GRADIENT. `horizon_band` is the falloff of the horizon
##     colour into the mid colour, in units of sin(elevation) — the shared sky
##     uses 0.18, which spreads warm cream over the bottom thirty degrees of the
##     sky and reads as a wash. At 0.085 the orange is finished by fourteen
##     degrees and everything above it is the blue the flats are actually lit by.
##  3. THE SHADOWS ARE WARM. Ambient here is sky-sourced, so a dome whose lower
##     half is orange feeds warm light into every shadow for free; the cold
##     directional fill is cut to a third of the shared value so it tints rather
##     than governs, and the sand bounce goes up to carry the difference.
##  4. THE HAZE IS RED. Depth fog at dusk is sunlight that has been through a
##     hundred kilometres of atmosphere. `FOG_SUN_SCATTER` is two and a half
##     times the shared value, which is what puts the glow into the air on the
##     sun side of the map and leaves the other side cold.
##
## Every number below is a constant rather than an export because the scene these
## build is BAKED — the exports that survive into the shipped scene are the ones
## on `ScavWorldEnvironment` and on `VisualsDemo`, and this file writes their
## initial values. Change one here and re-run the builder.

## Sky dome, sRGB. The shader consumes linear, `_rgb()` converts.
const SKY_ZENITH: Color = Color("1b2138")
const SKY_MID: Color = Color("5b4a63")
const SKY_HORIZON: Color = Color("ff8b3d")
## What the dome fades to BELOW the horizon, and it has to sit JUST UNDER THE HAZE —
## `art/sky.gdshader` says so in its own comment and the reason only shows up in the
## air. The shader blends horizon to ground over 0.06 of sin(elevation), which is
## three and a half degrees, so anything much darker than the haze draws itself as a
## hard bar across every frame taken from above the terrain: fly the dash up two
## hundred metres and the true horizon lifts off the ridge line, and the strip of
## dome between them was a black band. Measured against `HAZE_COLOR` rather than
## guessed — this is that colour, one stop down.
const SKY_GROUND: Color = Color("8a5a3d")
## Falloff of the horizon colour into the mid colour, in units of sin(elevation).
const HORIZON_BAND: float = 0.085
## Brightness of the dome before the sun terms are added. Up from the shared 0.46:
## the gradient is now doing the work the shared dome did with sheer level.
const SKY_ENERGY: float = 0.70
## The disc, its aureole and its glow. All three go up — a sun ON the horizon is
## seen through the thickest air there is, and the halo is the whole of why a
## sunset photograph looks like one.
const SUN_DISC: float = 16.0
const SUN_HALO: float = 0.17
const SUN_GLOW: float = 0.062
## Dust in the band above the horizon. More of it than noon: this is the hour the
## flats are visibly full of it.
const CLOUD_AMOUNT: float = 1.35

## Direct light. Deep amber, not the shared cream.
const SUN_COLOR: Color = Color("ffb070")
## Warm light coming back up out of the sand.
const BOUNCE_COLOR: Color = Color("e0a163")
## Cold light coming down out of the sky, opposite the sun.
const SKY_FILL_COLOR: Color = Color("6a7ba6")
## The haze. Redder and darker than the shared `Palette.HAZE`.
const HAZE_COLOR: Color = Color("a06844")

## See (1) above: at 3.5 degrees this lands 0.26 on flat ground, which is about
## what the shared 2.3 at 16 degrees landed. The walls get the rest.
const SUN_ENERGY: float = 4.2
const SUN_ANGULAR_SIZE: float = 0.62
## Metres of shadow cascade. Long, because the shadows themselves are long: a six
## metre lamp standard at 3.5 degrees throws ninety-eight metres of shadow, and a
## cascade that ends at the shared 140 m cuts it in half across open ground. Two
## hundred and sixty covers that lamp with room over, and the water tower's own two
## hundred and forty metre shadow with none to spare, which is the right place to
## stop: it was 340, and the last eighty metres of it cost frames to shadow ground
## that is already four-fifths haze.
const SHADOW_DISTANCE: float = 260.0
## Splits the sun's shadow is divided into: 0 orthogonal, 1 two, 2 four. ORTHOGONAL,
## and this is the single biggest frame saving in the file. A cascade is a draw-call
## multiplier — every caster inside `SHADOW_DISTANCE` is re-drawn once per cascade it
## touches, and this scene stands at the edge of a 211-chunk town, so two splits meant
## drawing most of a city twice more per frame. One cascade over 260 m at the 8192
## map the Ultra preset asks for is 31 texels per metre, which is finer than the two
## splits gave the far half anyway; what two splits actually bought was resolution in
## the first 26 m, and nothing in this demo is read at that distance.
const SHADOW_CASCADES: int = 0
const BOUNCE_ENERGY: float = 0.46
const SKY_FILL_ENERGY: float = 0.09
const AMBIENT_ENERGY: float = 0.34

## Metres before haze starts, and the metre at which it is total. The far end is
## past the map's own rim (880 m from the centre) because the overlook stands
## outside the town and can see the rim beyond it at nearer 1250 m.
const FOG_BEGIN: float = 70.0
const FOG_END: float = 1250.0
const FOG_ENERGY: float = 0.60
const FOG_SKY_AFFECT: float = 0.05
const FOG_AERIAL: float = 0.62
## Forward scatter of the sun through the haze. The one number that makes the air
## on the sun side of the map glow and the air behind you stay cold.
const FOG_SUN_SCATTER: float = 0.30
const FOG_DEPTH_CURVE: float = 1.35
const VOLUMETRIC_DENSITY: float = 0.0006
## Metres the froxel volume reaches. Short on purpose: the volume is a fixed grid, so
## stretching it over 260 m spread the same slices thinner without adding anything —
## past about a hundred and sixty metres the depth fog is already carrying the air,
## and the volumetric pass is only there for the light shafts near the lamps.
const VOLUMETRIC_LENGTH: float = 160.0

const EXPOSURE: float = 1.28
const TONEMAP_WHITE: float = 7.0
const CONTRAST: float = 1.0
## Over the shared 1.05. ACES desaturates as it rolls off and a sunset is the one
## frame in the game whose subject IS its colour.
const SATURATION: float = 1.22

## Where the fill lights stand, as directions light arrives FROM. The bounce comes
## up out of the sand and slightly from the sun's side; the cold fill comes down
## out of the sky opposite it.
const BOUNCE_FROM: Vector3 = Vector3(-0.34, -0.90, -0.27)
const SKY_FILL_FROM: Vector3 = Vector3(0.62, 0.70, 0.36)

const SHADER_SKY: String = "res://art/sky.gdshader"


## The sky shader consumes LINEAR colour and the palette above is sRGB. Handing a
## `Color` straight to a sky uniform renders it about a stop and a half bright and
## half as saturated, which is exactly how a sunset turns into a cream wash.
static func rgb(color: Color) -> Vector3:
	var linear: Color = color.srgb_to_linear()
	return Vector3(linear.r, linear.g, linear.b)


## The dusk dome. Same shader as the shared sky — only the numbers differ.
static func sky_material(sun_direction: Vector3) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = load(SHADER_SKY) as Shader
	mat.set_shader_parameter("sun_direction", sun_direction.normalized())
	mat.set_shader_parameter("zenith_color", rgb(SKY_ZENITH))
	mat.set_shader_parameter("mid_color", rgb(SKY_MID))
	mat.set_shader_parameter("horizon_color", rgb(SKY_HORIZON))
	mat.set_shader_parameter("ground_color", rgb(SKY_GROUND))
	mat.set_shader_parameter("horizon_band", HORIZON_BAND)
	mat.set_shader_parameter("sky_energy", SKY_ENERGY)
	mat.set_shader_parameter("sun_disc", SUN_DISC)
	mat.set_shader_parameter("sun_halo", SUN_HALO)
	mat.set_shader_parameter("sun_glow", SUN_GLOW)
	mat.set_shader_parameter("cloud_amount", CLOUD_AMOUNT)
	return mat


## The dusk Environment. Built whole rather than duplicated off the shared one, so
## a change to the shared afternoon balance cannot quietly walk into this scene.
static func environment(sky_material_path: String) -> Environment:
	var sky := Sky.new()
	sky.sky_material = load(sky_material_path)
	sky.radiance_size = Sky.RADIANCE_SIZE_128
	sky.process_mode = Sky.PROCESS_MODE_REALTIME

	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_sky_contribution = 1.0
	env.ambient_light_energy = AMBIENT_ENERGY
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY

	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.tonemap_exposure = EXPOSURE
	env.tonemap_white = TONEMAP_WHITE
	env.adjustment_enabled = true
	env.adjustment_contrast = CONTRAST
	env.adjustment_saturation = SATURATION

	# Quality-gated by `GameSettings`; these are the Ultra values it scales from.
	env.ssao_enabled = true
	env.ssao_radius = 1.4
	env.ssao_intensity = 1.6
	env.ssao_light_affect = 0.1
	env.glow_enabled = true
	env.glow_intensity = 0.52
	env.glow_hdr_threshold = 1.35
	var levels: PackedFloat32Array = [0.30, 0.62, 0.46, 0.18, 0.07]
	for i in levels.size():
		env.set_glow_level(i + 1, levels[i])

	env.fog_enabled = true
	env.fog_mode = Environment.FOG_MODE_DEPTH
	env.fog_light_color = HAZE_COLOR
	env.fog_light_energy = FOG_ENERGY
	env.fog_sun_scatter = FOG_SUN_SCATTER
	env.fog_density = 1.0
	env.fog_aerial_perspective = FOG_AERIAL
	env.fog_sky_affect = FOG_SKY_AFFECT
	env.fog_depth_curve = FOG_DEPTH_CURVE
	env.fog_depth_begin = FOG_BEGIN
	env.fog_depth_end = FOG_END

	env.volumetric_fog_density = VOLUMETRIC_DENSITY
	env.volumetric_fog_albedo = HAZE_COLOR
	env.volumetric_fog_length = VOLUMETRIC_LENGTH
	env.volumetric_fog_ambient_inject = 0.14
	env.volumetric_fog_sky_affect = 0.1
	return env


## The `World` node this demo ships: a `WorldEnvironment` carrying the shared
## `ScavWorldEnvironment` script — so `VisualsDemo` drives it through exactly the
## same properties every other demo uses — over the dusk Environment and three
## lights of this demo's own.
##
## The three children are authored here rather than instanced from
## `scav_world.tscn` for one reason: the script exposes the fill ENERGIES but not
## the fill COLOURS, and a warm shadow is the third of the four things that make a
## sunset read. Owning the nodes is the only way to own their colour.
static func world_node(script: Script, env: Environment, sun_dir: Vector3) -> WorldEnvironment:
	var node := WorldEnvironment.new()
	node.name = "World"
	node.environment = env
	node.set_script(script)
	node.set("sun_direction", sun_dir)
	node.set("sun_color", SUN_COLOR)
	node.set("sun_energy", SUN_ENERGY)
	node.set("sun_angular_size", SUN_ANGULAR_SIZE)
	node.set("shadow_distance", SHADOW_DISTANCE)
	node.set("shadow_cascades", SHADOW_CASCADES)
	node.set("bounce_energy", BOUNCE_ENERGY)
	node.set("sky_fill_energy", SKY_FILL_ENERGY)
	node.set("ambient_energy", AMBIENT_ENERGY)
	node.set("fog_color", HAZE_COLOR)
	node.set("fog_begin", FOG_BEGIN)
	node.set("fog_end", FOG_END)
	node.set("fog_energy", FOG_ENERGY)
	node.set("fog_sky_affect", FOG_SKY_AFFECT)
	node.set("fog_aerial", FOG_AERIAL)
	node.set("fog_sun_scatter", FOG_SUN_SCATTER)
	node.set("exposure", EXPOSURE)
	node.set("tonemap_white", TONEMAP_WHITE)
	node.set("contrast", CONTRAST)
	node.set("saturation", SATURATION)

	node.add_child(_light("Sun", SUN_COLOR, SUN_ENERGY, sun_dir, true))
	var bounce: DirectionalLight3D = _light(
		"Bounce", BOUNCE_COLOR, BOUNCE_ENERGY, BOUNCE_FROM, false
	)
	bounce.sky_mode = DirectionalLight3D.SKY_MODE_LIGHT_ONLY
	node.add_child(bounce)
	var fill: DirectionalLight3D = _light(
		"SkyFill", SKY_FILL_COLOR, SKY_FILL_ENERGY, SKY_FILL_FROM, false
	)
	fill.sky_mode = DirectionalLight3D.SKY_MODE_LIGHT_ONLY
	node.add_child(fill)
	return node


## One directional light, aimed so that it shines FROM `from_dir`. Godot lights
## emit along local -Z, so the basis looks at the negated direction; the script
## re-aims the sun at `_ready()` and leaves the two fills exactly where this puts
## them, which is why their transforms have to be right in the bake.
static func _light(
	node_name: String, color: Color, energy: float, from_dir: Vector3, shadows: bool
) -> DirectionalLight3D:
	var light := DirectionalLight3D.new()
	light.name = node_name
	light.light_color = color
	light.light_energy = energy
	light.light_specular = 0.9 if shadows else 0.0
	light.shadow_enabled = shadows
	if shadows:
		light.light_angular_distance = SUN_ANGULAR_SIZE
		light.shadow_bias = 0.08
		light.shadow_normal_bias = 2.2
		light.shadow_blur = 0.9
		light.directional_shadow_mode = SHADOW_CASCADES as DirectionalLight3D.ShadowMode
		light.directional_shadow_split_1 = 0.10
		light.directional_shadow_blend_splits = true
		light.directional_shadow_fade_start = 0.9
		light.directional_shadow_max_distance = SHADOW_DISTANCE
	var d: Vector3 = from_dir.normalized()
	var up: Vector3 = Vector3.BACK if absf(d.y) > 0.98 else Vector3.UP
	light.transform = Transform3D(Basis.looking_at(-d, up), d * 40.0)
	return light
