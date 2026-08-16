---
title: Hosting
nav_order: 3
---

# Hosting a relay

## On your machine

```bash
cd server
docker compose up -d
```

Players on the same network connect to `ws://your-ip:8890`.

## Online, with Google Cloud Run

Cloud Run gives you an HTTPS address for free, which is what browser games need.

```bash
MELAY_GCP_PROJECT=my-project scripts/deploy-cloudrun.sh
```

It prints your relay address when it finishes. Set that as **Url** in
*Project Settings > Melay*, and set **Mode** to `Remote`.

`MELAY_GCP_REGION` defaults to `us-east1` if you want somewhere else.

## Anywhere else

The relay is one small Docker image:

```bash
docker run -d -p 8890:8890 -v melay-data:/data ghcr.io/bearlikelion/melay:latest
```

Put it behind Caddy or nginx if you want HTTPS on your own domain.

## Browser games need wss://

A game running in a browser on an HTTPS page can only connect to a `wss://` address, never
`ws://`. If you plan to ship to the web, your relay needs HTTPS. Cloud Run handles this for
you. A plain IP address cannot.

## Settings

Set these as environment variables. All are optional.

| Variable | Default | What it does |
|---|---|---|
| `MELAY_ADDR` | `:8890` | Port to listen on |
| `MELAY_DATABASE_URL` | `file:/data/melay.db` | Where analytics go, or `none` to turn them off |
| `MELAY_MAX_ROOMS` | `50` | Room limit per game |
| `MELAY_MAX_PLAYERS_PER_ROOM` | `8` | Players per room |
| `MELAY_WEB_DIR` | unset | Folder holding a web export, served at `/play` |

## Many games, one relay

Games are kept apart by their game name, so you can point everything you make at the same
relay. To set limits or require a password per game, create `melay.yaml`:

```yaml
games:
  spacewar:
    max_players_per_room: 16
    api_key: "${SPACEWAR_KEY}"
```

Games with an `api_key` must send it. Everything else connects freely.

## Checking it works

```bash
curl https://your-relay/api/v1/health
```

The dashboard at `/` shows players, rooms and playtime for every game.
