import Foundation
@testable import Linn
import Observation
import Synchronization
import Testing

/// The server publishes 2-3 snapshots per acknowledged volume step. Frames that change
/// nothing must not invalidate views that read `playlist` (the root view, PlayerBar,
/// HomeView, the queue), or every knob step re-renders most of the app.
@Test(.timeLimit(.minutes(1))) @MainActor
func identicalServerFramesDoNotNotifyPlaylistObservers() async throws {
    let gateway = FrameGateway()
    let linn = Linn(gateway: gateway)
    linn.start()
    defer { linn.stop() }
    await gateway.send(frame(muted: false))
    try await waitUntil { linn.playlist.songs.count == 30 && linn.isMuted == false }

    let notified = NotificationFlag()
    withObservationTracking {
        _ = linn.playlist
    } onChange: {
        notified.set()
    }

    // Two identical frames, then one that only flips mute so we know all were applied.
    await gateway.send(frame(muted: false))
    await gateway.send(frame(muted: false))
    await gateway.send(frame(muted: true))
    try await waitUntil { linn.isMuted == true }

    #expect(!notified.value, "an unchanged playlist notified its observers")
    #expect(linn.playlist.songs.first?.id == "song|Track 0|Artist 0|Album 0")
}

/// Written from Observation's onChange, read on the main actor after the frames settle.
private final class NotificationFlag: Sendable {
    private let state = Mutex(false)
    var value: Bool { state.withLock { $0 } }
    func set() { state.withLock { $0 = true } }
}

private func frame(muted: Bool) -> Linn.Snapshot {
    var snapshot = Linn.Snapshot()
    snapshot.playState = .playing
    let songs = (0 ..< 30).map { index in
        Linn.Song(id: "playlist-\(index)", title: "Track \(index)", artist: "Artist \(index % 3)",
                  album: "Album \(index % 2)", duration: 200 + index, queueIndex: index)
    }
    snapshot.playlist = .init(songs: songs, currentIndex: 10, total: 30)
    snapshot.currentSong = songs[10]
    snapshot.volume = 20
    snapshot.isMuted = muted
    snapshot.maximumVolume = 70
    return snapshot
}

@MainActor
private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
    for _ in 0 ..< 400 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("condition never became true")
}

private actor FrameGateway: LinnGateway {
    private let snapshots: AsyncThrowingStream<Linn.Snapshot, Error>
    private let continuation: AsyncThrowingStream<Linn.Snapshot, Error>.Continuation

    init() {
        (snapshots, continuation) = AsyncThrowingStream.makeStream(of: Linn.Snapshot.self)
    }

    func send(_ snapshot: Linn.Snapshot) { continuation.yield(snapshot) }

    func nowPlayingUpdates(room _: String?, updateInterval _: Int) async -> AsyncThrowingStream<Linn.Snapshot, Error> {
        snapshots
    }

    func setVolume(_: Int, room _: String, group _: Bool) async throws {}
    func setMuted(_: Bool, room _: String, group _: Bool) async throws {}
    func wake(room _: String) async throws {}
    func play(room _: String) async throws {}
    func seek(to _: Int, room _: String) async throws {}
    func pause(room _: String) async throws {}
    func previous(room _: String) async throws {}
    func next(room _: String) async throws {}
    func selectPlaylistItem(at _: Int, room _: String) async throws {}
    func mediaServices(room _: String) async throws -> [Linn.LibraryService] { [] }
    func browseMedia(mediaID: String, index _: Int, count _: Int, browseType _: String) async throws -> Linn.LibraryPage {
        Linn.LibraryPage(id: mediaID)
    }
    func searchMedia(serviceID _: String, query _: String, type _: Linn.SearchType, index _: Int, count _: Int) async throws -> Linn.LibraryPage {
        Linn.LibraryPage(id: "search")
    }
    func selectMedia(mediaID _: String, room _: String, queue _: Linn.QueuePlacement) async throws {}
    func setMediaFavourite(mediaID _: String, isFavourite _: Bool) async throws {}
}
