@tool
extends SceneTree
## TEMPORARY PROBE. Dumps what the baked collider set says is standable near the Ash
## Line so the race route can be drawn over geometry that actually exists. Delete after.

const LO: float = -12.0
const HI: float = 24.0


func _initialize() -> void:
	_run()


func _run() -> void:
	await process_frame
	var q: WorldQuery = WorldQuery.load_baked()
	var lay: WorldLayoutData = q.layout
	var out := PackedStringArray()

	out.push_back("ROOF CENTRES: what top_at says vs what the layout claims")
	for i: int in lay.building_count():
		var p: Vector3 = lay.building_pos[i]
		if absf(p.x + 8.0) > 60.0 or p.z < -120.0 or p.z > 60.0:
			continue
		var t: float = q.top_at(p.x, p.z, LO, HI)
		var stand: bool = not is_nan(t) and q.can_stand(p.x, p.z, t, 1.9, 0.32)
		out.push_back(
			(
				"  b%02d  x %7.2f z %7.2f  claim %6.2f  top_at %6.2f  stand %s  w %5.2f d %5.2f"
				% [
					i,
					p.x,
					p.z,
					p.y,
					t,
					"yes" if stand else "NO ",
					lay.building_size[i].x,
					lay.building_size[i].y
				]
			)
		)

	out.push_back("")
	out.push_back("CARRIAGEWAY x -8: ground, top_at, standable")
	for zi: int in range(-20, 70, 2):
		var z: float = float(zi)
		var g: float = q.ground_h(-8.0, z)
		var t: float = q.top_at(-8.0, z, LO, HI)
		out.push_back(
			(
				"  z %6.1f  ground %6.2f  top %6.2f  stand(3.2m) %s  stand(6m) %s"
				% [
					z,
					g,
					t,
					"yes" if q.can_stand(-8.0, z, g, 3.2, 1.7) else "NO ",
					"yes" if q.can_stand(-8.0, z, g, 6.0, 3.0) else "NO "
				]
			)
		)

	out.push_back("")
	out.push_back("GRID top_at, x -60..24 step 4, z -44..60 step 4   ('.' = ground only)")
	var head: String = "        "
	for xi: int in range(-60, 28, 4):
		head += "%5d" % xi
	out.push_back(head)
	for zi: int in range(-44, 64, 4):
		var z: float = float(zi)
		var row: String = "  z%5d" % zi
		for xi: int in range(-60, 28, 4):
			var x: float = float(xi)
			var g: float = q.ground_h(x, z)
			var t: float = q.top_at(x, z, LO, HI)
			if is_nan(t) or t <= g + 0.4:
				row += "    ."
			else:
				row += "%5.1f" % t
		out.push_back(row)

	out.push_back("")
	out.push_back("CANDIDATE POINTS")
	for c: Array in [
		["riv bank N", -8.0, 6.0],
		["riv bank N2", -8.0, 12.0],
		["market", -9.0, 18.0],
		["cross", -8.0, 16.0],
		["road 24", -8.0, 24.0],
		["road 32", -8.0, 32.0],
		["road 40", -8.0, 40.0],
		["road 48", -8.0, 48.0],
		["road 56", -8.0, 56.0],
		["b74 roof", -22.23, 27.55],
		["b75 roof", -22.27, 44.89],
		["b71 roof", -47.59, 31.26],
		["b84 roof", 4.32, 48.50],
		["b26 roof", -17.93, -21.70],
		["b25 roof", -18.12, -34.14],
		["b24 roof", -34.55, -22.31],
		["b23 roof", -33.83, -35.08],
		["b36 roof", 8.03, -50.78],
		["b32 roof", 10.18, -69.66],
		["b30 roof", 4.57, -84.35],
		["b13 roof", -28.01, -63.19],
		["b21 roof", -56.17, -17.79],
		["b22 roof", -55.63, 0.81],
		["plaza", 4.0, 6.0],
	]:
		var x: float = c[1]
		var z: float = c[2]
		var g: float = q.ground_h(x, z)
		var t: float = q.top_at(x, z, LO, HI)
		out.push_back(
			(
				"  %-12s x %7.2f z %7.2f  ground %6.2f  top %6.2f  stand %s"
				% [c[0], x, z, g, t, "yes" if (not is_nan(t) and q.can_stand(x, z, t, 1.9, 0.32)) else "NO "]
			)
		)

	var f := FileAccess.open("res://tools/ash_flats/probe_town.txt", FileAccess.WRITE)
	f.store_string("\n".join(out) + "\n")
	f.close()
	print("\n".join(out))
	quit()
