class_name GunVoice
extends RefCounted
## The voice of one weapon, derived from the round it throws. Range spec 19.
##
## Nothing in this game has a gun sound authored for it, because nothing in this
## game has an authored gun. A weapon is five scavenged parts and a cartridge that
## fell out of their geometry, so its voice falls out of the same number: muzzle
## energy sets every band in the shot, and cyclic rate sets the clatter of the
## action behind it. A 9 mm machine pistol and a welded anti-materiel single-shot
## are the same nine layers with different numbers in them, which is why they stay
## recognisably the same family while sounding nothing alike.
##
## This class is pure arithmetic on a `GunSpec`. It reads no node and no clock, so
## `res://tools/bake_gun_audio.gd` uses it to decide what to synthesise and
## `GunAudio` uses it at play time to decide which baked band to reach for and how
## far to bend it. One derivation, two consumers, no drift between them.

## Energy, in joules, that maps to `e` of 1. The reference's divisor.
const ENERGY_REFERENCE: float = 2500.0
## `e` is clamped to this range before anything is derived from it. A derringer and
## a shoulder-fired cannon are 33x apart in energy and that is the whole span.
const E_MIN: float = 0.12
const E_MAX: float = 4.0
## Baked energy bands. Eight is enough that the pitch bend inside a band stays
## under a semitone, and few enough that the whole bank is under five megabytes.
const BAND_COUNT: int = 8
## How the residual energy inside a band is spent as playback pitch. The three
## voice bands scale as `e^-0.42`, `e^-0.26` and `e^-0.22`; one playback rate
## cannot honour all three, so this is their weighted middle.
const BAND_PITCH_EXPONENT: float = 0.30

## Sharp transient band — the crack that reaches the far end of the range first.
var crack_hz: float = 1200.0
## Chest band. This is the one that makes a big round feel big indoors.
var body_hz: float = 90.0
## Sub band, felt more than heard.
var sub_hz: float = 50.0
## Reverberant tail length, seconds.
var tail: float = 0.6
## Master level of the shot, 0-1.
var level: float = 0.4
## Centre of the action clatter, Hz. The only term the cartridge does not set.
var mech_hz: float = 1400.0
## True for a shot load: adds the payload hiss layer.
var payload: bool = false
## The clamped energy ratio every band above came from. Also the bank index key.
var big: float = 1.0


## Derive the voice of `spec`. A null spec gives the middle of the range, which is
## what a bench with nothing on it should make when you dry-fire it.
static func from_spec(spec: GunSpec) -> GunVoice:
	if spec == null:
		return from_energy(ENERGY_REFERENCE, 600.0, false)
	return from_energy(float(spec.muzzle_energy), float(spec.cyclic), spec.pellets > 1)


## The derivation proper — `voice(st)` in the reference, argument for argument.
static func from_energy(energy: float, cyclic: float, has_payload: bool) -> GunVoice:
	var v := GunVoice.new()
	var e: float = clampf(energy / ENERGY_REFERENCE, E_MIN, E_MAX)
	v.big = e
	v.crack_hz = clampf(2400.0 / pow(e, 0.42), 260.0, 3200.0)
	v.body_hz = clampf(112.0 / pow(e, 0.26), 28.0, 150.0)
	v.sub_hz = clampf(62.0 / pow(e, 0.22), 20.0, 80.0)
	v.tail = clampf(0.34 + 0.85 * log(1.0 + e * 3.0) / log(10.0), 0.28, 2.1)
	v.level = clampf(0.26 + 0.34 * log(1.0 + e * 4.0) / log(10.0), 0.22, 0.92)
	v.mech_hz = clampf(1200.0 + cyclic * 1.2, 900.0, 3400.0)
	v.payload = has_payload
	return v


## Centre energy ratio of baked band `index`. The bands are geometric in `e`
## because every frequency in the voice is a power of `e`, so equal ratios are
## equal pitch steps and no band is worse served than any other.
static func band_energy(index: int) -> float:
	var t: float = float(clampi(index, 0, BAND_COUNT - 1)) / float(BAND_COUNT - 1)
	return E_MIN * pow(E_MAX / E_MIN, t)


## Nearest baked band to `e`, in the same geometric measure.
static func band_of(e: float) -> int:
	var k: float = clampf(e, E_MIN, E_MAX)
	var t: float = log(k / E_MIN) / log(E_MAX / E_MIN)
	return clampi(roundi(t * float(BAND_COUNT - 1)), 0, BAND_COUNT - 1)


## The baked band this voice plays out of.
func band() -> int:
	return band_of(big)


## Playback pitch scale against the band that will be played. Above 1 the round is
## smaller than the band's centre and everything in the sample rises.
func pitch_scale() -> float:
	var centre: float = band_energy(band_of(big))
	return pow(centre / big, BAND_PITCH_EXPONENT)


## Level in decibels, referenced to the loudest voice in the set so the biggest
## round in the game plays at unity and everything else sits under it.
func volume_db() -> float:
	return linear_to_db(clampf(level / 0.92, 0.05, 1.0))
