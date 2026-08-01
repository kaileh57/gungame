@tool
extends SceneTree
## Gun-part mesh bake: reference geometry in, repaired ArrayMesh resources out.
##
## The reference prototype ships its 95 parts as a quantised int16 blob and drew
## them with DoubleSide + smooth normals, which hid the fact that most of them
## wind inwards and that the set carries 711 boundary (hole) edges. Godot culls
## backfaces, so every one of those defects would be visible. This script decodes
## the blob, repairs the topology in WebGL's winding, and writes what
## `PartLibrary` expects: `part_library.tres` plus one ArrayMesh per part. WebGL's
## front face is counter-clockwise and Godot's is CLOCKWISE, so `_build_surface`
## reverses the index order as it scatters — else every gun is culled inside out.
##
## Run headless (the global class cache must be current, so run the editor once
## with `--editor --quit` after any change to res://core/):
##   godot --headless --path <project> --script res://tools/bake_gun_parts.gd

const HTML_PATH := "res://reference/scav_range.html"
const MESH_DIR := "res://data/guns/meshes"
const MANIFEST_PATH := "res://data/guns/part_library.tres"
const REPORT_PATH := "res://data/bake_report.txt"

## The reference embeds exactly this much. A mismatch means a different prototype
## and every golden value derived from it is void.
const EXPECTED_PARTS := 95
const EXPECTED_BLOB_BYTES := 232134

## Quantisation leaves duplicate seam vertices a few units of last place apart;
## 1e-5 is two steps on the coarsest axis and never merges points that were
## distinct in the source.
const WELD_TOL := 1.0e-5
## A triangle below this area is numerically a line and has no usable normal.
const DEGEN_AREA := 1.0e-11
## A vertex this close to an edge it does not belong to is a T-junction left over
## from the reference's modelling, not a distinct point.
const TJUNCTION_TOL := 1.0e-4
## T-junction repair opens fresh boundary edges of its own, so it iterates.
const TJUNCTION_PASSES := 4
## Slit closing and rim capping feed each other; eight alternations is more than
## twice what the worst part in this set needs.
const CAP_PASSES := 8
## Faceted scrap look. Below this crease angle adjacent faces share a normal, so
## tessellated flats and fan caps read as one surface while cylinder facets and
## every real edge stay crisp. The reference used flatShading:true.
const SMOOTH_ANGLE_DEG := 15.0
## Out-of-plane deviation of a boundary loop, as a fraction of its own diameter,
## below which a centroid fan is a faithful cap rather than invented geometry.
## Loops past this are still capped - a hole you can see through is worse than a
## slightly domed end cap - but they are counted separately in the report.
const PLANAR_TOL := 0.05
## Signed volume below this fraction of the component's bounding-box volume is
## too near zero to decide orientation from; fall back to the normal vote.
const VOLUME_EPS := 1.0e-4

## Report table layout: column labels, the row field each reads, column widths.
## Volume and watertightness are appended by hand, so they have no field name.
const COL_HEAD := (
	"idx kind group class v_in t_in v_wld degen tjnc t_out patch"
	+ " wflip cflip conf edge0 rims edge1 volume tight"
)
const COL_FIELD := "index k g c v0 t0 v1 degen splits t1 comp wflip cflip conflict be0 capped be1"
const COL_WIDTH := [3, 8, 14, 8, 6, 6, 6, 5, 5, 6, 5, 6, 6, 5, 6, 5, 6, 11, 5]
const RULE_WIDTH := 161


## Working geometry: vertex array plus a flat index array, three per face.
class Geo:
	extends RefCounted

	var v := PackedVector3Array()
	var t := PackedInt32Array()

	func tri_count() -> int:
		return t.size() / 3


func _initialize() -> void:
	var started := Time.get_ticks_msec()
	var data := _load_partdata()
	if data.is_empty():
		push_error("bake_gun_parts: no part data in %s" % HTML_PATH)
		quit(1)
		return
	var defs: Array = data.get("parts", [])
	var blob := Marshalls.base64_to_raw(str(data.get("blob", "")))
	print("partdata: %d parts, blob %d bytes" % [defs.size(), blob.size()])
	if defs.size() != EXPECTED_PARTS or blob.size() != EXPECTED_BLOB_BYTES:
		push_error(
			(
				"bake_gun_parts: expected %d parts / %d blob bytes, got %d / %d"
				% [EXPECTED_PARTS, EXPECTED_BLOB_BYTES, defs.size(), blob.size()]
			)
		)
		quit(1)
		return

	DirAccess.make_dir_recursive_absolute(MESH_DIR)
	var rows: Array[Dictionary] = []
	for i in defs.size():
		rows.append(_bake_part(i, defs[i], blob))

	var saved := _save_manifest(defs, rows, blob)
	var report := _compose_report(rows, Time.get_ticks_msec() - started, saved)
	_write_text(REPORT_PATH, report)
	print(report)
	quit(0 if saved and _all_pass(rows) else 1)


# ---------------------------------------------------------------- source data


func _load_partdata() -> Dictionary:
	var f := FileAccess.open(HTML_PATH, FileAccess.READ)
	if f == null:
		return {}
	var html := f.get_as_text()
	f.close()
	var tag := html.find('<script id="partdata"')
	if tag < 0:
		return {}
	var body := html.find(">", tag)
	var close := html.find("</script>", body)
	if body < 0 or close < 0:
		return {}
	var parsed: Variant = JSON.parse_string(html.substr(body + 1, close - body - 1))
	if typeof(parsed) != TYPE_DICTIONARY:
		return {}
	return parsed


## positions: nv*3 signed int16 at vo, indices: nf*3 unsigned int16 at io,
## component a = qo[a] + raw * qs[a]. No centering term. Verified against `ext`.
func _decode(p: Dictionary, blob: PackedByteArray) -> Geo:
	var nv := int(p["nv"])
	var nf := int(p["nf"])
	var vo := int(p["vo"])
	var io := int(p["io"])
	var qo: Array = p["qo"]
	var qs: Array = p["qs"]
	var g := Geo.new()
	g.v.resize(nv)
	for i in nv:
		var b := vo + i * 6
		g.v[i] = Vector3(
			float(qo[0]) + float(blob.decode_s16(b)) * float(qs[0]),
			float(qo[1]) + float(blob.decode_s16(b + 2)) * float(qs[1]),
			float(qo[2]) + float(blob.decode_s16(b + 4)) * float(qs[2])
		)
	g.t.resize(nf * 3)
	for i in nf * 3:
		g.t[i] = blob.decode_u16(io + i * 2)
	return g


# ------------------------------------------------------------------- topology


## Merge vertices within tol via a hash grid sized to tol, checking the 27-cell
## neighbourhood so a pair straddling a cell boundary is still caught.
func _weld(g: Geo, tol: float) -> int:
	var grid := {}
	var out := PackedVector3Array()
	var remap := PackedInt32Array()
	remap.resize(g.v.size())
	var tol2 := tol * tol
	for i in g.v.size():
		var p := g.v[i]
		var c := Vector3i(floori(p.x / tol), floori(p.y / tol), floori(p.z / tol))
		var hit := -1
		for dx in range(-1, 2):
			for dy in range(-1, 2):
				for dz in range(-1, 2):
					var key := Vector3i(c.x + dx, c.y + dy, c.z + dz)
					if not grid.has(key):
						continue
					for j: int in grid[key]:
						if out[j].distance_squared_to(p) <= tol2:
							hit = j
							break
					if hit >= 0:
						break
				if hit >= 0:
					break
			if hit >= 0:
				break
		if hit < 0:
			hit = out.size()
			out.append(p)
			if not grid.has(c):
				grid[c] = []
			grid[c].append(hit)
		remap[i] = hit
	var merged := g.v.size() - out.size()
	g.v = out
	for i in g.t.size():
		g.t[i] = remap[g.t[i]]
	return merged


func _drop_degenerates(g: Geo, area_eps: float) -> int:
	var keep := PackedInt32Array()
	var dropped := 0
	for i in range(0, g.t.size(), 3):
		var a := g.t[i]
		var b := g.t[i + 1]
		var c := g.t[i + 2]
		if a == b or b == c or a == c:
			dropped += 1
			continue
		if (g.v[b] - g.v[a]).cross(g.v[c] - g.v[a]).length() * 0.5 < area_eps:
			dropped += 1
			continue
		keep.append(a)
		keep.append(b)
		keep.append(c)
	g.t = keep
	return dropped


func _edge_map(t: PackedInt32Array) -> Dictionary:
	var edges := {}
	for ti in t.size() / 3:
		for e in 3:
			var a := t[ti * 3 + e]
			var b := t[ti * 3 + (e + 1) % 3]
			var key := Vector2i(mini(a, b), maxi(a, b))
			if not edges.has(key):
				edges[key] = []
			edges[key].append(ti)
	return edges


func _slot_of(t: PackedInt32Array, ti: int, key: Vector2i) -> int:
	for e in 3:
		var x := t[ti * 3 + e]
		var y := t[ti * 3 + (e + 1) % 3]
		if mini(x, y) == key.x and maxi(x, y) == key.y:
			return e
	return -1


## +1 if triangle ti traverses the edge low->high, -1 if high->low, 0 if absent.
func _edge_dir(t: PackedInt32Array, ti: int, key: Vector2i) -> int:
	var slot := _slot_of(t, ti, key)
	if slot < 0:
		return 0
	return 1 if t[ti * 3 + slot] < t[ti * 3 + (slot + 1) % 3] else -1


func _flip(t: PackedInt32Array, ti: int) -> void:
	var s := t[ti * 3 + 1]
	t[ti * 3 + 1] = t[ti * 3 + 2]
	t[ti * 3 + 2] = s


## The reference leaves T-junctions behind: a vertex sitting partway along
## another triangle's edge, which reads as a crack because the long edge has no
## partner. Split that edge at every such vertex. Dropping the degenerate slivers
## above exposes more of them, which is why this runs after and iterates.
func _split_t_junctions(g: Geo) -> int:
	var splits := 0
	for _pass in TJUNCTION_PASSES:
		var edges := _edge_map(g.t)
		var bverts := PackedInt32Array()
		var seen := {}
		for key: Vector2i in edges:
			if edges[key].size() != 1:
				continue
			for vid in [key.x, key.y]:
				if not seen.has(vid):
					seen[vid] = true
					bverts.append(vid)
		if bverts.is_empty():
			break
		var plan := {}
		for key: Vector2i in edges:
			if edges[key].size() != 1:
				continue
			var ti: int = edges[key][0]
			if plan.has(ti):
				continue
			var slot := _slot_of(g.t, ti, key)
			if slot < 0:
				continue
			var a := g.t[ti * 3 + slot]
			var b := g.t[ti * 3 + (slot + 1) % 3]
			var pa := g.v[a]
			var ab := g.v[b] - pa
			var len2 := ab.length_squared()
			if len2 <= 0.0:
				continue
			var margin := TJUNCTION_TOL / sqrt(len2)
			var hits: Array = []
			for m: int in bverts:
				if m == a or m == b:
					continue
				var u := (g.v[m] - pa).dot(ab) / len2
				if u <= margin or u >= 1.0 - margin:
					continue
				if g.v[m].distance_to(pa + ab * u) > TJUNCTION_TOL:
					continue
				hits.append([u, m])
			if hits.is_empty():
				continue
			hits.sort_custom(func(x: Array, y: Array) -> bool: return x[0] < y[0])
			var mids := PackedInt32Array()
			for h: Array in hits:
				mids.append(h[1])
			plan[ti] = [slot, mids]
		if plan.is_empty():
			break
		var out := PackedInt32Array()
		for ti in g.tri_count():
			if not plan.has(ti):
				out.append(g.t[ti * 3])
				out.append(g.t[ti * 3 + 1])
				out.append(g.t[ti * 3 + 2])
				continue
			var slot: int = plan[ti][0]
			var mids: PackedInt32Array = plan[ti][1]
			var b := g.t[ti * 3 + (slot + 1) % 3]
			var c := g.t[ti * 3 + (slot + 2) % 3]
			var prev := g.t[ti * 3 + slot]
			for m: int in mids:
				out.append(prev)
				out.append(m)
				out.append(c)
				prev = m
				splits += 1
			out.append(prev)
			out.append(b)
			out.append(c)
		g.t = out
	return splits


## Flood fill triangles across shared edges. With `fix_winding` it corrects
## orientation on the way: two triangles agree on a shared edge when they
## traverse it in opposite directions, so agreeing in direction means one of them
## is inside out.
##
## Winding propagation deliberately stops at edges shared by three or more faces.
## Those are where the reference welded separate shells together and no
## orientation satisfies all three, so crossing one resolves nothing - it carries
## an arbitrary choice into a patch that was perfectly orientable on its own and
## leaves a trail of inside-out faces behind it. Each manifold patch is oriented
## on its own evidence instead. Returns {comp, count, flips}.
func _flood(g: Geo, edges: Dictionary, fix_winding: bool) -> Dictionary:
	var comp := PackedInt32Array()
	comp.resize(g.tri_count())
	comp.fill(-1)
	var flips := 0
	var groups := 0
	for seed in comp.size():
		if comp[seed] != -1:
			continue
		comp[seed] = groups
		var stack := PackedInt32Array([seed])
		while not stack.is_empty():
			var ti := stack[stack.size() - 1]
			stack.remove_at(stack.size() - 1)
			for e in 3:
				var a := g.t[ti * 3 + e]
				var b := g.t[ti * 3 + (e + 1) % 3]
				var key := Vector2i(mini(a, b), maxi(a, b))
				var adj: Array = edges[key]
				if fix_winding and adj.size() != 2:
					continue
				var mine := _edge_dir(g.t, ti, key)
				for other: int in adj:
					if other == ti or comp[other] != -1:
						continue
					if fix_winding and _edge_dir(g.t, other, key) == mine:
						_flip(g.t, other)
						flips += 1
					comp[other] = groups
					stack.append(other)
		groups += 1
	return {"comp": comp, "count": groups, "flips": flips}


## Edges whose faces traverse them the same way, i.e. disagree on which side is
## out. Split two ways, because they do not mean the same thing: on an ordinary
## two-face edge a disagreement means one face is inside out and you can see
## straight through it, and must be zero. On a branch edge shared by three or
## more faces no orientation satisfies every pair, so some disagreement is the
## honest answer and only its count is worth reporting.
func _count_conflicts(g: Geo, edges: Dictionary) -> Vector2i:
	var seam := 0
	var branch := 0
	for key: Vector2i in edges:
		var adj: Array = edges[key]
		var bad := 0
		for i in adj.size():
			for j in range(i + 1, adj.size()):
				if _edge_dir(g.t, adj[i], key) == _edge_dir(g.t, adj[j], key):
					bad += 1
		if adj.size() == 2:
			seam += bad
		else:
			branch += bad
	return Vector2i(seam, branch)


## Divergence-theorem volume about `origin`. Exact for closed surfaces; for open
## ones it still reports the sign correctly as long as the surface wraps the
## origin, which is why the component centroid is used and not world zero.
func _signed_volume(g: Geo, tris: PackedInt32Array, origin: Vector3) -> float:
	var sum := 0.0
	for ti: int in tris:
		var a := g.v[g.t[ti * 3]] - origin
		var b := g.v[g.t[ti * 3 + 1]] - origin
		var c := g.v[g.t[ti * 3 + 2]] - origin
		sum += a.dot(b.cross(c))
	return sum / 6.0


## Area-weighted vote of face normal against the outward radial direction. Used
## only when the signed volume is too near zero to trust (a near-flat shell).
func _outward_vote(g: Geo, tris: PackedInt32Array, origin: Vector3) -> float:
	var vote := 0.0
	for ti: int in tris:
		var a := g.v[g.t[ti * 3]]
		var b := g.v[g.t[ti * 3 + 1]]
		var c := g.v[g.t[ti * 3 + 2]]
		vote += (b - a).cross(c - a).dot((a + b + c) / 3.0 - origin)
	return vote


func _group_tris(comp: PackedInt32Array, count: int) -> Array:
	var groups: Array = []
	groups.resize(count)
	for i in count:
		groups[i] = PackedInt32Array()
	for ti in comp.size():
		groups[comp[ti]].append(ti)
	return groups


func _centroid_of(g: Geo, tris: PackedInt32Array) -> Vector3:
	var sum := Vector3.ZERO
	for ti: int in tris:
		sum += g.v[g.t[ti * 3]] + g.v[g.t[ti * 3 + 1]] + g.v[g.t[ti * 3 + 2]]
	return sum / maxf(1.0, float(tris.size() * 3))


func _bounds_of(g: Geo, tris: PackedInt32Array) -> AABB:
	if tris.is_empty():
		return AABB()
	var box := AABB(g.v[g.t[tris[0] * 3]], Vector3.ZERO)
	for ti: int in tris:
		for e in 3:
			box = box.expand(g.v[g.t[ti * 3 + e]])
	return box


## Flip whole patches until every one encloses positive volume, i.e. faces
## outward. Returns (triangles reversed, patches decided by the normal vote
## because their enclosed volume was too near zero to read).
func _orient_outward(g: Geo, groups: Array) -> Vector2i:
	var flipped := 0
	var voted := 0
	for tris: PackedInt32Array in groups:
		var origin := _centroid_of(g, tris)
		var box := _bounds_of(g, tris)
		var scale := maxf(box.size.x * box.size.y * box.size.z, 1.0e-12)
		var vol := _signed_volume(g, tris, origin)
		var inverted := vol < 0.0
		if absf(vol) < VOLUME_EPS * scale:
			inverted = _outward_vote(g, tris, origin) < 0.0
			voted += 1
		if not inverted:
			continue
		for ti: int in tris:
			_flip(g.t, ti)
		flipped += tris.size()
	return Vector2i(flipped, voted)


# --------------------------------------------------------------------- holes


## Boundary half-edges, as corner ids (triangle * 3 + slot).
func _boundary_halves(t: PackedInt32Array, edges: Dictionary) -> PackedInt32Array:
	var open := PackedInt32Array()
	for ti in t.size() / 3:
		for e in 3:
			var a := t[ti * 3 + e]
			var b := t[ti * 3 + (e + 1) % 3]
			if edges[Vector2i(mini(a, b), maxi(a, b))].size() == 1:
				open.append(ti * 3 + e)
	return open


func _head_of(t: PackedInt32Array, half: int) -> int:
	return t[(half / 3) * 3 + (half % 3 + 1) % 3]


func _dsu_find(parent: Dictionary, x: int) -> int:
	var r := x
	while parent[r] != r:
		r = parent[r]
	while parent[x] != r:
		var nxt: int = parent[x]
		parent[x] = r
		x = nxt
	return r


## A boundary edge with an endpoint that touches no other boundary edge bounds
## nothing: it is a zero-area slit where the reference gave a face no opposite
## number, not an aperture you could fan across. Supply that opposite face - the
## same triangle wound the other way, which faces inward and is backface-culled,
## so it costs one invisible triangle and no new vertices. Every edge it touches
## gains a face, so this can only ever reduce the boundary count.
func _close_slits(g: Geo) -> int:
	var edges := _edge_map(g.t)
	var halves := _boundary_halves(g.t, edges)
	if halves.is_empty():
		return 0
	var degree := {}
	for h: int in halves:
		for vid in [g.t[h], _head_of(g.t, h)]:
			degree[vid] = degree.get(vid, 0) + 1
	var fins := {}
	for h: int in halves:
		if degree[g.t[h]] == 1 or degree[_head_of(g.t, h)] == 1:
			fins[h / 3] = true
	for ti: int in fins:
		g.t.append(g.t[ti * 3])
		g.t.append(g.t[ti * 3 + 2])
		g.t.append(g.t[ti * 3 + 1])
	return fins.size()


## Group boundary half-edges into rims by connected component of the boundary
## graph, then close each rim with a fan to its own centroid: half-edge u->v gets
## cap triangle (v, u, centre), the one winding that keeps the shell consistently
## wound. Every boundary edge therefore gains exactly one second face, so the
## rims close whether or not they chain head-to-tail, and on the four worst parts
## in this set they do not chain, because the surface branches.
func _cap_boundaries(g: Geo) -> Dictionary:
	var edges := _edge_map(g.t)
	var halves := _boundary_halves(g.t, edges)
	if halves.is_empty():
		return {"capped": 0, "domed": 0, "bend": 0.0}
	var parent := {}
	for h: int in halves:
		for vid in [g.t[h], _head_of(g.t, h)]:
			if not parent.has(vid):
				parent[vid] = vid
	for h: int in halves:
		parent[_dsu_find(parent, g.t[h])] = _dsu_find(parent, _head_of(g.t, h))
	var rims := {}
	for h: int in halves:
		var root := _dsu_find(parent, g.t[h])
		if not rims.has(root):
			rims[root] = PackedInt32Array()
		rims[root].append(h)

	var domed := 0
	var worst := 0.0
	for root: int in rims:
		var rim: PackedInt32Array = rims[root]
		var verts := {}
		for h: int in rim:
			verts[g.t[h]] = true
			verts[_head_of(g.t, h)] = true
		var centre := Vector3.ZERO
		for vid: int in verts:
			centre += g.v[vid]
		centre /= float(verts.size())
		var radius := 0.0
		for vid: int in verts:
			radius = maxf(radius, g.v[vid].distance_to(centre))
		# Newell's area vector, summed over directed edges: the same quantity a
		# traversed loop would give, without needing the traversal.
		var area := Vector3.ZERO
		for h: int in rim:
			area += (g.v[g.t[h]] - centre).cross(g.v[_head_of(g.t, h)] - centre)
		if area.length() > 1.0e-12:
			var axis := area.normalized()
			var dev := 0.0
			for vid: int in verts:
				dev = maxf(dev, absf((g.v[vid] - centre).dot(axis)))
			var bend := dev / maxf(radius * 2.0, 1.0e-9)
			worst = maxf(worst, bend)
			if bend > PLANAR_TOL:
				domed += 1
		var ci := g.v.size()
		g.v.append(centre)
		for h: int in rim:
			g.t.append(_head_of(g.t, h))
			g.t.append(g.t[h])
			g.t.append(ci)
	return {"capped": rims.size(), "domed": domed, "bend": worst}


# ------------------------------------------------------------------- normals


func _face_normals(g: Geo) -> PackedVector3Array:
	var fn := PackedVector3Array()
	fn.resize(g.tri_count())
	for ti in g.tri_count():
		var a := g.v[g.t[ti * 3]]
		var b := g.v[g.t[ti * 3 + 1]]
		var c := g.v[g.t[ti * 3 + 2]]
		fn[ti] = (b - a).cross(c - a).normalized()
	return fn


## The two vertices joined to vid inside face f, in winding order (prev, next).
func _ring_at(t: PackedInt32Array, f: int, vid: int) -> Vector2i:
	for e in 3:
		if t[f * 3 + e] == vid:
			return Vector2i(t[f * 3 + (e + 2) % 3], t[f * 3 + (e + 1) % 3])
	return Vector2i(-1, -1)


## True when both faces contain the same edge through vid, i.e. they are
## neighbours across a crease rather than merely touching at a point.
func _share_edge_at(t: PackedInt32Array, fa: int, fb: int, vid: int) -> bool:
	var one := _ring_at(t, fa, vid)
	var two := _ring_at(t, fb, vid)
	return one.x == two.x or one.x == two.y or one.y == two.x or one.y == two.y


func _uf_find(parent: PackedInt32Array, i: int) -> int:
	var r := i
	while parent[r] != r:
		r = parent[r]
	while parent[i] != r:
		var nxt := parent[i]
		parent[i] = r
		i = nxt
	return r


## Split every vertex into one output vertex per smoothing group, where a group
## is a run of edge-connected incident faces whose normals stay inside the crease
## angle. Unreferenced vertices fall out for free.
func _build_surface(g: Geo, angle_deg: float) -> Array:
	var fn := _face_normals(g)
	var cos_thr := cos(deg_to_rad(angle_deg))
	var incident: Array = []
	incident.resize(g.v.size())
	for i in g.v.size():
		incident[i] = PackedInt32Array()
	for ti in g.tri_count():
		for e in 3:
			incident[g.t[ti * 3 + e]].append(ti * 3 + e)

	var out_v := PackedVector3Array()
	var out_n := PackedVector3Array()
	var out_i := PackedInt32Array()
	out_i.resize(g.t.size())
	for vid in g.v.size():
		var corners: PackedInt32Array = incident[vid]
		var m := corners.size()
		if m == 0:
			continue
		var parent := PackedInt32Array()
		parent.resize(m)
		for i in m:
			parent[i] = i
		for i in m:
			for j in range(i + 1, m):
				var fa := corners[i] / 3
				var fb := corners[j] / 3
				if fn[fa].dot(fn[fb]) < cos_thr:
					continue
				if not _share_edge_at(g.t, fa, fb, vid):
					continue
				parent[_uf_find(parent, i)] = _uf_find(parent, j)
		var accum := {}
		for i in m:
			var root := _uf_find(parent, i)
			var f := corners[i] / 3
			var ring := _ring_at(g.t, f, vid)
			var e0 := (g.v[ring.x] - g.v[vid]).normalized()
			var e1 := (g.v[ring.y] - g.v[vid]).normalized()
			var w := acos(clampf(e0.dot(e1), -1.0, 1.0))
			accum[root] = accum.get(root, Vector3.ZERO) + fn[f] * w
		var slot := {}
		for root: int in accum:
			slot[root] = out_v.size()
			out_v.append(g.v[vid])
			var nrm: Vector3 = accum[root]
			out_n.append(nrm.normalized() if nrm.length() > 1.0e-12 else Vector3.UP)
		for i in m:
			# Corner 0,1,2 goes out as 0,2,1. See WINDING in the header.
			var c: int = corners[i]
			out_i[c - c % 3 + (3 - c % 3) % 3] = slot[_uf_find(parent, i)]

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = out_v
	arrays[Mesh.ARRAY_NORMAL] = out_n
	arrays[Mesh.ARRAY_INDEX] = out_i
	return arrays


# ----------------------------------------------------------------------- bake


func _bake_part(index: int, p: Dictionary, blob: PackedByteArray) -> Dictionary:
	var g := _decode(p, blob)
	var row := {
		"index": index,
		"k": str(p.get("k", "")),
		"g": str(p.get("g", "")),
		"c": str(p.get("c", "")),
		"v0": g.v.size(),
		"t0": g.tri_count(),
		"bbox_err": _bbox_error(g, p)
	}

	row["merged"] = _weld(g, WELD_TOL)
	row["v1"] = g.v.size()
	row["degen"] = _drop_degenerates(g, DEGEN_AREA)
	row["be_raw"] = _boundary_halves(g.t, _edge_map(g.t)).size()
	row["splits"] = _split_t_junctions(g)

	var edges := _edge_map(g.t)
	var nonmanifold := 0
	for key: Vector2i in edges:
		if edges[key].size() > 2:
			nonmanifold += 1
	row["nonmanifold"] = nonmanifold

	var wind := _flood(g, edges, true)
	row["wflip"] = wind["flips"]
	row["comp"] = wind["count"]
	var orient := _orient_outward(g, _group_tris(wind["comp"], wind["count"]))
	row["cflip"] = orient.x
	row["voted"] = orient.y
	var conflicts := _count_conflicts(g, edges)
	row["conflict"] = conflicts.x
	row["branch_conflict"] = conflicts.y
	row["be0"] = _boundary_halves(g.t, edges).size()

	row["capped"] = 0
	row["domed"] = 0
	row["fins"] = 0
	row["bend"] = 0.0
	for _pass in CAP_PASSES:
		var slits := _close_slits(g)
		if slits > 0:
			row["fins"] += slits
			continue
		var caps := _cap_boundaries(g)
		if caps["capped"] == 0:
			break
		row["capped"] += caps["capped"]
		row["domed"] += caps["domed"]
		row["bend"] = maxf(row["bend"], caps["bend"])

	var edges2 := _edge_map(g.t)
	row["be1"] = _boundary_halves(g.t, edges2).size()
	row["t1"] = g.tri_count()

	var shells := _flood(g, edges2, false)
	var total := 0.0
	var worst := INF
	for tris: PackedInt32Array in _group_tris(shells["comp"], shells["count"]):
		var vol := _signed_volume(g, tris, _centroid_of(g, tris))
		total += vol
		worst = minf(worst, vol)
	row["volume"] = total
	row["min_comp_volume"] = worst
	row["watertight"] = row["be1"] == 0
	row["inverted"] = worst < 0.0

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, _build_surface(g, SMOOTH_ANGLE_DEG))
	var path := "%s/part_%02d.res" % [MESH_DIR, index]
	var err := ResourceSaver.save(mesh, path)
	if err != OK:
		push_error("bake_gun_parts: save failed for %s (%d)" % [path, err])
	row["mesh"] = path
	row["out_v"] = mesh.surface_get_array_len(0)
	return row


## Largest per-axis disagreement between the decoded bounding box and the size
## the reference recorded in `ext`. Anything above quantisation noise means the
## blob was read wrong.
func _bbox_error(g: Geo, p: Dictionary) -> float:
	if g.v.is_empty():
		return 0.0
	var lo := g.v[0]
	var hi := g.v[0]
	for q in g.v:
		lo = lo.min(q)
		hi = hi.max(q)
	var size := hi - lo
	var ext: Array = p.get("ext", [0.0, 0.0, 0.0])
	return maxf(
		maxf(absf(size.x - float(ext[0])), absf(size.y - float(ext[1]))),
		absf(size.z - float(ext[2]))
	)


# --------------------------------------------------------------------- output


func _socket_of(spec: Variant, key: String) -> GunSocket:
	if typeof(spec) != TYPE_DICTIONARY:
		return null
	var table: Dictionary = spec
	if not table.has(key):
		return null
	var entry: Array = table[key]
	var pos: Array = entry[0]
	return GunSocket.make(
		Vector3(float(pos[0]), float(pos[1]), float(pos[2])), float(entry[1]), float(entry[2])
	)


func _make_part(p: Dictionary, row: Dictionary) -> GunPart:
	var part := GunPart.new()
	part.index = row["index"]
	part.kind = StringName(row["k"])
	part.donor_group = StringName(row["g"])
	part.weapon_class = StringName(row["c"])
	var ext: Array = p.get("ext", [0.0, 0.0, 0.0])
	part.ext = Vector3(float(ext[0]), float(ext[1]), float(ext[2]))
	part.hull_volume = float(p.get("cv", 0.0))
	part.fit_height = float(p.get("fh", 0.0))
	part.fit_width = float(p.get("fw", 0.0))
	part.muzzle_radius = float(p.get("muz", -1.0))
	part.metal_color = Color.html(str(p.get("met", "#ffffff")))
	part.wood_color = Color.html(str(p.get("wd", "#ffffff")))
	var sockets: Variant = p.get("s", null)
	part.socket_front = _socket_of(sockets, "front")
	part.socket_rear = _socket_of(sockets, "rear")
	part.socket_bottom = _socket_of(sockets, "bottom")
	part.socket_top = _socket_of(sockets, "top")
	part.mesh_path = row["mesh"]
	part.boundary_edges = row["be1"]
	part.signed_volume = row["volume"]
	return part


func _save_manifest(defs: Array, rows: Array[Dictionary], blob: PackedByteArray) -> bool:
	var set_res := GunPartSet.new()
	var parts: Array[GunPart] = []
	var unrepaired := PackedInt32Array()
	for i in rows.size():
		parts.append(_make_part(defs[i], rows[i]))
		if rows[i]["be1"] != 0:
			unrepaired.append(rows[i]["index"])
	set_res.parts = parts
	set_res.unrepaired = unrepaired
	set_res.source_blob_bytes = blob.size()
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(blob)
	set_res.source_hash = ctx.finish().hex_encode()
	set_res.baked_at = Time.get_datetime_string_from_system(true)
	var err := ResourceSaver.save(set_res, MANIFEST_PATH)
	if err != OK:
		push_error("bake_gun_parts: save failed for %s (%d)" % [MANIFEST_PATH, err])
		return false
	return true


func _write_text(path: String, body: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_error("bake_gun_parts: cannot write %s" % path)
		return
	f.store_string(body)
	f.close()


func _all_pass(rows: Array[Dictionary]) -> bool:
	for r in rows:
		if r["inverted"] or not r["watertight"]:
			return false
	return true


func _cells(values: Array) -> String:
	var cells := PackedStringArray()
	for i in values.size():
		var text := str(values[i])
		cells.append(text.rpad(COL_WIDTH[i]) if i < 4 else text.lpad(COL_WIDTH[i]))
	return " ".join(cells)


func _report_header() -> PackedStringArray:
	var out := PackedStringArray()
	var tol := [
		String.num_scientific(WELD_TOL),
		String.num_scientific(DEGEN_AREA),
		String.num_scientific(TJUNCTION_TOL),
		SMOOTH_ANGLE_DEG,
		PLANAR_TOL
	]
	out.append("gun part mesh bake")
	out.append("source    %s" % HTML_PATH)
	out.append("manifest  %s" % MANIFEST_PATH)
	out.append("meshes    %s/part_00.res .. part_94.res" % MESH_DIR)
	out.append("weld %s  degenerate %s  t-junction %s  crease %.0f deg  planar %.2f" % tol)
	out.append("")
	out.append(_cells(Array(COL_HEAD.split(" "))))
	out.append("-".repeat(RULE_WIDTH))
	return out


func _table_row(r: Dictionary) -> String:
	var values: Array = []
	for field in COL_FIELD.split(" "):
		values.append(r[field])
	values.append("%.6f" % r["volume"])
	values.append("yes" if r["watertight"] else "NO")
	return _cells(values)


func _compose_report(rows: Array[Dictionary], msec: int, saved: bool) -> String:
	var out := _report_header()
	# Every integer a part row carries is a count worth totalling; the index is
	# the one that is an identity rather than a quantity.
	var tot := {}
	for field: String in rows[0]:
		if typeof(rows[0][field]) == TYPE_INT and field != "index":
			tot[field] = 0
	var inverted: Array[String] = []
	var leaky: Array[String] = []
	var flipped_parts := 0
	var worst_bbox := 0.0
	var worst_bend := 0.0
	for r in rows:
		out.append(_table_row(r))
		for k: String in tot:
			tot[k] += r[k]
		if r["cflip"] > 0:
			flipped_parts += 1
		if r["inverted"]:
			inverted.append("%d %s/%s" % [r["index"], r["k"], r["g"]])
		if not r["watertight"]:
			leaky.append("%d %s/%s (%d edges)" % [r["index"], r["k"], r["g"], r["be1"]])
		worst_bbox = maxf(worst_bbox, r["bbox_err"])
		worst_bend = maxf(worst_bend, r["bend"])
	out.append("-".repeat(RULE_WIDTH))
	out.append_array(_compose_totals(rows.size(), tot, flipped_parts, worst_bbox, worst_bend, msec))
	out.append("")
	if leaky.is_empty():
		out.append("watertight            all %d parts" % rows.size())
	else:
		out.append("NOT watertight (%d):" % leaky.size())
		for s in leaky:
			out.append("  %s" % s)
	if not saved:
		out.append("manifest              FAILED TO SAVE")
	out.append("")
	if not inverted.is_empty():
		out.append("RESULT: FAIL - %d parts still inverted:" % inverted.size())
		for s in inverted:
			out.append("  %s" % s)
	elif not leaky.is_empty():
		out.append("RESULT: FAIL - winding clean, but %d parts still open" % leaky.size())
	elif not saved:
		out.append("RESULT: FAIL - meshes repaired but the manifest did not save")
	else:
		out.append("RESULT: PASS - %d parts, 0 inverted, 0 open boundary edges" % rows.size())
	return "\n".join(out)


func _compose_totals(
	count: int, tot: Dictionary, flipped: int, bbox: float, bend: float, msec: int
) -> PackedStringArray:
	var out := PackedStringArray()
	var edges := [tot["be_raw"], tot["be0"], tot["be1"]]
	var rims := [tot["capped"], tot["domed"], bend]
	var branch := [tot["nonmanifold"], tot["branch_conflict"]]
	var chosen := [tot["comp"] - tot["voted"], tot["voted"]]
	out.append("")
	out.append("parts                 %d" % count)
	out.append("bbox error vs ext     %s  (quantisation noise)" % String.num_scientific(bbox))
	out.append("vertices  in / welded %d / %d" % [tot["v0"], tot["v0"] - tot["merged"]])
	out.append("triangles in / out    %d / %d" % [tot["t0"], tot["t1"]])
	out.append("degenerates dropped   %d" % tot["degen"])
	out.append("t-junctions split     %d" % tot["splits"])
	out.append("winding flips         %d" % tot["wflip"])
	out.append("patches reoriented    %d triangles across %d parts" % [tot["cflip"], flipped])
	out.append("patches oriented by   enclosed volume %d, normal vote %d" % chosen)
	out.append("branch edges          %d  (%d face-pair disagreements across them)" % branch)
	out.append(
		"inside-out seams      %d  (two-face edges disagreeing; must be 0)" % tot["conflict"]
	)
	out.append("boundary edges        %d raw -> %d after t-junctions -> %d after caps" % edges)
	out.append("rims capped           %d  (%d domed, worst bend %.3f of diameter)" % rims)
	out.append("slit fins added       %d" % tot["fins"])
	out.append("shipped vertices      %d" % tot["out_v"])
	out.append("bake time             %d ms" % msec)
	return out
