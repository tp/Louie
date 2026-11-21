# System Now Playing

`LinnNowPlaying` is a separate product of the Linn package. It observes Linn's song, play state, timeline, queue availability and volume through `Observations`, and publishes timestamped snapshots. Core Linn does not depend on NowPlaying.

- **iOS 27:** `RemoteMediaSession<LinnSessionAttributes>` publishes the Linn room. The embedded ExtensionKit extension implements `RemoteMediaSessionRepresentable`. It connects to the configured **Louie Home Server**, subscribes to gRPC `WatchState` while running, and sends acknowledged gRPC commands. The app requests system-primary status while foregrounded.
- **macOS 27:** `MediaSession<LinnMediaSession>` publishes app-level media controls and metadata while Louie is running. Commands go to the home server. Apple's remote-session and device APIs are unavailable on macOS, so the Mac uses the general session API and has no remote speaker volume slider.

The server remains the only connection to the Linn gateway and owns playback predictions. App and extension consume complete server projections, including cleared metadata and timeline fields. Neither merges partial gateway events nor predicts track changes independently.

Play/pause, toggle, previous/next and seek are supported. Seek requires an explicit, valid seek range in the server snapshot. Positions are finite, clamped to that range and sent as whole seconds through `Seek`. Shuffle/repeat are not advertised. The iOS speaker slider uses room volume, respects the server's current maximum, and never exceeds 70.

Paused sessions remain available. Stopping playback, standby, losing connection, or closing the app window removes the app's publication. The extension also clears its content and disables commands when it observes standby or a Linn disconnection. When this phone itself loses its route to the home server, the extension keeps the APNs-backed content but disables commands and removes the speaker's volume slider until its own `WatchState` stream reaches the server again. It treats the route as lost after two consecutive failed attempts (the first attempt and the 1 s retry), or at once if the stream ends for good. An APNs update restarts that stream, as does Louie reconnecting to the home server: the app then re-sends its fresh state even when nothing changed. Merely resuming Louie re-sends nothing, because its state may predate newer APNs content. No background audio mode or local audio session is activated.

## Background limits

The iOS extension is not a permanently running service. The optional [APNs integration](now-playing-push.md) registers push-to-start tokens from the app and session-update tokens from the extension. The home server sends start/update/end notifications while both processes are suspended. Apple controls delivery and presentation; real signed-device verification remains necessary.

The extension needs access to the home server for commands and token registration. APNs delivery itself only needs internet access. Losing the phone's LAN connection preserves server-managed Now Playing content but disables its controls until the extension reconnects; an authoritative Linn standby/disconnection update removes it. No standalone Watch app or internet-accessible control endpoint is added.

## Verification

Package tests cover server seek-range mapping, finite/clamped seeks, snapshot serialization and elapsed-time anchors, complete snapshot replacement, observable radio updates, standby/disconnection/recovery, room-volume limits, command error propagation, the extension's reachability gating and monitor restart, and superseded system volume. CI's existing Swift package job runs both test targets. Both app platforms must build; iOS must embed and validate the extension.

On a signed iOS 27 device on the home network:

1. Open Louie during playback; inspect track, artwork, elapsed time and room in Lock Screen/Control Center.
2. Background Louie and exercise pause/play, previous/next, scrub and volume. Confirm updated metadata and the volume limit on the real Linn.
3. Switch to radio: the scrubber should disappear. Pause should retain controls; stop or standby should remove active content when an update can be delivered.
4. Change the song from another controller. Disconnect/reconnect the home server and check stale content disappears and recovers. Test prolonged suspension separately against the limitation above.
5. With a push-enabled build, leave the home network during playback (turn Wi-Fi off). Lock Screen content should stay and keep updating through APNs, while play/pause, previous/next and scrub become disabled and the volume slider disappears. After the song changes, open Louie while still away: the Lock Screen must keep showing the new song rather than revert to what Louie showed before it was suspended. Return home and open Louie (once it reconnects), or wait for the next APNs update: controls should be enabled again. If a Lock Screen command still does nothing, stream the `xyz.preetz.Louie` logs with category `NowPlaying` in Console (include info messages for volume). They show reachability changes, completed and failed commands, and commands refused locally because of stale attributes.

On macOS 27, open Louie and check Control Center metadata and media keys, including seek on supported tracks. Confirm another media app can take primary status and closing Louie releases its session. Automatic system-primary selection remains controlled by macOS.

Apple references: [remote sessions](https://developer.apple.com/documentation/nowplaying/publishing-remote-media-sessions), [general sessions](https://developer.apple.com/documentation/nowplaying/publishing-media-sessions).
