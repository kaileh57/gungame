extends RefCounted
## How much of the sight picture the gun itself covers when you aim.
##
## The ADS solve puts `GunAttachPoints.sight` exactly on the view axis, and the
## gun cache bake proves it does to float precision. That proof is necessary and
## it is not sufficient: putting a POINT on the axis says nothing about whether
## the receiver, the magazine and the optic that surround that point sit below the
## axis or across it. On this part library they frequently sat across it, because
## the parts are solid slabs with no aperture — the sight datum for a fitted optic
## is a quarter of the way down the sight part's own box, and for a scope it is the
## middle of the tube, so the crosshair was INSIDE the geometry.
##
## This measures it rather than arguing about it. A wide sample — every receiver
## class, irons and optics and scopes, every tier the roll produces — is put into
## the shipped shouldered pose, and rays are cast from the eye through a grid of
## screen samples and counted where they meet the weapon's own triangles.
##
## Three numbers per weapon:
##   centre    the ray straight down the view axis meets the gun. Aim is blind.
##   sight     fraction of a 5.5 degree window around the axis that the gun covers.
##   frame     fraction of the whole 44 degree ADS frame the gun covers.
## Plus `crest`, the highest elevation the gun reaches in a narrow column around
## the axis, in degrees. Negative means the whole weapon is below your aim, which
## is the condition the solve now guarantees.
##
## Hip-fire is measured too and must not move: the fix is only allowed to touch
## the shouldered end of the pose.

const RASTER_SCRIPT: String = "res://tools/ads_occlusion/occlusion_raster.gd"
const REPORT_PATH: String = "res://data/guns/ads_occlusion_report.txt"

## Seeds scanned looking for one weapon per (receiver class, optic, tier) cell.
const SEED_BUDGET: int = 20000
## `WeaponHolster.iron_sight_height` and `sight_notch`, which is what the shipped
## player forwards into the solve.
const IRON_HEIGHT: float = 0.10
const SIGHT_NOTCH: float = 0.25

## `ViewmodelPass.fov_ads`, the lens the gun is drawn through when shouldered.
const FRAME_FOV: float = 44.0
## 1600x900, the resolution every capture and every performance number uses.
const FRAME_ASPECT: float = 1600.0 / 900.0
## Odd, so the exact view axis is a sample rather than something straddled.
const FRAME_COLS: int = 161
const FRAME_ROWS: int = 91
## Half-angle of the sight-picture window: the middle quarter of the ADS lens,
## about a 200 pixel box at 900p, which is where a shooter is actually looking.
const SIGHT_HALF_DEGREES: float = 5.5
const SIGHT_SAMPLES: int = 65
## Half-width of the column the crest is measured in. Narrow on purpose — this
## asks "is anything in front of my aim", not "is anything on screen".
const CREST_HALF_DEGREES: float = 2.0
## `ViewmodelPass.near_plane`, restated for the header line.
const NEAR_PLANE: float = 0.006
## Passes over the whole sample the pose solve is timed across.
const COST_RUNS: int = 20

## Bars. The first two are the whole point and are absolute; the last two are
## budgets for how much gun a shooter should have to look past.
const BAR_CENTRE_BLOCKED: int = 0
## Every weapon's crest must sit at least this far BELOW the view axis, degrees.
const BAR_CREST_DEGREES: float = 0.8
const BAR_SIGHT_FRACTION: float = 0.34
const BAR_FRAME_FRACTION: float = 0.40

var _lines: PackedStringArray = PackedStringArray()
var _raster: RefCounted = null


## Measure the sample and report. Returns false when a bar is missed.
func run() -> bool:
	if not PartLibrary.is_loaded():
		_say("FAILED: the part library is not loaded: %s" % PartLibrary.load_error)
		_finish()
		return false
	var script := load(RASTER_SCRIPT) as GDScript
	if script == null:
		_say("FAILED: could not load %s" % RASTER_SCRIPT)
		_finish()
		return false
	_raster = script.new()

	var sample: Array = _sample()
	_say("ADS occlusion probe")
	_say("")
	_say("sample       %d weapons, one per (receiver class, optic, tier) cell" % sample.size())
	_say(
		(
			"lens         %.0f deg vertical at %.2f:1, near %.3f m"
			% [FRAME_FOV, FRAME_ASPECT, NEAR_PLANE]
		)
	)
	_say(
		(
			"sight window +/- %.1f deg, %d x %d rays"
			% [SIGHT_HALF_DEGREES, SIGHT_SAMPLES, SIGHT_SAMPLES]
		)
	)
	_say("frame        %d x %d rays" % [FRAME_COLS, FRAME_ROWS])
	_say("")
	if sample.is_empty():
		_say("FAILED: the roll produced no weapons")
		_finish()
		return false

	var before: Array = []
	var after: Array = []
	for entry: Dictionary in sample:
		before.append(_measure(entry, _legacy_pose()))
		after.append(_measure(entry, GunHandPose.new()))
	_say("BEFORE — the solve that put the sight datum itself on the view axis")
	_say("")
	_table(before)
	_summary(before)
	_say("")
	_say("AFTER — the eye line cleared off the part boxes")
	_say("")
	_table(after)
	var passed: bool = _summary(after)
	_delta(before, after)
	_cost(sample)
	_finish()
	return passed


## What the eye-line solve costs, which is the only cost it has: it runs inside
## `GunHandPose.configure`, on equip and on swap, and never in a frame that is not
## also building geometry. Timed against the same call with the clearing stages off
## so the figure is the delta and not the whole solve.
func _cost(sample: Array) -> void:
	var legacy := _legacy_pose()
	var solved := GunHandPose.new()
	var runs: int = COST_RUNS
	var before: int = Time.get_ticks_usec()
	for _r: int in runs:
		for entry: Dictionary in sample:
			legacy.configure(entry["spec"], IRON_HEIGHT, SIGHT_NOTCH)
	var middle: int = Time.get_ticks_usec()
	for _r: int in runs:
		for entry: Dictionary in sample:
			solved.configure(entry["spec"], IRON_HEIGHT, SIGHT_NOTCH)
	var after: int = Time.get_ticks_usec()
	var calls: float = float(maxi(runs * sample.size(), 1))
	_say("")
	_say(
		(
			"configure cost, us per weapon    %.1f  ->  %.1f   (%d calls each)"
			% [float(middle - before) / calls, float(after - middle) / calls, int(calls)]
		)
	)


## The pose as it was before the eye line was cleared, built out of the shipped
## resource with the two clearing stages turned off and the fallback pushed out of
## reach. Measuring the old solve this way rather than from a copy of the old code
## is what makes the before and after columns comparable: same sample, same raster,
## same pose resource, three tunables apart.
func _legacy_pose() -> GunHandPose:
	var hand := GunHandPose.new()
	hand.sight_clearance_units = 0.0
	hand.ads_clear_degrees = 0.0
	hand.ads_drop_limit_degrees = 40.0
	return hand


## One weapon per (receiver class, optic state, tier), lowest seed wins, so the
## sample is reproducible and spans the whole part set rather than one gun.
func _sample() -> Array:
	var cells: Dictionary = {}
	for seed_value: int in range(1, SEED_BUDGET + 1):
		var spec: GunSpec = GunFactory.build(seed_value)
		if spec == null:
			continue
		var receiver: GunPart = PartLibrary.part(spec.receiver_index())
		if receiver == null:
			continue
		var key: String = "%s|%s|%d" % [receiver.weapon_class, _optic(spec), spec.tier_index]
		if not cells.has(key):
			cells[key] = spec
	var keys: Array = cells.keys()
	keys.sort()
	var out: Array = []
	for key: String in keys:
		out.append({"key": key, "spec": cells[key]})
	return out


static func _optic(spec: GunSpec) -> String:
	if spec.scoped:
		return "scope"
	return "optic" if spec.has_optic else "irons"


## Put one weapon into the shipped shouldered pose and count the rays it eats.
##
## `GunHandPose` is the resource `WeaponHolster` hosts in the player prefab, and
## `GunPose.transform` is the transform the holster publishes onto `Hand`/`Lift`,
## so this measures the pose that ships and not a model of it.
func _measure(entry: Dictionary, hand: GunHandPose) -> Dictionary:
	var spec: GunSpec = entry["spec"]
	hand.configure(spec, IRON_HEIGHT, SIGHT_NOTCH)
	var pose: GunPose = hand.pose()
	var frame_half := Vector2(
		tan(deg_to_rad(FRAME_FOV * 0.5)) * FRAME_ASPECT, tan(deg_to_rad(FRAME_FOV * 0.5))
	)
	var sight_half: float = tan(deg_to_rad(SIGHT_HALF_DEGREES))
	var ads: PackedVector3Array = _raster.triangles(spec, pose.transform(1.0), pose.lift)
	var hip: PackedVector3Array = _raster.triangles(spec, pose.transform(0.0), pose.lift)
	var window: Dictionary = _raster.cover(
		ads, Vector2(sight_half, sight_half), Vector2i(SIGHT_SAMPLES, SIGHT_SAMPLES)
	)
	var frame: Dictionary = _raster.cover(ads, frame_half, Vector2i(FRAME_COLS, FRAME_ROWS))
	var hip_frame: Dictionary = _raster.cover(hip, frame_half, Vector2i(FRAME_COLS, FRAME_ROWS))
	var crest: float = _raster.crest(ads, tan(deg_to_rad(CREST_HALF_DEGREES)))
	var lift := Vector3(0.0, pose.lift, 0.0)
	var datum: Vector3 = pose.transform(1.0) * (pose.attach.sight_datum + lift)
	return {
		"key": entry["key"],
		"name": spec.weapon_name,
		"centre": bool(window["centre"]),
		"sight": float(window["fraction"]),
		"frame": float(frame["fraction"]),
		"hip": float(hip_frame["fraction"]),
		"crest": rad_to_deg(atan(crest)) if crest > -INF else -90.0,
		"drop": rad_to_deg(atan(datum.y / maxf(-datum.z, 1.0e-6))),
		"scale": pose.ads_scale,
		"relief": pose.sight_distance(1.0),
		"offset": pose.sight_offset(1.0).length(),
	}


func _table(rows: Array) -> void:
	_say(
		(
			"%-26s %6s %7s %7s %7s %7s %6s %7s"
			% ["class | optic | tier", "centre", "sight", "frame", "crest", "drop", "scale", "hip"]
		)
	)
	for row: Dictionary in rows:
		var bad: bool = bool(row["centre"]) or float(row["crest"]) > -BAR_CREST_DEGREES
		_say(
			(
				"%-26s %6s %6.1f%% %6.1f%% %7.2f %7.2f %6.2f %6.1f%%%s"
				% [
					row["key"],
					"BLIND" if row["centre"] else "-",
					float(row["sight"]) * 100.0,
					float(row["frame"]) * 100.0,
					float(row["crest"]),
					float(row["drop"]),
					float(row["scale"]),
					float(row["hip"]) * 100.0,
					"  <-" if bad else "",
				]
			)
		)
	_say("")


func _summary(rows: Array) -> bool:
	var n: int = rows.size()
	var full_scale: float = GunHandPose.new().ads_scale
	var blocked: int = 0
	var above: int = 0
	var sight_sum: float = 0.0
	var frame_sum: float = 0.0
	var hip_sum: float = 0.0
	var worst_sight: float = 0.0
	var worst_frame: float = 0.0
	var worst_crest: float = -1.0e9
	var worst_drop: float = 0.0
	var shrunk: int = 0
	var worst_offset: float = 0.0
	var min_relief: float = 1.0e9
	for row: Dictionary in rows:
		blocked += 1 if row["centre"] else 0
		above += 1 if float(row["crest"]) > -BAR_CREST_DEGREES else 0
		sight_sum += float(row["sight"])
		frame_sum += float(row["frame"])
		hip_sum += float(row["hip"])
		worst_sight = maxf(worst_sight, float(row["sight"]))
		worst_frame = maxf(worst_frame, float(row["frame"]))
		worst_crest = maxf(worst_crest, float(row["crest"]))
		worst_drop = minf(worst_drop, float(row["drop"]))
		shrunk += 1 if float(row["scale"]) < full_scale - 1.0e-6 else 0
		worst_offset = maxf(worst_offset, float(row["offset"]))
		min_relief = minf(min_relief, float(row["relief"]))
	var denominator: float = float(maxi(n, 1))
	_say("weapons                          %d" % n)
	_say(
		(
			"view axis inside the gun         %d of %d  (%.1f%%)"
			% [blocked, n, float(blocked) / denominator * 100.0]
		)
	)
	_say(
		(
			"gun crest above the bar          %d of %d  (bar %.2f deg below axis)"
			% [above, n, BAR_CREST_DEGREES]
		)
	)
	_say("sight window occluded, mean      %.1f%%" % (sight_sum / denominator * 100.0))
	_say(
		(
			"sight window occluded, worst     %.1f%%  (bar %.0f%%)"
			% [worst_sight * 100.0, BAR_SIGHT_FRACTION * 100.0]
		)
	)
	_say("ADS frame occluded, mean         %.1f%%" % (frame_sum / denominator * 100.0))
	_say(
		(
			"ADS frame occluded, worst        %.1f%%  (bar %.0f%%)"
			% [worst_frame * 100.0, BAR_FRAME_FRACTION * 100.0]
		)
	)
	_say("worst crest                      %.2f deg" % worst_crest)
	_say("sight picture below the axis     %.2f deg at worst" % worst_drop)
	_say("shrunk into the pose             %d of %d  (below %.2f x)" % [shrunk, n, full_scale])
	_say("hip frame occluded, mean         %.1f%%" % (hip_sum / denominator * 100.0))
	_say("sight offset at full ADS, worst  %s m" % String.num_scientific(worst_offset))
	_say("eye relief, closest              %.4f m" % min_relief)
	var passed: bool = (
		blocked <= BAR_CENTRE_BLOCKED
		and above == 0
		and worst_sight <= BAR_SIGHT_FRACTION
		and worst_frame <= BAR_FRAME_FRACTION
	)
	_say("")
	_say("RESULT: %s" % ("PASS" if passed else "FAIL"))
	return passed


## The deliverable, on one line each: what the change actually bought.
func _delta(before: Array, after: Array) -> void:
	var n: int = maxi(before.size(), 1)
	_say("")
	_say("BEFORE -> AFTER over %d weapons" % before.size())
	_say(
		(
			"view axis inside the gun         %d  ->  %d  of %d"
			% [_count_blind(before), _count_blind(after), before.size()]
		)
	)
	_say(
		(
			"sight window occluded, mean      %.1f%%  ->  %.1f%%"
			% [_mean(before, "sight") * 100.0, _mean(after, "sight") * 100.0]
		)
	)
	_say(
		(
			"sight window occluded, worst     %.1f%%  ->  %.1f%%"
			% [_worst(before, "sight") * 100.0, _worst(after, "sight") * 100.0]
		)
	)
	_say(
		(
			"ADS frame occluded, mean         %.1f%%  ->  %.1f%%"
			% [_mean(before, "frame") * 100.0, _mean(after, "frame") * 100.0]
		)
	)
	_say(
		(
			"hip frame occluded, mean         %.1f%%  ->  %.1f%%   (must not move)"
			% [_mean(before, "hip") * 100.0, _mean(after, "hip") * 100.0]
		)
	)
	var moved: int = 0
	for i: int in n:
		if absf(float(before[i]["hip"]) - float(after[i]["hip"])) > 1.0e-9:
			moved += 1
	_say("hip poses that moved             %d of %d" % [moved, before.size()])


static func _count_blind(rows: Array) -> int:
	var out: int = 0
	for row: Dictionary in rows:
		out += 1 if row["centre"] else 0
	return out


static func _mean(rows: Array, key: String) -> float:
	var total: float = 0.0
	for row: Dictionary in rows:
		total += float(row[key])
	return total / float(maxi(rows.size(), 1))


static func _worst(rows: Array, key: String) -> float:
	var out: float = 0.0
	for row: Dictionary in rows:
		out = maxf(out, float(row[key]))
	return out


func _finish() -> void:
	if _raster != null:
		_raster.call("clear_cache")
	var file := FileAccess.open(REPORT_PATH, FileAccess.WRITE)
	if file != null:
		file.store_string("\n".join(_lines) + "\n")
		file.close()
	print("\n".join(_lines))


func _say(line: String) -> void:
	_lines.append(line)
