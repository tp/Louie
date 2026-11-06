# Louie Home Server

A Rust service for a Raspberry Pi 5 running 64-bit Raspberry Pi OS Lite.
It owns one connection to the Linn CI Gateway and exposes the configured room
through the `louie.linn.v1.Linn` gRPC service. Apple apps connect to this server
for music controls, library browsing, and shared playback state.

## Architecture

Apple apps → gRPC → `louie-server` → WebSocket → Linn CI Gateway

| Component | Responsibility |
| --- | --- |
| [`src/main.rs`](src/main.rs) | Configuration, logging, and gRPC listener |
| [`src/service.rs`](src/service.rs) | gRPC operations, validation, and library mapping |
| [`src/gateway.rs`](src/gateway.rs) | One Linn socket, subscriptions, reconnects, tagged replies, and command scheduling |
| [`src/optimism.rs`](src/optimism.rs) | Per-command, per-field predictions over observed Linn state |
| [`src/scheduler.rs`](src/scheduler.rs) | Playback ordering, compatible supersession, dependencies and deadlines |
| [`linn-ci-gateway`](linn-ci-gateway) | Generated payload models and handwritten WebSocket normalization |
| [`linn.proto`](../proto/louie/linn/v1/linn.proto) | Client/server API contract |

`GetState` returns a snapshot; `WatchState` sends the current snapshot immediately
and subsequent updates. The server publishes predicted values with per-field
`pending` flags so all clients see the same intent. Command acknowledgement is
separate from observed state confirmation. For row selection, a confirmed queue
index does not confirm the song: the preview waits for changed, nonempty metadata
or its timeout. Rejected commands release their own predictions.

### Command ordering and prediction

Playback has one dispatched command at a time. A gateway acknowledgement completes
its gRPC call, but the lane remains occupied until the relevant Linn events settle
its fields, the gateway rejects it, or the confirmation deadline expires. Evidence
may arrive before the acknowledgement. Playlist, metadata, transport and seek
updates confirm their own fields independently, in either arrival order.

The bounded waiting queue preserves additions and dependent actions. Only adjacent
compatible actions replace each other: row selections, seeks, play/pause, and album
replacements. Replaced calls receive `CANCELLED` with `louie-error-reason: superseded`.
Sequential skips accumulate against the projected row. Shuffle/unknown destinations
stay unknown until observed. A→B→A sends A once if A settles successfully.

Volume and mute have independent lanes and keep latest-value-wins dispatch after
acknowledgement. Library browsing is independent of playback; searches retain their
existing serial queue. Apple clients project server snapshots and retain immediate
local volume/mute feedback and row markers.

| Limit | Behaviour |
|---|---|
| Waiting queue | At most 8 actions per lane, each with a 15-second lifetime |
| Gateway acknowledgement | 5 seconds from dispatch |
| Playback confirmation | 3 seconds after acknowledgement; 6 seconds for media changes |
| Timeout read-back | Up to 3 seconds; missing replies cause reconnect |
| Swift RPC deadline | 25 seconds, allowing queue wait plus acknowledgement |

A playback timeout removes its prediction and reads back transport, metadata,
position and playlist before dispatching more playback commands. Read-back explicitly
renews status subscriptions with `update: 1`: live testing showed that omission stops
pushes, contrary to the vendor spec; `update: 0` cancels them as well. Row/seek targets
are checked against the current queue contents and limits at dispatch; Linn's
playlist revision also advances on selection updates, so revision alone is not a
queue identity. Failed, expired or invalidated commands cancel dependent row/seek
requests (`command-dependency`); unrelated additions and transport actions survive.
Standby and disconnect clear pending work; controls are not replayed on reconnect.

Track counts are hints. A changed queue with a mismatching count is displayed as
observed, while the unconfirmed operation remains bounded by its deadline. No title
history, fallback prediction stack, or restoration of expired commands is retained.

Linn events have no causal command ID. Serialization and read-back reduce ambiguity
but cannot prevent an old timed-out command or another controller from changing the
device later. `pending` identifies predicted fields; settled fields follow observed
state. This is bounded correction, not a guarantee of causal confirmation.

Gateway connectivity and speaker power are separate: `now_playing.is_standby`
comes from `/V2/product/status`, is read before the first connected snapshot,
and stays updated through a subscription. A room in standby keeps its observed
metadata, but playback and volume commands fail with `linn-standby` in the
`louie-error-reason` metadata. Clients show an off state and disable those controls.
`Wake` sends `/V2/product/set_standby` with `standby: false` and waits up to
30 seconds for observed standby-off, rather than treating its acknowledgement as
completion. It does not start playback. Already-awake calls are no-ops;
unreachable rooms fail immediately, and a disconnect while waking fails the
request. The Apple client allows 35 seconds and shows progress only on the Home
playing card. The real Linn took about 13 seconds to report awake during testing.

Browsing remains available in standby. If either Linn or Louie Home Server is
unreachable, clients cancel library loading, hide cached library pages, and
block browsing/search/favourites until reconnection reloads the library.
Topology updates also detect a room disappearing while the gateway remains up.

For a deliberate wake test, run `check_linn http://louie-pi.local:50051 --wake`.
This changes the room's power state and leaves it awake; it does not play music.
The normal deploy smoke check does not send this command.

## Build and test

Run from this directory with Rust installed through rustup:

```sh
cargo fmt --all -- --check
cargo clippy --workspace --locked --all-targets -- -D warnings
cargo test --workspace --locked --all-targets
cargo build --release --locked
```

[`rust-toolchain.toml`](rust-toolchain.toml) pins Rust 1.99.1, and
[`Cargo.lock`](Cargo.lock) pins dependencies. Both `louie-server` and
`linn-ci-gateway` are workspace members; CI runs tests and Clippy for both,
checks generated models, and builds the release binary. Tests use local mock
WebSocket servers and do not require a Linn device.

[`build.rs`](build.rs) generates the Rust gRPC code locally using a pinned,
vendored `protoc`. A native build needs neither Docker nor a system `protoc`.

## Configuration and local run

The process reads environment variables; it does not load `.env` files itself.
The systemd unit loads `~/.config/louie/server.env` on the Pi.

| Variable | Default | Purpose |
| --- | --- | --- |
| `LINN_CI_GATEWAY_WS_URL` | Required | Linn WebSocket endpoint, such as `ws://linn-host.local:8088/ws` |
| `LINN_ROOM` | `Linn` | Room name reported by the gateway |
| `LINN_MAX_VOLUME` | `70` | Volume ceiling; startup rejects values outside 0–70 |
| `LOUIE_GRPC_BIND` | `127.0.0.1:50051` | Listener address; use the Pi's reserved LAN IPv4 address for Apple clients |
| `RUST_LOG` | `louie_server=info` | Log filter |
| `SENTRY_DSN` | Unset | Optional warning, error, and panic reporting |

For development, replace the Linn hostname below with your gateway:

```sh
LINN_CI_GATEWAY_WS_URL=ws://linn-host.local:8088/ws cargo run --locked
```

The deployed Apple client endpoint is `http://louie-pi.local:50051`; the reserved
IPv4 address also works. The service currently uses plaintext gRPC without
authentication on the home LAN. Internet exposure requires authentication and TLS.

## Deploy to the Pi

The checked-in [`deploy/deploy-pi.sh`](deploy/deploy-pi.sh) targets
`louie@192.168.4.58`, using `louie-pi.local` as its SSH host-key alias. It assumes
SSH key access, Docker on the development Mac, and a configured Pi. Its build
cache is `/private/tmp/louie-pi-build`; adjust the script for another deployment.

For the first installation, create `~/.config/louie/server.env` on the Pi using
[`deploy/server.env.example`](deploy/server.env.example), with the actual Linn
endpoint, room, and reserved Pi address. Enable the user service to run without
an interactive login by running this once on the Pi:

```sh
sudo loginctl enable-linger louie
```

From the repository root on the Mac:

```sh
bash server/deploy/deploy-pi.sh
```

The script builds ARM64 Linux binaries in Docker using the pinned Rust version,
copies them and the user unit over SSH, verifies the server binary checksum,
backs up the installed files, and restarts `louie.service`. Its gRPC smoke check
requires a Linn reconnection if the previous server was connected. An already
offline Linn does not by itself fail deployment. On smoke-check failure, it
restores the previous binaries and unit when available.

Systemd restarts the process after a crash. Replacing a binary alone does not
reload the running process; the deploy script explicitly restarts it.

On the Pi:

```sh
systemctl --user status louie.service
journalctl --user -u louie.service -f
# After editing server.env:
systemctl --user restart louie.service
```

## Check the live server

From this directory on the Mac:

```sh
cargo run --locked --example check_linn -- http://louie-pi.local:50051
```

This checks `GetState`, the volume ceiling when available, and the initial
`WatchState` snapshot. Optional flags:

- `--require-connected`: fail if Linn is disconnected.
- `--probe-ack`: also request the media-service list and wait for its reply.
- `--probe-volume`: change the room volume by one step within the ceiling,
  verify observed state, then attempt to restore and verify the original volume.
  This flag controls the real speaker.

The deploy script also installs this tool as `~/.local/bin/check_linn` on the Pi.

## Generated code

The OpenAPI spec is local to [`linn-ci-gateway`](linn-ci-gateway).
`openapi.original.yaml` is the source copy; `normalize.sh` selects the wrapped
endpoints and related schemas and corrects known gateway/spec mismatches.
`generate.sh` uses a digest-pinned Docker image to generate models and their
module index, without HTTP client implementations, model docs, or generated tests.
There is no JAR fallback or cloud generation.

From the repository root, with Docker and Mike Farah's `yq` v4 installed:

```sh
bash server/linn-ci-gateway/normalize.sh
bash server/linn-ci-gateway/generate.sh
git diff -- server/linn-ci-gateway
```

To deliberately refresh the source spec first, run
`OPENAPI_SPEC_URL=http://your-gateway/api/swagger.yaml bash server/linn-ci-gateway/fetch-spec.sh`.
Routine generation does not fetch a spec. Correct the normalization script and
regenerate rather than editing generated models. The handwritten WebSocket module
handles narrow live-payload normalization, such as string-or-array artists.

Generated model files remain tracked and checked by CI; `.gitattributes` marks
them as generated for GitHub review. After changing the gRPC proto, rebuild Rust
and run `bash Packages/Linn/generate-proto.sh` from the repository root for Swift.
That script needs a local `protoc` and builds the pinned Swift plugins locally.

## Current scope

One configured Linn room; no users, roles, service discovery, or other home devices.
Now Playing token-registration RPCs currently return `UNIMPLEMENTED`; APNs delivery
and the Apple Now Playing integration are follow-up work. The music server does
not require the Hey Louie/Modal voice backend.

The deployed path is tested with IPv4. The server still accepts general socket
addresses; IPv4-only validation is not yet enforced. The command scheduler implements
[#27](https://github.com/tp/Louie/issues/27); its scripted and WebSocket integration
tests cover common flows and overlapping intentions. Live Linn latency and rare
late-command behaviour still require hardware validation before deployment.
