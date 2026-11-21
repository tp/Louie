import Foundation
@testable import Linn
import Testing

// Deterministic: the fake reports each setVolume call and holds it until the
// test acknowledges or rejects it, so no wall-clock timing decides the order.

@Test(.timeLimit(.minutes(1)))
@MainActor
func volumeDragKeepsOneRequestInFlightAndEndsWithTheFinalValue() async throws {
    let gateway = VolumeTestGateway()
    var calls = gateway.calls.makeAsyncIterator()
    let linn = Linn(gateway: gateway)

    linn.setVolume(11)
    // The first value reaches the speaker without waiting for the finger to stop.
    let first = await calls.next()
    #expect(first == 11)

    // The finger keeps turning while the Home Server has not acknowledged 11.
    for volume in 12 ... 15 {
        linn.setVolume(volume)
    }
    await gateway.acknowledgeOldest()
    // Mid-drag, the newest value follows the acknowledgement; 12...14 never open an RPC.
    let midDrag = await calls.next()
    #expect(midDrag == 15)

    for volume in 16 ... 20 {
        linn.setVolume(volume)
    }
    await gateway.acknowledgeOldest()
    // The final value always goes out last.
    let final = await calls.next()
    #expect(final == 20)
    await gateway.acknowledgeOldest()

    // Sentinel: nothing else was queued behind 20.
    linn.setVolume(25)
    let sentinel = await calls.next()
    #expect(sentinel == 25)
    await gateway.acknowledgeAll()

    let sent = await gateway.sent
    let maximumInFlight = await gateway.maximumInFlight
    #expect(sent == [11, 15, 20, 25])
    #expect(maximumInFlight == 1)
}

@Test(.timeLimit(.minutes(1)))
@MainActor
func volumeUsesAGatewayAssignedAfterTheFirstRequest() async throws {
    // Linn(room:) only assigns its gateway in start(), so a sender that
    // captured the gateway when it was created would drop every later value.
    let linn = Linn(room: "Linn")
    linn.setVolume(5)

    let gateway = VolumeTestGateway()
    var calls = gateway.calls.makeAsyncIterator()
    linn.linnGateway = gateway
    linn.setVolume(6)

    var received = await calls.next()
    if received == 5 {
        await gateway.acknowledgeOldest()
        received = await calls.next()
    }
    #expect(received == 6)
    await gateway.acknowledgeAll()
}

@Test(.timeLimit(.minutes(1)))
@MainActor
func rejectedLatestVolumeRestoresTheServerVolumeImmediately() async throws {
    let gateway = VolumeTestGateway()
    var calls = gateway.calls.makeAsyncIterator()
    let linn = Linn(gateway: gateway)
    defer { linn.stop() }
    linn.start()
    await gateway.send(volumeSnapshot(volume: 10))
    try await waitForVolumeTest { linn.volume == 10 }

    linn.setVolume(30)
    let requested = await calls.next()
    #expect(requested == 30)
    await gateway.rejectOldest()
    try await waitForVolumeTest { linn.lastErrorMessage != nil }
    // The server publishes only on change, so no snapshot repairs a stale knob.
    #expect(linn.volume == 10)

    // The optimistic hold is gone: the next server reading applies at once.
    await gateway.send(volumeSnapshot(volume: 12, position: 2))
    try await waitForVolumeTest { linn.timeline?.position == 2 }
    #expect(linn.volume == 12)
}

@Test(.timeLimit(.minutes(1)))
@MainActor
func rejectedSupersededVolumeKeepsTheNewerRequest() async throws {
    let gateway = VolumeTestGateway()
    var calls = gateway.calls.makeAsyncIterator()
    let linn = Linn(gateway: gateway)
    defer { linn.stop() }
    linn.start()
    await gateway.send(volumeSnapshot(volume: 10))
    try await waitForVolumeTest { linn.volume == 10 }

    linn.setVolume(30)
    let superseded = await calls.next()
    #expect(superseded == 30)
    linn.setVolume(40)
    await gateway.rejectOldest()
    let newer = await calls.next()
    #expect(newer == 40)

    // A stale reading while 40 is in flight: the hold for 40 is still active.
    await gateway.send(volumeSnapshot(volume: 10, position: 2))
    try await waitForVolumeTest { linn.timeline?.position == 2 }
    #expect(linn.lastErrorMessage == nil)
    #expect(linn.volume == 40)
    await gateway.acknowledgeAll()
}

@Test(.timeLimit(.minutes(1)))
@MainActor
func rejectedMuteRestoresTheServerMuteState() async throws {
    let gateway = VolumeTestGateway()
    let linn = Linn(gateway: gateway)
    defer { linn.stop() }
    linn.start()
    await gateway.send(volumeSnapshot(volume: 10))
    try await waitForVolumeTest { linn.isMuted == false }

    await gateway.rejectMuteCommands()
    linn.setMuted(true)
    #expect(linn.isMuted == true)
    try await waitForVolumeTest { linn.lastErrorMessage != nil }
    #expect(linn.isMuted == false)
}

private struct VolumeRejected: Error {}

/// Holds each `setVolume` like the Home Server holds the RPC until Linn acknowledges it.
private actor VolumeTestGateway: LinnGateway {
    nonisolated let calls: AsyncStream<Int>
    private let callContinuation: AsyncStream<Int>.Continuation
    private let snapshots: AsyncThrowingStream<Linn.Snapshot, Error>
    private let snapshotContinuation: AsyncThrowingStream<Linn.Snapshot, Error>.Continuation
    private var held: [CheckedContinuation<Void, any Error>] = []
    private var shouldRejectMute = false
    private(set) var sent: [Int] = []
    private(set) var maximumInFlight = 0

    init() {
        (calls, callContinuation) = AsyncStream.makeStream(of: Int.self)
        (snapshots, snapshotContinuation) = AsyncThrowingStream.makeStream(of: Linn.Snapshot.self)
    }

    func setVolume(_ volume: Int, room _: String, group _: Bool) async throws {
        try await withCheckedThrowingContinuation { continuation in
            held.append(continuation)
            sent.append(volume)
            maximumInFlight = max(maximumInFlight, held.count)
            callContinuation.yield(volume)
        }
    }

    func acknowledgeOldest() {
        guard !held.isEmpty else { return }
        held.removeFirst().resume()
    }

    func acknowledgeAll() {
        let acknowledged = held
        held = []
        for continuation in acknowledged { continuation.resume() }
    }

    func rejectOldest() {
        guard !held.isEmpty else { return }
        held.removeFirst().resume(throwing: VolumeRejected())
    }

    func rejectMuteCommands() {
        shouldRejectMute = true
    }

    func setMuted(_: Bool, room _: String, group _: Bool) async throws {
        if shouldRejectMute { throw VolumeRejected() }
    }

    func send(_ snapshot: Linn.Snapshot) {
        snapshotContinuation.yield(snapshot)
    }

    func nowPlayingUpdates(room _: String?, updateInterval _: Int) async -> AsyncThrowingStream<Linn.Snapshot, Error> {
        snapshots
    }

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

private func volumeSnapshot(volume: Int, position: Int = 1) -> Linn.Snapshot {
    var snapshot = Linn.Snapshot()
    snapshot.playState = .playing
    snapshot.timeline = .init(position: position, duration: 180, progress: Double(position) / 180)
    snapshot.volume = volume
    snapshot.isMuted = false
    return snapshot
}

/// Waits for Linn to apply a snapshot or finish a command; the condition, not the clock, decides.
@MainActor
private func waitForVolumeTest(_ condition: @MainActor () -> Bool) async throws {
    for _ in 0 ..< 200 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(condition())
}
