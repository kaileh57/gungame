class_name GunSpec
extends Resource
## A rolled weapon: which five parts, how they were fitted, and every number the
## geometry implies. Produced by `GunFactory.roll()`, consumed by the viewmodel,
## the ballistics solver, the HUD and the weapon bench.
##
## Nothing here is invented. The reference derives real stats from the assembled
## geometry — receiver length becomes case length, the barrel's thinnest section
## becomes bore, case volume becomes powder, powder plus barrel length becomes
## muzzle energy — and this resource is the record of that derivation.
##
## Units: lengths in millimetres unless the field says otherwise, angles in MOA
## unless the field says radians, energy in joules, mass in kilograms.

## Seed passed to the roll. Decides only which parts were picked.
@export var roll_seed: int = 0
## Deterministic hash of the five part indices. Everything cosmetic and every
## per-weapon random constant keys off this, not off `roll_seed`, so the same
## five parts always produce the same name, recoil pattern and tint.
@export var cfg: int = 0
@export var weapon_name: String = ""

@export_group("Assembly")
## Part indices in fixed order: receiver, barrel, stock, grip, and the sight if
## one was fitted. Index into `PartLibrary.parts()`.
@export var part_indices: PackedInt32Array = PackedInt32Array()
## Uniform XY scale applied to each part, index-aligned with `part_indices`.
@export var part_scales: PackedFloat32Array = PackedFloat32Array()
## Extra Z-only multiplier per part, closing most of the width mismatch.
@export var part_z_scales: PackedFloat32Array = PackedFloat32Array()
## Local offset per part, in receiver-local model units.
@export var part_offsets: PackedVector3Array = PackedVector3Array()
## Summed absolute log-mismatch across every fitted joint. Poisons reliability,
## spread and reload time; zero only when every cut face matched its socket.
@export var fit_error: float = 0.0
## Muzzle position in receiver-local model units, where tracers and flash spawn.
@export var muzzle_local: Vector3 = Vector3.ZERO

@export_group("Grading")
@export var score: float = 0.0
@export var tier_index: int = 1
@export var tier_name: StringName = &"Scrap"
@export var tier_color: Color = Color.WHITE
## Emergent traits, read off the finished numbers rather than rolled.
@export var quirks: PackedStringArray = PackedStringArray()

@export_group("Cartridge")
## Matched cartridge name, or "<bore>x<len> wildcat" when nothing fits.
@export var caliber: String = ""
@export var bore: float = 0.0
@export var case_length: int = 0
@export var pellets: int = 1
@export var explosive: bool = false
@export var blast_radius: float = 0.0

@export_group("Ballistics")
@export var muzzle_velocity: int = 0
@export var muzzle_energy: int = 0
## Effective range in metres, past which damage falls off hard.
@export var effective_range: int = 0
## Velocity the projectile simulation integrates with, m/s.
@export var sim_velocity: int = 0
@export var damage: float = 0.0
@export var crit_multiplier: float = 1.0
## Metres inside which a head hit still counts as a head hit. Zero when explosive.
@export var headshot_range: float = 0.0
## Recoil impulse, newton-seconds. Drives the recoil springs and the audio voice.
@export var impulse: float = 0.0

@export_group("Action")
@export var fire_mode: StringName = &"semi"
@export var feed: StringName = &"box"
@export var archetype: StringName = &""
@export var rpm: int = 0
## Mechanical cycle rate, before the trigger and the shooter get in the way.
@export var cyclic: int = 0
@export var magazine: int = 0
@export var reload_time: float = 0.0
@export var automatic: bool = false
## True when the action cannot stop itself — it fires until the magazine is dry.
@export var runaway: bool = false
@export var sidearm: bool = false

@export_group("Handling")
## Kilograms. Derived from hull volume and donor material density.
@export var mass: float = 0.0
@export var precision: int = 0
@export var reach: int = 0
@export var kick: int = 0
@export var handling: int = 0
## 0-100. Below 14 the tier is clamped to Hazard or Field-Grade, below 30 to
## Gunsmithed — a gun that eats itself is never a prize.
@export var reliability: int = 0
@export var burst_dps: int = 0
@export var sustained_dps: int = 0
@export var barrel_length: int = 0
@export var overall_length: int = 0

@export_group("Accuracy")
## Cone half-angle in MOA.
@export var spread: float = 0.0
## Same cone in radians. 1 MOA = 0.000290888 rad exactly, as the reference has it.
@export var spread_rad: float = 0.0
## Preformatted cone for the stat card: minutes below 60, degrees above.
@export var spread_text: String = ""

@export_group("Optics")
@export var has_optic: bool = false
## True only for a real scope: gates the circular scope render over the lean-in FOV.
@export var scoped: bool = false
@export var zoom: float = 1.0
## Magnification ladder the optic can cycle through. Never empty on a rolled gun;
## a bench reroll that skips `fit_optics` leaves it empty and callers fall back
## to `[zoom]`.
@export var zoom_levels: PackedFloat32Array = PackedFloat32Array()

@export_group("Recoil")
## Radians of muzzle rise per shot.
@export var recoil_vertical: float = 0.0
## Radians of horizontal wander per shot.
@export var recoil_horizontal: float = 0.0
## -1..1 fixed bias direction. This weapon always walks the same way.
@export var recoil_drift: float = 0.0
## Shots per horizontal cycle, 4..13.
@export var recoil_period: int = 4
## Random spice on top of the pattern, scaled by unreliability.
@export var recoil_random: float = 0.0
## Seconds-scale settle rate back to centre.
@export var recoil_settle: float = 0.0

@export_group("Presentation")
## Whole-weapon albedo multiplier, 0.86..1.14. One tint for every part.
@export var tint: float = 1.0
## Donor families present in the assembly, in `part_indices` order, deduplicated.
@export var donor_groups: Array[StringName] = []


## How many parts this weapon is built from: 4 without a sight, 5 with.
func part_count() -> int:
	return part_indices.size()


## Local transform for fitted part `i`, ready to hand to a MeshInstance3D.
func part_transform(i: int) -> Transform3D:
	var k: float = part_scales[i]
	var kz: float = part_z_scales[i]
	return Transform3D(Basis().scaled(Vector3(k, k, k * kz)), part_offsets[i])


## Index of the receiver, which is always first and never scaled.
func receiver_index() -> int:
	return part_indices[0]


func barrel_index() -> int:
	return part_indices[1]


func stock_index() -> int:
	return part_indices[2]


func grip_index() -> int:
	return part_indices[3]


## Sight part index, or -1 when the gun has iron sights only.
func sight_index() -> int:
	if part_indices.size() < 5:
		return -1
	return part_indices[4]


## The magnification ladder, with the reference's fallback for bench rerolls that
## never went through the optics fit.
func zoom_ladder() -> PackedFloat32Array:
	if zoom_levels.is_empty():
		return PackedFloat32Array([zoom])
	return zoom_levels
