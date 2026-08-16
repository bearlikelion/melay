// Package store persists Melay analytics events and answers aggregate queries.
package store

import "time"

// Event kinds recorded by the server. Everything except EventCustom is produced
// without any client involvement, so a game that never calls track() is still measured.
const (
	EventSessionStarted = "session_started"
	EventSessionEnded   = "session_ended"
	EventRoomCreated    = "room_created"
	EventRoomClosed     = "room_closed"
	EventPeerJoined     = "peer_joined"
	EventPeerLeft       = "peer_left"
	EventCustom         = "custom"
)

// Event is one analytics record.
type Event struct {
	At          time.Time
	Kind        string
	Name        string
	Game        string
	GameVersion string
	SessionID   string
	ClientID    string
	Platform    string
	RoomID      string
	DurationMS  int64
	Props       map[string]string
}

// Bucket is one labelled count in a breakdown.
type Bucket struct {
	Key   string `json:"key"`
	Count int    `json:"count"`
}

// Stats is the aggregate view of one game over a time range.
type Stats struct {
	Game              string   `json:"game"`
	Sessions          int      `json:"sessions"`
	UniqueClients     int      `json:"unique_clients"`
	RoomsCreated      int      `json:"rooms_created"`
	TotalPlaytimeMS   int64    `json:"total_playtime_ms"`
	MedianSessionMS   int64    `json:"median_session_ms"`
	P95SessionMS      int64    `json:"p95_session_ms"`
	Platforms         []Bucket `json:"platforms"`
	Versions          []Bucket `json:"versions"`
	BytesRelayed      int64    `json:"bytes_relayed"`
	PlayersOnline     int      `json:"players_online"`
	PeakPlayersOnline int      `json:"peak_players_online"`
	RoomsActive       int      `json:"rooms_active"`
}

// Store records events and answers aggregate queries. Record must never block the
// caller, since it runs on the connection hot path.
type Store interface {
	Record(Event)
	RecordBytes(game string, n int64)
	Stats(game string, since time.Time) (Stats, error)
	Games() ([]string, error)
	Close() error
}

// Nop is a Store that discards everything, for tests and for running without a database.
type Nop struct{}

func (Nop) Record(Event)                                  {}
func (Nop) RecordBytes(string, int64)                     {}
func (Nop) Stats(game string, _ time.Time) (Stats, error) { return Stats{Game: game}, nil }
func (Nop) Games() ([]string, error)                      { return nil, nil }
func (Nop) Close() error                                  { return nil }
