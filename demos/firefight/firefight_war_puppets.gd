class_name FirefightWarPuppets
extends RefCounted
## The war as a client sees it: a hundred real creatures, driven from eight bytes
## each, deciding nothing.
##
## A puppet is not a proxy mesh. It is the SAME baked `EnemyActor` the host is
## running, spawned out of the same pooled `EnemySpawner`, with the same rig, the
## same gait solver, the same collapse and the same shadow. The only difference
## is who tells it where to go: on the host that is `FirefightAgent.think`, and
## here it is the wire. Everything below the motor — which clip is playing, where
## the feet land, how the weapon sits in the hands, which way it falls when it
## dies — is a deterministic function of position, facing and the death event, so
## none of it is ever sent.
##
## HOW A BODY MOVES. Not by teleporting to the last packet: at the rates the link
## sends far bodies that would be a slideshow. Each sample gives a point and,
## together with the one before it, a velocity, so between packets the puppet is
## STEERED toward where the host's body is now estimated to be — dead reckoning
## into `EnemyActor.steer`, which is the same entry point the AI uses. That means
## the animation, the foot planting and the gait clamp all come out right for
## free: `_clamped_speed` will not let a body travel faster than its own stride,
## so a puppet catching up cannot skate, it can only walk faster.
##
## The servo is a spring with a hard limit. Small error is walked off; error past
## `snap_distance` is a body that has diverged for real — wedged on geometry the
## host's copy walked past, or shoved by another puppet — and is teleported,
## because a body in the wrong place is worse than a body that jumped.
##
## AIM COSTS NOTHING ON THE WIRE. A creature's weapon points where it is
## shooting, and the client is told about every round fired. So a shot record
## also aims the rig, and the aim is held for `aim_hold` seconds afterwards —
## which is longer than the gap between rounds for anything that is actually in a
## fight, and expires for anything that is not. A body between engagements
## relaxes to its clip's rehearsal aim exactly as it does on the host.

## Metres of error past which a puppet is teleported instead of walked.
const SNAP_DISTANCE: float = 2.5
## Metres of error under which a puppet is told to stand still. Below this the
## servo would be fighting quantisation, and a body that twitches in place is
## more visible than one that is three centimetres out.
const DEADBAND: float = 0.10
## Requested speed per metre of error, in 1/s. Three tenths of a second to close
## a gap, which is well inside the interval between two samples of a near body.
const CATCHUP_GAIN: float = 3.2
## Ceiling on the requested speed as a multiple of the species' run speed. The
## gait clamp inside `EnemyActor` is the real limit; this stops the servo asking
## for something absurd on the frame a snap is about to happen anyway.
const CATCHUP_CEILING: float = 1.4
## Seconds of dead reckoning allowed past the last sample. Beyond this the host
## has stopped talking about this body — it is far, or the packet was lost — and
## extrapolating further invents motion that never happened.
const EXTRAPOLATE_MAX: float = 0.35
## Seconds a rig keeps aiming where its last round went.
const AIM_HOLD: float = 1.6
## Ceiling on the estimated velocity, as a multiple of run speed. A sample pair
## that straddles a snap on the host would otherwise imply a rocket.
const VELOCITY_CEILING: float = 1.6

var _spawners: Array[EnemySpawner] = []
var _actors: Array[EnemyActor] = []
var _slot_of: Dictionary = {}
var _used: PackedInt32Array = PackedInt32Array()
var _want: PackedVector3Array = PackedVector3Array()
var _vel: PackedVector3Array = PackedVector3Array()
var _yaw: PackedFloat32Array = PackedFloat32Array()
var _age: PackedFloat32Array = PackedFloat32Array()
var _aim_at: PackedVector3Array = PackedVector3Array()
var _aim_age: PackedFloat32Array = PackedFloat32Array()
var _aiming: PackedInt32Array = PackedInt32Array()


func _init(spawners: Array[EnemySpawner]) -> void:
	_spawners = spawners
	_actors.resize(FirefightWarWire.MAX_SLOTS)
	_want.resize(FirefightWarWire.MAX_SLOTS)
	_vel.resize(FirefightWarWire.MAX_SLOTS)
	_yaw.resize(FirefightWarWire.MAX_SLOTS)
	_age.resize(FirefightWarWire.MAX_SLOTS)
	_aim_at.resize(FirefightWarWire.MAX_SLOTS)
	_aim_age.resize(FirefightWarWire.MAX_SLOTS)
	_aiming.resize(FirefightWarWire.MAX_SLOTS)
	for s: EnemySpawner in _spawners:
		if s != null and not s.despawned.is_connected(_on_despawned):
			s.despawned.connect(_on_despawned)


## Bodies this machine is currently puppeting.
func live_count() -> int:
	return _used.size()


## A body entered play on the host. Idempotent by slot: a baseline that arrives
## after the live event it duplicates re-places the body instead of making a
## second one, which is the whole of the join race.
func spawn(slot: int, faction: int, species: int, at: Vector3, yaw: float) -> void:
	if slot < 0 or slot >= FirefightWarWire.MAX_SLOTS:
		return
	if _actors[slot] != null and is_instance_valid(_actors[slot]):
		_place(_actors[slot], at, yaw)
		_sample(slot, at, yaw, true)
		return
	if faction < 0 or faction >= _spawners.size() or _spawners[faction] == null:
		return
	var roster: Array = FirefightRoster.ROSTERS[faction]
	if species < 0 or species >= roster.size():
		return
	# `looking_at`, not `Basis(UP, yaw)`, because `EnemyActor.revive` reads the
	# transform's -Z as the heading the body starts facing. Handing it the other
	# basis stands every reinforcement up back to front for the third of a second
	# its turn rate needs to come round.
	var facing := Vector3(sin(yaw), 0.0, cos(yaw))
	var basis := Basis.looking_at(facing, Vector3.UP)
	var actor: EnemyActor = _spawners[faction].spawn(roster[species], Transform3D(basis, at))
	if actor == null:
		return
	# The spawner scatters and snaps every spawn onto the navmesh, which is right
	# when it is deciding where a body goes and wrong when the host already has.
	_place(actor, at, yaw)
	_actors[slot] = actor
	_slot_of[actor] = slot
	_used.append(slot)
	_sample(slot, at, yaw, true)
	_aim_age[slot] = 1e9
	_aiming[slot] = 0


## One position sample off the stream.
func move(slot: int, at: Vector3, yaw: float) -> void:
	if slot < 0 or slot >= FirefightWarWire.MAX_SLOTS or _actors[slot] == null:
		return
	_sample(slot, at, yaw, false)


## The host says this body died. The corpse, the collapse, the take it falls in
## and the eight-second linger are all local — none of that is on the wire, and
## none of it has to be: every machine loaded the same rig and the same falls.
func kill(slot: int) -> void:
	if slot < 0 or slot >= FirefightWarWire.MAX_SLOTS:
		return
	var actor: EnemyActor = _actors[slot]
	if actor == null or not is_instance_valid(actor) or not actor.alive:
		return
	actor.kill()


## The host's pool took this body back. The local pool usually has already, on
## its own eight-second corpse timer, so this is the mop-up rather than the rule.
func gone(slot: int) -> void:
	if slot < 0 or slot >= FirefightWarWire.MAX_SLOTS:
		return
	var actor: EnemyActor = _actors[slot]
	if actor == null:
		return
	_release(slot)
	if is_instance_valid(actor) and actor.alive:
		var spawner: EnemySpawner = _spawner_of(actor)
		if spawner != null:
			spawner.despawn(actor)


## A round was fired on the host. Points the rig at where it went and plays the
## attack clip; the tracer, flash, powder and impact are the caller's business.
func shot(slot: int, at: Vector3) -> void:
	if slot < 0 or slot >= FirefightWarWire.MAX_SLOTS:
		return
	var actor: EnemyActor = _actors[slot]
	if actor == null or not is_instance_valid(actor) or not actor.alive:
		return
	_aim_at[slot] = at
	_aim_age[slot] = 0.0
	_aiming[slot] = 1
	var body: EnemyBody = actor.body()
	if body != null:
		body.aim_at(at)
		body.play_clip(String(BeastClips.ATTACK))


## Drive every puppet one physics step. This is the whole client-side simulation
## of a hundred-body war.
func advance(delta: float) -> void:
	var write: int = 0
	for i: int in _used.size():
		var slot: int = _used[i]
		var actor: EnemyActor = _actors[slot]
		if actor == null or not is_instance_valid(actor):
			_actors[slot] = null
			continue
		_used[write] = slot
		write += 1
		_age[slot] += delta
		_aim_age[slot] += delta
		if actor.alive:
			_drive(slot, actor)
			_aim(slot, actor)
	if write != _used.size():
		_used.resize(write)


## Every puppet back to its pool. The scene teardown path.
func clear() -> void:
	for slot: int in _used:
		var actor: EnemyActor = _actors[slot]
		if actor != null and is_instance_valid(actor):
			var spawner: EnemySpawner = _spawner_of(actor)
			if spawner != null:
				spawner.despawn(actor)
		_actors[slot] = null
	_used.clear()
	_slot_of.clear()


func _drive(slot: int, actor: EnemyActor) -> void:
	var goal: Vector3 = _want[slot] + _vel[slot] * minf(_age[slot], EXTRAPOLATE_MAX)
	var to: Vector3 = goal - actor.global_position
	if to.length_squared() > SNAP_DISTANCE * SNAP_DISTANCE:
		actor.global_position = goal
		actor.velocity = Vector3.ZERO
		actor.halt()
	else:
		var flat := Vector3(to.x, 0.0, to.z)
		var d: float = flat.length()
		if d <= DEADBAND:
			actor.halt()
		else:
			var run: float = 3.4 if actor.profile == null else actor.profile.run_speed
			actor.steer(flat / d, minf(d * CATCHUP_GAIN, run * CATCHUP_CEILING))
	# Facing, in the actor's own terms: `_tick_facing` turns toward `atan2(x, z)`
	# of whatever `look_at_point` last set, so a point one metre along the wire's
	# yaw is exactly the heading the host's body is holding. A body that is
	# actually walking overrides this with its travel direction, on both machines.
	var y: float = _yaw[slot]
	actor.look_at_point(actor.global_position + Vector3(sin(y), 0.0, cos(y)))


func _aim(slot: int, actor: EnemyActor) -> void:
	if _aiming[slot] == 0:
		return
	var body: EnemyBody = actor.body()
	if body == null:
		return
	if _aim_age[slot] < AIM_HOLD:
		body.aim_at(_aim_at[slot])
		return
	body.clear_aim()
	_aiming[slot] = 0


## Fold one sample in, and derive the velocity the next `advance` extrapolates
## along. `fresh` is a spawn or a snap: there is no previous point to difference
## against, so the body starts still rather than inheriting a bogus velocity.
func _sample(slot: int, at: Vector3, yaw: float, fresh: bool) -> void:
	if fresh or _age[slot] <= 0.0:
		_vel[slot] = Vector3.ZERO
	else:
		var actor: EnemyActor = _actors[slot]
		var run: float = 3.4 if actor == null or actor.profile == null else actor.profile.run_speed
		var v: Vector3 = (at - _want[slot]) / _age[slot]
		_vel[slot] = v.limit_length(run * VELOCITY_CEILING)
	_want[slot] = at
	_yaw[slot] = yaw
	_age[slot] = 0.0


func _place(actor: EnemyActor, at: Vector3, yaw: float) -> void:
	actor.global_position = at
	actor.rotation.y = yaw
	actor.velocity = Vector3.ZERO
	actor.halt()


func _release(slot: int) -> void:
	var actor: EnemyActor = _actors[slot]
	if actor != null:
		_slot_of.erase(actor)
	_actors[slot] = null
	var i: int = _used.find(slot)
	if i >= 0:
		_used.remove_at(i)


func _spawner_of(actor: EnemyActor) -> EnemySpawner:
	if actor.faction < 0 or actor.faction >= _spawners.size():
		return null
	return _spawners[actor.faction]


## The local pool reclaimed a corpse on its own timer. Let the slot go; the
## host's own `K_GONE` for it, whenever it lands, then finds nothing to do.
func _on_despawned(actor: EnemyActor) -> void:
	var slot: Variant = _slot_of.get(actor)
	if slot != null:
		_release(int(slot))
