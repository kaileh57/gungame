class_name AmmoCounter
extends Node3D
## The ammunition count, on the gun.
##
## Screen-space ammo counters are the first thing the project's diegetic rule
## deletes, so this goes where a scav would actually have scratched it: a plate on
## the receiver with the magazine count on it. `WeaponHolster` mounts one on its own
## `Hand` in every armed level, so it moves with the weapon — including when the
## weapon kicks, which is the whole reason it reads as part of the gun.
##
## Three states, from the reference's HUD rules: normal, low at a quarter of the
## magazine or less, and empty. Low and empty are colour changes, not text
## changes, because you read a colour without looking away from the sights.
##
## THE FOURTH STATE IS A JAM, AND IT NEEDED MORE THAN A WORD. `JAM` on its own told
## you the action was bound but not that holding reload was doing anything about it,
## and clearing a stoppage runs from about 0.4 s to 4.2 s depending on the weapon's
## grading and how badly it bound — so a bad gun read as broken rather than as slow.
## `set_clear_progress` draws that timer as a ring closing around the count. The
## geometry is four bars baked by `demos/range/build/range_ammo_kit.gd`, each one
## running from its own origin along its own +X, so a fill is one `scale.x` per side
## and there is nothing per-frame but four assignments.

## Where the plate is baked. It is written under the range because that bake owns the
## mesh shop which validates and saves it, NOT because it belongs to that demo — this
## is the ammunition readout for every armed level in the game, and the path is a
## detail of this module rather than something its callers should know.
const SCENE_PATH: String = "res://demos/range/ammo_counter.tscn"

## Colour once the magazine is at or below `low_fraction`.
@export var low_color: Color = UiStyle.ACCENT
## Colour at zero, and while the action is jammed.
@export var empty_color: Color = UiStyle.WARN
@export var normal_color: Color = Color(0.792, 0.749, 0.659)
@export_range(0.05, 0.5, 0.01) var low_fraction: float = 0.25
## Shown instead of the count while the action is jammed.
@export var jam_text: String = "JAM"
## Seconds the count is held in the low colour after a magazine seated short.
@export_range(0.0, 6.0, 0.1) var short_flash_seconds: float = 1.6
## Fraction of the ring each fill bar spans, in sweep order. Written by the bake off
## the ring's own dimensions; the default is the shipped plate's, so a counter built
## by hand still fills evenly instead of not at all.
@export var ring_shares: PackedFloat32Array = PackedFloat32Array(
	[0.3146, 0.1854, 0.3146, 0.1854]
)

var _magazine: int = 0
var _capacity: int = 0
var _jammed: bool = false
var _clear: float = 0.0
var _short_left: float = 0.0
var _fault_text: String = ""
var _fills: Array[MeshInstance3D] = []

@onready var _count: Label3D = $Count
@onready var _capacity_label: Label3D = get_node_or_null(^"Capacity") as Label3D
@onready var _ring: Node3D = get_node_or_null(^"ClearRing") as Node3D


func _ready() -> void:
	set_process(false)
	_collect_fills()
	_refresh()
	_apply_ring()


## Instance the baked plate, or null when the bake has not been run. Callers mount
## the result themselves; `WeaponHolster` is the one that does it in play.
static func spawn() -> AmmoCounter:
	var packed := ResourceLoader.load(SCENE_PATH, "PackedScene") as PackedScene
	if packed == null:
		return null
	return packed.instantiate() as AmmoCounter


## Something in the feed went wrong: a magazine seated short, a shell was dropped on the
## way to the gate, or the stack stripped a round it should not have.
##
## THREE MECHANICS, ALL INVISIBLE, ALL WORKING. `short_loaded`, `fumbled` and `misfed`
## have been emitted since the port with NOTHING LISTENING, so a worn gun handed you 11 of
## 12, ate a shell, or quietly lost a round, and every one of those read as the gun being
## broken rather than as the gun being bad. They share one readout because they share one
## meaning to the shooter: that did not go the way it should have.
func flag_feed_fault(text: String = "") -> void:
	_short_left = short_flash_seconds
	_fault_text = text
	set_process(_short_left > 0.0)
	_refresh()


## A fresh magazine did not seat its full count.
func set_short_loaded(_missing: int) -> void:
	flag_feed_fault()


func _process(delta: float) -> void:
	if _short_left <= 0.0:
		return
	_short_left -= delta
	if _short_left <= 0.0:
		_short_left = 0.0
		_fault_text = ""
		set_process(false)
		_refresh()


## Update the count. Call it when the number changes, not every frame.
func set_ammo(magazine: int, capacity: int) -> void:
	if magazine == _magazine and capacity == _capacity:
		return
	_magazine = magazine
	_capacity = capacity
	_refresh()


## A jammed action shows JAM in the empty colour until it is cleared.
func set_jammed(jammed: bool) -> void:
	if jammed == _jammed:
		return
	_jammed = jammed
	if not _jammed:
		set_clear_progress(0.0)
	_refresh()


## How far through clearing the stoppage the shooter is, 0 to 1. Zero hides the ring
## entirely, so an idle gun carries no furniture it does not need.
##
## Guarded on a real change rather than assigned blindly: this is fed straight off
## `GunJam.clear_progress()` every frame the trigger is held, and the guard is what
## keeps a held reload from touching four transforms a frame for no visible change.
func set_clear_progress(progress: float) -> void:
	var p: float = clampf(progress, 0.0, 1.0)
	if absf(p - _clear) < 0.002 and not (p > 0.0 and _clear == 0.0):
		return
	_clear = p
	_apply_ring()


func clear_progress() -> float:
	return _clear


func _collect_fills() -> void:
	_fills.clear()
	if _ring == null:
		return
	for i: int in 8:
		var node := _ring.get_node_or_null(NodePath("Fill%d" % i)) as MeshInstance3D
		if node == null:
			break
		_fills.append(node)


## Lay the progress out around the ring, one side at a time. A side that the sweep
## has not reached is HIDDEN rather than scaled to zero: `scale.x = 0` is a singular
## basis, which Godot warns about every frame it is drawn with.
func _apply_ring() -> void:
	if _ring == null:
		return
	if _clear <= 0.0:
		_ring.visible = false
		return
	_ring.visible = true
	var left: float = _clear
	for i: int in _fills.size():
		var share: float = 0.25
		if i < ring_shares.size():
			share = maxf(ring_shares[i], 0.0001)
		var fill: float = clampf(left / share, 0.0, 1.0)
		left = maxf(left - share, 0.0)
		var node: MeshInstance3D = _fills[i]
		node.visible = fill > 0.001
		if node.visible:
			node.scale = Vector3(fill, 1.0, 1.0)


func _refresh() -> void:
	if _count == null:
		return
	if _jammed:
		_count.text = jam_text
		_count.modulate = empty_color
	elif _short_left > 0.0:
		# The number is honest; the colour says the magazine is not full because the feed
		# failed, rather than because you have been shooting. A fault with a name says it.
		_count.text = _fault_text if not _fault_text.is_empty() else str(_magazine)
		_count.modulate = low_color
	else:
		_count.text = str(_magazine)
		_count.modulate = _state_color()
	if _capacity_label != null:
		_capacity_label.text = "/%d" % _capacity


func _state_color() -> Color:
	if _magazine <= 0:
		return empty_color
	if _magazine <= maxi(1, int(float(_capacity) * low_fraction)):
		return low_color
	return normal_color
