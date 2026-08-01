class_name NetAddress
extends RefCounted
## What somebody types into a join box, turned into a host and a port.
##
## Split out of `NetGame` so the join UI can validate as you type without
## attempting a connection — the box can go red on the fourth character of
## "192.168.1.999" instead of after a ten second timeout.
##
## Accepts, in this order:
##
##     192.168.1.5              bare IPv4, default port
##     192.168.1.5:27015        IPv4 with a port
##     ::1                      bare IPv6, default port
##     [::1]:27015              IPv6 with a port, brackets required
##     localhost                shorthand for 127.0.0.1, resolved here
##     someone.example.com      hostname, resolved by the caller
##     someone.example.com:9999 hostname with a port
##
## `parse` never blocks. A name that is not already an IP address comes back with
## `needs_lookup` true and `NetGame` resolves it asynchronously — DNS on a bad
## name can stall for seconds and the title screen has to stay alive.

## Ports below 1024 need privileges on most systems and 0 means "any", so neither
## is something a person should be typing into a join box.
const MIN_PORT: int = 1024
const MAX_PORT: int = 65535

## Longest a hostname may be, per RFC 1035. A longer string is a paste accident.
const MAX_HOST: int = 253


## Turn typed text into `{ok, host, port, needs_lookup, error}`.
##
## `host` is an IP address ready for `ENetMultiplayerPeer.create_client` when
## `needs_lookup` is false, and a name that still has to be resolved when it is
## true. `error` is a whole sentence aimed at the person who typed the text, and
## is empty when `ok`.
static func parse(text: String, default_port: int) -> Dictionary:
	var out: Dictionary = {
		"ok": false, "host": "", "port": default_port, "needs_lookup": false, "error": ""
	}
	var trimmed: String = text.strip_edges()
	if trimmed.is_empty():
		out["error"] = "Type an address — an IP like 192.168.1.5, or 192.168.1.5:27015."
		return out
	_split(out, trimmed, default_port)
	if String(out["error"]).is_empty():
		_grade(out)
	return out


## Render a host and port the way this parser reads them back. IPv6 gets its
## brackets, so `format` and `parse` round-trip.
static func format(host: String, port: int) -> String:
	if host.contains(":"):
		return "[%s]:%d" % [host, port]
	return "%s:%d" % [host, port]


## Pull the host and the port apart into `out`. The whole difficulty is IPv6: a
## bare `::1` is full of colons and none of them is a port separator, so a port is
## only recognised after a `]`, or after the single colon of an IPv4-or-name form.
static func _split(out: Dictionary, text: String, default_port: int) -> void:
	out["host"] = text
	if text.begins_with("["):
		_split_bracketed(out, text, default_port)
	elif text.count(":") == 1:
		var parts: PackedStringArray = text.split(":", false)
		if parts.size() != 2:
			out["error"] = "That address has a colon with nothing on one side of it."
		else:
			out["host"] = parts[0]
			_take_port(out, parts[1])


static func _split_bracketed(out: Dictionary, text: String, default_port: int) -> void:
	var close: int = text.find("]")
	if close < 0:
		out["error"] = "That address opens a bracket and never closes it."
		return
	out["host"] = text.substr(1, close - 1)
	var tail: String = text.substr(close + 1)
	if tail.is_empty():
		return
	if not tail.begins_with(":"):
		out["error"] = "Put the port after the brackets, like [::1]:%d." % default_port
		return
	_take_port(out, tail.substr(1))


## Read the port half. Separate because both branches of `_split` need it, and
## because "27015x" has to fail rather than quietly becoming 27015.
static func _take_port(out: Dictionary, text: String) -> void:
	if not text.is_valid_int():
		out["error"] = "'%s' is not a port number." % text
		return
	out["port"] = text.to_int()


## Decide whether the split halves are usable, and whether the host still needs a
## DNS lookup. Mutates `out` in place; the caller has already checked for a split
## error, so anything set here is the final verdict.
static func _grade(out: Dictionary) -> void:
	var host: String = String(out["host"])
	var port: int = int(out["port"])
	if port < MIN_PORT or port > MAX_PORT:
		out["error"] = "Port %d is out of range. Use %d to %d." % [port, MIN_PORT, MAX_PORT]
		return
	if host.to_lower() == "localhost":
		host = "127.0.0.1"
		out["host"] = host
	if host.is_valid_ip_address():
		out["ok"] = true
		return
	if not _is_hostname(host):
		out["error"] = "'%s' is not an address. Use an IP like 192.168.1.5." % host
		return
	out["ok"] = true
	out["needs_lookup"] = true


## Letters, digits, dots and hyphens, no empty ends, nothing enormous, and at
## least one letter — an all-digit string that failed `is_valid_ip_address` is a
## mistyped IP like "192.168.1.999", not a hostname, and saying so is more use
## than sending it to a resolver that will time out.
static func _is_hostname(text: String) -> bool:
	if text.is_empty() or text.length() > MAX_HOST:
		return false
	if text.begins_with(".") or text.ends_with(".") or text.begins_with("-"):
		return false
	var letters: int = 0
	for i: int in text.length():
		var c: int = text.unicode_at(i)
		var alpha: bool = (c >= 65 and c <= 90) or (c >= 97 and c <= 122)
		if alpha:
			letters += 1
		elif not _is_host_punct(c):
			return false
	return letters > 0


## Digit, dot or hyphen: the characters a hostname may carry that are not letters.
static func _is_host_punct(c: int) -> bool:
	return (c >= 48 and c <= 57) or c == 46 or c == 45
