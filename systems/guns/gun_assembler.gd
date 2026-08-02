class_name GunAssembler
extends RefCounted
## Socket fitting and the whole ballistics derivation: five scavenged parts in,
## a fully specified `GunSpec` out.
##
## Nothing here is rolled. The reference derives real numbers from the geometry —
## receiver length becomes case length, the barrel's thinnest section becomes
## bore, case volume becomes powder, powder plus barrel length becomes muzzle
## energy, and the recoil pattern falls out of impulse over mass. This file is
## that derivation, in the reference's own execution order.
##
## THE ORDER IS LOAD-BEARING. `reload` is computed from the pre-archetype
## capacity; `cap` is then rewritten; `spread` is written four separate times
## before it is final. Moving a line changes every stat downstream of it. The
## only sanctioned deviations are the ones `GunTuning` names, and each of those
## is applied at the exact point the reference's own value would have been read,
## so `GunTuning.reference_exact()` reproduces the golden vectors bit for bit.

## Below this the recorded mating-face height is a data defect, not a thin cut.

const SCOPE_ZOOM: float = 4.2  # optic magnification that reads as a scope
const ZERO_FIT_HEIGHT: float = 1.0e-4
## The reference's guard against dividing by a zero-height cut face. Keep it:
## with it, part 70 lands on `err = 13.59`; without it, on `inf`.
const FIT_EPS: float = 1.0e-6

## Rounds per minute no action reaches however light its bolt. The reference's own
## cyclic clamp, kept as the hard ceiling on the mechanical rate.
const CYCLIC_CEILING: float = 1850.0
## Millimetres of case below which the bolt stroke stops shrinking. A pistol-length
## action still has to unlock, extract, feed and re-lock, so the stroke term is
## measured against this and never rewards a case shorter than it.
const CYCLIC_STROKE_FLOOR: float = 30.0
## Most of its cycle rate a badly mated action may lose to `fit_error`.
const CYCLIC_FIT_FLOOR: float = 0.45
## Rounds per minute below which a semi-auto stops being a weapon and becomes a
## single-shot with extra steps.
const SEMI_FLOOR_RPM: float = 60.0

## Moment of inertia in kg·m² that halves the swing handling score. A 4.5 kg,
## 900 mm rifle sits at 3.6; a 1.2 kg, 300 mm snubnose at 0.11.
##
## 2.9 is not free: handling is a 1-99 RATING that `score` and `grade` both read,
## so the swing model has to re-rank the roster without deflating it. At 1.6 the
## mean handling over 2 000 builds fell 53.9 -> 38.4 and took mean score down with
## it, which moved 160 weapons a tier down for no design reason. 2.9 puts the mean
## back on the reference's and keeps the widened ends.
const SWING_REFERENCE: float = 2.9
## Millimetres of stock at which the weapon counts as fully shouldered. Everything
## between a pistol grip and this is a partial shoulder and gets a partial share.
const SHOULDER_FULL: float = 200.0
## The rate band the recoil character reads as slow and as fast, rpm. A weapon at
## or under the low mark shoves once; one at or over low+span climbs and walks.
const TEMPO_LOW_RPM: float = 200.0
const TEMPO_SPAN_RPM: float = 900.0

## Extra muzzle rise a weapon with no stock takes, as a share.
const RISE_STOCKLESS: float = 0.55
## Share of the rise a barrel-heavy weapon keeps out in front of the hands.
const RISE_MUZZLE_HEAVY: float = 0.35
## Widest band the character rise may occupy, radians per shot. The reference's is
## [0.0016, 0.052]; opening it is most of what makes a launcher unlike an SMG.
const RISE_MIN: float = 0.0010
const RISE_MAX: float = 0.075

## Lateral share of the kick: a floor every gun has, plus what the joints, the
## missing stock, the cyclic tempo and a warhead add on top.
const LAT_BASE: float = 0.16
const LAT_FIT: float = 0.30
const LAT_STOCKLESS: float = 0.42
const LAT_TEMPO: float = 0.75
const LAT_EXPLOSIVE: float = 0.30
const LAT_MIN: float = 0.06
const LAT_MAX: float = 1.60

## Constant sideways bias in the walk. Its SIGN stays the reference's coin flip off
## `cfg`; its size is the geometry's, so a matched shouldered rifle barely drifts.
const DRIFT_BASE: float = 0.18
const DRIFT_FIT: float = 0.22
const DRIFT_STOCKLESS: float = 0.45
## How much of the drift magnitude is the weapon's own `cfg` signature rather than
## its geometry. `BASE + SPAN * mean|roll|` is 1.0 at the mean, so the roster's mean
## drift is the geometry's and only its SPREAD comes from here.
const DRIFT_ROLL_BASE: float = 0.45
const DRIFT_ROLL_SPAN: float = 1.10

## Shots per horizontal cycle, from the tempo. A bolt gun has nothing to walk over
## and gets the minimum; a 1 100 rpm SMG sweeps across a dozen rounds.
const PERIOD_MIN: float = 3.0
const PERIOD_SPAN: float = 11.0
const PERIOD_MAX: float = 15.0

## Random spice: what unreliability contributes, the floor under it, and what a
## missing shoulder adds.
const RANDOM_REL_WEIGHT: float = 0.85
const RANDOM_BASE: float = 0.10
const RANDOM_STOCKLESS: float = 0.30
const RANDOM_MAX: float = 1.45

## Settle rate — how fast the climb decays towards `GunRecoil.settle_floor`. Mass
## and a shoulder buy a fast settle (one shove, then calm); tempo spends it (a
## sustained climb). The reference's band is [0.08, 0.42]; this one is far wider.
const SETTLE_BASE: float = 0.06
const SETTLE_MASS: float = 0.55
const SETTLE_MASS_REFERENCE: float = 8.0
const SETTLE_SHOULDER: float = 0.30
const SETTLE_TEMPO: float = 0.28
const SETTLE_MIN: float = 0.04
const SETTLE_MAX: float = 0.95


## Fit one part to one receiver socket.
##
## Returns `{k, kz, pos, err}`: `k` is the uniform XY scale that matches the
## part's own cut face to the socket, `kz` an extra Z-only multiplier closing 85%
## of the width mismatch, `pos` the placement including the deliberate joint
## overlap, and `err` the log-mismatch that survives — zero for a perfect match.
static func fit(kind: StringName, p: GunPart, sock: GunSocket, tuning: GunTuning) -> Dictionary:
	var pos: Vector3 = sock.position
	var h: float = sock.height
	var w: float = sock.width
	var l: float = p.fit_height
	if tuning.zero_fit_height_ratio > 0.0 and l <= ZERO_FIT_HEIGHT:
		l = p.ext.y * tuning.zero_fit_height_ratio
	var k: float = h / maxf(l, FIT_EPS)
	k = minf(k, float(GunTables.FIT_CAP_HEIGHT[kind]) / maxf(p.ext.y, FIT_EPS))
	if kind == &"stock":
		k = minf(k, GunTables.FIT_CAP_STOCK_LENGTH / maxf(p.ext.x, FIT_EPS))
	var lim: Vector2 = GunTables.LIM[kind]
	k = clampf(k, lim.x, lim.y)
	var kz: float = clampf(1.0 + 0.85 * ((w / maxf(p.fit_width, FIT_EPS)) - 1.0), 0.70, 1.90)
	var o: float = GunTables.OVL[kind]
	match kind:
		&"barrel":
			pos.x -= o
		&"stock":
			pos.x += o
		&"sight":
			pos.y -= o
		&"grip":
			pos.y += o
			pos.x = (pos.x - h * 0.5) + 0.06 * h + l * k * 0.5
	var err: float = absf(log(maxf(h, FIT_EPS) / maxf(l * k, FIT_EPS)))
	return {"k": k, "kz": kz, "pos": pos, "err": err}


## The reference's `randomSel`: receiver, barrel, stock, grip, sight-gate, sight.
## Five draws minimum, six maximum, in that exact order — the whole determinism
## contract rests on it. Element 4 is null when the gate fails (38% of rolls).
static func random_sel(rand: XorShift32, by_kind: Dictionary) -> Array[GunPart]:
	var out: Array[GunPart] = []
	out.append(draw_part(rand, by_kind[&"receiver"]))
	out.append(draw_part(rand, by_kind[&"barrel"]))
	out.append(draw_part(rand, by_kind[&"stock"]))
	out.append(draw_part(rand, by_kind[&"grip"]))
	if rand.next() < 0.62:
		out.append(draw_part(rand, by_kind[&"sight"]))
	else:
		out.append(null)
	return out


## `pick(r, a)` over a part pool: one draw, floor-indexed.
static func draw_part(rand: XorShift32, pool: Array[GunPart]) -> GunPart:
	return pool[int(floor(rand.next() * float(pool.size())))]


## `build(seed)`: roll five parts from the seed and derive everything, optics
## included. This is the function the golden vectors in the spec are taken from.
static func build(seed_value: int, by_kind: Dictionary, tuning: GunTuning) -> GunSpec:
	var rand := XorShift32.new(seed_value)
	var sel: Array[GunPart] = random_sel(rand, by_kind)
	var spec: GunSpec = assemble(sel[0], sel[1], sel[2], sel[3], sel[4], seed_value, tuning)
	return fit_optics(spec)


## Derive a complete weapon from five chosen parts. `sight` may be null.
##
## Optics are NOT fitted here: the reference's bench reroll calls this directly
## and leaves `zoom_levels` empty on purpose, which is why every consumer has to
## go through `GunSpec.zoom_ladder()`.
static func assemble(
	rec: GunPart,
	bar: GunPart,
	sto: GunPart,
	gri: GunPart,
	sight: GunPart,
	roll_seed: int,
	tuning: GunTuning
) -> GunSpec:
	# --- 4.1 fit each part to its socket, in the fixed assembly order ---------
	# The fitted scales stay in full precision here and are narrowed to the
	# spec's float32 arrays only at the end. Reading them back through a
	# PackedFloat32Array mid-derivation costs eight significant figures, which is
	# enough to move `mass` and every joule and newton-second derived from it.
	var used: Array[GunPart] = [rec]
	var scales := PackedFloat64Array([1.0])
	var z_scales := PackedFloat64Array([1.0])
	var offsets := PackedVector3Array([Vector3.ZERO])
	var err: float = 0.0
	var slots: Array = [
		[&"barrel", bar, rec.socket_front],
		[&"stock", sto, rec.socket_rear],
		[&"grip", gri, rec.socket_bottom],
	]
	if sight != null:
		slots.append([&"sight", sight, rec.socket_top])
	for slot: Array in slots:
		var f: Dictionary = fit(slot[0], slot[1], slot[2], tuning)
		used.append(slot[1])
		scales.append(f["k"])
		z_scales.append(f["kz"])
		offsets.append(f["pos"])
		err += float(f["err"])

	# --- 4.2 dimensions -------------------------------------------------------
	# barrel/stock/receiver lengths are MILLIMETRES; grip height and sight length
	# stay in MODEL UNITS. Mixing them silently ruins feed, mode, capacity and zoom.
	var bar_len: float = bar.ext.x * scales[1] * GunTables.MM
	var sto_len: float = sto.ext.x * scales[2] * GunTables.MM
	var mag_h: float = gri.ext.y * scales[3]
	var sig_len: float = sight.ext.x * scales[4] if sight != null else 0.0
	var rec_len: float = rec.ext.x * GunTables.MM

	var x0: float = 1.0e9
	var x1: float = -1.0e9
	for i: int in used.size():
		var p: GunPart = used[i]
		var half: float = p.ext.x * scales[i] * 0.5
		var centre: float = offsets[i].x
		if p.kind == &"barrel":
			centre += half
		elif p.kind == &"stock":
			centre -= half
		x0 = minf(x0, centre - half)
		x1 = maxf(x1, centre + half)
	var oa_len: float = (x1 - x0) * GunTables.MM

	# --- 4.3 mass -------------------------------------------------------------
	var mass: float = 0.35
	for i: int in used.size():
		var p: GunPart = used[i]
		var k: float = scales[i]
		var density: float = 0.0009 if (p.kind == &"grip" or p.kind == &"stock") else 0.0021
		mass += p.hull_volume * k * k * k * z_scales[i] * GunTables.CM3 * density
	mass = clampf(mass, 0.5, tuning.mass_ceiling)

	# --- 4.4 cartridge geometry ----------------------------------------------
	# Bore is the barrel's business and the receiver caps it, because the action
	# has to close on that case head — but a barrel already over 25 mm is a
	# launcher tube, and no receiver turns that back into a rifle round.
	var case_len: float = clampf(10.0 + rec_len * 0.13, 16.0, 115.0)
	var muz: float = bar.muzzle_radius
	if muz <= 0.0:
		muz = 0.25
	var bore_raw: float = muz * scales[1] * GunTables.MM * 0.46
	var head_rec: float = clampf(rec.socket_front.height * GunTables.MM * 0.19, 6.0, 42.0)
	var explosive: bool = bore_raw >= 25.0
	var bore: float = (
		clampf(bore_raw, 25.0, 110.0) if explosive else clampf(bore_raw, 4.5, head_rec * 0.94)
	)
	var case_head: float = bore * 1.04 if explosive else head_rec
	var shot: bool = not explosive and bore >= 12.5 and bore / head_rec > 0.78
	var fill: float = clampf(1.15 - bore / 30.0, 0.35, 1.0)
	var powder: float = pow(case_head / 10.0, 2.0) * (case_len / 10.0) * 0.30 * fill
	var burn: float = 1.0 - exp(-bar_len / 240.0)
	var energy: float = powder * 1250.0 * (0.34 + 0.66 * burn)
	var proj_g: float = pow(bore, 2.85) * 0.012
	var pellets: int = clampi(roundi(pow(bore / 6.0, 2.0)), 2, 16) if shot else 1
	var vel: float = clampf(sqrt(2.0 * energy / (proj_g / 1000.0)), 150.0, 1500.0)
	var impulse: float = proj_g / 1000.0 * vel + powder * 0.75 / 1000.0 * 1500.0

	# --- 4.6 capacity, feed, fire mode ---------------------------------------
	var round_vol: float = pow(case_head / 10.0, 2.0) * (case_len / 10.0) * 1.05
	var gk: float = scales[3]
	var grip_hull: float = gri.hull_volume * gk * gk * gk * z_scales[3]
	var mag_raw: float = grip_hull * GunTables.CM3 * (0.50 + 0.50 * clampf(mag_h / 1.6, 0.0, 1.7))
	var cap: int = maxi(1, roundi(20.5 * pow(mag_raw, 0.40) / round_vol))
	var rec_class: StringName = rec.weapon_class
	if rec_class == &"revolver":
		cap = clampi(cap, 5, 9)
	if explosive:
		cap = clampi(cap, 1, 4)
	cap = clampi(cap, 1, 200)
	var cap_raw: int = cap

	# How badly the impulse outruns the bolt. Low means a light kick against a
	# heavy carrier, so the action cycles fast and full-auto is on the table.
	var bolt_kg: float = rec.hull_volume * GunTables.CM3 * 0.0009
	var cyc: float = impulse / maxf(bolt_kg * 18.0, 0.05)

	var feed: StringName = &"internal"
	if rec_class == &"revolver":
		feed = &"cylinder"
	elif rec_class == &"shotgun" and mag_h < 1.15:
		feed = &"tube"
	elif explosive:
		feed = &"breech"
	elif mag_h > 0.85:
		feed = &"box"

	var mode: StringName = _fire_mode(
		cap, rec_class, explosive, cyc, pellets, tuning.auto_shotgun_cycle
	)
	var auto_fire: bool = mode == &"Full-auto" or mode == &"Machine pistol"
	var cyclic: int = _cyclic_rpm(bolt_kg, impulse, case_len, err, tuning)
	# Free recoil velocity, m/s: what the shooter has to arrest between aimed shots.
	var recoil_vel: float = impulse / maxf(mass, 0.5)
	var rpm: int = _rpm_for(mode, auto_fire, cyclic, impulse, recoil_vel, tuning)

	var sidearm: bool = oa_len <= 720.0 and mass <= 3.6
	var hs_range: int = roundi(clampf((vel - 180.0) * 0.10, 6.0, 320.0))

	# --- 4.7 provisional cone, in minutes of arc ------------------------------
	var raw_spread: float = 19.0 / (0.55 + 0.65 * GunTables.log2(1.0 + bar_len / 170.0))
	if sight != null:
		raw_spread *= 0.52 - 0.05 * minf(sig_len, 3.0)
	if sto_len > 80.0:
		raw_spread *= 0.74
	raw_spread *= 1.0 + 0.85 * err
	raw_spread *= 1.0 + 0.9 * impulse / maxf(mass, 0.4) / 10.0
	if shot:
		var choke: float = clampf(bar_len / 700.0, 0.0, tuning.shot_spread_barrel_cap)
		raw_spread *= tuning.shot_spread_multiplier * (1.0 - choke)

	# --- 4.8 archetype --------------------------------------------------------
	var classes: Array[StringName] = []
	var groups: Array[StringName] = []
	for p: GunPart in used:
		if not classes.has(p.weapon_class):
			classes.append(p.weapon_class)
		if not groups.has(p.donor_group):
			groups.append(p.donor_group)
	var rel0: float = clampf(100.0 - float(classes.size() - 1) * 6.0 - err * 12.0, 10.0, 99.0)
	var has_optic: bool = sight != null
	# The Sniper and Marksman gates read `rpm <= 145` as a proxy for "a deliberate,
	# big-cartridge action", and the reference's semi rate — `320 - impulse*7` — is
	# exactly a cartridge measure wearing a rate's clothes. The recovery-priced semi
	# rate moves that whole band, so classification keeps reading the reference's
	# number and the archetype census does not shift under a rate change. Every other
	# mode's rate is untouched at this point, so only the semi branch needs it.
	var class_rpm: int = (
		_reference_semi_rpm(impulse)
		if mode == &"Semi-auto" and tuning.semi_rate_ceiling > 0
		else rpm
	)
	var arch: String = _archetype(
		explosive,
		pellets,
		auto_fire,
		mode,
		cap,
		mass,
		bar_len,
		case_len,
		case_head,
		class_rpm,
		raw_spread,
		sidearm
	)
	var tune: Array = GunTables.TUNE[arch]

	# --- 4.9 damage, capacity, rate and reload, finalised ---------------------
	var per_proj: float = (
		1.35 * 0.5 * pow(energy / float(pellets), 0.66) if shot else 0.5 * pow(energy, 0.66)
	)
	var dmg: float = per_proj * float(pellets) * float(tune[GunTables.Tune.DMG])
	var blast_r: float = 0.0
	if explosive:
		blast_r = clampf(1.4 + bore * 0.098, 3.0, 12.0)
		dmg = clampf(120.0 * pow(bore / 40.0, 2.15), 90.0, 900.0)
		cap = clampi(roundi(float(cap) * 0.5), 1, 8)
	else:
		cap = maxi(1, roundi(float(cap) * float(tune[GunTables.Tune.CAP])))
	var cap_limit: int = tuning.capacity_limit(feed, arch)
	if cap_limit > 0:
		cap = mini(cap, cap_limit)
	# A bolt-driven rate is the only one the trigger does not already limit, so it
	# is the only one that needs a ceiling. Kept even, as the reference's is.
	var bolt_driven: bool = auto_fire or mode == &"3-round burst"
	# The archetype multiplier is smallest exactly where the geometry is already
	# slowest and largest where it is already fastest, so at full strength it drags
	# both ends of the auto band into the middle. On a bolt-driven rate it is taken
	# at `archetype_rate_on_cyclic` strength; a trigger-limited rate still takes it
	# in full, because there the archetype IS the shooter's cadence.
	var rate_mul: float = float(tune[GunTables.Tune.RPM])
	if bolt_driven:
		rate_mul = 1.0 + (rate_mul - 1.0) * clampf(tuning.archetype_rate_on_cyclic, 0.0, 1.0)
	rpm = maxi(8, roundi(float(rpm) * rate_mul / 2.0) * 2)
	if bolt_driven and tuning.auto_rpm_ceiling > 0:
		rpm = mini(rpm, (tuning.auto_rpm_ceiling / 2) * 2)

	var cap_reload: int = cap if tuning.reload_uses_final_capacity else cap_raw
	var reload: float = _reload_base(feed, cap_reload, mag_h, bore)
	reload *= float(tune[GunTables.Tune.REL])
	reload *= 1.0 + maxf(0.0, mass - 4.0) * 0.055 + maxf(0.0, oa_len - 900.0) / 2400.0
	reload *= 1.0 + (100.0 - rel0) / 100.0 * 0.40
	reload = GunTables.to_fixed(clampf(reload, 0.75, 14.0), 1)

	var sd: float = proj_g / (bore * bore)
	var range_e: float = (
		clampf(70.0 + bore * 4.2, 90.0, 620.0)
		if explosive
		else 1400.0 * sd * log(maxf(energy / 80.0, 1.02))
	)

	# --- 4.10 handling, lethality, crit --------------------------------------
	var burst_dps: float = dmg * float(rpm) / 60.0
	var cycle_t: float = float(cap) / (float(rpm) / 60.0)
	var sust_dps: float = dmg * float(cap) / (cycle_t + reload)
	var kick: float = clampf(
		26.0 * impulse / maxf(mass, 0.5) * (0.72 if sto_len > 80.0 else 1.0), 3.0, 99.0
	)
	var hand: float = _handling(mass, oa_len, tuning)
	var no_cycle: bool = (
		mode == &"Break-action"
		or mode == &"Single-shot"
		or mode == &"Bolt-action"
		or mode == &"Pump-action"
	)
	var crit: float = (
		1.0
		if explosive
		else clampf(1.7 + vel / 1350.0 - (0.55 if shot else 0.0) + sd * 1.6, 1.35, 3.4)
	)
	var lethal: float = clampf(38.0 * GunTables.log10(1.0 + sust_dps), 1.0, 99.0)
	var burst_rating: float = clampf(30.0 * GunTables.log10(1.0 + burst_dps), 1.0, 99.0)
	var punch: float = clampf(34.0 * GunTables.log10(1.0 + dmg * crit), 1.0, 99.0)

	# --- 4.11 the cone, finalised. A tight cone is earned, not rolled. -------
	var fit_q: float = clampf(1.0 - float(groups.size() - 1) / 4.0 * 0.80 - err * 0.55, 0.05, 1.0)
	var loose: float = float(GunTables.LOOSE.get(arch, GunTables.LOOSE_DEFAULT))
	var spread: float = raw_spread * float(tune[GunTables.Tune.SPR])
	spread *= 1.0 + 1.9 * loose * pow(1.0 - fit_q, 1.30)
	if has_optic:
		spread *= 0.86
	var floor_moa: float = float(GunTables.FLOOR.get(arch, GunTables.FLOOR_DEFAULT))
	spread = maxf(spread, floor_moa * (0.85 + 0.45 * (1.0 - fit_q)))
	if explosive:
		spread = maxf(spread, 7.0)
	var grade: float = clampf(
		(
			(
				0.28 * lethal
				+ 0.20 * punch
				+ 0.16 * clampf(30.0 * GunTables.log10(1.0 + range_e), 1.0, 99.0)
				+ 0.10 * (100.0 - kick)
				+ 0.08 * hand
				+ 0.18 * rel0
				- 40.0
			)
			/ 34.0
		),
		0.0,
		1.0
	)
	spread = clampf(spread * (2.30 - 1.40 * grade), 1.0, 1600.0)

	# --- 4.12 everything that falls out of the cone --------------------------
	var reach_limit: float = minf(3400.0 / spread, range_e)
	if shot and tuning.shot_range_cap > 0.0:
		reach_limit = minf(range_e, tuning.shot_range_cap)
	var eff_range: float = clampf(reach_limit, tuning.min_effective_range, 1800.0)
	var precision: float = clampf(105.0 - 40.0 * GunTables.log10(1.0 + spread), 1.0, 99.0)
	var reach: float = clampf(33.0 * GunTables.log10(1.0 + eff_range), 1.0, 99.0)
	var rel: float = clampf(
		(
			98.0
			- float(classes.size() - 1) * 6.0
			- err * 12.0
			- maxf(0.0, mass - 6.0) * 3.5
			- (0.0 if no_cycle else maxf(0.0, cyc - 1.1) * 14.0)
			- (8.0 if spread > 200.0 else 0.0)
		),
		1.0,
		99.0
	)
	# --- 4.12b cadence, judged against the class's own band -------------------
	# Fast FOR ITS CLASS, centred on mid-band. See docs/GUN_DESIGN.md.
	var cadence: float = clampf(GunTables.rate_position(arch, float(rpm)), 0.0, 1.0) - 0.5
	var score: float = (
		0.14 * lethal
		+ 0.09 * burst_rating
		+ 0.14 * punch
		+ 0.13 * reach
		+ 0.24 * precision
		+ 0.05 * (100.0 - kick)
		+ 0.07 * hand
		+ 0.14 * rel
		+ tuning.cadence_swing * cadence
	)

	# --- 4.13 optics ---------------------------------------------------------
	var zoom: float = clampf(1.25 + sig_len * 0.40, 1.25, 3.1) if has_optic else 1.15
	if arch == "Sniper":
		zoom = clampf(zoom * 2.2, 3.4, 9.0)
	elif arch == "Marksman carbine":
		zoom = clampf(zoom * 1.6, 2.6, 6.5)

	# --- 4.15 the per-weapon config hash -------------------------------------
	# Everything cosmetic keys off this rather than the roll seed, so the same
	# five parts always produce the same name, recoil pattern and tint.
	var sight_term: int = (sight.index + 1) * 40503 if sight != null else 7919
	var cfg: int = (
		((rec.index + 1) * 73856093)
		^ ((bar.index + 1) * 19349663)
		^ ((sto.index + 1) * 83492791)
		^ ((gri.index + 1) * 2654435761)
		^ sight_term
	)
	cfg &= 0xFFFFFFFF
	if cfg == 0:
		cfg = 1

	# --- 4.16 recoil pattern -------------------------------------------------
	var pattern: Dictionary = _recoil(
		{
			&"impulse": impulse,
			&"mass": mass,
			&"err": err,
			&"stock_mm": sto_len,
			&"barrel_mm": bar_len,
			&"overall_mm": oa_len,
			&"rpm": rpm,
			&"reliability": rel,
			&"explosive": explosive,
			&"cfg": cfg,
		},
		tuning
	)

	# --- assemble the record --------------------------------------------------
	var spec := GunSpec.new()
	spec.roll_seed = roll_seed
	spec.cfg = cfg
	spec.weapon_name = GunTables.name_for(XorShift32.new((cfg ^ 0x5BF03635) & 0xFFFFFFFF), groups)

	spec.part_indices = PackedInt32Array()
	for p: GunPart in used:
		spec.part_indices.append(p.index)
	spec.part_scales = _narrow(scales)
	spec.part_z_scales = _narrow(z_scales)
	spec.part_offsets = offsets
	spec.fit_error = err
	spec.muzzle_local = offsets[1] + Vector3(bar.ext.x * scales[1], 0.0, 0.0)

	spec.score = score
	spec.tier_index = GunTables.tier_index_for(score, rel)
	spec.tier_name = StringName(Palette.GUN_TIER_NAMES[spec.tier_index])
	spec.tier_color = Palette.TIER_COLORS[spec.tier_index]
	spec.quirks = _quirks(
		auto_fire, cyc, spread, explosive, hs_range, vel, dmg, rel, cap, eff_range, mass, sidearm
	)

	spec.caliber = GunTables.cartridge_name(bore, case_len, shot)
	spec.bore = GunTables.to_fixed(bore, 1)
	spec.case_length = roundi(case_len)
	spec.pellets = pellets
	spec.explosive = explosive
	spec.blast_radius = GunTables.to_fixed(blast_r, 1)

	spec.muzzle_velocity = roundi(vel)
	spec.muzzle_energy = roundi(energy)
	spec.effective_range = roundi(eff_range)
	spec.sim_velocity = roundi(vel * 0.5)
	spec.damage = float(roundi(dmg))
	spec.crit_multiplier = GunTables.to_fixed(crit, 2)
	spec.headshot_range = 0.0 if explosive else float(hs_range)
	spec.impulse = impulse

	spec.fire_mode = mode
	spec.feed = feed
	spec.archetype = StringName(arch)
	spec.rpm = rpm
	spec.cyclic = cyclic
	spec.magazine = cap
	spec.reload_time = reload
	spec.automatic = auto_fire
	spec.runaway = spec.quirks.has("runaway")
	spec.sidearm = sidearm

	spec.mass = mass
	spec.precision = roundi(precision)
	spec.reach = roundi(reach)
	spec.kick = roundi(kick)
	spec.handling = roundi(hand)
	spec.reliability = roundi(rel)
	spec.burst_dps = roundi(burst_dps)
	spec.sustained_dps = roundi(sust_dps)
	spec.barrel_length = roundi(bar_len)
	spec.overall_length = roundi(oa_len)

	var decimals: int = 1 if spread < 10.0 else 0
	spec.spread = GunTables.to_fixed(spread, decimals)
	spec.spread_rad = spread * GunTables.MOA_RAD
	spec.spread_text = (
		GunTables.num_text(spec.spread, decimals) + "'"
		if spread < 60.0
		else "%.1f°" % (spread / 60.0)
	)

	spec.has_optic = has_optic
	spec.scoped = false
	spec.zoom = zoom
	spec.zoom_levels = PackedFloat32Array()

	spec.recoil_vertical = float(pattern[&"vertical"])
	spec.recoil_horizontal = float(pattern[&"horizontal"])
	spec.recoil_drift = float(pattern[&"drift"])
	spec.recoil_period = int(pattern[&"period"])
	spec.recoil_random = float(pattern[&"random"])
	spec.recoil_settle = float(pattern[&"settle"])

	spec.tint = 0.86 + 0.28 * XorShift32.new((cfg ^ 0x9E37) & 0xFFFFFFFF).next()
	spec.donor_groups = groups
	return spec


## Fit the magnification ladder and decide whether the optic earns a scope tube.
## Mutates and returns the same spec, exactly as the reference does.
static func fit_optics(spec: GunSpec) -> GunSpec:
	var rank: int = GunTables.TIER_RANK[spec.tier_index]
	var marksman: bool = spec.archetype == &"Sniper" or spec.archetype == &"Marksman carbine"
	var n: int = 1
	if spec.has_optic and spec.zoom >= 2.4:
		n += 1
	if marksman and spec.has_optic:
		n += 1
	if rank >= 3 and spec.has_optic:
		n += 1
	n = clampi(n, 1, 4)
	var top: float = clampf(
		spec.zoom * (1.0 + 0.55 * float(n - 1)) * (1.0 + 0.10 * float(rank)), spec.zoom, 14.0
	)
	var levels := PackedFloat32Array()
	for i: int in n:
		var t: float = 0.0 if n == 1 else float(i) / float(n - 1)
		levels.append(GunTables.to_fixed(spec.zoom + (top - spec.zoom) * t, 1))
	spec.zoom_levels = levels
	var battle: bool = spec.archetype == &"Battle rifle" or spec.archetype == &"Auto battle rifle"
	# Scopes you can find: 3% -> 11%. Marksman glass is scoped outright, and so is
	# anything topping SCOPE_ZOOM — hence the scoped machine pistol.
	var top_zoom: float = levels[levels.size() - 1]
	spec.scoped = spec.has_optic and (marksman or top_zoom >= SCOPE_ZOOM or (rank >= 2 and battle))
	return spec


## Narrow the derivation's full-precision scales into the spec's storage width.
## There is no Packed*Array conversion constructor between the two.
static func _narrow(values: PackedFloat64Array) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(values.size())
	for i: int in values.size():
		out[i] = values[i]
	return out


## The fire-mode ladder: top to bottom, first hit wins.
static func _fire_mode(
	cap: int,
	rec_class: StringName,
	explosive: bool,
	cyc: float,
	pellets: int,
	auto_shotgun_cycle: float
) -> StringName:
	var shotgun: bool = rec_class == &"shotgun"
	var mode: StringName = &"Break-action"
	if cap <= 1:
		mode = &"Single-shot"
	elif rec_class == &"revolver":
		mode = &"Double-action"
	elif explosive:
		mode = &"Break-action"
	elif pellets > 1 and cyc < auto_shotgun_cycle:
		# THE AUTO SHOTGUN, previously UNREACHABLE (0 of 40,000). Gated on PELLETS,
		# not `rec_class` — `_archetype` reads pellets, and that is the difference.
		mode = &"Full-auto"
	elif cyc < 0.55:
		if shotgun:
			mode = &"Semi-auto"
		else:
			mode = &"Machine pistol" if rec_class == &"pistol" else &"Full-auto"
	elif cyc < 0.85:
		mode = &"Pump-action" if shotgun else &"3-round burst"
	elif cyc < 1.35:
		mode = &"Pump-action" if shotgun else &"Semi-auto"
	elif shotgun:
		mode = &"Pump-action"
	elif rec_class == &"sniper" or rec_class == &"rifle":
		mode = &"Bolt-action"
	if rec_class == &"sniper" and cyc > 0.40:
		if mode == &"Full-auto" or mode == &"3-round burst":
			mode = &"Semi-auto"
	return mode


## The MECHANICAL cycle rate: how fast the action can run itself, rounded to ten
## rpm as the reference does.
##
## Four terms, all geometric. The reference's own is a light bolt against a heavy
## impulse; on top of it the bolt must travel the length of the loaded cartridge,
## and a badly mated action loses rate to friction and short-stroking. The stroke
## term is the one that separates an SMG from a battle rifle — same carrier mass,
## 30 mm of case against 100 mm, and the rifle turns 2.3 times slower.
##
## The fourth term is the one that stops the band eating itself. The three physical
## terms together span roughly 120 to 1900 rpm, and the bottom third of that is
## below anything a self-loader actually runs at — so it used to be CLAMPED, and a
## clamp is a collapse: every Auto battle rifle in 2 000 builds came out at exactly
## the same rate because every one of them was sitting on the floor. `cyclic_contrast`
## replaces the clamp with a power law about `cyclic_pivot_rpm`, which is the same
## squeeze in log space but strictly monotone — two actions that differ by a gram or
## a millimetre still differ in rate, at both ends of the roster.
static func _cyclic_rpm(
	bolt_kg: float, impulse: float, case_len: float, err: float, tuning: GunTuning
) -> int:
	var raw: float = 1500.0 / sqrt(bolt_kg * impulse)
	if tuning.cyclic_stroke_power > 0.0:
		var stroke: float = maxf(case_len, CYCLIC_STROKE_FLOOR) / CYCLIC_STROKE_FLOOR
		raw /= pow(stroke, tuning.cyclic_stroke_power)
	if tuning.cyclic_fit_penalty > 0.0:
		raw *= maxf(1.0 - tuning.cyclic_fit_penalty * maxf(err, 0.0), CYCLIC_FIT_FLOOR)
	var pivot: float = float(tuning.cyclic_pivot_rpm)
	if pivot > 0.0:
		raw = pivot * pow(maxf(raw, 1.0) / pivot, clampf(tuning.cyclic_contrast, 0.05, 2.0))
	var floor_rpm: float = float(tuning.cyclic_floor_rpm)
	return roundi(clampf(raw, floor_rpm, CYCLIC_CEILING) / 10.0) * 10


## Trigger-limited rate, before the archetype multiplier.
static func _rpm_for(
	mode: StringName,
	auto_fire: bool,
	cyclic: int,
	impulse: float,
	recoil_vel: float,
	tuning: GunTuning
) -> int:
	if auto_fire or mode == &"3-round burst":
		return cyclic
	match mode:
		&"Semi-auto":
			return _semi_rpm(impulse, recoil_vel, tuning)
		&"Double-action":
			return 110
		&"Pump-action":
			return 72
		&"Bolt-action":
			return 42
		&"Break-action":
			return 24
	return 16


## How fast aimed single shots can actually be taken.
##
## The reference prices a semi by IMPULSE, and its ceiling of 320 rpm is also its
## cyclic floor — so the fastest semi and the slowest full-auto were the same
## weapon in the hand. This prices it by RECOVERY instead: what paces a semi is
## getting the muzzle back on the plate, which is free recoil velocity, not
## momentum. A 1.4 kg snubnose and a 7 kg battle rifle can carry the same impulse
## and do not recover at anything like the same speed.
static func _semi_rpm(impulse: float, recoil_vel: float, tuning: GunTuning) -> int:
	if tuning.semi_rate_ceiling <= 0:
		return _reference_semi_rpm(impulse)
	var ceiling: float = float(tuning.semi_rate_ceiling)
	var scale: float = maxf(tuning.semi_recovery_scale, 0.01)
	return roundi(clampf(ceiling / (1.0 + maxf(recoil_vel, 0.0) / scale), SEMI_FLOOR_RPM, ceiling))


## The reference's impulse-priced semi rate. Still the number the Sniper and
## Marksman archetype gates are calibrated against — see the call site.
static func _reference_semi_rpm(impulse: float) -> int:
	return roundi(clampf(320.0 - impulse * 7.0, 90.0, 320.0))


## How quickly the weapon comes onto a target, 1-99.
##
## The reference subtracts length and mass separately, which scores a 1.9 m
## launcher above a sniper rifle for being slightly lighter. What a shooter
## actually fights is the moment of inertia — mass out at the end of its own
## length — so the swing model multiplies them, and the two are blended by
## `handling_from_swing`. The launcher and the snubnose end up an order of
## magnitude apart instead of thirty points.
static func _handling(mass: float, oa_len: float, tuning: GunTuning) -> float:
	var reference: float = 132.0 - 0.062 * oa_len - 5.0 * mass
	var reach_m: float = oa_len / 1000.0
	var swing: float = mass * reach_m * reach_m
	var swing_hand: float = 100.0 / (1.0 + swing / SWING_REFERENCE)
	var blend: float = clampf(tuning.handling_from_swing, 0.0, 1.0)
	return clampf(lerpf(reference, swing_hand, blend), 1.0, 99.0)


## The six recoil constants, as one record. `parts` carries `impulse`, `mass`,
## `err`, `stock_mm`, `barrel_mm`, `overall_mm`, `rpm`, `reliability`, `explosive`
## and `cfg`; the return carries `vertical`, `horizontal`, `drift`, `period`,
## `random` and `settle`.
##
## The reference has ONE magnitude — `impulse / mass` — with the lateral share a
## near-constant, the drift and the walk period rolled off `cfg`, and the settle
## rate a straight line in mass. Every gun therefore recoils in the same shape at
## a different size. The character model gives each field its own piece of the
## geometry, so a stockless launcher, a shouldered bolt gun and a 1 100 rpm SMG
## recoil differently in KIND: the launcher shoves hard and sideways once, the
## bolt gun shoves hard and straight once, the SMG climbs and walks and never
## quite settles. `recoil_character` blends between the two, field by field, and
## both branches consume the same two draws so the `cfg` stream is unchanged.
static func _recoil(parts: Dictionary, tuning: GunTuning) -> Dictionary:
	var impulse: float = float(parts[&"impulse"])
	var mass: float = float(parts[&"mass"])
	var err: float = maxf(float(parts[&"err"]), 0.0)
	var stock_mm: float = float(parts[&"stock_mm"])
	var rel: float = float(parts[&"reliability"])
	var explosive: bool = bool(parts[&"explosive"])
	var pr := XorShift32.new((int(parts[&"cfg"]) ^ 0x1F2E3D4C) & 0xFFFFFFFF)
	var rolled_drift: float = GunTables.to_fixed(pr.next() * 2.0 - 1.0, 3)
	var rolled_period: float = float(roundi(4.0 + pr.next() * 9.0))

	var ref_v: float = clampf(impulse / maxf(mass, 0.6) * 0.0032, 0.0016, 0.052)
	var ref_lat: float = 0.28 + err * 0.55 + (0.0 if stock_mm > 80.0 else 0.42)
	if explosive:
		ref_lat += 0.3
	var out: Dictionary = {
		&"vertical": ref_v,
		&"horizontal": ref_v * clampf(ref_lat, 0.18, 1.35),
		&"drift": rolled_drift,
		&"period": int(rolled_period),
		&"random": clampf((100.0 - rel) / 100.0 * 1.15 + 0.16, 0.16, 1.3),
		&"settle": clampf(0.10 + 0.24 * (mass / 6.0), 0.08, 0.42),
	}
	var blend: float = clampf(tuning.recoil_character, 0.0, 1.0)
	if blend <= 0.0:
		return out

	# Three geometric readings, each 0-1: how much shoulder the weapon offers, how
	# much of its length is barrel hanging off the hands, and how fast it runs.
	var shoulder: float = clampf(stock_mm / SHOULDER_FULL, 0.0, 1.0)
	var overall_mm: float = maxf(float(parts[&"overall_mm"]), 1.0)
	var muzzle_heavy: float = clampf(float(parts[&"barrel_mm"]) / overall_mm, 0.0, 1.0)
	var tempo: float = clampf((float(parts[&"rpm"]) - TEMPO_LOW_RPM) / TEMPO_SPAN_RPM, 0.0, 1.0)

	var rise: float = impulse / maxf(mass, 0.6) * tuning.recoil_rise_scale
	rise *= 1.0 + RISE_STOCKLESS * (1.0 - shoulder)
	rise *= 1.0 - RISE_MUZZLE_HEAVY * muzzle_heavy
	var ch_v: float = clampf(rise, RISE_MIN, RISE_MAX)
	var ch_lat: float = (
		LAT_BASE
		+ LAT_FIT * err
		+ LAT_STOCKLESS * (1.0 - shoulder)
		+ LAT_TEMPO * tempo
		+ (LAT_EXPLOSIVE if explosive else 0.0)
	)
	# The geometry says HOW MUCH the muzzle walks off centre; which way and how
	# pronounced stays the weapon's own signature, off `cfg`. Without the second
	# factor every matched shouldered rifle in the game drifts by the same 0.18 and
	# the pattern stops being something you learn per gun. Mean |roll| is 0.5, so
	# `DRIFT_ROLL_BASE + DRIFT_ROLL_SPAN * 0.5 == 1.0` keeps the roster's mean drift
	# exactly where the geometry put it and spreads it 0.45x to 1.55x around that.
	var sign_drift: float = 1.0 if rolled_drift >= 0.0 else -1.0
	var drift_geo: float = DRIFT_BASE + DRIFT_FIT * err + DRIFT_STOCKLESS * (1.0 - shoulder)
	var drift_sig: float = DRIFT_ROLL_BASE + DRIFT_ROLL_SPAN * absf(rolled_drift)
	var ch_drift: float = sign_drift * clampf(drift_geo * drift_sig, 0.05, 1.0)
	# Shots per horizontal cycle. The sine only means anything on a weapon that fires
	# long enough strings to complete one, so the tempo reading owns the field in
	# proportion to how much tempo there is: at zero the walk period is the weapon's
	# own rolled one, and every break-action in the game is no longer handed the same
	# three-shot oscillation it will never live to finish.
	var walk: float = clampf(PERIOD_MIN + PERIOD_SPAN * tempo, PERIOD_MIN, PERIOD_MAX)
	var ch_period: float = lerpf(rolled_period, walk, tempo)
	var ch_random: float = clampf(
		(
			(100.0 - rel) / 100.0 * RANDOM_REL_WEIGHT
			+ RANDOM_BASE
			+ RANDOM_STOCKLESS * (1.0 - shoulder)
		),
		RANDOM_BASE * 0.8,
		RANDOM_MAX
	)
	var ch_settle: float = clampf(
		(
			SETTLE_BASE
			+ SETTLE_MASS * (mass / SETTLE_MASS_REFERENCE)
			+ SETTLE_SHOULDER * shoulder
			- SETTLE_TEMPO * tempo
		),
		SETTLE_MIN,
		SETTLE_MAX
	)

	out[&"vertical"] = lerpf(float(out[&"vertical"]), ch_v, blend)
	out[&"horizontal"] = (
		float(out[&"vertical"])
		* lerpf(clampf(ref_lat, 0.18, 1.35), clampf(ch_lat, LAT_MIN, LAT_MAX), blend)
	)
	out[&"drift"] = GunTables.to_fixed(lerpf(rolled_drift, ch_drift, blend), 3)
	out[&"period"] = roundi(lerpf(rolled_period, ch_period, blend))
	out[&"random"] = lerpf(float(out[&"random"]), ch_random, blend)
	out[&"settle"] = lerpf(float(out[&"settle"]), ch_settle, blend)
	return out


## Unmodified reload time in seconds, before the archetype and mass penalties.
static func _reload_base(feed: StringName, cap: int, mag_h: float, bore: float) -> float:
	match feed:
		&"box":
			return 1.05 + float(cap) * 0.021 + mag_h * 0.42
		&"cylinder":
			return 2.3 + float(cap) * 0.26
		&"tube":
			return 0.42 * float(cap) + 0.70
		&"breech":
			return 2.9 + bore * 0.048
	return 0.95 + float(cap) * 0.30


## Archetype classification, on the pre-archetype capacity and rate.
static func _archetype(
	explosive: bool,
	pellets: int,
	auto_fire: bool,
	mode: StringName,
	cap: int,
	mass: float,
	bar_len: float,
	case_len: float,
	case_head: float,
	rpm: int,
	raw_spread: float,
	sidearm: bool
) -> String:
	var burst: bool = mode == &"3-round burst"
	if explosive:
		return "Launcher"
	if pellets > 1:
		if auto_fire:
			return "Auto shotgun"
		return "Slug gun" if bar_len > 560.0 else "Shotgun"
	if auto_fire and cap >= 36 and mass > 4.7 and bar_len >= 330.0:
		return "Machine gun"
	if auto_fire and bar_len < 320.0 and (case_len < 42.0 or mass < 4.6):
		return "Submachine gun"
	if auto_fire and case_len > 60.0 and bar_len >= 380.0:
		return "Auto battle rifle"
	if auto_fire or burst:
		return "Assault rifle" if bar_len >= 300.0 else "Chopped auto"
	if rpm <= 145 and raw_spread < 11.0 and case_len > 50.0 and bar_len >= 430.0:
		return "Sniper"
	if rpm <= 145 and raw_spread < 14.0 and bar_len >= 320.0:
		return "Marksman carbine"
	if mode == &"Semi-auto" and case_len > 52.0 and bar_len >= 340.0:
		return "Battle rifle"
	if cap <= 8 and case_head > 13.0 and bar_len >= 260.0:
		return "Hand cannon"
	if bar_len < 250.0:
		return "Snubnose"
	if sidearm:
		return "Sidearm"
	return "Carbine" if case_len < 40.0 else "Hybrid"


## Emergent traits, read off the finished numbers. Push order is display order.
static func _quirks(
	auto_fire: bool,
	cyc: float,
	spread: float,
	explosive: bool,
	hs_range: int,
	vel: float,
	dmg: float,
	rel: float,
	cap: int,
	eff_range: float,
	mass: float,
	sidearm: bool
) -> PackedStringArray:
	var q := PackedStringArray()
	if auto_fire and cyc < 0.20:
		q.append("runaway")
	if spread > 150.0:
		q.append("blunderbuss")
	if explosive:
		q.append("explosive")
	if not explosive and hs_range >= 110:
		q.append("flat-shooting")
	if vel > 1150.0:
		q.append("overbore")
	if dmg > 190.0:
		q.append("hand cannon")
	if rel < 32.0:
		q.append("jam-prone")
	if cap >= 60:
		q.append("drum-fed")
	if eff_range > 700.0:
		q.append("reach-out")
	if mass > 8.5:
		q.append("crew-served")
	if sidearm:
		q.append("sidearm")
	return q
