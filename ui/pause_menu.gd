class_name PauseMenu
extends CanvasLayer
## Escape, in every demo. Resume, settings, back to the main menu.
##
## The pause STATE belongs to `SceneRouter` — this menu never writes
## `get_tree().paused` and never touches the mouse mode. It listens to
## `pause_changed` and shows itself. That split is what stops Escape from being
## half-handled between a menu and a player controller.
##
## Mounted once by the `DebugHUD` autoload, so every demo gets it without doing
## anything. Nothing here animates for longer than 120 ms; the user asked for fast
## and a pause menu that fades in slowly is a pause menu you resent.

@export_range(0.02, 0.15, 0.01) var fade_seconds: float = UiStyle.ANIM_FAST
## How far the panel rises as it appears, in pixels. Small on purpose.
@export_range(0.0, 40.0, 1.0) var rise_pixels: float = 14.0

var _tween: Tween = null

@onready var _scrim: ColorRect = $Scrim
@onready var _frame: PanelContainer = $Root/Frame
@onready var _subtitle: Label = $Root/Frame/Body/Subtitle
@onready var _resume: Button = $Root/Frame/Body/Resume
@onready var _settings_button: Button = $Root/Frame/Body/SettingsButton
@onready var _quit_button: Button = $Root/Frame/Body/MainMenuButton
@onready var _settings_host: Control = $SettingsHost
@onready var _settings: SettingsPanel = $SettingsHost/SettingsPanel


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	visible = false
	_settings_host.visible = false
	_resume.pressed.connect(_on_resume)
	_settings_button.pressed.connect(_open_settings)
	_quit_button.pressed.connect(_on_main_menu)
	_settings.closed.connect(_close_settings)
	SceneRouter.pause_changed.connect(_on_pause_changed)


func _input(event: InputEvent) -> void:
	if not visible or not _settings_host.visible:
		return
	if not event.is_action_pressed(&"pause"):
		return
	# Escape inside settings backs out to the menu instead of resuming. Consumed
	# here so SceneRouter's unhandled-input pause toggle never sees it.
	get_viewport().set_input_as_handled()
	_close_settings()


## Open the settings page over the pause menu. Public so a demo's own diegetic
## control can route to it without duplicating the page.
func open_settings() -> void:
	_open_settings()


func _on_pause_changed(is_paused: bool) -> void:
	if is_paused:
		_show()
		return
	_hide()


func _show() -> void:
	var info: Dictionary = SceneRouter.demo_info(SceneRouter.current_demo)
	_subtitle.text = String(info.get("title", "")) if not info.is_empty() else ""
	visible = true
	_settings_host.visible = false
	_frame.pivot_offset = _frame.size * 0.5
	_scrim.modulate.a = 0.0
	_frame.modulate.a = 0.0
	_frame.position.y += rise_pixels
	_kill_tween()
	_tween = create_tween()
	_tween.set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
	_tween.set_parallel(true)
	_tween.tween_property(_scrim, "modulate:a", 1.0, fade_seconds)
	_tween.tween_property(_frame, "modulate:a", 1.0, fade_seconds)
	(
		_tween
		. tween_property(_frame, "position:y", _frame.position.y - rise_pixels, fade_seconds)
		. set_trans(Tween.TRANS_CUBIC)
		. set_ease(Tween.EASE_OUT)
	)
	_resume.grab_focus()


func _hide() -> void:
	if not visible:
		return
	_kill_tween()
	_tween = create_tween()
	_tween.set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
	_tween.set_parallel(true)
	_tween.tween_property(_scrim, "modulate:a", 0.0, fade_seconds)
	_tween.tween_property(_frame, "modulate:a", 0.0, fade_seconds)
	_tween.chain().tween_callback(_finish_hide)


func _finish_hide() -> void:
	visible = false
	_settings_host.visible = false


func _open_settings() -> void:
	_settings_host.visible = true
	_settings.open()


func _close_settings() -> void:
	_settings_host.visible = false
	_resume.grab_focus()


func _on_resume() -> void:
	SceneRouter.set_paused(false)


func _on_main_menu() -> void:
	SceneRouter.back_to_menu()


func _kill_tween() -> void:
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_tween = null
