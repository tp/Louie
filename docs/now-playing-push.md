# Now Playing push setup

## Apple setup

Use Apple Developer team `8Q6UTKYN59` for both targets:

| Target | Explicit bundle identifier |
| --- | --- |
| Louie | `xyz.preetz.Louie` |
| Embedded Now Playing extension | `xyz.preetz.Louie.NowPlaying` |

The App Store Connect record uses SKU `louie-ios`. The store display name can
differ from the app target name and bundle ID.

Only Louie needs an App Store Connect app record. The extension is shipped inside
that app, with no separate installation or store listing. Enable **Push Notifications**
on the main App ID and select your team for both targets in Xcode. There is no Watch
target in this implementation.

Create an APNs key in Developer Account → Certificates, Identifiers & Profiles →
Keys. Record the Team ID and Key ID and download the private `.p8` file. Current
Apple keys may be scoped to an environment; configure production for TestFlight
and sandbox for development builds. A key enabled for both environments can be
used for both sets of settings below. The key must
permit the app's Now Playing topic: `xyz.preetz.Louie.push-type.nowplaying`.
Never commit or put the private key into the app bundle.

The iOS app has an `aps-environment` entitlement using `LOUIE_APNS_ENVIRONMENT`.
Debug defaults to `development` (sandbox); Release defaults to `production`.
The same build setting goes into Info.plist so registration selects the correct
APNs endpoint. **Check the final signed entitlement after export**: if you sign a
Release build with a development profile, build with
`LOUIE_APNS_ENVIRONMENT=development`. A beta OS does not make TestFlight sandbox.

## Home server setup

Copy the key to a private location such as:

```sh
mkdir -p ~/.config/louie
chmod 700 ~/.config/louie
# Copy your own downloaded key here; do not use the repository's test key.
chmod 600 ~/.config/louie/AuthKey_PRODUCTION.p8
```

Add these to `~/.config/louie/server.env`:

```dotenv
APNS_TEAM_ID=YOUR_TEAM_ID
APNS_BUNDLE_ID=xyz.preetz.Louie
APNS_PRODUCTION_KEY_ID=YOUR_KEY_ID
APNS_PRODUCTION_KEY_PATH=/home/louie/.config/louie/AuthKey_PRODUCTION.p8
# Optional development environment:
# APNS_SANDBOX_KEY_ID=YOUR_SANDBOX_KEY_ID
# APNS_SANDBOX_KEY_PATH=/home/louie/.config/louie/AuthKey_SANDBOX.p8
```

Restart `louie.service` after deploying this branch. Without keys, ordinary gRPC
controls continue working and the app retries token registration. The server never
logs device tokens, JWTs or private-key contents. APNs error logging deliberately
omits request URLs, because device tokens appear in their paths.

The registry is a small in-memory collection backed by atomic JSON writes to
`~/.local/state/louie/nowplaying.json`. It persists installations, token kinds,
environments, session IDs and control endpoints. Registration succeeds only after
saving. It replaces rotated tokens, uses conditional removal to protect replacements,
and retains at most one start and one session token per installation/environment.
Delivery cursors and playback state are not persisted. Keep the JSON private.

## Data flow

1. App launch loads/creates a stable installation UUID in UserDefaults. It registers
   the current push-to-start token, observes rotations and retries registration failures.
2. Attributes carry the installation ID and APNs environment into the extension;
   no App Group is necessary to share this identity.
3. Each extension session registers its current update token and observes rotations.
4. The server watches its existing playback projection. It sends `start` when there
   is content and no update token, `update` for meaningful changes, and `end` on stop,
   standby or Linn disconnection. Paused sessions remain available.
5. The same Codable attributes are used by gRPC-driven publication and APNs. A shared
   fixture is validated by Rust and Swift. Times use explicit Unix seconds; play
   states use string values. No decoder-specific Date encoding is assumed.

The server uses Apple's `nowplaying` push type and app-level topic. It caches the
ES256 provider JWT for 30 minutes, coalesces state, and suppresses ordinary elapsed
seconds. A seek/drift correction, metadata, play state, availability, volume or
seek-range change produces an update. Requests expire immediately if the device
cannot receive them; retries use the latest state rather than queued old payloads.
Successful APNs acceptance is not proof of display or delivery.

## Signed-device verification

These checks need your real provisioning and APNs credentials; mock tests cannot
verify system presentation or Apple's push budget/scheduling.

1. Install the signed iOS 27 app on a real device on the home LAN. Open Louie during
   playback, then verify start and session tokens appear in the private registry
   (inspect counts/kinds/environments, do not paste token values into logs).
2. Background the app and let iOS suspend it. Change track, pause/resume, seek and
   change volume from a second controller; inspect Lock Screen/Control Center.
3. Stop playback or put Linn in standby; verify the remote session ends. Start it
   from another controller while Louie remains closed; verify push-to-start and a
   newly registered session-update token.
4. Restart the home server; verify persisted session tokens continue to receive
   updates. Restart/upgrade the app and verify token rotation does not duplicate
   registrations.
5. Repeat with a TestFlight build against **production** APNs.
6. Test leaving the LAN: registered sessions can receive APNs updates, but controls
   and registration of a new session still require LAN/VPN access. No Funnel is
   configured. Also verify the system's Watch Now Playing behavior; this is not an
   independent Watch app.

Apple references: [remote sessions and payloads](https://developer.apple.com/documentation/nowplaying/publishing-remote-media-sessions),
[APNs signing keys](https://developer.apple.com/help/account/keys/create-a-private-key/),
[token authentication](https://developer.apple.com/documentation/usernotifications/establishing-a-token-based-connection-to-apns).
