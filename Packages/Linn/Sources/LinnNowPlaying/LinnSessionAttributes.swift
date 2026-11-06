import Foundation
import Linn
import NowPlaying

/// Shared by the app and its remote-media extension. No app process state is required to send a command.
public struct LinnSessionAttributes: Codable, Sendable, Equatable {
    public let serverURL: URL
    public let room: String
    public var maximumVolume: Int
    public var playback: Playback
    public var timestamp: Date
    public var hasPrevious: Bool
    public var hasNext: Bool
    public var volume: Int?
    public var canControlPlayback: Bool

    public var id: String { "\(serverURL.absoluteString)|\(room)" }

    public struct Playback: Codable, Sendable, Equatable {
        public var song: Linn.Song?
        public var state: Linn.PlayState?
        public var timeline: Linn.Timeline?
    }

    @MainActor
    public init(linn: Linn, serverURL: URL, previous: Self? = nil, now: Date = .now) {
        self.serverURL = serverURL
        room = linn.room
        maximumVolume = min(70, linn.maximumVolume)
        playback = Playback(song: linn.currentSong, state: linn.playState, timeline: linn.timeline)
        // Volume/queue changes must not reset the system's elapsed-time anchor.
        timestamp = previous?.playback == playback ? previous!.timestamp : now
        hasPrevious = linn.hasPrevious
        hasNext = linn.hasNext
        volume = linn.volume
        canControlPlayback = linn.canControlPlayback
    }

    public var hasContent: Bool {
        canControlPlayback && playback.song != nil && playback.state != nil && playback.state != .stopped
    }
}

#if os(iOS)
extension LinnSessionAttributes: RemoteMediaSessionAttributes {}
#endif
