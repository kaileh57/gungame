class_name RangeTarget
extends Node3D
## One thing on the range you are allowed to shoot, and everything that happens
## when you do: damage, swing, knock-down, score and the reset clock.
##
## The six kinds in `docs/spec/range.md` §15.2 differ in about a dozen numbers and
## in nothing else, so they are one script with a `kind` rather than six scripts
## with one parent. What changes per kind is the reset delay, the score formula
## and whether the body disappears when it dies; the swing, the impulse
## accumulator and the reset are shared.
##
## HOW A ROUND GETS HERE. The shootable parts are `StaticBody3D` children on the
## PROP layer carrying `zone` metadata — `body` on the plate, `head` on the
## scoring spot. `GunDamage.apply` walks up from whichever one the ray found and
## lands on `apply_bullet_damage` here. Nothing polls; a target that is standing
## still and undamaged is not even processing.
##
## WHO DECIDES. `authority` is true in single-player and on the host, and false on
## a client. A target that is not the authority takes no damage, keeps no clock and
## scores nothing: the round a client fires still throws its own sparks, because
## that is the gun's business and it is cosmetic, but whether the plate rang, went
## over or paid out is the host's answer and arrives through `remote_hit`,
## `remote_down`, `remote_boom` and `restore`. `remote_sync` is the half-second
## backstop that puts a target that somehow drifted back where it belongs.

## Points were earned. `label` is what a readout should print — the damage, or a
## word like DOWN when the shot finished the target. `kind` is the damage-pop
## style the HUD should draw it in, so the caller never has to parse the label.
signal scored(points: int, at: Vector3, label: String, kind: StringName)
## The target went down. Carries the seconds until it stands back up.
signal downed(target: RangeTarget, reset_in: float)
## A round landed. `crit` is a head-zone hit, `killed` is the shot that finished it.
signal registered(crit: bool, killed: bool)
## A round landed, with what it actually did. Fires only where the target is the
## authority, and carries the one number `scored` does not: the damage. It is what
## the demo replicates so a client's plate rings by the same amount.
signal struck(amount: float, at: Vector3, crit: bool)
## The target healed and stood back up.
signal restored(target: RangeTarget)

enum Kind { PLATE, POPPER, BOTTLE, BARREL, PAPER, MOVER }

## Every target joins this. The bench's RESET button, the blast solver and the
## scoreboard all find their work through it rather than through node paths.
const GROUP: StringName = &"range_targets"

## Barrel detonation: fixed damage over a fixed radius, whatever set it off.
const BLAST_DAMAGE: float = 200.0
const BLAST_RADIUS: float = 9.5
## Sympathetic detonation delay window, seconds. A row of drums goes off as a
## string of separate bangs rather than as one.
const CHAIN_DELAY_MIN: float = 0.09
const CHAIN_DELAY_MAX: float = 0.25

## Damage-pop styles, matching the keys `DamagePops.KINDS` knows.
const POP_HIT: StringName = &"hit"
const POP_CRIT: StringName = &"crit"
const POP_DOWN: StringName = &"down"
const POP_BOOM: StringName = &"boom"
const POP_BREAK: StringName = &"break"

@export var kind: Kind = Kind.PLATE
@export_range(1.0, 5000.0, 1.0) var max_health: float = 60.0
## Score for putting this target down, and the base the per-hit score is built on.
@export_range(0, 400, 1) var points: int = 16
## Nominal half-size, metres. Sizes the impact spark burst and the blast reach.
@export_range(0.05, 3.0, 0.01) var target_radius: float = 0.30
## Seconds face-down before it stands back up. Zero never resets.
@export_range(0.0, 30.0, 0.5) var reset_seconds: float = 5.0
## Distance down-range this target was placed at, metres. Display only.
@export_range(0.0, 500.0, 0.5) var distance_hint: float = 15.0

@export_group("Swing")
## The node the impulse rotates. Left empty on targets that do not move.
@export var swing_path: NodePath = NodePath()
## Hardest angle a live target swings to, radians. The reference's ±0.55.
@export_range(0.05, 1.2, 0.01) var swing_limit: float = 0.55
## Fraction of the angular velocity left after one second.
@export_range(0.001, 0.9, 0.001) var swing_velocity_retain: float = 0.05
## Fraction of the angle left after one second.
@export_range(0.001, 0.9, 0.001) var swing_angle_retain: float = 0.02
## Angle a downed target falls to, radians.
@export_range(0.5, 2.0, 0.01) var down_angle: float = 1.35
@export_range(1.0, 20.0, 0.5) var down_rate: float = 7.0
## Newton-seconds of swing per point of damage, before the clamp.
@export_range(0.0, 0.1, 0.001) var swing_per_damage: float = 0.012

@export_group("Track")
## Half the travel of a mover, metres. Zero holds it still.
@export_range(0.0, 20.0, 0.1) var track_span: float = 0.0
@export_range(0.0, 6.0, 0.01) var track_speed: float = 1.15
@export_range(0.0, 6.3, 0.01) var track_phase: float = 0.0

var health: float = 60.0
var alive: bool = true
## True in single-player and on the host. A client's targets decide nothing; see
## the class docstring. Written once by the demo before anything can be shot.
var authority: bool = true

var _swing: Node3D = null
var _down_timer: float = 0.0
var _swing_velocity: float = 0.0
var _swing_angle: float = 0.0
var _bodies: Array[CollisionObject3D] = []
var _visuals: Array[VisualInstance3D] = []
var _home_x: float = 0.0


func _ready() -> void:
	add_to_group(GROUP)
	health = max_health
	_home_x = position.x
	_swing = get_node_or_null(swing_path) as Node3D
	_collect(self)
	set_process(is_mover())
	set_physics_process(false)


func _process(delta: float) -> void:
	if is_mover() and track_span > 0.0:
		track_phase = fposmod(track_phase + delta * track_speed, TAU)
		position.x = _home_x + sin(track_phase) * track_span
	var busy: bool = _tick_swing(delta)
	busy = _tick_reset(delta) or busy
	if not busy and not is_mover():
		set_process(false)


func is_mover() -> bool:
	return kind == Kind.MOVER


## True while the target is standing and can be hurt.
func is_live() -> bool:
	return alive


## Say whether this machine decides what happens to this target. The demo calls it
## for every target once, before a round can possibly be in the air.
func set_authority(on: bool) -> void:
	authority = on


## A round arrived. This is the contract `GunDamage.apply` calls; the trailing
## `crit` is the weapon's own headshot multiplier, which is why the score bonus
## is decided by the zone and not by the multiplier's size.
func apply_bullet_damage(
	amount: float, at: Vector3, _normal: Vector3, _dir: Vector3, zone: StringName, _crit: float
) -> void:
	take_hit(amount, at, zone == GunDamage.ZONE_HEAD)


## Anything that is not a bullet — a blast, a debug poke — comes in here.
func take_damage(amount: float) -> void:
	take_hit(amount, global_position + Vector3(0.0, target_radius, 0.0), false)


## The one place a target loses health. Returns true if this shot finished it.
##
## A client never gets past the first line. Its own round has already drawn its
## spark and its hole by the time it arrives here; what the plate DID about it is
## the host's to say, and comes back through `remote_hit`.
func take_hit(amount: float, at: Vector3, crit: bool) -> bool:
	if not authority or not alive or amount <= 0.0:
		return false
	struck.emit(amount, at, crit)
	match kind:
		Kind.BOTTLE:
			_break_glass(at)
			return true
		Kind.BARREL:
			health -= amount
			scored.emit(roundi(amount * 0.2), at, str(roundi(amount)), POP_HIT)
			registered.emit(crit, health <= 0.0)
			if health <= 0.0:
				detonate()
				return true
			_kick(amount, crit)
			return false
		_:
			health -= amount
			_kick(amount, crit)
			var finished: bool = health <= 0.0
			var gained: int = roundi(
				(amount * 0.35 + float(points) * 0.25) * (1.6 if crit else 1.0)
			)
			scored.emit(gained, at, str(roundi(amount)), POP_CRIT if crit else POP_HIT)
			registered.emit(crit, finished)
			if finished:
				scored.emit(points, at, "DOWN", POP_DOWN)
				knock_down()
			return finished


## Put the target down for `reset_seconds`. Poppers and plates fall over; bottles
## and drums are simply gone.
func knock_down() -> void:
	if not alive:
		return
	alive = false
	health = 0.0
	_down_timer = reset_seconds
	var vanish: bool = kind == Kind.BOTTLE or kind == Kind.BARREL
	for body: CollisionObject3D in _bodies:
		body.process_mode = Node.PROCESS_MODE_DISABLED
	if vanish:
		for visual: VisualInstance3D in _visuals:
			visual.visible = false
	downed.emit(self, reset_seconds)
	set_process(true)


## Stand it back up, whole. Called by the reset clock and by the bench's RESET.
func restore() -> void:
	alive = true
	health = max_health
	_down_timer = 0.0
	_swing_velocity = 0.0
	_swing_angle = 0.0
	if _swing != null:
		_swing.rotation.x = 0.0
	for body: CollisionObject3D in _bodies:
		body.process_mode = Node.PROCESS_MODE_INHERIT
	for visual: VisualInstance3D in _visuals:
		visual.visible = true
	restored.emit(self)
	set_process(is_mover())


## Blow the drum. Fixed 200 damage over 9.5 m regardless of what set it off, and
## anything it kills that is itself a drum goes up on its own short fuse.
func detonate() -> void:
	if not authority or not alive or kind != Kind.BARREL:
		return
	var centre: Vector3 = remote_boom()
	scored.emit(points * 3, centre, "BOOM", POP_BOOM)
	registered.emit(false, true)
	downed.emit(self, reset_seconds)
	splash(global_position, BLAST_DAMAGE, BLAST_RADIUS, self)


# --- what the host says happened ---------------------------------------------


## A round landed, on the host's authority. Cosmetic only: the swing kick and the
## reason to keep processing. Scoring, the fall and the reset clock all arrive as
## their own events, because they are separate decisions and one of them can
## happen without the others.
func remote_hit(amount: float, at: Vector3, crit: bool) -> void:
	if authority:
		return
	_kick(amount, crit)
	_note_remote_hit(at)


## What a subclass does with a replicated hit beyond ringing. The paper target puts
## a hole in itself here; everything else has nothing to add.
func _note_remote_hit(_at: Vector3) -> void:
	pass


## The host put this target down.
func remote_down() -> void:
	if not authority:
		knock_down()


## The host blew this drum. Returns the blast centre so `detonate` can reuse it —
## the two are the same act, and the only difference is who decided.
func remote_boom() -> Vector3:
	var centre: Vector3 = global_position + Vector3(0.0, 0.5, 0.0)
	alive = false
	health = 0.0
	_down_timer = reset_seconds
	for body: CollisionObject3D in _bodies:
		body.process_mode = Node.PROCESS_MODE_DISABLED
	for visual: VisualInstance3D in _visuals:
		visual.visible = false
	VfxService.spawn_explosion(centre, BLAST_RADIUS * 0.45)
	VfxService.spawn_puff(centre, 24, 1.0, 0.9, 3.0, true)
	set_process(true)
	return centre


## The half-second reconcile. Standing or not, and where a mover is along its
## track — the one piece of continuous state a client cannot derive, and the one
## that decides whether a shot the player saw connect connected on the host.
func remote_sync(standing: bool, phase: float) -> void:
	if authority:
		return
	if is_mover() and track_span > 0.0:
		track_phase = phase
	if standing and not alive:
		restore()
	elif not standing and alive:
		knock_down()


## Hand a blast out to everything standing inside `radius` of `centre`. Distance
## is measured to each target's own origin, which is ground level for a plate —
## the reference's rule, and the one the scoring numbers were tuned against.
static func splash(centre: Vector3, damage: float, radius: float, source: RangeTarget) -> int:
	if radius <= 0.0 or source == null:
		return 0
	var hits: int = 0
	for node: Node in source.get_tree().get_nodes_in_group(GROUP):
		var target := node as RangeTarget
		if target == null or target == source or not target.alive:
			continue
		if target.kind == Kind.PAPER:
			continue
		var reach: float = centre.distance_to(target.global_position)
		if reach > radius:
			continue
		var falloff: float = 1.0 - reach / radius
		hits += 1
		target._swing_velocity += 1.35 * falloff
		target.set_process(true)
		if target.kind == Kind.BARREL:
			if target.health - damage * falloff <= 0.0:
				target.fuse(source)
			else:
				target.health -= damage * falloff
			continue
		target.health -= damage * falloff
		if target.health <= 0.0:
			target.scored.emit(target.points, target.global_position, "DOWN", POP_DOWN)
			target.registered.emit(false, true)
			target.knock_down()
	return hits


## Arm a sympathetic detonation on a short random fuse, re-checking on the way in
## that the drum is still standing — a second blast may have taken it already.
func fuse(source: RangeTarget) -> void:
	var rand: float = randf()
	var delay: float = lerpf(CHAIN_DELAY_MIN, CHAIN_DELAY_MAX, rand)
	var timer: SceneTreeTimer = get_tree().create_timer(delay, false)
	timer.timeout.connect(_on_fuse.bind(source))


func _on_fuse(_source: RangeTarget) -> void:
	if alive:
		detonate()


## Bottles are one-hit: no health, no swing, they are just gone and they cost the
## shooter nothing to miss, which is why they are worth thirty a piece.
func _break_glass(at: Vector3) -> void:
	VfxService.spawn_impact(at, Vector3.UP, VFXSurface.Kind.GLASS, 1.2)
	scored.emit(points, at, "BREAK", POP_BREAK)
	registered.emit(false, true)
	knock_down()


func _kick(amount: float, crit: bool) -> void:
	if _swing == null:
		return
	_swing_velocity += clampf(amount * swing_per_damage, 0.05, 1.6) * (1.5 if crit else 1.0)
	set_process(true)


## Returns true while the target still needs a frame. A plate that has stopped
## ringing takes itself off the process list until the next round lands.
func _tick_swing(delta: float) -> bool:
	if _swing == null:
		return false
	if not alive:
		var fall: float = 1.0 - exp(-down_rate * delta)
		_swing.rotation.x += (down_angle - _swing.rotation.x) * fall
		return absf(down_angle - _swing.rotation.x) > 0.002
	_swing_velocity *= pow(swing_velocity_retain, delta)
	_swing_angle += _swing_velocity * delta * 6.0
	_swing_angle *= pow(swing_angle_retain, delta)
	_swing.rotation.x = clampf(_swing_angle, -swing_limit, swing_limit)
	return absf(_swing_angle) > 0.001 or absf(_swing_velocity) > 0.001


## The reset clock is a timer of record, so a client does not run one: it stands
## its target back up when the host says so and not a frame before, or two machines
## drift apart by however far their two clocks did.
func _tick_reset(delta: float) -> bool:
	if alive or reset_seconds <= 0.0 or not authority:
		return false
	_down_timer -= delta
	if _down_timer > 0.0:
		return true
	restore()
	return false


func _collect(node: Node) -> void:
	for child: Node in node.get_children():
		var body := child as CollisionObject3D
		if body != null:
			_bodies.append(body)
		var visual := child as VisualInstance3D
		if visual != null:
			_visuals.append(visual)
		_collect(child)
