extends RefCounted
## ONE PLAYER'S GUN, AS THE HOST RESOLVES IT.
##
## A client runs a whole `Weapon` of its own — trigger, cadence, magazine, jam,
## recoil, tracer, muzzle flash — because that is what makes shooting feel instant
## and none of it needs anybody's permission. What a client may NOT do is decide
## what it hit. So it sends the host the lines its pellets went down, and this
## object re-traces them against the host's own physics world with the host's own
## copy of that player's weapon. The host decides what was struck, what it took and
## what it scored; the client finds out.
##
## THE PAYLOAD IS DIRECTIONS, NOT DAMAGE. Amount comes from `spec`, which the host
## granted in the first place — the equip button is authoritative, so the loadout
## is too. A client cannot inflate a number it never sends. What it CAN influence
## is where its pellets went, so every direction is checked against the widest cone
## this weapon is physically able to produce (`_max_half_cone`: no shouldering,
## sprinting, airborne, bloom saturated) and anything outside it is folded back
## onto the honest aim line rather than refused, because a refusal caused by a
## packet arriving one frame late reads to the player as the gun not working.
##
## It is deliberately the same parts a real `Weapon` uses — `GunHitscan`,
## `GunDamage`, `GunProjectilePool` — assembled the same way `Weapon._throw_payload`
## assembles them, so a launcher lobs a shell on the host exactly as it does in the
## client's hands and a penetrating rifle round still goes through the tin.
##
## No visual effects live here. The host draws a remote player's tracer from the
## broadcast that `RangeNet` sends off `on_tracer`, the same one every other
## machine draws it from, so there is one code path for the picture and not two.

## Shortest projectile spawn distance, metres. `Weapon.MIN_PROJECTILE_STANDOFF`.
const MIN_STANDOFF: float = 1.4
## Blast standoff from the surface a shell detonates against, metres.
const BLAST_STANDOFF: float = 0.25
## Angular slack added to the validation cone, radians — 0.63 degrees. Absorbs the
## float error of a direction that went out as a world-space point and came back.
const CONE_SLACK: float = 0.011
## Speed the validation cone is evaluated at. Past `move_reference_speed` the
## penalty clamps, so this only has to be "sprinting" to reach the ceiling.
const CONE_SPEED: float = 20.0
## Surface id reported for a pellet that hit nothing.
const NO_SURFACE: int = -1

## Whose gun this is.
var peer: int = 0
## What the host says they are holding. Null until the bench grants them one.
var spec: GunSpec = null
## `on_hit(collider, at, normal, amount, surface)` — one arriving pellet, resolved.
var on_hit: Callable = Callable()
## `on_tracer(from, to, surface)` — where a pellet's streak should be drawn.
## `surface` is `NO_SURFACE` when the pellet hit nothing.
var on_tracer: Callable = Callable()
## `on_blast(at, radius)` — a warhead went off.
var on_blast: Callable = Callable()

var _damage: GunDamage = GunDamage.new()
var _hitscan: GunHitscan = GunHitscan.new()
var _projectiles: GunProjectilePool = GunProjectilePool.new()
var _spread: GunSpread = GunSpread.new()
var _exclude: Array[RID] = []
var _space: PhysicsDirectSpaceState3D = null
var _pellet_damage: float = 0.0
var _pellet_dir: Vector3 = Vector3.FORWARD
var _pellet_hit: bool = false
var _tracer_end: Vector3 = Vector3.ZERO
var _surface: int = NO_SURFACE
var _max_half_cone: float = 0.0


func _init(owner_peer: int) -> void:
	peer = owner_peer
	_hitscan.on_hit = _on_hitscan_hit
	_projectiles.on_impact = _on_projectile_impact


## Take the weapon the host granted this player. Everything downstream of the roll
## is rebuilt, and the validation cone is re-derived from the new gun.
func configure(new_spec: GunSpec) -> void:
	spec = new_spec
	if spec == null:
		return
	_hitscan.configure(spec, _damage)
	_spread.configure(spec)
	_projectiles.configure()
	# The worst cone this weapon can ever throw: hip fire, sprinting, both feet off
	# the ground, bloom saturated. Anything wider than that is not a shot.
	_spread.bloom = _spread.bloom_max
	_max_half_cone = _spread.effective(0.0, CONE_SPEED, false, false) * 0.5 + CONE_SLACK


## True once this arm can resolve a shot.
func is_armed() -> bool:
	return spec != null


## Resolve one trigger pull. `points` are where the client's own pellets landed,
## which is only ever read as a set of DIRECTIONS from `origin`; a pellet the
## client reported no impact for, or that is missing entirely, goes down `aim`.
##
## `muzzle` decides nothing — it is where the streak is drawn from, so a remote
## player's tracer leaves their gun rather than the bridge of their nose.
func fire(
	space: PhysicsDirectSpaceState3D,
	origin: Vector3,
	muzzle: Vector3,
	aim: Vector3,
	points: PackedVector3Array
) -> void:
	if spec == null or space == null:
		return
	if not origin.is_finite() or not aim.is_finite() or aim.length_squared() < 1.0e-6:
		return
	_space = space
	var pellets: int = maxi(spec.pellets, 1)
	var window: float = maxf(spec.headshot_range, MIN_STANDOFF)
	var line: Vector3 = aim.normalized()
	_pellet_damage = spec.damage / float(pellets)
	for i: int in clampi(points.size(), 1, pellets):
		var dir: Vector3 = _pellet_direction(origin, line, points, i)
		_pellet_dir = dir
		_pellet_hit = false
		_surface = NO_SURFACE
		_tracer_end = _hitscan.trace(space, origin, dir, window, _exclude)
		if not _pellet_hit:
			var start: Vector3 = origin + dir * window
			_projectiles.spawn(start, dir, float(spec.sim_velocity), spec, _pellet_damage, window)
			_tracer_end = start
		if on_tracer.is_valid():
			on_tracer.call(muzzle, _tracer_end, _surface)


## Advance anything this arm put in the air. Called from the host's physics frame.
func step(delta: float, space: PhysicsDirectSpaceState3D) -> void:
	if space == null:
		return
	_space = space
	_projectiles.step(delta, space, _hitscan, _exclude)


## Live projectiles, for a debug line.
func in_flight() -> int:
	return _projectiles.active_count()


## Drop anything still in the air. A range reset, or the player leaving.
func clear() -> void:
	_projectiles.clear()


## The direction pellet `i` actually went. A reported point outside the widest
## cone this gun can produce is folded onto the aim line instead of being thrown
## away: a stale packet is not a cheat and refusing it silently eats the shot.
func _pellet_direction(
	origin: Vector3, aim: Vector3, points: PackedVector3Array, i: int
) -> Vector3:
	if i >= points.size():
		return aim
	var offset: Vector3 = points[i] - origin
	if not offset.is_finite() or offset.length_squared() < 1.0e-6:
		return aim
	var dir: Vector3 = offset.normalized()
	return dir if dir.angle_to(aim) <= _max_half_cone else aim


func _on_hitscan_hit(
	collider: Object, at: Vector3, normal: Vector3, distance: float, scale: float, surface: int
) -> void:
	_pellet_hit = true
	_tracer_end = at
	_surface = surface
	_arrive(collider, at, normal, distance, _pellet_damage * scale, _pellet_dir, surface)


func _on_projectile_impact(
	collider: Object,
	at: Vector3,
	normal: Vector3,
	distance: float,
	dmg: float,
	from_spec: GunSpec,
	dir: Vector3
) -> void:
	_arrive(collider, at, normal, distance, dmg, dir, _damage.surface_of(collider), from_spec)


## One round arriving somewhere, however it got there. `Weapon._arrive` without the
## effects: the host's picture of a remote player's shot is a broadcast, not a
## second local draw, or the host would see every impact twice.
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
	var use: GunSpec = from_spec if from_spec != null else spec
	if use == null:
		return
	if use.explosive:
		_detonate(at + normal * BLAST_STANDOFF, use)
		return
	var zone: StringName = _damage.zone_of(collider)
	var amount: float = _damage.resolve(base, distance, use, zone)
	_damage.apply(collider, amount, at, normal, dir, use.crit_multiplier)
	_damage.push(collider, at, dir, use.impulse)
	if on_hit.is_valid():
		on_hit.call(collider, at, normal, amount, surface)


func _detonate(at: Vector3, use: GunSpec) -> void:
	var radius: float = maxf(use.blast_radius, 0.5)
	_damage.blast(_space, at, use.damage, radius, _exclude)
	if on_blast.is_valid():
		on_blast.call(at, radius)
