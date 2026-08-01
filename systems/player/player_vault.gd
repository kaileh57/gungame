class_name PlayerVault
extends Resource
## The decision that separates "climb onto that" from "hurdle that".
##
## `PlayerMantle` finds a ledge in front of you and, on its own, always puts you on top
## of it. That is right for a container or a roof and wrong for a waist-high rail, a low
## wall or a windowsill, where stopping on the lip throws away every metre per second you
## brought and reads as a stumble. This class looks past the lip: if the solid ends
## within `max_depth` and the far side drops away, the target moves to just beyond the
## far edge and the exit speed is scaled up instead of down, so the run carries through.
##
## It only ever narrows an already-valid mantle, so a demo can switch the whole behaviour
## off with `enabled` and get the reference's motion back exactly.

## Distance stepped forward per probe while hunting for the far edge. Finer than this
## buys nothing: the landing is pushed clear of the edge anyway.
const SCAN_STEP: float = 0.11

## Turn the hurdle off and every ledge becomes a climb-on-top.
@export var enabled: bool = true
## Tallest obstacle you will hurdle rather than climb. Above waist height the move stops
## looking like a vault and the mantle arc is the honest answer.
@export_range(0.2, 2.0, 0.01) var max_rise: float = 1.24
## Shortest obstacle worth hurdling. Below this the step-up already handled it.
@export_range(0.1, 1.5, 0.01) var min_rise: float = 0.55
## Deepest obstacle you will hurdle. A wall thicker than this is a roof to stand on.
@export_range(0.2, 3.0, 0.01) var max_depth: float = 1.05
## Planar speed needed to commit to a hurdle. Walking up to a rail should climb it.
@export_range(0.0, 12.0, 0.05) var min_speed: float = 3.2
## How far the far edge must fall away before it counts as "the other side" rather than
## a chip in the top surface.
@export_range(0.05, 2.0, 0.01) var min_drop: float = 0.35
## How far past the far edge the landing is placed, so you clear the edge instead of
## landing balanced on it.
@export_range(0.05, 1.5, 0.01) var clear_past: float = 0.34
## Fraction of the carried speed you leave a hurdle with. Above the mantle's 0.62 on
## purpose — the whole point of the move is that momentum survives it.
@export_range(0.1, 1.5, 0.01) var exit_speed_scale: float = 0.94
## Floor on the exit speed, so a slow hurdle still puts you down clear of the obstacle.
@export_range(0.5, 10.0, 0.05) var min_exit_speed: float = 3.4
## Multiplies the arc duration. A hurdle covers more ground than a climb-on, and running
## it at the same duration reads as a teleport.
@export_range(0.5, 2.5, 0.01) var duration_scale: float = 1.18

## Landing point chosen by the last successful `plan_over`. Feet position, world space.
var landing: Vector3 = Vector3.ZERO
## Depth of the obstacle the last successful `plan_over` measured, metres.
var depth: float = 0.0


## Is the solid the mantle just found something to hurdle rather than climb? On true,
## `landing` and `depth` hold the answer.
##
## `lip` is the probe point that found the ledge — world x and z, with the surface height
## in y — and `lip_distance` is how far ahead of the feet that was. The far-edge scan
## walks on from the lip, so the depth it measures is the obstacle's, not the approach's.
## `forward` is the unit heading in world XZ.
func plan_over(
	probe: PlayerProbe,
	feet: Vector3,
	forward: Vector2,
	lip: Vector3,
	lip_distance: float,
	speed: float,
	clear_height: float,
	clear_radius: float
) -> bool:
	if not enabled or speed < min_speed:
		return false
	var rise: float = lip.y - feet.y
	if rise < min_rise or rise > max_rise:
		return false
	var far: float = _far_edge(probe, lip, forward)
	if far < 0.0:
		return false
	# Land ABOVE the obstacle's top, past its far edge, and fall from there. Nothing on
	# the arc is ever below the surface it is crossing, so the hurdle cannot clip.
	var land := Vector3(
		lip.x + forward.x * (far + clear_past), lip.y + 0.02, lip.z + forward.y * (far + clear_past)
	)
	if not probe.can_stand(land, clear_height, clear_radius):
		return false
	landing = land
	depth = lip_distance + far
	return true


## Forward speed to leave a hurdle with, given the speed carried into it.
func exit_speed(carried: float) -> float:
	return maxf(min_exit_speed, carried * exit_speed_scale)


## Distance from the lip probe to the far edge of the obstacle, or -1.0 when the solid
## runs on past `max_depth` or never drops far enough to be an edge.
func _far_edge(probe: PlayerProbe, lip: Vector3, forward: Vector2) -> float:
	var travelled: float = SCAN_STEP
	while travelled <= max_depth:
		var here: float = probe.top_at(
			lip.x + forward.x * travelled,
			lip.z + forward.y * travelled,
			lip.y - min_drop,
			lip.y + 0.05
		)
		if is_nan(here):
			return travelled
		travelled += SCAN_STEP
	return -1.0
