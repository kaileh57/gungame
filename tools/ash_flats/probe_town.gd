@tool
extends SceneTree
## PROBE. Dumps what the baked collider set says is standable along the Ash Line and
## through the settlement north of the river, so the race route can be drawn over
## geometry that actually exists. Read `probe_town.txt` beside it.
##
## Run:
##   godot --headless --path <project> --script res://tools/ash_flats/probe_town.gd

## Height window every `top_at` is asked over. Below the riverbed, above every roof.
const LO: float = -12.0
const HI: float = 26.0
## The corridor the north leg is drawn in: x range, z range and the grid steps.
const CX0: int = -32
const CX1: int = 14
const CX_STEP: int = 2
const CZ0: int = -8
const CZ1: int = 92
const CZ_STEP: int = 3


func _initialize() -> void:
	_run()


func _run() -> void:
	await process_frame
	var q: WorldQuery = WorldQuery.load_baked()
	var out := PackedStringArray()
	_roofs(q, out)
	_ladders(q, out)
	_pois(q, out)
	_carriageway(q, out)
	_grid(q, out)
	var f := FileAccess.open("res://tools/ash_flats/probe_town.txt", FileAccess.WRITE)
	f.store_string("\n".join(out) + "\n")
	f.close()
	print("\n".join(out))
	quit()


func _roofs(q: WorldQuery, out: PackedStringArray) -> void:
	var lay: WorldLayoutData = q.layout
	out.push_back("ROOF CENTRES: what top_at says vs what the layout claims")
	for i: int in lay.building_count():
		var p: Vector3 = lay.building_pos[i]
		if absf(p.x + 8.0) > 60.0 or p.z < -120.0 or p.z > 96.0:
			continue
		var t: float = q.top_at(p.x, p.z, LO, HI)
		var stand: bool = not is_nan(t) and q.can_stand(p.x, p.z, t, 1.9, 0.32)
		var room: bool = not is_nan(t) and q.can_stand(p.x, p.z, t, 2.4, 1.6)
		(
			out
			. push_back(
				(
					"  b%02d x %7.2f z %7.2f  claim %6.2f  top %6.2f  stand %s  room %s  w %5.2f d %5.2f"
					% [
						i,
						p.x,
						p.z,
						p.y,
						t,
						"yes" if stand else "NO ",
						"yes" if room else "NO ",
						lay.building_size[i].x,
						lay.building_size[i].y
					]
				)
			)
		)


## Every climb volume in the north half, because a route onto a roof needs a way up.
func _ladders(q: WorldQuery, out: PackedStringArray) -> void:
	var lay: WorldLayoutData = q.layout
	out.push_back("")
	out.push_back("LADDERS  z -20..92, x -50..30   (foot, top, yaw)")
	for i: int in lay.ladder_count():
		var o: Vector3 = lay.ladder_origin[i]
		if o.z < -20.0 or o.z > 92.0 or o.x < -50.0 or o.x > 30.0:
			continue
		out.push_back(
			(
				"  L%02d  x %7.2f z %7.2f  foot %6.2f  top %6.2f  yaw %5.2f  ground %6.2f"
				% [i, o.x, o.z, o.y, lay.ladder_top[i], lay.ladder_yaw[i], q.ground_h(o.x, o.z)]
			)
		)


func _pois(q: WorldQuery, out: PackedStringArray) -> void:
	var lay: WorldLayoutData = q.layout
	out.push_back("")
	out.push_back("POIS")
	for i: int in lay.poi_name.size():
		var p: Vector3 = lay.poi_pos[i]
		out.push_back(
			(
				"  %-14s %-5s x %7.2f y %6.2f z %7.2f  ground %6.2f"
				% [
					lay.poi_name[i],
					"EXFIL" if lay.poi_kind[i] == WorldLayoutData.PoiKind.EXFIL else "poi",
					p.x,
					p.y,
					p.z,
					q.ground_h(p.x, p.z)
				]
			)
		)


## The carriageway north of the river, which is where the finish has to stand: the
## ground, whatever is over it, and whether a gantry-sized volume fits.
func _carriageway(q: WorldQuery, out: PackedStringArray) -> void:
	out.push_back("")
	out.push_back("CARRIAGEWAY x -8: ground, top, clearance for a runner and for a gantry")
	for zi: int in range(-6, 94, 2):
		var z: float = float(zi)
		var g: float = q.ground_h(-8.0, z)
		var t: float = q.top_at(-8.0, z, LO, HI)
		var wide: bool = (
			q.can_stand(-13.8, z, q.ground_h(-13.8, z), 6.0, 0.5)
			and q.can_stand(-2.2, z, q.ground_h(-2.2, z), 6.0, 0.5)
		)
		out.push_back(
			(
				"  z %6.1f  ground %6.2f  top %6.2f  run %s  post %s  span %s"
				% [
					z,
					g,
					t,
					"yes" if q.can_stand(-8.0, z, g, 3.2, 1.7) else "NO ",
					"yes" if wide else "NO ",
					"yes" if q.can_stand(-8.0, z, g + 5.5, 1.2, 5.0) else "NO "
				]
			)
		)


## The corridor as a table of collider tops. '.' is bare ground; anything else is the
## height of the highest thing a deck at that spot would have to clear or sit on.
func _grid(q: WorldQuery, out: PackedStringArray) -> void:
	out.push_back("")
	out.push_back(
		(
			"GRID top_at, x %d..%d step %d, z %d..%d step %d   ('.' = ground only)"
			% [CX0, CX1, CX_STEP, CZ0, CZ1, CZ_STEP]
		)
	)
	var head: String = "        "
	for xi: int in range(CX0, CX1 + 1, CX_STEP):
		head += "%5d" % xi
	out.push_back(head)
	for zi: int in range(CZ0, CZ1 + 1, CZ_STEP):
		var row: String = "  z%5d" % zi
		for xi: int in range(CX0, CX1 + 1, CX_STEP):
			var g: float = q.ground_h(float(xi), float(zi))
			var t: float = q.top_at(float(xi), float(zi), LO, HI)
			row += "    ." if is_nan(t) or t <= g + 0.4 else "%5.1f" % t
		out.push_back(row)
