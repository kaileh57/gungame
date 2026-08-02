extends RefCounted
## The receiver plate the magazine count is scratched on, and the ring that draws
## itself around that count while you are clearing a stoppage.
##
## BAKE-TIME ONLY. `tools/build_range.gd` is the only caller. It writes
## `res://demos/range/ammo_counter.tscn`, which `WeaponHolster` hangs off its own
## `Hand` node in every armed level — so this one bake is the ammunition readout
## for the whole game, not just for the range.
##
## NO `class_name` HERE, deliberately, for the same reason as the other kits beside
## this file: a global class added to the project stays invisible to a `--script`
## main loop until the editor rescans and rewrites the class cache, so a headless
## bake that named one would fail on a clean checkout. The builder preloads this
## file by path, which needs no cache at all.
##
## WHY THE RING EXISTS. A jammed action showed `JAM` and nothing else, and clearing
## it takes anywhere from 0.4 s to 4.2 s depending on the weapon's grading and how
## badly it bound — so holding reload on a bad gun read as "the gun is broken and
## will not unjam" rather than as "this is a four-second stoppage". The number was
## always correct; the player just had no way to see it running. The ring is that
## number, drawn in the one place the eye is already pointed.
##
## FOUR BARS, NOT A SWEPT ARC. Each side of the ring is one box whose ORIGIN sits at
## the end the fill starts from and whose geometry runs out along its own +X, so the
## fill is a single `scale.x` per side and nothing rebuilds, re-uploads or shades per
## frame. Four draw calls and a dim track behind them is the whole cost.

## Half-extents of the plate face the numbers are stencilled into.
const FACE_HALF: Vector3 = Vector3(0.052, 0.030, 0.004)
## The surround, and how far behind the face it sits.
const BEZEL_HALF: Vector3 = Vector3(0.056, 0.034, 0.004)
const BEZEL_Z: float = -0.003

## Centre-line of the ring, which runs in the four-millimetre gutter between the
## face and the edge of the surround. Both radii are pulled in far enough that the
## bar's OUTER face stays a fifth of a millimetre inside the bezel's: flush would be
## coplanar, and coplanar is what z-fights.
const RING_HALF_W: float = 0.0536
const RING_HALF_H: float = 0.0316
## Half-thickness of a bar across the ring. At this width the inner edge overlaps
## the face by 0.6 mm, so the ring is welded to the plate rather than resting on it.
const RING_HALF_T: float = 0.0022
## The ring stands a millimetre proud of the face and reaches back a millimetre into
## the surround. The back overlap is the point: a bar that merely touched the bezel
## would be an air gap the moment anything moved.
const RING_Z: float = 0.002
const RING_HALF_Z: float = 0.003

## Track colour. Dark enough to read as a machined channel rather than as a fifth
## bar that never fills.
const TRACK_COLOR: Color = Color(0.106, 0.098, 0.086)
## Fill colour. The band orange off the range palette — the same hue the target
## bands use, which is this level's colour for "working".
const FILL_COLOR: Color = Color(0.761, 0.353, 0.204)

## Where a receiver plate sits relative to the holster hand: left of the breech,
## canted toward the eye so it is legible without breaking the sight line.
##
## THE AIM IS SOLVED, NOT GUESSED. In the hand's own frame the bore runs along +X
## and the eye sits at (-0.466, 0.142, -0.089) — that is, almost directly BEHIND the
## breech and only nine centimetres off to the side. A plate lying along the receiver
## flank therefore presents its edge to the shooter, and a plate at the old 0.40 rad
## presented its BACK: `Count` and `Capacity` are `double_sided = false`, so the
## numbers vanished and what the viewmodel put in front of the eye was the blank rear
## face of the mount — a 10 cm sheet of sky-reflecting steel, the brightest and
## flattest thing on screen, sitting over the gun. These two angles point the plate's
## +Z at that eye position. The counter is also stood down to three quarters: aimed
## square on, the full plate is a billboard rather than something welded to a gun.
const MOUNT_AT: Vector3 = Vector3(-0.062, 0.010, -0.056)
const MOUNT_ROT: Vector3 = Vector3(-0.315, -1.652, 0.06)
const MOUNT_SCALE: float = 0.72


## Bake the counter and save it. Returns false if anything failed, which the
## builder's own report already carries through `shop.fail`.
static func build(shop: RangeShop, script_path: String, scene_path: String) -> bool:
	var root := Node3D.new()
	root.name = "AmmoCounter"
	root.set_script(load(script_path))

	_plate(shop, root)
	_labels(root)
	_ring(shop, root)
	root.set("ring_shares", shares())

	root.position = MOUNT_AT
	root.rotation = MOUNT_ROT
	root.scale = Vector3.ONE * MOUNT_SCALE

	shop.own_all(root, root)
	var ok: bool = true
	var packed := PackedScene.new()
	if packed.pack(root) != OK:
		shop.fail("could not pack the ammo counter")
		ok = false
	elif ResourceSaver.save(packed, scene_path) != OK:
		shop.fail("could not save %s" % scene_path)
		ok = false
	else:
		shop.note("ammo counter", scene_path)
	root.free()
	return ok


## Fraction of the whole ring each side spans, in sweep order: top, right, bottom,
## left. Derived from the ring's own dimensions rather than written down, so the
## fill cannot drift from the geometry if a radius is ever retuned.
static func shares() -> PackedFloat32Array:
	var w: float = RING_HALF_W * 2.0
	var h: float = RING_HALF_H * 2.0
	var perimeter: float = maxf((w + h) * 2.0, 0.0001)
	var sw: float = w / perimeter
	var sh: float = h / perimeter
	return PackedFloat32Array([sw, sh, sw, sh])


static func _plate(shop: RangeShop, root: Node3D) -> void:
	var m := WorldMesher.new()
	m.box(Vector3.ZERO, FACE_HALF, 0.0, RangeShop.C_LAMP, RangeShop.SURF_METAL)
	# The surround. Darkened hard off `C_STEEL_DARK`: the world material gives steel
	# 0.66 metallic, so on the viewmodel pass — where the only thing there is to
	# reflect is an open desert sky — a mid-grey bezel comes back as a bright chrome
	# frame around the numbers and reads as screen furniture rather than as a plate
	# someone welded on.
	m.box(
		Vector3(0.0, 0.0, BEZEL_Z),
		BEZEL_HALF,
		0.0,
		RangeShop.C_STEEL_DARK.darkened(0.55),
		RangeShop.SURF_METAL
	)
	var plate := MeshInstance3D.new()
	plate.name = "Plate"
	plate.mesh = shop.commit(m, "ammo_plate")
	plate.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	plate.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	root.add_child(plate)


static func _labels(root: Node3D) -> void:
	var font: Font = ResourceLoader.load(RangeShop.FONT_DISPLAY, "Font") as Font
	root.add_child(_label("Count", "0", font, 64, 0.00062, Vector3(-0.012, 0.0, 0.006)))
	var capacity := _label("Capacity", "/0", font, 40, 0.00052, Vector3(0.026, -0.008, 0.006))
	capacity.modulate = Color(0.51, 0.482, 0.435)
	root.add_child(capacity)


static func _label(
	node_name: String, text: String, font: Font, size: int, pixels: float, at: Vector3
) -> Label3D:
	var label := Label3D.new()
	label.name = node_name
	label.text = text
	label.font = font
	label.font_size = size
	label.pixel_size = pixels
	label.position = at
	label.shaded = false
	label.double_sided = false
	label.no_depth_test = false
	return label


## The stoppage-clearing ring: a dim closed track, and four fill bars laid over it.
##
## The four bars are ONE pair of meshes between them — a horizontal bar and a
## vertical one — instanced four times and turned by the node rather than baked four
## times at four angles. Each is authored running from the local origin out along +X,
## so the node's own position puts that origin on the corner the side starts at and
## `scale.x` is the fill.
static func _ring(shop: RangeShop, root: Node3D) -> void:
	var ring := Node3D.new()
	ring.name = "ClearRing"
	ring.visible = false
	root.add_child(ring)

	var track := WorldMesher.new()
	var span_x: float = RING_HALF_W + RING_HALF_T
	for sy: float in [1.0, -1.0]:
		track.box(
			Vector3(0.0, RING_HALF_H * sy, RING_Z),
			Vector3(span_x, RING_HALF_T, RING_HALF_Z),
			0.0,
			TRACK_COLOR,
			RangeShop.SURF_METAL
		)
	for sx: float in [1.0, -1.0]:
		track.box(
			Vector3(RING_HALF_W * sx, 0.0, RING_Z),
			Vector3(RING_HALF_T, RING_HALF_H - RING_HALF_T, RING_HALF_Z),
			0.0,
			TRACK_COLOR,
			RangeShop.SURF_METAL
		)
	var track_node := MeshInstance3D.new()
	track_node.name = "Track"
	track_node.mesh = shop.commit(track, "ammo_ring_track")
	track_node.material_override = _flat(TRACK_COLOR, 0.0)
	track_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	track_node.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	ring.add_child(track_node)

	var bar_h: ArrayMesh = _bar(shop, "ammo_ring_h", RING_HALF_W * 2.0)
	var bar_v: ArrayMesh = _bar(shop, "ammo_ring_v", RING_HALF_H * 2.0)
	var fill := _flat(FILL_COLOR, 1.4)
	# Sweep order, clockwise from the top-left corner: along the top, down the right,
	# back along the bottom, up the left. Reading order, so the ring closes where the
	# eye expects a countdown to end.
	var sides: Array[Array] = [
		[bar_h, Vector3(-RING_HALF_W, RING_HALF_H, 0.0), 0.0],
		[bar_v, Vector3(RING_HALF_W, RING_HALF_H, 0.0), -PI * 0.5],
		[bar_h, Vector3(RING_HALF_W, -RING_HALF_H, 0.0), PI],
		[bar_v, Vector3(-RING_HALF_W, -RING_HALF_H, 0.0), PI * 0.5],
	]
	for i: int in sides.size():
		var side: Array = sides[i]
		var node := MeshInstance3D.new()
		node.name = "Fill%d" % i
		node.mesh = side[0] as ArrayMesh
		node.position = side[1] as Vector3
		node.rotation = Vector3(0.0, 0.0, float(side[2]))
		node.material_override = fill
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		node.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
		node.visible = false
		ring.add_child(node)


## One fill bar, running from the local origin out along +X.
static func _bar(shop: RangeShop, mesh_name: String, length: float) -> ArrayMesh:
	var m := WorldMesher.new()
	m.box(
		Vector3(length * 0.5, 0.0, RING_Z),
		Vector3(length * 0.5, RING_HALF_T, RING_HALF_Z),
		0.0,
		FILL_COLOR,
		RangeShop.SURF_METAL
	)
	return shop.commit(m, mesh_name)


## Unshaded, because the ring has to read the same whether the gun is in the sun on
## the range or under the bay roof, and because the world surface shader would give
## a 2 mm bar the same sky reflection that made the bezel look like chrome.
static func _flat(color: Color, glow: float) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = color
	mat.disable_receive_shadows = true
	if glow > 0.0:
		mat.emission_enabled = true
		mat.emission = color
		mat.emission_energy_multiplier = glow
	return mat
