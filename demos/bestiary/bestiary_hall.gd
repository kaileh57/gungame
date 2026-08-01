class_name BestiaryHall
extends Node3D
## The enemy rack, as a place you walk through.
##
## Twelve plinths in three bays — scav, machine, mutant — under a lamp gantry,
## with a control desk at each end of the walkway so you never have to walk back
## to change what the room is doing. Every creature on the rack runs the same
## clip at the same pace, because the entire value of a rack is comparison: a
## stilt and a skitter walking side by side tell you more in two seconds than
## either does alone in a minute.
##
## Nothing on screen. The desk is the UI: a dial for the clip, a slider for the
## pace, two levers, three buttons and a tube that reads out whichever species
## the inspection lamp is on. Look at a control and a bead lights on it; press
## `fire` or `interact` and it actuates. That is the same `DiegeticControl.shoot`
## path the main menu uses, so a control behaves identically whether a bullet or
## a keypress reaches it.
##
## Everything in the room is baked by `res://tools/build_bestiary.gd`. This file
## builds nothing; it wires, listens and reads out.

## Control ids the two desks carry. Both desks carry all of them and are kept in
## lockstep, so a change made at one end is visible at the other.
const ID_CLIP: StringName = &"clip"
const ID_PACE: StringName = &"pace"
const ID_TURN: StringName = &"turn"
const ID_TRACK: StringName = &"track"
const ID_PREV: StringName = &"prev"
const ID_NEXT: StringName = &"next"
const ID_TAKE: StringName = &"take"

## Dial detent labels, in `BeastClips.CLIPS` order.
const CLIP_LABELS: PackedStringArray = ["IDLE", "WALK", "RUN", "AIM", "ATTACK", "STAGGER", "DEATH"]
## Species class id -> what the bay sign calls it.
const CLASS_LABELS: Dictionary = {&"scav": "SCAV", &"machine": "MACHINE", &"mutant": "MUTANT"}

@export_group("Inspection")
## Seconds for the inspection lamp to cross from one plinth to the next. It moves
## rather than cuts so you can see which way the focus went.
@export_range(0.05, 2.0, 0.01) var focus_travel: float = 0.34
## Height above the plinth top the lamp aims at, as a fraction of body height.
@export_range(0.0, 1.0, 0.01) var focus_aim_height: float = 0.58
## How far the inspection lamp dips while it travels, as a fraction of its
## energy. Without it the beam smears a bright stripe across everything between
## the old plinth and the new one.
@export_range(0.0, 1.0, 0.01) var focus_travel_dip: float = 0.55

## Playback rate the desks start at. The sliders are baked at their default value
## and pushed to this on load, so the room is never showing a pace the knob does
## not agree with.
@export_range(0.15, 2.0, 0.05) var default_pace: float = 1.0

@export_group("Turntables")
## Plinth rotation in revolutions per minute while the TURN lever is thrown. Slow
## enough to read a silhouette, fast enough to see the far side before you lose
## interest.
@export_range(0.5, 12.0, 0.1) var turntable_rpm: float = 2.6

@export_group("Selector bead")
## How far the desk controls answer a look, in metres.
@export_range(0.5, 6.0, 0.05) var reach: float = 2.6
## Metres the bead floats off the face of whatever it is marking.
@export_range(0.0, 0.2, 0.005) var bead_standoff: float = 0.055
## Seconds for the bead to travel between controls.
@export_range(0.01, 0.5, 0.005) var bead_travel: float = 0.055

@export_group("Tracking")
## Height on the player the creatures look at when the TRACK lever is thrown, as
## a fraction of the camera height. Just under 1 keeps them off your hairline.
@export_range(0.5, 1.2, 0.01) var track_eye_fraction: float = 0.94

var _ids: Array[StringName] = []
var _bodies: Array[ExhibitBody] = []
var _turntables: Array[Node3D] = []
var _placards: Array[DiegeticReadout] = []
var _plinths: PackedVector3Array = PackedVector3Array()
var _cards: Array[DiegeticReadout] = []
## Control id -> every control carrying it, across both desks.
var _banks: Dictionary = {}

var _focus: int = 0
var _focus_from: Vector3 = Vector3.ZERO
var _focus_to: Vector3 = Vector3.ZERO
var _focus_t: float = 1.0
var _spin: float = 0.0
var _turning: bool = false
var _tracking: bool = false
var _take: int = 0
var _bead_target: Vector3 = Vector3.ZERO
## The inspection lamp's baked energy, so the travel dip has something to return
## to after a settings preset has changed it.
var _focus_energy: float = 0.0
## The desk. It latches the press in `_unhandled_input` and casts that press's own
## ray in `_physics_process`; the bead simply rides `hovered()`. The hall used to
## cache what the eye was on in `_process` and read the cache back on the click,
## which is a frame late by construction — look at a knob and click in the same
## motion and the click resolved against the empty air you were looking at before.
var _hands: DiegeticInteractor = null

@onready var _exhibits: Node3D = $Exhibits
@onready var _consoles: Node3D = $Consoles
@onready var _focus_rig: Node3D = $FocusRig
@onready var _focus_light: SpotLight3D = $FocusRig/Light
@onready var _bead: MeshInstance3D = $Bead


func _ready() -> void:
	GameSettings.register_viewport(get_viewport())
	_focus_energy = _focus_light.light_energy
	_build_hands()
	_collect_exhibits()
	_collect_controls()
	_apply_initial_state()
	_write_placards()
	_apply_clip(BeastClips.IDLE)
	_focus_on(0, true)
	_bead.visible = false


func _process(delta: float) -> void:
	var eye: Camera3D = get_viewport().get_camera_3d()
	_spin_turntables(delta)
	_track(eye)
	_advance_focus(delta)
	_update_bead(delta)


## The desk's hands. World geometry is in the mask so a knob you are looking at
## through a wall is not reachable — a world hit simply resolves to no control.
## Both buttons do the same thing here, and both give the centred nudge a plate
## wants rather than a bullet's placed hit, which is what the hall has always done.
func _build_hands() -> void:
	_hands = DiegeticInteractor.new()
	_hands.name = "Hands"
	_hands.collision_mask = GameLayers.WORLD | GameLayers.PROP
	_hands.interact_reach = reach
	_hands.fire_reach = reach
	_hands.fire_presses_at_point = false
	add_child(_hands)
	CombatReticle.mount(self).watch(_hands)


## Which control the player is looking at, or `&""`. Public because the F3
## overlay and the headless scene check both want it without reaching into the
## ray query.
func hovered_id() -> StringName:
	return _hands.hovered_id()


## The species the inspection lamp is on.
func focused_id() -> StringName:
	return &"" if _ids.is_empty() else _ids[_focus]


# --- wiring -----------------------------------------------------------------


func _collect_exhibits() -> void:
	for id: StringName in SpeciesTable.IDS:
		var node: Node3D = _exhibits.get_node_or_null(NodePath("Exhibit_%s" % id)) as Node3D
		if node == null:
			push_error("BestiaryHall: no plinth for species '%s'. Re-run build_bestiary." % id)
			continue
		var turntable := node.get_node_or_null(^"Turntable") as Node3D
		var body := node.get_node_or_null(^"Turntable/Body") as ExhibitBody
		var placard := node.get_node_or_null(^"Placard") as DiegeticReadout
		if turntable == null or body == null or placard == null:
			push_error("BestiaryHall: plinth '%s' is missing a child. Re-run build_bestiary." % id)
			continue
		_ids.append(id)
		_bodies.append(body)
		_turntables.append(turntable)
		_placards.append(placard)
		_plinths.append(node.global_position)


func _collect_controls() -> void:
	for console: Node in _consoles.get_children():
		var card := console.get_node_or_null(^"Card") as DiegeticReadout
		if card != null:
			_cards.append(card)
		for node: Node in console.get_children():
			var control := node as DiegeticControl
			if control == null:
				continue
			var bank: Array = _banks.get(control.control_id, [])
			bank.append(control)
			_banks[control.control_id] = bank
	_bind_dial(ID_CLIP, _on_clip_selected)
	_bind_slider(ID_PACE, _on_pace_changed)
	_bind_lever(ID_TURN, _on_turn_toggled)
	_bind_lever(ID_TRACK, _on_track_toggled)
	_bind_button(ID_PREV, _on_prev)
	_bind_button(ID_NEXT, _on_next)
	_bind_button(ID_TAKE, _on_take)


func _bind_dial(id: StringName, handler: Callable) -> void:
	for control: DiegeticControl in _bank(id):
		var dial := control as DiegeticDial
		if dial == null:
			push_error("BestiaryHall: control '%s' is not a dial." % id)
			continue
		dial.option_selected.connect(handler.bind(dial))


func _bind_slider(id: StringName, handler: Callable) -> void:
	for control: DiegeticControl in _bank(id):
		control.value_changed.connect(handler.bind(control))


func _bind_lever(id: StringName, handler: Callable) -> void:
	for control: DiegeticControl in _bank(id):
		var lever := control as DiegeticLever
		if lever == null:
			push_error("BestiaryHall: control '%s' is not a lever." % id)
			continue
		lever.toggled.connect(handler.bind(lever))


func _bind_button(id: StringName, handler: Callable) -> void:
	for control: DiegeticControl in _bank(id):
		control.pressed.connect(handler)


func _bank(id: StringName) -> Array:
	var bank: Array = _banks.get(id, [])
	if bank.is_empty():
		push_error("BestiaryHall: no control carries id '%s'." % id)
	return bank


## Push the room's opening state onto both desks without firing a handler. The
## controls ship at their scene defaults; this is the one place that decides what
## the rack is doing when you walk in.
func _apply_initial_state() -> void:
	_set_bank(ID_CLIP, 0.0)
	_set_bank(ID_PACE, default_pace)
	_set_bank(ID_TURN, 0.0)
	_set_bank(ID_TRACK, 0.0)
	for body: ExhibitBody in _bodies:
		body.pace = default_pace


func _set_bank(id: StringName, value: float) -> void:
	for control: DiegeticControl in _bank(id):
		control.set_value(value, false)


## Copy a control's value onto its twin at the far desk without firing that
## twin's handler, which would otherwise bounce the change back.
func _mirror(id: StringName, value: float, source: DiegeticControl) -> void:
	for control: DiegeticControl in _bank(id):
		if control == source:
			continue
		control.set_value(value, false)
		control.flash()


# --- handlers ---------------------------------------------------------------


func _on_clip_selected(index: int, _text: String, source: DiegeticDial) -> void:
	var clip: StringName = BeastClips.CLIPS[clampi(index, 0, BeastClips.CLIPS.size() - 1)]
	_apply_clip(clip)
	_mirror(ID_CLIP, float(index), source)


func _on_pace_changed(value: float, source: DiegeticControl) -> void:
	for body: ExhibitBody in _bodies:
		body.pace = value
	_mirror(ID_PACE, value, source)


func _on_turn_toggled(on: bool, source: DiegeticLever) -> void:
	_turning = on
	_mirror(ID_TURN, 1.0 if on else 0.0, source)


func _on_track_toggled(on: bool, source: DiegeticLever) -> void:
	_tracking = on
	if not on:
		for body: ExhibitBody in _bodies:
			body.clear_aim()
	_mirror(ID_TRACK, 1.0 if on else 0.0, source)


func _on_prev() -> void:
	_focus_on(_step(-1), false)


func _on_next() -> void:
	_focus_on(_step(1), false)


func _on_take() -> void:
	_take = (_take + 1) % 5
	for body: ExhibitBody in _bodies:
		body.set_take(_take)
	_write_cards()


func _step(dir: int) -> int:
	var n: int = _bodies.size()
	return 0 if n == 0 else posmod(_focus + dir, n)


# --- room state -------------------------------------------------------------


func _apply_clip(clip: StringName) -> void:
	for body: ExhibitBody in _bodies:
		body.show_clip(clip)
	_write_cards()


func _focus_on(index: int, instant: bool) -> void:
	if _plinths.is_empty():
		return
	_focus = clampi(index, 0, _plinths.size() - 1)
	var stats: EnemyStats = _bodies[_focus].species_stats
	var height: float = 1.6 if stats == null else stats.height
	_focus_to = _plinths[_focus] + Vector3(0.0, height * focus_aim_height, 0.0)
	_focus_from = _focus_rig.global_position if not instant else _focus_to
	_focus_t = 0.0 if not instant else 1.0
	if instant:
		_focus_rig.global_position = _focus_to
	_write_cards()


func _advance_focus(delta: float) -> void:
	if _focus_t >= 1.0:
		return
	_focus_t = minf(1.0, _focus_t + delta / maxf(focus_travel, 0.01))
	var k: float = _focus_t * _focus_t * (3.0 - 2.0 * _focus_t)
	_focus_rig.global_position = _focus_from.lerp(_focus_to, k)
	_focus_light.light_energy = _focus_energy * (1.0 - focus_travel_dip * sin(PI * _focus_t))


func _spin_turntables(delta: float) -> void:
	if not _turning:
		return
	_spin = fposmod(_spin + delta * turntable_rpm * TAU / 60.0, TAU)
	for turntable: Node3D in _turntables:
		turntable.rotation.y = _spin


## Point every rig at the player's head. `aim_at` is a rig-space write, not an IK
## solve, so twelve of these is a dozen vector subtractions.
func _track(eye: Camera3D) -> void:
	if not _tracking or eye == null:
		return
	var at: Vector3 = eye.global_position
	at.y *= track_eye_fraction
	for body: ExhibitBody in _bodies:
		body.aim_at(at)


func _update_bead(delta: float) -> void:
	var control: DiegeticControl = _hands.hovered()
	if control == null:
		_bead.visible = false
		return
	var was_hidden: bool = not _bead.visible
	_bead_target = control.global_position + control.global_basis.z.normalized() * bead_standoff
	if was_hidden:
		_bead.global_position = _bead_target
	_bead.visible = true
	var k: float = clampf(delta / maxf(bead_travel, 0.005), 0.0, 1.0)
	_bead.global_position = _bead.global_position.lerp(_bead_target, k)


# --- readouts ---------------------------------------------------------------


## The plinth placards never change, so they are written once. Each is a painted
## steel stencil rather than a lit tube: twelve glowing screens down a hall would
## light the room more than the lamps do.
func _write_placards() -> void:
	for i: int in _placards.size():
		var stats: EnemyStats = _bodies[i].species_stats
		if stats == null:
			continue
		var id: StringName = _ids[i]
		var entry: Dictionary = SpeciesTable.CATALOGUE[id]
		var placard: DiegeticReadout = _placards[i]
		placard.accent = stats.tier_color
		placard.set_title("%02d  %s" % [i + 1, stats.display_name.to_upper()])
		placard.set_lines(
			PackedStringArray(
				[
					(
						"%s . %s . %s"
						% [
							String(entry["class"]),
							String(entry["role"]),
							stats.tier_name.to_lower()
						]
					),
					"%.2f m . %.0f kg . %d parts" % [stats.height, stats.mass, int(entry["parts"])],
					(
						"%.0f hp . %.0f%% armour . poise %.0f"
						% [stats.health, stats.armour, stats.stagger]
					)
				]
			)
		)
		placard.set_bars(
			PackedStringArray(["THREAT", "RUN"]),
			PackedFloat32Array([stats.threat / 99.0, clampf(stats.run_speed / 6.0, 0.0, 1.0)]),
			PackedColorArray([stats.tier_color, UiStyle.COOL])
		)


## The desk tubes carry the focused species and what the room is doing to it.
func _write_cards() -> void:
	if _cards.is_empty() or _bodies.is_empty():
		return
	var stats: EnemyStats = _bodies[_focus].species_stats
	if stats == null:
		return
	var entry: Dictionary = SpeciesTable.CATALOGUE[_ids[_focus]]
	var clip: StringName = _bodies[_focus].shown_clip()
	var lines := PackedStringArray(
		[
			"%s . %s" % [String(entry["class"]).to_upper(), String(entry["role"])],
			"%.0f hp . %.0f%% armour . %.0f kg" % [stats.health, stats.armour, stats.mass],
			"%.2f / %.2f m/s . %.1f m reach" % [stats.speed, stats.run_speed, stats.reach],
			(
				"%.2f x %.2f x %.2f m . %d bones"
				% [stats.width, stats.height, stats.depth, int(entry["bones"])]
			),
			"clip %s . take %d" % [String(clip).to_upper(), _take + 1]
		]
	)
	var bars := PackedStringArray(["THREAT", "HEALTH", "ARMOUR", "RUN"])
	var values := PackedFloat32Array(
		[
			clampf(stats.threat / 99.0, 0.0, 1.0),
			clampf(EnemyStats.THREAT_HP_K * BeastMath.log10(1.0 + stats.health) / 99.0, 0.0, 1.0),
			clampf(stats.armour / EnemyStats.ARMOUR_CAP, 0.0, 1.0),
			clampf(stats.run_speed / 6.0, 0.0, 1.0)
		]
	)
	var colors := PackedColorArray([stats.tier_color, UiStyle.GOOD, UiStyle.COOL, UiStyle.GOLD])
	for card: DiegeticReadout in _cards:
		card.accent = stats.tier_color
		card.set_title(
			(
				"%02d  %s  .  %s"
				% [_focus + 1, stats.display_name.to_upper(), stats.tier_name.to_upper()]
			)
		)
		card.set_lines(lines)
		card.set_bars(bars, values, colors)
