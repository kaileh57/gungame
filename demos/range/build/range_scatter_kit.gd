class_name RangeScatterKit
extends RefCounted
## Everything loose: boulders out on the dirt, spent brass and hulls underfoot,
## tyres and wind flags down the lane, and the run of scavenged world props that
## turns the shoulders of the range from an empty plain into a junk line.
##
## BAKE-TIME ONLY. `tools/build_range.gd` is the only caller.
##
## ALL OF IT IS MULTIMESH — one draw call per kind, no shadows on anything past
## the shadow cascade, and no GI. The instance buffer is written by `MmBake`
## rather than `set_instance_transform`, which is a silent no-op under
## `--headless`.
##
## The world props come out of `res://data/world/props/props.tres`, which
## `tools/build_props.gd` already baked. Nothing here re-authors a barrel that
## the catalogue has: what this file does is decide where they stand.
##
## NOTHING MAY STAND IN FRONT OF A TARGET. A crate that hides the 140 m drum is
## a broken range, not decoration, so every placement is tested against the sight
## line to every entry in `RangeTargetKit.LAYOUT` from the shooter's own eye and
## thrown away if it falls inside one. See `_blocks_lane`.
##
## The scatter is drawn off the bake's master `XorShift32`, in this order, so the
## level is byte-identical between runs.

## Boulders out on the dirt.
const ROCK_COUNT: int = 64
## Spent brass on the firing pad. Nobody sweeps a range.
const CASING_COUNT: int = 380
## Share of the brass that piles up at a station rather than lying where it fell.
const CASING_CLUSTERED: float = 0.72
## Spent shotshell hulls, which are bigger, brighter and fewer.
const HULL_COUNT: int = 110

## Beyond this the brass is 2 cm of clutter and pure overdraw.
const BRASS_FADE_END: float = 42.0
const BRASS_FADE_MARGIN: float = 6.0
## Tyres and flags are small enough to fade too, but they read as the lane edge
## much further out than a case head does.
const SMALL_FADE_END: float = 190.0
const SMALL_FADE_MARGIN: float = 30.0

## Where the shooter's eye is when they walk in, which is the sight line every
## placement is tested against.
const EYE: Vector3 = Vector3(0.0, 1.96, 5.5)
## Slack added to every sight cone, radians. A hair over a quarter of a degree.
const SIGHT_MARGIN: float = 0.0045

## The prop catalogue, and the shape of the junk line down each shoulder.
## Columns: id, count, |x| band, z band, casts shadows.
const PROP_SCATTER: Array[Array] = [
	[&"sandbags", 34, Vector2(14.2, 21.0), Vector2(-3.0, -52.0), true],
	[&"barrel", 26, Vector2(14.5, 26.0), Vector2(-6.0, -110.0), true],
	[&"crate", 16, Vector2(14.5, 22.0), Vector2(-4.0, -60.0), true],
	[&"big_crate", 12, Vector2(15.0, 24.0), Vector2(-8.0, -80.0), true],
	[&"wall_holed", 12, Vector2(17.0, 30.0), Vector2(-30.0, -150.0), false],
	[&"wreck", 7, Vector2(19.0, 34.0), Vector2(-40.0, -210.0), false],
	[&"containers", 7, Vector2(20.0, 36.0), Vector2(-60.0, -260.0), false],
	[&"dead_tree", 22, Vector2(16.0, 38.0), Vector2(-30.0, -320.0), false],
	[&"tower", 2, Vector2(26.0, 34.0), Vector2(-130.0, -210.0), false],
]
const P_ID: int = 0
const P_COUNT: int = 1
const P_BAND_X: int = 2
const P_BAND_Z: int = 3
const P_SHADOW: int = 4

## Candidates drawn per prop before the sampler gives that one up.
const PROP_TRIES: int = 30
## Spacing between two props of any kind, metres.
const PROP_SPACING: float = 3.4

## The two runs of poles, parallel to the lane and well outside it, that put a
## man-made line on the horizon.
const POWER_LINE_X: float = 33.0
const POWER_LINE_Z: PackedFloat32Array = [-104.0, -196.0]

## The stations the brass piles up around — the same five the yard kit benches.
const STATION_X: PackedFloat32Array = [-8.4, -4.2, 0.0, 4.2, 8.4]
const STATION_Z: float = -1.0

## Where the tyres are, as [x, z, count, standing on edge rather than stacked].
## A stack is the tyres lying flat on each other, nesting a little as they do;
## on-edge means leant up against something like a wheel.
const TYRE_STACKS: Array[Array] = [
	[-13.6, -3.4, 3, false],
	[13.6, -3.4, 2, false],
	[-15.4, -11.2, 4, false],
	[15.1, -10.4, 3, false],
	[-14.2, -19.6, 2, false],
	[14.8, -21.0, 4, false],
	[-15.8, -31.0, 3, false],
	[15.6, -34.5, 2, false],
	[-10.4, 5.6, 2, false],
	[10.6, 4.4, 3, false],
	[-12.6, -6.8, 1, true],
	[12.9, -14.2, 1, true],
	[-16.1, -25.4, 1, true],
	[16.0, -42.0, 2, true],
	[-15.2, -46.5, 2, false],
	[11.9, 6.6, 1, true],
	[-6.6, 2.4, 1, false],
	[5.0, 1.3, 2, false],
]

## Wind flags on the lane-edge posts, at these distances down-range.
const FLAG_Z: PackedFloat32Array = [-12.0, -20.0, -30.0, -44.0, -62.0, -84.0, -112.0, -146.0]
const FLAG_X: float = 16.42

## Packs instance transforms straight into `MultiMesh.buffer`.
const MmBake := preload("res://tools/mm_bake.gd")

var _shop: RangeShop = null
var _rand: XorShift32 = null
var _taken: PackedVector2Array = PackedVector2Array()


func _init(workshop: RangeShop, rand: XorShift32) -> void:
	_shop = workshop
	_rand = rand


func build(root: Node3D, props: WorldPropSet) -> void:
	var scatter := Node3D.new()
	scatter.name = "Scatter"
	root.add_child(scatter)
	_rocks(scatter)
	_brass(scatter)
	_hulls(scatter)
	_tyres(scatter)
	_flags(scatter)
	_props(scatter, props)


# ================================================================ ground cover


## Rock: two cones sharing a rim, which is closed by construction and reads as a
## chipped boulder once it is scaled unevenly.
func _rocks(scatter: Node3D) -> void:
	var rm := WorldMesher.new()
	rm.cylinder(
		Vector3(0.0, -0.15, 0.0),
		0.0,
		1.0,
		0.35,
		7,
		RangeShop.C_ROCK_A,
		RangeShop.SURF_ROCK,
		Vector3.UP,
		0.0,
		false
	)
	rm.cylinder(
		Vector3(0.0, 0.45, 0.0),
		1.0,
		0.0,
		0.25,
		7,
		RangeShop.C_ROCK_A,
		RangeShop.SURF_ROCK,
		Vector3.UP,
		0.0,
		false
	)

	var rocks := MultiMesh.new()
	rocks.mesh = _shop.commit(rm, "rock")
	var rock_xf: Array[Transform3D] = []
	var rock_col := PackedColorArray()
	for i: int in ROCK_COUNT:
		var ang: float = _rand.next() * TAU
		var dist: float = 16.0 + _rand.next() * 320.0
		var x: float = sin(ang) * dist * 0.5
		var z: float = -absf(cos(ang)) * dist - 8.0
		if absf(x) < 9.0:
			x += 14.0 * signf(x if absf(x) > 0.001 else 1.0)
		var s: float = 0.30 + _rand.next() * 1.05
		var basis := Basis.from_euler(
			Vector3(_rand.next() * 0.6 - 0.3, _rand.next() * TAU, _rand.next() * 0.6 - 0.3)
		)
		basis = basis.scaled(Vector3(s, s * 0.62, s * (0.8 + _rand.next() * 0.5)))
		rock_xf.append(Transform3D(basis, Vector3(x, -0.10, z)))
		rock_col.append(
			(
				Color.WHITE.lerp(RangeShop.C_ROCK_B / RangeShop.C_ROCK_A, _rand.next())
				if i % 3 != 0
				else Color(0.86, 0.86, 0.86)
			)
		)
	MmBake.fill(rocks, rock_xf, rock_col)
	_add_mm(scatter, "Rocks", rocks, false, 0.0)


## Brass, most of it piled where somebody stood. A uniform sprinkle over 200 m2
## reads as confetti; four hundred cases with three quarters of them inside a
## metre of five bench fronts reads as a range that gets used.
func _brass(scatter: Node3D) -> void:
	var cm := WorldMesher.new()
	cm.cylinder(
		Vector3.ZERO,
		0.0046,
		0.0052,
		0.021,
		8,
		RangeShop.C_BRASS,
		RangeShop.SURF_METAL,
		Vector3.RIGHT
	)
	var casings := MultiMesh.new()
	casings.mesh = _shop.commit(cm, "casing")
	var casing_xf: Array[Transform3D] = []
	var casing_col := PackedColorArray()
	for i: int in CASING_COUNT:
		var lane_x: float = 0.0
		var lane_z: float = 0.0
		if _rand.next() < CASING_CLUSTERED:
			# Ejection throws right and forward, so a pile is not a disc.
			var s: int = int(_rand.next() * float(STATION_X.size())) % STATION_X.size()
			var spread: float = 0.35 + _rand.next() * 1.15
			lane_x = STATION_X[s] + 0.55 + (_rand.next() - 0.42) * spread * 2.2
			lane_z = STATION_Z - 0.15 - _rand.next() * spread * 1.3
		else:
			lane_x = (_rand.next() * 2.0 - 1.0) * 10.4 + 0.9
			lane_z = RangeShop.PAD_CENTER.z + (_rand.next() * 2.0 - 1.0) * 4.6
		var basis := Basis.from_euler(Vector3(0.0, _rand.next() * TAU, 0.0))
		var scale: float = 0.8 + _rand.next() * 0.55
		basis = basis.scaled(Vector3(scale, scale, scale))
		casing_xf.append(Transform3D(basis, Vector3(lane_x, RangeShop.PAD_TOP + 0.006, lane_z)))
		casing_col.append(Color.WHITE.darkened(_rand.next() * 0.35))
	MmBake.fill(casings, casing_xf, casing_col)
	_add_mm(scatter, "Brass", casings, false, BRASS_FADE_END)


## Shotshell hulls: a plastic tube and a brass head, in the three colours the
## scav loaders use. Bigger and brighter than a rifle case, so a handful of them
## does more for the floor than another two hundred rounds of brass would.
func _hulls(scatter: Node3D) -> void:
	var hm := WorldMesher.new()
	hm.cylinder(
		Vector3(0.010, 0.0, 0.0),
		0.0095,
		0.0092,
		0.026,
		6,
		Color.WHITE,
		RangeShop.SURF_POLY,
		Vector3.RIGHT
	)
	hm.cylinder(
		Vector3(-0.022, 0.0, 0.0),
		0.0098,
		0.0098,
		0.008,
		6,
		RangeShop.C_BRASS,
		RangeShop.SURF_METAL,
		Vector3.RIGHT
	)
	var hulls := MultiMesh.new()
	hulls.mesh = _shop.commit(hm, "hull")
	var tint: Array[Color] = [Color("8e3226"), Color("2f5a3a"), Color("2b3f66"), Color("6b6152")]
	var xf: Array[Transform3D] = []
	var col := PackedColorArray()
	for _i: int in HULL_COUNT:
		var s: int = int(_rand.next() * float(STATION_X.size())) % STATION_X.size()
		var x: float = STATION_X[s] + (_rand.next() - 0.35) * 3.0
		var z: float = STATION_Z - 0.1 - _rand.next() * 2.2
		if _rand.next() < 0.22:
			x = (_rand.next() * 2.0 - 1.0) * 10.2
			z = RangeShop.PAD_CENTER.z + (_rand.next() * 2.0 - 1.0) * 4.4
		var basis := Basis.from_euler(Vector3(0.0, _rand.next() * TAU, 0.0))
		xf.append(Transform3D(basis, Vector3(x, RangeShop.PAD_TOP + 0.0098, z)))
		col.append(tint[int(_rand.next() * 4.0) % 4])
	MmBake.fill(hulls, xf, col)
	_add_mm(scatter, "Hulls", hulls, false, BRASS_FADE_END)


# ================================================================== lane edges


## A tyre: two truncated cones back to back for the sidewalls and a hub down the
## middle. Three closed shells, one mesh, stacked and lain flat by the instance
## transform alone.
func _tyres(scatter: Node3D) -> void:
	var tm := WorldMesher.new()
	tm.cylinder(
		Vector3(0.0, -0.058, 0.0), 0.295, 0.355, 0.058, 10, RangeShop.C_LAMP, RangeShop.SURF_POLY
	)
	tm.cylinder(
		Vector3(0.0, 0.058, 0.0), 0.355, 0.295, 0.058, 10, RangeShop.C_LAMP, RangeShop.SURF_POLY
	)
	tm.cylinder(Vector3.ZERO, 0.175, 0.175, 0.075, 12, RangeShop.C_STEEL_DARK, RangeShop.SURF_METAL)
	var tyres := MultiMesh.new()
	tyres.mesh = _shop.commit(tm, "tyre")

	var xf: Array[Transform3D] = []
	var col := PackedColorArray()
	for stack: Array in TYRE_STACKS:
		var x: float = float(stack[0])
		var z: float = float(stack[1])
		var n: int = int(stack[2])
		var on_edge: bool = bool(stack[3])
		var ground: float = RangeShop.PAD_TOP if _on_pad(x, z) else 0.0
		for i: int in n:
			var basis := Basis(Vector3.UP, _rand.next() * TAU)
			var y: float = ground + 0.118 + float(i) * 0.196
			if on_edge:
				# Stood up like a wheel: the mesh's axis goes from +Y onto +Z.
				basis = Basis(Vector3.RIGHT, PI * 0.5) * basis
				y = ground + 0.352
			basis = Basis(Vector3.BACK, (_rand.next() - 0.5) * 0.14) * basis
			var spread: float = 0.55 if on_edge else 0.11
			var jx: float = (_rand.next() - 0.5) * spread
			var jz: float = (_rand.next() - 0.5) * spread
			xf.append(Transform3D(basis, Vector3(x + jx, y, z + jz)))
			col.append(Color.WHITE.darkened(_rand.next() * 0.22))
	MmBake.fill(tyres, xf, col)
	_add_mm(scatter, "Tyres", tyres, true, 0.0)


## Wind flags on the lane-edge posts. A range reads the wind off rags on sticks,
## and eight pairs of them down a four-hundred-metre lane is the cheapest thing
## in this file and the one that most makes the place look worked.
func _flags(scatter: Node3D) -> void:
	var fm := WorldMesher.new()
	fm.box(
		Vector3(0.0, 1.52, 0.0),
		Vector3(0.026, 1.52, 0.026),
		0.0,
		RangeShop.C_POST,
		RangeShop.SURF_METAL
	)
	fm.box(
		Vector3(0.24, 2.74, 0.0),
		Vector3(0.225, 0.155, 0.007),
		0.0,
		RangeShop.C_BAND,
		RangeShop.SURF_CLOTH
	)
	fm.box(
		Vector3(0.44, 2.52, 0.0),
		Vector3(0.125, 0.105, 0.007),
		0.26,
		RangeShop.C_SIGN,
		RangeShop.SURF_CLOTH
	)
	var flags := MultiMesh.new()
	flags.mesh = _shop.commit(fm, "wind_flag")
	var xf: Array[Transform3D] = []
	var col := PackedColorArray()
	for z: float in FLAG_Z:
		for side: int in 2:
			var sx: float = FLAG_X if side == 1 else -FLAG_X
			var yaw: float = (0.0 if side == 1 else PI) + (_rand.next() - 0.5) * 0.8
			var s: float = 0.86 + _rand.next() * 0.32
			var basis := Basis(Vector3.UP, yaw).scaled(Vector3(s, s, s))
			xf.append(Transform3D(basis, Vector3(sx, 0.0, z)))
			# Instance tint stays near white: it multiplies the pole as well as the
			# rag, so anything stronger than a bleach dyes the steel with it.
			col.append(Color.WHITE.darkened(_rand.next() * 0.26))
	MmBake.fill(flags, xf, col)
	_add_mm(scatter, "WindFlags", flags, false, SMALL_FADE_END)


# ================================================================= world props


## The junk line down both shoulders, drawn from the catalogue
## `tools/build_props.gd` already baked. One MultiMesh and one static body per
## kind: N transforms against one mesh and one trimesh, rather than N copies of
## either.
func _props(scatter: Node3D, props: WorldPropSet) -> void:
	if props == null:
		_shop.note("props", "SKIPPED — res://data/world/props/props.tres is missing")
		return
	var total: int = 0
	for rule: Array in PROP_SCATTER:
		var id: StringName = rule[P_ID]
		var asset: WorldPropAsset = props.asset(id)
		if asset == null:
			_shop.note("props", "SKIPPED %s — not in the catalogue" % id)
			continue
		var placed: Array[Transform3D] = _place(rule, asset)
		total += placed.size()
		if placed.is_empty():
			continue
		var mm := MultiMesh.new()
		mm.mesh = asset.mesh
		MmBake.fill(mm, placed)
		_add_mm(scatter, "%s_mm" % id, mm, bool(rule[P_SHADOW]), 0.0)
		_prop_body(scatter, id, asset, placed)
	total += _power_lines(scatter, props)
	_shop.note("props", "%d instances over %d kinds" % [total, PROP_SCATTER.size()])


## Rejection-sample one kind into its band. A candidate has to clear every other
## prop already down and every target sight line before it is kept.
func _place(rule: Array, asset: WorldPropAsset) -> Array[Transform3D]:
	var band_x: Vector2 = rule[P_BAND_X]
	var band_z: Vector2 = rule[P_BAND_Z]
	var radius: float = maxf(asset.bounds.size.x, asset.bounds.size.z) * 0.5
	var out: Array[Transform3D] = []
	for _i: int in int(rule[P_COUNT]):
		for _try: int in PROP_TRIES:
			var x: float = band_x.x + (band_x.y - band_x.x) * _rand.next()
			if _rand.next() < 0.5:
				x = -x
			var z: float = band_z.x + (band_z.y - band_z.x) * _rand.next()
			if _too_close(x, z):
				continue
			if _blocks_lane(x, z, radius):
				continue
			_taken.append(Vector2(x, z))
			out.append(Transform3D(Basis(Vector3.UP, _rand.next() * TAU), Vector3(x, 0.0, z)))
			break
	return out


func _too_close(x: float, z: float) -> bool:
	for p: Vector2 in _taken:
		if Vector2(x, z).distance_squared_to(p) < PROP_SPACING * PROP_SPACING:
			return true
	return false


## True when a prop of half-width `radius` standing at (x, z) would fall inside
## the cone from the shooter's eye to any target that is further away than it is.
## This is the rule that keeps the range shootable while the shoulders fill up.
func _blocks_lane(x: float, z: float, radius: float) -> bool:
	var depth: float = EYE.z - z
	if depth <= 0.5:
		return true
	var mine: float = atan2(x, depth)
	var half_mine: float = atan2(radius, depth)
	for entry: Array in RangeTargetKit.LAYOUT:
		var td: float = EYE.z + float(entry[2])
		if td <= depth:
			continue
		var theirs: float = atan2(float(entry[1]), td)
		var half_theirs: float = atan2(_target_half(entry), td)
		if absf(mine - theirs) < half_mine + half_theirs + SIGHT_MARGIN:
			return true
	return false


## Half the width a target needs kept clear, metres. Generous on purpose: what is
## being protected is the shot, not the silhouette.
static func _target_half(entry: Array) -> float:
	match String(entry[0]):
		"plate":
			return float(entry[3]) + 0.35
		"popper":
			return 0.45
		"bottles":
			return 3.5
		"paper":
			return 0.85
		"barrel":
			return 0.55
		"mover":
			return float(entry[4]) + 1.2
	return 1.0


## One body per kind, every instance a shape on the asset's shared trimesh.
func _prop_body(
	scatter: Node3D, id: StringName, asset: WorldPropAsset, placed: Array[Transform3D]
) -> void:
	if asset.shape == null:
		return
	var body := StaticBody3D.new()
	body.name = "%s_body" % id
	body.collision_layer = GameLayers.PROP
	body.collision_mask = 0
	body.set_meta(&"surface", &"metal" if id == &"containers" else &"wood")
	body.set_meta(&"zone", &"body")
	var n: int = 0
	for xf: Transform3D in placed:
		var cs := CollisionShape3D.new()
		cs.name = "%s_%02d" % [id, n]
		cs.shape = asset.shape
		cs.transform = xf
		body.add_child(cs)
		n += 1
	scatter.add_child(body)


## Two runs of poles parallel to the lane, well outside the berms' shoulder. The
## catalogue bakes a power line running along X, so each run is yawed a quarter
## turn to lie along the lane instead of across it.
func _power_lines(scatter: Node3D, props: WorldPropSet) -> int:
	var asset: WorldPropAsset = props.asset(&"power_line")
	if asset == null:
		return 0
	var xf: Array[Transform3D] = []
	for i: int in POWER_LINE_Z.size():
		var sx: float = POWER_LINE_X if i % 2 == 0 else -POWER_LINE_X
		xf.append(Transform3D(Basis(Vector3.UP, PI * 0.5), Vector3(sx, 0.0, POWER_LINE_Z[i])))
	var mm := MultiMesh.new()
	mm.mesh = asset.mesh
	MmBake.fill(mm, xf)
	_add_mm(scatter, "power_line_mm", mm, false, 0.0)
	_prop_body(scatter, &"power_line", asset, xf)
	return xf.size()


# ======================================================================= shared


func _on_pad(x: float, z: float) -> bool:
	return (
		absf(x) <= RangeShop.PAD_HALF.x and absf(z - RangeShop.PAD_CENTER.z) <= RangeShop.PAD_HALF.z
	)


func _add_mm(
	parent: Node3D, node_name: String, mm: MultiMesh, shadows: bool, fade_end: float
) -> MultiMeshInstance3D:
	var node := MultiMeshInstance3D.new()
	node.name = node_name
	node.multimesh = mm
	node.cast_shadow = (
		GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		if shadows
		else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	)
	node.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	# Every mesh in the level, catalogue prop or not, draws with the one world
	# surface material. Stating it here rather than trusting what a prop was baked
	# against is what keeps a re-baked catalogue from changing how the range looks.
	node.material_override = _shop.material
	if fade_end > 0.0:
		node.visibility_range_end = fade_end
		node.visibility_range_end_margin = (
			BRASS_FADE_MARGIN if fade_end <= BRASS_FADE_END else SMALL_FADE_MARGIN
		)
	parent.add_child(node)
	return node
