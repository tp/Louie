import Foundation
import Linn
import LinnCiGateway
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
        self.gateway = gateway ?? CiGateway(webSocketURL: attributes.gatewayURL)
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
                Logger(subsystem: "xyz.timm.preetz.Louie", category: "NowPlaying")
                    .error("Remote session subscription failed: \(String(describing: error), privacy: .public)")
            }
            self?.monitoringTask = nil
        }
    }

    func receive(_ update: CiGateway.NowPlaying) {
        let previous = attributes.playback
        // The handshake delivers several partial snapshots before all subscriptions arrive.
        if let song = Linn.Song(update.currentItem) { attributes.playback.song = song }
        if let state = Linn.PlayState(update.playback) { attributes.playback.state = state }
        if let timeline = Linn.Timeline(update.timeline) { attributes.playback.timeline = timeline }
        if let queue = update.queue {
            attributes.hasPrevious = (queue.index ?? 0) > 0
            attributes.hasNext = queue.index.map { $0 + 1 < (queue.length ?? 0) } ?? false
        }
        if let volume = update.roomState?.volume { attributes.volume = volume }
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
        [
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

    // Keep the async acknowledgement path separate from Linn's optimistic UI controls.
    // NowPlaying must receive gateway failures instead of an early successful return.
    func perform(_ command: Command) async throws {
        if monitoringEnabled { startMonitoring() }
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
}

#if os(macOS)
extension LinnMediaSession: MediaSessionRepresentable {}
#elseif os(iOS)
extension LinnMediaSession: RemoteMediaSessionRepresentable {
    public var devices: [MediaDevice] {
        let gateway = gateway
        let room = attributes.room
        let maximumVolume = attributes.maximumVolume
        let capabilities: [MediaDevice.Capability] = attributes.volume.map { volume in
            [.absoluteVolume(Float(volume) / 100) { level in
                guard level.isFinite else { throw CommandError.unavailable }
                let volume = min(maximumVolume, Int((min(1, max(0, level)) * 100).rounded()))
                try await gateway.setVolume(volume, room: room, group: true)
            }]
        } ?? []
        return [MediaDevice(id: id, name: room, type: .speaker, capabilities: capabilities)]
    }
}
#endif
