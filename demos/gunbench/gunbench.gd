class_name Gunbench
extends Node3D
## THE GUN BENCH. A gunsmith's bay with two turntables, a wall of rolled weapons and a
## console you operate by shooting it.
##
## The dynamic gun system is the centrepiece of the project and the range is a place to
## shoot things, not a place to read them. This is the reading room: roll a weapon,
## filter what you roll, put it in your hands, pull it apart into its five parts with
## every one labelled and traced back to its donor family, hang it on the rack, and set
## it against another one field by field.
##
## Everything on the console is physical. Nothing here draws a screen-space panel and
## nothing prints an instruction over the middle of the view: every control carries its
## own stencil, the five readouts are objects with bezels, and the one thing a player
## has to be told — that F3 is the diagnostics overlay and Escape is the way out — is
## painted on a board bolted to the floor by the door.
##
## THREE WEAPONS ARE IN PLAY AT ONCE and that is the whole interaction. Stand A holds
## one, stand B holds one, and your hands hold a third. A grab station under each stand
## TRADES: the weapon above that button comes to your hands and the weapon that was in
## your hands goes onto that stand, so nothing is ever thrown away and the stand you
## took from never goes empty. The wall rack trades the same way with stand A.
##
## THE CONTROLS:
##   GRAB A / GRAB B  under each stand. Takes THAT stand's weapon; yours goes on it.
##   ROLL             a fresh weapon on stand A
##   CLASS            narrow the roll to one of the reference's sixteen archetypes
##   TIER             refuse anything below a grade
##   COMPARE          copy stand A's weapon onto stand B
##   ROLL RACK        on the rack's own plate. Rerolls the six hooks and nothing else.
##   STRIP            the deck lever. Pulls both stands' weapons apart.
##   a peg            trades that hook with stand A
##
## There is deliberately no console plate that equips: a second, distant way to do what
## the grab stations do is exactly the confusion the stations exist to end.
##
## Rolling is not free — `GunFactory.roll` assembles up to four hundred weapons hunting
## for an archetype — so it happens on a button press and on scene load, never per frame
## and never in `_process`.
##
## FOUR PLAYERS AT ONE BENCH. The bay is a shared room and the host owns everything in
## it: both stands, all six hooks, both dials, the lever and every player's hands.
## Every machine actuates its OWN presses locally — that is what makes the plate flash
## and clack under your own shot with no round trip — but on a client the press is an
## INTENT: `GunbenchNet.request` sends it, the host resolves it, and the answer is the
## whole bench coming back. `res://demos/gunbench/gunbench_net.gd` is the wire and this
## file never touches a socket.
##
## A GRAB STATION KNOWS WHO HIT IT, which is the whole reason any of this exists. The
## press arrives at the host carrying Godot's sender id, so `GRAB A` gives stand A's
## weapon to the player who shot the plate and puts THAT player's weapon back on the
## stand. Four people can work the same two stands and nothing is ever handed to the
## wrong pair of hands.
##
## THE TWO CARDS THAT READ OUT HANDS ARE THE ONE PER-VIEWER THING IN THE BAY. Every
## other panel is a shared object and reads identically on all four machines. The
## middle card and the cartridge card under it describe the weapon YOU are holding,
## because the alternative is three of the four players reading a card about somebody
## else's gun. The cartridge card's title carries the slot colour of whoever is looking
## at it so this is stated rather than assumed.
##
## THERE IS NO FREE CAMERA IN THIS BAY. F8 is wired into the player prefab and it is
## removed here on purpose — see `_disable_freecam`.
##
## Single-player is untouched by all of the above: `NetGame.is_authority()` is true with
## no session, `NetGame.peer_id()` is 1, and every path below is the one the bench has
## always taken.

## Router id and menu copy. The bench registers itself because it is not in the shipped
## `SceneRouter.DEMOS` table, and a demo that cannot be routed to cannot be left either.
const DEMO_ID: String = "gunbench"
const DEMO_TITLE: String = "GUN BENCH"
const DEMO_BLURB: String = "Two turntables and a wall of scrap. Find out what a gun is made of."

## Control ids, as stencilled on the thing that carries them. These are duplicated in
## `res://tools/build_gunbench.gd`, which cannot name this class: a `--script` bake
## compiles before the autoloads this file's class chain reaches exist.
const ID_ROLL: StringName = &"roll"
const ID_CLASS: StringName = &"class"
const ID_TIER: StringName = &"tier"
const ID_COMPARE: StringName = &"compare"
const ID_STRIP: StringName = &"strip"
const ID_GRAB_MAIN: StringName = &"grab_main"
const ID_GRAB_RIVAL: StringName = &"grab_rival"
const ID_ROLL_RACK: StringName = &"roll_rack"
## A hook on the wall. Not a `DiegeticControl.control_id` — the six pegs share their
## own id — so the peg's index rides in the action's value.
const ID_PEG: StringName = &"peg"

## Dial position 0 on both filters: take whatever the tables give.
const FILTER_ANY: String = "ANY"

## Hand slot the bench equips into. The holster's primary.
const HAND_SLOT: int = 0

## Where each slot stands when the bay is shared. Four people spawned on one mark is
## four capsules inside each other, so the slot decides which metre of floor is yours.
## SLOT 0 IS EXACTLY ZERO and always will be: single-player is slot 0 and has to stand
## precisely where the scene put it, which is what `verify_gunbench` measures its
## reach-from-spawn assertions from.
const SLOT_STANDS: PackedVector3Array = [
	Vector3(0.0, 0.0, 0.0),
	Vector3(-1.10, 0.0, 0.30),
	Vector3(1.10, 0.0, 0.30),
	Vector3(0.0, 0.0, 1.25),
]

@export_group("Rolling")
## Seed the bench's weapon stream starts from. Zero takes the clock, so every visit
## finds a different rack; set it and the whole bay is reproducible.
@export var stream_seed: int = 0
## Whole weapons rolled while hunting for one that clears the tier filter before the
## best of the batch is accepted instead. Each one is a full assembly, so this is a
## multiplier on an already expensive call — keep it small.
@export_range(1, 64, 1) var tier_attempts: int = 24

@export_group("Interaction")
## Metres a walk-up `interact` reaches. A shot reaches as far as the bullet does.
@export_range(0.5, 8.0, 0.1) var interact_range: float = 3.2
## Metres a press on the trigger reaches. A shot reaches as far as the bullet does,
## and the bay is nine metres across, so this only has to clear the room.
@export_range(1.0, 500.0, 1.0) var fire_reach: float = 120.0
## Fraction of a full-power hit a console control is actuated with when the trigger
## ray finds it. The bench is not a damage model; a hit is a hit.
@export_range(0.0, 1.0, 0.05) var control_power: float = 1.0
## Metres the exploded assembly separates its parts by. Big enough to read the tags,
## small enough that a long weapon does not reach the next stand.
@export_range(0.05, 0.8, 0.005) var explode_metres: float = 0.24

@export_group("Weapon")
## Let the player fire the weapon in their hands. The console is operated the same way
## whether this is on or off — the trigger ray does not need a bullet to exist.
@export var live_fire: bool = true
## Multiplies the recoil the weapon pushes back into the look angles.
@export_range(0.0, 2.0, 0.05) var recoil_scale: float = 1.0

var _rand: XorShift32 = null
var _class_filter: String = ""
var _tier_filter: int = 0
var _controls: Dictionary = {}
var _pegs: Array[GunbenchPeg] = []
## The weapon actually in YOUR hands, on this machine. Kept here rather than read back
## off the holster because the holster only owns it from the moment the swap exchanges
## the geometry, and the middle card has to be right before that.
var _hand_spec: GunSpec = null
## Every player's hands, keyed by peer id. HOST ONLY — it is what a grab station needs
## in order to put the right weapon back on the stand, and the host is the only machine
## that resolves a grab. A client keeps its own in `_hand_spec` and needs no more.
var _hands_by_peer: Dictionary = {}
## What this machine last put in its hands, on each stand and on each hook, as wires.
## THE SNAPSHOT REPEATS THE WHOLE BAY ON EVERY PRESS and rebuilding it all every time
## anybody touches anything is eight `GunSpec` assemblies and forty mesh nodes for a
## button somebody pushed across the room. Only what actually changed is decoded — and
## for the hands it is also what stops the holster replaying its stow-and-draw.
var _hand_wire: PackedInt32Array = PackedInt32Array()
var _shown_main: PackedInt32Array = PackedInt32Array()
var _shown_rival: PackedInt32Array = PackedInt32Array()
var _shown_pegs: Array[PackedInt32Array] = []
## The socket. Owns every RPC in the demo; this file owns every decision.
var _net: GunbenchNet = null
## Every click on the console goes through this. It latches the press in
## `_unhandled_input` and casts the press's own ray in `_physics_process`, which is
## what makes a flick-and-click land instead of resolving against where the eye was
## a frame ago.
var _hands: DiegeticInteractor = null
## The trigger, so a click too short to straddle a physics tick still fires a round.
var _trigger: TriggerLatch = TriggerLatch.new()

@onready var _main: GunbenchStand = $Stands/MainStand
@onready var _rival: GunbenchStand = $Stands/RivalStand
@onready var _card_stat: DiegeticReadout = $Cards/Stat
@onready var _card_hands: DiegeticReadout = $Cards/Hands
@onready var _card_cartridge: DiegeticReadout = $Cards/Cartridge
@onready var _card_rival: DiegeticReadout = $Cards/Rival
@onready var _card_delta: DiegeticReadout = $Cards/Delta
@onready var _player: PlayerController = $Player
@onready var _holster: WeaponHolster = $Player/Eye/Holster
@onready var _weapon: Weapon = $Weapon


func _ready() -> void:
	_register_demo()
	GameSettings.register_viewport(get_viewport())
	_rand = XorShift32.new(stream_seed if stream_seed != 0 else _clock_seed())
	_disable_freecam()
	_build_hands()
	_build_net()
	_main.explode_metres = explode_metres
	_rival.explode_metres = explode_metres
	_collect_controls()
	_collect_pegs()
	_wire_weapon()
	_stand_at_slot()
	# Capsules, sunglasses, names and everybody's laser dot, in one line. Free and inert
	# in single-player: the roster is a list of one and only your own dim dot is drawn.
	#
	# DEFERRED, AND IT HAS TO BE. `NetPresence.instance()` parents itself to `/root`,
	# and this `_ready` runs INSIDE the root's own `add_child` of the bay — so calling
	# it straight from here is refused with "Parent node is busy setting up children"
	# and leaves the singleton orphaned: nobody in the bay can see anybody. One frame
	# later the tree is idle and the add lands.
	_enter_presence.call_deferred()
	if not PartLibrary.is_loaded():
		push_error("Gunbench: the part library is not loaded. %s" % PartLibrary.load_error)
		_refuse_controls()
		return
	if NetGame.is_authority():
		_stock_the_bay()
	else:
		# A client owns nothing here and must not roll: two machines rolling their own
		# bench is two different bays. Show an honestly empty room and ask the host.
		_set_stand(_main, null)
		_set_stand(_rival, null)
		for peg: GunbenchPeg in _pegs:
			peg.set_spec(null)
		_set_hand_cards(null)
		_net.hello()
	# Launched straight from the editor the router has no current demo, so nothing has
	# taken the mouse. Entering through the menu, this is already true and costs nothing.
	if SceneRouter.current_demo.is_empty():
		SceneRouter.set_mouse_captured(true)


func _exit_tree() -> void:
	DebugHUD.clear_note(&"gunbench")


func _physics_process(_delta: float) -> void:
	_hands.enabled = not SceneRouter.is_paused()
	_drive_trigger()
	if _weapon == null or _weapon.spec() == null:
		return
	_weapon.set_aim_blend(_player.ads)
	_weapon.set_stance(_player.speed, _player.grounded, _player.crouch_t > 0.5)


## Nothing here resolves a click. The console belongs to `_hands`, which latches
## every press whether or not a physics tick is near it; all that is left is the
## trigger, and that is latched too.
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		return
	if SceneRouter.is_paused():
		_trigger.clear()
		return
	if event.is_action_pressed(&"fire"):
		_trigger.press()
		return
	if event.is_action_released(&"fire"):
		_trigger.release()
		return
	if event.is_action_pressed(&"reload") and live_fire and _weapon != null:
		_weapon.reload()


## The weapon on the main stand. Null before the first roll lands.
func current_spec() -> GunSpec:
	return _main.spec()


## The weapon in YOUR hands. This is the one the middle card reads out and the one the
## trigger fires; it is on neither stand. In a shared bay this is your own and nobody
## else's — ask the host through a grab if you want somebody else's.
func hand_spec() -> GunSpec:
	return _hand_spec


## Roll one weapon through the console's current filters and put it on the main stand.
## On a client this asks the host to do it and returns immediately.
func roll_now() -> void:
	_operate(ID_ROLL, 0)


## Take the weapon off `stand` and put what you were holding in its place. This is what
## a grab button does, and it is the whole trade: the stand you took from is never left
## empty and the weapon you were carrying is never destroyed.
##
## Returns whether the trade happened. On a CLIENT it returns whether the request was
## sent, because the answer is a snapshot that has not arrived yet.
func grab_from(stand: GunbenchStand) -> bool:
	if stand == null:
		return false
	var action: StringName = ID_GRAB_MAIN if stand == _main else ID_GRAB_RIVAL
	if not NetGame.is_authority():
		_net.request(action, 0)
		return true
	return _grab(stand, NetGame.peer_id())


## Reroll the six hooks on the wall, and nothing else. Neither stand nor your hands are
## touched: `verify_gunbench` asserts exactly that.
func roll_rack() -> void:
	_operate(ID_ROLL_RACK, 0)


# --- setup --------------------------------------------------------------------


func _register_demo() -> void:
	if SceneRouter.has_demo(DEMO_ID):
		return
	SceneRouter.register_demo(DEMO_ID, DEMO_TITLE, scene_file_path, DEMO_BLURB)


## THE FREE CAMERA IS REMOVED FROM THIS BAY, DELIBERATELY.
##
## It was reported as closing the game when F8 was pressed here. The cause was looked
## for and NOT found. `FreecamController` adopts the live camera, makes itself current
## and hands the view back, and neither the bench, the interactor, the reticle, the
## holster nor the viewmodel pass has a path through that which can take the process
## down; the baked scene was also run twice with a synthesised F8 and stayed up with a
## clean console, though that keystroke could not be proven to have reached the window.
## So: not reproduced, and not explained.
##
## It comes out anyway, because it is worth nothing here and the report is worth
## something. The bay is nine metres across, every control is a plate you stand in
## front of, and the one thing a free camera buys — getting a look at something you
## cannot walk to — does not exist in a room you can cross in four seconds. An
## unexplained crash on a feature nobody needs is a feature you delete.
##
## The node is freed rather than merely silenced so nothing can quietly become current
## behind the player, and the board by the door no longer promises it.
func _disable_freecam() -> void:
	var freecam: Node = get_node_or_null(^"Player/Freecam")
	if freecam != null:
		freecam.queue_free()


## Everyone in the bay appears to everyone else. Called deferred from `_ready` — see
## the note there.
func _enter_presence() -> void:
	NetPresence.enter(NetPresence.FULL, $Player/Eye)


## The wire. Built here rather than baked into the scene so it cannot exist before this
## node does, and named from a constant because Godot routes an RPC by node path: it
## has to be `/root/Gunbench/Net` on every machine or nothing arrives anywhere.
func _build_net() -> void:
	_net = GunbenchNet.new()
	_net.name = String(GunbenchNet.NODE_NAME)
	add_child(_net)
	_net.world_arrived.connect(_on_world_arrived)
	_net.action_arrived.connect(_on_action_arrived)
	_net.peer_arrived.connect(_on_peer_arrived)
	NetGame.peer_left.connect(_on_peer_left)


## Stand on your slot's mark. Slot 0 — which is the host, and is also you in
## single-player — does not move at all, so a bench with nobody else in it spawns you
## exactly where the scene put you and every measurement taken from that mark still
## holds.
func _stand_at_slot() -> void:
	if not NetGame.is_networked() or _player == null:
		return
	var slot: int = clampi(NetGame.local_player().slot, 0, SLOT_STANDS.size() - 1)
	_player.teleport(_player.global_position + SLOT_STANDS[slot], _player.yaw)


## Fill the bay. HOST ONLY, and once.
func _stock_the_bay() -> void:
	_fill_rack()
	_set_stand(_main, _roll())
	# The rival stand starts loaded too. An empty second stand and a delta card reading
	# "PUT A WEAPON ON EACH STAND" is a correct first frame and a useless one; two
	# weapons and a filled comparison is what the bench is for.
	_set_stand(_rival, GunFactory.roll(_next_seed()))
	# And a THIRD weapon straight into your hands, which is what makes the grab stations
	# mean anything on the first press: with the stands' own weapons duplicated into the
	# hands there is nothing to trade and the first press looks like it did nothing.
	_give_hand(NetGame.peer_id(), GunFactory.roll(_next_seed()))
	_publish(&"", 0, NetGame.peer_id())


## Every control the bench owns, keyed by its stencilled id, plus the dial option lists
## that have to agree with the reference's tables rather than with a hand-typed copy.
##
## The list is assembled by hand rather than by walking the whole tree, because the
## rack's six pegs are `DiegeticControl`s too and they go through `_on_peg_pressed`.
func _collect_controls() -> void:
	var candidates: Array[Node] = []
	candidates.append_array($Console/Panel.get_children())
	candidates.append_array($Console/Deck.get_children())
	candidates.append_array($Rack/RollStation.get_children())
	candidates.append(_main.grab_control())
	candidates.append(_rival.grab_control())
	for node: Node in candidates:
		var control := node as DiegeticControl
		if control == null:
			continue
		_controls[control.control_id] = control
		# A dial reports through `option_selected`, which fires whether it was shot or
		# stepped from code; `pressed` also fires on a hit that did not move the detent.
		var dial := control as DiegeticDial
		if dial != null:
			dial.option_selected.connect(_on_filter_changed.bind(dial))
			continue
		control.pressed.connect(_on_control_pressed.bind(control))

	var class_dial := _controls.get(ID_CLASS) as DiegeticDial
	if class_dial != null:
		var classes := PackedStringArray([FILTER_ANY])
		for entry: Array in GunTables.CLASS_MIX:
			classes.append(String(entry[0]).to_upper())
		class_dial.set_options(classes)

	var tier_dial := _controls.get(ID_TIER) as DiegeticDial
	if tier_dial != null:
		var tiers := PackedStringArray([FILTER_ANY])
		for tier_name: String in Palette.GUN_TIER_NAMES:
			tiers.append(tier_name.to_upper())
		tier_dial.set_options(tiers)


func _collect_pegs() -> void:
	for node: Node in $Rack/Pegs.get_children():
		var peg := node as GunbenchPeg
		if peg == null:
			continue
		_pegs.append(peg)
		_shown_pegs.append(PackedInt32Array())
		peg.pressed.connect(_on_peg_pressed.bind(peg))


## The weapon node lives on the bench, not inside the baked player, and is pointed at
## the player's eye and at whatever the holster currently has up. Rebinding on
## `weapon_changed` is what keeps the muzzle marker correct across a swap.
func _wire_weapon() -> void:
	if _weapon == null:
		return
	# `slot_equipped`, not `weapon_changed`: the holster only emits the latter at the end
	# of a swap animation, and the very first equip into an empty slot is not a swap.
	_holster.slot_equipped.connect(_on_slot_equipped)
	_weapon.hit.connect(_on_weapon_hit)
	_weapon.recoiled.connect(_on_weapon_recoiled)
	_weapon.set_rig($Player/Eye, $Player/Eye, _player)


func _fill_rack() -> void:
	for peg: GunbenchPeg in _pegs:
		peg.set_spec(GunFactory.roll(_next_seed()))


func _clock_seed() -> int:
	return Time.get_ticks_usec() & 0xFFFFFFFF


## The reference's seed draw: floor of a unit float across the 32-bit range, which is
## `(rand()*4294967295)>>>0` and not a rounding.
func _next_seed() -> int:
	return int(_rand.next() * 4294967295.0) & 0xFFFFFFFF


# --- rolling ------------------------------------------------------------------


## One weapon through both filters. The class filter is `GunFactory`'s own business —
## it already hunts for an archetype. The tier filter is ours, because grade falls out
## of the finished numbers and cannot be asked for up front, so it is a rejection loop
## with a budget that keeps the best it saw rather than returning nothing.
func _roll() -> GunSpec:
	var best: GunSpec = null
	for _i: int in tier_attempts:
		var spec: GunSpec = GunFactory.roll(_next_seed(), _class_filter)
		if spec == null:
			return best
		if _tier_filter <= 0 or spec.tier_index >= _tier_filter:
			return spec
		if best == null or spec.tier_index > best.tier_index:
			best = spec
	return best


## Put `spec` on `stand` and repaint whatever reads that stand out. One function for
## both stands, because "which card does this stand own" is the stand's business and
## not two near-identical copies of the same six lines.
func _set_stand(stand: GunbenchStand, spec: GunSpec) -> void:
	stand.set_spec(spec)
	var card: DiegeticReadout = _card_stat if stand == _main else _card_rival
	var rest: Color = UiStyle.ACCENT if stand == _main else UiStyle.COOL
	card.set_title(GunbenchCards.title(spec))
	card.set_lines(GunbenchCards.stat_lines(spec))
	card.set_bars(
		GunbenchCards.BAR_LABELS, GunbenchCards.stat_bars(spec), GunbenchCards.stat_bar_colors(spec)
	)
	card.accent = spec.tier_color if spec != null else rest
	_refresh_delta()
	_sync_grab(stand)


## Put `spec` in `peer`'s hands. On the host this is the record for the whole bay — it
## is what a grab station reads to know what to put back on the stand — and on every
## machine it is what actually goes into the holster when `peer` is you.
func _give_hand(peer: int, spec: GunSpec) -> void:
	if peer <= 0:
		return
	if NetGame.is_authority():
		if spec == null:
			_hands_by_peer.erase(peer)
		else:
			_hands_by_peer[peer] = spec
	if peer == NetGame.peer_id():
		_take(spec)


## What `peer` is holding. HOST ONLY: a client is told about its own hands and nobody
## else's, and never has to answer this.
func _hand_of(peer: int) -> GunSpec:
	return _hands_by_peer.get(peer) as GunSpec


## The trade itself, resolved on the authority. `peer` is whoever hit the plate, so the
## weapon above that button goes to THEIR hands and what THEY were carrying goes onto
## the stand. Nothing is created and nothing is destroyed.
func _grab(stand: GunbenchStand, peer: int) -> bool:
	var taken: GunSpec = stand.spec()
	var held: GunSpec = _hand_of(peer)
	if taken == null and held == null:
		return false
	_set_stand(stand, held)
	_give_hand(peer, taken)
	return true


## Put `spec` in your own hands. The holster stows what is up at the OLD weapon's
## weight and only exchanges the geometry once it is out of sight, which is what makes
## the grab read as a hand movement rather than a pop; the middle card follows at the
## exchange, through `_on_slot_equipped`.
func _take(spec: GunSpec) -> void:
	_hand_spec = spec
	_hand_wire = GunbenchNet.encode_spec(spec)
	_holster.equip(HAND_SLOT, spec)
	_sync_grab(_main)
	_sync_grab(_rival)


## The two cards that read out your own hands: the big middle one and the cartridge
## under it. Driven from `slot_equipped`, so they change at the instant the geometry
## does and never describe a weapon that is still on its way up.
##
## These two are the only panels in the bay that are not the same on every machine —
## see the class doc. The cartridge card's title says whose hands it is describing, in
## the slot's own colour word, so nobody has to work that out.
func _set_hand_cards(spec: GunSpec) -> void:
	_card_hands.set_title(GunbenchCards.title(spec))
	_card_hands.set_lines(GunbenchCards.stat_lines(spec))
	_card_hands.set_bars(
		GunbenchCards.BAR_LABELS, GunbenchCards.stat_bars(spec), GunbenchCards.stat_bar_colors(spec)
	)
	_card_hands.accent = spec.tier_color if spec != null else UiStyle.GOLD
	_card_cartridge.set_title(_cartridge_title())
	_card_cartridge.set_lines(GunbenchCards.cartridge_lines(spec))
	_note(spec)


## "CARTRIDGE" alone with nobody else in the bay, and "CARTRIDGE · GOLD" with three
## other people in it. The slot NAME rather than the username on purpose: it is four
## characters at most, it matches the colour of your own avatar and dot, and a sixteen
## character name would run off a 512-pixel panel.
func _cartridge_title() -> String:
	if not NetGame.is_networked():
		return "CARTRIDGE"
	return "CARTRIDGE  ·  %s" % NetGame.local_player().slot_name()


func _refresh_delta() -> void:
	_card_delta.set_title("A AGAINST B")
	_card_delta.set_lines(GunbenchCards.delta_lines(_main.spec(), _rival.spec()))


## A grab button with nothing to trade on either side refuses, audibly, instead of
## flashing and doing nothing. In a healthy bay this is never false — both stands and
## the hands always hold something — but a bay whose part library failed to load has
## nothing anywhere, and a control that lies about that is worse than a dead one.
func _sync_grab(stand: GunbenchStand) -> void:
	var control: DiegeticControl = stand.grab_control()
	if control != null:
		control.enabled = stand.has_weapon() or _hand_spec != null


## Nothing in the bay can do anything without the part library, so every control in it
## refuses — audibly, through `DiegeticControl._deny` — rather than flashing and doing
## nothing. A dead bay that still clicks is the worst of the three outcomes.
func _refuse_controls() -> void:
	for control: DiegeticControl in _controls.values():
		control.enabled = false
	for peg: GunbenchPeg in _pegs:
		peg.enabled = false


## The F3 overlay's line. Screen text belongs to the debug build and nowhere else.
func _note(spec: GunSpec) -> void:
	var session: String = ""
	if NetGame.is_networked():
		var role: String = "host" if NetGame.is_host() else "guest"
		if _net != null and not _net.is_synced():
			role = "guest, waiting for the bench"
		session = "  %s %s" % [NetGame.local_player().slot_name(), role]
	if spec == null:
		DebugHUD.note(&"gunbench", "gunbench  no weapon%s" % session)
		return
	DebugHUD.note(
		&"gunbench",
		(
			"gunbench  in hand %s  %s  seed %d  fit %.3f%s"
			% [spec.weapon_name, String(spec.tier_name), spec.roll_seed, spec.fit_error, session]
		)
	)


# --- input --------------------------------------------------------------------


## The hands. `eye_path` is deliberately left empty so the rays come from whatever
## camera the viewport is using, which in this bay is always the player's own eye —
## there is no free camera here, and nothing else ever takes the view.
func _build_hands() -> void:
	_hands = DiegeticInteractor.new()
	_hands.name = "Hands"
	_hands.collision_mask = GameLayers.PROP
	_hands.interact_reach = interact_range
	_hands.fire_reach = fire_reach
	_hands.press_power = control_power
	_hands.fire_presses_at_point = true
	# The console is the only thing on the PROP layer in front of the player, and
	# nothing in this demo highlights what it is pointed at, so the per-frame hover
	# ray would be a ray cast for nobody.
	_hands.track_hover = false
	add_child(_hands)
	CombatReticle.mount(self).watch(_hands)


## Hold the trigger down for the tick the latch says it should be down for. Gunbench
## runs its weapon `self_driven`, and `Weapon` is a child of this node, so the state
## set here is read by `Weapon._physics_process` later in the same frame.
func _drive_trigger() -> void:
	if _weapon == null:
		return
	if not live_fire:
		_trigger.clear()
		_weapon.trigger_up()
		return
	if _trigger.resolve():
		_weapon.trigger_down()
	else:
		_weapon.trigger_up()


# --- console ------------------------------------------------------------------


## A control this machine actuated. The plate has already flashed and clacked under
## your own hand; what it MEANS is the authority's business, so the host resolves it
## and a client asks.
func _on_control_pressed(control: DiegeticControl) -> void:
	var value: int = 0
	if control.control_id == ID_STRIP:
		value = 1 if (control as DiegeticLever).is_on() else 0
	_operate(control.control_id, value)


## A filter dial moved on this machine. The detent has already turned under your shot;
## the host decides what the bench does about it and every dial in the bay is set from
## the answer, so four people never disagree about what the filter says.
##
## Detent 0 on both is ANY, so index 1 is the first real entry — the class list is
## `GunTables.CLASS_MIX` in table order, the tier list is `Palette.GUN_TIER_NAMES` in
## rank order, and neither is retyped here.
func _on_filter_changed(index: int, _text: String, dial: DiegeticDial) -> void:
	if dial.control_id != ID_CLASS and dial.control_id != ID_TIER:
		return
	_operate(dial.control_id, index)


## A hook was taken off the wall. Which hook rides in the action's value, because all
## six pegs answer to the same control id.
func _on_peg_pressed(peg: GunbenchPeg) -> void:
	var index: int = _pegs.find(peg)
	if index < 0:
		return
	_operate(ID_PEG, index)


# --- authority ----------------------------------------------------------------


## A press this machine made. Resolved here on the host and in single-player; sent as
## an intent on a client, where the answer arrives as the whole bench.
func _operate(action: StringName, value: int) -> void:
	if NetGame.is_authority():
		_resolve(NetGame.peer_id(), action, value)
		return
	_net.request(action, value)


## What a press MEANS. HOST ONLY, and the single place in the demo where the bay
## changes. `peer` is who pressed it — Godot's sender id for a client, this machine's
## own for the host — and it is the whole reason a grab station hands the right weapon
## to the right person.
func _resolve(peer: int, action: StringName, value: int) -> void:
	match action:
		ID_ROLL:
			_set_stand(_main, _roll())
		ID_COMPARE:
			_set_stand(_rival, _main.spec())
		ID_GRAB_MAIN:
			_grab(_main, peer)
		ID_GRAB_RIVAL:
			_grab(_rival, peer)
		ID_ROLL_RACK:
			_fill_rack()
		ID_STRIP:
			_set_strip(value != 0)
		ID_CLASS:
			_set_class(value)
			_set_stand(_main, _roll())
		ID_TIER:
			_set_tier(value)
			_set_stand(_main, _roll())
		ID_PEG:
			_trade_peg(value, peer)
		_:
			# An id the bench does not own. A client cannot make one up that matters.
			return
	# The host's own plate has already flashed under its own press; somebody else's has
	# not, and a bay where you cannot see the other three working is a bay with three
	# invisible people in it.
	if peer != NetGame.peer_id():
		_acknowledge(action, value)
	_publish(action, value, peer)


## The class filter, from a detent index. Read back off the DIAL rather than off the
## index that was asked for: the dial sanitises whatever it is given, and a filter
## derived from the raw number would then describe a detent the dial is not on.
func _set_class(index: int) -> void:
	var settled: int = _set_dial(ID_CLASS, index)
	var table: Array = GunTables.CLASS_MIX
	_class_filter = "" if settled <= 0 or settled > table.size() else String(table[settled - 1][0])


func _set_tier(index: int) -> void:
	_tier_filter = maxi(_set_dial(ID_TIER, index) - 1, 0)


## Both stands, and the lever that says so. Set from the value rather than toggled, so
## a machine that missed a message still ends up in the state the host is in.
func _set_strip(on: bool) -> void:
	_main.set_exploded(on)
	_rival.set_exploded(on)
	var lever := _controls.get(ID_STRIP) as DiegeticLever
	if lever != null and lever.is_on() != on:
		# Notified, so it THROWS rather than snapping. Nothing in this demo listens to
		# `value_changed` or `toggled` on a lever — the press comes in through
		# `pressed` — so a notified write cannot come back round.
		lever.set_on(on, true)


## The rack and YOUR HANDS trade. Shooting a hook hands you that weapon and hangs what
## you were carrying in its place, so the wall stays full and nothing is thrown away.
##
## IT USED TO TRADE WITH STAND A, which is what the user reported as "the guns are not
## selectable": you shoot a gun on the wall, the DISPLAY changes, your own gun does not,
## and the weapon you thought you had picked up is then what the grab plate puts back
## down. The bench was doing exactly what it was built to do, and what it was built to
## do was not what shooting a gun off a wall obviously means. The grab plates under the
## two stands are still how you take a DISPLAYED gun; the rack is now its own route.
## The rack does not
## reach into your hands: a peg and a grab station are two different movements.
func _trade_peg(index: int, peer: int) -> void:
	if index < 0 or index >= _pegs.size():
		return
	var peg: GunbenchPeg = _pegs[index]
	var taken: GunSpec = peg.spec()
	if taken == null:
		return
	peg.set_spec(_hand_of(peer))
	_give_hand(peer, taken)


## Turn a dial to a detent and answer with the detent it actually settled on, which is
## not always the one asked for: `DiegeticDial` wraps and clamps whatever it is given,
## which is also what keeps a hostile index harmless.
##
## `option_selected` is the only signal that reaches `_operate`, and `set_value` does
## not emit it — only a hit and `step_selection` do — so this cannot loop.
func _set_dial(id: StringName, index: int) -> int:
	var dial := _controls.get(id) as DiegeticDial
	if dial == null:
		return index
	if dial.selected_index() != index:
		dial.set_value(float(index))
	return dial.selected_index()


## Flash a plate somebody else worked. Cosmetic, local on every machine, no RPC — the
## rule in `res://net/README.md` — and it is the difference between three other people
## being present in the bay and three other people being capsules.
func _acknowledge(action: StringName, value: int) -> void:
	var control: DiegeticControl = null
	if action == ID_PEG:
		control = _pegs[value] if value >= 0 and value < _pegs.size() else null
	else:
		control = _controls.get(action) as DiegeticControl
	if control != null:
		control.flash()


# --- the wire -----------------------------------------------------------------


## Send the whole bay. HOST ONLY, and skipped entirely with nobody to send it to, so
## single-player never builds a snapshot it would throw away.
func _publish(action: StringName, value: int, by: int) -> void:
	if not NetGame.is_networked():
		return
	_net.publish(_snapshot(action, value, by))


## The whole bay, in about two hundred and sixty bytes. See `gunbench_net.gd` for why
## this is a snapshot and not a delta.
func _snapshot(action: StringName, value: int, by: int) -> Dictionary:
	var pegs: Array = []
	for peg: GunbenchPeg in _pegs:
		pegs.append(GunbenchNet.encode_spec(peg.spec()))
	var hands: Dictionary = {}
	for peer: int in _hands_by_peer:
		hands[peer] = GunbenchNet.encode_spec(_hands_by_peer[peer] as GunSpec)
	return {
		GunbenchNet.K_MAIN: GunbenchNet.encode_spec(_main.spec()),
		GunbenchNet.K_RIVAL: GunbenchNet.encode_spec(_rival.spec()),
		GunbenchNet.K_PEGS: pegs,
		GunbenchNet.K_HANDS: hands,
		GunbenchNet.K_CLASS: _dial_index(ID_CLASS),
		GunbenchNet.K_TIER: _dial_index(ID_TIER),
		GunbenchNet.K_STRIP: _main.is_exploded(),
		GunbenchNet.K_ACTION: action,
		GunbenchNet.K_VALUE: value,
		GunbenchNet.K_BY: by,
	}


## The host's bay, arriving on a client. Every field is type-checked before it is read:
## a snapshot from a build that does not match this one has to leave the bench empty,
## not take the process down.
func _on_world_arrived(state: Dictionary) -> void:
	var main_wire: PackedInt32Array = _wire_at(state, GunbenchNet.K_MAIN)
	if main_wire != _shown_main:
		_shown_main = main_wire
		_set_stand(_main, GunbenchNet.decode_spec(main_wire))
	var rival_wire: PackedInt32Array = _wire_at(state, GunbenchNet.K_RIVAL)
	if rival_wire != _shown_rival:
		_shown_rival = rival_wire
		_set_stand(_rival, GunbenchNet.decode_spec(rival_wire))
	_apply_pegs(state.get(GunbenchNet.K_PEGS))
	_set_class(_int_at(state, GunbenchNet.K_CLASS))
	_set_tier(_int_at(state, GunbenchNet.K_TIER))
	_set_strip(bool(state.get(GunbenchNet.K_STRIP, false)))
	_apply_own_hand(state.get(GunbenchNet.K_HANDS))
	var action: Variant = state.get(GunbenchNet.K_ACTION)
	if typeof(action) != TYPE_STRING_NAME:
		return
	if _int_at(state, GunbenchNet.K_BY) != NetGame.peer_id():
		_acknowledge(action, _int_at(state, GunbenchNet.K_VALUE))


## Only your own hands come off the snapshot. The other three are in it so the bay's
## state is complete and the host can be read back whole, but nothing on this machine
## draws somebody else's weapon — the avatars carry no gun — and rebuilding three
## `GunSpec`s on every press anybody makes would be three assemblies for nobody.
func _apply_own_hand(raw: Variant) -> void:
	if typeof(raw) != TYPE_DICTIONARY:
		return
	var hands: Dictionary = raw
	var mine: Variant = hands.get(NetGame.peer_id())
	var wire := PackedInt32Array()
	if typeof(mine) == TYPE_PACKED_INT32_ARRAY:
		wire = mine
	if wire == _hand_wire:
		return
	# `decode_spec` refuses a malformed wire and `_take` records what it actually got,
	# so a rejected weapon leaves the hands empty rather than out of step forever.
	_give_hand(NetGame.peer_id(), GunbenchNet.decode_spec(wire))


func _apply_pegs(raw: Variant) -> void:
	if typeof(raw) != TYPE_ARRAY:
		return
	var wires: Array = raw
	for i: int in _pegs.size():
		if i >= wires.size() or typeof(wires[i]) != TYPE_PACKED_INT32_ARRAY:
			continue
		var wire: PackedInt32Array = wires[i]
		if wire == _shown_pegs[i]:
			continue
		_shown_pegs[i] = wire
		_pegs[i].set_spec(GunbenchNet.decode_spec(wire))


static func _wire_at(state: Dictionary, key: StringName) -> PackedInt32Array:
	var raw: Variant = state.get(key)
	if typeof(raw) != TYPE_PACKED_INT32_ARRAY:
		return PackedInt32Array()
	return raw


static func _int_at(state: Dictionary, key: StringName) -> int:
	var raw: Variant = state.get(key)
	return int(raw) if typeof(raw) == TYPE_INT else 0


func _dial_index(id: StringName) -> int:
	var dial := _controls.get(id) as DiegeticDial
	return 0 if dial == null else dial.selected_index()


## A client pressed something. HOST ONLY.
func _on_action_arrived(from_peer: int, action: StringName, value: int) -> void:
	_resolve(from_peer, action, value)


## Somebody walked into the bay. HOST ONLY: roll them the third weapon every player
## starts with — the one that makes their first grab a trade rather than a no-op — and
## publishing it is also what hands them the rest of the bench.
func _on_peer_arrived(peer_id: int) -> void:
	if not NetGame.is_authority() or peer_id == NetGame.peer_id():
		return
	if _hand_of(peer_id) == null and PartLibrary.is_loaded():
		_give_hand(peer_id, GunFactory.roll(_next_seed()))
	_publish(&"", 0, peer_id)


## Somebody left. Their weapon leaves with them rather than lingering as a hand nobody
## has; the stands and the rack are untouched, which is what "nothing is thrown away"
## means for the things that are still in the room.
func _on_peer_left(peer_id: int) -> void:
	_net.forget(peer_id)
	if not NetGame.is_authority() or peer_id == NetGame.peer_id():
		return
	if _hands_by_peer.erase(peer_id):
		_publish(&"", 0, peer_id)


# --- weapon -------------------------------------------------------------------


## The geometry in your hands has just been exchanged. This is the honest moment for
## the middle card to change: before it, the weapon still up is the old one.
func _on_slot_equipped(slot: int, spec: GunSpec) -> void:
	if slot != HAND_SLOT:
		return
	_hand_spec = spec
	_set_hand_cards(spec)
	_sync_grab(_main)
	_sync_grab(_rival)
	if _weapon == null or spec == null:
		return
	_weapon.setup(spec)
	var gun: Node3D = _holster.active_node()
	var muzzle: Node3D = gun.get_node_or_null(^"Muzzle") as Node3D if gun != null else null
	_weapon.set_rig($Player/Eye, muzzle if muzzle != null else $Player/Eye, _player)


## A bullet that lands on a console control operates it, exactly as the control's own
## documentation asks for. The control's cooldown swallows the duplicate when the
## trigger ray has already actuated it this frame, and swallows the other eight pellets
## when the weapon in your hands turned out to be a shotgun.
func _on_weapon_hit(collider: Object, position: Vector3, _normal: Vector3, _damage: float) -> void:
	var control := collider as DiegeticControl
	if control != null:
		control.shoot(position, control_power)


func _on_weapon_recoiled(aim_delta: Vector2) -> void:
	if _player == null:
		return
	_player.pitch = clampf(
		_player.pitch + aim_delta.x * recoil_scale, -_player.pitch_limit, _player.pitch_limit
	)
	_player.yaw += aim_delta.y * recoil_scale
