import Foundation
import Linn
import NowPlaying
import Observation
import OSLog

/// Retain one publisher for a connected window and cancel `run` when that connection is discarded.
@available(iOSApplicationExtension, unavailable)
@MainActor
@Observable
public final class LinnNowPlayingPublisher {
    public var isForeground = false

    private static let logger = Logger(subsystem: "xyz.preetz.Louie", category: "NowPlaying")
    #if os(iOS)
    @ObservationIgnored private var session: RemoteMediaSession<LinnSessionAttributes>?
    #elseif os(macOS)
    @ObservationIgnored private var session: MediaSession<LinnMediaSession>?
    @ObservationIgnored private var model: LinnMediaSession?
    #endif

    public init() {}

    public func run(linn: Linn, configuration: Linn.Configuration) async {
        #if os(iOS)
        let identity = NowPlayingPushIdentity.load()
        let tokenTask: Task<Void, Never>? = identity.map { identity in
            let registrar = NowPlayingTokenRegistrar(gateway: configuration.makePushGateway(),
                installationID: identity.installationID, environment: identity.environment, serverURL: configuration.serverURL)
            return Task {
                await registrar.observe(current: RemoteMediaSession<LinnSessionAttributes>.pushToStartToken,
                    updates: RemoteMediaSession<LinnSessionAttributes>.pushToStartTokenUpdates)
            }
        }
        defer { tokenTask?.cancel() }
        #else
        let identity: NowPlayingPushIdentity? = nil
        #endif
        let snapshots = Observations {
            (linn.connectionState, LinnSessionAttributes(linn: linn, serverURL: configuration.serverURL,
                installationID: identity?.installationID, pushEnvironment: identity?.environment.rawValue), linn.isCurrentSongPending, self.isForeground)
        }
        var previous: LinnSessionAttributes?
        var wasForeground = false
        for await (connection, observed, songPending, foreground) in snapshots {
            if Task.isCancelled { break }
            var attributes = observed
            if attributes.playback == previous?.playback {
                attributes.timestamp = previous!.timestamp
            }
            do {
                // An unknown shuffle destination is temporary, not a stopped session.
                if songPending && attributes.canControlPlayback
                    && [.playing, .paused, .buffering, .loading].contains(attributes.playback.state) { continue }
                // Losing this phone's LAN connection does not mean Linn stopped.
                // APNs can still keep the system session current off the home network.
                if identity != nil && [.idle, .connecting, .serverUnreachable].contains(connection) { continue }
                guard connection == .connected, attributes.hasContent else {
                    try await end()
                    previous = nil
                    wasForeground = foreground
                    continue
                }
                #if os(iOS)
                var started = false
                if session == nil, foreground {
                    // Reuse a surviving remote session after relaunch instead of duplicating the room.
                    let existing = try await RemoteMediaSession<LinnSessionAttributes>.sessions()
                    session = existing.first { $0.id == attributes.id }
                    if session == nil {
                        session = try await RemoteMediaSession.start(attributes: attributes)
                    }
                    started = true
                }
                if let session {
                    if started || attributes != previous { try await session.update(attributes) }
                    if foreground && (started || !wasForeground) {
                        try await session.requestToBecomeSystemPrimary()
                    }
                }
                #elseif os(macOS)
                if session == nil {
                    let model = LinnMediaSession(attributes: attributes)
                    self.model = model
                    let session = MediaSession(model)
                    self.session = session
                    do {
                        try await session.requestToBecomeApplicationPrimary()
                    } catch {
                        self.session = nil
                        self.model = nil
                        throw error
                    }
                } else if attributes != previous {
                    model?.update(attributes)
                }
                #endif
                previous = attributes
                wasForeground = foreground
            } catch is CancellationError {
                break
            } catch {
                Self.logger.error("Could not publish Now Playing: \(String(describing: error), privacy: .public)")
            }
        }
        #if os(iOS)
        // A view disappearing must not terminate the server-managed session.
        session = nil
        #else
        do { try await end() }
        catch { Self.logger.error("Could not end Now Playing: \(String(describing: error), privacy: .public)") }
        #endif
    }

    private func end() async throws {
        #if os(iOS)
        if let session {
            try await session.end()
            self.session = nil
        }
        #elseif os(macOS)
        session = nil
        model = nil
        #endif
    }
}
