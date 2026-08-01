class_name WorldNoise
extends RefCounted
## Value noise, exactly as the reference's `vnoise2` / `fbm2` / `ridged`.
##
## The permutation table is shuffled from its own rng stream (`WORLD_SEED ^
## 0x9e3779b9`), separate from the layout stream, so adding a building never moves
## a dune. Everything here is deterministic and allocation-free after `_init`.
##
## The octaves are NOT offset per octave — only the coordinate is scaled — so they
## stay correlated near the origin. That is the reference behaviour and the whole
## silhouette of the map depends on it. It is not a bug to fix.

const PERM_SEED_MIX: int = 0x9e3779b9

var _np: PackedByteArray


func _init(world_seed: int) -> void:
	var r := XorShift32.new(world_seed ^ PERM_SEED_MIX)
	var p := PackedByteArray()
	p.resize(256)
	for i in 256:
		p[i] = i
	var i: int = 255
	while i > 0:
		var j: int = int(floor(r.next() * float(i + 1)))
		var t: int = p[i]
		p[i] = p[j]
		p[j] = t
		i -= 1
	_np = PackedByteArray()
	_np.resize(512)
	for k in 512:
		_np[k] = p[k & 255]


## Two-dimensional value noise in [0, 1]. `floor(x) & 255` on a negative x wraps
## the way JS does — GDScript's two's-complement `&` agrees, but `int()` would
## truncate toward zero and give a different cell, so `floor` is explicit.
func vnoise2(x: float, y: float) -> float:
	var fxi: int = int(floor(x))
	var fyi: int = int(floor(y))
	var xi: int = fxi & 255
	var yi: int = fyi & 255
	var fx: float = x - float(fxi)
	var fy: float = y - float(fyi)
	fx = fx * fx * (3.0 - 2.0 * fx)
	fy = fy * fy * (3.0 - 2.0 * fy)
	var a: float = float(_np[_np[xi] + yi]) / 255.0
	var b: float = float(_np[_np[xi + 1] + yi]) / 255.0
	var c: float = float(_np[_np[xi] + yi + 1]) / 255.0
	var d: float = float(_np[_np[xi + 1] + yi + 1]) / 255.0
	return lerpf(lerpf(a, b, fx), lerpf(c, d, fx), fy)


## Fractal sum, normalised by the summed amplitude so the range stays [0, 1].
func fbm2(x: float, y: float, octaves: int = 4, lac: float = 2.03, gain: float = 0.5) -> float:
	var s: float = 0.0
	var a: float = 0.5
	var n: float = 0.0
	var px: float = x
	var py: float = y
	for _i in octaves:
		s += a * vnoise2(px, py)
		n += a
		px *= lac
		py *= lac
		a *= gain
	return s / n


## Ridged variant. Lacunarity 2.07 and gain 0.5 are hard-coded in the reference.
func ridged(x: float, y: float, octaves: int = 4) -> float:
	var s: float = 0.0
	var a: float = 0.5
	var n: float = 0.0
	var px: float = x
	var py: float = y
	for _i in octaves:
		s += a * (1.0 - absf(vnoise2(px, py) * 2.0 - 1.0))
		n += a
		px *= 2.07
		py *= 2.07
		a *= 0.5
	return s / n


## Frame-rate-independent exponential approach. Used by the camera and stance code.
static func damp(a: float, b: float, rate: float, dt: float) -> float:
	return lerpf(a, b, 1.0 - exp(-rate * dt))
