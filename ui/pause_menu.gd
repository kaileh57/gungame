class_name PauseMenu
extends CanvasLayer
## Escape, in every demo. Resume, settings, and the way out.
##
## The pause STATE belongs to `SceneRouter` — this menu never writes
## `get_tree().paused` and never touches the mouse mode. It listens to
## `pause_changed` and shows itself. That split is what stops Escape from being
## half-handled between a menu and a player controller.
##
## IN MULTIPLAYER THE WAY OUT MEANS TWO DIFFERENT THINGS, and this menu's job is
## to say which one you are about to do:
##   * The HOST's exit ends the session. Everyone follows them to the title
##     screen, because the host owns the scene. The button says so and is painted
##     in the accent colour.
##   * A CLIENT's exit is QUIT LOBBY: they leave, the others carry on. It is
##     painted in the warning colour, because leaving somebody else's game is not
##     the same act as closing your own.
## Pausing means two different things as well, and the menu says that too: the
## host's pause stops the authoritative simulation for everybody, while a client's
## pause stops nothing but their own view.
##
## Neither branch calls `NetGame` to do the leaving. Both press
## `SceneRouter.back_to_menu()`, which already routes a client's request for the
## menu into `NetGame.leave()` — one owner of that policy, and this menu stays a
## thing that listens rather than a second place that decides.
##
## Mounted once by the `DebugHUD` autoload, so every demo gets it without doing
## anything. Nothing here animates for longer than 120 ms; the user asked for fast
## and a pause menu that fades in slowly is a pause menu you resent.

## What the exit button says. The host's is the only one that moves other people.
const EXIT_SOLO_TEXT: String = "MAIN MENU"
const EXIT_HOST_TEXT: String = "MAIN MENU (EVERYONE)"
const EXIT_CLIENT_TEXT: String = "QUIT LOBBY"

## Every font colour the baked theme sets on a Button. All four are overridden
## together, or hovering a red QUIT LOBBY would turn it the theme's gold and throw
## the warning away at exactly the moment the player is about to press it.
const EXIT_COLOR_STATES: PackedStringArray = [
	"font_color",
	"font_focus_color",
	"font_hover_color",
	"font_pressed_color",
]

const HOST_HINT: String = (
	"You are the host. While the game is held here nothing moves for anybody — "
	+ "the simulation everyone is watching is this one. MAIN MENU ends the session "
	+ "and takes every player back to the title screen with you."
)
const CLIENT_HINT: String = (
	"This holds your view only. The game keeps running around you, and the host "
	+ "cannot see that you stopped. QUIT LOBBY leaves the game and puts you back on "
	+ "your own title screen; everyone else carries on without you."
)

@export_range(0.02, 0.15, 0.01) var fade_seconds: float = UiStyle.ANIM_FAST
## How far the panel rises as it appears, in pixels. Small on purpose.
@export_range(0.0, 40.0, 1.0) var rise_pixels: float = 14.0

var _tween: Tween = null
## Who you are in the session, painted in your slot colour. Hidden in single
## player, where the answer is "the only person here".
var _session: Label = null
## What the exit button is about to do, in words. Hidden in single player, where
## MAIN MENU means the obvious thing and does not need explaining.
var _hint: Label = null

@onready var _scrim: ColorRect = $Scrim
@onready var _frame: PanelContainer = $Root/Frame
@onready var _body: VBoxContainer = $Root/Frame/Body
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
	_build_session_lines()
	_resume.pressed.connect(_on_resume)
	_settings_button.pressed.connect(_open_settings)
	_quit_button.pressed.connect(_on_main_menu)
	_settings.closed.connect(_close_settings)
	SceneRouter.pause_changed.connect(_on_pause_changed)
	# Everything that can change the answer to "who am I in this game": somebody
	# joining or leaving, a rename, hosting starting, and the session ending.
	NetGame.players_changed.connect(_refresh_role)
	NetGame.lobby_opened.connect(_refresh_role)
	NetGame.lobby_closed.connect(_refresh_role)
	_refresh_role()


func _input(event: InputEvent) -> void:
	if _is_display_cycle(event):
		get_viewport().set_input_as_handled()
		GameSettings.cycle_window_mode()
		return
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


## The two lines the baked scene does not carry, because what they say depends on
## a session that does not exist when the scene is built. Placed rather than just
## appended, so the panel still reads top to bottom: which demo, who you are in
## it, the buttons, and then what the last button is really going to do.
func _build_session_lines() -> void:
	_session = Label.new()
	_session.name = "Session"
	_session.add_theme_font_size_override("font_size", UiStyle.FONT_SIZE_SMALL)
	_session.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_session.visible = false
	_body.add_child(_session)
	_body.move_child(_session, _subtitle.get_index() + 1)

	_hint = Label.new()
	_hint.name = "SessionHint"
	_hint.add_theme_font_size_override("font_size", UiStyle.FONT_SIZE_SMALL)
	_hint.add_theme_color_override("font_color", UiStyle.TEXT_DIM)
	_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hint.visible = false
	_body.add_child(_hint)


## Say who the local player is and make the exit button mean what it will do.
## Cheap and idempotent, so it runs on every roster change and on every open
## rather than trying to work out when the answer could have moved.
func _refresh_role() -> void:
	if _session == null or _hint == null:
		return
	var networked: bool = NetGame.is_networked()
	_session.visible = networked
	_hint.visible = networked
	if not networked:
		_quit_button.text = EXIT_SOLO_TEXT
		for state: String in EXIT_COLOR_STATES:
			_quit_button.remove_theme_color_override(state)
		return
	var me: NetPlayer = NetGame.local_player()
	var count: int = NetGame.players().size()
	_session.add_theme_color_override("font_color", me.color())
	if NetGame.is_host():
		_session.text = (
			"HOSTING AS %s     %d OF %d PLAYERS" % [me.slot_name(), count, NetPlayer.MAX_PLAYERS]
		)
		_hint.text = HOST_HINT
		_quit_button.text = EXIT_HOST_TEXT
		_paint_exit(UiStyle.ACCENT)
		return
	_session.text = (
		"GUEST OF %s     YOU ARE %s     %d OF %d"
		% [_host_name(), me.slot_name(), count, NetPlayer.MAX_PLAYERS]
	)
	_hint.text = CLIENT_HINT
	_quit_button.text = EXIT_CLIENT_TEXT
	_paint_exit(UiStyle.WARN)


## Paint the exit button in a role colour. Hover and press get a lifted version of
## the same colour rather than the theme's gold, so the button never stops looking
## like the thing it is while the pointer is on it.
func _paint_exit(base: Color) -> void:
	var lit: Color = base.lerp(UiStyle.TEXT, 0.45)
	_quit_button.add_theme_color_override("font_color", base)
	_quit_button.add_theme_color_override("font_focus_color", base)
	_quit_button.add_theme_color_override("font_hover_color", lit)
	_quit_button.add_theme_color_override("font_pressed_color", lit)


## Whose game this is, for a client. Never empty — a roster that has not landed
## yet is still a game with a host in it.
func _host_name() -> String:
	var owner_player: NetPlayer = NetGame.player(NetPlayer.HOST_ID)
	if owner_player == null:
		return "THE HOST"
	return owner_player.display_name()


func _on_pause_changed(is_paused: bool) -> void:
	if is_paused:
		_show()
		return
	_hide()


func _show() -> void:
	var info: Dictionary = SceneRouter.demo_info(SceneRouter.current_demo)
	_subtitle.text = String(info.get("title", "")) if not info.is_empty() else ""
	_refresh_role()
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


## Both roles press this. `SceneRouter.back_to_menu()` sends the host home and
## announces the route, which every client follows; a client's own request is
## turned into `NetGame.leave()` by the router, which drops the session and puts
## them back on their own title screen. See this file's header.
func _on_main_menu() -> void:
	SceneRouter.back_to_menu()


func _kill_tween() -> void:
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_tween = null


## Alt+Enter and F11 — the two things every player tries without being told.
## Matched on the raw key rather than through an InputMap action on purpose: the
## action list is the GAME's vocabulary, and a window-manager convention has no
## business in it. This node is mounted by `DebugHUD` for the whole run, so the
## shortcut works in every demo and on the title screen alike.
static func _is_display_cycle(event: InputEvent) -> bool:
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo:
		return false
	if key.keycode == KEY_F11:
		return true
	return key.alt_pressed and (key.keycode == KEY_ENTER or key.keycode == KEY_KP_ENTER)
