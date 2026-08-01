class_name GunbenchStand
extends Node3D
## A turntable with a weapon on it, the grab station under it, and the lever that pulls
## that weapon apart.
##
## The stand owns nothing about the roll — hand it a `GunSpec` and it shows you what
## `GunFactory` built from it, in the same baked meshes the viewmodel uses. It rotates
## slowly so you see every side without walking, and on command it slides the five
## fitted parts off each other along the axes a gunsmith would lay them out on: the
## barrel forward, the stock back, the grip down, the sight up, receiver stays put.
##
## THE GRAB STATION IS PART OF THE STAND and not part of the console, which is the
## whole point of it: the plate is bolted to this column, under this weapon, and it
## carries this weapon's name beside the button that takes it. The stand does not
## decide what a press MEANS — `Gunbench` wires `grab_control().pressed` — it only
## guarantees the button and the name belong to the same weapon.
##
## The five tags are baked nodes, not spawned ones. A gun never has more than five
## parts, so five `Label3D` children exist from the moment the scene loads and the
## only thing that changes at run time is their text, position and visibility.
##
## Explosion offsets are quoted in METRES and converted here. The assembled gun node
## is in model units (1 unit = 90 mm) and is scaled by `model_scale` on the way into
## the world, so a part offset written in world metres has to be divided back out or
## a two-centimetre nudge becomes a twenty-centimetre one.

## The stand's weapon changed. Emitted after the geometry is live, so a listener can
## read `spec()` and trust what it finds.
signal spec_changed(spec: GunSpec)

## Model units to metres. The project's gun scale, and not negotiable — the fit
## solver, the ballistics and the socket geometry all assume it.
const MODEL_TO_METRES: float = 0.09
## Tags never exceed this many, because a weapon never has more than five parts.
const MAX_PARTS: int = 5
## Which way each slot travels when the assembly is pulled apart, in gun-local axes.
## Gun-local +X is the muzzle, +Y is up, +Z is the shooter's right.
const EXPLODE_AXES: Dictionary = {
	&"receiver": Vector3.ZERO,
	&"barrel": Vector3(1.0, 0.0, 0.0),
	&"stock": Vector3(-1.0, 0.0, 0.0),
	&"grip": Vector3(0.0, -1.0, 0.0),
	&"sight": Vector3(0.0, 1.0, 0.0),
}

@export_group("Turntable")
## Degrees per second the platter turns. Slow enough to read a stencil off the side.
@export_range(0.0, 90.0, 0.5) var spin_degrees: float = 11.0
## Height above the stand's own origin the assembly is centred at. 1.62 is the player's
## eye line, and it is also what keeps the grab station's plate clear of the sweeping
## assembly — see `STAND_GUN_Y` in `res://tools/build_gunbench.gd`.
@export_range(0.0, 3.0, 0.005) var gun_height: float = 1.62
## Model units to world metres for the assembled weapon.
@export_range(0.01, 0.5, 0.001) var model_scale: float = MODEL_TO_METRES

@export_group("Grab station")
## The letter stencilled on this stand's grab button and printed in front of the
## weapon's name, so the plate under the gun, the button that takes it and the
## "A AGAINST B" delta card all say the same thing.
@export var station_mark: String = "A"

@export_group("Exploded view")
## Metres a part travels along its axis at full separation.
@export_range(0.0, 1.0, 0.005) var explode_metres: float = 0.30
## Seconds for the assembly to reach 95 % of the target separation. Exponential, so
## it is frame-rate independent and never overshoots into the tags.
@export_range(0.02, 2.0, 0.01) var explode_seconds: float = 0.32
## Metres a tag floats above the part it names.
@export_range(0.0, 0.6, 0.005) var tag_lift: float = 0.115
## Separation below which the tags are simply hidden — a label on an assembled gun
## is a label lying across the gun.
@export_range(0.0, 1.0, 0.01) var tag_threshold: float = 0.08

var _spec: GunSpec = null
var _gun: Node3D = null
## Fitted part transforms as `GunFactory` left them, in model units.
var _rest: Array[Transform3D] = []
## Per-part travel in model units, index-aligned with `_parts`.
var _travel: PackedVector3Array = PackedVector3Array()
var _parts: Array[MeshInstance3D] = []
var _tags: Array[Label3D] = []
var _explode_target: float = 0.0
var _explode: float = 0.0
var _spinning: bool = true

@onready var _pivot: Node3D = $Pivot
@onready var _placard: Label3D = $Column/Station/Name
@onready var _grab: DiegeticControl = $Column/Station/Grab


func _ready() -> void:
	_tags.resize(MAX_PARTS)
	for i: int in MAX_PARTS:
		var tag := $Pivot/Tags.get_child(i) as Label3D
		tag.visible = false
		_tags[i] = tag
	_placard.text = GunbenchCards.placard(null, station_mark)
	set_process(spin_degrees > 0.0)


func _process(delta: float) -> void:
	if _spinning and spin_degrees > 0.0:
		_pivot.rotation.y = wrapf(_pivot.rotation.y + deg_to_rad(spin_degrees) * delta, 0.0, TAU)
	if is_equal_approx(_explode, _explode_target):
		return
	_explode = lerpf(_explode, _explode_target, 1.0 - exp(-delta / maxf(explode_seconds, 0.001)))
	if absf(_explode - _explode_target) < 0.001:
		_explode = _explode_target
	_apply_explode()


## Put a weapon on the platter. Passing null empties the stand.
func set_spec(spec: GunSpec) -> void:
	_clear_gun()
	_spec = spec
	_placard.text = GunbenchCards.placard(spec, station_mark)
	if spec != null:
		_build_gun(spec)
	_apply_explode()
	spec_changed.emit(spec)


func spec() -> GunSpec:
	return _spec


## The button bolted under this stand's weapon. `Gunbench` wires what it does; the
## stand only knows that it belongs to this weapon and no other.
func grab_control() -> DiegeticControl:
	return _grab


func has_weapon() -> bool:
	return _spec != null


## Pull the assembly apart, or let it back together.
func set_exploded(on: bool) -> void:
	_explode_target = 1.0 if on else 0.0
	set_process(true)


func is_exploded() -> bool:
	return _explode_target > 0.5


## Stop or restart the turntable. Freezing it is what you want while reading a stencil.
func set_spinning(on: bool) -> void:
	_spinning = on


## Where the assembled weapon sits in world space, for a camera or a light to aim at.
func focus_point() -> Vector3:
	return _pivot.global_position


func _clear_gun() -> void:
	for tag: Label3D in _tags:
		tag.visible = false
	_parts.clear()
	_rest.clear()
	_travel = PackedVector3Array()
	if _gun == null:
		return
	_pivot.remove_child(_gun)
	_gun.queue_free()
	_gun = null


## The assembly, straight from the factory: no geometry is generated here, only baked
## part meshes placed at the transforms the fit solver already wrote onto the spec.
func _build_gun(spec: GunSpec) -> void:
	_gun = GunFactory.build_node(spec)
	if _gun == null:
		push_error("GunbenchStand: GunFactory returned no node for '%s'." % spec.weapon_name)
		return
	_gun.scale = Vector3.ONE * model_scale
	_gun.position = Vector3(0.0, gun_height, 0.0)
	# Centre the assembly on the platter rather than on the receiver's origin, or a
	# long weapon hangs its stock off the back of the stand.
	var box: AABB = GunFactory.assembly_aabb(spec)
	_gun.position -= Vector3(box.get_center().x, 0.0, 0.0) * model_scale
	_pivot.add_child(_gun)

	# The factory drops any slot whose mesh failed to load, so the child list is not
	# guaranteed to be index-aligned with `part_indices`. Walk the parts and consume a
	# mesh child only when one was actually built, which keeps the two in step.
	var distance: float = explode_metres / maxf(model_scale, 0.0001)
	var cursor: int = 0
	for i: int in spec.part_count():
		var part: GunPart = PartLibrary.part(spec.part_indices[i])
		if part == null or PartLibrary.mesh_for(spec.part_indices[i]) == null:
			continue
		var mesh_node := _gun.get_child(cursor) as MeshInstance3D
		cursor += 1
		if mesh_node == null:
			continue
		var slot: int = _parts.size()
		_parts.append(mesh_node)
		_rest.append(mesh_node.transform)
		_travel.append(Vector3(EXPLODE_AXES.get(part.kind, Vector3.ZERO)) * distance)
		if slot < MAX_PARTS:
			_tags[slot].text = (
				"%s\n%s" % [String(part.kind).to_upper(), String(part.donor_group).to_upper()]
			)


## Push the current separation onto the parts and their tags. Called only when the
## value actually moved, so an idle stand costs one float comparison per frame.
func _apply_explode() -> void:
	var show_tags: bool = _explode > tag_threshold
	var base: Vector3 = _gun.position if _gun != null else Vector3.ZERO
	for i: int in _parts.size():
		var offset: Vector3 = _travel[i] * _explode
		var rest: Transform3D = _rest[i]
		_parts[i].transform = Transform3D(rest.basis, rest.origin + offset)
		if i >= MAX_PARTS:
			continue
		var tag: Label3D = _tags[i]
		tag.visible = show_tags
		if show_tags:
			# Model units into the pivot's metres, then a fixed lift in metres on top.
			tag.position = base + (rest.origin + offset) * model_scale + Vector3(0.0, tag_lift, 0.0)
	for i: int in range(_parts.size(), MAX_PARTS):
		_tags[i].visible = false
