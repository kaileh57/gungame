class_name GunVfxBridge
extends RefCounted
## Late-bound link from the firing code to whatever is drawing the game.
##
## The weapon must work with no VFX at all — headless verification fires ten
## thousand rounds into a bare physics world, and the AI fires from off-screen where
## nothing is rendered. So nothing here is a hard dependency: the bridge finds the
## VFX service once, remembers how many arguments each of its entry points actually
## takes, and trims its calls to fit. A service that is missing, or that exposes a
## shorter signature than we offer, costs one cached boolean per call site.
##
## Resolution order: an autoload named `VfxService` or `VFX`, then the first node in
## the `vfx_service` group.

## Autoload names tried, in order.
const SINGLETON_NAMES: PackedStringArray = ["VfxService", "VFX"]
## Group a scene-local VFX service can join instead of being an autoload.
const SERVICE_GROUP: StringName = &"vfx_service"

## Muzzle flash sprite edge length, metres — range spec 16.5:
##   `fs = cl(0.05 + energy/9000, 0.05, 0.34) * (pellets > 1 ? 1.35 : 1)`
## The service is handed this rather than the raw energy, because the size curve
## belongs to the weapon that knows the round and not to the pool that draws it.
const FLASH_MIN: float = 0.05
const FLASH_MAX: float = 0.34
const FLASH_PER_JOULE: float = 1.0 / 9000.0
## A shot load throws a wider, shorter flame front than a single ball.
const FLASH_SHOT_GAIN: float = 1.35

var _service: Object = null
var _arity: Dictionary = {}
var _resolved: bool = false


## Bind to the service. Safe to call again — a demo that swaps its VFX root can
## re-resolve without rebuilding the weapon.
func bind(tree: SceneTree) -> bool:
	_service = null
	_arity.clear()
	_resolved = true
	if tree == null:
		return false
	_service = _find_service(tree)
	return _service != null


func is_bound() -> bool:
	return _service != null


## A round in flight, drawn from the muzzle rather than from the eye. `speed` is
## the round's own speed in m/s and drives how far along the segment the streak has
## got; 0 draws the whole segment at once, which is what a per-frame projectile
## streak wants because that segment IS where the round is.
func tracer(from: Vector3, to: Vector3, speed: float) -> void:
	_send(&"spawn_tracer", [from, to, speed])


## Sparks, dust and noise where a round arrived. `surface` is a `VFXSurface.Kind`.
func impact(at: Vector3, normal: Vector3, surface: int, intensity: float) -> void:
	_send(&"spawn_impact", [at, normal, surface, intensity])


## A hole. `hot` marks fresh spall on bare steel, which glows before it cools.
func decal(at: Vector3, normal: Vector3, size: float, hot: bool) -> void:
	_send(&"spawn_decal", [at, normal, size, hot])


## Muzzle flash sized off the round's energy. `pellets` widens it for a shotgun.
## `at` is the muzzle NODE, not its transform: the pool re-reads the transform when
## it draws, so a flash fired from a viewmodel that is still being posed this frame
## lands on the barrel rather than one frame behind it.
func muzzle_flash(at: Node3D, energy: float, pellets: int) -> void:
	_send(&"spawn_muzzle_flash", [at, flash_scale(energy, pellets)])


## Range spec 16.5's `fs`, in metres.
static func flash_scale(energy: float, pellets: int) -> float:
	var fs: float = clampf(FLASH_MIN + energy * FLASH_PER_JOULE, FLASH_MIN, FLASH_MAX)
	return fs * (FLASH_SHOT_GAIN if pellets > 1 else 1.0)


## The visual half of a blast. The damage half is `GunDamage.blast`.
func explosion(at: Vector3, radius: float) -> void:
	_send(&"spawn_explosion", [at, radius])


func _send(method: StringName, args: Array) -> void:
	if _service == null:
		return
	var want: int = _arity.get(method, -1)
	if want < 0:
		want = _lookup_arity(method)
		_arity[method] = want
	if want < 0 or want > args.size():
		return
	_service.callv(String(method), args.slice(0, want))


## Declared argument count of `method`, or -1 when the service has no such entry.
func _lookup_arity(method: StringName) -> int:
	if not _service.has_method(method):
		return -1
	for entry: Dictionary in _service.get_method_list():
		if StringName(entry.get("name", "")) == method:
			return (entry.get("args", []) as Array).size()
	return -1


func _find_service(tree: SceneTree) -> Object:
	var root: Node = tree.root
	if root != null:
		for name_text: String in SINGLETON_NAMES:
			var node: Node = root.get_node_or_null(NodePath(name_text))
			if node != null:
				return node
	var grouped: Array[Node] = tree.get_nodes_in_group(SERVICE_GROUP)
	if grouped.is_empty():
		return null
	return grouped[0]
