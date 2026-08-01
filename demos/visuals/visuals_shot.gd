class_name VisualsShot
extends RefCounted
## The hero angle of the visuals showpiece, written as numbers instead of as a
## comment in the builder.
##
## One camera decides this scene: you arrive at the parapet of the lookout terrace,
## eye tipped six degrees down, looking west-north-west across the settlement with
## the low sun 39 degrees off the left of the axis. `res://tools/build_visuals.gd`
## places the deck, the console, the rack, the stair, the kits and the props against
## that camera, and writes what each of them does to the frame into its report.
##
## The terrace is turned to the view rather than to the pad, so its local +X is the
## camera's right and its local -Z is the way you are looking. That is what makes
## "off the hero axis" a decidable question at build time: the control post sits at
## deck-local (-2.4, 1.4), which is a hundred and forty degrees round from where you
## stand, and no arithmetic in the builder can quietly walk it back into shot.

## The heading everything is laid out against.
const VIEW_YAW: float = 0.845
## Where the eye is tipped at spawn. Six degrees is the natural angle from a three
## metre rise to a settlement forty metres out, and it buys back the dead sky a
## level camera spends its top third on.
const VIEW_PITCH_DEGREES: float = -6.2

## The lookout terrace: long across the view, shallow along it.
const DECK: Vector2 = Vector2(32.0, 28.0)
const DECK_HALF: Vector2 = Vector2(10.5, 5.0)
const DECK_RISE: float = 3.0
## Deck-local metres. You arrive left of centre and right up against the parapet,
## close enough that the whole kerb falls below a 78 degree lens. That is
## deliberate: set back far enough to see the kerb, it becomes a hundred and thirty
## pixels of flat concrete across the bottom of the shot. The console is behind
## your right shoulder, the rack is off your left, and the stair comes up at the
## far end, so the walk in reads stair, console, parapet.
##
## THE KERB HAS DEPTH. It was set at -3.75 against the kerb's NEAR edge, which is
## 46 degrees below the eye and safely out of frame — but the bar is 0.32 m deep
## and its FAR edge sat at 44.6 degrees, inside the 45.2 degrees the bottom of the
## frame reaches. Three centimetres of kerb top therefore crossed the shot as a
## hard fourteen-pixel band, which reads as the frame slicing the foreground off.
## The eye stands 0.25 m further forward so the far edge clears by five degrees:
## the constraint is the edge of the kerb NEAREST the drop, not the one nearest
## your boots. `frame_lines()` in the bake report is where the bearings are checked.
const STAND_LOCAL: Vector2 = Vector2(-6.4, -4.0)
const POST_LOCAL: Vector2 = Vector2(-2.4, 1.4)
const RACK_LOCAL: Vector2 = Vector2(-9.6, -2.6)
const STAIR_LOCAL_X: float = 6.0

## Half the vertical field of view the player's eye ships with, the aspect the shot
## is judged at, and its width in pixels. Enough to turn a bearing into a screen x,
## which is the only form a composition can actually be checked in.
const EYE_HALF_FOV: float = deg_to_rad(39.0)
const SHOT_ASPECT: float = 16.0 / 9.0
const SHOT_WIDTH: float = 1600.0

## Kit id, pad-local XZ, yaw. Footprints are checked pairwise before packing. The
## plaza is the subject and stands on the axis at forty metres, the compound reads
## behind it at seventy-seven, the water tower anchors the left of frame, and
## `street_block` is turned off the axis so its bulk reads as a building, not a wall.
const KITS: Array = [
	["plaza", Vector2(-4.0, 4.0), 0.0],
	["compound", Vector2(-38.0, -14.0), -0.20],
	["watchtower", Vector2(-43.0, 15.0), 0.45],
	["street_block", Vector2(-2.0, -30.0), 2.86],
	["ruin_cluster", Vector2(38.5, -25.0), 3.35],
]

## Pad-local XZ and yaw of the six lamp standards, along the plaza and the street.
## The first stands twenty-four metres out and eight degrees right: from the deck
## its head sits on the horizon, which is where a warm point light does the most
## work in a back-lit frame.
const LAMPS: Array = [
	[Vector2(10.2, 11.5), 0.6],
	[Vector2(-2.1, 16.3), -0.3],
	[Vector2(10.9, -4.4), 1.9],
	[Vector2(-21.2, 22.7), 2.9],
	[Vector2(-11.2, -6.7), 0.2],
	[Vector2(-36.1, 6.3), 2.2],
]

## Set dressing: species, pad-local XZ, yaw. Ground species only — nothing here has
## a brain, and a hovering body with no director would sink. Two husks stand on the
## pad below the parapet, close enough to give the settlement a scale.
const CREATURES: Array = [
	["husk", Vector2(11.4, 25.1), 1.1],
	["husk", Vector2(8.6, 25.3), 2.4],
	["picker", Vector2(7.0, 9.1), -1.2],
	["gorger", Vector2(-11.0, 8.2), 0.7],
	["stilt", Vector2(6.2, -2.1), 2.8],
]

## Props placed by eye: the ones that frame the shot. The scatter reads this too, so
## a barrel never stands inside a wreck. The first two are the foreground — both
## below the parapet, neither on the axis. Nothing else is allowed inside thirteen
## metres: the rock shelf that used to sit at twelve read as a smooth pale wedge,
## because a low-poly boulder baked for thirty metres has nothing to say at twelve.
## The last six land inside the terrace's own footprint and so are placed on it
## rather than on the pad — dunnage round the stair head and the console, because a
## bare twenty-one metre slab behind you reads as a grey-box floor.
const LANDMARKS: Array = [
	[&"wreck", Vector2(13.9, 29.4), 1.15],
	[&"dead_tree", Vector2(25.2, 17.6), 1.2],
	[&"wreck", Vector2(16.2, 12.0), 0.55],
	[&"rock_cluster", Vector2(-35.1, 32.8), 0.8],
	[&"dead_tree", Vector2(-19.0, 28.0), 0.0],
	[&"market", Vector2(-8.6, 33.2), PI],
	[&"wall_holed", Vector2(-13.0, 34.0), 0.1],
	[&"rock_cluster", Vector2(-49.0, 33.0), 0.8],
	[&"power_line", Vector2(4.0, -46.0), 0.06],
	[&"containers", Vector2(21.2, 2.9), 1.55],
	[&"dead_tree", Vector2(-52.0, -34.0), 2.5],
	[&"big_crate", Vector2(37.8, 23.3), 0.9],
	[&"crate", Vector2(37.6, 27.4), 0.3],
	[&"barrel", Vector2(39.3, 25.7), 0.0],
	[&"sandbags", Vector2(32.8, 32.2), 1.7],
	[&"barrel", Vector2(33.4, 30.3), 0.0],
	[&"crate", Vector2(27.8, 36.0), 2.4],
]


## Deck-local metres to pad-local metres.
static func deck_local(local: Vector2) -> Vector2:
	var c: float = cos(VIEW_YAW)
	var s: float = sin(VIEW_YAW)
	return DECK + Vector2(local.x * c + local.y * s, -local.x * s + local.y * c)


## The inverse: pad-local metres to the deck's own frame. Clutter exclusion is done
## here, because the pad-aligned bounding box of a turned terrace claims eighty
## square metres of open ground it has no business claiming.
static func to_deck(pad: Vector2) -> Vector2:
	var c: float = cos(VIEW_YAW)
	var s: float = sin(VIEW_YAW)
	var d: Vector2 = pad - DECK
	return Vector2(d.x * c - d.y * s, d.x * s + d.y * c)


## Unit vector the hero camera looks along, in pad-local XZ.
static func forward() -> Vector2:
	return Vector2(-sin(VIEW_YAW), -cos(VIEW_YAW))


## Pad-local position of the standing eye.
static func stand() -> Vector2:
	return deck_local(STAND_LOCAL)


## Pad-local point `fwd` metres ahead of the standing eye and `right` metres to its
## right. This is the function the composition is written in.
static func view_of(fwd: float, right: float) -> Vector2:
	var f: Vector2 = forward()
	return stand() + f * fwd + Vector2(-f.y, f.x) * right


## Yaw-aware half-extent of a kit's footprint, read off its own baked mesh so it
## cannot go stale when a kit is re-baked.
static func kit_half(id: String, yaw: float) -> Vector2:
	var mesh := load("res://data/world/kits/%s_mesh.res" % id) as ArrayMesh
	if mesh == null:
		return Vector2(12.0, 12.0)
	var box: AABB = mesh.get_aabb()
	var half := Vector2(box.size.x, box.size.z) * 0.5
	var c: float = absf(cos(yaw))
	var s: float = absf(sin(yaw))
	return Vector2(half.x * c + half.y * s, half.x * s + half.y * c)


## Everything wrong with the layout, in words. A shot that reads is worth nothing if
## two kits stand in each other or one hangs off the terrace, and both are decidable
## here, before anything is baked.
static func layout_faults(pad_half: Vector2) -> PackedStringArray:
	var out := PackedStringArray()
	for i in KITS.size():
		var a: Array = KITS[i]
		var ah: Vector2 = kit_half(a[0] as String, float(a[2]))
		var ac: Vector2 = a[1]
		if absf(ac.x) + ah.x > pad_half.x or absf(ac.y) + ah.y > pad_half.y:
			out.append("kit '%s' overhangs the pad" % a[0])
		for j in range(i + 1, KITS.size()):
			var b: Array = KITS[j]
			var gap: Vector2 = (ac - (b[1] as Vector2)).abs() - ah - kit_half(b[0] as String, b[2])
			if gap.x < 0.0 and gap.y < 0.0:
				out.append(
					"kits '%s' and '%s' overlap by (%.1f, %.1f) m" % [a[0], b[0], -gap.x, -gap.y]
				)
	return out


## The whole frame, as text: every element's bearing, range and pixel column, in the
## order it was placed. `res://tools/build_visuals.gd` writes this into its report,
## so the composition can be checked from the numbers without opening the engine.
static func frame_lines() -> PackedStringArray:
	var eye: Vector2 = stand()
	var out := PackedStringArray()
	out.append("hero eye              pad (%.1f, %.1f) yaw %.3f" % [eye.x, eye.y, VIEW_YAW])
	out.append("%-20s %11s %7s %8s" % ["element", "bearing", "range", "screen x"])
	out.append(frame_line("sun disc", view_of(781.0, -624.0)))
	for entry: Array in KITS:
		out.append(frame_line("kit " + String(entry[0]), entry[1] as Vector2))
	for entry: Array in LANDMARKS:
		out.append(frame_line("prop " + String(entry[0]), entry[1] as Vector2))
	out.append(frame_line("post", deck_local(POST_LOCAL)))
	out.append(frame_line("rack", deck_local(RACK_LOCAL)))
	return out


## One line of it: what `at` does to the shot. Bearing off the view axis in degrees,
## range in metres, and the pixel column it lands in — or `off` when it falls
## outside the lens, which for the console is the point.
static func frame_line(label: String, at: Vector2) -> String:
	var f: Vector2 = forward()
	var d: Vector2 = at - stand()
	var fwd: float = d.dot(f)
	var bearing: float = atan2(d.dot(Vector2(-f.y, f.x)), fwd) if fwd > 0.01 else PI
	var edge: float = atan(tan(EYE_HALF_FOV) * SHOT_ASPECT)
	var half: float = SHOT_WIDTH * 0.5
	var inside: bool = fwd > 0.01 and absf(bearing) < edge
	return (
		"%-20s %7.1f deg %7s %8s"
		% [
			label,
			rad_to_deg(bearing),
			"far" if d.length() > 1.0e3 else "%.1f" % d.length(),
			("%.0f" % (half + half * tan(bearing) / tan(edge))) if inside else "off"
		]
	)
