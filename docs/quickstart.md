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

Copy `addons/melay/` into your project, then turn on **Melay** in
*Project > Project Settings > Plugins*.

## 3. Set your game name

In *Project Settings > Melay*, set:

- **Mode** to `Local`
- **Game Id** to anything, for example `my-game`

## 4. Host a room

```gdscript
func host() -> void:
	await Melay.connect_to_relay()
	var result: MelayResult = await Melay.create_room({"max_players": 4})
	print("Room code: ", result.value.code)
```

## 5. Join it

```gdscript
func join(code: String) -> void:
	await Melay.connect_to_relay()
	await Melay.join_room(code)
```

That is it. `multiplayer.multiplayer_peer` is now set on both sides, so your `@rpc`
functions work as normal.

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
