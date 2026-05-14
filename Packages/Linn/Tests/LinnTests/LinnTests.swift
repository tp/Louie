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

    #expect(linn.currentSong?.title == "Three")
    #expect(linn.timeline == nil)
    #expect(linn.songTransitionDirection == .forward)

    try await waitUntil {
        await gateway.selectedPlaylistIndexes() == [3]
    }
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
}

private actor TestGateway: LinnGateway {
    private let stream: AsyncThrowingStream<CiGateway.NowPlaying, Error>
    private let continuation: AsyncThrowingStream<CiGateway.NowPlaying, Error>.Continuation
    private var selectedIndexes: [Int] = []

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

    func previous(room _: String) async throws {}

    func next(room _: String) async throws {}

    func selectPlaylistItem(at index: Int, room _: String) async throws {
        selectedIndexes.append(index)
    }

    func setVolume(_: Int, room _: String, group _: Bool) async throws {}

    func setMuted(_: Bool, room _: String, group _: Bool) async throws {}

    func send(_ update: CiGateway.NowPlaying) {
        continuation.yield(update)
    }

    func selectedPlaylistIndexes() -> [Int] {
        selectedIndexes
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
