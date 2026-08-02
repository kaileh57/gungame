class_name ArenaLoadout
extends Node
## What the player is holding and what happens when they pull the trigger.
##
## The baked player prefab ships a body, a camera and a `WeaponHolster` — the
## holster owns where a gun sits and how fast it comes up, and nothing else. The
## mechanism is a `Weapon` node, and somebody has to build one, point it at the
## player's eye, and hand it the trigger. That is this.
##
## The gun is scavenged, which in this world means rolled: three seeds, three
## weapons, swapped with the frozen `weapon_1..3` bindings. Rerolling the primary
## from the control desk is the whole point of a test arena — you come here to
## find out what a particular pile of parts is worth against a particular animal.
##
## Recoil is split the way `Weapon` documents it: the permanent kick is added to
## the player's own look angles, and the transient half is pushed into the camera
## rig's spring so it decays without ever moving where the gun is actually aimed.

## A fresh gun landed in a slot.
signal weapon_rolled(slot: int, spec: GunSpec)
## Something took a round. Forwarded straight off the weapon so the demo can route
## it at the control station without knowing the weapon exists.
signal round_landed(collider: Object, at: Vector3, normal: Vector3, damage: float)

## The receiver plate the magazine count is scratched on. Baked ONCE, by
## `tools/build_range.gd`, and shared rather than duplicated: it is a piece of the
## `ui/hud` module that happens to need a mesh, its script is `ui/hud/ammo_counter.gd`,
## and baking a second identical plate into `demos/arena` would be two things to keep
## in step for no gain.
const AMMO_SCENE: String = "res://demos/range/ammo_counter.tscn"

## Seeds the three starting weapons are rolled from. Changing these changes the
## guns and nothing else, which is exactly what a tuning pass wants.
@export var start_seeds: PackedInt32Array = PackedInt32Array([90210, 31337, 4711])
## Weapon class each slot asks the factory for. Empty means anything.
@export var start_classes: PackedStringArray = PackedStringArray(["", "", "Sidearm"])
## Fraction of a full-power hit a round is worth to a diegetic control. Anything
## that reaches a knob works it; the number exists so a tuning pass can make the
## desk fussier.
@export_range(0.0, 1.0, 0.01) var control_power: float = 1.0
## Reroll the primary with a fresh seed each time, rather than cycling the list.
@export var reroll_uses_clock: bool = true
## Hang the magazine count on the gun. The arena shipped with NO ammunition readout
## of any kind — not on the weapon and not on the HUD — so the only way to know you
## were dry was the click. This is the project's diegetic answer and the range demo
## already bakes the plate; see `AMMO_SCENE`.
@export var show_ammo_plate: bool = true

@export_group("Wiring")
@export var player_path: NodePath = NodePath("../Player")
@export var hud_path: NodePath = NodePath("../CombatHud")

var _player: PlayerController = null
var _holster: WeaponHolster = null
var _eye: Camera3D = null
var _rig: PlayerCameraRig = null
var _weapon: Weapon = null
var _hud: CombatHud = null
var _ammo_plate: AmmoCounter = null
var _reroll_serial: int = 0
var _spec: GunSpec = null
## The trigger, read as EVENTS rather than polled. `Input.is_action_pressed` in a
## 60 Hz physics callback cannot see a click that opened and closed between two
## ticks, and the arena draws at 220 fps — measured before this latch existed,
## fifty sub-frame taps put zero rounds downrange, so the gun only fired if you
## held the button long enough to straddle a tick.
var _trigger: TriggerLatch = TriggerLatch.new()


func _ready() -> void:
	_player = get_node_or_null(player_path) as PlayerController
	if _player == null:
		push_error("ArenaLoadout: player_path does not resolve to a PlayerController.")
		return
	_eye = _player.get_node_or_null(^"Eye") as Camera3D
	_rig = _eye as PlayerCameraRig
	_holster = _player.get_node_or_null(^"Eye/Holster") as WeaponHolster
	_hud = get_node_or_null(hud_path) as CombatHud
	if _holster == null or _eye == null:
		push_error("ArenaLoadout: the baked player has no Eye/Holster.")
		return
	_build_weapon()
	# BOTH signals, and this is not belt-and-braces. `weapon_changed` is emitted from
	# the holster's `_exchange()` — the end of a SWAP — and rolling into an empty slot
	# is not a swap, so the very first gun of the demo never raises it. Connecting only
	# that one leaves `Weapon._spec` null from spawn: `tick()` returns before it reaches
	# the fire control, and the trigger does nothing at all until the player happens to
	# press `2`. `slot_equipped` is the signal that fires when the geometry is built.
	_holster.weapon_changed.connect(_on_weapon_changed)
	_holster.slot_equipped.connect(_on_slot_equipped)
	_mount_ammo_plate()
	if _hud != null:
		_hud.set_camera(_eye)
	for i: int in mini(start_seeds.size(), _holster.slot_count):
		var want: String = start_classes[i] if i < start_classes.size() else ""
		weapon_rolled.emit(i, _holster.roll_into(i, start_seeds[i], want))
	_holster.select(0)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		return
	if _blocked():
		_trigger.clear()
		return
	if event.is_action_pressed(&"fire"):
		_trigger.press()
		return
	if event.is_action_released(&"fire"):
		_trigger.release()
		return
	if event.is_action_pressed(&"reload"):
		_weapon.reload()
	elif event.is_action_released(&"reload"):
		_weapon.cancel_clear()


func _physics_process(_delta: float) -> void:
	if _weapon == null:
		return
	if _blocked():
		_trigger.clear()
		_weapon.trigger_up()
		_weapon.set_aim_blend(0.0)
		return
	_weapon.set_aim_blend(_player.ads)
	_weapon.set_stance(_player.speed, _player.grounded, _player.crouch_t > 0.5)
	if not _holster.is_ready_to_fire():
		_trigger.clear()
	if _trigger.resolve():
		_weapon.trigger_down()
	else:
		_weapon.trigger_up()
	if _hud != null:
		_hud.set_picture(_weapon.effective_spread(), _cycle_fraction(), _eye.fov)


## Roll a new primary. The control desk's reroll button lands here.
func reroll_primary(want_class: String = "") -> GunSpec:
	_reroll_serial += 1
	var seed_value: int = (
		int(Time.get_ticks_usec() & 0x7FFFFFFF)
		if reroll_uses_clock
		else start_seeds[0] + _reroll_serial * 7919
	)
	var spec: GunSpec = _holster.roll_into(WeaponHolster.PRIMARY_SLOT, seed_value, want_class)
	weapon_rolled.emit(WeaponHolster.PRIMARY_SLOT, spec)
	return spec


func weapon() -> Weapon:
	return _weapon


func active_spec() -> GunSpec:
	return null if _holster == null else _holster.active_spec()


## A one-line description of what is in the player's hands, for the arena readout.
func weapon_line() -> String:
	var spec: GunSpec = active_spec()
	if spec == null:
		return "empty hands"
	return "%s  ·  %s  ·  %d rnd" % [spec.weapon_name, spec.tier_name, spec.magazine]


func _build_weapon() -> void:
	_weapon = Weapon.new()
	_weapon.name = "Weapon"
	# The holster and the demo drive this; a self-driven weapon would also tick
	# while the tree is paused behind the pause menu.
	_weapon.self_driven = true
	_weapon.process_mode = Node.PROCESS_MODE_PAUSABLE
	_player.add_child(_weapon)
	_weapon.set_rig(_eye, _eye, _player)
	_weapon.hit.connect(_on_hit)
	_weapon.recoiled.connect(_on_recoiled)
	_weapon.fired.connect(_on_fired)
	_weapon.ammo_changed.connect(_on_ammo_changed)
	_weapon.jam.jammed.connect(_on_jammed)
	_weapon.jam.cleared.connect(_on_jam_cleared)


## The count goes on the receiver, not on the screen. `Hand` is the node
## `WeaponHolster` parents every built weapon to, so a plate hung off it rides the
## swap pose and the ready pose without knowing about either — and it is on the
## VIEWMODEL layer, so the world camera never sees it.
func _mount_ammo_plate() -> void:
	if not show_ammo_plate:
		return
	var packed := ResourceLoader.load(AMMO_SCENE, "PackedScene") as PackedScene
	if packed == null:
		push_error("ArenaLoadout: the ammunition plate is not baked. Re-run build_range.")
		return
	var plate := packed.instantiate() as AmmoCounter
	var hand: Node3D = _holster.get_node_or_null(^"Hand") as Node3D
	if plate == null or hand == null:
		if plate != null:
			plate.free()
		return
	hand.add_child(plate)
	_ammo_plate = plate
	_set_layers(plate, GameLayers.VIEWMODEL)


static func _set_layers(node: Node, layers: int) -> void:
	var visual := node as VisualInstance3D
	if visual != null:
		visual.layers = layers
	for child: Node in node.get_children():
		_set_layers(child, layers)


func _on_ammo_changed(loaded: int, _reserve: int) -> void:
	if _ammo_plate != null:
		_ammo_plate.set_ammo(loaded, _weapon.ammo().capacity())


func _on_jammed() -> void:
	if _ammo_plate != null:
		_ammo_plate.set_jammed(true)
	if _hud != null:
		_hud.banner("JAM — HOLD R", 2.2)


func _on_jam_cleared() -> void:
	if _ammo_plate != null:
		_ammo_plate.set_jammed(false)


## The geometry for a slot was built. The muzzle marker exists from this moment, and
## for the first gun of the demo this is the only notification there is.
func _on_slot_equipped(slot: int, spec: GunSpec) -> void:
	if slot == _holster.active_slot:
		_adopt(spec)


## A swap finished and a different gun is up.
func _on_weapon_changed(_slot: int, spec: GunSpec) -> void:
	_adopt(spec)


## The muzzle moves with the gun, so the tracer and the flash have to be re-bound
## every time the geometry is exchanged rather than once at load. Rebuilding the
## mechanism is the expensive half and also reloads the magazine, so it only runs
## when the gun genuinely changed — a re-bind must never refill a half-spent mag.
func _adopt(spec: GunSpec) -> void:
	if spec == null:
		return
	if spec != _spec:
		_spec = spec
		_weapon.setup(spec)
	var node: Node3D = _holster.active_node()
	var muzzle: Node3D = null if node == null else node.get_node_or_null(^"Muzzle") as Node3D
	_weapon.set_rig(_eye, muzzle if muzzle != null else _eye, _player)
	if _ammo_plate != null:
		# A swap does not raise `ammo_changed` — the magazine did not move, the gun
		# did — so the plate has to be re-read here or it shows the last gun's count.
		_ammo_plate.set_ammo(_weapon.ammo().loaded(), _weapon.ammo().capacity())


func _on_hit(collider: Object, at: Vector3, normal: Vector3, damage: float) -> void:
	round_landed.emit(collider, at, normal, damage)


## The permanent half of the kick moves where the player is looking; the camera
## rig's spring takes the transient half so the two never fight.
func _on_recoiled(aim_delta: Vector2) -> void:
	_player.pitch = clampf(_player.pitch + aim_delta.x, -_player.pitch_limit, _player.pitch_limit)
	_player.yaw = wrapf(_player.yaw + aim_delta.y, -PI, PI)
	if _rig != null:
		_rig.apply_recoil_impulse(aim_delta.x * 2.4, aim_delta.y * 1.8, aim_delta.y * 0.9, 1.6)


## Every shot is a noise the whole compound gets to hear, filed at the muzzle with
## the round's real energy behind it.
func _on_fired(origin: Vector3, _direction: Vector3, spec: GunSpec) -> void:
	AINoiseBus.emit_gunshot(origin, float(spec.muzzle_energy), Factions.PLAYER, -1)


## How far through working the action the gun is, 0 to 1. The reticle opens with
## it, so a bolt gun's crosshair blooms for the whole throw and a straight-blowback
## machine pistol's barely moves.
func _cycle_fraction() -> float:
	if _weapon.reload_action.is_busy():
		return _weapon.reload_action.progress()
	return 1.0


func _blocked() -> bool:
	return _player.freecam_active or _player.input_suspended or SceneRouter.is_paused()
