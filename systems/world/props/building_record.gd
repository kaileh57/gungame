class_name BuildingRecord
extends RefCounted
## What a building generator hands back: enough to bridge two roofs, drop an
## extraction pad on one, or spawn a patrol inside without re-deriving anything.
##
## The reference returns an anonymous object per generator with a different set
## of marker flags on each (`warehouse: true`, `ruin: true`, …). One record with
## a `kind` instead — the flags were only ever read as a type test.

var x: float = 0.0
var z: float = 0.0
## Footprint, full width and depth, before yaw.
var w: float = 0.0
var d: float = 0.0
var ry: float = 0.0
## Walkable top surface, world Y.
var roof_y: float = 0.0
## Ground height under the centre.
var base: float = 0.0
var kind: int = WorldLayoutData.Kind.HOUSE


func _init(
	p_x: float,
	p_z: float,
	p_w: float,
	p_d: float,
	p_ry: float,
	p_roof_y: float,
	p_base: float,
	p_kind: int
) -> void:
	x = p_x
	z = p_z
	w = p_w
	d = p_d
	ry = p_ry
	roof_y = p_roof_y
	base = p_base
	kind = p_kind


## Push this record into the baked layout so navigation and the exfil flow can
## find it. Containers deliberately never do this: they have no interior.
func publish(layout: WorldLayoutData) -> void:
	layout.add_building(x, z, w, d, ry, roof_y, base, kind)


## Has a flat deck you could stand a helicopter, a plank or an enemy on.
func has_deck() -> bool:
	return (
		kind != WorldLayoutData.Kind.RUIN
		and kind != WorldLayoutData.Kind.MARKET
		and kind != WorldLayoutData.Kind.TOWER
	)


## Eligible as the SOURCE end of a roof plank. A compound has a deck you can walk
## onto, but its perimeter wall is not somewhere to launch a bridge from.
func can_bridge_from() -> bool:
	return has_deck() and kind != WorldLayoutData.Kind.COMPOUND
