class_name RangeTargetKit
extends RefCounted
## Every target on the range, built from `docs/spec/range.md` §15.2 and placed in
## the exact call order of §15.3 — which is the level.
##
## BAKE-TIME ONLY. `tools/build_range.gd` is the only caller.
##
## Two rules run through all of it. Each target's shootable parts are separate
## `StaticBody3D` nodes so a scoring spot can carry `zone = head` while the plate
## it sits on carries `zone = body`; and every collider is matched to the shell it
## stands for to within a few millimetres, because a plate you can hit two
## centimetres in front of its face is a plate that reads as broken.

## Down-range distances, in metres, and what stands at each. Entries are
## `[kind, x, distance, a, b]` where `a`/`b` mean radius/hp for a plate, hp for a
## popper, count for a bottle row, and radius/span for a mover.
const LAYOUT: Array = [
	["plate", -5.5, 15.0, 0.30, 60.0],
	["plate", 0.0, 15.0, 0.24, 45.0],
	["plate", 5.5, 15.0, 0.30, 60.0],
	["popper", -9.0, 22.0, 130.0, 0.0],
	["popper", 9.0, 22.0, 130.0, 0.0],
	["bottles", 0.0, 12.0, 9.0, 0.0],
	["paper", 0.0, 25.0, 0.0, 0.0],
	["plate", -7.0, 35.0, 0.42, 160.0],
	["plate", 7.0, 35.0, 0.42, 160.0],
	["barrel", -13.0, 30.0, 0.0, 0.0],
	["barrel", 13.0, 30.0, 0.0, 0.0],
	["barrel", 0.0, 52.0, 0.0, 0.0],
	["mover", 0.0, 45.0, 0.5, 7.5],
	["plate", -11.0, 70.0, 0.55, 260.0],
	["plate", 11.0, 70.0, 0.55, 260.0],
	["popper", 0.0, 70.0, 340.0, 0.0],
	["plate", -6.0, 140.0, 0.75, 440.0],
	["plate", 6.0, 140.0, 0.75, 440.0],
	["barrel", -20.0, 140.0, 0.0, 0.0],
	["barrel", 20.0, 140.0, 0.0, 0.0],
	["plate", 0.0, 250.0, 1.05, 700.0],
	["plate", 0.0, 400.0, 1.45, 1000.0],
]

const TARGET_SCRIPT: String = "res://demos/range/range_target.gd"
const PAPER_SCRIPT: String = "res://demos/range/range_paper.gd"
const PAPER_FACE_PATH: String = "res://demos/range/paper_face.res"
const PAPER_MATERIAL_PATH: String = "res://demos/range/paper_face_mat.tres"

var shop: RangeShop = null

var _rand: XorShift32 = null


func _init(workshop: RangeShop, rand: XorShift32) -> void:
	shop = workshop
	_rand = rand


func build(parent: Node3D) -> void:
	for entry: Array in LAYOUT:
		var kind: String = String(entry[0])
		var x: float = float(entry[1])
		var d: float = float(entry[2])
		var a: float = float(entry[3])
		var b: float = float(entry[4])
		match kind:
			"plate":
				parent.add_child(_plate(x, d, a, b, false))
			"popper":
				parent.add_child(_popper(x, d, a))
			"bottles":
				_bottle_row(parent, d, int(a))
			"paper":
				parent.add_child(_paper(d))
			"barrel":
				parent.add_child(_barrel(x, d))
			"mover":
				parent.add_child(_mover(d, a, b))


## Swinging steel disc on a stake. The disc and the scoring spot are separate
## bodies so a shot on the spot resolves as a head hit; the spot stands 5 mm
## proud of the face, which is both how it wins the ray and how it reads.
func _plate(x: float, distance: float, radius: float, hp: float, is_mover: bool) -> Node3D:
	var ph: float = maxf(0.7, radius * 1.4)
	var node := Node3D.new()
	node.name = "Plate_%s_%s" % [str(int(distance)), str(int(absf(x) * 10.0))]
	node.position = Vector3(x, 0.0, -distance)
	node.set_script(load(TARGET_SCRIPT))
	node.set("kind", 5 if is_mover else 0)
	node.set("max_health", hp)
	node.set("points", roundi((36.0 + distance * 0.9) if is_mover else (8.0 + distance * 0.55)))
	node.set("target_radius", radius)
	node.set("reset_seconds", 5.0)
	node.set("distance_hint", distance)

	if not is_mover:
		var post_mesh: ArrayMesh = shop.cached(
			"plate_post_%s" % RangeShop.key(ph),
			func() -> ArrayMesh:
				var m := WorldMesher.new()
				m.box(
					Vector3(0.0, ph * 0.5 - 0.12, 0.0),
					Vector3(0.055, ph * 0.5 + 0.12, 0.055),
					0.0,
					RangeShop.C_POST,
					RangeShop.SURF_METAL
				)
				m.box(
					Vector3(0.0, ph - 0.04, 0.0),
					Vector3(0.09, 0.05, 0.09),
					0.0,
					RangeShop.C_STEEL_DARK,
					RangeShop.SURF_METAL
				)
				return shop.commit(m, "plate_post_%s" % RangeShop.key(ph))
		)
		shop.add_mesh(node, "Post", post_mesh, true)

	var swing := Node3D.new()
	swing.name = "Swing"
	swing.position = Vector3(0.0, 0.0 if is_mover else ph, 0.0)
	node.add_child(swing)

	var disc_y: float = radius * 0.92
	var disc_mesh: ArrayMesh = shop.cached(
		"plate_disc_%s" % RangeShop.key(radius),
		func() -> ArrayMesh:
			var m := WorldMesher.new()
			m.cylinder(
				Vector3(0.0, disc_y, 0.0),
				radius,
				radius,
				0.022,
				26,
				RangeShop.C_STEEL,
				RangeShop.SURF_METAL,
				Vector3.BACK
			)
			# Backing web, so the plate is a plate and not a coin.
			m.box(
				Vector3(0.0, disc_y, -0.045),
				Vector3(radius * 0.14, radius * 0.86, 0.03),
				0.0,
				RangeShop.C_STEEL_DARK,
				RangeShop.SURF_METAL
			)
			m.box(
				Vector3(0.0, disc_y, -0.045),
				Vector3(radius * 0.86, radius * 0.14, 0.03),
				0.0,
				RangeShop.C_STEEL_DARK,
				RangeShop.SURF_METAL
			)
			m.cylinder(
				Vector3(0.0, disc_y, 0.019),
				radius * 0.31,
				radius * 0.31,
				0.006,
				22,
				RangeShop.C_RING,
				RangeShop.SURF_METAL,
				Vector3.BACK
			)
			return shop.commit(m, "plate_disc_%s" % RangeShop.key(radius))
	)
	var spot_mesh: ArrayMesh = shop.cached(
		"plate_spot_%s" % RangeShop.key(radius),
		func() -> ArrayMesh:
			var m := WorldMesher.new()
			m.cylinder(
				Vector3(0.0, disc_y, 0.030),
				radius * 0.27,
				radius * 0.27,
				0.005,
				22,
				RangeShop.C_DOT,
				RangeShop.SURF_METAL,
				Vector3.BACK
			)
			return shop.commit(m, "plate_spot_%s" % RangeShop.key(radius))
	)

	var surface: StringName = &"mover" if is_mover else &"plate"
	var body := shop.prop_body("Face", surface, &"body")
	shop.add_mesh(body, "Disc", disc_mesh, true)
	var disc_shape := CollisionShape3D.new()
	var cyl := CylinderShape3D.new()
	cyl.radius = radius
	# The shell spans -0.075 (back of the web) to +0.022 (front of the plate).
	# The box matches it to 3 mm, which is as close as a ray can tell.
	cyl.height = 0.10
	disc_shape.shape = cyl
	disc_shape.position = Vector3(0.0, disc_y, -0.026)
	disc_shape.rotation.x = PI * 0.5
	body.add_child(disc_shape)
	swing.add_child(body)

	var head := shop.prop_body("Spot", surface, &"head")
	shop.add_mesh(head, "Dot", spot_mesh, false)
	var head_shape := CollisionShape3D.new()
	var head_cyl := CylinderShape3D.new()
	head_cyl.radius = radius * 0.27
	head_cyl.height = 0.012
	head_shape.shape = head_cyl
	head_shape.position = Vector3(0.0, disc_y, 0.030)
	head_shape.rotation.x = PI * 0.5
	head.add_child(head_shape)
	swing.add_child(head)

	node.set("swing_path", NodePath("Swing"))
	return node


func _popper(x: float, distance: float, hp: float) -> Node3D:
	var node := Node3D.new()
	node.name = "Popper_%s_%s" % [str(int(distance)), str(int(absf(x) * 10.0))]
	node.position = Vector3(x, 0.0, -distance)
	node.set_script(load(TARGET_SCRIPT))
	node.set("kind", 1)
	node.set("max_health", hp)
	node.set("points", roundi(16.0 + distance * 0.8))
	node.set("target_radius", 0.44)
	node.set("reset_seconds", 6.0)
	node.set("distance_hint", distance)

	var hinge := Node3D.new()
	hinge.name = "Swing"
	node.add_child(hinge)

	var body_mesh: ArrayMesh = shop.cached(
		"popper_body",
		func() -> ArrayMesh:
			var m := WorldMesher.new()
			m.box(
				Vector3(0.0, 0.27, 0.0),
				Vector3(0.05, 0.30, 0.05),
				0.0,
				RangeShop.C_POST,
				RangeShop.SURF_METAL
			)
			m.box(
				Vector3(0.0, 0.98, 0.0),
				Vector3(0.22, 0.44, 0.026),
				0.0,
				RangeShop.C_STEEL,
				RangeShop.SURF_METAL
			)
			m.box(
				Vector3(0.0, 0.61, -0.030),
				Vector3(0.06, 0.20, 0.020),
				0.0,
				RangeShop.C_STEEL_DARK,
				RangeShop.SURF_METAL
			)
			return shop.commit(m, "popper_body")
	)
	var head_mesh: ArrayMesh = shop.cached(
		"popper_head",
		func() -> ArrayMesh:
			var m := WorldMesher.new()
			m.box(
				Vector3(0.0, 1.55, 0.0),
				Vector3(0.125, 0.135, 0.026),
				0.0,
				RangeShop.C_STEEL,
				RangeShop.SURF_METAL
			)
			m.cylinder(
				Vector3(0.0, 1.55, 0.030),
				0.10,
				0.10,
				0.006,
				18,
				RangeShop.C_BAND,
				RangeShop.SURF_METAL
			)
			return shop.commit(m, "popper_head")
	)

	var torso := shop.prop_body("Body", &"popper", &"body")
	shop.add_mesh(torso, "Steel", body_mesh, true)
	shop.add_box_shape(torso, Vector3(0.0, 0.98, -0.015), Vector3(0.44, 0.88, 0.085))
	shop.add_box_shape(torso, Vector3(0.0, 0.27, 0.0), Vector3(0.10, 0.60, 0.10))
	hinge.add_child(torso)

	var head := shop.prop_body("Head", &"popper", &"head")
	shop.add_mesh(head, "Steel", head_mesh, true)
	shop.add_box_shape(head, Vector3(0.0, 1.55, 0.004), Vector3(0.25, 0.27, 0.068))
	hinge.add_child(head)

	node.set("swing_path", NodePath("Swing"))
	return node


func _bottle_row(parent: Node3D, distance: float, count: int) -> void:
	var rack := Node3D.new()
	rack.name = "BottleRack"
	rack.position = Vector3(0.0, 0.0, -distance)
	parent.add_child(rack)

	var m := WorldMesher.new()
	m.box(
		Vector3(0.0, 1.0, 0.0), Vector3(3.3, 0.06, 0.20), 0.0, RangeShop.C_RAIL, RangeShop.SURF_WOOD
	)
	for lx: float in [-3.0, 3.0]:
		m.box(
			Vector3(lx, 0.50, 0.0),
			Vector3(0.05, 0.55, 0.05),
			0.0,
			RangeShop.C_POST,
			RangeShop.SURF_METAL
		)
		m.box(
			Vector3(lx, 0.02, 0.0),
			Vector3(0.13, 0.05, 0.13),
			0.0,
			RangeShop.C_POST,
			RangeShop.SURF_METAL
		)
	m.box(
		Vector3(0.0, 0.62, 0.0),
		Vector3(3.0, 0.035, 0.035),
		0.0,
		RangeShop.C_POST,
		RangeShop.SURF_METAL
	)
	shop.add_mesh(rack, "Rail", shop.commit(m, "bottle_rail"), true)
	shop.adopt_shape(rack, Vector3(0.0, 1.0, 0.0), Vector3(6.6, 0.12, 0.40), &"wood")

	var body_mesh: ArrayMesh = shop.cached(
		"bottle_body",
		func() -> ArrayMesh:
			var m2 := WorldMesher.new()
			m2.cylinder(
				Vector3(0.0, 0.15, 0.0),
				0.075,
				0.055,
				0.15,
				10,
				RangeShop.C_GLASS,
				RangeShop.SURF_POLY
			)
			return shop.commit(m2, "bottle_body")
	)
	var neck_mesh: ArrayMesh = shop.cached(
		"bottle_neck",
		func() -> ArrayMesh:
			var m2 := WorldMesher.new()
			m2.cylinder(
				Vector3(0.0, 0.35, 0.0),
				0.040,
				0.028,
				0.05,
				8,
				RangeShop.C_GLASS.lightened(0.1),
				RangeShop.SURF_POLY
			)
			m2.cylinder(
				Vector3(0.0, 0.395, 0.0),
				0.030,
				0.030,
				0.012,
				8,
				RangeShop.C_BRASS,
				RangeShop.SURF_METAL
			)
			return shop.commit(m2, "bottle_neck")
	)

	var span: float = 5.6 / float(maxi(count - 1, 1))
	for i: int in count:
		var node := Node3D.new()
		node.name = "Bottle%d" % i
		# 2 cm into the rail top rather than balanced on it.
		node.position = Vector3(-2.8 + float(i) * span, 1.04, -distance)
		node.set_script(load(TARGET_SCRIPT))
		node.set("kind", 2)
		node.set("max_health", 1.0)
		node.set("points", 30)
		node.set("target_radius", 0.09)
		node.set("reset_seconds", 9.0)
		node.set("distance_hint", distance)

		var body := shop.prop_body("Glass", &"glass", &"body")
		shop.add_mesh(body, "Body", body_mesh, false)
		shop.add_cyl_shape(body, Vector3(0.0, 0.15, 0.0), 0.075, 0.30)
		node.add_child(body)

		var neck := shop.prop_body("Neck", &"glass", &"head")
		shop.add_mesh(neck, "Neck", neck_mesh, false)
		shop.add_cyl_shape(neck, Vector3(0.0, 0.36, 0.0), 0.042, 0.13)
		node.add_child(neck)
		parent.add_child(node)


func _barrel(x: float, distance: float) -> Node3D:
	var node := Node3D.new()
	node.name = "Barrel_%s_%s" % [str(int(distance)), str(int(absf(x) * 10.0))]
	# Sunk 2 cm, so the drum stands in the dirt instead of on a line drawn on it.
	node.position = Vector3(x, -0.02, -distance)
	node.set_script(load(TARGET_SCRIPT))
	node.set("kind", 3)
	node.set("max_health", 95.0)
	node.set("points", 45)
	node.set("target_radius", 0.32)
	node.set("reset_seconds", 13.0)
	node.set("distance_hint", distance)

	var warm: bool = absf(x) > 6.0
	var drum_mesh: ArrayMesh = shop.cached(
		"barrel_drum_%s" % ("a" if warm else "b"),
		func() -> ArrayMesh:
			var m := WorldMesher.new()
			var col: Color = RangeShop.C_DRUM_A if warm else RangeShop.C_DRUM_B
			m.cylinder(Vector3(0.0, 0.45, 0.0), 0.29, 0.29, 0.45, 14, col, RangeShop.SURF_METAL)
			for rib_y: float in [0.20, 0.63]:
				m.cylinder(
					Vector3(0.0, rib_y, 0.0),
					0.305,
					0.305,
					0.035,
					14,
					RangeShop.C_DRUM_RIB,
					RangeShop.SURF_METAL
				)
			m.cylinder(
				Vector3(0.0, 0.885, 0.0),
				0.30,
				0.30,
				0.025,
				14,
				RangeShop.C_DRUM_RIB,
				RangeShop.SURF_METAL
			)
			return shop.commit(m, "barrel_drum_%s" % ("a" if warm else "b"))
	)
	var cap_mesh: ArrayMesh = shop.cached(
		"barrel_cap",
		func() -> ArrayMesh:
			var m := WorldMesher.new()
			m.cylinder(
				Vector3(0.0, 0.925, 0.0),
				0.13,
				0.13,
				0.028,
				12,
				RangeShop.C_DRUM_CAP,
				RangeShop.SURF_METAL
			)
			return shop.commit(m, "barrel_cap")
	)

	var drum := shop.prop_body("Drum", &"barrel", &"body")
	shop.add_mesh(drum, "Body", drum_mesh, true)
	shop.add_cyl_shape(drum, Vector3(0.0, 0.45, 0.0), 0.30, 0.90)
	node.add_child(drum)

	var cap := shop.prop_body("Cap", &"barrel", &"head")
	shop.add_mesh(cap, "Cap", cap_mesh, true)
	shop.add_cyl_shape(cap, Vector3(0.0, 0.925, 0.0), 0.135, 0.058)
	node.add_child(cap)
	return node


func _mover(distance: float, radius: float, span: float) -> Node3D:
	var holder := Node3D.new()
	holder.name = "MoverRig"
	holder.position = Vector3(0.0, 0.0, -distance)

	var m := WorldMesher.new()
	m.box(
		Vector3(0.0, 2.75, 0.0),
		Vector3(span + 1.0, 0.06, 0.09),
		0.0,
		RangeShop.C_POST,
		RangeShop.SURF_METAL
	)
	m.box(
		Vector3(0.0, 2.60, 0.0),
		Vector3(span + 1.0, 0.035, 0.035),
		0.0,
		RangeShop.C_STEEL_DARK,
		RangeShop.SURF_METAL
	)
	for lx: float in [-(span + 0.9), span + 0.9]:
		m.box(
			Vector3(lx, 1.40, 0.0),
			Vector3(0.08, 1.42, 0.08),
			0.0,
			RangeShop.C_POST,
			RangeShop.SURF_METAL
		)
		m.strut(
			Vector3(lx, 2.70, 0.0),
			Vector3(lx * 0.72, 1.65, 0.0),
			0.035,
			RangeShop.C_POST,
			RangeShop.SURF_METAL
		)
	shop.add_mesh(holder, "Rail", shop.commit(m, "mover_rail_%s" % RangeShop.key(span)), true)

	var plate: Node3D = _plate(0.0, 0.0, radius, 260.0, true)
	plate.name = "Mover"
	plate.position = Vector3(0.0, 1.4, 0.0)
	plate.set("points", roundi(36.0 + distance * 0.9))
	plate.set("distance_hint", distance)
	plate.set("track_span", span)
	plate.set("track_speed", 1.15)
	plate.set("track_phase", _rand.next() * TAU)
	# The trolley the plate hangs off, so it is not floating under the rail.
	var tm := WorldMesher.new()
	tm.box(
		Vector3(0.0, 1.32, -0.02),
		Vector3(0.09, 0.055, 0.09),
		0.0,
		RangeShop.C_STEEL_DARK,
		RangeShop.SURF_METAL
	)
	tm.box(
		Vector3(0.0, 1.05, -0.06),
		Vector3(0.028, 0.30, 0.028),
		0.0,
		RangeShop.C_STEEL_DARK,
		RangeShop.SURF_METAL
	)
	shop.add_mesh(plate, "Hanger", shop.commit(tm, "mover_hanger"), true)
	holder.add_child(plate)
	return holder


func _paper(distance: float) -> Node3D:
	var node := Node3D.new()
	node.name = "PaperTarget"
	node.position = Vector3(0.0, 0.0, -distance)
	node.set_script(load(PAPER_SCRIPT))
	node.set("kind", 4)
	node.set("max_health", 1.0e9)
	node.set("points", 8)
	node.set("target_radius", 0.58)
	node.set("reset_seconds", 0.0)
	node.set("distance_hint", distance)
	node.set("ring_spacing", 0.077)

	var m := WorldMesher.new()
	m.box(
		Vector3(0.0, 2.02, 0.0),
		Vector3(0.68, 0.035, 0.035),
		0.0,
		RangeShop.C_RAIL,
		RangeShop.SURF_WOOD
	)
	for lx: float in [-0.62, 0.62]:
		m.box(
			Vector3(lx, 1.01, 0.0),
			Vector3(0.035, 1.02, 0.035),
			0.0,
			RangeShop.C_POST,
			RangeShop.SURF_METAL
		)
		m.box(
			Vector3(lx, 0.03, 0.0),
			Vector3(0.11, 0.05, 0.11),
			0.0,
			RangeShop.C_POST,
			RangeShop.SURF_METAL
		)
	# Backing board: the card the face is stapled to, and what you see from behind.
	m.box(
		Vector3(0.0, 1.45, 0.0),
		Vector3(0.60, 0.60, 0.012),
		0.0,
		RangeShop.C_PAPER.darkened(0.28),
		RangeShop.SURF_WOOD
	)
	shop.add_mesh(node, "Frame", shop.commit(m, "paper_frame"), true)

	var face := MeshInstance3D.new()
	face.name = "Face"
	var plane := PlaneMesh.new()
	plane.size = Vector2(1.15, 1.15)
	plane.orientation = PlaneMesh.FACE_Z
	face.mesh = plane
	face.material_override = _paper_material()
	face.position = Vector3(0.0, 1.45, 0.015)
	face.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	face.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	node.add_child(face)

	var body := shop.prop_body("Board", &"paper", &"body")
	shop.add_box_shape(body, Vector3(0.0, 1.45, 0.008), Vector3(1.20, 1.20, 0.06))
	node.add_child(body)

	node.set("face_path", NodePath("Face"))
	return node


## The printed face: nine rings at 34 px on a 512 canvas, a heavy ten ring and a
## filled X. Baked to a texture once; the scoring maths never reads it.
func _paper_material() -> Material:
	if ResourceLoader.exists(PAPER_MATERIAL_PATH):
		var existing := ResourceLoader.load(PAPER_MATERIAL_PATH, "Material") as Material
		if existing != null:
			return existing
	var size: int = 512
	var image := Image.create_empty(size, size, true, Image.FORMAT_RGB8)
	var paper := Color("e8e2d2")
	var ink := Color("2a2724")
	image.fill(paper)
	var centre: float = float(size) * 0.5
	for y: int in size:
		for x: int in size:
			var dx: float = float(x) + 0.5 - centre
			var dy: float = float(y) + 0.5 - centre
			var r: float = sqrt(dx * dx + dy * dy)
			var col: Color = paper
			# Grain, so a 1.15 m sheet does not read as flat vinyl.
			var grain: float = RangeShop.hash01(x * 131 + y * 977) * 0.05 - 0.025
			col = col.lightened(grain) if grain > 0.0 else col.darkened(-grain)
			if r <= 11.0:
				col = ink
			else:
				for ring: int in range(1, 7):
					var rr: float = float(ring) * 34.0
					var width: float = 2.5 if ring == 1 else 1.0
					if absf(r - rr) <= width:
						col = ink
						break
			image.set_pixel(x, y, col)
	image.generate_mipmaps()
	var tex := ImageTexture.create_from_image(image)
	if ResourceSaver.save(tex, PAPER_FACE_PATH) != OK:
		shop.fail("could not save %s" % PAPER_FACE_PATH)
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = tex
	mat.roughness = 0.96
	mat.metallic = 0.0
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	mat.cull_mode = BaseMaterial3D.CULL_BACK
	if ResourceSaver.save(mat, PAPER_MATERIAL_PATH) != OK:
		shop.fail("could not save %s" % PAPER_MATERIAL_PATH)
	shop.note("paper face", "%dx%d, 6 rings at 34 px" % [size, size])
	return mat
