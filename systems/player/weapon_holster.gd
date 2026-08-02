class_name WeaponHolster
extends Node3D
## What the player is carrying, where it sits in the hands, and how it moves.
##
## Slot 0 is the PRIMARY — the gun you replace constantly, because in this world a gun
## is a consumable. The remaining slots are secondaries you keep. That asymmetry is the
## whole loadout design, so it is a named constant rather than a convention.
##
## Swap timing is driven by weight and nothing else. `GunSpec.mass` is derived from hull
## volume and donor material density, so a scrap-welded LMG genuinely takes longer to
## bring up than a machine pistol, and the difference is felt rather than read. There is
## no swap animation resource: the pose is two poses and a curve, which is both cheaper
## and easier to tune than a clip per weapon that nobody would author.
##
## THE POSE IS NOT A CONSTANT. It used to be: a fixed hand offset and a fixed scale,
## applied to every weapon in the library regardless of how long or how tall it was.
## That is what put a 0.70 m assembly 0.32 m from the eye with its butt-plate four
## centimetres BEHIND the near plane, and a gun sliced open by the near plane reads as a
## black slab across the corner of the screen rather than as a gun. The pose is now
## solved per weapon by `GunHandPose` from the assembly's real bounds and its real sight
## — the same resource `res://tools/build_gun_cache.gd` asserts the ADS sight line
## against, so what you see is what the bake proved.
##
## AIMING IS NOT THE SAME AS ALIGNING A POINT. Putting the sight on the view axis was
## exact and it still left the crosshair inside the weapon on 78 of 111 rolled guns,
## because these parts are solid slabs with no aperture and the sight datum for a scope
## is the middle of the tube. `GunHandPose.ads_clear_degrees` now derives an EYE LINE
## from the assembled part boxes instead, so the whole weapon passes below your aim
## whatever it is built out of. `res://tools/verify_ads_occlusion.gd` measures it by
## casting rays from the eye and counting the ones that hit the gun.
##
## This node owns WHICH weapon is up, WHEN it is up, and the render pass its geometry
## belongs to. `GunHandPose` owns where the gun sits and how it moves; `GunFactory` owns
## the geometry. The hierarchy those three meet in is fixed:
##
##   Holster                 <- eye-relative, identity
##     Hand      (Node3D)    <- posed in METRES: position and rotation only, so anything
##                              a demo hangs here (an ammo counter, a wrist strap) is
##                              authored at world scale and rides the pose
##       Lift    (Node3D)    <- the 0.30 model-unit lift and the whole model-unit scale
##         Gun   (Node3D)    <- `GunFactory.build_node`, left in model units

## The gun's node has been built and parented into `slot`. `spec` may be null on clear.
signal slot_equipped(slot: int, spec: GunSpec)
## A swap began. `seconds` is the whole stow-plus-draw, for a HUD that wants to show it.
signal swap_started(from_slot: int, to_slot: int, seconds: float)
## The new weapon is fully up and ready to fire.
signal swap_finished(slot: int)
## The active slot changed. Fires at the moment the geometry is exchanged, mid-swap.
signal weapon_changed(slot: int, spec: GunSpec)

## The slot that gets overwritten by whatever you scavenge.
const PRIMARY_SLOT: int = 0

const HAND_NAME: StringName = &"Hand"
const LIFT_NAME: StringName = &"Lift"

## Slots carried. Three matches the frozen `weapon_1`..`weapon_3` bindings.
@export_range(1, 6, 1) var slot_count: int = 3
## Where the gun sits and how it moves. Left null a private instance is built, which is
## what every shipped demo uses; assign one to tune a hand without touching this script.
@export var hand_pose: GunHandPose = null

@export_group("Swap timing")
## Seconds to stow, before weight. Weight adds `stow_per_kg` on top.
@export_range(0.0, 1.0, 0.005) var stow_base: float = 0.09
@export_range(0.0, 0.3, 0.001) var stow_per_kg: float = 0.035
@export_range(0.02, 1.0, 0.005) var stow_min: float = 0.08
@export_range(0.05, 2.0, 0.005) var stow_max: float = 0.45
@export_range(0.0, 1.0, 0.005) var draw_base: float = 0.13
@export_range(0.0, 0.3, 0.001) var draw_per_kg: float = 0.055
@export_range(0.02, 1.0, 0.005) var draw_min: float = 0.12
@export_range(0.05, 2.0, 0.005) var draw_max: float = 0.70
## Stow curve exponent. Above 1 the gun leaves slowly then whips down.
@export_range(0.3, 4.0, 0.05) var stow_ease: float = 1.6
## Draw curve exponent. Below 1 the gun snaps up then settles.
@export_range(0.3, 4.0, 0.05) var draw_ease: float = 0.55

@export_group("Sights")
## Forwarded to `GunAttachPoints` through the pose solve. How far above the receiver's
## top rail the notch of a set of irons sits, in model units.
@export_range(0.0, 1.0, 0.005) var iron_sight_height: float = 0.10
## How far below the top of a fitted sight part the sight picture is, as a fraction of
## that part's height.
@export_range(0.0, 0.9, 0.01) var sight_notch: float = 0.25

@export_group("Viewmodel")
## Visual layers the built gun is put on. The world camera culls `VIEWMODEL` and the
## viewmodel pass renders only it, which is what keeps the muzzle out of the wall you
## are leaning on. Set this to `WORLD` to see the gun in the ordinary pass instead —
## useful when debugging fit, useless in play.
@export_flags_3d_render var render_layers: int = GameLayers.VIEWMODEL
## A held gun casting a shadow means a gun-shaped shadow sliding across the ground in
## front of you from a mesh the world camera cannot see. Off is the only correct value
## in play; it is a knob because a display stand wants the opposite.
@export var cast_shadows: bool = false
## Hang the magazine count on the gun.
##
## THE READOUT BELONGS TO THE HOLSTER, NOT TO A DEMO. It used to be mounted by each
## level that wanted one, which meant exactly two of them had it — the range and the
## arena — and everywhere else the only way to know you were dry was the click. The
## holster is the one node that knows what weapon is up, when it is swapping and where
## the hands are, so mounting it here is what gives every armed level the same readout
## with the same wiring. Off is for a display stand, which has a gun but no shooter.
@export var show_ammo_counter: bool = true

@export_group("Wiring")
## Optional. When set, freecam and suspended input silence the hotkeys, and the walk
## bob, sprint lower and ADS blend are read from the player every frame.
@export var player_path: NodePath = NodePath()
@export var handle_input: bool = true
## Adopt the `Weapon` that has been rigged to this holster's muzzle, so the per-shot
## punch, the reload arc and the jam roll play without a demo wiring them by hand. The
## test is exact rather than a name match: the weapon whose `muzzle_node()` sits inside
## this holster is this holster's weapon and no other can be.
@export var auto_bind_weapon: bool = true

## Which slot is up. Stays pointed at the OLD slot until the geometry is exchanged.
var active_slot: int = 0

var _player: PlayerController = null
var _specs: Array[GunSpec] = []
var _nodes: Array[Node3D] = []
var _dirty: Array[bool] = []
var _slot_actions: Array[StringName] = []
var _hand: Node3D = null
var _lift: Node3D = null
var _weapon: Weapon = null
var _ammo: AmmoCounter = null
var _rescan: bool = true
## 0 fully up, 1 fully stowed.
var _down: float = 0.0
## Where `_down` was when the current phase started, so an interrupted swap continues
## from the pose the gun is actually in rather than snapping back to the curve.
var _down_from: float = 0.0
var _phase: int = 0
var _phase_t: float = 0.0
var _phase_dur: float = 0.0
var _pending_slot: int = -1


func _ready() -> void:
	if hand_pose == null:
		hand_pose = GunHandPose.new()
	_specs.resize(slot_count)
	_nodes.resize(slot_count)
	_dirty.resize(slot_count)
	for i: int in slot_count:
		_slot_actions.append(StringName("weapon_%d" % (i + 1)))
	active_slot = clampi(active_slot, 0, slot_count - 1)
	_player = get_node_or_null(player_path) as PlayerController
	_hand = _child(self, HAND_NAME)
	# The solve composes its Euler triple in XYZ, and its ADS assertions are made in
	# that order. A hand left on Godot's YXZ default would land the bore somewhere the
	# bake never checked.
	_hand.rotation_order = EULER_ORDER_XYZ
	_lift = _child(_hand, LIFT_NAME)
	_mount_ammo_counter()
	# The gun is posed from where the player ended up this frame, so it has to run after
	# the body and the camera rig have.
	process_priority = 100
	_apply_pose(0.0)


func _unhandled_input(event: InputEvent) -> void:
	# Mouse motion arrives here dozens of times a frame and can never be a hotkey.
	if event is InputEventMouseMotion or not handle_input or _input_blocked():
		return
	if event.is_action_pressed(&"weapon_next"):
		next_weapon()
		return
	if event.is_action_pressed(&"weapon_prev"):
		prev_weapon()
		return
	for i: int in _slot_actions.size():
		if InputMap.has_action(_slot_actions[i]) and event.is_action_pressed(_slot_actions[i]):
			select(i)
			return


func _process(delta: float) -> void:
	if _weapon == null and auto_bind_weapon and _rescan:
		_rescan = false
		bind_weapon(_rigged_weapon())
	_read_player()
	# One clamped delta for the swap and the animation both, so a hitch cannot
	# fast-forward one of them past the other.
	var dt: float = hand_pose.advance(delta)
	_advance_swap(dt)
	_apply_pose(_ads_amount())
	_tick_clear_ring()


## Build `spec` into `slot` and keep it. Equipping the slot that is currently up plays a
## full swap so the exchange is never a pop; equipping any other slot is silent.
func equip(slot: int, spec: GunSpec) -> void:
	if slot < 0 or slot >= slot_count:
		push_error("WeaponHolster: slot %d is out of range." % slot)
		return
	# Replacing what is in your hands stows the old one first, at the OLD weight, and
	# only exchanges the geometry once it is out of sight.
	if slot == active_slot and _nodes[slot] != null:
		_begin_swap(slot, true)
		_specs[slot] = spec
		_dirty[slot] = true
		return
	_specs[slot] = spec
	_build(slot)
	if slot == active_slot:
		_show_only(slot)
		_configure_pose()


## Roll a fresh gun straight into a slot. The seed decides which five parts, nothing
## else; `want_class` is passed through to `GunFactory.roll` unchanged.
func roll_into(slot: int, seed: int, want_class: String = "") -> GunSpec:
	var spec: GunSpec = GunFactory.roll(seed, want_class)
	equip(slot, spec)
	return spec


## Bring `slot` up. Returns false when it is already up or holds nothing.
func select(slot: int) -> bool:
	if slot < 0 or slot >= slot_count or _specs[slot] == null:
		return false
	if slot == active_slot and _phase == 0:
		return false
	if _pending_slot == slot and _phase == 1:
		return false
	_begin_swap(slot, false)
	return true


## Next slot that actually holds something, wrapping. Cheap enough to spam on a wheel.
func next_weapon() -> bool:
	return select(_step_slot(1))


func prev_weapon() -> bool:
	return select(_step_slot(-1))


func spec_at(slot: int) -> GunSpec:
	if slot < 0 or slot >= slot_count:
		return null
	return _specs[slot]


func node_at(slot: int) -> Node3D:
	if slot < 0 or slot >= slot_count:
		return null
	return _nodes[slot]


func active_spec() -> GunSpec:
	return spec_at(active_slot)


func active_node() -> Node3D:
	return node_at(active_slot)


func is_swapping() -> bool:
	return _phase != 0


## True only when the active weapon is fully up. Fire control should gate on this.
func is_ready_to_fire() -> bool:
	return _phase == 0 and _specs[active_slot] != null


func clear_slot(slot: int) -> void:
	if slot < 0 or slot >= slot_count:
		return
	_specs[slot] = null
	_build(slot)
	if slot == active_slot:
		_configure_pose()


func stow_seconds(spec: GunSpec) -> float:
	var mass: float = 0.0 if spec == null else spec.mass
	return clampf(stow_base + mass * stow_per_kg, stow_min, stow_max)


func draw_seconds(spec: GunSpec) -> float:
	var mass: float = 0.0 if spec == null else spec.mass
	return clampf(draw_base + mass * draw_per_kg, draw_min, draw_max)


## Whole stow-plus-draw for swapping from what is up to `slot`.
func swap_seconds(slot: int) -> float:
	return stow_seconds(active_spec()) + draw_seconds(spec_at(slot))


func set_input_enabled(value: bool) -> void:
	handle_input = value


## Adopt a live `Weapon`, so its punch drives the model and its reload and jam arcs
## play. Passing null releases the current one and hands the punch back to the pose's
## private `GunRecoil`, which is what makes a bench with no weapon still recoil.
##
## The animation itself is not re-exported here: `hand_pose` is public, and a display
## stand or a cutscene with no weapon at all drives it directly with
## `hand_pose.fire_shot()`, `begin_reload()`, `set_jammed()` and `begin_jam_clear()`.
## One authority for the animation beats a forwarding layer that can drift from it.
func bind_weapon(weapon: Weapon) -> void:
	if weapon == _weapon:
		return
	_disconnect_weapon()
	_weapon = weapon
	if _weapon == null:
		hand_pose.unbind_recoil()
		return
	_weapon.fired.connect(_on_weapon_fired)
	_weapon.state_changed.connect(_on_weapon_state)
	_weapon.ammo_changed.connect(_on_weapon_ammo)
	_weapon.tree_exiting.connect(_on_weapon_leaving)
	if _weapon.jam != null:
		_weapon.jam.jammed.connect(_on_weapon_jammed)
		_weapon.jam.cleared.connect(_on_weapon_unjammed)
	if _weapon.recoil != null:
		hand_pose.bind_recoil(_weapon.recoil)
	# The magazine was filled by `Weapon.setup`, which every demo calls BEFORE the
	# holster has found the weapon to bind — so the first `ammo_changed` of a gun's
	# life is always emitted into nothing. Read the count once here or the plate shows
	# 0/0 until the player happens to fire.
	_push_ammo()


func _begin_swap(slot: int, same_slot: bool) -> void:
	var from: int = active_slot
	var total: float = swap_seconds(slot)
	_pending_slot = slot
	if _phase != 1:
		# Starting, or interrupting a draw: stow from wherever the gun currently is, so
		# a fast double-tap never snaps the model back to the top of the curve.
		_down_from = _down
		_phase_dur = maxf(0.01, stow_seconds(_specs[from]) * (1.0 - _down))
		_phase_t = 0.0
	_phase = 1
	swap_started.emit(from, from if same_slot else slot, total)


func _advance_swap(delta: float) -> void:
	if _phase == 0 or delta <= 0.0:
		return
	_phase_t += delta
	var k: float = clampf(_phase_t / _phase_dur, 0.0, 1.0)
	if _phase == 1:
		_down = lerpf(_down_from, 1.0, pow(k, stow_ease))
		if k >= 1.0:
			_exchange()
		return
	_down = lerpf(_down_from, 0.0, pow(k, draw_ease))
	if k >= 1.0:
		_down = 0.0
		_phase = 0
		swap_finished.emit(active_slot)


func _exchange() -> void:
	var slot: int = _pending_slot
	if slot >= 0 and slot < slot_count:
		if _dirty[slot] or (_nodes[slot] == null and _specs[slot] != null):
			_build(slot)
		active_slot = slot
	_show_only(active_slot)
	# The gun that comes up is not the gun that was reloading.
	hand_pose.clear_animation()
	_configure_pose()
	_down = 1.0
	_down_from = 1.0
	_phase = 2
	_phase_t = 0.0
	_phase_dur = maxf(0.01, draw_seconds(_specs[active_slot]))
	_pending_slot = -1
	weapon_changed.emit(active_slot, _specs[active_slot])
	# The demo re-rigs its weapon on this signal, so the muzzle it points at only
	# exists now. Look for it again on the next frame rather than never.
	_rescan = true
	# A SWAP DOES NOT RAISE `ammo_changed` — the magazine did not move, the gun did.
	# The demo has already re-adopted on the emit above, so the weapon is carrying the
	# new gun's magazine by now and the plate can simply be re-read. Without this the
	# counter shows the count of the gun you just put away.
	_push_ammo()


func _build(slot: int) -> void:
	_dirty[slot] = false
	if _nodes[slot] != null:
		_nodes[slot].queue_free()
		_nodes[slot] = null
	var spec: GunSpec = _specs[slot]
	if spec == null:
		slot_equipped.emit(slot, null)
		return
	var node: Node3D = GunFactory.build_node(spec)
	if node == null:
		push_error("WeaponHolster: GunFactory.build_node returned nothing for slot %d." % slot)
		return
	# Left in model units on purpose. The pose solve works in model units and puts the
	# whole scale on `Lift`, so scaling here would apply it twice.
	node.visible = false
	_lift.add_child(node)
	_nodes[slot] = node
	_claim_geometry(node)
	slot_equipped.emit(slot, spec)
	_rescan = true


## Move every mesh the factory handed back onto the viewmodel layer. Done once per
## build rather than per frame, and iteratively rather than recursively because the
## assembly is one level deep and a stack frame per part is a silly price.
func _claim_geometry(root: Node3D) -> void:
	var shadow: int = (
		GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		if cast_shadows
		else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	)
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		var vi := n as VisualInstance3D
		if vi != null:
			vi.layers = render_layers
			var gi := vi as GeometryInstance3D
			if gi != null:
				gi.cast_shadow = shadow as GeometryInstance3D.ShadowCastingSetting
		for child: Node in n.get_children():
			stack.push_back(child)


## Hang the ammunition plate off `Hand`.
##
## `Hand` is posed in METRES — position and rotation only, with the whole model-unit
## scale living one node down on `Lift` — which is exactly why a world-scale prop goes
## here: the counter rides the ready pose, the swap arc and the recoil without knowing
## that any of them exist. Silent when the bake is missing, because a level with no
## ammo plate is worse than a level that crashes on load only in theory.
func _mount_ammo_counter() -> void:
	if not show_ammo_counter or _hand == null:
		return
	# A demo that baked its own counter into the scene keeps it rather than growing a
	# second one on top.
	if _hand.get_node_or_null(^"AmmoCounter") != null:
		return
	var plate: AmmoCounter = AmmoCounter.spawn()
	if plate == null:
		return
	plate.name = "AmmoCounter"
	_hand.add_child(plate)
	_claim_geometry(plate)
	_ammo = plate


## Read the whole ammunition state off the weapon and publish it. Used where a signal
## cannot reach: on bind, and when the weapon goes away.
func _push_ammo() -> void:
	if _ammo == null:
		return
	if _weapon == null:
		_ammo.set_ammo(0, 0)
		_ammo.set_jammed(false)
		_ammo.set_clear_progress(0.0)
		return
	var ammo: GunAmmo = _weapon.ammo()
	_ammo.set_ammo(ammo.loaded(), ammo.capacity())
	_ammo.set_jammed(_weapon.jam != null and _weapon.jam.is_jammed())


## Drive the stoppage ring, read straight off the weapon rather than mirrored.
##
## `GunJam` owns how long THIS jam takes — workmanship grading and severity both scale
## it, so the same stoppage runs anywhere from 0.4 s to 4.2 s — and a copy of that
## number kept here would drift from the gun the moment either side was tuned. Costs
## one branch a frame on a gun that is not jammed.
func _tick_clear_ring() -> void:
	if _ammo == null or _weapon == null or _weapon.jam == null:
		return
	if _weapon.jam.is_jammed() or _weapon.jam.is_clearing():
		_ammo.set_clear_progress(_weapon.jam.clear_progress())
	elif _ammo.clear_progress() > 0.0:
		_ammo.set_clear_progress(0.0)


func _show_only(slot: int) -> void:
	for i: int in _nodes.size():
		if _nodes[i] != null:
			_nodes[i].visible = i == slot


## Re-solve the resting pose for whatever is up. Pure maths over the baked geometry —
## a few microseconds, and never per frame.
func _configure_pose() -> void:
	hand_pose.configure(_specs[active_slot], iron_sight_height, sight_notch)


func _read_player() -> void:
	if _player == null:
		return
	hand_pose.set_motion(_player.speed, _player.grounded, _player.sprinting, _player.bob_t)


func _ads_amount() -> float:
	return 0.0 if _player == null else clampf(_player.ads, 0.0, 1.0)


## Publish the solved pose onto the two nodes. `Hand` carries position and rotation in
## metres so a demo can hang world-scale props off it; `Lift` carries the lift and the
## model-unit scale, which is the only place the scale is applied.
func _apply_pose(ads: float) -> void:
	hand_pose.resolve(ads, _down)
	var s: float = maxf(hand_pose.uniform_scale, 1.0e-5)
	_hand.position = hand_pose.position
	_hand.rotation = hand_pose.rotation
	_lift.position = Vector3(0.0, hand_pose.lift_units * s, 0.0)
	_lift.scale = Vector3.ONE * s


func _step_slot(dir: int) -> int:
	var base: int = _pending_slot if _pending_slot >= 0 else active_slot
	for i: int in range(1, slot_count + 1):
		var slot: int = wrapi(base + dir * i, 0, slot_count)
		if _specs[slot] != null:
			return slot
	return base


func _input_blocked() -> bool:
	if _player == null:
		return false
	return _player.freecam_active or _player.input_suspended


func _on_weapon_fired(_origin: Vector3, _direction: Vector3, _spec: GunSpec) -> void:
	# The bound weapon has already taken the punch on the shared `GunRecoil`; this only
	# starts the action cycling. Unbound, `GunHandPose` fires its own.
	hand_pose.fire_shot(_ads_amount())


func _on_weapon_state(state: StringName) -> void:
	if state == Weapon.STATE_CLEARING:
		hand_pose.begin_jam_clear()
		return
	if state == Weapon.STATE_RELOADING:
		if not hand_pose.is_reloading():
			hand_pose.begin_reload()
	elif hand_pose.is_reloading():
		hand_pose.cancel_reload()


func _on_weapon_ammo(loaded: int, _reserve: int) -> void:
	if _ammo != null and _weapon != null:
		_ammo.set_ammo(loaded, _weapon.ammo().capacity())


func _on_weapon_jammed() -> void:
	hand_pose.set_jammed(true)
	if _ammo != null:
		_ammo.set_jammed(true)


func _on_weapon_unjammed() -> void:
	hand_pose.set_jammed(false)
	if _ammo != null:
		_ammo.set_jammed(false)


func _on_weapon_leaving() -> void:
	bind_weapon(null)
	_rescan = true


func _disconnect_weapon() -> void:
	if _weapon == null:
		return
	if _weapon.fired.is_connected(_on_weapon_fired):
		_weapon.fired.disconnect(_on_weapon_fired)
	if _weapon.state_changed.is_connected(_on_weapon_state):
		_weapon.state_changed.disconnect(_on_weapon_state)
	if _weapon.ammo_changed.is_connected(_on_weapon_ammo):
		_weapon.ammo_changed.disconnect(_on_weapon_ammo)
	if _weapon.tree_exiting.is_connected(_on_weapon_leaving):
		_weapon.tree_exiting.disconnect(_on_weapon_leaving)
	if _weapon.jam != null:
		if _weapon.jam.jammed.is_connected(_on_weapon_jammed):
			_weapon.jam.jammed.disconnect(_on_weapon_jammed)
		if _weapon.jam.cleared.is_connected(_on_weapon_unjammed):
			_weapon.jam.cleared.disconnect(_on_weapon_unjammed)
	_weapon = null


## The weapon rigged to this holster, or null.
##
## Every demo that pairs a `Weapon` with a holster calls `Weapon.set_rig` with the
## muzzle marker of the gun this holster built, so "its muzzle is inside me" identifies
## the pairing exactly. A name match would pick up an enemy's weapon in the arena;
## this cannot, because an enemy's muzzle is inside the enemy.
func _rigged_weapon() -> Weapon:
	if _nodes[active_slot] == null:
		return null
	return _search_weapon(get_tree().root)


func _search_weapon(node: Node) -> Weapon:
	var weapon := node as Weapon
	if weapon != null:
		var muzzle: Node3D = weapon.muzzle_node()
		if muzzle != null and muzzle != weapon and is_ancestor_of(muzzle):
			return weapon
		return null
	for child: Node in node.get_children():
		var found: Weapon = _search_weapon(child)
		if found != null:
			return found
	return null


## Find a child by name, or make one. Named rather than indexed so a holster baked into
## a `PackedScene` and one built at runtime end up as the same tree.
static func _child(parent: Node3D, node_name: StringName) -> Node3D:
	var found := parent.get_node_or_null(NodePath(node_name)) as Node3D
	if found != null:
		return found
	var made := Node3D.new()
	made.name = String(node_name)
	parent.add_child(made)
	return made
