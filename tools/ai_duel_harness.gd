extends Node
## Headless proof that the fighting works: bake cover over a synthetic arena, then
## run two agents at each other with real guns, real rays and real suppression and
## count what comes out.
##
## The arena is built here rather than loaded because the demos are not the thing
## under test — the combat is. A floor, a navigation quad, a scatter of crouch and
## standing obstructions, and two bodies is enough to exercise every path:
## sampling, the grid index, the claim ledger, the engagement band, the peek
## cycle, near-miss suppression, and the corridor test that stops an agent
## shooting its own squad in the back.
##
## Physics is static here, so the simulation runs `STEPS_PER_FRAME` decision steps
## per real physics frame. Nothing moves between them and every ray is a real ray
## against the real world, so the results are what they would be in a frame.
##
## Driven by `res://tools/verify_ai_combat.gd`, which loads this at runtime so that
## it compiles with the autoloads already registered.

## The whole report, once every check has run.
signal finished(report: String)

## Agent decision step. Matches the physics tick the director would run them on.
const DT: float = 1.0 / 60.0
## Decision steps packed into one real physics frame. The world is static, so this
## only changes how long the harness takes to run, never what it measures.
const STEPS_PER_FRAME: int = 40
## Simulated seconds before a duel is called endless.
const MAX_SECONDS: float = 90.0
## Metres between the two duellists.
const DUEL_SEPARATION: float = 22.0
const ARENA_HALF: float = 24.0
## Hit points, expressed as how many landed rounds a body is worth. Rolled guns
## range from 20 to 500 damage a shot, so a fixed pool would make one duel a
## single trigger pull and the next a war of attrition; scaling the body to the
## deadlier of the two guns is what keeps the measurement about the AI.
const SHOTS_TO_KILL: float = 8.0
const HEALTH: float = 140.0
const MUZZLE_HEIGHT: float = 1.55

var _arena: Node3D = null
var _index: AITargetIndex = null
var _targets: Array[AITarget] = []
var _health: PackedFloat32Array = PackedFloat32Array()
var _hits: PackedInt32Array = PackedInt32Array()
var _combat: Array[AICombat] = []
var _lines: PackedStringArray = PackedStringArray()
var _reloads: PackedInt32Array = PackedInt32Array([0, 0])


func _ready() -> void:
	_run()


## Report a line as it is measured rather than at the end, so a harness that
## wedges says where it wedged.
func _say(line: String) -> void:
	_lines.append(line)
	print(line)


func _run() -> void:
	_build_arena()
	await get_tree().physics_frame
	await get_tree().physics_frame
	_check_suppression_curve()
	var cover: AICoverSet = await _check_cover_bake()
	_check_cover_queries(cover)
	_check_aim_ramp()
	await _check_friendly_corridor()
	await _duel("open ground", false)
	await _duel("both in cover", true)
	finished.emit("\n".join(_lines))


## Floor, obstructions, a navigation quad and two bodies. The obstructions stay
## clear of the firing corridor so line of sight is a property of the peek cycle
## rather than of the scenery.
func _build_arena() -> void:
	_arena = Node3D.new()
	_arena.name = "Arena"
	add_child(_arena)
	_add_box(Vector3(0.0, -0.5, 0.0), Vector3(ARENA_HALF * 2.0, 1.0, ARENA_HALF * 2.0))
	var x: float = -16.0
	while x <= 16.0:
		for z: float in [-9.0, -5.0, 5.0, 9.0]:
			var tall: bool = absf(z) > 7.0
			var h: float = 2.6 if tall else 1.05
			_add_box(Vector3(x, h * 0.5, z), Vector3(1.7, h, 1.7))
		x += 4.0
	var nav := NavigationRegion3D.new()
	var mesh := NavigationMesh.new()
	mesh.set_vertices(
		PackedVector3Array(
			[
				Vector3(-ARENA_HALF, 0.0, -ARENA_HALF),
				Vector3(ARENA_HALF, 0.0, -ARENA_HALF),
				Vector3(ARENA_HALF, 0.0, ARENA_HALF),
				Vector3(-ARENA_HALF, 0.0, ARENA_HALF)
			]
		)
	)
	mesh.add_polygon(PackedInt32Array([0, 1, 2, 3]))
	nav.navigation_mesh = mesh
	_arena.add_child(nav)
	# The sampler asks the navigation map where the ground is, so the map has to
	# have caught up with the region before a single probe is fired.
	NavigationServer3D.map_force_update(nav.get_navigation_map())
	_add_body(0, Vector3(-DUEL_SEPARATION * 0.5, 0.0, 0.0))
	_add_body(1, Vector3(DUEL_SEPARATION * 0.5, 0.0, 0.0))
	_index = AITargetIndex.new()
	for t: AITarget in _targets:
		_index.add(t)


func _add_box(centre: Vector3, size: Vector3) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.collision_layer = GameLayers.WORLD
	body.collision_mask = 0
	body.position = centre
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	body.add_child(shape)
	_arena.add_child(body)
	return body


## One duellist: a body on the enemy layer so `MASK_BULLET` finds it, and an
## `AITarget` so the index and the damage path find it.
func _add_body(faction: int, at: Vector3) -> void:
	var body := StaticBody3D.new()
	body.name = "Duelist%d" % faction
	body.collision_layer = GameLayers.ENEMY
	body.collision_mask = 0
	body.position = at
	var shape := CollisionShape3D.new()
	var caps := CapsuleShape3D.new()
	caps.radius = 0.36
	caps.height = 1.8
	shape.shape = caps
	shape.position = Vector3(0.0, 0.9, 0.0)
	body.add_child(shape)
	var target := AITarget.new()
	target.faction = faction
	target.body_path = NodePath("..")
	target.receiver_path = NodePath("..")
	target.body_radius = 0.36
	body.add_child(target)
	_arena.add_child(body)
	_targets.append(target)
	_health.append(HEALTH)
	_hits.append(0)
	var slot: int = _targets.size() - 1
	target.damaged.connect(
		func(amount: float, _p: Vector3, _a: Node) -> void:
			_health[slot] -= amount
			_hits[slot] += 1
			if _health[slot] <= 0.0:
				_targets[slot].mark_dead()
	)


## A rifleman with numbers in the same country as the bestiary's ranged species.
## The gun overrides most of them; what survives is reaction, settle, tolerance
## and the burst discipline, which is the split the design intends.
func _make_profile() -> AISpeciesProfile:
	var p := AISpeciesProfile.new()
	p.species_id = &"duellist"
	p.display_name = "Duellist"
	p.weapon = AISpeciesProfile.Weapon.AUTO
	p.weapon_range = 90.0
	p.min_range = 0.0
	p.damage = 11.0
	p.rpm = 480.0
	p.burst = 4
	p.burst_pause = 0.55
	p.magazine = 30
	p.reload_time = 2.4
	p.spread_degrees = 1.4
	p.aim_settle = 0.7
	p.reaction_time = 0.28
	p.suppression_tolerance = 0.6
	p.suppression_gain = 1.0
	p.body_radius = 0.36
	p.health = HEALTH
	return p


func _check_suppression_curve() -> void:
	var s := AISuppression.new()
	_say("suppression curve (body radius 0.36 m, crack radius %.2f m)" % s.crack_radius)
	for miss: float in [0.0, 0.4, 0.8, 1.2, 1.8, 2.4, 3.2]:
		_say("  miss %.1f m -> severity %.3f" % [miss, s.severity_for(miss, 0.36)])
	s.reset()
	var rounds: int = 0
	while not s.is_pinned(0.6) and rounds < 200:
		s.apply(s.severity_for(0.8, 0.36))
		s.advance(1.0 / 8.0)
		rounds += 1
	_say("  rounds at 0.8 m and 8 rps to pin a 0.6-tolerance body: %d" % rounds)
	var quiet: float = 0.0
	while s.level > 0.0 and quiet < 30.0:
		s.advance(DT)
		quiet += DT
	_say("  seconds of quiet to recover from pinned: %.2f" % quiet)
	_say("")


func _check_cover_bake() -> AICoverSet:
	var region: NavigationRegion3D = null
	for child: Node in _arena.get_children():
		if child is NavigationRegion3D:
			region = child as NavigationRegion3D
	var nav_map: RID = region.get_navigation_map()
	NavigationServer3D.map_force_update(nav_map)
	var probe: Vector3 = NavigationServer3D.map_get_closest_point(nav_map, Vector3(6.0, 1.0, 6.0))
	_say("navigation map %s, closest point to (6, 1, 6) is %s" % [nav_map, probe])
	var space: PhysicsDirectSpaceState3D = _arena.get_world_3d().direct_space_state
	var bounds := AABB(
		Vector3(-ARENA_HALF, 0.0, -ARENA_HALF), Vector3(ARENA_HALF * 2.0, 4.0, ARENA_HALF * 2.0)
	)
	var started: int = Time.get_ticks_msec()
	var cover: AICoverSet = AICoverSampler.sample(space, nav_map, bounds, {"spacing": 1.2})
	var msec: int = Time.get_ticks_msec() - started
	var firing: int = 0
	var full: int = 0
	for i: int in cover.size():
		if cover.high_mask(i) == 0:
			firing += 1
		elif cover.high_mask(i) == cover.low_mask(i):
			full += 1
	var path: String = "user://verify_ai_cover.tres"
	var err: int = ResourceSaver.save(cover, path)
	var reloaded: AICoverSet = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
	_say("cover bake over a %.0f m arena at 1.2 m spacing" % (ARENA_HALF * 2.0))
	_say("  points            %d" % cover.size())
	_say("  firing positions  %d" % firing)
	_say("  full cover        %d" % full)
	_say("  grid cells        %d" % cover.cell_keys.size())
	_say("  sample time       %d ms" % msec)
	_say("  save/reload       err %d, %d points back" % [err, reloaded.size()])
	_say("")
	return cover


func _check_cover_queries(cover: AICoverSet) -> void:
	var map := AICoverMap.new()
	map.bind(cover)
	var threat := Vector3(DUEL_SEPARATION * 0.5, 0.0, 0.0)
	var from := Vector3(-DUEL_SEPARATION * 0.5, 0.0, 0.0)
	var first: int = map.query(from, threat, Vector2(8.0, 40.0), 12.0, 1, true)
	if first < 0:
		_say("cover queries: nothing baked, skipped")
		_say("")
		return
	var claimed: bool = map.claim(first, 1)
	var stolen: bool = map.claim(first, 2)
	var second: int = map.query(from, threat, Vector2(8.0, 40.0), 12.0, 2, true)
	_say("cover queries")
	_say("  ready             %s" % map.is_ready())
	_say(
		(
			"  agent 1 point     %d at %s, protection %d"
			% [first, map.point(first), cover.protection(first, threat - map.point(first))]
		)
	)
	_say("  claim / re-claim  %s / %s (second must be false)" % [claimed, stolen])
	_say("  agent 2 point     %d (must differ from %d)" % [second, first])
	_say("  lean position     %s" % map.lean_position(first, threat, 0.7))
	_say("  still covered     %s" % map.still_covered(first, threat))
	map.release(first, 1)
	_say("  after release     re-claimable %s" % map.claim(first, 2))
	_say("")


## The two things that stop an agent being a turret: the cone shrinking with
## time-on-target rather than starting perfect, and the lead solution actually
## solving for where a moving target will be. Measured analytically, because a
## strafing target would need a mover and this is arithmetic either way.
func _check_aim_ramp() -> void:
	var c := AICombat.new(_make_profile(), 0, 900)
	var gun: GunSpec = GunFactory.roll(4400, "Rifle")
	c.bind_gun(gun)
	var speed: float = float(maxi(gun.sim_velocity, 1))
	var flight: float = DUEL_SEPARATION / speed
	var here := Vector3(DUEL_SEPARATION, 1.25, 0.0)
	var across := Vector3(0.0, 0.0, 5.0)
	var intercept: Vector3 = here + across * flight
	_say("aim ramp (target %.0f m out, 5 m/s across, round at %.0f m/s)" % [DUEL_SEPARATION, speed])
	for settle: float in [0.0, 0.5, 1.0]:
		c.settle = settle
		var cone: float = c.current_spread(false)
		var lead: Vector3 = c.aim_solution(here, across, DUEL_SEPARATION)
		_say(
			(
				"  settle %.1f  cone %.3f deg (%.3f m wide at range)  lead miss %.3f m"
				% [
					settle,
					rad_to_deg(cone),
					tan(cone) * DUEL_SEPARATION,
					lead.distance_to(intercept)
				]
			)
		)
	c.settle = 1.0
	_say("  settled baseline    cone %.3f deg" % rad_to_deg(c.current_spread(false)))
	_say("  suppressive fire    cone %.3f deg" % rad_to_deg(c.current_spread(true)))
	c.suppress.level = 0.6
	_say("  under 0.60 incoming cone %.3f deg" % rad_to_deg(c.current_spread(false)))
	_check_template()
	_say("")


## A species owns one authored template and every body gets a deep copy of it.
## The tuning has to survive the copy and the suppression state has to not.
func _check_template() -> void:
	var template := AICombat.new()
	template.peek_seconds = 2.35
	var a: AICombat = template.instantiate(_make_profile(), 0, 51)
	var b: AICombat = template.instantiate(_make_profile(), 1, 52)
	a.suppress.apply(1.0)
	_say(
		(
			"  template copy       peek %.2f/%.2f  suppression %.2f/%.2f (second must be 0.00)"
			% [a.peek_seconds, b.peek_seconds, a.suppress.level, b.suppress.level]
		)
	)


## An ally standing in the corridor must stop the shot, and only the ally.
func _check_friendly_corridor() -> void:
	var profile: AISpeciesProfile = _make_profile()
	var combat := AICombat.new(profile, 0, 101)
	combat.bind_gun(GunFactory.roll(20260728, "Rifle"))
	var ally := AITarget.new()
	ally.faction = 0
	ally.body_path = NodePath(".")
	ally.receiver_path = NodePath(".")
	ally.position = Vector3(0.0, 0.0, 0.0)
	_arena.add_child(ally)
	var ally_id: int = _index.add(ally)
	await get_tree().physics_frame
	_index.refresh(DT)
	var muzzle: Vector3 = _targets[0].global_position + Vector3.UP * MUZZLE_HEIGHT
	var aim: Vector3 = _targets[1].aim_point()
	var blocked: int = _sim_shots(combat, muzzle, aim, 3.0)
	_index.remove(ally)
	ally.queue_free()
	await get_tree().physics_frame
	_index.refresh(DT)
	combat.configure(profile, 0, 101)
	combat.bind_gun(GunFactory.roll(20260728, "Rifle"))
	var clear: int = _sim_shots(combat, muzzle, aim, 3.0)
	_say("friendly corridor (ally id %d on the firing line)" % ally_id)
	_say("  shots with ally in the way   %d  (must be 0)" % blocked)
	_say("  shots with the line clear    %d" % clear)
	_say("")


## Run one agent for `seconds` against a fixed aim point and return its shot count.
func _sim_shots(combat: AICombat, muzzle: Vector3, aim: Vector3, seconds: float) -> int:
	var space: PhysicsDirectSpaceState3D = _arena.get_world_3d().direct_space_state
	var t: float = 0.0
	while t < seconds:
		combat.tick(DT, muzzle, aim, true, _index, space, false)
		t += DT
	return combat.shots_fired


func _duel(label: String, use_cover: bool) -> void:
	var profile: AISpeciesProfile = _make_profile()
	_combat.clear()
	for i: int in 2:
		var gun: GunSpec = GunFactory.roll(4400 + i * 7, "Rifle")
		var c := AICombat.new(profile, i, 200 + i)
		c.bind_gun(gun)
		c.set_in_cover(use_cover)
		_combat.append(c)
		_health[i] = HEALTH
		_hits[i] = 0
		_targets[i].alive = true
	var toughest: float = 0.0
	for c: AICombat in _combat:
		toughest = maxf(toughest, c.gun.damage * c.gun_damage_scale)
	for i: int in 2:
		_health[i] = toughest * SHOTS_TO_KILL
	_reloads = PackedInt32Array([0, 0])
	_wire_suppression()
	var stats: Dictionary = await _run_duel(use_cover)
	stats["health"] = toughest * SHOTS_TO_KILL
	_report_duel(label, use_cover, stats)


## Every round either agent fires is measured against the other body, exactly as a
## director would do it. This is the whole near-miss loop: it is why a duel in
## cover takes longer than a duel in the open even though the guns are the same.
func _wire_suppression() -> void:
	for i: int in 2:
		var other: int = 1 - i
		_combat[i].reload_started.connect(func(_seconds: float) -> void: _reloads[i] += 1)
		_combat[i].fired.connect(
			func(origin: Vector3, dir: Vector3, hit_position: Vector3, _hit: Object) -> void:
				var travel: float = origin.distance_to(hit_position)
				_combat[other].register_incoming(origin, dir, travel, _targets[other].aim_point())
		)


func _run_duel(use_cover: bool) -> Dictionary:
	var space: PhysicsDirectSpaceState3D = _arena.get_world_3d().direct_space_state
	var muzzles := PackedVector3Array()
	for i: int in 2:
		muzzles.append(_targets[i].global_position + Vector3.UP * MUZZLE_HEIGHT)
	var t: float = 0.0
	var first_hit: float = -1.0
	var steps: int = 0
	var peak := PackedFloat32Array([0.0, 0.0])
	while t < MAX_SECONDS and _targets[0].alive and _targets[1].alive:
		for i: int in 2:
			var other: int = 1 - i
			# Ducked behind cover, neither of them can see the other. With no mover
			# in the harness this is what the peek cycle physically means.
			var los: bool = _combat[i].wants_exposure() and _combat[other].wants_exposure()
			if not use_cover:
				los = true
			_combat[i].tick(DT, muzzles[i], _targets[other].aim_point(), los, _index, space, false)
			peak[i] = maxf(peak[i], _combat[i].suppress.level)
		if first_hit < 0.0 and (_hits[0] > 0 or _hits[1] > 0):
			first_hit = t
		t += DT
		steps += 1
		if steps % STEPS_PER_FRAME == 0:
			_index.refresh(DT * float(STEPS_PER_FRAME))
			await get_tree().physics_frame
	return {"seconds": t, "first_hit": first_hit, "peak": peak}


func _report_duel(label: String, use_cover: bool, stats: Dictionary) -> void:
	var seconds: float = stats["seconds"]
	var toughest: float = float(stats["health"])
	var peak: PackedFloat32Array = stats["peak"]
	var winner: int = 1 if not _targets[0].alive else 0
	_say("duel: %s" % label)
	for i: int in 2:
		var c: AICombat = _combat[i]
		var band: Vector2 = c.engagement_band()
		var rate: float = 0.0 if c.shots_fired == 0 else float(_hits[1 - i]) / float(c.shots_fired)
		_say(
			(
				"  agent %d  %s  dmg %.1f  range %d m  rpm %d  mag %d"
				% [
					i,
					c.gun.weapon_name,
					c.gun.damage,
					c.gun.effective_range,
					c.gun.rpm,
					c.gun.magazine
				]
			)
		)
		_say(
			(
				"           band %.1f-%.1f m  posture at %.0f m: %s"
				% [band.x, band.y, DUEL_SEPARATION, _posture_name(c.posture(DUEL_SEPARATION, true))]
			)
		)
		_say(
			(
				"           shots %d  hits scored %d  hit rate %.1f%%  peak suppression %.2f"
				% [c.shots_fired, _hits[1 - i], rate * 100.0, peak[i]]
			)
		)
		_say(
			(
				"           health left %.1f of %.1f  reloads %d  settle %.2f"
				% [_health[i], toughest, _reloads[i], c.settle]
			)
		)
	if _targets[0].alive and _targets[1].alive:
		_say("  VERDICT  endless: nobody died in %.1f s" % seconds)
	else:
		_say(
			(
				"  VERDICT  agent %d won at %.2f s (first hit %.2f s), cover %s"
				% [winner, seconds, float(stats["first_hit"]), use_cover]
			)
		)
	_say("")


func _posture_name(p: AICombat.Posture) -> String:
	match p:
		AICombat.Posture.ADVANCE:
			return "ADVANCE"
		AICombat.Posture.RETREAT:
			return "RETREAT"
		_:
			return "HOLD"
