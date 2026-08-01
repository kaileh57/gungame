class_name GunHandPose
extends Resource
## How the gun in your hands moves, as a resource any carrier node can host.
##
## The solve is `GunPose` and it is pure. This is everything that reads a clock: the
## walk bob, the breath, the sprint lower, the shot punch, the action working, the
## reload arc, the jam rattle and the stow. It produces one position, one Euler triple
## and one uniform scale per frame, and it does not know or care what node those end up
## on — which is the point. `Viewmodel` hosts one in its own gun world; `WeaponHolster`
## hosts one on the player's hand in the ordinary scene tree. Both get the same gun.
##
## The punch magnitudes are NOT duplicated here. They live on `GunRecoil`, which is the
## same resource the weapon uses to walk the shooter's aim, so a gun that shoves the
## camera hard also shoves its own model hard without anyone keeping two numbers in
## step. `bind_recoil()` hands over a weapon's instance; unbound, this owns one and
## fires and decays it itself, which is what makes a bench or a display stand work with
## no `Weapon` in the scene at all.
##
## What this owns is how the punch is SPENT — back along the view, down, and as muzzle
## rise — because that is a viewmodel judgement and has nothing to do with where the
## shooter's aim ended up.
##
## IT ALSO OWNS THE SHOULDERED SIGHT LINE, which is the one part of the resting pose
## that cannot be solved from geometry alone. `GunAttachPoints` knows where the sight
## picture is and how tall every fitted part is; only this knows how big the weapon is
## drawn and how far the butt is stood off, and the eye line is an ANGLE, so it needs
## both. `configure` therefore raises the eye line off the part boxes until the whole
## weapon passes `ads_clear_degrees` under the crosshair, and shrinks the weapon toward
## `ads_scale_floor` when clearing it would otherwise bury the sight further than
## `ads_drop_limit_degrees`. Measured over 111 rolled weapons by
## `res://tools/verify_ads_occlusion.gd`, this took the view axis out of the gun's own
## triangles on 78 of them and left the hip pose bit-identical.

## Frame time is hard-clamped to this, matching the reference's 20 fps floor. Every
## timer below assumes the clamp; without it a hitch fast-forwards a reload.
const MAX_DELTA: float = 0.05
## Steps the shouldered scale is walked down through when a weapon cannot clear the
## view axis inside `ads_drop_limit_degrees`. Eight over the whole range is finer
## than the eye can read and this runs once per weapon, not per frame.
const SHOULDER_STEPS: int = 8

@export_group("Fit")
## Base scale applied to the model-unit assembly. Everything in the pose is in metres
## once this has been applied.
@export_range(0.005, 0.2, 0.0005) var scale_base: float = 0.043
## Model length, in model units, that scales at 1.0. Longer guns are shrunk toward
## `scale_min` so an LMG does not fill the screen.
@export_range(1.0, 30.0, 0.1) var scale_reference_length: float = 8.5
@export_range(0.1, 2.0, 0.01) var scale_min: float = 0.40
@export_range(0.1, 3.0, 0.01) var scale_max: float = 1.10
## How much closer the gun comes when shouldered. Above 1 it grows into the pose.
@export_range(1.0, 3.0, 0.01) var ads_scale: float = 1.5
## The assembly is lifted this far inside the holder so it does not straddle the view
## axis. Carried by every extent the solve uses, and by the carrier's lift node.
@export_range(0.0, 2.0, 0.005) var lift_units: float = 0.30

@export_group("Hip pose")
## Sideways offset at the hip, metres. Positive is toward the shooter's right.
@export_range(-0.6, 0.6, 0.001) var hip_x: float = 0.132
## Where the TOP of the gun sits below the eye line, metres — the solve subtracts
## the assembly's own height from this, so it is a framing number and not an
## offset. At 0.058 the top of the receiver landed about a third of the way down
## the picture, which put the widest, flattest, most sky-lit face of a short
## weapon across the middle of the frame and left it reading as a slab rather than
## as a gun in the corner of the eye. 0.094 at the shipping hip depth is about
## 17 degrees below the view axis, which is three fifths of the way down a 58
## degree lens — where a viewmodel belongs.
@export_range(-0.6, 0.6, 0.001) var hip_y: float = -0.094
@export_range(0.0, 1.0, 0.005) var hip_depth_base: float = 0.19
@export_range(0.0, 1.0, 0.005) var hip_depth_gain: float = 0.22
@export_range(0.0, 1.0, 0.005) var hip_depth_min: float = 0.22
@export_range(0.0, 1.5, 0.005) var hip_depth_max: float = 0.38
## Muzzle-up tilt at the hip, radians. Goes to zero as you aim in.
@export_range(-0.5, 0.5, 0.001) var hip_pitch: float = 0.03
## Yaw lead at the hip, radians. The gun is turned slightly across the view so you see
## its flank rather than its rear cross-section. Goes to zero as you aim in. Three
## degrees was not enough lead to show a flank: a stubby came back as its own
## magazine plate seen square on, which is a rectangle and reads as one.
@export_range(-0.5, 0.5, 0.001) var hip_yaw_lead: float = 0.095
## Roll at the hip, radians.
@export_range(-0.5, 0.5, 0.001) var hip_roll: float = 0.02

@export_group("Shouldered pose")
## Standoff from the eye to the butt when shouldered, metres, before length. This is a
## judgement about how much gun you want to see, not a geometric constraint: the butt
## is stood off far enough that its rear cross-section reads as a small shape low in
## the picture, and shouldering brings the whole gun physically closer so it grows into
## the pose instead of staying a thin stick you happen to be looking along.
@export_range(0.0, 1.0, 0.005) var rear_standoff_base: float = 0.125
@export_range(0.0, 1.0, 0.005) var rear_standoff_gain: float = 0.105
@export_range(0.0, 1.0, 0.005) var rear_standoff_min: float = 0.15
@export_range(0.0, 1.5, 0.005) var rear_standoff_max: float = 0.245

@export_group("Sight line")
## How far below the view axis the HIGHEST point of the weapon sits at full ADS,
## degrees. This is the whole occlusion fix: the eye line is derived per weapon from
## the assembled part boxes so that a snubnose and a machine gun both present their
## crest the same angle under the crosshair, instead of a constant offset that a tall
## receiver or a scope walks straight through. At 0 the gun's top edge touches your
## aim point; below about 1 degree the highest corner reads as clipping the reticle.
@export_range(0.0, 12.0, 0.05) var ads_clear_degrees: float = 1.6
## Flat margin the eye line keeps above the assembly's bounding box, model units,
## forwarded into `GunAttachPoints`. The angular solve almost always asks for more;
## this is the floor that holds when a caller poses without one.
@export_range(0.0, 1.0, 0.005) var sight_clearance_units: float = 0.03
## How far the eye line may be dropped BELOW the weapon's own sight picture before
## the weapon is shrunk into the pose instead of pushed further down, degrees. A tall
## stock comb sitting right under the eye is what spends this: clearing it buries the
## optic, and past this angle the honest answer is a smaller gun in the frame rather
## than a sight you cannot see over.
@export_range(0.0, 40.0, 0.5) var ads_drop_limit_degrees: float = 6.0
## Floor the shouldered scale falls to for a weapon that cannot clear the axis inside
## `ads_drop_limit_degrees`. 1.0 means such a weapon is shouldered at its hip size
## rather than growing into the pose.
@export_range(0.4, 3.0, 0.01) var ads_scale_floor: float = 1.0

@export_group("Sway and bob")
## Bob phase gained per metre travelled. Only used when the carrier feeds no phase.
@export_range(0.0, 8.0, 0.05) var bob_rate: float = 1.9
## Speed at which bob amplitude reaches full, m/s.
@export_range(0.5, 20.0, 0.1) var bob_speed_reference: float = 5.0
@export_range(0.5, 4.0, 0.05) var bob_speed_ceiling: float = 1.4
## Below this the feet are not moving and the bob stops accumulating.
@export_range(0.0, 3.0, 0.01) var bob_min_speed: float = 0.6
@export_range(0.0, 0.1, 0.0005) var sway_lateral: float = 0.010
@export_range(0.0, 0.1, 0.0005) var sway_vertical: float = 0.008
## How much of the sway, bob and kick survives being shouldered. 0.7 means 30 %.
@export_range(0.0, 1.0, 0.01) var ads_damping: float = 0.7

@export_group("Breathing")
## Idle sway rate, radians per second. Slow enough to read as breath, not as drift.
@export_range(0.0, 6.0, 0.01) var idle_rate: float = 0.9
@export_range(0.0, 0.02, 0.0001) var idle_lateral: float = 0.0016
@export_range(0.0, 0.02, 0.0001) var idle_vertical: float = 0.0012
@export_range(0.0, 0.05, 0.0001) var idle_pitch: float = 0.0025
## How much of the breath survives being shouldered. Holding your breath is the whole
## reason to shoulder a gun.
@export_range(0.0, 1.0, 0.01) var idle_ads_damping: float = 0.85

@export_group("Sprint")
## Where the gun goes when you run: down, out and rolled off the shoulder.
@export var sprint_offset: Vector3 = Vector3(0.03, -0.055, 0.04)
## Euler offset at full sprint, radians.
@export var sprint_rotation: Vector3 = Vector3(-0.20, 0.30, 0.38)
@export_range(0.5, 30.0, 0.1) var sprint_rate: float = 9.0

@export_group("Recoil")
## Where the per-shot punch comes from. Magnitudes are `GunRecoil`'s — this only
## decides how they are spent. Left alone, a private instance is used and driven here;
## `bind_recoil()` replaces it with the weapon's so the model and the aim agree.
@export var recoil: GunRecoil = null
## How the stored kick spends itself: back along the view, down, and as muzzle rise.
@export_range(0.0, 3.0, 0.01) var kick_depth: float = 0.55
@export_range(0.0, 1.0, 0.005) var kick_drop: float = 0.06
@export_range(0.0, 2.0, 0.01) var kick_rise: float = 0.30

@export_group("Action")
## Actions slower than this cycle visibly — the bolt is worked and comes back.
@export_range(0.0, 2.0, 0.005) var slow_cycle_threshold: float = 0.24
@export_range(0.0, 0.3, 0.001) var cycle_depth: float = 0.045
@export_range(0.0, 1.0, 0.005) var cycle_roll: float = 0.12

@export_group("Reload and jam")
## Peak drop and push of the reload arc, and how far the gun rolls over so you can see
## the magazine well.
@export_range(0.0, 0.6, 0.001) var reload_drop: float = 0.12
@export_range(0.0, 0.3, 0.001) var reload_push: float = 0.03
@export_range(0.0, 2.0, 0.01) var reload_roll: float = 0.6
## Seconds to clear a jam. The reference's fixed 1.2 s.
@export_range(0.1, 5.0, 0.05) var jam_clear_time: float = 1.2
## How far the gun is rolled over while jammed, radians.
@export_range(0.0, 1.5, 0.01) var jam_roll: float = 0.25
## Rattle while you are beating the action open.
@export_range(0.0, 0.1, 0.0005) var jam_rattle: float = 0.012
@export_range(1.0, 80.0, 0.5) var jam_rattle_rate: float = 26.0

@export_group("Stow")
## Pose added when fully stowed, and the Euler offset with it: muzzle drops, wrist
## rolls out. The carrier owns the stow TIMING; this owns the shape of it.
@export var stow_offset: Vector3 = Vector3(0.02, -0.34, 0.10)
@export var stow_rotation: Vector3 = Vector3(0.95, 0.30, -0.25)

## Resolved this frame by `resolve()`. Metres, radians and a uniform factor.
var position: Vector3 = Vector3.ZERO
var rotation: Vector3 = Vector3.ZERO
var uniform_scale: float = 0.043

var _spec: GunSpec = null
var _pose: GunPose = GunPose.new()
var _owns_recoil: bool = true
var _rand: XorShift32 = XorShift32.new(1)

var _speed: float = 0.0
var _grounded: bool = true
var _sprinting: bool = false
var _sprint: float = 0.0
var _bob: float = 0.0
var _bob_external: bool = false
var _idle: float = 0.0

var _cycle_left: float = 0.0
var _cycle_for: float = 0.0
var _reload_left: float = 0.0
var _reload_for: float = 0.0
var _clear_left: float = 0.0
var _jammed: bool = false


func _init() -> void:
	# Two hands sharing one animator would shove each other's guns around.
	resource_local_to_scene = true
	if recoil == null:
		recoil = GunRecoil.new()


## Solve the hip and shouldered poses for `spec`. Pure maths on the baked geometry, no
## scene tree. `iron_height` and `notch` are the carrier's sight tuning, forwarded to
## `GunAttachPoints`; both have the same defaults `GunVisual` exports.
func configure(spec: GunSpec, iron_height: float = 0.10, notch: float = 0.25) -> void:
	_spec = spec
	var solved := GunPose.new()
	solved.lift = lift_units
	solved.ads_scale = ads_scale
	solved.hip_pitch = hip_pitch
	solved.hip_yaw_lead = hip_yaw_lead
	solved.hip_roll = hip_roll
	solved.base_scale = scale_base
	if spec == null:
		_pose = solved
		return
	solved.attach = GunAttachPoints.for_spec(spec, iron_height, notch, sight_clearance_units)
	if not solved.attach.valid:
		_pose = solved
		return
	var box: AABB = solved.attach.bounds
	solved.base_scale = (
		scale_base * clampf(scale_reference_length / maxf(box.size.x, 1.0), scale_min, scale_max)
	)
	# How much the weapon grows into the pose. Normally `ads_scale`; less for a weapon
	# whose own comb or optic would otherwise have to be dropped out of the picture to
	# get it off the view axis.
	solved.ads_scale = _shoulder_scale(solved.attach, solved.base_scale, box)
	# Everything shouldered is measured at the shouldered scale, because that is the
	# size the gun actually is when the pose has to be right.
	var shoulder: float = solved.ads_scale
	var sa: float = solved.base_scale * shoulder
	var top: float = (box.end.y + lift_units) * sa
	var rear: float = -box.position.x * sa
	var length: float = box.size.x * sa
	var centre_z: float = -(box.position.z + box.end.z) * 0.5 * sa
	var standoff: float = _standoff(length)
	# The sight-line solve, in two halves. First the eye line is raised off the part
	# boxes until the whole weapon passes `ads_clear_degrees` under the crosshair —
	# without this the axis runs through the optic, because these parts are solid and
	# have no aperture to look through. Then the holder is placed to put that line on
	# the axis: `sight` is in the lifted holder frame and the shouldered rotation sends
	# local (x,y,z) to (z, y, -x), so cancelling its z and y is exactly what does it.
	solved.attach.raise_eye_line(standoff / sa, tan(deg_to_rad(ads_clear_degrees)))
	var sight: Vector3 = solved.attach.sight + Vector3(0.0, lift_units, 0.0)
	solved.ads = Vector3(-sight.z * sa, -sight.y * sa, -standoff - rear)
	# At the hip you are not looking down anything, so the reference's box-centring is
	# the right answer: width centred, top of the gun just under the crosshair. Every
	# term divides the shouldered scale back out, so the hip pose is the same whatever
	# the sight line did to the shouldered one.
	var depth: float = clampf(
		hip_depth_base + length / shoulder * hip_depth_gain, hip_depth_min, hip_depth_max
	)
	solved.hip = Vector3(
		hip_x + centre_z / shoulder, hip_y - top / shoulder, -depth - rear / shoulder
	)
	solved.slow_action = (60.0 / maxf(float(spec.rpm), 1.0)) > slow_cycle_threshold
	_pose = solved
	if _owns_recoil:
		recoil.configure(spec)
		_rand = XorShift32.new(spec.cfg if spec.cfg != 0 else 1)


## Standoff from the eye to the butt for an assembly `length` metres long.
func _standoff(length: float) -> float:
	return clampf(
		rear_standoff_base + length * rear_standoff_gain, rear_standoff_min, rear_standoff_max
	)


## How much this weapon is allowed to grow into the shouldered pose.
##
## Clearing the view axis costs a drop, and the drop is paid by the sight picture:
## the taller the thing forcing the eye line up — a stock comb sitting right under
## the eye, almost always — the further the optic ends up below your aim. Past
## `ads_drop_limit_degrees` the honest fallback is a smaller gun rather than a
## sight you cannot see, so the shouldered scale is walked down toward
## `ads_scale_floor` until the drop fits or the floor is reached.
##
## Standing the eye further off in model units is what actually buys the clearance,
## and shrinking the weapon does exactly that: `standoff` falls with length while
## the scale falls faster, so the eye retreats along the gun. Nothing here touches
## the hip pose, which divides the shouldered scale back out.
func _shoulder_scale(attach: GunAttachPoints, base: float, box: AABB) -> float:
	var floor_scale: float = minf(ads_scale_floor, ads_scale)
	var tan_clear: float = tan(deg_to_rad(ads_clear_degrees))
	var tan_limit: float = tan(deg_to_rad(ads_drop_limit_degrees))
	var chosen: float = ads_scale
	for step: int in SHOULDER_STEPS + 1:
		chosen = lerpf(ads_scale, floor_scale, float(step) / float(SHOULDER_STEPS))
		var sa: float = maxf(base * chosen, 1.0e-6)
		var relief: float = _standoff(box.size.x * sa) / sa
		if attach.drop_tangent(attach.eye_line(relief, tan_clear), relief) <= tan_limit:
			break
	return chosen


## The solved poses, and every measurement taken off them. Never null.
func pose() -> GunPose:
	return _pose


## True when there is a weapon with a usable solve to pose.
func is_solved() -> bool:
	return _spec != null and _pose.attach.valid


## Take a weapon's recoil instance. From here on the weapon fires and decays it and
## this only reads the punch, so the model and the shooter's aim can never disagree.
func bind_recoil(value: GunRecoil) -> void:
	if value == null:
		return
	recoil = value
	_owns_recoil = false


## Hand the punch back to a private instance. For a bench that took a gun off a weapon.
func unbind_recoil() -> void:
	if _owns_recoil:
		return
	recoil = GunRecoil.new()
	_owns_recoil = true
	if _spec != null:
		recoil.configure(_spec)


## One round has gone. Starts the action cycling, and adds the punch when nothing else
## owns the recoil — a bound weapon has already taken it by the time this is called.
func fire_shot(ads: float = 0.0) -> void:
	if _spec == null:
		return
	if _owns_recoil:
		recoil.fire(clampf(ads, 0.0, 1.0), _rand)
	_cycle_for = 60.0 / maxf(float(_spec.rpm), 1.0)
	_cycle_left = _cycle_for


## Play the reload arc. With no argument it runs for `GunSpec.reload_time`.
func begin_reload(seconds: float = -1.0) -> void:
	if _spec == null:
		return
	var t: float = seconds if seconds > 0.0 else _spec.reload_time
	if t <= 0.0:
		return
	_reload_for = t
	_reload_left = t
	_cycle_left = 0.0


func cancel_reload() -> void:
	_reload_left = 0.0


func is_reloading() -> bool:
	return _reload_left > 0.0


## The action is stuck. The gun rolls over and stays there until it is cleared.
func set_jammed(value: bool) -> void:
	_jammed = value
	if not value:
		_clear_left = 0.0


func is_jammed() -> bool:
	return _jammed


## Beat the action open. Clears the jam when it finishes.
func begin_jam_clear(seconds: float = -1.0) -> void:
	if not _jammed:
		return
	_clear_left = seconds if seconds > 0.0 else jam_clear_time


## Drop every animation timer without touching the solve. Called on a swap, where the
## gun that comes up is not the gun that was reloading.
func clear_animation() -> void:
	_cycle_left = 0.0
	_reload_left = 0.0
	_clear_left = 0.0
	_jammed = false
	_sprint = 0.0
	if _owns_recoil:
		recoil.reset()


## Feed the carrier's movement state. `bob` is the walk phase; pass a negative value to
## let this accumulate its own from `speed`.
func set_motion(speed: float, on_ground: bool, sprinting: bool, bob: float = -1.0) -> void:
	_speed = maxf(speed, 0.0)
	_grounded = on_ground
	_sprinting = sprinting
	_bob_external = bob >= 0.0
	if _bob_external:
		_bob = bob


## Advance every timer. Returns the clamped delta actually used, so a carrier that has
## other clocks to run can stay on the same one.
func advance(delta: float) -> float:
	var dt: float = minf(maxf(delta, 0.0), MAX_DELTA)
	if dt <= 0.0:
		return 0.0
	_idle += dt * idle_rate
	if _owns_recoil:
		var interval: float = 0.1 if _spec == null else 60.0 / maxf(float(_spec.rpm), 1.0)
		recoil.tick(dt, interval)
	if not _bob_external and _grounded and _speed > bob_min_speed:
		_bob += dt * _speed * bob_rate
	var want_sprint: float = 1.0 if (_sprinting and _grounded and _speed > bob_min_speed) else 0.0
	_sprint += (want_sprint - _sprint) * minf(1.0, dt * sprint_rate)
	if _cycle_left > 0.0:
		_cycle_left = maxf(_cycle_left - dt, 0.0)
	if _reload_left > 0.0:
		_reload_left = maxf(_reload_left - dt, 0.0)
	if _clear_left > 0.0:
		_clear_left -= dt
		if _clear_left <= 0.0:
			_clear_left = 0.0
			_jammed = false
	return dt


## Layer everything onto the resting pose and publish `position`, `rotation` and
## `uniform_scale`. `ads` is 0 at the hip and 1 fully shouldered; `down` is 0 with the
## gun up and 1 fully stowed.
func resolve(ads: float, down: float = 0.0) -> void:
	var t: float = clampf(ads, 0.0, 1.0)
	var d: float = clampf(down, 0.0, 1.0)
	uniform_scale = _pose.uniform_scale(t)
	if not is_solved():
		position = _pose.hip.lerp(_pose.ads, t) + stow_offset * d
		rotation = _pose.rotation(t) + stow_rotation * d
		return
	var move: float = clampf(_speed / bob_speed_reference, 0.0, bob_speed_ceiling)
	var damp: float = 1.0 - ads_damping * t
	var kick: float = recoil.view_kick
	var kick_rot: float = recoil.view_roll
	var sway_x: float = sin(_bob * 2.0) * sway_lateral * move
	var sway_y: float = cos(_bob * 4.0) * sway_vertical * move
	# Breath only shows when the feet are still; walking drowns it out anyway.
	var breath: float = (1.0 - clampf(move, 0.0, 1.0)) * (1.0 - idle_ads_damping * t)
	var pos: Vector3 = _pose.hip.lerp(_pose.ads, t)
	pos.x += sway_x * damp + sin(_idle) * idle_lateral * breath
	pos.y += sway_y * damp - kick * kick_drop + cos(_idle * 1.37) * idle_vertical * breath
	pos.z += kick * kick_depth * damp
	var roll: float = hip_roll * (1.0 - t)
	var pitch: float = (
		hip_pitch * (1.0 - t)
		+ kick_rot * kick_rise * damp
		+ sin(_idle * 0.73) * idle_pitch * breath
	)

	if _reload_left > 0.0:
		# One arc, out and back: down and away at the halfway point, so the magazine
		# well is in view when the magazine would be going into it.
		var arc: float = 1.0 - absf(_reload_left / maxf(_reload_for, 0.0001) - 0.5) * 2.0
		pos.y -= reload_drop * arc
		pos.z += reload_push * arc
		roll += reload_roll * arc
	elif _jammed:
		roll += jam_roll
		if _clear_left > 0.0:
			var rattle: float = sin(_clear_left * jam_rattle_rate)
			pos.y += rattle * jam_rattle
			pos.z += absf(rattle) * jam_rattle * 0.5
			roll += rattle * jam_rattle * 8.0
	elif _pose.slow_action and _cycle_left > 0.0:
		# 0 the instant it fired, 1 back in battery. Work the action and return.
		var cyc: float = sin((1.0 - _cycle_left / maxf(_cycle_for, 0.0001)) * PI)
		pos.z += cyc * cycle_depth
		roll += cyc * cycle_roll

	var lower: float = _sprint * (1.0 - t)
	pos += sprint_offset * lower
	pos += stow_offset * d
	var rot := Vector3(pitch, PI * 0.5 - hip_yaw_lead * (1.0 - t), roll)
	rot += sprint_rotation * lower
	rot += stow_rotation * d
	position = pos
	rotation = rot
