extends Resource
## Where a panel sits on the thing that carries it, DERIVED rather than tuned.
##
## A sign, a placard, a card or a screen is a box with a readable face, and it is
## almost never bolted flat — it is raked toward the reader. Raking it about its
## mount point swings one of its edges BACKWARDS by `half_height * sin(tilt)`.
## A `DiegeticReadout` is 0.42 m tall, so at 34 degrees its top-back corner swings
## 0.117 m behind the mount point, and any standoff that was picked by hand for the
## flat case is eaten whole. The panel sinks into its support and, on a support
## shallower than the swing, comes out the other side. That is one bug, copied
## across five builders.
##
## Nothing here is tuned. The standoff is solved, every time, from
##   * the panel's real bounds, measured off the geometry it actually carries,
##   * the basis it is actually mounted with — yaw, rake and scale, and
##   * the box the support actually occupies.
## For an axis-aligned support and a panel raked about X this reduces to the
## familiar
##     standoff = half_depth*cos(t) + half_height*|sin(t)| + support_half_depth + clearance
## but the code never assumes the bounds are centred on the panel's origin — a
## `DiegeticReadout`'s are not; its back plate hangs 60 mm behind the origin and
## its bezel reaches only 10 mm in front — and never assumes the rake is the only
## rotation between the panel and the frame the support is described in.
##
## [codeblock]
## var mount := PanelMount.new()
## mount.tilt_degrees = -34.0
## mount.apply(placard, PanelMount.half_box(stand_at, stand_half), at, "PlacardStand")
## [/codeblock]
##
## Every mount stamps what it did onto the node as metadata, and
## `res://tools/verify_mounts.gd` re-derives the intersection from that metadata in
## every baked scene. A panel that is not mounted through here is not checked, so
## the census in that tool is the second half of the gate: it names every readable
## face in a baked scene that carries no mount.
##
## Lives beside the panels rather than under `res://systems/world/` because every
## consumer is a diegetic panel and the whole job is measuring one; `systems/world`
## is terrain, town and props and has no notion of a readable face.

## Metadata keys stamped on a mounted panel. Read by `tools/verify_mounts.gd`.
const META_BOUNDS: StringName = &"mount_bounds"
const META_SUPPORT: StringName = &"mount_support"
const META_SUPPORT_NAME: StringName = &"mount_support_name"
const META_CLEARANCE: StringName = &"mount_clearance"
const META_AXIS: StringName = &"mount_axis"
const META_DIRECTION: StringName = &"mount_direction"
const META_FRAME: StringName = &"mount_frame"

## Which axis of the PANEL'S PARENT FRAME the standoff is solved along.
## 0 = X, 1 = Y, 2 = Z. A card on a board stands off along Z; a plate lying back on
## a bench top stands off along Y.
@export_range(0, 2, 1) var axis: int = Vector3.AXIS_Z
## Which end of the support the panel stands off. +1 is the support's high face on
## `axis`, -1 its low face — a panel that faces back down a hall is on the low face.
@export_range(-1, 1, 2) var direction: int = 1
## Rake about the panel's own X, applied after `yaw_degrees`. This is the rotation
## whose sine the old hand-tuned constants ignored.
@export_range(-89.0, 89.0, 0.05) var tilt_degrees: float = 0.0
## Turn about the parent's Y, applied first. It belongs in the solve rather than on
## the node afterwards, because a yawed panel's depth points down a different parent
## axis and the standoff has to be solved in the frame the panel finally sits in.
@export_range(-180.0, 180.0, 0.05) var yaw_degrees: float = 0.0
## Uniform scale. A `DiegeticReadout` ships at 600 x 420 mm and is blown up to be
## read across a room; the scale multiplies its bounds and therefore its swing, so
## it is part of the solve and not a decoration applied after it.
@export_range(0.05, 12.0, 0.01) var panel_scale: float = 1.0
## Air gap between the panel's nearest corner and the support's face. Zero is legal
## and means exactly touching. Four millimetres reads as a bolted standoff at the
## sizes this project mounts, and is small enough that no shadow gap opens under a
## plate lit by a lamp two metres away.
@export_range(0.0, 0.25, 0.0005) var clearance: float = 0.004
## Bounds to fall back on when the panel cannot be measured. A `Label3D` is the case
## that needs it: its geometry is a glyph run the text server lays out, and a bake
## that cannot lay it out would otherwise solve a standoff against nothing.
@export var bounds_override: AABB = AABB()


## An axis-aligned box from a centre and a full size.
static func centred(centre: Vector3, size: Vector3) -> AABB:
	return AABB(centre - size * 0.5, size)


## An axis-aligned box from a centre and half-extents, which is how `WorldMesher`
## and every builder in this project describe a solid.
static func half_box(centre: Vector3, half: Vector3) -> AABB:
	return AABB(centre - half, half * 2.0)


## The bounds of `box` after `b`, still centred on the origin `b` turns about.
## The standard support-function form: each output extent is the sum of the input
## half-extents projected onto that axis, which is exact for a box under any basis.
static func swept(b: Basis, box: AABB) -> AABB:
	var half: Vector3 = box.size * 0.5
	var centre: Vector3 = b * (box.position + half)
	var reach := Vector3(
		absf(b.x.x) * half.x + absf(b.y.x) * half.y + absf(b.z.x) * half.z,
		absf(b.x.y) * half.x + absf(b.y.y) * half.y + absf(b.z.y) * half.z,
		absf(b.x.z) * half.x + absf(b.y.z) * half.y + absf(b.z.z) * half.z
	)
	return AABB(centre - reach, reach * 2.0)


## Measure a panel: the union of every piece of geometry under it, in its own space,
## with its own transform left out. Meshes are read off the resource rather than off
## the node, so this answers correctly in a headless bake where nothing has entered
## a tree and the dummy renderer has no instance to ask.
static func measure(node: Node3D) -> AABB:
	var boxes: Array[AABB] = []
	_gather(node, Transform3D.IDENTITY, boxes)
	if boxes.is_empty():
		return AABB()
	var out: AABB = boxes[0]
	for i: int in range(1, boxes.size()):
		out = out.merge(boxes[i])
	return out


## The basis the panel is mounted with: yaw about the parent's up, then the rake
## about the panel's own X, then the uniform scale.
func mount_basis() -> Basis:
	var turn := Basis(Vector3.UP, deg_to_rad(yaw_degrees))
	var rake := Basis(Vector3.RIGHT, deg_to_rad(tilt_degrees))
	return (turn * rake).scaled(Vector3.ONE * panel_scale)


## The transform to give the panel, in its parent's frame. `at` is where it goes;
## its component on `axis` is IGNORED and replaced by the solved standoff, which is
## the whole point — that component is the number nobody can get right by hand.
func solve(bounds: AABB, support: AABB, at: Vector3) -> Transform3D:
	var reach: AABB = swept(mount_basis(), bounds)
	var origin: Vector3 = at
	if direction >= 0:
		origin[axis] = support.end[axis] + clearance - reach.position[axis]
	else:
		origin[axis] = support.position[axis] - clearance - reach.end[axis]
	return Transform3D(mount_basis(), origin)


## The same solve read the other way round: given a panel already placed at `at`,
## the plane the SUPPORT's facing side must not cross. For a sign bolted to a post
## the sign's place is the composition and the post is the thing that can move;
## pushing the sign forward instead would float it off its own mounting.
func support_face(bounds: AABB, at: Vector3) -> float:
	var reach: AABB = swept(mount_basis(), bounds)
	if direction >= 0:
		return at[axis] + reach.position[axis] - clearance
	return at[axis] + reach.end[axis] + clearance


## Mount `panel` on `support` and record what was done.
##
## `support`, `at`, `axis` and `direction` are all read in the MOUNT FRAME, and
## `frame` is where that frame sits in the panel's parent. A placard on a plinth
## corner is turned forty-five degrees to face up the aisle: solving in the parent
## would have to fatten the support box by that turn and would then push the panel
## along the wrong axis, so the turn goes in `frame` and the solve stays exact.
## Returns the transform written, so a caller can hang a label or a collision shape
## off the same basis.
func apply(
	panel: Node3D, support: AABB, at: Vector3, support_name: String, frame := Transform3D.IDENTITY
) -> Transform3D:
	var bounds: AABB = measure(panel)
	if bounds.size.length_squared() <= 0.0:
		bounds = bounds_override
	if bounds.size.length_squared() <= 0.0:
		push_error("PanelMount: '%s' has no measurable bounds and no override." % panel.name)
		return panel.transform
	var xf: Transform3D = solve(bounds, support, at)
	panel.transform = frame * xf
	declare(panel, bounds, support, support_name, frame)
	return xf


## A panel that HANGS rather than seats: the frame reaches down to meet it, so there
## is no standoff to solve — only a clearance to prove. Records the geometry so
## `verify_mounts` tests the intersection, and moves nothing. Clearance is zero,
## which the checker reads as "must not touch" rather than "must stand off by".
func hang(panel: Node3D, support: AABB, support_name: String) -> void:
	clearance = 0.0
	declare(panel, measure(panel), support, support_name)


## Record a mount whose transform the caller writes itself — the case where one
## solved basis drives a mesh, a label and a collision shape and the panel node is
## not the thing that moves. `bounds` and the transform must be the ones used.
func declare(
	panel: Node3D, bounds: AABB, support: AABB, support_name: String, frame := Transform3D.IDENTITY
) -> void:
	panel.set_meta(META_BOUNDS, bounds)
	panel.set_meta(META_SUPPORT, support)
	panel.set_meta(META_SUPPORT_NAME, support_name)
	panel.set_meta(META_CLEARANCE, clearance)
	panel.set_meta(META_AXIS, axis)
	panel.set_meta(META_DIRECTION, direction)
	panel.set_meta(META_FRAME, frame)


static func _gather(node: Node, at: Transform3D, boxes: Array[AABB]) -> void:
	var own: AABB = _own_bounds(node)
	if own.size.length_squared() > 0.0:
		var world: AABB = swept(at.basis, own)
		boxes.append(AABB(world.position + at.origin, world.size))
	for child: Node in node.get_children():
		var spatial := child as Node3D
		_gather(child, at if spatial == null else at * spatial.transform, boxes)


## One node's own geometry, in its own space. A `MultiMeshInstance3D` is skipped:
## the batches in this project are plinths and lamp stems, never a mounted panel,
## and its `get_aabb` is the batch rather than the piece.
static func _own_bounds(node: Node) -> AABB:
	var mesh_node := node as MeshInstance3D
	if mesh_node != null:
		return AABB() if mesh_node.mesh == null else mesh_node.mesh.get_aabb()
	if node is MultiMeshInstance3D:
		return AABB()
	var visual := node as VisualInstance3D
	return AABB() if visual == null else visual.get_aabb()
