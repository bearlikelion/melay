extends Node

## Drops the host's relay link mid-room and checks it resumes without the guest noticing,
## with a reliable RPC sent while it was away still arriving.

const TIMEOUT_SECONDS: float = 40.0
const POLL_INTERVAL: float = 0.1

enum Role {
	HOST,
	GUEST,
}

var _role: Role = Role.HOST
var _code_path: String = ""
var _url: String = "ws://127.0.0.1:8890"
var _notes: Array[String] = []
var _reconnects: int = 0
var _host_left: bool = false
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

	Melay.reconnected.connect(func() -> void: _reconnects += 1)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	_watchdog()
	_run()


func _run() -> void:
	Melay.configure(_url, "melay-resume", "1.0.0")
	var connected: MelayResult = await Melay.connect_to_relay()
	if connected.is_error():
		_fail("could not connect: %s" % connected.message)
		return

	if _role == Role.HOST:
		await _run_host()
	else:
		await _run_guest()


func _run_host() -> void:
	var created: MelayResult = await Melay.create_room({"max_players": 2})
	if created.is_error():
		_fail("could not host: %s" % created.message)
		return

	var file: FileAccess = FileAccess.open(_code_path, FileAccess.WRITE)
	file.store_string(Melay.get_room().code)
	file.close()

	if not await _wait_until(func() -> bool: return _notes.has("joined")):
		_fail("guest never checked in")
		return

	_note.rpc("dropping")
	Melay.get_node("%MelayClient")._socket.close(MelayClient.CLOSE_RESUMING)
	print("[resume-host] dropped the link")

	if not await _wait_until(func() -> bool: return _reconnects == 1):
		_fail("never reconnected")
		return
	print("[resume-host] reconnected")
	if not await _wait_until(func() -> bool: return _notes.has("while away")):
		_fail("the RPC sent during the drop was lost")
		return

	_note.rpc("back")
	if not await _wait_until(func() -> bool: return _notes.has("done")):
		_fail("guest never confirmed")
		return
	_finish("resume-host")


func _run_guest() -> void:
	var code: String = await _wait_for_code()
	var joined: MelayResult = await Melay.join_room(code)
	if joined.is_error():
		_fail("could not join: %s" % joined.message)
		return
	if not await _wait_until(func() -> bool: return multiplayer.get_peers().has(1)):
		_fail("host never appeared")
		return
	_note.rpc_id(1, "joined")

	if not await _wait_until(func() -> bool: return _notes.has("dropping")):
		_fail("host never dropped")
		return
	await get_tree().create_timer(0.5).timeout
	_note.rpc_id(1, "while away")

	if not await _wait_until(func() -> bool: return _notes.has("back")):
		_fail("host never came back")
		return
	_require(not _host_left, "saw the host leave")
	_note.rpc_id(1, "done")
	await get_tree().create_timer(0.5).timeout
	_finish("resume-guest")


@rpc("any_peer", "reliable")
func _note(text: String) -> void:
	_notes.append(text)


func _on_peer_disconnected(peer_id: int) -> void:
	if peer_id == 1:
		_host_left = true


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


func _require(condition: bool, message: String) -> bool:
	if not condition:
		_fail(message)
	return condition


func _fail(message: String) -> void:
	_failures.append(message)
	print("[resume] FAIL %s" % message)


func _watchdog() -> void:
	await get_tree().create_timer(TIMEOUT_SECONDS).timeout
	_fail("timed out")
	_finish("resume")


func _finish(role: String) -> void:
	if _failures.is_empty():
		print("[%s] ALL CHECKS PASSED" % role)
		get_tree().quit(0)
		return
	get_tree().quit(1)
