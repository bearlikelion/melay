---
title: Quick start
nav_order: 2
---

# Quick start

Get two players talking in about five minutes.

## 1. Start a relay

```bash
cd server
docker compose up -d
```

It runs on `http://localhost:8890`. Open that address to see the dashboard.

## 2. Add the addon

Copy the `addons/melay/` folder into your project, so you end up with:

```
your-project/
  addons/
    melay/
      plugin.cfg
      melay.gd
      ...
  project.godot
```

Then open *Project > Project Settings > Plugins* and tick **Melay**.

## 3. Check the autoload

Ticking that box adds an autoload for you. You do not have to create it yourself.

Look in *Project > Project Settings* under the autoload list and you should see:

| Name | Path |
|---|---|
| `Melay` | `res://addons/melay/melay.tscn` |

That single autoload is the whole API. Every call in this guide goes through it.

If it is not there, add it by hand with exactly that name and path. The name matters, because
your code calls `Melay.something()`. Note the path is a **scene**, not a script.

## 4. Point it at a relay

Do this once, early, in any script that runs at startup:

```gdscript
func _ready() -> void:
	Melay.configure("ws://127.0.0.1:8890", "my-game", "1.0.0")
```

| Argument | Meaning |
|---|---|
| `ws://127.0.0.1:8890` | Where your relay is |
| `my-game` | Your game's name. Keeps your rooms separate from other games on the same relay. |
| `1.0.0` | Your game's version. Stops old builds joining new ones. |

You can also set these in *Project Settings > Melay* instead of calling `configure()`. Turn on
**Advanced Settings** to see the section.

### Keeping your relay address out of git

Project settings live in `project.godot`, which you commit. If you would rather your own relay
address did not end up in a public repository, put it in `melay_local.cfg` next to
`project.godot`:

```ini
[connection]

url="wss://your-relay.example.com"
```

Add that filename to `.gitignore`. Melay reads it if it is there, and it is bundled into
exports, so your builds still connect while the repository stays clean. Copy
`melay_local.cfg.example` to get started.

Values are applied in this order, each overriding the one before:

1. Project settings
2. `melay_local.cfg`
3. A `configure()` call in code

## 5. Host a room

```gdscript
func host() -> void:
	await Melay.connect_to_relay()
	var result: MelayResult = await Melay.create_room({"max_players": 4})
	print("Room code: ", result.value.code)
```

## 6. Join it

```gdscript
func join(code: String) -> void:
	await Melay.connect_to_relay()
	await Melay.join_room(code)
```

That is it. `multiplayer.multiplayer_peer` is now set on both sides, so your `@rpc`
functions work as normal.

## How it hooks into Godot

Melay replaces the transport. Everything above it is stock Godot.

```
your game          @rpc, MultiplayerSpawner, MultiplayerSynchronizer
      |
SceneMultiplayer   Godot's own multiplayer, unchanged
      |
MelayPeer          <- Melay swaps this in
      |
WebSocket  ->  relay  ->  other players
```

It is the same shape as any other peer. Compare:

```gdscript
# Normally you build a peer and assign it:
var peer: ENetMultiplayerPeer = ENetMultiplayerPeer.new()
peer.create_server(7777)
multiplayer.multiplayer_peer = peer

# With Melay, joining a room does that step for you:
await Melay.connect_to_relay()
await Melay.create_room()
```

The order matters:

| When | What happens |
|---|---|
| `connect_to_relay()` | Opens the socket. `multiplayer.multiplayer_peer` is still untouched. |
| `create_room()` or `join_room()` | The relay hands you a peer id, Melay builds a `MelayPeer`, and **assigns it**. |
| `leave_room()` or losing the connection | Melay puts back an `OfflineMultiplayerPeer`, so `get_unique_id()` returns `1` again. |

So the peer is set when you enter a room, not when you connect. The host gets peer id `1`, so
`multiplayer.is_server()` behaves the way you expect.

Want to assign it yourself? See
[the note in the reference]({{ site.baseurl }}/reference#if-you-assign-the-peer-yourself).

## Checking for errors

Every `await` returns a `MelayResult`. Check it before using the value.

```gdscript
var result: MelayResult = await Melay.create_room()
if result.is_error():
	print(result.message)
	return
```

## A real lobby, end to end

Steps 5 and 6 get you connected. A real game needs a lobby: players gather, mark themselves
ready, and the host starts the match. Here is the whole pattern, which is what `demo/` does.

Put it all on **one node that exists on every peer**, such as your main scene. RPCs are matched
by node path, so both sides must agree on where the function lives.

### Listen for the room

```gdscript
func _ready() -> void:
	Melay.room_joined.connect(_on_room_joined)
	Melay.peer_joined.connect(_on_peer_joined)
	Melay.peer_left.connect(_on_peer_left)
	Melay.room_left.connect(_on_room_left)


func _on_room_joined(room: MelayRoom) -> void:
	# You are in. Swap the menu for the lobby.
	_ready_states.clear()
	_ready_states[room.self_peer_id] = false
	_show_lobby()
```

`room_joined` fires for the host and for everyone joining, so one handler covers both.

### Ready up

Every player owns their own ready flag, so this is `any_peer`. `call_local` means the sender
runs it too, and everyone ends up with the same dictionary.

```gdscript
var _ready_states: Dictionary = {}


func _on_ready_button_pressed() -> void:
	_is_ready = not _is_ready
	_set_ready.rpc(_is_ready)


@rpc("any_peer", "reliable", "call_local")
func _set_ready(is_ready: bool) -> void:
	# A local call reports sender 0, so fall back to our own id.
	var sender: int = multiplayer.get_remote_sender_id()
	if sender == 0:
		sender = multiplayer.get_unique_id()
	_ready_states[sender] = is_ready
	_refresh_lobby()
```

### Catch new arrivals up

Somebody joining late has an empty dictionary, so the host sends them the current one.

```gdscript
func _on_peer_joined(info: MelayPeerInfo) -> void:
	_ready_states[info.peer_id] = false
	if Melay.is_host():
		_sync_ready_states.rpc_id(info.peer_id, _ready_states)
	_refresh_lobby()


@rpc("authority", "reliable", "call_remote")
func _sync_ready_states(states: Dictionary) -> void:
	for peer_id: Variant in states:
		_ready_states[int(peer_id)] = bool(states[peer_id])
	_refresh_lobby()
```

`authority` means only the host may send it, which Godot enforces for you.

### Start the match

Only the host, and only once everybody is ready:

```gdscript
func _on_start_button_pressed() -> void:
	if not Melay.is_host() or not _all_ready():
		return
	_start_game.rpc()


@rpc("authority", "reliable", "call_local")
func _start_game() -> void:
	_show_game()


func _all_ready() -> bool:
	var room: MelayRoom = Melay.get_room()
	if room == null or room.peers.is_empty():
		return false
	for peer_id: int in room.peers:
		if not bool(_ready_states.get(peer_id, false)):
			return false
	return true
```

`call_local` matters here: without it the host would tell everyone else to start and stay in
the lobby itself.

### Which RPC mode to use

| Mode | Use it for |
|---|---|
| `any_peer` | Anything a player asserts about themselves, like readiness or input |
| `authority` | Anything only the host may decide, like starting the match |
| `call_local` | When the sender must run it too |
| `call_remote` | When the sender has already done the work locally |

### A countdown everyone shares

The demo goes one step further. Instead of starting immediately it sends the relay time the
match should begin at, so every player counts down to the same instant no matter their ping:

```gdscript
_start_game.rpc(Melay.get_relay_time_us() + 3_000_000)


@rpc("authority", "reliable", "call_local")
func _start_game(start_at_relay_us: int) -> void:
	var remaining: float = float(start_at_relay_us - Melay.get_relay_time_us()) / 1_000_000.0
	_begin_countdown(clampf(remaining, 0.0, 3.0))
```

## Try the demo

Open the `demo/` folder as a Godot project and press F5. For two players, use
*Debug > Customize Run Instances > 2 instances*.

Arrow keys or W and S slide your paddle up and down. The arena is a Jolt physics world seen
straight on: the serve is slow, and every hit winds the rally up a little faster.

## Next

- [Put a relay online]({{ site.baseurl }}/hosting) so other people can join
- [Ship it to the browser]({{ site.baseurl }}/web)
- [Look up a function]({{ site.baseurl }}/reference)
