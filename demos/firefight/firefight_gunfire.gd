class_name FirefightGunfire
extends Node
## What a shot does to everything that is not the thing it hit: the tracer you
## see, the report the other side hears, and the pressure it puts on whoever it
## went past.
##
## `AICombat` resolves its own hit and emits `fired`. It does not draw, it does
## not make a noise, and it does not tell the man it missed that it missed him —
## all three are deliberately outside it, because a headless duel harness must be
## able to run the same combat code with none of them present. This node is where
## they get connected for a demo that has a screen and ears.
##
## The suppression sweep is a grid query around the impact, not around the shot
## line. Sweeping the line would be the more faithful model and it costs a
## broad-phase query per metre of flight; rounds landing near a body is what
## actually pins it, and that is one query per shot against the same index
## perception already keeps warm.

## Rounds per second, across the whole battle, above which tracers are dropped.
## Everything else about a shot still happens; only the streak is rationed.
@export_range(10.0, 2000.0, 5.0) var tracer_budget_per_second: float = 220.0
## Muzzle sprite edge length in metres, in the same units `VfxMuzzle` quotes: a
## pistol is 0.05, a cannon 0.34. Quoted above a cannon on purpose — this is a
## battle watched from thirty to seventy metres out, where a 0.30 m flare is four
## pixels and the reference's own note about one-pixel lines applies.
@export_range(0.01, 1.6, 0.005) var muzzle_scale: float = 0.55
## Simultaneous muzzle flashes the pool is asked to hold. The shipped hub is
## built for one player's gun; a battle needs a whole firing line lit at once.
@export_range(1, 64, 1) var muzzle_slots: int = 28
## Fine powder particles released at the muzzle per shot: the wisp at the barrel.
@export_range(0, 6, 1) var smoke_per_shot: int = 2
## Seconds a powder wisp lives.
@export_range(0.2, 8.0, 0.05) var smoke_life: float = 2.6
## Fine puffs per second across the battle, above which the wisp is dropped. The
## fine field holds 420 particles; this keeps the standing population inside it
## and leaves the rest for impact dust.
@export_range(5.0, 400.0, 1.0) var smoke_budget_per_second: float = 85.0
## The powder bank: heavy particles per release, releases per second, how long one
## lives and how big it is.
##
## THIS IS THE EXPENSIVE EFFECT IN THE DEMO AND IT IS RATIONED SEPARATELY FOR
## THAT REASON. It is also the only one that is still on screen a second after
## the round that made it, which is what makes it the one that a still frame of a
## firefight is actually built out of — the flash lasts fifty milliseconds and the
## tracer forty-five, and at the eight to fifteen rounds a second sixty bodies
## actually put out, neither is reliably in any given frame.
##
## The cost is overdraw, and measured on the shipped 2.10 m sprite it is steep: a
## bank on every shot is about thirty live sprites and takes the scene from 179
## fps to 72.
##
## The numbers below are what came out of chasing that. RATE times PARTICLES
## times LIFE is the standing population, and the cost follows the population —
## so the way to hold a pall over the line without paying for it twice is a LOW
## rate and a LONG life, not the other way round. Two releases a second of two
## particles at seven and a half seconds is the same thirty sprites as six a
## second at two and a half, and costs the same, but it is always there instead
## of flickering in and out between one capture and the next. SIZE trades against
## count at roughly equal cost per unit of covered area, with the bigger sprite
## slightly the cheaper of the two because it is one draw and not two.
@export_range(0, 4, 1) var heavy_smoke_particles: int = 2
@export_range(0.0, 30.0, 0.25) var heavy_smoke_per_second: float = 2.0
## Seconds a bank lives. `VFXSmokeField` clamps a particle at eight.
@export_range(0.5, 8.0, 0.1) var heavy_smoke_life: float = 7.5
## Banks the ration may hold in hand, and the number it starts holding.
##
## A token bucket with a burst, and the burst is not a trick to get a better
## screenshot: the loudest moment of this battle is the first two seconds, when
## three factions that opened in contact all fire at once. A bucket that starts
## empty spends those two seconds earning its first token and the opening volley
## leaves no powder behind it at all. Starting it full puts a bank behind the
## first eight rounds and then falls back to the sustained rate, which is what
## the pall over a firing line actually does.
@export_range(1.0, 30.0, 1.0) var heavy_smoke_burst: float = 8.0
## Sprite edge length the heavy field is retuned to, in metres. The hub ships
## 2.10 m, which is a rocket motor seen from the cockpit.
@export_range(0.2, 4.0, 0.05) var heavy_smoke_size: float = 1.9
## Metres around an impact within which a hostile takes suppression.
@export_range(0.5, 12.0, 0.1) var suppression_radius: float = 3.6
## Severity applied at the impact point, falling to zero at the radius.
@export_range(0.0, 2.0, 0.01) var suppression_severity: float = 0.55
## Joules assumed for a creature's weapon report, for the hearing model. The
## bestiary's species do not carry a muzzle energy; this is a rifle-sized round,
## which is what every ranged species in the three rosters is carrying.
@export_range(50.0, 6000.0, 10.0) var report_energy: float = 1750.0
## Speed handed to the tracer pool, in m/s.
@export_range(50.0, 1400.0, 10.0) var tracer_speed: float = 780.0
## Ribbon width the hub is raised to for this demo, in metres. See
## `_scale_hub_for_a_battle` for why the shipped 0.05 m does not survive here.
@export_range(0.005, 0.3, 0.005) var tracer_width: float = 0.20

var _vfx: VfxService = null
var _targets: AITargetIndex = null
var _rows: PackedInt32Array = PackedInt32Array()
var _tracer_credit: float = 0.0
var _smoke_credit: float = 0.0
var _bank_credit: float = 0.0
var _shots: int = 0
## One reusable node the muzzle pool is pointed at. `VfxMuzzle.flash` takes a
## `Node3D` because a player's flash hangs off the viewmodel's muzzle bone and
## has to move with it; a creature's shot arrives here as a position and a
## direction with no node behind it. The pool reads the transform once and keeps
## only the point it worked out from it, so one node re-aimed per shot is the
## whole adapter — the alternative is sixty-six anchor nodes that exist to be
## read for one call each.
var _anchor: Node3D = null


func _ready() -> void:
	_bank_credit = heavy_smoke_burst
	_anchor = Node3D.new()
	_anchor.name = "MuzzleAnchor"
	add_child(_anchor)
	set_process(true)


func _process(delta: float) -> void:
	_tracer_credit = minf(_tracer_credit + tracer_budget_per_second * delta, 30.0)
	_smoke_credit = minf(_smoke_credit + smoke_budget_per_second * delta, 20.0)
	_bank_credit = minf(_bank_credit + heavy_smoke_per_second * delta, heavy_smoke_burst)


## Bind the pieces. Called by the demo root once everything is in the tree.
func bind(vfx: VfxService, targets: AITargetIndex) -> void:
	_vfx = vfx
	_targets = targets
	_scale_hub_for_a_battle()


## The VFX hub ships tuned for a gun held at arm's length. This is the same
## effects seen from an overlook forty metres back, and three of its numbers do
## not survive that change of scale.
##
## The muzzle pool holds eight flashes, which is right for one player's weapon
## and a squad shooting back. Sixty-six bodies means those eight slots turn over
## faster than the fifty-millisecond flash life, so at any instant two or three
## are lit and a firing line does not read as one. The pool rebuilds itself on
## assignment, and a flash is a shadowless six-metre omni, so the cost of the
## extra slots is bounded by how many are actually lit.
##
## A tracer is a 0.05 m ribbon. That is a comfortable streak past your own ear
## and a two-thirds-of-a-pixel scratch at forty metres — measured, and it is why
## the first pass of this demo had a hundred rounds in the air and not one of
## them visible. Width is the only lever here: the 45 ms life is a constant on
## the hub and the right one, and widening the ribbon is what the reference's own
## note about one-pixel lines says to do.
##
## The heavy smoke sprite is 2.10 m, which is a rocket motor at arm's length and
## a white clot over a firing line; see `heavy_smoke_size`.
##
## All three are set through exported properties on the INSTANCED hub, which is
## the same thing the bake does to the world's shadow distance for this scene,
## and all three go with the scene, because the hub instance does.
func _scale_hub_for_a_battle() -> void:
	if _vfx == null:
		return
	_vfx.tracer_width = maxf(_vfx.tracer_width, tracer_width)
	var heavy: Node = _vfx.get_node_or_null(^"SmokeHeavy")
	if heavy != null:
		heavy.set(&"particle_size", heavy_smoke_size)
	var pool: Node = _vfx.get_node_or_null(^"Muzzles")
	if pool == null:
		return
	if int(pool.get(&"budget")) < muzzle_slots:
		pool.set(&"budget", muzzle_slots)


## Hook one actor. Safe to call again on a pooled body: the connection is made
## once and survives recycling, because the actor node does.
func watch(actor: EnemyActor) -> void:
	if not actor.fired.is_connected(_on_fired):
		actor.fired.connect(_on_fired.bind(actor))


func shots_fired() -> int:
	return _shots


func _on_fired(
	origin: Vector3, direction: Vector3, hit_position: Vector3, hit: Object, actor: EnemyActor
) -> void:
	_shots += 1
	var landed: Vector3 = hit_position
	if landed.distance_squared_to(origin) < 1e-4:
		landed = origin + direction * 60.0
	_draw(origin, landed, direction, hit)
	AINoiseBus.emit_gunshot(origin, report_energy, actor.faction, actor.target().target_id)
	_suppress(landed, actor.faction)


func _draw(origin: Vector3, landed: Vector3, direction: Vector3, hit: Object) -> void:
	if _vfx == null:
		return
	_muzzle(origin, direction)
	if _tracer_credit >= 1.0:
		_tracer_credit -= 1.0
		_vfx.tracer(origin, landed, tracer_speed)
	var body := hit as CollisionObject3D
	if body == null:
		return
	# A body takes its own hit reaction and bleeds through the rig; scenery gets
	# the dust and the hole. Layer is the only thing available here that tells
	# the two apart, and it is exact.
	if (body.collision_layer & (GameLayers.ENEMY | GameLayers.ENEMY_HITBOX)) != 0:
		_vfx.impact(landed, -direction, VFXSurface.Kind.FLESH, 0.8)
		return
	var kind: int = VFXSurface.Kind.METAL
	if (body.collision_layer & GameLayers.WORLD) != 0:
		kind = VFXSurface.Kind.SAND
	_vfx.impact(landed, -direction, kind, 1.0)


## The flash at the barrel and the powder it leaves behind.
##
## `AICombat` reports the muzzle it fired from, so the flare is on the weapon and
## not on the body's origin. The anchor is aimed with `looking_at`, whose -Z is
## the direction it is given, and the pool leads its sprite along exactly that
## axis — so the flare sits a few centimetres in front of the barrel rather than
## inside it.
func _muzzle(origin: Vector3, direction: Vector3) -> void:
	if direction.length_squared() < 1e-6:
		return
	_anchor.global_transform = Transform3D(Basis.looking_at(direction), origin)
	_vfx.muzzle_flash(_anchor, muzzle_scale)
	# Ahead of the muzzle, not on it: powder leaves the barrel travelling, and a
	# puff centred on the weapon sits inside the body that fired it.
	# Sooty, not white. The smoke field settles every puff toward a pale grey
	# haze, which on a sun-bleached sand floor is the same value as the ground it
	# is standing on and disappears into it; powder over a firing line has to be
	# the darkest thing on the field or it is not there at all.
	var at: Vector3 = origin + direction * 0.55
	if smoke_per_shot > 0 and _smoke_credit >= 1.0:
		_smoke_credit -= 1.0
		_vfx.puff(at, smoke_per_shot, 0.55, 0.52, smoke_life)
	if heavy_smoke_particles > 0 and _bank_credit >= 1.0:
		_bank_credit -= 1.0
		_vfx.puff(at + Vector3.UP * 0.4, heavy_smoke_particles, 1.4, 0.55, heavy_smoke_life, true)


## Everything hostile standing near where the round landed leans on its weapon a
## little harder and shoots a little wider. This is the entire reason a squad
## that is being shot at stops walking down the middle of the road.
func _suppress(at: Vector3, faction: int) -> void:
	if _targets == null or suppression_severity <= 0.0:
		return
	var n: int = _targets.hostiles_near(at, suppression_radius, faction, _rows)
	for k: int in n:
		var row: int = _rows[k]
		var node: AITarget = _targets.node(row)
		var actor := node.body() as EnemyActor
		if actor == null or actor.weapon == null:
			continue
		var d: float = at.distance_to(_targets.aim_point(row))
		var falloff: float = 1.0 - clampf(d / suppression_radius, 0.0, 1.0)
		if falloff <= 0.01:
			continue
		var away: Vector3 = _targets.position_at(row) - at
		actor.weapon.take_suppression(suppression_severity * falloff, away.normalized())
