package proto

import (
	"bytes"
	"testing"
)

func TestRelayRoundTrip(t *testing.T) {
	cases := []struct {
		name    string
		peer    int32
		channel uint8
		mode    TransferMode
		packet  []byte
	}{
		{"broadcast", 0, 0, Unreliable, []byte("hello")},
		{"unicast", 42, 3, Reliable, []byte{0x00, 0xFF, 0x7F}},
		{"exclusion", -7, 255, UnreliableOrdered, []byte("exclude peer 7")},
		{"empty packet", 1, 0, Reliable, []byte{}},
		{"max peer id", 2147483647, 1, Reliable, []byte("max")},
		{"min peer id", -2147483648, 1, Reliable, []byte("min")},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			raw := EncodeRelay(tc.peer, tc.channel, tc.mode, tc.packet)

			f, err := Decode(raw)
			if err != nil {
				t.Fatalf("Decode: %v", err)
			}
			if f.Op != OpRelayOut {
				t.Fatalf("op = %s, want RELAY_OUT", f.Op)
			}

			h, packet, err := DecodeRelay(f.Payload)
			if err != nil {
				t.Fatalf("DecodeRelay: %v", err)
			}
			if h.Peer != tc.peer {
				t.Errorf("peer = %d, want %d", h.Peer, tc.peer)
			}
			if h.Channel != tc.channel {
				t.Errorf("channel = %d, want %d", h.Channel, tc.channel)
			}
			if h.Mode != tc.mode {
				t.Errorf("mode = %d, want %d", h.Mode, tc.mode)
			}
			if !bytes.Equal(packet, tc.packet) {
				t.Errorf("packet = %x, want %x", packet, tc.packet)
			}
		})
	}
}

// The wire format is little-endian so the Godot client can use PackedByteArray's
// codecs directly. Pin the byte layout so a well-meaning refactor cannot flip it.
func TestRelayHeaderIsLittleEndian(t *testing.T) {
	raw := EncodeRelay(0x01020304, 0xAB, Reliable, nil)

	want := []byte{byte(OpRelayOut), 0x04, 0x03, 0x02, 0x01, 0xAB, byte(Reliable)}
	if !bytes.Equal(raw, want) {
		t.Fatalf("frame = % x, want % x", raw, want)
	}
}

func TestPongIsLittleEndian(t *testing.T) {
	raw := EncodePong(0x0102030405060708, 0x1112131415161718)

	want := []byte{
		byte(OpPong),
		0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01,
		0x18, 0x17, 0x16, 0x15, 0x14, 0x13, 0x12, 0x11,
	}
	if !bytes.Equal(raw, want) {
		t.Fatalf("frame = % x, want % x", raw, want)
	}
}

func TestPingRoundTrip(t *testing.T) {
	const clientTime uint64 = 1755357000123456

	pong := EncodePong(clientTime, 99)
	f, err := Decode(pong)
	if err != nil {
		t.Fatalf("Decode: %v", err)
	}
	got, err := DecodePing(f.Payload)
	if err != nil {
		t.Fatalf("DecodePing: %v", err)
	}
	if got != clientTime {
		t.Fatalf("client time = %d, want %d", got, clientTime)
	}
}

func TestDecodeRejectsEmptyFrame(t *testing.T) {
	if _, err := Decode(nil); err != ErrShortFrame {
		t.Fatalf("err = %v, want ErrShortFrame", err)
	}
}

func TestDecodeRelayRejectsTruncatedHeader(t *testing.T) {
	for n := 0; n < relayHeaderLen; n++ {
		if _, _, err := DecodeRelay(make([]byte, n)); err != ErrShortFrame {
			t.Errorf("payload of %d bytes: err = %v, want ErrShortFrame", n, err)
		}
	}
	if _, _, err := DecodeRelay(make([]byte, relayHeaderLen)); err != nil {
		t.Errorf("exact-length header rejected: %v", err)
	}
}

func TestDecodePingRejectsTruncatedPayload(t *testing.T) {
	if _, err := DecodePing(make([]byte, 7)); err != ErrShortFrame {
		t.Fatalf("err = %v, want ErrShortFrame", err)
	}
}

func TestFatalErrorCodes(t *testing.T) {
	fatal := []ErrorCode{
		ErrProtocolMismatch, ErrBadFrame, ErrUnauthorized,
		ErrUnknownGame, ErrServerFull, ErrSlowConsumer,
	}
	for _, c := range fatal {
		if !c.Fatal() {
			t.Errorf("%s.Fatal() = false, want true", c)
		}
	}

	recoverable := []ErrorCode{
		ErrRateLimited, ErrRoomNotFound, ErrRoomFull, ErrWrongPassword,
		ErrVersionMismatch, ErrAlreadyInRoom, ErrNotInRoom,
		ErrPacketTooLarge, ErrInternal,
	}
	for _, c := range recoverable {
		if c.Fatal() {
			t.Errorf("%s.Fatal() = true, want false", c)
		}
	}
}

func TestEncodeJSONPrefixesOpcode(t *testing.T) {
	raw := EncodeJSON(OpWelcome, []byte(`{"a":1}`))

	f, err := Decode(raw)
	if err != nil {
		t.Fatalf("Decode: %v", err)
	}
	if f.Op != OpWelcome {
		t.Fatalf("op = %s, want WELCOME", f.Op)
	}
	if string(f.Payload) != `{"a":1}` {
		t.Fatalf("payload = %s", f.Payload)
	}
}
