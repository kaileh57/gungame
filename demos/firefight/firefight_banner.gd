class_name FirefightBanner
extends Node3D
## The scoreboard, and the only one in this demo: a mast over every zone flying
## the colours of whoever currently holds it.
##
## Full mast means held and quiet. Half mast means contested — two factions over
## the ledger's threshold on the same ground. Struck to the foot of the mast
## means nobody owns it. A flag that is climbing or falling is a zone that just
## changed hands, and it is visible from anywhere on the map, which is the whole
## reason the standings are not a line of text in a corner.
##
## It listens to the ledger rather than polling it. `Factions.territory` emits on
## capture and on contest, and between those two signals nothing here runs.
##
## IN MULTIPLAYER the ledger only exists on the host — a client's is stood down,
## because a client that ticked its own territory would be running its own war.
## `set_state` is how the wire drives a mast directly, and it is deliberately the
## same two facts the ledger's own signals carry, so the mast cannot tell which
## of the two spoke to it.

## Every mast in the scene, so the replication link can find the whole scoreboard
## without being handed a list of node paths that the bake would have to keep.
const GROUP: StringName = &"firefight_banner"

## Zone in `Factions.territory` this mast reports on.
@export var zone_id: StringName = &""
## The flag. Slides up and down the mast in local Y.
@export var flag_path: NodePath = NodePath("Flag")
## Local Y of the flag at full mast.
@export_range(0.5, 20.0, 0.05) var top_height: float = 5.2
## Local Y of the flag when the ground is unclaimed.
@export_range(0.0, 8.0, 0.05) var foot_height: float = 0.55
## Fraction of the way up the flag flies while the zone is contested.
@export_range(0.1, 0.95, 0.01) var half_mast: float = 0.52
## Metres per second the flag travels. Slow: a capture should take a moment.
@export_range(0.2, 12.0, 0.1) var hoist_speed: float = 1.6

var _flag: MeshInstance3D = null
var _want_y: float = 0.0
var _owner: int = Factions.NEUTRAL_ID
var _contested: bool = false


func _ready() -> void:
	add_to_group(GROUP)
	_flag = get_node_or_null(flag_path) as MeshInstance3D
	var ledger: Factions.Territory = Factions.territory
	ledger.owner_changed.connect(_on_owner_changed)
	ledger.contest_changed.connect(_on_contest_changed)
	_owner = ledger.zone_owner(zone_id)
	_contested = ledger.is_contested(zone_id)
	_want_y = _height_for()
	if _flag != null:
		_flag.position.y = _want_y
		_flag.set_instance_shader_parameter(&"tint", _colour_for())
	set_physics_process(false)


func _exit_tree() -> void:
	var ledger: Factions.Territory = Factions.territory
	if ledger.owner_changed.is_connected(_on_owner_changed):
		ledger.owner_changed.disconnect(_on_owner_changed)
	if ledger.contest_changed.is_connected(_on_contest_changed):
		ledger.contest_changed.disconnect(_on_contest_changed)


func _physics_process(delta: float) -> void:
	if _flag == null:
		set_physics_process(false)
		return
	_flag.position.y = move_toward(_flag.position.y, _want_y, hoist_speed * delta)
	if is_equal_approx(_flag.position.y, _want_y):
		set_physics_process(false)


func owner_faction() -> int:
	return _owner


## Drive the mast from somewhere other than the ledger — the replication link, on
## a client. Idempotent, and cheap when nothing changed: a mast that is already
## flying the right colour at the right height does not restart its hoist.
func set_state(new_owner: int, contested: bool) -> void:
	if new_owner == _owner and contested == _contested:
		return
	if new_owner != _owner:
		_owner = new_owner
		if _flag != null:
			_flag.set_instance_shader_parameter(&"tint", _colour_for())
	_contested = contested
	_restate()


func _on_owner_changed(id: StringName, _previous: int, current: int) -> void:
	if id != zone_id:
		return
	_owner = current
	if _flag != null:
		_flag.set_instance_shader_parameter(&"tint", _colour_for())
	_restate()


func _on_contest_changed(id: StringName, contested: bool) -> void:
	if id != zone_id:
		return
	_contested = contested
	_restate()


func _restate() -> void:
	_want_y = _height_for()
	set_physics_process(true)


func _height_for() -> float:
	if _owner < 0:
		return foot_height
	if _contested:
		return foot_height + (top_height - foot_height) * half_mast
	return top_height


## Neutral ground flies bare canvas. Anything else flies the holder's colour,
## lifted well clear of the haze so it still reads at two hundred metres.
func _colour_for() -> Color:
	if _owner < 0:
		return Palette.CANVAS
	return Palette.faction_color(_owner) * 1.4
