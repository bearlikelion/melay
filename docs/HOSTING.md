# Hosting Melay

## Running it

```bash
cd server
docker compose up -d
```

That publishes `:8890` and keeps a named volume at `/data` for the analytics database and your
config file.

Without compose:

```bash
docker run -d --name melay \
  -p 8890:8890 \
  -v melay-data:/data \
  -v "$PWD/melay.yaml:/data/melay.yaml:ro" \
  melay:latest
```

The image is built `FROM scratch` and runs as uid 65532. It has no shell, so use
`docker logs` rather than `docker exec` for diagnostics. The container healthchecks itself with
`/melay --healthcheck`, which probes `/healthz` over loopback.

## Configuration

Everything is optional. `server/melay.yaml` documents the full set, and environment variables
override the file:

| Variable | Default | Meaning |
|------|------|------|
| `MELAY_ADDR` | `:8890` | Listen address |
| `MELAY_DATABASE_URL` | `file:/data/melay.db` | SQLite path, or `none` to disable analytics |
| `MELAY_LOG_LEVEL` | `info` | `debug`, `info`, `warn`, `error` |
| `MELAY_LOG_JSON` | `true` in the image | Structured logs |
| `MELAY_ALLOW_UNREGISTERED` | `true` | Accept game ids with no config entry |
| `MELAY_MAX_ROOMS` | `50` | Default per-game room cap |
| `MELAY_MAX_PLAYERS_PER_ROOM` | `8` | Default room size cap |
| `MELAY_MAX_PACKET_SIZE` | `262144` | Largest relayed packet, in bytes |

Only `file:` and `:memory:` database URLs are supported. Postgres is not implemented.

## TLS, and why browsers need it

A Godot desktop or mobile build is happy with `ws://`. A **browser build served over HTTPS can
only open `wss://`**, because a page loaded over TLS may not open a plaintext WebSocket. So if
you ship to web, the relay needs TLS.

Melay does not terminate TLS itself. Put it behind a reverse proxy, which is one less thing to
get wrong and gives you certificate renewal for free.

### Caddy

The shortest path, since it obtains and renews certificates automatically:

```caddy
relay.example.com {
	reverse_proxy localhost:8890
}
```

Then connect to `wss://relay.example.com`. The addon appends `/ws` itself.

### nginx

WebSocket upgrades need explicit headers, and the read timeout must exceed your idle gaps or
nginx will drop live connections:

```nginx
server {
	listen 443 ssl;
	server_name relay.example.com;

	ssl_certificate     /etc/letsencrypt/live/relay.example.com/fullchain.pem;
	ssl_certificate_key /etc/letsencrypt/live/relay.example.com/privkey.pem;

	location / {
		proxy_pass         http://127.0.0.1:8890;
		proxy_http_version 1.1;
		proxy_set_header   Upgrade $http_upgrade;
		proxy_set_header   Connection "upgrade";
		proxy_set_header   Host $host;
		proxy_set_header   X-Forwarded-For $proxy_add_x_forwarded_for;

		# Melay pings every 5 seconds, so this only matters if a proxy sits in front
		# of it too, but a long timeout costs nothing.
		proxy_read_timeout 3600s;
		proxy_send_timeout 3600s;
	}
}
```

### Protecting the dashboard

`/` and `/api/v1/*` are unauthenticated and expose per-game player counts. If the relay is
public, restrict them at the proxy and leave `/ws` open:

```caddy
relay.example.com {
	@admin path / /api/*
	basic_auth @admin {
		mark $2a$14$...
	}
	reverse_proxy localhost:8890
}
```

## Cross-origin

The relay accepts WebSocket upgrades from any origin. A browser game is served from whatever
domain you host it on, and the relay carries no cookie or ambient authority that same-origin
checks would protect. Access control is the per-game `api_key`, not the origin header.

## Sizing

Each connection costs one goroutine pair and a bounded outbound queue. A small VPS handles
thousands of concurrent connections; the practical limits are bandwidth and file descriptors.

Raise the descriptor limit if you expect more than a few thousand:

```yaml
services:
  melay:
	ulimits:
	  nofile:
		soft: 65536
		hard: 65536
```

Traffic is roughly `packet_size x tick_rate x players x (players - 1)` for a fully connected
broadcast game, since the relay fans out rather than multicasting. Eight players sending 200
bytes 20 times a second is about 2.2 MB/s out of the relay.

## Backpressure

Each peer has a bounded outbound queue. When it fills, the relay drops the oldest
`UNRELIABLE` packets first, then `UNRELIABLE_ORDERED`, and only closes the connection if
reliable traffic exceeds a hard limit. One slow player degrades to stale positions instead of
stalling everyone else.

If you see `connection dropped frames under backpressure` in the logs, that peer's link could
not keep up. It is a symptom of the client's bandwidth, not of the relay.

## Backups

Analytics live in one SQLite file at `/data/melay.db` (plus its WAL sidecars). Back up the
volume, or set `MELAY_DATABASE_URL=none` if you do not want the data at all. Losing the file
costs you history and nothing else; rooms are entirely in memory.

## Upgrading

Rooms are in-memory, so restarting the container ends every session in progress. Drain during
a quiet period, or run two instances behind a proxy and move traffic over. There is no
cross-instance room sharing: a room lives on the instance that created it, so a single relay
per game is the supported topology today.
