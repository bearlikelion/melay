package room

import (
	"sort"
	"testing"

	"github.com/bearlikelion/melay/internal/proto"
)

// fakePeer records what the room sent it.
type fakePeer struct {
	session  string
	received [][]byte
	modes    []proto.TransferMode
}

func (f *fakePeer) SessionID() string   { return f.session }
func (f *fakePeer) DisplayName() string { return f.session }
func (f *fakePeer) Platform() string    { return "test" }

func (f *fakePeer) Send(frame []byte, mode proto.TransferMode) {
	cp := make([]byte, len(frame))
	copy(cp, frame)
	f.received = append(f.received, cp)
	f.modes = append(f.modes, mode)
}

// newTestRoom builds a room with n peers and returns it alongside the peers by id.
func newTestRoom(t *testing.T, n int) (*Manager, *Room, map[int32]*fakePeer) {
	t.Helper()

	m := NewManager()
	r, err := m.Create(CreateOptions{
		Game:        "testgame",
		GameVersion: "1.0.0",
		MaxPlayers:  16,
		MaxRooms:    10,
	})
	if err != nil {
		t.Fatalf("create room: %v", err)
	}

	peers := map[int32]*fakePeer{}
	for i := 0; i < n; i++ {
		p := &fakePeer{session: string(rune('a' + i))}
		id, err := r.Join(p)
		if err != nil {
			t.Fatalf("join %d: %v", i, err)
		}
		peers[id] = p
	}
	return m, r, peers
}

// receivedIDs lists which peer ids got at least one frame.
func receivedIDs(peers map[int32]*fakePeer) []int32 {
	var out []int32
	for id, p := range peers {
		if len(p.received) > 0 {
			out = append(out, id)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i] < out[j] })
	return out
}

func equalIDs(a, b []int32) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

func TestJoinAssignsHostIDOneThenAscending(t *testing.T) {
	_, _, peers := newTestRoom(t, 4)

	var ids []int32
	for id := range peers {
		ids = append(ids, id)
	}
	sort.Slice(ids, func(i, j int) bool { return ids[i] < ids[j] })

	want := []int32{1, 2, 3, 4}
	if !equalIDs(ids, want) {
		t.Fatalf("peer ids = %v, want %v", ids, want)
	}
}

func TestRelayBroadcastSkipsSender(t *testing.T) {
	_, r, peers := newTestRoom(t, 4)

	r.Relay(1, 0, 0, proto.Reliable, []byte("hello"))

	got := receivedIDs(peers)
	want := []int32{2, 3, 4}
	if !equalIDs(got, want) {
		t.Fatalf("broadcast reached %v, want %v", got, want)
	}
}

func TestRelayUnicastReachesOnlyTarget(t *testing.T) {
	_, r, peers := newTestRoom(t, 4)

	r.Relay(1, 3, 0, proto.Reliable, []byte("hello"))

	got := receivedIDs(peers)
	want := []int32{3}
	if !equalIDs(got, want) {
		t.Fatalf("unicast reached %v, want %v", got, want)
	}
}

// The exclusion case is the one nakama-godot's bridge gets wrong, so it is tested
// explicitly rather than folded into the broadcast test.
func TestRelayNegativeTargetExcludesThatPeerAndSender(t *testing.T) {
	_, r, peers := newTestRoom(t, 4)

	r.Relay(1, -3, 0, proto.Reliable, []byte("hello"))

	got := receivedIDs(peers)
	want := []int32{2, 4}
	if !equalIDs(got, want) {
		t.Fatalf("exclusion reached %v, want %v", got, want)
	}
}

func TestRelayToSelfIsDropped(t *testing.T) {
	_, r, peers := newTestRoom(t, 3)

	r.Relay(2, 2, 0, proto.Reliable, []byte("hello"))

	if got := receivedIDs(peers); len(got) != 0 {
		t.Fatalf("self-addressed relay reached %v, want nobody", got)
	}
}

func TestRelayToUnknownPeerIsDropped(t *testing.T) {
	_, r, peers := newTestRoom(t, 3)

	r.Relay(1, 99, 0, proto.Reliable, []byte("hello"))

	if got := receivedIDs(peers); len(got) != 0 {
		t.Fatalf("relay to unknown peer reached %v, want nobody", got)
	}
}

func TestRelayPreservesHeaderAndPayload(t *testing.T) {
	_, r, peers := newTestRoom(t, 2)

	payload := []byte{0xDE, 0xAD, 0xBE, 0xEF}
	r.Relay(1, 2, 7, proto.UnreliableOrdered, payload)

	frames := peers[2].received
	if len(frames) != 1 {
		t.Fatalf("peer 2 got %d frames, want 1", len(frames))
	}

	f, err := proto.Decode(frames[0])
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	if f.Op != proto.OpRelayOut {
		t.Fatalf("op = %s, want RELAY_OUT", f.Op)
	}

	h, packet, err := proto.DecodeRelay(f.Payload)
	if err != nil {
		t.Fatalf("decode relay: %v", err)
	}
	if h.Peer != 1 {
		t.Errorf("from = %d, want 1", h.Peer)
	}
	if h.Channel != 7 {
		t.Errorf("channel = %d, want 7", h.Channel)
	}
	if h.Mode != proto.UnreliableOrdered {
		t.Errorf("mode = %d, want UnreliableOrdered", h.Mode)
	}
	if string(packet) != string(payload) {
		t.Errorf("packet = %x, want %x", packet, payload)
	}
	// The mode is passed through to Send so the transport can apply its drop policy.
	if peers[2].modes[0] != proto.UnreliableOrdered {
		t.Errorf("send mode = %d, want UnreliableOrdered", peers[2].modes[0])
	}
}

func TestRoomFullRejectsExtraPeer(t *testing.T) {
	m := NewManager()
	r, err := m.Create(CreateOptions{
		Game: "testgame", GameVersion: "1.0.0", MaxPlayers: 2, MaxRooms: 10,
	})
	if err != nil {
		t.Fatalf("create: %v", err)
	}

	for i := 0; i < 2; i++ {
		if _, err := r.Join(&fakePeer{session: "x"}); err != nil {
			t.Fatalf("join %d: %v", i, err)
		}
	}
	if _, err := r.Join(&fakePeer{session: "overflow"}); err != ErrRoomFull {
		t.Fatalf("third join err = %v, want ErrRoomFull", err)
	}
}

func TestPeerIDsAreNotReusedAfterLeave(t *testing.T) {
	_, r, _ := newTestRoom(t, 3)

	r.Leave(2)
	id, err := r.Join(&fakePeer{session: "new"})
	if err != nil {
		t.Fatalf("join: %v", err)
	}
	if id == 2 {
		t.Fatalf("peer id 2 was reused after its owner left")
	}
	if id != 4 {
		t.Fatalf("new peer id = %d, want 4", id)
	}
}

func TestLastPeerLeavingEmptiesRoom(t *testing.T) {
	_, r, _ := newTestRoom(t, 2)

	if empty := r.Leave(1); empty {
		t.Fatal("room reported empty with one peer still in it")
	}
	if empty := r.Leave(2); !empty {
		t.Fatal("room did not report empty after the last peer left")
	}
}

func TestVersionScopingIsolatesRooms(t *testing.T) {
	m := NewManager()
	r, err := m.Create(CreateOptions{
		Game: "testgame", GameVersion: "1.0.0", MaxPlayers: 4, MaxRooms: 10,
	})
	if err != nil {
		t.Fatalf("create: %v", err)
	}

	if _, ok := m.FindByCode("testgame", "1.0.0", r.Code); !ok {
		t.Fatal("room not findable at its own version")
	}
	if _, ok := m.FindByCode("testgame", "2.0.0", r.Code); ok {
		t.Fatal("room was findable from a different game version")
	}
	if _, ok := m.FindByCode("othergame", "1.0.0", r.Code); ok {
		t.Fatal("room was findable from a different game")
	}
}

func TestFindByCodeIsCaseInsensitive(t *testing.T) {
	m := NewManager()
	r, err := m.Create(CreateOptions{
		Game: "testgame", GameVersion: "1.0.0", MaxPlayers: 4, MaxRooms: 10,
	})
	if err != nil {
		t.Fatalf("create: %v", err)
	}

	lower := ""
	for _, c := range r.Code {
		lower += string(c | 0x20)
	}
	if _, ok := m.FindByCode("testgame", "1.0.0", lower); !ok {
		t.Fatalf("lowercase code %q did not resolve", lower)
	}
}

func TestRoomCodeUsesUnambiguousAlphabet(t *testing.T) {
	m := NewManager()
	for i := 0; i < 200; i++ {
		r, err := m.Create(CreateOptions{
			Game: "testgame", GameVersion: "1.0.0", MaxPlayers: 4, MaxRooms: 1000,
		})
		if err != nil {
			t.Fatalf("create %d: %v", i, err)
		}
		if len(r.Code) != codeLength {
			t.Fatalf("code %q length = %d, want %d", r.Code, len(r.Code), codeLength)
		}
		for _, ch := range r.Code {
			if ch == 'I' || ch == 'L' || ch == 'O' || ch == 'U' {
				t.Fatalf("code %q contains ambiguous character %q", r.Code, ch)
			}
		}
	}
}

func TestMaxRoomsIsEnforcedPerGame(t *testing.T) {
	m := NewManager()
	opts := CreateOptions{Game: "capped", GameVersion: "1.0.0", MaxPlayers: 4, MaxRooms: 2}

	for i := 0; i < 2; i++ {
		if _, err := m.Create(opts); err != nil {
			t.Fatalf("create %d: %v", i, err)
		}
	}
	if _, err := m.Create(opts); err != ErrTooManyRooms {
		t.Fatalf("third create err = %v, want ErrTooManyRooms", err)
	}

	// A different game must not be affected by another game's cap.
	other := opts
	other.Game = "uncapped"
	if _, err := m.Create(other); err != nil {
		t.Fatalf("other game create: %v", err)
	}
}

func TestListFiltersByTagsAndVisibility(t *testing.T) {
	m := NewManager()
	base := CreateOptions{Game: "g", GameVersion: "1.0.0", MaxPlayers: 4, MaxRooms: 100}

	pub := base
	pub.Visibility = proto.VisibilityPublic
	pub.Tags = map[string]string{"mode": "ffa", "map": "dust"}
	if _, err := m.Create(pub); err != nil {
		t.Fatalf("create public: %v", err)
	}

	priv := base
	priv.Visibility = proto.VisibilityPrivate
	priv.Tags = map[string]string{"mode": "ffa"}
	if _, err := m.Create(priv); err != nil {
		t.Fatalf("create private: %v", err)
	}

	other := base
	other.Visibility = proto.VisibilityPublic
	other.Tags = map[string]string{"mode": "coop"}
	if _, err := m.Create(other); err != nil {
		t.Fatalf("create other: %v", err)
	}

	if got := m.List("g", "1.0.0", proto.RoomListRequest{}); len(got) != 2 {
		t.Fatalf("unfiltered list returned %d rooms, want 2 public", len(got))
	}

	ffa := m.List("g", "1.0.0", proto.RoomListRequest{Tags: map[string]string{"mode": "ffa"}})
	if len(ffa) != 1 {
		t.Fatalf("mode=ffa returned %d rooms, want 1", len(ffa))
	}
	if ffa[0].Tags["map"] != "dust" {
		t.Fatalf("wrong room matched: %+v", ffa[0])
	}

	none := m.List("g", "1.0.0", proto.RoomListRequest{
		Tags: map[string]string{"mode": "ffa", "map": "nether"},
	})
	if len(none) != 0 {
		t.Fatalf("over-constrained filter returned %d rooms, want 0", len(none))
	}
}

func TestPasswordCheck(t *testing.T) {
	m := NewManager()
	r, err := m.Create(CreateOptions{
		Game: "g", GameVersion: "1.0.0", MaxPlayers: 4, MaxRooms: 10, Password: "hunter2",
	})
	if err != nil {
		t.Fatalf("create: %v", err)
	}

	if !r.HasPassword() {
		t.Fatal("HasPassword = false for a password-protected room")
	}
	if !r.CheckPassword("hunter2") {
		t.Error("correct password rejected")
	}
	if r.CheckPassword("wrong") {
		t.Error("wrong password accepted")
	}

	open, err := m.Create(CreateOptions{Game: "g", GameVersion: "1.0.0", MaxPlayers: 4, MaxRooms: 10})
	if err != nil {
		t.Fatalf("create open: %v", err)
	}
	if !open.CheckPassword("") {
		t.Error("open room rejected an empty password")
	}
	if !open.CheckPassword("anything") {
		t.Error("open room rejected a supplied password")
	}
}
