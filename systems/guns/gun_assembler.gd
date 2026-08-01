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
const ZERO_FIT_HEIGHT: float = 1.0e-4
## The reference's guard against dividing by a zero-height cut face. Keep it:
## with it, part 70 lands on `err = 13.59`; without it, on `inf`.
const FIT_EPS: float = 1.0e-6


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

	var mode: StringName = _fire_mode(cap, rec_class, explosive, cyc)
	var auto_fire: bool = mode == &"Full-auto" or mode == &"Machine pistol"
	var cyclic: int = roundi(clampf(1500.0 / sqrt(bolt_kg * impulse), 320.0, 1850.0) / 10.0) * 10
	var rpm: int = _rpm_for(mode, auto_fire, cyclic, impulse)

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
		rpm,
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
	rpm = maxi(8, roundi(float(rpm) * float(tune[GunTables.Tune.RPM]) / 2.0) * 2)
	# A bolt-driven rate is the only one the trigger does not already limit, so it
	# is the only one that needs a ceiling. Kept even, as the reference's is.
	var bolt_driven: bool = auto_fire or mode == &"3-round burst"
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
	var hand: float = clampf(132.0 - 0.062 * oa_len - 5.0 * mass, 1.0, 99.0)
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
	var score: float = (
		0.14 * lethal
		+ 0.09 * burst_rating
		+ 0.14 * punch
		+ 0.13 * reach
		+ 0.24 * precision
		+ 0.05 * (100.0 - kick)
		+ 0.07 * hand
		+ 0.14 * rel
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
	var pr := XorShift32.new((cfg ^ 0x1F2E3D4C) & 0xFFFFFFFF)
	var rec_v: float = clampf(impulse / maxf(mass, 0.6) * 0.0032, 0.0016, 0.052)
	var lateral: float = 0.28 + err * 0.55 + (0.0 if sto_len > 80.0 else 0.42)
	if explosive:
		lateral += 0.3
	var rec_h: float = rec_v * clampf(lateral, 0.18, 1.35)
	var rec_drift: float = GunTables.to_fixed(pr.next() * 2.0 - 1.0, 3)
	var rec_period: int = roundi(4.0 + pr.next() * 9.0)

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

	spec.recoil_vertical = rec_v
	spec.recoil_horizontal = rec_h
	spec.recoil_drift = rec_drift
	spec.recoil_period = rec_period
	spec.recoil_random = clampf((100.0 - rel) / 100.0 * 1.15 + 0.16, 0.16, 1.3)
	spec.recoil_settle = clampf(0.10 + 0.24 * (mass / 6.0), 0.08, 0.42)

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
	spec.scoped = (
		spec.has_optic and levels[levels.size() - 1] >= 4.2 and (marksman or (rank >= 2 and battle))
	)
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
static func _fire_mode(cap: int, rec_class: StringName, explosive: bool, cyc: float) -> StringName:
	var shotgun: bool = rec_class == &"shotgun"
	var mode: StringName = &"Break-action"
	if cap <= 1:
		mode = &"Single-shot"
	elif rec_class == &"revolver":
		mode = &"Double-action"
	elif explosive:
		mode = &"Break-action"
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


## Trigger-limited rate, before the archetype multiplier.
static func _rpm_for(mode: StringName, auto_fire: bool, cyclic: int, impulse: float) -> int:
	if auto_fire or mode == &"3-round burst":
		return cyclic
	match mode:
		&"Semi-auto":
			return roundi(clampf(320.0 - impulse * 7.0, 90.0, 320.0))
		&"Double-action":
			return 110
		&"Pump-action":
			return 72
		&"Bolt-action":
			return 42
		&"Break-action":
			return 24
	return 16


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
