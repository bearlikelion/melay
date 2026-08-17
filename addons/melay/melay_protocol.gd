class_name MelayProtocol
extends RefCounted

## Wire format for the Melay relay. See server/PROTOCOL.md, which is normative.

enum Op {
	HELLO = 0x01,
	ROOM_CREATE = 0x02,
	ROOM_JOIN = 0x03,
	ROOM_LEAVE = 0x04,
	ROOM_LIST = 0x05,
	RELAY = 0x06,
	PING = 0x07,
	SNAPSHOT_PUT = 0x08,
	TRACK = 0x09,
	RELAY_FRAGMENT = 0x0A,

	WELCOME = 0x81,
	ROOM_STATE = 0x82,
	PEER_JOIN = 0x83,
	PEER_LEAVE = 0x84,
	RELAY_OUT = 0x85,
	PONG = 0x86,
	HOST_CHANGED = 0x87,
	SNAPSHOT_GET = 0x88,
	ERROR = 0x89,
	ROOM_LIST_OUT = 0x8A,
	RELAY_FRAGMENT_OUT = 0x8B,
}

const VERSION: int = 1

const VISIBILITY_PUBLIC: String = "public"
const VISIBILITY_PRIVATE: String = "private"

const CODE_PROTOCOL_MISMATCH: String = "protocol_mismatch"
const CODE_BAD_FRAME: String = "bad_frame"
const CODE_UNAUTHORIZED: String = "unauthorized"
const CODE_UNKNOWN_GAME: String = "unknown_game"
const CODE_SERVER_FULL: String = "server_full"
const CODE_SLOW_CONSUMER: String = "slow_consumer"
const CODE_RATE_LIMITED: String = "rate_limited"
const CODE_ROOM_NOT_FOUND: String = "room_not_found"
const CODE_ROOM_FULL: String = "room_full"
const CODE_WRONG_PASSWORD: String = "wrong_password"
const CODE_VERSION_MISMATCH: String = "version_mismatch"
const CODE_ALREADY_IN_ROOM: String = "already_in_room"
const CODE_NOT_IN_ROOM: String = "not_in_room"
const CODE_PACKET_TOO_LARGE: String = "packet_too_large"
const CODE_INTERNAL: String = "internal"

## Codes after which the server closes the socket.
const FATAL_CODES: Array[String] = [
	CODE_PROTOCOL_MISMATCH,
	CODE_BAD_FRAME,
	CODE_UNAUTHORIZED,
	CODE_UNKNOWN_GAME,
	CODE_SERVER_FULL,
	CODE_SLOW_CONSUMER,
]

## Codes raised locally by the addon rather than received from the server.
const CODE_TIMEOUT: String = "timeout"
const CODE_NOT_CONNECTED: String = "not_connected"
const CODE_CANCELLED: String = "cancelled"

const RELAY_HEADER_SIZE: int = 6
const RELAY_PACKET_OFFSET: int = 1 + RELAY_HEADER_SIZE

## The relay header plus the message id, index, count and total length a fragment carries.
const FRAGMENT_HEADER_SIZE: int = RELAY_HEADER_SIZE + 10
const FRAGMENT_PACKET_OFFSET: int = 1 + FRAGMENT_HEADER_SIZE

const PONG_PAYLOAD_SIZE: int = 16


## Builds a control frame from a dictionary payload.
static func encode_json(op: Op, data: Dictionary) -> PackedByteArray:
	var frame: PackedByteArray = PackedByteArray([op])
	frame.append_array(JSON.stringify(data).to_utf8_buffer())
	return frame


## Builds an outbound relay frame. Target follows Godot's addressing: 0 broadcasts,
## a positive id unicasts, a negative id excludes abs(target).
static func encode_relay(
	target: int,
	channel: int,
	mode: int,
	packet: PackedByteArray
) -> PackedByteArray:
	var frame: PackedByteArray = PackedByteArray()
	frame.resize(RELAY_PACKET_OFFSET)
	frame.encode_u8(0, Op.RELAY)
	frame.encode_s32(1, target)
	frame.encode_u8(5, channel)
	frame.encode_u8(6, mode)
	frame.append_array(packet)
	return frame


## Builds one slice of a packet too large for a single frame. Channel and mode are
## what the sender asked for, not the reliable mode the relay queues fragments under,
## and total is the whole message, which is what lets the relay bound it exactly.
static func encode_fragment(
	target: int,
	channel: int,
	mode: int,
	message_id: int,
	index: int,
	count: int,
	total: int,
	slice: PackedByteArray
) -> PackedByteArray:
	var frame: PackedByteArray = PackedByteArray()
	frame.resize(FRAGMENT_PACKET_OFFSET)
	frame.encode_u8(0, Op.RELAY_FRAGMENT)
	frame.encode_s32(1, target)
	frame.encode_u8(5, channel)
	frame.encode_u8(6, mode)
	frame.encode_u16(7, message_id)
	frame.encode_u16(9, index)
	frame.encode_u16(11, count)
	frame.encode_u32(13, total)
	frame.append_array(slice)
	return frame


static func encode_ping(client_time_us: int) -> PackedByteArray:
	var frame: PackedByteArray = PackedByteArray()
	frame.resize(9)
	frame.encode_u8(0, Op.PING)
	frame.encode_u64(1, client_time_us)
	return frame


static func encode_empty(op: Op) -> PackedByteArray:
	return PackedByteArray([op])


## Reads the opcode from a frame, or -1 when the frame is empty.
static func peek_op(frame: PackedByteArray) -> int:
	if frame.is_empty():
		return -1
	return frame.decode_u8(0)


## Parses a JSON control payload. Returns an empty dictionary on malformed input.
static func decode_json(frame: PackedByteArray) -> Dictionary:
	if frame.size() <= 1:
		return {}
	var text: String = frame.slice(1).get_string_from_utf8()
	var parsed: Variant = JSON.parse_string(text)
	if parsed is Dictionary:
		return parsed
	return {}


static func is_fatal(code: String) -> bool:
	return FATAL_CODES.has(code)
