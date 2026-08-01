class_name AshFlatsGunRig
extends Node
## The trigger. Binds the baked player's holster to a live `Weapon` and points the
## bore down the camera's line.
##
## The holster owns WHERE the gun is; `Weapon` owns WHAT HAPPENS when it goes off.
## Nothing in the shipped systems joins the two — the holster builds geometry and
## the weapon waits to be told — so the join is here, and it is four wires:
##
##   holster -> weapon   a new slot came up, so re-`setup` and re-aim
##   input   -> weapon   fire, reload
##   weapon  -> player   the permanent half of the recoil, straight onto the aim
##   weapon  -> camera   the transient half, into the rig's spring
##   weapon  -> world    a hit that landed on a shootable control actuates it
##
## There is no fifth wire onto the AI noise bus, because this demo has no ears in
## it: no spawner, no patrol, no bodies. Firing is how you work the yard board from
## across the plaza and nothing else.
##
## The ray starts at the CAMERA, not at the muzzle. Every shooter that traces from
## the barrel puts rounds into the wall the player is leaning against while the
## crosshair sits on open ground; the muzzle is the tracer's origin and nothing
## else, which is exactly the split `Weapon.set_rig` was written for.

## The weapon in hand changed. Null when the slot is empty.
signal armed(spec: GunSpec)

## Bullets are allowed to actuate anything in this group — the yard board's lever
## and dial. Matches `DiegeticControl.GROUP` without loading the UI script.
const CONTROL_GROUP: StringName = &"diegetic_control"
## Fraction of a full-strength hit a round delivers to a control. Anything that
## reaches the plate throws the lever; a control is not a health bar.
const CONTROL_POWER: float = 1.0

@export_group("Wiring")
@export var player_path: NodePath = NodePath("..")
@export var holster_path: NodePath = NodePath("../Eye/Holster")
@export var camera_path: NodePath = NodePath("../Eye")

@export_group("Loadout")
## Seed handed to `GunFactory.roll` for the gun you start holding. Roll a new one
## and the whole weapon changes: parts, ballistics, recoil, name.
@export_range(1, 2147483647, 1) var primary_seed: int = 20260728
## Weapon class asked of the factory for the primary. Empty rolls freely.
@export var primary_class: String = "Carbine"
@export_range(1, 2147483647, 1) var sidearm_seed: int = 20260729
@export var sidearm_class: String = "Sidearm"

@export_group("Feel")
## Multiplier on the transient view punch before it reaches the camera's spring.
## The permanent half of the kick is deliberately not scaled here — that half is
## a real change to where you are pointing and is the gun's own number.
@export_range(0.0, 3.0, 0.01) var camera_recoil_scale: float = 1.0
## Degrees of field-of-view punch per radian of view kick.
@export_range(0.0, 40.0, 0.5) var fov_kick_scale: float = 6.0

var _player: PlayerController = null
var _holster: WeaponHolster = null
var _camera: Camera3D = null
var _rig: PlayerCameraRig = null
var _weapon: Weapon = null
var _trigger: bool = false


func _ready() -> void:
	_player = get_node_or_null(player_path) as PlayerController
	_holster = get_node_or_null(holster_path) as WeaponHolster
	_camera = get_node_or_null(camera_path) as Camera3D
	_rig = _camera as PlayerCameraRig
	if _player == null or _holster == null or _camera == null:
		push_error("AshFlatsGunRig: needs the baked player's controller, holster and eye.")
		return
	_weapon = Weapon.new()
	_weapon.name = "Weapon"
	_weapon.self_driven = true
	add_child(_weapon)
	_weapon.recoiled.connect(_on_recoiled)
	_weapon.hit.connect(_on_hit)
	_holster.weapon_changed.connect(_on_weapon_changed)
	_holster.slot_equipped.connect(_on_slot_equipped)
	_holster.roll_into(WeaponHolster.PRIMARY_SLOT, primary_seed, primary_class)
	_holster.roll_into(WeaponHolster.PRIMARY_SLOT + 1, sidearm_seed, sidearm_class)
	_rebind()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion or _blocked():
		return
	if event.is_action_pressed(&"fire"):
		_trigger = true
		_weapon.trigger_down()
	elif event.is_action_released(&"fire"):
		_trigger = false
		_weapon.trigger_up()
	elif event.is_action_pressed(&"reload"):
		_weapon.reload()


func _physics_process(_delta: float) -> void:
	if _weapon == null:
		return
	if _blocked() and _trigger:
		_trigger = false
		_weapon.trigger_up()
	_weapon.set_aim_blend(_player.ads)
	_weapon.set_stance(_player.speed, _player.grounded, _player.crouch_t > 0.5)
	_apply_view_kick()


func weapon() -> Weapon:
	return _weapon


## Roll a fresh primary. The scavenging loop in one call: the gun in your hands is
## a consumable, and this is what replaces it.
func scavenge(seed_value: int, want_class: String = "") -> GunSpec:
	return _holster.roll_into(WeaponHolster.PRIMARY_SLOT, seed_value, want_class)


func _blocked() -> bool:
	return _player.freecam_active or _player.input_suspended or not _holster.is_ready_to_fire()


func _on_slot_equipped(slot: int, _spec: GunSpec) -> void:
	if slot == _holster.active_slot:
		_rebind()


func _on_weapon_changed(_slot: int, _spec: GunSpec) -> void:
	_rebind()


## Point the weapon at whatever is now in the hand. Called on every exchange
## because the muzzle marker belongs to the gun's own node, which is rebuilt.
func _rebind() -> void:
	var spec: GunSpec = _holster.active_spec()
	if spec == null:
		set_physics_process(false)
		armed.emit(null)
		return
	_weapon.setup(spec)
	var gun: Node3D = _holster.active_node()
	var muzzle: Node3D = null if gun == null else gun.get_node_or_null(^"Muzzle") as Node3D
	_weapon.set_rig(_camera, muzzle if muzzle != null else _camera, _player)
	set_physics_process(true)
	armed.emit(spec)


## The permanent half of the kick, and permanent is meant literally: 42 % of every
## shot's climb goes into the player's own look angles and stays there until the
## player pulls it back down. `aim_delta` is (pitch, yaw) in radians, in that
## order — the camera rig takes the same pair in the same order, which is exactly
## why it is easy to hand it them backwards and get a gun that walks sideways.
func _on_recoiled(aim_delta: Vector2) -> void:
	_player.pitch = clampf(_player.pitch + aim_delta.x, -_player.pitch_limit, _player.pitch_limit)
	_player.yaw += aim_delta.y


## The transient half. `GunRecoil` banks view punch on the weapon and the camera's
## spring spends it; draining it here every tick is what keeps the two halves of
## the model from fighting over the same radians.
func _apply_view_kick() -> void:
	if _rig == null:
		return
	var recoil: GunRecoil = _weapon.recoil
	if recoil.view_kick == 0.0 and recoil.view_roll == 0.0:
		return
	var kick: float = recoil.view_kick * camera_recoil_scale
	_rig.apply_recoil_impulse(
		kick, 0.0, recoil.view_roll * camera_recoil_scale, kick * fov_kick_scale
	)
	recoil.view_kick = 0.0
	recoil.view_roll = 0.0


## A round that lands on a shootable control works it. This is the only path by
## which the yard board can be operated from a distance, and it is why the board
## is a board and not a menu.
func _on_hit(collider: Object, position: Vector3, _normal: Vector3, _damage: float) -> void:
	var node := collider as Node
	if node == null or not node.is_in_group(CONTROL_GROUP):
		return
	node.call(&"shoot", position, CONTROL_POWER)
