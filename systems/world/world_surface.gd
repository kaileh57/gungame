class_name WorldSurface
extends RefCounted
## The nine world surface ids, exactly as the reference numbers them.
##
## One integer does three jobs at once: it is the per-vertex `CUSTOM0.x` attribute
## that picks the branch in `res://art/world_material.gdshader`, it is the `surf`
## field on every baked collider, and it is the key the footstep and impact synths
## look up. Renumber it and all three break silently, so it does not get renumbered.

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
}

const COUNT: int = 9

const NAMES: PackedStringArray = [
	"metal", "wood", "poly", "sand", "concrete", "tin", "cloth", "asphalt", "rock"
]

## How loud a footstep on this surface is, relative to concrete. Sand swallows a
## boot; corrugated tin announces you to the whole street.
const FOOTSTEP_GAIN: PackedFloat32Array = [1.0, 0.85, 0.7, 0.45, 0.8, 1.25, 0.3, 0.75, 0.7]


static func name_of(kind: int) -> String:
	if kind < 0 or kind >= COUNT:
		return "sand"
	return NAMES[kind]


static func from_name(surface_name: String) -> int:
	var i: int = NAMES.find(surface_name)
	if i < 0:
		return Kind.SAND
	return i


## True for the surfaces a bullet should spark off rather than puff dust from.
static func is_hard(kind: int) -> bool:
	return kind == Kind.METAL or kind == Kind.TIN or kind == Kind.ROCK
