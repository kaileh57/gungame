class_name RangeAmbience
extends Node3D
## The things that move when nobody is shooting: tarps in the wind, work lights
## that were wired by someone in a hurry, and dust off the berms.
##
## All of it is one `_process` over a handful of cached nodes. There is no reason
## for three scripts and three process callbacks when the whole job is a sine
## wave and a random walk, and a demo that spends a millisecond a frame on
## atmosphere has spent it badly.
##
## Nothing here creates anything. The tarps and the lamps were baked into the
## scene by `tools/build_range.gd`; this only leans on them.

## Groups the bake puts on the nodes this drives, so the wiring survives the
## scene being re-baked with a different node layout.
const TARP_GROUP: StringName = &"range_tarps"
const LIGHT_GROUP: StringName = &"range_work_lights"

@export_group("Wind")
## Peak tarp sway, radians.
@export_range(0.0, 0.5, 0.005) var sway_amplitude: float = 0.075
## Base sway rate, radians per second of phase.
@export_range(0.0, 4.0, 0.05) var sway_rate: float = 0.85
## How much the gust envelope opens and closes the sway. 0 is a steady breeze.
@export_range(0.0, 1.0, 0.01) var gust_depth: float = 0.55
@export_range(0.02, 1.0, 0.01) var gust_rate: float = 0.14

@export_group("Work lights")
## Peak brightness swing, as a fraction of each lamp's baked energy.
@export_range(0.0, 0.6, 0.01) var flicker_depth: float = 0.11
@export_range(0.1, 12.0, 0.1) var flicker_rate: float = 3.1
## Chance per second that a lamp drops out for a moment. Bad wiring.
@export_range(0.0, 2.0, 0.01) var dropout_rate: float = 0.12
@export_range(0.02, 0.4, 0.01) var dropout_seconds: float = 0.09

@export_group("Ash")
## Ash puffs drifting off the berms, per second. Zero turns them off.
@export_range(0.0, 4.0, 0.05) var drift_rate: float = 0.55
@export_range(10.0, 400.0, 5.0) var drift_reach: float = 220.0

var _tarps: Array[Node3D] = []
var _tarp_rest: PackedFloat32Array = PackedFloat32Array()
var _tarp_phase: PackedFloat32Array = PackedFloat32Array()
var _lamps: Array[OmniLight3D] = []
var _lamp_energy: PackedFloat32Array = PackedFloat32Array()
var _lamp_phase: PackedFloat32Array = PackedFloat32Array()
var _lamp_out: PackedFloat32Array = PackedFloat32Array()
var _clock: float = 0.0
var _drift_left: float = 0.0
var _rand: RandomNumberGenerator = RandomNumberGenerator.new()


func _ready() -> void:
	_rand.seed = 0x5A17
	for node: Node in get_tree().get_nodes_in_group(TARP_GROUP):
		for child: Node in node.get_children():
			var tarp := child as Node3D
			if tarp == null:
				continue
			_tarps.append(tarp)
			_tarp_rest.append(tarp.rotation.z)
			_tarp_phase.append(_rand.randf() * TAU)
	for node: Node in get_tree().get_nodes_in_group(LIGHT_GROUP):
		for child: Node in node.get_children():
			var lamp := child as OmniLight3D
			if lamp == null:
				continue
			_lamps.append(lamp)
			_lamp_energy.append(lamp.light_energy)
			_lamp_phase.append(_rand.randf() * TAU)
			_lamp_out.append(0.0)
	_drift_left = 1.0 / maxf(drift_rate, 0.01)
	set_process(not _tarps.is_empty() or not _lamps.is_empty() or drift_rate > 0.0)


func _process(delta: float) -> void:
	_clock += delta
	_sway(delta)
	_flicker(delta)
	_drift(delta)


## A gust envelope over a per-tarp sine. Two sines and a multiply per tarp: the
## cloth reads as loose without anything being simulated.
func _sway(_delta: float) -> void:
	if _tarps.is_empty():
		return
	var gust: float = 1.0 - gust_depth * 0.5 * (1.0 - cos(_clock * TAU * gust_rate))
	for i: int in _tarps.size():
		var phase: float = _tarp_phase[i] + _clock * sway_rate
		var swing: float = sin(phase) * 0.75 + sin(phase * 1.73 + 1.1) * 0.25
		_tarps[i].rotation.z = _tarp_rest[i] + swing * sway_amplitude * gust


## Mains hum plus the occasional dropout. The hum is deterministic and cheap; the
## dropout is a coin flip per lamp per second, which is rare enough to read as a
## fault rather than as a strobe.
func _flicker(delta: float) -> void:
	for i: int in _lamps.size():
		var lamp: OmniLight3D = _lamps[i]
		var base: float = _lamp_energy[i]
		var out: float = _lamp_out[i]
		if out > 0.0:
			out = maxf(out - delta, 0.0)
			_lamp_out[i] = out
			lamp.light_energy = base * 0.12
			continue
		if _rand.randf() < dropout_rate * delta:
			_lamp_out[i] = dropout_seconds
			continue
		var phase: float = _lamp_phase[i] + _clock * flicker_rate
		lamp.light_energy = (
			base * (1.0 + sin(phase) * 0.6 * flicker_depth + sin(phase * 2.7) * 0.4 * flicker_depth)
		)


## Dust lifting off the berm crests. One puff at a time through the shared VFX
## hub, so it costs a pooled sprite and no allocation.
func _drift(delta: float) -> void:
	if drift_rate <= 0.0:
		return
	_drift_left -= delta
	if _drift_left > 0.0:
		return
	_drift_left = 1.0 / maxf(drift_rate, 0.01)
	var z: float = -_rand.randf() * drift_reach - 20.0
	var x: float = (46.0 if _rand.randf() < 0.5 else -46.0) + _rand.randfn(0.0, 2.2)
	VfxService.spawn_puff(Vector3(x, 7.2, z), 5, 2.4, 0.28, 4.5, true)
