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
    @ObservationIgnored private let gateway: any LinnGateway
    @ObservationIgnored private var monitoringEnabled = false
    @ObservationIgnored private var monitoringTask: Task<Void, Never>?

    public init(attributes: LinnSessionAttributes, gateway: (any LinnGateway)? = nil) {
        id = attributes.id
        self.attributes = attributes
        self.gateway = gateway ?? Linn.Configuration(serverURL: attributes.serverURL).makeGateway()
    }

    deinit { monitoringTask?.cancel() }

    /// Used by the extension while it is running, including after a Lock Screen command.
    public func startMonitoring() {
        monitoringEnabled = true
        guard monitoringTask == nil else { return }
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
                Logger(subsystem: "xyz.timm.preetz.Louie", category: "NowPlaying")
                    .error("Remote session subscription failed: \(String(describing: error), privacy: .public)")
            }
            self?.monitoringTask = nil
        }
    }

    func receive(_ update: Linn.Snapshot) {
        // Keep the existing system session until the server resolves an unknown song.
        // Authoritative stop, standby and disconnection still take effect immediately.
        if update.connectionState == .connected && !update.isStandby
            && update.currentSong == nil && update.pending.currentItem
            && [.playing, .paused, .buffering, .loading].contains(update.playState) { return }
        let previous = attributes.playback
        // Home Server sends complete projections, including cleared fields.
        attributes.canControlPlayback = update.connectionState == .connected && !update.isStandby
        attributes.playback = .init(song: update.currentSong, state: update.playState, timeline: update.timeline)
        attributes.hasPrevious = (update.playlist.currentIndex ?? 0) > 0
        attributes.hasNext = update.playlist.currentIndex.map { $0 + 1 < (update.playlist.total ?? 0) } ?? false
        attributes.volume = update.volume
        if let maximum = update.maximumVolume { attributes.maximumVolume = min(70, maximum) }
        if previous != attributes.playback { attributes.timestamp = .now }
    }

    public func update(_ attributes: LinnSessionAttributes) {
        guard attributes.id == id else { return }
        self.attributes = attributes
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

    public var commands: [MediaCommand] {
        guard attributes.canControlPlayback else { return [] }
        return [
            .play { try await self.perform(.play) },
            .pause { try await self.perform(.pause) },
            .togglePlayPause { try await self.perform(.togglePlayPause) },
            .previous { try await self.perform(.previous) }.enabled(attributes.hasPrevious),
            .next { try await self.perform(.next) }.enabled(attributes.hasNext),
            .seekToPosition { try await self.perform(.seek($0)) }
                .enabled(attributes.playback.timeline?.seekableRange != nil),
        ]
    }

    enum Command { case play, pause, togglePlayPause, previous, next, seek(TimeInterval) }
    enum CommandError: Error { case unavailable }

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
        guard attributes.canControlPlayback, level.isFinite else { throw CommandError.unavailable }
        let volume = Int((min(1, max(0, level)) * Float(effectiveMaximumVolume)).rounded())
        try await gateway.setVolume(volume, room: attributes.room, group: false)
    }
}

#if os(macOS)
extension LinnMediaSession: MediaSessionRepresentable {}
#elseif os(iOS)
extension LinnMediaSession: RemoteMediaSessionRepresentable {
    public var devices: [MediaDevice] {
        guard attributes.canControlPlayback else { return [] }
        let capabilities: [MediaDevice.Capability] = normalizedVolume.map { volume in
            [.absoluteVolume(volume) { level in
                try await self.setVolume(level)
            }]
        } ?? []
        return [MediaDevice(id: id, name: attributes.room, type: .speaker, capabilities: capabilities)]
    }
}
#endif
