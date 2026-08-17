class_name DemoBall
extends RigidBody3D

## The ball. Jolt moves it; this only keeps the speed inside a playable band, reports the
## contacts the arena has to broadcast, and folds the host's states back in.

signal bounced(against: Node)

## Served slowly and wound up a step on every paddle hit, so a long rally is what makes
## it fast rather than the serve.
const SERVE_SPEED: float = 5.5
const MAX_SPEED: float = 20.0
const SPEEDUP: float = 1.12

## Below this share of the speed along x the rally turns into a vertical stalemate.
const MIN_HORIZONTAL: float = 0.35

## Past this much disagreement a host state is a teleport, not a nudge.
const SNAP_DISTANCE: float = 1.5

## How much of the remaining error each host state pulls in.
const CORRECTION_BLEND: float = 0.35

var _pending_position: Vector3 = Vector3.ZERO
var _pending_velocity: Vector3 = Vector3.ZERO
var _has_pending: bool = false
var _pending_is_jump: bool = false


func _ready() -> void:
	body_entered.connect(_on_body_entered)


func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	if _has_pending:
		_has_pending = false
		var moved: Transform3D = state.transform
		moved.origin = _pending_position
		state.transform = moved
		state.linear_velocity = _pending_velocity
		state.angular_velocity = Vector3.ZERO
		if _pending_is_jump:
			_pending_is_jump = false
			# Deferred, because the node only picks the new transform up after the step.
			reset_physics_interpolation.call_deferred()
	state.linear_velocity = _shape(state.linear_velocity)


func serve() -> void:
	var direction: Vector3 = Vector3.RIGHT.rotated(
		Vector3.BACK, randf_range(-PI / 5.0, PI / 5.0)
	)
	if randf() < 0.5:
		direction = -direction
	teleport(Vector3.ZERO, direction * SERVE_SPEED)


## Queued rather than applied, because Jolt only takes a state change during the step.
func teleport(to: Vector3, velocity: Vector3) -> void:
	_move(to, velocity, true)


## Folds an authoritative state in. A small disagreement is eased out over the next few
## updates so the ball keeps moving; a large one is not worth easing.
func correct(to: Vector3, velocity: Vector3) -> void:
	if global_position.distance_to(to) > SNAP_DISTANCE:
		teleport(to, velocity)
		return
	_move(global_position.lerp(to, CORRECTION_BLEND), velocity, false)


## Winds the rally up one step. Applied here and now rather than queued, so the state the
## host broadcasts on the same contact already carries it.
func speed_up() -> void:
	linear_velocity = _shape(linear_velocity * SPEEDUP)


func _on_body_entered(body: Node) -> void:
	bounced.emit(body)


# A jump breaks the line an interpolated ball is drawn along; a nudge is small enough
# that drawing it out over the tick is the smoothing we want.
func _move(to: Vector3, velocity: Vector3, is_jump: bool) -> void:
	_pending_position = to
	_pending_velocity = velocity
	_pending_is_jump = _pending_is_jump or is_jump
	_has_pending = true


# Holds the speed in its band and refuses angles too close to vertical.
func _shape(velocity: Vector3) -> Vector3:
	var flat: Vector3 = Vector3(velocity.x, velocity.y, 0.0)
	var speed: float = flat.length()
	if speed < 0.001:
		return flat

	var direction: Vector3 = flat / speed
	if absf(direction.x) < MIN_HORIZONTAL:
		var side: float = signf(direction.x)
		if side == 0.0:
			side = 1.0
		direction = Vector3(side * MIN_HORIZONTAL, direction.y, 0.0).normalized()
	return direction * clampf(speed, SERVE_SPEED, MAX_SPEED)
