class_name PlayerState
extends RefCounted
## What the player is doing right now, in one object other systems can read instead of
## reaching into the controller for eight loose variables.
##
## The camera rig wants the eye and the roll cues, the weapon holster wants the stance
## and the speed, the AI wants a target point and whether you are a crouched silhouette
## or a sprinting one, the HUD wants the stamina. All of them want it without polling a
## node path or duplicating the "am I sliding or just crouched" precedence, so the
## precedence is written once, here.
##
## The controller owns exactly one of these and rewrites it in place at the end of every
## physics tick — reading it allocates nothing. `PlayerController.state_changed` fires
## only when `kind` actually changes, so listeners can react on the edge rather than
## comparing every frame.

## Mutually exclusive, highest precedence first: being dead overrides everything, a
## mantle overrides the rest, a ladder overrides the slide, a slide overrides the
## crouch, crouching overrides plain ground.
enum Kind { GROUND, AIR, SLIDE, CROUCH, LADDER, MANTLE, DEAD }

const KIND_NAMES: PackedStringArray = [
	"ground", "air", "slide", "crouch", "ladder", "mantle", "dead"
]
## Crouch blend above which the stance counts as ducked for state purposes. Below it you
## are still standing as far as everything downstream is concerned.
const CROUCH_THRESHOLD: float = 0.55

var kind: Kind = Kind.AIR
var previous: Kind = Kind.AIR
## Seconds spent in `kind`. Reset on every transition.
var time_in_kind: float = 0.0

## Full world velocity, m/s. `planar_speed` is its XZ magnitude, cached because half the
## consumers want only that.
var velocity: Vector3 = Vector3.ZERO
var planar_speed: float = 0.0

## Feet, in world space. The controller's origin.
var feet: Vector3 = Vector3.ZERO
## Eye anchor before bob, lean and landing dip — the same point the camera rig lerps.
var eye: Vector3 = Vector3.ZERO
## Live collider dimensions. `height` shrinks as you crouch; `radius` never changes.
var height: float = 1.80
var radius: float = 0.34
## 0 standing, 1 fully ducked.
var crouch_t: float = 0.0

## Ground probe results, valid whenever `grounded` is true and stale otherwise.
var grounded: bool = false
var ground_normal: Vector3 = Vector3.UP
## Angle between the ground and horizontal, radians. 0 on a flat floor.
var ground_slope: float = 0.0
## Indexes `WorldSurface.Kind` — what you are standing on, for footstep audio and decals.
var ground_surface: int = 3
## Seconds since the feet last left the ground; 0 while grounded.
var air_time: float = 0.0

var sprinting: bool = false
## 0 hip, 1 fully aimed in.
var ads: float = 0.0
var stamina: float = 100.0
## Health, written by `PlayerHealth` every physics tick. Anything that already reads
## this snapshot for the stamina gets the health bar for free and does not have to
## find the health node. `dead` is the authority on the death state; `kind` follows
## it, because the precedence is written once and it is written here.
var health: float = 100.0
var health_max: float = 100.0
var dead: bool = false
## -1 fully left, +1 fully right. Zero unless lean actions are bound.
var lean: float = 0.0
## Signed lean into a slide, -1 left to +1 right. Zero when not sliding. The camera rig
## turns it into roll; a viewmodel that wants to drop the gun with the shoulder can read
## the same number instead of inventing its own envelope.
var slide_bank: float = 0.0
## 1 on the tick a slide-jump launched, easing to 0 over the controller's slide-jump air
## window. Non-zero means the body is mid slide-jump, which is also the window in which
## redirect air control is live and the next touchdown chains.
var slide_launch: float = 0.0
## Look angles, radians. Yaw 0 faces -Z.
var yaw: float = 0.0
var pitch: float = 0.0


## Fold the controller's flags into the one exclusive state. Precedence is the point:
## you can be crouched and on a ladder at once, and every consumer must agree on which
## of those wins.
static func classify(
	is_dead: bool,
	mantling: bool,
	on_ladder: bool,
	is_sliding: bool,
	is_grounded: bool,
	crouch_blend: float
) -> Kind:
	if is_dead:
		return Kind.DEAD
	if mantling:
		return Kind.MANTLE
	if on_ladder:
		return Kind.LADDER
	if is_sliding:
		return Kind.SLIDE
	if not is_grounded:
		return Kind.AIR
	if crouch_blend > CROUCH_THRESHOLD:
		return Kind.CROUCH
	return Kind.GROUND


static func name_of(k: Kind) -> String:
	return KIND_NAMES[int(k)]


## Fold this tick's flags into `kind` and age the clock. Returns true on the tick the
## state actually changed, which is the controller's cue to emit `state_changed`.
##
## The controller used to inline this. It lives here because the precedence already
## does, and because the death state had to enter that precedence from a field this
## object owns rather than from a seventh argument the caller would have to fetch.
func advance(
	dt: float, mantling: bool, on_ladder: bool, is_sliding: bool, is_grounded: bool, crouch: float
) -> bool:
	var next: Kind = classify(dead, mantling, on_ladder, is_sliding, is_grounded, crouch)
	if next == kind:
		time_in_kind += dt
		return false
	previous = kind
	kind = next
	time_in_kind = 0.0
	return true


## Health left as a 0..1 fraction — what the vignette and the AI's flinch both want.
func health_fraction() -> float:
	return clampf(health / maxf(health_max, 0.001), 0.0, 1.0)


## True when the feet are on something and free to accelerate — the state in which the
## ground controller runs. A slide is grounded but is not this.
func is_walking() -> bool:
	return kind == Kind.GROUND or kind == Kind.CROUCH


## True when the controller, not the player, owns the body for the moment. Weapon and
## camera systems use this to suppress input-driven sway. A corpse qualifies: nothing
## the player does with the mouse should move a body that is down.
func is_scripted() -> bool:
	return kind == Kind.MANTLE or kind == Kind.LADDER or kind == Kind.DEAD


func name() -> String:
	return KIND_NAMES[int(kind)]


func _to_string() -> String:
	return (
		"PlayerState<%s %.2f m/s %s>"
		% [
			KIND_NAMES[int(kind)],
			planar_speed,
			"grounded" if grounded else "air %.2fs" % air_time,
		]
	)
