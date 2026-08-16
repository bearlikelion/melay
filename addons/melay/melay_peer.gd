class_name MelayPeer
extends MultiplayerPeerExtension

## The MultiplayerPeer Godot talks to. It is deliberately a dumb queue: packets in
## through [method deliver_packet], packets out through [signal packet_generated].
## It knows nothing about rooms, sessions or the wire protocol, which is what lets a
## native implementation replace it later without touching anything else.

## Emitted when Godot hands down a packet to send.
signal packet_generated(target_peer: int, channel: int, mode: int, payload: PackedByteArray)

## Emitted from [method _poll] so the transport can pump its socket at exactly the
## moment Godot is about to read packets, rather than a frame earlier.
signal poll_requested

## Emitted when Godot closes the peer.
signal close_requested

const DEFAULT_MAX_PACKET_SIZE: int = 262144

## Godot reserves peer id 1 for the server, so the room host always holds it.
const HOST_PEER_ID: int = 1

var _self_peer_id: int = 0
var _connection_status: MultiplayerPeer.ConnectionStatus = CONNECTION_DISCONNECTED
var _target_peer: int = 0
var _transfer_channel: int = 0
var _transfer_mode: MultiplayerPeer.TransferMode = TRANSFER_MODE_RELIABLE
var _refuse_new_connections: bool = false
var _max_packet_size: int = DEFAULT_MAX_PACKET_SIZE
var _incoming: Array[MelayIncomingPacket] = []


func _poll() -> void:
	poll_requested.emit()


func _close() -> void:
	_incoming.clear()
	_self_peer_id = 0
	_connection_status = CONNECTION_DISCONNECTED
	close_requested.emit()


# The relay owns membership; kicking needs a protocol message v1 does not define.
func _disconnect_peer(_peer_id: int, _force: bool) -> void:
	pass


func _get_unique_id() -> int:
	return _self_peer_id


func _get_connection_status() -> MultiplayerPeer.ConnectionStatus:
	return _connection_status


func _is_server() -> bool:
	return _self_peer_id == HOST_PEER_ID


# The relay routes to any target itself, so Godot must not re-forward via the host.
func _is_server_relay_supported() -> bool:
	return true


func _get_max_packet_size() -> int:
	return _max_packet_size


func _get_available_packet_count() -> int:
	return _incoming.size()


func _get_packet_script() -> PackedByteArray:
	if _incoming.is_empty():
		return PackedByteArray()
	var packet: MelayIncomingPacket = _incoming.pop_front()
	return packet.data


# Called before _get_packet_script and must describe it, so this peeks, never pops.
func _get_packet_peer() -> int:
	if _incoming.is_empty():
		return HOST_PEER_ID
	return _incoming[0].from


func _get_packet_channel() -> int:
	if _incoming.is_empty():
		return 0
	return _incoming[0].channel


func _get_packet_mode() -> MultiplayerPeer.TransferMode:
	if _incoming.is_empty():
		return TRANSFER_MODE_RELIABLE
	return _incoming[0].mode


func _put_packet_script(buffer: PackedByteArray) -> Error:
	if _connection_status != CONNECTION_CONNECTED:
		return ERR_UNCONFIGURED
	if buffer.size() > _max_packet_size:
		push_error("Melay: packet of %d bytes exceeds the relay limit of %d" % [
			buffer.size(), _max_packet_size,
		])
		return ERR_OUT_OF_MEMORY
	packet_generated.emit(_target_peer, _transfer_channel, _transfer_mode, buffer)
	return OK


func _set_target_peer(peer_id: int) -> void:
	_target_peer = peer_id


func _set_transfer_channel(channel: int) -> void:
	_transfer_channel = clampi(channel, 0, 255)


func _get_transfer_channel() -> int:
	return _transfer_channel


func _set_transfer_mode(mode: MultiplayerPeer.TransferMode) -> void:
	_transfer_mode = mode


func _get_transfer_mode() -> MultiplayerPeer.TransferMode:
	return _transfer_mode


func _set_refuse_new_connections(enable: bool) -> void:
	_refuse_new_connections = enable


func _is_refusing_new_connections() -> bool:
	return _refuse_new_connections


## Adopts the relay-assigned identity and marks the peer usable.
func initialize(peer_id: int, max_packet_size: int) -> void:
	_self_peer_id = peer_id
	if max_packet_size > 0:
		_max_packet_size = max_packet_size
	_connection_status = CONNECTION_CONNECTED


## Reports progress towards being usable. Everything before a room is joined stays
## CONNECTING, because Godot has no state for "connected to the relay but not yet
## holding a peer id".
func set_connecting() -> void:
	_connection_status = CONNECTION_CONNECTING


## Queues a packet for Godot to read on the next poll.
func deliver_packet(
	data: PackedByteArray,
	from: int,
	channel: int,
	mode: MultiplayerPeer.TransferMode
) -> void:
	var packet: MelayIncomingPacket = MelayIncomingPacket.new()
	packet.data = data
	packet.from = from
	packet.channel = channel
	packet.mode = mode
	_incoming.push_back(packet)


## Announces another member of the room. SceneMultiplayer derives connected_to_server
## from peer_connected(1), so this is the only connection signal the peer ever emits.
func add_peer(peer_id: int) -> void:
	if peer_id == _self_peer_id:
		return
	peer_connected.emit(peer_id)


func remove_peer(peer_id: int) -> void:
	if peer_id == _self_peer_id:
		return
	peer_disconnected.emit(peer_id)


## Drops back to a disconnected state without emitting close_requested, for use when
## the transport has already gone away.
func reset() -> void:
	_incoming.clear()
	_self_peer_id = 0
	_target_peer = 0
	_connection_status = CONNECTION_DISCONNECTED


class MelayIncomingPacket:
	extends RefCounted

	var data: PackedByteArray = PackedByteArray()
	var from: int = 0
	var channel: int = 0
	var mode: MultiplayerPeer.TransferMode = MultiplayerPeer.TRANSFER_MODE_RELIABLE
