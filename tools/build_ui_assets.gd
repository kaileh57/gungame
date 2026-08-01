@tool
extends SceneTree
## UI bake: fonts, theme, materials, the grime texture, and every UI scene the
## runtime loads.
##
## Nothing under res://ui/ builds its own geometry or textures — the scripts there
## are behaviour only, and they assume the artifacts this script writes already
## exist. Run it once, commit the output, ship the output.
##
##   godot --headless --path <project> --script res://tools/build_ui_assets.gd
##
## Writes:
##   res://data/ui/font_mono.tres      fixed pitch, for numbers that must not jitter
##   res://data/ui/font_display.tres   condensed, for headings and stencilling
##   res://data/ui/debug_lines.tres    UiDebugDraw's unshaded vertex-colour material
##   res://data/ui/readout_grime.res   tileable grime for the CRT/placard shader
##   res://data/ui/lamp_off.tres       button lamp, dark
##   res://data/ui/lamp_on.tres        button lamp, lit
##   res://data/ui/control_click.res   the clack a control makes when it actuates
##   res://data/ui/control_deny.res    the dead knock it makes when it refuses
##   res://ui/diegetic/diegetic_{button,lever,dial,slider,readout}.tscn
##   res://ui/hud/combat_hud.tscn
##   res://data/ui/ui_assets_report.txt
##
## The two fonts are shared with the screen-menu bake, so they are adopted if they
## are already on disk and only authored when they are not — whichever builder runs
## first writes them, and neither clobbers the other. The Theme belongs to the menu
## bake outright; nothing here writes it.
##
## Every solid below is built from overlapping primitives — a cap sunk into its
## housing, a frame lapping over the screen it surrounds — because a butted joint
## is a visible seam the first time the camera is not square to it.

const OUT_DIR := "res://data/ui"
const REPORT_PATH := "res://data/ui/ui_assets_report.txt"

const FONT_MONO_PATH := "res://data/ui/font_mono.tres"
const FONT_DISPLAY_PATH := "res://data/ui/font_display.tres"
const DEBUG_LINES_PATH := "res://data/ui/debug_lines.tres"
const GRIME_PATH := "res://data/ui/readout_grime.res"
const LAMP_OFF_PATH := "res://data/ui/lamp_off.tres"
const LAMP_ON_PATH := "res://data/ui/lamp_on.tres"

const BUTTON_SCENE := "res://ui/diegetic/diegetic_button.tscn"
const LEVER_SCENE := "res://ui/diegetic/diegetic_lever.tscn"
const DIAL_SCENE := "res://ui/diegetic/diegetic_dial.tscn"
const SLIDER_SCENE := "res://ui/diegetic/diegetic_slider.tscn"
const READOUT_SCENE := "res://ui/diegetic/diegetic_readout.tscn"
const COMBAT_HUD_SCENE := "res://ui/hud/combat_hud.tscn"

const SCRAP_STEEL := "res://art/materials/scrap_steel.tres"
const SCRAP_POLYMER := "res://art/materials/scrap_polymer.tres"
const GUN_STEEL := "res://art/materials/gun_steel.tres"
const SCRAP_SHADER := "res://art/shaders/scrap_surface.gdshader"
const READOUT_SHADER := "res://ui/diegetic/readout.gdshader"
const VIGNETTE_SHADER := "res://ui/hud/vignette.gdshader"

## Fixed-pitch candidates, best first. `allow_system_fallback` covers the case
## where a machine has none of them; the UI degrades to the engine face rather
## than to nothing.
const MONO_FACES: PackedStringArray = [
	"Consolas", "DejaVu Sans Mono", "Liberation Mono", "Courier New", "monospace"
]
## Condensed grotesques. A scav stencil is narrow and hard-edged.
const DISPLAY_FACES: PackedStringArray = [
	"Bahnschrift", "Oswald", "Arial Narrow", "Liberation Sans Narrow", "DejaVu Sans", "sans-serif"
]

## Grime tile. 256 is the smallest size at which the fine grit does not read as a
## regular pattern at the 3x scale the shader samples it at.
const GRIME_SIZE := 256
## Lattice period of the coarsest octave. The tile wraps because every octave's
## period divides GRIME_SIZE.
const GRIME_BASE_PERIOD := 8
const GRIME_OCTAVES := 5

## World size of the readout screen, and the render target that fills it. Same
## aspect to a hundredth, or the text stretches.
const SCREEN_W := 0.52
const SCREEN_H := 0.325
const SCREEN_PX := Vector2i(512, 320)

## Label3D metres per font pixel. 48 pt at this scale is a ~7 cm cap height,
## which is what a stencilled placard reads like from across a room.
const LABEL_PIXEL_SIZE := 0.0014
const LABEL_FONT_SIZE := 48

## Sample rate of the two control sounds. Both are short percussive hits, so the
## rate buys nothing above this and the whole pair is under 30 kB at it.
const SOUND_RATE := 44100
## Struck plate: frequency in Hz, amplitude, decay time constant in seconds. The
## ratios are deliberately inharmonic — 1 : 1.63 : 2.66 : 4.06 — because a bolted
## steel plate has no harmonic series and anything that does reads as a chime.
const CLICK_PARTIALS: Array[Vector3] = [
	Vector3(318.0, 1.00, 0.075),
	Vector3(517.0, 0.62, 0.062),
	Vector3(846.0, 0.34, 0.045),
	Vector3(1291.0, 0.18, 0.031),
	Vector3(2130.0, 0.09, 0.019),
]
const CLICK_SECONDS := 0.14
## The refusal is the same plate hit through a wedge: an octave and a half down,
## damped twice as hard, and struck twice so it reads as "no" and not as "yes".
const DENY_PARTIALS: Array[Vector3] = [
	Vector3(96.0, 1.00, 0.055),
	Vector3(143.0, 0.55, 0.040),
	Vector3(211.0, 0.22, 0.026),
]
const DENY_SECONDS := 0.22
## Seconds between the two knocks of the refusal.
const DENY_REPEAT := 0.085
## Corner of the one-pole lowpass on the strike transient, in Hz. Raw white noise
## on a metal hit is a hiss; this leaves the grit and drops the fizz.
const NOISE_CORNER := 4000.0
## Peak sample after normalisation. Short of full scale so a control firing on the
## same frame as a gunshot cannot clip the bus.
const SOUND_PEAK := 0.94
## The noise in a strike is dither, not a signature, but it still comes off the
## project's one RNG so two bakes produce byte-identical files.
const SOUND_SEED := 0x5CA7B00C

var _report: PackedStringArray = PackedStringArray()
var _failed := false


func _initialize() -> void:
	if DirAccess.make_dir_recursive_absolute(OUT_DIR) != OK:
		push_error("build_ui_assets: cannot create %s." % OUT_DIR)
		quit(1)
		return

	_build_font(MONO_FACES, FONT_MONO_PATH, "mono")
	var display: Font = _build_font(DISPLAY_FACES, FONT_DISPLAY_PATH, "display")
	_build_debug_line_material()
	var grime: Texture2D = _build_grime()
	var lamp_off: Material = _build_lamp(
		LAMP_OFF_PATH, Color(0.196, 0.075, 0.055), Color.BLACK, 0.0
	)
	var lamp_on: Material = _build_lamp(
		LAMP_ON_PATH, Color(0.851, 0.451, 0.157), Palette.ACCENT_ORANGE, 4.2
	)

	_build_sounds()
	_build_button(display, lamp_off, lamp_on)
	_build_lever(display)
	_build_dial(display)
	_build_slider(display)
	_build_readout(grime)
	_build_combat_hud(display)

	_write_report()
	quit(1 if _failed else 0)


# --- fonts, theme, materials ------------------------------------------------


func _build_font(faces: PackedStringArray, path: String, label: String) -> Font:
	if ResourceLoader.exists(path):
		var existing: Font = ResourceLoader.load(path, "Font") as Font
		if existing != null:
			_report.append("kept  %-22s %s" % ["font %s" % label, path])
			return existing
	var font := SystemFont.new()
	font.font_names = faces
	font.allow_system_fallback = true
	font.antialiasing = TextServer.FONT_ANTIALIASING_GRAY
	font.hinting = TextServer.HINTING_LIGHT
	font.subpixel_positioning = TextServer.SUBPIXEL_POSITIONING_AUTO
	font.oversampling = 0.0
	_save(font, path, "font %s (%s)" % [label, faces[0]])
	return font


func _build_debug_line_material() -> void:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	# Lines carry alpha in their vertex colour, so the pass has to be transparent;
	# without depth writes, because a line has no thickness to occlude with.
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.disable_receive_shadows = true
	mat.disable_fog = true
	mat.no_depth_test = false
	mat.render_priority = 1
	_save(mat, DEBUG_LINES_PATH, "debug line material")


func _build_lamp(path: String, albedo: Color, emission: Color, energy: float) -> Material:
	var mat := ShaderMaterial.new()
	mat.shader = load(SCRAP_SHADER) as Shader
	mat.set_shader_parameter(&"surface_type", 2)
	mat.set_shader_parameter(&"albedo", albedo)
	mat.set_shader_parameter(&"metallic_base", 0.0)
	mat.set_shader_parameter(&"roughness_base", 0.32)
	mat.set_shader_parameter(&"detail_scale", 3.2)
	mat.set_shader_parameter(&"bump_scale", 14.0)
	mat.set_shader_parameter(&"bump_amount", 0.006)
	mat.set_shader_parameter(&"emission_color", emission)
	mat.set_shader_parameter(&"emission_energy", energy)
	mat.set_shader_parameter(&"flat_shaded", false)
	_save(mat, path, "lamp %s" % path.get_file())
	return mat


# --- control sounds ---------------------------------------------------------


## The two sounds every diegetic control carries. They are synthesised here and
## saved as `AudioStreamWAV`, for the same reason the grime tile is: a two-frame
## percussive hit is cheaper to author as arithmetic than to record, and a baked
## `.res` is a shipped artifact like any other. `DiegeticControl` falls back to
## these whenever a panel has not been given a sound of its own.
func _build_sounds() -> void:
	_save(_wav(_click_samples()), UiStyle.CLICK_SOUND_PATH, "sound control click")
	_save(_wav(_deny_samples()), UiStyle.DENY_SOUND_PATH, "sound control deny")


## A struck steel plate: a decaying inharmonic ring under a filtered noise crack
## that is gone in five milliseconds. The crack is what the ear reads as impact;
## the ring is what tells it the plate is metal and not wood.
func _click_samples() -> PackedFloat32Array:
	var count: int = int(CLICK_SECONDS * float(SOUND_RATE))
	var out := PackedFloat32Array()
	out.resize(count)
	var rng := XorShift32.new(SOUND_SEED)
	var noise: float = 0.0
	var k: float = 1.0 - exp(-TAU * NOISE_CORNER / float(SOUND_RATE))
	for i: int in count:
		var t: float = float(i) / float(SOUND_RATE)
		noise += k * (rng.next_range(-1.0, 1.0) - noise)
		out[i] = _ring(CLICK_PARTIALS, t, 0.0) + noise * 0.9 * exp(-t / 0.0045)
	return out


## Two dead knocks. Same synthesis, lower partials, and the second strike at 70 %
## of the first so it reads as a rebound rather than as a second control firing.
func _deny_samples() -> PackedFloat32Array:
	var count: int = int(DENY_SECONDS * float(SOUND_RATE))
	var out := PackedFloat32Array()
	out.resize(count)
	var rng := XorShift32.new(SOUND_SEED ^ 0x1F)
	var noise: float = 0.0
	var k: float = 1.0 - exp(-TAU * (NOISE_CORNER * 0.35) / float(SOUND_RATE))
	for i: int in count:
		var t: float = float(i) / float(SOUND_RATE)
		noise += k * (rng.next_range(-1.0, 1.0) - noise)
		var crack: float = exp(-t / 0.006)
		if t >= DENY_REPEAT:
			crack += 0.7 * exp(-(t - DENY_REPEAT) / 0.006)
		var body: float = _ring(DENY_PARTIALS, t, 0.0)
		body += 0.7 * _ring(DENY_PARTIALS, t, DENY_REPEAT)
		out[i] = body + noise * 0.55 * crack
	return out


## Sum of exponentially damped sines, silent before `start`.
static func _ring(partials: Array[Vector3], t: float, start: float) -> float:
	if t < start:
		return 0.0
	var age: float = t - start
	var sum: float = 0.0
	for p: Vector3 in partials:
		sum += p.y * exp(-age / p.z) * sin(TAU * p.x * age)
	return sum


## Normalise, fade both ends, and pack to signed 16-bit mono. The fades are the
## point: a waveform cut at a non-zero sample is itself a click, and stacking that
## on top of a click is how a UI ends up sounding cheap.
func _wav(samples: PackedFloat32Array) -> AudioStreamWAV:
	var count: int = samples.size()
	var peak: float = 0.0
	for v: float in samples:
		peak = maxf(peak, absf(v))
	var gain: float = SOUND_PEAK / maxf(peak, 0.00001)
	var fade_in: int = maxi(1, int(0.0015 * float(SOUND_RATE)))
	var fade_out: int = maxi(1, int(0.0060 * float(SOUND_RATE)))
	var bytes := PackedByteArray()
	bytes.resize(count * 2)
	for i: int in count:
		var v: float = samples[i] * gain
		if i < fade_in:
			v *= float(i) / float(fade_in)
		var tail: int = count - 1 - i
		if tail < fade_out:
			v *= float(tail) / float(fade_out)
		bytes.encode_s16(i * 2, int(round(clampf(v, -1.0, 1.0) * 32767.0)))
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = SOUND_RATE
	wav.stereo = false
	wav.data = bytes
	return wav


# --- grime ------------------------------------------------------------------


## Tileable value-noise fBm plus a grit octave. Every octave's lattice period
## divides the image size, so the tile wraps exactly and the shader can repeat it
## across a panel without a visible grid.
func _build_grime() -> Texture2D:
	var image := Image.create_empty(GRIME_SIZE, GRIME_SIZE, true, Image.FORMAT_RGB8)
	var low: float = 1.0
	var high: float = 0.0
	var field := PackedFloat32Array()
	field.resize(GRIME_SIZE * GRIME_SIZE)
	for y: int in GRIME_SIZE:
		for x: int in GRIME_SIZE:
			var u: float = float(x) / float(GRIME_SIZE)
			var v: float = float(y) / float(GRIME_SIZE)
			var sum: float = 0.0
			var amp: float = 1.0
			var norm: float = 0.0
			var period: int = GRIME_BASE_PERIOD
			for o: int in GRIME_OCTAVES:
				sum += amp * _value_noise(u, v, period, 1 + o * 7)
				norm += amp
				amp *= 0.55
				period *= 2
			var n: float = sum / norm
			field[y * GRIME_SIZE + x] = n
			low = minf(low, n)
			high = maxf(high, n)
	var span: float = maxf(high - low, 0.0001)
	for y: int in GRIME_SIZE:
		for x: int in GRIME_SIZE:
			# Stretched to the full range and pulled toward the middle: grime that
			# reaches pure black eats the text under it.
			var n: float = (field[y * GRIME_SIZE + x] - low) / span
			var g: float = 0.22 + 0.78 * (n * n * (3.0 - 2.0 * n))
			image.set_pixel(x, y, Color(g, g, g, 1.0))
	image.generate_mipmaps()
	var tex := PortableCompressedTexture2D.new()
	tex.keep_compressed_buffer = true
	tex.create_from_image(image, PortableCompressedTexture2D.COMPRESSION_MODE_LOSSLESS)
	_save(tex, GRIME_PATH, "grime %dx%d" % [GRIME_SIZE, GRIME_SIZE])
	return tex


## Smooth-interpolated value noise on a lattice of `period` cells, wrapping in
## both axes. `u` and `v` are 0..1 across the tile.
static func _value_noise(u: float, v: float, period: int, seed: int) -> float:
	var fx: float = u * float(period)
	var fy: float = v * float(period)
	var x0: int = int(floor(fx))
	var y0: int = int(floor(fy))
	var tx: float = fx - float(x0)
	var ty: float = fy - float(y0)
	tx = tx * tx * (3.0 - 2.0 * tx)
	ty = ty * ty * (3.0 - 2.0 * ty)
	var a: float = _lattice(x0, y0, period, seed)
	var b: float = _lattice(x0 + 1, y0, period, seed)
	var c: float = _lattice(x0, y0 + 1, period, seed)
	var d: float = _lattice(x0 + 1, y0 + 1, period, seed)
	return lerpf(lerpf(a, b, tx), lerpf(c, d, tx), ty)


## Integer hash of a wrapped lattice point to 0..1.
static func _lattice(x: int, y: int, period: int, seed: int) -> float:
	var h: int = posmod(x, period) * 374761393 + posmod(y, period) * 668265263 + seed * 1013904223
	h &= 0x7FFFFFFF
	h = (h ^ (h >> 13)) * 1274126177
	h &= 0x7FFFFFFF
	return float(h % 65536) / 65535.0


# --- diegetic controls ------------------------------------------------------


## A shootable button. Local +Z is out of the face: the cap travels -Z when it is
## pressed, and it starts 5 mm proud of the housing so the two solids overlap.
func _build_button(display: Font, lamp_off: Material, lamp_on: Material) -> void:
	var root := DiegeticButton.new()
	root.name = "DiegeticButton"
	root.control_id = &"button"
	root.collision_layer = GameLayers.PROP
	root.collision_mask = 0
	root.lamp_off_material = lamp_off
	root.lamp_on_material = lamp_on
	root.label_text = "BUTTON"

	var steel: Material = load(SCRAP_STEEL) as Material
	var polymer: Material = load(SCRAP_POLYMER) as Material

	root.add_child(_box("Housing", Vector3(0.14, 0.14, 0.05), Vector3(0.0, 0.0, -0.025), steel))
	var cap := Node3D.new()
	cap.name = "Cap"
	root.add_child(cap)
	cap.add_child(_cylinder_z("CapBody", 0.045, 0.030, Vector3(0.0, 0.0, 0.010), polymer))
	cap.add_child(_cylinder_z("Lamp", 0.017, 0.008, Vector3(0.0, 0.0, 0.026), lamp_off))

	root.add_child(_collider("Hit", Vector3(0.15, 0.15, 0.09), Vector3(0.0, 0.0, -0.012)))
	root.add_child(_label3d("Label", display, "BUTTON", Vector3(0.0, 0.098, 0.002)))
	root.add_child(_sound())
	_own_all(root)
	_pack(root, BUTTON_SCENE, "button")


## A two-position lever. The arm pivots about local X out of a plinth it sinks
## 10 mm into, so there is no gap at the root of the throw.
func _build_lever(display: Font) -> void:
	var root := DiegeticLever.new()
	root.name = "DiegeticLever"
	root.control_id = &"lever"
	root.collision_layer = GameLayers.PROP
	root.collision_mask = 0
	root.label_text = "LEVER"

	var steel: Material = load(SCRAP_STEEL) as Material
	var gun: Material = load(GUN_STEEL) as Material
	var polymer: Material = load(SCRAP_POLYMER) as Material

	root.add_child(_box("Base", Vector3(0.14, 0.06, 0.16), Vector3(0.0, -0.03, 0.0), steel))
	root.add_child(_cylinder_x("Boss", 0.030, 0.09, Vector3(0.0, 0.0, 0.0), steel))
	var arm := Node3D.new()
	arm.name = "Arm"
	root.add_child(arm)
	arm.add_child(_box("Shaft", Vector3(0.030, 0.20, 0.034), Vector3(0.0, 0.085, 0.0), gun))
	arm.add_child(_sphere("Grip", 0.032, Vector3(0.0, 0.180, 0.0), polymer))

	root.add_child(_collider("Hit", Vector3(0.17, 0.30, 0.26), Vector3(0.0, 0.075, 0.0)))
	root.add_child(_label3d("Label", display, "LEVER", Vector3(0.0, 0.265, 0.0)))
	var state: Label3D = _label3d("State", display, "OFF", Vector3(0.0, -0.075, 0.082))
	state.modulate = UiStyle.ACCENT
	root.add_child(state)
	root.add_child(_sound())
	_own_all(root)
	_pack(root, LEVER_SCENE, "lever")


## A rotary selector. Shoot right of centre to index up, left to index down.
func _build_dial(display: Font) -> void:
	var root := DiegeticDial.new()
	root.name = "DiegeticDial"
	root.control_id = &"dial"
	root.collision_layer = GameLayers.PROP
	root.collision_mask = 0
	root.label_text = "DIAL"
	root.options = PackedStringArray(["I", "II", "III", "IV"])

	var steel: Material = load(SCRAP_STEEL) as Material
	var polymer: Material = load(SCRAP_POLYMER) as Material
	var gun: Material = load(GUN_STEEL) as Material

	root.add_child(_box("Plate", Vector3(0.17, 0.17, 0.04), Vector3(0.0, 0.0, -0.020), steel))
	var knob := Node3D.new()
	knob.name = "Knob"
	root.add_child(knob)
	knob.add_child(_cylinder_z("KnobBody", 0.050, 0.034, Vector3(0.0, 0.0, 0.012), polymer))
	# The pointer laps 5 mm into the knob face rather than sitting on it, so no
	# angle of view finds an edge-on gap between the two.
	knob.add_child(_box("Pointer", Vector3(0.011, 0.050, 0.014), Vector3(0.0, 0.030, 0.024), gun))

	root.add_child(_collider("Hit", Vector3(0.18, 0.18, 0.09), Vector3(0.0, 0.0, -0.010)))
	root.add_child(_label3d("Label", display, "DIAL", Vector3(0.0, 0.115, 0.002)))
	var readout: Label3D = _label3d("Readout", display, "I", Vector3(0.0, -0.108, 0.002))
	readout.modulate = UiStyle.ACCENT
	root.add_child(readout)
	root.add_child(_sound())
	_own_all(root)
	_pack(root, DIAL_SCENE, "dial")


## A slider you shoot along. The whole rail is the hit surface, so the collider
## spans the full travel plus the knob's own width.
func _build_slider(display: Font) -> void:
	var root := DiegeticSlider.new()
	root.name = "DiegeticSlider"
	root.control_id = &"slider"
	root.collision_layer = GameLayers.PROP
	root.collision_mask = 0
	root.label_text = "SLIDER"

	var steel: Material = load(SCRAP_STEEL) as Material
	var gun: Material = load(GUN_STEEL) as Material
	var polymer: Material = load(SCRAP_POLYMER) as Material

	root.add_child(_box("Rail", Vector3(0.40, 0.060, 0.046), Vector3(0.0, 0.0, -0.023), steel))
	root.add_child(_box("Groove", Vector3(0.36, 0.018, 0.020), Vector3(0.0, 0.0, -0.006), gun))
	var knob := Node3D.new()
	knob.name = "Knob"
	root.add_child(knob)
	knob.add_child(
		_box("KnobBody", Vector3(0.036, 0.056, 0.036), Vector3(0.0, 0.0, 0.008), polymer)
	)

	root.add_child(_collider("Hit", Vector3(0.42, 0.075, 0.07), Vector3(0.0, 0.0, -0.012)))
	root.add_child(_label3d("Label", display, "SLIDER", Vector3(0.0, 0.070, 0.002)))
	var readout: Label3D = _label3d("Readout", display, "0.00", Vector3(0.0, -0.062, 0.002))
	readout.modulate = UiStyle.ACCENT
	root.add_child(readout)
	root.add_child(_sound())
	_own_all(root)
	_pack(root, SLIDER_SCENE, "slider")


## The world-space display. Four frame solids lap over the edges of a recessed
## screen quad; the quad sits 2 mm in front of a backplate, so the recess has real
## walls and nothing shows through it from any angle.
func _build_readout(grime: Texture2D) -> void:
	var root := DiegeticReadout.new()
	root.name = "DiegeticReadout"

	var steel: Material = load(SCRAP_STEEL) as Material
	root.add_child(_box("Back", Vector3(0.60, 0.42, 0.05), Vector3(0.0, 0.0, -0.035), steel))
	root.add_child(
		_box("FrameTop", Vector3(0.60, 0.055, 0.05), Vector3(0.0, 0.1825, -0.015), steel)
	)
	root.add_child(
		_box("FrameBottom", Vector3(0.60, 0.055, 0.05), Vector3(0.0, -0.1825, -0.015), steel)
	)
	root.add_child(
		_box("FrameLeft", Vector3(0.055, 0.42, 0.05), Vector3(-0.2725, 0.0, -0.015), steel)
	)
	root.add_child(
		_box("FrameRight", Vector3(0.055, 0.42, 0.05), Vector3(0.2725, 0.0, -0.015), steel)
	)

	var quad := QuadMesh.new()
	quad.size = Vector2(SCREEN_W, SCREEN_H)
	var screen := MeshInstance3D.new()
	screen.name = "Screen"
	screen.mesh = quad
	screen.position = Vector3(0.0, 0.0, -0.008)
	screen.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	var mat := ShaderMaterial.new()
	mat.shader = load(READOUT_SHADER) as Shader
	# Local to the scene: two readouts in one room each own their own copy, and so
	# each can point at its own render target.
	mat.resource_local_to_scene = true
	mat.set_shader_parameter(&"style", 0)
	mat.set_shader_parameter(&"grime_tex", grime)
	mat.set_shader_parameter(&"tint_color", Color.WHITE)
	mat.set_shader_parameter(&"emission_energy", 1.7)
	mat.set_shader_parameter(&"scan_lines", 190.0)
	mat.set_shader_parameter(&"scan_strength", 0.32)
	mat.set_shader_parameter(&"curvature", 0.055)
	mat.set_shader_parameter(&"vignette_strength", 0.42)
	mat.set_shader_parameter(&"grime_strength", 0.40)
	mat.set_shader_parameter(&"grime_scale", 3.0)
	mat.set_shader_parameter(&"flicker", 0.025)
	mat.set_shader_parameter(&"roughness_base", 0.38)
	mat.set_shader_parameter(&"metallic_base", 0.15)
	screen.set_surface_override_material(0, mat)
	root.add_child(screen)

	var viewport := SubViewport.new()
	viewport.name = "Display"
	viewport.size = SCREEN_PX
	viewport.disable_3d = true
	viewport.gui_disable_input = true
	viewport.transparent_bg = false
	viewport.render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS
	# Disabled at rest. DiegeticReadout flips it to UPDATE_ONCE whenever the text
	# changes, so a panel showing a static stat card renders exactly once.
	viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	screen.add_child(viewport)

	var canvas := ReadoutCanvas.new()
	canvas.name = "Canvas"
	canvas.size = Vector2(float(SCREEN_PX.x), float(SCREEN_PX.y))
	viewport.add_child(canvas)

	_own_all(root)
	_pack(root, READOUT_SCENE, "readout")


# --- combat HUD -------------------------------------------------------------


func _build_combat_hud(display: Font) -> void:
	var root := CombatHud.new()
	root.name = "CombatHud"
	root.layer = 10

	var vignette := ColorRect.new()
	vignette.name = "Vignette"
	vignette.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	vignette.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# The rect's own colour is irrelevant — the shader writes COLOR outright — but
	# white keeps it obvious in the editor that the material is doing the work.
	vignette.color = Color.WHITE
	var vig_mat := ShaderMaterial.new()
	vig_mat.shader = load(VIGNETTE_SHADER) as Shader
	vig_mat.set_shader_parameter(&"harm", 0.0)
	vig_mat.set_shader_parameter(&"pulse", 0.0)
	vig_mat.set_shader_parameter(&"hit_direction", Vector2.ZERO)
	vig_mat.set_shader_parameter(&"harm_color", Color(0.44, 0.09, 0.07, 1.0))
	vig_mat.set_shader_parameter(&"pulse_color", Color(0.72, 0.16, 0.11, 1.0))
	vig_mat.set_shader_parameter(&"harm_reach", 0.86)
	vig_mat.set_shader_parameter(&"lobe_focus", 3.4)
	vignette.material = vig_mat
	root.add_child(vignette)

	var reticle := CombatReticle.new()
	reticle.name = "Reticle"
	reticle.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(reticle)

	var pops := DamagePops.new()
	pops.name = "Pops"
	pops.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(pops)

	var banner := Label.new()
	banner.name = "Banner"
	banner.text = ""
	banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	banner.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	# Below the sight picture, above the bottom edge: the one place a warning can
	# sit without covering the thing the warning is about.
	banner.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	banner.anchor_top = 0.62
	banner.anchor_bottom = 0.62
	banner.anchor_left = 0.0
	banner.anchor_right = 1.0
	banner.offset_left = 0.0
	banner.offset_right = 0.0
	banner.offset_top = 0.0
	banner.offset_bottom = 34.0
	banner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	banner.add_theme_font_override(&"font", display)
	banner.add_theme_font_size_override(&"font_size", UiStyle.FONT_SIZE_HEAD)
	banner.add_theme_color_override(&"font_color", UiStyle.WARN)
	banner.add_theme_constant_override(&"outline_size", 6)
	banner.add_theme_color_override(&"font_outline_color", Color(0.035, 0.031, 0.028, 1.0))
	banner.visible = false
	root.add_child(banner)

	_own_all(root)
	_pack(root, COMBAT_HUD_SCENE, "combat hud")


# --- primitives -------------------------------------------------------------


static func _box(node_name: String, size: Vector3, pos: Vector3, mat: Material) -> MeshInstance3D:
	var mesh := BoxMesh.new()
	mesh.size = size
	return _instance(node_name, mesh, pos, mat)


## Cylinder with its axis along local Z, which is the face normal of every panel
## control here. CylinderMesh is Y-up, so it is rolled a quarter turn about X.
static func _cylinder_z(
	node_name: String, radius: float, height: float, pos: Vector3, mat: Material
) -> MeshInstance3D:
	var node: MeshInstance3D = _instance(node_name, _cylinder_mesh(radius, height), pos, mat)
	node.rotation = Vector3(PI * 0.5, 0.0, 0.0)
	return node


## Cylinder with its axis along local X — the pivot boss of a lever.
static func _cylinder_x(
	node_name: String, radius: float, height: float, pos: Vector3, mat: Material
) -> MeshInstance3D:
	var node: MeshInstance3D = _instance(node_name, _cylinder_mesh(radius, height), pos, mat)
	node.rotation = Vector3(0.0, 0.0, PI * 0.5)
	return node


static func _cylinder_mesh(radius: float, height: float) -> CylinderMesh:
	var mesh := CylinderMesh.new()
	mesh.top_radius = radius
	mesh.bottom_radius = radius
	mesh.height = height
	mesh.radial_segments = 20
	mesh.rings = 1
	# Both caps on, always. An open cylinder shows its inside the moment the
	# camera leaves the axis, and that is the one defect the project will not have.
	mesh.cap_top = true
	mesh.cap_bottom = true
	return mesh


static func _sphere(
	node_name: String, radius: float, pos: Vector3, mat: Material
) -> MeshInstance3D:
	var mesh := SphereMesh.new()
	mesh.radius = radius
	mesh.height = radius * 2.0
	mesh.radial_segments = 20
	mesh.rings = 10
	return _instance(node_name, mesh, pos, mat)


static func _instance(node_name: String, mesh: Mesh, pos: Vector3, mat: Material) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	node.name = node_name
	node.mesh = mesh
	node.position = pos
	node.set_surface_override_material(0, mat)
	return node


static func _collider(node_name: String, size: Vector3, pos: Vector3) -> CollisionShape3D:
	var shape := BoxShape3D.new()
	shape.size = size
	var node := CollisionShape3D.new()
	node.name = node_name
	node.shape = shape
	node.position = pos
	return node


static func _label3d(node_name: String, font: Font, text: String, pos: Vector3) -> Label3D:
	var node := Label3D.new()
	node.name = node_name
	node.text = text
	node.font = font
	node.font_size = LABEL_FONT_SIZE
	node.pixel_size = LABEL_PIXEL_SIZE
	node.position = pos
	node.modulate = UiStyle.TEXT
	node.outline_size = 10
	node.outline_modulate = Color(0.035, 0.031, 0.028, 1.0)
	node.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	node.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	node.shaded = false
	node.double_sided = false
	node.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	return node


static func _sound() -> AudioStreamPlayer3D:
	var node := AudioStreamPlayer3D.new()
	node.name = "Sound"
	node.unit_size = 3.0
	node.max_distance = 40.0
	node.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
	return node


# --- packing and reporting --------------------------------------------------


## PackedScene only keeps nodes owned by the root, so every descendant is claimed
## before packing. Missing this silently ships a scene with one node in it.
static func _own_all(root: Node) -> void:
	for child: Node in root.get_children():
		child.owner = root
		_own_all_under(child, root)


static func _own_all_under(node: Node, root: Node) -> void:
	for child: Node in node.get_children():
		child.owner = root
		_own_all_under(child, root)


func _pack(root: Node, path: String, label: String) -> void:
	var packed := PackedScene.new()
	var err: Error = packed.pack(root)
	if err != OK:
		_failed = true
		_report.append("FAIL  %-22s pack error %d" % [label, err])
		root.free()
		return
	_save(packed, path, "scene %s" % label)
	root.free()


func _save(res: Resource, path: String, label: String) -> void:
	var err: Error = ResourceSaver.save(res, path)
	if err != OK:
		_failed = true
		_report.append("FAIL  %-22s %s error %d" % [label, path, err])
		return
	_report.append("ok    %-22s %s" % [label, path])


func _write_report() -> void:
	var text: String = "\n".join(_report) + "\n"
	var file: FileAccess = FileAccess.open(REPORT_PATH, FileAccess.WRITE)
	if file == null:
		push_error("build_ui_assets: cannot write %s." % REPORT_PATH)
		_failed = true
	else:
		file.store_string(text)
		file.close()
	print(text)
	print("build_ui_assets: %s" % ("FAILED" if _failed else "PASS"))
