import Foundation

public extension Linn {
    enum ConnectionState: Sendable, Equatable {
        case idle
        case connecting
        case connected
        case failed(String)
    }

    enum PlayState: Sendable, Equatable {
        case stopped
        case playing
        case paused
        case loading
        case buffering
    }

    enum SongTransitionDirection: Sendable, Equatable {
        case forward
        case backward
    }

    struct Song: Sendable, Equatable, Identifiable {
        public var id: String
        public var title: String
        public var artist: String?
        public var album: String?
        public var duration: Int?
        public var artworkURL: URL?
        public var queueIndex: Int?

        public init(
            id: String,
            title: String,
            artist: String? = nil,
            album: String? = nil,
            duration: Int? = nil,
            artworkURL: URL? = nil,
            queueIndex: Int? = nil
        ) {
            self.id = id
            self.title = title
            self.artist = artist
            self.album = album
            self.duration = duration
            self.artworkURL = artworkURL
            self.queueIndex = queueIndex
        }
    }

    struct Timeline: Sendable, Equatable {
        public var position: Int?
        public var duration: Int?
        public var progress: Double?

        public init(position: Int? = nil, duration: Int? = nil, progress: Double? = nil) {
            self.position = position
            self.duration = duration
            self.progress = progress
        }
    }

    struct Playlist: Sendable, Equatable {
        public var songs: [Song]
        public var currentIndex: Int?
        public var total: Int?

        public init(songs: [Song] = [], currentIndex: Int? = nil, total: Int? = nil) {
            self.songs = songs
            self.currentIndex = currentIndex
            self.total = total
        }
    }

    enum SearchType: String, Sendable, Equatable, CaseIterable, Identifiable {
        case albums
        case artists
        case tracks
        case playlists
        case composers
        case stations

        public var id: String {
            rawValue
        }
    }

    enum QueuePlacement: String, Sendable, Equatable, CaseIterable, Identifiable {
        case now
        case next
        case last
        case replace

        public var id: String {
            rawValue
        }
    }

    struct LibraryService: Sendable, Equatable, Identifiable {
        public var id: String
        public var name: String
        public var kind: String?

        public init(id: String, name: String, kind: String? = nil) {
            self.id = id
            self.name = name
            self.kind = kind
        }
    }

    struct LibraryItem: Sendable, Equatable, Identifiable {
        public var id: String
        public var kind: String
        public var title: String
        public var subtitle: String?
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
            title: String,
            subtitle: String? = nil,
            album: String? = nil,
            artists: [String] = [],
            artworkURL: URL? = nil,
            duration: Int? = nil,
            containedKinds: [String] = [],
            childCount: Int? = nil,
            isFavourite: Bool? = nil,
            canFavourite: Bool = false
        ) {
            self.id = id
            self.kind = kind
            self.title = title
            self.subtitle = subtitle
            self.album = album
            self.artists = artists
            self.artworkURL = artworkURL
            self.duration = duration
            self.containedKinds = containedKinds
            self.childCount = childCount
            self.isFavourite = isFavourite
            self.canFavourite = canFavourite
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

    struct LibraryPage: Sendable, Equatable {
        public var id: String?
        public var contentRevision: Int?
        public var index: Int
        public var count: Int
        public var total: Int?
        public var items: [LibraryItem]

        public init(
            id: String? = nil,
            contentRevision: Int? = nil,
            index: Int = 0,
            count: Int = 0,
            total: Int? = nil,
            items: [LibraryItem] = []
        ) {
            self.id = id
            self.contentRevision = contentRevision
            self.index = index
            self.count = count
            self.total = total
            self.items = items
        }
    }

    struct LibrarySection: Sendable, Equatable, Identifiable {
        public enum Kind: String, Sendable, Equatable {
            case favourites
            case recommendations
            case playlists
            case purchases
            case browse
        }

        public var id: String
        public var title: String
        public var kind: Kind
        public var path: [String]
        public var source: LibraryItem?
        public var items: [LibraryItem]

        public init(
            id: String,
            title: String,
            kind: Kind,
            path: [String] = [],
            source: LibraryItem? = nil,
            items: [LibraryItem] = []
        ) {
            self.id = id
            self.title = title
            self.kind = kind
            self.path = path
            self.source = source
            self.items = items
        }
    }

    struct Library: Sendable, Equatable {
        public enum Availability: Sendable, Equatable {
            case unavailable
            case loading
            case available
            case failed(String)
        }

        public struct Qobuz: Sendable, Equatable {
            public var root: LibrarySection?
            public var discover: LibraryItem?
            public var genres: LibraryItem?
            public var myQobuz: LibraryItem?
            public var favouriteArtists: LibrarySection?
            public var favouriteAlbums: LibrarySection?
            public var favouritePlaylists: LibrarySection?
            public var myPlaylists: LibrarySection?
            public var purchases: LibrarySection?
            public var recommendations: [LibrarySection]
            public var browseSections: [LibrarySection]

            public init(sections: [LibrarySection] = []) {
                root = sections.first { Self.normalized($0.path) == ["qobuz"] }
                discover = Self.rootItem(in: root, title: "discover", kindContains: "discover")
                genres = Self.rootItem(in: root, title: "genres", kindContains: "genres")
                myQobuz = Self.rootItem(in: root, title: "my qobuz", kindContains: "myqobuz")
                favouriteArtists = Self.section(
                    in: sections,
                    matchingPathSuffixes: [
                        ["my qobuz", "favourites", "artist"],
                        ["my qobuz", "favourites", "artists"],
                    ]
                )
                favouriteAlbums = Self.section(
                    in: sections,
                    matchingPathSuffixes: [
                        ["my qobuz", "favourites", "album"],
                        ["my qobuz", "favourites", "albums"],
                    ]
                )
                favouritePlaylists = Self.section(
                    in: sections,
                    matchingPathSuffixes: [
                        ["my qobuz", "favourites", "playlist"],
                        ["my qobuz", "favourites", "playlists"],
                    ]
                )
                myPlaylists = Self.section(in: sections, matchingPathSuffixes: [["my qobuz", "my playlists"]])
                purchases = Self.section(in: sections, matchingPathSuffixes: [["my qobuz", "purchased"]])
                recommendations = sections.filter { $0.kind == .recommendations }
                browseSections = sections.filter { $0.kind == .browse }
            }

            private static func rootItem(
                in root: LibrarySection?,
                title: String,
                kindContains kind: String
            ) -> LibraryItem? {
                root?.items.first {
                    $0.title.lowercased() == title
                        || $0.kind.lowercased().contains(kind)
                }
            }

            private static func section(
                in sections: [LibrarySection],
                matchingPathSuffixes suffixes: [[String]]
            ) -> LibrarySection? {
                sections.first { section in
                    let path = normalized(section.path)
                    return suffixes.contains { hasSuffix($0, in: path) }
                }
            }

            private static func hasSuffix(_ suffix: [String], in path: [String]) -> Bool {
                guard suffix.count <= path.count else {
                    return false
                }
                return Array(path.suffix(suffix.count)) == suffix
            }

            private static func normalized(_ path: [String]) -> [String] {
                path.map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                }
            }
        }

        public var availability: Availability
        public var qobuzService: LibraryService?
        public var rootPage: LibraryPage?
        public var sections: [LibrarySection]
        public var qobuz: Qobuz

        public init(
            availability: Availability = .unavailable,
            qobuzService: LibraryService? = nil,
            rootPage: LibraryPage? = nil,
            sections: [LibrarySection] = [],
            qobuz: Qobuz? = nil
        ) {
            self.availability = availability
            self.qobuzService = qobuzService
            self.rootPage = rootPage
            self.sections = sections
            self.qobuz = qobuz ?? Qobuz(sections: sections)
        }
    }
}
