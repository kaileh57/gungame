class_name WorldLayoutData
extends Resource
## Everything about the town that is not geometry: streets, ladders, buildings,
## points of interest and extraction pads.
##
## The bake fills it; navigation, the compass, the exfil flow and any demo that
## wants to put something sensible somewhere all read it. Nothing here is
## regenerated at runtime.

enum Kind { HOUSE, WAREHOUSE, RUIN, TOWER, MARKET, COMPOUND, CONTAINERS }
enum PoiKind { POI, EXFIL }

## Climb-volume half-width along the ladder's local X, metres.
const LADDER_HALF_W: float = 0.78
## Climb-volume reach along the ladder's local +Z (it also reaches 0.45 back).
const LADDER_HALF_D: float = 0.95
## How far below `y0` the climb volume starts.
const LADDER_FOOT_DROP: float = 0.15
## Extraction pad trigger radius, and the radius of the painted ring.
const EXFIL_RADIUS: float = 4.6

@export var world_seed: int = 0

## Road centre lines: (x0, z0, x1, z1) per entry, widths alongside.
@export var road_lines: PackedVector4Array = PackedVector4Array()
@export var road_widths: PackedFloat32Array = PackedFloat32Array()

## Ladder foot, as (x, y0, z). The climb reaches up to `ladder_top`.
@export var ladder_origin: PackedVector3Array = PackedVector3Array()
@export var ladder_yaw: PackedFloat32Array = PackedFloat32Array()
@export var ladder_top: PackedFloat32Array = PackedFloat32Array()

## Building centre as (x, roof_y, z); footprint, yaw and ground height alongside.
@export var building_pos: PackedVector3Array = PackedVector3Array()
@export var building_size: PackedVector2Array = PackedVector2Array()
@export var building_yaw: PackedFloat32Array = PackedFloat32Array()
@export var building_base: PackedFloat32Array = PackedFloat32Array()
@export var building_kind: PackedByteArray = PackedByteArray()

## Named places. `poi_kind` separates ordinary landmarks from extraction pads.
@export var poi_pos: PackedVector3Array = PackedVector3Array()
@export var poi_name: PackedStringArray = PackedStringArray()
@export var poi_kind: PackedByteArray = PackedByteArray()

## Block rectangles the BSP settled on, as (x0, z0, x1, z1). Handy for spawning.
@export var blocks: PackedVector4Array = PackedVector4Array()


func add_road(x0: float, z0: float, x1: float, z1: float, w: float) -> void:
	road_lines.push_back(Vector4(x0, z0, x1, z1))
	road_widths.push_back(w)


func add_ladder(x: float, z: float, ry: float, y0: float, y1: float) -> void:
	ladder_origin.push_back(Vector3(x, y0, z))
	ladder_yaw.push_back(ry)
	ladder_top.push_back(y1)


func add_building(
	x: float, z: float, w: float, d: float, ry: float, roof_y: float, base: float, kind: int
) -> int:
	building_pos.push_back(Vector3(x, roof_y, z))
	building_size.push_back(Vector2(w, d))
	building_yaw.push_back(ry)
	building_base.push_back(base)
	building_kind.push_back(kind)
	return building_yaw.size() - 1


func add_poi(x: float, y: float, z: float, poi: String, kind: int) -> void:
	poi_pos.push_back(Vector3(x, y, z))
	poi_name.push_back(poi)
	poi_kind.push_back(kind)


func building_count() -> int:
	return building_yaw.size()


func ladder_count() -> int:
	return ladder_yaw.size()


## Distance from (x, z) to the nearest carriageway edge; negative inside a road.
## Linear in the number of roads — bake-time use only. At runtime read the baked
## road mask on `WorldTerrainData` instead.
func dist_to_road(x: float, z: float) -> float:
	var best: float = 1.0e9
	for i in road_lines.size():
		var rd: Vector4 = road_lines[i]
		var dx: float = rd.z - rd.x
		var dz: float = rd.w - rd.y
		var l2: float = dx * dx + dz * dz
		if l2 <= 0.0:
			l2 = 1.0
		var t: float = clampf(((x - rd.x) * dx + (z - rd.y) * dz) / l2, 0.0, 1.0)
		var px: float = rd.x + dx * t
		var pz: float = rd.y + dz * t
		var dd: float = sqrt((x - px) * (x - px) + (z - pz) * (z - pz)) - road_widths[i] * 0.5
		if dd < best:
			best = dd
	return best


## Road paint at a point: 1 on the carriageway, falling to 0 across the three
## metres from 0.4 m inside the kerb to 2.6 m outside it.
func road_at(x: float, z: float) -> float:
	return 1.0 - smoothstep(-0.4, 2.6, dist_to_road(x, z))


## The ladder whose climb volume contains `p`, or -1. Volumes are boxes in the
## ladder's own frame: +-0.78 across, -0.45 to +0.95 out, `y0 - 0.15` to `y1`.
func ladder_at(p: Vector3) -> int:
	for i in ladder_yaw.size():
		var o: Vector3 = ladder_origin[i]
		if p.y < o.y - LADDER_FOOT_DROP or p.y > ladder_top[i]:
			continue
		var co: float = cos(ladder_yaw[i])
		var si: float = sin(ladder_yaw[i])
		var dx: float = p.x - o.x
		var dz: float = p.z - o.z
		var lx: float = dx * co - dz * si
		var lz: float = dx * si + dz * co
		if absf(lx) <= LADDER_HALF_W and lz >= -0.45 and lz <= LADDER_HALF_D:
			return i
	return -1


## Nearest named place to a point, or -1 when there are none.
func nearest_poi(x: float, z: float, kind: int = -1) -> int:
	var best: int = -1
	var best_d: float = INF
	for i in poi_name.size():
		if kind >= 0 and poi_kind[i] != kind:
			continue
		var p: Vector3 = poi_pos[i]
		var d: float = (x - p.x) * (x - p.x) + (z - p.z) * (z - p.z)
		if d < best_d:
			best_d = d
			best = i
	return best
