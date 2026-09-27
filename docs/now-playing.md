# System Now Playing

`LinnNowPlaying` is a separate product of the Linn package. It observes Linn's song, play state, timeline, queue availability and volume through `Observations`, and publishes timestamped snapshots. Metadata/command code is shared across platforms; core Linn does not depend on NowPlaying.

- **iOS 27:** `RemoteMediaSession<LinnSessionAttributes>` publishes the external Linn room. The embedded ExtensionKit extension implements `RemoteMediaSessionRepresentable` and sends acknowledged gateway commands even when the app is backgrounded. The app requests system-primary status while foregrounded. The extension subscribes to gateway updates while running.
- **macOS 27:** `MediaSession<LinnMediaSession>` publishes app-level media controls and metadata while Louie is running. Commands control the Linn, with no local audio playback. Apple's remote-session and device APIs are unavailable on macOS, so the Mac uses the general session API and has no remote speaker volume slider.

Play/pause, toggle, previous/next and seek are supported. Seek is enabled only with a known, positive seek range. Positions are finite, clamped to the range and sent as whole seconds to `/V2/seek/set_position`. Shuffle/repeat are not advertised. The iOS speaker slider respects Linn's configured maximum volume.

Paused sessions remain available. Stopping playback, losing the app's gateway connection, or closing its window removes the publication. No background audio mode or local audio session is activated.

## Background limits

The iOS extension is not a permanently running service. It keeps state current while scheduled, but guaranteed updates after both processes are suspended (or playback starting without opening Louie) require a server implementing Apple's NowPlaying APNs start/update/end notifications. The local CI Gateway has no such integration. This change does not register push tokens or add a backend.

## Device verification

Package tests cover seek payload encoding, sparse seek-status merging, seek validation/forwarding, snapshot round trips and timestamps, observed live updates, command availability and gateway failures. Both app platforms must build; the iOS build also embeds and validates the extension.

On a signed iOS 27 device connected to the Linn network:

1. Open Louie during playback; inspect track, artwork, elapsed time and room in Lock Screen/Control Center.
2. Background Louie and exercise pause/play, previous/next, scrub and volume. Confirm acknowledgement, updated metadata and the volume limit on the real Linn.
3. Switch to radio: the scrubber should disappear. Pause should retain controls; stop should remove the active publication when an update can be delivered.
4. Return from the background and change the song from another controller; check refresh. Test prolonged suspension separately against the limitation above.

On macOS 27, open Louie and check Control Center metadata and media keys, including seek on supported tracks. Confirm another media app can take primary status and closing Louie releases its session. Automatic system-primary selection remains controlled by macOS.

Apple references: [remote sessions](https://developer.apple.com/documentation/nowplaying/publishing-remote-media-sessions), [general sessions](https://developer.apple.com/documentation/nowplaying/publishing-media-sessions).
