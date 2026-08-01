class_name Weapon
extends Node3D
## Everything between the trigger and the damage, in one node.
##
## The player drives this. The AI drives this. There is no second, simpler weapon
## for enemies — a raider with a rolled gun jams, blooms, walks its recoil pattern
## and runs its magazine dry exactly as the player's does, because it is the same
## object with a different thing calling `trigger_down()`.
##
## Wiring, all optional:
##   `set_rig(aim, muzzle, shooter)` — where the ray starts, where the tracer starts,
##   and whose own collider to ignore. Unset, all three fall back to this node.
##   `set_aim_blend(0..1)` — how shouldered the shooter is; tightens the cone and
##   softens the kick.
##   `set_stance(speed, on_ground, crouched)` — opens the cone for movement.
##
## The caller owns look angles. `fire()` hands back a permanent aim delta through
## `recoiled`; a camera adds it and then has to pull it back down. The decaying half
## — 58 % of every shot, and the half that makes a round feel like a shove — is read
## every frame off `view_recoil()` and added on top of the real aim without changing
## it. Both halves are needed; a camera that wires only `recoiled` gets a gun that
## climbs but never punches. A weapon that moved the camera itself could not be held
## by an AI, which is why neither half is applied here.

## A round left the barrel. Direction is the aim line, not the pellet.
signal fired(origin: Vector3, direction: Vector3, spec: GunSpec)
## One pellet, one surface. Fires once per penetrated surface too.
signal hit(collider: Object, position: Vector3, normal: Vector3, damage: float)
## `idle`, `firing`, `cycling`, `reloading`, `jammed`, `clearing` or `empty`.
signal state_changed(state: StringName)
## Permanent aim change from a shot, radians, as (pitch, yaw).
signal recoiled(aim_delta: Vector2)
## Forwarded from the magazine. `reserve` is -1 when the reserve is infinite.
signal ammo_changed(loaded: int, reserve: int)

const STATE_IDLE: StringName = &"idle"
const STATE_FIRING: StringName = &"firing"
const STATE_CYCLING: StringName = &"cycling"
const STATE_RELOADING: StringName = &"reloading"
const STATE_JAMMED: StringName = &"jammed"
const STATE_CLEARING: StringName = &"clearing"
const STATE_EMPTY: StringName = &"empty"

## Seconds a shot keeps the weapon reading as `firing` after the round goes off.
const FIRING_STATE_HOLD: float = 0.12
## Shortest projectile spawn distance, metres. The reference's `max(hsRange, 1.4)`.
const MIN_PROJECTILE_STANDOFF: float = 1.4
## Blast standoff from the surface a shell detonates against, metres.
const BLAST_STANDOFF: float = 0.25

@export_group("Mechanism")
@export var fire_control: FireControl
@export var spread: GunSpread
@export var recoil: GunRecoil
@export var jam: GunJam
@export var reload_action: GunReload
@export var damage: GunDamage
@export var hitscan: GunHitscan
@export var projectiles: GunProjectilePool

@export_group("Carry")
## Reserve ammunition is unlimited, as it is in the reference's range.
@export var infinite_reserve: bool = true
## Spare magazines carried when the reserve is finite.
@export_range(0, 20, 1) var reserve_magazines: int = 6
## Pulling the trigger on an empty gun starts the reload by itself.
@export var auto_reload_when_empty: bool = true
## Firing breaks off a shell-at-a-time reload instead of being locked out.
@export var firing_interrupts_reload: bool = true

@export_group("Drive")
## Tick from `_physics_process`. Turn off when an AI or a test drives `tick()`.
@export var self_driven: bool = true
## Only the first pellet gets a tracer above this payload count.
@export_range(1, 32, 1) var tracer_pellet_limit: int = 5
## Draw tracers, flashes, impacts and decals at all.
@export var visual_effects: bool = true
## Speak. The voice is derived from this weapon's own energy and cyclic rate, so
## nothing has to be assigned per gun; see `GunAudio`. Off for a silent test rig.
@export var audio_effects: bool = true

@export_group("Nodes")
## Where the ray starts: an eye, a camera, or an AI's aim node.
@export var aim_path: NodePath
## Where the tracer and flash start.
@export var muzzle_path: NodePath

var _spec: GunSpec
var _ammo: GunAmmo = GunAmmo.new()
var _rand: XorShift32 = XorShift32.new(1)
var _vfx: GunVfxBridge = GunVfxBridge.new()
var _audio: GunAudio = null
var _aim: Node3D
var _muzzle: Node3D
var _exclude: Array[RID] = []
var _state: StringName = STATE_IDLE
var _ads: float = 0.0
var _speed: float = 0.0
var _on_ground: bool = true
var _crouched: bool = false
var _firing_hold: float = 0.0
var _pellet_hit: bool = false
var _pellet_dir: Vector3 = Vector3.FORWARD
var _pellet_damage: float = 0.0
var _draw_tracer: bool = false
var _tracer_end: Vector3 = Vector3.ZERO


func _ready() -> void:
	_build_parts()
	_bind_callbacks()
	if aim_path != NodePath():
		_aim = get_node_or_null(aim_path) as Node3D
	if muzzle_path != NodePath():
		_muzzle = get_node_or_null(muzzle_path) as Node3D
	_vfx.bind(get_tree())
	if audio_effects:
		_audio = GunAudio.service(get_tree())
	set_physics_process(self_driven)


func _physics_process(delta: float) -> void:
	tick(delta)


## Take a rolled weapon. Everything downstream of the roll is rebuilt here; call it
## again to change guns without rebuilding the node.
func setup(spec: GunSpec) -> void:
	if spec == null:
		push_error("Weapon.setup: null GunSpec.")
		return
	_build_parts()
	_bind_callbacks()
	_spec = spec
	# Seeding off `cfg` rather than `roll_seed` means the same five parts always
	# spice their recoil and their jams the same way, as the reference intends.
	_rand = XorShift32.new(spec.cfg if spec.cfg != 0 else 1)
	_ammo.configure(spec, infinite_reserve, reserve_magazines)
	fire_control.configure(spec)
	spread.configure(spec)
	recoil.configure(spec)
	jam.configure(spec)
	reload_action.configure(spec, fire_control.action_id())
	hitscan.configure(spec, damage)
	projectiles.configure()
	_firing_hold = 0.0
	_set_state(STATE_IDLE)


## Point the weapon at its owner's rig. Any argument may be null to keep the
## current value; pass this node to reset one to the default.
func set_rig(aim: Node3D, muzzle: Node3D, shooter: CollisionObject3D) -> void:
	if aim != null:
		_aim = aim
	if muzzle != null:
		_muzzle = muzzle
	_exclude.clear()
	if shooter != null:
		_exclude.append(shooter.get_rid())


## 0 hip, 1 fully shouldered.
func set_aim_blend(value: float) -> void:
	_ads = clampf(value, 0.0, 1.0)


## Horizontal speed in m/s, plus the two stance flags the cone cares about.
func set_stance(speed: float, on_ground: bool, crouched: bool) -> void:
	_speed = maxf(speed, 0.0)
	_on_ground = on_ground
	_crouched = crouched


func trigger_down() -> void:
	fire_control.trigger_down()


func trigger_up() -> void:
	fire_control.trigger_up()


## The reload key. Clears a jam if there is one, otherwise loads the gun — the
## reference gives the same key both jobs and so does this.
func reload() -> void:
	if jam.is_jammed():
		clear_jam()
		return
	if reload_action.is_busy():
		return
	if not reload_action.begin(_ammo):
		return
	_set_state(STATE_RELOADING)
	if _audio != null:
		_audio.reload_sequence(
			_spec, reload_action.expected_duration(_ammo), muzzle_transform().origin
		)


## Start working the action free. Held: release calls `cancel_clear()`.
func clear_jam() -> void:
	if jam.begin_clear():
		_set_state(STATE_CLEARING)


## Let go of the reload key mid-clear. The gun stays jammed.
func cancel_clear() -> void:
	if not jam.is_clearing():
		return
	jam.abort_clear()
	_set_state(STATE_JAMMED)


## Advance the whole weapon by `delta`. Call this or let `self_driven` do it.
##
## THE TRIGGER GROUP'S CLOCK RUNS WHATEVER THE ACTION IS DOING. It used to be the
## `else` of the branch below, and that one word cost a hand-worked gun half its rate
## of fire: `GunReload` cycles a bolt, pump or break action for `cycle_fraction` of
## the rated interval, and while it did, `FireControl._cooldown` — set to a whole
## interval by the shot that started the cycle — did not tick down at all. The two
## timers ran one after the other instead of being the same wait. Measured over 208
## rolled weapons, bolt, pump and break answered at **2.00 clicks per round** tapping
## at their own rated rpm, and every click made in the extra interval was discarded.
##
## Nothing can fire through a closed action as a result. `_fire_once` refuses while
## the gun is jammed, cycling or mid-reload, and a refused pull floors the cooldown
## at zero rather than banking credit. The only thing that changed is that the clock
## no longer stops — which is also what finally makes `firing_interrupts_reload`
## reachable, since a tube gun could never break off a reload it was never asked
## about.
func tick(delta: float) -> void:
	if _spec == null or delta <= 0.0:
		return
	spread.decay(delta)
	recoil.tick(delta, fire_control.interval())
	if _firing_hold > 0.0:
		_firing_hold -= delta
	if jam.is_clearing():
		jam.tick(delta)
	elif reload_action.is_busy():
		reload_action.tick(delta, _ammo)
	fire_control.advance(delta)
	projectiles.step(delta, _space(), hitscan, _exclude)
	_set_state(_current_state())


func spec() -> GunSpec:
	return _spec


func ammo() -> GunAmmo:
	return _ammo


func state() -> StringName:
	return _state


## True when a trigger pull right now would put a round downrange.
func is_ready_to_fire() -> bool:
	if _spec == null or jam.is_jammed() or reload_action.is_cycling():
		return false
	if reload_action.is_reloading() and not _may_interrupt_reload():
		return false
	return not _ammo.is_empty()


## The decaying half of the kick this frame, radians, as (pitch, yaw). ADD it to
## the shooter's look angles when placing the view; never accumulate it, and never
## write it back into the shooter's own aim — that half already went out through
## `recoiled`. A camera that skips this gets 42 % of every shot.
func view_recoil() -> Vector2:
	return Vector2.ZERO if _spec == null else recoil.camera_offset()


## Trauma the shot just fired is worth to a view-effects rig, 0-1. Decays with the
## shake envelope, so polling it every frame is correct and cheap.
func view_trauma() -> float:
	return 0.0 if _spec == null else recoil.shake_trauma()


## The cone the gun is shooting into right now, radians, full angle. The crosshair
## and the AI's accuracy model both read this rather than guessing.
func effective_spread() -> float:
	if _spec == null:
		return 0.0
	return spread.effective(_ads, _speed, _on_ground, _crouched)


## The node the bore leaves from — the rig's muzzle when one was bound, this node
## otherwise. Effects that must stay welded to the barrel take the node; anything
## that only needs a point this frame takes `muzzle_transform()`.
func muzzle_node() -> Node3D:
	return _muzzle if _muzzle != null else self


func muzzle_transform() -> Transform3D:
	return muzzle_node().global_transform


## Back to a carried, loaded, unjammed gun without re-rolling anything.
func reset() -> void:
	if _spec == null:
		return
	_ammo.reset()
	fire_control.reset()
	spread.reset()
	recoil.reset()
	jam.reset()
	reload_action.reset()
	projectiles.clear()
	_firing_hold = 0.0
	_set_state(STATE_IDLE)


## Instantiate any mechanism part left unset in the inspector.
func _build_parts() -> void:
	if fire_control == null:
		fire_control = FireControl.new()
	if spread == null:
		spread = GunSpread.new()
	if recoil == null:
		recoil = GunRecoil.new()
	if jam == null:
		jam = GunJam.new()
	if reload_action == null:
		reload_action = GunReload.new()
	if damage == null:
		damage = GunDamage.new()
	if hitscan == null:
		hitscan = GunHitscan.new()
	if projectiles == null:
		projectiles = GunProjectilePool.new()


func _bind_callbacks() -> void:
	fire_control.shoot = _fire_once
	hitscan.on_hit = _on_hitscan_hit
	projectiles.on_impact = _on_projectile_impact
	projectiles.on_streak = _on_projectile_streak
	projectiles.on_smoke = _on_projectile_smoke
	if not _ammo.ammo_changed.is_connected(_on_ammo_changed):
		_ammo.ammo_changed.connect(_on_ammo_changed)


func _on_ammo_changed(loaded: int, reserve: int) -> void:
	ammo_changed.emit(loaded, reserve)


func _space() -> PhysicsDirectSpaceState3D:
	if not is_inside_tree():
		return null
	var world: World3D = get_world_3d()
	return null if world == null else world.direct_space_state


func _aim_node() -> Node3D:
	return _aim if _aim != null else self


func _may_interrupt_reload() -> bool:
	return firing_interrupts_reload and reload_action.is_interruptible() and not _ammo.is_empty()


## The one place a round is spent. Returns true only when something left the
## barrel; `FireControl` reads that as permission to keep the cadence going.
func _fire_once() -> bool:
	if jam.is_jammed() or reload_action.is_cycling():
		return false
	if reload_action.is_reloading():
		if not _may_interrupt_reload():
			return false
		reload_action.interrupt()
	if _ammo.is_empty():
		# The click on an empty chamber IS the answer to the pull. Spending it here is
		# what stops a buffered pull from re-offering itself sixty times a second and
		# turning one click into a stutter of dry-fire sounds.
		fire_control.spend_pull()
		if _audio != null:
			_audio.dry_fire(muzzle_transform().origin)
		if auto_reload_when_empty:
			reload()
		return false
	_ammo.consume()
	if jam.roll(_ammo.loaded(), _rand):
		fire_control.cancel_burst()
		fire_control.spend_pull()
		if _audio != null:
			_audio.jammed(muzzle_transform().origin)
		return false
	_discharge()
	return true


## The round is gone and the action worked: throw the payload and take the kick.
func _discharge() -> void:
	var node: Node3D = _aim_node()
	var origin: Vector3 = node.global_position
	var dir: Vector3 = -node.global_basis.z
	_throw_payload(origin, dir)
	spread.add_shot(_ads)
	var delta: Vector2 = recoil.fire(_ads, _rand)
	recoiled.emit(delta)
	if _spec.runaway and _spec.automatic and _ammo.loaded() > 0:
		fire_control.queue_runaway(_ammo.loaded())
		spread.force_bloom(1.6)
	if visual_effects:
		_vfx.muzzle_flash(muzzle_node(), float(_spec.muzzle_energy), _spec.pellets)
	if _audio != null:
		_audio.shot(_spec, muzzle_transform().origin)
	reload_action.begin_cycle()
	_firing_hold = FIRING_STATE_HOLD
	fired.emit(origin, dir, _spec)


## Every pellet in the shell, each down its own line inside the cone.
func _throw_payload(origin: Vector3, dir: Vector3) -> void:
	var pellets: int = maxi(_spec.pellets, 1)
	var half_cone: float = effective_spread() * 0.5
	var window: float = maxf(_spec.headshot_range, MIN_PROJECTILE_STANDOFF)
	_pellet_damage = _spec.damage / float(pellets)
	var space: PhysicsDirectSpaceState3D = _space()
	var muzzle: Vector3 = muzzle_transform().origin
	for i: int in pellets:
		var pellet: Vector3 = GunSpread.sample(dir, half_cone, _rand)
		_pellet_dir = pellet
		_pellet_hit = false
		_draw_tracer = visual_effects and (i == 0 or pellets <= tracer_pellet_limit)
		_tracer_end = hitscan.trace(space, origin, pellet, window, _exclude)
		if not _pellet_hit:
			var start: Vector3 = origin + pellet * window
			projectiles.spawn(
				start, pellet, float(_spec.sim_velocity), _spec, _pellet_damage, window
			)
			_tracer_end = start
		if _draw_tracer:
			_vfx.tracer(muzzle, _tracer_end, float(_spec.sim_velocity))


func _on_hitscan_hit(
	collider: Object, at: Vector3, normal: Vector3, distance: float, scale: float, surface: int
) -> void:
	_pellet_hit = true
	_tracer_end = at
	_arrive(collider, at, normal, distance, _pellet_damage * scale, _pellet_dir, surface)


func _on_projectile_impact(
	collider: Object,
	at: Vector3,
	normal: Vector3,
	distance: float,
	dmg: float,
	spec: GunSpec,
	dir: Vector3
) -> void:
	var surface: int = damage.surface_of(collider)
	_arrive(collider, at, normal, distance, dmg, dir, surface, spec)


## One round arriving somewhere, however it got there.
func _arrive(
	collider: Object,
	at: Vector3,
	normal: Vector3,
	distance: float,
	base: float,
	dir: Vector3,
	surface: int,
	from_spec: GunSpec = null
) -> void:
	var use: GunSpec = from_spec if from_spec != null else _spec
	if use == null:
		return
	if use.explosive:
		_detonate(at + normal * BLAST_STANDOFF, normal, use)
		return
	var zone: StringName = damage.zone_of(collider)
	var amount: float = damage.resolve(base, distance, use, zone)
	damage.apply(collider, amount, at, normal, dir, use.crit_multiplier)
	damage.push(collider, at, dir, use.impulse)
	hit.emit(collider, at, normal, amount)
	if _audio != null:
		# Size drives the ring of a struck plate, and the damage a round did to a
		# surface is the best proxy this code has for how much of it moved.
		_audio.impact(
			GunAudioBank.impact_of_surface(surface),
			at,
			_audio.listener_distance(at),
			clampf(amount / 45.0, 0.2, 3.0)
		)
	if not visual_effects:
		return
	# The hole is the impact's own business: the service sizes it off the surface
	# it was told about. Asking for a second one here spent two slots of a 280-slot
	# ring on the same bullet hole and halved how long holes survived.
	_vfx.impact(at, normal, surface, clampf(amount / 60.0, 0.25, 2.0))


func _detonate(at: Vector3, normal: Vector3, use: GunSpec) -> void:
	var radius: float = maxf(use.blast_radius, 0.5)
	damage.blast(_space(), at, use.damage, radius, _exclude)
	hit.emit(null, at, normal, use.damage)
	if _audio != null:
		_audio.impact(GunAudioBank.Impact.BOOM, at, _audio.listener_distance(at), radius)
	if visual_effects:
		_vfx.explosion(at, radius)
		_vfx.decal(at, normal, 0.55, false)


## `tail`-to-`head` is the ground the round covered this frame, so the streak is
## drawn whole: the round is already at `head`, and re-walking the segment would
## put the visible tracer behind the projectile it is meant to be.
func _on_projectile_streak(_index: int, tail: Vector3, head: Vector3, _explosive: bool) -> void:
	if visual_effects:
		_vfx.tracer(tail, head, 0.0)


func _on_projectile_smoke(at: Vector3, explosive: bool) -> void:
	if visual_effects:
		_vfx.impact(at, Vector3.UP, VFXSurface.Kind.SAND, 0.35 if explosive else 0.12)


## What the gun is doing right now, in the order that matters to a listener.
func _current_state() -> StringName:
	if jam.is_clearing():
		return STATE_CLEARING
	if jam.is_jammed():
		return STATE_JAMMED
	if reload_action.is_reloading():
		return STATE_RELOADING
	if reload_action.is_cycling():
		return STATE_CYCLING
	if _firing_hold > 0.0:
		return STATE_FIRING
	return STATE_EMPTY if _ammo.is_empty() else STATE_IDLE


func _set_state(next: StringName) -> void:
	if next == _state:
		return
	_state = next
	state_changed.emit(next)
