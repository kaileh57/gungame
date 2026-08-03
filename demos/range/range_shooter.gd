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
##
## MULTIPLAYER. Everybody runs their own whole weapon, always. Trigger, cadence,
## magazine, jam, recoil, muzzle flash and tracer are yours, on your machine, with
## no round trip in them — that is what makes a gun feel like a gun and none of it
## is a decision anybody has to agree with.
##
## What IS a decision is what the round hit. On a client this node does not touch a
## target and does not work a control; it sends the host the line each of its
## pellets went down (`RangeNet.send_shot`) and the host re-traces them, decides,
## and tells everybody. A control the client's round landed on is FLASHED locally
## and nothing else — the prediction — and the authoritative state follows a round
## trip later, so a bench that three people are shooting at once still reads the
## same from all four seats.
##
## On the host every shot is resolved here directly, exactly as it is in
## single-player, bracketed by `RangeNet.set_actor` so that everything the round
## touches on the way through knows whose round it was. That is what makes the
## EQUIP cap hand the gun to the player who shot it.

## The active weapon changed. Carries the spec so a readout can redraw once.
signal weapon_changed(spec: GunSpec)
## A round hit something that was not a target and not a control.
signal missed(at: Vector3)
## A bench control was actuated by gunfire.
signal control_shot(control: DiegeticControl)

const HUD_SCENE: String = "res://ui/hud/combat_hud.tscn"
const RangeNetScript := preload("res://demos/range/range_net.gd")

## Damage that counts as a full-strength press on a diegetic control.
const FULL_POWER_DAMAGE: float = 45.0
## How far a tracer is drawn for a round that hit nothing, metres. Only used for
## the copy other machines see; your own comes off the weapon's own trace.
const MISS_TRACER: float = 260.0
## Pellet impacts held for one shot. A shotgun throws twelve and a launcher none;
## past this the payload is a packet and not a shot.
const MAX_REPORTED: int = 16
## Tracers published per shot. `Weapon.tracer_pellet_limit` is 5 for exactly the
## same reason — past a handful of streaks in one blast nobody can see a sixth —
## and matching it keeps a twelve-pellet shotgun off the wire twelve times a round.
const MAX_TRACERS: int = 5
## Where a spent case leaves the port, in the PORT'S OWN FRAME: out to the right, up, and
## a little back. Rotated into the world at the moment of the shot.
const SHELL_EJECT: Vector3 = Vector3(2.6, 1.7, 0.3)

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
var _spec: GunSpec = null
var _triggered: bool = false
var _net: RangeNetScript = null
var _authority: bool = true
var _me: int = 1
## Where this discharge's pellets landed, and on what. Filled by `_on_hit` while
## the payload is being thrown and flushed by `fired`, which `Weapon` emits last.
var _points: PackedVector3Array = PackedVector3Array()
var _surfaces: PackedInt32Array = PackedInt32Array()
## The trigger, read as EVENTS rather than polled. `Input.is_action_pressed` in a
## 60 Hz physics callback cannot see a click that opened and closed between two
## ticks, and this demo draws at 173 fps — measured before this latch existed,
## fifty sub-frame taps put zero rounds downrange, so the gun only fired if you
## held the button long enough to straddle a tick.
var _trigger: TriggerLatch = TriggerLatch.new()


func _ready() -> void:
	_bind_net()
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
	_weapon.jam.jammed.connect(_on_jammed)
	_weapon.jam.cleared.connect(_on_jam_cleared)

	_holster.weapon_changed.connect(_on_holster_changed)
	_holster.slot_equipped.connect(_on_slot_equipped)

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
	# Cleared before the tick, not after: this frame's payload is thrown inside it
	# and anything still in the list is a projectile from an earlier shot landing.
	_points.clear()
	_surfaces.clear()
	# Everything the round touches inside this tick — a plate scoring, a drum going
	# up, a cap being knocked in — asks `RangeNet.actor()` whose it was, and the
	# answer for the whole of it is: mine.
	if _authority and _net != null:
		_net.set_actor(_me)
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
##
## `mine` is false for somebody else's hit: their number still floats up off the
## plate, because a range with four people on it should look like it, but the mark
## on your crosshair only ever means YOUR round connected.
func report_hit(
	at: Vector3, text: String, kind: StringName, kill: bool, crit: bool, mine: bool = true
) -> void:
	if _hud == null:
		return
	if mine:
		_hud.hit_mark(kill, crit)
	_hud.pop(at, text, kind)


func banner(text: String, seconds: float = 1.6) -> void:
	if _hud != null:
		_hud.banner(text, seconds)


# --- wiring -----------------------------------------------------------------


func _bind_net() -> void:
	_net = RangeNetScript.of(self) as RangeNetScript
	if _net == null:
		return
	_authority = _net.is_authority()
	_me = _net.local_peer()
	_net.shot_seen.connect(_on_shot_seen)
	_net.blast_seen.connect(_on_blast_seen)
	_net.arm_hit.connect(_on_arm_hit)
	_net.roster_changed.connect(_on_roster_changed)


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
##
## `Weapon` emits this LAST, after every pellet of the payload has resolved, which
## is what makes `_points` a complete record of the shot rather than a partial one.
func _on_fired(origin: Vector3, direction: Vector3, _spec_fired: GunSpec) -> void:
	var node: Node3D = _holster.active_node()
	if node != null:
		var eject: Node3D = node.get_node_or_null(^"Eject") as Node3D
		if eject != null:
			# TRANSFORMED BY THE PORT, NOT PASSED RAW. `VfxService.shell` documents its
			# velocity as WORLD-space, and this handed it a constant — so every casing in
			# the game flew the same way along world +X regardless of which way the gun was
			# pointing. Turn round and the brass came out of the receiver sideways.
			VfxService.spawn_shell(eject, eject.global_transform.basis * SHELL_EJECT)
	_report_shot(origin, direction)


## Tell the rest of the session about the round. A client sends it as intent and
## the host answers with what it hit; the host sends it as fact, because on the
## host it already is one.
func _report_shot(origin: Vector3, direction: Vector3) -> void:
	if _net == null or not _net.is_networked():
		return
	var muzzle: Vector3 = _weapon.muzzle_transform().origin
	if not _authority:
		_net.send_shot(origin, muzzle, direction, _points)
		return
	if _points.is_empty():
		_net.publish_shot(_me, muzzle, origin + direction * MISS_TRACER, -1)
		return
	for i: int in mini(_points.size(), MAX_TRACERS):
		_net.publish_shot(_me, muzzle, _points[i], _surfaces[i])


func _on_hit(collider: Object, at: Vector3, _normal: Vector3, damage: float) -> void:
	if _points.size() < MAX_REPORTED:
		_points.append(at)
		_surfaces.append(_weapon.damage.surface_of(collider))
	var node := collider as Node
	if node != null and node.is_in_group(DiegeticControl.GROUP):
		_press_control(node as DiegeticControl, at, damage)
		return
	if node != null and _is_target(node):
		return
	missed.emit(at)


## A round landing on a bench control. On the host that IS the actuation, and
## `RangeNet.actor()` is already this player, so whatever the control does knows
## whose round did it. On a client it is a flash and nothing else: the state is the
## host's to decide, and it arrives a round trip later through `control_state`.
func _press_control(control: DiegeticControl, at: Vector3, damage: float) -> void:
	if control == null:
		return
	if not _authority:
		control.flash()
		return
	if control.shoot(at, clampf(damage / FULL_POWER_DAMAGE, 0.0, 1.0)):
		control_shot.emit(control)


## HOST: a remote player's round arrived on something. Same actuation as a local
## round, down to the debounce, because on the host it is the same kind of event.
func _on_arm_hit(collider: Object, at: Vector3, amount: float) -> void:
	var node := collider as Node
	if node == null or not node.is_in_group(DiegeticControl.GROUP):
		return
	var control := node as DiegeticControl
	if control != null and control.shoot(at, clampf(amount / FULL_POWER_DAMAGE, 0.0, 1.0)):
		control_shot.emit(control)


## Somebody else's round, on its way past. Cosmetic and local on every machine:
## the streak, a little powder at their muzzle, and the spark where it landed.
##
## The impact normal is taken back along the round's own line rather than sent. A
## plate is faced at the firing line and a berm is faced up the lane, so the two
## agree to within a few degrees on everything you actually shoot at here, and it
## is not worth twelve bytes a pellet to be exact about a spark.
func _on_shot_seen(_id: int, from: Vector3, to: Vector3, surface: int) -> void:
	VfxService.spawn_puff(from, 3, 0.26, 0.42, 0.26, false)
	var line: Vector3 = from - to
	if line.length_squared() < 1.0e-4:
		return
	VfxService.spawn_tracer(from, to, 0.0)
	# BRASS IS SYNCED AT SPAWN, NOT SIMULATED ACROSS THE WIRE. Everybody saw their own
	# casings and nobody else's, so a bay with four people shooting had one stream of brass
	# in it. The round already replicates as a line, and that line carries enough to place
	# the ejection: the bore is the direction, and right is bore x up. Each machine then
	# tumbles its own copy, which costs nothing and needs no further traffic — two players
	# watching the same case land a centimetre apart is not a thing anyone can perceive.
	var bore: Vector3 = -line.normalized()
	var right: Vector3 = bore.cross(Vector3.UP)
	if right.length_squared() > 1.0e-6:
		right = right.normalized()
		var vel: Vector3 = (
			right * SHELL_EJECT.x + Vector3.UP * SHELL_EJECT.y + bore * SHELL_EJECT.z
		)
		VfxService.spawn_shell_from(from, vel)
	if surface >= 0:
		VfxService.spawn_impact(to, line.normalized(), surface, 0.8)


func _on_blast_seen(at: Vector3, radius: float) -> void:
	VfxService.spawn_explosion(at, radius)
	VfxService.spawn_puff(at, 24, 1.0, 0.9, 3.0, true)


## A client's peer id is 1 until its handshake lands, so who "I" am is re-read
## whenever the roster moves rather than trusted from `_ready`.
func _on_roster_changed() -> void:
	if _net == null:
		return
	_me = _net.local_peer()
	_authority = _net.is_authority()


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


func _on_jammed() -> void:
	banner("JAM — HOLD R", 2.2)


func _on_jam_cleared() -> void:
	banner("CLEARED", 0.9)
