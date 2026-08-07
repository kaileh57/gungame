extends Node
## Does the pause menu actually work while a session is up?
##   "<godot>" --headless --path <proj> res://tools/verify_pause_menu.tscn
##
## Reported as "escape opens the menu but the buttons are dead in multiplayer". Boots a
## real demo, hosts a real ENet session in this same process, pauses, and inspects every
## thing that could swallow a click.

const DEMO := "res://demos/range/range.tscn"

var _f := 0
var _root: Node = null
var _log: Array = []
var _bad := 0


func _ready() -> void:
	# The harness must outlive its own pause. Default INHERIT means calling
	# `set_paused(true)` stops this node's own `_process` and the test hangs forever --
	# which is the same class of bug it is here to find.
	process_mode = Node.PROCESS_MODE_ALWAYS
	_root = (load(DEMO) as PackedScene).instantiate()
	add_child(_root)


func _process(_d: float) -> void:
	_f += 1
	if _f == 8:
		_log.append("networked before host   %s" % NetGame.is_networked())
		var err: int = NetGame.host()
		_log.append("host()                  err=%s" % err)
	elif _f == 30:
		_log.append("networked after host    %s" % NetGame.is_networked())
		_log.append("is_host                 %s" % NetGame.is_host())
		_log.append("local_player            %s" % (NetGame.local_player() != null))
		SceneRouter.set_paused(true)
	elif _f == 60:
		_inspect()


func _inspect() -> void:
	var menu: Node = _find(get_tree().root, "PauseMenu")
	if menu == null:
		_fail("no PauseMenu in the tree at all")
		_out()
		return
	_log.append("menu visible            %s" % menu.visible)
	_log.append("menu process_mode       %s  (0=inherit 3=always)" % menu.process_mode)
	_log.append("tree paused             %s" % get_tree().paused)
	_log.append("router wants capture    %s  (must be false)" % SceneRouter.mouse_should_be_captured())

	if not menu.visible:
		_fail("the menu never became visible")
	if SceneRouter.mouse_should_be_captured():
		_fail("pointer is captured while paused, so no click can reach a button")

	for path: String in ["Root/Frame/Body/Resume", "Root/Frame/Body/SettingsButton",
			"Root/Frame/Body/MainMenuButton"]:
		var b := menu.get_node_or_null(NodePath(path)) as Button
		if b == null:
			_fail("missing button %s" % path)
			continue
		# `can_process` is the real question: a paused tree stops input on anything that
		# did not opt out, and a Button that cannot process cannot be clicked.
		_log.append(
			"%-14s vis=%s disabled=%s can_process=%s filter=%s"
			% [b.name, b.visible, b.disabled, b.can_process(), b.mouse_filter]
		)
		if not b.can_process():
			_fail("%s cannot process while paused" % b.name)
		if b.disabled:
			_fail("%s is disabled" % b.name)
		if b.mouse_filter == Control.MOUSE_FILTER_IGNORE:
			_fail("%s ignores the mouse" % b.name)

	# THE REGRESSION THIS EXISTS FOR. Multiplayer means two windows, which means alt-tab.
	# Simulate focus leaving and returning while the menu is open: the pointer must still be
	# free afterwards. Restoring a remembered mode re-captured it over the open menu and
	# every button went dead.
	# Order matters, and this is the order that actually broke. Focus is lost while the
	# pointer is CAPTURED, the game is paused while the window is in the background -- which
	# multiplayer makes possible, because a host can pause or route you remotely -- and only
	# then does focus return. The old handler restored the mode it remembered from step one
	# and captured the pointer over an open menu.
	SceneRouter.set_paused(false)
	SceneRouter.set_mouse_captured(true)
	GameSettings.notification(NOTIFICATION_APPLICATION_FOCUS_OUT)
	SceneRouter.set_paused(true)
	GameSettings.notification(NOTIFICATION_APPLICATION_FOCUS_IN)
	# Asserted on the ROUTER'S INTENT, not on Input.mouse_mode. A headless run has no
	# display server, so `Input.mouse_mode` never actually changes and reading it back
	# passes whatever the code does — which is exactly how the first version of this test
	# passed against the very bug it was written for.
	var wants: bool = SceneRouter.mouse_should_be_captured()
	_log.append("router wants capture    %s  (must be false while paused)" % wants)
	if wants:
		_fail("focus returning re-captured the mouse over the open pause menu")

	var scrim := menu.get_node_or_null(^"Scrim") as Control
	if scrim != null:
		_log.append("scrim filter=%s can_process=%s" % [scrim.mouse_filter, scrim.can_process()])
	_out()


func _fail(text: String) -> void:
	_bad += 1
	_log.append("FAIL  %s" % text)


func _out() -> void:
	print("\n===== PAUSE MENU =====")
	for l in _log:
		print(l)
	print("result   %s" % ("FAIL" if _bad else "PASS"))
	print("=====  END  =====")
	# Give the router's UPnP mapping back before leaving.
	NetGame.leave()
	get_tree().quit(1 if _bad else 0)


func _find(n: Node, want: String) -> Node:
	if n.name == want:
		return n
	for c: Node in n.get_children():
		var f: Node = _find(c, want)
		if f != null:
			return f
	return null
