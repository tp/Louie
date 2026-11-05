<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="./docs/assets/Louie%20Wordmark%20White.svg">
    <source media="(prefers-color-scheme: light)" srcset="./docs/assets/Louie%20Wordmark.svg">
    <img alt="Louie" src="./docs/assets/Louie%20Wordmark.svg" height="250">
  </picture>
</p>

Louie is an iOS companion app for the home. It currently supports managing one's Linn music system, with more features to come.

## Linn server

The Raspberry Pi server is in `server/`; its gRPC schema is in
`proto/louie/linn/v1/linn.proto`. Build and test it with:

```sh
cd server
cargo test --locked --all-targets
cargo build --release --locked
```

`server/rust-toolchain.toml` fixes the Rust version, and `server/Cargo.lock` fixes
crate versions. `build.rs` generates Rust code locally using the versioned
`protoc-bin-vendored` crate; no system `protoc` installation or Buf account is
needed. Cargo downloads dependencies from crates.io on a clean machine, but
the schema and code-generation inputs are not sent to a hosted generator.

The Linn CI Gateway WebSocket payload models live in the separate
`server/linn-ci-gateway` crate. They are generated from the normalized local
`server/linn-ci-gateway/openapi.yaml` by running
`bash server/linn-ci-gateway/generate.sh`. The script runs a pinned OpenAPI
Generator image locally and commits only the model output; CI checks that it
is current. The handwritten `websocket` module handles the live gateway's
string-or-array `artist` deviation. To update from a local gateway, run
`bash server/linn-ci-gateway/fetch-spec.sh`, then
`bash server/linn-ci-gateway/normalize.sh`, then regenerate the Rust models
with `bash server/linn-ci-gateway/generate.sh`. Until #25 removes the Swift
client, also run
`OPENAPI_USE_LOCAL_SPEC=1 bash Packages/LinnCiGateway/Scripts/generate-openapi-client.sh`.

If we add Buf for linting or Swift generation later, use only local schema
inputs and `local:` plugins. Do not add `remote:` plugins or BSR module inputs
to the generation configuration.

### Pi deployment

Run `bash server/deploy/deploy-pi.sh` from the repository root. It builds an
ARM64 Linux release binary in Docker with the pinned Rust version, copies it
over SSH, verifies its checksum, restarts `louie.service`, and checks the gRPC
state stream. The smoke check also works while Linn is offline. It keeps the
previous binary, check tool, and systemd unit for rollback if the check fails.

The Pi configuration is at `~/.config/louie/server.env`; the initial values are
in `server/deploy/server.env.example`. The user unit is
`server/deploy/louie.service`. User lingering is enabled on the Pi so the
service starts at boot. To inspect it on the Pi:

Set `SENTRY_DSN` in `server.env` to send server warnings, errors, and panics
to Sentry. The server runs normally without a DSN.

```sh
systemctl --user status louie.service
journalctl --user -u louie.service -f
```

### Swift client

The app connects to `louie-pi.local:50051` by default. Its address can be
changed in the connection screen or through `LOUIE_SERVER_URL` in the local
developer `.env`. Old direct-DSM connection settings are not reused. The Pi
owns the Linn connection and broadcasts full state snapshots to the app.

The Swift messages and gRPC client under `Packages/Linn/Sources/Linn/Generated`
are checked in. Regenerate them locally with
`bash Packages/Linn/generate-proto.sh` after changing the proto. This builds
the code generators from the versions pinned in `Packages/Linn/Package.swift`
and uses a local `protoc`; it does not use Buf Cloud or remote code generation.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="./docs/assets/iPad%20Home%20Dark.png">
  <source media="(prefers-color-scheme: light)" srcset="./docs/assets/iPad%20Home%20Light.png">
  <img alt="Louie's start screen on iPad" src="./docs/assets/iPad%20Home%20Light.png">
</picture>
