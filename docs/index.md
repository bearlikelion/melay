---
title: Melay
layout: home
nav_order: 1
permalink: /
---

# Melay

Multiplayer for Godot 4 that works in the browser.
{: .fs-6 .fw-300 }

[Get started]({{ site.baseurl }}/quickstart){: .btn .btn-primary .mr-2 }
[Host a relay]({{ site.baseurl }}/hosting){: .btn }

---

Melay is two things:

- **An addon** that gives you a Godot `MultiplayerPeer`. Your `@rpc` functions work unchanged.
- **A relay** you run in Docker, which passes packets between players.

It is pure GDScript, so it runs on Web, Mobile, PC and Steam with no build step.

```gdscript
Melay.configure("wss://your-relay", "my-game", "1.0.0")
await Melay.connect_to_relay()

var result: MelayResult = await Melay.create_room({"max_players": 4})
print("Share this code: ", result.value.code)
```

Another player calls `Melay.join_room(code)` and you are connected.

## What you get

- Rooms with short share codes, and a public room list
- Analytics per game, with nothing to add to your code
- One relay serves every game you ship, kept apart by game name

## What it is not

Melay passes packets. It does not run your game, and it does not check what players send.
One player is the host and everyone trusts them.

Ready? [Start here]({{ site.baseurl }}/quickstart).
