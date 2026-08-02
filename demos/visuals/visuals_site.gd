class_name VisualsSite
extends RefCounted
## Where the showpiece terrace is graded into the world, decided from the baked
## terrain and the baked town rather than typed in as a coordinate.
##
## The demo used to be a settlement standing alone in the flats at (-220, -40),
## which is a fine vignette and a poor answer to "show me the map". The terrace
## itself is worth keeping — it is the foreground the hero frame is built out of —
## so what changed is where it stands: on a rise on the ash flats with the WHOLE
## town in front of it, along the axis the composition already looks down.
##
## The search is a scan, not a search in the interesting sense: `VisualsShot`
## fixes the heading, so the only free variables are how far back from the town
## the terrace stands and how far off the axis. Every candidate is scored on three
## things that can be measured off the bake —
##
##   RISE     how far the standing eye clears the town's mean roof. This is the
##            whole reason for an overlook; at zero you are looking at a wall of
##            the nearest buildings and the city behind them is invisible.
##   CLEAR    the tightest gap between the sightline to the town centre and the
##            ground under it. A dune between you and the city is the one failure
##            mode a height score alone cannot see, and it is fatal.
##   FILL     how much dirt the terrace has to bury to sit level. Cheap ground is
##            better ground: a terrace on a 20 m grade is a retaining wall with a
##            view, and it reads as one.
##
## — and the winner is baked. Nothing here runs at load; `res://tools/build_visuals.gd`
## calls `choose()` once and writes the coordinate into the scene.

const Shot := preload("res://demos/visuals/visuals_shot.gd")

## Metres back from the town centre the scan considers. The near end is set by the
## town's own reach — the terrace is 130 m across and may not stand in the
## streets — and the far end by the lens: past 560 m the city is 30 degrees of a
## 110 degree frame and the shot is a landscape with a smudge in it.
const RANGE_NEAR: float = 250.0
const RANGE_FAR: float = 560.0
const RANGE_STEP: float = 10.0
## Metres either side of the view axis. Small: the composition is built around the
## town sitting on the axis, and this is here to dodge a dune, not to reframe.
const LATERAL: PackedFloat32Array = [-96.0, -48.0, 0.0, 48.0, 96.0]

## Sample spacing when measuring a candidate's footprint, metres.
const FOOT_STEP: float = 6.0
## Sample spacing along the sightline to the town, metres.
const RAY_STEP: float = 9.0
## The sightline is only judged over this span of the way there. The first tenth
## is the terrace's own graded edge, which is below the eye by construction, and
## the last twentieth is the town itself, which is meant to be in the way.
const RAY_FROM: float = 0.10
const RAY_TO: float = 0.94
## Metres of daylight the sightline must keep over the ground to count as a view.
const CLEAR_MIN: float = 1.5
## Clearance past this buys nothing — a view is a view.
const CLEAR_CAP: float = 14.0

## Metres the terrace must keep clear of any baked building. The terrace is a
## closed buried solid; a house inside its footprint is a house inside a hill.
const BUILDING_MARGIN: float = 14.0
## Metres of terrain that must remain outside the terrace on every side.
const RIM_MARGIN: float = 60.0

## Score weights. Rise is the subject, clearance is the veto made continuous, and
## fill is the tax.
const W_RISE: float = 1.0
const W_CLEAR: float = 1.6
const W_FILL: float = 0.30

## Candidates written into the build report.
const REPORT_ROWS: int = 8

## Where the eye ends up relative to the graded top: the deck's rise plus a
## standing eye. Only used for scoring, so it does not have to be exact — but it
## is the same 3.0 + 1.66 the built scene ends up with.
const EYE_OVER_PAD: float = Shot.DECK_RISE + 1.66


## The town's centre of mass, its reach, and its mean roof height, read off the
## baked layout. Returned as (centre.x, centre.z, reach, roof_y) so the caller can
## report it without this class owning a struct.
static func town_metrics(layout: WorldLayoutData) -> Vector4:
	var n: int = 0 if layout == null else layout.building_pos.size()
	if n == 0:
		return Vector4(0.0, 0.0, 160.0, 6.0)
	var sum := Vector2.ZERO
	var roof: float = 0.0
	for i in n:
		var p: Vector3 = layout.building_pos[i]
		sum += Vector2(p.x, p.z)
		roof += p.y
	var centre: Vector2 = sum / float(n)
	var reach: float = 0.0
	for i in n:
		var p: Vector3 = layout.building_pos[i]
		var s: Vector2 = layout.building_size[i]
		var d: float = Vector2(p.x, p.z).distance_to(centre) + maxf(s.x, s.y) * 0.5
		reach = maxf(reach, d)
	return Vector4(centre.x, centre.y, reach, roof / float(n))


## Pick the overlook. `pad_half` is the terrace's top course; `pad_out` how much
## wider its outermost course is. Appends a scan table to `report` and returns the
## world XZ the terrace is graded into.
static func choose(
	terrain: WorldTerrainData,
	layout: WorldLayoutData,
	pad_half: Vector2,
	pad_out: float,
	report: PackedStringArray
) -> Vector2:
	var town: Vector4 = town_metrics(layout)
	var centre := Vector2(town.x, town.y)
	var roof: float = town.w
	var outer: Vector2 = pad_half + Vector2.ONE * pad_out
	var rim: float = _rim(terrain) - RIM_MARGIN
	# The view axis, and the bearing that walks BACK along it: the terrace stands
	# behind the shot, so the town falls in front of it.
	var fwd: Vector2 = Shot.forward()
	var back := Vector2(-fwd.x, -fwd.y)
	var side := Vector2(-back.y, back.x)

	var rows: Array = []
	var d: float = RANGE_NEAR
	while d <= RANGE_FAR:
		for lateral: float in LATERAL:
			var at: Vector2 = centre + back * d + side * lateral
			var row: Dictionary = _score(terrain, layout, at, outer, pad_half, centre, roof, rim)
			row["at"] = at
			row["range"] = d
			row["lateral"] = lateral
			rows.append(row)
		d += RANGE_STEP
	rows.sort_custom(_better)

	report.append(
		(
			"town centre           (%.0f, %.0f)  reach %.0f m  mean roof %.1f m"
			% [centre.x, centre.y, town.z, roof]
		)
	)
	report.append("site scan             %d candidates on the view axis" % rows.size())
	var head: Array = ["site", "range", "off", "rise", "clear", "fill", "score"]
	report.append("%-18s %7s %7s %7s %7s %7s  %s" % head)
	var shown: int = 0
	for row: Dictionary in rows:
		if shown >= REPORT_ROWS:
			break
		report.append(_row_line(row))
		shown += 1

	if rows.is_empty() or not bool(rows[0]["ok"]):
		report.append("FAIL: no candidate overlook cleared the town; falling back to the axis")
		return centre + back * 380.0
	return rows[0]["at"] as Vector2


## Sort key: anything that fails a hard test sinks, and the rest go on score.
static func _better(a: Dictionary, b: Dictionary) -> bool:
	if bool(a["ok"]) != bool(b["ok"]):
		return bool(a["ok"])
	return float(a["score"]) > float(b["score"])


static func _row_line(row: Dictionary) -> String:
	var at: Vector2 = row["at"]
	return (
		"%-18s %7.0f %7.0f %7.1f %7.1f %7.1f  %.1f %s"
		% [
			"(%.0f, %.0f)" % [at.x, at.y],
			float(row["range"]),
			float(row["lateral"]),
			float(row["rise"]),
			float(row["clear"]),
			float(row["fill"]),
			float(row["score"]),
			"" if bool(row["ok"]) else String(row["why"])
		]
	)


## Everything measurable about one candidate.
static func _score(
	terrain: WorldTerrainData,
	layout: WorldLayoutData,
	at: Vector2,
	outer: Vector2,
	top_half: Vector2,
	town: Vector2,
	roof: float,
	rim: float
) -> Dictionary:
	var out: Dictionary = {"ok": false, "why": "", "rise": 0.0, "clear": 0.0, "fill": 0.0}
	out["score"] = -1.0e9
	if absf(at.x) + outer.x > rim or absf(at.y) + outer.y > rim:
		out["why"] = "off the map"
		return out
	if _hits_building(layout, at, outer):
		out["why"] = "stands in the town"
		return out

	var hi: float = -1.0e9
	var lo: float = 1.0e9
	var x: float = -outer.x
	while x <= outer.x:
		var z: float = -outer.y
		while z <= outer.y:
			var h: float = terrain.ground_h(at.x + x, at.y + z)
			lo = minf(lo, h)
			if absf(x) <= top_half.x and absf(z) <= top_half.y:
				hi = maxf(hi, h)
			z += FOOT_STEP
		x += FOOT_STEP
	var eye: float = hi + EYE_OVER_PAD
	out["rise"] = eye - roof
	out["fill"] = hi - lo
	out["clear"] = _sightline(terrain, at, eye, town, roof)
	if float(out["clear"]) < CLEAR_MIN:
		out["why"] = "a dune is in the way"
		return out
	out["ok"] = true
	out["score"] = (
		W_RISE * float(out["rise"])
		+ W_CLEAR * minf(float(out["clear"]), CLEAR_CAP)
		- W_FILL * float(out["fill"])
	)
	return out


## Tightest gap between the ground and the line from the eye to the town's roofs.
static func _sightline(
	terrain: WorldTerrainData, from: Vector2, eye_y: float, town: Vector2, roof: float
) -> float:
	var span: float = from.distance_to(town)
	if span < 1.0:
		return 0.0
	var worst: float = 1.0e9
	var t: float = RAY_FROM
	var step: float = RAY_STEP / span
	while t <= RAY_TO:
		var p: Vector2 = from.lerp(town, t)
		var ray: float = lerpf(eye_y, roof, t)
		worst = minf(worst, ray - terrain.ground_h(p.x, p.y))
		t += step
	return worst


## True when any baked building's footprint reaches inside the terrace. Footprints
## are treated as axis-aligned at their largest extent, which over-claims a turned
## building by a metre or two and is the safe direction to be wrong in.
static func _hits_building(layout: WorldLayoutData, at: Vector2, outer: Vector2) -> bool:
	if layout == null:
		return false
	for i in layout.building_pos.size():
		var p: Vector3 = layout.building_pos[i]
		var s: Vector2 = layout.building_size[i]
		var reach: float = maxf(s.x, s.y) * 0.5 + BUILDING_MARGIN
		if absf(p.x - at.x) < outer.x + reach and absf(p.z - at.y) < outer.y + reach:
			return true
	return false


## Half-width of the baked terrain, metres, off its own sampling axis.
static func _rim(terrain: WorldTerrainData) -> float:
	if terrain == null or terrain.ax.is_empty():
		return 880.0
	return maxf(absf(terrain.ax[0]), absf(terrain.ax[terrain.ax.size() - 1]))
