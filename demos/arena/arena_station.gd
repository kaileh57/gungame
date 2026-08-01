class_name ArenaStation
extends Node3D
## The control desk. Four dials, three levers and a screen, all of them objects in
## the world that you operate by shooting them.
##
## There is no menu for any of this and there is not going to be one. The desk
## reads its own state off the controls rather than mirroring it into variables,
## so what the dial is pointing at IS the setting — there is no second copy to
## drift out of step with the knob.
##
## Bullets reach the controls through `bullet_hit`, which the demo calls with
## whatever the player's weapon says it struck. The walk-up path for the same
## actuation is `DiegeticInteractor`, which the demo stands up over this desk and
## points with `interact_reach`.

## The SPAWN lever went over. `species` is empty for "any". `mix` is how many
## factions the wave is dealt across, starting from `faction` — 1 is one side, 3
## is a three-way brawl.
signal spawn_requested(species: StringName, faction: int, count: int, mix: int)
## The CLEAR lever went over.
signal clear_requested
## The aggression dial moved. 0 cowed, 1 rabid.
signal aggression_changed(value: float)
## The AI DEBUG lever went over.
signal debug_toggled(on: bool)

const CONTROL_GROUP: StringName = &"diegetic_control"

## The rungs the COUNT dial offers, before the arena's live cap is applied.
##
## A LADDER AND NOT A RANGE. The dial actuates one detent per shot, so every rung
## costs the operator a trigger pull and the useful shape is coarse at the top —
## 1, 4, 8 are the numbers you want when you are looking at one animal, and 64 or
## 96 are the numbers you want when you are looking at a war. Anything above the
## controller's own `population_cap` is dropped and the cap itself is appended, so
## the LAST detent is always exactly what this arena can actually hold. See
## `set_count_ceiling`.
const COUNT_LADDER: PackedInt32Array = [1, 2, 4, 8, 12, 16, 24, 32, 48, 64, 96, 128]
## Detent the COUNT dial starts on, as an index into whatever ladder survived the
## cap. Four rungs in is 12 on the shipped ladder — a wave, not a demonstration.
const COUNT_DEFAULT_INDEX: int = 4
## Aggression detents. The dial is five positions because that is as fine as a
## knob you shoot from ten metres can usefully be.
const AGGRESSION_LABELS: PackedStringArray = ["COWED", "WARY", "STEADY", "PRESSING", "RABID"]
const AGGRESSION_VALUES: PackedFloat32Array = [0.05, 0.28, 0.5, 0.74, 1.0]
## How many factions a wave is dealt across, and what the MIX dial calls each.
## Dealing round robin from the FACTION dial's selection means "TWO WAY" starting
## on CHOIR is CHOIR against SCAV, which is what a wrap should do.
const MIX_LABELS: PackedStringArray = ["ONE SIDE", "TWO WAY", "THREE WAY"]

## How far a walk-up press reaches, metres. Read by `ArenaController` when it
## builds the desk's hands, so the desk owns the one number.
@export_range(0.5, 6.0, 0.05) var interact_reach: float = 2.6
## Species the SPECIES dial offers, after the ANY entry.
@export var species: Array[StringName] = []
## Display names for those species, index aligned.
@export var species_labels: PackedStringArray = PackedStringArray()

var _alive: int = 0
var _capacity: int = 0
var _status: String = ""
## The rungs the COUNT dial is currently offering, after the cap was applied.
var _count_steps: PackedInt32Array = PackedInt32Array()

@onready var _species_dial: DiegeticDial = $SpeciesDial
@onready var _faction_dial: DiegeticDial = $FactionDial
@onready var _mix_dial: DiegeticDial = $MixDial
@onready var _count_dial: DiegeticDial = $CountDial
@onready var _aggression_dial: DiegeticDial = $AggressionDial
@onready var _spawn_lever: DiegeticLever = $SpawnLever
@onready var _clear_lever: DiegeticLever = $ClearLever
@onready var _debug_lever: DiegeticLever = $DebugLever
@onready var _readout: DiegeticReadout = $Readout


func _ready() -> void:
	_species_dial.set_options(_species_options())
	_faction_dial.set_options(PackedStringArray(Factions.NAMES))
	_mix_dial.set_options(MIX_LABELS)
	# THREE WAY out of the box. The arena is a combat sandbox and a wave that is
	# all one faction can only ever fight the player; dealing it across all three
	# is the behaviour that was asked for, and the dial is right there to turn it
	# back to ONE SIDE when what you want is twelve of one animal in a row.
	_mix_dial.set_value(float(MIX_LABELS.size() - 1), false)
	_aggression_dial.set_options(AGGRESSION_LABELS)
	_aggression_dial.set_value(2.0, false)
	set_count_ceiling(COUNT_LADDER[COUNT_LADDER.size() - 1])
	_species_dial.option_selected.connect(_on_setting_changed)
	_faction_dial.option_selected.connect(_on_setting_changed)
	_mix_dial.option_selected.connect(_on_setting_changed)
	_count_dial.option_selected.connect(_on_setting_changed)
	_aggression_dial.option_selected.connect(_on_aggression_changed)
	_spawn_lever.toggled.connect(_on_spawn_lever)
	_clear_lever.toggled.connect(_on_clear_lever)
	_debug_lever.toggled.connect(func(on: bool) -> void: debug_toggled.emit(on))
	_refresh()


## Re-cut the COUNT dial's detents so its last rung is exactly `cap`.
##
## `ArenaController` calls this with the total its three spawners can actually
## sustain, so the knob cannot ask for a wave the arena will not deliver and the
## operator can always reach the ceiling by turning it to the stop. The selection
## is preserved by VALUE rather than by index — re-cutting a ladder under a dial
## that is pointing at "32" must leave it pointing at 32 and not at whatever now
## happens to sit in slot 7.
func set_count_ceiling(cap: int) -> void:
	var want: int = maxi(cap, 1)
	var wanted_count: int = selected_count() if not _count_steps.is_empty() else -1
	var steps := PackedInt32Array()
	for rung: int in COUNT_LADDER:
		if rung < want:
			steps.append(rung)
	steps.append(want)
	if steps == _count_steps:
		return
	_count_steps = steps
	var labels := PackedStringArray()
	labels.resize(steps.size())
	for i: int in steps.size():
		labels[i] = str(steps[i])
	_count_dial.set_options(labels)
	var index: int = mini(COUNT_DEFAULT_INDEX, steps.size() - 1)
	if wanted_count > 0:
		index = _nearest_step(wanted_count)
	_count_dial.set_value(float(index), false)
	_refresh()


## Detent whose count is closest to `wanted`, preferring the lower on a tie so a
## shrinking cap never quietly asks for more than it did before.
func _nearest_step(wanted: int) -> int:
	var best: int = 0
	var best_gap: int = 1 << 30
	for i: int in _count_steps.size():
		var gap: int = absi(_count_steps[i] - wanted)
		if gap < best_gap:
			best_gap = gap
			best = i
	return best


## Route a bullet at whatever it struck. Returns true when the collider was one of
## this station's controls and it actuated, which is the demo's cue to stop
## treating the round as an ordinary impact.
func bullet_hit(collider: Object, at: Vector3, power: float) -> bool:
	var control: DiegeticControl = _control_of(collider)
	if control == null:
		return false
	return control.shoot(at, power)


## What the desk currently says it will do. The demo pushes live numbers back in
## through `set_roster` and `set_status`; everything else is read off the knobs.
func selected_species() -> StringName:
	var i: int = _species_dial.selected_index() - 1
	if i < 0 or i >= species.size():
		return &""
	return species[i]


## What the species dial reads, for a status line that should say "ANY" rather
## than an empty string.
func selected_species_label() -> String:
	return _species_dial.selected_text()


func selected_faction() -> int:
	return clampi(_faction_dial.selected_index(), 0, Factions.COUNT - 1)


func selected_count() -> int:
	if _count_steps.is_empty():
		return 1
	return _count_steps[clampi(_count_dial.selected_index(), 0, _count_steps.size() - 1)]


## Factions the wave is dealt across, 1 to 3.
func selected_mix() -> int:
	return clampi(_mix_dial.selected_index() + 1, 1, Factions.COUNT)


func selected_aggression() -> float:
	var i: int = clampi(_aggression_dial.selected_index(), 0, AGGRESSION_VALUES.size() - 1)
	return AGGRESSION_VALUES[i]


## Live population, for the screen.
func set_roster(alive: int, capacity: int) -> void:
	if alive == _alive and capacity == _capacity:
		return
	_alive = alive
	_capacity = capacity
	_refresh()


## One line of whatever the director is doing. Cheap to call; the screen only
## re-renders when the text actually changes.
func set_status(text: String) -> void:
	if text == _status:
		return
	_status = text
	_refresh()


## Put the spawn lever back down once the wave has walked in, so the next throw
## is a fresh one rather than a toggle nobody can see the state of.
func rearm() -> void:
	_spawn_lever.set_on(false, false)
	_clear_lever.set_on(false, false)


func _species_options() -> PackedStringArray:
	var out := PackedStringArray(["ANY"])
	for i: int in species.size():
		out.append(
			species_labels[i] if i < species_labels.size() else String(species[i]).to_upper()
		)
	return out


## The control that owns a collider. A control is a `StaticBody3D`, so the
## collider is normally the control itself; the parent walk covers a control whose
## builder gave it a separate hit body.
func _control_of(collider: Object) -> DiegeticControl:
	var node: Node = collider as Node
	var depth: int = 0
	while node != null and depth < 3:
		var control := node as DiegeticControl
		if control != null and control.is_in_group(CONTROL_GROUP) and is_ancestor_of(control):
			return control
		node = node.get_parent()
		depth += 1
	return null


func _on_setting_changed(_index: int, _text: String) -> void:
	_refresh()


func _on_aggression_changed(_index: int, _text: String) -> void:
	aggression_changed.emit(selected_aggression())
	_refresh()


func _on_spawn_lever(on: bool) -> void:
	if not on:
		return
	spawn_requested.emit(selected_species(), selected_faction(), selected_count(), selected_mix())


func _on_clear_lever(on: bool) -> void:
	if not on:
		return
	clear_requested.emit()


func _refresh() -> void:
	_readout.set_title("ENEMY TEST ARENA")
	var lines := PackedStringArray()
	lines.append(
		(
			"%s  ·  %s  ·  x%d"
			% [_species_dial.selected_text(), _faction_dial.selected_text(), selected_count()]
		)
	)
	lines.append(
		"mix  %s  ·  posture  %s" % [_mix_dial.selected_text(), _aggression_dial.selected_text()]
	)
	lines.append("alive  %d / %d" % [_alive, _capacity])
	if not _status.is_empty():
		lines.append(_status)
	_readout.set_lines(lines)
	var fill: float = 0.0 if _capacity <= 0 else float(_alive) / float(_capacity)
	_readout.set_bars(
		PackedStringArray(["POPULATION", "POSTURE"]),
		PackedFloat32Array([fill, selected_aggression()]),
		PackedColorArray([UiStyle.WARN if fill > 0.85 else UiStyle.GOOD, UiStyle.ACCENT])
	)
