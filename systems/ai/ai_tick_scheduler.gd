class_name AITickScheduler
extends Node
## The AI level-of-detail clock. Decides which agents think this frame and how
## hard, inside a fixed per-frame budget.
##
## A hundred agents each running a full think at sixty hertz is six thousand
## thinks a second, and no amount of tightening the think itself makes that free.
## The way out is that almost none of it is observable: an agent forty metres
## behind you does not need to re-evaluate cover sixty times a second, and one
## beyond the fog does not need to at all. So agents are bucketed by distance to
## the viewer and by whether they are in front of it, each bucket gets a target
## rate, and a hard per-frame ceiling caps the lot.
##
## Every bucket has its own rotating cursor, which is what stops starvation: when
## the budget runs out mid-bucket the next frame resumes where it stopped rather
## than restarting at the top, so the two hundredth agent ticks exactly as often
## as the first. Buckets also get a reserved share of the budget before the
## leftovers are handed back down the list, so a brawl at your feet cannot stop
## the far half of the map from ever thinking.
##
## Elapsed time is per agent, not per frame: a far agent that ticks at four hertz
## is handed a delta of about a quarter second and integrates accordingly. That
## is why `AITickContext.delta` is documented as time since *this agent* last
## ticked.

## In view and close. Full think, effectively every frame.
const NEAR: int = 0
## Mid-field, or close but behind you. Full think at a reduced rate.
const MID: int = 1
## Far but still in the world. Cheap think only.
const FAR: int = 2
## Beyond the far radius. Kept warm at a crawl so it is not a cold start when
## you turn round.
const DORMANT: int = 3
const BUCKET_COUNT: int = 4

## Run the whole behaviour: perception, target selection, cover, path requests.
const KIND_FULL: int = 0
## Run the approximation: no raycasts, no cover query, coarse movement.
const KIND_CHEAP: int = 1

@export_group("Buckets")
## Metres inside which an agent is NEAR.
@export_range(2.0, 120.0, 0.5) var near_radius: float = 22.0
## Metres inside which an agent is at worst MID.
@export_range(5.0, 300.0, 0.5) var mid_radius: float = 55.0
## Metres inside which an agent is at worst FAR. Beyond it, DORMANT.
@export_range(10.0, 800.0, 1.0) var far_radius: float = 140.0
## Push agents outside the viewer's cone down one bucket. What is behind you
## does not need to be sharp, and this is most of the saving in a corridor.
@export var offscreen_demote: bool = true
## Full angle of the viewer cone used for that test, in degrees. Deliberately
## wider than the camera's field of view so agents do not visibly dumb down at
## the screen edge.
@export_range(40.0, 300.0, 1.0) var viewer_cone_degrees: float = 150.0
## Agents re-bucketed per frame, round robin. Re-bucketing is a distance compare
## and a dot product, so this can be generous; the cap only exists so a very
## large population cannot spike on the arithmetic.
@export_range(4, 512, 4) var rebucket_per_frame: int = 64

@export_group("Rates")
## Target thinks per second for a NEAR agent. At or above the frame rate this
## means every frame.
@export_range(1.0, 120.0, 1.0) var near_hz: float = 60.0
@export_range(0.5, 60.0, 0.5) var mid_hz: float = 15.0
@export_range(0.1, 30.0, 0.1) var far_hz: float = 4.0
@export_range(0.02, 10.0, 0.02) var dormant_hz: float = 0.5

@export_group("Budget")
## Hard ceiling on agent ticks per frame. This is the number that decides the
## frame cost of the AI; everything else only decides who spends it.
@export_range(1, 512, 1) var agents_per_frame: int = 48
## Fraction of the budget reserved for NEAR before leftovers are redistributed.
@export_range(0.0, 1.0, 0.01) var near_share: float = 0.55
@export_range(0.0, 1.0, 0.01) var mid_share: float = 0.25
@export_range(0.0, 1.0, 0.01) var far_share: float = 0.15
@export_range(0.0, 1.0, 0.01) var dormant_share: float = 0.05
## Raycasts handed to the whole population per frame, via `AITickContext`.
@export_range(0, 512, 1) var ray_budget_per_frame: int = 24
## Path queries advertised to the population per frame. Keep this in step with
## the path service's own ceiling; this is the number agents ration against.
@export_range(0, 128, 1) var path_budget_per_frame: int = 8

var _agents: Array[Object] = []
var _pos: PackedVector3Array = PackedVector3Array()
var _bucket: PackedInt32Array = PackedInt32Array()
var _accum: PackedFloat32Array = PackedFloat32Array()
var _pinned: PackedInt32Array = PackedInt32Array()
var _handle: PackedInt32Array = PackedInt32Array()
var _slot: PackedInt32Array = PackedInt32Array()
var _row_of: Dictionary = {}
var _next_handle: int = 1

var _members: Array[PackedInt32Array] = []
var _member_used: PackedInt32Array = PackedInt32Array()
var _cursor: PackedInt32Array = PackedInt32Array()

var _due_row: PackedInt32Array = PackedInt32Array()
var _due_delta: PackedFloat32Array = PackedFloat32Array()
var _due_used: int = 0

var _ticks: PackedInt32Array = PackedInt32Array()
var _frames: int = 0
var _now: float = 0.0
var _rebucket_cursor: int = 0
var _viewer_pos: Vector3 = Vector3.ZERO
var _viewer_forward: Vector3 = Vector3.FORWARD
var _cone_cos: float = -1.0


func _init() -> void:
	_members.resize(BUCKET_COUNT)
	for b: int in BUCKET_COUNT:
		_members[b] = PackedInt32Array()
	_member_used.resize(BUCKET_COUNT)
	_cursor.resize(BUCKET_COUNT)
	_ticks.resize(BUCKET_COUNT)


## Add an agent. The returned handle is what every other call takes; it is stable
## across other agents dying, which a row index is not.
##
## New agents start DORMANT with a full accumulator, so the first `begin_frame`
## after a spawn wave buckets them properly and ticks them immediately rather
## than leaving them frozen for a quarter second.
func add_agent(agent: Object, p: Vector3) -> int:
	var h: int = _next_handle
	_next_handle += 1
	var row: int = _agents.size()
	_agents.append(agent)
	_pos.append(p)
	_bucket.append(DORMANT)
	_accum.append(999.0)
	_pinned.append(0)
	_handle.append(h)
	_slot.append(-1)
	_row_of[h] = row
	_join(row, DORMANT)
	return h


func remove_agent(handle: int) -> void:
	var row: int = _row_of.get(handle, -1)
	if row < 0:
		return
	_leave(row)
	var last: int = _agents.size() - 1
	if row != last:
		_agents[row] = _agents[last]
		_pos[row] = _pos[last]
		_bucket[row] = _bucket[last]
		_accum[row] = _accum[last]
		_pinned[row] = _pinned[last]
		_handle[row] = _handle[last]
		_slot[row] = _slot[last]
		_row_of[_handle[row]] = row
		var b: int = _bucket[row]
		if _slot[row] >= 0:
			var list: PackedInt32Array = _members[b]
			list[_slot[row]] = row
			_members[b] = list
	_row_of.erase(handle)
	_agents.resize(last)
	_pos.resize(last)
	_bucket.resize(last)
	_accum.resize(last)
	_pinned.resize(last)
	_handle.resize(last)
	_slot.resize(last)


func clear() -> void:
	_agents.clear()
	_pos.clear()
	_bucket.clear()
	_accum.clear()
	_pinned.clear()
	_handle.clear()
	_slot.clear()
	_row_of.clear()
	_due_used = 0
	for b: int in BUCKET_COUNT:
		_member_used[b] = 0
		_cursor[b] = 0


## Where the agent is, for bucketing. The owner writes this once per frame for
## everything it moved; agents that did not move do not need the call.
func set_agent_position(handle: int, p: Vector3) -> void:
	var row: int = _row_of.get(handle, -1)
	if row >= 0:
		_pos[row] = p


## Hold an agent at NEAR regardless of where it is. For the ones actively
## shooting at you from across the map, whose aim would visibly stutter at four
## hertz. Use it sparingly — every pin is a full think you are paying for.
func pin(handle: int, pinned: bool) -> void:
	var row: int = _row_of.get(handle, -1)
	if row >= 0:
		_pinned[row] = 1 if pinned else 0


## Open the frame: age every accumulator, re-bucket a slice of the population,
## then fill the due list inside the budget. Call once, then walk the due list.
func begin_frame(delta: float, viewer_pos: Vector3, viewer_forward: Vector3) -> void:
	_now += delta
	_frames += 1
	_viewer_pos = viewer_pos
	var f: Vector3 = viewer_forward
	_viewer_forward = Vector3.FORWARD if f.length_squared() < 1e-6 else f.normalized()
	_cone_cos = cos(deg_to_rad(clampf(viewer_cone_degrees, 40.0, 300.0) * 0.5))
	var n: int = _agents.size()
	for i: int in n:
		_accum[i] += delta
	_rebucket_slice(n)
	_select(n)


## Hand the frame's shared pools to the tick context. Kept here because the
## budget and the pools are the same decision: how much AI this frame costs.
func begin_context(ctx: AITickContext) -> void:
	ctx.begin_frame(ray_budget_per_frame, path_budget_per_frame, _now)


## How many agents are due this frame.
func due_count() -> int:
	return _due_used


func due_agent(i: int) -> Object:
	return _agents[_due_row[i]]


func due_handle(i: int) -> int:
	return _handle[_due_row[i]]


## Seconds since that agent last ticked. Feed this to `AITickContext.delta`, not
## the frame delta — a far agent is integrating a quarter of a second.
func due_delta(i: int) -> float:
	return _due_delta[i]


## KIND_FULL or KIND_CHEAP. The agent's own tick branches on it.
func due_kind(i: int) -> int:
	return KIND_CHEAP if _bucket[_due_row[i]] >= FAR else KIND_FULL


func due_bucket(i: int) -> int:
	return _bucket[_due_row[i]]


func agent_count() -> int:
	return _agents.size()


func bucket_population(b: int) -> int:
	return _member_used[b]


## Cumulative ticks handed to a bucket since the last `reset_stats`. The ratio
## between these is the whole point of the scheduler, so it is worth watching.
func bucket_ticks(b: int) -> int:
	return _ticks[b]


func frames_elapsed() -> int:
	return _frames


func clock() -> float:
	return _now


func reset_stats() -> void:
	for b: int in BUCKET_COUNT:
		_ticks[b] = 0
	_frames = 0


func _bucket_interval(b: int) -> float:
	match b:
		NEAR:
			return 1.0 / maxf(near_hz, 0.01)
		MID:
			return 1.0 / maxf(mid_hz, 0.01)
		FAR:
			return 1.0 / maxf(far_hz, 0.01)
		_:
			return 1.0 / maxf(dormant_hz, 0.01)


func _bucket_share(b: int) -> float:
	match b:
		NEAR:
			return near_share
		MID:
			return mid_share
		FAR:
			return far_share
		_:
			return dormant_share


## Re-bucket `rebucket_per_frame` agents starting where we left off. Spreading it
## means a distant agent can be one frame late to promote, which at the distances
## involved is invisible.
func _rebucket_slice(n: int) -> void:
	if n == 0:
		return
	var count: int = mini(rebucket_per_frame, n)
	var near_sq: float = near_radius * near_radius
	var mid_sq: float = mid_radius * mid_radius
	var far_sq: float = far_radius * far_radius
	for k: int in count:
		var i: int = _rebucket_cursor % n
		_rebucket_cursor = i + 1
		var b: int = DORMANT
		if _pinned[i] != 0:
			b = NEAR
		else:
			var to: Vector3 = _pos[i] - _viewer_pos
			var d2: float = to.length_squared()
			if d2 <= near_sq:
				b = NEAR
			elif d2 <= mid_sq:
				b = MID
			elif d2 <= far_sq:
				b = FAR
			if offscreen_demote and b < DORMANT and d2 > 1e-4:
				if to.normalized().dot(_viewer_forward) < _cone_cos:
					b += 1
		if b != _bucket[i]:
			_leave(i)
			_bucket[i] = b
			_join(i, b)


## Fill the due list. Two sweeps: the first honours each bucket's reserved share,
## the second hands whatever is left back down the priority order. Both walk the
## bucket's rotating cursor, which is where the fairness comes from.
func _select(n: int) -> void:
	_due_used = 0
	if n == 0:
		return
	if _due_row.size() < agents_per_frame:
		_due_row.resize(agents_per_frame)
		_due_delta.resize(agents_per_frame)
	var remaining: int = agents_per_frame
	for b: int in BUCKET_COUNT:
		if remaining <= 0:
			break
		var reserved: int = int(ceil(float(agents_per_frame) * _bucket_share(b)))
		remaining -= _drain(b, mini(reserved, remaining))
	for b: int in BUCKET_COUNT:
		if remaining <= 0:
			break
		remaining -= _drain(b, remaining)


## Take up to `cap` due agents from one bucket, resuming at its cursor and
## stopping after one full lap so a bucket with nothing ready cannot spin.
func _drain(b: int, cap: int) -> int:
	if cap <= 0:
		return 0
	var used: int = _member_used[b]
	if used == 0:
		return 0
	var list: PackedInt32Array = _members[b]
	var interval: float = _bucket_interval(b)
	var taken: int = 0
	var c: int = _cursor[b] % used
	for k: int in used:
		if taken >= cap:
			break
		var i: int = list[c]
		c += 1
		if c >= used:
			c = 0
		if _accum[i] < interval:
			continue
		_due_row[_due_used] = i
		_due_delta[_due_used] = _accum[i]
		_due_used += 1
		_accum[i] = 0.0
		_ticks[b] += 1
		taken += 1
	_cursor[b] = c
	return taken


func _join(row: int, b: int) -> void:
	var list: PackedInt32Array = _members[b]
	var used: int = _member_used[b]
	if used >= list.size():
		list.resize(maxi(used * 2, 16))
	list[used] = row
	_members[b] = list
	_slot[row] = used
	_member_used[b] = used + 1


func _leave(row: int) -> void:
	var s: int = _slot[row]
	if s < 0:
		return
	var b: int = _bucket[row]
	var used: int = _member_used[b]
	var list: PackedInt32Array = _members[b]
	var last: int = used - 1
	if s != last:
		var moved: int = list[last]
		list[s] = moved
		_slot[moved] = s
		_members[b] = list
	_member_used[b] = last
	_slot[row] = -1
	if _cursor[b] >= last:
		_cursor[b] = 0
