class_name BeastMat
extends RefCounted
## The bestiary material table — 18 surfaces mapped onto ART's shared scrap shader.
##
## `type` selects the shader's fragment branch: 0 rusted steel, 1 timber,
## 2 polymer/rubber, 3 canvas/cloth, 4 flesh, 5 chitin/bone. `dens` and `fill`
## feed the density fallback for any rig that does not declare its own `rho`;
## `HARD` (below) is the armour-bearing fraction that drives the `cover` stat.
##
## The reference also carried an `env` (envMapIntensity) column. Godot's scrap
## shader takes its reflections from the world environment directly and has no
## such input, so that column is deliberately absent rather than carried dead.
##
## `flash` is the muzzle flare: it is excluded from every mass, area, bounds,
## floor and penetration query, and lives at scale 1e-4 until a shot inflates it.

const SHADER_PATH: String = "res://art/shaders/scrap_surface.gdshader"
const MATERIAL_DIR: String = "res://data/enemies/materials"

## Object-space detail frequency. One model unit is one metre for creatures.
const DETAIL_SCALE: float = 3.2

const TABLE: Dictionary = {
	"steel":
	{"type": 0, "col": "#4d4a44", "metal": 0.74, "rough": 0.50, "dens": 7800.0, "fill": 0.16},
	"ironox":
	{"type": 0, "col": "#6b4a34", "metal": 0.55, "rough": 0.72, "dens": 7500.0, "fill": 0.15},
	"gunmet":
	{"type": 0, "col": "#33353a", "metal": 0.80, "rough": 0.42, "dens": 7900.0, "fill": 0.14},
	"brass":
	{"type": 0, "col": "#8a7238", "metal": 0.85, "rough": 0.38, "dens": 8400.0, "fill": 0.18},
	"alum":
	{"type": 0, "col": "#7d8288", "metal": 0.78, "rough": 0.44, "dens": 2700.0, "fill": 0.20},
	"timber":
	{"type": 1, "col": "#8a5a2b", "metal": 0.04, "rough": 0.82, "dens": 700.0, "fill": 0.75},
	"poly":
	{"type": 2, "col": "#26282b", "metal": 0.05, "rough": 0.78, "dens": 1150.0, "fill": 0.28},
	"rubber":
	{"type": 2, "col": "#141517", "metal": 0.03, "rough": 0.92, "dens": 1150.0, "fill": 0.22},
	"canvas":
	{"type": 3, "col": "#6b6152", "metal": 0.02, "rough": 0.95, "dens": 700.0, "fill": 0.13},
	"hide":
	{"type": 3, "col": "#4a3a2c", "metal": 0.03, "rough": 0.80, "dens": 900.0, "fill": 0.16},
	"flesh":
	{"type": 4, "col": "#836158", "metal": 0.02, "rough": 0.62, "dens": 1050.0, "fill": 0.88},
	"pallid":
	{"type": 4, "col": "#9b8d80", "metal": 0.02, "rough": 0.58, "dens": 1040.0, "fill": 0.82},
	"gut":
	{"type": 4, "col": "#5d3a34", "metal": 0.02, "rough": 0.50, "dens": 1030.0, "fill": 0.88},
	"chitin":
	{"type": 5, "col": "#3a352e", "metal": 0.10, "rough": 0.38, "dens": 1300.0, "fill": 0.32},
	"bone":
	{"type": 5, "col": "#b6ac96", "metal": 0.03, "rough": 0.55, "dens": 1900.0, "fill": 0.55},
	"glow":
	{
		"type": 2,
		"col": "#12140f",
		"metal": 0.0,
		"rough": 0.40,
		"dens": 1200.0,
		"fill": 0.20,
		"emis": "#c8451f",
		"emis_i": 2.6
	},
	"glowc":
	{
		"type": 2,
		"col": "#0f1416",
		"metal": 0.0,
		"rough": 0.40,
		"dens": 1200.0,
		"fill": 0.20,
		"emis": "#3fa8c8",
		"emis_i": 2.2
	},
	"flash":
	{
		"type": 2,
		"col": "#000000",
		"metal": 0.0,
		"rough": 1.0,
		"dens": 1.0,
		"fill": 0.0,
		"emis": "#ffcf7a",
		"emis_i": 5.0,
		"fx": true
	}
}

## Fraction of a surface that counts as armour. Anything absent contributes zero,
## which is why the gorger — all gut, flesh, hide and canvas — has `cover` 0.
const HARD: Dictionary = {
	"steel": 1.0,
	"ironox": 0.85,
	"gunmet": 1.0,
	"alum": 0.62,
	"brass": 0.70,
	"chitin": 0.45,
	"bone": 0.30,
	"poly": 0.22
}


## True for the muzzle-flare pseudo-material, which every measurement skips.
static func is_fx(key: StringName) -> bool:
	return bool(TABLE[String(key)].get("fx", false))


## Armour-bearing fraction of a surface.
static func hardness(key: StringName) -> float:
	return float(HARD.get(String(key), 0.0))


## Fallback density in kg/m3 for rigs that declare no `rho`: bulk density times
## the fraction of the primitive that is actually solid.
static func density(key: StringName) -> float:
	var d: Dictionary = TABLE[String(key)]
	return float(d["dens"]) * float(d["fill"])


## Stable identifier for a (material, colour-override) pair. One material per id.
static func material_id(key: StringName, col_override: String = "") -> String:
	if col_override.is_empty():
		return String(key)
	return "%s_%s" % [String(key), col_override.trim_prefix("#")]


## Path the bake writes this material to, and the runtime loads it from.
static func material_path(key: StringName, col_override: String = "") -> String:
	return "%s/%s.tres" % [MATERIAL_DIR, material_id(key, col_override)]


## Derivative-bump frequency and depth for a shader surface type.
static func bump_for_type(surface_type: int) -> Vector2:
	match surface_type:
		3:
			return Vector2(16.0, 0.012)
		4:
			return Vector2(7.0, 0.016)
		5:
			return Vector2(12.0, 0.013)
	return Vector2(9.0, 0.011)


## Build the material for one (key, colour-override) pair. Bake-time only —
## shipping code loads the saved `.tres`.
static func build_material(key: StringName, col_override: String = "") -> Material:
	var d: Dictionary = TABLE[String(key)]
	if bool(d.get("fx", false)):
		return _build_flash_material(d)
	var albedo: Color = Color(col_override if not col_override.is_empty() else String(d["col"]))
	var mat := ShaderMaterial.new()
	mat.shader = load(SHADER_PATH) as Shader
	var surface_type: int = int(d["type"])
	var bump: Vector2 = bump_for_type(surface_type)
	mat.set_shader_parameter("surface_type", surface_type)
	mat.set_shader_parameter("albedo", albedo)
	mat.set_shader_parameter("metallic_base", float(d["metal"]))
	mat.set_shader_parameter("roughness_base", float(d["rough"]))
	mat.set_shader_parameter("detail_scale", DETAIL_SCALE)
	mat.set_shader_parameter("bump_scale", bump.x)
	mat.set_shader_parameter("bump_amount", bump.y)
	# Every beast material in the reference is `flatShading: true`. Faceted is the
	# art direction, not a compromise: it is what makes a 12-segment sphere read as
	# hammered scrap instead of a low-poly ball.
	mat.set_shader_parameter("flat_shaded", true)
	var emis: String = String(d.get("emis", ""))
	if emis.is_empty():
		mat.set_shader_parameter("emission_color", Color.BLACK)
		mat.set_shader_parameter("emission_energy", 0.0)
	else:
		mat.set_shader_parameter("emission_color", Color(emis))
		mat.set_shader_parameter("emission_energy", float(d["emis_i"]))
	mat.resource_name = material_id(key, col_override)
	return mat


## The muzzle flare. Unlit, additive, depth-write off — it is a light, not a solid.
## `emis * emis_i` is deliberately allowed past 1.0 so the flare blows out on an
## HDR target the way a real muzzle blast does.
static func _build_flash_material(d: Dictionary) -> Material:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.disable_ambient_light = true
	mat.disable_receive_shadows = true
	mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	var glow: Color = Color(String(d["emis"])) * float(d["emis_i"])
	mat.albedo_color = Color(glow.r, glow.g, glow.b, 0.85)
	mat.resource_name = "flash"
	return mat
