import Foundation

/// Linn state and library data shared by the server client, previews, and tests.
public enum LinnGatewayData {
    public struct NowPlaying: Sendable, Equatable {
        public enum ConnectionStatus: Sendable, Equatable {
            case connected
            case connecting
            case disconnected
            case serverUnreachable
        }

        public var connectionStatus = ConnectionStatus.connected
        public var connectionError: String?
        public struct Pending: Sendable, Equatable {
            public var playback = false
            public var transport = false
            public var queue = false
            public var queueIndex = false
            public var queueTotal = false
            public var currentItem = false
            public var timeline = false
            public var volume = false
            public var mute = false

            public init(playback: Bool = false, transport: Bool = false, queue: Bool = false, queueIndex: Bool = false, queueTotal: Bool = false, currentItem: Bool = false, timeline: Bool = false, volume: Bool = false, mute: Bool = false) {
                self.playback = playback
                self.transport = transport
                self.queue = queue
                self.queueIndex = queueIndex
                self.queueTotal = queueTotal
                self.currentItem = currentItem
                self.timeline = timeline
                self.volume = volume
                self.mute = mute
            }
        }

        public var pending = Pending()
        public var context: Context
        public var playback: Playback?
        public var queue: Queue?
        public var currentItem: CurrentItem?
        public var playlist: Playlist?
        public var timeline: Timeline?
        public var roomState: RoomState?

        public init(room: String, session: String) {
            context = Context(room: room, session: session)
        }

        public var room: String {
            context.room
        }

        public var session: String {
            context.session
        }

        public struct Context: Sendable, Equatable {
            public var room: String
            public var session: String

            public init(room: String, session: String) {
                self.room = room
                self.session = session
            }
        }

        public enum TransportState: String, Sendable, Equatable {
            case stop
            case play
            case pause
            case buffering
            case waiting
            case unknown
        }

        public struct Playback: Sendable, Equatable {
            public var transportState: TransportState?

            public init(
                transportState: TransportState? = nil
            ) {
                self.transportState = transportState
            }
        }

        public struct Queue: Sendable, Equatable {
            public var index: Int?
            public var length: Int?

            public init(index: Int? = nil, length: Int? = nil) {
                self.index = index
                self.length = length
            }
        }

        public struct RoomState: Sendable, Equatable {
            public var volume: Int?
            public var isMuted: Bool?
            public var maximumVolume: Int?

            public init(volume: Int? = nil, isMuted: Bool? = nil, maximumVolume: Int? = nil) {
                self.volume = volume
                self.isMuted = isMuted
                self.maximumVolume = maximumVolume
            }
        }

        public struct Playlist: Sendable, Equatable {
            public var items: [PlaylistItem]
            public var total: Int?
            public var contentRevision: Int?

            public init(items: [PlaylistItem] = [], total: Int? = nil, contentRevision: Int? = nil) {
                self.items = items
                self.total = total
                self.contentRevision = contentRevision
            }
        }

        public struct PlaylistItem: Sendable, Equatable, Identifiable {
            public var index: Int
            public var displayName: String?
            public var album: String?
            public var artist: String?
            public var duration: Int?
            public var artworkURL: URL?
            public var isCurrent: Bool

            public init(
                index: Int,
                displayName: String? = nil,
                album: String? = nil,
                artist: String? = nil,
                duration: Int? = nil,
                artworkURL: URL? = nil,
                isCurrent: Bool = false
            ) {
                self.index = index
                self.displayName = displayName
                self.album = album
                self.artist = artist
                self.duration = duration
                self.artworkURL = artworkURL
                self.isCurrent = isCurrent
            }

            public var id: Int {
                index
            }
        }

        public struct CurrentItem: Sendable, Equatable, Identifiable {
            public var id: String
            public var kind: String
            public var displayName: String?
            public var artworkURL: URL?
            public var track: Track?

            public init(
                id: String,
                kind: String,
                displayName: String? = nil,
                artworkURL: URL? = nil,
                track: Track? = nil
            ) {
                self.id = id
                self.kind = kind
                self.displayName = displayName
                self.artworkURL = artworkURL
                self.track = track
            }
        }

        public struct Track: Sendable, Equatable {
            public var title: String?
            public var album: String?
            public var artist: String?

            public init(title: String? = nil, album: String? = nil, artist: String? = nil) {
                self.title = title
                self.album = album
                self.artist = artist
            }
        }

        public struct Timeline: Sendable, Equatable {
            public var position: Int?
            public var duration: Int?
            public var seekableRange: SeekableRange?

            public init(position: Int? = nil, duration: Int? = nil, seekableRange: SeekableRange? = nil) {
                self.position = position
                self.duration = duration
                self.seekableRange = seekableRange
            }

            public var progress: Double? {
                guard let position, let duration, duration > 0 else {
                    return nil
                }
                return Double(position) / Double(duration)
            }
        }

        public struct SeekableRange: Sendable, Equatable {
            public var lowerBound: Int?
            public var upperBound: Int?

            public init(lowerBound: Int? = nil, upperBound: Int? = nil) {
                self.lowerBound = lowerBound
                self.upperBound = upperBound
            }
        }
    }

    public struct MediaService: Sendable, Equatable, Identifiable {
        public var id: String
        public var name: String
        public var kind: String?

        public init(id: String, name: String, kind: String? = nil) {
            self.id = id
            self.name = name
            self.kind = kind
        }
    }

    public struct MediaItem: Sendable, Equatable, Identifiable {
        public var id: String
        public var kind: String
        public var name: String?
        public var title: String?
        public var album: String?
        public var artists: [String]
        public var artworkURL: URL?
        public var duration: Int?
        public var containedKinds: [String]
        public var childCount: Int?
        public var isFavourite: Bool?
        public var canFavourite: Bool

        public init(
            id: String,
            kind: String,
            name: String? = nil,
            title: String? = nil,
            album: String? = nil,
            artists: [String] = [],
            artworkURL: URL? = nil,
            duration: Int? = nil,
            containedKinds: [String] = [],
            childCount: Int? = nil,
            isFavourite: Bool? = nil,
            canFavourite: Bool? = nil
        ) {
            self.id = id
            self.kind = kind
            self.name = name
            self.title = title
            self.album = album
            self.artists = artists
            self.artworkURL = artworkURL
            self.duration = duration
            self.containedKinds = containedKinds
            self.childCount = childCount
            self.isFavourite = isFavourite
            self.canFavourite = canFavourite ?? (isFavourite != nil)
        }

        public var displayTitle: String? {
            title ?? name
        }

        public var isContainer: Bool {
            kind.contains("container")
                || kind.contains("album")
                || kind.contains("playlist")
                || kind.hasPrefix("md.qobuz")
                || childCount != nil
                || !containedKinds.isEmpty
        }
    }

    public struct MediaPage: Sendable, Equatable {
        public var id: String?
        public var contentRevision: Int?
        public var index: Int
        public var count: Int
        public var total: Int?
        public var children: [MediaItem]

        public init(
            id: String? = nil,
            contentRevision: Int? = nil,
            index: Int = 0,
            count: Int = 0,
            total: Int? = nil,
            children: [MediaItem] = []
        ) {
            self.id = id
            self.contentRevision = contentRevision
            self.index = index
            self.count = count
            self.total = total
            self.children = children
        }
    }

}
