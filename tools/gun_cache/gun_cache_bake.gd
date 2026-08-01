extends RefCounted
## Gun cache bake: seeded example weapons, and the proof that the shouldered pose
## actually looks down the sights.
##
## Rolling a weapon is a few milliseconds of assembly, which is fine on a pickup
## and not fine when the range wants a rack of fifty-six of them at load. This
## writes one `GunSpec` and one packed `GunVisual` per (weapon class, tier) cell,
## plus a manifest, so a demo opens by loading geometry it already paid for.
##
## It then verifies the ADS solve. For every weapon in the cache it configures a
## `GunHandPose` at full ADS and checks that the sight sits on the view axis and
## the bore is parallel to it. That is the one number in this system that cannot be
## eyeballed: a viewmodel that looks plausible and is two centimetres off the sight
## line is a gun that shoots where the crosshair is not. `GunHandPose` is the
## resource the player's `WeaponHolster` actually hosts, so what is asserted here is
## the pose that ships — the bake and the game cannot disagree about the sight line.
##
## Loaded and run by `res://tools/build_gun_cache.gd`. It lives in its own file
## because `--script` compiles the entry script before the project's autoload
## singletons are bound to GDScript, so anything naming `PartLibrary` or
## `GunFactory` at compile time cannot be the entry point. Loaded one frame later,
## from here, every autoload and every global class resolves normally and the whole
## bake stays statically typed.

const CACHE_DIR := "res://data/guns/cache"
const INDEX_PATH := "res://data/guns/cache/index.json"
const REPORT_PATH := "res://data/guns/cache/bake_report.txt"
## The ray caster the occlusion half of the proof uses. Loaded rather than named so
## this file keeps compiling under `--script` before the autoloads exist.
const RASTER_SCRIPT := "res://tools/ads_occlusion/occlusion_raster.gd"

## Tier ranks a `GunSpec` can carry, Hazard through Relic.
const TIER_COUNT := 7
## Seeds scanned looking for one weapon per (class, tier) cell. Relic-grade
## launchers do not fall out of the first thousand rolls; this is what buys them.
const SEED_BUDGET := 40000

## The shouldered sight must land on the view axis to well inside a pixel at any
## sane resolution. This is metres of lateral offset at the sight, and the solve is
## closed-form, so anything above float noise means the maths is wrong.
const ALIGN_POSITION_TOL := 1.0e-6
## Cosine between the bore and the view axis. 1 - 1e-9 is about 1.6 arc seconds.
const ALIGN_ANGLE_TOL := 1.0e-9
## Muzzle and ejection markers derived from a spec must match the ones
## `GunFactory.build_node` authors, in model units.
const MARKER_TOL := 1.0e-5
## Degrees the highest point of the weapon must sit BELOW the view axis at full
## ADS. `GunHandPose.ads_clear_degrees` solves for 1.6; this is the bar, set under
## it so the gate reports a real regression rather than float noise on the target.
const CREST_BAR_DEGREES := 0.8
## Half-width of the column the crest is measured in, degrees. Narrow on purpose:
## this asks whether anything is in front of your aim, not whether anything is on
## screen.
const CREST_HALF_DEGREES := 2.0
## Half-angle of the sight-picture window the covered fraction is reported over.
const SIGHT_HALF_DEGREES := 5.5
## Odd, so the exact view axis is one of the rays rather than something straddled.
const SIGHT_SAMPLES := 33

var _lines: PackedStringArray = PackedStringArray()
var _failed := false


## Bake everything and report. Returns false when the cache could not be written
## or when a weapon in it does not line up on its own sights.
func run() -> bool:
	if not PartLibrary.is_loaded():
		_fail("the part library is not loaded: %s" % PartLibrary.load_error)
		return false
	if DirAccess.make_dir_recursive_absolute(CACHE_DIR) != OK:
		_fail("could not create %s" % CACHE_DIR)
		return false

	_say("gun cache bake")
	_say("")

	var cells: Dictionary = _scan()
	var entries: Array = _write_cache(cells)
	if entries.is_empty():
		_fail("no weapons were cached")
		return false
	_write_index(entries)
	var aligned: bool = _verify(entries)
	_write_report()
	print("\n".join(_lines))
	return aligned and not _failed


## One weapon per (class, tier), lowest seed wins so the cache is reproducible.
## `weapon_class` comes off the receiver, which is what decides what the gun is.
func _scan() -> Dictionary:
	var cells: Dictionary = {}
	var scanned: int = 0
	for seed_value: int in range(1, SEED_BUDGET + 1):
		var spec: GunSpec = GunFactory.build(seed_value)
		if spec == null:
			continue
		scanned += 1
		var receiver: GunPart = PartLibrary.part(spec.receiver_index())
		if receiver == null:
			continue
		var key: String = "%s|%d" % [receiver.weapon_class, spec.tier_index]
		if not cells.has(key):
			cells[key] = spec
	var classes: Dictionary = {}
	for key: String in cells:
		classes[key.split("|")[0]] = true
	_say(
		(
			"scanned      %d seeds, filled %d of %d cells across %d classes"
			% [scanned, cells.size(), classes.size() * TIER_COUNT, classes.size()]
		)
	)
	return cells


## Write a spec and a packed `GunVisual` per cell, sorted so the manifest reads
## class by class and the file list is stable between bakes.
func _write_cache(cells: Dictionary) -> Array:
	var keys: Array = cells.keys()
	keys.sort()
	var entries: Array = []
	for key: String in keys:
		var spec: GunSpec = cells[key]
		var parts: PackedStringArray = key.split("|")
		var weapon_class: String = parts[0]
		var tier: int = int(parts[1])
		var id: String = "%s_t%d" % [weapon_class, tier]
		var spec_path: String = "%s/%s.tres" % [CACHE_DIR, id]
		var scene_path: String = "%s/%s.tscn" % [CACHE_DIR, id]
		if ResourceSaver.save(spec, spec_path) != OK:
			_warn("could not write %s" % spec_path)
			continue
		# Reload the saved resource so the packed scene references it as an
		# external file instead of embedding a second copy of every field.
		var stored := ResourceLoader.load(spec_path, "GunSpec") as GunSpec
		if stored == null or not _write_visual(stored, scene_path):
			continue
		(
			entries
			. append(
				{
					"id": id,
					"weapon_class": weapon_class,
					"tier": tier,
					"tier_name": String(spec.tier_name),
					"name": spec.weapon_name,
					"seed": spec.roll_seed,
					"mass": spec.mass,
					"scoped": spec.scoped,
					"scene": scene_path,
					"spec": spec_path,
				}
			)
		)
	_say("cached       %d weapons into %s" % [entries.size(), CACHE_DIR])
	return entries


func _write_visual(spec: GunSpec, path: String) -> bool:
	var visual := GunVisual.new()
	visual.name = "GunVisual"
	visual.spec = spec
	visual.model_scale = 1.0
	# Baked entries are for benches and racks, where a gun in the world casts a
	# shadow. A viewmodel turns it off on the node it mounts.
	visual.cast_shadows = true
	var gun: Node3D = GunFactory.build_node(spec)
	gun.name = String(GunVisual.GUN_NODE)
	visual.add_child(gun)
	_claim(visual, visual)
	var packed := PackedScene.new()
	var packed_err: int = packed.pack(visual)
	if packed_err != OK:
		visual.free()
		_warn("could not pack %s (error %d)" % [path, packed_err])
		return false
	var err: int = ResourceSaver.save(packed, path)
	visual.free()
	if err != OK:
		_warn("could not write %s (error %d)" % [path, err])
		return false
	return true


func _write_index(entries: Array) -> void:
	var file := FileAccess.open(INDEX_PATH, FileAccess.WRITE)
	if file == null:
		_warn("could not write %s" % INDEX_PATH)
		return
	file.store_string(JSON.stringify({"entries": entries}, "\t"))
	file.close()
	_say("manifest     %s" % INDEX_PATH)


## The alignment proof.
##
## `GunHandPose.configure()` is pure: it reads the baked geometry and produces the
## hip and shouldered poses without a scene tree, which is what lets this run here
## rather than in a play session nobody will repeat. It is also the exact resource
## `WeaponHolster` hosts in the shipped player, so this is not a model of the pose —
## it is the pose.
func _verify(entries: Array) -> bool:
	_say("")
	_say("ADS sight-line verification, %d weapons" % entries.size())
	_say(
		(
			"%-22s %-14s %12s %12s %10s %8s %7s"
			% ["id", "sight", "|xy| ads", "1-cos", "relief m", "crest", "sight%"]
		)
	)
	var raster: RefCounted = _raster()
	var vm := GunHandPose.new()
	var worst_offset: float = 0.0
	var worst_angle: float = 0.0
	var worst_marker: float = 0.0
	var worst_crest: float = -1.0e9
	var worst_window: float = 0.0
	var blind: int = 0
	var min_relief: float = 1.0e9
	var max_relief: float = -1.0e9
	var failures: int = 0
	for entry: Dictionary in entries:
		var spec := ResourceLoader.load(String(entry["spec"]), "GunSpec") as GunSpec
		if spec == null:
			failures += 1
			continue
		vm.configure(spec)
		var pose: GunPose = vm.pose()
		var attach: GunAttachPoints = pose.attach
		if not attach.valid:
			_say("%-22s INVALID SOLVE" % entry["id"])
			failures += 1
			continue
		var offset: float = pose.sight_offset(1.0).length()
		var angle_err: float = 1.0 - pose.bore_alignment(1.0)
		var relief: float = pose.sight_distance(1.0)
		var marker_err: float = _marker_error(spec, attach)
		var seen: Dictionary = _occlusion(raster, spec, pose)
		worst_offset = maxf(worst_offset, offset)
		worst_angle = maxf(worst_angle, absf(angle_err))
		worst_marker = maxf(worst_marker, marker_err)
		worst_crest = maxf(worst_crest, float(seen["crest"]))
		worst_window = maxf(worst_window, float(seen["window"]))
		blind += 1 if seen["centre"] else 0
		min_relief = minf(min_relief, relief)
		max_relief = maxf(max_relief, relief)
		var bad: bool = (
			offset > ALIGN_POSITION_TOL
			or absf(angle_err) > ALIGN_ANGLE_TOL
			or marker_err > MARKER_TOL
			or relief <= 0.0
			or bool(seen["centre"])
			or float(seen["crest"]) > -CREST_BAR_DEGREES
		)
		if bad:
			failures += 1
		_say(
			(
				"%-22s %-14s %12s %12s %10.4f %8.2f %6.1f%%%s"
				% [
					entry["id"],
					"scope" if attach.sight_optical else ("sight" if spec.has_optic else "irons"),
					_sci(offset),
					_sci(angle_err),
					relief,
					float(seen["crest"]),
					float(seen["window"]) * 100.0,
					"  FAIL" if bad else "",
				]
			)
		)
	_say("")
	_say(
		(
			"worst sight offset at full ADS   %s m  (tol %s)"
			% [_sci(worst_offset), _sci(ALIGN_POSITION_TOL)]
		)
	)
	_say(
		(
			"worst bore misalignment  1-cos   %s    (tol %s)"
			% [_sci(worst_angle), _sci(ALIGN_ANGLE_TOL)]
		)
	)
	_say("worst marker disagreement        %s mu (tol %s)" % [_sci(worst_marker), _sci(MARKER_TOL)])
	_say("eye relief range                 %.4f .. %.4f m" % [min_relief, max_relief])
	_say("view axis inside the gun         %d of %d  (must be 0)" % [blind, entries.size()])
	_say("worst crest                      %.2f deg (bar %.2f)" % [worst_crest, -CREST_BAR_DEGREES])
	_say("worst sight window occluded      %.1f%%" % (worst_window * 100.0))
	_say("result                           %s" % ("PASS" if failures == 0 else "FAIL"))
	return failures == 0


## The occlusion half of the proof: rays from the eye through the sight picture,
## counted where they meet the weapon's own triangles.
##
## An exact `|xy|` at the sight says the ADS solve aligned a POINT. It says nothing
## about the receiver, the comb and the optic around that point, and on this part
## library — solid slabs, no aperture — those used to sit across the axis on most
## rolls. `crest` is the highest elevation the weapon reaches in a narrow column
## around the axis: negative means the whole weapon is below your aim.
func _occlusion(raster: RefCounted, spec: GunSpec, pose: GunPose) -> Dictionary:
	if raster == null:
		return {"centre": false, "crest": -90.0, "window": 0.0}
	var tris: PackedVector3Array = raster.call("triangles", spec, pose.transform(1.0), pose.lift)
	var half: float = tan(deg_to_rad(SIGHT_HALF_DEGREES))
	var window: Dictionary = raster.call(
		"cover", tris, Vector2(half, half), Vector2i(SIGHT_SAMPLES, SIGHT_SAMPLES)
	)
	var crest: float = raster.call("crest", tris, tan(deg_to_rad(CREST_HALF_DEGREES)))
	return {
		"centre": bool(window["centre"]),
		"crest": rad_to_deg(atan(crest)) if crest > -INF else -90.0,
		"window": float(window["fraction"]),
	}


func _raster() -> RefCounted:
	var script := load(RASTER_SCRIPT) as GDScript
	if script == null:
		_warn("could not load %s; the occlusion check did not run" % RASTER_SCRIPT)
		return null
	return script.new()


## `GunAttachPoints.for_spec` derives the muzzle and the ejection port from the
## spec; `GunFactory.build_node` authors markers for the same two points. They are
## the same geometry stated twice, so they had better agree.
func _marker_error(spec: GunSpec, derived: GunAttachPoints) -> float:
	var node: Node3D = GunFactory.build_node(spec)
	var adopted := GunAttachPoints.for_spec(spec)
	adopted.adopt_markers(node)
	node.free()
	return maxf(
		derived.muzzle.distance_to(adopted.muzzle), derived.eject.distance_to(adopted.eject)
	)


## Every child has to be owned by the root or `PackedScene.pack` writes an empty
## scene with a single node in it.
func _claim(node: Node, root_node: Node) -> void:
	for child: Node in node.get_children():
		child.owner = root_node
		_claim(child, root_node)


func _write_report() -> void:
	var file := FileAccess.open(REPORT_PATH, FileAccess.WRITE)
	if file == null:
		push_error("build_gun_cache: could not write %s" % REPORT_PATH)
		return
	file.store_string("\n".join(_lines) + "\n")
	file.close()


## Godot's format strings have no `%e`, and these are the numbers where the
## exponent is the whole point.
static func _sci(value: float) -> String:
	if value == 0.0:
		return "0"
	return String.num_scientific(value)


func _say(line: String) -> void:
	_lines.append(line)


## A cell that could not be written. The bake carries on and the manifest simply
## does not list it; the report says which one and why.
func _warn(reason: String) -> void:
	_failed = true
	push_warning("build_gun_cache: %s" % reason)
	_say("SKIPPED: %s" % reason)


func _fail(reason: String) -> void:
	_failed = true
	push_error("build_gun_cache: %s" % reason)
	_say("FAILED: %s" % reason)
	_write_report()
	print("\n".join(_lines))
