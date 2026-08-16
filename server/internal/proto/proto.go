// Package proto implements the Melay wire protocol described in server/PROTOCOL.md.
package proto

import (
	"encoding/binary"
	"errors"
	"fmt"
)

// Version is the protocol version this build speaks.
const Version = 1

// Op is a Melay frame opcode. The high bit marks server-to-client frames.
type Op uint8

const (
	OpHello       Op = 0x01
	OpRoomCreate  Op = 0x02
	OpRoomJoin    Op = 0x03
	OpRoomLeave   Op = 0x04
	OpRoomList    Op = 0x05
	OpRelay       Op = 0x06
	OpPing        Op = 0x07
	OpSnapshotPut Op = 0x08
	OpTrack       Op = 0x09

	OpWelcome     Op = 0x81
	OpRoomState   Op = 0x82
	OpPeerJoin    Op = 0x83
	OpPeerLeave   Op = 0x84
	OpRelayOut    Op = 0x85
	OpPong        Op = 0x86
	OpHostChanged Op = 0x87
	OpSnapshotGet Op = 0x88
	OpError       Op = 0x89
	OpRoomListOut Op = 0x8A
)

func (o Op) String() string {
	switch o {
	case OpHello:
		return "HELLO"
	case OpRoomCreate:
		return "ROOM_CREATE"
	case OpRoomJoin:
		return "ROOM_JOIN"
	case OpRoomLeave:
		return "ROOM_LEAVE"
	case OpRoomList:
		return "ROOM_LIST"
	case OpRelay:
		return "RELAY"
	case OpPing:
		return "PING"
	case OpSnapshotPut:
		return "SNAPSHOT_PUT"
	case OpTrack:
		return "TRACK"
	case OpWelcome:
		return "WELCOME"
	case OpRoomState:
		return "ROOM_STATE"
	case OpPeerJoin:
		return "PEER_JOIN"
	case OpPeerLeave:
		return "PEER_LEAVE"
	case OpRelayOut:
		return "RELAY_OUT"
	case OpPong:
		return "PONG"
	case OpHostChanged:
		return "HOST_CHANGED"
	case OpSnapshotGet:
		return "SNAPSHOT_GET"
	case OpError:
		return "ERROR"
	case OpRoomListOut:
		return "ROOM_LIST_OUT"
	}
	return fmt.Sprintf("OP(0x%02X)", uint8(o))
}

// TransferMode mirrors Godot's MultiplayerPeer.TransferMode.
type TransferMode uint8

const (
	Unreliable        TransferMode = 0
	UnreliableOrdered TransferMode = 1
	Reliable          TransferMode = 2
)

// relayHeaderLen is the fixed header after the opcode: i32 peer, u8 channel, u8 mode.
const relayHeaderLen = 6

// ErrShortFrame means a frame ended before its fixed header did.
var ErrShortFrame = errors.New("melay: frame too short")

// Frame is a decoded Melay frame. Payload aliases the read buffer and must not be
// retained past the read loop without copying.
type Frame struct {
	Op      Op
	Payload []byte
}

// Decode splits a raw WebSocket message into an opcode and its payload.
func Decode(msg []byte) (Frame, error) {
	if len(msg) < 1 {
		return Frame{}, ErrShortFrame
	}
	return Frame{Op: Op(msg[0]), Payload: msg[1:]}, nil
}

// RelayHeader is the fixed part of a relay frame in either direction.
type RelayHeader struct {
	// Peer is the target on the way in and the sender on the way out.
	Peer    int32
	Channel uint8
	Mode    TransferMode
}

// DecodeRelay splits a relay payload into its header and the opaque Godot packet.
// The returned packet aliases payload.
func DecodeRelay(payload []byte) (RelayHeader, []byte, error) {
	if len(payload) < relayHeaderLen {
		return RelayHeader{}, nil, ErrShortFrame
	}
	h := RelayHeader{
		Peer:    int32(binary.LittleEndian.Uint32(payload[0:4])),
		Channel: payload[4],
		Mode:    TransferMode(payload[5]),
	}
	return h, payload[relayHeaderLen:], nil
}

// EncodeRelay builds an outbound relay frame in a single allocation.
func EncodeRelay(from int32, channel uint8, mode TransferMode, packet []byte) []byte {
	buf := make([]byte, 1+relayHeaderLen+len(packet))
	buf[0] = byte(OpRelayOut)
	binary.LittleEndian.PutUint32(buf[1:5], uint32(from))
	buf[5] = channel
	buf[6] = byte(mode)
	copy(buf[1+relayHeaderLen:], packet)
	return buf
}

// DecodePing reads the client timestamp echoed back by PONG.
func DecodePing(payload []byte) (uint64, error) {
	if len(payload) < 8 {
		return 0, ErrShortFrame
	}
	return binary.LittleEndian.Uint64(payload[0:8]), nil
}

// EncodePong echoes the client timestamp and appends the server's.
func EncodePong(clientTimeUS, serverTimeUS uint64) []byte {
	buf := make([]byte, 1+16)
	buf[0] = byte(OpPong)
	binary.LittleEndian.PutUint64(buf[1:9], clientTimeUS)
	binary.LittleEndian.PutUint64(buf[9:17], serverTimeUS)
	return buf
}

// EncodeJSON prefixes an already-marshalled JSON payload with its opcode.
func EncodeJSON(op Op, jsonPayload []byte) []byte {
	buf := make([]byte, 1+len(jsonPayload))
	buf[0] = byte(op)
	copy(buf[1:], jsonPayload)
	return buf
}
