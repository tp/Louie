import Foundation
import Observation
import OSLog

public protocol LinnGateway: Sendable {
    func nowPlayingUpdates(
        room: String?,
        updateInterval: Int
    ) async -> AsyncThrowingStream<Linn.Snapshot, Error>

    func play(room: String) async throws
    func pause(room: String) async throws
    func previous(room: String) async throws
    func next(room: String) async throws
    func selectPlaylistItem(at index: Int, room: String) async throws
    func setVolume(_ volume: Int, room: String, group: Bool) async throws
    func setMuted(_ isMuted: Bool, room: String, group: Bool) async throws
    func mediaServices(room: String) async throws -> [Linn.LibraryService]
    func browseMedia(mediaID: String, index: Int, count: Int, browseType: String) async throws -> Linn.LibraryPage
    func searchMedia(serviceID: String, query: String, type: Linn.SearchType, index: Int, count: Int) async throws -> Linn.LibraryPage
    func selectMedia(mediaID: String, room: String, queue: Linn.QueuePlacement) async throws
    func selectMedia(mediaID: String, room: String, queue: Linn.QueuePlacement, preview: Linn.LibraryItem?) async throws
    func setMediaFavourite(mediaID: String, isFavourite: Bool) async throws
}

public extension LinnGateway {
    func selectMedia(mediaID: String, room: String, queue: Linn.QueuePlacement, preview: Linn.LibraryItem?) async throws {
        try await selectMedia(mediaID: mediaID, room: room, queue: queue)
    }

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
    public private(set) var maximumVolume: Int
    public private(set) var connectionState: ConnectionState = .idle
    public private(set) var library = Library()
    public private(set) var currentSong: Song?
    public private(set) var playlist = Playlist()
    public private(set) var playState: PlayState?
    public private(set) var volume: Int?
    public private(set) var isMuted: Bool?
    public private(set) var isStandby = false
    public var canControlPlayback: Bool { connectionState == .connected && !isStandby }
    public private(set) var timeline: Timeline?
    public private(set) var lastErrorMessage: String?
    public private(set) var songTransitionDirection: SongTransitionDirection = .forward

    /// Queue row the user tapped that the device hasn't switched to yet.
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
        guard canControlPlayback else { return false }
        guard let currentIndex = playlist.currentIndex else {
            return false
        }
        return currentIndex > 0
    }

    public var hasNext: Bool {
        guard canControlPlayback else { return false }
        guard let currentIndex = playlist.currentIndex, let total = playlist.total else {
            return false
        }
        return currentIndex + 1 < total
    }

    /// Number of songs left in the server's current queue projection.
    public var remainingQueueCount: Int {
        guard let total = playlist.total else {
            return upcomingSongs.count
        }
        guard let currentIndex = playlist.currentIndex else {
            return total
        }
        return max(0, total - currentIndex - 1)
    }

    private var linnGateway: (any LinnGateway)?
    private var configurationLoadAttempted = false
    private var pendingQueueExpiresAt: Date?
    private var optimisticVolume: OptimisticVolume?
    private var optimisticMute: OptimisticMute?
    private var libraryContentRevision: Int?
    private var libraryPageCache: [LibraryCacheKey: LibraryPage] = [:]
    private static let logger = Logger(subsystem: "Louie.Linn", category: "Linn")

    @ObservationIgnored private var updatesTask: Task<Void, Never>?
    @ObservationIgnored private var libraryTask: Task<Void, Never>?

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
        linnGateway = PiLinnGateway(serverURL: configuration.serverURL)
        configurationLoadAttempted = true
    }

    public init(
        gateway: any LinnGateway,
        room: String = "Linn",
        maximumVolume: Int = 70
    ) {
        self.room = room
        self.maximumVolume = maximumVolume
        linnGateway = gateway
        configurationLoadAttempted = true
    }

    public init(
        room: String = "Linn",
        maximumVolume: Int = 70
    ) {
        self.room = room
        self.maximumVolume = maximumVolume
        linnGateway = nil
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
            linnGateway = nil
            configurationLoadAttempted = true
            setQueueAvailability(hasPrevious: hasPrevious, hasNext: hasNext)
        }
    #endif

    deinit {
        updatesTask?.cancel()
        libraryTask?.cancel()
    }

    public func start() {
        if linnGateway == nil, !configurationLoadAttempted {
            configurationLoadAttempted = true
            do {
                let configuration = try Configuration.local()
                Self.logger.info("Loaded Louie server URL \(configuration.serverURL.absoluteString, privacy: .public)")
                linnGateway = PiLinnGateway(serverURL: configuration.serverURL)
            } catch {
                let message = error.localizedDescription
                Self.logger.error("Failed to load Linn configuration: \(message, privacy: .public)")
                lastErrorMessage = message
                connectionState = .failed(message)
                return
            }
        }

        guard let linnGateway else {
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
            var loadLibraryOnConnection = linnGateway is PiLinnGateway

            do {
                let updates = await linnGateway.nowPlayingUpdates(room: requestedRoom, updateInterval: 1)
                for try await update in updates {
                    guard update.connectionState == .connected else {
                        connectionState = update.connectionState
                        loadLibraryOnConnection = true
                        continue
                    }
                    apply(update)
                    connectionState = .connected
                    if loadLibraryOnConnection {
                        loadLibraryOnConnection = false
                        loadLibrary()
                    }
                }
            } catch is CancellationError {
                Self.logger.info("Linn now-playing update task cancelled")
                connectionState = .idle
            } catch {
                let message = error.localizedDescription
                Self.logger.error("Linn now-playing update task failed: \(message, privacy: .public)")
                lastErrorMessage = message
                connectionState = .failed(message)
            }
        }

        if !(linnGateway is PiLinnGateway) {
            loadLibrary()
        }
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
        guard linnGateway != nil else {
            return
        }
        connectionState = .idle
    }

    public func play() {
        performControl { linnGateway, room in
            try await linnGateway.play(room: room)
        }
    }

    public func pause() {
        performControl { linnGateway, room in
            try await linnGateway.pause(room: room)
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
        guard hasPrevious else {
            return
        }
        performControl { linnGateway, room in
            try await linnGateway.previous(room: room)
        }
    }

    public func next() {
        guard hasNext else {
            return
        }
        performControl { linnGateway, room in
            try await linnGateway.next(room: room)
        }
    }

    public func play(_ song: Song) {
        guard let targetQueueIndex = song.queueIndex else {
            return
        }

        pendingQueueIndex = targetQueueIndex
        pendingQueueExpiresAt = Date().addingTimeInterval(6)
        performControl(onFailure: { [weak self] in
            if self?.pendingQueueIndex == targetQueueIndex {
                self?.pendingQueueIndex = nil
                self?.pendingQueueExpiresAt = nil
            }
        }) { linnGateway, room in
            try await linnGateway.selectPlaylistItem(at: targetQueueIndex, room: room)
        }
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
        performControl { linnGateway, room in
            try await linnGateway.setVolume(clampedVolume, room: room, group: false)
        }
    }

    public func setMuted(_ isMuted: Bool) {
        self.isMuted = isMuted
        optimisticMute = OptimisticMute(
            target: isMuted,
            expiresAt: Date().addingTimeInterval(2.5)
        )
        performControl { linnGateway, room in
            try await linnGateway.setMuted(isMuted, room: room, group: false)
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

        guard let linnGateway else {
            library = Library(availability: .unavailable)
            libraryContentRevision = nil
            libraryPageCache = [:]
            return
        }

        library.availability = .loading
        libraryTask = Task { [weak self, linnGateway, room] in
            guard let self else {
                return
            }

            do {
                let services = try await linnGateway.mediaServices(room: room)
                try Task.checkCancellation()
                guard let qobuzService = services.first(where: { $0.name.localizedCaseInsensitiveCompare("Qobuz") == .orderedSame }) else {
                    let availableServices = Self.availableMediaServicesDescription(services)
                    let message = "Qobuz media service is unavailable. Available media services: \(availableServices)."
                    Self.logger.error("\(message, privacy: .public)")
                    library = Library(availability: .failed(message))
                    return
                }

                let rootPage = try await linnGateway.browseMedia(
                    mediaID: qobuzService.id,
                    index: 0,
                    count: 50,
                    browseType: ""
                )
                let libraryRootPage = rootPage
                reconcileLibraryRevision(libraryRootPage.contentRevision)
                cache(libraryRootPage, mediaID: qobuzService.id, browseType: "")

                let sections = await buildLibrarySections(
                    rootPage: libraryRootPage,
                    gateway: linnGateway
                )
                try Task.checkCancellation()
                library = Library(
                    availability: .available,
                    qobuzService: qobuzService,
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
                let message = error.localizedDescription
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

        guard let linnGateway else {
            throw LibraryError.unavailable
        }

        let page = try await linnGateway.browseMedia(mediaID: item.id, index: index, count: count, browseType: browseType)
        let libraryPage = page
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
        guard let linnGateway, let serviceID = library.qobuzService?.id else {
            throw LibraryError.unavailable
        }

        let page = try await linnGateway.searchMedia(
            serviceID: serviceID,
            query: trimmedQuery,
            type: type,
            index: index,
            count: count
        )
        return page
    }

    public func play(_ item: LibraryItem, placement: QueuePlacement = .replace) {
        guard linnGateway != nil else {
            return
        }
        let serverPreview = mediaSelectionServerPreview(for: item)
        performControl { linnGateway, room in
            try await linnGateway.selectMedia(
                mediaID: item.id,
                room: room,
                queue: placement,
                preview: serverPreview
            )
        }
    }

    private func mediaSelectionServerPreview(for item: LibraryItem) -> LibraryItem? {
        guard !item.title.isEmpty else { return nil }
        var preview = item
        if item.isContainer {
            // Preserve the container type for the server's queue count logic.
            // The server can use its first-track cache for the song preview.
            preview.childCount = queuedTrackCount(for: item)
        }
        return preview
    }

    public func setFavourite(_ item: LibraryItem, isFavourite: Bool) {
        guard item.canFavourite, item.isFavourite != nil, let linnGateway else {
            return
        }

        updateLibraryItem(id: item.id, isFavourite: isFavourite)
        Task { [weak self, linnGateway] in
            do {
                try await linnGateway.setMediaFavourite(mediaID: item.id, isFavourite: isFavourite)
            } catch is CancellationError {
            } catch {
                self?.updateLibraryItem(id: item.id, isFavourite: item.isFavourite)
                self?.lastErrorMessage = error.localizedDescription
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

    private static func availableMediaServicesDescription(_ services: [LibraryService]) -> String {
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
        let libraryPage = page
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

    private func apply(_ update: Linn.Snapshot) {
        isStandby = update.isStandby
        if isStandby {
            pendingQueueIndex = nil
            pendingQueueExpiresAt = nil
            optimisticVolume = nil
            optimisticMute = nil
        }
        playState = update.playState
        if update.pending.queueTotal && update.pending.currentItem {
            // A new queue starts at its first row even when its index is
            // numerically lower than the old queue's playing row.
            songTransitionDirection = .forward
        } else {
            updateSongTransitionDirection(incomingQueueIndex: update.playlist.currentIndex)
        }
        currentSong = update.currentSong
        playlist = update.playlist
        timeline = update.timeline
        if let pendingQueueIndex,
           (pendingQueueExpiresAt.map({ Date() >= $0 }) ?? true
            || (!update.pending.queueIndex && update.playlist.currentIndex == pendingQueueIndex)) {
            self.pendingQueueIndex = nil
            pendingQueueExpiresAt = nil
        }
        assignStableQueueSongIDs()
        if let serverMaximum = update.maximumVolume, serverMaximum > 0 {
            maximumVolume = serverMaximum
        }
        let incomingVolume = update.volume.map { min($0, maximumVolume) }
        volume = reconcileOptimistic(
            &optimisticVolume,
            target: \.target,
            expiresAt: \.expiresAt,
            incoming: incomingVolume,
            confirmed: !update.pending.volume,
            matches: { $0 == $1 }
        ) ?? incomingVolume
        let incomingMuted = update.isMuted
        isMuted = reconcileOptimistic(
            &optimisticMute,
            target: \.target,
            expiresAt: \.expiresAt,
            incoming: incomingMuted,
            confirmed: !update.pending.mute,
            matches: { $0 == $1 }
        ) ?? incomingMuted
    }

    private func updateSongTransitionDirection(incomingQueueIndex: Int?) {
        guard let currentIndex = playlist.currentIndex, let incomingQueueIndex, currentIndex != incomingQueueIndex else {
            return
        }

        songTransitionDirection = incomingQueueIndex > currentIndex ? .forward : .backward
    }

    /// Passes a known track count to the server for its queue prediction.
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

    /// Holds a local control value (volume or mute) until either:
    /// the device reports a matching state (clear, accept it), the optimistic
    /// expires (clear, accept whatever just arrived), or neither (keep holding).
    /// Returns the target value while holding, otherwise nil.
    private func reconcileOptimistic<State, Target, Incoming>(
        _ state: inout State?,
        target: (State) -> Target,
        expiresAt: (State) -> Date,
        incoming: Incoming,
        confirmed: Bool = true,
        matches: (Incoming, Target) -> Bool
    ) -> Target? {
        guard let current = state else {
            return nil
        }

        if Date() >= expiresAt(current) {
            state = nil
            return nil
        }

        if confirmed && matches(incoming, target(current)) {
            state = nil
            return nil
        }

        return target(current)
    }

    private func assignStableQueueSongIDs() {
        // Content-based identity instead of the positional "playlist-<index>"
        // ids the gateway mapping produces. Positional ids make SwiftUI treat
        // a reorder as N in-place content swaps (wrong animations, broken
        // drag-to-reorder). Duplicate tracks get an occurrence ordinal, so
        // identity stays stable as long as their relative order holds.
        // Metadata enrichment (such as a newly available duration) must not
        // change row identity.
        var occurrences: [String: Int] = [:]
        playlist.songs = playlist.songs
            .sorted { ($0.queueIndex ?? 0) < ($1.queueIndex ?? 0) }
            .map { song in
                var song = song
                let base = "\(song.title)|\(song.artist ?? "")|\(song.album ?? "")"
                let ordinal = occurrences[base, default: 0]
                occurrences[base] = ordinal + 1
                song.id = ordinal == 0 ? "song|\(base)" : "song|\(base)|\(ordinal)"
                return song
            }
    }

    private func performControl(
        onFailure: (@MainActor () -> Void)? = nil,
        operation: @escaping (any LinnGateway, String) async throws -> Void
    ) {
        lastErrorMessage = nil

        guard let linnGateway else {
            return
        }

        // Commands run independently: play/pause, media selection, volume, and
        // favourites must not cancel each other. (Rapid Enqueue-then-pause used
        // to silently drop the enqueue.) Each command is short-lived — the
        // gateway acks or times out within seconds.
        Task { [weak self, linnGateway, room] in
            do {
                try await operation(linnGateway, room)
            } catch is CancellationError {
                onFailure?()
            } catch {
                guard let self else {
                    return
                }
                if let serverError = error as? PiLinnRPCError, serverError.reason == .linnRejected {
                    Self.logger.error("Linn rejected command: \(serverError.message, privacy: .private)")
                }
                onFailure?()
                self.lastErrorMessage = error.localizedDescription
            }
        }
    }

    #if DEBUG
        private func installMockPlaylist(previousSongs: [Song], currentSong: Song?) {
            playlist.songs = []

            for (index, song) in previousSongs.reversed().enumerated() {
                var indexedSong = song
                indexedSong.queueIndex = index
                playlist.songs.append(indexedSong)
            }

            if var currentSong {
                let currentIndex = previousSongs.count
                currentSong.queueIndex = currentIndex
                self.currentSong = currentSong
                playlist.songs.append(currentSong)
                playlist.currentIndex = currentIndex
                playlist.total = currentIndex + 1
            }

            assignStableQueueSongIDs()
        }

        /// Preview/mock-only adapter from button availability flags to the internal queue shape.
        ///
        /// Production state comes from `Linn.Playlist`, where `hasPrevious`
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
