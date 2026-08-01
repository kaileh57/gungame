extends Node
## Two-instance host/join smoke test. Runs as a SCENE (not --script) so the
## autoloads, NetGame included, actually resolve.
##   host:   <godot> --path <proj> res://tools/net_smoke.tscn -- --role=host
##   client: <godot> --path <proj> res://tools/net_smoke.tscn -- --role=client
## Exits 0 on success, 1 on failure, and prints one line per checked fact.

const PORT: int = 27015
const DEADLINE: float = 25.0

var _role: String = "host"
var _elapsed: float = 0.0
var _done: bool = false
var _saw_peer: bool = false


func _ready() -> void:
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--role="):
			_role = arg.substr(7)
	if not Engine.has_singleton("NetGame") and get_node_or_null(^"/root/NetGame") == null:
		_fail("NetGame autoload is not present")
		return
	var net: Node = get_node(^"/root/NetGame")
	_report("NetGame autoload resolved")
	for sig: String in ["peer_joined", "peer_left", "joined", "join_failed"]:
		if net.has_signal(sig):
			_report("signal %s present" % sig)
	if net.has_signal("peer_joined"):
		net.connect("peer_joined", _on_peer)
	if net.has_signal("joined"):
		net.connect("joined", _on_joined)
	if net.has_signal("join_failed"):
		net.connect("join_failed", _on_join_failed)

	if _role == "host":
		var err: int = int(net.call("host", PORT))
		if err != OK:
			_fail("host() returned %d" % err)
			return
		_report("host() opened port %d" % PORT)
	else:
		net.call("join", "127.0.0.1", PORT)
		_report("join() dialling 127.0.0.1:%d" % PORT)


func _on_peer(id: int) -> void:
	_saw_peer = true
	_report("peer_joined %d" % id)


func _on_joined() -> void:
	_report("joined the lobby")


func _on_join_failed(reason: String) -> void:
	_fail("join_failed: %s" % reason)


func _process(delta: float) -> void:
	if _done:
		return
	_elapsed += delta
	var net: Node = get_node_or_null(^"/root/NetGame")
	if net != null and net.has_method("players"):
		var n: int = (net.call("players") as Array).size()
		if n >= 2:
			_report("roster has %d players" % n)
			_pass()
			return
	if _elapsed > DEADLINE:
		_fail("timed out after %.0fs (saw_peer=%s)" % [DEADLINE, str(_saw_peer)])


func _report(msg: String) -> void:
	print("[%s] %s" % [_role, msg])


func _pass() -> void:
	_done = true
	print("[%s] RESULT: PASS" % _role)
	get_tree().quit(0)


func _fail(msg: String) -> void:
	_done = true
	print("[%s] FAIL: %s" % [_role, msg])
	print("[%s] RESULT: FAIL" % _role)
	get_tree().quit(1)
