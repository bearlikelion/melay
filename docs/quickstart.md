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
| `leave_room()` or losing the connection | Melay sets it back to `null`. |

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

## Try the demo

Open the `demo/` folder as a Godot project and press F5. For two players, use
*Debug > Customize Run Instances > 2 instances*.

Arrow keys move your paddle. A and D rotate it.

## Next

- [Put a relay online]({{ site.baseurl }}/hosting) so other people can join
- [Ship it to the browser]({{ site.baseurl }}/web)
- [Look up a function]({{ site.baseurl }}/reference)
