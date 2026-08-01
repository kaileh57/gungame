@tool
extends SceneTree
## Weapon-voice bake: range spec 19's WebAudio graph rendered to a sample bank.
##
## Run headless:
##   godot --headless --path <project> --script res://tools/bake_gun_audio.gd
##
## Writes `res://data/audio/gun_audio_bank.tres` and the samples beside it, plus
## `res://default_bus_layout.tres` — the compressor, the berm slapback and the
## room the reference put after its oscillators, which Godot can do on a bus and
## therefore should, because a room printed into a sample cannot follow the gun.
##
## Every number below is quoted from the spec at the point it is used. Where the
## spec leaves an attack unstated the value is stated here as a constant with the
## reason, rather than being buried as a literal in the fifteenth argument of a
## call nobody will ever read.

const SYNTH := preload("res://tools/gun_audio/gun_synth.gd")

const OUT_DIR := "res://data/audio"
const BANK_PATH := "res://data/audio/gun_audio_bank.tres"
const BUS_LAYOUT_PATH := "res://default_bus_layout.tres"
const REPORT_PATH := "res://data/audio_bake_report.txt"

## Rendering seed. The noise in the bank is deterministic, so a re-bake produces
## byte-identical samples and the diff of a tuning change is only the tuning.
const SEED := 0x5CA7A1D0

## Attacks the spec does not give. A noise burst wants the shortest attack that is
## not a click at 44.1 kHz; a tone wants long enough not to thump on its own onset.
const NOISE_ATTACK := 0.001
const TONE_ATTACK := 0.004

## The action clatter and the reload clack are baked once and pitched at play time.
const ACTION_HZ := 1400.0
const CLACK_HZ := 1000.0
const UI_HZ := 900.0
const IMPACT_STEEL_HZ := 1100.0
## Clack amplitude in the bank. The loudest clack the reference asks for is 0.26,
## so rendering at 0.2 leaves every one of them within a few decibels of the bake
## and none of them has to be pushed hard enough to change shape.
const CLACK_PEAK := 0.2
## `lvl` at the top of its range. The clatter is specified as `lvl * 0.26` and is
## played back scaled by `lvl / LEVEL_MAX`, so it is rendered pre-divided.
const LEVEL_MAX := 0.92

## Bus. Compressor from the spec's `DynamicsCompressor`; the convolver becomes the
## slapback delay and the tail, per the spec's own PORT note.
const COMP_THRESHOLD_DB := -9.0
const COMP_RATIO := 3.4
const COMP_ATTACK_MS := 4.0
const COMP_RELEASE_MS := 260.0
const SLAPBACK_MS := 85.0
const SLAPBACK_LEVEL_DB := -9.1
const TAIL_SECONDS := 2.6

var _synth: RefCounted
var _lines: PackedStringArray = PackedStringArray()
var _bytes: int = 0


func _init() -> void:
	var started: int = Time.get_ticks_msec()
	_synth = SYNTH.new(SEED)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))

	var bank := GunAudioBank.new()
	bank.band_energies = PackedFloat32Array()
	bank.shots.resize(GunVoice.BAND_COUNT * 2)
	bank.impacts.resize(GunAudioBank.Impact.size())
	bank.ui_reference_hz = UI_HZ
	bank.clack_reference_hz = CLACK_HZ
	bank.clack_reference_peak = CLACK_PEAK
	bank.action_reference_hz = ACTION_HZ
	bank.impact_reference_hz = IMPACT_STEEL_HZ

	for band: int in GunVoice.BAND_COUNT:
		var e: float = GunVoice.band_energy(band)
		bank.band_energies.append(e)
		var voice: GunVoice = GunVoice.from_energy(e * GunVoice.ENERGY_REFERENCE, 0.0, false)
		for payload: int in 2:
			var name := "shot_b%d%s" % [band, "_payload" if payload == 1 else ""]
			var wav: AudioStreamWAV = _shot(voice, payload == 1)
			bank.shots[GunAudioBank.shot_index(band, payload == 1)] = _save(wav, name)
		_note(
			(
				"band %d  e %.3f  crack %.0f  body %.1f  sub %.1f  tail %.2f  lvl %.3f"
				% [band, e, voice.crack_hz, voice.body_hz, voice.sub_hz, voice.tail, voice.level]
			)
		)

	bank.action = _save(_action(), "action")
	bank.dry = _save(_dry(), "dry")
	bank.jam = _save(_jam(), "jam")
	bank.ui = _save(_ui(), "ui")
	bank.step = _save(_step(), "step")
	bank.clack = _save(_clack(), "clack")
	bank.impacts[GunAudioBank.Impact.DEFAULT] = _save(_impact_default(), "impact_default")
	bank.impacts[GunAudioBank.Impact.STEEL] = _save(_impact_steel(), "impact_steel")
	bank.impacts[GunAudioBank.Impact.GLASS] = _save(_impact_glass(), "impact_glass")
	bank.impacts[GunAudioBank.Impact.BOOM] = _save(_impact_boom(), "impact_boom")

	var ok: bool = bank.is_complete()
	var err: int = ResourceSaver.save(bank, BANK_PATH)
	_bake_bus_layout()
	_note("")
	_note("bank complete          %s" % ("yes" if ok else "NO"))
	_note("samples                %d" % (bank.shots.size() + bank.impacts.size() + 6))
	_note("sample bytes           %d" % _bytes)
	_note("bank save              %s" % ("ok" if err == OK else error_string(err)))
	_note("bus layout             %s" % BUS_LAYOUT_PATH)
	_note("bake time              %d ms" % (Time.get_ticks_msec() - started))
	var text: String = "\n".join(_lines) + "\n"
	var f := FileAccess.open(REPORT_PATH, FileAccess.WRITE)
	if f != null:
		f.store_string(text)
		f.close()
	print(text)
	quit(0 if ok and err == OK else 1)


## The nine shot layers, in the spec's own order. `L` and `B` are the reference's.
func _shot(voice: GunVoice, payload: bool) -> AudioStreamWAV:
	var l: float = voice.level
	var b: float = voice.big
	var sub_decay: float = 0.22 + 0.14 * b
	var length: float = 0.055 + voice.tail * 1.4 + 0.02 + 0.05
	var buf: PackedFloat32Array = _synth.buffer(length)
	# punch — the thump that arrives before anything is recognisable as a note.
	_synth.layer(
		buf,
		0.0,
		SYNTH.Wave.NOISE,
		0.0,
		0.0,
		SYNTH.lowpass(voice.body_hz * 2.4, 0.6),
		l * 1.75,
		0.0009,
		0.085
	)
	# sub — swept down hard, which is what a big round does to a room.
	_synth.layer(
		buf,
		0.0,
		SYNTH.Wave.SINE,
		voice.sub_hz * 2.4,
		voice.sub_hz * 0.6,
		null,
		l * 1.30,
		0.005,
		sub_decay
	)
	# body
	_synth.layer(
		buf,
		0.0,
		SYNTH.Wave.TRIANGLE,
		voice.body_hz * 2.0,
		voice.body_hz * 0.5,
		null,
		l * 1.05,
		0.004,
		0.15
	)
	# crack, and the air behind it
	_synth.layer(
		buf,
		0.0,
		SYNTH.Wave.NOISE,
		0.0,
		0.0,
		SYNTH.bandpass(voice.crack_hz, 0.9),
		l * 0.95,
		0.0012,
		0.075
	)
	_synth.layer(
		buf,
		0.004,
		SYNTH.Wave.NOISE,
		0.0,
		0.0,
		SYNTH.highpass(voice.crack_hz * 2.2, 0.4),
		l * 0.30,
		0.0008,
		0.028
	)
	if payload:
		# The hiss of a column of shot leaving. Only a payload gun has it.
		_synth.layer(
			buf, 0.0, SYNTH.Wave.NOISE, 0.0, 0.0, SYNTH.bandpass(2100.0, 0.5), l * 0.55, 0.004, 0.20
		)
	# The two echoes. Rendered dry; the bus supplies the room.
	_synth.layer(
		buf,
		0.012,
		SYNTH.Wave.NOISE,
		0.0,
		0.0,
		SYNTH.lowpass(1200.0, 0.7),
		l * 1.15,
		0.008,
		voice.tail
	)
	_synth.layer(
		buf,
		0.055,
		SYNTH.Wave.NOISE,
		0.0,
		0.0,
		SYNTH.lowpass(520.0, 0.6),
		l * 0.55 * b,
		0.02,
		voice.tail * 1.4
	)
	return _synth.finish(buf)


func _action() -> AudioStreamWAV:
	var buf: PackedFloat32Array = _synth.buffer(0.06)
	_synth.layer(
		buf,
		0.0,
		SYNTH.Wave.NOISE,
		0.0,
		0.0,
		SYNTH.bandpass(ACTION_HZ, 2.2),
		0.26 * LEVEL_MAX,
		0.001,
		0.034
	)
	return _synth.finish(buf)


func _dry() -> AudioStreamWAV:
	var buf: PackedFloat32Array = _synth.buffer(0.04)
	_synth.layer(
		buf, 0.0, SYNTH.Wave.NOISE, 0.0, 0.0, SYNTH.bandpass(3000.0, 5.0), 0.16, 0.0008, 0.020
	)
	return _synth.finish(buf)


func _jam() -> AudioStreamWAV:
	var buf: PackedFloat32Array = _synth.buffer(0.14)
	_synth.layer(
		buf, 0.0, SYNTH.Wave.NOISE, 0.0, 0.0, SYNTH.bandpass(420.0, 6.0), 0.28, NOISE_ATTACK, 0.11
	)
	return _synth.finish(buf)


func _ui() -> AudioStreamWAV:
	var buf: PackedFloat32Array = _synth.buffer(0.07)
	_synth.layer(
		buf, 0.0, SYNTH.Wave.NOISE, 0.0, 0.0, SYNTH.bandpass(UI_HZ, 4.0), 0.10, NOISE_ATTACK, 0.05
	)
	return _synth.finish(buf)


func _step() -> AudioStreamWAV:
	var buf: PackedFloat32Array = _synth.buffer(0.1)
	_synth.layer(
		buf, 0.0, SYNTH.Wave.NOISE, 0.0, 0.0, SYNTH.lowpass(340.0, 1.0), 0.055, NOISE_ATTACK, 0.075
	)
	return _synth.finish(buf)


## `clack(dt, freq, peak)` — a ring and a knock together. The ring carries the
## pitch, so it is the one playback bends.
func _clack() -> AudioStreamWAV:
	var buf: PackedFloat32Array = _synth.buffer(0.1)
	_synth.layer(
		buf,
		0.0,
		SYNTH.Wave.NOISE,
		0.0,
		0.0,
		SYNTH.bandpass(CLACK_HZ, 2.8),
		CLACK_PEAK * 1.3,
		NOISE_ATTACK,
		0.055
	)
	_synth.layer(
		buf,
		0.0,
		SYNTH.Wave.NOISE,
		0.0,
		0.0,
		SYNTH.lowpass(260.0, 1.0),
		CLACK_PEAK * 0.9,
		NOISE_ATTACK,
		0.07
	)
	return _synth.finish(buf)


func _impact_default() -> AudioStreamWAV:
	var buf: PackedFloat32Array = _synth.buffer(0.16)
	_synth.layer(
		buf, 0.0, SYNTH.Wave.NOISE, 0.0, 0.0, SYNTH.lowpass(520.0, 1.0), 0.20, NOISE_ATTACK, 0.11
	)
	_synth.layer(
		buf, 0.0, SYNTH.Wave.NOISE, 0.0, 0.0, SYNTH.bandpass(1700.0, 1.0), 0.07, NOISE_ATTACK, 0.05
	)
	return _synth.finish(buf)


## Steel rings, and the ring is the whole cue on a range. Rendered at the 1 m plate
## frequency; `GunAudio` bends it by the plate it actually hit.
func _impact_steel() -> AudioStreamWAV:
	var f: float = IMPACT_STEEL_HZ
	var buf: PackedFloat32Array = _synth.buffer(0.9)
	_synth.layer(
		buf, 0.0, SYNTH.Wave.NOISE, 0.0, 0.0, SYNTH.lowpass(180.0, 1.0), 0.26, NOISE_ATTACK, 0.10
	)
	_synth.layer(buf, 0.0, SYNTH.Wave.TRIANGLE, f, f, null, 0.30, TONE_ATTACK, 0.70)
	_synth.layer(buf, 0.0, SYNTH.Wave.SINE, f * 2.71, f * 2.71, null, 0.13, TONE_ATTACK, 0.34)
	_synth.layer(
		buf, 0.0, SYNTH.Wave.NOISE, 0.0, 0.0, SYNTH.highpass(3600.0, 1.0), 0.13, NOISE_ATTACK, 0.05
	)
	_synth.layer(
		buf, 0.0, SYNTH.Wave.NOISE, 0.0, 0.0, SYNTH.bandpass(f, 1.2), 0.16, NOISE_ATTACK, 0.75
	)
	return _synth.finish(buf)


## Five bursts a fifth of a frame apart. Deterministic, but the frequencies are
## drawn per burst, which is why a pane never sounds like one note.
func _impact_glass() -> AudioStreamWAV:
	var buf: PackedFloat32Array = _synth.buffer(0.2)
	for i: int in 5:
		var f: float = 2600.0 + _synth.rand() * 3200.0
		_synth.layer(
			buf,
			float(i) * 0.012,
			SYNTH.Wave.NOISE,
			0.0,
			0.0,
			SYNTH.bandpass(f, 6.0),
			0.13,
			NOISE_ATTACK,
			0.09
		)
	return _synth.finish(buf)


func _impact_boom() -> AudioStreamWAV:
	var buf: PackedFloat32Array = _synth.buffer(2.5)
	_synth.layer(buf, 0.0, SYNTH.Wave.SINE, 150.0, 22.0, null, 1.25, TONE_ATTACK, 1.05)
	_synth.layer(buf, 0.0, SYNTH.Wave.SINE, 70.0, 18.0, null, 0.95, TONE_ATTACK, 1.5)
	_synth.layer(
		buf, 0.0, SYNTH.Wave.NOISE, 0.0, 0.0, SYNTH.lowpass(520.0, 1.0), 1.0, NOISE_ATTACK, 0.62
	)
	_synth.layer(
		buf, 0.0, SYNTH.Wave.NOISE, 0.0, 0.0, SYNTH.bandpass(1800.0, 1.0), 0.42, NOISE_ATTACK, 0.20
	)
	_synth.layer(buf, 0.02, SYNTH.Wave.NOISE, 0.0, 0.0, SYNTH.lowpass(900.0, 1.0), 0.85, 0.02, 2.3)
	return _synth.finish(buf)


## The bus the reference's master chain becomes. Written to the project root,
## which is where Godot looks for a bus layout without being told.
func _bake_bus_layout() -> void:
	var master: int = AudioServer.get_bus_index(&"Master")
	var index: int = AudioServer.get_bus_index(GunAudio.BUS)
	if index < 0:
		index = AudioServer.bus_count
		AudioServer.add_bus(index)
		AudioServer.set_bus_name(index, String(GunAudio.BUS))
	AudioServer.set_bus_send(index, AudioServer.get_bus_name(maxi(master, 0)))
	for i: int in range(AudioServer.get_bus_effect_count(index) - 1, -1, -1):
		AudioServer.remove_bus_effect(index, i)

	var comp := AudioEffectCompressor.new()
	comp.threshold = COMP_THRESHOLD_DB
	comp.ratio = COMP_RATIO
	comp.attack_us = COMP_ATTACK_MS * 1000.0
	comp.release_ms = COMP_RELEASE_MS
	AudioServer.add_bus_effect(index, comp)

	# The berm. A range is a wall of earth at a known distance and it answers every
	# shot exactly once, which is a delay tap and not a reverb.
	var slap := AudioEffectDelay.new()
	slap.dry = 1.0
	slap.tap1_active = true
	slap.tap1_delay_ms = SLAPBACK_MS
	slap.tap1_level_db = SLAPBACK_LEVEL_DB
	slap.tap2_active = false
	slap.feedback_active = false
	AudioServer.add_bus_effect(index, slap)

	var room := AudioEffectReverb.new()
	room.room_size = clampf(TAIL_SECONDS / 3.0, 0.0, 1.0)
	room.damping = 0.42
	room.spread = 0.6
	room.predelay_msec = 12.0
	room.wet = 0.22
	room.dry = 1.0
	AudioServer.add_bus_effect(index, room)

	ResourceSaver.save(AudioServer.generate_bus_layout(), BUS_LAYOUT_PATH)


func _save(wav: AudioStreamWAV, sample_name: String) -> AudioStreamWAV:
	var path := "%s/%s.res" % [OUT_DIR, sample_name]
	var err: int = ResourceSaver.save(wav, path)
	if err != OK:
		_note("SAVE FAILED %s: %s" % [path, error_string(err)])
		return null
	_bytes += wav.data.size()
	return ResourceLoader.load(path) as AudioStreamWAV


func _note(line: String) -> void:
	_lines.append(line)
