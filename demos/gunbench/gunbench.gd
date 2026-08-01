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
## has to be told — that F8 is the free camera and Escape is the way out — is painted on
## a board bolted to the floor by the door.
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

## Dial position 0 on both filters: take whatever the tables give.
const FILTER_ANY: String = "ANY"

## Hand slot the bench equips into. The holster's primary.
const HAND_SLOT: int = 0

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
## The weapon actually in your hands. Kept here rather than read back off the holster
## because the holster only owns it from the moment the swap exchanges the geometry,
## and the middle card has to be right before that.
var _hand_spec: GunSpec = null
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
	_build_hands()
	_main.explode_metres = explode_metres
	_rival.explode_metres = explode_metres
	_collect_controls()
	_collect_pegs()
	_wire_weapon()
	if not PartLibrary.is_loaded():
		push_error("Gunbench: the part library is not loaded. %s" % PartLibrary.load_error)
		_refuse_controls()
		return
	_fill_rack()
	_set_stand(_main, _roll())
	# The rival stand starts loaded too. An empty second stand and a delta card reading
	# "PUT A WEAPON ON EACH STAND" is a correct first frame and a useless one; two
	# weapons and a filled comparison is what the bench is for.
	_set_stand(_rival, GunFactory.roll(_next_seed()))
	# And a THIRD weapon straight into your hands, which is what makes the grab stations
	# mean anything on the first press: with the stands' own weapons duplicated into the
	# hands there is nothing to trade and the first press looks like it did nothing.
	_take(GunFactory.roll(_next_seed()))
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


## The weapon in your hands. This is the one the middle card reads out and the one the
## trigger fires; it is on neither stand.
func hand_spec() -> GunSpec:
	return _hand_spec


## Roll one weapon through the console's current filters and put it on the main stand.
func roll_now() -> void:
	_set_stand(_main, _roll())


## Take the weapon off `stand` and put what you were holding in its place. This is what
## a grab button does, and it is the whole trade: the stand you took from is never left
## empty and the weapon you were carrying is never destroyed.
func grab_from(stand: GunbenchStand) -> bool:
	if stand == null:
		return false
	var taken: GunSpec = stand.spec()
	var held: GunSpec = _hand_spec
	if taken == null and held == null:
		return false
	_set_stand(stand, held)
	_take(taken)
	return true


## Reroll the six hooks on the wall, and nothing else. Neither stand nor your hands are
## touched: `verify_gunbench` asserts exactly that.
func roll_rack() -> void:
	_fill_rack()


# --- setup --------------------------------------------------------------------


func _register_demo() -> void:
	if SceneRouter.has_demo(DEMO_ID):
		return
	SceneRouter.register_demo(DEMO_ID, DEMO_TITLE, scene_file_path, DEMO_BLURB)


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


## Put `spec` in your hands. The holster stows what is up at the OLD weapon's weight
## and only exchanges the geometry once it is out of sight, which is what makes the
## grab read as a hand movement rather than a pop; the middle card follows at the
## exchange, through `_on_slot_equipped`.
func _take(spec: GunSpec) -> void:
	_hand_spec = spec
	_holster.equip(HAND_SLOT, spec)
	_sync_grab(_main)
	_sync_grab(_rival)


## The two cards that read out your own hands: the big middle one and the cartridge
## under it. Driven from `slot_equipped`, so they change at the instant the geometry
## does and never describe a weapon that is still on its way up.
func _set_hand_cards(spec: GunSpec) -> void:
	_card_hands.set_title(GunbenchCards.title(spec))
	_card_hands.set_lines(GunbenchCards.stat_lines(spec))
	_card_hands.set_bars(
		GunbenchCards.BAR_LABELS, GunbenchCards.stat_bars(spec), GunbenchCards.stat_bar_colors(spec)
	)
	_card_hands.accent = spec.tier_color if spec != null else UiStyle.GOLD
	_card_cartridge.set_title("CARTRIDGE")
	_card_cartridge.set_lines(GunbenchCards.cartridge_lines(spec))
	_note(spec)


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
	if spec == null:
		DebugHUD.note(&"gunbench", "gunbench  no weapon")
		return
	DebugHUD.note(
		&"gunbench",
		(
			"gunbench  in hand %s  %s  seed %d  fit %.3f"
			% [spec.weapon_name, String(spec.tier_name), spec.roll_seed, spec.fit_error]
		)
	)


# --- input --------------------------------------------------------------------


## The hands. `eye_path` is deliberately left empty so the rays come from whatever
## camera is live — the eye, or the freecam once F8 has taken over — which is how
## the console stays operable from the free camera.
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


func _on_control_pressed(control: DiegeticControl) -> void:
	match control.control_id:
		ID_ROLL:
			_set_stand(_main, _roll())
		ID_COMPARE:
			_set_stand(_rival, _main.spec())
		ID_GRAB_MAIN:
			grab_from(_main)
		ID_GRAB_RIVAL:
			grab_from(_rival)
		ID_ROLL_RACK:
			roll_rack()
		ID_STRIP:
			var on: bool = (control as DiegeticLever).is_on()
			_main.set_exploded(on)
			_rival.set_exploded(on)


## A filter dial moved. Detent 0 on both is ANY, so index 1 is the first real entry —
## the class list is `GunTables.CLASS_MIX` in table order, the tier list is
## `Palette.GUN_TIER_NAMES` in rank order, and neither is retyped here.
func _on_filter_changed(index: int, _text: String, dial: DiegeticDial) -> void:
	if dial.control_id == ID_CLASS:
		_class_filter = "" if index <= 0 else String(GunTables.CLASS_MIX[index - 1][0])
	elif dial.control_id == ID_TIER:
		_tier_filter = index - 1
	else:
		return
	_set_stand(_main, _roll())


## The rack and stand A trade. Taking a gun off a peg puts stand A's weapon back on
## that hook, so the wall stays full and nothing is ever thrown away. The rack does not
## reach into your hands: a peg and a grab station are two different movements.
func _on_peg_pressed(peg: GunbenchPeg) -> void:
	var taken: GunSpec = peg.spec()
	if taken == null:
		return
	peg.set_spec(_main.spec())
	_set_stand(_main, taken)


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
