// Package config loads Melay server settings from a YAML file and the environment.
package config

import (
	"fmt"
	"os"
	"regexp"
	"strconv"
	"strings"

	"gopkg.in/yaml.v3"
)

// Defaults applied when neither the file nor the environment says otherwise.
const (
	DefaultAddr              = ":8890"
	DefaultMaxRooms          = 50
	DefaultMaxPlayersPerRoom = 8
	DefaultMaxPacketSize     = 262144
	DefaultMaxMessageSize    = 8 << 20
	DefaultMaxNameLength     = 32
	DefaultDatabaseURL       = "file:melay.db"
)

// GameConfig holds per-game limits and the optional shared secret.
type GameConfig struct {
	MaxRooms          int    `yaml:"max_rooms"`
	MaxPlayersPerRoom int    `yaml:"max_players_per_room"`
	MaxPacketSize     int    `yaml:"max_packet_size"`
	MaxMessageSize    int    `yaml:"max_message_size"`
	APIKey            string `yaml:"api_key"`
	Disabled          bool   `yaml:"disabled"`
}

// Defaults are the limits applied to games with no explicit entry.
type Defaults struct {
	MaxRooms          int  `yaml:"max_rooms"`
	MaxPlayersPerRoom int  `yaml:"max_players_per_room"`
	MaxPacketSize     int  `yaml:"max_packet_size"`
	MaxMessageSize    int  `yaml:"max_message_size"`
	AllowUnregistered bool `yaml:"allow_unregistered"`
}

// Config is the whole server configuration.
type Config struct {
	Addr        string `yaml:"addr"`
	DatabaseURL string `yaml:"database_url"`
	// WebDir, when set, is a Godot web export served at /play alongside the relay.
	// Same origin as the WebSocket, which sidesteps mixed content and CORS entirely.
	WebDir   string                `yaml:"web_dir"`
	LogLevel string                `yaml:"log_level"`
	LogJSON  bool                  `yaml:"log_json"`
	Games    map[string]GameConfig `yaml:"games"`
	Default  Defaults              `yaml:"default"`
}

// Resolved is the effective limit set for one game id, after defaults are applied.
type Resolved struct {
	MaxRooms          int
	MaxPlayersPerRoom int
	MaxPacketSize     int
	MaxMessageSize    int
	APIKey            string
	Registered        bool
}

var envRef = regexp.MustCompile(`\$\{([A-Za-z_][A-Za-z0-9_]*)\}`)

// New returns a Config with every default filled in.
func New() *Config {
	return &Config{
		Addr:        DefaultAddr,
		DatabaseURL: DefaultDatabaseURL,
		LogLevel:    "info",
		Games:       map[string]GameConfig{},
		Default: Defaults{
			MaxRooms:          DefaultMaxRooms,
			MaxPlayersPerRoom: DefaultMaxPlayersPerRoom,
			MaxPacketSize:     DefaultMaxPacketSize,
			MaxMessageSize:    DefaultMaxMessageSize,
			AllowUnregistered: true,
		},
	}
}

// Load reads an optional YAML file and then applies environment overrides.
// A missing path is not an error, so the container runs with no config mounted.
func Load(path string) (*Config, error) {
	cfg := New()

	if path != "" {
		raw, err := os.ReadFile(path)
		if err != nil {
			if !os.IsNotExist(err) {
				return nil, fmt.Errorf("read config %s: %w", path, err)
			}
		} else {
			if err := yaml.Unmarshal(expandEnv(raw), cfg); err != nil {
				return nil, fmt.Errorf("parse config %s: %w", path, err)
			}
		}
	}

	cfg.applyEnv()
	cfg.fillZeroes()
	return cfg, cfg.validate()
}

// expandEnv substitutes ${VAR} references so secrets stay out of the YAML file.
func expandEnv(raw []byte) []byte {
	return envRef.ReplaceAllFunc(raw, func(m []byte) []byte {
		name := string(envRef.FindSubmatch(m)[1])
		return []byte(os.Getenv(name))
	})
}

func (c *Config) applyEnv() {
	// Cloud Run, Heroku and friends inject PORT and expect the process to honour it.
	if v := os.Getenv("PORT"); v != "" {
		c.Addr = ":" + v
	}
	if v := os.Getenv("MELAY_ADDR"); v != "" {
		c.Addr = v
	}
	if v := os.Getenv("MELAY_DATABASE_URL"); v != "" {
		c.DatabaseURL = v
	}
	if v := os.Getenv("MELAY_WEB_DIR"); v != "" {
		c.WebDir = v
	}
	if v := os.Getenv("MELAY_LOG_LEVEL"); v != "" {
		c.LogLevel = v
	}
	if v := os.Getenv("MELAY_LOG_JSON"); v != "" {
		c.LogJSON = v == "1" || strings.EqualFold(v, "true")
	}
	if v := os.Getenv("MELAY_ALLOW_UNREGISTERED"); v != "" {
		c.Default.AllowUnregistered = v == "1" || strings.EqualFold(v, "true")
	}
	if n, ok := envInt("MELAY_MAX_ROOMS"); ok {
		c.Default.MaxRooms = n
	}
	if n, ok := envInt("MELAY_MAX_PLAYERS_PER_ROOM"); ok {
		c.Default.MaxPlayersPerRoom = n
	}
	if n, ok := envInt("MELAY_MAX_PACKET_SIZE"); ok {
		c.Default.MaxPacketSize = n
	}
	if n, ok := envInt("MELAY_MAX_MESSAGE_SIZE"); ok {
		c.Default.MaxMessageSize = n
	}
}

func envInt(key string) (int, bool) {
	v := os.Getenv(key)
	if v == "" {
		return 0, false
	}
	n, err := strconv.Atoi(v)
	if err != nil {
		return 0, false
	}
	return n, true
}

func (c *Config) fillZeroes() {
	if c.Addr == "" {
		c.Addr = DefaultAddr
	}
	if c.DatabaseURL == "" {
		c.DatabaseURL = DefaultDatabaseURL
	}
	if c.LogLevel == "" {
		c.LogLevel = "info"
	}
	if c.Default.MaxRooms <= 0 {
		c.Default.MaxRooms = DefaultMaxRooms
	}
	if c.Default.MaxPlayersPerRoom <= 0 {
		c.Default.MaxPlayersPerRoom = DefaultMaxPlayersPerRoom
	}
	if c.Default.MaxPacketSize <= 0 {
		c.Default.MaxPacketSize = DefaultMaxPacketSize
	}
	if c.Default.MaxMessageSize <= 0 {
		c.Default.MaxMessageSize = DefaultMaxMessageSize
	}
	if c.Games == nil {
		c.Games = map[string]GameConfig{}
	}
}

func (c *Config) validate() error {
	for name, g := range c.Games {
		if name == "" {
			return fmt.Errorf("config: game with empty id")
		}
		if g.MaxPlayersPerRoom < 0 || g.MaxRooms < 0 || g.MaxPacketSize < 0 || g.MaxMessageSize < 0 {
			return fmt.Errorf("config: negative limit for game %q", name)
		}
	}
	return nil
}

// Resolve returns the effective limits for a game id, falling back to defaults.
// Registered is false when the id has no entry, which callers reject unless
// Default.AllowUnregistered is set.
func (c *Config) Resolve(game string) Resolved {
	r := Resolved{
		MaxRooms:          c.Default.MaxRooms,
		MaxPlayersPerRoom: c.Default.MaxPlayersPerRoom,
		MaxPacketSize:     c.Default.MaxPacketSize,
		MaxMessageSize:    c.Default.MaxMessageSize,
	}
	g, ok := c.Games[game]
	if !ok {
		return r
	}
	r.Registered = true
	r.APIKey = g.APIKey
	if g.MaxRooms > 0 {
		r.MaxRooms = g.MaxRooms
	}
	if g.MaxPlayersPerRoom > 0 {
		r.MaxPlayersPerRoom = g.MaxPlayersPerRoom
	}
	if g.MaxPacketSize > 0 {
		r.MaxPacketSize = g.MaxPacketSize
	}
	if g.MaxMessageSize > 0 {
		r.MaxMessageSize = g.MaxMessageSize
	}
	// A ceiling below one frame would refuse traffic a single RELAY carries fine.
	if r.MaxMessageSize < r.MaxPacketSize {
		r.MaxMessageSize = r.MaxPacketSize
	}
	return r
}

// Enabled reports whether a game id may connect at all.
func (c *Config) Enabled(game string) bool {
	g, ok := c.Games[game]
	if !ok {
		return c.Default.AllowUnregistered
	}
	return !g.Disabled
}
