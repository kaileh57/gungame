class_name CourseMarks
extends RefCounted
## The parts of the movement course that are LIGHT and SOUND rather than concrete: the
## marker flare over the next gate, the rival-time holograms beside the lap board, the
## lap board itself, and the two chimes a gate makes.
##
## Bake-time only, exactly like `CourseKit` beside it. `res://tools/build_movement.gd`
## drives this once, headless; nothing in here runs in a frame. It is a separate file
## from the kit because the kit's one rule is "mesh and collision out of the same call"
## and none of this collides with anything — a flare, a hologram and a WAV are all
## things you look at or listen to and walk straight through.
##
## NOTHING HERE PAINTS A COLOUR. Instance shader parameters are written at RUNTIME by
## `SplitGate` and `MovementScoreboard`, because the beacon's colour pulses every frame
## and a hologram's colour belongs to whichever player is standing in that slot, which
## is not knowable at bake time. This file builds the nodes and leaves them dark.

## The projector shader and the one material every flare and hologram wears. It lives
## beside this file because this file is the only thing that uses it.
const SHADER_PATH: String = "res://demos/movement/hologram.gdshader"
const MATERIAL_PATH: String = "res://demos/movement/holo_material.tres"
## The gate chime's player, sized to carry across a sixty-metre yard without being
## louder than the world it is in.
const SOUND_UNIT: float = 5.0
const SOUND_REACH: float = 70.0

## Sample rate and headroom of the two chimes. Mono 16-bit, same as every other baked
## sound in the project — a struck chime has nothing above 20 kHz worth the bytes.
const RATE: int = 44100
const PEAK: float = 0.68
## Fades on both ends of a rendered chime. A waveform cut at a non-zero sample IS a
## click, and stacking a click onto a chime is how a course ends up sounding cheap.
const FADE_IN: float = 0.0012
const FADE_OUT: float = 0.0060

## The pass chime: one struck bell, up where nothing else in the demo lives so it cuts
## through a sprint.
const PASS_SECONDS: float = 0.34
const PASS_HZ: float = 1318.5
const PASS_DECAY: float = 0.085
## The lap chime: the same bell struck three times up a major triad, the last one left
## to ring. This is the only sound on the course that says you finished something.
## Each row is (onset seconds, hertz, decay seconds).
const LAP_SECONDS: float = 1.30
const LAP_STRIKES: PackedVector3Array = [
	Vector3(0.00, 1046.5, 0.16),
	Vector3(0.11, 1318.5, 0.20),
	Vector3(0.22, 1568.0, 0.46),
]

## Beacon geometry, in the gate's own local frame, measured from the lintel.
const LAMP_SIZE: Vector3 = Vector3(1.15, 0.17, 0.26)
const LAMP_RISE: float = 0.30
## The flare. Two crossed quads rather than one billboard: a billboard that turns to
## face you is a sprite, and a fixed cross reads as a shaft of light standing in the
## yard, which is the whole point of being able to see it from the bench.
##
## MEASURED AGAINST THE SHOT, NOT PICKED. At 1.30 x 8.20 the start gate's flare stood
## directly behind the gantry screen from the spawn and washed the whole middle of the
## frame — and the middle of the frame is the console this demo exists to read. Narrow,
## short and tapered, it still clears the 4.6 m yard wall by six metres and is the only
## thing you can see from the far end of the course.
const COLUMN_SIZE: Vector2 = Vector2(0.95, 7.00)
const COLUMN_FOOT: float = 0.42
## Same reason: at 11 m the start gate's lamp lit the master column five metres behind
## it. This reaches the arch it is bolted to and stops.
const GLOW_RANGE: float = 5.5

## Lap board. Two posts and a slab, sized to be read from the console thirty metres off.
const POST_HALF: Vector3 = Vector3(0.10, 1.05, 0.10)
const POST_SPAN: float = 1.05
const BOARD_HALF: Vector3 = Vector3(1.45, 0.66, 0.09)
const BOARD_Y: float = 2.68
## Text sits proud of the face it is painted on so it can never z-fight with it.
const FACE_PROUD: float = 0.02
## Draw distance for everything on this structure. The whole course fits in 52 m of the
## bench, so anything past this is text nothing can be standing at.
const SIGN_RANGE: float = 62.0

## The hologram mast, OUTBOARD of the lap board. Three slots, because there are three
## other players and there are never four.
##
## The sign of this is the whole decision. The pair stands at the west rim of the
## authored 110-degree view cone, so one of the two is always further out than the other
## reads comfortably — and the one you look at every lap is your own board, so the mast
## takes the worse seat.
const MAST_OFFSET: float = -2.70
const MAST_HALF: Vector3 = Vector3(0.13, 0.70, 0.13)
const CAP_HALF: Vector3 = Vector3(0.50, 0.06, 0.30)
const CAP_Y: float = 1.44
const HOLO_BASE_Y: float = 1.92
const HOLO_PITCH: float = 0.80
const HOLO_SIZE: Vector2 = Vector2(1.95, 0.66)
const HOLO_NAME_Y: float = 0.17
const HOLO_TIME_Y: float = -0.13


## Write a baked artifact and hand back the LOADED copy, so the packed scene stores an
## external reference to it rather than inlining a second copy of the bytes.
static func save(res: Resource, path: String) -> Resource:
	var err: Error = ResourceSaver.save(res, path)
	if err != OK:
		push_error("CourseMarks: could not save %s (error %d)." % [path, err])
		return res
	return load(path)


## The one material both the flares and the holograms wear, baked and reloaded.
static func projector() -> ShaderMaterial:
	var shader := load(SHADER_PATH) as Shader
	if shader == null:
		push_error("CourseMarks: %s did not load; every flare will be dark." % SHADER_PATH)
		return null
	var mat := ShaderMaterial.new()
	mat.shader = shader
	# Additive geometry has to be drawn after the opaque pass it is meant to sit over.
	mat.render_priority = 2
	return save(mat, MATERIAL_PATH) as ShaderMaterial


## An `AudioStreamPlayer3D` for a thing you run past at eight metres a second.
static func sound_node() -> AudioStreamPlayer3D:
	var node := AudioStreamPlayer3D.new()
	node.name = "Sound"
	node.unit_size = SOUND_UNIT
	node.max_distance = SOUND_REACH
	node.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
	return node


## The demo's one RPC node, at a fixed name under the demo root — `Movement/Link`. An RPC
## only routes when the node path is identical on every machine, which is why this is the
## only node in the demo allowed to carry one.
static func link(root: Node3D, script: Script, console: Node, timer: Node, board: Node) -> Node:
	var node: Node = script.new()
	node.name = "Link"
	root.add_child(node)
	node.set(&"console_path", node.get_path_to(console))
	node.set(&"timer_path", node.get_path_to(timer))
	node.set(&"board_path", node.get_path_to(board))
	return node


## The lamp, the flare and the lamp's light, parented under one node that is switched
## off as a whole. `RunTimer` lights exactly one of these at a time, so the whole system
## costs one omni light and three draw calls.
static func beacon(gate: Node3D, mat: Material, lintel_y: float) -> Node3D:
	var node := Node3D.new()
	node.name = "Beacon"
	node.position = Vector3(0.0, lintel_y, 0.0)
	# Dark until the timer says otherwise. Visibility is inherited, so this one flag
	# switches the lamp, both flare quads and the light together.
	node.visible = false
	gate.add_child(node)

	var box := BoxMesh.new()
	box.size = LAMP_SIZE
	_emitter(node, mat, "Lamp", box, Vector3(0.0, LAMP_RISE, 0.0), 0.0)

	for i: int in 2:
		var quad := QuadMesh.new()
		quad.size = COLUMN_SIZE
		var at := Vector3(0.0, COLUMN_FOOT + COLUMN_SIZE.y * 0.5, 0.0)
		var col: MeshInstance3D = _emitter(node, mat, "Column%d" % i, quad, at, 0.0)
		col.rotation = Vector3(0.0, PI * 0.5 * float(i), 0.0)

	var glow := OmniLight3D.new()
	glow.name = "Glow"
	glow.position = Vector3(0.0, LAMP_RISE, 0.0)
	glow.omni_range = GLOW_RANGE
	# A marker light that casts shadows would put five gates' worth of shadow map on the
	# course for no read at all.
	glow.shadow_enabled = false
	node.add_child(glow)
	return node


## The lap board and the hologram mast, as one node. `at` is the foot of the board on the
## apron; the mast stands `MAST_OFFSET` east of it. Everything solid goes through the kit,
## so the board has a collider and nothing here is a thing you can walk through.
static func scoreboard(kit: CourseKit, root: Node3D, at: Vector3, mat: Material) -> Node3D:
	var node := Node3D.new()
	node.name = "Scoreboard"
	root.add_child(node)
	var body: StaticBody3D = kit.static_body(node, "Posts")
	_board(kit, node, body, at)
	_mast(kit, node, body, at + Vector3(MAST_OFFSET, 0.0, 0.0), mat, at.z)
	return node


## The pass chime, rendered.
static func chime_pass() -> AudioStreamWAV:
	var out: PackedFloat32Array = _silence(PASS_SECONDS)
	_tick(out, 0.0, 0x9A17)
	_strike(out, 0.0, PASS_HZ, 0.85, PASS_DECAY)
	return _wav(out)


## The lap chime, rendered.
static func chime_lap() -> AudioStreamWAV:
	var out: PackedFloat32Array = _silence(LAP_SECONDS)
	for strike: Vector3 in LAP_STRIKES:
		_tick(out, strike.x, 0x5EA1 + int(strike.y))
		_strike(out, strike.x, strike.y, 0.72, strike.z)
	return _wav(out)


# --- geometry ---------------------------------------------------------------


## Two posts, a slab, and the three lines `MovementScoreboard` writes. The labels are
## named rather than left as `T000`, because the runtime finds them by name.
static func _board(kit: CourseKit, node: Node3D, body: StaticBody3D, at: Vector3) -> void:
	var steel: Color = kit.steel()
	for s: float in [-1.0, 1.0]:
		var post: Vector3 = at + Vector3(POST_SPAN * s, POST_HALF.y, 0.0)
		kit.box(body, post, POST_HALF, steel, WorldSurface.Kind.METAL)
	# Wider than the posts and shallower than them, and it overlaps their tops rather
	# than sitting on them: no two faces on this structure are coplanar.
	var slab: Vector3 = at + Vector3(0.0, BOARD_Y, 0.0)
	kit.box(body, slab, BOARD_HALF, kit.rusty(), WorldSurface.Kind.METAL)

	var face: float = at.z + BOARD_HALF.z + FACE_PROUD
	_named(kit, node, "Who", "PLAYER 1", Vector3(at.x, 3.10, face), 0.24, Palette.BONE)
	_named(kit, node, "Best", "- - . - -", Vector3(at.x, 2.66, face), 0.40, Palette.GOLD)
	_named(kit, node, "Last", "LAST  - - . - -", Vector3(at.x, 2.22, face), 0.20, Palette.BONE)


## The mast and its three hologram slots, hidden until somebody posts a time.
static func _mast(
	kit: CourseKit, node: Node3D, body: StaticBody3D, at: Vector3, mat: Material, face_z: float
) -> void:
	var stem: Vector3 = at + Vector3(0.0, MAST_HALF.y, 0.0)
	kit.box(body, stem, MAST_HALF, kit.steel(), WorldSurface.Kind.METAL)
	kit.box(body, at + Vector3(0.0, CAP_Y, 0.0), CAP_HALF, kit.rusty(), WorldSurface.Kind.METAL)
	var plate := Vector3(at.x, 1.02, at.z + MAST_HALF.z + FACE_PROUD)
	kit.plate(node, "RIVAL BEST", plate, 0.0, 0.17, Palette.ACCENT_ORANGE, SIGN_RANGE)

	for i: int in NetPlayer.MAX_PLAYERS - 1:
		var y: float = HOLO_BASE_Y + HOLO_PITCH * float(i)
		var slot := Node3D.new()
		slot.name = "Slot%d" % i
		slot.visible = false
		node.add_child(slot)
		var quad := QuadMesh.new()
		quad.size = HOLO_SIZE
		_emitter(slot, mat, "Panel", quad, Vector3(at.x, y, face_z + 0.03), 1.0)
		var text_z: float = face_z + 0.06
		_named(kit, slot, "Name", "", Vector3(at.x, y + HOLO_NAME_Y, text_z), 0.19, Palette.BONE)
		_named(kit, slot, "Time", "", Vector3(at.x, y + HOLO_TIME_Y, text_z), 0.30, Palette.GOLD)


## One unlit emitter. `scan` is the raster-bar mix this instance wants and is recorded as
## metadata, so the runtime can push it without knowing which node is a panel and which
## is a lamp head.
static func _emitter(
	parent: Node3D, mat: Material, node_name: String, mesh: Mesh, at: Vector3, scan: float
) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	node.name = node_name
	node.mesh = mesh
	# Material OVERRIDE rather than a surface material on the primitive: the mesh is
	# built here and dressing it afterwards is exactly the mistake that ships a scene
	# pointing at an undressed copy.
	node.material_override = mat
	node.position = at
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	node.set_meta(&"holo_scan", scan)
	parent.add_child(node)
	return node


## A named `Label3D` on a vertical face, sized in metres of line height.
static func _named(
	kit: CourseKit,
	parent: Node3D,
	node_name: String,
	text: String,
	at: Vector3,
	height: float,
	col: Color
) -> Label3D:
	var node: Label3D = kit.plate(parent, text, at, 0.0, height, col, SIGN_RANGE)
	node.name = node_name
	return node


# --- sound ------------------------------------------------------------------


static func _silence(seconds: float) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(maxi(int(seconds * float(RATE)), 1))
	return out


## One struck bell: the fundamental plus two partials, each decaying faster than the one
## below it, which is what an ear reads as metal rather than as a sine tone.
static func _strike(
	out: PackedFloat32Array, start: float, hz: float, amp: float, decay: float
) -> void:
	var first: int = maxi(int(start * float(RATE)), 0)
	for i: int in range(first, out.size()):
		var age: float = float(i - first) / float(RATE)
		var env: float = exp(-age / decay)
		if env < 0.0008:
			return
		var body: float = env * sin(TAU * hz * age)
		body += 0.34 * exp(-age / (decay * 0.55)) * sin(TAU * hz * 2.0 * age)
		body += 0.15 * exp(-age / (decay * 0.32)) * sin(TAU * hz * 3.01 * age)
		out[i] += amp * body


## Five milliseconds of low-passed noise at the onset. The bell says what was struck;
## this is the only part the ear reads as it having been struck at all.
static func _tick(out: PackedFloat32Array, start: float, seed_value: int) -> void:
	var rng := XorShift32.new(seed_value)
	var first: int = maxi(int(start * float(RATE)), 0)
	var last: int = mini(first + int(0.02 * float(RATE)), out.size())
	var lowpass: float = 0.0
	var k: float = 1.0 - exp(-TAU * 3400.0 / float(RATE))
	for i: int in range(first, last):
		var age: float = float(i - first) / float(RATE)
		lowpass += k * (rng.next_range(-1.0, 1.0) - lowpass)
		out[i] += lowpass * 0.45 * exp(-age / 0.0035)


## Normalise, fade both ends, pack to signed 16-bit mono.
static func _wav(samples: PackedFloat32Array) -> AudioStreamWAV:
	var count: int = samples.size()
	var loudest: float = 0.0
	for v: float in samples:
		loudest = maxf(loudest, absf(v))
	var gain: float = PEAK / maxf(loudest, 0.00001)
	var rise: int = maxi(1, int(FADE_IN * float(RATE)))
	var fall: int = maxi(1, int(FADE_OUT * float(RATE)))
	var bytes := PackedByteArray()
	bytes.resize(count * 2)
	for i: int in count:
		var v: float = samples[i] * gain
		if i < rise:
			v *= float(i) / float(rise)
		var tail: int = count - 1 - i
		if tail < fall:
			v *= float(tail) / float(fall)
		bytes.encode_s16(i * 2, roundi(clampf(v, -1.0, 1.0) * 32767.0))
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = RATE
	wav.stereo = false
	wav.data = bytes
	return wav
