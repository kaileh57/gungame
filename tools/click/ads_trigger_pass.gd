extends RefCounted
## CLICKS PER ROUND, with the sights up. The ADS half of `verify_click_input.gd`.
##
## The user report this exists to settle is "some guns when I ADS only shoot on the
## third click, sometimes even more". `verify_click_input`'s existing trigger pass
## fires one sub-frame tap, waits as long as the gun needs, and asks whether the tap
## ever became a round — so it can only ever find a click the INPUT path lost. It
## cannot see a click the MECHANISM ate, because it never sends a second one until
## the first has been paid.
##
## This asks the other question: with the gun ready and the player clicking, how
## many clicks does a round cost. Four numbers per weapon, each taken twice —
## shouldered and at the hip — so "when I ADS" is answered with data rather than
## with an argument:
##
##   `cold`   clicks spent on the first round from a gun that has been idle. Must
##            be 1 for every weapon.
##   `ready`  clicks per round when every tap is made only after the weapon itself
##            says it is ready — `is_ready_to_fire()`, no cooldown left, nothing
##            cycling. This is the CONTROL: it isolates the input path, so anything
##            `rated` loses on top of it belongs to the mechanism and not to the
##            event queue.
##   `rated`  clicks per round tapping at the weapon's own `60 / rpm`. This is the
##            fastest a person could reasonably expect the gun to answer, and it
##            must be 1.
##   `early`  clicks per round when every tap lands `EARLY_LEAD` seconds BEFORE the
##            weapon is willing, timed from the previous round so the lead cannot
##            drift. This is the player-facing number and it is the one the report
##            is about: nobody clicks on the beat, and a mechanism that only fires
##            on the exact tick it is ready throws away every click that is early.
##
## Two entry points, because the two things worth knowing need different rigs:
##   `sweep()`   a large weapon sample driven through a real `Weapon` and a real
##               `TriggerLatch` at the physics rate, with no scene. Cheap, so the
##               sample can be hundreds and can enumerate all eight mechanisms
##               rather than hoping a random roll surfaces a pump.
##   `in_demo()` the real input path — `Input.parse_input_event`, a real right
##               mouse button held down, `PlayerController.ads` measured on its way
##               to 1 — in a demo that is really running. Smaller sample, no
##               simulation anywhere in it.
##
## BURST IS EXEMPT FROM THE `rated` GATE and nothing else is. A burst deliberately
## waits `FireControl.burst_gap_scale` intervals after its last round, so tapping it
## once per interval cannot fire every tap and should not.
##
## THE HOLSTER IS REACHED BY `call` RATHER THAN BY TYPE, and that is trap 21 rather
## than laziness: `WeaponHolster` names the `GunFactory` AUTOLOAD, and a script handed
## to `--script` is compiled before the autoloads exist. Typing a variable as
## `WeaponHolster` here therefore fails to compile that script, which silently strips
## the holster off every demo this pass then loads and reports as "no Holster".

const MANIFEST_PATH: String = "res://data/guns/part_library.tres"
const TUNING_PATH: String = "res://data/guns/gun_tuning.tres"

## Physics step the sweep drives. The shipping game's tick.
const STEP: float = 1.0 / 60.0
## Rolled seeds in the sweep, on top of the eight enumerated mechanisms.
const SWEEP_SEEDS: int = 200
## Seconds a swept weapon sits idle before the cold tap.
const IDLE_SECONDS: float = 2.0
## Ceiling on how long a wait-until-ready will spin. Longer than the slowest thing
## a weapon does — a 15 rpm break-action reloading is about 8 s — so a weapon that
## trips this is stuck rather than slow, and the pass says so instead of silently
## reporting the stall as a lost click.
const IDLE_LIMIT_SECONDS: float = 24.0
## Taps in the `ready` and `rated` strings.
const STRING_TAPS: int = 10
## Taps a cold pass will spend before it gives up and reports the gun as dead.
const MAX_TAPS: int = 12
## Click rate for the cold pass. A person clicking, not a machine.
const CLICK_HZ: float = 5.0
## Seconds before the weapon is willing that the `early` pass puts its taps. A
## human aiming for a beat lands inside about a tenth of a second of it, and half
## of those attempts are early. Kept under `FireControl.pull_buffer` on purpose:
## the promise being measured is "a click this far early still counts".
const EARLY_LEAD: float = 0.12
## Extra time past the lead that a tap is given to become a round.
const EARLY_MARGIN: float = 0.05
## Clicks per round past which a mechanism is reported as eating them.
const CLICKS_BAR: float = 1.05

## Weapon classes rolled into the primary for the in-demo pass. Between them they
## reach every mechanism; a plain weighted roll needs hundreds of seeds to surface
## a pump and never guarantees one at all.
const DEMO_CLASSES: PackedStringArray = [
	"", "Sniper", "Shotgun", "Slug gun", "Assault rifle", "Sidearm", "Hand cannon"
]
## Seeds each class is rolled at.
const DEMO_SEEDS: PackedInt32Array = [0x5CA71E, 0x1D0C]
## Taps in the in-demo strings. Shorter than `STRING_TAPS` because every frame here
## is a real drawn frame of a real demo.
const DEMO_TAPS: int = 6
## Drawn frames a swap, an aim blend, a round or an idle wait is given.
const SWAP_FRAMES: int = 900
const AIM_FRAMES: int = 400
## 24 s at the 200 fps cap, matching `IDLE_LIMIT_SECONDS`.
const IDLE_FRAMES: int = 4800
## Frame cap the in-demo pass runs at, and therefore the frames-per-second its tap
## pacing is computed against.
const FRAME_CAP: int = 200
## ADS blend counted as fully shouldered, and as fully down.
const ADS_UP: float = 0.98
const ADS_DOWN: float = 0.02

var _tree: SceneTree = null
var _say: Callable = Callable()
var _rows: Array[Dictionary] = []
var _failures: PackedStringArray = PackedStringArray()
var _fired: int = 0
var _jams: int = 0
var _world: Node3D = null


## Every mechanism plus `SWEEP_SEEDS` rolled weapons, driven through a real
## `Weapon` and a real `TriggerLatch`. Returns the rows it measured.
func sweep(tree: SceneTree, say: Callable) -> Array[Dictionary]:
	_tree = tree
	_say = say
	_rows = []
	var pools: Dictionary = _pools()
	if pools.is_empty():
		_failures.append("ads sweep: %s is missing or empty" % MANIFEST_PATH)
		return _rows
	var tuning: GunTuning = _tuning()
	_world = Node3D.new()
	_world.name = "AdsClickSweep"
	tree.root.add_child(_world)
	await tree.physics_frame
	var specs: Array[GunSpec] = _mechanism_specs(pools, tuning)
	var enumerated: int = specs.size()
	specs.append_array(_rolled_specs(pools, tuning))
	for spec: GunSpec in specs:
		_rows.append(_measure_spec(spec))
	tree.root.remove_child(_world)
	_world.queue_free()
	_world = null
	_report("SWEEP  %d mechanisms + %d rolled" % [enumerated, specs.size() - enumerated])
	return _rows


## The same three numbers through the real input path, in a demo that is running.
## `rig_path` is the node that owns the trigger, `scene` is already loaded by the
## caller. Returns the rows it measured.
func in_demo(tree: SceneTree, say: Callable, demo: Node, rig_path: String) -> Array[Dictionary]:
	_tree = tree
	_say = say
	_rows = []
	var player: Node3D = demo.get_node_or_null(^"Player") as Node3D
	var holster: Node = demo.get_node_or_null(^"Player/Eye/Holster")
	var weapon: Weapon = _weapon_of(demo, rig_path)
	if player == null or holster == null or weapon == null:
		_failures.append("ads in-demo: no Player, Holster or Weapon on %s" % rig_path)
		return _rows
	weapon.fired.connect(_on_fired)
	weapon.jam.jammed.connect(_on_jammed)
	for want: String in DEMO_CLASSES:
		for seed_value: int in DEMO_SEEDS:
			# Slot 0 is `WeaponHolster.PRIMARY_SLOT`, spelled out because naming the
			# class here would drag the `GunFactory` autoload into this compile.
			var spec := holster.call(&"roll_into", 0, seed_value, want) as GunSpec
			if spec == null:
				continue
			if not await _wait_swap(holster):
				_failures.append("ads in-demo: the swap to %s never finished" % spec.weapon_name)
				continue
			_rows.append(await _measure_live(weapon, player, spec))
	weapon.fired.disconnect(_on_fired)
	weapon.jam.jammed.disconnect(_on_jammed)
	await _hold_aim(player, false)
	return _rows


## Everything the two passes found that is out of bounds.
func failures() -> PackedStringArray:
	return _failures


## Per-mechanism means over `rows`, printed. Safe to call with an empty array.
func summarise(rows: Array[Dictionary], title: String) -> void:
	if rows.is_empty():
		return
	var by_action: Dictionary = {}
	for row: Dictionary in rows:
		var id: String = String(row["action"])
		if not by_action.has(id):
			by_action[id] = []
		(by_action[id] as Array).append(row)
	_report("")
	_report(title)
	_report(
		(
			"%-8s %4s  %-13s %-13s %-13s %-13s"
			% ["action", "n", "cold ads/hip", "ready ads/hip", "rated ads/hip", "early ads/hip"]
		)
	)
	for id: String in by_action:
		var group: Array = by_action[id]
		_report(
			(
				"%-8s %4d  %5.2f /%5.2f  %5.2f /%5.2f  %5.2f /%5.2f  %5.2f /%5.2f"
				% [
					id,
					group.size(),
					_mean(group, "cold_ads"),
					_mean(group, "cold_hip"),
					_mean(group, "ready_ads"),
					_mean(group, "ready_hip"),
					_mean(group, "rated_ads"),
					_mean(group, "rated_hip"),
					_mean(group, "early_ads"),
					_mean(group, "early_hip"),
				]
			)
		)
	_grade(by_action, title)


# --- the sweep ----------------------------------------------------------------


func _measure_spec(spec: GunSpec) -> Dictionary:
	return {
		"weapon": spec.weapon_name,
		"action": String(GunTables.action_for(spec.fire_mode)),
		"rpm": spec.rpm,
		"cold_ads": _sweep_cold(spec, 1.0),
		"cold_hip": _sweep_cold(spec, 0.0),
		"ready_ads": _sweep_string(spec, 1.0, true),
		"ready_hip": _sweep_string(spec, 0.0, true),
		"rated_ads": _sweep_string(spec, 1.0, false),
		"rated_hip": _sweep_string(spec, 0.0, false),
		"early_ads": _sweep_early(spec, 1.0),
		"early_hip": _sweep_early(spec, 0.0),
	}


## Clicks spent on the first round from a gun that has been idle for two seconds.
func _sweep_cold(spec: GunSpec, ads: float) -> float:
	var rig: Dictionary = _sweep_rig(spec, ads)
	_sweep_ticks(rig, int(IDLE_SECONDS / STEP))
	var gap: int = maxi(1, int((1.0 / CLICK_HZ) / STEP))
	var spent: int = 0
	var got: bool = false
	for tap: int in MAX_TAPS:
		var before: int = _fired
		var jams: int = _jams
		_sweep_tap(rig)
		_sweep_ticks(rig, gap)
		if _fired > before:
			got = true
			spent += 1
			break
		# A pull the action bound up is a gun fact, not an input fact, and the jam
		# rate is `verify_guns_firing`'s to assert. It cost the player a click and it
		# is reported as `eaten`, but it is not charged to the input path.
		if _jams > jams:
			continue
		spent += 1
	_sweep_drop(rig)
	return float(spent) if got else float(MAX_TAPS + 1)


## Clicks per round over a string. `on_ready` waits for the weapon to say it is
## ready before every tap; otherwise taps land once per rated interval.
func _sweep_string(spec: GunSpec, ads: float, on_ready: bool) -> float:
	var rig: Dictionary = _sweep_rig(spec, ads)
	var weapon: Weapon = rig["weapon"]
	var interval: float = weapon.fire_control.interval()
	var gap: int = maxi(2, int(interval / STEP) + 1)
	_sweep_ticks(rig, int(IDLE_SECONDS / STEP))
	var rounds: int = 0
	var taps: int = 0
	for i: int in STRING_TAPS:
		if on_ready:
			_sweep_idle(rig)
		var before: int = _fired
		var jams: int = _jams
		_sweep_tap(rig)
		_sweep_ticks(rig, gap)
		if _fired > before:
			rounds += 1
			taps += 1
		elif _jams == jams:
			taps += 1
	_sweep_drop(rig)
	return float(taps) / maxf(float(rounds), 0.5)


## Clicks per round when every tap lands `EARLY_LEAD` before the weapon is willing.
## The wait is timed from the previous ROUND rather than from a free clock: the
## shots lock to the mechanism's own cadence, so a fixed gap between taps would
## walk the lead out to a full interval over ten of them and measure drift.
func _sweep_early(spec: GunSpec, ads: float) -> float:
	var rig: Dictionary = _sweep_rig(spec, ads)
	var weapon: Weapon = rig["weapon"]
	var interval: float = weapon.fire_control.interval()
	var lead: int = maxi(1, int(EARLY_LEAD / STEP))
	var window: int = lead + maxi(1, int(EARLY_MARGIN / STEP))
	var wait: int = maxi(1, int(interval / STEP) - lead)
	_sweep_idle(rig)
	_sweep_tap(rig)
	_sweep_until_fired(rig, window + wait)
	var rounds: int = 0
	var taps: int = 0
	for i: int in STRING_TAPS:
		_sweep_ticks(rig, wait)
		var before: int = _fired
		var jams: int = _jams
		_sweep_tap(rig)
		_sweep_until_fired(rig, window)
		if _fired > before:
			rounds += 1
			taps += 1
		elif _jams == jams:
			taps += 1
	_sweep_drop(rig)
	return float(taps) / maxf(float(rounds), 0.5)


## Run at most `ticks`, stopping the moment a round leaves. Stopping ON the round
## is what anchors the next wait to the mechanism's cadence.
func _sweep_until_fired(rig: Dictionary, ticks: int) -> void:
	var before: int = _fired
	for i: int in ticks:
		_sweep_ticks(rig, 1)
		if _fired > before:
			return


## Spin the rig until the weapon is genuinely willing: loaded, unjammed, nothing
## cycling, nothing queued and no cooldown left.
func _sweep_idle(rig: Dictionary) -> void:
	var weapon: Weapon = rig["weapon"]
	for i: int in int(IDLE_LIMIT_SECONDS / STEP):
		if _is_quiet(weapon):
			return
		_sweep_ticks(rig, 1)
	_failures.append("ads sweep: %s never went quiet" % weapon.spec().weapon_name)


func _sweep_tap(rig: Dictionary) -> void:
	var latch: TriggerLatch = rig["latch"]
	latch.press()
	latch.release()


## The exact loop `RangeShooter._physics_process` runs, with the magazine topped up
## and jams beaten out — running dry and binding the action are gun facts, and
## counting either here would report them as lost clicks.
func _sweep_ticks(rig: Dictionary, ticks: int) -> void:
	var weapon: Weapon = rig["weapon"]
	var latch: TriggerLatch = rig["latch"]
	for i: int in ticks:
		if weapon.jam.is_jammed():
			weapon.jam.reset()
		_top_up(weapon)
		var want: bool = latch.resolve()
		if want != bool(rig["down"]):
			rig["down"] = want
			if want:
				weapon.trigger_down()
			else:
				weapon.trigger_up()
		weapon.tick(STEP)


func _sweep_rig(spec: GunSpec, ads: float) -> Dictionary:
	var weapon := Weapon.new()
	weapon.self_driven = false
	weapon.visual_effects = false
	weapon.audio_effects = false
	weapon.infinite_reserve = true
	_world.add_child(weapon)
	weapon.setup(spec)
	weapon.set_rig(weapon, weapon, null)
	weapon.position = Vector3(0.0, 1.65, 0.0)
	weapon.set_aim_blend(ads)
	weapon.set_stance(0.0, true, false)
	weapon.fired.connect(_on_fired)
	weapon.jam.jammed.connect(_on_jammed)
	return {"weapon": weapon, "latch": TriggerLatch.new(), "down": false}


func _sweep_drop(rig: Dictionary) -> void:
	var weapon: Weapon = rig["weapon"]
	_world.remove_child(weapon)
	weapon.queue_free()


# --- the demo -----------------------------------------------------------------


func _measure_live(weapon: Weapon, player: Node3D, spec: GunSpec) -> Dictionary:
	var row: Dictionary = {
		"weapon": spec.weapon_name,
		"action": String(GunTables.action_for(spec.fire_mode)),
		"rpm": spec.rpm,
	}
	for shouldered: bool in [true, false]:
		var tag: String = "ads" if shouldered else "hip"
		await _hold_aim(player, shouldered)
		row["cold_" + tag] = await _live_cold(weapon)
		row["ready_" + tag] = await _live_string(weapon, true)
		row["rated_" + tag] = await _live_string(weapon, false)
		row["early_" + tag] = await _live_early(weapon)
	return row


## The `early` pass through the real input path. See `_sweep_early`.
func _live_early(weapon: Weapon) -> float:
	var interval: float = weapon.fire_control.interval()
	var lead: int = maxi(1, int(EARLY_LEAD * float(FRAME_CAP)))
	var window: int = lead + maxi(1, int(EARLY_MARGIN * float(FRAME_CAP)))
	var wait: int = maxi(1, int(interval * float(FRAME_CAP)) - lead)
	await _live_idle(weapon)
	_click()
	await _live_until_fired(weapon, window + wait)
	var rounds: int = 0
	var taps: int = 0
	for i: int in DEMO_TAPS:
		await _live_frames(weapon, wait)
		var before: int = _fired
		var jams: int = _jams
		_click()
		await _live_until_fired(weapon, window)
		if _fired > before:
			rounds += 1
			taps += 1
		elif _jams == jams:
			taps += 1
	return float(taps) / maxf(float(rounds), 0.5)


func _live_until_fired(weapon: Weapon, frames: int) -> void:
	var before: int = _fired
	for i: int in frames:
		await _live_frames(weapon, 1)
		if _fired > before:
			return


func _live_cold(weapon: Weapon) -> float:
	await _live_idle(weapon)
	var gap: int = maxi(1, int(float(FRAME_CAP) / CLICK_HZ))
	var spent: int = 0
	for tap: int in MAX_TAPS:
		var before: int = _fired
		var jams: int = _jams
		_click()
		await _live_frames(weapon, gap)
		if _fired > before:
			return float(spent + 1)
		if _jams == jams:
			spent += 1
	return float(MAX_TAPS + 1)


func _live_string(weapon: Weapon, on_ready: bool) -> float:
	var interval: float = weapon.fire_control.interval()
	var gap: int = maxi(2, int(interval * float(FRAME_CAP)) + 1)
	var rounds: int = 0
	var taps: int = 0
	for i: int in DEMO_TAPS:
		if on_ready:
			await _live_idle(weapon)
		var before: int = _fired
		var jams: int = _jams
		_click()
		await _live_frames(weapon, gap)
		if _fired > before:
			rounds += 1
			taps += 1
		elif _jams == jams:
			taps += 1
	return float(taps) / maxf(float(rounds), 0.5)


## Let the demo draw `frames` frames, keeping the magazine full and the action
## unbound. Both are gun facts; leaving them in would report a reload as a lost
## click, which is the mistake this pass exists to avoid making.
func _live_frames(weapon: Weapon, frames: int) -> void:
	for f: int in frames:
		_top_up(weapon)
		if weapon.jam.is_jammed():
			weapon.jam.reset()
		await _tree.process_frame


## Wait out whatever the gun is doing, topping the magazine up in place and beating
## any jam out, so neither shows up as a lost click.
func _live_idle(weapon: Weapon) -> void:
	for i: int in IDLE_FRAMES:
		_top_up(weapon)
		if weapon.jam.is_jammed():
			weapon.jam.reset()
		if _is_quiet(weapon):
			return
		await _tree.process_frame
	_failures.append("ads in-demo: %s never went quiet" % weapon.spec().weapon_name)


## Press and release the left mouse button inside one drawn frame — the same
## sub-frame tap the rest of this harness sends.
func _click() -> void:
	_button(MOUSE_BUTTON_LEFT, true)
	_button(MOUSE_BUTTON_LEFT, false)


## Hold or release the real right mouse button and wait for `PlayerController.ads`
## to arrive. The blend is damped at `ads_damp_rate`, so it is waited ON rather
## than assumed: a pass that clicked before the sights were up would be measuring
## the hip pose and calling it ADS.
func _hold_aim(player: Node3D, down: bool) -> bool:
	_button(MOUSE_BUTTON_RIGHT, down)
	var want: float = ADS_UP if down else ADS_DOWN
	for i: int in AIM_FRAMES:
		var ads: float = float(player.get(&"ads"))
		if (down and ads >= want) or (not down and ads <= want):
			return true
		await _tree.process_frame
	_failures.append("ads in-demo: the aim blend never reached %.2f" % want)
	return false


func _button(index: int, down: bool) -> void:
	var click := InputEventMouseButton.new()
	click.button_index = index as MouseButton
	click.pressed = down
	click.button_mask = 0
	Input.parse_input_event(click)


func _wait_swap(holster: Node) -> bool:
	for i: int in SWAP_FRAMES:
		if bool(holster.call(&"is_ready_to_fire")) and not bool(holster.call(&"is_swapping")):
			# One more frame so the demo's own `slot_equipped` handler has run and
			# the mechanism has been rebuilt for the gun that is now up.
			await _tree.process_frame
			return true
		await _tree.process_frame
	return false


func _weapon_of(demo: Node, rig_path: String) -> Weapon:
	var rig: Node = demo.get_node_or_null(NodePath(rig_path))
	if rig == null:
		return null
	if rig.has_method(&"weapon"):
		return rig.call(&"weapon") as Weapon
	return rig.get_node_or_null(^"Weapon") as Weapon


# --- shared -------------------------------------------------------------------


func _on_fired(_origin: Vector3, _direction: Vector3, _spec: GunSpec) -> void:
	_fired += 1


func _on_jammed() -> void:
	_jams += 1


## The gun is willing right now: loaded, unjammed, nothing cycling or reloading,
## nothing queued and no cooldown left. A tap made here MUST become a round.
func _is_quiet(weapon: Weapon) -> bool:
	return (
		weapon.is_ready_to_fire()
		and weapon.fire_control.cooldown_remaining() <= 0.0
		and weapon.fire_control.burst_remaining() <= 0
		and not weapon.reload_action.is_busy()
	)


## Refill the magazine in place. Never while a burst or a runaway string is still
## owed rounds: `GunSpec.runaway` re-queues the whole magazine on every discharge,
## so feeding one mid-string makes a gun that fires until the harness gives up.
func _top_up(weapon: Weapon) -> void:
	if weapon.ammo().loaded() > 2 or weapon.fire_control.burst_remaining() > 0:
		return
	weapon.ammo().fill()


## Grade a set of per-action groups. `cold` and `ready` are gated for everything;
## `rated` is gated for everything but a burst, which is meant to pause.
func _grade(by_action: Dictionary, title: String) -> void:
	for id: String in by_action:
		var group: Array = by_action[id]
		var keys: PackedStringArray = ["cold_ads", "cold_hip", "ready_ads", "ready_hip"]
		if id != "burst":
			keys.append_array(
				["rated_ads", "rated_hip", "early_ads", "early_hip"] as PackedStringArray
			)
		for key: String in keys:
			var worst: Array = _worst(group, key)
			if float(worst[0]) > CLICKS_BAR:
				_failures.append(
					(
						"%s: %s %s worst %.2f clicks/round on %s"
						% [title, id, key, float(worst[0]), worst[1]]
					)
				)


func _mean(group: Array, key: String) -> float:
	var total: float = 0.0
	for row: Dictionary in group:
		total += float(row.get(key, 0.0))
	return total / maxf(float(group.size()), 1.0)


## The worst value of `key` in `group`, and the weapon that scored it.
func _worst(group: Array, key: String) -> Array:
	var worst: float = 0.0
	var who: String = "?"
	for row: Dictionary in group:
		if float(row.get(key, 0.0)) > worst:
			worst = float(row[key])
			who = String(row["weapon"])
	return [worst, who]


func _report(line: String) -> void:
	if _say.is_valid():
		_say.call(line)


func _mechanism_specs(pools: Dictionary, tuning: GunTuning) -> Array[GunSpec]:
	var receivers: Array[GunPart] = pools[&"receiver"]
	var barrels: Array[GunPart] = pools[&"barrel"]
	var stocks: Array[GunPart] = pools[&"stock"]
	var grips: Array[GunPart] = pools[&"grip"]
	var by_action: Dictionary = {}
	for r: int in receivers.size():
		for b: int in barrels.size():
			var spec: GunSpec = GunAssembler.assemble(
				receivers[r],
				barrels[b],
				stocks[r % stocks.size()],
				grips[r % grips.size()],
				null,
				1,
				tuning
			)
			if spec == null:
				continue
			var id: String = String(GunTables.action_for(spec.fire_mode))
			if not by_action.has(id):
				by_action[id] = spec
	var out: Array[GunSpec] = []
	for id: StringName in FireControl.ACTION_IDS.keys():
		if by_action.has(String(id)):
			out.append(by_action[String(id)] as GunSpec)
	return out


func _rolled_specs(pools: Dictionary, tuning: GunTuning) -> Array[GunSpec]:
	var out: Array[GunSpec] = []
	var seed_value: int = 1
	while out.size() < SWEEP_SEEDS and seed_value < 40000:
		var spec: GunSpec = GunAssembler.build(seed_value, pools, tuning)
		seed_value += 7
		if spec != null:
			out.append(spec)
	return out


func _pools() -> Dictionary:
	var set_res := ResourceLoader.load(MANIFEST_PATH) as GunPartSet
	if set_res == null or set_res.parts.is_empty():
		return {}
	var pools: Dictionary = {}
	for kind: StringName in [&"barrel", &"stock", &"grip", &"receiver", &"sight"]:
		var bucket: Array[GunPart] = []
		pools[kind] = bucket
	for part: GunPart in set_res.parts:
		var bucket: Array[GunPart] = pools[part.kind]
		bucket.append(part)
	return pools


func _tuning() -> GunTuning:
	if ResourceLoader.exists(TUNING_PATH):
		var res := ResourceLoader.load(TUNING_PATH) as GunTuning
		if res != null:
			return res
	return GunTuning.new()
