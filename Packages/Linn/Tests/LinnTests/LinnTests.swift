import Foundation
@testable import Linn
import LinnCiGateway
import Testing

@Test
@MainActor
func nextUsesForwardDirectionAndSuppressesStaleNowPlayingFields() async throws {
    let gateway = TestGateway()
    let linn = Linn(gateway: gateway)
    let titles = ["Zero", "One", "Two"]

    linn.start()
    await gateway.send(nowPlaying(index: 1, titles: titles, volume: 10))
    try await waitUntil {
        linn.currentSong?.title == "One"
    }

    linn.next()

    #expect(linn.songTransitionDirection == .forward)
    #expect(linn.currentSong?.title == "Two")
    #expect(linn.timeline == nil)

    await gateway.send(nowPlaying(index: 1, titles: titles, volume: 11))
    try await waitUntil {
        linn.volume == 11
    }

    #expect(linn.currentSong?.title == "Two")
    #expect(linn.timeline == nil)

    await gateway.send(nowPlaying(index: 2, titles: titles, position: 9, volume: 12))
    try await waitUntil {
        linn.volume == 12
    }

    #expect(linn.currentSong?.title == "Two")
    #expect(linn.timeline?.position == 9)
    #expect(await gateway.selectedPlaylistIndexes() == [2])
    #expect(await gateway.nextCallCount() == 0)
}

@Test
@MainActor
func previousUsesBackwardDirectionAndSuppressesStaleNowPlayingFields() async throws {
    let gateway = TestGateway()
    let linn = Linn(gateway: gateway)
    let titles = ["Zero", "One", "Two"]

    linn.start()
    await gateway.send(nowPlaying(index: 1, titles: titles, volume: 10))
    try await waitUntil {
        linn.currentSong?.title == "One"
    }

    linn.previous()

    #expect(linn.songTransitionDirection == .backward)
    #expect(linn.currentSong?.title == "Zero")
    #expect(linn.timeline == nil)

    await gateway.send(nowPlaying(index: 1, titles: titles, volume: 11))
    try await waitUntil {
        linn.volume == 11
    }

    #expect(linn.currentSong?.title == "Zero")
    #expect(linn.timeline == nil)

    await gateway.send(nowPlaying(index: 0, titles: titles, position: 7, volume: 12))
    try await waitUntil {
        linn.volume == 12
    }

    #expect(linn.currentSong?.title == "Zero")
    #expect(linn.timeline?.position == 7)
    #expect(await gateway.selectedPlaylistIndexes() == [0])
    #expect(await gateway.previousCallCount() == 0)
}

@Test
@MainActor
func previousCanUseCurrentSongCachedFromEarlierUpdates() async throws {
    let gateway = TestGateway()
    let linn = Linn(gateway: gateway)
    let titles = ["Zero", "One", "Two"]

    linn.start()
    await gateway.send(nowPlaying(index: 0, titles: titles, playlistIndexes: [1, 2]))
    try await waitUntil {
        linn.currentSong?.title == "Zero"
    }

    linn.next()
    #expect(linn.currentSong?.title == "One")

    await gateway.send(nowPlaying(index: 1, titles: titles, playlistIndexes: [2]))
    try await waitUntil {
        linn.timeline?.position == 1
    }

    #expect(linn.playlist.songs.map(\.title) == ["Zero", "One", "Two"])
    #expect(linn.playlist.currentIndex == 1)

    linn.previous()

    #expect(linn.songTransitionDirection == .backward)
    #expect(linn.currentSong?.title == "Zero")
}

@Test
@MainActor
func streamQueueIndexMovementUpdatesSongTransitionDirection() async throws {
    let gateway = TestGateway()
    let linn = Linn(gateway: gateway)
    let titles = ["Zero", "One", "Two"]

    linn.start()
    await gateway.send(nowPlaying(index: 1, titles: titles))
    try await waitUntil {
        linn.currentSong?.title == "One"
    }

    await gateway.send(nowPlaying(index: 2, titles: titles))
    try await waitUntil {
        linn.currentSong?.title == "Two"
    }

    #expect(linn.songTransitionDirection == .forward)

    await gateway.send(nowPlaying(index: 1, titles: titles))
    try await waitUntil {
        linn.currentSong?.title == "One"
    }

    #expect(linn.songTransitionDirection == .backward)
}

@Test
@MainActor
func playSongSelectsPlaylistItemByQueueIndex() async throws {
    let gateway = TestGateway()
    let linn = Linn(gateway: gateway)
    let titles = ["Zero", "One", "Two", "Three"]

    linn.start()
    await gateway.send(nowPlaying(index: 0, titles: titles))
    try await waitUntil {
        linn.playlist.songs.count == 4
    }

    let song = try #require(linn.playlist.songs.first { $0.title == "Three" })
    #expect(song.queueIndex == 3)

    linn.play(song)

    #expect(linn.currentSong?.title == "Zero")
    #expect(linn.playlist.currentIndex == 0)
    #expect(linn.pendingQueueIndex == 3)
    #expect(linn.timeline?.position == 1)

    try await waitUntil {
        await gateway.selectedPlaylistIndexes() == [3]
    }

    await gateway.send(nowPlaying(index: 3, titles: titles, position: 11))
    try await waitUntil {
        linn.pendingQueueIndex == nil
    }

    #expect(linn.currentSong?.title == "Three")
    #expect(linn.playlist.currentIndex == 3)
    #expect(linn.timeline?.position == 11)
}

@Test
@MainActor
func playlistTracksDeviceCurrentIndexAndKeepsPreviousItems() async throws {
    let gateway = TestGateway()
    let linn = Linn(gateway: gateway)
    let titles = ["Zero", "One", "Two", "Three"]

    linn.start()
    await gateway.send(nowPlaying(index: 2, titles: titles))
    try await waitUntil {
        linn.playlist.currentIndex == 2
    }

    #expect(linn.playlist.total == 4)
    #expect(linn.playlist.songs.map(\.title) == titles)
    #expect(linn.previousSongs.map(\.title) == ["One", "Zero"])
    #expect(linn.upcomingSongs.map(\.title) == ["Three"])
    #expect(linn.remainingQueueCount == 1)
}

@Test
@MainActor
func rapidPlaylistSelectionsSendOnlyFirstAndLatestPendingTarget() async throws {
    let gateway = TestGateway()
    let linn = Linn(gateway: gateway)
    let titles = ["Zero", "One", "Two", "Three"]

    await gateway.suspendSelections()
    linn.start()
    await gateway.send(nowPlaying(index: 0, titles: titles))
    try await waitUntil {
        linn.currentSong?.title == "Zero"
    }

    linn.next()
    linn.next()
    linn.next()

    try await waitUntil {
        await gateway.selectedPlaylistIndexes() == [1]
    }

    await gateway.send(nowPlaying(index: 1, titles: titles))
    try await waitUntil {
        await gateway.selectedPlaylistIndexes() == [1, 3]
    }

    await gateway.resumeSelections()
}

@Test
@MainActor
func rapidQueueItemSelectionsShowLatestPendingTarget() async throws {
    let gateway = TestGateway()
    let linn = Linn(gateway: gateway)
    let titles = ["Zero", "One", "Two", "Three"]

    linn.start()
    await gateway.send(nowPlaying(index: 0, titles: titles))
    try await waitUntil {
        linn.playlist.songs.count == 4
    }

    let one = try #require(linn.playlist.songs.first { $0.title == "One" })
    let three = try #require(linn.playlist.songs.first { $0.title == "Three" })

    linn.play(one)
    linn.play(three)

    #expect(linn.currentSong?.title == "Zero")
    #expect(linn.pendingQueueIndex == 3)
    #expect(linn.remainingQueueCount == 0)

    try await waitUntil {
        await gateway.selectedPlaylistIndexes() == [1]
    }

    await gateway.send(nowPlaying(index: 1, titles: titles))
    try await waitUntil {
        await gateway.selectedPlaylistIndexes() == [1, 3]
    }

    #expect(linn.pendingQueueIndex == 3)

    await gateway.send(nowPlaying(index: 3, titles: titles))
    try await waitUntil {
        linn.pendingQueueIndex == nil
    }

    #expect(linn.currentSong?.title == "Three")
}

@Test
@MainActor
func remainingQueueCountTracksOptimisticSkipPosition() async throws {
    let gateway = TestGateway()
    let linn = Linn(gateway: gateway)
    let titles = ["Zero", "One", "Two", "Three"]

    linn.start()
    await gateway.send(nowPlaying(index: 0, titles: titles))
    try await waitUntil {
        linn.remainingQueueCount == 3
    }

    linn.next()

    #expect(linn.playlist.currentIndex == 1)
    #expect(linn.remainingQueueCount == 2)
}

@Test
@MainActor
func libraryDiscoversQobuzAndUsesCachedBrowsedSections() async throws {
    let gateway = TestGateway()
    await gateway.seedQobuzLibrary(contentRevision: 1)
    let linn = Linn(gateway: gateway)

    linn.loadLibrary()
    try await waitUntil {
        linn.library.availability == .available
    }

    #expect(linn.library.qobuzService?.name == "Qobuz")
    #expect(await gateway.browseCallCount(mediaID: "service-qobuz") == 1)
    #expect(await gateway.browseCallCount(mediaID: "qobuz-myqobuz") == 1)
    #expect(await gateway.browseCallCount(mediaID: "qobuz-favourites") == 1)
    #expect(await gateway.browseCallCount(mediaID: "qobuz-favourite-albums") == 1)
    #expect(await gateway.browseCallCount(mediaID: "qobuz-discover") == 0)
    #expect(await gateway.browseCallCount(mediaID: "qobuz-genres") == 0)
    #expect(await gateway.browseCallCount(mediaID: "qobuz-album-happy-christmas") == 0)

    #expect(linn.library.qobuz.discover?.title == "Discover")
    #expect(linn.library.qobuz.genres?.title == "Genres")
    #expect(linn.library.qobuz.myQobuz?.title == "My Qobuz")
    let favourites = try #require(linn.library.qobuz.favouriteAlbums)
    let source = try #require(favourites.source)
    #expect(favourites.items.map(\.title) == [
        "Happy Christmas",
        "Shostakovich: Complete String Quartets, Vol. 2, Nos. 6-12",
    ])

    let browseCountAfterLoad = await gateway.browseCallCount(mediaID: source.id)
    let favouritesPage = try await linn.browse(source)
    #expect(favouritesPage.items.map(\.title) == [
        "Happy Christmas",
        "Shostakovich: Complete String Quartets, Vol. 2, Nos. 6-12",
    ])

    #expect(await gateway.browseCallCount(mediaID: source.id) == browseCountAfterLoad)
}

@Test
@MainActor
func qobuzRootFoldersExposeSectionsWithoutBrowsingMediaItems() async throws {
    let gateway = TestGateway()
    await gateway.seedNestedQobuzLibrary(contentRevision: 1)
    let linn = Linn(gateway: gateway)

    linn.loadLibrary()
    try await waitUntil {
        linn.library.availability == .available
    }

    #expect(await gateway.browseCallCount(mediaID: "service-qobuz") == 1)
    #expect(await gateway.browseCallCount(mediaID: "qobuz-myqobuz") == 1)
    #expect(await gateway.browseCallCount(mediaID: "qobuz-favourites") == 1)
    #expect(await gateway.browseCallCount(mediaID: "qobuz-favourite-albums") == 1)
    #expect(await gateway.browseCallCount(mediaID: "qobuz-discover") == 0)
    #expect(await gateway.browseCallCount(mediaID: "qobuz-genres") == 0)
    #expect(await gateway.browseCallCount(mediaID: "qobuz-album-chopin-nocturnes") == 0)
    #expect(linn.library.qobuz.favouriteAlbums?.items.map(\.title) == ["Chopin: The Complete Nocturnes"])
}

@Test
@MainActor
func libraryRefreshInvalidatesCacheWhenContentRevisionChanges() async throws {
    let gateway = TestGateway()
    await gateway.seedQobuzLibrary(contentRevision: 1)
    let linn = Linn(gateway: gateway)

    linn.loadLibrary()
    try await waitUntil {
        linn.library.availability == .available
    }

    let initialBrowseCount = await gateway.browseCallCount(mediaID: "service-qobuz")

    await gateway.seedQobuzLibrary(contentRevision: 2)
    linn.refreshLibrary()
    try await waitUntil {
        linn.library.rootPage?.contentRevision == 2
    }

    #expect(await gateway.browseCallCount(mediaID: "service-qobuz") > initialBrowseCount)
}

@Test
@MainActor
func librarySearchResultsReplaceAndMediaItemsCanBeSelected() async throws {
    let gateway = TestGateway()
    await gateway.seedQobuzLibrary(contentRevision: 1)
    let linn = Linn(gateway: gateway)

    linn.loadLibrary()
    try await waitUntil {
        linn.library.availability == .available
    }

    let firstResults = try await linn.searchLibrary(query: "Happy", type: .albums)
    #expect(firstResults.items.map(\.title) == ["Happy Christmas"])

    let secondResults = try await linn.searchLibrary(query: "Billie", type: .albums)
    #expect(secondResults.items.map(\.title) == ["HIT ME HARD AND SOFT"])

    let item = try #require(secondResults.items.first)
    linn.play(item, placement: .next)
    try await waitUntil {
        await gateway.selectedMediaItems() == [
            TestGateway.SelectedMediaItem(mediaID: item.id, room: "Linn", queue: .next),
        ]
    }
}

@Test
@MainActor
func libraryFavouriteUpdatesSupportedItems() async throws {
    let gateway = TestGateway()
    await gateway.seedQobuzLibrary(contentRevision: 1)
    let linn = Linn(gateway: gateway)

    linn.loadLibrary()
    try await waitUntil {
        linn.library.availability == .available
    }

    let item = try #require(linn.library.qobuz.favouriteAlbums?.items.first)
    #expect(item.canFavourite)

    linn.setFavourite(item, isFavourite: false)
    try await waitUntil {
        await gateway.favouriteRequests() == [
            TestGateway.FavouriteRequest(mediaID: item.id, isFavourite: false),
        ]
    }
    #expect(linn.library.qobuz.favouriteAlbums?.items.first?.isFavourite == false)
}

@Test
func demoGatewayReplaceEmitsImmediateCountThenDelayedObservedQueue() async throws {
    let gateway = DemoLinnGateway(
        songs: [Linn.Song(id: "initial", title: "Initial")],
        mediaSelectionObservationDelay: .milliseconds(20)
    )
    let updates = await gateway.nowPlayingUpdates(room: "Linn", updateInterval: 1)
    var iterator = updates.makeAsyncIterator()

    let initial = try #require(try await iterator.next())
    #expect(initial.queue?.length == 1)

    let command = Task {
        try await gateway.selectMedia(mediaID: "qobuz-album-hit-me-hard-and-soft", room: "Linn", queue: .replace)
    }

    let immediate = try #require(try await iterator.next())
    #expect(immediate.queue?.length == 10)
    #expect(immediate.currentItem?.track?.title == "Initial")

    let observed = try #require(try await iterator.next())
    try await command.value

    #expect(observed.queue?.index == 0)
    #expect(observed.queue?.length == 10)
    #expect(observed.playlist?.items.count == 10)
    #expect(observed.currentItem?.track?.title == "SKINNY")
}

@Test
func demoGatewayLastAppendsAfterDelayWhileKeepingCurrentItem() async throws {
    let gateway = DemoLinnGateway(
        songs: [
            Linn.Song(id: "zero", title: "Zero"),
            Linn.Song(id: "one", title: "One"),
        ],
        currentIndex: 0,
        mediaSelectionObservationDelay: .milliseconds(20)
    )
    let updates = await gateway.nowPlayingUpdates(room: "Linn", updateInterval: 1)
    var iterator = updates.makeAsyncIterator()
    _ = try #require(try await iterator.next())

    let command = Task {
        try await gateway.selectMedia(mediaID: "qobuz-track-lunch", room: "Linn", queue: .last)
    }

    let immediate = try #require(try await iterator.next())
    #expect(immediate.queue?.length == 3)
    #expect(immediate.currentItem?.track?.title == "Zero")

    let observed = try #require(try await iterator.next())
    try await command.value

    #expect(observed.queue?.index == 0)
    #expect(observed.queue?.length == 3)
    #expect(observed.currentItem?.track?.title == "Zero")
    #expect(observed.playlist?.items.map(\.displayName) == ["Zero", "One", "LUNCH"])
}

@Test
func demoGatewayNextInsertsAfterCurrentWithoutChangingCurrentItem() async throws {
    let gateway = DemoLinnGateway(
        songs: [
            Linn.Song(id: "zero", title: "Zero"),
            Linn.Song(id: "one", title: "One"),
        ],
        currentIndex: 0,
        mediaSelectionObservationDelay: .milliseconds(20)
    )
    let updates = await gateway.nowPlayingUpdates(room: "Linn", updateInterval: 1)
    var iterator = updates.makeAsyncIterator()
    _ = try #require(try await iterator.next())

    let command = Task {
        try await gateway.selectMedia(mediaID: "qobuz-track-lunch", room: "Linn", queue: .next)
    }

    let immediate = try #require(try await iterator.next())
    #expect(immediate.queue?.length == 3)

    let observed = try #require(try await iterator.next())
    try await command.value

    #expect(observed.queue?.index == 0)
    #expect(observed.currentItem?.track?.title == "Zero")
    #expect(observed.playlist?.items.map(\.displayName) == ["Zero", "LUNCH", "One"])
}

@Test
func demoGatewayNowInsertsAfterCurrentAndSelectsInsertedItemAfterDelay() async throws {
    let gateway = DemoLinnGateway(
        songs: [
            Linn.Song(id: "zero", title: "Zero"),
            Linn.Song(id: "one", title: "One"),
        ],
        currentIndex: 0,
        mediaSelectionObservationDelay: .milliseconds(20)
    )
    let updates = await gateway.nowPlayingUpdates(room: "Linn", updateInterval: 1)
    var iterator = updates.makeAsyncIterator()
    _ = try #require(try await iterator.next())

    let command = Task {
        try await gateway.selectMedia(mediaID: "qobuz-track-lunch", room: "Linn", queue: .now)
    }

    let immediate = try #require(try await iterator.next())
    #expect(immediate.queue?.length == 3)
    #expect(immediate.queue?.index == 0)
    #expect(immediate.currentItem?.track?.title == "Zero")

    let observed = try #require(try await iterator.next())
    try await command.value

    #expect(observed.queue?.index == 1)
    #expect(observed.currentItem?.track?.title == "LUNCH")
    #expect(observed.playlist?.items.map(\.displayName) == ["Zero", "LUNCH", "One"])
}

@Test
func demoGatewayNextMarksPendingPlaylistItemBeforeObservedCurrentIndexChanges() async throws {
    let gateway = DemoLinnGateway(
        songs: [
            Linn.Song(id: "zero", title: "Zero"),
            Linn.Song(id: "one", title: "One"),
            Linn.Song(id: "two", title: "Two"),
        ],
        currentIndex: 0,
        playlistSelectionObservationDelay: .milliseconds(20)
    )
    let updates = await gateway.nowPlayingUpdates(room: "Linn", updateInterval: 1)
    var iterator = updates.makeAsyncIterator()

    let initial = try #require(try await iterator.next())
    #expect(initial.queue?.index == 0)
    #expect(initial.playlist?.items.first(where: \.isCurrent)?.index == 0)

    let command = Task {
        try await gateway.next(room: "Linn")
    }

    let pending = try #require(try await iterator.next())
    #expect(pending.queue?.index == 0)
    #expect(pending.currentItem?.track?.title == "Zero")
    #expect(pending.playback?.transportState == .buffering)
    #expect(pending.playlist?.items.first(where: \.isCurrent)?.index == 1)

    let observed = try #require(try await iterator.next())
    try await command.value

    #expect(observed.queue?.index == 1)
    #expect(observed.currentItem?.track?.title == "One")
    #expect(observed.playback?.transportState == .play)
    #expect(observed.playlist?.items.first(where: \.isCurrent)?.index == 1)
}

private actor TestGateway: LinnGateway {
    struct SelectedMediaItem: Sendable, Equatable {
        var mediaID: String
        var room: String
        var queue: CiGateway.QueuePlacement
    }

    struct FavouriteRequest: Sendable, Equatable {
        var mediaID: String
        var isFavourite: Bool
    }

    private let stream: AsyncThrowingStream<CiGateway.NowPlaying, Error>
    private let continuation: AsyncThrowingStream<CiGateway.NowPlaying, Error>.Continuation
    private var selectedIndexes: [Int] = []
    private var selectedMedia: [SelectedMediaItem] = []
    private var favourites: [FavouriteRequest] = []
    private var previousCalls = 0
    private var nextCalls = 0
    private var shouldSuspendSelections = false
    private var suspendedSelections: [CheckedContinuation<Void, Never>] = []
    private var services: [CiGateway.MediaService] = []
    private var mediaPages: [String: CiGateway.MediaPage] = [:]
    private var browseCounts: [String: Int] = [:]

    init() {
        let source = AsyncThrowingStream<CiGateway.NowPlaying, Error>.makeStream()
        stream = source.stream
        continuation = source.continuation
    }

    func nowPlayingUpdates(
        room _: String?,
        updateInterval _: Int
    ) async -> AsyncThrowingStream<CiGateway.NowPlaying, Error> {
        stream
    }

    func play(room _: String) async throws {}

    func pause(room _: String) async throws {}

    func previous(room _: String) async throws {
        previousCalls += 1
    }

    func next(room _: String) async throws {
        nextCalls += 1
    }

    func selectPlaylistItem(at index: Int, room _: String) async throws {
        selectedIndexes.append(index)
        if shouldSuspendSelections {
            await withCheckedContinuation { continuation in
                suspendedSelections.append(continuation)
            }
        }
    }

    func setVolume(_: Int, room _: String, group _: Bool) async throws {}

    func setMuted(_: Bool, room _: String, group _: Bool) async throws {}

    func mediaServices(room _: String) async throws -> [CiGateway.MediaService] {
        services
    }

    func browseMedia(mediaID: String, index _: Int, count _: Int, browseType _: String) async throws -> CiGateway.MediaPage {
        browseCounts[mediaID, default: 0] += 1
        return mediaPages[mediaID] ?? CiGateway.MediaPage(id: mediaID)
    }

    func searchMedia(
        serviceID _: String,
        query: String,
        type _: CiGateway.MediaSearchType,
        index _: Int,
        count _: Int
    ) async throws -> CiGateway.MediaPage {
        let allItems = mediaPages.values.flatMap(\.children)
        let matches = allItems.filter {
            ($0.displayTitle ?? "").localizedCaseInsensitiveContains(query)
                || $0.artists.joined(separator: " ").localizedCaseInsensitiveContains(query)
        }
        return CiGateway.MediaPage(
            id: "search",
            contentRevision: mediaPages["service-qobuz"]?.contentRevision,
            index: 0,
            count: matches.count,
            total: matches.count,
            children: matches
        )
    }

    func selectMedia(mediaID: String, room: String, queue: CiGateway.QueuePlacement) async throws {
        selectedMedia.append(SelectedMediaItem(mediaID: mediaID, room: room, queue: queue))
    }

    func setMediaFavourite(mediaID: String, isFavourite: Bool) async throws {
        favourites.append(FavouriteRequest(mediaID: mediaID, isFavourite: isFavourite))
    }

    func send(_ update: CiGateway.NowPlaying) {
        continuation.yield(update)
    }

    func selectedPlaylistIndexes() -> [Int] {
        selectedIndexes
    }

    func selectedMediaItems() -> [SelectedMediaItem] {
        selectedMedia
    }

    func favouriteRequests() -> [FavouriteRequest] {
        favourites
    }

    func browseCallCount(mediaID: String) -> Int {
        browseCounts[mediaID] ?? 0
    }

    func previousCallCount() -> Int {
        previousCalls
    }

    func nextCallCount() -> Int {
        nextCalls
    }

    func suspendSelections() {
        shouldSuspendSelections = true
    }

    func resumeSelections() {
        shouldSuspendSelections = false
        let continuations = suspendedSelections
        suspendedSelections.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }

    func seedQobuzLibrary(contentRevision: Int) {
        services = [
            CiGateway.MediaService(id: "service-qobuz", name: "Qobuz", kind: "md.service"),
        ]
        mediaPages = [
            "service-qobuz": CiGateway.MediaPage(
                id: "service-qobuz",
                contentRevision: contentRevision,
                index: 0,
                count: 3,
                total: 3,
                children: [
                    CiGateway.MediaItem(id: "qobuz-discover", kind: "md.qobuz.discover", name: "Discover"),
                    CiGateway.MediaItem(id: "qobuz-genres", kind: "md.qobuz.genres", name: "Genres"),
                    CiGateway.MediaItem(id: "qobuz-myqobuz", kind: "md.qobuz.myqobuz", name: "My Qobuz"),
                ]
            ),
            "qobuz-myqobuz": CiGateway.MediaPage(
                id: "qobuz-myqobuz",
                contentRevision: contentRevision,
                index: 0,
                count: 3,
                total: 3,
                children: [
                    CiGateway.MediaItem(id: "qobuz-favourites", kind: "md.container", name: "Favourites"),
                    CiGateway.MediaItem(id: "qobuz-my-playlists", kind: "md.container.qobuz.playlist", name: "My Playlists"),
                    CiGateway.MediaItem(id: "qobuz-purchased", kind: "md.container", name: "Purchased"),
                ]
            ),
            "qobuz-favourites": CiGateway.MediaPage(
                id: "qobuz-favourites",
                contentRevision: contentRevision,
                index: 0,
                count: 3,
                total: 3,
                children: [
                    CiGateway.MediaItem(id: "qobuz-favourite-albums", kind: "md.container.qobuz.album", name: "Albums"),
                    CiGateway.MediaItem(id: "qobuz-favourite-artists", kind: "md.container", name: "Artist"),
                    CiGateway.MediaItem(id: "qobuz-favourite-playlists", kind: "md.container", name: "Playlists"),
                ]
            ),
            "qobuz-favourite-albums": CiGateway.MediaPage(
                id: "qobuz-favourite-albums",
                contentRevision: contentRevision,
                index: 0,
                count: 2,
                total: 2,
                children: [
                    CiGateway.MediaItem(
                        id: "qobuz-album-happy-christmas",
                        kind: "md.album.qobuz",
                        name: "Happy Christmas",
                        album: "Happy Christmas",
                        artists: ["Frank Sinatra"],
                        artworkURL: URL(string: "https://static.qobuz.com/images/covers/25/04/3610152050425_230.jpg"),
                        containedKinds: ["md.track.qobuz"],
                        childCount: 50,
                        isFavourite: true,
                        disabledActions: ["a46"]
                    ),
                    CiGateway.MediaItem(
                        id: "qobuz-album-shostakovich-quartets",
                        kind: "md.album.qobuz",
                        name: "Shostakovich: Complete String Quartets, Vol. 2, Nos. 6-12",
                        album: "Shostakovich: Complete String Quartets, Vol. 2, Nos. 6-12",
                        artists: ["Cuarteto Casals"],
                        artworkURL: URL(string: "https://static.qobuz.com/images/covers/ob/zn/wozp8tpq0znob_230.jpg"),
                        containedKinds: ["md.track.qobuz"],
                        childCount: 30,
                        isFavourite: true
                    ),
                ]
            ),
            "qobuz-favourite-artists": CiGateway.MediaPage(
                id: "qobuz-favourite-artists",
                contentRevision: contentRevision,
                index: 0,
                count: 1,
                total: 1,
                children: [
                    CiGateway.MediaItem(
                        id: "qobuz-artist-qrion",
                        kind: "md.artist.qobuz",
                        name: "Qrion",
                        artists: ["Qrion"],
                        artworkURL: URL(string: "https://static.qobuz.com/images/artists/covers/small/afd716d782ba6b056d5a311b0bed0573.jpg"),
                        isFavourite: true
                    ),
                ]
            ),
            "qobuz-favourite-playlists": CiGateway.MediaPage(
                id: "qobuz-favourite-playlists",
                contentRevision: contentRevision,
                index: 0,
                count: 2,
                total: 2,
                children: [
                    CiGateway.MediaItem(
                        id: "qobuz-playlist-willkommen",
                        kind: "md.playlist.qobuz",
                        name: "Willkommen bei Qobuz",
                        artworkURL: URL(string: "https://static.qobuz.com/images/playlists/1285072_2bc9b2d5023757d1a8b10db915efd367_rectangle.jpg"),
                        containedKinds: ["md.track.qobuz"],
                        childCount: 125
                    ),
                    CiGateway.MediaItem(
                        id: "qobuz-playlist-true-sound-covers",
                        kind: "md.playlist.qobuz",
                        name: "True Sound Covers",
                        artworkURL: URL(string: "https://static.qobuz.com/images/covers/13/05/0093624980513_300.jpg"),
                        containedKinds: ["md.track.qobuz"],
                        childCount: 50
                    ),
                ]
            ),
            "qobuz-my-playlists": CiGateway.MediaPage(
                id: "qobuz-my-playlists",
                contentRevision: contentRevision,
                index: 0,
                count: 2,
                total: 2,
                children: [
                    CiGateway.MediaItem(
                        id: "qobuz-playlist-demo",
                        kind: "md.playlist.qobuz",
                        name: "Demo",
                        artworkURL: URL(string: "https://static.qobuz.com/images/covers/09/32/0088807203209_300.jpg"),
                        containedKinds: ["md.track.qobuz"],
                        childCount: 17
                    ),
                    CiGateway.MediaItem(
                        id: "qobuz-playlist-cello-henry-bedtime",
                        kind: "md.playlist.qobuz",
                        name: "\"Cello\" (Henry bedtime)",
                        artworkURL: URL(string: "https://static.qobuz.com/images/covers/43/80/0884977868043_300.jpg"),
                        containedKinds: ["md.track.qobuz"],
                        childCount: 8
                    ),
                ]
            ),
            "qobuz-purchased": CiGateway.MediaPage(
                id: "qobuz-purchased",
                contentRevision: contentRevision,
                index: 0,
                count: 1,
                total: 1,
                children: [
                    CiGateway.MediaItem(
                        id: "qobuz-album-hit-me-hard-and-soft",
                        kind: "md.album.qobuz",
                        name: "HIT ME HARD AND SOFT",
                        album: "HIT ME HARD AND SOFT",
                        artists: ["Billie Eilish"],
                        artworkURL: URL(string: "https://static.qobuz.com/images/covers/kc/95/gvcirtodd95kc_230.jpg"),
                        containedKinds: ["md.track.qobuz"],
                        childCount: 10,
                        isFavourite: true,
                        disabledActions: ["a46"]
                    ),
                ]
            ),
        ]
    }

    func seedNestedQobuzLibrary(contentRevision: Int) {
        services = [
            CiGateway.MediaService(id: "service-qobuz", name: "Qobuz", kind: "md.qobuz"),
        ]
        mediaPages = [
            "service-qobuz": CiGateway.MediaPage(
                id: "service-qobuz",
                contentRevision: contentRevision,
                index: 0,
                count: 3,
                total: 3,
                children: [
                    CiGateway.MediaItem(id: "qobuz-discover", kind: "md.qobuz.discover", name: "Discover"),
                    CiGateway.MediaItem(id: "qobuz-genres", kind: "md.qobuz.genres", name: "Genres"),
                    CiGateway.MediaItem(id: "qobuz-myqobuz", kind: "md.qobuz.myqobuz", name: "My Qobuz"),
                ]
            ),
            "qobuz-myqobuz": CiGateway.MediaPage(
                id: "qobuz-myqobuz",
                contentRevision: contentRevision,
                index: 0,
                count: 3,
                total: 3,
                children: [
                    CiGateway.MediaItem(id: "qobuz-favourites", kind: "md.container", name: "Favourites"),
                    CiGateway.MediaItem(id: "qobuz-my-playlists", kind: "md.container.qobuz.playlist", name: "My Playlists"),
                    CiGateway.MediaItem(id: "qobuz-purchased", kind: "md.container", name: "Purchased"),
                ]
            ),
            "qobuz-favourites": CiGateway.MediaPage(
                id: "qobuz-favourites",
                contentRevision: contentRevision,
                index: 0,
                count: 3,
                total: 3,
                children: [
                    CiGateway.MediaItem(id: "qobuz-favourite-albums", kind: "md.container.qobuz.album", name: "Albums"),
                    CiGateway.MediaItem(id: "qobuz-favourite-artists", kind: "md.container", name: "Artist"),
                    CiGateway.MediaItem(id: "qobuz-favourite-playlists", kind: "md.container", name: "Playlists"),
                ]
            ),
            "qobuz-favourite-albums": CiGateway.MediaPage(
                id: "qobuz-favourite-albums",
                contentRevision: contentRevision,
                index: 0,
                count: 1,
                total: 1,
                children: [
                    CiGateway.MediaItem(
                        id: "qobuz-album-chopin-nocturnes",
                        kind: "md.album.qobuz",
                        name: "Chopin: The Complete Nocturnes",
                        album: "Chopin: The Complete Nocturnes",
                        artists: ["Tom Hicks"],
                        artworkURL: URL(string: "https://static.qobuz.com/images/covers/yc/ag/nuuxf36hoagyc_230.jpg"),
                        containedKinds: ["md.track.qobuz"],
                        childCount: 21,
                        isFavourite: true
                    ),
                ]
            ),
            "qobuz-favourite-artists": CiGateway.MediaPage(
                id: "qobuz-favourite-artists",
                contentRevision: contentRevision,
                index: 0,
                count: 0,
                total: 0,
                children: []
            ),
            "qobuz-favourite-playlists": CiGateway.MediaPage(
                id: "qobuz-favourite-playlists",
                contentRevision: contentRevision,
                index: 0,
                count: 0,
                total: 0,
                children: []
            ),
            "qobuz-my-playlists": CiGateway.MediaPage(
                id: "qobuz-my-playlists",
                contentRevision: contentRevision,
                index: 0,
                count: 0,
                total: 0,
                children: []
            ),
            "qobuz-purchased": CiGateway.MediaPage(
                id: "qobuz-purchased",
                contentRevision: contentRevision,
                index: 0,
                count: 0,
                total: 0,
                children: []
            ),
        ]
    }
}

private func nowPlaying(
    index: Int,
    titles: [String],
    playlistIndexes: [Int]? = nil,
    position: Int = 1,
    volume: Int = 10
) -> CiGateway.NowPlaying {
    let title = titles[index]
    let playlistIndexes = playlistIndexes ?? Array(titles.indices)
    var nowPlaying = CiGateway.NowPlaying(room: "Linn", session: "test-session")
    nowPlaying.playback = CiGateway.NowPlaying.Playback(transportState: .play)
    nowPlaying.queue = CiGateway.NowPlaying.Queue(index: index, length: titles.count)
    nowPlaying.currentItem = CiGateway.NowPlaying.CurrentItem(
        id: "song-\(index)",
        kind: "md.track",
        displayName: title,
        track: CiGateway.NowPlaying.Track(
            title: title,
            album: "Album \(index)",
            artist: "Artist \(index)"
        )
    )
    nowPlaying.playlist = CiGateway.NowPlaying.Playlist(
        items: playlistIndexes.map { index in
            CiGateway.NowPlaying.PlaylistItem(
                index: index,
                displayName: titles[index],
                album: "Album \(index)",
                artist: "Artist \(index)",
                duration: 180 + index
            )
        },
        total: titles.count,
        contentRevision: 1
    )
    nowPlaying.timeline = CiGateway.NowPlaying.Timeline(position: position, duration: 180)
    nowPlaying.roomState = CiGateway.NowPlaying.RoomState(volume: volume, isMuted: false)
    return nowPlaying
}

@MainActor
private func waitUntil(
    _ condition: @MainActor () -> Bool
) async throws {
    for _ in 0 ..< 50 {
        if condition() {
            return
        }
        try await Task.sleep(for: .milliseconds(20))
    }

    #expect(condition())
}

@MainActor
private func waitUntil(
    _ condition: @MainActor () async -> Bool
) async throws {
    for _ in 0 ..< 50 {
        if await condition() {
            return
        }
        try await Task.sleep(for: .milliseconds(20))
    }

    #expect(await condition())
}
