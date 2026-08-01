class_name TerrainField
extends RefCounted
## The analytic height field: `terrainH`, the warped sampling axis, and the
## bilinear `groundH` that reads back off it.
##
## This is the bake-time authority. Nothing at runtime should construct one — the
## 40401-sample height grid costs ~360k fbm evaluations to fill. The bake writes
## it into a `WorldTerrainData` resource and the game reads that.

## Radius of the flattened pan the town sits in, metres.
const TOWN_R: float = 132.0
## Height the pan is levelled toward.
const PAN_HEIGHT: float = 0.0

## Samples per axis. 200 quads, 201 vertices, 80000 triangles at full resolution.
const TN: int = 200
## Half-extent of the sampled axis, metres. The mesh spans [-880, +880].
const TW: float = 880.0
## Linear share of the axis warp. The remaining 58 % is a quintic, which packs
## 3.7 m cells into the town and stretches them to 29 m at the rim.
const TA: float = 0.42

## x, z, radius, plateau height, plateau-start fraction — five floats per mesa.
const MESAS: PackedFloat32Array = [
	300.0,
	-40.0,
	118.0,
	46.0,
	0.62,
	258.0,
	168.0,
	74.0,
	33.0,
	0.55,
	348.0,
	210.0,
	88.0,
	40.0,
	0.60,
	-286.0,
	-238.0,
	62.0,
	27.0,
	0.50,
	214.0,
	-282.0,
	70.0,
	31.0,
	0.55,
]

## Sampling epsilon for `ground_normal`, metres.
const NORMAL_EPS: float = 1.2
## Sampling epsilon for `terrain_n`, the analytic normal. Deliberately tighter
## than `NORMAL_EPS`: it differentiates the field itself rather than the mesh.
const TERRAIN_N_EPS: float = 0.9

## Slope at which the ground starts reading as rock, and where it is fully rock.
const ROCK_SLOPE_LO: float = 0.50
const ROCK_SLOPE_HI: float = 0.95
## Height band that adds up to 0.8 of rock on its own, so mesa caps are stone
## even where they are flat.
const ROCK_HEIGHT_LO: float = 13.0
const ROCK_HEIGHT_HI: float = 24.0
const ROCK_HEIGHT_GAIN: float = 0.8
## Sum of the four corner rock masks above which a quad is emitted as ROCK.
const QUAD_ROCK_THRESHOLD: float = 2.0

## Gravel is painted this far either side of the wadi centre line, and only
## below this height — above it the channel has climbed out of its own bed.
const GRAVEL_HALF_W: float = 16.0
const GRAVEL_MAX_H: float = 6.0

## Road paint is only tested inside this box. Outside it there are no streets,
## and `dist_to_road` is linear in the road count.
const ROAD_BOUND_X: float = 175.0
const ROAD_BOUND_Z: float = 210.0
## Above this much rock the ground is too broken to have been graded.
const ROAD_MAX_ROCK: float = 0.5

var noise: WorldNoise
var _ax: PackedFloat32Array
var _hg: PackedFloat32Array


func _init(world_seed: int) -> void:
	noise = WorldNoise.new(world_seed)
	_build_axis()
	_build_grid()


## Dry-river centre line: the x of the wadi as a function of z.
static func wadi_x(z: float) -> float:
	return z * 0.62 - 34.0 + sin(z * 0.019) * 26.0 + sin(z * 0.0071 + 2.0) * 44.0


func _build_axis() -> void:
	_ax = PackedFloat32Array()
	_ax.resize(TN + 1)
	for i in TN + 1:
		var u: float = float(i) / float(TN) * 2.0 - 1.0
		var s: float = signf(u)
		if s == 0.0:
			s = 1.0
		var a: float = absf(u)
		_ax[i] = TW * (TA * u + (1.0 - TA) * s * pow(a, 5.0))


func _build_grid() -> void:
	var w: int = TN + 1
	_hg = PackedFloat32Array()
	_hg.resize(w * w)
	for j in w:
		var z: float = _ax[j]
		var row: int = j * w
		for i in w:
			_hg[row + i] = terrain_h(_ax[i], z)


func axis() -> PackedFloat32Array:
	return _ax


func heights() -> PackedFloat32Array:
	return _hg


## The authoritative height function. Every term is transcribed from the
## reference; the detail fade in front of the high-frequency terms is what stops
## the coarse rim cells aliasing into a diamond hatch.
func terrain_h(x: float, z: float) -> float:
	var d: float = sqrt(x * x + z * z)
	var detail: float = 1.0 - smoothstep(170.0, 400.0, d)

	var h: float = noise.fbm2(x * 0.0032 + 11.0, z * 0.0032 - 7.0, 4) * 26.0 - 9.0
	h += noise.fbm2(x * 0.011 - 3.0, z * 0.011 + 5.0, 3) * 5.5 * (0.25 + 0.75 * detail)

	# Dunes rise outside the town and bias south and west. The smoothstep runs
	# descending on purpose: the mask grows as z*0.8 + x*0.3 goes negative.
	var dune_mask: float = (
		smoothstep(TOWN_R - 6.0, TOWN_R + 150.0, d)
		* (0.45 + 0.55 * smoothstep(-40.0, -300.0, z * 0.8 + x * 0.3))
	)
	var dn: float = noise.ridged(x * 0.0072 + 31.0, z * 0.0043 - 17.0, 4)
	h += dn * dn * 30.0 * dune_mask
	h += noise.ridged(x * 0.021, z * 0.013 + 9.0, 2) * 2.4 * dune_mask * detail

	for m in 5:
		var b: int = m * 5
		var mx: float = MESAS[b]
		var mz: float = MESAS[b + 1]
		var mr: float = MESAS[b + 2]
		var mh: float = MESAS[b + 3]
		var ms: float = MESAS[b + 4]
		var md: float = sqrt((x - mx) * (x - mx) + (z - mz) * (z - mz)) / mr
		var wob: float = (
			1.0 + (noise.fbm2(x * 0.02 + mx, z * 0.02 - mz, 3) - 0.5) * 0.30 * (0.2 + 0.8 * detail)
		)
		var t: float = 1.0 - smoothstep(ms * wob, 1.0 * wob, md)
		h += mh * pow(t, 0.55)

	# The pan. Weight 0.985 rather than 1.0 leaves 1.5 % of the wild terrain in,
	# so the town floor is level without being dead flat.
	var pan: float = 1.0 - smoothstep(TOWN_R * 0.52, TOWN_R * 1.34, d)
	h = lerpf(h, PAN_HEIGHT + noise.fbm2(x * 0.03, z * 0.03, 2) * 1.5 - 0.75, pan * 0.985)

	var wd: float = absf(x - wadi_x(z))
	var bank: float = 1.0 - smoothstep(9.0, 32.0, wd)
	h -= 5.2 * bank * bank * (0.65 + 0.35 * smoothstep(0.0, 40.0, absf(z)))
	if wd < 11.0:
		h += (noise.fbm2(x * 0.09, z * 0.09, 2) - 0.5) * 0.6

	# The graded rim road north of z = -60. Note the band centre is
	# x = -8 - sin(z*0.008)*18, from the abs() of (x + 8 + sin(...)*18).
	var road_t: float = 1.0 - smoothstep(6.5, 13.0, absf(x + 8.0 + sin(z * 0.008) * 18.0))
	if z < -60.0:
		h = lerpf(h, h * 0.55 + 1.2, road_t * smoothstep(-60.0, -110.0, z) * 0.9)

	return h


## Index of the axis cell containing `v`, clamped to [0, TN-1].
func ax_index(v: float) -> int:
	if v <= _ax[0]:
		return 0
	if v >= _ax[TN]:
		return TN - 1
	var lo: int = 0
	var hi: int = TN
	while hi - lo > 1:
		var m: int = (lo + hi) >> 1
		if _ax[m] <= v:
			lo = m
		else:
			hi = m
	return lo


## Exact height on the rendered surface. The quad (i,j)..(i+1,j+1) is split along
## its a-c diagonal, which is the split the mesher actually emits — the reference
## interpolated the other diagonal and let the player float by up to a metre on
## the coarse rim cells.
func ground_h(x: float, z: float) -> float:
	if x <= _ax[0] or x >= _ax[TN] or z <= _ax[0] or z >= _ax[TN]:
		return terrain_h(x, z)
	var i: int = ax_index(x)
	var j: int = ax_index(z)
	var s: float = (x - _ax[i]) / (_ax[i + 1] - _ax[i])
	var t: float = (z - _ax[j]) / (_ax[j + 1] - _ax[j])
	var w: int = TN + 1
	var h00: float = _hg[j * w + i]
	var h10: float = _hg[j * w + i + 1]
	var h01: float = _hg[(j + 1) * w + i]
	var h11: float = _hg[(j + 1) * w + i + 1]
	if t >= s:
		return h00 + (h01 - h00) * t + (h11 - h01) * s
	return h00 + (h10 - h00) * s + (h11 - h10) * t


## Surface normal of the rendered terrain, sampled with a 1.2 m cross.
func ground_normal(x: float, z: float, e: float = NORMAL_EPS) -> Vector3:
	var hl: float = ground_h(x - e, z)
	var hr: float = ground_h(x + e, z)
	var hd: float = ground_h(x, z - e)
	var hu: float = ground_h(x, z + e)
	return Vector3(hl - hr, 2.0 * e, hd - hu).normalized()


## Normal of the analytic field rather than of the rendered mesh, on a 0.9 m
## cross. The two agree to within the grid's own curvature; the bake compares
## them and reports the worst disagreement, which is how a broken axis warp or a
## mis-sampled grid announces itself.
func terrain_n(x: float, z: float, e: float = TERRAIN_N_EPS) -> Vector3:
	var hl: float = terrain_h(x - e, z)
	var hr: float = terrain_h(x + e, z)
	var hd: float = terrain_h(x, z - e)
	var hu: float = terrain_h(x, z + e)
	return Vector3(hl - hr, 2.0 * e, hd - hu).normalized()


## Rock mask at every grid intersection, 0 sand to 1 stone.
##
## Slope is measured as a central difference over the warped axis, so the rim's
## 29 m cells report the gradient they actually render at rather than the one a
## uniform grid would infer. The height term is what makes the mesa caps stone.
func rock_grid() -> PackedFloat32Array:
	var w: int = TN + 1
	var vk := PackedFloat32Array()
	vk.resize(w * w)
	for j in w:
		var jd: int = maxi(0, j - 1)
		var ju: int = mini(TN, j + 1)
		var dz: float = maxf(_ax[ju] - _ax[jd], 1.0e-3)
		for i in w:
			var il: int = maxi(0, i - 1)
			var ir: int = mini(TN, i + 1)
			var dx: float = maxf(_ax[ir] - _ax[il], 1.0e-3)
			var gx: float = (_hg[j * w + ir] - _hg[j * w + il]) / dx
			var gz: float = (_hg[ju * w + i] - _hg[jd * w + i]) / dz
			var slope: float = sqrt(gx * gx + gz * gz)
			vk[j * w + i] = clampf(
				(
					smoothstep(ROCK_SLOPE_LO, ROCK_SLOPE_HI, slope)
					+ smoothstep(ROCK_HEIGHT_LO, ROCK_HEIGHT_HI, _hg[j * w + i]) * ROCK_HEIGHT_GAIN
				),
				0.0,
				1.0
			)
	return vk


## Per-vertex terrain colour, LINEAR, ready for `ARRAY_COLOR`.
##
## Every lerp happens in sRGB and the conversion is the last step — the reference
## tints in gamma space and the result is visibly warmer than the same lerps done
## linearly, which is the look this world has.
func colour_grid(vk: PackedFloat32Array) -> PackedColorArray:
	var w: int = TN + 1
	var vc := PackedColorArray()
	vc.resize(w * w)
	for j in w:
		var z: float = _ax[j]
		for i in w:
			var k: int = j * w + i
			var x: float = _ax[i]
			var tone: float = noise.fbm2(x * 0.0045 + 3.0, z * 0.0045 - 8.0, 3)
			var c: Color = Palette.TERRAIN_SAND_LOW.lerp(
				Palette.TERRAIN_SAND_HIGH, clampf((tone - 0.30) * 2.1, 0.0, 1.0)
			)
			var rock_tone: float = noise.fbm2(x * 0.012 + 21.0, z * 0.012, 2)
			c = c.lerp(
				Palette.TERRAIN_ROCK_LOW.lerp(
					Palette.TERRAIN_ROCK_HIGH, clampf((rock_tone - 0.32) * 2.4, 0.0, 1.0)
				),
				vk[k]
			)
			var wd: float = absf(x - wadi_x(z))
			if wd < GRAVEL_HALF_W and _hg[k] < GRAVEL_MAX_H:
				c = c.lerp(Palette.TERRAIN_GRAVEL, (1.0 - smoothstep(7.0, 15.0, wd)) * 0.8)
			var jit: float = (
				1.0
				+ (noise.fbm2(x * 0.085 + 11.0, z * 0.085 - 5.0, 2) - 0.5) * 0.30
				+ (noise.vnoise2(x * 0.32 + 7.0, z * 0.32 - 3.0) - 0.5) * 0.10
			)
			var m: float = clampf(jit, 0.65, 1.35)
			vc[k] = Color(c.r * m, c.g * m, c.b * m).srgb_to_linear()
	return vc


## Road paint at every grid intersection. `layout` is the baked town; pass null
## and the map bakes unpaved.
##
## Gated on the rock mask as well as the bounding box: `dist_to_road` knows
## nothing about the terrain, so without the gate the streets would climb the
## wadi banks wherever a centre line happened to run past one.
func road_grid(layout: WorldLayoutData, vk: PackedFloat32Array) -> PackedFloat32Array:
	var w: int = TN + 1
	var vr := PackedFloat32Array()
	vr.resize(w * w)
	if layout == null or layout.road_lines.is_empty():
		return vr
	for j in w:
		var z: float = _ax[j]
		if absf(z) >= ROAD_BOUND_Z:
			continue
		for i in w:
			var x: float = _ax[i]
			if absf(x) >= ROAD_BOUND_X or vk[j * w + i] >= ROAD_MAX_ROCK:
				continue
			vr[j * w + i] = layout.road_at(x, z)
	return vr


## Per-quad surface id, `TN * TN` entries. The four corner masks vote; two or
## more corners' worth of rock carries the quad.
func quad_surface_grid(vk: PackedFloat32Array) -> PackedByteArray:
	var w: int = TN + 1
	var qs := PackedByteArray()
	qs.resize(TN * TN)
	for j in TN:
		for i in TN:
			var sum: float = (
				vk[j * w + i] + vk[j * w + i + 1] + vk[(j + 1) * w + i + 1] + vk[(j + 1) * w + i]
			)
			var kind: int = (
				WorldSurface.Kind.ROCK if sum > QUAD_ROCK_THRESHOLD else WorldSurface.Kind.SAND
			)
			qs[j * TN + i] = kind
	return qs
