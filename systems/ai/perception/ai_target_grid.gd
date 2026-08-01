class_name AITargetGrid
extends RefCounted
## Broad phase for "who is near me", rebuilt once per index tick and read by every
## agent that ticks after it.
##
## A hashed uniform grid over XZ with a counting sort into one flat row array. The
## flat layout is the whole point: after the build there is exactly one
## PackedInt32Array of rows and one of bucket offsets, no per-cell array, so a
## rebuild allocates nothing once the arrays have reached their high-water mark
## and a query is a contiguous walk.
##
## Vertical extent is ignored. The ash flats are broad and low; bucketing by Y as
## well would triple the cell walk to separate bodies that a squared-distance
## reject rejects for free anyway.
##
## Buckets are hashed, so two distant cells can share one. That is why every entry
## carries its cell key and the query compares it: without that check a walk over
## a bounding box would hand back the same row twice from a colliding cell, and
## an agent would build awareness on one target at double rate.

## Power of two — the mask depends on it — and sized against the row count, not
## the world. Every build pays one prefix-sum pass over this table whatever `n`
## is, so a table much wider than the crowd is a fixed cost for nothing.
const BUCKETS: int = 256
const BUCKET_MASK: int = BUCKETS - 1
## Cells a single query may walk before it is cheaper to scan every row instead.
## A 400 m sight range at an 8 m cell is ten thousand cells against, at worst, a
## couple of hundred rows.
const CELL_WALK_LIMIT: int = 256
## Added to cell coordinates so a negative cell stays a distinct positive key
## after the shift, and so the hash never multiplies a negative.
const BIAS: int = 0x20000000
const HASH_X: int = 73856093
const HASH_Z: int = 19349663

var cell_size: float = 16.0
## Set false to make every query hand back the whole table. The broad phase only
## starts paying above roughly a hundred bodies, so a scene that will never get
## there can turn it off and skip the build; it is also the baseline the harness
## measures the grid against.
var enabled: bool = true

var _keys: PackedInt64Array = PackedInt64Array()
var _rows: PackedInt32Array = PackedInt32Array()
var _start: PackedInt32Array = PackedInt32Array()
var _row_key: PackedInt64Array = PackedInt64Array()
var _row_bucket: PackedInt32Array = PackedInt32Array()
var _n: int = 0


func _init(cell: float = 16.0) -> void:
	cell_size = maxf(cell, 0.5)
	_start.resize(BUCKETS + 1)


func size() -> int:
	return _n


func clear() -> void:
	_n = 0


## Bucket `count` rows of `pos`. O(n) plus one pass over the bucket table; no
## comparison sort, no allocation once the arrays have grown.
func build(pos: PackedVector3Array, count: int) -> void:
	_n = count
	if _row_key.size() < count:
		_row_key.resize(count)
		_row_bucket.resize(count)
		_keys.resize(count)
		_rows.resize(count)
	_start.fill(0)
	var inv: float = 1.0 / cell_size
	for row: int in count:
		var p: Vector3 = pos[row]
		var cx: int = floori(p.x * inv) + BIAS
		var cz: int = floori(p.z * inv) + BIAS
		var b: int = (cx * HASH_X ^ cz * HASH_Z) & BUCKET_MASK
		_row_key[row] = (cx << 32) | cz
		_row_bucket[row] = b
		_start[b + 1] += 1
	# _start[b + 1] holds bucket b's population; the running sum turns _start[b]
	# into the offset bucket b begins at. The scatter then consumes _start[b] as
	# its own write head, which leaves _start[b] sitting on bucket b's END. That
	# is deliberate — it saves copying the table to a second cursor array every
	# build, at the price of the read side taking its lower bound from _start[b - 1].
	for b: int in BUCKETS:
		_start[b + 1] += _start[b]
	for row: int in count:
		var b: int = _row_bucket[row]
		var at: int = _start[b]
		_start[b] = at + 1
		_rows[at] = row
		_keys[at] = _row_key[row]


## Append every row whose cell overlaps the XZ disc of `radius` about `center`
## into `out`. Rows are candidates, not hits: the caller still owes an exact
## distance test, which it was going to do anyway to reject on sight range.
## Returns the number appended. Falls back to handing back every row when the
## cell walk would cost more than the scan it is meant to avoid.
func query_sphere(center: Vector3, radius: float, out: PackedInt32Array) -> int:
	out.clear()
	if _n == 0:
		return 0
	if not enabled:
		for row: int in _n:
			out.append(row)
		return _n
	var inv: float = 1.0 / cell_size
	var min_x: int = floori((center.x - radius) * inv) + BIAS
	var max_x: int = floori((center.x + radius) * inv) + BIAS
	var min_z: int = floori((center.z - radius) * inv) + BIAS
	var max_z: int = floori((center.z + radius) * inv) + BIAS
	var cells: int = (max_x - min_x + 1) * (max_z - min_z + 1)
	if cells > CELL_WALK_LIMIT or cells >= _n:
		for row: int in _n:
			out.append(row)
		return _n
	# The hash and the key are written out rather than called: a GDScript function
	# call costs more than the arithmetic it would wrap, and this is the innermost
	# loop in the module. Everything that only depends on cx is hoisted. `build`
	# leaves _start[b] on bucket b's END, so the lower bound comes from b - 1.
	var found: int = 0
	var cx: int = min_x
	while cx <= max_x:
		var key_x: int = cx << 32
		var hash_x: int = cx * HASH_X
		var cz: int = min_z
		while cz <= max_z:
			var key: int = key_x | cz
			var b: int = (hash_x ^ cz * HASH_Z) & BUCKET_MASK
			var end: int = _start[b]
			var j: int = 0 if b == 0 else _start[b - 1]
			while j < end:
				if _keys[j] == key:
					out.append(_rows[j])
					found += 1
				j += 1
			cz += 1
		cx += 1
	return found
