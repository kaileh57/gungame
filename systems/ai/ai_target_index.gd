# gdlint:ignore = max-public-methods
# `contact_priority` is the twenty-first public method and the project's limit is
# twenty. Suppressed here rather than raised project-wide: twenty of the twenty-one
# are one-line row accessors on a structure-of-arrays table, which is what that
# rule is least useful against, and lifting the bar for every class in the project
# to admit one scoring function is the wrong trade.
class_name AITargetIndex
extends RefCounted
## The director's flat table of everything the AI can perceive, plus the broad
## phase that keeps looking at it cheap.
##
## Structure-of-arrays on purpose. Perception is the hottest loop in the module
## and it reads five fields per row; an array of objects would touch five cache
## lines to reject a target that is four hundred metres away.
##
## Above a couple of dozen bodies the linear sweep stops being free, so `refresh`
## also rebuilds an `AITargetGrid` and `hostiles_near` answers out of it. The grid
## hands back candidates for one agent's sight range instead of the whole table,
## and falls back to the full sweep by itself when an agent's range is wide enough
## that walking cells would cost more.
##
## Rows are swap-removed, so a row index is only valid until the next removal.
## Anything that has to remember a target across ticks keys off `target_id`.
##
## The refresh also drives each body's own senses — stance, sun exposure, footfall
## noise, nerve. That work belongs to the body and lives on `AITarget`, but it has
## to be CLOCKED by something budgeted, and this is the only pass in the module
## that already walks every body at a fixed cost per tick. Putting it here means a
## hundred bodies emit footsteps and keep their morale for a bounded slice of the
## frame instead of a hundred nodes each running their own `_process`.

const FLAG_ALIVE: int = 1 << 0
const FLAG_PLAYER: int = 1 << 1
## Metres of slack added to a `hostiles_near` radius, covering the gap between a
## body's origin — which the grid buckets — and its aim point, which is what
## perception actually measures to.
const AIM_SLACK: float = 2.0
## The faction table's own script, preloaded so its CONSTANTS resolve at compile
## time. The autoload of the same name does not exist while a `--script` tool is
## compiling, and naming it here failed the whole dependency chain behind this
## file — `AITarget`, `EnemyActor`, `tools/build_enemies.gd`, `tools/build_arena.gd`.
const FactionTable := preload("res://systems/ai/factions.gd")
## Lowest and highest faction id, including the two pseudo-factions. Sized to
## `FactionTable.NEUTRAL_ID` through `FactionTable.F.CHOIR`.
const FACTION_MIN: int = -2
const FACTION_SPAN: int = 5

## The `Factions` autoload, resolved on first use. See `_hostile`.
static var _factions: Object = null

## Broad phase over the row positions. Rebuilt by `refresh`; its `cell_size` is
## the one knob and belongs to whoever owns the index.
var grid: AITargetGrid = AITargetGrid.new()
## Drive each body's stance, exposure, footfall and morale from the refresh. Off
## turns the whole population back into bare positions, which is what a harness
## measuring the broad phase on its own wants.
var senses_enabled: bool = true
## Metres within which another body counts as company for morale purposes.
var company_radius: float = 18.0
## Seconds between company counts for one row. The count is a grid query and it
## is the only part of the sense refresh that is not free, so it runs at a
## fraction of the rate the rest does.
var company_interval: float = 0.5
## Metres within which a death is witnessed by its friends.
var witness_radius: float = 22.0

## --- target priority ---------------------------------------------------------
##
## The terms `contact_priority` scores with. Plain vars rather than `@export`s
## because this class is a `RefCounted` and cannot carry them; whoever owns the
## index publishes the inspector knobs and pushes them down. `ArenaDirector` is
## the reference implementation of that.

## Extra weight the PLAYER is worth to a body that can see it, over and above an
## ordinary hostile. Zero makes the player just another body in the room.
var player_bias: float = 7.0
## Metres at which that extra weight has fallen to half. A player further away
## than a few of these is worth about what anybody else at the same range is.
var player_bias_range: float = 30.0
## Awareness at which the player bias is paid in full. Below it the bias scales
## down in proportion, and that is the whole of "not aggro'd on you".
var player_bias_awareness: float = 0.55
## Extra weight any contact is worth simply for being close. This is the term
## that starts a brawl between two hostile bodies that have walked into each
## other, and the one that lets a knife fight outrank a distant rifle.
var proximity_bias: float = 2.2
## Metres at which the closeness weight has fallen to half.
var proximity_range: float = 9.0
## Share of a contact's score that survives its remembered position being
## worthless. The same 0.45 floor `AIMemory.best_slot` ranks with.
var confidence_floor: float = 0.45
## Hand the PLAYER back FIRST from `hostiles_near`, ahead of every other candidate
## in range.
##
## This is a priority decision and not a perception one — the candidate list is
## unchanged, only its order — but it is the one that decides whether the scoring
## above ever gets a chance to run. `AIPerception.look` walks the list and spends
## at most three raycasts on it, so in a room holding ninety-odd bodies the player
## is ONE row among forty in range and gets looked at roughly three times in
## forty. Measured on the arena at 94 bodies with this off: **15 of 94 carried any
## contact on the player at all**, and ten of those fifteen chose the player — the
## scoring was doing its job on the handful of bodies that had ever noticed you.
##
## OFF BY DEFAULT, because it is a statement about a level and not about the AI: it
## is right for a test arena whose entire purpose is putting the bestiary in front
## of the player, and wrong for a three-faction war the player is a bystander in.
## `ArenaDirector` turns it on; the firefight leaves it off, where it is a no-op
## anyway for want of a player-faction row.
var player_first: bool = false

var _nodes: Array[AITarget] = []
var _pos: PackedVector3Array = PackedVector3Array()
var _eye: PackedVector3Array = PackedVector3Array()
var _aim: PackedVector3Array = PackedVector3Array()
var _vel: PackedVector3Array = PackedVector3Array()
var _faction: PackedInt32Array = PackedInt32Array()
var _flags: PackedInt32Array = PackedInt32Array()
var _radius: PackedFloat32Array = PackedFloat32Array()
var _visibility: PackedFloat32Array = PackedFloat32Array()
var _loudness: PackedFloat32Array = PackedFloat32Array()
var _id: PackedInt32Array = PackedInt32Array()
var _stamp: PackedFloat32Array = PackedFloat32Array()
var _allies: PackedInt32Array = PackedInt32Array()
var _hostiles: PackedInt32Array = PackedInt32Array()
var _company_at: PackedFloat32Array = PackedFloat32Array()
var _by_id: Dictionary = {}
var _by_collider: Dictionary = {}
var _next_id: int = 1
var _cursor: int = 0
var _clock: float = 0.0
var _candidates: PackedInt32Array = PackedInt32Array()
var _hostile_to: PackedInt32Array = PackedInt32Array()


func _init() -> void:
	_hostile_to.resize(FACTION_SPAN)


func size() -> int:
	return _nodes.size()


## Register a target. Assigns and returns its stable id; re-registering a node
## that is already in the table returns the id it already has.
func add(t: AITarget) -> int:
	if t == null:
		return -1
	var known: int = row_of(t.target_id)
	if known >= 0 and _nodes[known] == t:
		return t.target_id
	var id: int = _next_id
	_next_id += 1
	t.target_id = id
	var row: int = _nodes.size()
	_nodes.append(t)
	_pos.append(t.global_position)
	_eye.append(t.eye_point())
	_aim.append(t.aim_point())
	_vel.append(Vector3.ZERO)
	_faction.append(t.faction)
	_flags.append(_flags_for(t))
	_radius.append(t.body_radius)
	_visibility.append(t.visibility)
	_loudness.append(t.motion_loudness)
	_id.append(id)
	_stamp.append(_clock)
	_allies.append(0)
	_hostiles.append(0)
	# Staggered by row so a wave that spawns together does not take every company
	# count on the same tick.
	_company_at.append(_clock + float(row % 7) * 0.07)
	_by_id[id] = row
	var b: Node3D = t.body()
	if b != null:
		_by_collider[b.get_instance_id()] = id
	return id


func remove(t: AITarget) -> void:
	if t == null:
		return
	var row: int = row_of(t.target_id)
	if row < 0:
		return
	var b: Node3D = t.body()
	if b != null:
		_by_collider.erase(b.get_instance_id())
	_drop_row(row)


## Re-read every row from its node, difference the velocity, and rebuild the
## broad phase. Called once per index tick, never per agent.
func refresh(delta: float) -> void:
	_clock += delta
	var row: int = 0
	while row < _nodes.size():
		if not _read_row(row):
			continue
		row += 1
	_cursor = 0
	grid.build(_pos, _nodes.size())


## Refresh at most `rows` rows, resuming where the last call stopped, and rebuild
## the broad phase each time the sweep wraps. This is what lets a hundred bodies
## cost a fixed slice of the frame: a row's velocity is differenced against its
## own last stamp, so a row read every fourth tick still reports the right speed.
## Returns the number of rows actually read. `rows <= 0` means the whole table.
func refresh_budgeted(delta: float, rows: int) -> int:
	if rows <= 0:
		refresh(delta)
		return _nodes.size()
	_clock += delta
	if _nodes.is_empty():
		grid.clear()
		_cursor = 0
		return 0
	var read: int = 0
	var wanted: int = mini(rows, _nodes.size())
	while read < wanted and not _nodes.is_empty():
		if _cursor >= _nodes.size():
			_cursor = 0
		if _read_row(_cursor):
			_cursor += 1
		read += 1
	grid.build(_pos, _nodes.size())
	return read


func row_of(id: int) -> int:
	var row: int = _by_id.get(id, -1)
	return row


## Row of the target whose collider a raycast hit, or -1 if it hit scenery.
func row_of_collider(collider: Object) -> int:
	if collider == null:
		return -1
	var found: int = _by_collider.get(collider.get_instance_id(), -1)
	return -1 if found < 0 else row_of(found)


## Fill `out` with the rows of living targets hostile to `faction` whose origin is
## within `radius` (plus aim slack) of `from`. Returns the count. The caller still
## owes an exact test against whichever point it actually cares about.
##
## `want_hostile` false inverts the test and hands back everyone NOT hostile —
## friends and neutrals — which is what a body checking whether it is alone, or
## whether there is a teammate in its firing corridor, is actually asking. It is
## the same query with the same broad phase rather than a second method, because
## the expensive half is the grid walk and it is identical either way.
func hostiles_near(
	from: Vector3, radius: float, faction: int, out: PackedInt32Array, want_hostile: bool = true
) -> int:
	out.clear()
	var n: int = _nodes.size()
	if n == 0:
		return 0
	var wanted: int = 1 if want_hostile else 0
	for i: int in FACTION_SPAN:
		_hostile_to[i] = 1 if _hostile(faction, FACTION_MIN + i) else 0
	var reach: float = radius + AIM_SLACK
	var r2: float = reach * reach
	var count: int = grid.query_sphere(from, reach, _candidates)
	var found: int = 0
	var player_at: int = -1
	for k: int in count:
		var row: int = _candidates[k]
		# Same staleness guard as `_refresh_company`: the grid trails the table by
		# up to one refresh, and a target freed in between leaves a dangling row.
		if row >= n or (_flags[row] & FLAG_ALIVE) == 0:
			continue
		var f: int = _faction[row] - FACTION_MIN
		if f < 0 or f >= FACTION_SPAN or _hostile_to[f] != wanted:
			continue
		if _pos[row].distance_squared_to(from) > r2:
			continue
		if player_first and (_flags[row] & FLAG_PLAYER) != 0:
			player_at = found
		out.append(row)
		found += 1
	# One swap, and only when the caller asked for it and the player is actually in
	# the list. See `player_first` for why the ORDER of this list decides whether
	# the player is ever noticed in a crowded room.
	if player_at > 0:
		var head: int = out[0]
		out[0] = out[player_at]
		out[player_at] = head
	return found


## What a remembered contact is worth to a body deciding who to shoot at.
##
## THE PLAYER IS THE INTERESTING TARGET and every body that knows where they are
## should be coming for them — but a hard "always the player" switch produces a
## room full of hostile factions walking past each other with their backs turned,
## which is not a fight. What is wanted is a preference and not a mode:
## prioritise the player, and let two hostiles that have got close to each other
## while nobody is aware of the player go for each other instead.
##
## So this is a product of three interpretable terms and no branches:
##
## - **belief** — awareness scaled by confidence, the same shape
##   `AIMemory.best_slot` ranks on, so a thing you can see beats a thing you only
##   remember and a fresh contact beats a stale one.
## - **proximity** — a mild preference for the nearer of two contacts. This is
##   the term that makes "they got too close to each other" a real cause rather
##   than a special case.
## - **the player term** — a large bias that decays with range AND with how aware
##   of the player this body actually is.
##
## The awareness gate is what makes it read as a preference. A body that has only
## HEARD something the player did carries a near-zero awareness on that contact,
## so `belief` and the player bias collapse together and the rival standing two
## metres away wins outright — nine to one on the shipped numbers. The same body
## once it has eyes on the player carries awareness near one, the bias comes up to
## full weight, and the player wins from across the compound. Nothing flips; the
## two curves cross, at roughly "player at 55 m against a rival at 4 m".
##
## `row` is the contact's row, or -1 for something the index has never heard of —
## a bare "I was shot from over there" carries no target id and gets the ordinary
## hostile treatment, which is correct: the body does not know who shot it.
## `believed_at` is where the observer THINKS the contact is, not where it is, so
## the range terms reason about the same evidence the rest of the brain does.
func contact_priority(
	row: int, observer: Vector3, believed_at: Vector3, awareness: float, confidence: float
) -> float:
	if awareness <= 0.0:
		return 0.0
	var trust: float = confidence_floor + (1.0 - confidence_floor) * clampf(confidence, 0.0, 1.0)
	var d2: float = observer.distance_squared_to(believed_at)
	var score: float = awareness * trust * (1.0 + proximity_bias * _falloff(d2, proximity_range))
	if row < 0 or row >= _nodes.size() or (_flags[row] & FLAG_PLAYER) == 0:
		return score
	var gate: float = clampf(awareness / maxf(player_bias_awareness, 0.01), 0.0, 1.0)
	return score * (1.0 + player_bias * gate * _falloff(d2, player_bias_range))


## One over one plus the squared range ratio: full weight at contact, half weight
## at `scale` metres, and never quite zero. Squared throughout, so a priority
## solve over eight memory slots costs no square roots at all.
static func _falloff(d2: float, scale: float) -> float:
	var s: float = maxf(scale, 0.01)
	return 1.0 / (1.0 + d2 / (s * s))


func node(row: int) -> AITarget:
	return _nodes[row]


func id(row: int) -> int:
	return _id[row]


func position_at(row: int) -> Vector3:
	return _pos[row]


func eye(row: int) -> Vector3:
	return _eye[row]


func aim_point(row: int) -> Vector3:
	return _aim[row]


func velocity(row: int) -> Vector3:
	return _vel[row]


func faction(row: int) -> int:
	return _faction[row]


func body_radius(row: int) -> float:
	return _radius[row]


## How visible this body is RIGHT NOW: the authored figure with stance, sunlight
## and stillness already folded in by `AITarget.effective_visibility`. Perception
## multiplies its awareness gain by this and by nothing else about the target.
func visibility(row: int) -> float:
	return _visibility[row]


## Movement noise plus the rule of thumb that a body moving fast is easier to pick
## out of clutter than one standing still.
func loudness(row: int) -> float:
	return _loudness[row] + minf(_vel[row].length() * 0.14, 0.7)


func is_alive(row: int) -> bool:
	return (_flags[row] & FLAG_ALIVE) != 0


func is_player(row: int) -> bool:
	return (_flags[row] & FLAG_PLAYER) != 0


## Pull one row's state off its node, and give the body its budgeted sense step.
## Returns false when the node was gone and the row was dropped, in which case the
## caller must not advance past it.
func _read_row(row: int) -> bool:
	var t: AITarget = _nodes[row]
	if not is_instance_valid(t):
		_drop_row(row)
		return false
	var p: Vector3 = t.global_position
	var dt: float = maxf(_clock - _stamp[row], 1e-4)
	_vel[row] = (p - _pos[row]) / dt
	_stamp[row] = _clock
	_pos[row] = p
	_eye[row] = p + t.eye_offset
	_aim[row] = p + t.aim_offset
	_faction[row] = t.faction
	_radius[row] = t.body_radius
	var was_alive: bool = (_flags[row] & FLAG_ALIVE) != 0
	_flags[row] = _flags_for(t)
	var now_alive: bool = (_flags[row] & FLAG_ALIVE) != 0
	if was_alive and not now_alive:
		_announce_death(row)
	elif now_alive and not was_alive:
		# A pooled body just came back. It must not come back still flinching from
		# the round that killed it last wave, and it must not come back broken.
		t.reset_senses()
	if senses_enabled and t.alive:
		_refresh_company(row)
		t.refresh_senses(dt, _vel[row], _allies[row], _hostiles[row])
		_visibility[row] = t.effective_visibility()
		_loudness[row] = t.effective_loudness()
	else:
		_visibility[row] = t.visibility
		_loudness[row] = t.motion_loudness
	return true


## How many friends and how many enemies this body has around it. One grid query,
## rate-limited per row: morale changes over seconds, not over frames.
func _refresh_company(row: int) -> void:
	if _clock < _company_at[row]:
		return
	_company_at[row] = _clock + company_interval
	var mine: int = _faction[row]
	for i: int in FACTION_SPAN:
		_hostile_to[i] = 1 if _hostile(mine, FACTION_MIN + i) else 0
	var count: int = grid.query_sphere(_pos[row], company_radius, _candidates)
	var r2: float = company_radius * company_radius
	var live: int = _nodes.size()
	var friends: int = 0
	var foes: int = 0
	for k: int in count:
		var other: int = _candidates[k]
		# The grid is a tick old and this runs INSIDE the read loop, so a row freed
		# earlier in the same sweep has already been swap-removed out from under it.
		# Without this bound the first target to be freed indexes off the end of
		# every packed array in the class.
		if other >= live or other == row or (_flags[other] & FLAG_ALIVE) == 0:
			continue
		if _pos[other].distance_squared_to(_pos[row]) > r2:
			continue
		var f: int = _faction[other] - FACTION_MIN
		if f < 0 or f >= FACTION_SPAN:
			continue
		if _hostile_to[f] != 0:
			foes += 1
		elif _faction[other] == mine:
			friends += 1
	_allies[row] = friends
	_hostiles[row] = foes


## A body went down: tell its friends. This is the single biggest input to morale
## and it costs one grid query per death, which is a rounding error against the
## VFX the same death fires.
func _announce_death(row: int) -> void:
	var where: Vector3 = _pos[row]
	var mine: int = _faction[row]
	var count: int = grid.query_sphere(where, witness_radius, _candidates)
	var r2: float = witness_radius * witness_radius
	var live: int = _nodes.size()
	for k: int in count:
		var other: int = _candidates[k]
		if other >= live or other == row or (_flags[other] & FLAG_ALIVE) == 0:
			continue
		if _faction[other] != mine:
			continue
		if _pos[other].distance_squared_to(where) > r2:
			continue
		var node: AITarget = _nodes[other]
		if is_instance_valid(node):
			node.witness_death(where)


## Whether two factions shoot at each other, with the autoload resolved BY NAME
## rather than named. `hostile` reads the live stance matrix, so unlike the
## constants above it cannot come off the preloaded script. The fallback only
## fires with no autoload in the process, which is a bake tool, and no bake tool
## runs a target index.
func _hostile(a: int, b: int) -> bool:
	if _factions == null:
		if not Engine.has_singleton(&"Factions"):
			return a != b
		_factions = Engine.get_singleton(&"Factions")
	return bool(_factions.call(&"hostile", a, b))


func _flags_for(t: AITarget) -> int:
	var f: int = 0
	if t.alive:
		f |= FLAG_ALIVE
	if t.faction == FactionTable.PLAYER:
		f |= FLAG_PLAYER
	return f


func _drop_row(row: int) -> void:
	_by_id.erase(_id[row])
	var last: int = _nodes.size() - 1
	if row != last:
		_nodes[row] = _nodes[last]
		_pos[row] = _pos[last]
		_eye[row] = _eye[last]
		_aim[row] = _aim[last]
		_vel[row] = _vel[last]
		_faction[row] = _faction[last]
		_flags[row] = _flags[last]
		_radius[row] = _radius[last]
		_visibility[row] = _visibility[last]
		_loudness[row] = _loudness[last]
		_id[row] = _id[last]
		_stamp[row] = _stamp[last]
		_allies[row] = _allies[last]
		_hostiles[row] = _hostiles[last]
		_company_at[row] = _company_at[last]
		_by_id[_id[row]] = row
	_nodes.resize(last)
	_pos.resize(last)
	_eye.resize(last)
	_aim.resize(last)
	_vel.resize(last)
	_faction.resize(last)
	_flags.resize(last)
	_radius.resize(last)
	_visibility.resize(last)
	_loudness.resize(last)
	_id.resize(last)
	_stamp.resize(last)
	_allies.resize(last)
	_hostiles.resize(last)
	_company_at.resize(last)
