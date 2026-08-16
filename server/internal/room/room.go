// Package room holds Melay's room model: membership, peer id assignment and relay fanout.
package room

import (
	"crypto/sha256"
	"crypto/subtle"
	"sync"
	"time"

	"github.com/bearlikelion/melay/internal/proto"
)

// HostPeerID is the peer id Godot reserves for the server, so the host always holds it.
const HostPeerID int32 = 1

// firstClientPeerID is where non-host ids start. Ids are never reused within a room.
const firstClientPeerID int32 = 2

// Peer is the room's view of a connected client. The hub supplies the implementation.
type Peer interface {
	SessionID() string
	DisplayName() string
	Platform() string
	// Send queues a frame. It must never block; the implementation sheds load
	// according to mode when its outbound queue is full.
	Send(frame []byte, mode proto.TransferMode)
}

// Room is one game session. All state is guarded by mu.
type Room struct {
	ID          string
	Code        string
	Name        string
	Game        string
	GameVersion string
	Visibility  string
	Tags        map[string]string
	MaxPlayers  int
	Dedicated   bool
	CreatedAt   time.Time

	passwordHash []byte

	mu         sync.RWMutex
	peers      map[int32]Peer
	order      []int32
	hostID     int32
	nextPeerID int32
	closed     bool
}

func hashPassword(password string) []byte {
	if password == "" {
		return nil
	}
	sum := sha256.Sum256([]byte(password))
	return sum[:]
}

// CheckPassword compares in constant time so a wrong guess leaks no timing signal.
func (r *Room) CheckPassword(password string) bool {
	if len(r.passwordHash) == 0 {
		return true
	}
	got := hashPassword(password)
	return subtle.ConstantTimeCompare(r.passwordHash, got) == 1
}

// HasPassword reports whether joining requires a password.
func (r *Room) HasPassword() bool {
	return len(r.passwordHash) > 0
}

// Join adds a peer and returns its assigned id. The first peer becomes the host at id 1.
func (r *Room) Join(p Peer) (int32, error) {
	r.mu.Lock()
	defer r.mu.Unlock()

	if r.closed {
		return 0, ErrRoomNotFound
	}
	if len(r.peers) >= r.MaxPlayers {
		return 0, ErrRoomFull
	}

	var id int32
	if len(r.peers) == 0 {
		id = HostPeerID
		r.hostID = HostPeerID
	} else {
		id = r.nextPeerID
		r.nextPeerID++
	}

	r.peers[id] = p
	r.order = append(r.order, id)
	return id, nil
}

// Leave removes a peer and reports whether the room is now empty.
func (r *Room) Leave(id int32) (empty bool) {
	r.mu.Lock()
	defer r.mu.Unlock()

	if _, ok := r.peers[id]; !ok {
		return len(r.peers) == 0
	}
	delete(r.peers, id)
	for i, v := range r.order {
		if v == id {
			r.order = append(r.order[:i], r.order[i+1:]...)
			break
		}
	}
	if len(r.peers) == 0 {
		r.closed = true
		return true
	}
	return false
}

// Relay fans a packet out using Godot's target addressing. The sender never gets
// its own packet back, including in the broadcast and exclusion cases.
func (r *Room) Relay(from, target int32, channel uint8, mode proto.TransferMode, packet []byte) {
	frame := proto.EncodeRelay(from, channel, mode, packet)

	r.mu.RLock()
	defer r.mu.RUnlock()

	switch {
	case target > 0:
		if target == from {
			return
		}
		if p, ok := r.peers[target]; ok {
			p.Send(frame, mode)
		}
	case target == 0:
		for id, p := range r.peers {
			if id == from {
				continue
			}
			p.Send(frame, mode)
		}
	default:
		excluded := -target
		for id, p := range r.peers {
			if id == from || id == excluded {
				continue
			}
			p.Send(frame, mode)
		}
	}
}

// Broadcast sends a control frame to every peer, optionally skipping one.
func (r *Room) Broadcast(frame []byte, skip int32) {
	r.mu.RLock()
	defer r.mu.RUnlock()

	for id, p := range r.peers {
		if id == skip {
			continue
		}
		p.Send(frame, proto.Reliable)
	}
}

// State builds the authoritative room snapshot from selfID's point of view.
func (r *Room) State(selfID int32) proto.RoomState {
	r.mu.RLock()
	defer r.mu.RUnlock()

	peers := make([]proto.PeerInfo, 0, len(r.peers))
	for _, id := range r.order {
		p, ok := r.peers[id]
		if !ok {
			continue
		}
		peers = append(peers, proto.PeerInfo{
			PeerID:      id,
			SessionID:   p.SessionID(),
			DisplayName: p.DisplayName(),
			Platform:    p.Platform(),
			IsHost:      id == r.hostID,
		})
	}

	return proto.RoomState{
		RoomID:     r.ID,
		Code:       r.Code,
		Name:       r.Name,
		HostPeerID: r.hostID,
		SelfPeerID: selfID,
		MaxPlayers: r.MaxPlayers,
		Visibility: r.Visibility,
		Dedicated:  r.Dedicated,
		Tags:       r.Tags,
		Peers:      peers,
	}
}

// PeerInfo describes one member, for the join notification sent to everyone else.
func (r *Room) PeerInfo(id int32) (proto.PeerInfo, bool) {
	r.mu.RLock()
	defer r.mu.RUnlock()

	p, ok := r.peers[id]
	if !ok {
		return proto.PeerInfo{}, false
	}
	return proto.PeerInfo{
		PeerID:      id,
		SessionID:   p.SessionID(),
		DisplayName: p.DisplayName(),
		Platform:    p.Platform(),
		IsHost:      id == r.hostID,
	}, true
}

// Summary builds the public room-list entry.
func (r *Room) Summary() proto.RoomSummary {
	r.mu.RLock()
	defer r.mu.RUnlock()

	return proto.RoomSummary{
		RoomID:      r.ID,
		Code:        r.Code,
		Name:        r.Name,
		PlayerCount: len(r.peers),
		MaxPlayers:  r.MaxPlayers,
		HasPassword: len(r.passwordHash) > 0,
		Tags:        r.Tags,
		CreatedAt:   r.CreatedAt.Unix(),
	}
}

// PlayerCount is the current membership.
func (r *Room) PlayerCount() int {
	r.mu.RLock()
	defer r.mu.RUnlock()
	return len(r.peers)
}

// HostID is the peer id currently acting as host.
func (r *Room) HostID() int32 {
	r.mu.RLock()
	defer r.mu.RUnlock()
	return r.hostID
}

// matchesTags reports whether every requested tag is present with the same value.
// Tags the filter omits are unconstrained.
func (r *Room) matchesTags(filter map[string]string) bool {
	for k, want := range filter {
		if r.Tags[k] != want {
			return false
		}
	}
	return true
}
