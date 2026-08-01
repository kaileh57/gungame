class_name GunAudioBank
extends Resource
## Every baked weapon sound in one resource. Written by `res://tools/bake_gun_audio.gd`.
##
## The bank is indexed, not searched. A shot is `shots[band * 2 + payload]`, an
## impact is `impacts[kind]`, and everything else has its own slot — so playing a
## sound is an array read and a `play()`, with no string lookup and no allocation
## in the shot path.

## The four impact voices the reference distinguishes. Everything that is not a
## plate, a pane or a detonation shares the dull one, which is correct: dirt,
## paper and thin metal all sound like a thump and a tick.
enum Impact { DEFAULT, STEEL, GLASS, BOOM }

## Shot samples, `GunVoice.BAND_COUNT` energy bands, each in a solid and a payload
## variant. Index with `shot_index()`.
@export var shots: Array[AudioStreamWAV] = []
## Centre energy ratio each band was rendered at. Kept here rather than recomputed
## so a bank baked with a different band count still plays correctly.
@export var band_energies: PackedFloat32Array = PackedFloat32Array()

## Trigger on an empty chamber.
@export var dry: AudioStreamWAV = null
## The action refusing to move.
@export var jam: AudioStreamWAV = null
## A diegetic control being worked. Pitched from `ui_reference_hz`.
@export var ui: AudioStreamWAV = null
## A footfall.
@export var step: AudioStreamWAV = null
## One magazine, shell or cylinder movement. Pitched from `clack_reference_hz`.
@export var clack: AudioStreamWAV = null
## The action working behind the shot. Held out of the shot samples because its
## frequency comes from cyclic rate, which is free of the energy the bands index.
@export var action: AudioStreamWAV = null

## Impact voices, indexed by `GunAudioBank.Impact`.
@export var impacts: Array[AudioStreamWAV] = []

## Frequencies the pitchable samples were rendered at, so playback can bend them.
@export var ui_reference_hz: float = 900.0
@export var clack_reference_hz: float = 1000.0
@export var action_reference_hz: float = 1400.0
@export var impact_reference_hz: float = 1100.0
## Amplitude the clack was rendered at. The reference gives each clack in a reload
## its own peak, and playback makes up the difference in decibels.
@export var clack_reference_peak: float = 0.2


## Sample index for an energy band and payload flag.
static func shot_index(band: int, payload: bool) -> int:
	return band * 2 + (1 if payload else 0)


## The impact voice a `VFXSurface.Kind` speaks with.
static func impact_of_surface(surface: int) -> Impact:
	match surface:
		VFXSurface.Kind.METAL, VFXSurface.Kind.TIN, VFXSurface.Kind.PLATE, VFXSurface.Kind.BARREL:
			return Impact.STEEL
		VFXSurface.Kind.GLASS:
			return Impact.GLASS
		_:
			return Impact.DEFAULT


## True when the bank holds everything `GunAudio` will ask it for.
func is_complete() -> bool:
	if shots.size() != GunVoice.BAND_COUNT * 2 or band_energies.size() != GunVoice.BAND_COUNT:
		return false
	if impacts.size() != Impact.size():
		return false
	for s: AudioStreamWAV in shots:
		if s == null:
			return false
	for s: AudioStreamWAV in impacts:
		if s == null:
			return false
	return (
		dry != null
		and jam != null
		and ui != null
		and step != null
		and clack != null
		and action != null
	)


## The shot sample for `voice`, or null if the bank is short.
func shot_for(voice: GunVoice) -> AudioStreamWAV:
	var i: int = shot_index(voice.band(), voice.payload)
	return null if i < 0 or i >= shots.size() else shots[i]


func impact_sample(kind: Impact) -> AudioStreamWAV:
	var i: int = int(kind)
	return null if i < 0 or i >= impacts.size() else impacts[i]
