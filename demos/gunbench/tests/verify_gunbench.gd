extends SceneTree
## GRAB ACCEPTANCE. Runs the baked gun bench and proves the thing the user report said
## did not work: that you can take a gun off a stand, that you get THAT gun, and that
## what you were holding goes back onto the stand instead of vanishing.
##
## Run it with a window, so it can also photograph what it asserted:
##   godot --path <project> --resolution 1600x900 \
##       --script res://demos/gunbench/tests/verify_gunbench.gd
##
## Headless works too and is what a bake would run; the PNG pass reports itself as NOT
## MEASURED rather than pretending, exactly as `tools/verify_click_input.gd` does for
## the menu.
##
## WHAT IT ASKS, in order:
##   1. every control the bench documents exists, with the id it documents, and the
##      retired TO HAND plate does not
##   2. three DISTINCT weapons are in play at boot — stand A, stand B, your hands
##   3. each grab button is REACHABLE: a ray from the player's own eye, from where the
##      demo spawns him, lands on that button and not on the console in front of it
##   4. GRAB A puts stand A's weapon in your hands and your weapon on stand A, and
##      GRAB B does the same for stand B. Both are tested for the PERMUTATION — the
##      three weapons afterwards are the same three weapons as before, reordered —
##      which is what "nothing vanishes" means as an assertion
##   5. the middle card and the cartridge card under it read out the weapon that is
##      actually in your hands, checked against the text the canvas will draw
##   6. ROLL RACK rerolls all six hooks and changes NEITHER stand NOR your hands
##   7. ROLL changes stand A only; COMPARE copies A onto B; a peg trades with stand A
##
## EVERYTHING IS DUCK-TYPED. A `--script` main loop compiles before the autoloads are
## registered, so naming `Gunbench` here would drag `GameSettings` and `SceneRouter`
## into a compile that cannot resolve them. `DiegeticControl` and `GameLayers` are
## named because they reach no autoload and `tools/verify_click_input.gd` already
## proves it.
##
## The one white-box reach is the readout's canvas: `_title` is the string the panel
## will actually draw, and there is no public way to read it back. Asserting the
## demo's own `hand_spec()` instead would only prove the demo agrees with itself.

const SCENE_PATH: String = "res://demos/gunbench/gunbench.tscn"
const REPORT_PATH: String = "res://demos/gunbench/gunbench_verify.txt"
const SHOT_DIR: String = "res://_shots/gunbench_grab"

## Frames the bay gets to build itself, roll four weapons and settle the player.
const WARMUP_FRAMES: int = 40
## Physics frames a holster swap is given to exchange the geometry. The stow is
## `stow_base + mass * stow_per_kg` and caps at 0.45 s, so 60 frames at 60 Hz is more
## than twice the longest stow the heaviest rolled weapon can ask for.
const SWAP_FRAMES: int = 60
## Physics frames spent settling after the player is teleported.
const SETTLE_FRAMES: int = 12
## Metres the reachability ray is allowed to travel. `Gunbench.fire_reach` is 120 and
## the bay is 11 m across, so anything this cannot reach, a bullet could not either.
const REACH: float = 12.0
## Drawn-plus-physics frame pairs the eye is given to swing onto a control, and the
## pairs it then has to stay on it for. `PlayerCamera` smooths with a time constant, so
## this is a convergence budget and not a delay — see `_settle_aim`.
const AIM_TRIES: int = 40
const AIM_HOLD: int = 6

## Every control the bench documents, by node path and by the id it must carry.
const CONTROLS: Array = [
	["Stands/MainStand/Column/Station/Grab", "grab_main"],
	["Stands/RivalStand/Column/Station/Grab", "grab_rival"],
	["Console/Panel/Roll", "roll"],
	["Console/Panel/Class", "class"],
	["Console/Panel/Tier", "tier"],
	["Console/Panel/Compare", "compare"],
	["Console/Deck/Strip", "strip"],
	["Rack/RollStation/Roll", "roll_rack"],
]
## Ids that must NOT exist any more. TO HAND was the second way to do what the grab
## stations do, and a demo with both is the confusion this pass was asked to end.
const RETIRED: PackedStringArray = ["to_hand"]

var _lines: PackedStringArray = PackedStringArray()
var _failed: bool = false
var _started: bool = false
var _shots: int = 0


func _process(_delta: float) -> bool:
	if not _started:
		_started = true
		_run()
	return false


func _run() -> void:
	var packed: PackedScene = load(SCENE_PATH) as PackedScene
	if packed == null:
		_fail("%s did not load" % SCENE_PATH)
		_finish()
		return
	var bench: Node = packed.instantiate()
	root.add_child(bench)
	current_scene = bench
	for _i: int in WARMUP_FRAMES:
		await physics_frame

	_say("GUNBENCH GRAB ACCEPTANCE")
	_say("")
	_check_controls(bench)
	await _check_boot(bench)
	await _check_reach(bench)
	await _check_grab(bench, "Stands/MainStand", "grab_main", "A")
	await _check_grab(bench, "Stands/RivalStand", "grab_rival", "B")
	await _check_rack(bench)
	await _check_console(bench)
	await _shoot_the_evidence(bench)
	_summarise()
	_finish()


# --- the controls -------------------------------------------------------------


func _check_controls(bench: Node) -> void:
	var ids: Dictionary = {}
	for node: Node in bench.find_children("*", "", true, false):
		var control := node as DiegeticControl
		if control != null and not control.control_id.is_empty():
			ids[String(control.control_id)] = true
	for entry: Array in CONTROLS:
		var control: DiegeticControl = bench.get_node_or_null(NodePath(String(entry[0])))
		if control == null:
			_fail("no control at %s" % entry[0])
			continue
		if String(control.control_id) != String(entry[1]):
			_fail("%s carries id '%s', expected '%s'" % [entry[0], control.control_id, entry[1]])
			continue
		_say(
			"control   %-42s id %-11s label %s" % [entry[0], control.control_id, control.label_text]
		)
	for dead: String in RETIRED:
		if ids.has(dead):
			_fail("retired control '%s' is still in the scene" % dead)
	_say("")


# --- what the bay holds -------------------------------------------------------


func _check_boot(bench: Node) -> void:
	var a: Object = _stand_spec(bench, "Stands/MainStand")
	var b: Object = _stand_spec(bench, "Stands/RivalStand")
	var hand: Object = _hand(bench)
	_say("boot      A %-26s B %-26s hands %s" % [_name_of(a), _name_of(b), _name_of(hand)])
	if a == null or b == null or hand == null:
		_fail("the bay did not open with a weapon on both stands and one in your hands")
		return
	if a == b or a == hand or b == hand:
		_fail("two of the three opening weapons are the same object; the first trade is a no-op")
	await physics_frame


## A ray from the player's own eye, aimed at each control from where the demo puts him.
## This is the user's complaint stated as a measurement: a button you cannot get a ray
## onto from the door is a button you cannot press.
##
## THE AIM HAS TO CONVERGE, NOT BE ASSUMED. Writing `yaw` and `pitch` moves the BODY;
## `PlayerCamera` runs at `process_priority` 100 and lerps the eye toward it, so a fixed
## two-physics-frame settle measures the tail of the last swing rather than this one.
## Measured, before this loop existed: five of eight controls "failed", every one of them
## reporting the PREVIOUS control as the blocker, and the same build passed twice on
## either side of it. Poll until the crosshair arrives, then require it to STAY.
func _check_reach(bench: Node) -> void:
	var player: Node3D = bench.get_node_or_null(^"Player") as Node3D
	var eye: Camera3D = bench.get_node_or_null(^"Player/Eye") as Camera3D
	if player == null or eye == null:
		_fail("the bench has no Player/Eye to aim")
		return
	for entry: Array in CONTROLS:
		var control: DiegeticControl = bench.get_node_or_null(NodePath(String(entry[0])))
		if control == null:
			continue
		var hit: Object = await _settle_aim(player, eye, control)
		var metres: float = eye.global_position.distance_to(control.global_position)
		if hit == control:
			_say("reach     %-11s clear from spawn at %.2f m" % [control.control_id, metres])
			continue
		var blocker: String = "nothing" if hit == null else String((hit as Node).name)
		_fail(
			(
				"%s is NOT reachable from the spawn point: the ray stops on %s at %.2f m"
				% [control.control_id, blocker, metres]
			)
		)
	_aim(player, Vector3(0.0, 1.3, -2.4))
	await physics_frame


## Turn the player onto `control` and wait for the eye to actually get there. Returns
## what the crosshair finally rests on, which is `control` when the aim is clear.
func _settle_aim(player: Node3D, eye: Camera3D, control: DiegeticControl) -> Object:
	_aim(player, control.global_position)
	var hit: Object = null
	for _i: int in AIM_TRIES:
		# A drawn frame, because the camera rig only advances in `_process`, and then a
		# physics frame, because the ray is cast against the physics space.
		await process_frame
		await physics_frame
		_aim(player, control.global_position)
		hit = _under_crosshair(eye)
		if hit == control:
			break
	if hit != control:
		return hit
	# And still there after the eye has had time to drift off it again.
	for _i: int in AIM_HOLD:
		await process_frame
		await physics_frame
	return _under_crosshair(eye)


# --- the trade ----------------------------------------------------------------


## Press one grab button and prove the three weapons were PERMUTED, not replaced.
func _check_grab(bench: Node, stand_path: String, id: String, mark: String) -> void:
	var stand: Node = bench.get_node_or_null(NodePath(stand_path))
	var other_path: String = (
		"Stands/RivalStand" if stand_path.ends_with("MainStand") else "Stands/MainStand"
	)
	var before_stand: Object = _stand_spec(bench, stand_path)
	var before_other: Object = _stand_spec(bench, other_path)
	var before_hand: Object = _hand(bench)

	var control: DiegeticControl = bench.get_node_or_null(
		NodePath(stand_path + "/Column/Station/Grab")
	)
	if control == null or stand == null:
		_fail("GRAB %s has no button or no stand" % mark)
		return
	if not control.interact():
		_fail("GRAB %s refused a walk-up press" % mark)
		return
	for _i: int in SWAP_FRAMES:
		await physics_frame

	var after_stand: Object = _stand_spec(bench, stand_path)
	var after_hand: Object = _hand(bench)
	var after_other: Object = _stand_spec(bench, other_path)
	_say("GRAB %s    took %-26s left %-26s" % [mark, _name_of(after_hand), _name_of(after_stand)])
	if after_hand != before_stand:
		_fail("GRAB %s did not put THAT stand's weapon in your hands" % mark)
	if after_stand != before_hand:
		_fail("GRAB %s did not put the weapon you were holding back on the stand" % mark)
	if after_other != before_other:
		_fail("GRAB %s disturbed the other stand" % mark)
	if (
		_multiset([before_stand, before_other, before_hand])
		!= _multiset([after_stand, after_other, after_hand])
	):
		_fail("GRAB %s did not permute the three weapons; something was created or lost" % mark)
	_check_cards(bench, after_hand, "after GRAB " + mark)
	if id != String(control.control_id):
		_fail("GRAB %s answers to '%s'" % [mark, control.control_id])


## The middle card and the cartridge card under it, read as the strings the canvases
## will draw. `_title` and `_lines` are private and there is no public reader; asserting
## the demo's own accessor instead would only prove the demo agrees with itself.
func _check_cards(bench: Node, hand: Object, when: String) -> void:
	if hand == null:
		return
	var want: String = String(hand.get(&"weapon_name")).to_upper()
	var got: String = _card_title(bench, "Cards/Hands")
	if got != want:
		_fail("the IN YOUR HANDS card reads '%s' %s; the hand holds '%s'" % [got, when, want])
		return
	# The cartridge card under it belongs to the same weapon. Its title never changes, so
	# the assertion is on its first LINE, which `GunbenchCards.cartridge_lines` fills with
	# the calibre.
	var bore: String = String(hand.get(&"caliber")).to_upper()
	var lines: PackedStringArray = _card_lines(bench, "Cards/Cartridge")
	if lines.is_empty() or lines[0] != bore:
		var head: String = "nothing" if lines.is_empty() else lines[0]
		_fail("the CARTRIDGE card reads '%s' %s; the hand chambers '%s'" % [head, when, bore])
		return
	_say("cards     IN YOUR HANDS '%s' over CARTRIDGE '%s' %s" % [got, bore, when])


# --- the rack -----------------------------------------------------------------


## The whole point of the rack having its own button: it rerolls the wall and touches
## nothing else.
func _check_rack(bench: Node) -> void:
	var before: Array = _rack(bench)
	var a: Object = _stand_spec(bench, "Stands/MainStand")
	var b: Object = _stand_spec(bench, "Stands/RivalStand")
	var hand: Object = _hand(bench)
	var control: DiegeticControl = bench.get_node_or_null(^"Rack/RollStation/Roll")
	if control == null:
		_fail("the rack has no roll button")
		return
	if not control.interact():
		_fail("ROLL RACK refused a walk-up press")
		return
	for _i: int in SWAP_FRAMES:
		await physics_frame
	var after: Array = _rack(bench)
	var moved: int = 0
	for i: int in mini(before.size(), after.size()):
		if before[i] != after[i]:
			moved += 1
	_say("ROLL RACK %d of %d hooks changed" % [moved, before.size()])
	if before.is_empty() or moved != before.size():
		_fail("ROLL RACK left %d of %d hooks alone" % [before.size() - moved, before.size()])
	if _stand_spec(bench, "Stands/MainStand") != a or _stand_spec(bench, "Stands/RivalStand") != b:
		_fail("ROLL RACK moved a stand")
	if _hand(bench) != hand:
		_fail("ROLL RACK reached into your hands")
	_check_cards(bench, hand, "after ROLL RACK")


# --- the console --------------------------------------------------------------


func _check_console(bench: Node) -> void:
	var b: Object = _stand_spec(bench, "Stands/RivalStand")
	var hand: Object = _hand(bench)
	var roll: DiegeticControl = bench.get_node_or_null(^"Console/Panel/Roll")
	var before_a: Object = _stand_spec(bench, "Stands/MainStand")
	if roll == null or not roll.interact():
		_fail("ROLL refused a walk-up press")
		return
	for _i: int in SWAP_FRAMES:
		await physics_frame
	var after_a: Object = _stand_spec(bench, "Stands/MainStand")
	_say("ROLL      A %-26s (was %s)" % [_name_of(after_a), _name_of(before_a)])
	if after_a == before_a:
		_fail("ROLL did not change stand A")
	if _stand_spec(bench, "Stands/RivalStand") != b:
		_fail("ROLL moved stand B")
	if _hand(bench) != hand:
		_fail("ROLL reached into your hands — the grab stations are the only way to arm")

	var compare: DiegeticControl = bench.get_node_or_null(^"Console/Panel/Compare")
	if compare == null or not compare.interact():
		_fail("COMPARE refused a walk-up press")
		return
	await physics_frame
	if _stand_spec(bench, "Stands/RivalStand") != after_a:
		_fail("COMPARE did not copy stand A onto stand B")
	else:
		_say("COMPARE   B now reads %s" % _name_of(after_a))

	var peg: DiegeticControl = bench.get_node_or_null(^"Rack/Pegs/Peg0")
	var hook: Object = null if peg == null else peg.call(&"spec")
	if peg == null or not peg.interact():
		_fail("the first peg refused a walk-up press")
		return
	await physics_frame
	if _stand_spec(bench, "Stands/MainStand") != hook:
		_fail("a peg press did not put that hook's weapon on stand A")
	elif peg.call(&"spec") != after_a:
		_fail("a peg press did not hang stand A's weapon back on the hook")
	else:
		_say("PEG 0     traded %s onto stand A" % _name_of(hook))
	if _hand(bench) != hand:
		_fail("a peg press reached into your hands")


# --- the photographs ----------------------------------------------------------


## Stand where a player stands and photograph what he sees. A gate that only counts
## objects cannot answer "is the button legible", and this pass exists because of a
## report about what the bay LOOKED like.
func _shoot_the_evidence(bench: Node) -> void:
	if DisplayServer.get_name() == "headless":
		_say("")
		_say("shots     NOT MEASURED - re-run without --headless to photograph the stations.")
		return
	DirAccess.make_dir_recursive_absolute(SHOT_DIR)
	var player: Node3D = bench.get_node_or_null(^"Player") as Node3D
	if player == null:
		_fail("no Player to stand anywhere")
		return
	# The whole room from the spawn point, then each station walked up to, then one grab
	# photographed TWICE: six frames after the press, while the cap is down and the lamp
	# is lit, and again once the holster has finished the swap, so the weapon that came
	# to hand and the weapon left behind on the stand are in the same frame.
	await _stand_and_shoot(player, Vector3(0.0, 0.0, 1.9), Vector3(0.0, 1.45, -2.4), "room")
	await _stand_and_shoot(
		player, Vector3(-1.55, 0.0, -0.45), Vector3(-1.55, 1.30, -2.01), "grab_a"
	)
	await _stand_and_shoot(player, Vector3(-4.0, 0.0, -3.4), Vector3(-5.54, 1.45, -4.02), "rack")
	await _stand_and_shoot(player, Vector3(3.3, 0.0, 1.2), Vector3(3.30, 1.60, -0.62), "sign")
	await _stand_and_shoot(player, Vector3(1.55, 0.0, -0.45), Vector3(1.55, 1.30, -2.01), "grab_b")
	var control: DiegeticControl = bench.get_node_or_null(^"Stands/RivalStand/Column/Station/Grab")
	if control == null:
		return
	control.interact()
	for _i: int in 6:
		await process_frame
	await _shot("grab_b_pressed")
	for _i: int in SWAP_FRAMES:
		await physics_frame
	await _shot("grab_b_taken")


func _stand_and_shoot(player: Node3D, at: Vector3, look: Vector3, tag: String) -> void:
	player.call(&"teleport", at, 0.0)
	for _i: int in SETTLE_FRAMES:
		await physics_frame
	_aim(player, look)
	for _i: int in 8:
		await process_frame
	await _shot(tag)


func _shot(tag: String) -> void:
	await process_frame
	var image: Image = root.get_texture().get_image()
	var file: String = "%s/%s.png" % [SHOT_DIR, tag]
	if image == null or image.save_png(file) != OK:
		_fail("could not write %s" % file)
		return
	_shots += 1
	_say("shot      %s" % file)


# --- reading the bay ----------------------------------------------------------


func _stand_spec(bench: Node, path: String) -> Object:
	var stand: Node = bench.get_node_or_null(NodePath(path))
	return null if stand == null else stand.call(&"spec")


func _hand(bench: Node) -> Object:
	return bench.call(&"hand_spec")


func _rack(bench: Node) -> Array:
	var out: Array = []
	var pegs: Node = bench.get_node_or_null(^"Rack/Pegs")
	if pegs == null:
		return out
	for peg: Node in pegs.get_children():
		out.append(peg.call(&"spec"))
	return out


func _card_title(bench: Node, path: String) -> String:
	var canvas: Node = bench.get_node_or_null(NodePath(path + "/Screen/Display/Canvas"))
	return "" if canvas == null else String(canvas.get(&"_title"))


func _card_lines(bench: Node, path: String) -> PackedStringArray:
	var canvas: Node = bench.get_node_or_null(NodePath(path + "/Screen/Display/Canvas"))
	if canvas == null:
		return PackedStringArray()
	return canvas.get(&"_lines") as PackedStringArray


func _name_of(spec: Object) -> String:
	return "-" if spec == null else String(spec.get(&"weapon_name"))


## Order-independent identity of a set of weapons. Instance ids rather than names,
## because two rolls can legitimately produce the same name and a name comparison
## would call that "nothing was lost" when something was.
func _multiset(specs: Array) -> Array:
	var ids: Array[int] = []
	for spec: Object in specs:
		ids.append(0 if spec == null else int(spec.get_instance_id()))
	ids.sort()
	return ids


func _aim(player: Node3D, target: Vector3) -> void:
	var eye: Node3D = player.get_node_or_null(^"Eye") as Node3D
	var from: Vector3 = player.global_position + Vector3(0.0, 1.66, 0.0)
	if eye != null:
		from = eye.global_position
	var to: Vector3 = target - from
	if to.length_squared() < 1.0e-6:
		return
	player.set(&"yaw", atan2(-to.x, -to.z))
	player.set(&"pitch", atan2(to.y, Vector2(to.x, to.z).length()))


## What the crosshair is on, cast against WORLD and PROP together so the console, the
## stands and the walls can all block. A PROP-only ray would report a button behind a
## cabinet as reachable.
func _under_crosshair(eye: Camera3D) -> Object:
	var query := PhysicsRayQueryParameters3D.new()
	query.from = eye.global_position
	query.to = eye.global_position - eye.global_basis.z * REACH
	query.collision_mask = GameLayers.WORLD | GameLayers.PROP
	query.collide_with_areas = false
	var hit: Dictionary = eye.get_world_3d().direct_space_state.intersect_ray(query)
	return null if hit.is_empty() else hit["collider"]


# --- report -------------------------------------------------------------------


func _summarise() -> void:
	_say("")
	_say("shots written          %d" % _shots)
	_say("RESULT: %s" % ("FAIL" if _failed else "PASS"))


func _say(line: String) -> void:
	print(line)
	_lines.append(line)


func _fail(line: String) -> void:
	_failed = true
	_say("FAIL  %s" % line)


func _finish() -> void:
	var file: FileAccess = FileAccess.open(REPORT_PATH, FileAccess.WRITE)
	if file != null:
		file.store_string("\n".join(_lines) + "\n")
		file.close()
	quit(1 if _failed else 0)
