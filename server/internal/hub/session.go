package hub

import (
	"sync"
	"time"

	"github.com/bearlikelion/melay/internal/proto"
	"github.com/bearlikelion/melay/internal/room"
)

// DefaultResumeWindow is how long a dropped client's seat is held for it to come back.
const DefaultResumeWindow = 30 * time.Second

// historyLimit bounds the reliable frames a session keeps for replay after a drop.
const historyLimit = 8 << 20

type sentFrame struct {
	seq  uint64
	data []byte
}

// session is a client's identity and room seat, which outlive any one connection.
// Reliable frames to and from it are counted so a resumed connection replays exactly
// what the old one lost.
type session struct {
	sessionID   string
	clientID    string
	game        string
	gameVersion string
	displayName string
	platform    string
	startedAt   time.Time

	stateMu sync.RWMutex
	room    *room.Room
	peerID  int32

	mu        sync.Mutex
	conn      *Conn
	ended     bool
	hold      *time.Timer
	sent      []sentFrame
	sentBytes int
	sentSeq   uint64
	recvSeq   uint64
}

// SessionID implements room.Peer.
func (s *session) SessionID() string { return s.sessionID }

// DisplayName implements room.Peer.
func (s *session) DisplayName() string { return s.displayName }

// Platform implements room.Peer.
func (s *session) Platform() string { return s.platform }

// Send implements room.Peer. Reliable frames are numbered and kept, and while the
// seat is held they wait in the history for the client to resume.
func (s *session) Send(frame []byte, mode proto.TransferMode) {
	s.mu.Lock()
	defer s.mu.Unlock()

	if mode == proto.Reliable {
		s.sentSeq++
		s.sent = append(s.sent, sentFrame{seq: s.sentSeq, data: frame})
		s.sentBytes += len(frame)
		for s.sentBytes > historyLimit {
			s.sentBytes -= len(s.sent[0].data)
			s.sent = s.sent[1:]
		}
	}
	if s.conn != nil {
		s.conn.Send(frame, mode)
	}
}

// noteRecv counts one reliable frame from c, reporting false when c has been replaced
// and the frame must be dropped as a duplicate of what the client will replay.
func (s *session) noteRecv(c *Conn) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.conn != c {
		return false
	}
	s.recvSeq++
	return true
}

// attach binds the first connection to a fresh session.
func (s *session) attach(c *Conn) {
	s.mu.Lock()
	s.conn = c
	s.mu.Unlock()
}

// resume moves the session onto c, queues the WELCOME and replays every reliable
// frame after received. It fails when the client is further behind than the history.
func (s *session) resume(c *Conn, received uint64, welcome proto.Welcome) (old *Conn, ok bool) {
	s.mu.Lock()
	defer s.mu.Unlock()

	oldest := s.sentSeq + 1
	if len(s.sent) > 0 {
		oldest = s.sent[0].seq
	}
	if s.ended || received > s.sentSeq || received+1 < oldest {
		return nil, false
	}
	if s.hold != nil {
		s.hold.Stop()
		s.hold = nil
	}

	old = s.conn
	s.conn = c
	welcome.Resumed = true
	welcome.Received = s.recvSeq
	c.sendJSON(proto.OpWelcome, welcome)
	for _, f := range s.sent {
		if f.seq > received {
			c.enqueue(f.data)
		}
	}
	return old, true
}

// detach unbinds c, reporting false when another connection already owns the session.
func (s *session) detach(c *Conn) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.conn != c || s.ended {
		return false
	}
	s.conn = nil
	return true
}

// holdFor keeps the seat open, calling expire unless a resume arrives first.
func (s *session) holdFor(window time.Duration, expire func()) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.hold = time.AfterFunc(window, expire)
}

// end marks the session finished, reporting false when a resume got there first.
func (s *session) end() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.conn != nil || s.ended {
		return false
	}
	s.ended = true
	if s.hold != nil {
		s.hold.Stop()
		s.hold = nil
	}
	return true
}

// currentRoom returns the room this session is in, if any.
func (s *session) currentRoom() (*room.Room, int32) {
	s.stateMu.RLock()
	defer s.stateMu.RUnlock()
	return s.room, s.peerID
}

func (s *session) setRoom(r *room.Room, peerID int32) {
	s.stateMu.Lock()
	s.room = r
	s.peerID = peerID
	s.stateMu.Unlock()
}
