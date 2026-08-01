class_name GunVisual
extends Node3D
## An assembled weapon you can look at: the baked part meshes, the markers, and
## the attach-point solve, in one node that works the same in a viewmodel, on a
## weapon bench and lying on the ground.
##
## Geometry comes from `GunFactory.build_node`, which serves the repaired meshes
## and the three shared gun materials. This node adds what a renderer needs on top
## of that: the render layer, the shadow policy, the model-unit-to-metres scale and
## a cached `GunAttachPoints`.
##
## Two ways in. `set_spec()` assembles on the spot, which is what you do when a gun
## is rolled — on pickup, on a bench reroll, never per frame. `spec` set in the
## inspector or baked into a PackedScene by `res://tools/build_gun_cache.gd` gives
## you the same thing with the roll already paid for, which is what the range and
## the bench use so opening them costs nothing.

## The geometry changed. `spec` may be null when the visual was cleared.
signal spec_changed(spec: GunSpec)

## Where `build_gun_cache.gd` writes its seeded example weapons.
const CACHE_DIR: String = "res://data/guns/cache"
## Manifest the bake writes alongside them: id, class, tier and file paths.
const CACHE_INDEX: String = "res://data/guns/cache/index.json"
## One model unit is 90 mm. Scale by this to put a gun in world space.
const MODEL_TO_METRES: float = 0.09
## Name `GunFactory.build_node` gives the assembly, and the name this node keeps it
## under so a baked scene and a runtime build are the same tree.
const GUN_NODE: StringName = &"Gun"

## The weapon to show. Assigning it rebuilds the geometry. Serialised into the
## baked cache scenes, so an instanced cache entry knows what it is holding.
@export var spec: GunSpec = null:
	set = set_spec

@export_group("Render")
## Which render layers the parts sit on. The viewmodel keeps its own layer so a
## second camera can own the gun and nothing else.
@export_flags_3d_render var render_layers: int = 1 << 7
## Off for a viewmodel — a first-person gun shadow is never seen and always costs.
## On for a gun in the world, where it is most of what sells the object.
@export var cast_shadows: bool = false
## 1.0 leaves the assembly in model units, which is what the viewmodel poses in.
## Use `MODEL_TO_METRES` to stand the gun up in the world at its real size.
@export_range(0.001, 1.0, 0.001) var model_scale: float = 1.0

@export_group("Sights")
## How far above the receiver's top rail the notch of a set of irons sits, in model
## units. This is where the sight PICTURE is — `GunAttachPoints.sight_datum`.
@export_range(0.0, 1.0, 0.005) var iron_sight_height: float = 0.10
## How far below the top of a fitted sight part the sight picture is, as a fraction
## of that part's height. 0 looks along the very top edge, 0.5 looks through the
## middle of it.
@export_range(0.0, 0.9, 0.01) var sight_notch: float = 0.25
## Margin the derived EYE LINE keeps above the whole assembly, model units. These
## parts are solid slabs with no aperture, so a sight line left on the picture runs
## through the gun; this is what lifts it clear. Matches `GunHandPose`'s default so
## a bench's solve and the held weapon's agree. Zero leaves the line on the picture.
@export_range(0.0, 1.0, 0.005) var sight_clearance: float = 0.03

var _gun: Node3D = null
var _muzzle: Marker3D = null
var _eject: Marker3D = null
var _attach: GunAttachPoints = GunAttachPoints.new()


func _ready() -> void:
	# A baked cache scene arrives with its geometry already under it. Adopt that
	# rather than throwing it away and re-assembling what the bake already paid for.
	var existing := get_node_or_null(NodePath(GUN_NODE)) as Node3D
	if existing != null:
		_gun = existing
		_finish_build()
	elif spec != null:
		_rebuild()
	scale = Vector3.ONE * model_scale


## Show `value`, or nothing when it is null. Assembling is a few tenths of a
## millisecond of mesh lookup and transform maths; it is not a per-frame call.
func set_spec(value: GunSpec) -> void:
	spec = value
	if not is_inside_tree():
		return
	_rebuild()


## Drop the geometry and the solve. The node stays, ready for the next weapon.
func clear() -> void:
	set_spec(null)


## Attach points for what is currently shown. Never null; check `valid`.
func attach_points() -> GunAttachPoints:
	return _attach


## The muzzle marker, for parenting a flash or reading a world transform. Null when
## nothing is equipped.
func muzzle() -> Marker3D:
	return _muzzle


func eject() -> Marker3D:
	return _eject


## Assembled bounds in model units.
func bounds() -> AABB:
	return _attach.bounds


## True when there is geometry to look at.
func has_gun() -> bool:
	return _gun != null


## Ids in the baked cache, in the order the bake wrote them. Empty when
## `res://tools/build_gun_cache.gd` has not been run.
static func cache_ids() -> PackedStringArray:
	var out := PackedStringArray()
	for entry: Dictionary in cache_entries():
		out.append(String(entry.get("id", "")))
	return out


## The whole manifest: one dictionary per cached weapon with `id`, `weapon_class`,
## `tier`, `tier_name`, `name`, `scene` and `spec`.
static func cache_entries() -> Array:
	if not FileAccess.file_exists(CACHE_INDEX):
		return []
	var text: String = FileAccess.get_file_as_string(CACHE_INDEX)
	var parsed: Variant = JSON.parse_string(text)
	if parsed is Dictionary and (parsed as Dictionary).has("entries"):
		return (parsed as Dictionary)["entries"] as Array
	return []


## A ready-to-instance `GunVisual` scene for a cached weapon, or null.
static func cache_scene(id: String) -> PackedScene:
	var entry: Dictionary = _cache_entry(id)
	if entry.is_empty():
		return null
	return ResourceLoader.load(String(entry["scene"]), "PackedScene") as PackedScene


## The `GunSpec` of a cached weapon, without instancing its geometry — for a rack
## listing that shows stats before it shows guns.
static func cache_spec(id: String) -> GunSpec:
	var entry: Dictionary = _cache_entry(id)
	if entry.is_empty():
		return null
	return ResourceLoader.load(String(entry["spec"]), "GunSpec") as GunSpec


static func _cache_entry(id: String) -> Dictionary:
	for entry: Dictionary in cache_entries():
		if String(entry.get("id", "")) == id:
			return entry
	return {}


func _rebuild() -> void:
	if _gun != null:
		_gun.queue_free()
		_gun = null
	_muzzle = null
	_eject = null
	_attach = GunAttachPoints.new()
	if spec == null:
		spec_changed.emit(null)
		return
	_gun = GunFactory.build_node(spec)
	if _gun == null:
		push_error("GunVisual: GunFactory.build_node returned nothing for '%s'." % spec.weapon_name)
		return
	_gun.name = String(GUN_NODE)
	add_child(_gun)
	_finish_build()


func _finish_build() -> void:
	_muzzle = _gun.get_node_or_null(^"Muzzle") as Marker3D
	_eject = _gun.get_node_or_null(^"Eject") as Marker3D
	_apply_render_flags(_gun)
	_attach = GunAttachPoints.for_spec(spec, iron_sight_height, sight_notch, sight_clearance)
	_attach.adopt_markers(_gun)
	spec_changed.emit(spec)


func _apply_render_flags(node: Node) -> void:
	var vi := node as VisualInstance3D
	if vi != null:
		vi.layers = render_layers
		var gi := node as GeometryInstance3D
		if gi != null:
			gi.cast_shadow = (
				GeometryInstance3D.SHADOW_CASTING_SETTING_ON
				if cast_shadows
				else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			)
	for child: Node in node.get_children():
		_apply_render_flags(child)
