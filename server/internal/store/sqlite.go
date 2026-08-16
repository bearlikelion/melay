package store

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"log/slog"
	"strings"
	"sync"
	"time"

	_ "modernc.org/sqlite"
)

// eventQueue is the buffer between the hot path and the writer goroutine. When it
// fills, events are dropped rather than allowed to stall a relay.
const eventQueue = 4096

// flushInterval bounds how long a batch waits before being committed.
const flushInterval = 2 * time.Second

const schema = `
CREATE TABLE IF NOT EXISTS events (
	id           INTEGER PRIMARY KEY AUTOINCREMENT,
	at           INTEGER NOT NULL,
	kind         TEXT    NOT NULL,
	name         TEXT    NOT NULL DEFAULT '',
	game         TEXT    NOT NULL,
	game_version TEXT    NOT NULL DEFAULT '',
	session_id   TEXT    NOT NULL DEFAULT '',
	client_id    TEXT    NOT NULL DEFAULT '',
	platform     TEXT    NOT NULL DEFAULT '',
	room_id      TEXT    NOT NULL DEFAULT '',
	duration_ms  INTEGER NOT NULL DEFAULT 0,
	props        TEXT    NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS idx_events_game_at  ON events(game, at);
CREATE INDEX IF NOT EXISTS idx_events_kind_at  ON events(kind, at);

CREATE TABLE IF NOT EXISTS bytes_relayed (
	game  TEXT    NOT NULL,
	day   INTEGER NOT NULL,
	bytes INTEGER NOT NULL DEFAULT 0,
	PRIMARY KEY (game, day)
);
`

// SQLite is the default Store: one embedded file, no external service.
type SQLite struct {
	db  *sql.DB
	log *slog.Logger

	events chan Event

	mu    sync.Mutex
	bytes map[string]int64

	closeOnce sync.Once
	done      chan struct{}
	stopped   chan struct{}
}

// OpenSQLite opens or creates the database at dsn and starts the writer goroutine.
func OpenSQLite(dsn string, log *slog.Logger) (*SQLite, error) {
	if strings.Contains(dsn, "://") && !strings.HasPrefix(dsn, "file:") {
		return nil, fmt.Errorf("store: only file: and :memory: DSNs are supported, got %q", dsn)
	}
	if !strings.Contains(dsn, "_pragma=") {
		sep := "?"
		if strings.Contains(dsn, "?") {
			sep = "&"
		}
		dsn += sep + "_pragma=journal_mode(WAL)&_pragma=busy_timeout(5000)&_pragma=synchronous(NORMAL)"
	}

	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, fmt.Errorf("store: open %s: %w", dsn, err)
	}
	// The writer is a single goroutine; more connections only invite lock contention.
	db.SetMaxOpenConns(1)

	if _, err := db.Exec(schema); err != nil {
		db.Close()
		return nil, fmt.Errorf("store: migrate: %w", err)
	}

	s := &SQLite{
		db:      db,
		log:     log,
		events:  make(chan Event, eventQueue),
		bytes:   map[string]int64{},
		done:    make(chan struct{}),
		stopped: make(chan struct{}),
	}
	go s.run()
	return s, nil
}

// Record queues an event, dropping it if the writer has fallen far behind.
func (s *SQLite) Record(e Event) {
	select {
	case s.events <- e:
	default:
		s.log.Warn("analytics queue full, dropping event", "kind", e.Kind, "game", e.Game)
	}
}

// RecordBytes accumulates relayed volume in memory; the writer flushes it periodically.
func (s *SQLite) RecordBytes(game string, n int64) {
	s.mu.Lock()
	s.bytes[game] += n
	s.mu.Unlock()
}

func (s *SQLite) run() {
	defer close(s.stopped)

	ticker := time.NewTicker(flushInterval)
	defer ticker.Stop()

	batch := make([]Event, 0, 256)
	for {
		select {
		case e := <-s.events:
			batch = append(batch, e)
			if len(batch) >= cap(batch) {
				s.writeBatch(batch)
				batch = batch[:0]
			}
		case <-ticker.C:
			if len(batch) > 0 {
				s.writeBatch(batch)
				batch = batch[:0]
			}
			s.flushBytes()
		case <-s.done:
			// Drain whatever is still queued before shutting down.
			for {
				select {
				case e := <-s.events:
					batch = append(batch, e)
					continue
				default:
				}
				break
			}
			if len(batch) > 0 {
				s.writeBatch(batch)
			}
			s.flushBytes()
			return
		}
	}
}

func (s *SQLite) writeBatch(batch []Event) {
	tx, err := s.db.Begin()
	if err != nil {
		s.log.Error("analytics begin failed", "err", err)
		return
	}
	stmt, err := tx.Prepare(`INSERT INTO events
		(at, kind, name, game, game_version, session_id, client_id, platform, room_id, duration_ms, props)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`)
	if err != nil {
		tx.Rollback()
		s.log.Error("analytics prepare failed", "err", err)
		return
	}
	defer stmt.Close()

	for _, e := range batch {
		props := ""
		if len(e.Props) > 0 {
			if raw, err := json.Marshal(e.Props); err == nil {
				props = string(raw)
			}
		}
		if _, err := stmt.Exec(e.At.Unix(), e.Kind, e.Name, e.Game, e.GameVersion,
			e.SessionID, e.ClientID, e.Platform, e.RoomID, e.DurationMS, props); err != nil {
			s.log.Error("analytics insert failed", "err", err)
		}
	}
	if err := tx.Commit(); err != nil {
		s.log.Error("analytics commit failed", "err", err)
	}
}

func (s *SQLite) flushBytes() {
	s.mu.Lock()
	pending := s.bytes
	s.bytes = map[string]int64{}
	s.mu.Unlock()

	if len(pending) == 0 {
		return
	}
	day := time.Now().Truncate(24 * time.Hour).Unix()
	for game, n := range pending {
		_, err := s.db.Exec(`INSERT INTO bytes_relayed (game, day, bytes) VALUES (?, ?, ?)
			ON CONFLICT(game, day) DO UPDATE SET bytes = bytes + excluded.bytes`, game, day, n)
		if err != nil {
			s.log.Error("analytics bytes flush failed", "game", game, "err", err)
		}
	}
}

// Games lists every game id that has ever produced an event.
func (s *SQLite) Games() ([]string, error) {
	rows, err := s.db.Query(`SELECT DISTINCT game FROM events WHERE game != '' ORDER BY game`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []string
	for rows.Next() {
		var g string
		if err := rows.Scan(&g); err != nil {
			return nil, err
		}
		out = append(out, g)
	}
	return out, rows.Err()
}

// Stats aggregates one game over the window starting at since.
func (s *SQLite) Stats(game string, since time.Time) (Stats, error) {
	st := Stats{Game: game}
	from := since.Unix()

	err := s.db.QueryRow(`SELECT
			COUNT(*),
			COALESCE(SUM(duration_ms), 0),
			COUNT(DISTINCT client_id)
		FROM events WHERE game = ? AND at >= ? AND kind = ?`,
		game, from, EventSessionEnded).
		Scan(&st.Sessions, &st.TotalPlaytimeMS, &st.UniqueClients)
	if err != nil {
		return st, err
	}

	if err := s.db.QueryRow(`SELECT COUNT(*) FROM events
		WHERE game = ? AND at >= ? AND kind = ?`, game, from, EventRoomCreated).
		Scan(&st.RoomsCreated); err != nil {
		return st, err
	}

	durations, err := s.sessionDurations(game, from)
	if err != nil {
		return st, err
	}
	st.MedianSessionMS = percentile(durations, 0.50)
	st.P95SessionMS = percentile(durations, 0.95)

	if st.Platforms, err = s.breakdown(game, from, "platform"); err != nil {
		return st, err
	}
	if st.Versions, err = s.breakdown(game, from, "game_version"); err != nil {
		return st, err
	}

	if err := s.db.QueryRow(`SELECT COALESCE(SUM(bytes), 0) FROM bytes_relayed
		WHERE game = ? AND day >= ?`, game, since.Truncate(24*time.Hour).Unix()).
		Scan(&st.BytesRelayed); err != nil {
		return st, err
	}

	return st, nil
}

func (s *SQLite) sessionDurations(game string, from int64) ([]int64, error) {
	rows, err := s.db.Query(`SELECT duration_ms FROM events
		WHERE game = ? AND at >= ? AND kind = ? ORDER BY duration_ms`,
		game, from, EventSessionEnded)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []int64
	for rows.Next() {
		var d int64
		if err := rows.Scan(&d); err != nil {
			return nil, err
		}
		out = append(out, d)
	}
	return out, rows.Err()
}

// breakdown counts sessions grouped by one column. The column name is chosen by the
// caller from a fixed set, never from user input.
func (s *SQLite) breakdown(game string, from int64, column string) ([]Bucket, error) {
	switch column {
	case "platform", "game_version":
	default:
		return nil, fmt.Errorf("store: breakdown on unsupported column %q", column)
	}

	rows, err := s.db.Query(`SELECT `+column+`, COUNT(*) FROM events
		WHERE game = ? AND at >= ? AND kind = ? GROUP BY `+column+` ORDER BY COUNT(*) DESC`,
		game, from, EventSessionStarted)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	out := []Bucket{}
	for rows.Next() {
		var b Bucket
		if err := rows.Scan(&b.Key, &b.Count); err != nil {
			return nil, err
		}
		if b.Key == "" {
			b.Key = "unknown"
		}
		out = append(out, b)
	}
	return out, rows.Err()
}

// percentile expects sorted input and returns 0 for an empty set.
func percentile(sorted []int64, p float64) int64 {
	if len(sorted) == 0 {
		return 0
	}
	idx := int(p * float64(len(sorted)-1))
	if idx < 0 {
		idx = 0
	}
	if idx >= len(sorted) {
		idx = len(sorted) - 1
	}
	return sorted[idx]
}

// Close flushes pending events and closes the database.
func (s *SQLite) Close() error {
	s.closeOnce.Do(func() {
		close(s.done)
		<-s.stopped
	})
	return s.db.Close()
}
