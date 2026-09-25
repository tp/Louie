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

    /// Queue row the user tapped that the device hasn't switched to yet.
    public var pendingQueueIndex: Int? {
        if case let .queueItem(targetIndex) = pendingPlayback {
            targetIndex
        } else {
            nil
        }
    }

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

    /// Number of songs left after the observed or pending queue selection,
    /// including library additions the device hasn't reported yet.
    public var remainingQueueCount: Int {
        let effectiveCurrentIndex = pendingQueueIndex ?? playlist.currentIndex
        if let pendingQueueLength {
            let currentIndex = pendingQueueLength.currentIndex ?? effectiveCurrentIndex ?? -1
            return max(0, pendingQueueLength.total - currentIndex - 1)
        }

        guard let total = playlist.total else {
            return upcomingSongs.count
        }

        guard let effectiveCurrentIndex else {
            return total
        }

        return max(0, total - effectiveCurrentIndex - 1)
    }

    private var ciGateway: (any LinnGateway)?
    private var configurationLoadAttempted = false
    private var playlistContentRevision: Int?
    private var playlistSongsByIndex: [Int: Song] = [:]
    private var pendingPlayback: PendingPlayback?
    private var isPreviewingMedia: Bool {
        if case .media = pendingPlayback {
            return true
        }
        return false
    }

    private var pendingQueueLength: PendingQueueLength?
    private var optimisticPlayState: OptimisticPlayState?
    private var optimisticVolume: OptimisticVolume?
    private var optimisticMute: OptimisticMute?
    @ObservationIgnored private var mediaSelectionGeneration = 0
    /// What the device itself last reported, regardless of any preview shown.
    @ObservationIgnored private var reportedSong: Song?
    @ObservationIgnored private var reportedTimeline: Timeline?
    private var playlistSelectionQueue = PlaylistSelectionQueue()
    private var libraryContentRevision: Int?
    private var libraryPageCache: [LibraryCacheKey: LibraryPage] = [:]
    private static let logger = Logger(subsystem: "Louie.Linn", category: "Linn")

    @ObservationIgnored private var updatesTask: Task<Void, Never>?
    @ObservationIgnored private var playlistSelectionTask: Task<Void, Never>?
    @ObservationIgnored private var playlistSelectionTimeoutTask: Task<Void, Never>?
    @ObservationIgnored private var libraryTask: Task<Void, Never>?

    /// What the user asked to play that the device hasn't picked up yet.
    /// Only one at a time: the latest request supersedes earlier ones.
    private enum PendingPlayback {
        /// Previous/next. Already shown as current; stale updates are ignored
        /// until the device reaches the index.
        case skip(targetIndex: Int, expiresAt: Date)
        /// A tapped queue row. Marked pending in the queue, not shown as
        /// current until the device confirms.
        case queueItem(targetIndex: Int)
        /// A library item started with play-now or replace. Shown as current
        /// while the device swaps its queue.
        case media(MediaSelection)
    }

    private struct MediaSelection {
        var generation: Int
        var preview: Song
        /// Title the device reports once it plays the selection, when known.
        /// Only needed when that's also the song being replaced.
        var expectedTitle: String?
        var replacedSong: Song?
        var supersededTitles: [String]
        var playlistRevision: Int?
        var expiresAt: Date
    }

    /// Queue length the device will report once library items it was just
    /// sent land, so the queue count responds right away.
    private struct PendingQueueLength {
        var total: Int
        /// Where the new queue starts playing, for a replace or play-now.
        /// Nil for additions, which count from wherever playback is.
        var currentIndex: Int?
        /// A replace can keep the old length; then only a new revision
        /// tells the swapped queue apart from the old one.
        var requiresNewRevision: Bool
        var revisionAtRequest: Int?
        var expiresAt: Date
    }

    private struct OptimisticPlayState {
        var targetState: PlayState
        var previousState: PlayState?
        var expiresAt: Date
    }

    private struct OptimisticVolume {
        var target: Int
        var expiresAt: Date
    }

    private struct OptimisticMute {
        var target: Bool
        var expiresAt: Date
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
        // A cancelled in-flight load would otherwise strand `.loading`, and the
        // next `loadLibrary()` bails out on that state — the library would
        // never load again without a manual refresh.
        if library.availability == .loading {
            library.availability = .unavailable
        }
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
        // Hold the optimistic value briefly so the 1s status cadence doesn't
        // snap a mid-drag knob back to a stale device reading.
        optimisticVolume = OptimisticVolume(
            target: clampedVolume,
            expiresAt: Date().addingTimeInterval(2.5)
        )
        performControl { ciGateway, room in
            try await ciGateway.setVolume(clampedVolume, room: room)
        }
    }

    public func setMuted(_ isMuted: Bool) {
        self.isMuted = isMuted
        optimisticMute = OptimisticMute(
            target: isMuted,
            expiresAt: Date().addingTimeInterval(2.5)
        )
        performControl { ciGateway, room in
            try await ciGateway.setMuted(isMuted, room: room)
        }
    }

    public func loadLibrary() {
        loadLibrary(force: false)
    }

    private func loadLibrary(force: Bool) {
        switch library.availability {
        case .loading:
            return
        case .available where !force:
            return
        case .available, .unavailable, .failed:
            break
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
                try Task.checkCancellation()
                guard let qobuzService = services.first(where: { $0.name.localizedCaseInsensitiveCompare("Qobuz") == .orderedSame }) else {
                    let availableServices = Self.availableMediaServicesDescription(services)
                    let message = "Qobuz media service is unavailable. Available media services: \(availableServices)."
                    Self.logger.error("\(message, privacy: .public)")
                    library = Library(availability: .failed(message))
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
                try Task.checkCancellation()
                library = Library(
                    availability: .available,
                    qobuzService: LibraryService(qobuzService),
                    rootPage: libraryRootPage,
                    sections: sections
                )
            } catch is CancellationError {
            } catch {
                // A cancelled task can also surface transport errors; don't
                // let a stale load stomp the state a newer load owns.
                guard !Task.isCancelled else {
                    return
                }
                let message = String(describing: error)
                Self.logger.error("Qobuz library load failed: \(message, privacy: .public)")
                library.availability = .failed(message)
            }
        }
    }

    public func refreshLibrary() {
        libraryContentRevision = nil
        libraryPageCache = [:]
        loadLibrary(force: true)
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

        let startsPlaying = placement == .replace || placement == .now
        let previewGeneration = startsPlaying ? previewMediaSelection(item) : nil
        if let trackCount = queuedTrackCount(for: item) {
            anticipateQueueLength(adding: trackCount, placement: placement)
        }

        performControl(onFailure: { [weak self] in
            self?.pendingQueueLength = nil
            if let previewGeneration {
                self?.revertMediaSelectionPreview(generation: previewGeneration)
            }
        }) { ciGateway, room in
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
        Task { [weak self, ciGateway] in
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

    private static func availableMediaServicesDescription(_ services: [CiGateway.MediaService]) -> String {
        guard !services.isEmpty else {
            return "none"
        }

        return services
            .map { service in
                if let kind = service.kind, !kind.isEmpty {
                    return "\(service.name) (\(kind))"
                }
                return service.name
            }
            .joined(separator: ", ")
    }

    private func buildLibrarySections(
        rootPage: LibraryPage,
        gateway: any LinnGateway
    ) async -> [LibrarySection] {
        var sections: [LibrarySection] = []
        var rootBrowseItems: [LibraryItem] = []

        for item in rootPage.items {
            let sectionKind = LibraryItemClassifier.sectionKind(for: item)
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

            if LibraryItemClassifier.isPersonalLibraryFolder(item) {
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
            if LibraryItemClassifier.isFavouritesFolder(child) {
                let favouriteSections = await favouriteLibrarySections(
                    for: child,
                    gateway: gateway,
                    path: path + [child.title]
                )
                sections.append(contentsOf: favouriteSections)
                continue
            }

            let sectionKind = LibraryItemClassifier.sectionKind(for: child)
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
        let sectionFolders = items.filter(LibraryItemClassifier.isFavouriteSectionFolder)
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

    private enum LibraryItemClassifier {
        static let personalLibraryTitles: Set<String> = ["my qobuz", "my music", "my library", "library"]
        static let favouritesTitles: Set<String> = ["favourites", "favorites", "liked"]
        static let favouriteSectionTitles: Set<String> = [
            "album", "albums", "artist", "artists", "playlist", "playlists",
        ]

        static func isPersonalLibraryFolder(_ item: LibraryItem) -> Bool {
            item.kind.lowercased().hasPrefix("md.qobuz")
                && personalLibraryTitles.contains(item.title.lowercased())
        }

        static func isFavouritesFolder(_ item: LibraryItem) -> Bool {
            favouritesTitles.contains(item.title.lowercased())
        }

        static func isFavouriteSectionFolder(_ item: LibraryItem) -> Bool {
            favouriteSectionTitles.contains(item.title.lowercased())
        }

        static func sectionKind(for item: LibraryItem) -> LibrarySection.Kind {
            let title = item.title.lowercased()
            if ["favourite", "favorite", "liked"].contains(where: title.contains) {
                return .favourites
            }
            if ["recommend", "for you"].contains(where: title.contains) {
                return .recommendations
            }
            if title.contains("playlist") {
                return .playlists
            }
            if ["purchase", "owned"].contains(where: title.contains) {
                return .purchases
            }
            return .browse
        }
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

        var incomingCurrentSong = Song(update.currentItem)
        if let incomingQueueIndex = update.queue?.index {
            incomingCurrentSong?.queueIndex = incomingQueueIndex
        }
        reportedSong = incomingCurrentSong
        reportedTimeline = Timeline(update.timeline)

        if !suppressNowPlayingFields {
            let wasPreviewingMedia = isPreviewingMedia
            // The queue position follows the device either way; only the
            // song shown as playing is held on the preview.
            if shouldHoldMediaSelectionPreview(incoming: incomingCurrentSong) {
                playlist.currentIndex = update.queue?.index
            } else {
                // The preview already moved forward; the new queue's index
                // says nothing about direction relative to the old one.
                if !wasPreviewingMedia {
                    updateSongTransitionDirection(incomingQueueIndex: update.queue?.index)
                }
                currentSong = incomingCurrentSong
                if let incomingQueueIndex = update.queue?.index, let incomingCurrentSong {
                    playlistSongsByIndex[incomingQueueIndex] = incomingCurrentSong
                }
                playlist.currentIndex = update.queue?.index
                timeline = reportedTimeline
            }
        }

        reconcilePlaylistSelectionConfirmation(incomingQueueIndex: update.queue?.index)
        reconcilePendingQueueLength()
        updatePlaylistSongs()
        let incomingVolume = update.roomState?.volume.map { min($0, maximumVolume) }
        volume = reconcileOptimistic(
            &optimisticVolume,
            target: \.target,
            expiresAt: \.expiresAt,
            incoming: incomingVolume,
            matches: { $0 == $1 }
        ) ?? incomingVolume
        let incomingMuted = update.roomState?.isMuted
        isMuted = reconcileOptimistic(
            &optimisticMute,
            target: \.target,
            expiresAt: \.expiresAt,
            incoming: incomingMuted,
            matches: { $0 == $1 }
        ) ?? incomingMuted
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

        switch kind {
        case .skip:
            optimisticallySelectQueueIndex(targetQueueIndex, song: optimisticSong ?? playlistSongsByIndex[targetQueueIndex])
        case .queueItem:
            pendingPlayback = .queueItem(targetIndex: targetQueueIndex)
        }
        enqueuePlaylistSelection(PlaylistSelectionJob(targetIndex: targetQueueIndex, kind: kind))
    }

    private func optimisticallySelectQueueIndex(_ targetQueueIndex: Int, song: Song?) {
        updateSongTransitionDirection(incomingQueueIndex: targetQueueIndex)
        pendingPlayback = .skip(targetIndex: targetQueueIndex, expiresAt: Date().addingTimeInterval(4))

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
            do {
                try await Task.sleep(for: .seconds(6))
            } catch {
                // Cancelled — the selection was confirmed or superseded. A
                // swallowed `try?` here would run the timeout body immediately.
                return
            }
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
                    clearPendingQueueItem(failedJob: job)
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

        // Reaching the tapped row confirms it — unless that row's own
        // selection is still waiting to be sent, and the device is just on
        // it from before.
        if case .queueItem(targetIndex: incomingQueueIndex) = pendingPlayback,
           playlistSelectionQueue.pending?.targetIndex != incomingQueueIndex {
            pendingPlayback = nil
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
        if failure.failed {
            clearPendingQueueItem(failedJob: job)
        }
        if let nextJob = failure.next {
            sendPlaylistSelection(nextJob)
        }
    }

    /// A newer request already replaced `pendingPlayback`, so only a still
    /// pending tap on the failed row is cleared.
    private func clearPendingQueueItem(failedJob: PlaylistSelectionJob) {
        if case .queueItem(targetIndex: failedJob.targetIndex) = pendingPlayback {
            pendingPlayback = nil
        }
    }

    private func updateSongTransitionDirection(incomingQueueIndex: Int?) {
        guard let currentIndex = playlist.currentIndex, let incomingQueueIndex, currentIndex != incomingQueueIndex else {
            return
        }

        songTransitionDirection = incomingQueueIndex > currentIndex ? .forward : .backward
    }

    /// Shows `item` as the current song right away. Returns the selection's
    /// generation, or nil when there's nothing meaningful to show.
    private func previewMediaSelection(_ item: LibraryItem) -> Int? {
        guard let preview = mediaSelectionPreview(for: item) else {
            return nil
        }

        // Songs from requests this one supersedes can still reach the device
        // (a skip already sent, an earlier start still loading); reporting
        // them doesn't mean the selection is playing.
        var supersededTitles: [String] = []
        switch pendingPlayback {
        case let .media(earlier):
            supersededTitles = earlier.supersededTitles + [earlier.preview.title]
            if let expectedTitle = earlier.expectedTitle {
                supersededTitles.append(expectedTitle)
            }
        case .skip, .queueItem, nil:
            break
        }
        let selectionTargets = [playlistSelectionQueue.inFlight, playlistSelectionQueue.pending]
            .compactMap { $0?.targetIndex }
        supersededTitles += selectionTargets.compactMap { playlistSongsByIndex[$0]?.title }
        // A queued skip or row tap would otherwise be sent into the new queue.
        playlistSelectionQueue.discardPending()

        mediaSelectionGeneration += 1
        pendingPlayback = .media(MediaSelection(
            generation: mediaSelectionGeneration,
            preview: preview.song,
            expectedTitle: preview.expectedTitle,
            replacedSong: reportedSong,
            supersededTitles: supersededTitles,
            playlistRevision: playlistContentRevision,
            expiresAt: Date().addingTimeInterval(8)
        ))
        songTransitionDirection = .forward
        currentSong = preview.song
        timeline = nil
        return mediaSelectionGeneration
    }

    private func mediaSelectionPreview(for item: LibraryItem) -> (song: Song, expectedTitle: String?)? {
        // Hey Louie starts media by id alone.
        guard !item.title.isEmpty else {
            return nil
        }

        guard item.isContainer else {
            return (Self.previewSong(item), item.title)
        }

        // An album or playlist starts at its first track. The detail screen
        // has usually browsed it already; otherwise show the container itself
        // until the device reports the track.
        let firstTrack = libraryPageCache[LibraryCacheKey(mediaID: item.id, browseType: "")]?
            .items.first { !$0.isContainer && !$0.title.isEmpty }
        if let firstTrack {
            return (Self.previewSong(firstTrack, container: item), firstTrack.title)
        }
        return (Self.previewSong(item), nil)
    }

    private static func previewSong(_ item: LibraryItem, container: LibraryItem? = nil) -> Song {
        let artists = item.artists.isEmpty ? container?.artists ?? [] : item.artists
        return Song(
            id: "preview|\(item.id)",
            title: item.title,
            artist: artists.isEmpty ? item.subtitle : artists.joined(separator: ", "),
            album: item.album ?? container?.title,
            duration: item.duration,
            artworkURL: item.artworkURL ?? container?.artworkURL
        )
    }

    /// Songs a library item adds to the queue, when that's known without
    /// asking the device: one for a track, the track list of an album or
    /// playlist that was browsed or reports its size.
    private func queuedTrackCount(for item: LibraryItem) -> Int? {
        if item.kind.contains("track") {
            return 1
        }
        guard item.isContainer else {
            return nil
        }

        if let page = libraryPageCache[LibraryCacheKey(mediaID: item.id, browseType: "")],
           !page.items.isEmpty,
           page.items.allSatisfy({ !$0.isContainer }) {
            return page.total ?? page.items.count
        }
        // Folder containers (e.g. favourite albums) count their albums, not tracks.
        let isTrackList = !item.kind.contains("container")
            && (item.kind.contains("album") || item.kind.contains("playlist"))
        if isTrackList, let childCount = item.childCount, childCount > 0 {
            return childCount
        }
        return nil
    }

    private func anticipateQueueLength(adding trackCount: Int, placement: QueuePlacement) {
        let expiresAt = Date().addingTimeInterval(6)
        guard placement != .replace else {
            pendingQueueLength = PendingQueueLength(
                total: trackCount,
                currentIndex: 0,
                requiresNewRevision: true,
                revisionAtRequest: playlistContentRevision,
                expiresAt: expiresAt
            )
            return
        }

        // Additions stack on anything still pending.
        let pending = pendingQueueLength
        var currentIndex = pending?.currentIndex
        if placement == .now {
            currentIndex = (currentIndex ?? pendingQueueIndex ?? playlist.currentIndex ?? -1) + 1
        }
        pendingQueueLength = PendingQueueLength(
            total: (pending?.total ?? playlist.total ?? 0) + trackCount,
            currentIndex: currentIndex,
            requiresNewRevision: pending?.requiresNewRevision ?? false,
            revisionAtRequest: pending?.revisionAtRequest ?? playlistContentRevision,
            expiresAt: expiresAt
        )
    }

    private func reconcilePendingQueueLength() {
        guard let pending = pendingQueueLength else {
            return
        }

        let landed = playlist.total == pending.total
            && (!pending.requiresNewRevision || playlistContentRevision != pending.revisionAtRequest)
        if landed || Date() >= pending.expiresAt {
            pendingQueueLength = nil
        }
    }

    private func revertMediaSelectionPreview(generation: Int) {
        guard case let .media(selection) = pendingPlayback, selection.generation == generation else {
            return
        }

        pendingPlayback = nil
        songTransitionDirection = .backward
        currentSong = reportedSong
        timeline = reportedTimeline
    }

    /// Keeps the preview while the device reports nothing (loading) or a song
    /// that isn't the selection yet. Until the queue revision changes, only
    /// the expected track counts as playing; after it, any song that isn't
    /// left over from before — or one the new queue confirms at its index,
    /// which covers restarting what was already playing.
    private func shouldHoldMediaSelectionPreview(incoming: Song?) -> Bool {
        guard case let .media(selection) = pendingPlayback else {
            return false
        }

        if Date() >= selection.expiresAt {
            pendingPlayback = nil
            return false
        }

        guard let incoming else {
            return true
        }

        func sameTitle(_ title: String) -> Bool {
            incoming.title.localizedCaseInsensitiveCompare(title) == .orderedSame
        }

        let isStale = selection.replacedSong.map { replaced in
            incoming.title == replaced.title && incoming.artist == replaced.artist
        } ?? false || selection.supersededTitles.contains(where: sameTitle)
        let isExpected = selection.expectedTitle.map(sameTitle) ?? false

        let released: Bool
        if selection.playlistRevision == nil {
            // No revisions from this gateway: the best signal is a new song.
            released = !isStale
        } else if playlistContentRevision == selection.playlistRevision {
            released = isExpected && !isStale
        } else {
            let matchesNewQueue = incoming.queueIndex
                .flatMap { playlistSongsByIndex[$0] }
                .map { sameTitle($0.title) } ?? false
            released = !isStale || isExpected || matchesNewQueue
        }

        if released {
            pendingPlayback = nil
        }
        return !released
    }

    /// After previous/next, ignores stale updates until the device reaches
    /// the target index or the skip expires.
    private func shouldSuppressNowPlayingFields(incomingQueueIndex: Int?) -> Bool {
        guard case let .skip(targetIndex, expiresAt) = pendingPlayback else {
            return false
        }

        if Date() >= expiresAt || incomingQueueIndex == targetIndex {
            pendingPlayback = nil
            return false
        }
        return true
    }

    private func reconciledPlayState(incoming: PlayState?) -> PlayState? {
        reconcileOptimistic(
            &optimisticPlayState,
            target: \.targetState,
            expiresAt: \.expiresAt,
            incoming: incoming,
            matches: { $0 == $1 }
        ) ?? incoming
    }

    /// Holds an optimistic value (play state, volume, mute) until either:
    /// the device reports a matching state (clear, accept it), the optimistic
    /// expires (clear, accept whatever just arrived), or neither (keep holding).
    /// Returns the target value while holding, otherwise nil.
    private func reconcileOptimistic<State, Target, Incoming>(
        _ state: inout State?,
        target: (State) -> Target,
        expiresAt: (State) -> Date,
        incoming: Incoming,
        matches: (Incoming, Target) -> Bool
    ) -> Target? {
        guard let current = state else {
            return nil
        }

        if Date() >= expiresAt(current) {
            state = nil
            return nil
        }

        if matches(incoming, target(current)) {
            state = nil
            return nil
        }

        return target(current)
    }

    private func updatePlaylistSongs() {
        // Content-based identity instead of the positional "playlist-<index>"
        // ids the gateway mapping produces. Positional ids make SwiftUI treat
        // a reorder as N in-place content swaps (wrong animations, broken
        // drag-to-reorder). Duplicate tracks get an occurrence ordinal, so
        // identity stays stable as long as their relative order holds.
        // Duration is deliberately excluded: playlist items carry it but
        // now-playing metadata doesn't, and the two sources must agree.
        var occurrences: [String: Int] = [:]
        playlist.songs = playlistSongsByIndex
            .sorted { $0.key < $1.key }
            .map { _, song in
                var song = song
                let base = "\(song.title)|\(song.artist ?? "")|\(song.album ?? "")"
                let ordinal = occurrences[base, default: 0]
                occurrences[base] = ordinal + 1
                song.id = ordinal == 0 ? "song|\(base)" : "song|\(base)|\(ordinal)"
                return song
            }
    }

    private func performControl(
        optimisticState: PlayState? = nil,
        onFailure: (@MainActor () -> Void)? = nil,
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

        // Commands run independently: play/pause, media selection, volume, and
        // favourites must not cancel each other. (Rapid Enqueue-then-pause used
        // to silently drop the enqueue.) Each command is short-lived — the
        // gateway acks or times out within seconds.
        Task { [weak self, ciGateway, room] in
            do {
                try await operation(ciGateway, room)
            } catch is CancellationError {
            } catch {
                guard let self else {
                    return
                }
                if let optimisticState, self.optimisticPlayState?.targetState == optimisticState {
                    self.playState = self.optimisticPlayState?.previousState
                    self.optimisticPlayState = nil
                }
                onFailure?()
                self.lastErrorMessage = String(describing: error)
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
