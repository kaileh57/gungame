extends RefCounted
## Everything Recast is fed for the firefight arena, and the navmesh parameters it
## is fed them with.
##
## BAKE-TIME ONLY. `tools/build_firefight.gd` is the only caller.
##
## WINDING. Godot's navigation baker reverses every triangle on its way into
## Recast, because Godot treats clockwise as front-facing and Recast treats
## counter-clockwise as up. Faces handed to it must be in GODOT's convention.
## `WorldMesher` already emits in that convention, so the arena's own vertices go
## straight in, and the boxes below match it.


static func make_navmesh() -> NavigationMesh:
	var nm := NavigationMesh.new()
	# MUST match the navigation map, which takes its cell size and height from
	# `ProjectSettings` and is 0.25 / 0.25 here. A navmesh baked at any other
	# voxel size is silently refused by the map: the region registers, reports
	# zero bounds, contributes no polygons, and every query answers with the
	# origin. Nothing is logged. The cover bake comes out empty and every agent
	# in the demo stands still, and the two symptoms look nothing alike.
	nm.cell_size = 0.25
	nm.cell_height = 0.25
	# Sized for the widest body in the three rosters rather than the median. A
	# navmesh a Foreman does not fit through is a navmesh that wedges a Foreman
	# in a gate and leaves it there.
	nm.agent_radius = 0.62
	nm.agent_height = 2.1
	nm.agent_max_climb = 0.45
	nm.agent_max_slope = 46.0
	nm.region_min_size = 8.0
	nm.region_merge_size = 20.0
	nm.edge_max_length = nm.cell_size * 30.0
	nm.edge_max_error = 1.2
	nm.detail_sample_distance = 4.0
	nm.detail_sample_max_error = 0.6
	nm.filter_low_hanging_obstacles = true
	nm.filter_ledge_spans = true
	nm.filter_walkable_low_height_spans = true
	return nm


## Thirty-six vertices, twelve outward triangles, of a yaw-rotated box.
static func box_faces(c: Vector3, h: Vector3, ry: float) -> PackedVector3Array:
	var basis := Basis(Vector3.UP, ry)
	var p := PackedVector3Array()
	p.resize(8)
	for s: int in 8:
		var local := Vector3(
			h.x if (s & 1) != 0 else -h.x,
			h.y if (s & 2) != 0 else -h.y,
			h.z if (s & 4) != 0 else -h.z
		)
		p[s] = c + basis * local
	const QUADS: Array[Vector4i] = [
		Vector4i(0, 1, 3, 2),
		Vector4i(4, 6, 7, 5),
		Vector4i(0, 4, 5, 1),
		Vector4i(2, 3, 7, 6),
		Vector4i(0, 2, 6, 4),
		Vector4i(1, 5, 7, 3),
	]
	var out := PackedVector3Array()
	for q: Vector4i in QUADS:
		out.append_array(PackedVector3Array([p[q.x], p[q.y], p[q.z], p[q.x], p[q.z], p[q.w]]))
	return out


## The compound kit's own collision boxes, in each of the three home transforms.
## The kit is a scene of `BoxShape3D` shapes over one fused mesh, and those shapes
## are the truth about what an agent can walk through, so those are what Recast
## is fed rather than the mesh.
static func compound_boxes(compound: PackedScene, homes: Array[Transform3D]) -> Array:
	var out: Array = []
	var kit := compound.instantiate() as Node3D
	var shapes: Array = []
	_collect_box_shapes(kit, Transform3D.IDENTITY, shapes)
	kit.free()
	for x: Transform3D in homes:
		for entry: Array in shapes:
			var world: Transform3D = x * (entry[0] as Transform3D)
			out.append([world.origin, entry[1], world.basis.get_euler(EULER_ORDER_YXZ).y])
	return out


static func _collect_box_shapes(node: Node, parent: Transform3D, out: Array) -> void:
	var here: Transform3D = parent
	var n3 := node as Node3D
	if n3 != null:
		here = parent * n3.transform
	var cs := node as CollisionShape3D
	if cs != null:
		var box := cs.shape as BoxShape3D
		if box != null and not cs.disabled:
			out.append([here, box.size * 0.5])
	for child: Node in node.get_children():
		_collect_box_shapes(child, here, out)


## Cover props as navigation obstacles, using each asset's own baked box set. A
## prop with no box set falls back to its bounds, which is coarser but never
## leaves a hole an agent can path into and then get stuck in.
static func clutter_faces(props: WorldPropSet, clutter: Dictionary) -> PackedVector3Array:
	var out := PackedVector3Array()
	for id: StringName in clutter:
		var asset: WorldPropAsset = props.asset(id)
		if asset == null:
			continue
		for x: Transform3D in clutter[id]:
			var yaw: float = x.basis.get_euler(EULER_ORDER_YXZ).y
			if asset.boxes != null and asset.boxes.size() > 0:
				for i: int in asset.boxes.size():
					out.append_array(
						box_faces(
							x * asset.boxes.centers[i],
							asset.boxes.halves[i],
							yaw + asset.boxes.yaws[i]
						)
					)
				continue
			var b: AABB = asset.bounds
			out.append_array(box_faces(x * b.get_center(), b.size * 0.5, yaw))
	return out


static func navmesh_bounds(navmesh: NavigationMesh, fallback_radius: float) -> AABB:
	var verts: PackedVector3Array = navmesh.get_vertices()
	if verts.is_empty():
		var r: float = fallback_radius
		return AABB(Vector3(-r, -2.0, -r), Vector3.ONE * r * 2.0)
	var box := AABB(verts[0], Vector3.ZERO)
	for i: int in range(1, verts.size()):
		box = box.expand(verts[i])
	return box
