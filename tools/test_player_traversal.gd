extends SceneTree
## Headless verification of res://systems/player/{player_mantle,player_vault,player_ladder}.gd.
##
## Builds graded ledges out of real colliders, sweeps the mantle planner across them and
## reports the height band in which it fires; replays every armed arc at 240 Hz and
## measures how far the body cylinder penetrates the obstacle it is crossing; checks that
## head room is respected; checks that a thin rail is hurdled and a thick wall is climbed;
## and checks the ladder volume's frame, envelope and registry.
##
## Each case gets its own physics frame, because a collider moved this frame is not in the
## broadphase until the next one.
##
## Run:
##   godot --headless --path <project> --script res://tools/test_player_traversal.gd

## Radius of the real body. `PlayerController.radius`.
const BODY_RADIUS: float = 0.34
## Head room the landing needs. `crouch_height + 0.06`.
const CROUCH_CLEAR: float = 1.18
## Radius the controller hands the planner for head-room tests. `radius * 0.92`.
const CLEAR_RADIUS: float = 0.3128
const STEP_HEIGHT: float = 0.58
const AUTO_RISE: float = 1.32
const MANUAL_RISE: float = 2.05
const HEIGHT_MIN: float = 0.05
const HEIGHT_MAX: float = 2.40
const HEIGHT_STEP: float = 0.05
## Far above everything, i.e. "no ceiling".
const NO_CEILING: float = 400.0

var _harness: Harness = null


## Owns the colliders and runs one case per physics frame.
class Harness:
	extends Node3D

	var probe: PlayerProbe = PlayerProbe.new()
	var mantle: PlayerMantle = PlayerMantle.new()
	var cases: Array[Dictionary] = []
	var results: Array[Dictionary] = []
	var finished: bool = false

	var _wall: StaticBody3D = null
	var _wall_shape: BoxShape3D = null
	var _ceiling: StaticBody3D = null
	var _index: int = -1

	func _ready() -> void:
		add_child(_slab(Vector3(60.0, 2.0, 60.0), Vector3(0.0, -1.0, 0.0)))
		_wall_shape = BoxShape3D.new()
		_wall_shape.size = Vector3(8.0, 1.0, 1.0)
		_wall = _body(_wall_shape, Vector3.ZERO)
		add_child(_wall)
		_ceiling = _slab(Vector3(8.0, 0.4, 6.0), Vector3.ZERO)
		_ceiling.position = Vector3(0.0, NO_CEILING, -2.0)
		add_child(_ceiling)
		mantle.clear_height = CROUCH_CLEAR
		mantle.clear_radius = CLEAR_RADIUS
		mantle.step_height = STEP_HEIGHT

	func _physics_process(_dt: float) -> void:
		if finished:
			return
		# Evaluate the case whose geometry was placed last frame, then place the next.
		if _index >= 0:
			results.append(_evaluate(cases[_index]))
		_index += 1
		if _index >= cases.size():
			finished = true
			return
		_place(cases[_index])

	func _place(c: Dictionary) -> void:
		var top: float = c["top"]
		var depth: float = c["depth"]
		var near_z: float = c["near_z"]
		# The slab's top face sits at `top` and it runs 8 m down, so it is always solid
		# from the ground up. It occupies z <= near_z; forward is -Z.
		_wall_shape.size = Vector3(8.0, top + 8.0, depth)
		_wall.position = Vector3(0.0, top - (top + 8.0) * 0.5, near_z - depth * 0.5)
		_ceiling.position = Vector3(0.0, c["ceiling"], near_z - 2.0)

	func _evaluate(c: Dictionary) -> Dictionary:
		probe.bind(get_world_3d().direct_space_state, [] as Array[RID], 0xFFFFFFFF)
		# A control case runs the reference's curves with the anti-clip cap disabled, to
		# show what the cap is actually buying.
		var control: bool = c["label"].begins_with("control")
		mantle.clear_radius = 0.0 if control else CLEAR_RADIUS
		mantle.lip_margin = 0.0 if control else 0.03
		var feet := Vector3.ZERO
		var ok: bool = mantle.plan(probe, feet, 0.0, c["max_rise"], c["speed"])
		var out := {
			"case": c,
			"planned": ok,
			"hurdle": false,
			"exit": 0.0,
			"landing": Vector3.ZERO,
			"rise": 0.0,
			"penetration": 0.0,
		}
		if not ok:
			return out
		out["hurdle"] = mantle.is_hurdle
		out["exit"] = mantle.exit_speed()
		out["landing"] = mantle.target()
		out["rise"] = mantle.rise
		out["penetration"] = _replay(c["top"], c["near_z"])
		mantle.cancel()
		return out

	## Step the armed arc at 240 Hz and return the deepest horizontal penetration of the
	## body cylinder into the slab, counted only while the feet are still below its top.
	func _replay(top: float, near_z: float) -> float:
		var dt: float = 1.0 / 240.0
		var worst: float = 0.0
		var guard: int = 0
		while mantle.active and guard < 4000:
			var p: Vector3 = mantle.advance(dt)
			guard += 1
			if p.y >= top - 1e-4:
				continue
			# The slab fills z <= near_z, so the centre must stay a full radius clear.
			var pen: float = BODY_RADIUS - (p.z - near_z)
			if pen > worst:
				worst = pen
		return worst

	static func _slab(size: Vector3, offset: Vector3) -> StaticBody3D:
		var shape := BoxShape3D.new()
		shape.size = size
		return _body(shape, offset)

	static func _body(shape: Shape3D, offset: Vector3) -> StaticBody3D:
		var body := StaticBody3D.new()
		var col := CollisionShape3D.new()
		col.shape = shape
		col.position = offset
		body.add_child(col)
		return body


func _initialize() -> void:
	_harness = Harness.new()
	_harness.cases = _build_cases()
	root.add_child(_harness)


func _process(_delta: float) -> bool:
	if not _harness.finished:
		return false
	quit(0 if _report() == 0 else 1)
	return true


func _build_cases() -> Array[Dictionary]:
	var cases: Array[Dictionary] = []
	for spec: Array in [
		["auto", AUTO_RISE, 0.92], ["manual", MANUAL_RISE, 0.92], ["auto-close", AUTO_RISE, 0.42]
	]:
		var label: String = spec[0]
		var max_rise: float = spec[1]
		var probe_d: float = spec[2]
		# Near face 20 mm inside the probe distance, so that probe is the first to land
		# on the slab and the previous ones fall short of it.
		var near_z: float = -(probe_d - 0.02)
		var height: float = HEIGHT_MIN
		while height <= HEIGHT_MAX + 1e-6:
			cases.append(_case("sweep:" + label, height, near_z, 6.0, NO_CEILING, max_rise, 5.0))
			height += HEIGHT_STEP
	var gap: float = CROUCH_CLEAR + 0.40
	while gap >= 0.60:
		cases.append(_case("headroom", 1.00, -0.90, 6.0, 1.00 + gap + 0.20, MANUAL_RISE, 1.0))
		gap -= 0.02
	for depth: float in [0.30, 0.60, 0.90, 1.40, 3.00]:
		cases.append(_case("hurdle", 0.95, -0.90, depth, NO_CEILING, AUTO_RISE, 6.0))
	cases.append(_case("hurdle-slow", 0.95, -0.90, 0.40, NO_CEILING, AUTO_RISE, 1.0))
	for probe_d: float in PlayerMantle.PROBE_DISTANCES:
		for top: float in [0.70, 1.00, 1.30]:
			cases.append(_case("control", top, -(probe_d - 0.02), 6.0, NO_CEILING, AUTO_RISE, 5.0))
	return cases


func _case(
	label: String,
	top: float,
	near_z: float,
	depth: float,
	ceiling: float,
	max_rise: float,
	speed: float
) -> Dictionary:
	return {
		"label": label,
		"top": top,
		"near_z": near_z,
		"depth": depth,
		"ceiling": ceiling,
		"max_rise": max_rise,
		"speed": speed,
	}


func _report() -> int:
	var failures: int = 0
	print("=== PLAYER TRAVERSAL VERIFICATION ===")
	failures += _report_sweep("sweep:auto", AUTO_RISE, 0.92)
	failures += _report_sweep("sweep:manual", MANUAL_RISE, 0.92)
	failures += _report_sweep("sweep:auto-close", AUTO_RISE, 0.42)
	failures += _report_headroom()
	failures += _report_hurdle()
	failures += _report_control()
	failures += _report_ladder()
	print("")
	if failures == 0:
		print("RESULT: PASS")
	else:
		print("RESULT: FAIL (%d checks)" % failures)
	return failures


func _report_sweep(label: String, max_rise: float, probe_d: float) -> int:
	var failures: int = 0
	var lo: float = -1.0
	var hi: float = -1.0
	var gaps: int = 0
	var was: bool = false
	var worst: float = 0.0
	var worst_at: float = 0.0
	for r: Dictionary in _rows(label):
		var top: float = r["case"]["top"]
		if r["planned"]:
			if lo < 0.0:
				lo = top
			elif not was:
				gaps += 1
			hi = top
			if r["penetration"] > worst:
				worst = r["penetration"]
				worst_at = top
		was = r["planned"]
	print("")
	print("[%s] max_rise %.2f m, ledge found by the probe at %.2f m" % [label, max_rise, probe_d])
	if lo < 0.0:
		print("  band: NONE — the planner never fired")
		return 1
	print("  fires for ledge tops %.2f m .. %.2f m (step %.2f)" % [lo, hi, HEIGHT_STEP])
	print("  discontinuities inside the band: %d" % gaps)
	print("  worst penetration of the obstacle: %.5f m (at a %.2f m ledge)" % [worst, worst_at])
	if gaps != 0:
		print("  FAIL: band is not contiguous")
		failures += 1
	if worst > 0.001:
		print("  FAIL: the arc clips the obstacle")
		failures += 1
	if hi > max_rise + 1e-6 or hi < max_rise - HEIGHT_STEP - 1e-6:
		print("  FAIL: band top %.2f is not the max rise %.2f" % [hi, max_rise])
		failures += 1
	# The floor of the band is whichever rule gives out first: the ramp test refuses
	# anything the step-up could have walked, but it is only consulted below a
	# rise-over-run of `ramp_ratio`, so a close, steep ledge is a ledge at any height.
	var steep: float = probe_d * _harness.mantle.ramp_ratio
	print(
		"  band floor %.2f m (step-up %.2f m, steepness escape %.2f m)" % [lo, STEP_HEIGHT, steep]
	)
	if lo > STEP_HEIGHT + 1e-6 or lo >= steep - 1e-6:
		return failures
	print("  FAIL: fires below the step-up height without being steep enough to justify it")
	return failures + 1


func _report_headroom() -> int:
	var last_ok: float = -1.0
	var first_fail: float = -1.0
	# Gaps are swept from wide to narrow. Only the transition matters: keep going once the
	# ceiling is low enough to become a ledge in its own right, which it eventually is.
	for r: Dictionary in _rows("headroom"):
		var gap: float = r["case"]["ceiling"] - 1.20
		if first_fail >= 0.0:
			break
		if r["planned"]:
			last_ok = gap
		else:
			first_fail = gap
	print("")
	print("[headroom] 1.00 m ledge, landing needs %.2f m of clearance" % CROUCH_CLEAR)
	print("  planned down to a %.2f m gap, refused at %.2f m" % [last_ok, first_fail])
	if first_fail < 0.0 or absf(first_fail - CROUCH_CLEAR) > 0.06:
		print("  FAIL: the refusal threshold is not the crouch clearance")
		return 1
	return 0


func _report_hurdle() -> int:
	var failures: int = 0
	print("")
	print("[hurdle] 0.95 m rail, carried speed 6.0 m/s, near face at z = -0.90")
	for r: Dictionary in _rows("hurdle"):
		var depth: float = r["case"]["depth"]
		if not r["planned"]:
			print("  depth %.2f m: NO PLAN" % depth)
			failures += 1
			continue
		var landing: Vector3 = r["landing"]
		print(
			(
				"  depth %.2f m: %-9s exit %.2f m/s  landing z %+.2f  clip %.5f m"
				% [
					depth,
					"HURDLE" if r["hurdle"] else "climb-on",
					r["exit"],
					landing.z,
					r["penetration"],
				]
			)
		)
		if r["penetration"] > 0.001:
			print("    FAIL: clipped the rail")
			failures += 1
		if depth <= 0.90 and not r["hurdle"]:
			print("    FAIL: a %.2f m rail should be hurdled" % depth)
			failures += 1
		if depth >= 1.40 and r["hurdle"]:
			print("    FAIL: a %.2f m wall is not a rail" % depth)
			failures += 1
		if r["hurdle"] and landing.z > r["case"]["near_z"] - depth:
			print("    FAIL: hurdle landing is not past the far face")
			failures += 1
	for r: Dictionary in _rows("hurdle-slow"):
		print("  walking pace 1.0 m/s: planned=%s hurdle=%s" % [r["planned"], r["hurdle"]])
		if r["hurdle"]:
			print("    FAIL: walking pace should climb on, not hurdle")
			failures += 1
	return failures


## What the reference's curves do on their own. Anything above zero here is the corner
## clip the anti-clip cap exists to remove; if this ever reads zero the cap is dead code.
func _report_control() -> int:
	var worst: Dictionary = {}
	for r: Dictionary in _rows("control"):
		var face: float = -float(r["case"]["near_z"])
		var pen: float = r["penetration"]
		if pen > float(worst.get(face, 0.0)):
			worst[face] = pen
	print("")
	print("[control] same arcs with the anti-clip cap disabled")
	var any: float = 0.0
	for face: float in worst:
		print("  near face %.2f m ahead: worst penetration %.4f m" % [face, worst[face]])
		any = maxf(any, worst[face])
	if any > 0.001:
		return 0
	print("  FAIL: the cap removes nothing, so it should not exist")
	return 1


func _report_ladder() -> int:
	var failures: int = 0
	var l := PlayerLadder.new()
	l.climb_height = 4.0
	root.add_child(l)
	l.rotation.y = PI * 0.5
	l.position = Vector3(10.0, 2.0, -3.0)
	l.refresh()
	print("")
	print("[ladder] origin (10, 2, -3), yaw 90 deg, climb_height 4.00 m")
	print(
		(
			"  out (%.3f, %.3f)  along (%.3f, %.3f)  bottom %.3f  top %.3f"
			% [l.out_x(), l.out_z(), l.along_x(), l.along_z(), l.bottom_y(), l.top_y()]
		)
	)
	if absf(l.out_x() - 1.0) > 1e-5 or absf(l.out_z()) > 1e-5:
		print("  FAIL: yaw 90 deg must put local +Z on world +X")
		failures += 1
	if absf(l.bottom_y() - 1.85) > 1e-5 or absf(l.top_y() - 6.0) > 1e-5:
		print("  FAIL: vertical extent is wrong")
		failures += 1
	var on := Vector3(10.2, 4.0, -3.0)
	var far := Vector3(11.2, 4.0, -3.0)
	var side := Vector3(10.2, 4.0, -4.2)
	var over := Vector3(10.2, 6.30, -3.0)
	var under := Vector3(10.2, -0.4, -3.0)
	print(
		(
			"  fit: at stand-off %.3f  too far %.3f  sideways %.3f  above %.3f  below %.3f"
			% [
				l.fit_score(on, 1.8),
				l.fit_score(far, 1.8),
				l.fit_score(side, 1.8),
				l.fit_score(over, 1.8),
				l.fit_score(under, 1.8),
			]
		)
	)
	if l.fit_score(on, 1.8) < 0.0:
		print("  FAIL: should attach at the stand-off distance")
		failures += 1
	if l.fit_score(far, 1.8) >= 0.0 or l.fit_score(side, 1.8) >= 0.0:
		print("  FAIL: the attach envelope is too generous")
		failures += 1
	if l.fit_score(over, 1.8) >= 0.0 or l.fit_score(under, 1.8) >= 0.0:
		print("  FAIL: should let go past the ends")
		failures += 1
	if PlayerLadder.find_for(on, 1.8) != l or PlayerLadder.find_for(far, 1.8) != null:
		print("  FAIL: find_for disagrees with fit_score")
		failures += 1
	print("  registry holds %d ladder(s)" % PlayerLadder.registry().size())
	if PlayerLadder.registry().size() != 1:
		print("  FAIL: registry should hold exactly the one ladder in the tree")
		failures += 1
	l.free()
	if not PlayerLadder.registry().is_empty():
		print("  FAIL: a freed ladder stayed in the registry")
		failures += 1
	return failures


func _rows(label: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for r: Dictionary in _harness.results:
		if r["case"]["label"] == label:
			out.append(r)
	return out
