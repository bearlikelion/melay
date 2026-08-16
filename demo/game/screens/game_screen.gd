class_name GameScreen
extends Control

## The arena. Every player drives their own paddle; the host alone simulates the ball
## and reports its state upward so the main scene can broadcast it.
##
## Non-host peers do not just apply what arrives. They dead-reckon the ball forward
## from the last known velocity and ease the drawn position onto that, so 20 updates
## a second still look like continuous motion.

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
var _active: bool = false
var _ball_velocity: Vector2 = Vector2.ZERO
var _ball_predicted: Vector2 = Vector2.ZERO
var _ball_send_elapsed: float = 0.0
var _ball_updates: int = 0
var _countdown_left: float = 0.0
var _running: bool = false


func _ready() -> void:
	_leave_button.pressed.connect(leave_requested.emit)


func _process(delta: float) -> void:
	if not _active:
		return

	if not _running:
		_tick_countdown(delta)
		return

	_tick_countdown(delta)
	if _is_host:
		_simulate_ball(delta)
	else:
		_follow_ball(delta)


func setup(room: MelayRoom) -> void:
	if room == null:
		return

	_is_host = room.is_host()
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
func apply_ball(to: Vector2, velocity: Vector2) -> void:
	_ball_predicted = to
	_ball_velocity = velocity
	_ball_updates += 1


func get_ball_position() -> Vector2:
	return _ball.position


## Number of authoritative updates applied, so tests can tell prediction apart from
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

	_ball.position += _ball_velocity * delta

	var bounced: bool = false
	if _ball.position.x <= 0.0 or _ball.position.x >= bounds.x:
		_ball_velocity.x = -_ball_velocity.x
		bounced = true
	if _ball.position.y <= 0.0 or _ball.position.y >= bounds.y:
		_ball_velocity.y = -_ball_velocity.y
		bounced = true
	_ball.position = _ball.position.clamp(Vector2.ZERO, bounds)

	if _bounce_off_players():
		bounced = true

	if bounced:
		_apply_speedup()

	_ball_send_elapsed += delta
	# A bounce is what prediction cannot guess, so it skips the interval.
	if bounced or _ball_send_elapsed >= BALL_SEND_INTERVAL:
		_ball_send_elapsed = 0.0
		ball_synced.emit(_ball.position, _ball_velocity)


func _apply_speedup() -> void:
	var speed: float = minf(_ball_velocity.length() * BALL_SPEEDUP, BALL_MAX_SPEED)
	_ball_velocity = _ball_velocity.normalized() * speed


func _bounce_off_players() -> bool:
	var radius: float = _ball.size.x * 0.5
	var centre: Vector2 = _ball.position + _ball.size * 0.5

	for peer_id: int in _players:
		var player: DemoPlayer = _players[peer_id]
		if not is_instance_valid(player):
			continue
		if _reflect_off_paddle(player, centre, radius):
			return true
	return false


# Paddles rotate, so this is a circle against an oriented box, solved in local space.
func _reflect_off_paddle(player: DemoPlayer, centre: Vector2, radius: float) -> bool:
	var angle: float = player.rotation
	var paddle_centre: Vector2 = player.centre()
	var half: Vector2 = DemoPlayer.SIZE * 0.5

	var local: Vector2 = (centre - paddle_centre).rotated(-angle)
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

	var velocity_local: Vector2 = _ball_velocity.rotated(-angle)
	if velocity_local.dot(normal) < 0.0:
		velocity_local = velocity_local.bounce(normal)
	# A hit away from the middle angles the return along the paddle's length.
	velocity_local.x += (local.x / half.x) * BALL_SPEED * SPIN_INFLUENCE

	_ball_velocity = velocity_local.rotated(angle)
	_ball.position = paddle_centre + (closest + normal * radius).rotated(angle) \
		- _ball.size * 0.5
	return true


# Dead-reckons between updates and eases onto the result, so corrections read as nudges.
func _follow_ball(delta: float) -> void:
	var bounds: Vector2 = _playfield.size - _ball.size
	if bounds.x <= 0.0 or bounds.y <= 0.0:
		return

	_ball_predicted += _ball_velocity * delta

	# Mirrors the host's wall reflection so the guess cannot run off the field.
	if _ball_predicted.x <= 0.0 or _ball_predicted.x >= bounds.x:
		_ball_velocity.x = -_ball_velocity.x
	if _ball_predicted.y <= 0.0 or _ball_predicted.y >= bounds.y:
		_ball_velocity.y = -_ball_velocity.y
	_ball_predicted = _ball_predicted.clamp(Vector2.ZERO, bounds)

	if _ball.position.distance_to(_ball_predicted) > BALL_SNAP_DISTANCE:
		_ball.position = _ball_predicted
		return
	_ball.position = _ball.position.lerp(
		_ball_predicted, clampf(BALL_SMOOTHING * delta, 0.0, 1.0)
	)


func _reset_ball() -> void:
	_ball.position = (_playfield.size - _ball.size) * 0.5
	_ball_predicted = _ball.position

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
