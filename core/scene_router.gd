extends Node
## Autoload `SceneRouter`. Owns which demo is loaded, the fade between them, and
## the pause state.
##
## The pause MENU is UI's. The pause STATE is this router's: it is the only thing
## that writes `get_tree().paused` and the only thing that decides whether the
## mouse is captured. Everything else listens to `pause_changed`. One owner means
## the Escape key cannot end up half-handled between a menu and a controller.
##
## Demos are registered here rather than discovered, so a missing scene is a loud
## error at the moment you try to enter it instead of a black screen.

## Emitted after a demo's scene is live. `demo_id` is empty for the main menu.
signal demo_changed(demo_id: String)
signal pause_changed(is_paused: bool)
## Emitted when a requested demo could not be loaded, so UI can say why.
signal route_failed(demo_id: String, message: String)

const DEMOS: Dictionary = {
	"range":
	{
		"title": "SCAV RANGE",
		"scene": "res://demos/range/range.tscn",
		"blurb": "Bench, rack and four hundred metres of dirt. Find out what a gun is worth.",
	},
	"bestiary":
	{
		"title": "BESTIARY",
		"scene": "res://demos/bestiary/bestiary.tscn",
		"blurb": "Every species, rigged and walking. Nothing here is friendly.",
	},
	"ash_flats":
	{
		"title": "ASH FLATS",
		"scene": "res://demos/ash_flats/ash_flats.tscn",
		"blurb": "One dead town on one dry river. Walk out or do not.",
	},
	"firefight":
	{
		"title": "FIREFIGHT",
		"scene": "res://demos/firefight/firefight.tscn",
		"blurb": "Three factions, seven pieces of ground, nobody's thumb on it.",
	},
	"arena":
	{
		"title": "ENEMY TEST ARENA",
		"scene": "res://demos/arena/arena.tscn",
		"blurb": "Walls, cover and a lever. Put every animal in front of every gun.",
	},
	"gunbench":
	{
		"title": "GUN BENCH",
		"scene": "res://demos/gunbench/gunbench.tscn",
		"blurb": "Two turntables and a wall of scrap. Find out what a gun is made of.",
	},
	"movement":
	{
		"title": "MOVEMENT BENCH",
		"scene": "res://demos/movement/movement.tscn",
		"blurb": "Ledges, gaps, slopes, a stopwatch. Turn the dials until it feels right.",
	},
	"visuals":
	{
		"title": "THE FLATS AT DUSK",
		"scene": "res://demos/visuals/visuals.tscn",
		"blurb": "Nothing to shoot. Stand on the rise and look at it.",
	},
}
## Display order for the menu. Every shipped demo is listed: a demo that is not on
## this list has no way in, because the menu is the only caller of `go()` and a
## scene cannot register itself from inside a scene you cannot reach.
const DEMO_ORDER: PackedStringArray = [
	"range",
	"bestiary",
	"ash_flats",
	"firefight",
	"arena",
	"gunbench",
	"movement",
	"visuals",
]

const FADE_COLOR: Color = Color(0.035, 0.031, 0.028, 1.0)
const FADE_LAYER: int = 128

## Empty while the main menu is up, otherwise the id of the running demo.
var current_demo: String = ""

var _runtime_demos: Dictionary = {}
var _fade_layer: CanvasLayer = null
var _fade_rect: ColorRect = null
var _fade_seconds: float = 0.28
var _menu_scene: String = "res://ui/main_menu.tscn"
var _paused: bool = false
var _transitioning: bool = false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_menu_scene = String(ProjectSettings.get_setting("demos/routing/main_menu_scene", _menu_scene))
	_fade_seconds = float(ProjectSettings.get_setting("demos/routing/fade_seconds", 0.28))
	_build_fade_overlay()


func _unhandled_input(event: InputEvent) -> void:
	if not event.is_action_pressed(&"pause"):
		return
	if current_demo.is_empty() or _transitioning:
		return
	get_viewport().set_input_as_handled()
	toggle_pause()


## Enter a demo by id. Fades out, swaps the scene, fades back in. Unpauses first,
## so leaving a paused demo for another one cannot strand the tree paused.
func go(demo_id: String) -> void:
	if _transitioning:
		return
	var info: Dictionary = demo_info(demo_id)
	if info.is_empty():
		_route_error(demo_id, "No demo is registered under the id '%s'." % demo_id)
		return
	var path: String = String(info["scene"])
	if not ResourceLoader.exists(path):
		_route_error(
			demo_id,
			(
				"Demo '%s' is registered as %s, which does not exist. " % [demo_id, path]
				+ "That demo's builder has not been run."
			)
		)
		return
	await _switch_to(path, demo_id)


## Leave whatever is running and return to the main menu. Also the pause menu's
## exit: it unpauses, releases the mouse and forgets the current demo.
func back_to_menu() -> void:
	if _transitioning:
		return
	if not ResourceLoader.exists(_menu_scene):
		_route_error("", "The main menu scene %s does not exist." % _menu_scene)
		return
	await _switch_to(_menu_scene, "")


## Restart the running demo from scratch. Does nothing in the menu.
func reload_current() -> void:
	if current_demo.is_empty():
		return
	await go(current_demo)


func has_demo(demo_id: String) -> bool:
	return DEMOS.has(demo_id) or _runtime_demos.has(demo_id)


## Title / scene / blurb for a demo, or an empty dictionary if it is not registered.
func demo_info(demo_id: String) -> Dictionary:
	if _runtime_demos.has(demo_id):
		return _runtime_demos[demo_id]
	if DEMOS.has(demo_id):
		return DEMOS[demo_id]
	return {}


## Ids in menu order, shipped demos first, then anything registered at runtime.
func demo_ids() -> PackedStringArray:
	var ids := PackedStringArray(DEMO_ORDER)
	for id: String in _runtime_demos:
		if not ids.has(id):
			ids.append(id)
	return ids


## Add a demo the shipped table does not know about. Used by tooling and tests;
## a shipped demo belongs in DEMOS so a bad path is caught at review time.
##
## Demo roots announce themselves on `_ready` so a scene opened straight from the
## editor still has an entry to reload against. For a shipped demo that call is a
## restatement of what is already in DEMOS, so it is silently accepted; only a
## contradiction — same id, different scene — is worth an error.
func register_demo(demo_id: String, title: String, scene: String, blurb: String = "") -> void:
	if DEMOS.has(demo_id):
		var shipped: Dictionary = DEMOS[demo_id]
		if String(shipped["scene"]) != scene:
			push_error(
				(
					"SceneRouter: '%s' is a shipped demo at %s; it cannot be re-registered as %s."
					% [demo_id, String(shipped["scene"]), scene]
				)
			)
		return
	_runtime_demos[demo_id] = {"title": title, "scene": scene, "blurb": blurb}


func is_paused() -> bool:
	return _paused


func toggle_pause() -> void:
	set_paused(not _paused)


## The single writer of `get_tree().paused`. Also decides mouse capture, because
## the two are the same question asked twice.
func set_paused(value: bool) -> void:
	if _paused == value:
		return
	_paused = value
	get_tree().paused = value
	_sync_mouse()
	pause_changed.emit(value)


## Force the mouse mode. Only for the rare case where a demo wants the cursor
## while unpaused, such as the weapon bench; call it again with `false` after.
func set_mouse_captured(captured: bool) -> void:
	Input.mouse_mode = (Input.MOUSE_MODE_CAPTURED if captured else Input.MOUSE_MODE_VISIBLE)


func main_menu_scene() -> String:
	return _menu_scene


func _switch_to(path: String, demo_id: String) -> void:
	_transitioning = true
	set_paused(false)
	await _fade_to(1.0)
	var err: Error = get_tree().change_scene_to_file(path)
	if err != OK:
		_transitioning = false
		await _fade_to(0.0)
		_route_error(demo_id, "Loading %s failed with error %d." % [path, err])
		return
	# change_scene_to_file swaps at the next idle frame; wait for the new tree to
	# exist before revealing it, or the first frame of the demo is the old one.
	await get_tree().process_frame
	await get_tree().process_frame
	current_demo = demo_id
	_sync_mouse()
	demo_changed.emit(demo_id)
	await _fade_to(0.0)
	_transitioning = false


func _fade_to(alpha: float) -> void:
	if _fade_rect == null:
		return
	var tween := create_tween()
	tween.set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
	tween.tween_property(_fade_rect, "color:a", alpha, _fade_seconds)
	await tween.finished


func _build_fade_overlay() -> void:
	_fade_layer = CanvasLayer.new()
	_fade_layer.layer = FADE_LAYER
	_fade_layer.name = "RouterFade"
	add_child(_fade_layer)

	_fade_rect = ColorRect.new()
	_fade_rect.name = "Fade"
	_fade_rect.color = Color(FADE_COLOR.r, FADE_COLOR.g, FADE_COLOR.b, 0.0)
	_fade_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fade_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	_fade_layer.add_child(_fade_rect)


func _sync_mouse() -> void:
	set_mouse_captured(not current_demo.is_empty() and not _paused)


func _route_error(demo_id: String, message: String) -> void:
	push_error("SceneRouter: " + message)
	route_failed.emit(demo_id, message)
