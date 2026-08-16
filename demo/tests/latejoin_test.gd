extends Node

## Joins a room that is already mid-match and checks the late joiner is pulled into
## the game rather than left sitting in the lobby.

const DEMO_SCENE: PackedScene = preload("res://game/melay_demo.tscn")

const TIMEOUT_SECONDS: float = 40.0
const POLL_INTERVAL: float = 0.1

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
	Melay.configure(_url, "melay-latejoin", "1.0.0")

	_demo = DEMO_SCENE.instantiate()
	add_child(_demo)
	await get_tree().process_frame

	if _role == Role.HOST:
		await _run_host()
	else:
		await _run_latecomer()


func _run_host() -> void:
	_demo._current.host_requested.emit("late-host")
	if not await _wait_until(func() -> bool: return Melay.is_in_room()):
		_fail("never hosted")
		return

	var code: String = Melay.get_room().code

	# Start solo, so the match is already running when the other instance arrives.
	_demo._current.ready_toggled.emit(true)
	if not await _wait_until(func() -> bool: return _demo._all_ready()):
		_fail("never reached all-ready")
		return
	_demo._current.start_requested.emit()

	if not await _wait_until(func() -> bool: return _demo._screen == MelayDemo.Screen.GAME):
		_fail("host never entered the game")
		return

	# Published only now, so whoever picks it up is guaranteed to be a late joiner.
	var file: FileAccess = FileAccess.open(_code_path, FileAccess.WRITE)
	if file == null:
		_fail("could not write the code file")
		return
	file.store_string(code)
	file.close()
	print("[late-host] in game as %s, waiting for a late joiner" % code)

	if not await _wait_until(func() -> bool: return _demo._current.player_count() >= 2):
		_fail("the late joiner never appeared in the arena")
		return
	_finish("late-host")


func _run_latecomer() -> void:
	var code: String = await _wait_for_code()
	if code.is_empty():
		_fail("host never published a code")
		return

	_demo._current.join_requested.emit(code, "late-guest")
	if not await _wait_until(func() -> bool: return Melay.is_in_room()):
		_fail("never joined")
		return

	# The host should push us into the game without us readying up at all.
	if not await _wait_until(func() -> bool: return _demo._screen == MelayDemo.Screen.GAME):
		_fail("stayed in the lobby, the host never started us")
		return
	_require(_demo._current.player_count() >= 1, "arena has no players")
	_finish("late-guest")


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
	print("[latejoin] FAIL %s" % message)


func _watchdog() -> void:
	await get_tree().create_timer(TIMEOUT_SECONDS).timeout
	_fail("timed out")
	_finish("latejoin")


func _finish(role: String) -> void:
	if _failures.is_empty():
		print("[%s] ALL CHECKS PASSED" % role)
		get_tree().quit(0)
		return
	get_tree().quit(1)
