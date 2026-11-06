<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="./docs/assets/Louie%20Wordmark%20White.svg">
    <source media="(prefers-color-scheme: light)" srcset="./docs/assets/Louie%20Wordmark.svg">
    <img alt="Louie" src="./docs/assets/Louie%20Wordmark.svg" height="250">
  </picture>
</p>

Louie is an iOS companion app for the home. It currently supports managing one's Linn music system, with more features to come.

## Linn server

[Louie Home Server](server/README.md) runs on the Raspberry Pi and owns the
Linn connection. See its README for architecture, configuration, builds, tests,
model generation, deployment, and systemd operations.

### Swift client

The app connects to `louie-pi.local:50051` by default. Its address can be
changed in the connection screen or through `LOUIE_SERVER_URL` in the local
developer `.env`. Old direct-DSM connection settings are not reused. The Pi
owns the Linn connection and broadcasts full state snapshots to the app.

`PiLinnGateway` maps each gRPC snapshot directly into `Linn.Snapshot`, using
app-domain songs, playlists, timelines, and connection states. `Linn` replaces
its playback and queue state from that snapshot, including empty queues; it
does not merge earlier gateway events or infer queue metadata from the current
song. Playback predictions belong to the server. The client retains immediate
volume/mute feedback, the pending row marker, and stable row IDs for animations.

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
