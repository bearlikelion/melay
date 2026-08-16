extends Node

## Drives examples/melay_demo through its whole flow without a human clicking:
## menu, lobby, ready up, start, then the arena. Run from tests/run_tests.sh.

const DEMO_SCENE: PackedScene = preload("res://game/melay_demo.tscn")

const TIMEOUT_SECONDS: float = 40.0
const POLL_INTERVAL: float = 0.1
const SETTLE_SECONDS: float = 2.0

enum Role {
	HOST,
	GUEST,
}

var _role: Role = Role.HOST
var _code_path: String = ""
var _url: String = "ws://127.0.0.1:8890"
var _demo: MelayDemo = null
var _failures: Array[String] = []


func _ready() -> void:
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

	_watchdog()
	_run()


func _run() -> void:
	Melay.configure(_url, "melay-demo-drive", "1.0.0")

	_demo = DEMO_SCENE.instantiate()
	add_child(_demo)
	await get_tree().process_frame

	if _role == Role.HOST:
		await _run_host()
	else:
		await _run_guest()


func _run_host() -> void:
	_screen().host_requested.emit("drive-host")
	var room: MelayRoom = await _await_room()
	if room == null:
		return
	_log("hosting %s" % room.code)

	var file: FileAccess = FileAccess.open(_code_path, FileAccess.WRITE)
	if file == null:
		_fail("could not write the code file")
		return
	file.store_string(room.code)
	file.close()

	if not await _wait_until(func() -> bool: return _lobby_player_count() == 2):
		_fail("the guest never appeared in the lobby")
		return
	_log("both players in the lobby")

	# Start must stay locked until every player has readied up.
	_require(not _demo._all_ready(), "start was available before anyone readied up")
	_screen().ready_toggled.emit(true)

	if not await _wait_until(func() -> bool: return _demo._all_ready()):
		_fail("never reached all-ready")
		return
	_log("all players ready, starting")

	_screen().start_requested.emit()
	if not await _wait_until(func() -> bool: return _demo._screen == MelayDemo.Screen.GAME):
		_fail("host never entered the game screen")
		return

	_require(not _screen().is_running(), "play began before the countdown ran")
	if not await _wait_until(func() -> bool: return _screen().is_running()):
		_fail("the countdown never finished")
		return
	_log("countdown finished, playing")

	await _settle()
	_check_arena()

	# A peer joining after the match started must be pulled straight into the game.
	# This is the path that silently broke when _start_game gained an argument.
	if _role == Role.HOST:
		_require(
			_demo._in_game,
			"host is not marked in-game, so the late joiner path cannot be exercised"
		)

	# Held open until the guest is done, rather than racing it to the exit.
	if not await _wait_until(func() -> bool: return FileAccess.file_exists(_done_path())):
		_fail("the guest never reported finishing")
	_finish()


func _run_guest() -> void:
	var code: String = await _wait_for_code()
	if code.is_empty():
		_fail("host never published a room code")
		return

	_screen().join_requested.emit(code, "drive-guest")
	var room: MelayRoom = await _await_room()
	if room == null:
		return
	_log("joined %s as peer %d" % [code, room.self_peer_id])

	if not await _wait_until(func() -> bool: return _lobby_player_count() == 2):
		_fail("the host never appeared in the lobby")
		return

	_screen().ready_toggled.emit(true)

	# The host drives the transition, so the guest only has to follow it.
	if not await _wait_until(func() -> bool: return _demo._screen == MelayDemo.Screen.GAME):
		_fail("guest never followed the host into the game screen")
		return
	_log("followed the host into the game")

	if not await _wait_until(func() -> bool: return _screen().is_running()):
		_fail("the countdown never finished")
		return

	await _settle()
	_check_arena()

	# Position alone moves from local prediction, so count applied updates instead.
	var updates_before: int = _screen().get_ball_update_count()
	var position_before: Vector2 = _screen().get_ball_position()
	await get_tree().create_timer(0.8).timeout

	_require(
		_screen().get_ball_update_count() > updates_before,
		"guest applied no authoritative ball updates from the host"
	)
	_require(_screen().get_ball_position() != position_before, "the guest's ball never moved")

	var done: FileAccess = FileAccess.open(_done_path(), FileAccess.WRITE)
	if done != null:
		done.store_string("done")
		done.close()
	_finish()


func _done_path() -> String:
	return _code_path + ".guest-done"


func _screen() -> Node:
	return _demo._current


func _lobby_player_count() -> int:
	var room: MelayRoom = Melay.get_room()
	return 0 if room == null else room.peers.size()


func _check_arena() -> void:
	if not _require(_demo._screen == MelayDemo.Screen.GAME, "not on the game screen"):
		return
	var count: int = _screen().player_count()
	_require(count == 2, "arena has %d players, want 2" % count)


func _await_room() -> MelayRoom:
	if not await _wait_until(func() -> bool: return Melay.is_in_room()):
		_fail("never entered a room")
		return null
	return Melay.get_room()


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


func _settle() -> void:
	await get_tree().create_timer(SETTLE_SECONDS).timeout


func _require(condition: bool, message: String) -> bool:
	if not condition:
		_fail(message)
	return condition


func _fail(message: String) -> void:
	_failures.append(message)
	print("[demo-%s] FAIL %s" % [_role_name(), message])


func _log(message: String) -> void:
	print("[demo-%s] %s" % [_role_name(), message])


func _role_name() -> String:
	return "guest" if _role == Role.GUEST else "host"


func _watchdog() -> void:
	await get_tree().create_timer(TIMEOUT_SECONDS).timeout
	_fail("timed out")
	_finish()


func _finish() -> void:
	if _failures.is_empty():
		print("[demo-%s] ALL CHECKS PASSED" % _role_name())
		get_tree().quit(0)
		return
	get_tree().quit(1)
