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
##
## WHEN A GAME IS NETWORKED, THE HOST OWNS THIS. `NetGame` installs itself through
## `set_network` on boot; after that a client asking to `go()` somewhere is
## refused, and everything the host routes to is announced on `route_started` so
## the clients can be sent after it through `follow_host`. None of that changes
## anything in single-player, where there is no network object to ask.

## Emitted after a demo's scene is live. `demo_id` is empty for the main menu.
signal demo_changed(demo_id: String)
## Emitted the moment a route is COMMITTED to, before the fade — so a client can
## start loading the same scene while the host is still fading out, rather than a
## whole transition behind it. `NetGame` is the only listener that matters.
signal route_started(demo_id: String)
signal pause_changed(is_paused: bool)
## Emitted when a requested demo could not be loaded, so UI can say why.
signal route_failed(demo_id: String, message: String)

const DEMOS: Dictionary = {
	"range":
	{
		"title": "SCAV RANGE",
		"scene": "res://demos/range/range.tscn",
		"blurb": "A shooting range with targets out to 400 metres. Roll new guns at the bench.",
	},
	"bestiary":
	{
		"title": "BESTIARY",
		"scene": "res://demos/bestiary/bestiary.tscn",
		"blurb": "One of every enemy in the game, walking around so you can look at them.",
	},
	"ash_flats":
	{
		"title": "ASH FLATS",
		"scene": "res://demos/ash_flats/ash_flats.tscn",
		"blurb": "An abandoned town on a dry riverbed. Enemies patrol it. There is a race course.",
	},
	"firefight":
	{
		"title": "FIREFIGHT",
		"scene": "res://demos/firefight/firefight.tscn",
		"blurb": "Three AI factions fight each other over seven control points. You watch.",
	},
	"arena":
	{
		"title": "ENEMY TEST ARENA",
		"scene": "res://demos/arena/arena.tscn",
		"blurb": "A walled arena with cover. Pull the lever to spawn enemies and fight them.",
	},
	"gunbench":
	{
		"title": "GUN BENCH",
		"scene": "res://demos/gunbench/gunbench.tscn",
		"blurb": "Two gun stands and a rack of weapons. Swap parts and compare the results.",
	},
	"movement":
	{
		"title": "MOVEMENT BENCH",
		"scene": "res://demos/movement/movement.tscn",
		"blurb": "An obstacle course with a timer. Dials let you retune how the player moves.",
	},
	"visuals":
	{
		"title": "THE FLATS AT DUSK",
		"scene": "res://demos/visuals/visuals.tscn",
		"blurb": "The full map at sunset with no enemies. Somewhere to look at the scenery.",
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
## `NetGame`, or null in a build with no `net/`. Held as a plain Object and called
## by name so this file names no autoload and compiles anywhere — including under
## `--script`, where autoloads do not exist.
var _net: Object = null
## A `follow_host` that arrived mid-transition, applied when that one lands. The
## host can only issue one route per transition, but the client's transition
## starts a round trip later and ends a round trip later, so there is a real
## window in which the next instruction would otherwise be dropped in silence.
var _pending_follow: String = ""
var _has_pending_follow: bool = false


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
	if not _may_route():
		_route_error(demo_id, "The host decides where everyone goes. Leave the game to pick.")
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
##
## A CLIENT asking for the menu is a client asking to leave the game, so that is
## what it gets — `NetGame.leave()` drops the session and routes them home by
## itself. That keeps the pause menu's existing exit button doing the obvious
## thing without the pause menu having to know a network exists.
func back_to_menu() -> void:
	if _transitioning:
		return
	if not _may_route():
		_net.call(&"leave")
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


## `NetGame` hands itself over here on boot, and nothing else ever calls this.
##
## Push rather than pull, deliberately: this file must not name the `NetGame`
## autoload. A `--script` harness or a bake tool that compiles `core/` has no
## autoloads at all, and a hard reference would take the whole of `core/` down
## with it. Passed as an Object and called by name for the same reason.
func set_network(net: Object) -> void:
	_net = net


## Route because the HOST said so. `demo_id` is empty for the main menu.
##
## The one path that skips the client guard, and `NetGame` is its only caller. A
## demo the host has and this build does not is reported through `route_failed`
## rather than crashing — the client stays where it is, out of step but alive,
## which is the better of the two bad outcomes.
func follow_host(demo_id: String) -> void:
	if _transitioning:
		_pending_follow = demo_id
		_has_pending_follow = true
		return
	_has_pending_follow = false
	_pending_follow = ""
	# No "already there" shortcut on purpose: the host only announces a route it
	# actually took, so being told to go where you already are means it RELOADED,
	# and following it is the whole job.
	if demo_id.is_empty():
		await _switch_to(_menu_scene, "")
		return
	var info: Dictionary = demo_info(demo_id)
	if info.is_empty() or not ResourceLoader.exists(String(info["scene"])):
		_route_error(demo_id, "The host went to '%s', which this build does not have." % demo_id)
		return
	await _switch_to(String(info["scene"]), demo_id)


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


## True when the local machine may choose the scene: always in single-player, and
## on the host in a networked session. A client is refused.
func _may_route() -> bool:
	if _net == null or not _net.has_method(&"is_networked"):
		return true
	if not bool(_net.call(&"is_networked")):
		return true
	return bool(_net.call(&"is_host"))


func _switch_to(path: String, demo_id: String) -> void:
	_transitioning = true
	# Announced BEFORE the fade, not after the swap: a client told at the end of
	# the host's transition starts its own a whole transition late, and the host
	# would be playing while everybody else is still looking at black.
	route_started.emit(demo_id)
	set_paused(false)
	await _fade_to(1.0)
	var err: Error = get_tree().change_scene_to_file(path)
	if err != OK:
		_transitioning = false
		_has_pending_follow = false
		_pending_follow = ""
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
	if _has_pending_follow:
		var next: String = _pending_follow
		_has_pending_follow = false
		_pending_follow = ""
		follow_host(next)


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
