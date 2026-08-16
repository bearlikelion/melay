---
title: Browser and itch.io
nav_order: 4
---

# Browser and itch.io

Melay is built for this. It is pure GDScript, so a web export needs no special setup.

## Before you start

Your relay must be on HTTPS. A browser game cannot connect to a plain `ws://` address.
[Deploy to Cloud Run]({{ site.baseurl }}/hosting#online-with-google-cloud-run) if you have not
already, then set **Url** in *Project Settings > Melay* to the `wss://` address it gives you,
and **Mode** to `Remote`.

## Export

```bash
cd demo
godot --headless --export-release "Web" build/web/index.html
```

Do not open the result by double-clicking it. Serve it instead:

```bash
scripts/serve-web.py
```

Then open `http://localhost:8000`.

## Upload to itch.io

1. Make a new project and set **Kind of project** to *HTML*.
2. Zip the contents of `build/web`, with `index.html` at the top of the zip.
3. Upload it and tick **This file will be played in the browser**.
4. Set the viewport size to match your game.

## Or host it on the relay

The relay can serve your game itself, at `/play`:

```bash
cd demo && godot --headless --export-release "Web" build/web/index.html
cd .. && scripts/deploy-cloudrun.sh --with-web
```

This is the easiest way to test, because the game and the relay end up on the same address.

## If the game will not load

**A SharedArrayBuffer error.** Your export has *Thread Support* turned on, which needs special
headers. Either turn *Thread Support* off in the export settings, or serve the game with
`scripts/serve-web.py`, which sends them for you. Melay itself never needs threads.

**Nothing happens at all.** You opened the file directly instead of serving it. Use
`scripts/serve-web.py`.

**It loads but cannot connect.** Your relay address is `ws://` and needs to be `wss://`.
