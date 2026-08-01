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
##
## MULTIPLAYER. A rack is one exhibit that everybody is stood in front of, so the
## room has ONE state and all four players drive it. Nobody has a privilege here:
## whoever touches a control changes the room under their own hand immediately,
## then tells the host, and the host hands the whole six-number state back to
## everybody. That echo is what keeps four halls identical, and it is also what
## you SEE — the twin at the far desk moves and flashes under somebody else's hand
## exactly as it always did under your own, which is the feedback the two-desk
## design already had and did not need inventing for the network.
##
## In single-player none of it runs. `NetGame.is_networked()` is false, no packet
## is ever sent, and the hall is exactly the room it was.

## The six numbers that ARE the room. Everything a desk can change is one of them
## and the whole vector is what crosses the wire — six floats, on a human pressing
## a button, so there was never a reason to send a delta and re-derive the rest.
enum Field { CLIP = 0, PACE = 1, TURN = 2, TRACK = 3, FOCUS = 4, TAKE = 5 }

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

## How many entries `Field` has, and therefore the length of a state packet.
const FIELD_COUNT: int = 6
## Which bank of controls carries each field. FOCUS has none: it is driven by two
## momentary buttons and its readout is the inspection lamp itself.
const FIELD_BANKS: Dictionary = {
	Field.CLIP: ID_CLIP,
	Field.PACE: ID_PACE,
	Field.TURN: ID_TURN,
	Field.TRACK: ID_TRACK,
	Field.TAKE: ID_TAKE,
}
## The pace slider's baked travel, from `tools/build_bestiary.gd`. Repeated here
## rather than read off the control because a number arriving off the wire is
## clamped before it ever reaches a body, and that has to happen on a machine
## whose desks failed to build just as much as on one whose desks are fine.
const PACE_MIN: float = 0.15
const PACE_MAX: float = 2.00
## Seeded collapses `ExhibitBody` carries, and therefore the modulus of TAKE.
const TAKE_COUNT: int = 5
## How often a client that has walked in re-asks the host what the room is doing,
## and how many times before it stops asking. This only ever runs in the second
## after a scene change: the host and its clients swap scenes a round trip apart,
## so the very first request can land before the host's own hall exists.
const RESYNC_SECONDS: float = 0.5
const RESYNC_TRIES: int = 12
## Fastest a peer's presses are believed, in milliseconds. It is `DiegeticControl`'s
## own `press_cooldown` — already the fastest anybody clicks — so this never refuses
## a real press, and a client that has come loose cannot make the host broadcast the
## room faster than a hand could turn it.
const PRESS_FLOOR_MS: int = 40

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
## The room in the shape the wire carries it, indexed by `Field`. The single truth
## on the host; a copy the host keeps corrected everywhere else.
var _state: PackedFloat32Array = PackedFloat32Array()
var _awaiting_state: bool = false
var _resync_clock: float = 0.0
var _resync_left: int = 0
## Peer id -> when that peer's last press was believed. At most three entries, and
## only ever written on the host.
var _last_press_ms: Dictionary = {}
## Every player's head, rebuilt once a frame while TRACK is thrown, so the twelve
## rigs share one gather instead of asking the roster twelve times. One entry in
## single-player — yours — which is what makes it the same loop in both.
var _heads: PackedVector3Array = PackedVector3Array()

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
	# No eye handed over on purpose. F8 gives the viewport to the freecam, and the
	# freecam is a child of the player body — so "whatever camera is live" makes the
	# laser dot follow the eye you are actually looking through, while the avatar
	# stays on the body it stands for.
	NetPresence.enter(NetPresence.FULL)
	_enter_session()


func _process(delta: float) -> void:
	var eye: Camera3D = get_viewport().get_camera_3d()
	_spin_turntables(delta)
	_track(eye)
	_advance_focus(delta)
	_update_bead(delta)
	_tick_resync(delta)


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
	var pace: float = clampf(default_pace, PACE_MIN, PACE_MAX)
	_state = PackedFloat32Array([0.0, pace, 0.0, 0.0, 0.0, 0.0])
	_set_bank(ID_CLIP, 0.0)
	_set_bank(ID_PACE, pace)
	_set_bank(ID_TURN, 0.0)
	_set_bank(ID_TRACK, 0.0)
	for body: ExhibitBody in _bodies:
		body.pace = pace


func _set_bank(id: StringName, value: float) -> void:
	for control: DiegeticControl in _bank(id):
		control.set_value(value, false)


# --- handlers ---------------------------------------------------------------


func _on_clip_selected(index: int, _text: String, source: DiegeticDial) -> void:
	_drive(Field.CLIP, float(index), source)


func _on_pace_changed(value: float, source: DiegeticControl) -> void:
	_drive(Field.PACE, value, source)


func _on_turn_toggled(on: bool, source: DiegeticLever) -> void:
	_drive(Field.TURN, 1.0 if on else 0.0, source)


func _on_track_toggled(on: bool, source: DiegeticLever) -> void:
	_drive(Field.TRACK, 1.0 if on else 0.0, source)


func _on_prev() -> void:
	_drive(Field.FOCUS, float(_step(-1)), null)


func _on_next() -> void:
	_drive(Field.FOCUS, float(_step(1)), null)


func _on_take() -> void:
	_drive(Field.TAKE, float(posmod(_take + 1, TAKE_COUNT)), null)


func _step(dir: int) -> int:
	var n: int = _bodies.size()
	return 0 if n == 0 else posmod(_focus + dir, n)


# --- the room's state -------------------------------------------------------


## Somebody standing at a desk in THIS hall turned something. It happens here
## first, so the room answers the hand that moved it with no round trip in the
## way, and then the host is told. On the host, telling the host is telling
## everybody. In single-player the second half does not exist.
func _drive(field: int, value: float, source: DiegeticControl) -> void:
	if not _set_field(field, value, source, false):
		return
	if not _net_live():
		return
	if NetGame.is_authority():
		_rx_state.rpc(_state, false)
	else:
		_rq_field.rpc_id(NetPlayer.HOST_ID, field, value)


## Write one field and do whatever that field means. Returns false when the room
## was already like that, which is what stops an echo from flashing every control
## on every machine that already agreed.
##
## `source` is the control the hand was on, if any: it has already moved itself
## and moving it again would fight its own tween. `instant` skips the inspection
## lamp's travel, which is only ever right for the copy of the room a player is
## handed as they walk in.
func _set_field(field: int, raw: float, source: DiegeticControl, instant: bool) -> bool:
	if field < 0 or field >= FIELD_COUNT or _state.size() != FIELD_COUNT:
		return false
	var value: float = _sanitize_field(field, raw)
	if is_equal_approx(_state[field], value):
		return false
	_state[field] = value
	match field:
		Field.CLIP:
			_apply_clip(BeastClips.CLIPS[int(value)])
		Field.PACE:
			for body: ExhibitBody in _bodies:
				body.pace = value
		Field.TURN:
			_turning = value > 0.5
		Field.TRACK:
			_set_tracking(value > 0.5)
		Field.FOCUS:
			_focus_on(int(value), instant)
		Field.TAKE:
			_take = int(value)
			for body: ExhibitBody in _bodies:
				body.set_take(_take)
			_write_cards()
	_echo_field(field, source)
	return true


## Move every control that carries this field except the one that was touched, and
## flash them all. This was the two desks staying in lockstep; it is now also how
## you watch another player operate the far desk from where you are standing.
func _echo_field(field: int, source: DiegeticControl) -> void:
	if not FIELD_BANKS.has(field):
		return
	for control: DiegeticControl in _bank(FIELD_BANKS[field]):
		if control == source:
			continue
		# TAKE is a momentary button and holds no value; the flash is the whole of
		# its feedback, and the card readout says which take you landed on.
		if field != Field.TAKE:
			control.set_value(_state[field], false)
		control.flash()


## Clamp a candidate into what the field can actually be. Every number that has
## come off the wire goes through here first, so a client that sends nonsense
## moves the room to a legal position instead of into an error.
func _sanitize_field(field: int, raw: float) -> float:
	if not is_finite(raw):
		return 0.0
	var out: float = 0.0
	match field:
		Field.CLIP:
			out = float(clampi(int(round(raw)), 0, BeastClips.CLIPS.size() - 1))
		Field.PACE:
			out = clampf(raw, PACE_MIN, PACE_MAX)
		Field.TURN, Field.TRACK:
			out = 1.0 if raw > 0.5 else 0.0
		Field.FOCUS:
			out = 0.0 if _bodies.is_empty() else float(posmod(int(round(raw)), _bodies.size()))
		Field.TAKE:
			out = float(posmod(int(round(raw)), TAKE_COUNT))
	return out


func _set_tracking(on: bool) -> void:
	_tracking = on
	if on:
		return
	for body: ExhibitBody in _bodies:
		body.clear_aim()


# --- multiplayer ------------------------------------------------------------


## True when there is a session and the socket under it is actually up. Single
## player never gets past this line, and neither does a peer mid-handshake.
func _net_live() -> bool:
	return NetGame.is_networked() and NetAvatarLink.transport_ready(get_tree())


## Walk in. The host already IS the truth and has nothing to ask; a client asks
## for it and keeps asking until it arrives, because the two machines change scene
## a round trip apart and the first request can beat the host's hall into being.
func _enter_session() -> void:
	if NetGame.is_authority() or not _net_live():
		return
	_awaiting_state = true
	_resync_left = RESYNC_TRIES
	# Due immediately: the usual case is that the host is already standing in the
	# hall and the answer comes back inside a frame.
	_resync_clock = RESYNC_SECONDS


func _tick_resync(delta: float) -> void:
	if not _awaiting_state:
		return
	_resync_clock += delta
	if _resync_clock < RESYNC_SECONDS:
		return
	_resync_clock = 0.0
	_resync_left -= 1
	if _resync_left < 0 or not _net_live():
		_awaiting_state = false
		return
	_rq_state.rpc_id(NetPlayer.HOST_ID)


## A client asking what the room is doing. Answered privately, so nobody else pays
## for somebody else arriving.
@rpc("any_peer", "call_remote", "reliable")
func _rq_state() -> void:
	if not NetGame.is_authority():
		return
	var who: int = multiplayer.get_remote_sender_id()
	if who > 0:
		_rx_state.rpc_id(who, _state, true)


## A client turned something. Intent, not fact: the host decides what the room
## becomes and the echo below is what actually settles it — including on the
## machine that asked, which is already showing its own optimistic answer.
##
## Echoed unconditionally rather than only on a change, so a client that has
## somehow drifted is corrected by the next thing anybody touches.
@rpc("any_peer", "call_remote", "reliable")
func _rq_field(field: int, value: float) -> void:
	if not NetGame.is_authority() or not _net_live():
		return
	if not _believe_press(multiplayer.get_remote_sender_id()):
		return
	_set_field(field, value, null, false)
	_rx_state.rpc(_state, false)


## Whether this peer's press arrived slowly enough to have come from a hand.
func _believe_press(who: int) -> bool:
	if who <= 0:
		return false
	var now: int = Time.get_ticks_msec()
	if now - int(_last_press_ms.get(who, -100000)) < PRESS_FLOOR_MS:
		return false
	_last_press_ms[who] = now
	return true


## The room, from the host. `instant` is true only for the copy a player is handed
## as they walk in, so the inspection lamp is already on the right plinth instead
## of sweeping the length of the hall on their first frame.
@rpc("authority", "call_remote", "reliable")
func _rx_state(state: PackedFloat32Array, instant: bool) -> void:
	if NetGame.is_authority() or state.size() != FIELD_COUNT:
		return
	_awaiting_state = false
	for field: int in FIELD_COUNT:
		_set_field(field, state[field], null, instant)


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


## Point every rig at the nearest head in the room. `aim_at` is a rig-space write,
## not an IK solve, so twelve of these is a dozen vector subtractions and the
## nearest-of-four search on top of it is another forty-eight.
##
## NEAREST, not "the local player": every machine picks from the same four heads
## and gets the same answer, so the rack does the same thing on all four screens —
## and a creature follows whoever actually walked up to it, which is the only
## reading of "track" that is not a lie in a room with four people in it.
func _track(eye: Camera3D) -> void:
	if not _tracking:
		return
	_gather_heads(eye)
	if _heads.is_empty():
		return
	for body: ExhibitBody in _bodies:
		body.aim_at(_nearest_head(body.global_position))


## Every player's head in world space, at the height a creature looks at. Yours
## comes off whichever camera is live; everyone else's off the avatar the presence
## system stands them in, which is the node `NetPlayer.avatar` is documented to be.
func _gather_heads(eye: Camera3D) -> void:
	_heads.clear()
	if eye != null:
		var mine: Vector3 = eye.global_position
		mine.y *= track_eye_fraction
		_heads.append(mine)
	if not NetGame.is_networked():
		return
	for who: NetPlayer in NetGame.players():
		if who.is_local or not is_instance_valid(who.avatar):
			continue
		var head: Vector3 = who.avatar.global_position
		head.y = (head.y + NetPresence.EYE_HEIGHT) * track_eye_fraction
		_heads.append(head)


func _nearest_head(from: Vector3) -> Vector3:
	var best: Vector3 = _heads[0]
	var gap: float = from.distance_squared_to(best)
	for i: int in range(1, _heads.size()):
		var d: float = from.distance_squared_to(_heads[i])
		if d < gap:
			gap = d
			best = _heads[i]
	return best


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
