extends RefCounted
## The seven pieces of ground and everything bolted beside them: the capture
## volume, the banner mast, the fly-to post, the speed dial and the one sign in
## the demo.
##
## BAKE-TIME ONLY. `tools/build_firefight.gd` is the only caller.
##
## The zone table lives here rather than in the builder because every number in
## it is a placement: where the mast stands, how far out the post is set, which
## faction's colour the vane wears. A table split from the furniture it positions
## drifts from it.
##
## Scripts are attached by path, not by `class_name`. A script handed to
## `--script` compiles before any autoload exists, and `AITerritoryZone` reaches
## `Factions`, so naming it here would fail the bake before `_initialize`.

const SCRIPT_ZONE: String = "res://systems/ai/ai_territory_zone.gd"
const SCRIPT_MARKER: String = "res://demos/firefight/firefight_marker.gd"
const SCRIPT_BANNER: String = "res://demos/firefight/firefight_banner.gd"
const SCRIPT_DIAL: String = "res://demos/firefight/firefight_dial.gd"

## `Factions.NEUTRAL_ID`, spelled out for the reason above.
const NEUTRAL: int = -2

## Zone table: id, angle in degrees, initial owner as a `Factions.F` value,
## ledger value, sign text. The three homes are listed in enum order, which is
## what lets the builder index this table by faction for a home transform.
const ZONES: Array = [
	[&"scav_yard", 90.0, 0, 1.0, "SCAV YARD"],
	[&"foundry_gate", 210.0, 1, 1.0, "FOUNDRY GATE"],
	[&"choir_house", 330.0, 2, 1.0, "CHOIR HOUSE"],
	[&"tank_farm", 30.0, NEUTRAL, 1.15, "TANK FARM"],
	[&"cut_bank", 150.0, NEUTRAL, 1.15, "CUT BANK"],
	[&"slag_road", 270.0, NEUTRAL, 1.15, "SLAG ROAD"],
	[&"the_pan", 0.0, NEUTRAL, 1.6, "THE PAN"],
]
## Index of the centre zone in `ZONES`. It sits at the origin, not on the ring.
const CENTRE_ZONE: int = 6
## Radius the six outer zones sit on.
const ZONE_RING: float = 48.0
## Radius of a zone's capture cylinder.
const ZONE_RADIUS: float = 24.0
const ZONE_HEIGHT: float = 26.0
## Total sweep of the speed dial needle, in degrees. The drum detent marks are
## cut over the same arc, so the two cannot disagree.
const DIAL_SWEEP_DEGREES: float = 220.0

## The fixture mesh every part below is cut out of, surface by surface.
var _mesh: ArrayMesh = null


func _init(fixture_mesh: ArrayMesh) -> void:
	_mesh = fixture_mesh


static func center(i: int) -> Vector3:
	if i == CENTRE_ZONE:
		return Vector3.ZERO
	var a: float = deg_to_rad(float(ZONES[i][1]))
	return Vector3(sin(a), 0.0, cos(a)) * ZONE_RING


func zone_node(i: int) -> Node3D:
	var zone := Node3D.new()
	zone.set_script(load(SCRIPT_ZONE))
	zone.set(&"zone_id", ZONES[i][0])
	zone.set(&"initial_owner", int(ZONES[i][2]))
	zone.set(&"radius", ZONE_RADIUS * (1.3 if i == CENTRE_ZONE else 1.0))
	zone.set(&"height", ZONE_HEIGHT)
	zone.set(&"value", float(ZONES[i][3]))
	zone.position = center(i)
	zone.add_to_group(&"firefight_zone", true)
	return zone


## The mast over a zone. Offset off the anchor so a squad standing on the
## objective is not standing inside the flagpole.
func banner(i: int) -> Node3D:
	var mast := Node3D.new()
	mast.set_script(load(SCRIPT_BANNER))
	mast.position = center(i) + Vector3(0.0, 0.0, 4.6)
	_attach(mast, _part("mast"), "Mast")
	var flag: MeshInstance3D = _part("flag")
	flag.position = Vector3(0.0, 5.2, 0.0)
	_attach(mast, flag, "Flag")
	mast.set(&"zone_id", ZONES[i][0])
	mast.set(&"flag_path", NodePath("Flag"))
	mast.set(&"top_height", 5.2)
	return mast


## A fly-to post beside a zone, angled so its vantage looks back across the
## objective rather than at the back of the flagpole.
func marker(i: int) -> Node3D:
	var centre: Vector3 = center(i)
	var outward: Vector3 = centre.normalized() if centre.length_squared() > 1.0 else Vector3.BACK
	var post_node: Node3D = _post(String(ZONES[i][4]))
	post_node.position = centre + outward * (ZONE_RADIUS + 5.0)
	post_node.rotation.y = atan2(-outward.x, -outward.z)
	post_node.set(&"marker_name", String(ZONES[i][4]))
	post_node.set(&"track_hotspot", i == CENTRE_ZONE)
	post_node.set(&"eye_offset", Vector3(0.0, 9.5, 5.0))
	post_node.set(&"base_tint", tint(i))
	return post_node


## The post on the gantry, so a spectator who has flown out over the war can get
## back to the dial without steering all the way home.
func gantry_marker() -> Node3D:
	var post_node: Node3D = _post("THE GANTRY")
	post_node.position = Vector3(-2.6, 1.22, 74.0)
	post_node.rotation.y = PI
	post_node.set(&"marker_name", "THE GANTRY")
	post_node.set(&"eye_offset", Vector3(0.0, 2.1, 2.8))
	post_node.set(&"base_tint", Color(0.86, 0.84, 0.80, 1.0))
	post_node.set(&"reach", 18.0)
	return post_node


## The shared body of a marker: a post bolted down, a head that lifts and turns,
## a vane on the head and a name plate under it.
func _post(plate_text: String) -> Node3D:
	var post_node := Node3D.new()
	post_node.set_script(load(SCRIPT_MARKER))
	_attach(post_node, _part("post"), "Post")
	var head := Node3D.new()
	_attach(post_node, head, "Head")
	head.position = Vector3(0.0, 1.98, 0.0)
	_attach(head, _part("vane"), "Vane")
	_attach(head, _plate(plate_text, Vector3(0.0, 0.42, 0.0)), "Plate")
	var tinted: Array[NodePath] = [NodePath("Post"), NodePath("Head/Vane")]
	post_node.set(&"tinted_paths", tinted)
	post_node.set(&"lift_path", NodePath("Head"))
	post_node.set(&"vane_path", NodePath("Head"))
	return post_node


## The speed dial, on its plinth on the gantry. The needle rest angle and the
## marks on the drum come from the same sweep constant, so the two agree.
func dial() -> Node3D:
	var dial_node := Node3D.new()
	dial_node.set_script(load(SCRIPT_DIAL))
	dial_node.position = Vector3(2.6, 1.22, 74.0)
	dial_node.rotation.y = PI
	_attach(dial_node, _part("plinth"), "Plinth")
	var head := Node3D.new()
	_attach(dial_node, head, "Head")
	head.position = Vector3(0.0, 0.92, -0.42)
	_attach(head, _part("drum"), "Drum")
	_attach(head, _part("needle"), "Needle")
	_attach(head, _plate("SIM RATE", Vector3(0.0, -0.42, 0.06)), "Plate")
	var tinted: Array[NodePath] = [NodePath("Plinth"), NodePath("Head/Drum")]
	dial_node.set(&"base_tint", Color(0.80, 0.78, 0.74, 1.0))
	dial_node.set(&"reach", 14.0)
	dial_node.set(&"lift_height", 0.03)
	dial_node.set(&"tinted_paths", tinted)
	dial_node.set(&"lift_path", NodePath("Head"))
	dial_node.set(&"needle_path", NodePath("Head/Needle"))
	dial_node.set(&"sweep_degrees", DIAL_SWEEP_DEGREES)
	return dial_node


## The one instruction in the demo, engraved on a plate bolted to the gantry rail
## where the spectator starts. Everything else is learned by looking at it.
func sign_post() -> Node3D:
	var post := Node3D.new()
	post.position = Vector3(0.0, 1.86, 69.1)
	post.rotation.y = PI
	_attach(post, _plate("LOOK AT A POST \u2014 PRESS  E", Vector3.ZERO), "Plate")
	return post


## Engraved lettering. `Label3D` is a real object in the world with a real
## transform: it is lit, it is occluded, and it goes behind a wall when a wall is
## in front of it. That is the difference between a sign and a HUD.
func _plate(text: String, offset: Vector3) -> Label3D:
	var label := Label3D.new()
	label.text = text
	label.position = offset
	label.font_size = 96
	label.pixel_size = 0.0022
	label.modulate = Palette.BONE
	label.outline_size = 18
	label.outline_modulate = Color(0.06, 0.055, 0.05, 0.9)
	label.billboard = BaseMaterial3D.BILLBOARD_DISABLED
	label.double_sided = false
	label.shaded = true
	return label


## One surface of the fixture mesh, as its own `MeshInstance3D`. Godot draws a
## whole `ArrayMesh`, so a part is extracted into a single-surface mesh that
## shares the source arrays rather than copying them into the scene file.
func _part(surface_name: String) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	for s: int in _mesh.get_surface_count():
		if _mesh.surface_get_name(s) != surface_name:
			continue
		var out := ArrayMesh.new()
		out.resource_name = surface_name
		out.add_surface_from_arrays(
			Mesh.PRIMITIVE_TRIANGLES,
			_mesh.surface_get_arrays(s),
			[],
			{},
			WorldMesher.surface_format()
		)
		out.surface_set_material(0, _mesh.surface_get_material(s))
		mi.mesh = out
		break
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	return mi


static func tint(i: int) -> Color:
	var owner_faction: int = int(ZONES[i][2])
	if owner_faction < 0:
		return Color(0.84, 0.82, 0.78, 1.0)
	return Palette.faction_color(owner_faction).lerp(Color.WHITE, 0.25)


## Add a child and give it a name. Ownership is set by the builder in one pass at
## the end, which is the only way `PackedScene.pack` keeps a whole subtree.
func _attach(parent: Node, child: Node, child_name: String) -> void:
	child.name = child_name
	parent.add_child(child)
