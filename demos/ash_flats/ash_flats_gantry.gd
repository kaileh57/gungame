class_name AshFlatsGantry
extends Node3D
## The starter's gantry: a steel span over the start line with five lamps on it, and the
## painted line under it.
##
## THE COUNTDOWN IS THE GANTRY. There is no screen-space "3… 2… 1…" in this demo and
## there is not going to be — the project's rule is that a number you can read is a thing
## you can walk up to, and a countdown is the strongest case there is for it, because
## everyone on the line is already looking at the same object.
##
## HOW IT READS, and it was chosen to be unmistakable to somebody who has never seen it:
##
##   ARMED       all five lamps dark. The line is open, nobody is racing.
##   COUNTDOWN   all five light AMBER at once, then one goes out per second, left to
##               right. Lamps going out is time running out; you can count what is left
##               without counting what has gone.
##   GO          the instant the last one goes out all five come up GREEN together and
##               the painted line lights with them. Nothing else in this demo is green.
##   RACE        the lamps hold green while the race runs, so a straggler still on the
##               line knows the clock is going.
##   RESULT      amber again, dimmer, until the line re-arms.
##
## Every lamp is one `MeshInstance3D` with a `surface_override_material`, and all three
## materials were baked once by `tools/build_ash_flats.gd`. Switching the countdown is
## therefore five pointer writes a second and no allocation — which matters, because this
## runs on every machine and one of them is also running the whole race.
##
## PURELY A DISPLAY. It holds no state of its own and decides nothing: it reads
## `AshFlatsRace.state` and `AshFlatsRace.lamps_lit()` and paints them. On a client that
## is exactly as correct as on the host, because the countdown clock is the one thing in
## the race that every machine is allowed to run for itself.

## Node names inside the baked scene.
const LAMPS_NODE: NodePath = ^"Lamps"
const PAINT_NODE: NodePath = ^"Paint"

## Seconds the GO flash holds before the lamps settle to their race colour. Long enough
## to be seen by somebody already looking down the line rather than up at the span.
const GO_FLASH: float = 1.4
## The two `_pattern` values that are not a lamp count.
const GO: int = -1
const RESULT: int = -2

@export var dark_material: Material = null
@export var armed_material: Material = null
@export var go_material: Material = null

var _lamps: Array[MeshInstance3D] = []
var _paint: MeshInstance3D = null
var _race: AshFlatsRace = null
var _drawn: int = -1
var _flash: float = 0.0


func _ready() -> void:
	var root: Node = get_node_or_null(LAMPS_NODE)
	if root != null:
		for child: Node in root.get_children():
			var lamp := child as MeshInstance3D
			if lamp != null:
				_lamps.append(lamp)
	_paint = get_node_or_null(PAINT_NODE) as MeshInstance3D
	set_process(false)


func _process(delta: float) -> void:
	_flash = maxf(0.0, _flash - delta)
	_repaint()


## Give the gantry the race it displays. Until this is called it costs nothing at all.
func watch(race: AshFlatsRace) -> void:
	_race = race
	set_process(race != null and not _lamps.is_empty())
	if race == null:
		return
	race.state_changed.connect(_on_state_changed)
	_drawn = -1
	_repaint()


## The lamp pattern as one integer, so the whole display is a single compare per frame.
## `GO` is all green, `RESULT` all amber, zero all dark, and any positive number is that
## many amber lamps lit from the left.
func _pattern() -> int:
	if _race == null:
		return 0
	if _flash > 0.0 or _race.state == AshFlatsRace.State.RUNNING:
		return GO
	if _race.state == AshFlatsRace.State.COUNTDOWN:
		return maxi(_race.lamps_lit(), 1)
	if _race.state == AshFlatsRace.State.FINISHED:
		return RESULT
	return 0


## One compare, and nothing at all when the pattern has not changed. The lamps only
## actually move six times in a whole race.
func _repaint() -> void:
	var want: int = _pattern()
	if want == _drawn:
		return
	_drawn = want
	var lit: Material = go_material if want == GO else armed_material
	for i: int in _lamps.size():
		var on: bool = want == GO or want == RESULT or i < want
		_lamps[i].set_surface_override_material(0, lit if on else dark_material)
	if _paint != null:
		_paint.set_surface_override_material(0, lit if want != 0 else dark_material)


## The one transition worth reacting to rather than polling: the lights going out is the
## start, and it deserves a flash the eye cannot miss.
func _on_state_changed(state: int) -> void:
	if state == AshFlatsRace.State.RUNNING:
		_flash = GO_FLASH
	_drawn = -1
	_repaint()
