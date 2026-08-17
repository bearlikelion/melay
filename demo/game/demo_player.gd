class_name DemoPlayer
extends ColorRect

## One player's paddle. The owning peer drives it side to side from input and broadcasts
## its position; everyone else interpolates towards the last state they were told.

const SPEED: float = 320.0
const SIZE: Vector2 = Vector2(104.0, 22.0)

## State goes out 20 times a second rather than every frame, which is plenty for
## a demo and keeps the relay traffic readable in the logs.
const SEND_INTERVAL: float = 0.05

const SMOOTHING: float = 18.0

## Peers build their game screen a few milliseconds apart, so hold off broadcasting
## until they have all had a chance to spawn this node.
const START_GRACE: float = 0.4

const PALETTE: Array[Color] = [
	Color("5b8dee"),
	Color("f2696c"),
	Color("46c88d"),
	Color("f0a848"),
	Color("a97bea"),
	Color("3fb8c4"),
	Color("e06fb0"),
	Color("94a3b8"),
]

var peer_id: int = 0

## Held false during the pre-match countdown so nobody can move off their spawn.
var movement_enabled: bool = false

var _target_position: Vector2 = Vector2.ZERO
var _send_elapsed: float = 0.0
var _grace_left: float = START_GRACE

@onready var _name_label: Label = %NameLabel


func _ready() -> void:
	custom_minimum_size = SIZE
	size = SIZE
	_target_position = position


func _process(delta: float) -> void:
	if is_multiplayer_authority():
		return
	position = position.lerp(_target_position, clampf(SMOOTHING * delta, 0.0, 1.0))


# Driven at a fixed rate so the paddle the host collides against advances in step with
# the ball rather than at whatever the frame rate happens to be.
func _physics_process(delta: float) -> void:
	if movement_enabled and is_multiplayer_authority():
		_drive(delta)


## Called by the arena straight after add_child, so the label is already available.
## The node name is set by the caller before it enters the tree, because the state
## RPCs resolve by path and every peer has to agree on it.
func setup(p_peer_id: int, display_name: String, is_host: bool) -> void:
	peer_id = p_peer_id
	set_multiplayer_authority(p_peer_id)
	color = PALETTE[absi(p_peer_id) % PALETTE.size()]

	var label: String = display_name
	if label.is_empty():
		label = "Peer %d" % p_peer_id
	if is_host:
		label += " (host)"
	_name_label.text = label


func teleport(to: Vector2) -> void:
	position = to
	_target_position = to


## Centre of the paddle in its parent's space, which is what collision works against.
func centre() -> Vector2:
	return position + SIZE * 0.5


@rpc("authority", "unreliable_ordered", "call_remote")
func remote_state(to: Vector2) -> void:
	_target_position = to


func _drive(delta: float) -> void:
	var direction: float = Input.get_axis("melay_move_left", "melay_move_right")
	position.x += direction * SPEED * delta

	var bounds: Vector2 = get_parent_area_size() - SIZE
	position.x = clampf(position.x, 0.0, maxf(bounds.x, 0.0))

	if _grace_left > 0.0:
		_grace_left -= delta
		return

	_send_elapsed += delta
	if _send_elapsed < SEND_INTERVAL:
		return
	_send_elapsed = 0.0
	remote_state.rpc(position)
