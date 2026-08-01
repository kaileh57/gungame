class_name WorldPropAsset
extends Resource
## One baked prop: its mesh, its trimesh collision, and the oriented boxes the
## movement code walks against.
##
## The two collision forms are generated from the same geometry and therefore
## agree. `boxes` is what `WorldColliderSet` queries for stepping, vaulting and
## standing; `shape` is what Jolt uses so that bullets, grenades and enemy bodies
## collide the ordinary way.
##
## Props baked this way sit at the origin on flat ground, ready to be instanced
## anywhere. The town build calls the same generators directly instead, because
## it needs them to follow the terrain.

@export var id: StringName = &""
@export var mesh: ArrayMesh
@export var shape: ConcavePolygonShape3D
@export var boxes: WorldColliderSet
## Local bounds of the visual mesh.
@export var bounds: AABB = AABB()
@export var triangle_count: int = 0
## Total outward volume of every shell, cubic metres. Negative means something is
## inside out and the bake should not have shipped.
@export var volume: float = 0.0
## Surface ids this prop uses, for the footstep and impact tables.
@export var surfaces: PackedByteArray = PackedByteArray()


## A ready-to-add node for this prop: the mesh plus a static body carrying the
## trimesh. Callers that drive their own `WorldColliderSet` want `mesh` alone and
## should not use this.
func instantiate(prop_name: String = "") -> Node3D:
	var root := Node3D.new()
	root.name = prop_name if prop_name != "" else String(id)
	var mi := MeshInstance3D.new()
	mi.name = "Mesh"
	mi.mesh = mesh
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	root.add_child(mi)
	if shape != null:
		var body := StaticBody3D.new()
		body.name = "Body"
		body.collision_layer = GameLayers.PROP
		body.collision_mask = 0
		var cs := CollisionShape3D.new()
		cs.name = "Shape"
		cs.shape = shape
		body.add_child(cs)
		root.add_child(body)
	return root
