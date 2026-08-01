extends RefCounted
## Offline synthesiser: the reference's WebAudio graph, rendered to samples.
##
## Range spec 19 describes the weapon voice as a live graph — oscillators and noise
## through biquads through exponential gain envelopes, summed into a compressor, a
## tanh waveshaper and a convolution reverb. Godot has no such graph, and building
## one per shot at runtime would violate the bake rule anyway, so the spec's own
## PORT note is taken: every layer is rendered here, once, into `AudioStreamWAV`.
##
## Two deliberate departures from the reference topology, both forced and both
## documented at the point of use:
##   * The compressor stays on the bus rather than being printed into the samples,
##     because a compressor is a property of the sum and printing it per-sample
##     would compress each shot against itself instead of against the mix.
##   * The convolver becomes a delay plus a reverb on that same bus, exactly as
##     the spec's PORT note prescribes. The nine dry layers are printed; the two
##     echo layers are printed with their filters but no reverb, and the bus adds
##     the room.
##
## Bake-time only. Nothing here ships, nothing here runs in a frame.

## Source waveforms. Noise covers every layer the reference drives from its
## white-noise buffer; the two tones are its `OscillatorNode` types.
enum Wave { SINE, TRIANGLE, NOISE }

## Everything is rendered at CD rate and shipped as 16-bit mono. A gun sample is
## broadband transient and there is nothing above 20 kHz in it worth the bytes.
const SAMPLE_RATE: int = 44100
## Floor of every exponential ramp. WebAudio cannot ramp to or from zero and
## neither can this; 0.0001 is the reference's own floor, -80 dB.
const ENVELOPE_FLOOR: float = 0.0001
## Master waveshaper: `tanh(x*1.9)/tanh(1.9)`, then the reference's 1.15 gain.
const SHAPER_DRIVE: float = 1.9
const MASTER_GAIN: float = 1.15
## Uniform headroom trim. The shaper saturates at `1/tanh(1.9)`, which times the
## master gain overshoots full scale by 21 %. Backing every sample off by the same
## fixed amount keeps them all clear of the rail without flattening the level
## differences between them — those differences are the whole point of `lvl`.
const HEADROOM: float = 1.0 / 1.21

## Tail cut. Rendering an envelope all the way to the floor wastes a second of
## silence per sample; below this the layer is inaudible under anything.
const TAIL_FLOOR: float = 0.0006

var _rand: XorShift32


func _init(seed_value: int) -> void:
	_rand = XorShift32.new(seed_value if seed_value != 0 else 1)


## A silent mono buffer long enough to hold `seconds`.
func buffer(seconds: float) -> PackedFloat32Array:
	var buf := PackedFloat32Array()
	buf.resize(maxi(int(ceilf(seconds * float(SAMPLE_RATE))), 1))
	return buf


## Sum one layer into `buf`.
##
## `start` is the layer's onset in seconds, `f0`/`f1` the oscillator's exponential
## frequency sweep across the whole envelope (equal values hold it), `filter` an
## optional biquad the source runs through before the envelope, and `peak`/`attack`
## /`decay` the reference's three envelope numbers. Source, then filter, then gain,
## which is WebAudio's own node order and matters: filtering after the envelope
## would smear the attack.
func layer(
	buf: PackedFloat32Array,
	start: float,
	wave: Wave,
	f0: float,
	f1: float,
	filter: Biquad,
	peak: float,
	attack: float,
	decay: float
) -> void:
	var att: int = maxi(int(attack * float(SAMPLE_RATE)), 1)
	var dec: int = maxi(int(decay * float(SAMPLE_RATE)), 1)
	var first: int = maxi(int(start * float(SAMPLE_RATE)), 0)
	var total: int = att + dec
	var last: int = mini(first + total, buf.size())
	if last <= first or peak <= 0.0:
		return
	# Per-sample multipliers instead of a pow() per sample: an exponential ramp is
	# a constant ratio per step by definition.
	var up: float = pow(peak / ENVELOPE_FLOOR, 1.0 / float(att))
	var down: float = pow(ENVELOPE_FLOOR / peak, 1.0 / float(dec))
	var glide: float = 1.0 if f0 <= 0.0 or f1 <= 0.0 else pow(f1 / f0, 1.0 / float(total))
	var env: float = ENVELOPE_FLOOR
	var freq: float = maxf(f0, 1.0)
	var phase: float = 0.0
	var step: float = 1.0 / float(SAMPLE_RATE)
	for i: int in range(first, last):
		var n: int = i - first
		env = env * (up if n < att else down)
		if n > att and env < TAIL_FLOOR:
			return
		var raw: float = 0.0
		match wave:
			Wave.NOISE:
				raw = _rand.next() * 2.0 - 1.0
			Wave.SINE:
				raw = sin(phase * TAU)
			Wave.TRIANGLE:
				# Straight from the phase rather than from a sine, because the odd
				# harmonics are what give the body layer its edge.
				raw = 4.0 * absf(phase - floorf(phase + 0.5)) - 1.0
		phase = fposmod(phase + freq * step, 1.0)
		freq *= glide
		if filter != null:
			raw = filter.process(raw)
		buf[i] += raw * env


## Print the master chain into `buf` and hand back a shippable stream. The
## compressor is not here — see the class note.
func finish(buf: PackedFloat32Array) -> AudioStreamWAV:
	var shaper: float = tanh(SHAPER_DRIVE)
	var data := PackedByteArray()
	data.resize(buf.size() * 2)
	for i: int in buf.size():
		var y: float = tanh(buf[i] * SHAPER_DRIVE) / shaper * MASTER_GAIN * HEADROOM
		var q: int = clampi(roundi(clampf(y, -1.0, 1.0) * 32767.0), -32768, 32767)
		data.encode_s16(i * 2, q)
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = SAMPLE_RATE
	stream.stereo = false
	stream.data = data
	return stream


## Uniform noise in `[0,1)`, for the reference's `rand` terms inside a sequence.
func rand() -> float:
	return _rand.next()


static func lowpass(hz: float, q: float) -> Biquad:
	return Biquad.new(Biquad.Kind.LOWPASS, hz, q)


static func highpass(hz: float, q: float) -> Biquad:
	return Biquad.new(Biquad.Kind.HIGHPASS, hz, q)


static func bandpass(hz: float, q: float) -> Biquad:
	return Biquad.new(Biquad.Kind.BANDPASS, hz, q)


## One RBJ biquad in transposed direct form II — the same filter shapes WebAudio's
## `BiquadFilterNode` uses, so a frequency and a Q out of the spec land here
## unchanged. Bandpass is the constant-0-dB-peak form, which is WebAudio's.
class Biquad:
	extends RefCounted

	enum Kind { LOWPASS, HIGHPASS, BANDPASS }

	var _b0: float = 1.0
	var _b1: float = 0.0
	var _b2: float = 0.0
	var _a1: float = 0.0
	var _a2: float = 0.0
	var _z1: float = 0.0
	var _z2: float = 0.0

	func _init(kind: Kind, hz: float, q: float) -> void:
		var f: float = clampf(hz, 10.0, float(SAMPLE_RATE) * 0.45)
		var quality: float = maxf(q, 0.05)
		var w: float = TAU * f / float(SAMPLE_RATE)
		var cw: float = cos(w)
		var sw: float = sin(w)
		var alpha: float = sw / (2.0 * quality)
		var a0: float = 1.0 + alpha
		match kind:
			Kind.LOWPASS:
				_b0 = (1.0 - cw) * 0.5
				_b1 = 1.0 - cw
				_b2 = _b0
			Kind.HIGHPASS:
				_b0 = (1.0 + cw) * 0.5
				_b1 = -(1.0 + cw)
				_b2 = _b0
			Kind.BANDPASS:
				_b0 = alpha
				_b1 = 0.0
				_b2 = -alpha
		_b0 /= a0
		_b1 /= a0
		_b2 /= a0
		_a1 = (-2.0 * cw) / a0
		_a2 = (1.0 - alpha) / a0

	func process(x: float) -> float:
		var y: float = _b0 * x + _z1
		_z1 = _b1 * x - _a1 * y + _z2
		_z2 = _b2 * x - _a2 * y
		return y
