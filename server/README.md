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
| [`src/optimism.rs`](src/optimism.rs) | Pending predictions over observed Linn state |
| [`linn-ci-gateway`](linn-ci-gateway) | Generated payload models and handwritten WebSocket normalization |
| [`linn.proto`](../proto/louie/linn/v1/linn.proto) | Client/server API contract |

`GetState` returns a snapshot; `WatchState` sends the current snapshot immediately
and subsequent updates. The server publishes predicted values with per-field
`pending` flags so all clients see the same intent. Command acknowledgement is
separate from observed state confirmation. For row selection, a confirmed queue
index does not confirm the song: the preview waits for changed, nonempty metadata
or its timeout. Rejected commands release their own predictions.

The server serializes searches and coalesces pending volume, mute, and row-selection
commands. It reconnects to Linn automatically and preserves observed state while
reporting a disconnected status. Shared playback prediction belongs here; Apple
clients retain immediate feedback for local volume/mute controls and row taps.

Gateway connectivity and speaker power are separate: `now_playing.is_standby`
comes from `/V2/product/status`, is read before the first connected snapshot,
and stays updated through a subscription. A room in standby keeps its observed
metadata, but playback and volume commands fail with `linn-standby` in the
`louie-error-reason` metadata. Clients show an off state and disable those controls.
Topology updates also detect a room disappearing while the gateway remains up.

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
addresses; IPv4-only validation is not yet enforced. Prediction handling for rare
overlapping commands remains a simplification follow-up in
[#27](https://github.com/tp/Louie/issues/27). Linn status frames carry no command ID,
so pending predictions use observations and bounded timeouts rather than assuming
an acknowledgement proves playback has changed.
