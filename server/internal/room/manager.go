package room

import (
	"crypto/rand"
	"errors"
	"fmt"
	"strings"
	"sync"
	"time"

	"github.com/bearlikelion/melay/internal/proto"
)

// Errors the manager and rooms return. The hub maps these onto protocol error codes.
var (
	ErrRoomNotFound  = errors.New("room not found")
	ErrRoomFull      = errors.New("room full")
	ErrWrongPassword = errors.New("wrong password")
	ErrTooManyRooms  = errors.New("too many rooms for game")
	ErrCodeExhausted = errors.New("could not allocate a room code")
)

// codeAlphabet is Crockford base32: no I, L, O or U, so codes cannot be misread aloud.
const codeAlphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

const codeLength = 6

// maxCodeAttempts bounds collision retries before we admit the space is too full.
const maxCodeAttempts = 12

// Manager owns every room on the server.
type Manager struct {
	mu     sync.RWMutex
	rooms  map[string]*Room
	byCode map[string]*Room
	counts map[string]int
}

// NewManager returns an empty manager.
func NewManager() *Manager {
	return &Manager{
		rooms:  map[string]*Room{},
		byCode: map[string]*Room{},
		counts: map[string]int{},
	}
}

// CreateOptions are the manager-level inputs for a new room.
type CreateOptions struct {
	Game        string
	GameVersion string
	Name        string
	MaxPlayers  int
	Visibility  string
	Tags        map[string]string
	Password    string
	Dedicated   bool
	MaxRooms    int
}

// codeKey namespaces a room code by game and version, so two games can share a code
// and an old build cannot see a new build's rooms.
func codeKey(game, version, code string) string {
	return game + "\x00" + version + "\x00" + strings.ToUpper(code)
}

func randomCode() (string, error) {
	buf := make([]byte, codeLength)
	if _, err := rand.Read(buf); err != nil {
		return "", err
	}
	out := make([]byte, codeLength)
	for i, b := range buf {
		out[i] = codeAlphabet[int(b)%len(codeAlphabet)]
	}
	return string(out), nil
}

func randomID() (string, error) {
	buf := make([]byte, 16)
	if _, err := rand.Read(buf); err != nil {
		return "", err
	}
	return fmt.Sprintf("%x", buf), nil
}

// Create allocates a room with a unique code for its game and version.
func (m *Manager) Create(opt CreateOptions) (*Room, error) {
	m.mu.Lock()
	defer m.mu.Unlock()

	if opt.MaxRooms > 0 && m.counts[opt.Game] >= opt.MaxRooms {
		return nil, ErrTooManyRooms
	}

	var code string
	for attempt := 0; attempt < maxCodeAttempts; attempt++ {
		c, err := randomCode()
		if err != nil {
			return nil, err
		}
		if _, taken := m.byCode[codeKey(opt.Game, opt.GameVersion, c)]; !taken {
			code = c
			break
		}
	}
	if code == "" {
		return nil, ErrCodeExhausted
	}

	id, err := randomID()
	if err != nil {
		return nil, err
	}

	if opt.Visibility != proto.VisibilityPrivate {
		opt.Visibility = proto.VisibilityPublic
	}
	if opt.Tags == nil {
		opt.Tags = map[string]string{}
	}

	r := &Room{
		ID:           id,
		Code:         code,
		Name:         opt.Name,
		Game:         opt.Game,
		GameVersion:  opt.GameVersion,
		Visibility:   opt.Visibility,
		Tags:         opt.Tags,
		MaxPlayers:   opt.MaxPlayers,
		Dedicated:    opt.Dedicated,
		CreatedAt:    time.Now(),
		passwordHash: hashPassword(opt.Password),
		peers:        map[int32]Peer{},
		nextPeerID:   firstClientPeerID,
		hostID:       HostPeerID,
	}

	m.rooms[id] = r
	m.byCode[codeKey(opt.Game, opt.GameVersion, code)] = r
	m.counts[opt.Game]++
	return r, nil
}

// FindByCode looks up a room within one game and version.
func (m *Manager) FindByCode(game, version, code string) (*Room, bool) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	r, ok := m.byCode[codeKey(game, version, code)]
	return r, ok
}

// FindByID looks up a room and verifies it belongs to the caller's game and version.
func (m *Manager) FindByID(game, version, id string) (*Room, bool) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	r, ok := m.rooms[id]
	if !ok || r.Game != game || r.GameVersion != version {
		return nil, false
	}
	return r, true
}

// Remove deletes a room, normally because its last peer left.
func (m *Manager) Remove(r *Room) {
	m.mu.Lock()
	defer m.mu.Unlock()

	if _, ok := m.rooms[r.ID]; !ok {
		return
	}
	delete(m.rooms, r.ID)
	delete(m.byCode, codeKey(r.Game, r.GameVersion, r.Code))
	if m.counts[r.Game] > 0 {
		m.counts[r.Game]--
	}
}

// List returns public rooms for one game and version, filtered by tags.
func (m *Manager) List(game, version string, req proto.RoomListRequest) []proto.RoomSummary {
	limit := req.Limit
	if limit <= 0 || limit > 200 {
		limit = 50
	}

	m.mu.RLock()
	candidates := make([]*Room, 0, len(m.rooms))
	for _, r := range m.rooms {
		if r.Game != game || r.GameVersion != version {
			continue
		}
		if r.Visibility != proto.VisibilityPublic {
			continue
		}
		if !r.matchesTags(req.Tags) {
			continue
		}
		candidates = append(candidates, r)
	}
	m.mu.RUnlock()

	out := make([]proto.RoomSummary, 0, len(candidates))
	for _, r := range candidates {
		s := r.Summary()
		if req.OnlyJoinable && s.PlayerCount >= s.MaxPlayers {
			continue
		}
		out = append(out, s)
		if len(out) >= limit {
			break
		}
	}
	return out
}

// Stats reports live counts per game, for the analytics API.
func (m *Manager) Stats() map[string]GameStats {
	m.mu.RLock()
	rooms := make([]*Room, 0, len(m.rooms))
	for _, r := range m.rooms {
		rooms = append(rooms, r)
	}
	m.mu.RUnlock()

	out := map[string]GameStats{}
	for _, r := range rooms {
		s := out[r.Game]
		s.Rooms++
		s.Players += r.PlayerCount()
		out[r.Game] = s
	}
	return out
}

// GameStats is the live snapshot for one game id.
type GameStats struct {
	Rooms   int `json:"rooms"`
	Players int `json:"players"`
}

// TotalRooms is the number of live rooms across all games.
func (m *Manager) TotalRooms() int {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return len(m.rooms)
}
