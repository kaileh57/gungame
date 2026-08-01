class_name VFXSurface
extends RefCounted
## What a hit looks like, keyed by what was hit.
##
## Ids 0-8 are byte-identical to the world's own surface table
## (`['metal','wood','poly','sand','concrete','tin','cloth','asphalt','rock']`,
## world spec 7), so a terrain or building raycast hands its surface id straight
## to `VFX.spawn_impact` with nothing in between. Ids 9-16 are the range targets
## and the creature materials, which the world table has no opinion about.
##
## The numbers for sand, metal, rock, wood, steel plate, barrel, bottle and paper
## are the reference's own (range spec 13.2, 16.1, 16.3). The rest are keyed off
## those: same families, retinted for the surface, and never louder or
## longer-lived than the reference's most violent case.

enum Kind {
	METAL = 0,
	WOOD = 1,
	POLY = 2,
	SAND = 3,
	CONCRETE = 4,
	TIN = 5,
	CLOTH = 6,
	ASPHALT = 7,
	ROCK = 8,
	PLATE = 9,
	GLASS = 10,
	PAPER = 11,
	BARREL = 12,
	FLESH = 13,
	CHITIN = 14,
	BONE = 15,
	OIL = 16,
}

const COUNT: int = 17

const NAMES: PackedStringArray = [
	"metal",
	"wood",
	"poly",
	"sand",
	"concrete",
	"tin",
	"cloth",
	"asphalt",
	"rock",
	"plate",
	"glass",
	"paper",
	"barrel",
	"flesh",
	"chitin",
	"bone",
	"oil",
]

## Every name any other system might hand us, folded onto a Kind. Covers the
## world's nine surface ids, the range's `userData.mat` values, the bestiary's
## eighteen material keys and the range's target kinds.
const ALIASES: Dictionary = {
	&"metal": Kind.METAL,
	&"steel": Kind.METAL,
	&"ironox": Kind.METAL,
	&"gunmet": Kind.METAL,
	&"brass": Kind.METAL,
	&"alum": Kind.METAL,
	&"wood": Kind.WOOD,
	&"timber": Kind.WOOD,
	&"poly": Kind.POLY,
	&"rubber": Kind.POLY,
	&"glow": Kind.POLY,
	&"glowc": Kind.POLY,
	&"flash": Kind.POLY,
	&"sand": Kind.SAND,
	&"dirt": Kind.SAND,
	&"concrete": Kind.CONCRETE,
	&"tin": Kind.TIN,
	&"cloth": Kind.CLOTH,
	&"canvas": Kind.CLOTH,
	&"hide": Kind.CLOTH,
	&"asphalt": Kind.ASPHALT,
	&"rock": Kind.ROCK,
	&"stone": Kind.ROCK,
	&"plate": Kind.PLATE,
	&"popper": Kind.PLATE,
	&"mover": Kind.PLATE,
	&"glass": Kind.GLASS,
	&"bottle": Kind.GLASS,
	&"paper": Kind.PAPER,
	&"barrel": Kind.BARREL,
	&"flesh": Kind.FLESH,
	&"pallid": Kind.FLESH,
	&"gut": Kind.FLESH,
	&"chitin": Kind.CHITIN,
	&"bone": Kind.BONE,
	&"oil": Kind.OIL,
}

## Particles per hit at intensity 1. Paper takes none - the reference punches a
## hole in it and nothing else.
const SPARK_COUNT: PackedInt32Array = [5, 6, 4, 9, 7, 6, 3, 6, 5, 11, 18, 0, 6, 10, 8, 9, 9]
## Base ejection speed, m/s, before the reference's 0.35..1.35 per-particle roll.
const SPARK_SPEED: PackedFloat32Array = [
	3.2, 2.4, 2.0, 2.2, 2.8, 3.4, 1.4, 2.4, 3.2, 3.0, 3.6, 0.0, 2.6, 2.4, 3.0, 3.2, 2.2
]
## Base lifetime, s, before the reference's 0.6..1.4 per-particle roll.
const SPARK_LIFE: PackedFloat32Array = [
	0.70,
	0.55,
	0.45,
	0.70,
	0.60,
	0.60,
	0.40,
	0.60,
	0.70,
	0.55,
	0.90,
	0.0,
	0.50,
	0.45,
	0.50,
	0.55,
	0.55
]
## Multiplier on the 11 m/s^2 particle gravity. Wet matter falls harder.
const SPARK_GRAVITY: PackedFloat32Array = [
	1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.3, 1.0, 1.0, 1.2
]
const SPARK_COLOR: PackedColorArray = [
	Color(0.85, 0.80, 0.65),
	Color(0.74, 0.55, 0.32),
	Color(0.70, 0.68, 0.62),
	Color(0.45, 0.38, 0.27),
	Color(0.72, 0.68, 0.60),
	Color(0.88, 0.84, 0.70),
	Color(0.55, 0.50, 0.42),
	Color(0.60, 0.57, 0.52),
	Color(0.85, 0.80, 0.65),
	Color(1.00, 0.82, 0.45),
	Color(0.50, 0.90, 0.62),
	Color(0.00, 0.00, 0.00),
	Color(1.00, 0.70, 0.35),
	Color(0.42, 0.13, 0.10),
	Color(0.36, 0.33, 0.28),
	Color(0.82, 0.78, 0.66),
	Color(0.10, 0.09, 0.09),
]
## 1 where the debris is fluid and belongs in the alpha-blended spray field
## instead of the additive spark field. Blood does not glow.
const SPARK_WET: PackedInt32Array = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 1]

## Dust sprites kicked up on top of the sparks. Zero for anything that does not
## powder when a bullet goes through it.
const DUST_COUNT: PackedInt32Array = [0, 2, 1, 4, 5, 0, 2, 4, 4, 0, 0, 0, 1, 0, 0, 1, 0]
const DUST_SPREAD: PackedFloat32Array = [
	0.0, 0.16, 0.12, 0.30, 0.26, 0.0, 0.14, 0.24, 0.22, 0.0, 0.0, 0.0, 0.20, 0.0, 0.0, 0.10, 0.0
]
const DUST_DARK: PackedFloat32Array = [
	0.0, 0.30, 0.26, 0.34, 0.30, 0.0, 0.22, 0.38, 0.30, 0.0, 0.0, 0.0, 0.40, 0.0, 0.0, 0.24, 0.0
]
## Birth colour of the dust. Alpha 0 means "use the smoke field's own haze".
const DUST_TINT: PackedColorArray = [
	Color(0, 0, 0, 0),
	Color(0.55, 0.45, 0.32, 1),
	Color(0.42, 0.42, 0.42, 1),
	Color(0.66, 0.57, 0.42, 1),
	Color(0.72, 0.70, 0.66, 1),
	Color(0, 0, 0, 0),
	Color(0.55, 0.51, 0.44, 1),
	Color(0.40, 0.39, 0.37, 1),
	Color(0.62, 0.56, 0.47, 1),
	Color(0, 0, 0, 0),
	Color(0, 0, 0, 0),
	Color(0, 0, 0, 0),
	Color(0.24, 0.22, 0.20, 1),
	Color(0, 0, 0, 0),
	Color(0, 0, 0, 0),
	Color(0.78, 0.74, 0.64, 1),
	Color(0, 0, 0, 0),
]
const DUST_LIFE: float = 0.85
const DUST_RISE: float = 0.35

## Decal diameter in metres. Zero means the surface takes no hole: a bottle
## shatters instead.
const DECAL_SIZE: PackedFloat32Array = [
	0.055,
	0.055,
	0.050,
	0.055,
	0.060,
	0.050,
	0.045,
	0.058,
	0.055,
	0.050,
	0.0,
	0.050,
	0.070,
	0.055,
	0.050,
	0.050,
	0.060
]
## 1 where the hole is fresh spall rather than a hole - bare steel only.
const DECAL_HOT: PackedInt32Array = [0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0]


## Fold any surface name the rest of the project uses onto a Kind. Unknown names
## resolve to METAL, which is the least wrong answer for scrap.
static func from_key(key: StringName) -> int:
	return int(ALIASES.get(key, Kind.METAL))


static func kind_name(kind: int) -> String:
	return NAMES[clampi(kind, 0, COUNT - 1)]


## Clamp anything handed in from outside into a usable index.
static func valid(kind: int) -> int:
	return clampi(kind, 0, COUNT - 1)
