class_name NetRoster
extends RefCounted
## The player list, in both of the forms it has to exist in at once.
##
## `entries` is the WIRE form — an Array of `{id, slot, name}` — and on the host it
## is the source of truth. It is small enough, four entries and never more, that
## the host sends the WHOLE thing every time anything changes. A full snapshot
## cannot drift the way a stream of deltas can, and at this size there is nothing
## to be won by being clever about it.
##
## `players` is the MATERIALISED form — peer id to `NetPlayer` — and every machine
## builds it from the same wire form, so `NetGame.players()` answers identically
## on all of them. Existing objects are updated in place rather than rebuilt, so
## an avatar handle and an aim point survive a rename or somebody else joining.
##
## `NetGame` owns exactly one of these and is the only thing that should make one.
## Clients never write `entries`; they receive it and call `apply`.

## The wire form. Host writes, everyone reads.
var entries: Array = []

## peer id -> `NetPlayer`. Built by `apply` on every machine.
var players: Dictionary = {}


## HOST ONLY. Put a new player in the lowest free slot under a name nobody else
## has, and return the entry that was added.
func add(id: int, wanted: String) -> Dictionary:
	var entry: Dictionary = {"id": id, "slot": free_slot(), "name": unique_name(wanted, id)}
	entries.append(entry)
	return entry


## HOST ONLY. True if there was one to remove.
func remove(id: int) -> bool:
	var index: int = index_of(id)
	if index < 0:
		return false
	entries.remove_at(index)
	return true


## HOST ONLY. True if the entry existed and now carries `text`.
func rename(id: int, text: String) -> bool:
	var index: int = index_of(id)
	if index < 0:
		return false
	(entries[index] as Dictionary)["name"] = text
	return true


func index_of(id: int) -> int:
	var found: int = -1
	for i: int in entries.size():
		if int((entries[i] as Dictionary)["id"]) == id:
			found = i
			break
	return found


func full() -> bool:
	return entries.size() >= NetPlayer.MAX_PLAYERS


## The lowest free slot, so a guest who leaves frees their colour for the next one
## rather than the fourth person always being sage. The host takes slot 0 when the
## session opens and holds it for as long as the session lasts.
func free_slot() -> int:
	var taken: Dictionary = {}
	for entry: Variant in entries:
		taken[int((entry as Dictionary)["slot"])] = true
	var slot: int = NetPlayer.MAX_PLAYERS - 1
	for i: int in NetPlayer.MAX_PLAYERS:
		if not taken.has(i):
			slot = i
			break
	return slot


## Two people who both type "Kellen" become "Kellen" and "Kellen 2". A roster with
## two identical names in it is a roster nobody can read.
func unique_name(base: String, id: int) -> String:
	var wanted: String = base if not base.is_empty() else "PLAYER %d" % id
	var candidate: String = wanted
	var n: int = 2
	while _name_taken(candidate) and n <= NetPlayer.MAX_PLAYERS:
		candidate = "%s %d" % [wanted, n]
		n += 1
	return candidate


## Materialise `wire` onto `players`, and report what moved as `{added, gone}` so
## the caller can announce it.
##
## `mine` is this machine's peer id and `local` is the `NetPlayer` that must stand
## for it — `NetGame` keeps one such object for the whole run of the process so
## that anything may cache `local_player()` and never see it go stale.
func apply(wire: Array, mine: int, local: NetPlayer) -> Dictionary:
	var seen: Dictionary = {}
	var added := PackedInt32Array()
	for raw: Variant in wire:
		var entry: Dictionary = raw
		var id: int = int(entry.get("id", 0))
		if id <= 0:
			continue
		seen[id] = true
		var who: NetPlayer = players.get(id, null)
		if who == null:
			who = local if id == mine else NetPlayer.new()
			who.peer_id = id
			who.is_local = id == mine
			players[id] = who
			added.append(id)
		who.slot = clampi(int(entry.get("slot", 0)), 0, NetPlayer.MAX_PLAYERS - 1)
		who.username = String(entry.get("name", ""))
	var gone := PackedInt32Array()
	for id: int in players:
		if not seen.has(id):
			gone.append(id)
	for id: int in gone:
		players.erase(id)
	return {"added": added, "gone": gone}


## Everyone, in slot order, which puts the host first.
func sorted() -> Array[NetPlayer]:
	var list: Array[NetPlayer] = []
	for id: int in players:
		list.append(players[id])
	list.sort_custom(func(a: NetPlayer, b: NetPlayer) -> bool: return a.slot < b.slot)
	return list


## Is `id` in a wire roster that has not been applied yet? A client uses this on
## the first roster it receives to find out whether it was let in.
static func has_id(wire: Array, id: int) -> bool:
	var found: bool = false
	for raw: Variant in wire:
		if int((raw as Dictionary).get("id", 0)) == id:
			found = true
			break
	return found


func _name_taken(text: String) -> bool:
	var taken: bool = false
	for entry: Variant in entries:
		if String((entry as Dictionary)["name"]) == text:
			taken = true
			break
	return taken
