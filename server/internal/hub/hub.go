// Package hub accepts WebSocket connections and dispatches Melay frames.
package hub

import (
	"context"
	"crypto/rand"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/bearlikelion/melay/internal/config"
	"github.com/bearlikelion/melay/internal/proto"
	"github.com/bearlikelion/melay/internal/room"
	"github.com/bearlikelion/melay/internal/store"
	"github.com/coder/websocket"
)

// handshakeReadLimit applies until HELLO establishes the game's real packet limit.
const handshakeReadLimit = 64 * 1024

// frameOverhead covers the opcode plus the widest fixed header, which is a fragment's.
const frameOverhead = 24

// drainGrace bounds how long a closing connection may spend flushing its queue.
const drainGrace = 5 * time.Second

// Hub owns the connection set and routes frames to rooms.
type Hub struct {
	cfg   *config.Config
	rooms *room.Manager
	store store.Store
	log   *slog.Logger

	mu      sync.RWMutex
	conns   map[*Conn]struct{}
	peakCCU map[string]int
	liveCCU map[string]int
}

// New builds a hub over an existing room manager and analytics store.
func New(cfg *config.Config, rooms *room.Manager, st store.Store, log *slog.Logger) *Hub {
	return &Hub{
		cfg:     cfg,
		rooms:   rooms,
		store:   st,
		log:     log,
		conns:   map[*Conn]struct{}{},
		peakCCU: map[string]int{},
		liveCCU: map[string]int{},
	}
}

func newSessionID() (string, error) {
	buf := make([]byte, 16)
	if _, err := rand.Read(buf); err != nil {
		return "", err
	}
	return fmt.Sprintf("%x", buf), nil
}

// ServeHTTP upgrades a request and runs the connection until it closes.
func (h *Hub) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	ws, err := websocket.Accept(w, r, &websocket.AcceptOptions{
		// Browser builds are served from arbitrary origins, and the relay carries no
		// ambient authority worth protecting with same-origin. Auth is the per-game key.
		InsecureSkipVerify: true,
		CompressionMode:    websocket.CompressionDisabled,
	})
	if err != nil {
		h.log.Warn("websocket accept failed", "remote", r.RemoteAddr, "err", err)
		return
	}
	ws.SetReadLimit(handshakeReadLimit)

	ctx, cancel := context.WithCancel(r.Context())
	defer cancel()

	c := newConn(ws, h, h.log)
	h.addConn(c)
	defer h.removeConn(c)

	writerDone := make(chan struct{})
	go func() {
		defer close(writerDone)
		c.writeLoop(ctx)
	}()

	c.readLoop(ctx)

	// Mark closed rather than cancelling, so the writer flushes anything still queued.
	// A fatal ERROR frame is queued right before the read loop returns, and cancelling
	// here would discard the very message explaining the disconnect.
	c.closeSoon(proto.ErrInternal, "read loop ended")
	select {
	case <-writerDone:
	case <-time.After(drainGrace):
		h.log.Debug("writer did not drain in time", "session", c.sessionID)
	}

	cancel()
	ws.CloseNow()
}

func (h *Hub) addConn(c *Conn) {
	h.mu.Lock()
	h.conns[c] = struct{}{}
	h.mu.Unlock()
}

func (h *Hub) removeConn(c *Conn) {
	roomCode := ""
	if r, _ := c.currentRoom(); r != nil {
		roomCode = r.Code
	}
	h.leaveRoom(c, proto.ReasonDisconnected)

	h.mu.Lock()
	delete(h.conns, c)
	if c.game != "" {
		h.liveCCU[c.game]--
		if h.liveCCU[c.game] < 0 {
			h.liveCCU[c.game] = 0
		}
	}
	h.mu.Unlock()

	if c.sessionID == "" {
		return
	}
	h.store.Record(store.Event{
		At:          time.Now(),
		Kind:        store.EventSessionEnded,
		Game:        c.game,
		GameVersion: c.gameVersion,
		SessionID:   c.sessionID,
		ClientID:    c.clientID,
		Platform:    c.platform,
		DurationMS:  time.Since(c.connectedAt).Milliseconds(),
	})
	cause := c.endedBecause()
	fields := []any{
		"session", c.sessionID,
		"game", c.game,
		"version", c.gameVersion,
		"platform", c.platform,
		"reason", cause.reason,
		"duration_s", int64(time.Since(c.connectedAt).Seconds()),
		"silent_s", int64(c.silentFor().Seconds()),
		"frames_in", c.framesIn.Load(),
		"frames_out", c.framesOut.Load(),
		"bytes_in", c.bytesIn.Load(),
		"bytes_out", c.bytesOut.Load(),
		"dropped", c.droppedCount(),
	}
	if roomCode != "" {
		fields = append(fields, "code", roomCode)
	}
	if cause.code != "" {
		fields = append(fields, "error_code", string(cause.code))
	}
	if cause.status != -1 && cause.status != 0 {
		fields = append(fields, "ws_status", int(cause.status))
	}
	if cause.err != nil {
		fields = append(fields, "err", cause.err.Error())
	}
	h.log.Info("session ended", fields...)
}

// readLoop consumes frames until the socket closes or a fatal error occurs.
func (c *Conn) readLoop(ctx context.Context) {
	for {
		kind, data, err := c.ws.Read(ctx)
		if err != nil {
			c.noteEnd(readEndCause(err))
			return
		}
		c.noteRead(len(data))
		if kind != websocket.MessageBinary {
			c.sendError(proto.ErrBadFrame, "text frames are not part of the protocol")
			return
		}

		frame, err := proto.Decode(data)
		if err != nil {
			c.sendError(proto.ErrBadFrame, "empty frame")
			return
		}
		if !c.hub.dispatch(c, frame) {
			return
		}
	}
}

// dispatch handles one frame and reports whether the connection should continue.
func (h *Hub) dispatch(c *Conn, f proto.Frame) bool {
	if !c.helloDone && f.Op != proto.OpHello {
		c.sendError(proto.ErrBadFrame, "HELLO must be the first frame")
		return false
	}

	switch f.Op {
	case proto.OpHello:
		return h.handleHello(c, f.Payload)
	case proto.OpRoomCreate:
		h.handleRoomCreate(c, f.Payload)
	case proto.OpRoomJoin:
		h.handleRoomJoin(c, f.Payload)
	case proto.OpRoomLeave:
		h.handleRoomLeave(c)
	case proto.OpRoomList:
		h.handleRoomList(c, f.Payload)
	case proto.OpRelay:
		h.handleRelay(c, f.Payload)
	case proto.OpRelayFragment:
		h.handleRelayFragment(c, f.Payload)
	case proto.OpPing:
		h.handlePing(c, f.Payload)
	case proto.OpTrack:
		h.handleTrack(c, f.Payload)
	default:
		// Unknown opcodes are ignored so a newer peer degrades instead of disconnecting.
		h.log.Debug("ignoring unknown opcode", "op", f.Op.String(), "session", c.sessionID)
	}
	return true
}

func (h *Hub) handleHello(c *Conn, payload []byte) bool {
	if c.helloDone {
		c.sendError(proto.ErrBadFrame, "duplicate HELLO")
		return false
	}

	var hello proto.Hello
	if err := json.Unmarshal(payload, &hello); err != nil {
		c.sendError(proto.ErrBadFrame, "malformed HELLO")
		return false
	}
	if hello.Protocol != proto.Version {
		c.sendError(proto.ErrProtocolMismatch,
			fmt.Sprintf("server speaks protocol %d, client sent %d", proto.Version, hello.Protocol))
		return false
	}
	if hello.Game == "" || hello.ClientID == "" {
		c.sendError(proto.ErrBadFrame, "HELLO requires game and client_id")
		return false
	}
	if !h.cfg.Enabled(hello.Game) {
		c.sendError(proto.ErrUnknownGame, fmt.Sprintf("game %q is not accepted here", hello.Game))
		return false
	}

	resolved := h.cfg.Resolve(hello.Game)
	if resolved.APIKey != "" && hello.Auth != resolved.APIKey {
		c.sendError(proto.ErrUnauthorized, fmt.Sprintf("game %q requires a valid auth key", hello.Game))
		return false
	}

	sessionID, err := newSessionID()
	if err != nil {
		c.sendError(proto.ErrInternal, "could not allocate a session")
		return false
	}

	c.sessionID = sessionID
	c.clientID = hello.ClientID
	c.game = hello.Game
	c.gameVersion = hello.GameVersion
	c.platform = sanitize(hello.Platform, config.DefaultMaxNameLength)
	c.displayName = sanitize(hello.DisplayName, config.DefaultMaxNameLength)
	c.limits = proto.Limits{
		MaxPacketSize:     resolved.MaxPacketSize,
		MaxMessageSize:    resolved.MaxMessageSize,
		MaxPlayersPerRoom: resolved.MaxPlayersPerRoom,
		MaxRooms:          resolved.MaxRooms,
		MaxNameLength:     config.DefaultMaxNameLength,
	}
	c.helloDone = true
	c.ws.SetReadLimit(int64(resolved.MaxPacketSize + frameOverhead))

	h.mu.Lock()
	h.liveCCU[c.game]++
	if h.liveCCU[c.game] > h.peakCCU[c.game] {
		h.peakCCU[c.game] = h.liveCCU[c.game]
	}
	h.mu.Unlock()

	c.sendJSON(proto.OpWelcome, proto.Welcome{
		Protocol:     proto.Version,
		SessionID:    sessionID,
		ServerTimeUS: time.Now().UnixMicro(),
		Limits:       c.limits,
	})

	h.store.Record(store.Event{
		At:          time.Now(),
		Kind:        store.EventSessionStarted,
		Game:        c.game,
		GameVersion: c.gameVersion,
		SessionID:   c.sessionID,
		ClientID:    c.clientID,
		Platform:    c.platform,
	})
	h.log.Info("session started", "session", sessionID, "game", c.game,
		"version", c.gameVersion, "platform", c.platform)
	return true
}

func (h *Hub) handleRoomCreate(c *Conn, payload []byte) {
	if r, _ := c.currentRoom(); r != nil {
		c.sendError(proto.ErrAlreadyInRoom, "leave the current room before creating another")
		return
	}

	var req proto.RoomCreate
	if err := json.Unmarshal(payload, &req); err != nil {
		c.sendError(proto.ErrBadFrame, "malformed ROOM_CREATE")
		return
	}

	maxPlayers := req.MaxPlayers
	if maxPlayers <= 0 || maxPlayers > c.limits.MaxPlayersPerRoom {
		maxPlayers = c.limits.MaxPlayersPerRoom
	}

	r, err := h.rooms.Create(room.CreateOptions{
		Game:        c.game,
		GameVersion: c.gameVersion,
		Name:        sanitize(req.Name, c.limits.MaxNameLength),
		MaxPlayers:  maxPlayers,
		Visibility:  req.Visibility,
		Tags:        sanitizeTags(req.Tags),
		Password:    req.Password,
		Dedicated:   req.Dedicated,
		MaxRooms:    c.limits.MaxRooms,
	})
	if err != nil {
		if errors.Is(err, room.ErrTooManyRooms) {
			c.sendError(proto.ErrServerFull, fmt.Sprintf("game %q is at its room limit", c.game))
			return
		}
		c.sendError(proto.ErrInternal, "could not create room")
		return
	}

	h.store.Record(store.Event{
		At:          time.Now(),
		Kind:        store.EventRoomCreated,
		Game:        c.game,
		GameVersion: c.gameVersion,
		SessionID:   c.sessionID,
		ClientID:    c.clientID,
		Platform:    c.platform,
		RoomID:      r.ID,
	})
	h.log.Info("room created", "code", r.Code, "game", c.game, "session", c.sessionID)

	h.enterRoom(c, r)
}

func (h *Hub) handleRoomJoin(c *Conn, payload []byte) {
	if r, _ := c.currentRoom(); r != nil {
		c.sendError(proto.ErrAlreadyInRoom, "leave the current room before joining another")
		return
	}

	var req proto.RoomJoin
	if err := json.Unmarshal(payload, &req); err != nil {
		c.sendError(proto.ErrBadFrame, "malformed ROOM_JOIN")
		return
	}

	var (
		r  *room.Room
		ok bool
	)
	switch {
	case req.Code != "":
		r, ok = h.rooms.FindByCode(c.game, c.gameVersion, req.Code)
	case req.RoomID != "":
		r, ok = h.rooms.FindByID(c.game, c.gameVersion, req.RoomID)
	default:
		c.sendError(proto.ErrBadFrame, "ROOM_JOIN requires code or room_id")
		return
	}
	if !ok {
		c.sendError(proto.ErrRoomNotFound, "no such room for this game and version")
		return
	}
	if !r.CheckPassword(req.Password) {
		c.sendError(proto.ErrWrongPassword, "password did not match")
		return
	}

	h.enterRoom(c, r)
}

// enterRoom adds the connection to a room and notifies both sides.
func (h *Hub) enterRoom(c *Conn, r *room.Room) {
	peerID, err := r.Join(c)
	if err != nil {
		switch {
		case errors.Is(err, room.ErrRoomFull):
			c.sendError(proto.ErrRoomFull,
				fmt.Sprintf("room %s is full (%d/%d)", r.Code, r.PlayerCount(), r.MaxPlayers))
		default:
			c.sendError(proto.ErrRoomNotFound, "room is no longer available")
		}
		return
	}
	c.setRoom(r, peerID)

	if info, ok := r.PeerInfo(peerID); ok {
		if frame, err := json.Marshal(info); err == nil {
			r.Broadcast(proto.EncodeJSON(proto.OpPeerJoin, frame), peerID)
		}
	}
	c.sendJSON(proto.OpRoomState, r.State(peerID))

	h.log.Info("peer joined", "code", r.Code, "game", c.game, "peer", peerID,
		"host", peerID == r.HostID(), "players", r.PlayerCount(), "session", c.sessionID)

	h.store.Record(store.Event{
		At:          time.Now(),
		Kind:        store.EventPeerJoined,
		Game:        c.game,
		GameVersion: c.gameVersion,
		SessionID:   c.sessionID,
		ClientID:    c.clientID,
		Platform:    c.platform,
		RoomID:      r.ID,
	})
}

func (h *Hub) handleRoomLeave(c *Conn) {
	if r, _ := c.currentRoom(); r == nil {
		c.sendError(proto.ErrNotInRoom, "not in a room")
		return
	}
	h.leaveRoom(c, proto.ReasonLeft)
}

// leaveRoom removes the connection from its room and tears the room down when empty.
func (h *Hub) leaveRoom(c *Conn, reason string) {
	r, peerID := c.currentRoom()
	if r == nil {
		return
	}
	c.setRoom(nil, 0)

	empty := r.Leave(peerID)
	if frame, err := json.Marshal(proto.PeerLeave{PeerID: peerID, Reason: reason}); err == nil {
		r.Broadcast(proto.EncodeJSON(proto.OpPeerLeave, frame), peerID)
	}

	h.log.Info("peer left", "code", r.Code, "game", c.game, "peer", peerID,
		"was_host", peerID == room.HostPeerID, "reason", reason,
		"remaining", r.PlayerCount(), "session", c.sessionID)

	h.store.Record(store.Event{
		At:          time.Now(),
		Kind:        store.EventPeerLeft,
		Game:        c.game,
		GameVersion: c.gameVersion,
		SessionID:   c.sessionID,
		ClientID:    c.clientID,
		Platform:    c.platform,
		RoomID:      r.ID,
	})

	if empty {
		h.rooms.Remove(r)
		h.store.Record(store.Event{
			At:          time.Now(),
			Kind:        store.EventRoomClosed,
			Game:        r.Game,
			GameVersion: r.GameVersion,
			RoomID:      r.ID,
			DurationMS:  time.Since(r.CreatedAt).Milliseconds(),
		})
		h.log.Info("room closed", "code", r.Code, "game", r.Game,
			"lifetime_s", int64(time.Since(r.CreatedAt).Seconds()))
	}
}

func (h *Hub) handleRoomList(c *Conn, payload []byte) {
	var req proto.RoomListRequest
	if len(payload) > 0 {
		if err := json.Unmarshal(payload, &req); err != nil {
			c.sendError(proto.ErrBadFrame, "malformed ROOM_LIST")
			return
		}
	}
	c.sendJSON(proto.OpRoomListOut, proto.RoomListResponse{
		Rooms: h.rooms.List(c.game, c.gameVersion, req),
	})
}

func (h *Hub) handleRelay(c *Conn, payload []byte) {
	r, peerID := c.currentRoom()
	if r == nil {
		c.sendError(proto.ErrNotInRoom, "cannot relay outside a room")
		return
	}

	header, packet, err := proto.DecodeRelay(payload)
	if err != nil {
		c.sendError(proto.ErrBadFrame, "malformed RELAY header")
		return
	}
	if len(packet) > c.limits.MaxPacketSize {
		c.sendError(proto.ErrPacketTooLarge,
			fmt.Sprintf("packet of %d bytes exceeds the %d byte limit", len(packet), c.limits.MaxPacketSize))
		return
	}

	r.Relay(peerID, header.Peer, header.Channel, header.Mode, packet)
	h.store.RecordBytes(c.game, int64(len(packet)))
}

// handleRelayFragment routes one slice of a packet too large for a single frame.
// The relay holds no fragments: it checks the length the sender declares against the
// message ceiling, then forwards each slice as it arrives.
func (h *Hub) handleRelayFragment(c *Conn, payload []byte) {
	r, peerID := c.currentRoom()
	if r == nil {
		c.sendError(proto.ErrNotInRoom, "cannot relay outside a room")
		return
	}

	header, slice, err := proto.DecodeRelayFragment(payload)
	if err != nil {
		c.sendError(proto.ErrBadFrame, "malformed RELAY_FRAGMENT header")
		return
	}
	if header.Count < 2 || header.Index >= header.Count {
		c.sendError(proto.ErrBadFrame, "RELAY_FRAGMENT index outside its message")
		return
	}
	// Every slice carries at least one byte, so more slices than bytes is a lie.
	if uint32(header.Count) > header.Total {
		c.sendError(proto.ErrBadFrame, "RELAY_FRAGMENT count exceeds its message length")
		return
	}
	if len(slice) > c.limits.MaxPacketSize {
		c.sendError(proto.ErrPacketTooLarge,
			fmt.Sprintf("fragment of %d bytes exceeds the %d byte limit", len(slice), c.limits.MaxPacketSize))
		return
	}
	if int64(header.Total) > int64(c.limits.MaxMessageSize) {
		c.sendError(proto.ErrPacketTooLarge,
			fmt.Sprintf("message of %d bytes exceeds the %d byte limit",
				header.Total, c.limits.MaxMessageSize))
		return
	}

	r.RelayFragment(peerID, header, slice)
	h.store.RecordBytes(c.game, int64(len(slice)))
}

func (h *Hub) handlePing(c *Conn, payload []byte) {
	clientTime, err := proto.DecodePing(payload)
	if err != nil {
		c.sendError(proto.ErrBadFrame, "malformed PING")
		return
	}
	c.Send(proto.EncodePong(clientTime, uint64(time.Now().UnixMicro())), proto.Reliable)
}

func (h *Hub) handleTrack(c *Conn, payload []byte) {
	var req proto.Track
	if err := json.Unmarshal(payload, &req); err != nil {
		c.sendError(proto.ErrBadFrame, "malformed TRACK")
		return
	}
	if req.Event == "" {
		return
	}

	roomID := ""
	if r, _ := c.currentRoom(); r != nil {
		roomID = r.ID
	}
	h.store.Record(store.Event{
		At:          time.Now(),
		Kind:        store.EventCustom,
		Name:        sanitize(req.Event, 64),
		Game:        c.game,
		GameVersion: c.gameVersion,
		SessionID:   c.sessionID,
		ClientID:    c.clientID,
		Platform:    c.platform,
		RoomID:      roomID,
		Props:       req.Props,
	})
}

// LiveStats reports current and peak concurrency per game.
func (h *Hub) LiveStats() (live, peak map[string]int) {
	h.mu.RLock()
	defer h.mu.RUnlock()

	live = make(map[string]int, len(h.liveCCU))
	peak = make(map[string]int, len(h.peakCCU))
	for k, v := range h.liveCCU {
		live[k] = v
	}
	for k, v := range h.peakCCU {
		peak[k] = v
	}
	return live, peak
}

// sanitize trims a client-supplied string to a safe single-line value.
func sanitize(s string, max int) string {
	s = strings.TrimSpace(s)
	s = strings.Map(func(r rune) rune {
		if r < 0x20 || r == 0x7f {
			return -1
		}
		return r
	}, s)
	if max > 0 && len(s) > max {
		s = s[:max]
	}
	return s
}

// sanitizeTags bounds tag count and value length so a client cannot bloat the room list.
func sanitizeTags(tags map[string]string) map[string]string {
	const maxTags = 16
	if len(tags) == 0 {
		return map[string]string{}
	}
	out := make(map[string]string, len(tags))
	for k, v := range tags {
		if len(out) >= maxTags {
			break
		}
		k = sanitize(k, 32)
		if k == "" {
			continue
		}
		out[k] = sanitize(v, 64)
	}
	return out
}
