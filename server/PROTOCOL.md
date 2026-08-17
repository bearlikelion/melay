# Wire protocol

Version `1`. This page is normative. The Go server and the GDScript addon are both
implementations of it, and either may be replaced independently as long as it holds.


## Transport

A single WebSocket connection per client, to `ws://host:8890/ws` or `wss://host/ws`.

All frames are **binary** WebSocket messages, one Melay frame per message. Text frames are a
protocol error.

## Framing

```
+--------+--------------------------+
| u8 op  | payload (0..N bytes)     |
+--------+--------------------------+
```

Payloads are one of two kinds, fixed per opcode:

- **JSON** payloads are UTF-8 encoded objects. Used for control messages, which are infrequent
  and benefit from being easy to extend.
- **Binary** payloads have a fixed header layout. Used for the relay hot path and for timing,
  where re-encoding would be wasteful.

All multi-byte integers are **little-endian**. That matches `PackedByteArray.encode_u32` and
friends in Godot, so the GDScript client needs no byte swapping, and costs the Go side nothing.

Unknown opcodes must be ignored rather than treated as fatal, so a newer peer talking to an
older one degrades instead of disconnecting.

## Opcodes

| Op | Client to server | Payload |
|---|---|---|
| `0x01` | `HELLO` | JSON |
| `0x02` | `ROOM_CREATE` | JSON |
| `0x03` | `ROOM_JOIN` | JSON |
| `0x04` | `ROOM_LEAVE` | empty |
| `0x05` | `ROOM_LIST` | JSON |
| `0x06` | `RELAY` | binary |
| `0x07` | `PING` | binary |
| `0x08` | `SNAPSHOT_PUT` | binary (reserved) |
| `0x09` | `TRACK` | JSON |
| `0x0A` | `RELAY_FRAGMENT` | binary |

| Op | Server to client | Payload |
|---|---|---|
| `0x81` | `WELCOME` | JSON |
| `0x82` | `ROOM_STATE` | JSON |
| `0x83` | `PEER_JOIN` | JSON |
| `0x84` | `PEER_LEAVE` | JSON |
| `0x85` | `RELAY` | binary |
| `0x86` | `PONG` | binary |
| `0x87` | `HOST_CHANGED` | JSON (reserved) |
| `0x88` | `SNAPSHOT_GET` | binary (reserved) |
| `0x89` | `ERROR` | JSON |
| `0x8A` | `ROOM_LIST` | JSON |
| `0x8B` | `RELAY_FRAGMENT` | binary |

## Handshake

`HELLO` must be the first frame the client sends. Anything else before it is `bad_frame`. The
server replies with `WELCOME`, or `ERROR` followed by close.

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

`game` and `client_id` are required. `game` namespaces everything. `client_id` is a random
per-install identifier, not a device id and not PII.

`resume` carries a previous `session_id` to reclaim a seat held open after a drop. The server
may honour it or issue a fresh session, so the client must always read the returned
`session_id` rather than assume its own.

```json
{
  "protocol": 1,
  "session_id": "b1946ac92492d2347c6235b4d2611184",
  "server_time_us": 1755357000123456,
  "resumed": false,
  "limits": {
    "max_packet_size": 262144,
    "max_message_size": 8388608,
    "max_players_per_room": 8,
    "max_rooms": 50,
    "max_name_length": 32
  }
}
```

`limits.max_packet_size` is the largest packet one frame carries.
`limits.max_message_size` is the largest a game may send, reached by splitting it across
frames, and is what the client reports from `MultiplayerPeerExtension._get_max_packet_size`.

A relay that omits `max_message_size` does not route `RELAY_FRAGMENT`. Clients must treat its
absence as a ceiling of `max_packet_size` and never fragment, since unknown opcodes are
ignored rather than refused and the fragments would be dropped without a word.

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

Private rooms are reachable by code only and never appear in `ROOM_LIST`. `dedicated` marks the
creator a permanent host, which disables host migration for the room. The creator receives peer
id `1`.

### `0x03 ROOM_JOIN`

```json
{ "code": "H4K2Q9", "password": "" }
```

`code` is case-insensitive and normalised server-side. `room_id` may be supplied instead.

Rooms are keyed by `(game, game_version, code)`, so a client cannot join a room created by a
different `game_version`. That is what stops an old build from desyncing a new one.

### `0x82 ROOM_STATE`

The authoritative snapshot, sent on join and whenever membership changes in a way a delta
cannot express.

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

### `0x05` and `0x8A ROOM_LIST`

```json
{ "tags": { "mode": "ffa" }, "only_joinable": true, "limit": 50 }
```

Tag matching is exact on every supplied key; keys the request omits are unconstrained. Only
public rooms of the caller's `(game, game_version)` are listed.

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

## Relaying

```
client to server:
+--------+------------+-----------+--------+-----------------+
| u8 op  | i32 target | u8 channel| u8 mode| packet bytes    |
+--------+------------+-----------+--------+-----------------+

server to client:
+--------+------------+-----------+--------+-----------------+
| u8 op  | i32 from   | u8 channel| u8 mode| packet bytes    |
+--------+------------+-----------+--------+-----------------+
```

The header is 6 bytes after the opcode. `target` uses Godot's `MultiplayerPeer` addressing
exactly:

| `target` | Meaning |
|---|---|
| `0` | broadcast to every other peer in the room |
| `> 0` | send to that peer id only |
| `< 0` | broadcast to every peer except `abs(target)` |

The sender never receives its own packet back, in any of the three cases.

`mode` mirrors `MultiplayerPeer.TransferMode`: `0` unreliable, `1` unreliable ordered, `2`
reliable. `channel` is the Godot transfer channel, `0..255`. Both are copied unchanged to the
receiver so it can answer `_get_packet_channel` and `_get_packet_mode` truthfully.

### Fragmentation

A packet above `limits.max_packet_size` is split by the sending client and put back together
by the receiving one. The relay routes the pieces and holds none of them.

```
client to server:
+-------+------------+-----------+--------+---------+--------+---------+-----------+-------+
| u8 op | i32 target | u8 channel| u8 mode| u16 msg | u16 idx| u16 cnt | u32 total | slice |
+-------+------------+-----------+--------+---------+--------+---------+-----------+-------+

server to client:
+-------+------------+-----------+--------+---------+--------+---------+-----------+-------+
| u8 op | i32 from   | u8 channel| u8 mode| u16 msg | u16 idx| u16 cnt | u32 total | slice |
+-------+------------+-----------+--------+---------+--------+---------+-----------+-------+
```

The header is the relay header plus ten bytes. `target`, `channel` and `mode` mean what they
do for `RELAY`, and `channel` and `mode` are the sender's original request rather than how the
fragment travels. `msg` identifies the message, `idx` the slice within it, `cnt` how many
slices the message has, and `total` how many bytes they add up to.

Every fragment of a message repeats the same `msg`, `cnt` and `total`, so a receiver can size
the message from the first slice and treat a change in any of them as a broken set.

Fragments are queued reliably whatever `mode` says, because the drop policy below sheds
individual frames and one shed fragment strands the whole message. Slices therefore arrive in
the order they were sent, and a receiver may treat a slice that does not continue the message
in hand as a broken set and discard it.

The relay rejects a fragment whose `idx` falls outside `cnt` with `bad_frame`, a `cnt` larger
than `total` with `bad_frame`, a slice above `max_packet_size` with `packet_too_large`, and a
`total` above `limits.max_message_size` with `packet_too_large`. That last check is what
bounds a message without the relay ever buffering one, and it is exact: a message of exactly
`max_message_size` is routed, one byte more is refused.

A receiver must enforce `total` as well, discarding the set once the slices it has collected
run past it. The relay forwards slices without adding them up, so a sender that understates
`total` is only caught on the far side.

### Delivery and the drop policy

WebSocket is reliable and ordered, so every mode is delivered at least as strongly as
requested. `mode` is not used to weaken delivery on a healthy connection.

It is used under backpressure. Each peer has a bounded outbound queue, and when it fills the
server sheds load in this order:

1. Drop the oldest queued `UNRELIABLE` packet.
2. If none, drop the oldest queued `UNRELIABLE_ORDERED` packet.
3. If none, and the queue is still over the hard limit, close with `slow_consumer`.

One slow client degrades to stale positional updates rather than stalling the room.

Packets larger than `limits.max_packet_size` are rejected with `packet_too_large` and are not
relayed.

## Timing

```
PING:  +--------+---------------------+
       | u8 op  | u64 client_time_us  |
       +--------+---------------------+

PONG:  +--------+---------------------+---------------------+
       | u8 op  | u64 client_time_us  | u64 server_time_us  |
       +--------+---------------------+---------------------+
```

`client_time_us` is echoed back untouched, so the client computes round-trip time without
keeping per-ping state. `server_time_us` is the server's Unix time in microseconds when the
ping was processed.

The client sends `PING` once a second. Six consecutive missed pongs mean the connection is
dead. These samples are also what gives every peer a shared estimate of relay time.

## Analytics

```json
{ "event": "level_complete", "props": { "level": "3", "time_ms": "42311" } }
```

Custom game events, values as strings. Room and session lifecycle is recorded by the server
itself, so a game that never sends `TRACK` is still fully measured.

## Errors

```json
{ "code": "room_full", "message": "room H4K2Q9 is full (4/4)" }
```

`message` is for logs and developers, not for display. Branch on `code`.

| Code | Fatal | Meaning |
|---|---|---|
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

## Reserved for host migration

Allocated now so the protocol version does not have to change later.

```
0x08 SNAPSHOT_PUT (host only), 0x88 SNAPSHOT_GET (to a promoted host):
+--------+------------+-----------------+
| u8 op  | u64 tick   | snapshot bytes  |
+--------+------------+-----------------+
```

```json
{ "new_host_peer_id": 1, "previous_host_peer_id": 1, "snapshot_tick": 8134 }
```

## Connection state

Godot's `MultiplayerPeer.ConnectionStatus` has three states and Melay has five:

| Melay state | `_get_connection_status()` |
|---|---|
| `DISCONNECTED` | `CONNECTION_DISCONNECTED` |
| `CONNECTING` (socket opening) | `CONNECTION_CONNECTING` |
| `CONNECTED` (in lobby, no room) | `CONNECTION_CONNECTING` |
| `JOINING` (room requested) | `CONNECTION_CONNECTING` |
| `IN_ROOM` | `CONNECTION_CONNECTED` |

Reporting `CONNECTION_CONNECTED` before a peer id exists would make `SceneMultiplayer` start
using the peer while it has no identity, so the lobby states deliberately report
`CONNECTION_CONNECTING`. The full state is on `Melay.get_status()` for the game's own UI.

## HTTP surface

| Path | Purpose |
|---|---|
| `GET /ws` | The WebSocket endpoint above |
| `GET /api/v1/health` | Liveness. Use this rather than `/healthz`, which some load balancers answer themselves |
| `GET /healthz` | Same handler, for local and Docker healthchecks |
| `GET /api/v1/stats?game=&range=` | Aggregate analytics as JSON |
| `GET /api/v1/games` | Every game id the relay has seen |
| `GET /` | The embedded dashboard |

The JSON endpoints send `Access-Control-Allow-Origin: *`, so a dashboard hosted elsewhere can
read them.
