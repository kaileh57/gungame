class_name GunbenchPeg
extends DiegeticControl
## One hook on the wall rack, with a rolled weapon hanging off it.
##
## A peg is a `DiegeticControl` and nothing more clever than that: shoot it or walk up
## and press interact, and it emits `pressed` like every other control in the game. The
## bench decides what that means — here it means the peg and the main stand trade
## weapons, so the rack is never a bottomless dispenser and what you put back stays put.
##
## The hanging weapon is built by `GunFactory` from baked part meshes. It is added
## AFTER `DiegeticControl._ready` has collected its flash targets, which is deliberate:
## the hit flash drives the scrap shader's per-instance `tint`, and the gun parts are
## already using that uniform to carry their donor colour. Letting the flash reach them
## would wash a rack of scavenged weapons uniformly white on every hit.

## Model units to metres, matching `GunbenchStand`.
const MODEL_TO_METRES: float = 0.09

@export_group("Display")
## Model units to world metres for the hanging weapon.
@export_range(0.01, 0.5, 0.001) var model_scale: float = MODEL_TO_METRES
## Metres the weapon stands off the wall plate, so it hangs on the hooks rather than
## through them.
@export_range(0.0, 0.5, 0.005) var stand_off: float = 0.075

var _spec: GunSpec = null
var _gun: Node3D = null

@onready var _mount: Node3D = $Mount
@onready var _tag: Label3D = $Tag


func _ready() -> void:
	super()
	_tag.text = GunbenchCards.rack_tag(null)


## Hang a weapon here. Null empties the peg and disables it — an empty hook is not
## something you can take anything off.
func set_spec(spec: GunSpec) -> void:
	if _gun != null:
		_mount.remove_child(_gun)
		_gun.queue_free()
		_gun = null
	_spec = spec
	_tag.text = GunbenchCards.rack_tag(spec)
	enabled = spec != null
	if spec == null:
		return
	_gun = GunFactory.build_node(spec)
	if _gun == null:
		push_error("GunbenchPeg: GunFactory returned no node for '%s'." % spec.weapon_name)
		return
	_gun.scale = Vector3.ONE * model_scale
	# Hang it on its own centre of length, or a long weapon slides off one hook.
	var box: AABB = GunFactory.assembly_aabb(spec)
	_gun.position = Vector3(-box.get_center().x * model_scale, 0.0, stand_off)
	_mount.add_child(_gun)


func spec() -> GunSpec:
	return _spec


func has_weapon() -> bool:
	return _spec != null
