extends Node

## Melay: a Godot MultiplayerPeer backed by a Dockerised relay.
##
## Typical use:
## [codeblock]
## Melay.configure("ws://127.0.0.1:8890", "my-game", "1.0.0")
## var result: MelayResult = await Melay.connect_to_relay()
## if result.is_error():
##     push_error(result.message)
##     return
## var room: MelayResult = await Melay.create_room({"max_players": 4})
## print("share this code: ", room.value.code)
## [/codeblock]
##
## With [member auto_assign_peer] left on, [code]multiplayer.multiplayer_peer[/code] is
## wired up as soon as a room is joined, so ordinary [code]@rpc[/code] functions and
## MultiplayerSpawner just work from there.

signal connected
signal disconnected(reason: String)
## Emitted once the peer holds its relay-assigned id, before the room's existing
## members are announced. With [member auto_assign_peer] off, assign
## [code]multiplayer.multiplayer_peer[/code] here and nowhere else: waiting for
## [signal room_joined] misses the peer_connected announcements entirely.
signal peer_ready(peer: MelayPeer)
signal room_joined(room: MelayRoom)
signal room_left
signal peer_joined(info: MelayPeerInfo)
signal peer_left(info: MelayPeerInfo, reason: String)
signal error_received(code: String, message: String)
signal latency_updated(rtt_us: int, clock_offset_us: int)

const SETTING_MODE: String = "melay/connection/mode"
const SETTING_URL: String = "melay/connection/url"
const SETTING_LOCAL_URL: String = "melay/connection/local_url"
const SETTING_GAME_ID: String = "melay/connection/game_id"
const SETTING_GAME_VERSION: String = "melay/connection/game_version"
const SETTING_API_KEY: String = "melay/connection/api_key"
const SETTING_AUTO_ASSIGN: String = "melay/general/auto_assign_peer"

## Optional file holding the values for this machine or this deployment. Keep it out of
## version control so a personal relay address never lands in a public repository.
const LOCAL_CONFIG_PATH: String = "res://melay_local.cfg"

enum Mode {
	REMOTE,
	LOCAL,
}

## When true, joining a room assigns [code]multiplayer.multiplayer_peer[/code] and
## leaving clears it.
var auto_assign_peer: bool = true

@onready var _client: MelayClient = %MelayClient


func _ready() -> void:
	_apply_project_settings()
	_apply_local_config()
	_client.connected.connect(_on_client_connected)
	_client.disconnected.connect(_on_client_disconnected)
	_client.peer_ready.connect(_on_client_peer_ready)
	_client.room_joined.connect(_on_client_room_joined)
	_client.room_left.connect(_on_client_room_left)
	_client.peer_joined.connect(peer_joined.emit)
	_client.peer_left.connect(peer_left.emit)
	_client.error_received.connect(error_received.emit)
	_client.latency_updated.connect(latency_updated.emit)


## Points the addon at a relay. Overrides whatever the project settings say.
func configure(url: String, game_id: String, game_version: String = "1.0.0") -> void:
	_client.url = url
	_client.game_id = game_id
	_client.game_version = game_version


## Sets the shared secret for games the relay has an api_key configured for.
func set_api_key(api_key: String) -> void:
	_client.api_key = api_key


## Sets the name other players see. Not an identity; the relay does not verify it.
func set_display_name(display_name: String) -> void:
	_client.display_name = display_name


func connect_to_relay() -> MelayResult:
	return await _client.connect_to_relay()


func disconnect_from_relay() -> void:
	_client.disconnect_from_relay()


## Creates a room and becomes its host. Recognised options: name, max_players,
## visibility, tags, password, dedicated. Resolves to a [MelayRoom].
func create_room(options: Dictionary = {}) -> MelayResult:
	return await _client.create_room(options)


## Joins a room by its share code. Resolves to a [MelayRoom].
func join_room(code: String, password: String = "") -> MelayResult:
	return await _client.join_room(code, password)


## Lists public rooms for this game and version. Recognised filters: tags,
## only_joinable, limit. Resolves to an Array of room summary dictionaries.
func list_rooms(filter: Dictionary = {}) -> MelayResult:
	return await _client.list_rooms(filter)


## Quick play: joins the first open public room matching the options' tags, or hosts
## a new one when none is available.
func join_or_create(options: Dictionary = {}) -> MelayResult:
	var listing: MelayResult = await _client.list_rooms({
		"tags": options.get("tags", {}),
		"only_joinable": true,
		"limit": 10,
	})
	if listing.is_error():
		return listing

	for summary: Dictionary in listing.value:
		if bool(summary.get("has_password", false)):
			continue
		var joined: MelayResult = await _client.join_room(summary.get("code", ""))
		if not joined.is_error():
			return joined

	return await _client.create_room(options)


func leave_room() -> void:
	_client.leave_room()


## Records a custom analytics event against this game.
func track(event: String, props: Dictionary = {}) -> void:
	_client.track(event, props)


## The MultiplayerPeer to hand to [code]multiplayer.multiplayer_peer[/code]. Assigned
## automatically unless [member auto_assign_peer] is turned off.
func get_peer() -> MelayPeer:
	return _client.peer


func get_room() -> MelayRoom:
	return _client.get_room()


func get_status() -> MelayClient.Status:
	return _client.get_status()


## What the relay allows this game: max_packet_size, max_message_size,
## max_players_per_room, max_rooms and max_name_length. Empty until connected.
func get_limits() -> Dictionary:
	return _client.get_limits()


## The largest packet a game may send. Anything above the relay's frame limit is
## split on the way out and put back together on the far side, so this is what
## [code]get_max_packet_size[/code] would report if Godot exposed it to scripts.
func get_max_message_size() -> int:
	return _client.get_max_message_size()


func is_in_room() -> bool:
	return _client.get_status() == MelayClient.Status.IN_ROOM


func is_host() -> bool:
	var room: MelayRoom = _client.get_room()
	return room != null and room.is_host()


func get_session_id() -> String:
	return _client.get_session_id()


func get_client_id() -> String:
	return _client.get_client_id()


## Round-trip time to the relay in microseconds, from the most recent heartbeat.
func get_rtt_us() -> int:
	return _client.get_rtt_us()


## Offset that converts a local tick reading into relay time. Epoch-scale, not a small
## drift figure. See [method get_clock_drift_us] for estimate quality.
func get_clock_offset_us() -> int:
	return _client.get_clock_offset_us()


## How much the clock estimate moved on the most recent sample, in microseconds.
func get_clock_drift_us() -> int:
	return _client.get_clock_drift_us()


## False until the first heartbeat reply lands, when relay time is still unknown.
func has_clock_sync() -> bool:
	return _client.has_clock_sync()


## The relay's clock in microseconds. Peers agree on it within a round trip, so it is
## the reference to use when something must happen at the same moment for everyone.
func get_relay_time_us() -> int:
	return _client.get_relay_time_us()


func _apply_project_settings() -> void:
	var mode: Mode = ProjectSettings.get_setting(SETTING_MODE, Mode.REMOTE) as Mode
	if mode == Mode.LOCAL:
		_client.url = ProjectSettings.get_setting(SETTING_LOCAL_URL, _client.url)
	else:
		_client.url = ProjectSettings.get_setting(SETTING_URL, _client.url)

	_client.game_id = ProjectSettings.get_setting(SETTING_GAME_ID, _client.game_id)
	_client.game_version = ProjectSettings.get_setting(
		SETTING_GAME_VERSION, _client.game_version
	)
	_client.api_key = ProjectSettings.get_setting(SETTING_API_KEY, _client.api_key)
	auto_assign_peer = bool(ProjectSettings.get_setting(SETTING_AUTO_ASSIGN, true))


# Read after the project settings so it wins, and before any configure() call so code
# still has the final say.
func _apply_local_config() -> void:
	if not FileAccess.file_exists(LOCAL_CONFIG_PATH):
		return

	var config: ConfigFile = ConfigFile.new()
	if config.load(LOCAL_CONFIG_PATH) != OK:
		push_warning("Melay: could not read %s" % LOCAL_CONFIG_PATH)
		return

	_client.url = config.get_value("connection", "url", _client.url)
	_client.game_id = config.get_value("connection", "game_id", _client.game_id)
	_client.game_version = config.get_value(
		"connection", "game_version", _client.game_version
	)
	_client.api_key = config.get_value("connection", "api_key", _client.api_key)


func _on_client_connected() -> void:
	connected.emit()


func _on_client_disconnected(reason: String) -> void:
	if auto_assign_peer and multiplayer.multiplayer_peer == _client.peer:
		multiplayer.multiplayer_peer = null
	disconnected.emit(reason)


func _on_client_peer_ready(ready_peer: MelayPeer) -> void:
	if auto_assign_peer:
		multiplayer.multiplayer_peer = ready_peer
	peer_ready.emit(ready_peer)


func _on_client_room_joined(room: MelayRoom) -> void:
	room_joined.emit(room)


func _on_client_room_left() -> void:
	if auto_assign_peer and multiplayer.multiplayer_peer == _client.peer:
		multiplayer.multiplayer_peer = null
	room_left.emit()
