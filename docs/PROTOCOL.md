# Melay wire protocol

Version `1`.

This document is normative. The Go server in `server/` and the GDScript addon in `addons/melay/`
are both implementations of it, and either may be replaced independently as long as it holds.

## Transport

A single WebSocket connection per client, to `ws://host:8890/ws` or `wss://host/ws`.

All frames are **binary** WebSocket messages. One Melay frame per WebSocket message. Text frames
are a protocol error.

## Framing

```
+--------+--------------------------+
| u8 op  | payload (0..N bytes)     |
+--------+--------------------------+
```

Payloads are one of two kinds, fixed per opcode:

- **JSON** payloads are UTF-8 encoded JSON objects. Used for control messages, which are
  infrequent and benefit from being easy to extend.
- **Binary** payloads have a fixed header layout. Used for the relay hot path and for timing,
  where re-encoding would be wasteful.

All multi-byte integers are **little-endian**. This matches `PackedByteArray.encode_u32` and
friends in Godot, so the GDScript client needs no byte swapping, and costs the Go side nothing.

Unknown opcodes must be ignored rather than treated as fatal, so that a newer peer talking to an
older one degrades instead of disconnecting.

## Opcodes

### Client to server

| Op | Name | Payload |
|------|----------------|--------|
| `0x01` | `HELLO` | JSON |
| `0x02` | `ROOM_CREATE` | JSON |
| `0x03` | `ROOM_JOIN` | JSON |
| `0x04` | `ROOM_LEAVE` | empty |
| `0x05` | `ROOM_LIST` | JSON |
| `0x06` | `RELAY` | binary |
| `0x07` | `PING` | binary |
| `0x08` | `SNAPSHOT_PUT` | binary (reserved, phase 3) |
| `0x09` | `TRACK` | JSON |

### Server to client

| Op | Name | Payload |
|------|----------------|--------|
| `0x81` | `WELCOME` | JSON |
| `0x82` | `ROOM_STATE` | JSON |
| `0x83` | `PEER_JOIN` | JSON |
| `0x84` | `PEER_LEAVE` | JSON |
| `0x85` | `RELAY` | binary |
| `0x86` | `PONG` | binary |
| `0x87` | `HOST_CHANGED` | JSON (reserved, phase 3) |
| `0x88` | `SNAPSHOT_GET` | binary (reserved, phase 3) |
| `0x89` | `ERROR` | JSON |
| `0x8A` | `ROOM_LIST` | JSON |

## Handshake

`HELLO` must be the first frame the client sends. Any other frame before it is an error with
code `bad_frame`. The server replies with `WELCOME` or with `ERROR` followed by close.

### `0x01 HELLO`

```json
{
  "protocol": 1,
  "game": "spacewar",
  "game_version": "1.0.0",
  "client_id": "8f14e45fceea167a5a36dedd4bea2543",
  "display_name": "Mark",
  "platform": "linux",
  "auth": "optional-per-game-key",
  "resume": "optional-session-id"
}
```

`game` and `client_id` are required. `game` namespaces everything: two games on one Melay
instance never see each other's rooms. `client_id` is a random per-install identifier, not a
device id and not PII.

`resume` carries a previous `session_id` to reclaim a seat held open after a drop. The server
either honours it or ignores it and issues a fresh session, so the client must always read the
returned `session_id` rather than assume its own.

If `protocol` does not match the server's, the server replies `ERROR` with code
`protocol_mismatch` and closes.

### `0x81 WELCOME`

```json
{
  "protocol": 1,
  "session_id": "b1946ac92492d2347c6235b4d2611184",
  "server_time_us": 1755357000123456,
  "resumed": false,
  "limits": {
	"max_packet_size": 262144,
	"max_players_per_room": 8,
	"max_rooms": 50,
	"max_name_length": 32
  }
}
```

`limits.max_packet_size` is what the client must report from
`MultiplayerPeerExtension._get_max_packet_size`.

## Rooms

### `0x02 ROOM_CREATE`

```json
{
  "name": "Mark's game",
  "max_players": 4,
  "visibility": "public",
  "tags": { "mode": "ffa", "map": "dust" },
  "password": "",
  "dedicated": false
}
```

`visibility` is `"public"` or `"private"`. Private rooms are reachable by code only and never
appear in `ROOM_LIST`. `tags` is a free-form string-to-string map, filterable in `ROOM_LIST`.
`dedicated` marks the creator as a permanent host, which disables host migration for the room.

The creator becomes the host and receives peer id `1`.

### `0x03 ROOM_JOIN`

```json
{ "code": "H4K2Q9", "password": "" }
```

`code` is case-insensitive and normalised server-side. `room_id` may be supplied instead.

Rooms are keyed by `(game, game_version, code)`. A client cannot join a room created by a
different `game_version`, which stops an old build from desyncing a new one.

### `0x82 ROOM_STATE`

Sent to a client on join, and re-sent whenever the membership changes in a way a delta cannot
express. It is the authoritative snapshot of the room.

```json
{
  "room_id": "0f8e...",
  "code": "H4K2Q9",
  "name": "Mark's game",
  "host_peer_id": 1,
  "self_peer_id": 2,
  "max_players": 4,
  "visibility": "public",
  "dedicated": false,
  "tags": { "mode": "ffa" },
  "peers": [
	{
	  "peer_id": 1,
	  "session_id": "b194...",
	  "display_name": "Mark",
	  "platform": "linux",
	  "is_host": true
	}
  ]
}
```

`peers` always includes the recipient. `self_peer_id` is the recipient's own Godot peer id.

### `0x83 PEER_JOIN` and `0x84 PEER_LEAVE`

```json
{ "peer_id": 3, "session_id": "c2f1...", "display_name": "Ada", "platform": "web", "is_host": false }
```

```json
{ "peer_id": 3, "reason": "disconnected" }
```

`reason` is one of `left`, `disconnected`, `kicked`, `timeout`.

### `0x04 ROOM_LEAVE`

Empty payload. The connection stays open and returns to the lobby state, so a client can leave
one room and join another without reconnecting.

### `0x05 ROOM_LIST` and `0x8A ROOM_LIST`

Request:

```json
{ "tags": { "mode": "ffa" }, "only_joinable": true, "limit": 50 }
```

`tags` matching is exact on every supplied key. Keys the request omits are unconstrained.

Response:

```json
{
  "rooms": [
    {
      "room_id": "0f8e...",
      "code": "H4K2Q9",
	  "name": "Mark's game",
	  "player_count": 2,
	  "max_players": 4,
	  "has_password": false,
	  "tags": { "mode": "ffa" },
	  "created_at": 1755357000
    }
  ]
}
```

Only `visibility: "public"` rooms of the caller's `(game, game_version)` are listed.

## Relaying

### `0x06 RELAY` (client to server)

```
+--------+------------+-----------+--------+-----------------+
| u8 op  | i32 target | u8 channel| u8 mode| packet bytes    |
+--------+------------+-----------+--------+-----------------+
```

Header is 6 bytes after the opcode.

`target` uses Godot's `MultiplayerPeer` addressing exactly:

| `target` | Meaning |
|------|-----------|
| `0` | broadcast to every other peer in the room |
| `> 0` | send to that peer id only |
| `< 0` | broadcast to every peer except `abs(target)` |

The sender never receives its own packet back, in any of the three cases.

`mode` mirrors `MultiplayerPeer.TransferMode`:

| `mode` | Meaning |
|------|-----------|
| `0` | `TRANSFER_MODE_UNRELIABLE` |
| `1` | `TRANSFER_MODE_UNRELIABLE_ORDERED` |
| `2` | `TRANSFER_MODE_RELIABLE` |

`channel` is the Godot transfer channel, `0..255`.

### `0x85 RELAY` (server to client)

```
+--------+------------+-----------+--------+-----------------+
| u8 op  | i32 from   | u8 channel| u8 mode| packet bytes    |
+--------+------------+-----------+--------+-----------------+
```

`from` is the originating peer id. `channel` and `mode` are copied unchanged from the sender, so
the receiving peer can answer `_get_packet_channel` and `_get_packet_mode` truthfully.

### Delivery guarantees and the drop policy

WebSocket is reliable and ordered, so every mode is delivered at least as strongly as requested.
`mode` is not used to weaken delivery on a healthy connection.

It is used under backpressure. Each peer has a bounded outbound queue. When that queue is full
the server sheds load in this order:

1. Drop the oldest queued `UNRELIABLE` packet.
2. If none, drop the oldest queued `UNRELIABLE_ORDERED` packet.
3. If none, and the queue is still over the hard limit, close the connection with
   `ERROR` code `slow_consumer`.

The effect is that one slow client degrades to stale positional updates rather than stalling
everyone else in the room.

Packets larger than `limits.max_packet_size` are rejected with `ERROR` code `packet_too_large`
and are not relayed.

## Timing

### `0x07 PING` and `0x86 PONG`

```
PING:  +--------+---------------------+
       | u8 op  | u64 client_time_us  |
       +--------+---------------------+

PONG:  +--------+---------------------+---------------------+
       | u8 op  | u64 client_time_us  | u64 server_time_us  |
       +--------+---------------------+---------------------+
```

`client_time_us` is echoed back untouched, so the client can compute round-trip time without
keeping per-ping state. `server_time_us` is the server's Unix time in microseconds at the moment
the ping was processed.

The client sends `PING` once a second. Six consecutive missed pongs mean the connection is
dead. These samples are also the input to the phase 4 clock synchronisation, where the relay,
not a peer, is the time source.

## Analytics

### `0x09 TRACK`

```json
{ "event": "level_complete", "props": { "level": "3", "time_ms": "42311" } }
```

Custom game events. `props` values are strings. Room and session lifecycle events are recorded
by the server without any client involvement, so a game that never sends `TRACK` is still fully
measured.

## Errors

### `0x89 ERROR`

```json
{ "code": "room_full", "message": "room H4K2Q9 is full (4/4)" }
```

`message` is for logs and developers, not for display. Clients should branch on `code`.

| Code | Fatal | Meaning |
|------|-------|---------|
| `protocol_mismatch` | yes | Client and server disagree on protocol version |
| `bad_frame` | yes | Malformed frame, or a frame out of sequence |
| `unauthorized` | yes | Missing or wrong `auth` for a game that requires one |
| `unknown_game` | yes | Game id not registered and `allow_unregistered` is false |
| `server_full` | yes | Connection or room capacity reached |
| `slow_consumer` | yes | Outbound queue exceeded its hard limit |
| `rate_limited` | no | Too many control messages; back off and retry |
| `room_not_found` | no | No such code |
| `room_full` | no | Room is at `max_players` |
| `wrong_password` | no | Password did not match |
| `version_mismatch` | no | Room belongs to a different `game_version` |
| `already_in_room` | no | Join or create attempted while already in a room |
| `not_in_room` | no | Relay or leave attempted outside a room |
| `packet_too_large` | no | Relay payload above `limits.max_packet_size` |
| `internal` | no | Server-side fault |

Fatal errors are followed by a WebSocket close. Non-fatal errors leave the connection usable.

## Reserved for phase 3: host migration

These opcodes are allocated now so the protocol version does not have to change later.

`0x08 SNAPSHOT_PUT` (host only):

```
+--------+------------+-----------------+
| u8 op  | u64 tick   | snapshot bytes  |
+--------+------------+-----------------+
```

`0x88 SNAPSHOT_GET` has the same layout and is sent to a promoted host.

`0x87 HOST_CHANGED`:

```json
{ "new_host_peer_id": 1, "previous_host_peer_id": 1, "snapshot_tick": 8134 }
```

## Connection state

Godot's `MultiplayerPeer.ConnectionStatus` has three states and Melay has five. The mapping the
addon uses:

| Melay state | `_get_connection_status()` |
|------|------|
| `DISCONNECTED` | `CONNECTION_DISCONNECTED` |
| `CONNECTING` (socket opening) | `CONNECTION_CONNECTING` |
| `CONNECTED` (in lobby, no room) | `CONNECTION_CONNECTING` |
| `JOINING` (room requested) | `CONNECTION_CONNECTING` |
| `IN_ROOM` | `CONNECTION_CONNECTED` |

Reporting `CONNECTION_CONNECTED` before a peer id exists would make `SceneMultiplayer` start
using the peer while it still has no identity, so the lobby states deliberately report
`CONNECTION_CONNECTING`. The full state is available on `Melay.status` for the game's own UI.
