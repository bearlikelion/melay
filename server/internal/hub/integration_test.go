package hub_test

import (
	"context"
	"encoding/binary"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/bearlikelion/melay/internal/config"
	"github.com/bearlikelion/melay/internal/hub"
	"github.com/bearlikelion/melay/internal/proto"
	"github.com/bearlikelion/melay/internal/room"
	"github.com/bearlikelion/melay/internal/store"
	"github.com/coder/websocket"
)

// client is a minimal protocol client, independent of the GDScript implementation.
type client struct {
	t  *testing.T
	ws *websocket.Conn
}

func newServer(t *testing.T, cfg *config.Config) *httptest.Server {
	t.Helper()
	return newResumeServer(t, cfg, hub.DefaultResumeWindow)
}

func newResumeServer(t *testing.T, cfg *config.Config, window time.Duration) *httptest.Server {
	t.Helper()

	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	rooms := room.NewManager()
	h := hub.New(cfg, rooms, store.Nop{}, log)
	h.ResumeWindow = window

	mux := http.NewServeMux()
	mux.Handle("/ws", h)

	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	return srv
}

func dial(t *testing.T, srv *httptest.Server) *client {
	t.Helper()

	url := "ws" + strings.TrimPrefix(srv.URL, "http") + "/ws"
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	ws, _, err := websocket.Dial(ctx, url, nil)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	ws.SetReadLimit(1 << 20)
	t.Cleanup(func() { ws.CloseNow() })
	return &client{t: t, ws: ws}
}

func (c *client) send(op proto.Op, payload []byte) {
	c.t.Helper()

	frame := append([]byte{byte(op)}, payload...)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := c.ws.Write(ctx, websocket.MessageBinary, frame); err != nil {
		c.t.Fatalf("write %s: %v", op, err)
	}
}

func (c *client) sendJSON(op proto.Op, v any) {
	c.t.Helper()

	payload, err := json.Marshal(v)
	if err != nil {
		c.t.Fatalf("marshal %s: %v", op, err)
	}
	c.send(op, payload)
}

func (c *client) read() proto.Frame {
	c.t.Helper()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	_, data, err := c.ws.Read(ctx)
	if err != nil {
		c.t.Fatalf("read: %v", err)
	}
	f, err := proto.Decode(data)
	if err != nil {
		c.t.Fatalf("decode: %v", err)
	}
	return f
}

// expect reads until it sees op, failing on an ERROR frame or a timeout.
func (c *client) expect(op proto.Op) proto.Frame {
	c.t.Helper()

	for i := 0; i < 16; i++ {
		f := c.read()
		if f.Op == op {
			return f
		}
		if f.Op == proto.OpError {
			var e proto.Error
			json.Unmarshal(f.Payload, &e)
			c.t.Fatalf("waiting for %s, got ERROR %s: %s", op, e.Code, e.Message)
		}
	}
	c.t.Fatalf("never saw %s", op)
	return proto.Frame{}
}

func (c *client) hello(game, version, id string) proto.Welcome {
	c.t.Helper()
	return c.resume(game, version, id, "", 0)
}

func (c *client) resume(game, version, id, session string, received uint64) proto.Welcome {
	c.t.Helper()

	c.sendJSON(proto.OpHello, proto.Hello{
		Protocol:    proto.Version,
		Game:        game,
		GameVersion: version,
		ClientID:    id,
		DisplayName: id,
		Platform:    "test",
		Resume:      session,
		Received:    received,
	})
	var w proto.Welcome
	if err := json.Unmarshal(c.expect(proto.OpWelcome).Payload, &w); err != nil {
		c.t.Fatalf("welcome: %v", err)
	}
	return w
}

func (c *client) roomState() proto.RoomState {
	c.t.Helper()

	var st proto.RoomState
	if err := json.Unmarshal(c.expect(proto.OpRoomState).Payload, &st); err != nil {
		c.t.Fatalf("room state: %v", err)
	}
	return st
}

func relayPayload(target int32, channel uint8, mode proto.TransferMode, packet []byte) []byte {
	buf := make([]byte, 6+len(packet))
	buf[0] = byte(target)
	buf[1] = byte(target >> 8)
	buf[2] = byte(target >> 16)
	buf[3] = byte(target >> 24)
	buf[4] = channel
	buf[5] = byte(mode)
	copy(buf[6:], packet)
	return buf
}

func TestHostAndClientExchangePackets(t *testing.T) {
	srv := newServer(t, config.New())

	host := dial(t, srv)
	host.hello("spacewar", "1.0.0", "host")
	host.sendJSON(proto.OpRoomCreate, proto.RoomCreate{MaxPlayers: 4})
	hostState := host.roomState()

	if hostState.SelfPeerID != 1 {
		t.Fatalf("host peer id = %d, want 1", hostState.SelfPeerID)
	}
	if hostState.Code == "" {
		t.Fatal("room created without a code")
	}

	guest := dial(t, srv)
	guest.hello("spacewar", "1.0.0", "guest")
	guest.sendJSON(proto.OpRoomJoin, proto.RoomJoin{Code: hostState.Code})
	guestState := guest.roomState()

	if guestState.SelfPeerID != 2 {
		t.Fatalf("guest peer id = %d, want 2", guestState.SelfPeerID)
	}
	if guestState.HostPeerID != 1 {
		t.Fatalf("guest sees host id %d, want 1", guestState.HostPeerID)
	}
	if len(guestState.Peers) != 2 {
		t.Fatalf("guest sees %d peers, want 2", len(guestState.Peers))
	}

	// The host learns about the join.
	var join proto.PeerInfo
	if err := json.Unmarshal(host.expect(proto.OpPeerJoin).Payload, &join); err != nil {
		t.Fatalf("peer join: %v", err)
	}
	if join.PeerID != 2 {
		t.Fatalf("PEER_JOIN peer id = %d, want 2", join.PeerID)
	}

	// Host to guest, addressed directly.
	host.send(proto.OpRelay, relayPayload(2, 3, proto.Reliable, []byte("ping")))
	f := guest.expect(proto.OpRelayOut)
	h, packet, err := proto.DecodeRelay(f.Payload)
	if err != nil {
		t.Fatalf("decode relay: %v", err)
	}
	if h.Peer != 1 {
		t.Errorf("from = %d, want 1", h.Peer)
	}
	if h.Channel != 3 {
		t.Errorf("channel = %d, want 3", h.Channel)
	}
	if string(packet) != "ping" {
		t.Errorf("packet = %q, want ping", packet)
	}

	// Guest broadcasts back.
	guest.send(proto.OpRelay, relayPayload(0, 0, proto.Unreliable, []byte("pong")))
	f = host.expect(proto.OpRelayOut)
	h, packet, err = proto.DecodeRelay(f.Payload)
	if err != nil {
		t.Fatalf("decode relay: %v", err)
	}
	if h.Peer != 2 {
		t.Errorf("from = %d, want 2", h.Peer)
	}
	if string(packet) != "pong" {
		t.Errorf("packet = %q, want pong", packet)
	}
}

func TestLeaveNotifiesRemainingPeers(t *testing.T) {
	srv := newServer(t, config.New())

	host := dial(t, srv)
	host.hello("g", "1", "host")
	host.sendJSON(proto.OpRoomCreate, proto.RoomCreate{MaxPlayers: 4})
	code := host.roomState().Code

	guest := dial(t, srv)
	guest.hello("g", "1", "guest")
	guest.sendJSON(proto.OpRoomJoin, proto.RoomJoin{Code: code})
	guest.roomState()
	host.expect(proto.OpPeerJoin)

	guest.send(proto.OpRoomLeave, nil)

	var leave proto.PeerLeave
	if err := json.Unmarshal(host.expect(proto.OpPeerLeave).Payload, &leave); err != nil {
		t.Fatalf("peer leave: %v", err)
	}
	if leave.PeerID != 2 {
		t.Errorf("leave peer id = %d, want 2", leave.PeerID)
	}
	if leave.Reason != proto.ReasonLeft {
		t.Errorf("reason = %q, want %q", leave.Reason, proto.ReasonLeft)
	}
}

func TestRoomListRespectsVisibilityAndTags(t *testing.T) {
	srv := newServer(t, config.New())

	pub := dial(t, srv)
	pub.hello("g", "1", "pub")
	pub.sendJSON(proto.OpRoomCreate, proto.RoomCreate{
		Name: "public one", MaxPlayers: 4,
		Visibility: proto.VisibilityPublic,
		Tags:       map[string]string{"mode": "ffa"},
	})
	pub.roomState()

	priv := dial(t, srv)
	priv.hello("g", "1", "priv")
	priv.sendJSON(proto.OpRoomCreate, proto.RoomCreate{
		Name: "private one", MaxPlayers: 4, Visibility: proto.VisibilityPrivate,
	})
	priv.roomState()

	browser := dial(t, srv)
	browser.hello("g", "1", "browser")
	browser.sendJSON(proto.OpRoomList, proto.RoomListRequest{})

	var list proto.RoomListResponse
	if err := json.Unmarshal(browser.expect(proto.OpRoomListOut).Payload, &list); err != nil {
		t.Fatalf("room list: %v", err)
	}
	if len(list.Rooms) != 1 {
		t.Fatalf("listed %d rooms, want 1 public", len(list.Rooms))
	}
	if list.Rooms[0].Name != "public one" {
		t.Fatalf("listed %q, want the public room", list.Rooms[0].Name)
	}

	browser.sendJSON(proto.OpRoomList, proto.RoomListRequest{Tags: map[string]string{"mode": "coop"}})
	if err := json.Unmarshal(browser.expect(proto.OpRoomListOut).Payload, &list); err != nil {
		t.Fatalf("room list: %v", err)
	}
	if len(list.Rooms) != 0 {
		t.Fatalf("tag filter returned %d rooms, want 0", len(list.Rooms))
	}
}

func TestGameVersionIsolatesRooms(t *testing.T) {
	srv := newServer(t, config.New())

	oldBuild := dial(t, srv)
	oldBuild.hello("g", "1.0.0", "old")
	oldBuild.sendJSON(proto.OpRoomCreate, proto.RoomCreate{MaxPlayers: 4})
	code := oldBuild.roomState().Code

	newBuild := dial(t, srv)
	newBuild.hello("g", "2.0.0", "new")
	newBuild.sendJSON(proto.OpRoomJoin, proto.RoomJoin{Code: code})

	f := newBuild.read()
	if f.Op != proto.OpError {
		t.Fatalf("cross-version join returned %s, want ERROR", f.Op)
	}
	var e proto.Error
	json.Unmarshal(f.Payload, &e)
	if e.Code != proto.ErrRoomNotFound {
		t.Fatalf("error code = %s, want room_not_found", e.Code)
	}
}

func TestPingIsEchoedWithServerTime(t *testing.T) {
	srv := newServer(t, config.New())

	c := dial(t, srv)
	c.hello("g", "1", "c")

	const clientTime uint64 = 1234567890123
	payload := make([]byte, 8)
	for i := 0; i < 8; i++ {
		payload[i] = byte(clientTime >> (8 * i))
	}
	c.send(proto.OpPing, payload)

	f := c.expect(proto.OpPong)
	echoed, err := proto.DecodePing(f.Payload)
	if err != nil {
		t.Fatalf("decode pong: %v", err)
	}
	if echoed != clientTime {
		t.Fatalf("echoed client time = %d, want %d", echoed, clientTime)
	}
	if len(f.Payload) < 16 {
		t.Fatalf("pong payload is %d bytes, want 16", len(f.Payload))
	}
}

func TestFrameBeforeHelloIsRejected(t *testing.T) {
	srv := newServer(t, config.New())

	c := dial(t, srv)
	c.sendJSON(proto.OpRoomCreate, proto.RoomCreate{MaxPlayers: 4})

	f := c.read()
	if f.Op != proto.OpError {
		t.Fatalf("got %s, want ERROR", f.Op)
	}
	var e proto.Error
	json.Unmarshal(f.Payload, &e)
	if e.Code != proto.ErrBadFrame {
		t.Fatalf("error code = %s, want bad_frame", e.Code)
	}
}

func TestProtocolMismatchIsRejected(t *testing.T) {
	srv := newServer(t, config.New())

	c := dial(t, srv)
	c.sendJSON(proto.OpHello, proto.Hello{
		Protocol: proto.Version + 99, Game: "g", ClientID: "c",
	})

	f := c.read()
	var e proto.Error
	json.Unmarshal(f.Payload, &e)
	if e.Code != proto.ErrProtocolMismatch {
		t.Fatalf("error code = %s, want protocol_mismatch", e.Code)
	}
}

func TestPerGameAPIKeyIsEnforced(t *testing.T) {
	cfg := config.New()
	cfg.Games["locked"] = config.GameConfig{APIKey: "s3cret"}
	srv := newServer(t, cfg)

	wrong := dial(t, srv)
	wrong.sendJSON(proto.OpHello, proto.Hello{
		Protocol: proto.Version, Game: "locked", ClientID: "c", Auth: "nope",
	})
	var e proto.Error
	json.Unmarshal(wrong.read().Payload, &e)
	if e.Code != proto.ErrUnauthorized {
		t.Fatalf("error code = %s, want unauthorized", e.Code)
	}

	right := dial(t, srv)
	right.sendJSON(proto.OpHello, proto.Hello{
		Protocol: proto.Version, Game: "locked", ClientID: "c", Auth: "s3cret",
	})
	right.expect(proto.OpWelcome)

	// An unregistered game still connects while allow_unregistered is on.
	open := dial(t, srv)
	open.hello("anything-else", "1", "c")
}

func TestUnregisteredGameRejectedWhenDisallowed(t *testing.T) {
	cfg := config.New()
	cfg.Default.AllowUnregistered = false
	cfg.Games["known"] = config.GameConfig{}
	srv := newServer(t, cfg)

	c := dial(t, srv)
	c.sendJSON(proto.OpHello, proto.Hello{
		Protocol: proto.Version, Game: "stranger", ClientID: "c",
	})
	var e proto.Error
	json.Unmarshal(c.read().Payload, &e)
	if e.Code != proto.ErrUnknownGame {
		t.Fatalf("error code = %s, want unknown_game", e.Code)
	}
}

func TestRelayOutsideRoomIsRejected(t *testing.T) {
	srv := newServer(t, config.New())

	c := dial(t, srv)
	c.hello("g", "1", "c")
	c.send(proto.OpRelay, relayPayload(0, 0, proto.Reliable, []byte("stray")))

	var e proto.Error
	json.Unmarshal(c.read().Payload, &e)
	if e.Code != proto.ErrNotInRoom {
		t.Fatalf("error code = %s, want not_in_room", e.Code)
	}
}

func TestUnknownOpcodeIsIgnored(t *testing.T) {
	srv := newServer(t, config.New())

	c := dial(t, srv)
	c.hello("g", "1", "c")

	// A future opcode must not kill the connection.
	c.send(proto.Op(0x7E), []byte("from a newer client"))

	c.send(proto.OpPing, make([]byte, 8))
	if f := c.expect(proto.OpPong); f.Op != proto.OpPong {
		t.Fatal("connection did not survive an unknown opcode")
	}
}

func TestRoomFullIsReported(t *testing.T) {
	srv := newServer(t, config.New())

	host := dial(t, srv)
	host.hello("g", "1", "host")
	host.sendJSON(proto.OpRoomCreate, proto.RoomCreate{MaxPlayers: 1})
	code := host.roomState().Code

	guest := dial(t, srv)
	guest.hello("g", "1", "guest")
	guest.sendJSON(proto.OpRoomJoin, proto.RoomJoin{Code: code})

	var e proto.Error
	json.Unmarshal(guest.read().Payload, &e)
	if e.Code != proto.ErrRoomFull {
		t.Fatalf("error code = %s, want room_full", e.Code)
	}
}

func TestWrongPasswordIsReported(t *testing.T) {
	srv := newServer(t, config.New())

	host := dial(t, srv)
	host.hello("g", "1", "host")
	host.sendJSON(proto.OpRoomCreate, proto.RoomCreate{MaxPlayers: 4, Password: "open-sesame"})
	code := host.roomState().Code

	guest := dial(t, srv)
	guest.hello("g", "1", "guest")
	guest.sendJSON(proto.OpRoomJoin, proto.RoomJoin{Code: code, Password: "wrong"})

	var e proto.Error
	json.Unmarshal(guest.read().Payload, &e)
	if e.Code != proto.ErrWrongPassword {
		t.Fatalf("error code = %s, want wrong_password", e.Code)
	}

	ok := dial(t, srv)
	ok.hello("g", "1", "ok")
	ok.sendJSON(proto.OpRoomJoin, proto.RoomJoin{Code: code, Password: "open-sesame"})
	if st := ok.roomState(); st.SelfPeerID != 2 {
		t.Fatalf("peer id = %d, want 2", st.SelfPeerID)
	}
}

func TestJoinByLowercaseCode(t *testing.T) {
	srv := newServer(t, config.New())

	host := dial(t, srv)
	host.hello("g", "1", "host")
	host.sendJSON(proto.OpRoomCreate, proto.RoomCreate{MaxPlayers: 4})
	code := host.roomState().Code

	guest := dial(t, srv)
	guest.hello("g", "1", "guest")
	guest.sendJSON(proto.OpRoomJoin, proto.RoomJoin{Code: strings.ToLower(code)})
	if st := guest.roomState(); st.SelfPeerID != 2 {
		t.Fatalf("peer id = %d, want 2", st.SelfPeerID)
	}
}

func TestDisconnectNotifiesRoom(t *testing.T) {
	srv := newResumeServer(t, config.New(), 50*time.Millisecond)

	host := dial(t, srv)
	host.hello("g", "1", "host")
	host.sendJSON(proto.OpRoomCreate, proto.RoomCreate{MaxPlayers: 4})
	code := host.roomState().Code

	guest := dial(t, srv)
	guest.hello("g", "1", "guest")
	guest.sendJSON(proto.OpRoomJoin, proto.RoomJoin{Code: code})
	guest.roomState()
	host.expect(proto.OpPeerJoin)

	guest.ws.CloseNow()

	var leave proto.PeerLeave
	if err := json.Unmarshal(host.expect(proto.OpPeerLeave).Payload, &leave); err != nil {
		t.Fatalf("peer leave: %v", err)
	}
	if leave.Reason != proto.ReasonDisconnected {
		t.Fatalf("reason = %q, want %q", leave.Reason, proto.ReasonDisconnected)
	}
}

func fragmentPayload(
	target int32, channel uint8, mode proto.TransferMode,
	msgID, index, count uint16, total uint32, slice []byte,
) []byte {
	buf := append(relayPayload(target, channel, mode, nil), make([]byte, 10)...)
	binary.LittleEndian.PutUint16(buf[6:8], msgID)
	binary.LittleEndian.PutUint16(buf[8:10], index)
	binary.LittleEndian.PutUint16(buf[10:12], count)
	binary.LittleEndian.PutUint32(buf[12:16], total)
	return append(buf, slice...)
}

// Two peers in a room, one sending a packet in two pieces. The relay forwards each
// piece as it arrives; putting them back together is the client's job.
func TestFragmentsReachTheTargetInOrder(t *testing.T) {
	srv := newServer(t, config.New())

	host := dial(t, srv)
	host.hello("spacewar", "1.0.0", "host")
	host.sendJSON(proto.OpRoomCreate, proto.RoomCreate{MaxPlayers: 4})
	code := host.roomState().Code

	guest := dial(t, srv)
	guest.hello("spacewar", "1.0.0", "guest")
	guest.sendJSON(proto.OpRoomJoin, proto.RoomJoin{Code: code})
	guest.roomState()
	host.expect(proto.OpPeerJoin)

	host.send(proto.OpRelayFragment, fragmentPayload(2, 3, proto.Unreliable, 9, 0, 2, 9, []byte("front")))
	host.send(proto.OpRelayFragment, fragmentPayload(2, 3, proto.Unreliable, 9, 1, 2, 9, []byte("back")))

	var rebuilt []byte
	for i := uint16(0); i < 2; i++ {
		h, slice, err := proto.DecodeRelayFragment(guest.expect(proto.OpRelayFragmentOut).Payload)
		if err != nil {
			t.Fatalf("decode fragment: %v", err)
		}
		if h.Peer != 1 {
			t.Errorf("from = %d, want 1", h.Peer)
		}
		if h.Channel != 3 || h.Mode != proto.Unreliable {
			t.Errorf("channel/mode = %d/%d, want 3/Unreliable", h.Channel, h.Mode)
		}
		if h.MessageID != 9 || h.Index != i || h.Count != 2 {
			t.Errorf("msg %d idx %d of %d, want 9/%d/2", h.MessageID, h.Index, h.Count, i)
		}
		rebuilt = append(rebuilt, slice...)
	}
	if string(rebuilt) != "frontback" {
		t.Fatalf("rebuilt = %q, want frontback", rebuilt)
	}
}

func TestFragmentWithIndexOutsideItsMessageIsRejected(t *testing.T) {
	srv := newServer(t, config.New())

	c := dial(t, srv)
	c.hello("spacewar", "1.0.0", "c")
	c.sendJSON(proto.OpRoomCreate, proto.RoomCreate{MaxPlayers: 2})
	c.roomState()

	c.send(proto.OpRelayFragment, fragmentPayload(0, 0, proto.Reliable, 1, 4, 2, 10, []byte("stray")))

	var e proto.Error
	json.Unmarshal(c.read().Payload, &e)
	if e.Code != proto.ErrBadFrame {
		t.Fatalf("error code = %s, want bad_frame", e.Code)
	}
}

// The length a sender declares is what bounds the message, since the relay holds no
// fragments of its own to measure. Bounding it by fragment count instead would refuse
// messages that fit, because the header a fragment carries eats into every slice.
func TestMessageCeilingIsExact(t *testing.T) {
	cfg := config.New()
	cfg.Default.MaxMessageSize = cfg.Default.MaxPacketSize * 4
	ceiling := uint32(cfg.Default.MaxMessageSize)
	srv := newServer(t, cfg)

	host := dial(t, srv)
	host.hello("spacewar", "1.0.0", "host")
	host.sendJSON(proto.OpRoomCreate, proto.RoomCreate{MaxPlayers: 2})
	code := host.roomState().Code

	guest := dial(t, srv)
	guest.hello("spacewar", "1.0.0", "guest")
	guest.sendJSON(proto.OpRoomJoin, proto.RoomJoin{Code: code})
	guest.roomState()
	host.expect(proto.OpPeerJoin)

	host.send(proto.OpRelayFragment,
		fragmentPayload(2, 0, proto.Reliable, 1, 0, 2, ceiling, []byte("at the limit")))
	h, _, err := proto.DecodeRelayFragment(guest.expect(proto.OpRelayFragmentOut).Payload)
	if err != nil {
		t.Fatalf("decode fragment: %v", err)
	}
	if h.Total != ceiling {
		t.Fatalf("total = %d, want %d", h.Total, ceiling)
	}

	host.send(proto.OpRelayFragment,
		fragmentPayload(2, 0, proto.Reliable, 2, 0, 2, ceiling+1, []byte("one over")))

	var e proto.Error
	json.Unmarshal(host.read().Payload, &e)
	if e.Code != proto.ErrPacketTooLarge {
		t.Fatalf("error code = %s, want packet_too_large", e.Code)
	}
}

// Every slice carries at least one byte, so more slices than bytes cannot be honest.
func TestFragmentCountBeyondItsMessageLengthIsRejected(t *testing.T) {
	srv := newServer(t, config.New())

	c := dial(t, srv)
	c.hello("spacewar", "1.0.0", "c")
	c.sendJSON(proto.OpRoomCreate, proto.RoomCreate{MaxPlayers: 2})
	c.roomState()

	c.send(proto.OpRelayFragment, fragmentPayload(0, 0, proto.Reliable, 1, 0, 8, 4, []byte("short")))

	var e proto.Error
	json.Unmarshal(c.read().Payload, &e)
	if e.Code != proto.ErrBadFrame {
		t.Fatalf("error code = %s, want bad_frame", e.Code)
	}
}

func TestWelcomeAdvertisesTheMessageCeiling(t *testing.T) {
	srv := newServer(t, config.New())

	c := dial(t, srv)
	welcome := c.hello("spacewar", "1.0.0", "c")

	if welcome.Limits.MaxMessageSize < welcome.Limits.MaxPacketSize {
		t.Fatalf("max_message_size = %d, want at least max_packet_size %d",
			welcome.Limits.MaxMessageSize, welcome.Limits.MaxPacketSize)
	}
}

func TestResumeReplaysWhatTheDropMissed(t *testing.T) {
	srv := newServer(t, config.New())

	host := dial(t, srv)
	w := host.hello("g", "1", "host")
	host.sendJSON(proto.OpRoomCreate, proto.RoomCreate{MaxPlayers: 4})
	code := host.roomState().Code

	guest := dial(t, srv)
	guest.hello("g", "1", "guest")
	guest.sendJSON(proto.OpRoomJoin, proto.RoomJoin{Code: code})
	guest.roomState()
	host.expect(proto.OpPeerJoin)

	guest.send(proto.OpRelay, relayPayload(1, 0, proto.Reliable, []byte("a")))
	host.expect(proto.OpRelayOut)
	host.ws.CloseNow()
	time.Sleep(50 * time.Millisecond)

	guest.send(proto.OpRelay, relayPayload(1, 0, proto.Unreliable, []byte("u")))
	guest.send(proto.OpRelay, relayPayload(1, 0, proto.Reliable, []byte("b")))
	time.Sleep(50 * time.Millisecond)

	back := dial(t, srv)
	rw := back.resume("g", "1", "host", w.SessionID, 2)
	if !rw.Resumed || rw.SessionID != w.SessionID || rw.Received != 0 {
		t.Fatalf("welcome = %+v, want resumed %s with nothing received", rw, w.SessionID)
	}
	_, packet, err := proto.DecodeRelay(back.expect(proto.OpRelayOut).Payload)
	if err != nil || string(packet) != "b" {
		t.Fatalf("replayed %q (%v), want the reliable packet sent while away", packet, err)
	}

	back.send(proto.OpRelay, relayPayload(2, 0, proto.Reliable, []byte("c")))
	f := guest.read()
	if f.Op != proto.OpRelayOut {
		t.Fatalf("guest saw %s, want the resumed host's packet and no PEER_LEAVE", f.Op)
	}
}

func TestResumeFromBeyondTheHistoryStartsFresh(t *testing.T) {
	srv := newServer(t, config.New())

	first := dial(t, srv)
	w := first.hello("g", "1", "solo")
	first.sendJSON(proto.OpRoomCreate, proto.RoomCreate{MaxPlayers: 4})
	first.roomState()
	first.ws.CloseNow()
	time.Sleep(50 * time.Millisecond)

	back := dial(t, srv)
	rw := back.resume("g", "1", "solo", w.SessionID, 99)
	if rw.Resumed || rw.SessionID == w.SessionID {
		t.Fatalf("welcome = %+v, want a fresh session", rw)
	}
}

func TestResumeNeedsTheSameClient(t *testing.T) {
	srv := newServer(t, config.New())

	first := dial(t, srv)
	w := first.hello("g", "1", "owner")
	first.sendJSON(proto.OpRoomCreate, proto.RoomCreate{MaxPlayers: 4})
	first.roomState()
	first.ws.CloseNow()
	time.Sleep(50 * time.Millisecond)

	thief := dial(t, srv)
	if rw := thief.resume("g", "1", "thief", w.SessionID, 0); rw.Resumed {
		t.Fatalf("another client resumed the seat: %+v", rw)
	}
}
