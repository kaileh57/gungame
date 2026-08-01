class_name PropContext
extends RefCounted
## The bundle every building and prop generator writes into.
##
## The reference keeps all of this in module-level globals — `W`, `COL`,
## `LADDERS`, `POIS`, `G.r`. One object instead, so a generator can be run
## against a scratch mesher to bake a standalone prop and against the town's
## mesher to place it in the world, with no code path difference between the two.
##
## `terrain` may be null. A null terrain is flat ground at `flat_ground`, which is
## exactly what `res://tools/build_props.gd` wants when it bakes a canonical
## instance of each prop at the origin.

var mesher: WorldMesher
var colliders: WorldColliderSet
var layout: WorldLayoutData
var rng: XorShift32
var noise: WorldNoise
var tuning: PropTuning
var terrain: WorldTerrainData
## Ground height used when `terrain` is null.
var flat_ground: float = 0.0


func _init(
	p_mesher: WorldMesher,
	p_rng: XorShift32,
	p_colliders: WorldColliderSet = null,
	p_layout: WorldLayoutData = null,
	p_terrain: WorldTerrainData = null,
	p_noise: WorldNoise = null,
	p_tuning: PropTuning = null
) -> void:
	mesher = p_mesher
	rng = p_rng
	colliders = p_colliders if p_colliders != null else WorldColliderSet.new()
	layout = p_layout if p_layout != null else WorldLayoutData.new()
	terrain = p_terrain
	noise = p_noise if p_noise != null else WorldNoise.new(0)
	tuning = p_tuning if p_tuning != null else PropTuning.new()


func ground_h(x: float, z: float) -> float:
	if terrain == null:
		return flat_ground
	return terrain.ground_h(x, z)


## Ground normal at a point. Flat ground is level ground.
func ground_normal(x: float, z: float) -> Vector3:
	if terrain == null:
		return Vector3.UP
	return terrain.ground_normal(x, z)


## Local (lx, lz) in a frame yawed by `ry` about (ox, oz), in world XZ. This is
## the reference's `L`, and it is `Basis(Vector3.UP, ry)` restricted to the plane.
static func local(ox: float, oz: float, ry: float, lx: float, lz: float) -> Vector2:
	var co: float = cos(ry)
	var si: float = sin(ry)
	return Vector2(ox + lx * co + lz * si, oz - lx * si + lz * co)


## The four corners of a yawed footprint, anticlockwise from (-hw, -hd). Walls,
## ladders and awnings all index this, so the order is part of the contract:
## side `s` runs from corner `s` to corner `(s + 1) % 4`, and its outward normal
## is `wall_normal(cor[s], cor[s + 1])`.
static func corners(ox: float, oz: float, ry: float, hw: float, hd: float) -> PackedVector2Array:
	return PackedVector2Array(
		[
			local(ox, oz, ry, -hw, -hd),
			local(ox, oz, ry, hw, -hd),
			local(ox, oz, ry, hw, hd),
			local(ox, oz, ry, -hw, hd),
		]
	)


## Outward normal angle of the wall running from `a` to `b`.
static func wall_normal(a: Vector2, b: Vector2) -> float:
	return atan2(-(b.y - a.y), b.x - a.x) + PI * 0.5


## Geometry plus a collider — anything the player can walk into or stand on.
## `surf` defaults to the visual type, as in the reference.
func solid(
	center: Vector3, half: Vector3, ry: float, col: Color, type: int, surf: int = -1
) -> void:
	mesher.box(center, half, ry, col, type)
	colliders.add_box(center, half, ry, type if surf < 0 else surf)


## Geometry only. Trim, rails, branches, antennae — things you should never snag
## a sprint on.
func deco(center: Vector3, half: Vector3, ry: float, col: Color, type: int) -> void:
	mesher.box(center, half, ry, col, type)


## A collider with no geometry of its own, for the round props whose visual is a
## cylinder but whose collision is a box.
func add_col(center: Vector3, half: Vector3, ry: float, surf: int) -> void:
	colliders.add_box(center, half, ry, surf)
