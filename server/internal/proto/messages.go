package proto

// ErrorCode identifies a failure to the client. Clients branch on this, never on Message.
type ErrorCode string

const (
	ErrProtocolMismatch ErrorCode = "protocol_mismatch"
	ErrBadFrame         ErrorCode = "bad_frame"
	ErrUnauthorized     ErrorCode = "unauthorized"
	ErrUnknownGame      ErrorCode = "unknown_game"
	ErrServerFull       ErrorCode = "server_full"
	ErrSlowConsumer     ErrorCode = "slow_consumer"
	ErrRateLimited      ErrorCode = "rate_limited"
	ErrRoomNotFound     ErrorCode = "room_not_found"
	ErrRoomFull         ErrorCode = "room_full"
	ErrWrongPassword    ErrorCode = "wrong_password"
	ErrVersionMismatch  ErrorCode = "version_mismatch"
	ErrAlreadyInRoom    ErrorCode = "already_in_room"
	ErrNotInRoom        ErrorCode = "not_in_room"
	ErrPacketTooLarge   ErrorCode = "packet_too_large"
	ErrInternal         ErrorCode = "internal"
)

// Fatal reports whether the server closes the connection after sending this code.
func (c ErrorCode) Fatal() bool {
	switch c {
	case ErrProtocolMismatch, ErrBadFrame, ErrUnauthorized, ErrUnknownGame,
		ErrServerFull, ErrSlowConsumer:
		return true
	}
	return false
}

// Hello is the first frame a client sends.
type Hello struct {
	Protocol    int    `json:"protocol"`
	Game        string `json:"game"`
	GameVersion string `json:"game_version"`
	ClientID    string `json:"client_id"`
	DisplayName string `json:"display_name"`
	Platform    string `json:"platform"`
	Auth        string `json:"auth,omitempty"`
	Resume      string `json:"resume,omitempty"`
}

// Limits are the server-side caps a client must respect.
type Limits struct {
	MaxPacketSize     int `json:"max_packet_size"`
	MaxPlayersPerRoom int `json:"max_players_per_room"`
	MaxRooms          int `json:"max_rooms"`
	MaxNameLength     int `json:"max_name_length"`
}

// Welcome answers a successful Hello.
type Welcome struct {
	Protocol     int    `json:"protocol"`
	SessionID    string `json:"session_id"`
	ServerTimeUS int64  `json:"server_time_us"`
	Resumed      bool   `json:"resumed"`
	Limits       Limits `json:"limits"`
}

// RoomCreate requests a new room.
type RoomCreate struct {
	Name       string            `json:"name"`
	MaxPlayers int               `json:"max_players"`
	Visibility string            `json:"visibility"`
	Tags       map[string]string `json:"tags"`
	Password   string            `json:"password"`
	Dedicated  bool              `json:"dedicated"`
}

// RoomJoin requests entry to an existing room by code or id.
type RoomJoin struct {
	Code     string `json:"code"`
	RoomID   string `json:"room_id"`
	Password string `json:"password"`
}

// RoomListRequest filters the public room list.
type RoomListRequest struct {
	Tags         map[string]string `json:"tags"`
	OnlyJoinable bool              `json:"only_joinable"`
	Limit        int               `json:"limit"`
}

// PeerInfo describes one member of a room.
type PeerInfo struct {
	PeerID      int32  `json:"peer_id"`
	SessionID   string `json:"session_id"`
	DisplayName string `json:"display_name"`
	Platform    string `json:"platform"`
	IsHost      bool   `json:"is_host"`
}

// RoomState is the authoritative snapshot of a room, sent on join and on membership change.
type RoomState struct {
	RoomID     string            `json:"room_id"`
	Code       string            `json:"code"`
	Name       string            `json:"name"`
	HostPeerID int32             `json:"host_peer_id"`
	SelfPeerID int32             `json:"self_peer_id"`
	MaxPlayers int               `json:"max_players"`
	Visibility string            `json:"visibility"`
	Dedicated  bool              `json:"dedicated"`
	Tags       map[string]string `json:"tags"`
	Peers      []PeerInfo        `json:"peers"`
}

// PeerLeave reports a departure and why it happened.
type PeerLeave struct {
	PeerID int32  `json:"peer_id"`
	Reason string `json:"reason"`
}

// Leave reasons carried by PeerLeave.
const (
	ReasonLeft         = "left"
	ReasonDisconnected = "disconnected"
	ReasonKicked       = "kicked"
	ReasonTimeout      = "timeout"
)

// RoomSummary is one entry in a room list response.
type RoomSummary struct {
	RoomID      string            `json:"room_id"`
	Code        string            `json:"code"`
	Name        string            `json:"name"`
	PlayerCount int               `json:"player_count"`
	MaxPlayers  int               `json:"max_players"`
	HasPassword bool              `json:"has_password"`
	Tags        map[string]string `json:"tags"`
	CreatedAt   int64             `json:"created_at"`
}

// RoomListResponse answers a RoomListRequest.
type RoomListResponse struct {
	Rooms []RoomSummary `json:"rooms"`
}

// Track is a custom analytics event from a game.
type Track struct {
	Event string            `json:"event"`
	Props map[string]string `json:"props"`
}

// Error reports a failure. Message is for logs, not for display.
type Error struct {
	Code    ErrorCode `json:"code"`
	Message string    `json:"message"`
}

// Visibility values for RoomCreate.
const (
	VisibilityPublic  = "public"
	VisibilityPrivate = "private"
)
