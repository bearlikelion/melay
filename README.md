# Melay

**Mark's Relay.** One Docker container plus one pure-GDScript addon gives you a Godot 4
`MultiplayerPeer` that works identically on Web, Mobile, PC and Steam.

No native build step, no per-platform binaries, no backend to operate. Point the addon at a
Melay URL with a game name and your existing `@rpc` functions start working across the internet.

```gdscript
Melay.configure("wss://relay.example.com", "spacewar", "1.0.0")
await Melay.connect_to_relay()

var result: MelayResult = await Melay.create_room({"max_players": 4})
print("Share this code: ", result.value.code)
# multiplayer.multiplayer_peer is now wired up. Your @rpc functions just work.
```

## Why it exists

Shipping a Godot multiplayer game to browsers and consoles usually means picking your poison:
run a dedicated server per game, adopt a large backend, or depend on a service you do not
control. Melay is the small piece in the middle. It relays packets, hands out rooms, and tells
you which of your games people are actually playing.

One container serves many games at once, namespaced by game id, so a single $5 VPS can sit
behind everything you ship.

## What you get

- **A real `MultiplayerPeer`.** `MultiplayerPeerExtension` in GDScript, so `@rpc`,
  `MultiplayerSynchronizer` and `MultiplayerSpawner` behave normally.
- **Every platform, one codebase.** WebSocket transport, which is the only thing that works
  the same in a browser, on a phone, and on a desktop. No export template surgery.
- **Rooms and lobbies.** Six-character share codes, plus a filterable public room list.
- **Server-side analytics.** Players online, peak concurrency, session counts, playtime,
  platform and version breakdowns, per game. Your game does not have to integrate anything to
  be measured.
- **Real transfer-mode handling.** Godot's channels and transfer modes survive the trip, and
  the relay sheds unreliable traffic under backpressure instead of stalling a room.
- **Version safety.** Rooms are keyed by game version, so an old build cannot join a new one
  and desync it.

## Quick start

### 1. Run the relay

```bash
cd server
docker compose up -d
```

The relay listens on `:8890`. A dashboard is at `http://localhost:8890/` and the stats API at
`http://localhost:8890/api/v1/stats`.

### 2. Install the addon

Copy `addons/melay/` into your project and enable **Melay** in
*Project > Project Settings > Plugins*. That registers the `Melay` autoload for you.

### 3. Connect

Either set *Project Settings > Melay > Connection* (there is a Remote/Local mode switch, so
moving between your laptop and production is a dropdown), or configure it in code:

```gdscript
func _ready() -> void:
	Melay.configure("ws://127.0.0.1:8890", "my-game", "1.0.0")
	Melay.set_display_name("Mark")

	var connected: MelayResult = await Melay.connect_to_relay()
	if connected.is_error():
		push_error(connected.message)
		return

	var hosted: MelayResult = await Melay.create_room({"max_players": 4})
	if hosted.is_error():
		push_error(hosted.message)
		return

	var room: MelayRoom = hosted.value
	print("Room code: ", room.code)
```

Another player joins with `await Melay.join_room("H4K2Q9")`. From that point
`multiplayer.multiplayer_peer` is set on both sides and ordinary Godot multiplayer applies.

### 4. Try the example

`examples/melay_demo/` is the demo project's main scene. It swaps one child screen at a time:

| Screen | What it does |
|------|------|
| `screens/menu_screen` | Pick a name, then host, join by code, or browse open rooms |
| `screens/lobby_screen` | Everyone marks themselves ready; the host starts once all are |
| `screens/game_screen` | 3-2-1 countdown, then a paddle arena with a host-simulated ball |

Every RPC lives on the main scene, since it is the only node with a stable path on every
peer. Screens report upward with signals and are driven downward with method calls, so none of
them touch Melay directly.

Two details in there are worth copying into a real game:

- **The countdown is scheduled against relay time, not local time.** The host sends the relay
  timestamp it wants play to begin at, and each peer converts that to its own clock with
  `Melay.get_relay_time_us()`. All peers hit zero together instead of drifting apart by a round
  trip. Peers that have not had a heartbeat reply yet fall back to counting locally.
- **Non-authoritative state is interpolated, never snapped.** Remote players ease toward the
  last position they were sent, and the ball is dead-reckoned forward from its last known
  velocity between the 20 updates a second that arrive, so it reads as continuous motion rather
  than stepping. Bounces are sent the instant they happen, since that is the one thing
  prediction cannot guess.

## API

Everything asynchronous returns a `MelayResult`, which is either a payload or an error, never
both. There are no exceptions and no separate error callbacks.

```gdscript
Melay.configure(url: String, game_id: String, game_version: String = "1.0.0") -> void
Melay.set_display_name(name: String) -> void
Melay.set_api_key(key: String) -> void

await Melay.connect_to_relay()                  # -> MelayResult
await Melay.create_room(options := {})          # -> MelayResult, value is a MelayRoom
await Melay.join_room(code, password := "")     # -> MelayResult, value is a MelayRoom
await Melay.join_or_create(options := {})       # -> MelayResult, quick play
await Melay.list_rooms(filter := {})            # -> MelayResult, value is an Array
Melay.leave_room() -> void
Melay.disconnect_from_relay() -> void
Melay.track(event: String, props := {}) -> void

Melay.is_in_room() -> bool
Melay.is_host() -> bool
Melay.get_room() -> MelayRoom
Melay.get_rtt_us() -> int
Melay.get_relay_time_us() -> int
Melay.get_clock_drift_us() -> int
Melay.has_clock_sync() -> bool
```

Signals:

```gdscript
Melay.connected
Melay.disconnected(reason: String)
Melay.peer_ready(peer: MelayPeer)
Melay.room_joined(room: MelayRoom)
Melay.room_left
Melay.peer_joined(info: MelayPeerInfo)
Melay.peer_left(info: MelayPeerInfo, reason: String)
Melay.error_received(code: String, message: String)
Melay.latency_updated(rtt_us: int, clock_offset_us: int)
```

`create_room` options: `name`, `max_players`, `visibility` (`"public"` or `"private"`), `tags`
(a free-form string map you can filter the room list on), `password`, `dedicated`.

`list_rooms` filters: `tags`, `only_joinable`, `limit`.

### Turning off automatic peer assignment

By default, joining a room assigns `multiplayer.multiplayer_peer` for you. If you set
*Melay > General > Auto Assign Peer* to off, assign it in the `peer_ready` signal and nowhere
else:

```gdscript
Melay.peer_ready.connect(func(peer: MelayPeer) -> void:
	multiplayer.multiplayer_peer = peer
)
```

Waiting for `room_joined` is too late. Godot only learns about existing players from the
`peer_connected` signals the peer emits between those two points, so a peer installed
afterwards starts with an empty peer list and RPCs silently go nowhere.

## Clock

Every client estimates the relay's clock from its heartbeat, so peers share a time reference
without trusting each other. `Melay.get_relay_time_us()` is the number to schedule against when
something must happen at the same moment for everyone.

`get_clock_offset_us()` is an epoch-scale conversion factor, not a small drift figure: local
ticks count from engine start while the relay reports Unix time. To judge the estimate's
quality, read `get_clock_drift_us()`, which is how far the estimate moved on the last sample,
and check `has_clock_sync()` before relying on any of it.

Because the relay is the time source rather than a peer, this reference survives the host
leaving. That is the groundwork for host migration and is the thing netfox cannot do, since it
pins its clock to peer 1.

## Peer identity

The relay assigns peer ids. The host holds peer id `1`, so `multiplayer.is_server()`,
`MultiplayerSpawner` and every Godot tutorial behave the way you expect. Other players get
`2..N`, and ids are never reused inside a room.

Each connection also has a stable `session_id` that survives a peer id being reassigned.
Anything the player sees should key off that rather than the integer.

## Hosting many games

One container, many games, namespaced by game id. See `server/melay.yaml`:

```yaml
default:
  max_rooms: 50
  max_players_per_room: 8
  allow_unregistered: true

games:
  spacewar:
    max_rooms: 500
    max_players_per_room: 16
    api_key: "${SPACEWAR_KEY}"
```

Auth is open by default so a local `docker compose up` just works. Setting `api_key` makes it
mandatory for that game; `allow_unregistered: false` turns the container into a closed relay
for a known list.

See `docs/HOSTING.md` for TLS, reverse proxies and browser requirements.

## Analytics

The relay records room and session lifecycle itself, so a game that never calls `track()` is
still fully measured. Nothing identifying is stored: `client_id` is a random per-install value,
and IP addresses are used for rate limiting and then dropped.

- Dashboard: `http://your-relay/`
- JSON: `GET /api/v1/stats?game=<id>&range=7d`, and `GET /api/v1/games`

Custom events are one call:

```gdscript
Melay.track("level_complete", {"level": "3", "time_ms": "42311"})
```

## Repository layout

```
addons/melay/         the addon, the only part you copy into a game
server/               the Go relay and its Dockerfile
docs/PROTOCOL.md      the normative wire protocol
docs/HOSTING.md       deployment, TLS and browser notes
examples/melay_demo/  menu, lobby and arena screens
tests/                headless end-to-end checks
```

## Testing

```bash
cd server && go test ./...     # protocol, relay semantics, drop policy, integration
tests/run_tests.sh             # two headless Godot instances against a real relay
```

`tests/run_tests.sh` builds and starts its own relay, then runs two pairs of headless Godot
instances: one exercising the peer directly, one driving the demo through menu, lobby,
ready-up, start and arena. Point it at an existing relay with
`MELAY_URL=ws://host:8890 tests/run_tests.sh`.

## Status

Working today: relay, rooms and lobbies, analytics, and the `MultiplayerPeer`, verified
end to end with two headless Godot clients and from a real browser.

Not built yet: automatic reconnection, host migration, tick synchronisation and rollback
helpers, and transports other than WebSocket. The protocol reserves opcodes for host migration
so adding it will not be a breaking change.

## Licence

MIT. See `LICENSE`.
