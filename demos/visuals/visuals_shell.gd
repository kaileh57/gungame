class_name VisualsShell
extends RefCounted
## The three tests every shell this demo authors has to pass, lifted out of
## `res://tools/build_visuals.gd` so the builder stays under the thousand-line cap.
##
## The project's rule is that authored geometry is a union of CLOSED SOLIDS: every
## box overlaps its neighbour rather than butting against it, every face points
## out, and no edge is left with only one triangle on it. That is not fussiness —
## a butted joint is a hairline you can see the sky through at grazing angles, and
## an inverted face is a hole you can see the inside of the world through. Both
## are cheap to test for and free to fix at bake time, and neither is findable by
## looking at a screenshot.
##
## Nothing here runs at load. The builder calls `report()` once per shell and the
## result goes into `res://demos/visuals/build_report.txt`.

## Metres a vertex is rounded to before edges are counted. Two vertices closer
## than this are the same vertex — which is the whole point, since the boxes are
## authored independently and their shared corners only agree to float precision.
const WELD: float = 0.0002


## One line of the build report, and whether the shell passed. Returns
## (ok, text): the builder counts the failures and prints the text.
static func report(mesher: WorldMesher, label: String) -> Array:
	var vol: float = mesher.signed_volume()
	var conflicts: int = mesher.normal_conflicts()
	var degen: int = mesher.degenerate_count()
	var open: int = open_edges(mesher.vertices())
	var ok: bool = vol > 0.0 and conflicts == 0 and degen == 0 and open == 0
	var fmt: String = "shell %-6s %5d tris  vol %+9.2f  bad %d/%d/%d  %s"
	var text: String = (
		fmt
		% [
			label,
			mesher.triangle_count(),
			vol,
			conflicts,
			degen,
			open,
			"OK" if ok else "FAIL",
		]
	)
	return [ok, text]


## Boundary edges of a welded triangle soup. A closed solid has none; one is the
## air gap this project bans. Counted by parity rather than by exact count,
## because two boxes sharing a face legitimately put four triangles on an edge.
static func open_edges(pos: PackedVector3Array) -> int:
	var ids: Dictionary = {}
	var index := PackedInt32Array()
	index.resize(pos.size())
	for i in pos.size():
		var key: Vector3i = Vector3i(
			roundi(pos[i].x / WELD), roundi(pos[i].y / WELD), roundi(pos[i].z / WELD)
		)
		if not ids.has(key):
			ids[key] = ids.size()
		index[i] = ids[key]
	var edges: Dictionary = {}
	for t in index.size() / 3:
		for e in 3:
			var a: int = index[t * 3 + e]
			var b: int = index[t * 3 + (e + 1) % 3]
			if a == b:
				continue
			var pair: Vector2i = Vector2i(mini(a, b), maxi(a, b))
			edges[pair] = int(edges.get(pair, 0)) + 1
	var open: int = 0
	for count: int in edges.values():
		if count % 2 == 1:
			open += 1
	return open
