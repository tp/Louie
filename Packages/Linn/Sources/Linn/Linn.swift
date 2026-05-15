import Foundation
import LinnCiGateway
import Observation
import OSLog

public protocol LinnGateway: Sendable {
    func nowPlayingUpdates(
        room: String?,
        updateInterval: Int
    ) async -> AsyncThrowingStream<CiGateway.NowPlaying, Error>

    func play(room: String) async throws
    func pause(room: String) async throws
    func previous(room: String) async throws
    func next(room: String) async throws
    func selectPlaylistItem(at index: Int, room: String) async throws
    func setVolume(_ volume: Int, room: String, group: Bool) async throws
    func setMuted(_ isMuted: Bool, room: String, group: Bool) async throws
    func mediaServices(room: String) async throws -> [CiGateway.MediaService]
    func browseMedia(mediaID: String, index: Int, count: Int, browseType: String) async throws -> CiGateway.MediaPage
    func searchMedia(serviceID: String, query: String, type: CiGateway.MediaSearchType, index: Int, count: Int) async throws -> CiGateway.MediaPage
    func selectMedia(mediaID: String, room: String, queue: CiGateway.QueuePlacement) async throws
    func setMediaFavourite(mediaID: String, isFavourite: Bool) async throws
}

public extension LinnGateway {
    func setVolume(_ volume: Int, room: String) async throws {
        try await setVolume(volume, room: room, group: true)
    }

    func setMuted(_ isMuted: Bool, room: String) async throws {
        try await setMuted(isMuted, room: room, group: true)
    }
}

@Observable
@MainActor
public final class Linn {
    public enum ConnectionState: Sendable, Equatable {
        case idle
        case connecting
        case connected
        case failed(String)
    }

    public enum PlayState: Sendable, Equatable {
        case stopped
        case playing
        case paused
        case loading
        case buffering
    }

    public enum SongTransitionDirection: Sendable, Equatable {
        case forward
        case backward
    }

    public struct Song: Sendable, Equatable, Identifiable {
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

    public struct Timeline: Sendable, Equatable {
        public var position: Int?
        public var duration: Int?
        public var progress: Double?

        public init(position: Int? = nil, duration: Int? = nil, progress: Double? = nil) {
            self.position = position
            self.duration = duration
            self.progress = progress
        }
    }

    public struct Playlist: Sendable, Equatable {
        public var songs: [Song]
        public var currentIndex: Int?
        public var total: Int?

        public init(songs: [Song] = [], currentIndex: Int? = nil, total: Int? = nil) {
            self.songs = songs
            self.currentIndex = currentIndex
            self.total = total
        }
    }

    public enum SearchType: String, Sendable, Equatable, CaseIterable, Identifiable {
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

    public enum QueuePlacement: String, Sendable, Equatable, CaseIterable, Identifiable {
        case now
        case next
        case last
        case replace

        public var id: String {
            rawValue
        }
    }

    public struct LibraryService: Sendable, Equatable, Identifiable {
        public var id: String
        public var name: String
        public var kind: String?

        public init(id: String, name: String, kind: String? = nil) {
            self.id = id
            self.name = name
            self.kind = kind
        }
    }

    public struct LibraryItem: Sendable, Equatable, Identifiable {
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

    public struct LibraryPage: Sendable, Equatable {
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

    public struct LibrarySection: Sendable, Equatable, Identifiable {
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

    public struct Library: Sendable, Equatable {
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

    public let room: String
    public let maximumVolume: Int
    public private(set) var connectionState: ConnectionState = .idle
    public private(set) var library = Library()
    public private(set) var currentSong: Song?
    public private(set) var playlist = Playlist()
    public private(set) var playState: PlayState?
    public private(set) var volume: Int?
    public private(set) var isMuted: Bool?
    public private(set) var timeline: Timeline?
    public private(set) var lastErrorMessage: String?
    public private(set) var songTransitionDirection: SongTransitionDirection = .forward

    public var previousSongs: [Song] {
        guard let currentIndex = playlist.currentIndex else {
            return []
        }

        return playlist.songs
            .filter { ($0.queueIndex ?? currentIndex) < currentIndex }
            .sorted { ($0.queueIndex ?? 0) > ($1.queueIndex ?? 0) }
    }

    public var upcomingSongs: [Song] {
        guard let currentIndex = playlist.currentIndex else {
            return []
        }

        return playlist.songs
            .filter { ($0.queueIndex ?? currentIndex) > currentIndex }
            .sorted { ($0.queueIndex ?? 0) < ($1.queueIndex ?? 0) }
    }

    public var hasPrevious: Bool {
        guard let currentIndex = playlist.currentIndex else {
            return false
        }
        return currentIndex > 0
    }

    public var hasNext: Bool {
        guard let currentIndex = playlist.currentIndex, let total = playlist.total else {
            return false
        }
        return currentIndex + 1 < total
    }

    private var ciGateway: (any LinnGateway)?
    private var configurationLoadAttempted = false
    private var playlistContentRevision: Int?
    private var playlistSongsByIndex: [Int: Song] = [:]
    private var optimisticTransition: OptimisticTransition?
    private var optimisticPlayState: OptimisticPlayState?
    private var playlistSelectionQueue = PlaylistSelectionQueue()
    private var libraryContentRevision: Int?
    private var libraryPageCache: [LibraryCacheKey: LibraryPage] = [:]
    private static let logger = Logger(subsystem: "Louie.Linn", category: "Linn")

    @ObservationIgnored private var updatesTask: Task<Void, Never>?
    @ObservationIgnored private var controlTask: Task<Void, Never>?
    @ObservationIgnored private var playlistSelectionTask: Task<Void, Never>?
    @ObservationIgnored private var playlistSelectionTimeoutTask: Task<Void, Never>?
    @ObservationIgnored private var libraryTask: Task<Void, Never>?

    private struct OptimisticTransition {
        var targetQueueIndex: Int
        var expiresAt: Date
    }

    private struct OptimisticPlayState {
        var targetState: PlayState
        var previousState: PlayState?
        var expiresAt: Date
    }

    private struct PlaylistSelectionJob: Sendable, Equatable {
        enum Kind: Sendable, Equatable {
            case skip
            case queueItem
        }

        var targetIndex: Int
        var kind: Kind
    }

    private struct PlaylistSelectionQueue: Sendable, Equatable {
        var inFlight: PlaylistSelectionJob?
        var pending: PlaylistSelectionJob?

        mutating func enqueue(_ job: PlaylistSelectionJob) -> PlaylistSelectionJob? {
            guard let inFlight else {
                inFlight = job
                return job
            }

            pending = job.targetIndex == inFlight.targetIndex ? nil : job
            return nil
        }

        mutating func confirm(targetIndex: Int) -> (confirmed: Bool, next: PlaylistSelectionJob?) {
            guard inFlight?.targetIndex == targetIndex else {
                return (false, nil)
            }

            inFlight = nil
            return (true, dequeuePending())
        }

        mutating func fail(targetIndex: Int) -> (failed: Bool, next: PlaylistSelectionJob?) {
            guard inFlight?.targetIndex == targetIndex else {
                return (false, nil)
            }

            inFlight = nil
            return (true, dequeuePending())
        }

        private mutating func dequeuePending() -> PlaylistSelectionJob? {
            guard let pending else {
                return nil
            }

            self.pending = nil
            inFlight = pending
            return pending
        }
    }

    private struct LibraryCacheKey: Sendable, Hashable {
        var mediaID: String
        var browseType: String
    }

    public init(
        configuration: Configuration,
        room: String = "Linn",
        maximumVolume: Int = 70
    ) {
        self.room = room
        self.maximumVolume = maximumVolume
        ciGateway = CiGateway(webSocketURL: configuration.ciGatewayWebSocketURL)
        configurationLoadAttempted = true
    }

    public init(
        gateway: any LinnGateway,
        room: String = "Linn",
        maximumVolume: Int = 70
    ) {
        self.room = room
        self.maximumVolume = maximumVolume
        ciGateway = gateway
        configurationLoadAttempted = true
    }

    public init(
        room: String = "Linn",
        maximumVolume: Int = 70
    ) {
        self.room = room
        self.maximumVolume = maximumVolume
        ciGateway = nil
    }

    #if DEBUG
        public init(
            mockRoom room: String = "Main Room",
            maximumVolume: Int = 70,
            connectionState: ConnectionState = .connected,
            currentSong: Song? = nil,
            previousSongs: [Song] = [],
            playState: PlayState? = nil,
            volume: Int? = nil,
            isMuted: Bool? = nil,
            timeline: Timeline? = nil,
            songTransitionDirection: SongTransitionDirection = .forward,
            hasPrevious: Bool = false,
            hasNext: Bool = false,
            lastErrorMessage: String? = nil
        ) {
            self.room = room
            self.maximumVolume = maximumVolume
            self.connectionState = connectionState
            self.currentSong = currentSong
            installMockPlaylist(previousSongs: previousSongs, currentSong: currentSong)
            self.playState = playState
            self.volume = volume
            self.isMuted = isMuted
            self.timeline = timeline
            self.songTransitionDirection = songTransitionDirection
            self.lastErrorMessage = lastErrorMessage
            ciGateway = nil
            configurationLoadAttempted = true
            setQueueAvailability(hasPrevious: hasPrevious, hasNext: hasNext)
        }
    #endif

    deinit {
        updatesTask?.cancel()
        controlTask?.cancel()
        playlistSelectionTask?.cancel()
        playlistSelectionTimeoutTask?.cancel()
        libraryTask?.cancel()
    }

    public func start() {
        if ciGateway == nil, !configurationLoadAttempted {
            configurationLoadAttempted = true
            do {
                let configuration = try Configuration.local()
                Self.logger.info("Loaded Linn gateway websocket URL \(configuration.ciGatewayWebSocketURL.absoluteString, privacy: .public)")
                ciGateway = CiGateway(webSocketURL: configuration.ciGatewayWebSocketURL)
            } catch {
                let message = String(describing: error)
                Self.logger.error("Failed to load Linn configuration: \(message, privacy: .public)")
                lastErrorMessage = message
                connectionState = .failed(message)
                return
            }
        }

        guard let ciGateway else {
            if case .failed = connectionState {
                return
            }
            connectionState = .connected
            return
        }

        updatesTask?.cancel()
        connectionState = .connecting
        lastErrorMessage = nil
        let requestedRoom = room
        Self.logger.info("Starting Linn now-playing updates for requested room \(requestedRoom, privacy: .public)")

        updatesTask = Task { [weak self] in
            guard let self else {
                return
            }

            do {
                let updates = await ciGateway.nowPlayingUpdates(room: requestedRoom, updateInterval: 1)
                for try await update in updates {
                    apply(update)
                    connectionState = .connected
                }
            } catch is CancellationError {
                Self.logger.info("Linn now-playing update task cancelled")
                connectionState = .idle
            } catch {
                let message = String(describing: error)
                Self.logger.error("Linn now-playing update task failed: \(message, privacy: .public)")
                lastErrorMessage = message
                connectionState = .failed(message)
            }
        }

        loadLibrary()
    }

    public func stop() {
        updatesTask?.cancel()
        updatesTask = nil
        libraryTask?.cancel()
        guard ciGateway != nil else {
            return
        }
        connectionState = .idle
    }

    public func play() {
        performControl(optimisticState: .playing) { ciGateway, room in
            try await ciGateway.play(room: room)
        }
    }

    public func pause() {
        performControl(optimisticState: .paused) { ciGateway, room in
            try await ciGateway.pause(room: room)
        }
    }

    public func playPause() {
        if playState == .playing {
            pause()
        } else {
            play()
        }
    }

    public func previous() {
        guard hasPrevious, let currentIndex = playlist.currentIndex else {
            return
        }

        selectQueueIndex(currentIndex - 1, kind: .skip)
    }

    public func next() {
        guard hasNext, let currentIndex = playlist.currentIndex else {
            return
        }

        selectQueueIndex(currentIndex + 1, kind: .skip)
    }

    public func play(_ song: Song) {
        guard let targetQueueIndex = song.queueIndex else {
            return
        }

        selectQueueIndex(targetQueueIndex, optimisticSong: song, kind: .queueItem)
    }

    public func setVolume(_ volume: Int) {
        let clampedVolume = max(0, min(maximumVolume, volume))
        self.volume = clampedVolume
        performControl { ciGateway, room in
            try await ciGateway.setVolume(clampedVolume, room: room)
        }
    }

    public func setMuted(_ isMuted: Bool) {
        self.isMuted = isMuted
        performControl { ciGateway, room in
            try await ciGateway.setMuted(isMuted, room: room)
        }
    }

    public func loadLibrary() {
        if library.availability == .loading {
            return
        }

        libraryTask?.cancel()

        guard let ciGateway else {
            library = Library(availability: .unavailable)
            libraryContentRevision = nil
            libraryPageCache = [:]
            return
        }

        library.availability = .loading
        libraryTask = Task { [weak self, ciGateway, room] in
            guard let self else {
                return
            }

            do {
                let services = try await ciGateway.mediaServices(room: room)
                guard let qobuzService = services.first(where: { $0.name.localizedCaseInsensitiveCompare("Qobuz") == .orderedSame }) else {
                    applyUnavailableLibrary()
                    return
                }

                let rootPage = try await ciGateway.browseMedia(
                    mediaID: qobuzService.id,
                    index: 0,
                    count: 50,
                    browseType: ""
                )
                let libraryRootPage = LibraryPage(rootPage)
                reconcileLibraryRevision(libraryRootPage.contentRevision)
                cache(libraryRootPage, mediaID: qobuzService.id, browseType: "")

                let sections = await buildLibrarySections(
                    rootPage: libraryRootPage,
                    gateway: ciGateway
                )
                library = Library(
                    availability: .available,
                    qobuzService: LibraryService(qobuzService),
                    rootPage: libraryRootPage,
                    sections: sections
                )
            } catch is CancellationError {
            } catch {
                let message = String(describing: error)
                Self.logger.error("Qobuz library load failed: \(message, privacy: .public)")
                library.availability = .failed(message)
            }
        }
    }

    public func refreshLibrary() {
        libraryContentRevision = nil
        libraryPageCache = [:]
        loadLibrary()
    }

    public func browse(_ item: LibraryItem, index: Int = 0, count: Int = 50, browseType: String = "") async throws -> LibraryPage {
        if index == 0, let cached = libraryPageCache[LibraryCacheKey(mediaID: item.id, browseType: browseType)] {
            return cached
        }

        guard let ciGateway else {
            throw LibraryError.unavailable
        }

        let page = try await ciGateway.browseMedia(mediaID: item.id, index: index, count: count, browseType: browseType)
        let libraryPage = LibraryPage(page)
        reconcileLibraryRevision(libraryPage.contentRevision)
        if index == 0 {
            cache(libraryPage, mediaID: item.id, browseType: browseType)
        }
        return libraryPage
    }

    public func searchLibrary(
        query: String,
        type: SearchType = .albums,
        index: Int = 0,
        count: Int = 25
    ) async throws -> LibraryPage {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            return LibraryPage(id: "search", index: index)
        }
        guard let ciGateway, let serviceID = library.qobuzService?.id else {
            throw LibraryError.unavailable
        }

        let page = try await ciGateway.searchMedia(
            serviceID: serviceID,
            query: trimmedQuery,
            type: CiGateway.MediaSearchType(type),
            index: index,
            count: count
        )
        return LibraryPage(page)
    }

    public func play(_ item: LibraryItem, placement: QueuePlacement = .replace) {
        guard ciGateway != nil else {
            return
        }

        performControl { ciGateway, room in
            try await ciGateway.selectMedia(
                mediaID: item.id,
                room: room,
                queue: CiGateway.QueuePlacement(placement)
            )
        }
    }

    public func setFavourite(_ item: LibraryItem, isFavourite: Bool) {
        guard item.canFavourite, let ciGateway else {
            return
        }

        updateLibraryItem(id: item.id, isFavourite: isFavourite)
        controlTask?.cancel()
        controlTask = Task { [weak self, ciGateway] in
            do {
                try await ciGateway.setMediaFavourite(mediaID: item.id, isFavourite: isFavourite)
            } catch is CancellationError {
            } catch {
                self?.updateLibraryItem(id: item.id, isFavourite: item.isFavourite)
                self?.lastErrorMessage = String(describing: error)
            }
        }
    }

    private enum LibraryError: Error, LocalizedError {
        case unavailable

        var errorDescription: String? {
            switch self {
            case .unavailable:
                "Qobuz library is unavailable"
            }
        }
    }

    private func applyUnavailableLibrary() {
        library = Library(availability: .unavailable)
        libraryContentRevision = nil
        libraryPageCache = [:]
    }

    private func buildLibrarySections(
        rootPage: LibraryPage,
        gateway: any LinnGateway
    ) async -> [LibrarySection] {
        var sections: [LibrarySection] = []
        var rootBrowseItems: [LibraryItem] = []

        for item in rootPage.items {
            let sectionKind = classifiedSectionKind(for: item)
            if sectionKind != .browse {
                if let section = await librarySection(
                    for: item,
                    kind: sectionKind,
                    gateway: gateway,
                    path: ["Qobuz", item.title]
                ) {
                    sections.append(section)
                }
                continue
            }

            if isPersonalLibraryFolder(item) {
                let personalSections = await personalLibrarySections(
                    for: item,
                    gateway: gateway,
                    path: ["Qobuz", item.title]
                )
                sections.append(contentsOf: personalSections)
                rootBrowseItems.append(item)
            } else {
                rootBrowseItems.append(item)
            }
        }

        if !rootBrowseItems.isEmpty {
            sections.insert(
                LibrarySection(
                    id: rootPage.id ?? "qobuz-root",
                    title: "Qobuz",
                    kind: .browse,
                    path: ["Qobuz"],
                    items: rootBrowseItems
                ),
                at: 0
            )
        }

        return sections
    }

    private func personalLibrarySections(
        for item: LibraryItem,
        gateway: any LinnGateway,
        path: [String]
    ) async -> [LibrarySection] {
        let items = await browseSectionItems(item, gateway: gateway)
        var sections: [LibrarySection] = []

        for child in items {
            if isFavouritesFolder(child) {
                let favouriteSections = await favouriteLibrarySections(
                    for: child,
                    gateway: gateway,
                    path: path + [child.title]
                )
                sections.append(contentsOf: favouriteSections)
                continue
            }

            let sectionKind = classifiedSectionKind(for: child)
            guard sectionKind != .browse else {
                continue
            }
            if let section = await librarySection(
                for: child,
                kind: sectionKind,
                gateway: gateway,
                path: path + [child.title]
            ) {
                sections.append(section)
            }
        }

        return sections
    }

    private func favouriteLibrarySections(
        for item: LibraryItem,
        gateway: any LinnGateway,
        path: [String]
    ) async -> [LibrarySection] {
        let items = await browseSectionItems(item, gateway: gateway)
        let sectionFolders = items.filter(isFavouriteSectionFolder)
        guard !sectionFolders.isEmpty else {
            return [
                LibrarySection(
                    id: item.id,
                    title: item.title,
                    kind: .favourites,
                    path: path,
                    source: item,
                    items: items
                ),
            ]
        }

        var sections: [LibrarySection] = []
        for sectionFolder in sectionFolders {
            if let section = await librarySection(
                for: sectionFolder,
                kind: .favourites,
                gateway: gateway,
                path: path + [sectionFolder.title]
            ) {
                sections.append(section)
            }
        }
        return sections
    }

    private func librarySection(
        for item: LibraryItem,
        kind: LibrarySection.Kind,
        gateway: any LinnGateway,
        path: [String]
    ) async -> LibrarySection? {
        let items = await browseSectionItems(item, gateway: gateway)
        guard !items.isEmpty else {
            return nil
        }

        return LibrarySection(
            id: item.id,
            title: item.title,
            kind: kind,
            path: path,
            source: item,
            items: items
        )
    }

    private func browseSectionItems(
        _ item: LibraryItem,
        gateway: any LinnGateway
    ) async -> [LibraryItem] {
        let page = try? await gateway.browseMedia(mediaID: item.id, index: 0, count: 50, browseType: "")
        let libraryPage = page.map(LibraryPage.init)
        if let libraryPage {
            reconcileLibraryRevision(libraryPage.contentRevision)
            cache(libraryPage, mediaID: item.id, browseType: "")
        }
        return libraryPage?.items ?? []
    }

    private func isPersonalLibraryFolder(_ item: LibraryItem) -> Bool {
        let title = item.title.lowercased()
        let kind = item.kind.lowercased()
        return kind.hasPrefix("md.qobuz")
            && (
                title == "my qobuz"
                    || title == "my music"
                    || title == "my library"
                    || title == "library"
            )
    }

    private func isFavouritesFolder(_ item: LibraryItem) -> Bool {
        let title = item.title.lowercased()
        return title == "favourites"
            || title == "favorites"
            || title == "liked"
    }

    private func isFavouriteSectionFolder(_ item: LibraryItem) -> Bool {
        let title = item.title.lowercased()
        return title == "album"
            || title == "albums"
            || title == "artist"
            || title == "artists"
            || title == "playlist"
            || title == "playlists"
    }

    private func classifiedSectionKind(for item: LibraryItem) -> LibrarySection.Kind {
        let title = item.title.lowercased()

        if title.contains("favourite") || title.contains("favorite") || title.contains("liked") {
            return .favourites
        }
        if title.contains("recommend") || title.contains("for you") {
            return .recommendations
        }
        if title.contains("playlist") {
            return .playlists
        }
        if title.contains("purchase") || title.contains("purchased") || title.contains("owned") {
            return .purchases
        }
        return .browse
    }

    private func reconcileLibraryRevision(_ contentRevision: Int?) {
        guard let contentRevision else {
            return
        }
        if let libraryContentRevision, libraryContentRevision != contentRevision {
            libraryPageCache = [:]
        }
        libraryContentRevision = contentRevision
    }

    private func cache(_ page: LibraryPage, mediaID: String, browseType: String) {
        libraryPageCache[LibraryCacheKey(mediaID: mediaID, browseType: browseType)] = page
    }

    private func updateLibraryItem(id: String, isFavourite: Bool?) {
        func updated(_ item: LibraryItem) -> LibraryItem {
            guard item.id == id else {
                return item
            }
            var item = item
            item.isFavourite = isFavourite
            return item
        }

        var updatedLibrary = library
        if var rootPage = updatedLibrary.rootPage {
            rootPage.items = rootPage.items.map(updated)
            updatedLibrary.rootPage = rootPage
        }
        updatedLibrary.sections = updatedLibrary.sections.map { section in
            var section = section
            section.source = section.source.map(updated)
            section.items = section.items.map(updated)
            return section
        }
        updatedLibrary.qobuz = Library.Qobuz(sections: updatedLibrary.sections)
        library = updatedLibrary
        libraryPageCache = libraryPageCache.mapValues { page in
            var page = page
            page.items = page.items.map(updated)
            return page
        }
    }

    private func apply(_ update: CiGateway.NowPlaying) {
        let suppressNowPlayingFields = shouldSuppressNowPlayingFields(incomingQueueIndex: update.queue?.index)

        playState = reconciledPlayState(incoming: PlayState(update.playback))
        playlist.total = update.queue?.length ?? playlist.total
        if let playlist = update.playlist {
            if let contentRevision = playlist.contentRevision, contentRevision != playlistContentRevision {
                playlistSongsByIndex = [:]
                playlistContentRevision = contentRevision
            }

            for item in playlist.items {
                playlistSongsByIndex[item.index] = Song(item)
            }
        }

        if !suppressNowPlayingFields {
            updateSongTransitionDirection(incomingQueueIndex: update.queue?.index)
            var incomingCurrentSong = Song(update.currentItem)
            if let incomingQueueIndex = update.queue?.index {
                incomingCurrentSong?.queueIndex = incomingQueueIndex
            }
            currentSong = incomingCurrentSong
            if let incomingQueueIndex = update.queue?.index, let incomingCurrentSong {
                playlistSongsByIndex[incomingQueueIndex] = incomingCurrentSong
            }
            playlist.currentIndex = update.queue?.index
            timeline = Timeline(update.timeline)
        }

        reconcilePlaylistSelectionConfirmation(incomingQueueIndex: update.queue?.index)
        updatePlaylistSongs()
        volume = update.roomState?.volume.map { min($0, maximumVolume) }
        isMuted = update.roomState?.isMuted
    }

    private func selectQueueIndex(
        _ targetQueueIndex: Int,
        optimisticSong: Song? = nil,
        kind: PlaylistSelectionJob.Kind
    ) {
        if targetQueueIndex < 0 {
            return
        }
        if let total = playlist.total, targetQueueIndex >= total {
            return
        }

        optimisticallySelectQueueIndex(targetQueueIndex, song: optimisticSong ?? playlistSongsByIndex[targetQueueIndex])
        enqueuePlaylistSelection(PlaylistSelectionJob(targetIndex: targetQueueIndex, kind: kind))
    }

    private func optimisticallySelectQueueIndex(_ targetQueueIndex: Int, song: Song?) {
        updateSongTransitionDirection(incomingQueueIndex: targetQueueIndex)
        optimisticTransition = OptimisticTransition(
            targetQueueIndex: targetQueueIndex,
            expiresAt: Date().addingTimeInterval(4)
        )

        guard var selectedSong = song else {
            currentSong = nil
            playlist.currentIndex = targetQueueIndex
            timeline = nil
            updatePlaylistSongs()
            return
        }

        selectedSong.queueIndex = targetQueueIndex
        playlistSongsByIndex[targetQueueIndex] = selectedSong
        currentSong = selectedSong
        playlist.currentIndex = targetQueueIndex
        timeline = nil
        updatePlaylistSongs()
    }

    private func enqueuePlaylistSelection(_ job: PlaylistSelectionJob) {
        lastErrorMessage = nil

        guard ciGateway != nil else {
            return
        }

        if let jobToSend = playlistSelectionQueue.enqueue(job) {
            sendPlaylistSelection(jobToSend)
        }
    }

    private func sendPlaylistSelection(_ job: PlaylistSelectionJob) {
        guard let ciGateway else {
            return
        }

        playlistSelectionTimeoutTask?.cancel()
        playlistSelectionTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            self?.playlistSelectionTimedOut(job)
        }

        playlistSelectionTask = Task { [ciGateway, room] in
            do {
                try await ciGateway.selectPlaylistItem(at: job.targetIndex, room: room)
            } catch is CancellationError {
            } catch {
                let failure = playlistSelectionQueue.fail(targetIndex: job.targetIndex)
                if failure.failed {
                    playlistSelectionTimeoutTask?.cancel()
                    lastErrorMessage = String(describing: error)
                }
                if let nextJob = failure.next {
                    sendPlaylistSelection(nextJob)
                }
            }
        }
    }

    private func reconcilePlaylistSelectionConfirmation(incomingQueueIndex: Int?) {
        guard let incomingQueueIndex else {
            return
        }

        let confirmation = playlistSelectionQueue.confirm(targetIndex: incomingQueueIndex)
        if confirmation.confirmed {
            playlistSelectionTimeoutTask?.cancel()
        }
        if let nextJob = confirmation.next {
            sendPlaylistSelection(nextJob)
        }
    }

    private func playlistSelectionTimedOut(_ job: PlaylistSelectionJob) {
        let failure = playlistSelectionQueue.fail(targetIndex: job.targetIndex)
        if let nextJob = failure.next {
            sendPlaylistSelection(nextJob)
        }
    }

    private func updateSongTransitionDirection(incomingQueueIndex: Int?) {
        guard let currentIndex = playlist.currentIndex, let incomingQueueIndex, currentIndex != incomingQueueIndex else {
            return
        }

        songTransitionDirection = incomingQueueIndex > currentIndex ? .forward : .backward
    }

    private func shouldSuppressNowPlayingFields(incomingQueueIndex: Int?) -> Bool {
        guard let optimisticTransition else {
            return false
        }

        if Date() >= optimisticTransition.expiresAt {
            self.optimisticTransition = nil
            return false
        }

        if incomingQueueIndex == optimisticTransition.targetQueueIndex {
            self.optimisticTransition = nil
            return false
        }

        return true
    }

    private func reconciledPlayState(incoming: PlayState?) -> PlayState? {
        guard let optimisticPlayState else {
            return incoming
        }

        if Date() >= optimisticPlayState.expiresAt {
            self.optimisticPlayState = nil
            return incoming
        }

        if incoming == optimisticPlayState.targetState {
            self.optimisticPlayState = nil
            return incoming
        }

        return optimisticPlayState.targetState
    }

    private func updatePlaylistSongs() {
        playlist.songs = playlistSongsByIndex
            .sorted { $0.key < $1.key }
            .map(\.value)
    }

    private func performControl(
        optimisticState: PlayState? = nil,
        operation: @escaping (any LinnGateway, String) async throws -> Void
    ) {
        let previousPlayState = playState
        if let optimisticState {
            optimisticPlayState = OptimisticPlayState(
                targetState: optimisticState,
                previousState: previousPlayState,
                expiresAt: Date().addingTimeInterval(4)
            )
            playState = optimisticState
        }
        lastErrorMessage = nil

        guard let ciGateway else {
            return
        }

        controlTask?.cancel()
        controlTask = Task { [ciGateway, room] in
            do {
                try await operation(ciGateway, room)
            } catch is CancellationError {
            } catch {
                if let optimisticState, self.optimisticPlayState?.targetState == optimisticState {
                    playState = self.optimisticPlayState?.previousState
                    self.optimisticPlayState = nil
                }
                lastErrorMessage = String(describing: error)
            }
        }
    }

    #if DEBUG
        private func installMockPlaylist(previousSongs: [Song], currentSong: Song?) {
            playlistSongsByIndex = [:]

            for (index, song) in previousSongs.reversed().enumerated() {
                var indexedSong = song
                indexedSong.queueIndex = index
                playlistSongsByIndex[index] = indexedSong
            }

            if var currentSong {
                let currentIndex = previousSongs.count
                currentSong.queueIndex = currentIndex
                self.currentSong = currentSong
                playlistSongsByIndex[currentIndex] = currentSong
                playlist.currentIndex = currentIndex
                playlist.total = currentIndex + 1
            }

            updatePlaylistSongs()
        }

        /// Preview/mock-only adapter from button availability flags to the internal queue shape.
        ///
        /// Production state comes from `CiGateway.NowPlaying.Queue`, where `hasPrevious`
        /// and `hasNext` are derived from the playlist current index and total. The debug mock
        /// initializer accepts direct booleans because previews usually care about the
        /// visible button states, not a realistic queue position.
        private func setQueueAvailability(hasPrevious: Bool, hasNext: Bool) {
            var currentIndex = playlist.currentIndex
            var total = playlist.total

            switch (hasPrevious, hasNext) {
            case (true, true):
                currentIndex = currentIndex ?? 1
                total = max(total ?? 0, (currentIndex ?? 1) + 2)
            case (true, false):
                currentIndex = currentIndex ?? 1
                total = max(total ?? 0, (currentIndex ?? 1) + 1)
            case (false, true):
                currentIndex = currentIndex ?? 0
                total = max(total ?? 0, (currentIndex ?? 0) + 2)
            case (false, false):
                if playlist.songs.isEmpty {
                    currentIndex = nil
                    total = nil
                } else {
                    currentIndex = currentIndex ?? 0
                    total = total ?? playlist.songs.count
                }
            }

            playlist.currentIndex = currentIndex
            playlist.total = total
        }
    #endif
}

extension CiGateway: LinnGateway {
    public func nowPlayingUpdates(
        room: String?,
        updateInterval: Int
    ) async -> AsyncThrowingStream<NowPlaying, Error> {
        nowPlayingEvents(room: room, updateInterval: updateInterval)
    }

    public func browseMedia(mediaID: String, index: Int, count: Int, browseType: String) async throws -> MediaPage {
        try await browse(mediaID: mediaID, index: index, count: count, browseType: browseType)
    }

    public func searchMedia(serviceID: String, query: String, type: MediaSearchType, index: Int, count: Int) async throws -> MediaPage {
        try await search(serviceID: serviceID, query: query, type: type, index: index, count: count)
    }

    public func selectMedia(mediaID: String, room: String, queue: QueuePlacement) async throws {
        try await select(mediaID: mediaID, room: room, queue: queue)
    }

    public func setMediaFavourite(mediaID: String, isFavourite: Bool) async throws {
        try await setFavourite(mediaID: mediaID, isFavourite: isFavourite)
    }
}

public extension Linn.PlayState {
    init?(_ playback: CiGateway.NowPlaying.Playback?) {
        guard let transportState = playback?.transportState else {
            return nil
        }

        switch transportState {
        case .play:
            self = .playing
        case .pause:
            self = .paused
        case .stop:
            self = .stopped
        case .buffering, .waiting:
            self = .buffering
        case .unknown:
            self = .stopped
        }
    }
}

public extension Linn.Song {
    init?(_ item: CiGateway.NowPlaying.CurrentItem?) {
        guard let item else {
            return nil
        }

        let title = item.track?.title ?? item.displayName
        guard let title, !title.isEmpty else {
            return nil
        }

        self.init(
            id: item.id,
            title: title,
            artist: item.track?.artist,
            album: item.track?.album,
            artworkURL: item.artworkURL
        )
    }

    init?(_ item: CiGateway.NowPlaying.PlaylistItem) {
        let title = item.displayName
        guard let title, !title.isEmpty else {
            return nil
        }

        self.init(
            id: "playlist-\(item.index)",
            title: title,
            artist: item.artist,
            album: item.album,
            duration: item.duration,
            artworkURL: item.artworkURL,
            queueIndex: item.index
        )
    }
}

public extension Linn.Timeline {
    init?(_ timeline: CiGateway.NowPlaying.Timeline?) {
        guard let timeline else {
            return nil
        }
        self.init(
            position: timeline.position,
            duration: timeline.duration,
            progress: timeline.progress
        )
    }
}

public extension Linn.LibraryService {
    init(_ service: CiGateway.MediaService) {
        self.init(id: service.id, name: service.name, kind: service.kind)
    }
}

public extension Linn.LibraryPage {
    init(_ page: CiGateway.MediaPage) {
        self.init(
            id: page.id,
            contentRevision: page.contentRevision,
            index: page.index,
            count: page.count,
            total: page.total,
            items: page.children.map(Linn.LibraryItem.init)
        )
    }
}

public extension Linn.LibraryItem {
    init(_ item: CiGateway.MediaItem) {
        let title = item.displayTitle?.isEmpty == false ? item.displayTitle! : item.id
        let subtitle = item.artists.isEmpty ? item.album : item.artists.joined(separator: ", ")
        self.init(
            id: item.id,
            kind: item.kind,
            title: title,
            subtitle: subtitle,
            album: item.album,
            artists: item.artists,
            artworkURL: item.artworkURL,
            duration: item.duration,
            containedKinds: item.containedKinds,
            childCount: item.childCount,
            isFavourite: item.isFavourite,
            canFavourite: item.canFavourite
        )
    }
}

public extension CiGateway.MediaSearchType {
    init(_ type: Linn.SearchType) {
        switch type {
        case .albums:
            self = .albums
        case .artists:
            self = .artists
        case .tracks:
            self = .tracks
        case .playlists:
            self = .playlists
        case .composers:
            self = .composers
        case .stations:
            self = .stations
        }
    }
}

public extension CiGateway.QueuePlacement {
    init(_ placement: Linn.QueuePlacement) {
        switch placement {
        case .now:
            self = .now
        case .next:
            self = .next
        case .last:
            self = .last
        case .replace:
            self = .replace
        }
    }
}

public extension Linn {
    struct Configuration: Sendable {
        public var ciGatewayWebSocketURL: URL

        public init(ciGatewayWebSocketURL: URL) {
            self.ciGatewayWebSocketURL = ciGatewayWebSocketURL
        }

        public static func local(
            fileURL: URL? = nil,
            environment: [String: String] = ProcessInfo.processInfo.environment,
            currentDirectoryURL: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        ) throws -> Self {
            let values = try DotEnv.load(fileURL: fileURL, currentDirectoryURL: currentDirectoryURL)
            let urlString = environment["LINN_CI_GATEWAY_WS_URL"] ?? values["LINN_CI_GATEWAY_WS_URL"]

            guard let urlString, !urlString.isEmpty else {
                throw ConfigurationError.missingValue("LINN_CI_GATEWAY_WS_URL")
            }
            guard let url = URL(string: urlString) else {
                throw ConfigurationError.invalidURL(urlString)
            }

            return Self(ciGatewayWebSocketURL: url)
        }
    }

    enum ConfigurationError: Error, Sendable {
        case missingValue(String)
        case invalidURL(String)
    }
}

private enum DotEnv {
    static func load(fileURL: URL?, currentDirectoryURL: URL) throws -> [String: String] {
        let url = try fileURL ?? discover(from: currentDirectoryURL)
        guard let url else {
            return [:]
        }

        let contents = try String(contentsOf: url, encoding: .utf8)
        return parse(contents)
    }

    private static func discover(from currentDirectoryURL: URL) throws -> URL? {
        let fileManager = FileManager.default
        let candidates = [
            Bundle.main.url(forResource: ".env", withExtension: nil),
            Bundle.main.bundleURL.appendingPathComponent(".env"),
            currentDirectoryURL.appendingPathComponent(".env"),
            currentDirectoryURL.appendingPathComponent("Louie/.env"),
            currentDirectoryURL.appendingPathComponent("Packages/Linn/.env"),
        ].compactMap(\.self)

        return candidates.first { fileManager.fileExists(atPath: $0.path) }
    }

    private static func parse(_ contents: String) -> [String: String] {
        contents
            .split(whereSeparator: \.isNewline)
            .reduce(into: [:]) { values, line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else {
                    return
                }
                let parts = trimmed.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2 else {
                    return
                }

                let key = parts[0].trimmingCharacters(in: .whitespaces)
                let value = parts[1].trimmingCharacters(in: .whitespaces)
                values[key] = unquote(value)
            }
    }

    private static func unquote(_ value: String) -> String {
        guard value.count >= 2 else {
            return value
        }

        if value.first == "\"", value.last == "\"" {
            return String(value.dropFirst().dropLast())
        }
        if value.first == "'", value.last == "'" {
            return String(value.dropFirst().dropLast())
        }
        return value
    }
}
