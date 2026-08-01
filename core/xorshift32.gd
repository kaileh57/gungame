class_name XorShift32
extends RefCounted
## Bit-exact port of the reference prototypes' `rng(seed)` — a 32-bit xorshift.
##
## Every derived system keys off this exact stream: the town layout, the gun roll,
## the per-weapon recoil pattern, the wilds scatter. A single extra or missing
## draw re-rolls the whole world, so the helpers below document their draw cost.
##
## The middle shift in the JS original is `s >> 17` applied to a value JS has
## already coerced to int32 — an ARITHMETIC shift that sign-extends once bit 31
## is set. GDScript ints are 64-bit and would zero-fill, silently producing a
## different sequence, so the sign extension is done by hand.

const MASK32: int = 0xFFFFFFFF
const SIGN32: int = 0x80000000

var _s: int = 1


func _init(seed_value: int) -> void:
	_s = seed_value & MASK32
	if _s == 0:
		_s = 1


## Next float in [0, 1). One draw.
func next() -> float:
	_s = (_s ^ (_s << 13)) & MASK32
	var t: int = (_s >> 17) & 0x7FFF
	if (_s & SIGN32) != 0:
		t |= 0xFFFF8000
	_s = (_s ^ t) & MASK32
	_s = (_s ^ (_s << 5)) & MASK32
	return float(_s) / 4294967296.0


## `rr(r, a, b)` — uniform float in [a, b). One draw.
func next_range(a: float, b: float) -> float:
	return a + (b - a) * next()


## `ri(r, a, b)` — uniform int in [a, b], INCLUSIVE at both ends. One draw.
func next_int(a: int, b: int) -> int:
	return int(floor(float(a) + float(b - a + 1) * next()))


## `chance(r, p)` — true with probability p. One draw.
func chance(p: float) -> bool:
	return next() < p


## `pick(r, a)` — uniform element of `a`. One draw. Returns null on an empty array.
func pick(a: Array) -> Variant:
	if a.is_empty():
		return null
	return a[int(floor(next() * float(a.size())))]


## Current internal state, for checkpointing a stream mid-bake.
func state() -> int:
	return _s
