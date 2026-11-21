import Foundation
import Linn
import NowPlaying
import Observation
import OSLog

/// The iOS extension and macOS app share metadata and acknowledged gateway commands.
@Observable
@MainActor
public final class LinnMediaSession {
    public let id: String
    public private(set) var attributes: LinnSessionAttributes
    /// This phone's own route to Louie Home Server, as seen by the WatchState stream.
    /// APNs and app updates describe only the server's view, so `update(_:)` never changes it.
    private(set) var canReachServer = true
    @ObservationIgnored private var consecutiveUnreachable = 0
    @ObservationIgnored private let gateway: any LinnGateway
    @ObservationIgnored private var monitoringEnabled = false
    @ObservationIgnored private var monitoringTask: Task<Void, Never>?
    @ObservationIgnored private var monitoringGeneration = 0
    /// Diagnostics: only a session on the real gateway probes the network.
    @ObservationIgnored private let probesNetwork: Bool
    private static let logger = Logger(subsystem: "xyz.preetz.Louie", category: "NowPlaying")

    public init(attributes: LinnSessionAttributes, gateway: (any LinnGateway)? = nil) {
        id = attributes.id
        self.attributes = attributes
        self.gateway = gateway ?? Linn.Configuration(serverURL: attributes.serverURL).makeGateway()
        probesNetwork = gateway == nil
        Self.logger.notice("Session created: host=\(attributes.serverURL.host() ?? "?", privacy: .public) \(Self.summary(attributes), privacy: .public)")
    }

    private static func summary(_ attributes: LinnSessionAttributes) -> String {
        "state=\(attributes.playback.state.map(\.rawValue) ?? "nil") canControl=\(attributes.canControlPlayback) hasContent=\(attributes.hasContent) push=\(attributes.installationID != nil)"
    }

    @ObservationIgnored private var pushTokenTask: Task<Void, Never>?

    deinit {
        monitoringTask?.cancel()
        pushTokenTask?.cancel()
    }

    #if os(iOS)
    public func startObservingPushToken() {
        guard pushTokenTask == nil, let installationID = attributes.installationID,
              let value = attributes.pushEnvironment, let environment = NowPlayingPushEnvironment(rawValue: value) else { return }
        let registrar = NowPlayingTokenRegistrar(
            gateway: Linn.Configuration(serverURL: attributes.serverURL).makePushGateway(),
            installationID: installationID, environment: environment, serverURL: attributes.serverURL)
        let current = pushToken
        let updates = pushTokenUpdates
        let sessionID = id
        pushTokenTask = Task { await registrar.observe(current: current, updates: updates, sessionID: sessionID) }
    }
    #endif

    /// Used by the extension while it is running, including after a Lock Screen command.
    public func startMonitoring() {
        monitoringEnabled = true
        guard monitoringTask == nil else { return }
        monitoringGeneration += 1
        let generation = monitoringGeneration
        Self.logger.notice("Monitor \(generation) started, canReachServer=\(self.canReachServer)")
        if probesNetwork {
            let url = attributes.serverURL
            Task {
                let result = await ReachabilityProbe.describe(url)
                Self.logger.notice("Monitor \(generation) network probe: \(result, privacy: .public)")
            }
        }
        monitoringTask = Task { [weak self, gateway, room = attributes.room] in
            do {
                let updates = await gateway.nowPlayingUpdates(room: room, updateInterval: 1)
                for try await update in updates {
                    if Task.isCancelled { break }
                    self?.receive(update)
                }
            } catch is CancellationError {
            } catch {
                self?.receive(Linn.Snapshot(connectionState: .serverUnreachable))
                // The stream failed for good, so no retry can prove reachability.
                self?.setCanReachServer(false)
                Self.logger.error("Remote session subscription failed: \(String(describing: error), privacy: .public)")
            }
            // A cancelled predecessor must not clear its replacement's handle.
            if self?.monitoringGeneration == generation { self?.monitoringTask = nil }
        }
    }

    private func restartMonitoring() {
        monitoringTask?.cancel()
        monitoringTask = nil
        startMonitoring()
    }

    func receive(_ update: Linn.Snapshot) {
        recordReachability(update.connectionState)
        // Keep the existing system session until the server resolves an unknown song.
        // Authoritative stop, standby and disconnection still take effect immediately.
        if update.connectionState == .connected && !update.isStandby
            && update.currentSong == nil && update.pending.currentItem
            && [.playing, .paused, .buffering, .loading].contains(update.playState) { return }
        if attributes.installationID != nil && [.idle, .connecting, .serverUnreachable].contains(update.connectionState) { return }
        let previous = attributes.playback
        // Home Server sends complete projections, including cleared fields.
        attributes.canControlPlayback = update.connectionState == .connected && !update.isStandby
        attributes.playback = .init(song: update.currentSong, state: update.playState, timeline: update.timeline)
        attributes.hasPrevious = (update.playlist.currentIndex ?? 0) > 0
        attributes.hasNext = update.playlist.currentIndex.map { $0 + 1 < (update.playlist.total ?? 0) } ?? false
        attributes.volume = update.volume
        if let maximum = update.maximumVolume { attributes.maximumVolume = min(70, maximum) }
        if previous != attributes.playback {
            attributes.timestamp = update.timeline?.sampledAtSeconds.map(Date.init(timeIntervalSince1970:)) ?? .now
        }
    }

    /// PiLinnGateway yields `.serverUnreachable` itself when a WatchState attempt fails.
    /// Every other state in the stream is a frame from Louie Home Server.
    private func recordReachability(_ connection: Linn.ConnectionState) {
        switch connection {
        case .serverUnreachable:
            // Resuming often fails once on a socket iOS reclaimed while suspended. The gateway's
            // 1 s retry failing as well means this phone has no route to the server.
            consecutiveUnreachable += 1
            Self.logger.notice("WatchState unreachable (\(self.consecutiveUnreachable) in a row)")
            if consecutiveUnreachable >= 2 { setCanReachServer(false) }
        case .connected, .connecting, .linnUnavailable:
            consecutiveUnreachable = 0
            setCanReachServer(true)
        case .idle, .failed:
            break // App-side states; WatchState never carries them.
        }
    }

    private func setCanReachServer(_ reachable: Bool) {
        guard canReachServer != reachable else { return }
        canReachServer = reachable
        if reachable {
            Self.logger.notice("Now Playing extension reached Louie Home Server; controls enabled")
        } else {
            Self.logger.notice("Now Playing extension cannot reach Louie Home Server; controls disabled")
        }
    }

    public func update(_ attributes: LinnSessionAttributes) {
        guard attributes.id == id else { return }
        Self.logger.notice("Attributes update: \(Self.summary(attributes), privacy: .public) monitor=\(self.monitoringTask != nil) canReachServer=\(self.canReachServer)")
        self.attributes = attributes
        // APNs or the app woke the extension. A stopped monitor, or one backing off after
        // losing this phone's route, gets a fresh attempt so disabled controls can return.
        if monitoringEnabled && (monitoringTask == nil || !canReachServer) { restartMonitoring() }
    }

    public var content: (any MediaContentRepresentable)? {
        guard attributes.hasContent, let song = attributes.playback.song else { return nil }
        let duration = attributes.playback.timeline?.duration ?? song.duration
        let artwork = song.artworkURL.map { url in
            Artwork(id: url.absoluteString) { _ in
                let (data, response) = try await URLSession.shared.data(from: url)
                if let response = response as? HTTPURLResponse, !(200..<300).contains(response.statusCode) {
                    throw URLError(.badServerResponse)
                }
                return try ArtworkRepresentation(data: data)
            }
        }
        return MusicContent(
            id: song.id, songTitle: song.title, artistName: song.artist ?? "",
            albumName: song.album ?? "", type: .audio,
            duration: duration.flatMap { $0 > 0 ? .finite(TimeInterval($0)) : nil }, artwork: artwork
        )
    }

    public var playbackSnapshot: MediaPlaybackSnapshot? {
        guard attributes.hasContent else {
            return MediaPlaybackSnapshot(state: .stopped, timestamp: attributes.timestamp)
        }
        let state: MediaPlaybackSnapshot.PlaybackState
        switch attributes.playback.state {
        case .playing: state = .playing()
        case .paused: state = .paused
        case .buffering, .loading: state = .buffering
        case .stopped, nil: state = .stopped
        }
        return MediaPlaybackSnapshot(
            state: state,
            elapsedTime: attributes.playback.timeline?.position.map(TimeInterval.init),
            timestamp: attributes.timestamp
        )
    }

    /// Pushed attributes keep the content current off the home network, but a command
    /// can only be delivered while this phone reaches the server itself.
    var canSendCommands: Bool { attributes.canControlPlayback && canReachServer }

    public var commands: [MediaCommand] {
        guard attributes.canControlPlayback else { return [] }
        return [
            .play { try await self.handleSystemRequest("play") { try await self.perform(.play) } }
                .enabled(canReachServer),
            .pause { try await self.handleSystemRequest("pause") { try await self.perform(.pause) } }
                .enabled(canReachServer),
            .togglePlayPause { try await self.handleSystemRequest("toggle") { try await self.perform(.togglePlayPause) } }
                .enabled(canReachServer),
            .previous { try await self.handleSystemRequest("previous") { try await self.perform(.previous) } }
                .enabled(canReachServer && attributes.hasPrevious),
            .next { try await self.handleSystemRequest("next") { try await self.perform(.next) } }
                .enabled(canReachServer && attributes.hasNext),
            .seekToPosition { position in try await self.handleSystemRequest("seek") { try await self.perform(.seek(position)) } }
                .enabled(canReachServer && attributes.playback.timeline?.seekableRange != nil),
        ]
    }

    enum Command { case play, pause, togglePlayPause, previous, next, seek(TimeInterval) }
    enum CommandError: Error { case unavailable }

    /// Logs the outcome of one system request. `perform` recurses for toggle, so this wraps it.
    private func handleSystemRequest(
        _ name: String, successLevel: OSLogType = .default, _ request: () async throws -> Void
    ) async throws {
        do {
            try await request()
            // Tells a server that accepted the request apart from a tap that never reached the extension.
            Self.logger.log(level: successLevel, "Now Playing \(name, privacy: .public) completed")
        } catch {
            switch error {
            case is CancellationError:
                break
            case is CommandError, is Linn.SeekError:
                // Stale attributes or an invalid seek; the request never left the extension.
                Self.logger.error("Now Playing \(name, privacy: .public) refused locally: \(String(describing: error), privacy: .public)")
            default:
                Self.logger.error("Now Playing \(name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
            throw error
        }
    }

    // Report the server acknowledgement or error to NowPlaying. Predictions arrive
    // through WatchState; the extension does not predict independently.
    func perform(_ command: Command) async throws {
        if monitoringEnabled { startMonitoring() }
        guard attributes.canControlPlayback else { throw CommandError.unavailable }
        switch command {
        case .play:
            try await gateway.play(room: attributes.room)
        case .pause:
            try await gateway.pause(room: attributes.room)
        case .togglePlayPause:
            try await perform(attributes.playback.state == .playing ? .pause : .play)
        case .previous:
            guard attributes.hasPrevious else { throw CommandError.unavailable }
            try await gateway.previous(room: attributes.room)
        case .next:
            guard attributes.hasNext else { throw CommandError.unavailable }
            try await gateway.next(room: attributes.room)
        case .seek(let position):
            guard let timeline = attributes.playback.timeline else { throw Linn.SeekError.unavailable }
            try await gateway.seek(to: timeline.seekPosition(for: position), room: attributes.room)
        }
    }

    private var effectiveMaximumVolume: Int { max(0, min(70, attributes.maximumVolume)) }

    var normalizedVolume: Float? {
        attributes.volume.map { min(1, max(0, Float($0) / Float(max(1, effectiveMaximumVolume)))) }
    }

    func setVolume(_ level: Float) async throws {
        if monitoringEnabled { startMonitoring() }
        guard attributes.canControlPlayback, level.isFinite else { throw CommandError.unavailable }
        let volume = Int((min(1, max(0, level)) * Float(effectiveMaximumVolume)).rounded())
        do {
            try await gateway.setVolume(volume, room: attributes.room, group: false)
        } catch is CancellationError {
            // A newer value superseded this one on the server; WatchState reports the result.
        }
    }
}

#if os(macOS)
extension LinnMediaSession: MediaSessionRepresentable {}
#elseif os(iOS)
extension LinnMediaSession: RemoteMediaSessionRepresentable {
    public var devices: [MediaDevice] {
        guard attributes.canControlPlayback else { return [] }
        // The speaker stays listed; its slider returns once this phone reaches the server again.
        let volume = canReachServer ? normalizedVolume : nil
        let capabilities: [MediaDevice.Capability] = volume.map { volume in
            // A drag reports many levels; keep their successes out of the persisted log.
            [.absoluteVolume(volume) { level in
                try await self.handleSystemRequest("volume", successLevel: .info) { try await self.setVolume(level) }
            }]
        } ?? []
        return [MediaDevice(id: id, name: attributes.room, type: .speaker, capabilities: capabilities)]
    }
}
#endif
