extends Node
## Autoload `GunFactory`. Rolls weapons and turns a `GunSpec` into a node built
## from baked meshes.
##
## Two entry points matter to everyone else:
##   `roll(seed, want_class)`  a deterministic weapon, class-weighted by default
##   `build_node(spec)`        the assembled Node3D, one MeshInstance3D per part
##
## Nothing here generates geometry. Meshes come from `PartLibrary`, which serves
## the winding-repaired ArrayMesh the part bake wrote; materials come from ART's
## three gun surfaces, shared across every gun in the game, with per-part colour
## pushed through `set_instance_shader_parameter` so a rack of twelve weapons
## still costs three materials.
##
## Rolling is not free — `roll()` can assemble up to `roll_attempts` weapons
## looking for the archetype it was asked for. That is a few milliseconds. Roll
## on pickup, on level load or into a cache; never per frame.

## Emitted after every successful roll, for the debug overlay and the feed.
signal weapon_rolled(spec: GunSpec)

const TUNING_PATH: String = "res://data/guns/gun_tuning.tres"
## One shared ShaderMaterial per surface branch: 0 steel, 1 timber, 2 polymer.
const MATERIAL_PATHS: PackedStringArray = [
	"res://art/materials/gun_steel.tres",
	"res://art/materials/gun_timber.tres",
	"res://art/materials/gun_polymer.tres",
]
## The soot every timber and polymer part is lerped 15% toward, so a scavenged
## stock never reads as furniture.
const GRIME: Color = Color("2a2724")
## Guard against a material whose albedo channel is black, which would make the
## per-instance ratio infinite.
const ALBEDO_EPS: float = 1.0e-4

## How many whole assemblies `roll_typed` will try before giving up on the class
## it was asked for and returning the first acceptable weapon instead. The
## reference's budget. Sniper is 0.85% of raw rolls, which is what it buys.
@export_range(16, 2000, 1) var roll_attempts: int = 420
## Cast shadows from gun parts placed in the world. The viewmodel turns its own
## off regardless — a first-person gun shadow is never seen and always costs.
@export var world_shadows: bool = true

## Balance settings every roll is derived through. Loaded from
## `res://data/guns/gun_tuning.tres` when the bake has written one.
var tuning: GunTuning = null

var _pools: Dictionary = {}
var _materials: Array[ShaderMaterial] = [null, null, null]
var _albedos: PackedColorArray = PackedColorArray([Color.WHITE, Color.WHITE, Color.WHITE])


func _ready() -> void:
	tuning = ResourceLoader.load(TUNING_PATH, "GunTuning") as GunTuning if _has_tuning() else null
	if tuning == null:
		tuning = GunTuning.new()


## True once the part library is loaded and rolling will actually work.
func is_ready() -> bool:
	return PartLibrary.is_loaded()


## A deterministic weapon. With no `want_class` the archetype is drawn from the
## reference's `CLASS_MIX` percentages — what the world actually hands out, which
## is not at all what raw assembly produces (Sniper is 7% here and 0.85% there).
func roll(seed_value: int, want_class: String = "") -> GunSpec:
	var rand := XorShift32.new(seed_value)
	var want: String = want_class
	if want.is_empty():
		want = GunTables.wanted_class(rand.next())
	return roll_typed(rand, false, want)


## A weapon that fits a holster: overall length at or under 720 mm and 3.6 kg.
## The sidearm filter runs before the fallback is recorded, so this never returns
## something you cannot actually carry in the second slot.
func roll_holstered(seed_value: int, want_class: String = "Sidearm") -> GunSpec:
	return roll_typed(XorShift32.new(seed_value), true, want_class)


## The reference's raw `build(seed)`: five parts straight off the seed, no class
## targeting. This is the function the golden vectors are taken from.
func build(seed_value: int) -> GunSpec:
	var pools: Dictionary = part_pools()
	if pools.is_empty():
		return null
	return GunAssembler.build(seed_value, pools, tuning)


## Assemble up to `roll_attempts` weapons looking for `want`, keeping the first
## acceptable one as a fallback. Consumes one draw per attempt from `rand`.
func roll_typed(rand: XorShift32, need_sidearm: bool, want: String) -> GunSpec:
	var pools: Dictionary = part_pools()
	if pools.is_empty():
		return null
	var fallback: GunSpec = null
	for _i: int in roll_attempts:
		var spec: GunSpec = GunAssembler.build(_draw_seed(rand), pools, tuning)
		if need_sidearm and not spec.sidearm:
			continue
		if fallback == null:
			fallback = spec
		if String(spec.archetype) == want:
			weapon_rolled.emit(spec)
			return spec
	if fallback == null:
		fallback = GunAssembler.build(_draw_seed(rand), pools, tuning)
	weapon_rolled.emit(fallback)
	return fallback


## Assemble a named set of parts. `sight_index` of -1 means iron sights.
##
## `fit_optics` is deliberately NOT run, matching the bench's slot reroll, so the
## result carries an empty magnification ladder and every consumer must go
## through `GunSpec.zoom_ladder()`. Pass `with_optics` to opt back in.
func assemble_indices(
	receiver: int,
	barrel: int,
	stock: int,
	grip: int,
	sight: int,
	seed_value: int,
	with_optics: bool = false
) -> GunSpec:
	var lib: Node = PartLibrary
	var sight_part: GunPart = lib.part(sight) if sight >= 0 else null
	var spec: GunSpec = GunAssembler.assemble(
		lib.part(receiver),
		lib.part(barrel),
		lib.part(stock),
		lib.part(grip),
		sight_part,
		seed_value,
		tuning
	)
	if with_optics:
		GunAssembler.fit_optics(spec)
	return spec


## Swap one slot of an existing weapon for a random other part of the same kind.
## The sight slot has a 15% chance of removing the optic entirely, as the bench
## does. Returns a fresh spec; the original is untouched.
func reroll_slot(spec: GunSpec, kind: StringName, rand: RandomNumberGenerator) -> GunSpec:
	var indices := PackedInt32Array(
		[
			spec.receiver_index(),
			spec.barrel_index(),
			spec.stock_index(),
			spec.grip_index(),
			spec.sight_index(),
		]
	)
	var slot: int = [&"receiver", &"barrel", &"stock", &"grip", &"sight"].find(kind)
	if slot < 0:
		push_error("GunFactory: '%s' is not a swappable slot." % kind)
		return spec
	if kind == &"sight" and rand.randf() < 0.15:
		indices[4] = -1
	else:
		var pool: Array[GunPart] = PartLibrary.by_kind(kind)
		indices[slot] = pool[rand.randi_range(0, pool.size() - 1)].index
	return assemble_indices(
		indices[0], indices[1], indices[2], indices[3], indices[4], spec.roll_seed
	)


## The assembled weapon as a node: one MeshInstance3D per fitted part plus a
## `Muzzle` and an `Eject` marker, all in model units. Scale the returned node by
## 0.09 to put it in world space.
func build_node(spec: GunSpec) -> Node3D:
	var root := Node3D.new()
	root.name = "Gun"
	if spec == null:
		push_error("GunFactory.build_node: null spec.")
		return root
	for i: int in spec.part_count():
		var index: int = spec.part_indices[i]
		var part: GunPart = PartLibrary.part(index)
		var mesh: ArrayMesh = PartLibrary.mesh_for(index)
		if part == null or mesh == null:
			continue
		var mi := MeshInstance3D.new()
		mi.name = String(part.kind).capitalize()
		mi.mesh = mesh
		mi.transform = spec.part_transform(i)
		var surface: int = part.surface_type()
		mi.material_override = part_material(surface)
		mi.set_instance_shader_parameter(&"tint", _instance_tint(part, spec.tint, surface))
		mi.set_instance_shader_parameter(&"surface_seed", _surface_seed(part))
		mi.cast_shadow = (
			GeometryInstance3D.SHADOW_CASTING_SETTING_ON
			if world_shadows
			else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		)
		mi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
		root.add_child(mi)

	var muzzle := Marker3D.new()
	muzzle.name = "Muzzle"
	muzzle.position = spec.muzzle_local
	root.add_child(muzzle)

	var eject := Marker3D.new()
	eject.name = "Eject"
	eject.position = _eject_local(spec)
	root.add_child(eject)
	return root


## Bounding box of the assembled weapon in model units, from the baked mesh
## AABBs rather than from the part extents, so it accounts for the fitted scale
## and the joint overlaps.
func assembly_aabb(spec: GunSpec) -> AABB:
	var box := AABB()
	var first: bool = true
	for i: int in spec.part_count():
		var mesh: ArrayMesh = PartLibrary.mesh_for(spec.part_indices[i])
		if mesh == null:
			continue
		var local: AABB = spec.part_transform(i) * mesh.get_aabb()
		box = local if first else box.merge(local)
		first = false
	return box


## Part pools grouped by kind, in flat reference order. Empty and noisy when the
## part bake has not been run.
func part_pools() -> Dictionary:
	if not _pools.is_empty():
		return _pools
	if not PartLibrary.is_loaded():
		push_error("GunFactory: the part library is not loaded. %s" % PartLibrary.load_error)
		return {}
	for kind: StringName in PartLibrary.KINDS:
		_pools[kind] = PartLibrary.by_kind(kind)
	return _pools


## The shared material for a surface branch: 0 steel, 1 timber, 2 polymer.
func part_material(surface: int) -> ShaderMaterial:
	var i: int = clampi(surface, 0, MATERIAL_PATHS.size() - 1)
	if _materials[i] == null:
		var mat := ResourceLoader.load(MATERIAL_PATHS[i], "ShaderMaterial") as ShaderMaterial
		if mat == null:
			push_error("GunFactory: missing %s. Run res://tools/build_art.gd." % MATERIAL_PATHS[i])
			return null
		_materials[i] = mat
		var albedo: Variant = mat.get_shader_parameter(&"albedo")
		_albedos[i] = albedo if albedo is Color else Color.WHITE
	return _materials[i]


## Drop the cached pools and materials. Only the bake needs this.
func clear_cache() -> void:
	_pools.clear()
	_materials = [null, null, null]


func _has_tuning() -> bool:
	return ResourceLoader.exists(TUNING_PATH)


## `(rand()*4294967295)>>>0` — floor through ToUint32, not a rounding.
func _draw_seed(rand: XorShift32) -> int:
	return int(rand.next() * 4294967295.0) & 0xFFFFFFFF


## The per-instance colour multiplier that lands this part on its donor's hue.
##
## The shader computes `albedo * tint`, both `source_color`, so both are taken
## from sRGB into linear before the multiply. To hit an arbitrary target the
## instance tint has to be the linear RATIO expressed back in sRGB, which is what
## `linear_to_srgb()` on the quotient does.
func _instance_tint(part: GunPart, gun_tint: float, surface: int) -> Color:
	var target: Color = part.body_color().srgb_to_linear() * gun_tint
	if surface != 0:
		target = target.lerp(GRIME.srgb_to_linear(), 0.15)
	part_material(surface)
	var base: Color = _albedos[clampi(surface, 0, _albedos.size() - 1)].srgb_to_linear()
	var ratio := Color(
		target.r / maxf(base.r, ALBEDO_EPS),
		target.g / maxf(base.g, ALBEDO_EPS),
		target.b / maxf(base.b, ALBEDO_EPS)
	)
	return ratio.linear_to_srgb()


## The reference's per-part noise offset: donor colour modulo 997, plus a nudge
## per kind so a barrel and the receiver behind it do not rust identically.
func _surface_seed(part: GunPart) -> float:
	var c: Color = part.body_color()
	var hex: int = (
		(int(roundf(c.r * 255.0)) << 16)
		| (int(roundf(c.g * 255.0)) << 8)
		| int(roundf(c.b * 255.0))
	)
	return float(hex % 997) / 997.0 + float(String(part.kind).length()) * 0.11


## Ejection port, in model units: off the receiver's right shoulder, level with
## the top rail. Gun-local +X is the muzzle and +Y is up, so +Z is the shooter's
## right — which is where a scavenged action throws its brass.
func _eject_local(spec: GunSpec) -> Vector3:
	var rec: GunPart = PartLibrary.part(spec.receiver_index())
	if rec == null:
		return Vector3.ZERO
	var top: GunSocket = rec.socket_top
	var x: float = top.position.x if top != null else 0.0
	var y: float = (top.position.y * 0.5) if top != null else 0.2
	return Vector3(x, y, rec.ext.z * 0.5 + 0.06)
