class_name GunbenchCards
extends RefCounted
## Turns a `GunSpec` into the five cards the bench reads out: a stat card for each of
## the two stands, a third for whatever is in your hands, the cartridge card under it,
## the delta card that sets the two stands against each other, and the name plate
## beside a stand's grab button.
##
## Nothing here decides anything — the numbers are already on the spec, derived from
## the geometry by `GunAssembler`. This only chooses which of them a gunsmith would
## actually want burnt into a panel, and in what order.
##
## The line counts are not arbitrary. A `DiegeticReadout` renders into 512x320 with
## a 20 px margin; the title block eats 66 px, a line is 23 and a bar is 26, and the
## bars are bottom-anchored. Four lines over four bars is exactly what fits without
## the last bar sliding under the bezel, and a card that overflows is worse than a
## card that leaves something out.

## Rows on the stat card, in draw order.
const BAR_LABELS: PackedStringArray = ["DAMAGE", "RANGE", "RATE", "RELIABILITY"]

## What a full bar means. A bar is a comparison between two guns on one bench, not
## an absolute claim, so these are set near the top of what the roll tables actually
## produce rather than at some theoretical ceiling: past them the bar simply pins.
const DAMAGE_FULL: float = 90.0
const RANGE_FULL: float = 420.0
const RPM_FULL: float = 900.0

## Fields the delta card compares, as [label, property, higher-is-better, decimals].
const DELTA_ROWS: Array = [
	["DAMAGE", &"damage", true, 1],
	["BURST DPS", &"burst_dps", true, 0],
	["RANGE M", &"effective_range", true, 0],
	["RPM", &"rpm", true, 0],
	["PRECISION", &"precision", true, 0],
	["HANDLING", &"handling", true, 0],
	["RELIABILITY", &"reliability", true, 0],
	["MASS KG", &"mass", false, 2],
]


## Card heading: the rolled name, shouted, because a stencil has no lower case.
static func title(spec: GunSpec) -> String:
	if spec == null:
		return "NO WEAPON"
	return spec.weapon_name.to_upper()


## The four lines above the bars: what it is, how it feeds, what it does to a body,
## and what it costs you to hold.
static func stat_lines(spec: GunSpec) -> PackedStringArray:
	if spec == null:
		return PackedStringArray(["THE STAND IS EMPTY."])
	return PackedStringArray(
		[
			"%s  ·  %s" % [String(spec.tier_name).to_upper(), String(spec.archetype).to_upper()],
			(
				"%s  ·  %d rnd %s"
				% [String(spec.fire_mode), spec.magazine, GunTables.feed_label(spec.feed)]
			),
			(
				"%.1f dmg  x%.2f crit  ·  %d/%d dps"
				% [spec.damage, spec.crit_multiplier, spec.burst_dps, spec.sustained_dps]
			),
			"%.2f kg  ·  %d mm  ·  %s" % [spec.mass, spec.overall_length, spec.spread_text],
		]
	)


## Bar fractions, index-aligned with `BAR_LABELS`.
static func stat_bars(spec: GunSpec) -> PackedFloat32Array:
	if spec == null:
		return PackedFloat32Array([0.0, 0.0, 0.0, 0.0])
	return PackedFloat32Array(
		[
			clampf(spec.damage / DAMAGE_FULL, 0.0, 1.0),
			clampf(float(spec.effective_range) / RANGE_FULL, 0.0, 1.0),
			clampf(float(spec.rpm) / RPM_FULL, 0.0, 1.0),
			clampf(float(spec.reliability) / 100.0, 0.0, 1.0),
		]
	)


## Bar colours. Red through amber to green on the same ramp the settings page uses,
## so a bad bar reads as bad without a legend.
static func stat_bar_colors(spec: GunSpec) -> PackedColorArray:
	var out := PackedColorArray()
	for value: float in stat_bars(spec):
		out.append(UiStyle.meter_color(value))
	return out


## The cartridge card: what this barrel and this receiver add up to as ammunition,
## and what leaves the muzzle when they do.
static func cartridge_lines(spec: GunSpec) -> PackedStringArray:
	if spec == null:
		return PackedStringArray(["NO CARTRIDGE."])
	var out := PackedStringArray()
	out.append(spec.caliber.to_upper())
	out.append("bore %.2f mm  ·  case %d mm" % [spec.bore, spec.case_length])
	out.append("%d m/s  ·  %d J" % [spec.muzzle_velocity, spec.muzzle_energy])
	out.append("barrel %d mm  ·  reach %d m" % [spec.barrel_length, spec.effective_range])
	if spec.explosive:
		out.append("explosive  ·  %.1f m blast" % spec.blast_radius)
	elif spec.pellets > 1:
		out.append("%d pellets per pull" % spec.pellets)
	else:
		out.append("headshot inside %.0f m" % spec.headshot_range)
	out.append("recoil %.2f Ns  ·  kick %d" % [spec.impulse, spec.kick])
	out.append(optic_line(spec))
	# Wrapped, not joined: the character layer puts a mean 4.4 tags on a card and a
	# single line would be clipped by `ReadoutCanvas` without saying so.
	var first: bool = true
	for line: String in GunGrading.quirk_lines(spec):
		out.append(("· " if first else "  ") + line.to_lower())
		first = false
	return out


## What the sight slot bought, if anything.
static func optic_line(spec: GunSpec) -> String:
	if spec == null or not spec.has_optic:
		return "iron sights"
	var rungs := PackedStringArray()
	for z: float in spec.zoom_ladder():
		rungs.append("%.1fx" % z)
	return ("scope  " if spec.scoped else "optic  ") + " / ".join(rungs)


## The delta card. `a` is what is on the main stand, `b` what is on the rival stand;
## every row is signed from A's point of view and coloured by whether that sign is
## good news for A. A field where neither is better gets no colour at all.
static func delta_lines(a: GunSpec, b: GunSpec) -> PackedStringArray:
	if a == null or b == null:
		return PackedStringArray(
			["PUT A WEAPON ON EACH STAND.", "THE COMPARE PLATE COPIES THIS ONE."]
		)
	var out := PackedStringArray()
	out.append("A %s" % a.weapon_name.to_upper())
	out.append("B %s" % b.weapon_name.to_upper())
	for row: Array in DELTA_ROWS:
		var av: float = float(a.get(StringName(row[1])))
		var bv: float = float(b.get(StringName(row[1])))
		out.append(_delta_row(String(row[0]), av - bv, int(row[3]), bool(row[2])))
	return out


## The name beside a stand's grab button: which stand this is, what is on it, and what
## grade and class it came out as. `mark` is the stand's stencilled letter, so the
## plate under the gun, the button that takes it and the delta card all agree.
static func placard(spec: GunSpec, mark: String = "") -> String:
	var tag: String = "" if mark.is_empty() else mark + " · "
	if spec == null:
		return tag + "EMPTY STAND"
	return (
		"%s%s\n%s · %s"
		% [
			tag,
			spec.weapon_name.to_upper(),
			String(spec.tier_name).to_upper(),
			String(spec.archetype).to_upper(),
		]
	)


## Two-line rack tag: what it is and how good it is.
static func rack_tag(spec: GunSpec) -> String:
	if spec == null:
		return "EMPTY PEG"
	return "%s\n%s" % [spec.weapon_name.to_upper(), String(spec.tier_name).to_upper()]


## `+3.4 BETTER` / `-12 WORSE` / `= LEVEL`, padded so the arrows line up in mono.
static func _delta_row(label: String, diff: float, decimals: int, higher_is_better: bool) -> String:
	var text: String = String.num(absf(diff), decimals)
	if absf(diff) < pow(10.0, -float(decimals)) * 0.5:
		return "%-12s  =  level" % label
	var better: bool = (diff > 0.0) == higher_is_better
	var sign_text: String = "+" if diff > 0.0 else "-"
	return "%-12s %s%s  %s" % [label, sign_text, text, "A wins" if better else "B wins"]
