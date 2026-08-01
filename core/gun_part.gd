class_name GunPart
extends Resource
## One of the 95 scavenged gun parts, as baked by `res://tools/build_parts.gd`.
##
## The fields mirror the reference's embedded `partdata` block one for one; the
## only additions are `mesh_path` (the repaired ArrayMesh this part renders as)
## and `boundary_edges` (how many open edges survived the bake — must be 0).
##
## All lengths are in model units. 1 unit = 90 mm = 0.09 m; a gun instanced into
## world space is scaled by 0.09. Local origin conventions, implied by the
## dequantisation constants and confirmed by reconstruction:
##   receiver — centred on X, y = 0 is the bore line
##   barrel   — origin at the breech face, extends toward +X
##   stock    — origin at the front mating face, extends toward -X
##   grip     — hangs down, y in [-ext.y, 0]
##   sight    — centred on X, sits above y = 0

## Kind of part: `barrel`, `stock`, `grip`, `receiver` or `sight`.
@export var kind: StringName = &""
## Donor family, one of the 20 names used verbatim by the naming tables.
@export var donor_group: StringName = &""
## Donor class: rifle, smg, shotgun, pistol, sniper, revolver, lmg or launcher.
@export var weapon_class: StringName = &""

## Index into the flat 95-element part array. This is the part's identity: the
## per-weapon config hash is built from these five numbers and nothing else.
@export var index: int = -1

## Axis-aligned bounding box size, model units.
@export var ext: Vector3 = Vector3.ZERO
## Convex-hull volume, model units cubed. Drives mass, powder charge and bolt weight.
@export var hull_volume: float = 0.0

## Height of this part's mating cut face. Zero on part 70, which is the reference's
## own hazard case and must survive the port as a hazard, not as a divide by zero.
@export var fit_height: float = 0.0
## Width of this part's mating cut face.
@export var fit_width: float = 0.0
## Barrels only: muzzle-end radius proxy that drives bore. -1.0 on every other kind.
@export var muzzle_radius: float = -1.0

## Donor metal colour. Used by barrels, receivers and sights.
@export var metal_color: Color = Color.WHITE
## Donor timber colour. Used by grips and stocks.
@export var wood_color: Color = Color.WHITE

## Receivers only. Null on every other kind.
@export var socket_front: GunSocket = null
@export var socket_rear: GunSocket = null
@export var socket_bottom: GunSocket = null
@export var socket_top: GunSocket = null

## Baked, winding-repaired ArrayMesh for this part.
@export_file("*.res") var mesh_path: String = ""
## Open boundary edges left after the bake's cap pass. Anything above zero is a
## hole in the shipped mesh and a bake failure.
@export var boundary_edges: int = 0
## Signed volume of the repaired mesh. Positive means outward winding.
@export var signed_volume: float = 0.0


## The socket named `front`, `rear`, `bottom` or `top`. Null if this is not a receiver.
func socket(key: StringName) -> GunSocket:
	match key:
		&"front":
			return socket_front
		&"rear":
			return socket_rear
		&"bottom":
			return socket_bottom
		&"top":
			return socket_top
	return null


## True when this part is a receiver, i.e. carries the four sockets.
func is_receiver() -> bool:
	return kind == &"receiver"


## The colour this part actually renders in: timber for the parts you hold,
## metal for the parts that get hot.
func body_color() -> Color:
	if kind == &"grip" or kind == &"stock":
		return wood_color
	return metal_color


## Surface branch for `scrap_surface.gdshader`: 0 steel, 1 timber, 2 polymer.
## Barrels, receivers and sights are always steel. A grip or stock whose donor
## colour is near-neutral and dark is moulded polymer rather than wood — the
## reference's own test, kept because it is what makes the black guns read black.
func surface_type() -> int:
	if kind == &"barrel" or kind == &"receiver" or kind == &"sight":
		return 0
	var c: Color = wood_color
	var mx: float = maxf(c.r, maxf(c.g, c.b))
	var mn: float = minf(c.r, minf(c.g, c.b))
	if (mx - mn) < 0.06 and mx < 0.30:
		return 2
	return 1
