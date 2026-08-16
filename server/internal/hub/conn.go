package hub

import (
	"context"
	"encoding/json"
	"log/slog"
	"sync"
	"time"

	"github.com/bearlikelion/melay/internal/proto"
	"github.com/bearlikelion/melay/internal/room"
	"github.com/coder/websocket"
)

// Outbound queue bounds. Past softLimit the connection sheds unreliable traffic;
// past hardLimit it is a lost cause and gets closed.
const (
	softLimit = 256
	hardLimit = 1024
)

// writeTimeout bounds a single frame write, so one wedged socket cannot pin a goroutine.
const writeTimeout = 10 * time.Second

type outFrame struct {
	data []byte
	mode proto.TransferMode
}

// Conn is one client connection: its identity, its room membership, and its
// bounded outbound queue.
type Conn struct {
	ws  *websocket.Conn
	hub *Hub
	log *slog.Logger

	sessionID   string
	clientID    string
	game        string
	gameVersion string
	displayName string
	platform    string
	limits      proto.Limits
	connectedAt time.Time

	// helloDone gates every opcode other than HELLO.
	helloDone bool

	stateMu sync.RWMutex
	room    *room.Room
	peerID  int32

	outMu     sync.Mutex
	outQ      []outFrame
	dropped   uint64
	closed    bool
	notify    chan struct{}
	closeOnce sync.Once
}

func newConn(ws *websocket.Conn, h *Hub, log *slog.Logger) *Conn {
	return &Conn{
		ws:          ws,
		hub:         h,
		log:         log,
		connectedAt: time.Now(),
		notify:      make(chan struct{}, 1),
	}
}

// SessionID implements room.Peer.
func (c *Conn) SessionID() string { return c.sessionID }

// DisplayName implements room.Peer.
func (c *Conn) DisplayName() string { return c.displayName }

// Platform implements room.Peer.
func (c *Conn) Platform() string { return c.platform }

// Send queues a frame and never blocks. When the queue is over softLimit it sheds
// the oldest unreliable traffic first, so a slow client degrades to stale updates
// instead of stalling the room.
func (c *Conn) Send(frame []byte, mode proto.TransferMode) {
	c.outMu.Lock()
	if c.closed {
		c.outMu.Unlock()
		return
	}

	if len(c.outQ) >= softLimit {
		if !c.shedLocked() && len(c.outQ) >= hardLimit {
			c.outMu.Unlock()
			c.closeWithError(proto.ErrSlowConsumer, "outbound queue exceeded hard limit")
			return
		}
	}

	c.outQ = append(c.outQ, outFrame{data: frame, mode: mode})
	c.outMu.Unlock()

	select {
	case c.notify <- struct{}{}:
	default:
	}
}

// shedLocked drops one droppable frame, preferring the oldest fully unreliable one.
// It reports whether anything was dropped.
func (c *Conn) shedLocked() bool {
	for i, f := range c.outQ {
		if f.mode == proto.Unreliable {
			c.outQ = append(c.outQ[:i], c.outQ[i+1:]...)
			c.dropped++
			return true
		}
	}
	for i, f := range c.outQ {
		if f.mode == proto.UnreliableOrdered {
			c.outQ = append(c.outQ[:i], c.outQ[i+1:]...)
			c.dropped++
			return true
		}
	}
	return false
}

// sendJSON marshals and queues a control frame reliably.
func (c *Conn) sendJSON(op proto.Op, v any) {
	payload, err := json.Marshal(v)
	if err != nil {
		c.log.Error("marshal outbound frame", "op", op.String(), "err", err)
		return
	}
	c.Send(proto.EncodeJSON(op, payload), proto.Reliable)
}

// enqueue appends without consulting the queue bounds. Only terminal error frames
// use it, so that reporting an overflow cannot itself overflow the queue.
func (c *Conn) enqueue(frame []byte) {
	c.outMu.Lock()
	if c.closed {
		c.outMu.Unlock()
		return
	}
	c.outQ = append(c.outQ, outFrame{data: frame, mode: proto.Reliable})
	c.outMu.Unlock()

	select {
	case c.notify <- struct{}{}:
	default:
	}
}

// sendError reports a failure. Fatal codes are followed by a close.
func (c *Conn) sendError(code proto.ErrorCode, msg string) {
	if code.Fatal() {
		c.closeWithError(code, msg)
		return
	}
	c.sendJSON(proto.OpError, proto.Error{Code: code, Message: msg})
}

// closeWithError delivers a final error frame and then closes.
func (c *Conn) closeWithError(code proto.ErrorCode, msg string) {
	if payload, err := json.Marshal(proto.Error{Code: code, Message: msg}); err == nil {
		c.enqueue(proto.EncodeJSON(proto.OpError, payload))
	}
	c.closeSoon(code, msg)
}

// closeSoon marks the connection closed and wakes the writer so it can flush and exit.
func (c *Conn) closeSoon(code proto.ErrorCode, msg string) {
	c.closeOnce.Do(func() {
		c.outMu.Lock()
		c.closed = true
		c.outMu.Unlock()
		select {
		case c.notify <- struct{}{}:
		default:
		}
		c.log.Debug("closing connection", "session", c.sessionID, "code", string(code), "msg", msg)
	})
}

// writeLoop drains the outbound queue until the connection closes.
func (c *Conn) writeLoop(ctx context.Context) {
	for {
		c.outMu.Lock()
		batch := c.outQ
		c.outQ = nil
		closed := c.closed
		c.outMu.Unlock()

		for _, f := range batch {
			wctx, cancel := context.WithTimeout(ctx, writeTimeout)
			err := c.ws.Write(wctx, websocket.MessageBinary, f.data)
			cancel()
			if err != nil {
				c.closeSoon(proto.ErrInternal, "write failed")
				return
			}
		}

		if closed {
			return
		}

		select {
		case <-ctx.Done():
			return
		case <-c.notify:
		}
	}
}

// currentRoom returns the room this connection is in, if any.
func (c *Conn) currentRoom() (*room.Room, int32) {
	c.stateMu.RLock()
	defer c.stateMu.RUnlock()
	return c.room, c.peerID
}

func (c *Conn) setRoom(r *room.Room, peerID int32) {
	c.stateMu.Lock()
	c.room = r
	c.peerID = peerID
	c.stateMu.Unlock()
}

// droppedCount is the number of shed frames, for logging on disconnect.
func (c *Conn) droppedCount() uint64 {
	c.outMu.Lock()
	defer c.outMu.Unlock()
	return c.dropped
}
