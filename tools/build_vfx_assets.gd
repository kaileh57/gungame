@tool
extends SceneTree
## Bakes every VFX asset the game ships: seven textures, seventeen materials, the
## billboard quad, the brass casing mesh and the assembled effect hub scene.
##
## Nothing in `res://systems/vfx/` generates an image, a mesh or a material at
## runtime. This script is the only place any of it is authored, it runs once
## headless, and the `.res`/`.tscn` files it writes into `res://data/vfx/` are the
## shipped artifacts. If a gradient stop here disagrees with what is on disk, the
## next bake wins.
##
## Run headless:
##   godot --headless --path <project> --script res://tools/build_vfx_assets.gd

const OUT_DIR: String = "res://data/vfx"
const SHADER_DIR: String = "res://systems/vfx/shaders"
const SCRAP_SHADER: String = "res://art/shaders/scrap_surface.gdshader"

const TEX_SPARK: String = OUT_DIR + "/tex_spark.res"
const TEX_SMOKE: String = OUT_DIR + "/tex_smoke.res"
const TEX_HOLES: String = OUT_DIR + "/tex_hole_atlas.res"
const TEX_FLASH: String = OUT_DIR + "/tex_flash.res"
const TEX_TRACER: String = OUT_DIR + "/tex_tracer.res"
const TEX_MOTE: String = OUT_DIR + "/tex_mote.res"
const TEX_SHIMMER: String = OUT_DIR + "/tex_shimmer_noise.res"

const MESH_QUAD: String = OUT_DIR + "/mesh_quad.res"
const MESH_CASING: String = OUT_DIR + "/mesh_casing.res"

const MAT_SPARK_PROC: String = OUT_DIR + "/mat_spark_process.res"
const MAT_SPARK_DRAW: String = OUT_DIR + "/mat_spark_draw.res"
const MAT_SPRAY_PROC: String = OUT_DIR + "/mat_spray_process.res"
const MAT_SPRAY_DRAW: String = OUT_DIR + "/mat_spray_draw.res"
const MAT_FINE_PROC: String = OUT_DIR + "/mat_smoke_fine_process.res"
const MAT_FINE_DRAW: String = OUT_DIR + "/mat_smoke_fine_draw.res"
const MAT_HEAVY_PROC: String = OUT_DIR + "/mat_smoke_heavy_process.res"
const MAT_HEAVY_DRAW: String = OUT_DIR + "/mat_smoke_heavy_draw.res"
const MAT_ASH_PROC: String = OUT_DIR + "/mat_ash_process.res"
const MAT_ASH_DRAW: String = OUT_DIR + "/mat_ash_draw.res"
const MAT_MOTE_PROC: String = OUT_DIR + "/mat_mote_process.res"
const MAT_MOTE_DRAW: String = OUT_DIR + "/mat_mote_draw.res"
const MAT_DECAL: String = OUT_DIR + "/mat_decal.res"
const MAT_TRACER: String = OUT_DIR + "/mat_tracer.res"
const MAT_MUZZLE: String = OUT_DIR + "/mat_muzzle.res"
const MAT_SHIMMER: String = OUT_DIR + "/mat_shimmer.res"
const MAT_SHELL: String = OUT_DIR + "/mat_shell.res"

const HUB_SCENE: String = OUT_DIR + "/vfx.tscn"

## Pool ceilings, straight from range spec 16 and the ceilings note at line 2654:
## 1000 sparks, 780 smoke sprites split 420/360, 280 decals, 30 tracers.
const CAP_SPARKS: int = 1000
const CAP_SPRAY: int = 320
const CAP_SMOKE_FINE: int = 420
const CAP_SMOKE_HEAVY: int = 360
const CAP_DECALS: int = 280
const CAP_TRACERS: int = 30
const CAP_ASH: int = 1100
const CAP_MOTES: int = 220

## Casing dimensions in metres: a 5.56-ish bottleneck case, 45 mm long over a
## 9.6 mm head. The rim is a second, wider shell overlapping the base — solids
## that overlap, never surfaces that butt.
const CASE_LENGTH: float = 0.045
const CASE_RADIUS: float = 0.0048
const RIM_LENGTH: float = 0.0055
const RIM_RADIUS: float = 0.0056
const CASE_SIDES: int = 10

## Everything a VFX pool draws is transparent, unlit and enormous in extent.
## Culling it against a tight AABB costs a recompute per write and buys nothing.
const POOL_AABB: AABB = AABB(Vector3(-600.0, -200.0, -600.0), Vector3(1200.0, 400.0, 1200.0))


func _initialize() -> void:
	build()
	quit()


static func build() -> void:
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	_bake_textures()
	_bake_meshes()
	_bake_materials()
	_bake_hub()
	print("build_vfx_assets: baked 7 textures, 2 meshes, 17 materials and vfx.tscn")


static func _save(res: Resource, path: String) -> void:
	res.resource_path = ""
	var err: Error = ResourceSaver.save(res, path)
	if err != OK:
		push_error("build_vfx_assets: could not save %s (error %d)." % [path, err])


# --- textures ---------------------------------------------------------------


## Sample a stop list at `t`. Stops are `[position, Color]` in ascending order and
## are interpolated straight in sRGB with premultiplication left alone, because
## that is how a 2D canvas gradient behaves and every stop here is copied from one.
static func _gradient(stops: Array, t: float) -> Color:
	var last: int = stops.size() - 1
	if t <= float(stops[0][0]):
		return stops[0][1]
	for i: int in last:
		var a: float = float(stops[i][0])
		var b: float = float(stops[i + 1][0])
		if t <= b:
			var k: float = 0.0 if b <= a else (t - a) / (b - a)
			return Color(stops[i][1]).lerp(Color(stops[i + 1][1]), k)
	return stops[last][1]


## Radial gradient into a square image. `radius_scale` lets a variant tile fill a
## different fraction of its cell without changing the stop list.
static func _radial(size: int, stops: Array, radius_scale: float = 1.0) -> Image:
	var img := Image.create(size, size, true, Image.FORMAT_RGBA8)
	var centre: float = float(size) * 0.5
	var inv: float = 1.0 / (centre * radius_scale)
	for y: int in size:
		for x: int in size:
			var dx: float = (float(x) + 0.5 - centre) * inv
			var dy: float = (float(y) + 0.5 - centre) * inv
			img.set_pixel(x, y, _gradient(stops, minf(sqrt(dx * dx + dy * dy), 1.0)))
	return img


static func _bake_textures() -> void:
	_bake_spark()
	_bake_smoke()
	_bake_holes()
	_bake_flash()
	_bake_tracer()
	_bake_mote()
	_bake_shimmer_noise()


## 32² radial, white 1.0 @0, 0.55 @0.4, 0 @1 (range spec 16.1).
static func _bake_spark() -> void:
	var stops: Array = [
		[0.0, Color(1, 1, 1, 1)], [0.4, Color(1, 1, 1, 0.55)], [1.0, Color(1, 1, 1, 0)]
	]
	_save(ImageTexture.create_from_image(_radial(32, stops)), TEX_SPARK)


## 64² radial, white 0.88 @0, 0.40 @0.5, 0 @1 (range spec 16.2).
static func _bake_smoke() -> void:
	var stops: Array = [
		[0.0, Color(1, 1, 1, 0.88)], [0.5, Color(1, 1, 1, 0.40)], [1.0, Color(1, 1, 1, 0)]
	]
	_save(ImageTexture.create_from_image(_radial(64, stops)), TEX_SMOKE)


## Four 64² tiles side by side: three dark hole variants and the hot steel spall.
## The reference has one of each; three dark variants stop a burst into one plate
## stamping the same silhouette twenty times over. The variants differ only in
## radius and in a low-frequency rim wobble, so they still read as one calibre.
##
## Tile edges are fully transparent — the gradients reach alpha 0 well before the
## cell boundary — so mip bleed across the atlas has nothing to carry.
static func _bake_holes() -> void:
	var dark: Array = [
		[0.0, Color8(10, 8, 7, 255)],
		[0.42, Color8(26, 22, 18, 229)],
		[1.0, Color8(40, 34, 28, 0)],
	]
	var hot: Array = [
		[0.0, Color8(236, 240, 246, 255)],
		[0.32, Color8(150, 158, 172, 153)],
		[1.0, Color8(140, 150, 164, 0)],
	]
	var tile: int = 64
	var atlas := Image.create(tile * 4, tile, true, Image.FORMAT_RGBA8)
	var rng := XorShift32.new(0x5eed_0be1)
	for t: int in 4:
		var stops: Array = hot if t == 3 else dark
		# Rim wobble: three low harmonics per tile, ±9 % of the radius.
		var h1: float = rng.next_range(0.0, TAU)
		var h2: float = rng.next_range(0.0, TAU)
		var h3: float = rng.next_range(0.0, TAU)
		var scale: float = 1.0 if t == 3 else rng.next_range(0.80, 0.96)
		var centre: float = float(tile) * 0.5
		for y: int in tile:
			for x: int in tile:
				var dx: float = float(x) + 0.5 - centre
				var dy: float = float(y) + 0.5 - centre
				var ang: float = atan2(dy, dx)
				var wob: float = (
					1.0
					+ 0.05 * sin(ang * 2.0 + h1)
					+ 0.025 * sin(ang * 3.0 + h2)
					+ 0.015 * sin(ang * 5.0 + h3)
				)
				var r: float = sqrt(dx * dx + dy * dy) / (centre * scale * wob)
				atlas.set_pixel(x + t * tile, y, _gradient(stops, minf(r, 1.0)))
	atlas.generate_mipmaps()
	_save(ImageTexture.create_from_image(atlas), TEX_HOLES)


## 64² muzzle flare: the reference's four-stop core plus seven ellipse spikes
## through the centre (range spec 16.5). The spikes are what stop a flash from
## reading as a fuzzy orange dot.
static func _bake_flash() -> void:
	var stops: Array = [
		[0.0, Color8(255, 250, 225, 255)],
		[0.25, Color8(255, 196, 110, 217)],
		[0.6, Color8(255, 140, 50, 71)],
		[1.0, Color8(255, 120, 40, 0)],
	]
	var size: int = 64
	var img: Image = _radial(size, stops)
	var rng := XorShift32.new(0x0f1a_5117)
	var spike := Color8(255, 220, 150, 128)
	var centre: float = float(size) * 0.5
	for _s: int in 7:
		var ang: float = rng.next_range(0.0, TAU)
		var half_len: float = (14.0 + rng.next_range(0.0, 17.0)) * 0.5
		var half_wid: float = 2.2
		var ca: float = cos(ang)
		var sa: float = sin(ang)
		for y: int in size:
			for x: int in size:
				var dx: float = float(x) + 0.5 - centre
				var dy: float = float(y) + 0.5 - centre
				var u: float = (dx * ca + dy * sa) / half_len
				var v: float = (-dx * sa + dy * ca) / half_wid
				if u * u + v * v > 1.0:
					continue
				var dst: Color = img.get_pixel(x, y)
				var a: float = spike.a + dst.a * (1.0 - spike.a)
				img.set_pixel(
					x,
					y,
					Color(
						(spike.r * spike.a + dst.r * dst.a * (1.0 - spike.a)) / a,
						(spike.g * spike.a + dst.g * dst.a * (1.0 - spike.a)) / a,
						(spike.b * spike.a + dst.b * dst.a * (1.0 - spike.a)) / a,
						a
					)
				)
	img.generate_mipmaps()
	_save(ImageTexture.create_from_image(img), TEX_FLASH)


## Tracer ribbon, 64 × 16. U runs tail to head along the streak, V across it.
## The cross-section is a squared cosine so the ribbon has a hot core and no hard
## edge; the taper along U puts the brightness at the head, where the round is.
static func _bake_tracer() -> void:
	var w: int = 64
	var h: int = 16
	var img := Image.create(w, h, true, Image.FORMAT_RGBA8)
	for y: int in h:
		var v: float = (float(y) + 0.5) / float(h)
		var across: float = pow(cos((v - 0.5) * PI), 2.2)
		for x: int in w:
			var u: float = (float(x) + 0.5) / float(w)
			var along: float = 0.12 + 0.88 * pow(u, 1.8)
			img.set_pixel(x, y, Color(1.0, 1.0, 1.0, clampf(across * along, 0.0, 1.0)))
	img.generate_mipmaps()
	_save(ImageTexture.create_from_image(img), TEX_TRACER)


## 16² grit mote. Soft enough not to alias into a twinkling dot at distance.
static func _bake_mote() -> void:
	var stops: Array = [
		[0.0, Color(1, 1, 1, 1)], [0.55, Color(1, 1, 1, 0.62)], [1.0, Color(1, 1, 1, 0)]
	]
	_save(ImageTexture.create_from_image(_radial(16, stops)), TEX_MOTE)


static func _lattice(ix: int, iy: int, period: int, seed_offset: int) -> float:
	var x: int = posmod(ix, period)
	var y: int = posmod(iy, period)
	var n: int = (x * 374761393 + y * 668265263 + seed_offset * 2246822519) & 0x7fffffff
	n = (n ^ (n >> 13)) * 1274126177
	return float((n ^ (n >> 16)) & 0xffff) / 65535.0


static func _tiling_value(u: float, v: float, period: int, seed_offset: int) -> float:
	var fx: float = u * float(period)
	var fy: float = v * float(period)
	var ix: int = int(floor(fx))
	var iy: int = int(floor(fy))
	var tx: float = fx - float(ix)
	var ty: float = fy - float(iy)
	tx = tx * tx * (3.0 - 2.0 * tx)
	ty = ty * ty * (3.0 - 2.0 * ty)
	var a: float = _lattice(ix, iy, period, seed_offset)
	var b: float = _lattice(ix + 1, iy, period, seed_offset)
	var c: float = _lattice(ix, iy + 1, period, seed_offset)
	var d: float = _lattice(ix + 1, iy + 1, period, seed_offset)
	return lerpf(lerpf(a, b, tx), lerpf(c, d, tx), ty)


## 64² seamless two-channel value noise for the heat-shimmer refraction. R and G
## are independent fields so the horizontal and vertical wobble never correlate
## into a diagonal shear.
static func _bake_shimmer_noise() -> void:
	var size: int = 64
	var img := Image.create(size, size, true, Image.FORMAT_RGBA8)
	for y: int in size:
		var v: float = (float(y) + 0.5) / float(size)
		for x: int in size:
			var u: float = (float(x) + 0.5) / float(size)
			var r: float = _tiling_value(u, v, 4, 1) * 0.62 + _tiling_value(u, v, 8, 2) * 0.38
			var g: float = _tiling_value(u, v, 4, 7) * 0.62 + _tiling_value(u, v, 8, 11) * 0.38
			img.set_pixel(x, y, Color(r, g, 0.5, 1.0))
	img.generate_mipmaps()
	_save(ImageTexture.create_from_image(img), TEX_SHIMMER)


# --- meshes -----------------------------------------------------------------


static func _bake_meshes() -> void:
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE
	quad.orientation = PlaneMesh.FACE_Z
	_save(quad, MESH_QUAD)
	_save(_build_casing(), MESH_CASING)


## Push one outward-wound triangle with its own face normal. Non-indexed and flat
## shaded, which is the whole project's convention for authored geometry.
##
## Callers pass a, b, c counter-clockwise about the outward direction, so the
## right-hand cross gives the outward normal. Godot's front face is CLOCKWISE, so
## the vertices go out as a, c, b — the normal is computed before the swap and is
## unaffected by it.
static func _tri(
	v: PackedVector3Array, n: PackedVector3Array, a: Vector3, b: Vector3, c: Vector3
) -> void:
	var face: Vector3 = (b - a).cross(c - a)
	if face.length_squared() < 1.0e-16:
		return
	face = face.normalized()
	v.push_back(a)
	v.push_back(c)
	v.push_back(b)
	n.push_back(face)
	n.push_back(face)
	n.push_back(face)


## A closed, capped cylinder along +Y from `y0` to `y1`. Wound so the side quads
## face outward and both caps face away from the solid.
static func _cylinder(
	v: PackedVector3Array, n: PackedVector3Array, radius: float, y0: float, y1: float, sides: int
) -> void:
	var top := Vector3(0.0, y1, 0.0)
	var bottom := Vector3(0.0, y0, 0.0)
	for i: int in sides:
		var a0: float = TAU * float(i) / float(sides)
		var a1: float = TAU * float(i + 1) / float(sides)
		var p0 := Vector3(cos(a0) * radius, y0, sin(a0) * radius)
		var p1 := Vector3(cos(a1) * radius, y0, sin(a1) * radius)
		var q0 := Vector3(p0.x, y1, p0.z)
		var q1 := Vector3(p1.x, y1, p1.z)
		_tri(v, n, p0, q0, q1)
		_tri(v, n, p0, q1, p1)
		_tri(v, n, q0, top, q1)
		_tri(v, n, p1, bottom, p0)


## A spent brass case: the body, and a wider rim shell overlapping its base by a
## third of the rim's own length. Two watertight solids that intersect — no butted
## faces, no gap at the join, and nothing an outside ray can see the inside of.
static func _build_casing() -> ArrayMesh:
	var v := PackedVector3Array()
	var n := PackedVector3Array()
	var half: float = CASE_LENGTH * 0.5
	_cylinder(v, n, CASE_RADIUS, -half, half, CASE_SIDES)
	var split: int = v.size()
	_cylinder(v, n, RIM_RADIUS, -half - RIM_LENGTH * 0.34, -half + RIM_LENGTH * 0.66, CASE_SIDES)

	var vol_body: float = _signed_volume(v, 0, split)
	var vol_rim: float = _signed_volume(v, split, v.size())
	var open_body: int = _boundary_edges(v, 0, split)
	var open_rim: int = _boundary_edges(v, split, v.size())
	print(
		(
			"build_vfx_assets: casing %d tris, shell volumes %.9f / %.9f m^3, open edges %d / %d"
			% [v.size() / 3, vol_body, vol_rim, open_body, open_rim]
		)
	)
	if vol_body <= 0.0 or vol_rim <= 0.0 or open_body != 0 or open_rim != 0:
		push_error("build_vfx_assets: casing mesh is not a pair of closed outward shells.")

	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = v
	arrays[Mesh.ARRAY_NORMAL] = n
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


## Divergence-theorem volume over a triangle range. Positive means outward winding.
static func _signed_volume(v: PackedVector3Array, from: int, to: int) -> float:
	var total: float = 0.0
	var i: int = from
	while i + 2 < to:
		total += v[i].dot(v[i + 1].cross(v[i + 2]))
		i += 3
	return total / 6.0


## Count edges used by exactly one triangle. Zero means the shell is closed.
##
## Positions are keyed as micrometre integers rather than formatted floats: a
## vertex on the -X axis lands on -0.0 through `sin`, and "-0.000000" is not
## "0.000000", which reports six phantom open edges on a perfectly closed tube.
static func _boundary_edges(v: PackedVector3Array, from: int, to: int) -> int:
	var counts: Dictionary = {}
	var i: int = from
	while i + 2 < to:
		for e: int in 3:
			var a: Vector3 = v[i + e]
			var b: Vector3 = v[i + (e + 1) % 3]
			var ka: Vector3i = Vector3i(
				int(round(a.x * 1.0e6)), int(round(a.y * 1.0e6)), int(round(a.z * 1.0e6))
			)
			var kb: Vector3i = Vector3i(
				int(round(b.x * 1.0e6)), int(round(b.y * 1.0e6)), int(round(b.z * 1.0e6))
			)
			var key: String = "%v|%v" % [ka, kb]
			var flip: String = "%v|%v" % [kb, ka]
			if counts.has(flip):
				counts[flip] = int(counts[flip]) - 1
				if int(counts[flip]) == 0:
					counts.erase(flip)
			else:
				counts[key] = int(counts.get(key, 0)) + 1
		i += 3
	var open: int = 0
	for key: String in counts:
		open += absi(int(counts[key]))
	return open


# --- materials --------------------------------------------------------------


static func _shader_material(shader_file: String) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = load(SHADER_DIR + "/" + shader_file)
	return mat


static func _bake_materials() -> void:
	var spark_tex: Texture2D = load(TEX_SPARK)
	var smoke_tex: Texture2D = load(TEX_SMOKE)

	var spark_proc := _shader_material("spark_process.gdshader")
	spark_proc.set_shader_parameter("particle_size", 0.055)
	_save(spark_proc, MAT_SPARK_PROC)

	var spark_draw := _shader_material("spark_draw.gdshader")
	spark_draw.set_shader_parameter("spark_tex", spark_tex)
	spark_draw.set_shader_parameter("brightness", 1.4)
	_save(spark_draw, MAT_SPARK_DRAW)

	# Wet debris shares the spark integrator and differs only in how it is drawn:
	# a droplet occludes, it does not glow. Bigger, because blood is not a spark.
	var spray_proc := _shader_material("spark_process.gdshader")
	spray_proc.set_shader_parameter("particle_size", 0.038)
	spray_proc.set_shader_parameter("bounce_keep_horizontal", 0.18)
	spray_proc.set_shader_parameter("bounce_keep_vertical", 0.08)
	_save(spray_proc, MAT_SPRAY_PROC)

	var spray_draw := _shader_material("spray_draw.gdshader")
	spray_draw.set_shader_parameter("spark_tex", spark_tex)
	spray_draw.set_shader_parameter("darken", 0.45)
	_save(spray_draw, MAT_SPRAY_DRAW)

	var fine_proc := _shader_material("smoke_process.gdshader")
	fine_proc.set_shader_parameter("particle_size", 0.62)
	_save(fine_proc, MAT_FINE_PROC)

	var fine_draw := _shader_material("smoke_draw.gdshader")
	fine_draw.set_shader_parameter("smoke_tex", smoke_tex)
	fine_draw.set_shader_parameter("opacity", 0.50)
	_save(fine_draw, MAT_FINE_DRAW)

	var heavy_proc := _shader_material("smoke_process.gdshader")
	heavy_proc.set_shader_parameter("particle_size", 2.10)
	_save(heavy_proc, MAT_HEAVY_PROC)

	var heavy_draw := _shader_material("smoke_draw.gdshader")
	heavy_draw.set_shader_parameter("smoke_tex", smoke_tex)
	heavy_draw.set_shader_parameter("opacity", 0.40)
	heavy_draw.set_shader_parameter("grow", 0.85)
	_save(heavy_draw, MAT_HEAVY_DRAW)

	var ash_proc := _shader_material("ash_process.gdshader")
	ash_proc.set_shader_parameter("particle_size", 0.042)
	ash_proc.set_shader_parameter("mote_color", Palette.TIMBER.lerp(Palette.BONE, 0.45))
	_save(ash_proc, MAT_ASH_PROC)

	var ash_draw := _shader_material("ash_draw.gdshader")
	ash_draw.set_shader_parameter("mote_tex", load(TEX_MOTE))
	ash_draw.set_shader_parameter("opacity", 0.30)
	_save(ash_draw, MAT_ASH_DRAW)

	# Dust motes are the same field wound tight around the eye and barely moving:
	# the specks you only see because the sun is behind them.
	var mote_proc := _shader_material("ash_process.gdshader")
	mote_proc.set_shader_parameter("particle_size", 0.014)
	mote_proc.set_shader_parameter("wrap_radius", 7.0)
	mote_proc.set_shader_parameter("band_bottom", -1.6)
	mote_proc.set_shader_parameter("band_top", 3.4)
	mote_proc.set_shader_parameter("wind_base", Vector2(0.34, -0.2))
	mote_proc.set_shader_parameter("mote_color", Palette.BONE)
	_save(mote_proc, MAT_MOTE_PROC)

	var mote_draw := _shader_material("ash_draw.gdshader")
	mote_draw.set_shader_parameter("mote_tex", load(TEX_MOTE))
	mote_draw.set_shader_parameter("opacity", 0.22)
	mote_draw.set_shader_parameter("near_fade", 0.45)
	_save(mote_draw, MAT_MOTE_DRAW)

	var decal := _shader_material("decal.gdshader")
	decal.set_shader_parameter("hole_atlas", load(TEX_HOLES))
	decal.set_shader_parameter("tile_count", 4.0)
	decal.render_priority = 3
	_save(decal, MAT_DECAL)

	var tracer := _shader_material("tracer.gdshader")
	tracer.set_shader_parameter("tracer_tex", load(TEX_TRACER))
	tracer.set_shader_parameter("tracer_color", Color8(255, 224, 176))
	tracer.set_shader_parameter("peak_alpha", 0.5)
	_save(tracer, MAT_TRACER)

	var muzzle := _shader_material("muzzle_flash.gdshader")
	muzzle.set_shader_parameter("flash_tex", load(TEX_FLASH))
	muzzle.set_shader_parameter("brightness", 3.2)
	muzzle.render_priority = 4
	_save(muzzle, MAT_MUZZLE)

	var shimmer := _shader_material("heat_shimmer.gdshader")
	shimmer.set_shader_parameter("noise_tex", load(TEX_SHIMMER))
	shimmer.set_shader_parameter("strength", 0.008)
	_save(shimmer, MAT_SHIMMER)

	# Spent brass: the shared scrap steel branch, retinted, low roughness, and a
	# fine bump because a case is 45 mm long and the world detail scale would put
	# one noise cell across the whole thing.
	var shell := ShaderMaterial.new()
	shell.shader = load(SCRAP_SHADER)
	shell.set_shader_parameter("surface_type", Palette.Surface.STEEL)
	shell.set_shader_parameter("albedo", Color8(176, 132, 62))
	shell.set_shader_parameter("metallic_base", 0.92)
	shell.set_shader_parameter("roughness_base", 0.28)
	shell.set_shader_parameter("detail_scale", 44.0)
	shell.set_shader_parameter("bump_scale", 120.0)
	shell.set_shader_parameter("bump_amount", 0.004)
	_save(shell, MAT_SHELL)


# --- the hub scene ----------------------------------------------------------


static func _multimesh(mesh_path: String, slots: int) -> MultiMesh:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	mm.mesh = load(mesh_path)
	mm.instance_count = slots
	return mm


static func _particles(
	node: GPUParticles3D, process_path: String, draw_path: String, slots: int
) -> void:
	node.amount = slots
	node.lifetime = 60.0
	node.one_shot = false
	node.explosiveness = 0.0
	node.local_coords = false
	node.emitting = true
	node.draw_order = GPUParticles3D.DRAW_ORDER_VIEW_DEPTH
	node.process_material = load(process_path)
	node.draw_pass_1 = load(MESH_QUAD)
	node.material_override = load(draw_path)
	node.visibility_aabb = POOL_AABB
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


static func _bake_hub() -> void:
	var spark_script: Script = load("res://systems/vfx/vfx_spark_field.gd")
	var smoke_script: Script = load("res://systems/vfx/vfx_smoke_field.gd")
	var ash_script: Script = load("res://systems/vfx/vfx_ash_field.gd")

	var root := Node3D.new()
	root.name = "Vfx"
	root.set_script(load("res://systems/vfx/vfx_service.gd"))

	var sparks := GPUParticles3D.new()
	sparks.name = "Sparks"
	sparks.set_script(spark_script)
	_particles(sparks, MAT_SPARK_PROC, MAT_SPARK_DRAW, CAP_SPARKS)
	sparks.set("particle_size", 0.055)

	var spray := GPUParticles3D.new()
	spray.name = "Spray"
	spray.set_script(spark_script)
	_particles(spray, MAT_SPRAY_PROC, MAT_SPRAY_DRAW, CAP_SPRAY)
	spray.set("particle_size", 0.038)
	spray.set("particle_alpha", 0.85)
	spray.set("rng_seed", 0x1a77ee)

	var fine := GPUParticles3D.new()
	fine.name = "SmokeFine"
	fine.set_script(smoke_script)
	_particles(fine, MAT_FINE_PROC, MAT_FINE_DRAW, CAP_SMOKE_FINE)
	fine.set("particle_size", 0.62)
	fine.set("near_cull_squared", 38.0)

	var heavy := GPUParticles3D.new()
	heavy.name = "SmokeHeavy"
	heavy.set_script(smoke_script)
	_particles(heavy, MAT_HEAVY_PROC, MAT_HEAVY_DRAW, CAP_SMOKE_HEAVY)
	heavy.set("particle_size", 2.10)
	heavy.set("near_cull_squared", 150.0)
	heavy.set("rng_seed", 0x39b201)

	var ash := GPUParticles3D.new()
	ash.name = "Ash"
	ash.set_script(ash_script)
	_particles(ash, MAT_ASH_PROC, MAT_ASH_DRAW, CAP_ASH)
	ash.explosiveness = 1.0
	ash.lifetime = 3600.0
	ash.set("motes", CAP_ASH)

	var motes := GPUParticles3D.new()
	motes.name = "Motes"
	motes.set_script(ash_script)
	_particles(motes, MAT_MOTE_PROC, MAT_MOTE_DRAW, CAP_MOTES)
	motes.explosiveness = 1.0
	motes.lifetime = 3600.0
	motes.set("motes", CAP_MOTES)
	motes.set("wrap_radius", 7.0)
	motes.set("band_bottom", -1.6)
	motes.set("band_top", 3.4)

	var decals := MultiMeshInstance3D.new()
	decals.name = "Decals"
	decals.set_script(load("res://systems/vfx/vfx_decal_pool.gd"))
	decals.multimesh = _multimesh(MESH_QUAD, CAP_DECALS)
	decals.material_override = load(MAT_DECAL)
	decals.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	decals.custom_aabb = POOL_AABB

	var tracers := MultiMeshInstance3D.new()
	tracers.name = "Tracers"
	tracers.set_script(load("res://systems/vfx/vfx_tracer_pool.gd"))
	tracers.multimesh = _multimesh(MESH_QUAD, CAP_TRACERS)
	tracers.material_override = load(MAT_TRACER)
	tracers.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	tracers.custom_aabb = POOL_AABB

	var shells := MultiMeshInstance3D.new()
	shells.name = "Shells"
	shells.set_script(load("res://systems/vfx/vfx_shell_eject.gd"))
	shells.multimesh = _multimesh(MESH_CASING, 32)
	shells.material_override = load(MAT_SHELL)
	shells.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	shells.custom_aabb = POOL_AABB

	var muzzles := Node3D.new()
	muzzles.name = "Muzzles"
	muzzles.set_script(load("res://systems/vfx/vfx_muzzle.gd"))
	muzzles.set("flash_mesh", load(MESH_QUAD))
	muzzles.set("flash_material", load(MAT_MUZZLE))

	var blasts := Node3D.new()
	blasts.name = "Blasts"
	blasts.set_script(load("res://systems/vfx/vfx_explosion.gd"))
	blasts.set("shimmer_mesh", load(MESH_QUAD))
	blasts.set("shimmer_material", load(MAT_SHIMMER))

	for child: Node in [
		sparks, spray, fine, heavy, ash, motes, decals, tracers, shells, muzzles, blasts
	]:
		root.add_child(child)
		child.owner = root

	var packed := PackedScene.new()
	var err: Error = packed.pack(root)
	if err != OK:
		push_error("build_vfx_assets: packing the hub failed (error %d)." % err)
		root.free()
		return
	_save(packed, HUB_SCENE)
	root.free()
