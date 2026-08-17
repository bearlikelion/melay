extends Node

## Checks on the arena's 3D physics. No relay and no networking, so this runs standalone.
## The bodies are real, so every check steps the physics server and watches what Jolt did.

const GAME_SCENE: PackedScene = preload("res://game/screens/game_screen.tscn")

const MAX_STEPS: int = 150

## Long enough to drive a paddle the whole length of its travel, then to sit on the end
## of it and see whether it stays put.
const TRAVEL_STEPS: int = 60
const HOLD_STEPS: int = 20

## Counted out rather than waited for, so this one is only a loop bound.
const COUNTDOWN_STEPS: int = 300

var _failures: Array[String] = []
var _screen: GameScreen = null


func _ready() -> void:
	await _run()

	if _failures.is_empty():
		print("[ball] ALL CHECKS PASSED")
		get_tree().quit(0)
		return
	print("[ball] %d CHECK(S) FAILED" % _failures.size())
	get_tree().quit(1)


func _run() -> void:
	await _make_screen()
	await _check_wall_bounce()

	await _make_screen()
	await _check_paddle_bounce()

	await _make_screen()
	await _check_speed_cap()

	await _make_screen()
	await _check_paddle_stays_square()

	await _make_screen()
	await _check_paddle_stops_flush()

	await _make_screen()
	_check_countdown_holds_play()

	await _make_screen()
	_check_spawn_points()

	await _make_screen()
	await _check_guest_predicts_own_bounce()

	await _make_screen()
	await _check_stale_state_does_not_undo_prediction()

	await _make_screen()
	await _check_flight_time_extrapolation()


## Builds a host-side arena with one player, already past the countdown. Each check gets
## a fresh one, and its own World3D with it, so nothing leaks between them.
func _make_screen() -> void:
	if _screen != null:
		_screen.queue_free()
		_screen = null
		await get_tree().process_frame

	var info: MelayPeerInfo = MelayPeerInfo.new()
	info.peer_id = 1
	info.display_name = "tester"
	info.is_host = true

	var room: MelayRoom = MelayRoom.new()
	room.code = "TEST00"
	room.self_peer_id = 1
	room.host_peer_id = 1
	room.peers[1] = info

	_screen = GAME_SCENE.instantiate()
	add_child(_screen)
	_screen.setup(room)
	_screen.begin_countdown(0.0)
	await get_tree().physics_frame


func _check_wall_bounce() -> void:
	await _place_ball(Vector3(0.0, 4.0, 0.0), Vector3(4.0, 8.0, 0.0))
	var speed_before: float = _ball().linear_velocity.length()

	for i: int in MAX_STEPS:
		await get_tree().physics_frame
		if _ball().linear_velocity.y >= 0.0:
			continue

		_pass("ball reflected off the top wall")
		if absf(_ball().linear_velocity.length() - speed_before) > 0.2:
			_fail("a wall bounce changed the speed (%.2f, was %.2f)" % [
				_ball().linear_velocity.length(), speed_before,
			])
		return
	_fail("ball never reflected off the top wall")


func _check_paddle_bounce() -> void:
	var paddle: DemoPlayer = _screen._players[1]
	await _place_ball(Vector3(5.0, 0.0, 0.0), Vector3(9.0, 0.0, 0.0))
	var speed_before: float = _ball().linear_velocity.length()

	for i: int in MAX_STEPS:
		await get_tree().physics_frame
		if _ball().linear_velocity.x >= 0.0:
			continue

		_pass("ball reflected off the paddle")
		if _ball().position.x > paddle.position.x:
			_fail("ball was left on the far side of the paddle")
		if absf(_ball().linear_velocity.y) > 0.2:
			_fail("a square-on hit came back angled (%.2f)" % _ball().linear_velocity.y)

		var wanted: float = speed_before * DemoBall.SPEEDUP
		if absf(_ball().linear_velocity.length() - wanted) > 0.5:
			_fail("hit did not wind the rally up (%.2f, want %.2f)" % [
				_ball().linear_velocity.length(), wanted,
			])
		return
	_fail("ball passed straight through the paddle")


func _check_speed_cap() -> void:
	await _place_ball(Vector3(0.0, 0.0, 0.0), Vector3(DemoBall.MAX_SPEED * 6.0, 0.0, 0.0))

	for i: int in MAX_STEPS:
		await get_tree().physics_frame
		if _ball().linear_velocity.length() > DemoBall.MAX_SPEED + 1.0:
			_fail("ball speed %.1f exceeded the cap" % _ball().linear_velocity.length())
			return
	_pass("ball speed stayed under the cap through several bounces")


# Straight shots for now, so even a hit near the end of a paddle must leave it square
# and send the ball back along the line it came in on.
func _check_paddle_stays_square() -> void:
	var paddle: DemoPlayer = _screen._players[1]
	await _place_ball(Vector3(5.0, 0.9, 0.0), Vector3(9.0, 0.0, 0.0))

	for i: int in MAX_STEPS:
		await get_tree().physics_frame
		if _ball().linear_velocity.x >= 0.0:
			continue

		if absf(paddle.rotation.z) > 0.001:
			_fail("an off-centre hit turned the paddle (%.3f rad)" % paddle.rotation.z)
			return
		if absf(_ball().linear_velocity.y) > 0.2:
			_fail("an off-centre hit angled the return (%.2f)" % _ball().linear_velocity.y)
			return
		_pass("off-centre hit came straight back off a square paddle")
		return
	_fail("ball never reached the paddle")


# Holding into the end of the travel must stop the paddle dead, not have it push into
# the clamp and be shoved back out every step, which reads as jitter.
func _check_paddle_stops_flush() -> void:
	_ball().freeze = true
	var paddle: DemoPlayer = _screen._players[1]

	Input.action_press("melay_move_up")
	for i: int in TRAVEL_STEPS:
		await get_tree().physics_frame
	var settled: float = paddle.position.y

	for i: int in HOLD_STEPS:
		await get_tree().physics_frame
	Input.action_release("melay_move_up")

	if absf(settled - DemoPlayer.TRAVEL_LIMIT) > 0.02:
		_fail("paddle stopped at %.3f, want %.2f" % [settled, DemoPlayer.TRAVEL_LIMIT])
		return
	if absf(paddle.linear_velocity.y) > 0.01:
		_fail("paddle still pushing at the end of its travel (%.2f)" % paddle.linear_velocity.y)
		return
	if absf(paddle.position.y - settled) > 0.001:
		_fail("paddle drifted at the end of its travel (%.4f)" % (paddle.position.y - settled))
		return
	_pass("paddle stops flush against the end of its travel")


func _check_countdown_holds_play() -> void:
	_screen.begin_countdown(3.0)

	if _screen.is_running():
		_fail("play started during the countdown")
		return
	if _screen._players[1].movement_enabled:
		_fail("players could move during the countdown")
		return

	# Run the clock out and confirm it releases.
	for i: int in COUNTDOWN_STEPS:
		_screen._tick_countdown(1.0 / 60.0)
		if _screen.is_running():
			break

	if not _screen.is_running():
		_fail("countdown never released play")
		return
	if not _screen._players[1].movement_enabled:
		_fail("players stayed frozen after the countdown")
		return
	_pass("countdown holds play then releases it")


func _check_spawn_points() -> void:
	var second: MelayPeerInfo = MelayPeerInfo.new()
	second.peer_id = 2
	second.display_name = "other"
	_screen.spawn_player(second)

	var one: DemoPlayer = _screen._players[1]
	var two: DemoPlayer = _screen._players[2]

	if absf(one.position.y) > 0.01 or absf(two.position.y) > 0.01:
		_fail("paddles did not start vertically centred (%.2f, %.2f)" % [
			one.position.y, two.position.y,
		])
		return
	if signf(one.position.x) == signf(two.position.x):
		_fail("both paddles started on the same side of the arena")
		return
	_pass("paddles start centred on opposite sides")


# A guest bounces off its own paddle without waiting for the host to confirm the hit.
func _check_guest_predicts_own_bounce() -> void:
	_screen._is_host = false
	_screen.apply_ball(Vector3(5.0, 0.0, 0.0), Vector3(9.0, 0.0, 0.0), 0.0)

	for i: int in MAX_STEPS:
		await get_tree().physics_frame
		if _ball().linear_velocity.x < 0.0:
			_pass("guest predicted a bounce off its own paddle")
			return
	_fail("guest waited on the host and let the ball through its paddle")


# The host cannot have seen a bounce it had not been told about yet, so a state older
# than the prediction is stale and must not undo it.
func _check_stale_state_does_not_undo_prediction() -> void:
	_screen._is_host = false
	_screen.apply_ball(Vector3(5.0, 0.0, 0.0), Vector3(9.0, 0.0, 0.0), 0.0)

	for i: int in MAX_STEPS:
		await get_tree().physics_frame
		if _ball().linear_velocity.x < 0.0:
			break
	if _ball().linear_velocity.x >= 0.0:
		_fail("guest never predicted a bounce to begin with")
		return

	var stale: float = _screen._since_prediction + 0.5
	_screen.apply_ball(Vector3(5.5, 0.0, 0.0), Vector3(9.0, 0.0, 0.0), stale)
	await get_tree().physics_frame
	if _ball().linear_velocity.x > 0.0:
		_fail("a stale host state undid the predicted bounce")
		return

	# Sent after the bounce, so this one is authoritative and has to land.
	_screen.apply_ball(Vector3(4.0, 0.0, 0.0), Vector3(-9.0, 0.0, 0.0), 0.0)
	await get_tree().physics_frame
	if _ball().linear_velocity.x > -1.0:
		_fail("a fresh host state was rejected after the prediction")
		return
	_pass("stale states are ignored and fresh ones still land")


# A state that spent time in flight is stale, so it has to be rolled forward on arrival.
func _check_flight_time_extrapolation() -> void:
	_screen._is_host = false
	await _place_ball(Vector3(-5.0, 0.0, 0.0), Vector3.ZERO)

	var sent_at: Vector3 = Vector3(2.0, 0.0, 0.0)
	var velocity: Vector3 = Vector3(10.0, 0.0, 0.0)
	_screen.apply_ball(sent_at, velocity, 0.1)
	await get_tree().physics_frame

	var expected: float = sent_at.x + velocity.x * 0.1
	if absf(_ball().position.x - expected) > 0.3:
		_fail("state was not rolled forward (%.2f, want %.2f)" % [
			_ball().position.x, expected,
		])
		return
	_pass("host state is rolled forward by its flight time")


func _ball() -> DemoBall:
	return _screen._ball


func _place_ball(at: Vector3, velocity: Vector3) -> void:
	_ball().freeze = false
	_ball().teleport(at, velocity)
	await get_tree().physics_frame


func _pass(message: String) -> void:
	print("[ball] ok: %s" % message)


func _fail(message: String) -> void:
	_failures.append(message)
	print("[ball] FAIL %s" % message)
