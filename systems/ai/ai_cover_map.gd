class_name AICoverMap
extends Resource
## Runtime index over a baked `AICoverSet`: where one agent should be standing,
## plus a claim ledger so two of them never dive behind the same barrel.
##
## ONE QUERY ANSWERS TWO QUESTIONS. `query()` scores the cover field and the
## vantage field together and returns whichever won, so a body that should be
## kneeling behind a barrel and a body that should be on a roof both get their
## answer from the same call and neither caller has to know which is which. The
## returned index is opaque: feed it back to `point`, `claim`, `release`,
## `lean_position` and they decode it. `is_vantage()` is there for a debug
## overlay that wants to draw the two differently.
##
## WHICH ONE WINS IS DECIDED BY THE WEAPON, and specifically by the band
## `AICombat.engagement_band()` reports, which comes off the equipped
## `GunSpec.effective_range`. `AIVantage.min_band_range` is a hard floor under
## that: a body whose band tops out at nine metres never looks at a vantage point
## at all, so a scavenged shotgun cannot end up camping a rooftop at eighty
## metres however good the rooftop is.
##
## COVER IS CHOSEN AGAINST THE THREAT, NOT AGAINST THE FEET. Four terms decide
## it and only one of them is distance: how well the point's blocked sector faces
## the threat, whether it sits in the band the weapon works at, whether it lies on
## the approach lane this body has been given, and how far the walk is. The lane
## is what makes a flank read as a flank — see `lane_of`.
##
## Claims expire. An agent that dies mid-sprint, or one whose behaviour changed
## its mind, must not hold a firing position hostage for the rest of the fight, so
## a claim is a lease the holder has to keep renewing on its own tick.
##
## This is a `Resource` rather than a plain object for the same reason `AICombat`
## is: every number below is a tuning knob and knobs belong in the inspector. It
## holds no per-level state until `bind()`, so a director may keep authoring one
## and hand it the level's set on ready, or keep the default it constructs here.

## Seconds a claim survives without being renewed.
const CLAIM_LEASE: float = 3.0
## Vantage indices are offset by this so one integer names a point in either
## field. Well above any plausible cover count and well below 32-bit overflow.
const VANTAGE_BASE: int = 1 << 24

## Rejection ledger slots. `_score` charges every candidate it refuses to the
## FIRST gate that stopped it, in the order the gates are applied, and `query`
## charges every call to one outcome. Indices into `rejections()`.
##
## THIS EXISTS BECAUSE "COVER IS BARELY USED" IS NOT A DIAGNOSIS. Two hard gates
## here can zero a point outright — `band_reject` and the sector test — and before
## these counters there was no way to tell which one was firing, or whether the
## baked field simply had nothing inside the search radius to offer. Guessing at
## the weights without this is guessing.
## Candidates the grid walk visited.
const R_SCANNED: int = 0
## Leased to somebody else and not expired.
const R_CLAIMED: int = 1
## Inside the scanned cells but outside the search radius.
const R_TRAVEL: int = 2
## Further from the threat than `band.y * band_reject`.
const R_BAND: int = 3
## Nothing between it and the threat on that bearing.
const R_UNPROTECTED: int = 4
## Scored, and did not beat `min_score`.
const R_WEAK: int = 5
## Scored above `min_score`: a real candidate, whether or not it won.
const R_VIABLE: int = 6
## Calls to `query`.
const R_QUERIES: int = 7
## Calls whose grid walk found no baked point at all.
##
## NOT COMPARABLE WITH `refused`, and it will read higher. The vantage field is
## scanned before the cover grid and can answer a call whose grid walk then finds
## nothing, so a barren walk and an answered call are not exclusive. Read this
## against `scanned`, never against the refusal count.
const R_BARREN: int = 8
## Calls answered with a piece of cover.
const R_COVER: int = 9
## Calls answered with an overwatch position.
const R_VANTAGE: int = 10
## Calls answered from the refusal cooldown without scanning anything.
const R_THROTTLED: int = 11
## Calls that wanted a hole to hide in rather than a step to fire from — the
## `want_firing == false` path. Counted because "why does nothing ever take deep
## cover" is otherwise unanswerable: it may be that the query refuses them, or it
## may be that nothing is ever asking.
const R_HIDING: int = 12
## Calls the field could not better, answered with the point the body is already
## standing behind.
const R_KEPT: int = 13
## Grid cells the walk actually opened and read points out of.
##
## THIS IS THE SLOT THAT SEPARATES "THE LEVEL HAS NO COVER HERE" FROM "MY OWN
## CULL THREW IT AWAY", and without it `barren` is unreadable: a scan that saw
## nothing looks identical either way. Measured before it existed, the closer lane
## reported 2,040 barren scans of 2,059 and there was no way to tell whether the
## bake was thin or the threat disc was refusing whole cells unopened.
const R_CELLS: int = 14
## Cells inside the search square dropped unopened by the threat disc.
const R_CELL_CULL: int = 15
## Integer metres from body to threat, accumulated over every scan, so the lane's
## mean engagement range can be read off the ledger. A gate expressed in metres
## from the threat cannot be judged without knowing how far away the threat is.
const R_RANGE: int = 16
const R_COUNT: int = 17
const R_NAMES: PackedStringArray = [
	"scanned",
	"claimed",
	"travel",
	"band",
	"unprotected",
	"weak",
	"viable",
	"queries",
	"barren",
	"cover",
	"vantage",
	"throttled",
	"hiding",
	"kept",
	"cells",
	"cellcull",
	"range",
]
## The ledger is kept in two lanes, because one number over the whole population
## answers nothing. A body whose band tops out at a metre and a quarter — which is
## most of a creature roster — cannot reach cover fourteen metres away by
## construction, and it asks far more often than a rifleman does precisely because
## it never succeeds. Mixed together, the closers bury the shooters.
##
## Lane 0 is a SHOOTER: `band.y * band_reject` covers the whole search disc, so the
## band gate cannot refuse the field on its own. Lane 1 is a CLOSER: it can, and
## does.
const LANE_SHOOTER: int = 0
const LANE_CLOSER: int = R_COUNT
const LANE_NAMES: PackedStringArray = ["shooters", "closers"]

@export_group("Cover scoring")
## Score a point has to beat before it is worth walking to at all. Below this the
## query answers -1 and the caller stays where it is.
@export_range(0.0, 2.0, 0.01) var min_score: float = 0.05
## Weight on the point sitting at a range the weapon actually works at.
@export_range(0.0, 2.0, 0.01) var band_weight: float = 0.40
## Multiple of the band's top past which a point is not a firing position for
## this weapon at all, and is refused outright rather than scored down.
##
## Without this a body whose band tops out at a metre and a half — anything that
## bites — claims the barrel it happens to be standing next to sixty metres from
## the fight and holds it, because the distance, quality and facing terms alone
## clear the floor even with the band term at zero. Measured in the positioning
## harness before this existed: a Rat, a Picker and a shotgun Gasman all parked
## at 60 m from the contact and never closed. At 1.6 a marksman is unaffected
## (129 m of slack), a shotgun must be inside seven metres before cover means
## anything to it, and a thing with claws simply charges.
##
## IT ONLY APPLIES TO A FIRING POSITION — see `hide_min_range` — AND IT IS ONLY A
## FLOOR — see `advance_only`. Both of those exist because on its own this number
## refuses the entire close-quarters roster, and neither of the two attempts to
## carve an exception out of it worked:
##
## Measured over 90 s of the live firefight, before the hiding path was split out:
## of every candidate a body with a short band saw, this refused **100%** — 76,062
## of 76,062 — across 8,550 queries that returned nothing.
##
## Splitting the hiding path out did NOT fix it, and the ledger says why in one
## number: of 19,676 closer queries in 90 s, **five** were hiding queries.
## `AICombat.wants_cover()` is true only while reloading, dry, low or suppressed,
## so a body that is none of those asks for a FIRING position, comes back through
## here, and is refused. Measured after the split: closers opened 27 grid cells and
## had **1,570 culled** by this gate before they were read, 2,010 scans, **zero**
## answers. Seven of the twelve species in that demo fight with their limbs.
@export_range(1.0, 6.0, 0.05) var band_reject: float = 1.6
## Admit a firing candidate that is outside `band_reject` when it is no further
## from the threat than the body ALREADY IS. The band becomes a floor rather than
## the whole rule.
##
## THIS IS THE GATE `band_reject` WAS TRYING TO BE. What it was built to stop is on
## record: "a Rat, a Picker and a shotgun Gasman all parked at 60 m from the contact
## and never closed". That failure is not "the point is outside my weapon's band" —
## it is **cover that is not on the way in**, a body treating a barrel behind it as
## a firing position. Written as a multiple of the band it also refuses the crate
## two metres in front of a body already in contact, which is the one position you
## most want it to take, and for anything that bites there is no separation between
## the two cases at all: `band.y * 1.6` is about two metres, so the admissible disc
## about the threat is smaller than one grid cell and the walk comes back empty
## whatever the level has in it.
##
## Written as "never further from the fight than you already are" it refuses
## exactly the parked case, admits exactly the tuck-in case, and needs no second
## number: it is scale-free across a marksman at 120 m and a biter at 4 m. The
## admissible set is the lens between the caller's search disc about the body and a
## disc about the threat through the body — so a body can go sideways or forward
## into cover and can never go backwards into it. Off, this is the shipped
## behaviour of the two passes before it, and the closer lane answers nothing.
@export var advance_only: bool = true
## Metres from the threat inside which a point is refused to a body that only
## wants to STOP BEING SHOT. This is what `band_reject` becomes when `want_firing`
## is false, and it is a different question with a different answer.
##
## `band_reject` asks "is this a firing position for this weapon" — a shotgun that
## claims a barrel sixty metres from the fight has answered wrongly. A body that is
## reloading, pinned or breaking contact is not choosing a firing position at all;
## it wants the nearest solid thing, and its weapon's effective range has nothing
## to say about that. Applying the band there is what stopped every close-quarters
## body in the game from ever ducking. The only thing that has to be refused is
## cover taken IN THE ENEMY'S LAP, which is what this is: three metres, about two
## body lengths. The walk itself is already bounded by the caller's search radius.
@export_range(0.0, 20.0, 0.1) var hide_min_range: float = 3.0
## Weight on the point being close to the body that wants it.
@export_range(0.0, 2.0, 0.01) var travel_weight: float = 0.26
## Weight on the sampler's own quality figure — how much of the compass the point
## covers, biased toward points you can still shoot from.
@export_range(0.0, 2.0, 0.01) var quality_weight: float = 0.22
## Weight on the obstruction actually being between the point and the threat.
## The sector mask is a yes-or-no test at forty-five degree resolution; this is
## the term that separates a wall square-on to the fire from one edge-on to it.
@export_range(0.0, 2.0, 0.01) var facing_weight: float = 0.24
## Weight on the point lying along this body's approach lane. THIS IS THE FLANK.
@export_range(0.0, 2.0, 0.01) var flank_weight: float = 0.30
## Bonus for the point this body already holds. Pure hysteresis: without it an
## agent re-picks every tick and spends the fight shuffling between two barrels.
@export_range(0.0, 2.0, 0.01) var keep_bonus: float = 0.30
## Multiplier on full standing cover when the body wants to hide rather than
## shoot — reloading, pinned, or breaking contact. This is what rotates a
## suppressed body out of the crouch-height position it was firing from.
@export_range(1.0, 4.0, 0.01) var hide_bonus: float = 1.35

@export_group("Flanking")
## Share of bodies that take an arc around a contact instead of approaching it
## head on. At zero everybody walks straight at the fight.
@export_range(0.0, 1.0, 0.01) var flank_fraction: float = 0.5
## Degrees around the contact an arcing body aims to come in from, measured off
## its own current bearing. Half the squad left, half right.
@export_range(0.0, 90.0, 1.0) var flank_degrees: float = 42.0

@export_group("Vantage")
## Overwatch policy: what got baked, and which of it a given weapon wants. Null
## disables vantage selection and leaves this a pure cover map.
@export var vantage: AIVantage = null
## Seconds between one body's re-evaluations of the vantage field.
##
## THIS IS THE COST CONTROL. The scan is linear over the whole baked field and
## measures 24 microseconds against the 24 the cover grid costs — cheap once,
## expensive sixty times a second. Which roof to take is a decision that takes
## tens of seconds to act on, so re-taking it on every FULL tick buys nothing. A
## body already holding a position that still fits short-circuits out in one
## evaluation and does not scan at all.
@export_range(0.0, 8.0, 0.05) var vantage_period: float = 1.5

@export_group("Throttle")
## Seconds a body that was answered with NOTHING waits before scanning the field
## again. Zero lets it re-scan on every tick, which is what it used to do.
##
## THIS IS THE OTHER HALF OF THE COST CONTROL, and it was missing. A caller
## throttles itself once it HOLDS a point — `FirefightAgent.COVER_HOLD` and
## `ArenaBrain.COVER_HOLD` are both 2.4 s — but a refusal sets nothing, so a body
## standing where there is no cover asks again on its very next tick, at up to
## sixty hertz, forever. Measured over 90 s of the live firefight: 12,134 queries
## and 8 answers, with the failures re-asked so often that they buried the
## successes in every statistic taken over the query stream.
##
## Cleared the moment the body's intent changes — a shooter that starts reloading
## wants a hole NOW and must not be made to wait out a cooldown taken while it was
## looking for a firing step.
@export_range(0.0, 4.0, 0.05) var refusal_period: float = 0.8

var set_data: AICoverSet = null

var _cells: Dictionary = {}
## One ledger over both fields: cover occupies `[0, cover_count)` and vantage the
## run after it. A single pair of arrays rather than two, so nothing here has to
## pass a packed array into a function and depend on how GDScript copies it.
var _claim_owner: PackedInt32Array = PackedInt32Array()
var _claim_until: PackedFloat32Array = PackedFloat32Array()
## Approach-lane angle per agent, radians. Populated lazily from `agent_id`.
var _lane: Dictionary = {}
## Vantage point each agent currently holds, by agent id, as a public index. The
## reverse of the claim ledger, kept so a holder can be found without a scan.
var _holding: Dictionary = {}
## The same for ordinary cover, and it is what lets `query` answer "stay where you
## are" instead of "-1" when the field has nothing better to offer.
var _held_cover: Dictionary = {}
## Clock at which each agent may next re-evaluate the vantage field.
var _rescan: Dictionary = {}
## Agents whose last query came back empty, as `Vector2(until, want_firing)`. A
## value type, so holding one per body allocates nothing.
var _refused: Dictionary = {}
var _now: float = 0.0
## Why every candidate and every call has answered the way it did, since `bind`.
## Costs one integer add per scored candidate — at sixty-six bodies on a 2.4 s
## query hold that is about two thousand adds a second, which is nothing, and it
## is the only thing that makes the scoring gates measurable in a live demo.
var _reject: PackedInt32Array = PackedInt32Array()
## Which lane of `_reject` the grid walk in flight is charging. Set once per
## `query` rather than threaded through `_score`, which has arguments enough.
var _lane_base: int = LANE_SHOOTER
## Metres from the THREAT a firing candidate may be, for the query in flight.
## `band_reject` against the weapon's band, or the distance the body is already
## standing at, whichever is further — see `advance_only`. Set once per `query`
## for the same reason `_lane_base` is: `_score` has arguments enough, and the
## grid walk needs the identical number to cull whole cells with.
var _firing_reach: float = INF


func _init() -> void:
	if vantage == null:
		vantage = AIVantage.new()
	_reject.resize(R_COUNT * 2)


func bind(data: AICoverSet) -> void:
	set_data = data
	reset_rejections()
	_cells.clear()
	_lane.clear()
	_holding.clear()
	_held_cover.clear()
	_rescan.clear()
	_refused.clear()
	var n: int = 0 if data == null else data.size() + data.vantage_count()
	_claim_owner.resize(n)
	_claim_until.resize(n)
	for i: int in n:
		_claim_owner[i] = -1
		_claim_until[i] = 0.0
	if data == null:
		return
	for i: int in data.cell_keys.size():
		_cells[data.cell_keys[i]] = i


func is_ready() -> bool:
	return set_data != null and set_data.size() > 0


func advance(delta: float) -> void:
	_now += delta


## True when `i` names an overwatch position rather than a piece of cover.
func is_vantage(i: int) -> bool:
	return i >= VANTAGE_BASE


func vantage_count() -> int:
	return 0 if set_data == null else set_data.vantage_count()


## How many overwatch positions are leased right now, and how many pieces of
## ordinary cover. Reported rather than inferred, because "are the marksmen
## actually up on the roofs" is not answerable from a still frame and is the whole
## acceptance test for the vantage field. Returns `[vantage_held, cover_held]`.
func claims_held() -> Vector2i:
	if not is_ready():
		return Vector2i.ZERO
	var base: int = set_data.size()
	var vantage_held: int = 0
	var cover_held: int = 0
	for slot: int in _claim_owner.size():
		if _claim_owner[slot] < 0 or _claim_until[slot] <= _now:
			continue
		if slot >= base:
			vantage_held += 1
		else:
			cover_held += 1
	return Vector2i(vantage_held, cover_held)


## The rejection ledger, indexed by the `R_*` slots. Cumulative since `bind`.
func rejections() -> PackedInt32Array:
	return _reject


func reset_rejections() -> void:
	_reject.resize(R_COUNT * 2)
	for i: int in _reject.size():
		_reject[i] = 0


## One line of it, for an overlay row or a log: how the calls came out, then where
## the candidates went, once per lane. Empty when nothing has queried yet, so a
## demo with no cover consumer prints nothing rather than a row of zeroes.
func rejection_line() -> String:
	if _reject.is_empty() or _reject[R_QUERIES] + _reject[LANE_CLOSER + R_QUERIES] == 0:
		return ""
	var lanes := PackedStringArray()
	for lane: int in 2:
		var b: int = lane * R_COUNT
		if _reject[b + R_QUERIES] == 0:
			continue
		var calls: int = _reject[b + R_QUERIES]
		var scans: int = calls - _reject[b + R_THROTTLED]
		var answered: int = _reject[b + R_COVER] + _reject[b + R_VANTAGE] + _reject[b + R_KEPT]
		var refused: int = scans - answered
		var out: String = (
			(
				"%s %d asked (%d hiding) %d scanned -> %d cover %d kept %d vantage"
				+ " %d refused (%d barren) | %d seen:"
			)
			% [
				LANE_NAMES[lane],
				calls,
				_reject[b + R_HIDING],
				scans,
				_reject[b + R_COVER],
				_reject[b + R_KEPT],
				_reject[b + R_VANTAGE],
				refused,
				_reject[b + R_BARREN],
				_reject[b + R_SCANNED],
			]
		)
		for slot: int in [R_CLAIMED, R_TRAVEL, R_BAND, R_UNPROTECTED, R_WEAK, R_VIABLE]:
			out += " %s %d" % [R_NAMES[slot], _reject[b + slot]]
		out += (
			" | %d cells (%d culled) threat %.1f m"
			% [
				_reject[b + R_CELLS],
				_reject[b + R_CELL_CULL],
				float(_reject[b + R_RANGE]) / float(maxi(scans, 1)),
			]
		)
		lanes.append(out)
	return "  ||  ".join(lanes)


## The angle, in radians, this body comes in at: zero for a body that pushes
## straight down the middle, plus or minus `flank_degrees` for one that goes
## round. Measured off its own bearing to the contact, so an agent with a lane
## walks an arc around the target rather than a slightly-offset frontal line.
##
## Defaulted from the agent id rather than left at zero, because the alternative
## is every body in the game taking the shortest route to the same wall. It is
## stable for the life of a body — a flanker that has committed to the left keeps
## going left — and `set_agent_lane` overrides it for a squad that has actually
## assigned somebody the job.
func lane_of(agent_id: int) -> float:
	if _lane.has(agent_id):
		return _lane[agent_id]
	var h: int = hash(agent_id * 2654435761 + 101) & 0xFFFF
	var lane: float = 0.0
	if float(h >> 1) / 32767.0 < flank_fraction:
		lane = deg_to_rad(flank_degrees) * (1.0 if (h & 1) == 0 else -1.0)
	_lane[agent_id] = lane
	return lane


## Stable 0-1 spread off the agent id, so sixteen marksmen do not all re-evaluate
## the vantage field on the same frame.
static func _jitter(agent_id: int) -> float:
	return float(hash(agent_id * 40503 + 7) & 0xFFFF) / 65535.0


## Override one body's approach lane, in degrees. A squad that has assigned a
## flanker should call this with the side it wants covered; anything that does
## not gets the stable default above.
func set_agent_lane(agent_id: int, degrees: float) -> void:
	_lane[agent_id] = deg_to_rad(clampf(degrees, -180.0, 180.0))


## Best place for an agent standing at `from` to fight something at `threat`
## from, given the `band` metres its weapon works at.
##
## `agent_id` is the claim holder; a point already leased to someone else is
## skipped unless it is that agent's own. `want_firing` prefers a point it can
## shoot over and is what admits vantage points at all — pass false when the
## agent is reloading, pinned or withdrawing and only wants to stop being shot.
##
## Returns an index for `point()`, or -1 when there is nothing better than open
## ground. Cover is scanned over the grid cells inside `search_radius`; the
## vantage field is a linear scan over a few dozen points with three rejections
## in front of the arithmetic, which is cheaper than one extra grid cell.
func query(
	from: Vector3,
	threat: Vector3,
	band: Vector2,
	search_radius: float,
	agent_id: int,
	want_firing: bool
) -> int:
	if not is_ready():
		return -1
	_lane_base = (LANE_SHOOTER if band.y * band_reject >= search_radius else LANE_CLOSER)
	# How far from the THREAT a firing candidate may sit. The lane above still keys
	# off the band alone, because it names the KIND of body for the ledger and that
	# must not move when the body happens to be standing a long way off.
	_firing_reach = band.y * band_reject
	if advance_only:
		_firing_reach = maxf(_firing_reach, from.distance_to(threat))
	_reject[_lane_base + R_QUERIES] += 1
	if not want_firing:
		_reject[_lane_base + R_HIDING] += 1
	# A body that was told there is nothing here a moment ago is told so again
	# without another scan, unless what it wants has changed in the meantime.
	var wait: Vector2 = _refused.get(agent_id, Vector2.ZERO)
	if _now < wait.x and (wait.y > 0.5) == want_firing:
		_reject[_lane_base + R_THROTTLED] += 1
		return -1
	var best: int = -1
	var best_score: float = min_score
	if want_firing and vantage != null and vantage.applies(band.y):
		var limit: float = vantage.travel_limit(search_radius, band.y)
		var held: int = int(_holding.get(agent_id, -1))
		var due: bool = _now >= float(_rescan.get(agent_id, -1.0))
		if held >= 0 and not due:
			# Holding a position and not due to reconsider: one evaluation, and only
			# to check the fight has not moved out from under it.
			var v: int = held - VANTAGE_BASE
			if vantage.score_point(set_data, v, from, threat, band, limit, true) > 0.0:
				_reject[_lane_base + R_VANTAGE] += 1
				return held
		elif due:
			_rescan[agent_id] = _now + vantage_period * (0.75 + 0.5 * _jitter(agent_id))
			var base: int = set_data.size()
			for i: int in set_data.vantage_count():
				if not _available(base + i, agent_id):
					continue
				var mine: bool = _claim_owner[base + i] == agent_id
				var vs: float = vantage.score_point(set_data, i, from, threat, band, limit, mine)
				if vs > best_score:
					best_score = vs
					best = VANTAGE_BASE + i
	var lane: Vector3 = _lane_bearing(from, threat, agent_id)
	var size: float = set_data.cell_size
	var span: int = int(ceil(search_radius / size))
	var cx: int = int(floor(from.x / size))
	var cz: int = int(floor(from.z / size))
	var r2: float = search_radius * search_radius
	# A point that can win a FIRING query lies inside two discs, not one: the
	# caller's search radius about the body, and `band_reject` about the THREAT.
	# Culling on the second is exact — the gate in `_score` refuses everything
	# outside it — and it is most of the work for a body with a short band, which
	# scored twenty-four candidates per scan to refuse twenty-four. Measured over
	# 90 s of the live firefight, the closer lane scored 22,795 candidates and
	# refused 15,479 on that gate alone. A hiding body has no such disc.
	var t2: float = INF
	if want_firing:
		t2 = _firing_reach * _firing_reach
	_reject[_lane_base + R_RANGE] += int(from.distance_to(threat))
	var seen_before: int = _reject[_lane_base + R_SCANNED]
	for ox: int in range(-span, span + 1):
		# Whole columns and whole cells that cannot reach the search disc are
		# dropped before their contents are touched. The walk covers the square
		# that bounds the disc, so without this a fifth of every scan is spent
		# measuring points in the corners and throwing them away: measured over
		# 90 s of the live firefight, 71,725 of 153,097 candidates scored were
		# refused for distance alone.
		var gx: float = float(cx + ox) * size
		var dx: float = maxf(maxf(gx - from.x, from.x - gx - size), 0.0)
		if dx * dx > r2:
			continue
		var tx: float = maxf(maxf(gx - threat.x, threat.x - gx - size), 0.0)
		if tx * tx > t2:
			continue
		for oz: int in range(-span, span + 1):
			var gz: float = float(cz + oz) * size
			var dz: float = maxf(maxf(gz - from.z, from.z - gz - size), 0.0)
			if dx * dx + dz * dz > r2:
				continue
			var tz: float = maxf(maxf(gz - threat.z, threat.z - gz - size), 0.0)
			var slot: int = _cells.get(AICoverSet.key_from_cell(cx + ox, cz + oz), -1)
			if tx * tx + tz * tz > t2:
				# Charged only when the cell HELD points, so the counter reads "cover
				# this body was refused sight of" and not "empty squares walked".
				if slot >= 0:
					_reject[_lane_base + R_CELL_CULL] += 1
				continue
			if slot < 0:
				continue
			_reject[_lane_base + R_CELLS] += 1
			for i: int in range(set_data.cell_starts[slot], set_data.cell_starts[slot + 1]):
				var score: float = _score(i, from, threat, band, r2, agent_id, want_firing, lane)
				if score > best_score:
					best_score = score
					best = i
	if _reject[_lane_base + R_SCANNED] == seen_before:
		_reject[_lane_base + R_BARREN] += 1
	if best < 0:
		# NOTHING BETTER IS NOT A REASON TO STAND UP. A body re-scores the field
		# every couple of seconds, and a scan that comes back empty used to be
		# reported as "no cover", which made the caller drop the lease and walk
		# back into the open — from behind the very obstruction that was still
		# stopping rounds. `still_covered` exists for exactly this test and nothing
		# in the project called it. The threat has to have moved off the bearing
		# the point protects before the body is told to leave.
		var kept: int = _keep(agent_id, threat)
		if kept >= 0:
			_reject[_lane_base + R_KEPT] += 1
			return kept
		_refused[agent_id] = Vector2(_now + refusal_period, 1.0 if want_firing else 0.0)
		return -1
	_refused.erase(agent_id)
	if is_vantage(best):
		_reject[_lane_base + R_VANTAGE] += 1
	else:
		_reject[_lane_base + R_COVER] += 1
	return best


## Renew or take a lease. Returns false when someone else holds it.
func claim(i: int, agent_id: int) -> bool:
	var slot: int = _slot(i)
	if not _available(slot, agent_id):
		return false
	_claim_owner[slot] = agent_id
	_claim_until[slot] = _now + CLAIM_LEASE
	if is_vantage(i):
		_holding[agent_id] = i
	else:
		_held_cover[agent_id] = i
	return true


func release(i: int, agent_id: int) -> void:
	var slot: int = _slot(i)
	if slot < 0 or _claim_owner[slot] != agent_id:
		return
	_claim_owner[slot] = -1
	_claim_until[slot] = 0.0
	if is_vantage(i):
		if int(_holding.get(agent_id, -1)) == i:
			_holding.erase(agent_id)
	elif int(_held_cover.get(agent_id, -1)) == i:
		_held_cover.erase(agent_id)


## Position of point `i`. Out-of-range indices answer with the origin rather than
## faulting, so a caller can feed a failed `query()` straight back in.
func point(i: int) -> Vector3:
	if not is_ready():
		return Vector3.ZERO
	if is_vantage(i):
		var v: int = i - VANTAGE_BASE
		if v < 0 or v >= set_data.vantage_count():
			return Vector3.ZERO
		return set_data.vantage_positions[v]
	if i < 0 or i >= set_data.size():
		return Vector3.ZERO
	return set_data.positions[i]


## For cover, the direction from the obstruction toward open ground. For a
## vantage point, the bearing of the ground it overlooks — which is the direction
## the body should be facing in either case. Zero for a bad index.
func normal(i: int) -> Vector3:
	if not is_ready():
		return Vector3.ZERO
	if is_vantage(i):
		var v: int = i - VANTAGE_BASE
		if v < 0 or v >= set_data.vantage_count():
			return Vector3.ZERO
		return set_data.vantage_facing[v]
	if i < 0 or i >= set_data.size():
		return Vector3.ZERO
	return set_data.normals[i]


## Whether the point is full standing cover against a threat in that direction.
func is_full_cover(i: int, to_threat: Vector3) -> bool:
	return _protection(i, to_threat) == 2


## Does the agent's current position still count as cover against `threat`?
## Cheaper than a re-query and it is what stops an agent re-hiding every tick.
func still_covered(i: int, threat: Vector3) -> bool:
	var p: Vector3 = point(i)
	if p == Vector3.ZERO:
		return false
	var to_threat: Vector3 = threat - p
	to_threat.y = 0.0
	return _protection(i, to_threat) > 0


## Where to stand when leaning out of point `i` to shoot at `threat`: a step
## sideways along the obstruction rather than over the top of it, taken toward
## whichever side has the shorter walk. The peek cycle in `AICombat` decides
## when; this decides where.
func lean_position(i: int, threat: Vector3, lean: float) -> Vector3:
	var p: Vector3 = point(i)
	if p == Vector3.ZERO:
		return Vector3.ZERO
	var to_threat: Vector3 = threat - p
	to_threat.y = 0.0
	if to_threat.length_squared() < 1e-6:
		return p
	var side: Vector3 = to_threat.normalized().cross(Vector3.UP).normalized()
	# The baked normal points at open ground; lean toward whichever flank it
	# agrees with so the step is out from behind the obstruction, not into it.
	var n: Vector3 = normal(i)
	return p + side * (lean if side.dot(n) >= 0.0 else -lean)


## The bearing this body wants to arrive on, as a unit vector pointing away from
## the threat. Its own current bearing, rotated by its lane.
func _lane_bearing(from: Vector3, threat: Vector3, agent_id: int) -> Vector3:
	var axis: Vector3 = from - threat
	axis.y = 0.0
	if axis.length_squared() < 1e-6:
		return Vector3.ZERO
	axis = axis.normalized()
	var a: float = lane_of(agent_id)
	if is_zero_approx(a):
		return axis
	var ca: float = cos(a)
	var sa: float = sin(a)
	return Vector3(axis.x * ca - axis.z * sa, 0.0, axis.x * sa + axis.z * ca)


func _score(
	i: int,
	from: Vector3,
	threat: Vector3,
	band: Vector2,
	r2: float,
	agent_id: int,
	want_firing: bool,
	lane: Vector3
) -> float:
	_reject[_lane_base + R_SCANNED] += 1
	if not _available(i, agent_id):
		_reject[_lane_base + R_CLAIMED] += 1
		return 0.0
	var p: Vector3 = set_data.positions[i]
	var travel: float = from.distance_squared_to(p)
	if travel > r2:
		_reject[_lane_base + R_TRAVEL] += 1
		return 0.0
	var to_threat: Vector3 = threat - p
	to_threat.y = 0.0
	var d: float = maxf(to_threat.length(), 1e-3)
	# The range gate runs BEFORE the sector test: it is the coarser of the two, it
	# is two floats against a mask lookup and a branch, and putting it first means
	# the ledger charges a point that fails both to the gate that matters.
	#
	# WHICH gate it is depends on what the body is here for. Looking for a firing
	# step, the weapon's band decides; looking for a hole to reload in, only the
	# enemy's own lap is refused. See `band_reject` and `hide_min_range`.
	var wrong_range: bool = d > _firing_reach if want_firing else d < hide_min_range
	if wrong_range:
		_reject[_lane_base + R_BAND] += 1
		return 0.0
	var prot: int = set_data.protection(i, to_threat)
	if prot == 0:
		_reject[_lane_base + R_UNPROTECTED] += 1
		return 0.0
	# Crouch cover you can shoot over beats a hole you can only hide in, unless
	# hiding is the entire point of the move.
	var protection: float = 1.0 if prot == 1 else 0.72
	if not want_firing:
		protection = 0.7 if prot == 1 else hide_bonus
	var outside: float = maxf(band.x - d, 0.0) + maxf(d - band.y, 0.0)
	var span: float = maxf(band.y - band.x, 1.0)
	var band_k: float = clampf(1.0 - outside / span, 0.0, 1.0)
	var travel_k: float = clampf(1.0 - sqrt(travel) / maxf(sqrt(r2), 1.0), 0.0, 1.0)
	var s: float = protection * (0.34 + band_weight * band_k + travel_weight * travel_k)
	s += set_data.quality[i] * quality_weight
	# The normal points at open ground, so a point with the obstruction squarely
	# between it and the threat has its normal pointing squarely away from it.
	s += (-set_data.normals[i].dot(to_threat) / d * 0.5 + 0.5) * facing_weight
	if lane != Vector3.ZERO:
		s += (-to_threat.dot(lane) / d * 0.5 + 0.5) * flank_weight
	if _claim_owner[i] == agent_id:
		s += keep_bonus
	# Charged against `min_score` rather than against the running best, so the
	# ledger is independent of the order the grid walk happened to visit in.
	if s <= min_score:
		_reject[_lane_base + R_WEAK] += 1
	else:
		_reject[_lane_base + R_VIABLE] += 1
	return s


func _protection(i: int, to_threat: Vector3) -> int:
	if not is_ready():
		return 0
	if is_vantage(i):
		return set_data.vantage_protection(i - VANTAGE_BASE, to_threat)
	return set_data.protection(i, to_threat)


## The cover this agent is already standing behind, if it still holds the lease
## and the obstruction is still between it and `threat`. -1 otherwise.
func _keep(agent_id: int, threat: Vector3) -> int:
	var i: int = int(_held_cover.get(agent_id, -1))
	if i < 0 or i >= _claim_owner.size():
		return -1
	if _claim_owner[i] != agent_id or _claim_until[i] <= _now:
		return -1
	return i if still_covered(i, threat) else -1


## Ledger row for a public index, or -1 when it names nothing.
func _slot(i: int) -> int:
	if not is_ready():
		return -1
	if is_vantage(i):
		var v: int = i - VANTAGE_BASE
		return -1 if v < 0 or v >= set_data.vantage_count() else set_data.size() + v
	return -1 if i < 0 or i >= set_data.size() else i


## Whether `agent_id` may take ledger row `slot`: free, expired, or already its
## own.
func _available(slot: int, agent_id: int) -> bool:
	if slot < 0 or slot >= _claim_owner.size():
		return false
	return _claim_owner[slot] == -1 or _claim_owner[slot] == agent_id or _claim_until[slot] <= _now
