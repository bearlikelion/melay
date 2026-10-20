// Command melay runs the Melay relay: a WebSocket relay, lobby service and
// analytics recorder for Godot 4 multiplayer games.
package main

import (
	"context"
	"errors"
	"flag"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/bearlikelion/melay/internal/api"
	"github.com/bearlikelion/melay/internal/config"
	"github.com/bearlikelion/melay/internal/hub"
	"github.com/bearlikelion/melay/internal/proto"
	"github.com/bearlikelion/melay/internal/room"
	"github.com/bearlikelion/melay/internal/store"
)

// version is set at build time with -ldflags "-X main.version=v1.2.3".
var version = "dev"

// shutdownGrace bounds how long in-flight requests get to finish on SIGTERM.
const shutdownGrace = 10 * time.Second

func main() {
	configPath := flag.String("config", "melay.yaml", "path to the config file (optional)")
	healthcheck := flag.Bool("healthcheck", false, "probe a running server and exit; for container healthchecks")
	flag.Parse()

	cfg, err := config.Load(*configPath)
	if err != nil {
		slog.Error("config", "err", err)
		os.Exit(1)
	}

	if *healthcheck {
		os.Exit(probe(cfg.Addr))
	}

	log := newLogger(cfg)
	slog.SetDefault(log)

	st, err := openStore(cfg, log)
	if err != nil {
		log.Error("analytics store", "err", err)
		os.Exit(1)
	}
	defer st.Close()

	rooms := room.NewManager()
	h := hub.New(cfg, rooms, st, log)

	mux := http.NewServeMux()
	api.New(h, rooms, st, log, cfg.WebDir, version).Routes(mux)

	srv := &http.Server{
		Addr:              cfg.Addr,
		Handler:           mux,
		ReadHeaderTimeout: 10 * time.Second,
		// No write timeout: WebSocket connections are long-lived by design.
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	go func() {
		log.Info("melay listening",
			"version", version,
			"addr", cfg.Addr,
			"protocol", proto.Version,
			"games", len(cfg.Games),
			"allow_unregistered", cfg.Default.AllowUnregistered)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Error("listen", "err", err)
			stop()
		}
	}()

	<-ctx.Done()
	log.Info("shutting down")

	shutdownCtx, cancel := context.WithTimeout(context.Background(), shutdownGrace)
	defer cancel()
	if err := srv.Shutdown(shutdownCtx); err != nil {
		log.Warn("graceful shutdown failed", "err", err)
	}
}

// probe hits /healthz on a running instance and returns a process exit code.
// The scratch image ships no shell or curl, so the binary is its own healthcheck.
func probe(addr string) int {
	host, port, err := net.SplitHostPort(addr)
	if err != nil {
		return 1
	}
	if host == "" {
		host = "127.0.0.1"
	}

	client := &http.Client{Timeout: 3 * time.Second}
	resp, err := client.Get("http://" + net.JoinHostPort(host, port) + "/api/v1/health")
	if err != nil {
		return 1
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return 1
	}
	return 0
}

func newLogger(cfg *config.Config) *slog.Logger {
	level := slog.LevelInfo
	switch cfg.LogLevel {
	case "debug":
		level = slog.LevelDebug
	case "warn":
		level = slog.LevelWarn
	case "error":
		level = slog.LevelError
	}

	opts := &slog.HandlerOptions{Level: level}
	if cfg.LogJSON {
		return slog.New(slog.NewJSONHandler(os.Stdout, opts))
	}
	return slog.New(slog.NewTextHandler(os.Stdout, opts))
}

// openStore falls back to a no-op store when the database URL is empty, so the
// relay still runs in environments with no writable volume.
func openStore(cfg *config.Config, log *slog.Logger) (store.Store, error) {
	if cfg.DatabaseURL == "" || cfg.DatabaseURL == "none" {
		log.Warn("analytics disabled, no database url configured")
		return store.Nop{}, nil
	}
	return store.OpenSQLite(cfg.DatabaseURL, log)
}
