---
title: Reference
nav_order: 5
---

# Reference

Everything on the `Melay` autoload. Calls marked `await` return a `MelayResult`.

## Setup

| Call | Does |
|---|---|
| `Melay.configure(url, game_id, game_version)` | Point at a relay. Wins over everything else. |
| `Melay.set_display_name(name)` | Name other players see |
| `Melay.set_api_key(key)` | Only if your relay requires one |

## Connecting

| Call | Does |
|---|---|
| `await Melay.connect_to_relay()` | Connect |
| `Melay.disconnect_from_relay()` | Disconnect |

## Rooms

| Call | Returns |
|---|---|
| `await Melay.create_room(options)` | A `MelayRoom` |
| `await Melay.join_room(code, password)` | A `MelayRoom` |
| `await Melay.join_or_create(options)` | Joins any open room, or makes one |
| `await Melay.list_rooms(filter)` | An array of room summaries |
| `Melay.leave_room()` | Leaves, stays connected |

`create_room` options, all optional:

```gdscript
{
	"name": "Mark's game",
	"max_players": 4,
	"visibility": "public",        # or "private", code only
	"tags": {"mode": "ffa"},       # filter the room list on these
	"password": "",
}
```

`list_rooms` filters: `tags`, `only_joinable`, `limit`.

## Reading state

| Call | Returns |
|---|---|
| `Melay.is_in_room()` | `bool` |
| `Melay.is_host()` | `bool` |
| `Melay.get_room()` | `MelayRoom` |
| `Melay.get_rtt_us()` | Round-trip time in microseconds |
| `Melay.get_relay_time_us()` | Relay clock, the same for every player |

## Analytics

```gdscript
Melay.track("level_complete", {"level": "3"})
```

Rooms, sessions and playtime are recorded without you doing anything. Use `track` only for
your own events.

## Signals

| Signal | When |
|---|---|
| `connected` | Relay connection is up |
| `disconnected(reason)` | Connection lost |
| `room_joined(room)` | You are in a room |
| `room_left` | You left |
| `peer_joined(info)` | Somebody joined |
| `peer_left(info, reason)` | Somebody left |
| `error_received(code, message)` | Something failed |
| `peer_ready(peer)` | See the note below |

## MelayResult

```gdscript
result.is_error()   # bool
result.message      # what went wrong
result.value        # what you asked for
```

## MelayRoom

```gdscript
room.code           # the share code
room.self_peer_id   # your id
room.host_peer_id   # the host's id, always 1
room.peers          # peer_id -> MelayPeerInfo
room.is_host()
room.player_count()
```

## MelayPeerInfo

```gdscript
info.peer_id
info.display_name
info.platform
info.is_host
```

## Peer ids

The host is always peer `1`, so `multiplayer.is_server()` behaves the way you expect. Everyone
else gets `2` and up.

## If you assign the peer yourself

By default Melay sets `multiplayer.multiplayer_peer` for you. If you turn off
*Auto Assign Peer* in the project settings, do it in `peer_ready` and nowhere else:

```gdscript
Melay.peer_ready.connect(func(peer: MelayPeer) -> void:
	multiplayer.multiplayer_peer = peer
)
```

Doing it in `room_joined` is too late. Godot learns who else is in the room between those two
moments, so a peer set afterwards sees nobody and your RPCs go nowhere.
