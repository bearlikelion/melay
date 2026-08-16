class_name MelayDemo
extends Control

## Main scene for the Melay demo. It owns the relay connection and swaps one child
## screen at a time: menu, then lobby, then game.
##
## Every RPC lives here rather than on a screen, because this node is the only one
## with a stable path on every peer. Screens report upward with signals and are
## driven downward with method calls, so none of them touch Melay directly.

enum Screen {
	MENU,
	LOBBY,
	GAME,
}

const MENU_SCENE: PackedScene = preload("res://game/screens/menu_screen.tscn")
const LOBBY_SCENE: PackedScene = preload("res://game/screens/lobby_screen.tscn")
const GAME_SCENE: PackedScene = preload("res://game/screens/game_screen.tscn")

const COUNTDOWN_SECONDS: float = 3.0

@onready var _screen_host: Control = %ScreenHost

var _screen: Screen = Screen.MENU
var _current: Control = null
var _ready_states: Dictionary = {}
var _in_game: bool = false


func _ready() -> void:
	Melay.room_joined.connect(_on_room_joined)
	Melay.room_left.connect(_on_room_left)
	Melay.peer_joined.connect(_on_peer_joined)
	Melay.peer_left.connect(_on_peer_left)
	Melay.disconnected.connect(_on_disconnected)
	Melay.error_received.connect(_on_error_received)

	_show(Screen.MENU)


func _process(_delta: float) -> void:
	if _screen != Screen.GAME or _current == null:
		return

	_current.set_stats("players %d   rtt %.1f ms   clock drift %.2f ms%s" % [
		_current.player_count(),
		Melay.get_rtt_us() / 1000.0,
		Melay.get_clock_drift_us() / 1000.0,
		"" if Melay.has_clock_sync() else "   (waiting for clock)",
	])


func _show(screen: Screen) -> void:
	if _current != null:
		_current.queue_free()
		_current = null
	_screen = screen

	match screen:
		Screen.MENU:
			_current = MENU_SCENE.instantiate()
			_screen_host.add_child(_current)
			_current.host_requested.connect(_on_host_requested)
			_current.join_requested.connect(_on_join_requested)
			_current.browse_requested.connect(_on_browse_requested)
		Screen.LOBBY:
			_current = LOBBY_SCENE.instantiate()
			_screen_host.add_child(_current)
			_current.ready_toggled.connect(_on_ready_toggled)
			_current.start_requested.connect(_on_start_requested)
			_current.leave_requested.connect(_on_leave_requested)
			_current.set_room(Melay.get_room())
			_refresh_lobby()
		Screen.GAME:
			_current = GAME_SCENE.instantiate()
			_current.name = "Game"
			_screen_host.add_child(_current)
			_current.leave_requested.connect(_on_leave_requested)
			_current.ball_synced.connect(_on_ball_synced)
			_current.setup(Melay.get_room())


func _on_host_requested(display_name: String) -> void:
	_current.set_busy(true)
	_current.set_status("Connecting...")

	if not await _ensure_connected(display_name):
		return

	var created: MelayResult = await Melay.create_room({
		"name": "%s's game" % display_name,
		"max_players": 8,
		"visibility": MelayProtocol.VISIBILITY_PUBLIC,
		"tags": {"mode": "arena"},
	})
	if created.is_error():
		_menu_error(created)


func _on_join_requested(code: String, display_name: String) -> void:
	if code.strip_edges().is_empty():
		_current.set_status("Enter a room code, or browse for one.")
		return

	_current.set_busy(true)
	_current.set_status("Connecting...")

	if not await _ensure_connected(display_name):
		return

	var joined: MelayResult = await Melay.join_room(code.strip_edges())
	if joined.is_error():
		_menu_error(joined)


func _on_browse_requested(display_name: String) -> void:
	_current.set_busy(true)
	_current.set_status("Connecting...")

	if not await _ensure_connected(display_name):
		return

	var listing: MelayResult = await Melay.list_rooms({"only_joinable": true})
	if listing.is_error():
		_menu_error(listing)
		return

	_current.set_busy(false)
	_current.show_rooms(listing.value)


func _ensure_connected(display_name: String) -> bool:
	Melay.set_display_name(display_name)
	if Melay.get_status() != MelayClient.Status.DISCONNECTED:
		return true

	var connected: MelayResult = await Melay.connect_to_relay()
	if connected.is_error():
		_menu_error(connected)
		return false
	return true


func _menu_error(result: MelayResult) -> void:
	if _screen != Screen.MENU or _current == null:
		return
	_current.set_busy(false)
	_current.set_status("%s: %s" % [result.code, result.message])


func _on_room_joined(room: MelayRoom) -> void:
	_in_game = false
	_ready_states.clear()
	_ready_states[room.self_peer_id] = false
	_show(Screen.LOBBY)


func _on_room_left() -> void:
	_in_game = false
	_ready_states.clear()
	_show(Screen.MENU)


func _on_disconnected(reason: String) -> void:
	_in_game = false
	_ready_states.clear()
	_show(Screen.MENU)
	_current.set_status("Disconnected: %s" % reason)


func _on_error_received(code: String, message: String) -> void:
	if _screen == Screen.MENU and _current != null:
		_current.set_busy(false)
		_current.set_status("%s: %s" % [code, message])


func _on_peer_joined(info: MelayPeerInfo) -> void:
	_ready_states[info.peer_id] = false

	if Melay.is_host():
		_sync_ready_states.rpc_id(info.peer_id, _ready_states)
		# Already past the countdown, so a late joiner starts playing immediately.
		if _in_game:
			_start_game.rpc_id(info.peer_id, Melay.get_relay_time_us())

	if _screen == Screen.GAME and _current != null:
		_current.spawn_player(info)
	else:
		_refresh_lobby()


func _on_peer_left(info: MelayPeerInfo, _reason: String) -> void:
	_ready_states.erase(info.peer_id)

	if _screen == Screen.GAME and _current != null:
		_current.despawn_player(info.peer_id)
	else:
		_refresh_lobby()


func _on_ready_toggled(is_ready: bool) -> void:
	_set_ready.rpc(is_ready)


func _on_start_requested() -> void:
	if not Melay.is_host() or not _all_ready():
		return
	# Against the relay clock, so the countdown hits zero at the same moment everywhere.
	_start_game.rpc(Melay.get_relay_time_us() + int(COUNTDOWN_SECONDS * 1_000_000.0))


func _on_leave_requested() -> void:
	Melay.leave_room()


func _on_ball_synced(to: Vector2, velocity: Vector2) -> void:
	_sync_ball.rpc(to, velocity)


@rpc("any_peer", "reliable", "call_local")
func _set_ready(is_ready: bool) -> void:
	# A local call reports sender 0, so fall back to our own id.
	var sender: int = multiplayer.get_remote_sender_id()
	if sender == 0:
		sender = multiplayer.get_unique_id()
	_ready_states[sender] = is_ready
	_refresh_lobby()


@rpc("authority", "reliable", "call_remote")
func _sync_ready_states(states: Dictionary) -> void:
	for peer_id: Variant in states:
		_ready_states[int(peer_id)] = bool(states[peer_id])
	_refresh_lobby()


@rpc("authority", "reliable", "call_local")
func _start_game(start_at_relay_us: int) -> void:
	if _in_game:
		return
	_in_game = true
	_show(Screen.GAME)
	_current.begin_countdown(_seconds_until(start_at_relay_us))


## Converts a relay timestamp into how long this peer should still wait for it.
## Without a clock estimate the conversion would be nonsense, so fall back to counting
## the full duration locally rather than starting at a wrong moment.
func _seconds_until(relay_us: int) -> float:
	if not Melay.has_clock_sync():
		return COUNTDOWN_SECONDS
	var remaining: float = float(relay_us - Melay.get_relay_time_us()) / 1_000_000.0
	return clampf(remaining, 0.0, COUNTDOWN_SECONDS)


@rpc("authority", "unreliable_ordered", "call_remote")
func _sync_ball(to: Vector2, velocity: Vector2) -> void:
	if _screen == Screen.GAME and _current != null:
		_current.apply_ball(to, velocity)


func _refresh_lobby() -> void:
	if _screen != Screen.LOBBY or _current == null:
		return

	var room: MelayRoom = Melay.get_room()
	if room == null:
		return

	var rows: Array[Dictionary] = []
	for peer_id: int in room.peers:
		var info: MelayPeerInfo = room.get_peer(peer_id)
		rows.append({
			"peer_id": peer_id,
			"display_name": info.display_name,
			"is_host": info.is_host,
			"is_self": peer_id == room.self_peer_id,
			"is_ready": bool(_ready_states.get(peer_id, false)),
		})
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a["peer_id"] < b["peer_id"]
	)

	_current.set_players(rows)
	_current.set_is_host(Melay.is_host())
	_current.set_can_start(_all_ready())


func _all_ready() -> bool:
	var room: MelayRoom = Melay.get_room()
	if room == null or room.peers.is_empty():
		return false
	for peer_id: int in room.peers:
		if not bool(_ready_states.get(peer_id, false)):
			return false
	return true
