<div align="center">

<img src="addons/melay/icons/melay.svg" width="96" alt="Melay">

# Melay

**Multiplayer for Godot 4 that works in the browser.**

[Documentation](https://bearlikelion.github.io/melay/) ·
[Quick start](https://bearlikelion.github.io/melay/quickstart) ·
[Hosting](https://bearlikelion.github.io/melay/hosting) ·
[Reference](https://bearlikelion.github.io/melay/reference)

<img src="docs/assets/melay.png" alt="The demo lobby, and the relay's analytics dashboard">

</div>

---

Melay is two pieces:

- **An addon** that gives you a Godot `MultiplayerPeer`. Your `@rpc` functions work unchanged.
- **A relay** you run in Docker, which passes packets between players.

It is pure GDScript, so it runs on Web, Mobile, PC and Steam with no build step, no
per-platform binaries, and nothing to compile.

```gdscript
Melay.configure("wss://your-relay", "my-game", "1.0.0")
await Melay.connect_to_relay()

var result: MelayResult = await Melay.create_room({"max_players": 4})
print("Share this code: ", result.value.code)
```

Another player calls `Melay.join_room(code)`, and from that moment
`multiplayer.multiplayer_peer` is set on both sides. Nothing else about your game changes.

## Why

Shipping Godot multiplayer to a browser usually means running a dedicated server per game,
adopting a large backend, or depending on a service you do not control. Melay is the small
piece in the middle: one relay serves every game you ship, kept apart by game name.

## What you get

- **Rooms** with six-character share codes, plus a filterable public room list
- **Analytics** per game, with nothing to add to your code
- **A shared clock**, so every player can agree on when something happens
- **Version safety**, so an old build cannot join a new one and desync it
- **Backpressure handling**, so one slow player degrades instead of stalling the room

## Install

Grab `melay-addon-vX.Y.Z.zip` from [Releases](../../releases), extract it into your project so
the files land in `addons/melay/`, then enable **Melay** in
*Project > Project Settings > Plugins*.

Run a relay:

```bash
docker run -d -p 8890:8890 -v melay-data:/data ghcr.io/bearlikelion/melay:latest
```

Or put one online with an HTTPS address, which is what browser games need:

```bash
scripts/deploy-cloudrun.sh
```

## Try it

`demo/` is a complete Godot project: a menu, a lobby with ready-up, and a small paddle arena.

```bash
cd server && docker compose up -d      # start a relay
```

Then open `demo/` in Godot and press F5. For two players use
*Debug > Customize Run Instances > 2 instances*.

<div align="center">
<img src="docs/assets/countdown.png" width="620" alt="The demo's synchronised countdown">
</div>

## What it is not

Melay passes packets. It does not run your game and it does not check what players send. One
player is the host, and everyone trusts them. That is the right trade for co-op and casual
play, and the wrong one for competitive games where cheating matters.

## Layout

```
addons/melay/        the addon, the only thing you copy into a game
demo/                a complete Godot project
server/              the Go relay and its Dockerfile
docs/                the documentation site
scripts/             deploys, release packaging, local servers
server/PROTOCOL.md   the wire protocol, if you want your own client or server
CONTRIBUTING.md      layout, testing and releasing
```

## Requirements

| | |
|---|---|
| Godot | 4.7, which is what it is developed and tested against |
| Relay | Docker, or a single static binary, about 16MB |
| Browser games | A relay reachable over HTTPS |

The demo project is saved in Godot 4.7 scene format and will not open in an older editor. The
addon itself is plain GDScript with no exotic APIs, so earlier 4.x releases will probably work,
but that is untested.

## Testing

```bash
cd server && go test -race ./...   # protocol, relay behaviour, integration
cd demo && tests/run_tests.sh      # arena physics, then headless Godot clients
```

## Status

Working: the relay, rooms and lobbies, analytics, the shared clock, and the `MultiplayerPeer`.
Verified with headless Godot clients, from a real browser, and against a live deployment.

Not built yet: automatic reconnection, host migration, rollback helpers, and transports other
than WebSocket. The protocol reserves space for host migration, so adding it will not be a
breaking change.

## Licence

MIT. See [LICENSE](LICENSE).
