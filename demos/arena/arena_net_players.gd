class_name ArenaNetPlayers
extends RefCounted
## The host's ledger of what the compound has done to everybody. HOST ONLY.
##
## Four people are in the room and only one of them is standing on this machine.
## The other three are `PlayerAvatar`s driven by `NetPresence`, and something has to
## make them shootable, keep the number that says how shot they are, and decide when
## one of them has run out. That is this.
##
## WHY THE HOST HOLDS THE NUMBER. The AI only exists here. Every round that reaches
## a player was fired by a body this machine is simulating, resolved by a raycast
## this machine cast, against a silhouette this machine placed. Sending "you were
## hit for 23" and letting the owner keep their own tally would work right up to the
## first packet loss, after which two machines disagree about whether somebody is
## alive — and being alive is the one thing in this demo that everybody has to agree
## on, because the AI stops shooting at the dead. So the host keeps health, death
## and the respawn clock, and the owner's `PlayerHealth` is told what it is.
##
## THE TUNING IS NOT COPIED. `bind` reads `max_health`, `armour`, `damage_scale` and
## the whole regeneration and death policy off the host's OWN `PlayerHealth` node,
## which is the same baked prefab every client is running. One set of numbers, in
## the file that documents them, and a designer who turns `regen_delay` turns it for
## the session rather than for the host.
##
## The host's own player is NOT in this table. It has a real body, a real
## `PlayerHealth` and a real `AITarget` that `ArenaController` registered before any
## of this ran; putting it in here as well would be two ledgers for one man.

## A round reached somebody. `health` is what they have left, out of `maximum`.
signal player_hurt(peer_id: int, taken: float, from_position: Vector3, health: float)
## Somebody ran out.
signal player_down(peer_id: int, from_position: Vector3)
## Somebody's respawn clock finished.
signal player_up(peer_id: int, health: float)

## Seconds of avatar travel a speed sample is measured over. The avatar's transform
## arrives at 18 Hz, so anything shorter is measuring jitter.
const SPEED_WINDOW: float = 0.15
## Metres a second a sprinting player can actually cover. `PlayerController` tops
## out under this; anything faster is a teleport and is not heard as movement.
const TOP_SPEED: float = 12.0

var maximum: float = 100.0

var _director: ArenaDirector = null
var _armour: float = 0.0
var _scale: float = 1.0
var _regen_on: bool = true
var _regen_delay: float = 6.0
var _regen_rate: float = 12.0
var _regen_ceiling: float = 1.0
var _death_seconds: float = 2.4
var _spawn_protection: float = 1.5
## peer id -> {health, alive, quiet, clock, grace, mark, at, speed}
var _rows: Dictionary = {}


## Take the arena's own player tuning and the director every mark is registered
## with. `tuning` is the host's local `PlayerHealth`; null leaves the defaults.
func bind(director: ArenaDirector, tuning: PlayerHealth) -> void:
	_director = director
	if tuning == null:
		return
	maximum = tuning.max_health
	_armour = tuning.armour
	_scale = tuning.damage_scale
	_regen_on = tuning.regen_enabled
	_regen_delay = tuning.regen_delay
	_regen_rate = tuning.regen_rate
	_regen_ceiling = tuning.regen_ceiling
	_death_seconds = tuning.death_seconds
	_spawn_protection = tuning.spawn_protection


## Reconcile against the roster and against what `NetPresence` has actually built.
## An avatar can arrive several frames after the player does, and it is replaced
## outright if a peer's presence is torn down, so the mark is re-checked every tick
## rather than hung once on a `peer_joined`.
func refresh(local_id: int) -> void:
	var seen: Dictionary = {}
	var presence: NetPresence = NetPresence.instance()
	for who: NetPlayer in NetGame.players():
		if who.peer_id == local_id:
			continue
		seen[who.peer_id] = true
		var row: Dictionary = _row(who.peer_id)
		var avatar: Node3D = null
		if presence != null:
			avatar = presence.avatar_of(who.peer_id)
		_re_mark(row, who.peer_id, avatar)
	for id: int in _rows.keys():
		if not seen.has(id):
			_release(int(id))


## Regeneration, death clocks and the noise a moving body makes. One tick.
func tick(delta: float) -> void:
	for id: int in _rows:
		var row: Dictionary = _rows[id]
		row[&"grace"] = maxf(float(row[&"grace"]) - delta, 0.0)
		_track(row, delta)
		if not bool(row[&"alive"]):
			_tick_down(int(id), row, delta)
			continue
		row[&"quiet"] = float(row[&"quiet"]) + delta
		_regenerate(row, delta)
		_publish(row)


## THE DECISION. A round resolved against somebody's silhouette; this is the only
## place a player's health moves. Returns what actually came off, which is zero for
## a refused hit.
func hurt(peer_id: int, amount: float, from_position: Vector3) -> float:
	if not _rows.has(peer_id):
		return 0.0
	var row: Dictionary = _rows[peer_id]
	if not bool(row[&"alive"]) or float(row[&"grace"]) > 0.0:
		return 0.0
	# IDENTICAL to `PlayerHealth.apply_damage` and to `EnemyActor.apply_damage`: a
	# point of damage has to mean the same thing whichever side of the fight it
	# landed on, and whichever machine resolved it.
	var taken: float = amount * _scale * (1.0 - clampf(_armour, 0.0, 95.0) * 0.01)
	if taken <= 0.0:
		return 0.0
	taken = minf(taken, float(row[&"health"]))
	row[&"health"] = float(row[&"health"]) - taken
	row[&"quiet"] = 0.0
	_publish(row)
	player_hurt.emit(peer_id, taken, from_position, float(row[&"health"]))
	if float(row[&"health"]) <= 0.0:
		row[&"health"] = 0.0
		row[&"alive"] = false
		row[&"clock"] = 0.0
		_publish(row)
		player_down.emit(peer_id, from_position)
	return taken


## Health of one player as a fraction, and whether they are up. Missing peers read
## as a full bar so a roster line drawn a frame early is not a lie.
func fraction_of(peer_id: int) -> float:
	if not _rows.has(peer_id):
		return 1.0
	var row: Dictionary = _rows[peer_id]
	return clampf(float(row[&"health"]) / maxf(maximum, 0.001), 0.0, 1.0)


func is_alive(peer_id: int) -> bool:
	if not _rows.has(peer_id):
		return true
	return bool((_rows[peer_id] as Dictionary)[&"alive"])


func health_of(peer_id: int) -> float:
	if not _rows.has(peer_id):
		return maximum
	return float((_rows[peer_id] as Dictionary)[&"health"])


## A player asked to be put back on their feet early, or the demo did. Idempotent.
func revive(peer_id: int) -> void:
	if not _rows.has(peer_id):
		return
	var row: Dictionary = _rows[peer_id]
	row[&"health"] = maximum
	row[&"alive"] = true
	row[&"clock"] = 0.0
	row[&"quiet"] = 0.0
	row[&"grace"] = _spawn_protection
	_publish(row)
	player_up.emit(peer_id, maximum)


## Take every mark back off every avatar. The avatars belong to `NetPresence` and
## outlive the demo, so this is not optional tidying — a mark left on one would be
## a target row in the next demo's AI.
func drop_all() -> void:
	for id: int in _rows.keys():
		_release(int(id))
	_rows.clear()


func _row(peer_id: int) -> Dictionary:
	if _rows.has(peer_id):
		return _rows[peer_id]
	var row: Dictionary = {
		&"health": maximum,
		&"alive": true,
		&"quiet": 1.0e9,
		&"clock": 0.0,
		&"grace": _spawn_protection,
		&"mark": null,
		&"at": Vector3.ZERO,
		&"speed": 0.0,
	}
	_rows[peer_id] = row
	return row


## Hang a mark on this peer's avatar, or move it if the avatar was replaced.
func _re_mark(row: Dictionary, peer_id: int, avatar: Node3D) -> void:
	var mark := row[&"mark"] as ArenaPlayerMark
	if mark != null and is_instance_valid(mark) and mark.get_parent() == avatar:
		return
	if mark != null and is_instance_valid(mark):
		_unregister(mark)
	row[&"mark"] = null
	if avatar == null or not is_instance_valid(avatar):
		return
	var fresh: ArenaPlayerMark = ArenaPlayerMark.attach(avatar, peer_id)
	if fresh == null:
		return
	# `attach` adopts a mark already on the avatar, so the connection is checked
	# rather than assumed: connecting twice would take every hit off twice.
	if not fresh.wounded.is_connected(_on_wounded):
		fresh.wounded.connect(_on_wounded)
	if _director != null:
		_director.register_target(fresh.target(), false)
	fresh.set_health(fraction_of(peer_id), bool(row[&"alive"]))
	# Seeded, not left at the origin: the first travel sample of a mark whose last
	# position is Vector3.ZERO is the whole distance to the compound in one tick,
	# which the AI would hear as somebody sprinting past its ear.
	row[&"at"] = fresh.global_position
	row[&"speed"] = 0.0
	row[&"mark"] = fresh


func _release(peer_id: int) -> void:
	if not _rows.has(peer_id):
		return
	var row: Dictionary = _rows[peer_id]
	var mark := row[&"mark"] as ArenaPlayerMark
	if mark != null and is_instance_valid(mark):
		_unregister(mark)
	_rows.erase(peer_id)


## Take one mark out of the world. The director is checked for validity as well as
## for null: this also runs from the demo's teardown, where the node it points at
## may already be on its way out with the rest of the scene.
func _unregister(mark: ArenaPlayerMark) -> void:
	if _director != null and is_instance_valid(_director):
		_director.unregister_target(mark.target())
	mark.drop()


## Avatar travel, for the footfall noise the AI hears. The avatar is somebody
## else's `move_and_slide` and has no velocity on this machine, so it is measured.
func _track(row: Dictionary, delta: float) -> void:
	var mark := row[&"mark"] as ArenaPlayerMark
	if mark == null or not is_instance_valid(mark) or delta <= 0.0:
		return
	var here: Vector3 = mark.global_position
	var was: Vector3 = row[&"at"]
	var moved: float = Vector2(here.x - was.x, here.z - was.z).length()
	# Bounded by what a body can actually do. A respawn is a teleport, and a
	# teleport is not a sound.
	var sample: float = minf(moved / delta, TOP_SPEED)
	# Smoothed over a window rather than taken raw: the transform arrives at 18 Hz
	# and the tick runs at 60, so four ticks in five measure a speed of zero.
	var k: float = clampf(delta / SPEED_WINDOW, 0.0, 1.0)
	row[&"speed"] = lerpf(float(row[&"speed"]), sample, k)
	row[&"at"] = here
	mark.set_speed(float(row[&"speed"]))


func _regenerate(row: Dictionary, delta: float) -> void:
	if not _regen_on or float(row[&"quiet"]) < _regen_delay:
		return
	var ceiling: float = maximum * clampf(_regen_ceiling, 0.0, 1.0)
	if float(row[&"health"]) >= ceiling:
		return
	row[&"health"] = minf(float(row[&"health"]) + _regen_rate * delta, ceiling)


func _tick_down(peer_id: int, row: Dictionary, delta: float) -> void:
	row[&"clock"] = float(row[&"clock"]) + delta
	if float(row[&"clock"]) < _death_seconds:
		return
	revive(peer_id)


## Push the ledger onto the mark, so the AI's flinch model and `AIMorale` read the
## same health the owner is looking at.
func _publish(row: Dictionary) -> void:
	var mark := row[&"mark"] as ArenaPlayerMark
	if mark != null and is_instance_valid(mark):
		mark.set_health(
			clampf(float(row[&"health"]) / maxf(maximum, 0.001), 0.0, 1.0), bool(row[&"alive"])
		)


func _on_wounded(peer_id: int, amount: float, from_position: Vector3) -> void:
	hurt(peer_id, amount, from_position)
