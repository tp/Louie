import Foundation
import Linn
@testable import LinnNowPlaying
import Synchronization
import Testing

// TestFlight builds always carry a push identity, so APNs keeps the content current
// while the extension's own WatchState stream decides whether commands can be sent.
@MainActor
private func pushedAttributes() -> LinnSessionAttributes {
    let linn = Linn(mockRoom: "Linn", currentSong: .init(id: "song", title: "Song"),
                    previousSongs: [.init(id: "previous", title: "Previous")], playState: .playing,
                    hasPrevious: true, hasNext: true)
    return LinnSessionAttributes(linn: linn, serverURL: URL(string: "http://louie-pi.local:50051")!,
        installationID: "test", pushEnvironment: "production")
}

private func serverFrame(_ connection: Linn.ConnectionState = .connected) -> Linn.Snapshot {
    var frame = Linn.Snapshot(connectionState: connection)
    frame.playState = .playing
    frame.currentSong = .init(id: "song", title: "Song")
    frame.playlist = .init(currentIndex: 1, total: 3)
    return frame
}

/// PiLinnGateway yields this itself whenever a WatchState attempt fails.
private let unreachable = Linn.Snapshot(connectionState: .serverUnreachable)

@Test @MainActor
func pushedContentStaysButCommandsStopAfterTwoConsecutiveUnreachableEvents() {
    let pushed = pushedAttributes()
    let model = LinnMediaSession(attributes: pushed)
    #expect(model.canSendCommands)

    // Resuming at home: the reclaimed socket fails once, then the 1 s retry reaches the server.
    model.receive(unreachable)
    #expect(model.canSendCommands, "One failed attempt must not hide controls on every resume")
    model.receive(serverFrame())
    model.receive(unreachable)
    #expect(model.canSendCommands, "A server frame in between resets the failure count")

    // The retry failed as well: this phone has no route to Louie Home Server.
    model.receive(unreachable)
    #expect(!model.canSendCommands, "Lock Screen commands cannot be delivered and must not look available")
    #expect(model.content != nil, "APNs-backed content stays visible off the home network")
    #expect(model.commands.count == 6, "Controls stay listed and are only disabled")

    // APNs describes the server's view (canControlPlayback: true), not this phone's route.
    model.update(pushed)
    #expect(!model.canSendCommands)

    model.receive(serverFrame())
    #expect(model.canSendCommands)
}

@Test @MainActor
func pendingSongFrameStillProvesReachability() {
    let model = LinnMediaSession(attributes: pushedAttributes())
    model.receive(unreachable)
    model.receive(unreachable)
    #expect(!model.canSendCommands)

    let previous = model.attributes
    var pending = Linn.Snapshot()
    pending.playState = .playing
    pending.pending.currentItem = true
    model.receive(pending)
    #expect(model.attributes == previous, "An unknown song still keeps the existing session")
    #expect(model.canSendCommands, "Any frame from the server proves this phone reaches it")
}

@Test(arguments: [Linn.ConnectionState.connecting, .linnUnavailable("Linn is offline")]) @MainActor
func serverFramesAboutLinnStillProveTheServerIsReachable(connection: Linn.ConnectionState) {
    let model = LinnMediaSession(attributes: pushedAttributes())
    model.receive(unreachable)
    model.receive(unreachable)
    #expect(!model.canReachServer)
    model.receive(Linn.Snapshot(connectionState: connection))
    #expect(model.canReachServer)
}

@Test @MainActor
func pushUpdateRestartsAStoppedMonitorSoControlsCanRecover() async throws {
    let pushed = pushedAttributes()
    let gateway = WatchGateway(first: .failsForGood)
    let model = LinnMediaSession(attributes: pushed, gateway: gateway)
    model.startMonitoring()
    #expect(await canSendCommands(false, in: model), "A stream that failed for good disables controls at once")
    #expect(model.content != nil, "APNs-backed content stays visible")

    // Back home, an APNs or app update wakes the extension. Disabled controls cannot reach
    // perform(_:), so the update itself must give the monitor another attempt.
    model.update(pushed)
    #expect(await canSendCommands(true, in: model))
    let subscriptions = await gateway.subscriptions
    #expect(subscriptions == 2)
}

@Test @MainActor
func restartingABackingOffMonitorKeepsExactlyOneWatchStateSubscription() async throws {
    let pushed = pushedAttributes()
    let gateway = WatchGateway(first: .backsOff)
    let model = LinnMediaSession(attributes: pushed, gateway: gateway)
    model.startMonitoring()
    #expect(await canSendCommands(false, in: model))
    model.update(pushed)
    #expect(await canSendCommands(true, in: model))
    #expect(gateway.liveSubscriptions == 1, "The backing-off predecessor's WatchState must be cancelled")

    // A later command must reuse the live subscription. If the cancelled predecessor cleared
    // its replacement's handle, perform(_:) would open a parallel WatchState stream.
    try await model.perform(.play)
    for _ in 0..<100 {
        if await gateway.subscriptions > 2 { break }
        await Task.yield()
    }
    let subscriptions = await gateway.subscriptions
    #expect(subscriptions == 2)
    #expect(gateway.liveSubscriptions == 1)
}

@Test @MainActor
func systemVolumeRestartsAStoppedMonitorLikeCommands() async throws {
    let gateway = WatchGateway(first: .failsForGood)
    let model = LinnMediaSession(attributes: pushedAttributes(), gateway: gateway)
    model.startMonitoring()
    #expect(await canSendCommands(false, in: model))
    try await model.setVolume(0.5)
    #expect(await canSendCommands(true, in: model))
    let calls = await gateway.calls
    #expect(calls == ["volume:35"])
}

@Test @MainActor
func supersededSystemVolumeIsNotReportedAsAFailure() async throws {
    // PiLinnGateway maps the server's "superseded" status to CancellationError when a newer
    // volume from any controller replaces a waiting one.
    let gateway = WatchGateway(supersedesVolume: true)
    let model = LinnMediaSession(attributes: pushedAttributes(), gateway: gateway)
    await #expect(throws: Never.self) { try await model.setVolume(0.4) }
    let calls = await gateway.calls
    #expect(calls == ["volume:28"])
}

/// Event-driven wait on the observable session; the bound only matters when the expectation fails.
@MainActor
private func canSendCommands(_ expected: Bool, in model: LinnMediaSession) async -> Bool {
    let waiter = Task { @MainActor in
        for await value in Observations({ model.canSendCommands }) where value == expected { return true }
        return false
    }
    let bound = Task {
        try? await Task.sleep(for: .seconds(2))
        waiter.cancel()
    }
    defer { bound.cancel() }
    return await waiter.value
}

/// The extension's WatchState: the first subscription fails, later ones reach the server and stay open.
private actor WatchGateway: LinnGateway {
    enum FirstSubscription {
        /// The stream ends with an error, like an incompatible server (the monitor's terminal catch-all).
        case failsForGood
        /// Like PiLinnGateway.updates: the attempt and its 1 s retry fail, then the stream backs off.
        case backsOff
    }
    enum Failure: Error { case incompatibleServer, unexpectedCall }

    private let first: FirstSubscription
    private let supersedesVolume: Bool
    private(set) var subscriptions = 0
    private(set) var calls: [String] = []
    /// Streams not yet terminated. Cancelling a consumer terminates its stream synchronously.
    private let open = Mutex(0)
    nonisolated var liveSubscriptions: Int { open.withLock { $0 } }

    init(first: FirstSubscription = .backsOff, supersedesVolume: Bool = false) {
        self.first = first
        self.supersedesVolume = supersedesVolume
    }

    func nowPlayingUpdates(room: String?, updateInterval: Int) async -> AsyncThrowingStream<Linn.Snapshot, Error> {
        subscriptions += 1
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: Linn.Snapshot.self)
        open.withLock { $0 += 1 }
        continuation.onTermination = { _ in self.open.withLock { $0 -= 1 } }
        if subscriptions > 1 {
            continuation.yield(serverFrame())
        } else {
            switch first {
            case .failsForGood:
                continuation.finish(throwing: Failure.incompatibleServer)
            case .backsOff:
                continuation.yield(unreachable)
                continuation.yield(unreachable)
            }
        }
        return stream
    }

    func setVolume(_ volume: Int, room: String, group: Bool) async throws {
        calls.append("volume:\(volume)")
        if supersedesVolume { throw CancellationError() }
    }

    func play(room: String) async throws { calls.append("play") }
    func pause(room: String) async throws { calls.append("pause") }
    func previous(room: String) async throws { calls.append("previous") }
    func next(room: String) async throws { calls.append("next") }
    func wake(room: String) async throws { throw Failure.unexpectedCall }
    func seek(to position: Int, room: String) async throws { throw Failure.unexpectedCall }
    func selectPlaylistItem(at index: Int, room: String) async throws { throw Failure.unexpectedCall }
    func setMuted(_ isMuted: Bool, room: String, group: Bool) async throws { throw Failure.unexpectedCall }
    func mediaServices(room: String) async throws -> [Linn.LibraryService] { throw Failure.unexpectedCall }
    func browseMedia(mediaID: String, index: Int, count: Int, browseType: String) async throws -> Linn.LibraryPage { throw Failure.unexpectedCall }
    func searchMedia(serviceID: String, query: String, type: Linn.SearchType, index: Int, count: Int) async throws -> Linn.LibraryPage { throw Failure.unexpectedCall }
    func selectMedia(mediaID: String, room: String, queue: Linn.QueuePlacement) async throws { throw Failure.unexpectedCall }
    func setMediaFavourite(mediaID: String, isFavourite: Bool) async throws { throw Failure.unexpectedCall }
}
