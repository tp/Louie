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
    public private(set) var pendingQueueIndex: Int?

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

    /// Number of songs left after the observed or pending queue selection.
    public var remainingQueueCount: Int {
        guard let total = playlist.total else {
            return upcomingSongs.count
        }

        let effectiveCurrentIndex = pendingQueueIndex ?? playlist.currentIndex
        guard let effectiveCurrentIndex else {
            return total
        }

        return max(0, total - effectiveCurrentIndex - 1)
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

        switch kind {
        case .skip:
            pendingQueueIndex = nil
            optimisticallySelectQueueIndex(targetQueueIndex, song: optimisticSong ?? playlistSongsByIndex[targetQueueIndex])
        case .queueItem:
            pendingQueueIndex = targetQueueIndex
        }
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
                    reconcilePendingQueueSelection(failedJob: job, nextJob: failure.next)
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

        if pendingQueueIndex == incomingQueueIndex {
            pendingQueueIndex = nil
        }

        let confirmation = playlistSelectionQueue.confirm(targetIndex: incomingQueueIndex)
        if confirmation.confirmed {
            playlistSelectionTimeoutTask?.cancel()
            reconcilePendingQueueSelection(confirmedQueueIndex: incomingQueueIndex, nextJob: confirmation.next)
        }
        if let nextJob = confirmation.next {
            sendPlaylistSelection(nextJob)
        }
    }

    private func playlistSelectionTimedOut(_ job: PlaylistSelectionJob) {
        let failure = playlistSelectionQueue.fail(targetIndex: job.targetIndex)
        if failure.failed {
            reconcilePendingQueueSelection(failedJob: job, nextJob: failure.next)
        }
        if let nextJob = failure.next {
            sendPlaylistSelection(nextJob)
        }
    }

    private func reconcilePendingQueueSelection(
        confirmedQueueIndex: Int,
        nextJob: PlaylistSelectionJob?
    ) {
        if let nextJob, nextJob.kind == .queueItem {
            pendingQueueIndex = nextJob.targetIndex
        } else if pendingQueueIndex == confirmedQueueIndex {
            pendingQueueIndex = nil
        }
    }

    private func reconcilePendingQueueSelection(
        failedJob: PlaylistSelectionJob,
        nextJob: PlaylistSelectionJob?
    ) {
        if let nextJob, nextJob.kind == .queueItem {
            pendingQueueIndex = nextJob.targetIndex
        } else if failedJob.kind == .queueItem, pendingQueueIndex == failedJob.targetIndex {
            pendingQueueIndex = nil
        }
    }

    private func updateSongTransitionDirection(incomingQueueIndex: Int?) {
        guard let currentIndex = playlist.currentIndex, let incomingQueueIndex, currentIndex != incomingQueueIndex else {
            return
        }

        songTransitionDirection = incomingQueueIndex > currentIndex ? .forward : .backward
    }

    private func shouldSuppressNowPlayingFields(incomingQueueIndex: Int?) -> Bool {
        reconcileOptimistic(
            &optimisticTransition,
            target: \.targetQueueIndex,
            expiresAt: \.expiresAt,
            incoming: incomingQueueIndex,
            matches: { $0 == $1 }
        ) != nil
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

    /// Holds an optimistic value (queue transition or play-state) until either:
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
