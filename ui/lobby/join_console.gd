class_name JoinConsole
extends Node3D
## The JOIN box on the front of the bench: a steel case with a lid that SPRINGS UP
## and becomes the screen you type an address into.
##
## THE TRANSFORMATION IS THE POINT. Shut, it is a box stencilled JOIN A GAME with a
## red GO button on its front. Press it and the lid swings up on its hinge and stands
## leaning back at you — the same piece of steel, now a terminal, carrying a prompt,
## the address you are typing, and whatever went wrong in words. Nothing appears and
## nothing is swapped: one object moves.
##
## THE SECOND BEAT IS THE FLASH. Confirm an address and the case throws a burst of
## sparks out of the hinge seam, kicks forward on its feet, and the screen is a NAME
## box — the prompt has changed, the field has cleared, and what you type now is your
## call sign. The join itself does not go out until that name is confirmed, which is
## both what the brief asks for and the only ordering that works: the username travels
## inside the join handshake, so it has to exist before the socket opens.
##
## THIS FILE IS A DEVICE, NOT A POLICY. It knows how to open, how to take typing, and
## how to say something went wrong. It does not know what an address means or when to
## host — it emits `submitted` and `LobbyBench` decides. That is what keeps the
## networking in one file and the mechanism in this one.
##
## THE KEYBOARD IS CLAIMED WHILE IT IS OPEN. Every key it uses is marked handled, so
## typing "h" into an address types an h instead of hosting a game.

## A field was confirmed. `field` is one of `Mode`, `text` is what was in it. Address
## text has already been validated — a bad address never leaves this object.
signal submitted(field: int, text: String)
## The lid came down, however it came down.
signal shut_down

enum Mode {
	## Lid closed. The case is just a box that says JOIN A GAME.
	SHUT,
	## Typing an address.
	ADDRESS,
	## Typing a call sign.
	NAME,
	## The socket is open and we are waiting to be let in. Nothing to type.
	WAITING,
	## Hosting: the screen is reading your own address back to you.
	READOUT,
}

## Degrees the lid stands up at. Fifteen off vertical, which puts its face square to
## an eye that is looking down at the bench from 26 degrees above it.
const OPEN_DEGREES: float = 75.0
const OPEN_SECONDS: float = 0.26
const SHUT_SECONDS: float = 0.18
## Metres the whole case kicks forward when it changes mode. Small, hard, and over
## in a tenth of a second: the machine reacting rather than the machine animating.
const PUNCH: float = 0.016
const PUNCH_SECONDS: float = 0.10
## Caret blinks per second.
const CARET_HZ: float = 2.0

## Longest address anyone may type. An IPv6 with a port is 47 characters at the very
## worst, and `NetAddress` refuses anything past 253 anyway.
const MAX_ADDRESS: int = 48

## Characters allowed in an address on top of letters and digits: the IPv4 dot, the
## port colon, the IPv6 brackets and the hostname hyphen.
const ADDRESS_PUNCT: String = ".:-[]"

var _mode: int = Mode.SHUT
var _text: String = ""
var _caret_on: bool = true
var _caret_clock: float = 0.0
var _rest: Vector3 = Vector3.ZERO
var _lid_tween: Tween = null
var _punch_tween: Tween = null

@onready var _hinge: Node3D = $Hinge
@onready var _prompt: Label3D = $Hinge/Prompt
@onready var _entry: Label3D = $Hinge/Entry
@onready var _status: Label3D = $Hinge/Status
@onready var _hint: Label3D = $Hinge/Hint
@onready var _sparks: GPUParticles3D = $Sparks
@onready var _touch: DiegeticControl = $Touch
@onready var _go: DiegeticControl = $Go


func _ready() -> void:
	_rest = position
	_hinge.rotation.x = 0.0
	_touch.pressed.connect(_on_touch_pressed)
	_go.pressed.connect(_on_go_pressed)
	_apply_mode(Mode.SHUT)


func _process(delta: float) -> void:
	if not is_typing():
		return
	_caret_clock += delta * CARET_HZ
	var on: bool = fmod(_caret_clock, 2.0) < 1.0
	if on == _caret_on:
		return
	_caret_on = on
	_repaint()


func _unhandled_input(event: InputEvent) -> void:
	if not is_typing():
		return
	var key := event as InputEventKey
	if key == null or not key.pressed:
		return
	var used: bool = true
	if key.keycode == KEY_ESCAPE:
		if not key.echo:
			shut()
	elif key.keycode == KEY_ENTER or key.keycode == KEY_KP_ENTER:
		if not key.echo:
			_submit()
	elif key.keycode == KEY_BACKSPACE:
		_backspace()
	elif key.unicode >= 32:
		_type(key.unicode)
	else:
		used = false
	if used:
		get_viewport().set_input_as_handled()


## Open the lid on an address field. `prefill` is whatever was typed last time, so a
## failed join does not cost you the address you nearly got right.
func open_address(prefill: String) -> void:
	_text = prefill.substr(0, MAX_ADDRESS)
	_apply_mode(Mode.ADDRESS)


## The second beat: sparks, a kick, and the same screen is now a call-sign field.
func open_name(prefill: String) -> void:
	_text = prefill.substr(0, NetPlayer.MAX_NAME)
	burst()
	_apply_mode(Mode.NAME)


## Hosting. The screen reads your own address back so you can say it out loud.
func open_readout(body: String, note: String) -> void:
	_text = ""
	_status.text = note
	_status.modulate = UiStyle.TEXT_DIM
	burst()
	_apply_mode(Mode.READOUT)
	_entry.text = body


## The socket is open and nobody has answered yet.
func set_waiting(target: String) -> void:
	_text = target
	_apply_mode(Mode.WAITING)


## Say what happened, on the object. `bad` colours it as a refusal; anything longer
## than the screen is cut at its first sentence, because the whole sentence goes to
## the bench readout at a size you can actually read and this line is the label on
## the machine that failed.
func set_status(text: String, bad: bool) -> void:
	_status.text = first_sentence(text).to_upper()
	_status.modulate = UiStyle.WARN if bad else UiStyle.TEXT_DIM


## Shut the lid and go back to being a box.
func shut() -> void:
	if _mode == Mode.SHUT:
		return
	_apply_mode(Mode.SHUT)
	shut_down.emit()


## Sparks out of the hinge seam and a hard kick forward. Public because the lobby
## fires it for events the console did not cause, like a guest arriving.
func burst() -> void:
	if _sparks != null:
		_sparks.restart()
	if _punch_tween != null and _punch_tween.is_valid():
		_punch_tween.kill()
	position = _rest
	var kicked: Vector3 = _rest + Vector3(0.0, 0.0, PUNCH)
	_punch_tween = create_tween()
	_punch_tween.tween_property(self, ^"position", kicked, PUNCH_SECONDS * 0.35)
	_punch_tween.tween_property(self, ^"position", _rest, PUNCH_SECONDS * 0.65)


func mode() -> int:
	return _mode


## True while the keyboard belongs to this object.
func is_typing() -> bool:
	return _mode == Mode.ADDRESS or _mode == Mode.NAME


## The first sentence of a multi-sentence reason. `NetGame`'s refusals lead with the
## fact and follow with the advice; the fact is what fits on a 46 cm screen.
static func first_sentence(text: String) -> String:
	var stop: int = text.find(". ")
	if stop < 0:
		return text
	return text.substr(0, stop + 1)


# --- the mechanism ----------------------------------------------------------


func _apply_mode(next: int) -> void:
	_mode = next
	_caret_clock = 0.0
	_caret_on = true
	_dress()
	_set_open(_mode != Mode.SHUT)
	_repaint()


## What each mode says on the screen. The status line is left alone by the modes that
## have just written one — a refusal must survive the field it refers to reopening.
func _dress() -> void:
	match _mode:
		Mode.ADDRESS:
			_prompt.text = "IP ADDRESS"
			_hint.text = "ENTER = NEXT     ESC = CLOSE"
		Mode.NAME:
			_prompt.text = "CALL SIGN"
			_status.text = "THIS IS THE NAME THE OTHERS SEE."
			_status.modulate = UiStyle.TEXT_DIM
			_hint.text = "ENTER = JOIN     ESC = CLOSE"
		Mode.WAITING:
			_prompt.text = "CONNECTING"
			_hint.text = "ESC = CLOSE"
		Mode.READOUT:
			_prompt.text = "YOUR ADDRESS"
			_hint.text = "READ IT OUT. THEY TYPE IT IN."
		_:
			_prompt.text = ""
			_hint.text = ""
	_prompt.modulate = UiStyle.ACCENT


func _repaint() -> void:
	if _mode == Mode.READOUT:
		return
	if _mode == Mode.WAITING:
		_entry.text = _text
		return
	_entry.text = _text + ("_" if _caret_on else " ")


func _set_open(open: bool) -> void:
	if _lid_tween != null and _lid_tween.is_valid():
		_lid_tween.kill()
	var target: float = deg_to_rad(OPEN_DEGREES) if open else 0.0
	_lid_tween = create_tween()
	_lid_tween.set_trans(Tween.TRANS_BACK if open else Tween.TRANS_QUAD)
	_lid_tween.set_ease(Tween.EASE_OUT if open else Tween.EASE_IN)
	_lid_tween.tween_property(_hinge, ^"rotation:x", target, OPEN_SECONDS if open else SHUT_SECONDS)


func _type(unicode: int) -> void:
	if _text.length() >= _limit():
		return
	var ch: String = String.chr(unicode)
	if not _accepts(ch):
		return
	_text += ch
	_recheck()
	_repaint()


func _backspace() -> void:
	if _text.is_empty():
		return
	_text = _text.substr(0, _text.length() - 1)
	_recheck()
	_repaint()


func _limit() -> int:
	return NetPlayer.MAX_NAME if _mode == Mode.NAME else MAX_ADDRESS


## An address is letters, digits and five pieces of punctuation. Filtering at the key
## rather than at submit time means the field never holds something it cannot mean.
func _accepts(ch: String) -> bool:
	if _mode != Mode.ADDRESS:
		return true
	if ADDRESS_PUNCT.contains(ch):
		return true
	var c: int = ch.unicode_at(0)
	return (c >= 48 and c <= 57) or (c >= 65 and c <= 90) or (c >= 97 and c <= 122)


## Grade the address as it is typed, so the box goes red on the fourth character of
## "192.168.1.999" instead of after a ten second timeout. Dim, not red: this is a
## remark about an unfinished address, and the refusal colour belongs to a real one.
func _recheck() -> void:
	if _mode != Mode.ADDRESS:
		return
	if _text.is_empty():
		_status.text = "AN IP, OR AN IP AND A PORT: 192.168.1.5:%d" % NetGame.DEFAULT_PORT
		_status.modulate = UiStyle.TEXT_FAINT
		return
	var parsed: Dictionary = NetAddress.parse(_text, NetGame.DEFAULT_PORT)
	if bool(parsed["ok"]):
		_status.text = "READY: %s" % NetAddress.format(String(parsed["host"]), int(parsed["port"]))
		_status.modulate = UiStyle.GOOD
		return
	_status.text = first_sentence(String(parsed["error"])).to_upper()
	_status.modulate = UiStyle.TEXT_DIM


func _submit() -> void:
	if _mode == Mode.ADDRESS:
		var parsed: Dictionary = NetAddress.parse(_text, NetGame.DEFAULT_PORT)
		if not bool(parsed["ok"]):
			set_status(String(parsed["error"]), true)
			return
		submitted.emit(Mode.ADDRESS, _text)
		return
	if _mode == Mode.NAME:
		submitted.emit(Mode.NAME, _text)


func _on_touch_pressed() -> void:
	if _mode == Mode.SHUT:
		open_address(_text)
		return
	if _mode == Mode.READOUT or _mode == Mode.WAITING:
		shut()


func _on_go_pressed() -> void:
	if _mode == Mode.SHUT:
		open_address(_text)
		return
	_submit()
