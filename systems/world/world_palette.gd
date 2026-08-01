class_name WorldPalette
extends RefCounted
## The one-off colours the town generators name inline, plus `vary`.
##
## The family palettes themselves live in `res://art/palette.gd` as
## `Palette.WORLD_*` — this file does not duplicate them, it only adds the
## fifteen hard-coded shades the reference reaches for by hex and the jitter
## helper every generator wraps its picks in.

## Ladder stiles and rungs.
const LADDER: Color = Color("5a5049")
## Default door and window trim.
const TRIM: Color = Color("5c4a36")
## Slab grey — foundations, floor decks.
const SLAB: Color = Color("63605b")
## Steel rail, post, stanchion.
const RAIL: Color = Color("4a4c50")
## Catwalk and platform decking.
const DECK: Color = Color("5c584f")
## Fence and market post timber.
const POST: Color = Color("5c3f26")
## Dead branch.
const BRANCH: Color = Color("4d3323")
## Tyre rubber.
const TYRE: Color = Color("2b2d30")
## Power line conductor.
const WIRE: Color = Color("2f3134")
## Vent block and crash-site wing.
const VENT: Color = Color("63656a")
## Olive drum.
const DRUM_OLIVE: Color = Color("6a6544")
## Green drum.
const DRUM_GREEN: Color = Color("5f6448")
## Rust drum.
const DRUM_RUST: Color = Color("7a4a2c")
## Hauler body brown.
const HAULER: Color = Color("5b4838")
## Sandbag hessian.
const SANDBAG: Color = Color("8f7a52")
## Crash-site fuselage.
const FUSELAGE: Color = Color("6a6d73")
## Exfil marker orange. The only saturated colour in the world build.
const EXFIL: Color = Color("d8822f")

## Shipping-container livery, in pick order.
const CONTAINER: PackedColorArray = [
	Color("7a4a2c"),
	Color("5f6448"),
	Color("4a4d52"),
	Color("6a6544"),
	Color("5b4838"),
	Color("6b4028"),
]


## Randomised shade of a base sRGB colour. Consumes exactly three draws, in r/g/b
## order — the town layout's determinism is a function of that count, so this is
## never short-circuited even when `amt` is tiny.
##
## The 8-bit quantisation at the end is not decoration: the reference round-trips
## through `THREE.Color.getHex()`, which rounds each channel to a byte, and the
## mesher converts to linear from there.
static func vary(base: Color, r: XorShift32, amt: float = 0.09) -> Color:
	var f: float = 1.0 + (r.next() - 0.5) * 2.0 * amt
	var cr: float = clampf(base.r * f, 0.0, 1.0)
	var cg: float = clampf(base.g * f * (1.0 + (r.next() - 0.5) * amt * 0.4), 0.0, 1.0)
	var cb: float = clampf(base.b * f * (1.0 + (r.next() - 0.5) * amt * 0.6), 0.0, 1.0)
	return Color(round(cr * 255.0) / 255.0, round(cg * 255.0) / 255.0, round(cb * 255.0) / 255.0)


## `pick(r, PAL.x)` over a colour family. One draw.
static func pick(family: PackedColorArray, r: XorShift32) -> Color:
	return family[int(floor(r.next() * float(family.size())))]
