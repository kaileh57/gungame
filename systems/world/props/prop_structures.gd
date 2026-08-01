class_name PropStructures
extends RefCounted
## Ladders, pierced walls and stair flights — the three pieces of building fabric
## that every generator in `PropBuildings` is assembled from.
##
## All three are static: they own no state, they write into the `PropContext`
## they are handed, and they consume rng draws only where the reference does.

## Vertical extent of a hole, as (u0, u1, y0, y1): `u` runs from the wall's `a`
## end along its length, `y` is relative to the wall's base.
const HOLE_MIN_U: float = 0.02
const HOLE_MIN_Y: float = 0.02

## Trim rebate depths, metres — how far a lintel, jamb or sill stands proud of
## the wall face on each side.
const FRAME_LINTEL_OUT: float = 0.055
const FRAME_JAMB_OUT: float = 0.045
const FRAME_SILL_OUT: float = 0.085
## Trim overhangs past the hole edge.
const FRAME_LINTEL_PAD: float = 0.11
const FRAME_SILL_PAD: float = 0.13
## A hole whose sill is more than this above the wall base is a window, and
## windows get a sill board.
const WINDOW_SILL_MIN: float = 0.25

## Ladder rung and stile stock, half-extents.
const LADDER_STILE_HALF: float = 0.04
const LADDER_RUNG_HALF: float = 0.025
const LADDER_RUNG_HALF_W: float = 0.27
## Stand-off brackets, at these two fractions of the climb.
const LADDER_BRACKET_T: PackedFloat32Array = [0.2, 0.8]
const LADDER_BRACKET_INSET: float = 0.10

## Every step is a full-height block reaching this far below the flight's foot,
## so there is nothing to see under a staircase and nothing to fall into.
const STAIR_UNDERCUT: float = 0.25


## A bolted-on steel ladder from `y0` to `y1`, plus the climb volume that goes
## with it.
##
## `ry` must be oriented so the ladder's local +Z points AWAY from whatever it is
## bolted to — outward in world is `(sin ry, cos ry)`. Backwards, and the rungs
## run edge-on to the climber while the climb volume sits inside the wall.
##
## The rails carry no collider: the climb volume in `WorldLayoutData` is the
## interaction, and a collider here would only push the player off the ladder.
static func add_ladder(
	ctx: PropContext, x: float, z: float, ry: float, y0: float, y1: float, col: Color = Color.BLACK
) -> void:
	if y1 - y0 < 0.2:
		return
	var c: Color = WorldPalette.LADDER if col == Color.BLACK else col
	var co: float = cos(ry)
	var si: float = sin(ry)
	var mid: float = (y0 + y1) * 0.5
	var half_h: float = (y1 - y0) * 0.5
	var s_half: float = ctx.tuning.ladder_stile_half
	for sgn in [-1.0, 1.0]:
		var s: float = sgn * s_half
		ctx.deco(
			Vector3(x + s * co, mid, z - s * si),
			Vector3(LADDER_STILE_HALF, half_h, LADDER_STILE_HALF),
			ry,
			c,
			WorldSurface.Kind.METAL
		)
	var pitch: float = maxf(0.05, ctx.tuning.ladder_rung_pitch)
	var y: float = y0 + 0.28
	while y < y1 - 0.06:
		ctx.deco(
			Vector3(x, y, z),
			Vector3(LADDER_RUNG_HALF_W, LADDER_RUNG_HALF, LADDER_RUNG_HALF),
			ry,
			c,
			WorldSurface.Kind.METAL
		)
		y += pitch
	for t: float in LADDER_BRACKET_T:
		var by: float = lerpf(y0, y1, t)
		ctx.deco(
			Vector3(x - si * LADDER_BRACKET_INSET, by, z - co * LADDER_BRACKET_INSET),
			Vector3(0.30, 0.03, 0.12),
			ry,
			c,
			WorldSurface.Kind.METAL
		)
	ctx.layout.add_ladder(x, z, ry, y0, y1)


## A straight wall from (ax, az) to (bx, bz) with rectangular openings cut in it,
## framed in timber.
##
## The wall is emitted as a run of solid piers with slabs under and over each
## opening. Slabs are grown by `joint_overlap` into their neighbouring piers so
## the vertical joints are wet rather than coplanar; the opening itself keeps its
## exact size.
##
## `holes` are `Vector4(u0, u1, y0, y1)`. `u` is measured from `a` along the wall,
## `y` from `y_base`. `y1` is clamped to `h`; `y0` is not, so a hole may start
## below the wall.
##
## Overlapping holes each emit their own slabs and will z-fight. Every caller
## here checks its spacing before pushing a hole, which is why none of them do.
static func wall_with_holes(
	ctx: PropContext,
	ax: float,
	az: float,
	bx: float,
	bz: float,
	y_base: float,
	h: float,
	th: float,
	holes: Array[Vector4],
	col: Color,
	type: int,
	surf: int = -1,
	trim: Color = Color.BLACK
) -> void:
	var dx: float = bx - ax
	var dz: float = bz - az
	var length: float = sqrt(dx * dx + dz * dz)
	if length < 0.01:
		return
	var ry: float = atan2(-dz, dx)
	var co: float = cos(ry)
	var si: float = sin(ry)
	var cx: float = (ax + bx) * 0.5
	var cz: float = (az + bz) * 0.5
	var ov: float = ctx.tuning.joint_overlap

	var hs: Array[Vector4] = []
	for o: Vector4 in holes:
		if o.y <= 0.0 or o.x >= length:
			continue
		var clipped := Vector4(
			maxf(0.0, o.x), minf(length, o.y), y_base + o.z, y_base + minf(h, o.w)
		)
		hs.append(clipped)
	hs.sort_custom(func(p: Vector4, q: Vector4) -> bool: return p.x < q.x)

	var cur: float = 0.0
	for o: Vector4 in hs:
		if o.x > cur:
			_wall_slab(
				ctx, cx, cz, co, si, length, cur, o.x, y_base, y_base + h, th, ry, col, type, surf
			)
		_wall_slab(
			ctx, cx, cz, co, si, length, o.x - ov, o.y + ov, y_base, o.z, th, ry, col, type, surf
		)
		_wall_slab(
			ctx,
			cx,
			cz,
			co,
			si,
			length,
			o.x - ov,
			o.y + ov,
			o.w,
			y_base + h,
			th,
			ry,
			col,
			type,
			surf
		)
		cur = maxf(cur, o.y)
	if cur < length:
		_wall_slab(
			ctx, cx, cz, co, si, length, cur, length, y_base, y_base + h, th, ry, col, type, surf
		)

	var tc: Color = WorldPalette.TRIM if trim == Color.BLACK else trim
	for o: Vector4 in hs:
		var is_window: bool = o.z > y_base + WINDOW_SILL_MIN
		var jamb_hy: float = (o.w - o.z) * 0.5
		_wall_frame(
			ctx,
			cx,
			cz,
			co,
			si,
			length,
			o.x - FRAME_LINTEL_PAD,
			o.y + FRAME_LINTEL_PAD,
			o.w,
			o.w + 0.15,
			0.075,
			FRAME_LINTEL_OUT,
			th,
			ry,
			tc
		)
		_wall_frame(
			ctx,
			cx,
			cz,
			co,
			si,
			length,
			o.x - FRAME_LINTEL_PAD,
			o.x,
			o.z,
			o.w,
			jamb_hy,
			FRAME_JAMB_OUT,
			th,
			ry,
			tc
		)
		_wall_frame(
			ctx,
			cx,
			cz,
			co,
			si,
			length,
			o.y,
			o.y + FRAME_LINTEL_PAD,
			o.z,
			o.w,
			jamb_hy,
			FRAME_JAMB_OUT,
			th,
			ry,
			tc
		)
		if is_window:
			_wall_frame(
				ctx,
				cx,
				cz,
				co,
				si,
				length,
				o.x - FRAME_SILL_PAD,
				o.y + FRAME_SILL_PAD,
				o.z - 0.10,
				o.z,
				0.05,
				FRAME_SILL_OUT,
				th,
				ry,
				tc
			)


static func _wall_slab(
	ctx: PropContext,
	cx: float,
	cz: float,
	co: float,
	si: float,
	length: float,
	u0: float,
	u1: float,
	y0: float,
	y1: float,
	th: float,
	ry: float,
	col: Color,
	type: int,
	surf: int
) -> void:
	if u1 - u0 < HOLE_MIN_U or y1 - y0 < HOLE_MIN_Y:
		return
	var um: float = (u0 + u1) * 0.5 - length * 0.5
	ctx.solid(
		Vector3(cx + um * co, (y0 + y1) * 0.5, cz - um * si),
		Vector3((u1 - u0) * 0.5, (y1 - y0) * 0.5, th * 0.5),
		ry,
		col,
		type,
		surf
	)


static func _wall_frame(
	ctx: PropContext,
	cx: float,
	cz: float,
	co: float,
	si: float,
	length: float,
	u0: float,
	u1: float,
	y0: float,
	y1: float,
	hy: float,
	out: float,
	th: float,
	ry: float,
	tc: Color
) -> void:
	if u1 - u0 < HOLE_MIN_U or hy <= 0.0:
		return
	var um: float = (u0 + u1) * 0.5 - length * 0.5
	ctx.deco(
		Vector3(cx + um * co, (y0 + y1) * 0.5, cz - um * si),
		Vector3((u1 - u0) * 0.5, hy, th * 0.5 + out),
		ry,
		tc,
		WorldSurface.Kind.WOOD
	)


## A straight flight rising `rise_to` over a run of `run`, centred on (x, z) and
## running along the flight's local X.
##
## Every step is a solid block from its own tread down to `y0 - 0.25`: no
## overhangs, no cavity underneath, nothing to fall through. Treads overlap their
## neighbours by `joint_overlap` so consecutive risers never share a plane.
##
## Surface is forced to concrete whatever the visual type, because a steel
## staircase that sounds like a tin roof underfoot is worse than a wrong colour.
static func stairs_fixed(
	ctx: PropContext,
	x: float,
	z: float,
	ry: float,
	w: float,
	run: float,
	rise_to: float,
	y0: float,
	col: Color,
	type: int
) -> void:
	if run <= 0.0 or rise_to <= 0.0 or w <= 0.0:
		return
	var steps: int = maxi(2, int(round(rise_to / maxf(0.05, ctx.tuning.stair_riser))))
	var rise: float = rise_to / float(steps)
	var tread: float = run / float(steps)
	var co: float = cos(ry)
	var si: float = sin(ry)
	var ov: float = ctx.tuning.joint_overlap
	for i in steps:
		var u: float = -run * 0.5 + tread * (float(i) + 0.5)
		var top: float = y0 + rise * float(i + 1)
		var bot: float = y0 - STAIR_UNDERCUT
		ctx.solid(
			Vector3(x + u * co, (top + bot) * 0.5, z - u * si),
			Vector3(tread * 0.5 + ov, (top - bot) * 0.5, w * 0.5),
			ry,
			col,
			type,
			WorldSurface.Kind.CONCRETE
		)
