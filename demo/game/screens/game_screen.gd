class_name GameScreen
extends Control

## The arena. Every player drives their own paddle; the host alone simulates the ball
## and reports its state upward so the main scene can broadcast it.
##
## Non-host peers do not just apply what arrives. Each state is rolled forward by the
## time it spent in flight, dead-reckoned between updates, and bounced off the peer's
## own paddle straight away, so 20 updates a second still look like continuous motion
## and a hit lands flush instead of a round trip late.

signal leave_requested
signal ball_synced(to: Vector2, velocity: Vector2)

const PLAYER_SCENE: PackedScene = preload("res://game/demo_player.tscn")

## Starts gentle and creeps up on every bounce, so a long rally gets harder.
const BALL_SPEED: float = 150.0
const BALL_MAX_SPEED: float = 430.0
const BALL_SPEEDUP: float = 1.025

## Routine updates go out 20 times a second; bounces go out immediately.
const BALL_SEND_INTERVAL: float = 0.05

const BALL_SMOOTHING: float = 18.0

## Past this much error a correction is a teleport, not a nudge, so stop easing.
const BALL_SNAP_DISTANCE: float = 120.0

## Older than this and the stream stalled, so rolling the state that far forward would
## be guesswork rather than a correction.
const BALL_MAX_EXTRAPOLATION: float = 0.25

## How much an off-centre hit angles the return, as a fraction of the serve speed.
const SPIN_INFLUENCE: float = 0.5

## How long "GO" stays up after the countdown reaches zero.
const GO_LINGER: float = 0.6

@onready var _playfield: Control = %Playfield
@onready var _ball: ColorRect = %Ball
@onready var _room_label: Label = %RoomLabel
@onready var _stats_label: Label = %StatsLabel
@onready var _leave_button: Button = %LeaveButton
@onready var _countdown_label: Label = %CountdownLabel

var _players: Dictionary = {}
var _is_host: bool = false
var _self_peer_id: int = 0
var _active: bool = false
var _ball_velocity: Vector2 = Vector2.ZERO

## Where the ball actually is: the host's simulation, or a non-host's belief about it.
## [code]_ball.position[/code] is only the drawn value easing towards this.
var _ball_target: Vector2 = Vector2.ZERO
var _ball_send_elapsed: float = 0.0
var _ball_updates: int = 0

## Seconds since this peer bounced the ball off its own paddle without the host having
## confirmed it yet. Negative when nothing is outstanding.
var _since_prediction: float = -1.0
var _countdown_left: float = 0.0
var _running: bool = false


func _ready() -> void:
	_leave_button.pressed.connect(leave_requested.emit)


func _process(delta: float) -> void:
	if not _active:
		return
	_tick_countdown(delta)
	if _running and not _is_host:
		_draw_ball(delta)


# Stepped at a fixed rate, so a dropped frame cannot hand the ball a delta large enough
# to carry it clean through a paddle.
func _physics_process(delta: float) -> void:
	if not _active or not _running:
		return
	if _is_host:
		_simulate_ball(delta)
	else:
		_predict_ball(delta)


func setup(room: MelayRoom) -> void:
	if room == null:
		return

	_is_host = room.is_host()
	_self_peer_id = room.self_peer_id
	_room_label.text = "Room %s   you are peer %d%s" % [
		room.code, room.self_peer_id, "   host" if _is_host else "",
	]
	for peer_id: int in room.peers:
		spawn_player(room.get_peer(peer_id))

	if _is_host:
		_reset_ball()
	_active = true


func spawn_player(info: MelayPeerInfo) -> void:
	if info == null or _players.has(info.peer_id):
		return

	var player: DemoPlayer = PLAYER_SCENE.instantiate()
	# Named before entering the tree so the path matches on every peer, or RPCs miss.
	player.name = "Player%d" % info.peer_id
	_playfield.add_child(player)
	player.setup(info.peer_id, info.display_name, info.is_host)
	player.teleport(_spawn_point(info.peer_id))
	player.movement_enabled = _running
	_players[info.peer_id] = player


func despawn_player(peer_id: int) -> void:
	var player: DemoPlayer = _players.get(peer_id, null)
	if player != null and is_instance_valid(player):
		player.queue_free()
	_players.erase(peer_id)


## Starts the pre-match countdown. The caller works the duration out from the relay
## clock, so every peer reaches zero together rather than counting independently.
func begin_countdown(seconds: float) -> void:
	_countdown_left = maxf(seconds, 0.0)
	_running = _countdown_left <= 0.0
	_apply_countdown_label()
	_set_players_movable(_running)


func is_running() -> bool:
	return _running


func player_count() -> int:
	return _players.size()


func set_stats(text: String) -> void:
	_stats_label.text = text


## Applies an authoritative ball state from the host. Only non-hosts ever receive one.
## The age is how long the state spent in flight, rolled forward here so the drawn ball
## is not a whole latency behind the arena the host is simulating.
func apply_ball(to: Vector2, velocity: Vector2, age: float) -> void:
	_ball_updates += 1
	# Older than the bounce this peer already predicted, so it describes a world that no
	# longer exists and would only undo the prediction.
	if _since_prediction >= 0.0 and age > _since_prediction:
		return

	_since_prediction = -1.0
	_ball_velocity = velocity
	_ball_target = _advance_target(to, clampf(age, 0.0, BALL_MAX_EXTRAPOLATION))


func get_ball_position() -> Vector2:
	return _ball.position


## Number of authoritative updates received, so tests can tell prediction apart from
## packets actually arriving.
func get_ball_update_count() -> int:
	return _ball_updates


func _tick_countdown(delta: float) -> void:
	if _countdown_left <= -GO_LINGER:
		return

	var was_running: bool = _running
	_countdown_left -= delta
	_running = _countdown_left <= 0.0

	if _running and not was_running:
		_set_players_movable(true)
	_apply_countdown_label()


func _apply_countdown_label() -> void:
	if _countdown_left > 0.0:
		_countdown_label.text = str(ceili(_countdown_left))
		_countdown_label.visible = true
		return
	if _countdown_left > -GO_LINGER:
		_countdown_label.text = "GO"
		_countdown_label.visible = true
		return
	_countdown_label.visible = false


func _set_players_movable(movable: bool) -> void:
	for peer_id: int in _players:
		var player: DemoPlayer = _players[peer_id]
		if is_instance_valid(player):
			player.movement_enabled = movable


func _simulate_ball(delta: float) -> void:
	var bounds: Vector2 = _playfield.size - _ball.size
	if bounds.x <= 0.0 or bounds.y <= 0.0:
		return

	var before: Vector2 = _ball_velocity
	_ball_target = _advance_target(_ball_target, delta)
	var bounced: bool = _ball_velocity != before

	if _bounce_off_players():
		bounced = true
	if bounced:
		_apply_speedup()
	_ball.position = _ball_target

	_ball_send_elapsed += delta
	# A bounce is what prediction cannot guess, so it skips the interval.
	if bounced or _ball_send_elapsed >= BALL_SEND_INTERVAL:
		_ball_send_elapsed = 0.0
		ball_synced.emit(_ball_target, _ball_velocity)


# Steps a position forward, reflecting off the walls the way the host's simulation does.
func _advance_target(from: Vector2, delta: float) -> Vector2:
	var bounds: Vector2 = _playfield.size - _ball.size
	if bounds.x <= 0.0 or bounds.y <= 0.0:
		return from

	var to: Vector2 = from + _ball_velocity * delta
	if to.x <= 0.0 or to.x >= bounds.x:
		_ball_velocity.x = -_ball_velocity.x
	if to.y <= 0.0 or to.y >= bounds.y:
		_ball_velocity.y = -_ball_velocity.y
	return to.clamp(Vector2.ZERO, bounds)


func _apply_speedup() -> void:
	var speed: float = minf(_ball_velocity.length() * BALL_SPEEDUP, BALL_MAX_SPEED)
	_ball_velocity = _ball_velocity.normalized() * speed


func _bounce_off_players() -> bool:
	for peer_id: int in _players:
		if _reflect_off_paddle(_players[peer_id]):
			return true
	return false


# Waiting for the host to confirm a hit costs a round trip, and this peer already knows
# its own paddle exactly, so bounce now and let the next update settle any disagreement.
func _predict_own_bounce() -> void:
	var player: DemoPlayer = _players.get(_self_peer_id, null)
	if player != null and _reflect_off_paddle(player):
		_apply_speedup()
		_since_prediction = 0.0


# A circle against an axis-aligned box, resolved out along the shallowest escape.
func _reflect_off_paddle(player: DemoPlayer) -> bool:
	if not is_instance_valid(player):
		return false

	var radius: float = _ball.size.x * 0.5
	var centre: Vector2 = _ball_target + _ball.size * 0.5
	var paddle_centre: Vector2 = player.centre()
	var half: Vector2 = DemoPlayer.SIZE * 0.5

	var local: Vector2 = centre - paddle_centre
	var closest: Vector2 = local.clamp(-half, half)
	var offset: Vector2 = local - closest

	var normal: Vector2
	if offset.length_squared() > 0.0001:
		if offset.length() > radius:
			return false
		normal = offset.normalized()
	else:
		# The centre is inside the paddle, so escape along the shallowest axis.
		var gap: Vector2 = half - local.abs()
		if gap.x < gap.y:
			normal = Vector2(signf(local.x), 0.0)
		else:
			normal = Vector2(0.0, signf(local.y))
		if normal == Vector2.ZERO:
			normal = Vector2.UP

	if _ball_velocity.dot(normal) < 0.0:
		_ball_velocity = _ball_velocity.bounce(normal)
	# A hit away from the middle angles the return along the paddle's length.
	_ball_velocity.x += (local.x / half.x) * BALL_SPEED * SPIN_INFLUENCE

	_ball_target = paddle_centre + closest + normal * radius - _ball.size * 0.5
	return true


# Dead-reckons between the host's updates, bouncing off this peer's own paddle as it goes.
func _predict_ball(delta: float) -> void:
	if _since_prediction >= 0.0:
		_since_prediction += delta
	_ball_target = _advance_target(_ball_target, delta)
	_predict_own_bounce()


# The simulation steps at a fixed rate, so the drawn ball eases between those steps.
func _draw_ball(delta: float) -> void:
	if _ball.position.distance_to(_ball_target) > BALL_SNAP_DISTANCE:
		_ball.position = _ball_target
		return
	_ball.position = _ball.position.lerp(
		_ball_target, clampf(BALL_SMOOTHING * delta, 0.0, 1.0)
	)


func _reset_ball() -> void:
	_ball_target = (_playfield.size - _ball.size) * 0.5
	_ball.position = _ball_target

	# Served towards a paddle, so a rally starts instead of a drift along a wall.
	var direction: Vector2 = Vector2.DOWN.rotated(randf_range(-PI / 4.0, PI / 4.0))
	if randf() < 0.5:
		direction = -direction
	_ball_velocity = direction * BALL_SPEED


# First player on each side starts dead centre; later ones fan out alternately.
func _spawn_point(peer_id: int) -> Vector2:
	var slot: int = absi(peer_id) % 8
	var index_in_row: int = maxi(slot - 1, 0) / 2
	var side: float = 1.0 if index_in_row % 2 == 1 else -1.0
	var stagger: float = float((index_in_row + 1) / 2) * (DemoPlayer.SIZE.x + 16.0) * side

	var area: Vector2 = _playfield.size - DemoPlayer.SIZE
	return Vector2(
		clampf(area.x * 0.5 + stagger, 0.0, maxf(area.x, 0.0)),
		area.y * (0.82 if slot % 2 == 0 else 0.18)
	)
