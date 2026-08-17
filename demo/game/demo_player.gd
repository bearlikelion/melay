class_name DemoPlayer
extends RigidBody3D

## One player's paddle: a Jolt body left with one freedom, sliding along y, so every
## return comes straight back off a square face. The owning peer drives it and broadcasts
## where it got to; everyone else servos their own copy towards the last state they were
## told.

const SPEED: float = 8.0

## How far the centre may travel before the paddle would clip a wall.
const TRAVEL_LIMIT: float = 3.4

## How far the name sits from the paddle, and where it swaps to the other end.
const LABEL_OFFSET: float = 1.7
const LABEL_FLIP_AT: float = 1.5

## How hard a remote copy is pulled onto the state it was sent, in 1/s.
const FOLLOW_RATE: float = 16.0

## State goes out 20 times a second rather than every frame, which is plenty for
## a demo and keeps the relay traffic readable in the logs.
const SEND_INTERVAL: float = 0.05

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

var _lane_x: float = 0.0
var _target_y: float = 0.0
var _send_elapsed: float = 0.0
var _grace_left: float = START_GRACE

@onready var _mesh: MeshInstance3D = %Mesh
@onready var _name_label: Label3D = %NameLabel


func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	if is_multiplayer_authority():
		_drive(state)
	else:
		_follow(state)
	_confine(state)


func _process(_delta: float) -> void:
	# Swapped to whichever end of the paddle has room, so a name never rides up a wall.
	if position.y > LABEL_FLIP_AT:
		_name_label.position.y = -LABEL_OFFSET
	elif position.y < -LABEL_FLIP_AT:
		_name_label.position.y = LABEL_OFFSET


func _physics_process(delta: float) -> void:
	if not movement_enabled or not is_multiplayer_authority():
		return

	if _grace_left > 0.0:
		_grace_left -= delta
		return

	_send_elapsed += delta
	if _send_elapsed < SEND_INTERVAL:
		return
	_send_elapsed = 0.0
	remote_state.rpc(position.y)


## Called by the arena straight after add_child, so the label is already available.
## The node name is set by the caller before it enters the tree, because the state
## RPCs resolve by path and every peer has to agree on it.
func setup(p_peer_id: int, display_name: String, is_host: bool) -> void:
	peer_id = p_peer_id
	set_multiplayer_authority(p_peer_id)

	# A remote paddle only moves when a state lands, so it is the one worth interpolating.
	if is_multiplayer_authority():
		physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	else:
		physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_ON

	var colour: Color = PALETTE[absi(p_peer_id) % PALETTE.size()]
	var material: StandardMaterial3D = _mesh.material_override
	material.albedo_color = colour
	_name_label.modulate = colour

	var label: String = display_name
	if label.is_empty():
		label = "Peer %d" % p_peer_id
	if is_host:
		label += " (host)"
	_name_label.text = label


func teleport(to: Vector3) -> void:
	_lane_x = to.x
	_target_y = to.y
	position = to
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	reset_physics_interpolation()


@rpc("authority", "unreliable_ordered", "call_remote")
func remote_state(to_y: float) -> void:
	_target_y = to_y


func _drive(state: PhysicsDirectBodyState3D) -> void:
	var direction: float = 0.0
	if movement_enabled:
		direction = Input.get_axis("melay_move_down", "melay_move_up")

	# Never further than the travel has left, or the end clamps it back out and it jitters.
	var room: float = TRAVEL_LIMIT - signf(direction) * state.transform.origin.y
	var speed: float = minf(SPEED, maxf(room, 0.0) / state.step)
	state.linear_velocity = Vector3(0.0, direction * speed, 0.0)


func _follow(state: PhysicsDirectBodyState3D) -> void:
	var to_y: float = _target_y - state.transform.origin.y
	state.linear_velocity = Vector3(0.0, to_y * FOLLOW_RATE, 0.0)


# Written only when the paddle is off its lane, because Jolt reads a transform set as a
# teleport and drops the body's contacts.
func _confine(state: PhysicsDirectBodyState3D) -> void:
	var moved: Transform3D = state.transform
	var lane: Vector3 = Vector3(
		_lane_x, clampf(moved.origin.y, -TRAVEL_LIMIT, TRAVEL_LIMIT), 0.0
	)
	if moved.origin.is_equal_approx(lane):
		return

	moved.origin = lane
	state.transform = moved
