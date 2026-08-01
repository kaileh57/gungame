class_name ArenaNetBodies
extends RefCounted
## The compound's population on the wire. One table, two jobs: on the host it hands
## every live body a network id and writes the snapshot; on a client it stands up a
## puppet for every row of that snapshot and steers it.
##
## THE SNAPSHOT IS THE WHOLE TRUTH, and that is the design decision everything else
## falls out of. It carries species and faction for every body on every tick — two
## extra bytes each — rather than announcing arrivals once and trusting the client
## to have heard. Two bytes at thirty-two bodies and fifteen ticks is under a
## kilobyte a second, and what it buys is that a client which has just joined, just
## dropped forty packets, or just finished loading the scene late is CORRECT one
## packet later, with no join protocol, no resend queue and no divergence that has
## to be reasoned about. Membership works the same way: a body the host has stopped
## listing is a body the client retires. There is no despawn message to lose.
##
## PUPPETS ARE STEERED, NOT TELEPORTED. `EnemyActor` already owns a motor, a facing
## spring and a clip picker that reads its own speed — driving `steer()` with the
## distance the host moved a body over the tick interval gets all three for free, so
## a replicated body walks, runs and turns exactly as it does on the host instead of
## sliding at a fixed pose. Error past `SNAP_DISTANCE` is a teleport, because past
## about three metres steering is no longer catching up, it is lying.
##
## The client's own weapon still resolves its own hits against these puppets, which
## is prediction: the flinch, the blood and the damage number are immediate, and the
## host's snapshot is what decides whether the body is actually dead. See
## `ArenaNet._rq_hit`.

## Metres of error a puppet may hold before it is put where it belongs. Three and a
## half is a body length and a half: past it the correction is visible as a slide
## whichever way it is done, and a cut is cheaper to look at than a sprint.
const SNAP_DISTANCE: float = 3.5
## How far above its own run speed a puppet may be driven to close a gap. Anything
## more and a body that lost two packets arrives visibly skating.
const CATCHUP: float = 1.7
## Fire events one tick will carry. A hundred bodies in a firefight can all pull a
## trigger in the same 66 ms and none of it is worth a dropped snapshot.
const FIRE_LIMIT: int = 14
## Health is a byte: 0 is dead, 1..255 is the fraction. Zero doubles as the death
## flag, so a body's state costs one byte and not two.
const HP_SCALE: float = 254.0
## Meta the net id is written on, so anything holding an `EnemyActor` — the hit
## report, chiefly — can name it to the host.
const META_ID: StringName = &"arena_net_id"

var _spawners: Array[EnemySpawner] = []
## Species ids in a fixed order, from the first spawner. All three carry the same
## list (`tools/build_arena.gd` deals every spawner the same profile set), so one
## byte names a species on every machine.
var _catalogue: Array[StringName] = []
var _actor_of: Dictionary = {}
var _net_of: Dictionary = {}
## Ids this machine has recycled the corpse of. Held until the host stops listing
## them, so a locally-settled corpse is not hatched again by the next snapshot.
var _retired: Dictionary = {}
var _serial: int = 0
var _down_ids: PackedInt32Array = PackedInt32Array()
var _down_from: PackedVector3Array = PackedVector3Array()
var _fire_ids: PackedInt32Array = PackedInt32Array()
var _fire_aim: PackedVector3Array = PackedVector3Array()


## The three faction pools, indexed by faction id, exactly as `ArenaController`
## holds them. A client hatches a puppet out of its own faction's pool so a
## replicated Scav is a Scav to everything that looks at it.
func bind(spawners: Array[EnemySpawner]) -> void:
	_spawners = spawners
	_catalogue.clear()
	for spawner: EnemySpawner in _spawners:
		if spawner == null:
			continue
		for id: StringName in spawner.species:
			if not _catalogue.has(id):
				_catalogue.append(id)


## HOST. Give a body a network id. Idempotent, so a re-adopted actor keeps the id
## every client already knows it by.
func assign(actor: EnemyActor) -> int:
	if actor == null:
		return 0
	var key: int = actor.get_instance_id()
	if _net_of.has(key):
		return int(_net_of[key])
	_serial += 1
	_net_of[key] = _serial
	_actor_of[_serial] = actor
	actor.set_meta(META_ID, _serial)
	return _serial


## HOST. The spawner took a body back. Dropping it from the table is what tells
## every client to retire its puppet, one snapshot later.
func release(actor: EnemyActor) -> void:
	if actor == null:
		return
	var key: int = actor.get_instance_id()
	if not _net_of.has(key):
		return
	_actor_of.erase(int(_net_of[key]))
	_net_of.erase(key)


## HOST. A body went down. The snapshot already says so; this carries the bearing
## the round came from, which is what `EnemyActor._die` faces the collapse along.
func note_death(actor: EnemyActor, from_position: Vector3) -> void:
	var id: int = net_id_of(actor)
	if id <= 0:
		return
	_down_ids.append(id)
	_down_from.append(from_position)


## HOST. A body pulled a trigger. Replicated so a puppet plays its attack clip and
## turns onto whatever the real body is shooting at, which is the difference
## between a compound in a firefight and a compound sliding around in silence.
func note_fire(actor: EnemyActor, aim: Vector3) -> void:
	if _fire_ids.size() >= FIRE_LIMIT:
		return
	var id: int = net_id_of(actor)
	if id <= 0:
		return
	_fire_ids.append(id)
	_fire_aim.append(aim)


## HOST. Everything standing in the compound, this tick.
func snapshot() -> Dictionary:
	var ids := PackedInt32Array()
	var species := PackedByteArray()
	var faction := PackedByteArray()
	var pos := PackedVector3Array()
	var yaw := PackedFloat32Array()
	var hp := PackedByteArray()
	for id: int in _actor_of:
		var actor := _actor_of[id] as EnemyActor
		if actor == null or not is_instance_valid(actor):
			continue
		ids.append(id)
		species.append(_species_index(actor.species_id))
		faction.append(clampi(actor.faction, 0, 254))
		pos.append(actor.global_position)
		yaw.append(actor.rotation.y)
		hp.append(_health_byte(actor))
	return {"i": ids, "s": species, "f": faction, "p": pos, "y": yaw, "h": hp}


## HOST. Deaths and shots since the last call, and clears them.
func events() -> Dictionary:
	var out: Dictionary = {"d": _down_ids, "df": _down_from, "g": _fire_ids, "ga": _fire_aim}
	_down_ids = PackedInt32Array()
	_down_from = PackedVector3Array()
	_fire_ids = PackedInt32Array()
	_fire_aim = PackedVector3Array()
	return out


## CLIENT. Take one snapshot: hatch what is new, drive what is known, retire what
## the host has stopped listing. `interval` is seconds since the last snapshot
## ARRIVED, which is what the steering speed has to be measured against — using the
## frame delta would drive every puppet four times too fast.
func apply_snapshot(d: Dictionary, interval: float) -> void:
	var ids: PackedInt32Array = d.get("i", PackedInt32Array())
	var species: PackedByteArray = d.get("s", PackedByteArray())
	var faction: PackedByteArray = d.get("f", PackedByteArray())
	var pos: PackedVector3Array = d.get("p", PackedVector3Array())
	var yaw: PackedFloat32Array = d.get("y", PackedFloat32Array())
	var hp: PackedByteArray = d.get("h", PackedByteArray())
	var n: int = ids.size()
	if species.size() != n or faction.size() != n or pos.size() != n:
		return
	if yaw.size() != n or hp.size() != n:
		return
	var seen: Dictionary = {}
	for k: int in n:
		var id: int = ids[k]
		seen[id] = true
		if _retired.has(id):
			continue
		var actor := _actor_of.get(id) as EnemyActor
		if actor == null or not is_instance_valid(actor):
			actor = _hatch(id, species[k], faction[k], pos[k], yaw[k])
			if actor == null:
				continue
		_drive(actor, pos[k], yaw[k], hp[k], interval)
	for id: int in _actor_of.keys():
		if not seen.has(id):
			_retire(id)
	for id: int in _retired.keys():
		if not seen.has(id):
			_retired.erase(id)


## CLIENT. Deaths and shots the host resolved.
func apply_events(d: Dictionary) -> void:
	var down: PackedInt32Array = d.get("d", PackedInt32Array())
	var down_from: PackedVector3Array = d.get("df", PackedVector3Array())
	for k: int in mini(down.size(), down_from.size()):
		var actor := _actor_of.get(down[k]) as EnemyActor
		if actor != null and is_instance_valid(actor) and actor.alive:
			actor.kill(down_from[k])
	var fire: PackedInt32Array = d.get("g", PackedInt32Array())
	var aim: PackedVector3Array = d.get("ga", PackedVector3Array())
	for k: int in mini(fire.size(), aim.size()):
		var actor := _actor_of.get(fire[k]) as EnemyActor
		if actor == null or not is_instance_valid(actor) or not actor.alive:
			continue
		actor.look_at_point(aim[k])
		var body: EnemyBody = actor.body()
		if body != null:
			body.aim_at(aim[k])
			body.play_clip(String(BeastClips.ATTACK))


## CLIENT. This machine's own corpse timer recycled a puppet. Remembered rather
## than forgotten: the host is still listing the corpse, and without this the next
## snapshot would hatch it again.
func forget(actor: EnemyActor) -> void:
	var id: int = net_id_of(actor)
	if id <= 0:
		return
	if _actor_of.has(id):
		_actor_of.erase(id)
		_retired[id] = true
	_net_of.erase(actor.get_instance_id())


## Drop the table without touching a body. The demo teardown path; the spawners
## park their own actors.
func clear() -> void:
	_actor_of.clear()
	_net_of.clear()
	_retired.clear()


func count() -> int:
	return _actor_of.size()


## The id an actor is known by on the wire, or 0. Read off the actor's own meta, so
## a client's hit report can name a body it only ever received.
static func net_id_of(actor: EnemyActor) -> int:
	if actor == null or not is_instance_valid(actor) or not actor.has_meta(META_ID):
		return 0
	return int(actor.get_meta(META_ID))


## The body behind a net id, or null. The host resolves a client's hit report
## through this, which is also the validation: an id nobody is standing on cannot
## be shot.
func actor_of(id: int) -> EnemyActor:
	var actor := _actor_of.get(id) as EnemyActor
	return actor if actor != null and is_instance_valid(actor) else null


func _health_byte(actor: EnemyActor) -> int:
	if not actor.alive:
		return 0
	return clampi(int(actor.health_fraction() * HP_SCALE) + 1, 1, 255)


func _species_index(id: StringName) -> int:
	var i: int = _catalogue.find(id)
	return i if i >= 0 and i < 255 else 255


func _spawner_for(faction: int) -> EnemySpawner:
	if faction < 0 or faction >= _spawners.size():
		return null
	return _spawners[faction]


## CLIENT. Put a body of the right species and faction where the host says one is.
## `spawn` scatters and snaps to the navmesh on its way in, which is right for a
## real spawn and wrong for a copy, so the transform is written again afterwards.
func _hatch(id: int, species: int, faction: int, at: Vector3, yaw: float) -> EnemyActor:
	var spawner: EnemySpawner = _spawner_for(faction)
	if spawner == null or species >= _catalogue.size():
		return null
	var actor: EnemyActor = spawner.spawn(_catalogue[species], Transform3D(Basis(), at))
	if actor == null:
		# The pool is dry or the spawner is at its cap. Not an error: the next
		# snapshot asks again, and a corpse recycling frees the slot.
		return null
	actor.global_position = at
	actor.rotation.y = yaw
	actor.set_meta(META_ID, id)
	_actor_of[id] = actor
	_net_of[actor.get_instance_id()] = id
	return actor


## CLIENT. One body, one tick of correction.
func _drive(actor: EnemyActor, to: Vector3, yaw: float, hp: int, interval: float) -> void:
	if hp == 0:
		if actor.alive:
			actor.kill(actor.global_position - actor.global_basis.z)
		return
	if not actor.alive:
		return
	# The host's health, over this machine's predicted copy of it. Without this the
	# client's own rounds walk a body's health down and nothing ever walks it back,
	# so a long fight ends with a client killing bodies the host still has standing.
	# A body that has ALREADY collapsed here is left collapsed: a corpse cannot be
	# un-died, and the host will stop listing it within a corpse timer either way.
	var want: float = float(hp - 1) / HP_SCALE * actor.max_health
	if absf(actor.health - want) > actor.max_health * 0.02:
		actor.health = clampf(want, 0.01, actor.max_health)
	if actor.global_position.distance_to(to) > SNAP_DISTANCE:
		actor.global_position = to
		actor.velocity = Vector3.ZERO
		actor.halt()
	else:
		var gap: Vector3 = to - actor.global_position
		gap.y = 0.0
		var flat: float = gap.length()
		if flat > 0.02 and interval > 0.0:
			var run: float = 3.4 if actor.profile == null else actor.profile.run_speed
			actor.steer(gap, minf(flat / interval, run * CATCHUP))
		else:
			actor.halt()
	# Overridden by the motor while the body is travelling — `_tick_facing` faces a
	# moving body along its own heading, which is the same heading the host is
	# reporting — and authoritative while it is standing still shooting at somebody.
	actor.look_at_point(actor.global_position + Vector3(sin(yaw), 0.0, cos(yaw)))


## CLIENT. The host stopped listing a body. Its own spawner takes it back, which
## parks it in the pool the next hatch will draw from.
func _retire(id: int) -> void:
	var actor := _actor_of.get(id) as EnemyActor
	_actor_of.erase(id)
	if actor == null or not is_instance_valid(actor):
		return
	_net_of.erase(actor.get_instance_id())
	var spawner := actor.get_parent() as EnemySpawner
	if spawner != null:
		spawner.despawn(actor)
