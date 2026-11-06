import Foundation
@testable import Linn
import Testing

@Test
@MainActor
func predictedSongClearsThePreviousTrackTimeline() async throws {
    let gateway = TestGateway()
    let linn = Linn(gateway: gateway)
    linn.start()
    await gateway.send(nowPlaying(index: 0, titles: ["First", "Second"], position: 45))
    try await waitUntil { linn.timeline?.position == 45 }

    var predicted = nowPlaying(index: 1, titles: ["First", "Second"], position: 0)
    predicted.timeline = nil
    predicted.pending.queueIndex = true
    predicted.pending.currentItem = true
    await gateway.send(predicted)
    try await waitUntil { linn.currentSong?.title == "Second" }
    #expect(linn.timeline == nil)
}

@Test
@MainActor
func aDisconnectedServerSnapshotCanRecoverWithoutRestartingLinn() async throws {
    let gateway = TestGateway()
    let linn = Linn(gateway: gateway)
    linn.start()

    await gateway.send(nowPlaying(index: 0, titles: ["First"], volume: 10))
    try await waitUntil { linn.connectionState == .connected }

    var disconnected = Linn.Snapshot()
    disconnected.connectionState = .linnUnavailable(nil)
    await gateway.send(disconnected)
    try await waitUntil { linn.connectionState == .linnUnavailable(nil) }
    #expect(linn.currentSong?.title == "First")
    #expect(!linn.canControlPlayback)
    #expect(!linn.hasNext && !linn.hasPrevious)

    await gateway.send(nowPlaying(index: 0, titles: ["Second"], volume: 12))
    try await waitUntil { linn.connectionState == .connected && linn.currentSong?.title == "Second" }
}

@Test(arguments: [false, true])
@MainActor
func standbyDisablesControlsOnFreshClientsAndLiveUpdates(startConnected: Bool) async throws {
    let gateway = TestGateway()
    let linn = Linn(gateway: gateway)
    linn.start()
    let active = nowPlaying(index: 1, titles: ["First", "Last song", "Next"], volume: 18)
    if startConnected {
        await gateway.send(active)
        try await waitUntil { linn.canControlPlayback }
    }
    var standby = active
    standby.isStandby = true
    await gateway.send(standby)
    try await waitUntil { linn.isStandby && linn.connectionState == .connected }
    #expect(!linn.canControlPlayback)
    #expect(!linn.hasNext && !linn.hasPrevious)
    // Keep the last observed metadata, but views must display standby instead.
    #expect(linn.currentSong?.title == "Last song")
    var awake = active
    awake.isStandby = false
    await gateway.send(awake)
    try await waitUntil { linn.canControlPlayback }
    #expect(linn.hasNext && linn.hasPrevious)
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
func libraryLoadUsesAvailableLibraryCache() async throws {
    let gateway = TestGateway()
    await gateway.seedQobuzLibrary(contentRevision: 1)
    let linn = Linn(gateway: gateway)

    linn.loadLibrary()
    try await waitUntil {
        linn.library.availability == .available
    }

    let serviceBrowseCount = await gateway.browseCallCount(mediaID: "service-qobuz")
    linn.loadLibrary()

    #expect(await gateway.browseCallCount(mediaID: "service-qobuz") == serviceBrowseCount)
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
func libraryReportsAvailableServicesWhenQobuzIsMissing() async throws {
    let gateway = TestGateway()
    await gateway.seedMediaServices([
        Linn.LibraryService(id: "service-airable", name: "Airable", kind: "md.airable"),
    ])
    let linn = Linn(gateway: gateway)

    linn.loadLibrary()
    try await waitUntil {
        if case .failed = linn.library.availability {
            return true
        }
        return false
    }

    if case let .failed(message) = linn.library.availability {
        #expect(message == "Qobuz media service is unavailable. Available media services: Airable (md.airable).")
    } else {
        #expect(Bool(false), "Expected library load to fail when Qobuz is missing")
    }
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
    #expect(initial.playlist.total == 1)

    let command = Task {
        try await gateway.selectMedia(mediaID: "qobuz-album-hit-me-hard-and-soft", room: "Linn", queue: .replace)
    }

    let immediate = try #require(try await iterator.next())
    #expect(immediate.playlist.total == 10)
    #expect(immediate.currentSong?.title == "Initial")

    let observed = try #require(try await iterator.next())
    try await command.value

    #expect(observed.playlist.currentIndex == 0)
    #expect(observed.playlist.total == 10)
    #expect(observed.playlist.songs.count == 10)
    #expect(observed.currentSong?.title == "SKINNY")
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
    #expect(immediate.playlist.total == 3)
    #expect(immediate.currentSong?.title == "Zero")

    let observed = try #require(try await iterator.next())
    try await command.value

    #expect(observed.playlist.currentIndex == 0)
    #expect(observed.playlist.total == 3)
    #expect(observed.currentSong?.title == "Zero")
    #expect(observed.playlist.songs.map(\.title) == ["Zero", "One", "LUNCH"])
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
    #expect(immediate.playlist.total == 3)

    let observed = try #require(try await iterator.next())
    try await command.value

    #expect(observed.playlist.currentIndex == 0)
    #expect(observed.currentSong?.title == "Zero")
    #expect(observed.playlist.songs.map(\.title) == ["Zero", "LUNCH", "One"])
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
    #expect(immediate.playlist.total == 3)
    #expect(immediate.playlist.currentIndex == 0)
    #expect(immediate.currentSong?.title == "Zero")

    let observed = try #require(try await iterator.next())
    try await command.value

    #expect(observed.playlist.currentIndex == 1)
    #expect(observed.currentSong?.title == "LUNCH")
    #expect(observed.playlist.songs.map(\.title) == ["Zero", "LUNCH", "One"])
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
    #expect(initial.playlist.currentIndex == 0)
    #expect(!initial.pending.queueIndex)

    let command = Task {
        try await gateway.next(room: "Linn")
    }

    let pending = try #require(try await iterator.next())
    #expect(pending.playlist.currentIndex == 0)
    #expect(pending.currentSong?.title == "Zero")
    #expect(pending.playState == .buffering)
    #expect(pending.pending.queueIndex)

    let observed = try #require(try await iterator.next())
    try await command.value

    #expect(observed.playlist.currentIndex == 1)
    #expect(observed.currentSong?.title == "One")
    #expect(observed.playState == .playing)
    #expect(!observed.pending.queueIndex)
}

@Test
@MainActor
func stopDuringLibraryLoadDoesNotStrandLoadingState() async throws {
    let gateway = TestGateway()
    await gateway.seedQobuzLibrary(contentRevision: 1)
    await gateway.suspendMediaServices()
    let linn = Linn(gateway: gateway)

    linn.loadLibrary()
    try await waitUntil {
        linn.library.availability == .loading
    }

    linn.stop()
    #expect(linn.library.availability == .unavailable)

    await gateway.resumeMediaServices()
    linn.loadLibrary()
    try await waitUntil {
        linn.library.availability == .available
    }
}

@Test
@MainActor
func rapidCommandsRunIndependentlyWithoutCancellingEachOther() async throws {
    let gateway = TestGateway()
    let linn = Linn(gateway: gateway)
    let titles = ["Zero", "One"]

    linn.start()
    await gateway.send(nowPlaying(index: 0, titles: titles))
    try await waitUntil {
        linn.currentSong?.title == "Zero"
    }

    let item = Linn.LibraryItem(id: "album-1", kind: "md.album.qobuz", title: "Album")
    linn.play(item, placement: .last)
    linn.pause()

    try await waitUntil {
        await gateway.selectedMediaItems().count == 1
    }
    try await waitUntil {
        await gateway.pauseCallCount() == 1
    }
}

@Test
@MainActor
func queueSongIdentityIsContentBasedAndStableAcrossSources() async throws {
    func update(index: Int, volume: Int) -> Linn.Snapshot {
        var snapshot = nowPlaying(index: index, titles: ["Same", "Same", "Other"], volume: volume)
        snapshot.playlist.songs = snapshot.playlist.songs.map { song in
            var song = song
            song.artist = "Artist"
            song.album = "Album"
            song.duration = 200
            return song
        }
        snapshot.currentSong = snapshot.playlist.songs[index]
        snapshot.currentSong?.id = "media-\(index)"
        snapshot.currentSong?.duration = nil
        return snapshot
    }

    let gateway = TestGateway()
    let linn = Linn(gateway: gateway)

    linn.start()
    await gateway.send(update(index: 0, volume: 10))
    try await waitUntil {
        linn.playlist.songs.count == 3
    }

    let ids = linn.playlist.songs.map(\.id)
    #expect(Set(ids).count == 3)
    #expect(!ids.contains { $0.hasPrefix("playlist-") })

    // The next update replaces the index-1 entry from now-playing metadata
    // instead of the playlist payload; identity must not change with the source.
    await gateway.send(update(index: 1, volume: 11))
    try await waitUntil {
        linn.volume == 11
    }
    #expect(linn.playlist.songs.map(\.id) == ids)
}

@Test
@MainActor
func optimisticVolumeHoldsAgainstStaleUpdates() async throws {
    let gateway = TestGateway()
    let linn = Linn(gateway: gateway)
    let titles = ["Zero", "One"]

    linn.start()
    await gateway.send(nowPlaying(index: 0, titles: titles, volume: 10))
    try await waitUntil {
        linn.volume == 10
    }

    linn.setVolume(30)
    #expect(linn.volume == 30)

    // A stale reading from before the set must not snap the knob back.
    await gateway.send(nowPlaying(index: 0, titles: titles, position: 2, volume: 10))
    try await waitUntil {
        linn.timeline?.position == 2
    }
    #expect(linn.volume == 30)

    // The device confirms; the optimistic hold clears…
    await gateway.send(nowPlaying(index: 0, titles: titles, position: 3, volume: 30))
    try await waitUntil {
        linn.timeline?.position == 3
    }
    #expect(linn.volume == 30)

    // …and later readings apply again.
    await gateway.send(nowPlaying(index: 0, titles: titles, position: 4, volume: 12))
    try await waitUntil {
        linn.volume == 12
    }
}

@Test
@MainActor
func optimisticMuteHoldsAgainstStaleUpdates() async throws {
    let gateway = TestGateway()
    let linn = Linn(gateway: gateway)
    let titles = ["Zero", "One"]

    linn.start()
    await gateway.send(nowPlaying(index: 0, titles: titles, volume: 10))
    try await waitUntil {
        linn.isMuted == false
    }

    linn.setMuted(true)
    #expect(linn.isMuted == true)

    var stale = nowPlaying(index: 0, titles: titles, position: 2, volume: 10)
    stale.volume = 10
    stale.isMuted = false
    await gateway.send(stale)
    try await waitUntil {
        linn.timeline?.position == 2
    }
    #expect(linn.isMuted == true)

    var confirmed = nowPlaying(index: 0, titles: titles, position: 3, volume: 10)
    confirmed.volume = 10
    confirmed.isMuted = true
    await gateway.send(confirmed)
    try await waitUntil {
        linn.timeline?.position == 3
    }
    #expect(linn.isMuted == true)

    var unmuted = nowPlaying(index: 0, titles: titles, position: 4, volume: 10)
    unmuted.volume = 10
    unmuted.isMuted = false
    await gateway.send(unmuted)
    try await waitUntil {
        linn.isMuted == false
    }
}

@Test
@MainActor
func enqueueingALibraryItemKeepsTheCurrentSong() async throws {
    let gateway = TestGateway()
    let linn = Linn(gateway: gateway)

    linn.start()
    await gateway.send(nowPlaying(index: 0, titles: ["Zero"]))
    try await waitUntil {
        linn.currentSong?.title == "Zero"
    }

    let track = Linn.LibraryItem(id: "track-lunch", kind: "md.track.qobuz", title: "Lunch")
    linn.play(track, placement: .next)
    linn.play(track, placement: .last)

    #expect(linn.currentSong?.title == "Zero")
    #expect(linn.timeline?.position == 1)
}

@Test
@MainActor
func serverPredictionIsReplacedByTheNextServerState() async throws {
    let gateway = TestGateway()
    let linn = Linn(gateway: gateway)
    linn.start()
    await gateway.send(nowPlaying(index: 0, titles: ["Old", "Other"], volume: 10))
    try await waitUntil { linn.currentSong?.title == "Old" }

    var predicted = nowPlaying(index: 1, titles: ["Old", "Predicted"], position: 0, volume: 10)
    predicted.pending.currentItem = true
    predicted.pending.queueIndex = true
    await gateway.send(predicted)
    try await waitUntil { linn.currentSong?.title == "Predicted" }
    #expect(linn.playlist.currentIndex == 1)
    #expect(linn.songTransitionDirection == .forward)

    await gateway.send(nowPlaying(index: 0, titles: ["Actual", "Other"], position: 7, volume: 10))
    try await waitUntil { linn.currentSong?.title == "Actual" }
    #expect(linn.playlist.currentIndex == 0)
    #expect(linn.timeline?.position == 7)
    #expect(linn.songTransitionDirection == .backward)
}

@Test
@MainActor
func completeSnapshotsReplaceQueueRowsWithoutRetainingOrInventingSongs() async throws {
    let gateway = TestGateway()
    let linn = Linn(gateway: gateway)
    linn.start()
    await gateway.send(nowPlaying(index: 0, titles: ["Old", "Removed"]))
    try await waitUntil { linn.playlist.songs.count == 2 }

    // Metadata and queue position settle separately. Never write the current
    // title into a queue row: that row already belongs to the new song.
    var snapshot = nowPlaying(index: 0, titles: ["New"])
    snapshot.currentSong = .init(id: "old", title: "Old", queueIndex: 0)
    await gateway.send(snapshot)
    try await waitUntil { linn.playlist.total == 1 }
    #expect(linn.currentSong?.title == "Old")
    #expect(linn.playlist.songs.map(\.title) == ["New"])

    // A replace with unknown contents can deliberately clear all rows while
    // keeping a predicted current song. A previous snapshot must not refill it.
    snapshot.playlist = .init()
    snapshot.pending.currentItem = true
    snapshot.pending.queueTotal = true
    snapshot.timeline = nil
    await gateway.send(snapshot)
    try await waitUntil { linn.playlist.total == nil }
    #expect(linn.playlist.songs.isEmpty)
    #expect(linn.playlist.currentIndex == nil)
    #expect(linn.timeline == nil)
    #expect(linn.currentSong?.title == "Old")

    await gateway.send(Linn.Snapshot())
    try await waitUntil { linn.currentSong == nil }
    #expect(linn.playState == nil)
    #expect(linn.volume == nil)
    #expect(linn.isMuted == nil)
}

@Test
@MainActor
func predictedQueueReplaceAnimatesForwardFromAnEarlierIndex() async throws {
    let gateway = TestGateway()
    let linn = Linn(gateway: gateway)
    linn.start()
    await gateway.send(nowPlaying(index: 2, titles: ["Zero", "One", "Old"]))
    try await waitUntil { linn.currentSong?.title == "Old" }

    var predicted = nowPlaying(index: 0, titles: ["New", "Second"])
    predicted.pending.queueTotal = true
    predicted.pending.currentItem = true
    await gateway.send(predicted)
    try await waitUntil { linn.currentSong?.title == "New" }
    #expect(linn.songTransitionDirection == .forward)
}

@Test
@MainActor
func doubleSkipIsSentToTheServerWithoutLocalQueuePrediction() async throws {
    let gateway = TestGateway()
    let linn = Linn(gateway: gateway)
    linn.start()
    await gateway.send(nowPlaying(index: 0, titles: ["Zero", "One", "Two"]))
    try await waitUntil { linn.currentSong?.title == "Zero" }

    linn.next()
    linn.next()
    try await waitUntil { await gateway.nextCallCount() == 2 }
    #expect(linn.currentSong?.title == "Zero")
    #expect(linn.playlist.currentIndex == 0)

    await gateway.send(nowPlaying(index: 2, titles: ["Zero", "One", "Two"]))
    try await waitUntil { linn.currentSong?.title == "Two" }
    #expect(linn.remainingQueueCount == 0)
}

@Test
@MainActor
func queueRowTapShowsLocalPendingMarkerUntilServerConfirms() async throws {
    let gateway = TestGateway()
    let linn = Linn(gateway: gateway)
    linn.start()
    await gateway.send(nowPlaying(index: 0, titles: ["Zero", "One", "Two"]))
    try await waitUntil { linn.currentSong?.title == "Zero" }

    linn.play(try #require(linn.playlist.songs.first(where: { $0.queueIndex == 2 })))
    #expect(linn.pendingQueueIndex == 2)
    #expect(linn.currentSong?.title == "Zero")
    try await waitUntil { await gateway.selectedPlaylistIndexes() == [2] }

    var predicted = nowPlaying(index: 2, titles: ["Zero", "One", "Two"])
    predicted.pending.queueIndex = true
    await gateway.send(predicted)
    try await waitUntil { linn.currentSong?.title == "Two" }
    #expect(linn.pendingQueueIndex == 2)

    await gateway.send(nowPlaying(index: 2, titles: ["Zero", "One", "Two"]))
    try await waitUntil { linn.pendingQueueIndex == nil }
}

private let threeTrackAlbumPage = Linn.LibraryPage(
    id: "album-x",
    index: 0,
    count: 3,
    total: 3,
    items: [
        Linn.LibraryItem(id: "track-a", kind: "md.track.qobuz", title: "A"),
        Linn.LibraryItem(id: "track-b", kind: "md.track.qobuz", title: "B"),
        Linn.LibraryItem(id: "track-c", kind: "md.track.qobuz", title: "C"),
    ]
)

private struct MediaSelectionFailed: Error {}

private actor TestGateway: LinnGateway {
    struct SelectedMediaItem: Sendable, Equatable {
        var mediaID: String
        var room: String
        var queue: Linn.QueuePlacement
    }

    struct FavouriteRequest: Sendable, Equatable {
        var mediaID: String
        var isFavourite: Bool
    }

    private let stream: AsyncThrowingStream<Linn.Snapshot, Error>
    private let continuation: AsyncThrowingStream<Linn.Snapshot, Error>.Continuation
    private var selectedIndexes: [Int] = []
    private var selectedMedia: [SelectedMediaItem] = []
    private var mediaPreviews: [Linn.LibraryItem?] = []
    private var favourites: [FavouriteRequest] = []
    private var previousCalls = 0
    private var nextCalls = 0
    private var playCalls = 0
    private var pauseCalls = 0
    private var shouldSuspendSelections = false
    private var suspendedSelections: [CheckedContinuation<Void, Never>] = []
    private var shouldFailMediaSelections = false
    private var failingMediaIDs: Set<String> = []
    private var shouldSuspendMediaServices = false
    private var suspendedMediaServices: [CheckedContinuation<Void, Never>] = []
    private var services: [Linn.LibraryService] = []
    private var mediaPages: [String: Linn.LibraryPage] = [:]
    private var browseCounts: [String: Int] = [:]

    init() {
        let source = AsyncThrowingStream<Linn.Snapshot, Error>.makeStream()
        stream = source.stream
        continuation = source.continuation
    }

    func nowPlayingUpdates(
        room _: String?,
        updateInterval _: Int
    ) async -> AsyncThrowingStream<Linn.Snapshot, Error> {
        stream
    }

    func play(room _: String) async throws {
        playCalls += 1
    }

    func pause(room _: String) async throws {
        pauseCalls += 1
    }

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

    func mediaServices(room _: String) async throws -> [Linn.LibraryService] {
        if shouldSuspendMediaServices {
            await withCheckedContinuation { continuation in
                suspendedMediaServices.append(continuation)
            }
        }
        return services
    }

    func browseMedia(mediaID: String, index _: Int, count _: Int, browseType _: String) async throws -> Linn.LibraryPage {
        browseCounts[mediaID, default: 0] += 1
        return mediaPages[mediaID] ?? Linn.LibraryPage(id: mediaID)
    }

    func searchMedia(
        serviceID _: String,
        query: String,
        type _: Linn.SearchType,
        index _: Int,
        count _: Int
    ) async throws -> Linn.LibraryPage {
        let allItems = mediaPages.values.flatMap(\.items)
        let matches = allItems.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.artists.joined(separator: " ").localizedCaseInsensitiveContains(query)
        }
        return Linn.LibraryPage(
            id: "search",
            contentRevision: mediaPages["service-qobuz"]?.contentRevision,
            index: 0,
            count: matches.count,
            total: matches.count,
            items: matches
        )
    }

    func selectMedia(mediaID: String, room: String, queue: Linn.QueuePlacement) async throws {
        selectedMedia.append(SelectedMediaItem(mediaID: mediaID, room: room, queue: queue))
        if shouldFailMediaSelections || failingMediaIDs.contains(mediaID) {
            throw MediaSelectionFailed()
        }
    }

    func selectMedia(mediaID: String, room: String, queue: Linn.QueuePlacement, preview: Linn.LibraryItem?) async throws {
        mediaPreviews.append(preview)
        try await selectMedia(mediaID: mediaID, room: room, queue: queue)
    }

    func failMediaSelections(for mediaIDs: Set<String>) {
        failingMediaIDs.formUnion(mediaIDs)
    }

    func failMediaSelections() {
        shouldFailMediaSelections = true
    }

    func seedMediaPage(_ page: Linn.LibraryPage, for mediaID: String) {
        mediaPages[mediaID] = page
    }

    func setMediaFavourite(mediaID: String, isFavourite: Bool) async throws {
        favourites.append(FavouriteRequest(mediaID: mediaID, isFavourite: isFavourite))
    }

    func send(_ update: Linn.Snapshot) {
        continuation.yield(update)
    }

    func selectedPlaylistIndexes() -> [Int] {
        selectedIndexes
    }

    func selectedMediaItems() -> [SelectedMediaItem] {
        selectedMedia
    }

    func selectedMediaPreviews() -> [Linn.LibraryItem?] {
        mediaPreviews
    }

    func favouriteRequests() -> [FavouriteRequest] {
        favourites
    }

    func browseCallCount(mediaID: String) -> Int {
        browseCounts[mediaID] ?? 0
    }

    func seedMediaServices(_ services: [Linn.LibraryService]) {
        self.services = services
    }

    func previousCallCount() -> Int {
        previousCalls
    }

    func nextCallCount() -> Int {
        nextCalls
    }

    func playCallCount() -> Int {
        playCalls
    }

    func pauseCallCount() -> Int {
        pauseCalls
    }

    func suspendMediaServices() {
        shouldSuspendMediaServices = true
    }

    func resumeMediaServices() {
        shouldSuspendMediaServices = false
        let continuations = suspendedMediaServices
        suspendedMediaServices.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
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
            Linn.LibraryService(id: "service-qobuz", name: "Qobuz", kind: "md.service"),
        ]
        mediaPages = [
            "service-qobuz": Linn.LibraryPage(
                id: "service-qobuz",
                contentRevision: contentRevision,
                index: 0,
                count: 3,
                total: 3,
                items: [
                    Linn.LibraryItem(id: "qobuz-discover", kind: "md.qobuz.discover", title: "Discover"),
                    Linn.LibraryItem(id: "qobuz-genres", kind: "md.qobuz.genres", title: "Genres"),
                    Linn.LibraryItem(id: "qobuz-myqobuz", kind: "md.qobuz.myqobuz", title: "My Qobuz"),
                ]
            ),
            "qobuz-myqobuz": Linn.LibraryPage(
                id: "qobuz-myqobuz",
                contentRevision: contentRevision,
                index: 0,
                count: 3,
                total: 3,
                items: [
                    Linn.LibraryItem(id: "qobuz-favourites", kind: "md.container", title: "Favourites"),
                    Linn.LibraryItem(id: "qobuz-my-playlists", kind: "md.container.qobuz.playlist", title: "My Playlists"),
                    Linn.LibraryItem(id: "qobuz-purchased", kind: "md.container", title: "Purchased"),
                ]
            ),
            "qobuz-favourites": Linn.LibraryPage(
                id: "qobuz-favourites",
                contentRevision: contentRevision,
                index: 0,
                count: 3,
                total: 3,
                items: [
                    Linn.LibraryItem(id: "qobuz-favourite-albums", kind: "md.container.qobuz.album", title: "Albums"),
                    Linn.LibraryItem(id: "qobuz-favourite-artists", kind: "md.container", title: "Artist"),
                    Linn.LibraryItem(id: "qobuz-favourite-playlists", kind: "md.container", title: "Playlists"),
                ]
            ),
            "qobuz-favourite-albums": Linn.LibraryPage(
                id: "qobuz-favourite-albums",
                contentRevision: contentRevision,
                index: 0,
                count: 2,
                total: 2,
                items: [
                    Linn.LibraryItem(
                        id: "qobuz-album-happy-christmas",
                        kind: "md.album.qobuz",
                        title: "Happy Christmas",
                        subtitle: "Frank Sinatra",
                        album: "Happy Christmas",
                        artists: ["Frank Sinatra"],
                        artworkURL: URL(string: "https://static.qobuz.com/images/covers/25/04/3610152050425_230.jpg"),
                        containedKinds: ["md.track.qobuz"],
                        childCount: 50,
                        isFavourite: true,
                        canFavourite: true
                    ),
                    Linn.LibraryItem(
                        id: "qobuz-album-shostakovich-quartets",
                        kind: "md.album.qobuz",
                        title: "Shostakovich: Complete String Quartets, Vol. 2, Nos. 6-12",
                        subtitle: "Cuarteto Casals",
                        album: "Shostakovich: Complete String Quartets, Vol. 2, Nos. 6-12",
                        artists: ["Cuarteto Casals"],
                        artworkURL: URL(string: "https://static.qobuz.com/images/covers/ob/zn/wozp8tpq0znob_230.jpg"),
                        containedKinds: ["md.track.qobuz"],
                        childCount: 30,
                        isFavourite: true,
                        canFavourite: true
                    ),
                ]
            ),
            "qobuz-favourite-artists": Linn.LibraryPage(
                id: "qobuz-favourite-artists",
                contentRevision: contentRevision,
                index: 0,
                count: 1,
                total: 1,
                items: [
                    Linn.LibraryItem(
                        id: "qobuz-artist-qrion",
                        kind: "md.artist.qobuz",
                        title: "Qrion",
                        subtitle: "Qrion",
                        artists: ["Qrion"],
                        artworkURL: URL(string: "https://static.qobuz.com/images/artists/covers/small/afd716d782ba6b056d5a311b0bed0573.jpg"),
                        isFavourite: true,
                        canFavourite: true
                    ),
                ]
            ),
            "qobuz-favourite-playlists": Linn.LibraryPage(
                id: "qobuz-favourite-playlists",
                contentRevision: contentRevision,
                index: 0,
                count: 2,
                total: 2,
                items: [
                    Linn.LibraryItem(
                        id: "qobuz-playlist-willkommen",
                        kind: "md.playlist.qobuz",
                        title: "Willkommen bei Qobuz",
                        artworkURL: URL(string: "https://static.qobuz.com/images/playlists/1285072_2bc9b2d5023757d1a8b10db915efd367_rectangle.jpg"),
                        containedKinds: ["md.track.qobuz"],
                        childCount: 125
                    ),
                    Linn.LibraryItem(
                        id: "qobuz-playlist-true-sound-covers",
                        kind: "md.playlist.qobuz",
                        title: "True Sound Covers",
                        artworkURL: URL(string: "https://static.qobuz.com/images/covers/13/05/0093624980513_300.jpg"),
                        containedKinds: ["md.track.qobuz"],
                        childCount: 50
                    ),
                ]
            ),
            "qobuz-my-playlists": Linn.LibraryPage(
                id: "qobuz-my-playlists",
                contentRevision: contentRevision,
                index: 0,
                count: 2,
                total: 2,
                items: [
                    Linn.LibraryItem(
                        id: "qobuz-playlist-demo",
                        kind: "md.playlist.qobuz",
                        title: "Demo",
                        artworkURL: URL(string: "https://static.qobuz.com/images/covers/09/32/0088807203209_300.jpg"),
                        containedKinds: ["md.track.qobuz"],
                        childCount: 17
                    ),
                    Linn.LibraryItem(
                        id: "qobuz-playlist-cello-henry-bedtime",
                        kind: "md.playlist.qobuz",
                        title: "\"Cello\" (Henry bedtime)",
                        artworkURL: URL(string: "https://static.qobuz.com/images/covers/43/80/0884977868043_300.jpg"),
                        containedKinds: ["md.track.qobuz"],
                        childCount: 8
                    ),
                ]
            ),
            "qobuz-purchased": Linn.LibraryPage(
                id: "qobuz-purchased",
                contentRevision: contentRevision,
                index: 0,
                count: 1,
                total: 1,
                items: [
                    Linn.LibraryItem(
                        id: "qobuz-album-hit-me-hard-and-soft",
                        kind: "md.album.qobuz",
                        title: "HIT ME HARD AND SOFT",
                        subtitle: "Billie Eilish",
                        album: "HIT ME HARD AND SOFT",
                        artists: ["Billie Eilish"],
                        artworkURL: URL(string: "https://static.qobuz.com/images/covers/kc/95/gvcirtodd95kc_230.jpg"),
                        containedKinds: ["md.track.qobuz"],
                        childCount: 10,
                        isFavourite: true,
                        canFavourite: true
                    ),
                ]
            ),
        ]
    }

    func seedNestedQobuzLibrary(contentRevision: Int) {
        services = [
            Linn.LibraryService(id: "service-qobuz", name: "Qobuz", kind: "md.qobuz"),
        ]
        mediaPages = [
            "service-qobuz": Linn.LibraryPage(
                id: "service-qobuz",
                contentRevision: contentRevision,
                index: 0,
                count: 3,
                total: 3,
                items: [
                    Linn.LibraryItem(id: "qobuz-discover", kind: "md.qobuz.discover", title: "Discover"),
                    Linn.LibraryItem(id: "qobuz-genres", kind: "md.qobuz.genres", title: "Genres"),
                    Linn.LibraryItem(id: "qobuz-myqobuz", kind: "md.qobuz.myqobuz", title: "My Qobuz"),
                ]
            ),
            "qobuz-myqobuz": Linn.LibraryPage(
                id: "qobuz-myqobuz",
                contentRevision: contentRevision,
                index: 0,
                count: 3,
                total: 3,
                items: [
                    Linn.LibraryItem(id: "qobuz-favourites", kind: "md.container", title: "Favourites"),
                    Linn.LibraryItem(id: "qobuz-my-playlists", kind: "md.container.qobuz.playlist", title: "My Playlists"),
                    Linn.LibraryItem(id: "qobuz-purchased", kind: "md.container", title: "Purchased"),
                ]
            ),
            "qobuz-favourites": Linn.LibraryPage(
                id: "qobuz-favourites",
                contentRevision: contentRevision,
                index: 0,
                count: 3,
                total: 3,
                items: [
                    Linn.LibraryItem(id: "qobuz-favourite-albums", kind: "md.container.qobuz.album", title: "Albums"),
                    Linn.LibraryItem(id: "qobuz-favourite-artists", kind: "md.container", title: "Artist"),
                    Linn.LibraryItem(id: "qobuz-favourite-playlists", kind: "md.container", title: "Playlists"),
                ]
            ),
            "qobuz-favourite-albums": Linn.LibraryPage(
                id: "qobuz-favourite-albums",
                contentRevision: contentRevision,
                index: 0,
                count: 1,
                total: 1,
                items: [
                    Linn.LibraryItem(
                        id: "qobuz-album-chopin-nocturnes",
                        kind: "md.album.qobuz",
                        title: "Chopin: The Complete Nocturnes",
                        subtitle: "Tom Hicks",
                        album: "Chopin: The Complete Nocturnes",
                        artists: ["Tom Hicks"],
                        artworkURL: URL(string: "https://static.qobuz.com/images/covers/yc/ag/nuuxf36hoagyc_230.jpg"),
                        containedKinds: ["md.track.qobuz"],
                        childCount: 21,
                        isFavourite: true,
                        canFavourite: true
                    ),
                ]
            ),
            "qobuz-favourite-artists": Linn.LibraryPage(
                id: "qobuz-favourite-artists",
                contentRevision: contentRevision,
                index: 0,
                count: 0,
                total: 0,
                items: []
            ),
            "qobuz-favourite-playlists": Linn.LibraryPage(
                id: "qobuz-favourite-playlists",
                contentRevision: contentRevision,
                index: 0,
                count: 0,
                total: 0,
                items: []
            ),
            "qobuz-my-playlists": Linn.LibraryPage(
                id: "qobuz-my-playlists",
                contentRevision: contentRevision,
                index: 0,
                count: 0,
                total: 0,
                items: []
            ),
            "qobuz-purchased": Linn.LibraryPage(
                id: "qobuz-purchased",
                contentRevision: contentRevision,
                index: 0,
                count: 0,
                total: 0,
                items: []
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
) -> Linn.Snapshot {
    func song(at index: Int) -> Linn.Song {
        .init(
            id: "song-\(index)",
            title: titles[index],
            artist: "Artist \(index)",
            album: "Album \(index)",
            duration: 180 + index,
            queueIndex: index
        )
    }
    var snapshot = Linn.Snapshot()
    snapshot.playState = .playing
    snapshot.currentSong = song(at: index)
    snapshot.playlist = .init(
        songs: (playlistIndexes ?? Array(titles.indices)).map { song(at: $0) },
        currentIndex: index,
        total: titles.count
    )
    snapshot.timeline = .init(position: position, duration: 180, progress: Double(position) / 180)
    snapshot.volume = volume
    snapshot.isMuted = false
    return snapshot
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
