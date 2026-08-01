class_name RangeShooter
extends Node3D
## The join between the baked player and the gun systems: trigger, reload, kick,
## sight picture, and the bullet that lands on a bench control.
##
## The player scene ships a `WeaponHolster` — what you are carrying and where it
## sits — but nothing that pulls a trigger, because a holster has no opinion about
## firing and `Weapon` has no opinion about who owns it. This node is the opinion.
## It lives in the demo rather than in `res://systems/` because a demo decides what
## its own input means; a menu that wants a gun on a stand wants none of this.
##
## THE DIEGETIC PATH. Every bench control is a `StaticBody3D` in
## `DiegeticControl.GROUP` on the PROP layer, which is inside `MASK_BULLET`, so a
## round hits one exactly the way it hits a plate. `Weapon.hit` hands over the
## collider; if it is a control, it gets shot. Power is the round's damage against
## `full_power_damage`, so a derringer still works the buttons and a launcher does
## not work them nine times.

## The active weapon changed. Carries the spec so a readout can redraw once.
signal weapon_changed(spec: GunSpec)
## A round hit something that was not a target and not a control.
signal missed(at: Vector3)
## A bench control was actuated by gunfire.
signal control_shot(control: DiegeticControl)

const HUD_SCENE: String = "res://ui/hud/combat_hud.tscn"
const AMMO_SCENE: String = "res://demos/range/ammo_counter.tscn"

## Damage that counts as a full-strength press on a diegetic control.
const FULL_POWER_DAMAGE: float = 45.0

@export var player_path: NodePath = NodePath("../Player")
## Reserve ammunition is unlimited here. It is a range; you are not carrying it.
@export var infinite_reserve: bool = true
## Draw the screen sight picture, hit marks and damage pops. The reference HUD's
## crosshair is a sight picture rather than chrome, which is why it survives the
## project's diegetic rule; everything else it used to draw has moved in-world.
@export var show_sight_picture: bool = true
## How hard the gun shoves the view, on top of the permanent aim change.
@export_range(0.0, 3.0, 0.05) var view_kick_scale: float = 1.0

var _player: PlayerController = null
var _holster: WeaponHolster = null
var _eye: Camera3D = null
var _camera_rig: PlayerCameraRig = null
var _weapon: Weapon = null
var _hud: CombatHud = null
var _ammo_counter: AmmoCounter = null
var _spec: GunSpec = null
var _triggered: bool = false
## The trigger, read as EVENTS rather than polled. `Input.is_action_pressed` in a
## 60 Hz physics callback cannot see a click that opened and closed between two
## ticks, and this demo draws at 173 fps — measured before this latch existed,
## fifty sub-frame taps put zero rounds downrange, so the gun only fired if you
## held the button long enough to straddle a tick.
var _trigger: TriggerLatch = TriggerLatch.new()


func _ready() -> void:
	_player = get_node_or_null(player_path) as PlayerController
	if _player == null:
		push_error("RangeShooter: no PlayerController at %s." % player_path)
		set_physics_process(false)
		return
	_eye = _player.get_node_or_null(^"Eye") as Camera3D
	_camera_rig = _eye as PlayerCameraRig
	_holster = _player.get_node_or_null(^"Eye/Holster") as WeaponHolster
	if _eye == null or _holster == null:
		push_error("RangeShooter: the baked player is missing its Eye or Holster.")
		set_physics_process(false)
		return

	_weapon = Weapon.new()
	_weapon.name = "Weapon"
	_weapon.self_driven = false
	_weapon.infinite_reserve = infinite_reserve
	add_child(_weapon)
	_weapon.fired.connect(_on_fired)
	_weapon.hit.connect(_on_hit)
	_weapon.recoiled.connect(_on_recoiled)
	_weapon.ammo_changed.connect(_on_ammo_changed)
	_weapon.jam.jammed.connect(_on_jammed)
	_weapon.jam.cleared.connect(_on_jam_cleared)

	_holster.weapon_changed.connect(_on_holster_changed)
	_holster.slot_equipped.connect(_on_slot_equipped)

	_mount_ammo_counter()
	if show_sight_picture:
		_mount_hud()
	# The world's floor height, so spent brass and blast debris settle on the pad
	# instead of on whatever y the VFX hub guessed.
	VfxService.set_ground_y(0.30)


func _physics_process(delta: float) -> void:
	if _weapon == null or _player == null:
		return
	var live: bool = not _player.freecam_active and not _player.input_suspended
	var state: PlayerState = _player.state
	_weapon.set_aim_blend(state.ads)
	_weapon.set_stance(state.planar_speed, state.grounded, state.crouch_t > 0.5)
	# A press made against a closed gate — freecam, a menu, a swap in progress — is
	# forgotten rather than banked, so nothing goes off the instant the gate opens.
	if not (live and _holster.is_ready_to_fire()):
		_trigger.clear()
	var want: bool = _trigger.resolve()
	if want != _triggered:
		_triggered = want
		if want:
			_weapon.trigger_down()
		else:
			_weapon.trigger_up()
	_weapon.tick(delta)
	_apply_view_kick(delta)
	_draw_picture()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion or _weapon == null or _player == null:
		return
	if _player.freecam_active or _player.input_suspended:
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
		# Working a jam free is a held action: let go and the gun stays jammed,
		# which is the reference's behaviour and the reason the banner says HOLD.
		_weapon.cancel_clear()


## The weapon the player is holding, for the bench and the debug overlay.
func active_spec() -> GunSpec:
	return _spec


func weapon() -> Weapon:
	return _weapon


## `name#seed`, which is how the paper target decides whether the group on the
## board is still the same gun's group.
func weapon_tag() -> String:
	if _spec == null:
		return "?"
	return "%s#%d" % [_spec.weapon_name, _spec.roll_seed]


func camera() -> Camera3D:
	return _eye


func hud() -> CombatHud:
	return _hud


## Draw a hit mark and a damage pop. The scoreboard calls this so pops read the
## same whether the points came from a plate or from a barrel going up.
func report_hit(at: Vector3, text: String, kind: StringName, kill: bool, crit: bool) -> void:
	if _hud == null:
		return
	_hud.hit_mark(kill, crit)
	_hud.pop(at, text, kind)


func banner(text: String, seconds: float = 1.6) -> void:
	if _hud != null:
		_hud.banner(text, seconds)


# --- wiring -----------------------------------------------------------------


func _mount_hud() -> void:
	var packed := ResourceLoader.load(HUD_SCENE, "PackedScene") as PackedScene
	if packed == null:
		push_warning("RangeShooter: %s is missing; running without a sight picture." % HUD_SCENE)
		return
	_hud = packed.instantiate() as CombatHud
	if _hud == null:
		return
	add_child(_hud)
	_hud.set_camera(_eye)
	_hud.set_health(1.0)


## The magazine count lives on the gun, per the diegetic rule. `Hand` is the node
## `WeaponHolster` parents every built weapon to, so a counter hung off it rides
## the swap pose and the ready pose without knowing anything about either.
func _mount_ammo_counter() -> void:
	var packed := ResourceLoader.load(AMMO_SCENE, "PackedScene") as PackedScene
	if packed == null:
		return
	_ammo_counter = packed.instantiate() as AmmoCounter
	if _ammo_counter == null:
		return
	var hand: Node3D = _holster.get_node_or_null(^"Hand") as Node3D
	if hand == null:
		_ammo_counter.free()
		_ammo_counter = null
		return
	hand.add_child(_ammo_counter)
	_set_layers(_ammo_counter, GameLayers.VIEWMODEL)


func _set_layers(node: Node, layers: int) -> void:
	var visual := node as VisualInstance3D
	if visual != null:
		visual.layers = layers
	for child: Node in node.get_children():
		_set_layers(child, layers)


func _on_slot_equipped(slot: int, spec: GunSpec) -> void:
	if slot == _holster.active_slot:
		_adopt(spec)


func _on_holster_changed(_slot: int, spec: GunSpec) -> void:
	_adopt(spec)


## `slot_equipped` fires when the geometry is built and `weapon_changed` when it
## is actually up, and the muzzle marker only exists after the first of those.
## The rig is therefore re-bound on both, while the expensive half — rebuilding
## the mechanism — only runs when the weapon really changed.
func _adopt(spec: GunSpec) -> void:
	if spec == null:
		return
	var fresh: bool = spec != _spec
	if fresh:
		_spec = spec
		_weapon.setup(spec)
		_triggered = false
	_weapon.set_rig(_eye, _muzzle_of(), _player)
	if _ammo_counter != null:
		_ammo_counter.set_ammo(_weapon.ammo().loaded(), _weapon.ammo().capacity())
	if fresh:
		weapon_changed.emit(spec)


## The `Muzzle` marker the factory puts on every assembly, so the flash and the
## tracer leave the barrel rather than the bridge of your nose. Falls back to the
## eye when the holster has not finished building.
func _muzzle_of() -> Node3D:
	var node: Node3D = _holster.active_node()
	if node == null:
		return _eye
	var muzzle: Node3D = node.get_node_or_null(^"Muzzle") as Node3D
	return muzzle if muzzle != null else node


## Brass out of the ejection port. Belt-fed and break-action guns throw it just
## the same; the reference makes no distinction and neither does the port marker.
func _on_fired(_origin: Vector3, _direction: Vector3, _spec: GunSpec) -> void:
	var node: Node3D = _holster.active_node()
	if node == null:
		return
	var eject: Node3D = node.get_node_or_null(^"Eject") as Node3D
	if eject != null:
		VfxService.spawn_shell(eject, Vector3(2.6, 1.7, 0.3))


func _on_hit(collider: Object, at: Vector3, _normal: Vector3, damage: float) -> void:
	var node := collider as Node
	if node != null and node.is_in_group(DiegeticControl.GROUP):
		var control := node as DiegeticControl
		if control != null and control.shoot(at, clampf(damage / FULL_POWER_DAMAGE, 0.0, 1.0)):
			control_shot.emit(control)
		return
	if node != null and _is_target(node):
		return
	missed.emit(at)


func _is_target(node: Node) -> bool:
	var walk: Node = node
	var depth: int = 0
	while walk != null and depth < 4:
		if walk.is_in_group(RangeTarget.GROUP):
			return true
		walk = walk.get_parent()
		depth += 1
	return false


func _on_recoiled(aim_delta: Vector2) -> void:
	# The permanent half of the kick is a real change to where the player is
	# looking; they have to pull it back down themselves. Anything that moved the
	# camera without moving the player's aim would be a lie the next shot exposes.
	_player.pitch = clampf(_player.pitch + aim_delta.x, -_player.pitch_limit, _player.pitch_limit)
	_player.yaw += aim_delta.y


func _apply_view_kick(_delta: float) -> void:
	if _camera_rig == null:
		return
	var recoil: GunRecoil = _weapon.recoil
	if recoil.view_kick == 0.0 and recoil.view_roll == 0.0:
		return
	_camera_rig.apply_recoil_impulse(
		recoil.view_kick * view_kick_scale,
		0.0,
		recoil.view_roll * view_kick_scale,
		recoil.view_kick * view_kick_scale * 6.0
	)
	recoil.view_kick = 0.0
	recoil.view_roll = 0.0


func _draw_picture() -> void:
	if _hud == null or _eye == null:
		return
	var cycle: float = 1.0
	if _weapon.reload_action.is_busy():
		cycle = _weapon.reload_action.progress()
	_hud.set_picture(_weapon.effective_spread(), cycle, _eye.fov)


func _on_ammo_changed(loaded: int, _reserve: int) -> void:
	if _ammo_counter != null:
		_ammo_counter.set_ammo(loaded, _weapon.ammo().capacity())


func _on_jammed() -> void:
	if _ammo_counter != null:
		_ammo_counter.set_jammed(true)
	banner("JAM — HOLD R", 2.2)


func _on_jam_cleared() -> void:
	if _ammo_counter != null:
		_ammo_counter.set_jammed(false)
	banner("CLEARED", 0.9)
