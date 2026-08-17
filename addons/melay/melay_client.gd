class_name MelayClient
extends Node

## WebSocket transport for the Melay relay. Owns the socket, the protocol state
## machine and the mapping between relay frames and [MelayPeer].
##
## This is the only class that knows the wire format, so swapping the transport
## later (WebRTC, Steam, raw UDP) touches nothing above it.

signal connected
signal disconnected(reason: String)
## Emitted once the peer has its relay-assigned id but before any peer_connected is
## announced. Anything that needs to observe those announcements, above all assigning
## multiplayer.multiplayer_peer, has to happen here rather than on room_joined.
signal peer_ready(peer: MelayPeer)
signal room_joined(room: MelayRoom)
signal room_left
signal peer_joined(info: MelayPeerInfo)
signal peer_left(info: MelayPeerInfo, reason: String)
signal room_list_received(rooms: Array[Dictionary])
signal error_received(code: String, message: String)
signal latency_updated(rtt_us: int, clock_offset_us: int)

enum Status {
	DISCONNECTED,
	CONNECTING,
	CONNECTED,
	JOINING,
	IN_ROOM,
}

const CLIENT_ID_PATH: String = "user://melay_client_id"

const CONNECT_TIMEOUT: float = 10.0
const REQUEST_TIMEOUT: float = 10.0

## Once a second, so the round-trip readout stays current enough to act on.
const PING_INTERVAL: float = 1.0

## Six missed pongs means the link has been silent for about six seconds.
const MISSED_PONGS_BEFORE_DROP: int = 6

## Godot's defaults are sized for occasional messages, not for game traffic.
const INBOUND_BUFFER_SIZE: int = 1 << 20
const OUTBOUND_BUFFER_SIZE: int = 1 << 20
const MAX_QUEUED_PACKETS: int = 2048

## Message ids are u16, so they wrap rather than grow.
const MESSAGE_ID_LIMIT: int = 1 << 16

var peer: MelayPeer = null

var url: String = "ws://127.0.0.1:8890"
var game_id: String = ""
var game_version: String = "1.0.0"
var api_key: String = ""
var display_name: String = ""

var _socket: WebSocketPeer = null
var _status: Status = Status.DISCONNECTED
var _room: MelayRoom = null
var _session_id: String = ""
var _client_id: String = ""
var _limits: Dictionary = {}
var _hello_sent: bool = false
var _pending: MelayRequest = null
var _close_reason: String = ""

## Zero until a relay says otherwise, which is what keeps a client from fragmenting
## at a relay too old to route the frames.
var _max_message_size: int = 0
var _next_message_id: int = 0
## One in-flight message per sender: fragments arrive in the order they were sent,
## so a sender cannot have two on the way at once.
var _partials: Dictionary[int, MelayPartialMessage] = {}
var _outbox: Array[PackedByteArray] = []

var _ping_elapsed: float = 0.0
var _pings_outstanding: int = 0
var _rtt_us: int = 0
var _clock_offset_us: int = 0
var _clock_drift_us: int = 0
var _clock_synced: bool = false


func _ready() -> void:
	peer = MelayPeer.new()
	peer.packet_generated.connect(_on_peer_packet_generated)
	peer.poll_requested.connect(_pump)
	peer.close_requested.connect(_on_peer_close_requested)
	_client_id = _load_or_create_client_id()
	set_process(false)


func _process(delta: float) -> void:
	_pump()
	_tick_heartbeat(delta)


## Opens the relay connection and completes the handshake.
func connect_to_relay() -> MelayResult:
	if game_id == "":
		return MelayResult.fail(
			MelayProtocol.CODE_NOT_CONNECTED, "call configure() with a game id first"
		)
	if _status != Status.DISCONNECTED:
		return MelayResult.ok(null)

	_socket = WebSocketPeer.new()
	_socket.inbound_buffer_size = INBOUND_BUFFER_SIZE
	_socket.outbound_buffer_size = OUTBOUND_BUFFER_SIZE
	_socket.max_queued_packets = MAX_QUEUED_PACKETS

	var endpoint: String = _endpoint_url()
	var err: Error = _socket.connect_to_url(endpoint)
	if err != OK:
		_socket = null
		return MelayResult.fail(
			MelayProtocol.CODE_NOT_CONNECTED, "could not reach %s (error %d)" % [endpoint, err]
		)

	_hello_sent = false
	_close_reason = ""
	_status = Status.CONNECTING
	peer.set_connecting()
	set_process(true)

	var request: MelayRequest = _begin_request(CONNECT_TIMEOUT)
	return await request.completed


## Creates a room and joins it as host. Recognised options: name, max_players,
## visibility, tags, password, dedicated.
func create_room(options: Dictionary = {}) -> MelayResult:
	if _status == Status.IN_ROOM:
		return MelayResult.fail(MelayProtocol.CODE_ALREADY_IN_ROOM, "already in a room")
	if _status != Status.CONNECTED:
		return MelayResult.fail(MelayProtocol.CODE_NOT_CONNECTED, "not connected to the relay")

	var payload: Dictionary = {
		"name": options.get("name", ""),
		"max_players": int(options.get("max_players", 0)),
		"visibility": options.get("visibility", MelayProtocol.VISIBILITY_PUBLIC),
		"tags": options.get("tags", {}),
		"password": options.get("password", ""),
		"dedicated": bool(options.get("dedicated", false)),
	}
	_status = Status.JOINING
	_send(MelayProtocol.encode_json(MelayProtocol.Op.ROOM_CREATE, payload))

	var request: MelayRequest = _begin_request(REQUEST_TIMEOUT)
	return await request.completed


## Joins an existing room by its share code.
func join_room(code: String, password: String = "") -> MelayResult:
	if _status == Status.IN_ROOM:
		return MelayResult.fail(MelayProtocol.CODE_ALREADY_IN_ROOM, "already in a room")
	if _status != Status.CONNECTED:
		return MelayResult.fail(MelayProtocol.CODE_NOT_CONNECTED, "not connected to the relay")

	_status = Status.JOINING
	_send(MelayProtocol.encode_json(
		MelayProtocol.Op.ROOM_JOIN, {"code": code, "password": password}
	))

	var request: MelayRequest = _begin_request(REQUEST_TIMEOUT)
	return await request.completed


## Lists public rooms for this game and version. Recognised filters: tags,
## only_joinable, limit.
func list_rooms(filter: Dictionary = {}) -> MelayResult:
	if _status == Status.DISCONNECTED or _status == Status.CONNECTING:
		return MelayResult.fail(MelayProtocol.CODE_NOT_CONNECTED, "not connected to the relay")

	_send(MelayProtocol.encode_json(MelayProtocol.Op.ROOM_LIST, {
		"tags": filter.get("tags", {}),
		"only_joinable": bool(filter.get("only_joinable", true)),
		"limit": int(filter.get("limit", 50)),
	}))

	var request: MelayRequest = _begin_request(REQUEST_TIMEOUT)
	return await request.completed


## Leaves the current room without dropping the relay connection.
func leave_room() -> void:
	if _status != Status.IN_ROOM:
		return
	_send(MelayProtocol.encode_empty(MelayProtocol.Op.ROOM_LEAVE))
	_exit_room()


## Records a custom analytics event.
func track(event: String, props: Dictionary = {}) -> void:
	if _status == Status.DISCONNECTED or _status == Status.CONNECTING:
		return
	var stringified: Dictionary = {}
	for key: Variant in props:
		stringified[str(key)] = str(props[key])
	_send(MelayProtocol.encode_json(
		MelayProtocol.Op.TRACK, {"event": event, "props": stringified}
	))


func disconnect_from_relay(reason: String = "closed by the game") -> void:
	if _status == Status.DISCONNECTED:
		return
	_close_reason = reason
	if _socket != null:
		_socket.close()
	_teardown(reason)


func get_status() -> Status:
	return _status


func get_room() -> MelayRoom:
	return _room


func get_session_id() -> String:
	return _session_id


func get_client_id() -> String:
	return _client_id


func get_limits() -> Dictionary:
	return _limits


## The largest packet a game may send. Anything above the relay's frame limit is
## split on the way out and put back together on the far side.
func get_max_message_size() -> int:
	return _message_ceiling()


## Round-trip time to the relay in microseconds, from the most recent pong.
func get_rtt_us() -> int:
	return _rtt_us


## Offset that converts a local [method Time.get_ticks_usec] reading into relay time.
## This is an epoch-scale number, not a small drift figure: local ticks count from
## engine start while the relay reports Unix time. Use [method get_clock_drift_us] to
## judge how good the estimate is.
func get_clock_offset_us() -> int:
	return _clock_offset_us


## How much the offset estimate moved on the most recent sample. Near zero means the
## clock estimate has settled; a large value means latency is swinging about.
func get_clock_drift_us() -> int:
	return _clock_drift_us


## False until the first pong lands, when relay time is still unknown.
func has_clock_sync() -> bool:
	return _clock_synced


## The relay's clock in microseconds, as best this client can estimate it. Every peer
## in a room agrees on it within a round trip, which makes it a usable reference for
## scheduling something to happen at the same moment everywhere.
func get_relay_time_us() -> int:
	return Time.get_ticks_usec() + _clock_offset_us


# Also driven from the peer's _poll, so packets are fresh; draining twice is harmless.
func _pump() -> void:
	if _socket == null:
		return

	_socket.poll()

	match _socket.get_ready_state():
		WebSocketPeer.STATE_OPEN:
			if not _hello_sent:
				_send_hello()
			_flush()
			# A handler can resume an awaiting caller that disconnects mid-drain.
			while _socket != null and _socket.get_available_packet_count() > 0:
				_handle_frame(_socket.get_packet())
		WebSocketPeer.STATE_CLOSED:
			var reason: String = _close_reason
			if reason == "":
				reason = _socket.get_close_reason()
			if reason == "":
				reason = "the relay closed the connection"
			_teardown(reason)


func _tick_heartbeat(delta: float) -> void:
	if _status == Status.DISCONNECTED or _status == Status.CONNECTING:
		return

	_ping_elapsed += delta
	if _ping_elapsed < PING_INTERVAL:
		return
	_ping_elapsed = 0.0

	if _pings_outstanding >= MISSED_PONGS_BEFORE_DROP:
		disconnect_from_relay("relay stopped responding")
		return

	_pings_outstanding += 1
	_send(MelayProtocol.encode_ping(Time.get_ticks_usec()))


# What one frame may carry, which is the relay's packet limit.
func _frame_limit() -> int:
	return int(_limits.get("max_packet_size", MelayPeer.DEFAULT_MAX_PACKET_SIZE))


# What a game may send. A relay that never mentions a message size predates
# fragmentation, so the frame limit is also the ceiling there.
func _message_ceiling() -> int:
	return maxi(_max_message_size, _frame_limit())


func _endpoint_url() -> String:
	var base: String = url.strip_edges().trim_suffix("/")
	if base.ends_with("/ws"):
		return base
	return base + "/ws"


func _send_hello() -> void:
	_hello_sent = true
	_send(MelayProtocol.encode_json(MelayProtocol.Op.HELLO, {
		"protocol": MelayProtocol.VERSION,
		"game": game_id,
		"game_version": game_version,
		"client_id": _client_id,
		"display_name": display_name,
		"platform": OS.get_name().to_lower(),
		"auth": api_key,
	}))


func _send(frame: PackedByteArray) -> Error:
	if _socket == null or _socket.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return ERR_UNAVAILABLE
	_outbox.append(frame)
	return _flush()


# The socket's buffer is finite and a fragmented message can fill it in one go, so a
# refused frame waits its turn here instead of being lost halfway through a message.
func _flush() -> Error:
	while not _outbox.is_empty():
		var err: Error = _socket.send(_outbox[0], WebSocketPeer.WRITE_MODE_BINARY)
		if err != OK:
			if _outbox.size() > MAX_QUEUED_PACKETS:
				disconnect_from_relay("the outbound queue overflowed")
			return err
		_outbox.remove_at(0)
	return OK


func _handle_frame(frame: PackedByteArray) -> void:
	match MelayProtocol.peek_op(frame):
		MelayProtocol.Op.RELAY_OUT:
			_handle_relay(frame)
		MelayProtocol.Op.RELAY_FRAGMENT_OUT:
			_handle_fragment(frame)
		MelayProtocol.Op.WELCOME:
			_handle_welcome(MelayProtocol.decode_json(frame))
		MelayProtocol.Op.ROOM_STATE:
			_handle_room_state(MelayProtocol.decode_json(frame))
		MelayProtocol.Op.PEER_JOIN:
			_handle_peer_join(MelayProtocol.decode_json(frame))
		MelayProtocol.Op.PEER_LEAVE:
			_handle_peer_leave(MelayProtocol.decode_json(frame))
		MelayProtocol.Op.ROOM_LIST_OUT:
			_handle_room_list(MelayProtocol.decode_json(frame))
		MelayProtocol.Op.PONG:
			_handle_pong(frame)
		MelayProtocol.Op.ERROR:
			_handle_error(MelayProtocol.decode_json(frame))
		_:
			pass


func _handle_relay(frame: PackedByteArray) -> void:
	if frame.size() < MelayProtocol.RELAY_PACKET_OFFSET:
		return
	peer.deliver_packet(
		frame.slice(MelayProtocol.RELAY_PACKET_OFFSET),
		frame.decode_s32(1),
		frame.decode_u8(5),
		frame.decode_u8(6) as MultiplayerPeer.TransferMode
	)


# A message is complete once its last slice lands. A slice that does not continue
# the one in hand means the set was broken up, so what was collected is discarded.
func _handle_fragment(frame: PackedByteArray) -> void:
	if frame.size() < MelayProtocol.FRAGMENT_PACKET_OFFSET:
		return

	var from: int = frame.decode_s32(1)
	var channel: int = frame.decode_u8(5)
	var mode: int = frame.decode_u8(6)
	var message_id: int = frame.decode_u16(7)
	var index: int = frame.decode_u16(9)
	var count: int = frame.decode_u16(11)
	var total: int = frame.decode_u32(13)
	if count < 2 or index >= count or count > total or total > _message_ceiling():
		return

	var partial: MelayPartialMessage = _partials.get(from, null)
	if index == 0:
		partial = MelayPartialMessage.new()
		partial.message_id = message_id
		partial.count = count
		partial.total = total
		_partials[from] = partial
	elif partial == null or partial.message_id != message_id \
	or partial.count != count or partial.total != total or partial.next != index:
		_partials.erase(from)
		return

	partial.data.append_array(frame.slice(MelayProtocol.FRAGMENT_PACKET_OFFSET))
	partial.next += 1
	if partial.data.size() > total:
		_partials.erase(from)
		return
	if partial.next < count:
		return

	_partials.erase(from)
	if partial.data.size() != total:
		return
	peer.deliver_packet(partial.data, from, channel, mode as MultiplayerPeer.TransferMode)


func _handle_welcome(data: Dictionary) -> void:
	_session_id = data.get("session_id", "")
	_limits = data.get("limits", {})
	_max_message_size = int(_limits.get("max_message_size", 0))
	_status = Status.CONNECTED
	_pings_outstanding = 0
	connected.emit()
	_resolve(MelayResult.ok(null))


func _handle_room_state(data: Dictionary) -> void:
	var was_in_room: bool = _status == Status.IN_ROOM
	var previous_ids: Array[int] = []
	if _room != null:
		previous_ids = _room.other_peer_ids()

	_room = MelayRoom.from_dictionary(data)
	_status = Status.IN_ROOM

	if not was_in_room:
		peer.initialize(_room.self_peer_id, _message_ceiling())
		# SceneMultiplayer must be listening before the existing members are announced.
		peer_ready.emit(peer)
		for peer_id: int in _room.other_peer_ids():
			peer.add_peer(peer_id)
		room_joined.emit(_room)
		_resolve(MelayResult.ok(_room))
		return

	# A re-sent snapshot is authoritative, so reconcile rather than assume a delta.
	var current_ids: Array[int] = _room.other_peer_ids()
	for peer_id: int in current_ids:
		if not previous_ids.has(peer_id):
			peer.add_peer(peer_id)
	for peer_id: int in previous_ids:
		if not current_ids.has(peer_id):
			peer.remove_peer(peer_id)


func _handle_peer_join(data: Dictionary) -> void:
	if _room == null:
		return
	var info: MelayPeerInfo = MelayPeerInfo.from_dictionary(data)
	if info.peer_id == 0 or _room.peers.has(info.peer_id):
		return
	_room.peers[info.peer_id] = info
	peer.add_peer(info.peer_id)
	peer_joined.emit(info)


func _handle_peer_leave(data: Dictionary) -> void:
	if _room == null:
		return
	var peer_id: int = int(data.get("peer_id", 0))
	var info: MelayPeerInfo = _room.get_peer(peer_id)
	if info == null:
		return
	_room.peers.erase(peer_id)
	_partials.erase(peer_id)
	peer.remove_peer(peer_id)
	peer_left.emit(info, data.get("reason", ""))


func _handle_room_list(data: Dictionary) -> void:
	var rooms: Array[Dictionary] = []
	for entry: Variant in data.get("rooms", []):
		if entry is Dictionary:
			rooms.append(entry)
	room_list_received.emit(rooms)
	_resolve(MelayResult.ok(rooms))


func _handle_pong(frame: PackedByteArray) -> void:
	if frame.size() < 1 + MelayProtocol.PONG_PAYLOAD_SIZE:
		return

	_pings_outstanding = 0
	var sent_us: int = frame.decode_u64(1)
	var server_us: int = frame.decode_u64(9)
	var now_us: int = Time.get_ticks_usec()

	_rtt_us = now_us - sent_us
	# Assumes a symmetric path; a filtered multi-sample estimate would be better.
	var offset: int = server_us - (sent_us + _rtt_us / 2)
	if _clock_synced:
		_clock_drift_us = offset - _clock_offset_us
	_clock_offset_us = offset
	_clock_synced = true
	latency_updated.emit(_rtt_us, _clock_offset_us)


func _handle_error(data: Dictionary) -> void:
	var code: String = data.get("code", MelayProtocol.CODE_INTERNAL)
	var message: String = data.get("message", "")
	error_received.emit(code, message)

	# A rejected room request leaves us connected but back in the lobby.
	if _status == Status.JOINING:
		_status = Status.CONNECTED

	_resolve(MelayResult.fail(code, message))

	if MelayProtocol.is_fatal(code):
		_close_reason = "%s: %s" % [code, message]


func _on_peer_packet_generated(
	target_peer: int,
	channel: int,
	mode: int,
	payload: PackedByteArray
) -> void:
	if _status != Status.IN_ROOM:
		return
	var frame_limit: int = _frame_limit()
	if payload.size() <= frame_limit:
		_send(MelayProtocol.encode_relay(target_peer, channel, mode, payload))
		return

	var slice_size: int = frame_limit - MelayProtocol.FRAGMENT_HEADER_SIZE
	var count: int = ceili(float(payload.size()) / float(slice_size))
	var message_id: int = _next_message_id
	_next_message_id = (_next_message_id + 1) % MESSAGE_ID_LIMIT
	for index: int in count:
		var start: int = index * slice_size
		_send(MelayProtocol.encode_fragment(
			target_peer,
			channel,
			mode,
			message_id,
			index,
			count,
			payload.size(),
			payload.slice(start, mini(start + slice_size, payload.size()))
		))


func _on_peer_close_requested() -> void:
	if _status == Status.IN_ROOM:
		leave_room()


func _exit_room() -> void:
	if _room == null:
		return
	_room = null
	_status = Status.CONNECTED
	_partials.clear()
	peer.reset()
	room_left.emit()


func _teardown(reason: String) -> void:
	if _status == Status.DISCONNECTED:
		return

	_status = Status.DISCONNECTED
	_room = null
	_session_id = ""
	_hello_sent = false
	_pings_outstanding = 0
	_clock_synced = false
	_clock_drift_us = 0
	_max_message_size = 0
	_partials.clear()
	_outbox.clear()
	_socket = null
	set_process(false)
	peer.reset()

	_fail_pending(MelayProtocol.CODE_NOT_CONNECTED, reason)
	disconnected.emit(reason)


func _begin_request(timeout_sec: float) -> MelayRequest:
	_fail_pending(MelayProtocol.CODE_CANCELLED, "superseded by a newer request")
	var request: MelayRequest = MelayRequest.new()
	_pending = request
	_expire_request(request, timeout_sec)
	return request


# Fire and forget: the coroutine resolves the request only if it is still pending.
func _expire_request(request: MelayRequest, timeout_sec: float) -> void:
	await get_tree().create_timer(timeout_sec).timeout
	if _pending != request:
		return
	_pending = null
	if _status == Status.JOINING:
		_status = Status.CONNECTED
	request.completed.emit(
		MelayResult.fail(MelayProtocol.CODE_TIMEOUT, "the relay did not answer in time")
	)


func _resolve(result: MelayResult) -> void:
	if _pending == null:
		return
	var request: MelayRequest = _pending
	_pending = null
	request.completed.emit(result)


func _fail_pending(code: String, message: String) -> void:
	if _pending == null:
		return
	_resolve(MelayResult.fail(code, message))


# Random per-install id, not OS.get_unique_id(), so nothing identifying is stored.
func _load_or_create_client_id() -> String:
	if FileAccess.file_exists(CLIENT_ID_PATH):
		var existing: FileAccess = FileAccess.open(CLIENT_ID_PATH, FileAccess.READ)
		if existing != null:
			var stored: String = existing.get_as_text().strip_edges()
			existing.close()
			if stored.length() == 32:
				return stored

	var generated: String = Crypto.new().generate_random_bytes(16).hex_encode()
	var file: FileAccess = FileAccess.open(CLIENT_ID_PATH, FileAccess.WRITE)
	if file != null:
		file.store_string(generated)
		file.close()
	return generated


class MelayPartialMessage:
	extends RefCounted

	var data: PackedByteArray = PackedByteArray()
	var message_id: int = 0
	var count: int = 0
	var total: int = 0
	## The index expected next, which doubles as how many slices have landed.
	var next: int = 0


class MelayRequest:
	extends RefCounted

	signal completed(result: MelayResult)
