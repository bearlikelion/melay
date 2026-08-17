extends Node

## Deterministic checks on the arena's ball physics. No relay and no networking, so
## this runs standalone and fails loudly rather than flakily.

const GAME_SCENE: PackedScene = preload("res://game/screens/game_screen.tscn")

const STEP: float = 1.0 / 60.0
const MAX_STEPS: int = 240

var _failures: Array[String] = []


func _ready() -> void:
	await _run()

	if _failures.is_empty():
		print("[ball] ALL CHECKS PASSED")
		get_tree().quit(0)
		return
	print("[ball] %d CHECK(S) FAILED" % _failures.size())
	get_tree().quit(1)


func _run() -> void:
	var screen: GameScreen = await _make_screen()
	_check_wall_bounce(screen)

	screen = await _make_screen()
	_check_player_bounce(screen)

	screen = await _make_screen()
	_check_speed_cap(screen)

	screen = await _make_screen()
	_check_countdown_holds_play(screen)

	screen = await _make_screen()
	_check_spawn_points(screen)

	screen = await _make_screen()
	_check_guest_predicts_own_bounce(screen)

	screen = await _make_screen()
	_check_stale_state_does_not_undo_prediction(screen)

	screen = await _make_screen()
	_check_flight_time_extrapolation(screen)


## Builds a host-side arena with one player, already past the countdown.
func _make_screen() -> GameScreen:
	var screen: GameScreen = GAME_SCENE.instantiate()
	add_child(screen)

	var info: MelayPeerInfo = MelayPeerInfo.new()
	info.peer_id = 1
	info.display_name = "tester"
	info.is_host = true

	var room: MelayRoom = MelayRoom.new()
	room.code = "TEST00"
	room.self_peer_id = 1
	room.host_peer_id = 1
	room.peers[1] = info

	screen.setup(room)
	screen.begin_countdown(0.0)
	await get_tree().process_frame
	return screen


func _check_wall_bounce(screen: GameScreen) -> void:
	screen._players[1].position = Vector2(600.0, 600.0)
	screen._ball_target = Vector2(4.0, 200.0)
	screen._ball_velocity = Vector2(-200.0, 0.0)

	for i: int in MAX_STEPS:
		screen._simulate_ball(STEP)
		if screen._ball_velocity.x > 0.0:
			_pass("ball reflected off the left wall")
			return
	_fail("ball never reflected off the left wall")


func _check_player_bounce(screen: GameScreen) -> void:
	var player: DemoPlayer = screen._players[1]
	player.position = Vector2(300.0, 300.0)

	# Approaching the player's left face, vertically overlapping it.
	screen._ball_target = Vector2(260.0, 310.0)
	screen._ball_velocity = Vector2(220.0, 0.0)
	var speed_before: float = screen._ball_velocity.length()

	for i: int in MAX_STEPS:
		screen._simulate_ball(STEP)
		if screen._ball_velocity.x < 0.0:
			_pass("ball reflected off the player")
			if screen._ball_velocity.length() <= speed_before:
				_fail("bounce did not speed the ball up")
			if screen._ball.position.x + screen._ball.size.x > player.position.x + 1.0:
				_fail("ball was left overlapping the player after the bounce")
			return
	_fail("ball passed straight through the player")


func _check_speed_cap(screen: GameScreen) -> void:
	var player: DemoPlayer = screen._players[1]
	player.position = Vector2(300.0, 300.0)
	screen._ball_target = Vector2(260.0, 310.0)
	screen._ball_velocity = Vector2(GameScreen.BALL_MAX_SPEED * 4.0, 0.0)

	for i: int in MAX_STEPS:
		screen._simulate_ball(STEP)
		if screen._ball_velocity.x < 0.0:
			break

	if screen._ball_velocity.length() > GameScreen.BALL_MAX_SPEED + 1.0:
		_fail("ball speed %.1f exceeded the cap" % screen._ball_velocity.length())
		return
	_pass("ball speed stayed under the cap")


func _check_countdown_holds_play(screen: GameScreen) -> void:
	screen.begin_countdown(3.0)

	if screen.is_running():
		_fail("play started during the countdown")
		return
	if screen._players[1].movement_enabled:
		_fail("players could move during the countdown")
		return

	# Run the clock out and confirm it releases.
	for i: int in MAX_STEPS:
		screen._tick_countdown(STEP)
		if screen.is_running():
			break

	if not screen.is_running():
		_fail("countdown never released play")
		return
	if not screen._players[1].movement_enabled:
		_fail("players stayed frozen after the countdown")
		return
	_pass("countdown holds play then releases it")


func _check_spawn_points(screen: GameScreen) -> void:
	var second: MelayPeerInfo = MelayPeerInfo.new()
	second.peer_id = 2
	second.display_name = "other"
	screen.spawn_player(second)

	var one: DemoPlayer = screen._players[1]
	var two: DemoPlayer = screen._players[2]
	var field: Vector2 = screen._playfield.size
	var centre_x: float = (field.x - DemoPlayer.SIZE.x) * 0.5

	if absf(one.position.x - centre_x) > 1.0 or absf(two.position.x - centre_x) > 1.0:
		_fail("paddles did not start horizontally centred (%.1f, %.1f, want %.1f)" % [
			one.position.x, two.position.x, centre_x,
		])
		return
	if signf(one.position.y - field.y * 0.5) == signf(two.position.y - field.y * 0.5):
		_fail("both paddles started on the same side of the field")
		return
	_pass("paddles start centred on opposite sides")


# A guest bounces off its own paddle without waiting for the host to confirm the hit.
func _check_guest_predicts_own_bounce(screen: GameScreen) -> void:
	screen._is_host = false
	var player: DemoPlayer = screen._players[1]
	player.position = Vector2(300.0, 300.0)

	screen.apply_ball(Vector2(260.0, 310.0), Vector2(220.0, 0.0), 0.0)

	for i: int in MAX_STEPS:
		screen._predict_ball(STEP)
		if screen._ball_velocity.x < 0.0:
			_pass("guest predicted a bounce off its own paddle")
			return
	_fail("guest waited on the host and let the ball through its paddle")


# The host cannot have seen a bounce it had not been told about yet, so a state older
# than the prediction is stale and must not undo it.
func _check_stale_state_does_not_undo_prediction(screen: GameScreen) -> void:
	screen._is_host = false
	screen._players[1].position = Vector2(300.0, 300.0)

	screen.apply_ball(Vector2(260.0, 310.0), Vector2(220.0, 0.0), 0.0)
	for i: int in MAX_STEPS:
		screen._predict_ball(STEP)
		if screen._ball_velocity.x < 0.0:
			break
	if screen._ball_velocity.x >= 0.0:
		_fail("guest never predicted a bounce to begin with")
		return

	screen.apply_ball(Vector2(280.0, 310.0), Vector2(220.0, 0.0), 0.1)
	if screen._ball_velocity.x > 0.0:
		_fail("a stale host state undid the predicted bounce")
		return

	# Sent after the bounce, so this one is authoritative and has to land.
	screen.apply_ball(Vector2(240.0, 310.0), Vector2(-190.0, 0.0), 0.0)
	if absf(screen._ball_velocity.x + 190.0) > 1.0:
		_fail("a fresh host state was rejected after the prediction")
		return
	_pass("stale states are ignored and fresh ones still land")


# A state that spent time in flight is stale, so it has to be rolled forward on arrival.
func _check_flight_time_extrapolation(screen: GameScreen) -> void:
	screen._is_host = false
	screen._players[1].position = Vector2(600.0, 600.0)

	var sent_at: Vector2 = Vector2(200.0, 200.0)
	var velocity: Vector2 = Vector2(400.0, 0.0)
	screen.apply_ball(sent_at, velocity, 0.1)

	var expected: float = sent_at.x + velocity.x * 0.1
	if absf(screen._ball_target.x - expected) > 1.0:
		_fail("state was not rolled forward (%.1f, want %.1f)" % [
			screen._ball_target.x, expected,
		])
		return
	_pass("host state is rolled forward by its flight time")


func _pass(message: String) -> void:
	print("[ball] ok: %s" % message)


func _fail(message: String) -> void:
	_failures.append(message)
	print("[ball] FAIL %s" % message)
