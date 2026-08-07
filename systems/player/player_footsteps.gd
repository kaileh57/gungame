class_name PlayerFootsteps
extends Node3D
## The sound of walking.
##
## `PlayerController` has computed a full stride the whole time — a bob phase, a step
## every PI of it, the surface it landed on and how loud it was — and emitted
## `stepped(surface, volume)` to nobody. The sample was baked too: `GunAudioBank.step`
## has been sitting in `data/audio/gun_audio_bank.tres` since the audio pass. So the
## player has been walking in total silence past enemies who can HEAR those same
## footsteps, because `EnemyActor.motion_loudness` feeds the noise bus off the same
## motion. This connects the two ends of something already built.
##
## Nine surfaces, one sample. Pitch and level per surface is what makes tin sound like
## tin; a separate recording per material is a content problem, not a code one, and the
## bank is a synth bank anyway.

## Where the shared bank lives. Same constant as `GunAudio`, deliberately not shared
## through it: a gun's audio belongs to the gun and the player has feet without one.
const BANK_PATH: String = "res://data/audio/gun_audio_bank.tres"

## Voices. Four is enough for a sprint into a landing without a step ever being cut.
const VOICES: int = 4

## Pitch per `WorldSurface.Kind`, indexed by the enum. Metal and tin ring, sand and cloth
## deaden, rock and concrete sit in the middle.
const SURFACE_PITCH: PackedFloat32Array = [
	1.32,  # METAL
	0.94,  # WOOD
	1.06,  # POLY
	0.72,  # SAND
	1.00,  # CONCRETE
	1.44,  # TIN
	0.64,  # CLOTH
	0.88,  # ASPHALT
	0.98,  # ROCK
]
## Level trim per surface, in decibels, on top of the step's own volume.
const SURFACE_DB: PackedFloat32Array = [
	1.5,  # METAL
	0.0,  # WOOD
	-1.0,  # POLY
	-3.5,  # SAND
	0.0,  # CONCRETE
	2.0,  # TIN
	-6.0,  # CLOTH
	-0.5,  # ASPHALT
	-0.5,  # ROCK
]

## Master level for the whole stride, in decibels.
@export_range(-40.0, 12.0, 0.5) var volume_db: float = -9.0
## Random pitch spread either side of the surface pitch, so a corridor of identical steps
## does not turn into a machine gun.
@export_range(0.0, 0.4, 0.01) var pitch_jitter: float = 0.09
## How far a footstep carries. Short: these are your own feet, not a gunshot.
@export_range(1.0, 40.0, 0.5) var max_distance: float = 12.0
## Optional. Defaults to the parent, which is where the player prefab puts this.
@export var controller_path: NodePath = NodePath("..")

var _players: Array[AudioStreamPlayer3D] = []
var _next: int = 0
var _step: AudioStreamWAV = null
var _rand: RandomNumberGenerator = RandomNumberGenerator.new()


func _ready() -> void:
	var bank: Resource = ResourceLoader.load(BANK_PATH)
	if bank != null:
		_step = bank.get(&"step") as AudioStreamWAV
	if _step == null:
		# No bank baked yet. Stay silent rather than erroring every step.
		set_process(false)
		return
	for i: int in VOICES:
		var p := AudioStreamPlayer3D.new()
		p.name = "Step%d" % i
		p.stream = _step
		p.max_distance = max_distance
		p.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
		add_child(p)
		_players.append(p)
	var owner_node: Node = get_node_or_null(controller_path)
	if owner_node != null and owner_node.has_signal(&"stepped"):
		owner_node.connect(&"stepped", _on_stepped)


## A foot hit the ground. `surface` indexes `WorldSurface.Kind`; `volume` is the
## controller's own 0..1 reading of how hard, which already accounts for speed and for a
## crouch, so nothing here needs to know how fast the player is going.
func _on_stepped(surface: int, volume: float) -> void:
	if _players.is_empty() or volume <= 0.0:
		return
	var i: int = clampi(surface, 0, SURFACE_PITCH.size() - 1)
	var p: AudioStreamPlayer3D = _players[_next]
	_next = (_next + 1) % _players.size()
	p.pitch_scale = maxf(SURFACE_PITCH[i] + _rand.randf_range(-pitch_jitter, pitch_jitter), 0.05)
	p.volume_db = volume_db + SURFACE_DB[i] + linear_to_db(clampf(volume, 0.05, 1.0))
	p.play()
