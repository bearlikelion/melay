package hub

import (
	"io"
	"log/slog"
	"testing"

	"github.com/bearlikelion/melay/internal/proto"
)

func newTestConn() *Conn {
	return &Conn{
		session: &session{},
		log:     slog.New(slog.NewTextHandler(io.Discard, nil)),
		notify:  make(chan struct{}, 1),
	}
}

func queuedModes(c *Conn) []proto.TransferMode {
	c.outMu.Lock()
	defer c.outMu.Unlock()

	out := make([]proto.TransferMode, len(c.outQ))
	for i, f := range c.outQ {
		out[i] = f.mode
	}
	return out
}

func TestSendQueuesBelowSoftLimit(t *testing.T) {
	c := newTestConn()

	for i := 0; i < softLimit-1; i++ {
		c.Send([]byte("x"), proto.Reliable)
	}

	if got := len(queuedModes(c)); got != softLimit-1 {
		t.Fatalf("queued %d frames, want %d", got, softLimit-1)
	}
	if c.droppedCount() != 0 {
		t.Fatalf("dropped %d frames below the soft limit, want 0", c.droppedCount())
	}
}

// Past the soft limit the oldest fully unreliable frame goes first.
func TestShedPrefersUnreliableOverUnreliableOrdered(t *testing.T) {
	c := newTestConn()

	c.Send([]byte("unreliable"), proto.Unreliable)
	c.Send([]byte("ordered"), proto.UnreliableOrdered)
	for i := 0; i < softLimit-2; i++ {
		c.Send([]byte("reliable"), proto.Reliable)
	}

	// The queue is now at the soft limit, so this send must shed one frame.
	c.Send([]byte("trigger"), proto.Reliable)

	if c.droppedCount() != 1 {
		t.Fatalf("dropped %d frames, want 1", c.droppedCount())
	}
	modes := queuedModes(c)
	for _, m := range modes {
		if m == proto.Unreliable {
			t.Fatal("an unreliable frame survived while an ordered one was available to keep")
		}
	}
	var ordered int
	for _, m := range modes {
		if m == proto.UnreliableOrdered {
			ordered++
		}
	}
	if ordered != 1 {
		t.Fatalf("unreliable_ordered frames = %d, want 1 still queued", ordered)
	}
}

func TestShedFallsBackToUnreliableOrdered(t *testing.T) {
	c := newTestConn()

	c.Send([]byte("ordered"), proto.UnreliableOrdered)
	for i := 0; i < softLimit-1; i++ {
		c.Send([]byte("reliable"), proto.Reliable)
	}
	c.Send([]byte("trigger"), proto.Reliable)

	if c.droppedCount() != 1 {
		t.Fatalf("dropped %d frames, want 1", c.droppedCount())
	}
	for _, m := range queuedModes(c) {
		if m != proto.Reliable {
			t.Fatalf("queue still holds a %d frame, want only reliable", m)
		}
	}
}

// Reliable traffic is never shed, so an all-reliable backlog grows to the hard
// limit and then closes the connection rather than silently losing RPCs.
func TestReliableBacklogIsNeverShed(t *testing.T) {
	c := newTestConn()

	for i := 0; i < hardLimit-1; i++ {
		c.Send([]byte("reliable"), proto.Reliable)
	}

	if c.droppedCount() != 0 {
		t.Fatalf("dropped %d reliable frames, want 0", c.droppedCount())
	}
	if len(queuedModes(c)) != hardLimit-1 {
		t.Fatalf("queued %d frames, want %d", len(queuedModes(c)), hardLimit-1)
	}
}

func TestHardLimitClosesConnection(t *testing.T) {
	c := newTestConn()

	for i := 0; i < hardLimit+8; i++ {
		c.Send([]byte("reliable"), proto.Reliable)
	}

	c.outMu.Lock()
	closed := c.closed
	c.outMu.Unlock()

	if !closed {
		t.Fatal("connection stayed open past the hard limit")
	}
}

func TestSendAfterCloseIsDropped(t *testing.T) {
	c := newTestConn()
	c.closeSoon(proto.ErrInternal, "test")

	c.Send([]byte("late"), proto.Reliable)

	if got := len(queuedModes(c)); got != 0 {
		t.Fatalf("queued %d frames after close, want 0", got)
	}
}

func TestSanitizeStripsControlCharactersAndTruncates(t *testing.T) {
	cases := []struct {
		in   string
		max  int
		want string
	}{
		{"  Mark  ", 32, "Mark"},
		{"bad\x00name", 32, "badname"},
		{"line\nbreak", 32, "linebreak"},
		{"abcdefghij", 4, "abcd"},
		{"", 32, ""},
	}
	for _, tc := range cases {
		if got := sanitize(tc.in, tc.max); got != tc.want {
			t.Errorf("sanitize(%q, %d) = %q, want %q", tc.in, tc.max, got, tc.want)
		}
	}
}

func TestSanitizeTagsBoundsCountAndLength(t *testing.T) {
	tags := map[string]string{}
	for i := 0; i < 40; i++ {
		tags[string(rune('a'+i%26))+string(rune('0'+i/26))] = "v"
	}

	got := sanitizeTags(tags)
	if len(got) > 16 {
		t.Fatalf("kept %d tags, want at most 16", len(got))
	}

	long := sanitizeTags(map[string]string{"k": string(make([]byte, 200))})
	for _, v := range long {
		if len(v) > 64 {
			t.Fatalf("tag value length = %d, want at most 64", len(v))
		}
	}
}
