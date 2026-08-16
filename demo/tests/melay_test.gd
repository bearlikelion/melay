class_name MelayTest
extends Node

## Headless end-to-end check. Two instances of this scene, one host and one guest,
## connect to a running relay, share a room and exchange Godot RPCs over it.
##
## Run through tests/run_tests.sh rather than directly.

const TEST_GAME: String = "melay-selftest"
const TEST_VERSION: String = "1.0.0"

## Generous, because the guest spends part of it waiting for the host's code file.
const TIMEOUT_SECONDS: float = 30.0

const POLL_INTERVAL: float = 0.1

enum Role {
	HOST,
	GUEST,
}

var _role: Role = Role.HOST
var _code_path: String = ""
var _url: String = "ws://127.0.0.1:8890"

var _failures: Array[String] = []
var _pong_received: bool = false
var _peer_joined_seen: bool = false


func _ready() -> void:
	_parse_arguments()
	_start_timeout()
	_run()


func _parse_arguments() -> void:
	for argument: String in OS.get_cmdline_user_args():
		var parts: PackedStringArray = argument.split("=", true, 1)
		if parts.size() != 2:
			continue
		match parts[0]:
			"--role":
				_role = Role.GUEST if parts[1] == "guest" else Role.HOST
			"--code-file":
				_code_path = parts[1]
			"--url":
				_url = parts[1]


func _run() -> void:
	_log("starting as %s against %s" % [_role_name(), _url])

	Melay.configure(_url, TEST_GAME, TEST_VERSION)
	Melay.set_display_name(_role_name())
	Melay.peer_joined.connect(_on_peer_joined)

	var connected: MelayResult = await Melay.connect_to_relay()
	if not _require(not connected.is_error(), "connect: %s" % connected.message):
		return

	if _role == Role.HOST:
		await _run_host()
	else:
		await _run_guest()


func _run_host() -> void:
	var created: MelayResult = await Melay.create_room({
		"name": "selftest",
		"max_players": 4,
		"visibility": MelayProtocol.VISIBILITY_PRIVATE,
	})
	if not _require(not created.is_error(), "create_room: %s" % created.message):
		return

	var room: MelayRoom = created.value
	_require(room.self_peer_id == 1, "host peer id is %d, want 1" % room.self_peer_id)
	_require(Melay.is_host(), "host does not report is_host()")
	_require(multiplayer.is_server(), "multiplayer.is_server() is false on the host")
	_require(
		multiplayer.get_unique_id() == 1,
		"multiplayer.get_unique_id() is %d, want 1" % multiplayer.get_unique_id()
	)

	_log("hosting room %s, publishing code" % room.code)
	_write_code(room.code)

	# The guest answers the ping with a pong; receiving it proves RPCs work both ways.
	if not await _wait_until(func() -> bool: return _pong_received):
		_fail("never received a pong from the guest")
		return

	_require(_peer_joined_seen, "host never saw peer_joined")
	_finish()


func _run_guest() -> void:
	var code: String = await _wait_for_code()
	if code.is_empty():
		_fail("host never published a room code")
		return

	var joined: MelayResult = await Melay.join_room(code)
	if not _require(not joined.is_error(), "join_room: %s" % joined.message):
		return

	var room: MelayRoom = joined.value
	_require(room.self_peer_id == 2, "guest peer id is %d, want 2" % room.self_peer_id)
	_require(not Melay.is_host(), "guest reports is_host()")
	_require(not multiplayer.is_server(), "multiplayer.is_server() is true on the guest")
	_require(room.peers.size() == 2, "guest sees %d peers, want 2" % room.peers.size())
	_require(
		room.host_peer_id == 1,
		"guest sees host id %d, want 1" % room.host_peer_id
	)

	# Godot only knows about peer 1 if the peer emitted peer_connected for it.
	_require(
		multiplayer.get_peers().has(1),
		"multiplayer.get_peers() does not contain the host: %s" % [multiplayer.get_peers()]
	)

	_log("joined room %s as peer %d, pinging host" % [code, room.self_peer_id])
	ping.rpc_id(1, "hello from the guest")

	if not await _wait_until(func() -> bool: return _pong_received):
		_fail("never received a pong from the host")
		return
	_finish()


@rpc("any_peer", "reliable")
func ping(message: String) -> void:
	var sender: int = multiplayer.get_remote_sender_id()
	_log("ping from peer %d: %s" % [sender, message])
	_require(sender != 0, "ping arrived with no remote sender id")
	pong.rpc_id(sender, "hello from peer %d" % multiplayer.get_unique_id())


@rpc("any_peer", "reliable")
func pong(message: String) -> void:
	var sender: int = multiplayer.get_remote_sender_id()
	_log("pong from peer %d: %s" % [sender, message])
	_require(sender != 0, "pong arrived with no remote sender id")
	_pong_received = true

	# The host answers a pong with one of its own so both sides confirm a round trip.
	if _role == Role.HOST:
		return
	_pong_received = true


func _on_peer_joined(info: MelayPeerInfo) -> void:
	_log("peer joined: %s" % info)
	_peer_joined_seen = true
	if _role != Role.HOST:
		return
	_require(info.peer_id == 2, "joining peer id is %d, want 2" % info.peer_id)
	ping.rpc_id(info.peer_id, "hello from the host")


func _wait_for_code() -> String:
	var waited: float = 0.0
	while waited < TIMEOUT_SECONDS:
		if FileAccess.file_exists(_code_path):
			var file: FileAccess = FileAccess.open(_code_path, FileAccess.READ)
			if file != null:
				var code: String = file.get_as_text().strip_edges()
				file.close()
				if not code.is_empty():
					return code
		await get_tree().create_timer(POLL_INTERVAL).timeout
		waited += POLL_INTERVAL
	return ""


func _wait_until(predicate: Callable) -> bool:
	var waited: float = 0.0
	while waited < TIMEOUT_SECONDS:
		if predicate.call():
			return true
		await get_tree().create_timer(POLL_INTERVAL).timeout
		waited += POLL_INTERVAL
	return false


func _write_code(code: String) -> void:
	var file: FileAccess = FileAccess.open(_code_path, FileAccess.WRITE)
	if file == null:
		_fail("could not write the code file at %s" % _code_path)
		return
	file.store_string(code)
	file.close()


func _require(condition: bool, message: String) -> bool:
	if not condition:
		_fail(message)
	return condition


func _fail(message: String) -> void:
	_failures.append(message)
	print("[%s] FAIL %s" % [_role_name(), message])


func _log(message: String) -> void:
	print("[%s] %s" % [_role_name(), message])


func _role_name() -> String:
	return "guest" if _role == Role.GUEST else "host"


func _start_timeout() -> void:
	await get_tree().create_timer(TIMEOUT_SECONDS).timeout
	_fail("timed out after %.0f seconds" % TIMEOUT_SECONDS)
	_finish()


func _finish() -> void:
	if _failures.is_empty():
		print("[%s] ALL CHECKS PASSED" % _role_name())
		get_tree().quit(0)
		return
	print("[%s] %d CHECK(S) FAILED" % [_role_name(), _failures.size()])
	get_tree().quit(1)
