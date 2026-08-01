class_name PropTuning
extends Resource
## The knobs on the town's buildings and clutter that are safe to turn.
##
## Nothing here is an rng draw, so nothing here re-rolls the town: every value
## below changes the shape of a thing that has already been decided, never the
## decision. The proportions the reference fixes by hand — wall thickness, storey
## height ranges, hole widths — stay as constants in the generators, because
## moving them would drift the layout away from the transcribed spec.
##
## The three `fix_*` flags select between the reference's behaviour and the
## corrected one. They default to corrected. The reference's versions are kept
## reachable so a side-by-side is one checkbox away, not a code edit.

## How far abutting solids are pushed into each other. Two boxes that merely
## touch share a plane, and a shared plane is a z-fighting seam that opens into a
## visible slit the moment the camera moves. Everything joins wet.
@export_range(0.0, 0.05, 0.0005) var joint_overlap: float = 0.006

## Thickness given to corrugated roof sheets. The reference draws them as
## single-sided planes; under backface culling that is a roof you fall through
## and cannot see from below.
@export_range(0.01, 0.30, 0.005) var corrugated_thickness: float = 0.06

## Vertical rung pitch on a ladder, metres.
@export_range(0.18, 0.45, 0.01) var ladder_rung_pitch: float = 0.30
## Half the distance between the two stiles.
@export_range(0.15, 0.45, 0.01) var ladder_stile_half: float = 0.26

## Target riser on generated stairs. Must stay well under the player's step
## height (0.58 m) or the flight is climbed rather than walked.
@export_range(0.12, 0.40, 0.005) var stair_riser: float = 0.235

## Sides on the round props. These are the whole polygon budget of the clutter
## pass, so they are the first thing to drop on a weak machine.
@export_range(5, 24, 1) var barrel_segments: int = 10
@export_range(6, 32, 1) var tank_segments: int = 12
@export_range(6, 24, 1) var tyre_segments: int = 12
@export_range(4, 16, 1) var post_segments: int = 5
@export_range(4, 16, 1) var trunk_segments: int = 6

## Catenary depth of a power-line span at mid-point, metres, and how many struts
## approximate it.
@export_range(0.0, 4.0, 0.05) var wire_sag: float = 1.4
@export_range(2, 24, 1) var wire_segments: int = 7
## Half the world-X separation of the two conductors.
@export_range(0.05, 1.5, 0.01) var wire_half_spacing: float = 0.26
## Conductor half-thickness.
@export_range(0.005, 0.10, 0.001) var wire_radius: float = 0.022

## Draw tipped drums and truck wheels on the axis their collider actually uses.
## With this off they render upright inside a collider lying on its side, which
## is what the reference ships.
@export var fix_lying_cylinders: bool = true
## Lift the warehouse gable roof by the building's ground height. The reference
## builds the roof at absolute Y and the walls relative to the ground, so on a
## slope the roof floats free of the building.
@export var fix_warehouse_roof_base: bool = true
## Hang each power-line span between the two crossarms it actually connects. The
## reference holds one constant Y derived from a mix of both poles, which leaves
## one end in mid-air whenever the ground moves.
@export var fix_wire_endpoints: bool = true
