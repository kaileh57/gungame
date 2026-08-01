class_name Palette
extends RefCounted
## Every colour the project is allowed to use, as typed constants.
##
## The look is post-apocalyptic scav: sun-bleached ash desert, desaturated
## warm-neutral everything, one hot accent orange and one rare gold. If a colour
## is not in this file it does not belong in the game.
##
## All values are sRGB, which is how Godot stores `Color` and how
## `BaseMaterial3D.albedo_color` and `source_color` shader uniforms expect them.
## Convert with `.srgb_to_linear()` only when writing raw vertex colours or sky
## shader constants, which are consumed linear.

## Surface branch selector for `scrap_surface.gdshader`. Distinct from the world
## material's nine-way surface table, which is the terrain and town's own thing.
enum Surface { STEEL = 0, TIMBER = 1, POLYMER = 2, CANVAS = 3, FLESH = 4, CHITIN = 5 }

# --- the six neutrals plus two accents -------------------------------------

## Oxidised iron. The most common colour in the world.
const RUST: Color = Color("6b4a34")
## Bare, weathered steel.
const STEEL: Color = Color("4d4a44")
## Blued, oiled metal. Guns and machinery.
const GUNMETAL: Color = Color("33353a")
## Sun-dried timber. Stocks, poles, roof beams.
const TIMBER: Color = Color("8a5a2b")
## Canvas, webbing, tarpaulin.
const CANVAS: Color = Color("6b6152")
## Bone, bleached plaster, old paint.
const BONE: Color = Color("b6ac96")
## The single hot accent. Exfil markers, ember glow, warlord-grade gear.
const ACCENT_ORANGE: Color = Color("d8822f")
## Rare. Relic-grade only. If it is on screen twice, one of them is wrong.
const GOLD: Color = Color("e6c14f")

# --- tiers ------------------------------------------------------------------

const TIER_HAZARD: Color = Color("a03636")
const TIER_SCRAP: Color = Color("6f6a63")
const TIER_COBBLED: Color = Color("8a9a6b")
const TIER_FIELD_GRADE: Color = Color("57a0bb")
const TIER_GUNSMITHED: Color = Color("9a79c8")
const TIER_WARLORD: Color = Color("d8822f")
const TIER_RELIC: Color = Color("e6c14f")

## Indexed by tier rank, 0 Hazard through 6 Relic. Shared by the gun tiers and
## the bestiary threat tiers — a Warlord gun and a Warlord beast read the same.
const TIER_COLORS: PackedColorArray = [
	TIER_HAZARD,
	TIER_SCRAP,
	TIER_COBBLED,
	TIER_FIELD_GRADE,
	TIER_GUNSMITHED,
	TIER_WARLORD,
	TIER_RELIC,
]

const GUN_TIER_NAMES: PackedStringArray = [
	"Hazard",
	"Scrap",
	"Cobbled",
	"Field-Grade",
	"Gunsmithed",
	"Warlord-Grade",
	"Relic",
]

const BEAST_TIER_NAMES: PackedStringArray = [
	"Vermin",
	"Common",
	"Hardened",
	"Elite",
	"Warlord",
	"Apex",
]

# --- factions ---------------------------------------------------------------

## The three factions read apart on THREE axes at once, because at eighty metres
## a body is twenty pixels and one axis is not enough. Scav is warm and light,
## Foundry is warm and dark and the only hot hue on the field, Choir is cool and
## mid. Hue alone would fail in shadow; value alone would fail against the sand.
##
## Every one of these is a MULTIPLIER, not a paint. `EnemyBody.set_faction_color`
## pushes it into `scrap_surface.gdshader` as an instance uniform and the shader
## does `albedo * tint * COLOR`, so the number below scales a shell that is
## already flesh, chitin, canvas or steel. That is why a faction colour is
## brighter than the swatch you would paint a flag with: at value 0.55 a body
## comes out a silhouette.
##
## Scavengers. Bone and canvas — they wear whatever the desert left them.
const FACTION_SCAV: Color = Color("b6ac96")
## The Foundry. Forge ember on soot. Everything they own has been welded twice.
const FACTION_FOUNDRY: Color = Color("c8451f")
## The Choir. Cold, and nothing about them is warm — but weathered zinc, not a
## sensor light.
##
## This was `#3fa8c8`, saturation 0.69, and it was the one thing on the field
## that did not belong in a sun-bleached ash desert. Measured off the rendered
## frame, the pixels it produced ran hue 175 at saturation 0.46 against a scene
## whose mean is 0.31 — a saturated teal, in a palette whose own cold entries
## (`SKY_FILL` 0.17, `SKY_ZENITH` 0.28) are all but grey.
##
## Saturation is now 0.40 and the hue has moved off pure cyan onto the slate blue
## those two sit at. Both numbers were arrived at by rendering and counting
## pixels, not by picking a swatch: because the tint MULTIPLIES a warm flesh and
## chitin shell, a cool tint cancels toward neutral rather than colouring, and
## the render is far less saturated than the swatch. At 0.24 the bodies came out
## at rgb(43,45,47) and saturation 0.09 — dark neutral, not cold. At 0.40 they
## land near saturation 0.22, which is BELOW the frame's own mean of 0.31, so
## they are the desaturated thing on the field rather than the loud one, and
## still unmistakably the cold side of it.
##
## The VALUE is deliberately held where it was: the tint multiplies, so darkening
## the swatch darkens every Choir body with it, and a faction you cannot pick out
## of the dust is a worse defect than a saturated one.
const FACTION_CHOIR: Color = Color("78adc8")

## Indexed to match `Factions.F`: SCAV, FOUNDRY, CHOIR.
const FACTION_COLORS: PackedColorArray = [FACTION_SCAV, FACTION_FOUNDRY, FACTION_CHOIR]

# --- material appearance ----------------------------------------------------

## Appearance of the eighteen shared materials: base colour, which branch of the
## scrap shader renders it, and its PBR constants. Mass, armour and penetration
## live with the systems that need them; this table is only about how it looks.
const MATERIALS: Dictionary = {
	&"steel": {"color": Color("4d4a44"), "surface": Surface.STEEL, "metal": 0.74, "rough": 0.50},
	&"ironox": {"color": Color("6b4a34"), "surface": Surface.STEEL, "metal": 0.55, "rough": 0.72},
	&"gunmet": {"color": Color("33353a"), "surface": Surface.STEEL, "metal": 0.80, "rough": 0.42},
	&"brass": {"color": Color("8a7238"), "surface": Surface.STEEL, "metal": 0.85, "rough": 0.38},
	&"alum": {"color": Color("7d8288"), "surface": Surface.STEEL, "metal": 0.78, "rough": 0.44},
	&"timber": {"color": Color("8a5a2b"), "surface": Surface.TIMBER, "metal": 0.04, "rough": 0.82},
	&"poly": {"color": Color("26282b"), "surface": Surface.POLYMER, "metal": 0.05, "rough": 0.78},
	&"rubber": {"color": Color("141517"), "surface": Surface.POLYMER, "metal": 0.03, "rough": 0.92},
	&"canvas": {"color": Color("6b6152"), "surface": Surface.CANVAS, "metal": 0.02, "rough": 0.95},
	&"hide": {"color": Color("4a3a2c"), "surface": Surface.CANVAS, "metal": 0.03, "rough": 0.80},
	&"flesh": {"color": Color("836158"), "surface": Surface.FLESH, "metal": 0.02, "rough": 0.62},
	&"pallid": {"color": Color("9b8d80"), "surface": Surface.FLESH, "metal": 0.02, "rough": 0.58},
	&"gut": {"color": Color("5d3a34"), "surface": Surface.FLESH, "metal": 0.02, "rough": 0.50},
	&"chitin": {"color": Color("3a352e"), "surface": Surface.CHITIN, "metal": 0.10, "rough": 0.38},
	&"bone": {"color": Color("b6ac96"), "surface": Surface.CHITIN, "metal": 0.03, "rough": 0.55},
	&"glow": {"color": Color("12140f"), "surface": Surface.POLYMER, "metal": 0.0, "rough": 0.40},
	&"glowc": {"color": Color("0f1416"), "surface": Surface.POLYMER, "metal": 0.0, "rough": 0.40},
	&"flash": {"color": Color("000000"), "surface": Surface.POLYMER, "metal": 0.0, "rough": 1.0},
}

## Emissive colour and energy for the three materials that light themselves.
const EMISSIVE: Dictionary = {
	&"glow": {"color": Color("c8451f"), "energy": 2.6},
	&"glowc": {"color": Color("3fa8c8"), "energy": 2.2},
	&"flash": {"color": Color("ffcf7a"), "energy": 5.0},
}

# --- the world --------------------------------------------------------------

## Sky and fog. `HAZE` is the fog colour; `SKY_GROUND` is what the sky dome fades
## to below the horizon, a half-stop under the haze so the far rim of the terrain
## never reads brighter than the air in front of it.
##
## These four are the sky dome's stops, and they are authored so that their LINEAR
## values are the ones the sky shader wants — `build_art.gd` calls
## `srgb_to_linear()` on the way in. Read as sRGB swatches they look darker than
## the rendered sky, which is correct: ACES lifts them by roughly a stop.
const HAZE: Color = Color("b49a78")
const SKY_ZENITH: Color = Color("63748a")
const SKY_MID: Color = Color("9a9da2")
const SKY_HORIZON: Color = Color("e4c8a3")
const SKY_GROUND: Color = Color("ae997f")
## Direct sun. Low, warm, and the reason every shadow in the game is long. Warmer
## than a noon sun because at sixteen degrees the beam has crossed four airmasses.
const SUN: Color = Color("ffe3bc")
## Ground bounce, coming back up out of the sand.
const BOUNCE: Color = Color("c79a68")
## Sky fill, the cold half of the light. Cold, not BLUE — measured on the arena
## pad, a #7d96c4 fill landed shadowed concrete at rgb(30,36,46), half again as
## much blue as red, and a saturated blue-violet shadow on warm sand reads as
## paint rather than as shade. Desaturated toward a cool neutral at the same
## luminance, which keeps a shadow separate in hue from its lit side — the whole
## job of this light — without tinting a third of every exterior frame periwinkle.
const SKY_FILL: Color = Color("93a0b0")

## Direction toward the sun, normalised. Late afternoon, behind the left shoulder
## on the default spawn heading: sixteen degrees of elevation, which is what makes
## a shadow 3.5 times the height of the thing casting it.
const SUN_DIRECTION: Vector3 = Vector3(-0.623623, 0.275634, -0.731519)

const TERRAIN_SAND_LOW: Color = Color("7f6a4e")
const TERRAIN_SAND_HIGH: Color = Color("b5a082")
const TERRAIN_ROCK_LOW: Color = Color("6c5b49")
const TERRAIN_ROCK_HIGH: Color = Color("998672")
const TERRAIN_GRAVEL: Color = Color("8a8071")

## Structure palettes, one array per surface family. The town generators pick
## from these and jitter each pick, which is why the same building never repeats.
const WORLD_SAND: PackedColorArray = [
	Color("9a8163"), Color("a88d6b"), Color("8d7458"), Color("b09a7a"), Color("877051")
]
const WORLD_ADOBE: PackedColorArray = [
	Color("9a8468"),
	Color("a89076"),
	Color("8b7357"),
	Color("b2997c"),
	Color("7e6a52"),
	Color("a2764c"),
	Color("6f6a60"),
	Color("8f8778"),
	Color("b6ac96"),
	Color("7d8378"),
	Color("94694a"),
	Color("6a5f4f"),
]
const WORLD_CONCRETE: PackedColorArray = [
	Color("6f6c66"), Color("7a7770"), Color("63605b"), Color("84817a")
]
const WORLD_RUST: PackedColorArray = [
	Color("6b4028"), Color("7a4a2c"), Color("5a3522"), Color("8a5230")
]
const WORLD_TIN: PackedColorArray = [Color("6a6560"), Color("776f66"), Color("5c574f")]
const WORLD_WOOD: PackedColorArray = [
	Color("6b4423"), Color("7a5230"), Color("5c3f26"), Color("8a5a2b")
]
const WORLD_METAL: PackedColorArray = [
	Color("4a4c50"), Color("3f4247"), Color("5a5049"), Color("43464a")
]
const WORLD_CLOTH: PackedColorArray = [
	Color("8f7a52"), Color("a03636"), Color("5f6448"), Color("9a7d4a"), Color("6a6d73")
]
const WORLD_ROCK: PackedColorArray = [
	Color("7d6a55"), Color("8b7862"), Color("6c5b49"), Color("94806a")
]
const WORLD_ASPHALT: PackedColorArray = [Color("3a3835"), Color("434140"), Color("312f2d")]

# --- readouts ---------------------------------------------------------------

## Diegetic screens and stencilled signage. Warm off-white on soot.
const INK: Color = Color("1c1a18")
const PAPER: Color = Color("cabfa8")
## The fade the scene router wipes through. Not quite black; nothing here is.
const VOID: Color = Color("090807")


## Tier colour by rank, clamped. Ranks beyond the table return Relic gold, which
## is the correct answer for anything that has run off the top of the scale.
static func tier_color(rank: int) -> Color:
	return TIER_COLORS[clampi(rank, 0, TIER_COLORS.size() - 1)]


## Faction colour by `Factions.F` value.
static func faction_color(faction: int) -> Color:
	return FACTION_COLORS[clampi(faction, 0, FACTION_COLORS.size() - 1)]


## Base colour of a named material, magenta if the name is not in the table so a
## mistyped material is impossible to miss.
static func material_color(key: StringName) -> Color:
	if not MATERIALS.has(key):
		push_error("Palette: no material named '%s'." % key)
		return Color.MAGENTA
	return MATERIALS[key]["color"]


## Which branch of the scrap shader renders a named material.
static func material_surface(key: StringName) -> int:
	if not MATERIALS.has(key):
		push_error("Palette: no material named '%s'." % key)
		return Surface.STEEL
	return MATERIALS[key]["surface"]
