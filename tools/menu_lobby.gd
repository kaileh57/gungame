extends "res://tools/menu_geometry.gd"
## The multiplayer half of the workbench, cut from the same closed-shell kit the rest
## of the menu is: the join console, the roster sockets, the laser dots, the bar that
## locks the demo board, and the falling toast.
##
## `res://tools/build_main_menu.gd` owns the bake, the plates and the packing;
## `res://tools/menu_shop.gd` owns the room. This owns the lobby's furniture, and it
## is a third file for the same reason the second one exists: none of them may carry a
## thousand lines, and a number that lived in two files would drift the first time one
## of them moved.
##
## EVERY NUMBER HERE WAS SOLVED AGAINST THE AUTHORED EYE at (0, 1.62, 1.50) looking
## down 6.5 degrees through a 78 degree frame. Three placements are load bearing:
##
##   * The console sits where the BOTTOM of that frame is — its top face reads at 26
##     degrees below the horizon, three quarters of the way down the screen.
##   * The roster sits in the strip of bench top between the console in front of it
##     and the readout board's sightline behind it. Two degrees of screen either side.
##   * The lid's depth is set by the roster: standing open, its top edge lands at 22.3
##     degrees, which is just under the roster's feet at 21.8. A deeper lid covers the
##     names it is supposed to sit below.
##
## Move the eye and all three want re-solving.

## The join console: the middle of the bench's front strip, between the two utility
## plates. The GO button pokes 12 cm past the case, which still leaves 4 mm of bench.
const CONSOLE_Z: float = 0.245
const CASE: Vector3 = Vector3(0.44, 0.075, 0.16)
const LID: Vector3 = Vector3(0.46, 0.012, 0.13)
## The hinge runs along the case's FRONT-top edge, so the lid stands up leaning BACK
## and its face turns toward an eye that is above it. Hinged at the back it would
## rotate down through the bench instead.
const HINGE_LOCAL: Vector3 = Vector3(0.0, 0.075, 0.078)
## The GO button, proud of the front face — the ONE face on this object the eye sees
## square on, at 27 degrees off its normal, because the eye is high and the face is
## vertical.
const GO_LOCAL: Vector3 = Vector3(0.165, 0.040, 0.081)
const GO_RADIUS: float = 0.026
const GO_LENGTH: float = 0.018

## Four roster sockets across the back of the bench. The pitch is what fits between
## the tin on the left and the vice on the right without touching either.
const ROSTER_Z: float = -0.20
const ROSTER_PITCH: float = 0.35
const SOCKET: Vector3 = Vector3(0.32, 0.018, 0.085)
const TAG_SIZE: Vector3 = Vector3(0.30, 0.085, 0.012)
## Degrees a roster tag leans back: the angle that puts its face on the eye.
const TAG_LEAN_DEG: float = 26.0
const TAG_TEXT: Color = Color(0.96, 0.94, 0.90)
const TAG_MARK: Color = Color(0.96, 0.94, 0.90, 0.72)

## The bar that drops across the demo board on a machine that may not pick a demo.
## Between the two plate rows and clear in front of both.
const LOCK_Y: float = 1.68
const LOCK_BAR: Vector3 = Vector3(2.30, 0.055, 0.028)
const LOCK_TAB: Vector3 = Vector3(0.46, 0.11, 0.016)
const LOCK_STANDOFF: float = 0.075

const SIGN_SLAB: Vector3 = Vector3(0.64, 0.24, 0.022)
const DOT_RADIUS: float = 0.013

## The room's numbers, shared rather than copied. Everything this file places is
## placed against the bench and the board that file builds.
const MenuShop := preload("res://tools/menu_shop.gd")

var _steel: Material = null
var _polymer: Material = null
var _ember: Material = null
var _display: Font = null
## `res://ui/diegetic/diegetic_control.gd`, handed in rather than preloaded, so this
## file compiles under `--script` without dragging the UI's runtime graph in with it.
var _control: GDScript = null


func _init(
	steel: Material, polymer: Material, ember: Material, display: Font, control: GDScript
) -> void:
	_steel = steel
	_polymer = polymer
	_ember = ember
	_display = display
	_control = control


# --- the join console ---------------------------------------------------------


## A steel case with a lid hinged along its front-top edge, a GO button through the
## front, and a spark emitter at the seam the lid opens on. `script` drives it.
func build_console(script: GDScript) -> Node3D:
	var console := Node3D.new()
	console.name = "Console"
	console.set_script(script)
	console.position = Vector3(0.0, MenuShop.BENCH_TOP_Y, CONSOLE_Z)
	console.add_child(_build_case())
	console.add_child(_build_go())
	console.add_child(_build_hinge())
	console.add_child(_build_sparks())
	return console


## The case itself IS the control you press to open it, so the thing that moves and
## the thing you touch are one object. It flashes on press like every other control in
## the project, because its mesh is a child of the body.
func _build_case() -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = "Touch"
	body.set_script(_control)
	body.collision_layer = GameLayers.PROP
	body.collision_mask = 0
	body.set("control_id", &"join")
	body.set("cooldown", 0.25)
	body.add_child(
		mesh_node("Case", box(CASE, "join case"), _steel, Vector3(0.0, CASE.y * 0.5, 0.0), 0.28)
	)
	body.add_child(
		label(
			"Stencil",
			"JOIN A GAME",
			_display,
			17,
			0.0011,
			UiStyle.ACCENT,
			Vector3(-0.055, 0.040, CASE.z * 0.5 + 0.0015)
		)
	)
	body.add_child(
		hit_box(
			Vector3(CASE.x + 0.02, CASE.y + 0.02, CASE.z + 0.02), Vector3(0.0, CASE.y * 0.5, 0.0)
		)
	)
	return body


## The join button, standing proud of the front face so the ray finds it before the
## case behind it, and padded so it is a comfortable target rather than a 5 cm disc.
func _build_go() -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = "Go"
	body.set_script(_control)
	body.position = GO_LOCAL
	body.collision_layer = GameLayers.PROP
	body.collision_mask = 0
	body.set("control_id", &"join_go")
	body.set("cooldown", 0.25)
	var cap: MeshInstance3D = mesh_node(
		"Cap",
		cylinder(GO_RADIUS, GO_LENGTH, "go button"),
		_ember,
		Vector3(0.0, 0.0, GO_LENGTH * 0.5),
		0.33
	)
	# The kit builds cylinders about Y; a quarter turn stands this one on the face.
	cap.rotation = Vector3(deg_to_rad(90.0), 0.0, 0.0)
	body.add_child(cap)
	body.add_child(
		label(
			"Label", "GO", _display, 11, 0.0009, UiStyle.TEXT, Vector3(0.0, 0.0, GO_LENGTH + 0.002)
		)
	)
	body.add_child(hit_box(Vector3(0.075, 0.075, 0.05), Vector3(0.0, 0.0, GO_LENGTH * 0.75)))
	return body


## The lid, and the four lines stencilled on the face it turns into. They are SIBLINGS
## of the lid under the hinge rather than children of it, so the lid can be re-shaped
## without dragging the text off it.
func _build_hinge() -> Node3D:
	var hinge := Node3D.new()
	hinge.name = "Hinge"
	hinge.position = HINGE_LOCAL
	hinge.add_child(
		mesh_node(
			"Lid",
			box(LID, "console lid"),
			_steel,
			Vector3(0.0, LID.y * 0.5, -LID.z * 0.5),
			0.36,
			Color(1.18, 1.14, 1.10)
		)
	)
	hinge.add_child(_screen_label("Prompt", 13, 0.0010, UiStyle.ACCENT, -0.117))
	hinge.add_child(_screen_label("Entry", 22, 0.0015, UiStyle.TEXT, -0.084))
	hinge.add_child(_screen_label("Status", 11, 0.0012, UiStyle.TEXT_DIM, -0.040))
	hinge.add_child(_screen_label("Hint", 9, 0.0009, UiStyle.TEXT_FAINT, -0.011))
	return hinge


## One line on the lid's face. Laid into the lid's own XZ plane and turned to face its
## up axis, so that when the lid stands the line stands with it: the text's up axis
## lands on the direction the lid extends, which is the direction that becomes up.
func _screen_label(node_name: String, size: int, pixel: float, color: Color, z: float) -> Label3D:
	var line: Label3D = label(
		node_name, "", _display, size, pixel, color, Vector3(0.0, LID.y + 0.0015, z)
	)
	line.rotation = Vector3(-PI * 0.5, 0.0, 0.0)
	line.width = (LID.x - 0.02) / pixel
	line.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return line


## The flash that turns an address field into a name field. One shot, off by default,
## fired from `JoinConsole.burst()`. A `QuadMesh` and a process material, both baked
## into the scene like everything else here.
func _build_sparks() -> GPUParticles3D:
	var sparks := GPUParticles3D.new()
	sparks.name = "Sparks"
	sparks.position = Vector3(0.0, CASE.y + 0.004, CASE.z * 0.5 - 0.004)
	sparks.amount = 30
	sparks.lifetime = 0.55
	sparks.one_shot = true
	sparks.explosiveness = 1.0
	sparks.emitting = false
	sparks.local_coords = false
	sparks.visibility_aabb = AABB(Vector3(-0.5, -0.5, -0.5), Vector3(1.0, 1.0, 1.0))
	sparks.process_material = _spark_process()
	sparks.draw_pass_1 = _spark_mesh()
	return sparks


func _spark_process() -> ParticleProcessMaterial:
	var process := ParticleProcessMaterial.new()
	process.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	process.emission_sphere_radius = 0.03
	process.direction = Vector3(0.0, 1.0, 0.35)
	process.spread = 55.0
	process.initial_velocity_min = 0.7
	process.initial_velocity_max = 1.9
	process.gravity = Vector3(0.0, -3.2, 0.0)
	process.damping_min = 0.4
	process.damping_max = 1.3
	process.scale_min = 0.6
	process.scale_max = 1.4
	process.color = UiStyle.GOLD
	return process


func _spark_mesh() -> QuadMesh:
	var quad := QuadMesh.new()
	quad.size = Vector2(0.007, 0.007)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.vertex_color_use_as_albedo = true
	mat.albedo_color = UiStyle.GOLD
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	mat.billboard_keep_scale = true
	quad.material = mat
	return quad


# --- the roster ---------------------------------------------------------------


## Who is here, as four sockets with a coloured tag standing in each one that is
## taken. Slot 0 is the host and slot 0 is red, from `NetPlayer` — the roster owns the
## colours and this only paints them.
func build_roster() -> Node3D:
	var roster := Node3D.new()
	roster.name = "Roster"
	for i: int in NetPlayer.MAX_PLAYERS:
		roster.add_child(_build_slot(i))
	return roster


func _build_slot(index: int) -> Node3D:
	var slot := Node3D.new()
	slot.name = "Slot%d" % index
	var span: float = float(NetPlayer.MAX_PLAYERS - 1) * 0.5
	var x: float = (float(index) - span) * ROSTER_PITCH
	slot.position = Vector3(x, MenuShop.BENCH_TOP_Y, ROSTER_Z)
	slot.add_child(
		mesh_node(
			"Socket",
			box(SOCKET, "roster socket"),
			_polymer,
			Vector3(0.0, SOCKET.y * 0.5, 0.0),
			0.24 + 0.07 * float(index)
		)
	)
	var lean: float = deg_to_rad(TAG_LEAN_DEG)
	var up := Vector3(0.0, cos(lean), -sin(lean))
	var tag: MeshInstance3D = mesh_node(
		"Tag",
		box(TAG_SIZE, "roster tag"),
		null,
		Vector3(0.0, SOCKET.y, 0.0) + up * (TAG_SIZE.y * 0.5),
		0.3 + 0.05 * float(index)
	)
	tag.rotation = Vector3(-lean, 0.0, 0.0)
	tag.material_override = _slot_material(index)
	slot.add_child(tag)
	var face: float = TAG_SIZE.z * 0.5 + 0.0015
	tag.add_child(_tag_label("Name", 17, 0.0016, TAG_TEXT, Vector3(0.0, 0.014, face)))
	tag.add_child(_tag_label("Mark", 14, 0.0015, TAG_MARK, Vector3(0.0, -0.026, face)))
	var free: Label3D = label(
		"Free", "OPEN", _display, 14, 0.0015, UiStyle.TEXT_FAINT, Vector3(0.0, 0.040, -0.012)
	)
	free.rotation = Vector3(-lean, 0.0, 0.0)
	slot.add_child(free)
	return slot


func _tag_label(node_name: String, size: int, pixel: float, color: Color, at: Vector3) -> Label3D:
	var line: Label3D = label(node_name, "", _display, size, pixel, color, at)
	line.width = (TAG_SIZE.x - 0.02) / pixel
	line.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return line


## The four identity colours, one baked material each. A `StandardMaterial3D` rather
## than the scrap shader with a per-instance tint, because these four have to come out
## EXACTLY the colours `NetPlayer` says they are — a tint multiplied into a grey albedo
## is close, and close is what makes gold and sage stop being different colours.
func _slot_material(index: int) -> StandardMaterial3D:
	var color: Color = NetPlayer.SLOT_COLORS[index]
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.metallic = 0.0
	mat.roughness = 0.55
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = 0.35
	return mat


# --- the laser dots -----------------------------------------------------------


## Three dots, one per guest, hidden until somebody is pointing at something.
func build_dots(script: GDScript) -> Node3D:
	var dots := Node3D.new()
	dots.name = "Dots"
	dots.set_script(script)
	dots.set("solids", aim_solids())
	for i: int in NetPlayer.MAX_PLAYERS - 1:
		dots.add_child(_build_dot(i))
	return dots


func _build_dot(index: int) -> MeshInstance3D:
	var mesh := SphereMesh.new()
	mesh.radius = DOT_RADIUS
	mesh.height = DOT_RADIUS * 2.0
	mesh.radial_segments = 10
	mesh.rings = 5
	var node := MeshInstance3D.new()
	node.name = "Dot%d" % index
	node.mesh = mesh
	node.material_override = _dot_material(NetPlayer.SLOT_COLORS[index + 1])
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	node.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	node.visible = false
	var tag: Label3D = label(
		"Name", "", _display, 13, 0.0011, UiStyle.TEXT, Vector3(0.0, 0.035, 0.0)
	)
	tag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	tag.visible = false
	node.add_child(tag)
	return node


func _dot_material(color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = color
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = 2.2
	mat.disable_receive_shadows = true
	return mat


## The solids a laser dot may land on, as (centre, size) pairs read straight off the
## shed's own numbers.
##
## The menu has almost no colliders ON PURPOSE — the hands are given PROP only so a
## press reaches past the shed's own timber — and adding some for the dot would change
## what the reticle's look ray finds in this scene as a side effect. So the dot's ray
## is solved analytically against these four boxes instead, and they cannot drift from
## the geometry they stand for because they are derived from it here.
func aim_solids() -> PackedVector3Array:
	var board_mid: float = (MenuShop.BOARD_BOTTOM + MenuShop.BOARD_TOP) * 0.5
	var board_span: float = MenuShop.BOARD_TOP - MenuShop.BOARD_BOTTOM
	var out := PackedVector3Array()
	out.append(Vector3(0.0, board_mid, MenuShop.BOARD_Z))
	out.append(Vector3(MenuShop.BOARD_W, board_span, MenuShop.BOARD_T))
	out.append(Vector3(0.0, MenuShop.BENCH_TOP_Y - MenuShop.BENCH_TOP_T * 0.5, 0.0))
	out.append(Vector3(MenuShop.BENCH_W, MenuShop.BENCH_TOP_T, MenuShop.BENCH_D))
	out.append(Vector3(0.0, MenuShop.WALL_TOP * 0.5, MenuShop.WALL_Z))
	out.append(Vector3(MenuShop.WALL_HALF * 2.0, MenuShop.WALL_TOP, MenuShop.WALL_T))
	out.append(Vector3(0.0, -MenuShop.SLAB.y * 0.5, MenuShop.SLAB_Z))
	out.append(MenuShop.SLAB)
	return out


# --- the lock bar and the toast -----------------------------------------------


## The bar that says, from across the room, that this machine does not choose. Hidden
## until the local player is somebody else's guest, then dropped into place.
func build_lock_bar() -> Node3D:
	var lock := Node3D.new()
	lock.name = "LockBar"
	lock.position = Vector3(0.0, LOCK_Y, MenuShop.BOARD_FACE + LOCK_STANDOFF)
	lock.visible = false
	lock.add_child(
		mesh_node(
			"Bar", box(LOCK_BAR, "lock bar"), _steel, Vector3.ZERO, 0.41, Color(1.30, 1.10, 0.96)
		)
	)
	lock.add_child(
		mesh_node(
			"Tab",
			box(LOCK_TAB, "lock tab"),
			_steel,
			Vector3(0.0, -0.02, LOCK_TAB.z),
			0.47,
			Color(0.88, 0.74, 0.70)
		)
	)
	lock.add_child(
		label(
			"Text",
			"THE HOST PICKS",
			_display,
			22,
			0.0016,
			UiStyle.ACCENT,
			Vector3(0.0, -0.02, LOCK_TAB.z * 1.5 + 0.002)
		)
	)
	return lock


## The falling toast, as its own prefab root.
##
## IT COLLIDES WITH NOTHING, and the way it is made not to matters. `collision_mask`
## is zero, so it tests against nothing and can never come to rest on the bench it
## falls past. `collision_layer` is `VIEWMODEL`, which is the one layer in the
## contract that nothing queries — it is in no `MASK_*` constant — so nothing tests
## against it either.
##
## LAYER ZERO WOULD READ THE SAME AND DOES NOT WORK. Measured on Jolt: a body with no
## layer bits at all is registered in no broadphase layer and never integrates, so the
## sign hung motionless above the top of the frame and no toast was ever seen. A layer
## that nothing looks at is the same isolation with the body still in the world.
func build_sign(script: GDScript) -> RigidBody3D:
	var body := RigidBody3D.new()
	body.name = "LobbySign"
	body.set_script(script)
	body.mass = 2.2
	body.gravity_scale = 0.30
	body.collision_layer = GameLayers.VIEWMODEL
	body.collision_mask = 0
	body.can_sleep = false
	body.add_child(
		mesh_node(
			"Slab",
			box(SIGN_SLAB, "toast slab"),
			_steel,
			Vector3.ZERO,
			0.55,
			Color(1.35, 1.28, 1.18)
		)
	)
	body.add_child(_sign_face("Front", SIGN_SLAB.z * 0.5 + 0.002, 0.0))
	body.add_child(_sign_face("Back", -SIGN_SLAB.z * 0.5 - 0.002, PI))
	var shape := CollisionShape3D.new()
	shape.name = "Shape"
	var solid := BoxShape3D.new()
	solid.size = SIGN_SLAB
	shape.shape = solid
	body.add_child(shape)
	return body


## Both faces carry the same words, so the sign is readable whichever way it happens
## to be facing as it turns over.
func _sign_face(node_name: String, z: float, yaw: float) -> Label3D:
	var line: Label3D = label(
		node_name, "", _display, 34, 0.0026, UiStyle.TEXT, Vector3(0.0, 0.0, z)
	)
	line.rotation = Vector3(0.0, yaw, 0.0)
	line.width = (SIGN_SLAB.x - 0.04) / 0.0026
	line.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return line


## A padded press target. Padding outward is what makes a control feel crisp rather
## than slippery; it is never padded into a neighbour.
static func hit_box(size: Vector3, at: Vector3) -> CollisionShape3D:
	var shape := CollisionShape3D.new()
	shape.name = "Shape"
	var solid := BoxShape3D.new()
	solid.size = size
	shape.shape = solid
	shape.position = at
	return shape
