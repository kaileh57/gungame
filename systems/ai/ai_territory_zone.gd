class_name AITerritoryZone
extends Node3D
## A claimed patch of ground: a vertical cylinder with an owner, an anchor to fall
## back to, and a ring of patrol stations around its edge.
##
## The zone node is the authoring surface; the ledger of who owns it and how hard
## everyone is leaning on it lives in `Factions.territory`, so ownership outlives
## the scene. The node registers its shape on `_ready`, mirrors the two ledger
## signals for whatever is watching this particular zone, and otherwise gets out
## of the way.

## This zone changed hands. `previous_owner` is `Factions.NEUTRAL_ID` when the
## ground was unclaimed.
signal owner_changed(previous_owner: int, new_owner: int)
## Two or more factions crossed the ledger's contest threshold here, or dropped
## back out of it.
signal contest_changed(is_contested: bool)

## Stable id. Two zones with the same id are the same zone as far as the ledger is
## concerned, so keep them unique per world.
@export var zone_id: StringName = &"zone"
## Which faction holds it at scene start, and its home faction from then on.
## `-2` leaves it unclaimed and homeless — ground nobody gets a last stand on.
@export_range(-2, 2, 1) var initial_owner: int = -2
## Cylinder radius, metres. Patrol stations sit inside this circle.
@export_range(4.0, 200.0, 0.5) var radius: float = 40.0
## Cylinder height, metres, centred on the node. Generous enough to cover a roof.
@export_range(2.0, 80.0, 0.5) var height: float = 24.0
## How badly a faction wants this one. Scales the capture margin, so a high-value
## zone is both worth taking and harder to take.
@export_range(0.1, 4.0, 0.05) var value: float = 1.0
## Number of patrol stations generated around the rim. A probing patrol walks
## these in order; a defending squad stands on the ones facing the threat.
@export_range(3, 16, 1) var patrol_stations: int = 6
## Fraction of `radius` the patrol ring sits at.
@export_range(0.3, 1.2, 0.01) var patrol_ring: float = 0.86
## Where a losing squad regroups, relative to the zone node. The middle of a zone
## is rarely the defensible part of it, so this is authored, not derived.
@export var anchor_offset: Vector3 = Vector3.ZERO
## Pressure per second one body standing inside contributes to its faction. The
## ledger's decay is per second too, so the two are directly comparable: at the
## defaults two bodies out-push the bleed on ground they do not already own.
##
## THIS IS NOT THE NUMBER THE FIREFIGHT USES, and the two are easy to confuse
## because they have the same name and the same default. `push` below is the
## direct route and nothing in the shipped demos calls it: a squad publishes its
## presence through `AIBlackboard.interest` and pays for it at
## `AIRoles.body_pressure_rate`, scaled by `FirefightDirector.pressure_scale`.
## Turning this one changes nothing you can see.
@export_range(0.001, 0.25, 0.001) var body_pressure_rate: float = 0.030


func _ready() -> void:
	var ledger: Factions.Territory = Factions.territory
	ledger.register_zone(zone_id, global_position, radius, height, initial_owner, value)
	ledger.owner_changed.connect(_on_ledger_owner_changed)
	ledger.contest_changed.connect(_on_ledger_contest_changed)


func _exit_tree() -> void:
	var ledger: Factions.Territory = Factions.territory
	ledger.owner_changed.disconnect(_on_ledger_owner_changed)
	ledger.contest_changed.disconnect(_on_ledger_contest_changed)
	ledger.unregister_zone(zone_id)


func owner_faction() -> int:
	return Factions.territory.zone_owner(zone_id)


func set_owner_faction(faction: int) -> void:
	Factions.territory.set_owner(zone_id, faction)


## True while two or more factions are present in force.
func is_contested() -> bool:
	return Factions.territory.is_contested(zone_id)


func pressure(faction: int) -> float:
	return Factions.territory.pressure(zone_id, faction)


## Contribute one tick of presence. `bodies` is how many of that faction's agents
## are standing inside; `delta` is how long they have been at it.
##
## The direct route, for a caller that has counted bodies itself. The demos do not
## use it — see `body_pressure_rate` — but it is the honest one-line way to push a
## zone from a level script, and it goes through the same `add_pressure` the
## squads do, so the garrison ceiling and the contest attrition apply to it too.
func push(faction: int, bodies: int, delta: float) -> void:
	if bodies <= 0:
		return
	var amount: float = body_pressure_rate * float(bodies) * delta
	Factions.territory.add_pressure(zone_id, faction, amount * Factions.expansion(faction))


func contains(p: Vector3) -> bool:
	var c: Vector3 = global_position
	if absf(p.y - c.y) > height * 0.5:
		return false
	var dx: float = p.x - c.x
	var dz: float = p.z - c.z
	return dx * dx + dz * dz <= radius * radius


## Signed distance to the rim on the XZ plane. Negative inside.
func rim_distance(p: Vector3) -> float:
	var c: Vector3 = global_position
	return Vector2(p.x - c.x, p.z - c.z).length() - radius


func anchor() -> Vector3:
	return global_position + anchor_offset


## Patrol station `i`, wrapping. Stations are evenly spaced and start on +Z so a
## zone's first station is always its north face regardless of node rotation.
func station(i: int) -> Vector3:
	var n: int = maxi(patrol_stations, 1)
	var a: float = float(posmod(i, n)) / float(n) * TAU
	var r: float = radius * patrol_ring
	return global_position + Vector3(sin(a) * r, 0.0, cos(a) * r)


## The station closest to `from`, which is the one a defender should man when the
## threat is coming from that direction.
func nearest_station(from: Vector3) -> Vector3:
	var n: int = maxi(patrol_stations, 1)
	var best: Vector3 = station(0)
	var best_d: float = best.distance_squared_to(from)
	for i: int in range(1, n):
		var s: Vector3 = station(i)
		var d: float = s.distance_squared_to(from)
		if d < best_d:
			best = s
			best_d = d
	return best


func _on_ledger_owner_changed(id: StringName, previous: int, current: int) -> void:
	if id == zone_id:
		owner_changed.emit(previous, current)


func _on_ledger_contest_changed(id: StringName, contested: bool) -> void:
	if id == zone_id:
		contest_changed.emit(contested)
