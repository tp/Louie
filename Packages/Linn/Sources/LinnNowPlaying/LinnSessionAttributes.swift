import Foundation
import Linn
import NowPlaying

/// Shared by the app and its remote-media extension. No app process state is required to send a command.
public struct LinnSessionAttributes: Codable, Sendable, Equatable {
    public let gatewayURL: URL
    public let room: String
    public let maximumVolume: Int
    public var playback: Playback
    public var timestamp: Date
    public var hasPrevious: Bool
    public var hasNext: Bool
    public var volume: Int?

    public var id: String { "\(gatewayURL.absoluteString)|\(room)" }

    public struct Playback: Codable, Sendable, Equatable {
        public var song: Linn.Song?
        public var state: Linn.PlayState?
        public var timeline: Linn.Timeline?
    }

    @MainActor
    public init(linn: Linn, gatewayURL: URL, previous: Self? = nil, now: Date = .now) {
        self.gatewayURL = gatewayURL
        room = linn.room
        maximumVolume = linn.maximumVolume
        playback = Playback(song: linn.currentSong, state: linn.playState, timeline: linn.timeline)
        // Volume/queue changes must not reset the system's elapsed-time anchor.
        timestamp = previous?.playback == playback ? previous!.timestamp : now
        hasPrevious = linn.hasPrevious
        hasNext = linn.hasNext
        volume = linn.volume
    }

    public var hasContent: Bool {
        playback.song != nil && playback.state != nil && playback.state != .stopped
    }
}

#if os(iOS)
extension LinnSessionAttributes: RemoteMediaSessionAttributes {}
#endif
