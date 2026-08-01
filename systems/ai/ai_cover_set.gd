class_name AICoverSet
extends Resource
## A baked field of cover points.
##
## Structure-of-arrays, pre-sorted into a flat uniform grid so the runtime index
## is a Dictionary of cell key to slice start and nothing else has to be built on
## load. A 200 m town bakes to a few thousand points; sorting them at bake time
## costs nothing and saves every cover query from scanning the whole set.
##
## Each point stores two eight-sector masks: which compass sectors are blocked at
## crouch height and which at standing height. That is the whole model, and it is
## enough to tell the three cases apart — blocked low and open high is a firing
## position you can shoot over, blocked at both is a place to reload, and open low
## is not cover at all and never gets baked.
##
## The `vantage_*` arrays are a second, much smaller field baked alongside it and
## answering a different question. Cover is local — what is within a metre and a
## quarter of me. A vantage point is measured against the whole level: how much
## of the navigable ground it overlooks, from how high, through what arc, and
## whether a body can actually be routed to it. There are a few dozen of them
## against a few hundred cover points, so the runtime scan over them is linear
## and needs no grid. `AIVantage` owns both the baking and the choosing; this
## resource only stores what came out.

## Number of compass sectors in the protection masks. Eight is the smallest count
## that distinguishes a corner from a wall.
const SECTORS: int = 8

@export var cell_size: float = 4.0
@export var positions: PackedVector3Array = PackedVector3Array()
## Unit vector pointing from the obstruction toward open ground: the direction an
## agent faces when it is using this point properly.
@export var normals: PackedVector3Array = PackedVector3Array()
## Bits 0-7: sectors blocked at crouch height. Bits 8-15: blocked standing.
@export var masks: PackedInt32Array = PackedInt32Array()
## 0-1. How much of the compass this point covers, weighted toward points you can
## still shoot from.
@export var quality: PackedFloat32Array = PackedFloat32Array()
## Sorted, unique grid cell keys. Parallel to `cell_starts`.
@export var cell_keys: PackedInt32Array = PackedInt32Array()
## Index into `positions` where each cell's run begins. One longer than
## `cell_keys`; the extra entry is the total count.
@export var cell_starts: PackedInt32Array = PackedInt32Array()

@export_group("Vantage")
## Overwatch positions, best first. A few dozen; scanned linearly at runtime.
@export var vantage_positions: PackedVector3Array = PackedVector3Array()
## Unit, flat. Mean bearing of the ground each point overlooks.
@export var vantage_facing: PackedVector3Array = PackedVector3Array()
## Cosine of the half-angle about `vantage_facing` holding four fifths of that
## ground. A contact outside it is not overlooked from here.
@export var vantage_arc_cos: PackedFloat32Array = PackedFloat32Array()
## Metres. The eightieth-percentile distance to the ground the point can see —
## how far its command of the level actually extends.
@export var vantage_reach: PackedFloat32Array = PackedFloat32Array()
## 0-1 bake quality: elevation, coverage and a parapet, less exposure.
@export var vantage_score: PackedFloat32Array = PackedFloat32Array()
## Metres above the level's median navigable height.
@export var vantage_elevation: PackedFloat32Array = PackedFloat32Array()
## 0-1. One is standing at full height with nothing in any direction.
@export var vantage_exposure: PackedFloat32Array = PackedFloat32Array()
## Crouch and standing sector masks, packed exactly as `masks`.
@export var vantage_masks: PackedInt32Array = PackedInt32Array()


## Grid key for a world position. Packs two 16-bit cell coordinates, which covers
## a 262 km square at the default cell size — comfortably more world than exists.
static func key_for(p: Vector3, size: float) -> int:
	var xi: int = clampi(int(floor(p.x / size)) + 32768, 0, 65535)
	var zi: int = clampi(int(floor(p.z / size)) + 32768, 0, 65535)
	return xi * 65536 + zi


static func key_from_cell(xi: int, zi: int) -> int:
	return clampi(xi + 32768, 0, 65535) * 65536 + clampi(zi + 32768, 0, 65535)


## Compass sector a horizontal direction falls in. Sector 0 straddles +Z.
static func sector_of(dir: Vector3) -> int:
	var a: float = atan2(dir.x, dir.z) + TAU / float(SECTORS) * 0.5
	return posmod(int(floor(a / TAU * float(SECTORS))), SECTORS)


static func sector_direction(k: int) -> Vector3:
	var a: float = float(k) / float(SECTORS) * TAU
	return Vector3(sin(a), 0.0, cos(a))


func size() -> int:
	return positions.size()


func low_mask(i: int) -> int:
	return masks[i] & 0xFF


func high_mask(i: int) -> int:
	return (masks[i] >> 8) & 0xFF


## Protection against a threat lying in direction `to_threat` from the point.
## 0 none, 1 crouch cover you can fire over, 2 full standing cover.
func protection(i: int, to_threat: Vector3) -> int:
	return _protect(masks, i, to_threat)


func vantage_count() -> int:
	return vantage_positions.size()


## Same three-way answer as `protection`, against the vantage field. A rooftop
## with a parapet answers 1 and is a firing position; a bare slab answers 0 and
## is somewhere to be shot at from below.
func vantage_protection(i: int, to_threat: Vector3) -> int:
	return _protect(vantage_masks, i, to_threat)


## Store the vantage field. Takes the dictionary `AIVantage.bake` returns so the
## sampler does not have to know the layout of eight parallel arrays.
func set_vantage(packed: Dictionary) -> void:
	vantage_positions = packed["positions"]
	vantage_facing = packed["facing"]
	vantage_arc_cos = packed["arc_cos"]
	vantage_reach = packed["reach"]
	vantage_score = packed["score"]
	vantage_elevation = packed["elevation"]
	vantage_exposure = packed["exposure"]
	vantage_masks = packed["masks"]


static func _protect(bits: PackedInt32Array, i: int, to_threat: Vector3) -> int:
	if i < 0 or i >= bits.size():
		return 0
	var bit: int = 1 << sector_of(to_threat)
	if (bits[i] & bit) == 0:
		return 0
	return 2 if ((bits[i] >> 8) & bit) != 0 else 1
