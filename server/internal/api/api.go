// Package api serves the Melay analytics JSON API and the embedded dashboard.
package api

import (
	"encoding/json"
	"log/slog"
	"net/http"
	"sort"
	"strings"
	"time"

	"github.com/bearlikelion/melay/internal/hub"
	"github.com/bearlikelion/melay/internal/room"
	"github.com/bearlikelion/melay/internal/store"
	"github.com/bearlikelion/melay/web"
)

// defaultRange is used when the caller supplies no range parameter.
const defaultRange = 7 * 24 * time.Hour

// Server wires the read-only views over the live hub and the analytics store.
type Server struct {
	hub     *hub.Hub
	rooms   *room.Manager
	store   store.Store
	log     *slog.Logger
	start   time.Time
	webDir  string
	version string
}

// New builds the API handler set. webDir may be empty; when it points at a Godot web
// export, the game is served at /play on the same origin as the relay.
func New(h *hub.Hub, rooms *room.Manager, st store.Store, log *slog.Logger, webDir, version string) *Server {
	return &Server{hub: h, rooms: rooms, store: st, log: log, start: time.Now(), webDir: webDir, version: version}
}

// Routes registers every HTTP route the server exposes, including the WebSocket
// upgrade. All patterns are method-qualified because Go's mux treats a bare path
// and a method-qualified one as conflicting.
func (s *Server) Routes(mux *http.ServeMux) {
	mux.Handle("GET /ws", s.hub)
	// Google's frontend swallows /healthz before it reaches the container, so the
	// same handler is also served on a path nothing else claims.
	mux.HandleFunc("GET /healthz", s.handleHealth)
	mux.HandleFunc("GET /api/v1/health", s.handleHealth)
	mux.HandleFunc("GET /api/v1/games", s.handleGames)
	mux.HandleFunc("GET /api/v1/stats", s.handleStats)

	if hasWebExport(s.webDir) {
		mux.Handle("GET "+PlayPrefix, playHandler(s.webDir))
		// So /play works as well as /play/.
		mux.Handle("GET /play", http.RedirectHandler(PlayPrefix, http.StatusMovedPermanently))
		s.log.Info("serving web export", "dir", s.webDir, "path", PlayPrefix)
	} else if s.webDir != "" {
		s.log.Warn("web dir has no index.html, not serving it", "dir", s.webDir)
	}

	mux.Handle("GET /", web.Handler())
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	// Read-only public counters, so a dashboard hosted anywhere can read them.
	w.Header().Set("Access-Control-Allow-Origin", "*")
	w.WriteHeader(code)
	if err := json.NewEncoder(w).Encode(v); err != nil {
		return
	}
}

func (s *Server) handleHealth(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{
		"status":     "ok",
		"version":    s.version,
		"uptime_sec": int(time.Since(s.start).Seconds()),
		"rooms":      s.rooms.TotalRooms(),
		"web":        hasWebExport(s.webDir),
	})
}

// parseRange accepts a Go-style duration plus the shorthands "7d" and "all".
func parseRange(v string) time.Duration {
	v = strings.TrimSpace(strings.ToLower(v))
	switch v {
	case "":
		return defaultRange
	case "all":
		// Far enough back to include every record without special-casing the query.
		return 100 * 365 * 24 * time.Hour
	}
	if strings.HasSuffix(v, "d") {
		if d, err := time.ParseDuration(strings.TrimSuffix(v, "d") + "h"); err == nil {
			return d * 24
		}
	}
	if d, err := time.ParseDuration(v); err == nil {
		return d
	}
	return defaultRange
}

func (s *Server) handleGames(w http.ResponseWriter, _ *http.Request) {
	known, err := s.store.Games()
	if err != nil {
		s.log.Error("games query failed", "err", err)
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "query failed"})
		return
	}

	seen := map[string]struct{}{}
	for _, g := range known {
		seen[g] = struct{}{}
	}
	for g := range s.rooms.Stats() {
		seen[g] = struct{}{}
	}

	out := make([]string, 0, len(seen))
	for g := range seen {
		out = append(out, g)
	}
	sort.Strings(out)
	writeJSON(w, http.StatusOK, map[string]any{"games": out})
}

// gameStats merges the persisted aggregate with the live hub and room counters.
func (s *Server) gameStats(game string, since time.Time,
	live, peak map[string]int, rooms map[string]room.GameStats) (store.Stats, error) {

	st, err := s.store.Stats(game, since)
	if err != nil {
		return st, err
	}
	st.PlayersOnline = live[game]
	st.PeakPlayersOnline = peak[game]
	st.RoomsActive = rooms[game].Rooms
	return st, nil
}

func (s *Server) handleStats(w http.ResponseWriter, r *http.Request) {
	window := parseRange(r.URL.Query().Get("range"))
	since := time.Now().Add(-window)

	live, peak := s.hub.LiveStats()
	roomStats := s.rooms.Stats()

	if game := r.URL.Query().Get("game"); game != "" {
		st, err := s.gameStats(game, since, live, peak, roomStats)
		if err != nil {
			s.log.Error("stats query failed", "game", game, "err", err)
			writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "query failed"})
			return
		}
		writeJSON(w, http.StatusOK, st)
		return
	}

	known, err := s.store.Games()
	if err != nil {
		s.log.Error("games query failed", "err", err)
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "query failed"})
		return
	}
	seen := map[string]struct{}{}
	for _, g := range known {
		seen[g] = struct{}{}
	}
	for g := range roomStats {
		seen[g] = struct{}{}
	}
	for g := range live {
		seen[g] = struct{}{}
	}

	names := make([]string, 0, len(seen))
	for g := range seen {
		names = append(names, g)
	}
	sort.Strings(names)

	out := make([]store.Stats, 0, len(names))
	totalPlayers := 0
	for _, g := range names {
		st, err := s.gameStats(g, since, live, peak, roomStats)
		if err != nil {
			s.log.Error("stats query failed", "game", g, "err", err)
			continue
		}
		totalPlayers += st.PlayersOnline
		out = append(out, st)
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"version":        s.version,
		"range":          r.URL.Query().Get("range"),
		"generated_at":   time.Now().Unix(),
		"players_online": totalPlayers,
		"rooms_active":   s.rooms.TotalRooms(),
		"games":          out,
	})
}
