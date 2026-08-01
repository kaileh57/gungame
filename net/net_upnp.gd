class_name NetUpnp
extends RefCounted
## Asks the router to open the host's port, on a background Thread.
##
## `UPNP.discover()` broadcasts SSDP and then waits for a gateway to answer. It
## takes one to three seconds on a good home network and the full timeout on one
## with no gateway at all, so it can never run on the main thread — keeping the
## title screen alive while the router is asked is the entire reason this class
## exists as a separate object.
##
## FAILURE IS NORMAL AND IS NOT FATAL. Plenty of routers have UPnP switched off
## on purpose, plenty of connections sit behind carrier-grade NAT where no amount
## of UPnP helps, and a LAN game does not need it at all. `NetGame.host()` starts
## this and carries on hosting regardless; all this class owes anybody is one
## honest sentence about what happened, which is what `finished` carries.
##
## Nothing here is called from the main thread while the worker runs, and the
## worker publishes nothing directly: it writes a private result and defers, so
## every public field on this object is only ever written on the main thread.

## Emitted on the MAIN thread when the attempt has settled, win or lose.
## `message` is a fragment written to be dropped into a sentence, lower case and
## without a full stop — "UDP 27015 forwarded", "no router answered UPnP".
signal finished(ok: bool, message: String)

enum State {
	## Nothing has been attempted, or the mapping has been given back.
	IDLE,
	## The worker is talking to the router right now.
	WORKING,
	## The port is forwarded and `mapped_port` says which one.
	MAPPED,
	## The router said no, or there is no router. `message` says which.
	FAILED,
}

## Milliseconds `discover` waits for a gateway. Godot's own default, and about as
## short as it can be without missing slow consumer routers.
const DISCOVER_MS: int = 2000

## Lease durations tried, in order. Most consumer routers and miniupnpd reject a
## non-zero lease outright (`OnlyPermanentLeasesSupported`), and a minority reject
## a permanent one, so both get a turn before this gives up.
const LEASE_TRIES: PackedInt32Array = [0, 3600]

## ENet is UDP and only UDP. Forwarding TCP as well would be a lie in the router's
## table that nothing ever uses.
const PROTOCOL: String = "UDP"

## What the router's port-forward table calls this entry. Some routers refuse a
## mapping with a description and accept the identical one without, which is why
## `_map` tries it both ways.
const DESCRIPTION: String = "gungame"

## Where the attempt got to. One of `State`.
var state: int = State.IDLE

## A sentence fragment about the last attempt, for UI. Empty before the first one.
var message: String = ""

## The WAN address the gateway reports, when it reported one. Empty otherwise.
## This is the address to read out to somebody who wants to join over the
## internet — the machine's own IP is a LAN address and no use to them.
var external_ip: String = ""

## The forwarded port while `state` is MAPPED, otherwise 0.
var mapped_port: int = 0

var _thread: Thread = null
## The discovered gateway, kept alive after a successful mapping so the mapping
## can be handed back later without paying for discovery a second time.
var _upnp: UPNP = null
## Written by the worker at the very end of its run and read by the main thread
## only after `call_deferred` or `wait_to_finish`, both of which are barriers.
var _result: Dictionary = {}


## Start asking the router to forward `port`. Returns false if a worker is already
## running or a thread could not be started; either way the caller carries on
## hosting, because this is a bonus and not a prerequisite.
func forward(port: int) -> bool:
	if state == State.WORKING:
		return false
	_join()
	state = State.WORKING
	message = "asking the router"
	external_ip = ""
	_thread = Thread.new()
	var err: Error = _thread.start(_work.bind(port))
	if err != OK:
		_thread = null
		state = State.FAILED
		message = "could not start the UPnP thread (error %d)" % err
		return false
	return true


## Hand the mapping back, on a thread, because deleting one is another round trip
## to the router. Safe to call when nothing is mapped.
func release() -> void:
	_join()
	_absorb()
	if _upnp == null or mapped_port <= 0:
		_reset()
		return
	var gateway: UPNP = _upnp
	var port: int = mapped_port
	_reset()
	_thread = Thread.new()
	if _thread.start(_unmap.bind(gateway, port)) != OK:
		_thread = null


## Called when the process is going down. Joins the worker — a Thread that is
## never joined is an error at exit — and then gives the mapping back inline,
## because there is no frame left in which to do it politely.
func shutdown() -> void:
	_join()
	_absorb()
	if _upnp != null and mapped_port > 0:
		_upnp.delete_port_mapping(mapped_port, PROTOCOL)
	_reset()


## The worker. Everything in here runs off the main thread and touches nothing
## that the main thread can see except `_result`, which is written once, last.
func _work(port: int) -> void:
	var gateway := UPNP.new()
	var found: int = gateway.discover(DISCOVER_MS)
	var out: Dictionary = {"ok": false, "message": "", "ip": "", "port": port, "gateway": null}
	if found != UPNP.UPNP_RESULT_SUCCESS:
		out["message"] = "no router answered UPnP (%s)" % _result_text(found)
	elif gateway.get_gateway() == null or not gateway.get_gateway().is_valid_gateway():
		out["message"] = "something answered UPnP but it is not an internet gateway"
	else:
		out["ip"] = gateway.query_external_address()
		var mapped: int = _map(gateway, port)
		out["ok"] = mapped == UPNP.UPNP_RESULT_SUCCESS
		if bool(out["ok"]):
			out["message"] = "UDP %d forwarded" % port
			out["gateway"] = gateway
		else:
			out["message"] = (
				"the router refused to forward UDP %d (%s)" % [port, _result_text(mapped)]
			)
	_result = out
	_settle.call_deferred()


## Publish the worker's result and tell whoever is listening. Main thread only.
## Silent when the result has already been taken — `release` and `shutdown` both
## absorb it themselves, and a deferred call that lands after one of those must
## not report a failure that never happened.
func _settle() -> void:
	if _result.is_empty():
		return
	_absorb()
	finished.emit(state == State.MAPPED, message)


## Move `_result` onto the public fields. Idempotent, because `_settle`, `release`
## and `shutdown` all call it and on a fast quit more than one of them gets there.
func _absorb() -> void:
	if _result.is_empty():
		return
	var ok: bool = bool(_result["ok"])
	state = State.MAPPED if ok else State.FAILED
	message = String(_result["message"])
	external_ip = String(_result["ip"])
	mapped_port = int(_result["port"]) if ok else 0
	_upnp = _result["gateway"] as UPNP
	_result = {}


## Four attempts, cheapest and likeliest first: a permanent lease with a
## description, a permanent lease without one, then the same pair on an hour's
## lease. Routers disagree about which of those they will accept and the
## disagreement is not predictable from anything we can see from here.
static func _map(gateway: UPNP, port: int) -> int:
	var result: int = UPNP.UPNP_RESULT_UNKNOWN_ERROR
	for lease: int in LEASE_TRIES:
		result = gateway.add_port_mapping(port, port, DESCRIPTION, PROTOCOL, lease)
		if result == UPNP.UPNP_RESULT_SUCCESS:
			break
		result = gateway.add_port_mapping(port, port, "", PROTOCOL, lease)
		if result == UPNP.UPNP_RESULT_SUCCESS:
			break
	return result


static func _unmap(gateway: UPNP, port: int) -> void:
	gateway.delete_port_mapping(port, PROTOCOL)


## The `UPNP.UPNP_RESULT_*` codes worth telling a person apart, in the words that
## tell them what to do about it. Anything else comes back as its number, which is
## still better than silence when somebody has to search for it.
static func _result_text(code: int) -> String:
	var text: String = "router error %d" % code
	match code:
		UPNP.UPNP_RESULT_SUCCESS:
			text = "ok"
		UPNP.UPNP_RESULT_NO_DEVICES, UPNP.UPNP_RESULT_NO_GATEWAY:
			text = "nothing on this network speaks UPnP"
		UPNP.UPNP_RESULT_NOT_AUTHORIZED:
			text = "UPnP is switched off in the router"
		UPNP.UPNP_RESULT_CONFLICT_WITH_OTHER_MAPPING:
			text = "that port is already forwarded to another machine"
		UPNP.UPNP_RESULT_CONFLICT_WITH_OTHER_MECHANISM:
			text = "the router has that port reserved"
		UPNP.UPNP_RESULT_ONLY_PERMANENT_LEASE_SUPPORTED:
			text = "the router only allows permanent forwards"
		UPNP.UPNP_RESULT_NO_PORT_MAPS_AVAILABLE:
			text = "the router's forwarding table is full"
		UPNP.UPNP_RESULT_HTTP_ERROR, UPNP.UPNP_RESULT_SOCKET_ERROR:
			text = "the router stopped answering half way through"
		UPNP.UPNP_RESULT_INVALID_GATEWAY:
			text = "the gateway is not one we can talk to"
	return text


## Join the worker if there is one. `wait_to_finish` on a thread that has already
## returned is immediate; on one still in `discover` it costs up to `DISCOVER_MS`,
## which is the price of never leaking a thread.
func _join() -> void:
	if _thread == null:
		return
	if _thread.is_started():
		_thread.wait_to_finish()
	_thread = null


func _reset() -> void:
	state = State.IDLE
	message = ""
	external_ip = ""
	mapped_port = 0
	_upnp = null
	_result = {}
