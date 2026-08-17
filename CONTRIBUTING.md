# Development


## Layout

```
melay/
  addons/melay/        the addon, and the only thing a game copies
  demo/                a complete Godot project
    addons/melay       symlink to ../../addons/melay
    game/              the demo itself, screens under game/screens
    tests/             headless checks
  server/              the Go relay and its Dockerfile
  docs/                this site
  scripts/package.sh   builds the release artifacts
```

The addon lives at the repo root because that is the shape the Godot Asset Library expects: an
archive whose top level is `addons/`. The demo reaches it through a symlink, so there is one
copy to edit and no chance of the two drifting.

### If symlinks are a problem

Git creates symlinks on Linux and macOS without ceremony. On Windows it needs
`git config core.symlinks true` and Developer Mode enabled. If that is not workable, delete the
link and copy instead:

```bash
rm demo/addons/melay
cp -R addons/melay demo/addons/melay
```

Remember to copy back before committing, or your addon changes stay in the demo only.

## Pointing the demo at your own relay

`demo/project.godot` deliberately contains no relay address, so nobody's personal deployment
ends up in the repository. Create `demo/melay_local.cfg` instead:

```ini
[connection]

url="wss://your-relay.example.com"
```

That file is git ignored and bundled into exports, so builds connect while the repository
stays clean. Copy `demo/melay_local.cfg.example` to get started. Without it the demo falls
back to `ws://127.0.0.1:8890`, which is what `docker compose up` gives you.

## Testing

```bash
cd server && go test -race ./...   # protocol, relay semantics, drop policy, integration
cd demo && tests/run_tests.sh      # arena physics, then two pairs of headless Godot clients
```

`tests/run_tests.sh` builds and starts its own relay. Point it at one you already run with:

```bash
MELAY_URL=wss://your-relay tests/run_tests.sh
```

It runs three stages:

| Stage | What it covers |
|---|---|
| `arena physics` | The Jolt arena stepped for real: ball bounces off walls and paddles, the speed-up per hit and its cap, square returns, countdown gating, spawn placement. No relay needed. |
| `peer` | Two headless Godot clients sharing a room and exchanging `@rpc` calls in both directions. |
| `demo` | The demo driven through menu, lobby, ready-up, countdown, start and arena. |

The Go suite includes an integration test that speaks the protocol over a real WebSocket with a
client written independently of the GDScript one, so both halves are checked against the spec
rather than against each other.

## Previewing this site

GitHub Pages builds `docs/` with Jekyll. To see changes before pushing:

```bash
scripts/serve-docs.sh          # http://localhost:4000
scripts/serve-docs.sh 4001     # a different port
```

It runs Jekyll in a container, so no Ruby is needed locally, and caches gems in a named
volume so only the first run is slow. It serves with an empty `baseurl` so links resolve at
the root; in production the site lives under `/melay`, which `docs/_config.yml` sets.

## Screenshots

`demo/tests/shot.gd` walks the demo through every screen and writes PNGs, which is handy for
checking layout without clicking:

```bash
cd demo
godot --path . res://tests/shot.tscn -- --out=/tmp/shots
```

With no `--url` it uses the project settings, which is also a quick way to confirm the settings
point where you think they do.

## Releasing

Tag the commit and push it. The `Release` workflow builds everything and publishes it:

```bash
git tag v0.2.0
git push origin v0.2.0
```

Each release carries:

- `melay-addon-vX.Y.Z.zip`, extracting to `addons/melay/`, with the version stamped into
  `plugin.cfg` at package time
- relay binaries for linux, macOS and Windows on amd64 and arm64
- `SHA256SUMS`
- a multi-arch container image at `ghcr.io/<owner>/melay:vX.Y.Z` and `:latest`

The git tag is the single source of truth for the version, so `plugin.cfg` in the working tree
does not need bumping by hand.

To check the artifacts before tagging:

```bash
scripts/package.sh v0.2.0
ls dist/
```

## Continuous integration

The `CI` workflow runs on every push and pull request: gofmt, `go vet`, `go test -race`, a
Docker build, then a Godot job that imports the project, fails on any script error, and runs the
full end to end suite against a relay it builds itself.

The Godot job pins `GODOT_VERSION` at the top of `.github/workflows/ci.yml`. The demo project is
saved in Godot 4.7 scene format, so an older editor cannot open it; bump that value when you
move the project to a newer engine.

## House style

The addon and demo follow a strict GDScript style: explicit static types everywhere and never
`:=`, tabs, two blank lines between functions, enums instead of bare ints, `class_name` on every
reusable type, and comments kept to single lines that state only what the code cannot.

Signals go up and calls go down. The demo's screens never touch `Melay` directly; they report
intent upward and the main scene acts on it. That is also why every RPC lives on the main scene,
which is the only node with a path identical on every peer.
