class_name GameScreen
extends Control

## The arena: a Jolt world in a SubViewport, seen straight on through an orthogonal
## camera with the z axis locked out of every body, so it plays flat but collides for
## real. Paddles sit left and right and the ball crosses between them.
##
## Every peer simulates the whole arena. The host is the one that counts: it broadcasts
## the ball 20 times a second and on every contact, and the others fold those states into
## their own simulation rather than replacing it, so a hit off your own paddle lands
## straight away instead of a round trip late.

signal leave_requested
signal ball_synced(to: Vector3, velocity: Vector3)

const PLAYER_SCENE: PackedScene = preload("res://game/demo_player.tscn")

## Half the playable area, measured to the inner face of the walls.
const ARENA_HALF_X: float = 9.5
const ARENA_HALF_Y: float = 4.5
const BALL_HALF: float = 0.25

## Distance from the centre line to the first paddle lane, and how much deeper each
## extra player on the same side sits.
const LANE_X: float = 8.3
const LANE_STEP: float = 1.1

## Routine updates go out 20 times a second; contacts go out immediately.
const BALL_SEND_INTERVAL: float = 0.05

## Older than this and the stream stalled, so rolling the state that far forward would
## be guesswork rather than a correction.
const BALL_MAX_EXTRAPOLATION: float = 0.25

## How long "GO" stays up after the countdown reaches zero.
const GO_LINGER: float = 0.6

@onready var _paddles: Node3D = %Paddles
@onready var _ball: DemoBall = %Ball
@onready var _room_label: Label = %RoomLabel
@onready var _stats_label: Label = %StatsLabel
@onready var _leave_button: Button = %LeaveButton
@onready var _countdown_label: Label = %CountdownLabel

var _players: Dictionary = {}
var _is_host: bool = false
var _self_peer_id: int = 0
var _active: bool = false
var _ball_send_elapsed: float = 0.0
var _ball_updates: int = 0

## Seconds since this peer bounced the ball off its own paddle without the host having
## confirmed it yet. Negative when nothing is outstanding.
var _since_prediction: float = -1.0
var _countdown_left: float = 0.0
var _running: bool = false


func _ready() -> void:
	_leave_button.pressed.connect(leave_requested.emit)
	_ball.bounced.connect(_on_ball_bounced)


func _process(delta: float) -> void:
	if not _active:
		return
	_tick_countdown(delta)


func _physics_process(delta: float) -> void:
	if not _active or not _running:
		return

	if not _is_host:
		if _since_prediction >= 0.0:
			_since_prediction += delta
		return

	_ball_send_elapsed += delta
	if _ball_send_elapsed >= BALL_SEND_INTERVAL:
		_send_ball()


func setup(room: MelayRoom) -> void:
	if room == null:
		return

	_is_host = room.is_host()
	_self_peer_id = room.self_peer_id

	# A guest's ball is corrected onto a new line each time a state lands, not simulated
	# from its own input, so it is the one worth interpolating.
	if _is_host:
		_ball.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	else:
		_ball.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_ON

	_room_label.text = "Room %s   you are peer %d%s" % [
		room.code, room.self_peer_id, "   host" if _is_host else "",
	]
	for peer_id: int in room.peers:
		spawn_player(room.get_peer(peer_id))

	_active = true


func spawn_player(info: MelayPeerInfo) -> void:
	if info == null or _players.has(info.peer_id):
		return

	var player: DemoPlayer = PLAYER_SCENE.instantiate()
	# Named before entering the tree so the path matches on every peer, or RPCs miss.
	player.name = "Player%d" % info.peer_id
	_paddles.add_child(player)
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
	_apply_countdown_label()
	_set_running(_countdown_left <= 0.0)


func is_running() -> bool:
	return _running


func player_count() -> int:
	return _players.size()


func set_stats(text: String) -> void:
	_stats_label.text = text


## Applies an authoritative ball state from the host. Only non-hosts ever receive one.
## The age is how long the state spent in flight, rolled forward here so the ball is not
## a whole latency behind the arena the host is simulating.
func apply_ball(to: Vector3, velocity: Vector3, age: float) -> void:
	_ball_updates += 1
	# Older than the bounce this peer already predicted, so it describes a world that no
	# longer exists and would only undo the prediction.
	if _since_prediction >= 0.0 and age > _since_prediction:
		return

	_since_prediction = -1.0
	var rolled: float = clampf(age, 0.0, BALL_MAX_EXTRAPOLATION)
	# The host is the only one that serves, so its first state is what starts a guest.
	_ball.freeze = false
	_ball.correct(_clamp_to_arena(to + velocity * rolled), velocity)


func get_ball_position() -> Vector3:
	return _ball.position


## Number of authoritative updates received, so tests can tell prediction apart from
## packets actually arriving.
func get_ball_update_count() -> int:
	return _ball_updates


func _on_ball_bounced(against: Node) -> void:
	if not _running:
		return

	var player: DemoPlayer = against as DemoPlayer
	if player != null:
		_ball.speed_up()

	if _is_host:
		_send_ball()
		return

	# Waiting for the host to confirm a hit costs a round trip, and this peer already
	# knows its own paddle exactly, so the local bounce stands until told otherwise.
	if player != null and player.peer_id == _self_peer_id:
		_since_prediction = 0.0


func _send_ball() -> void:
	_ball_send_elapsed = 0.0
	ball_synced.emit(_ball.position, _ball.linear_velocity)


func _tick_countdown(delta: float) -> void:
	if _countdown_left <= -GO_LINGER:
		return

	_countdown_left -= delta
	_set_running(_countdown_left <= 0.0)
	_apply_countdown_label()


func _set_running(running: bool) -> void:
	if running == _running:
		return

	_running = running
	_set_players_movable(running)
	if not running:
		_ball.freeze = true
		return
	# Only the host serves; a guest's ball waits for the first state it is sent.
	if _is_host:
		_ball.freeze = false
		_ball.serve()


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


# A rolled-forward state ignores the walls, so keep it off them rather than let Jolt
# resolve a correction that landed inside one.
func _clamp_to_arena(to: Vector3) -> Vector3:
	return Vector3(
		clampf(to.x, -ARENA_HALF_X + BALL_HALF, ARENA_HALF_X - BALL_HALF),
		clampf(to.y, -ARENA_HALF_Y + BALL_HALF, ARENA_HALF_Y - BALL_HALF),
		0.0
	)


# Players alternate sides, and each extra pair sits a lane deeper into its own half.
func _spawn_point(peer_id: int) -> Vector3:
	var slot: int = absi(peer_id) % 8
	var side: float = -1.0 if slot % 2 == 0 else 1.0
	return Vector3(side * (LANE_X - float(slot / 2) * LANE_STEP), 0.0, 0.0)
