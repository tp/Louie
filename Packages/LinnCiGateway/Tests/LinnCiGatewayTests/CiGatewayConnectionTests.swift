import Foundation
@testable import LinnCiGateway
import Testing

@Suite(.timeLimit(.minutes(1)))
struct CiGatewayConnectionTests {
    @Test func concurrentCallersShareOneHandshake() async throws {
        let socket = FakeGatewaySocket(automaticHandshake: false)
        let factory = SocketFactory([socket])
        let connection = makeConnection(factory)
        defer { await connection.close() }

        let play = await connection.begin { try await $0.play(room: "Room") }
        _ = try await socket.nextRequest("/session/create")
        let pause = await connection.begin { try await $0.pause(room: "Room") }
        #expect(factory.count == 1)

        socket.inject(#"{"requestPath":"/session/create","session":"shared"}"#)
        _ = try await socket.nextRequest("/V2/topology/status")
        socket.inject(#"{"requestPath":"/V2/topology/status","data":{"rooms":[{"name":"Room"}]}}"#)
        let first = try await socket.sent.next()
        let second = try await socket.sent.next()
        #expect(Set([first.requestPath, second.requestPath]) == ["/V2/transport/play", "/V2/transport/pause"])
        #expect(first.session == "shared" && second.session == "shared")
        #expect(first.tag != second.tag)
        try socket.acknowledge(second)
        try socket.acknowledge(first)
        try await play.value
        try await pause.value
        #expect(factory.count == 1)
    }

    @Test func sharedHandshakeFailureReachesAllCallersAndNextCallCanRetry() async throws {
        let failed = FakeGatewaySocket(automaticHandshake: false)
        let recovered = FakeGatewaySocket(session: "recovered")
        let factory = SocketFactory([failed, recovered])
        let connection = makeConnection(factory)
        defer { await connection.close() }

        let first = await connection.begin { try await $0.play(room: "Room") }
        _ = try await failed.nextRequest("/session/create")
        let second = await connection.begin { try await $0.pause(room: "Room") }
        failed.drop()
        await #expect(throws: SocketTestError.disconnected) { try await first.value }
        await #expect(throws: SocketTestError.disconnected) { try await second.value }
        #expect(failed.isCancelled)
        #expect(factory.count == 1)

        let retry = await connection.begin { try await $0.play(room: "Room") }
        let request = try await recovered.nextRequest("/V2/transport/play")
        try recovered.acknowledge(request)
        try await retry.value
        #expect(factory.count == 2)
    }

    @Test func cancellingOneCallerDoesNotCancelSharedHandshake() async throws {
        let socket = FakeGatewaySocket(automaticHandshake: false)
        let connection = makeConnection(SocketFactory([socket]))
        defer { await connection.close() }
        let cancelled = await connection.begin { try await $0.play(room: "Room") }
        _ = try await socket.nextRequest("/session/create")
        let surviving = await connection.begin { try await $0.pause(room: "Room") }
        cancelled.cancel()
        socket.inject(#"{"requestPath":"/session/create","session":"shared"}"#)
        _ = try await socket.nextRequest("/V2/topology/status")
        socket.inject(#"{"requestPath":"/V2/topology/status","data":{"rooms":[{"name":"Room"}]}}"#)
        let request = try await socket.nextRequest("/V2/transport/pause")
        try socket.acknowledge(request)
        try await surviving.value
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(!socket.isCancelled)
        #expect(!socket.requests.contains { $0.requestPath == "/V2/transport/play" })
    }

    @Test func closingDuringHandshakeCannotPublishTheOldConnection() async throws {
        let old = FakeGatewaySocket(automaticHandshake: false)
        let fresh = FakeGatewaySocket(session: "fresh")
        let factory = SocketFactory([old, fresh])
        let connection = makeConnection(factory)
        defer { await connection.close() }
        let opening = await connection.begin { try await $0.play(room: "Room") }
        _ = try await old.nextRequest("/session/create")
        await connection.close()
        let next = await connection.begin { try await $0.pause(room: "Room") }
        await #expect(throws: CancellationError.self) { try await opening.value }
        #expect(old.isCancelled)
        let request = try await fresh.nextRequest("/V2/transport/pause")
        #expect(request.session == "fresh")
        try fresh.acknowledge(request)
        try await next.value
        #expect(factory.count == 2)
    }

    @Test func handshakeTimeoutCancelsItsSocket() async throws {
        let socket = FakeGatewaySocket(automaticHandshake: false)
        let sleeper = ManualSleeper()
        let connection = makeConnection(SocketFactory([socket]), sleeper: sleeper)
        defer { await connection.close() }
        let opening = await connection.begin { try await $0.play(room: "Room") }
        let timeout = try await sleeper.nextSleep(for: .seconds(10))
        timeout.release.send(())
        do {
            try await opening.value
            Issue.record("Expected session timeout")
        } catch CiGateway.GatewayError.timedOut(let context) {
            #expect(context == "session create")
        }
        #expect(socket.isCancelled)
    }

    @Test func wrongTagAndWrongPathDoNotAcknowledgeCommand() async throws {
        let socket = FakeGatewaySocket()
        let sleeper = ManualSleeper()
        let connection = makeConnection(SocketFactory([socket]), sleeper: sleeper)
        defer { await connection.close() }
        let command = await connection.begin { try await $0.play(room: "Room") }
        let request = try await socket.nextRequest("/V2/transport/play")
        let probe = NowPlayingProbe(connection.nowPlayingEvents(room: "Room", updateInterval: 1))
        defer { probe.task.cancel() }
        _ = try await socket.nextRequest("/V2/playlist/subscribe")
        socket.inject(#"{"requestPath":"/V2/transport/play","tag":"unrelated"}"#)
        socket.inject("{\"requestPath\":\"/V2/transport/pause\",\"tag\":\"\(request.tag!)\"}")
        // This later stream update proves the preceding replies were handled
        // before advancing the command timeout.
        socket.inject(#"{"requestPath":"/V2/volume/status","data":{"volume":44}}"#)
        _ = try await probe.next { $0.roomState?.volume == 44 }
        let timeout = try await sleeper.nextSleep(for: .seconds(2))
        timeout.release.send(())
        do {
            try await command.value
            Issue.record("An unrelated reply completed the command")
        } catch CiGateway.GatewayError.timedOut(let path) {
            #expect(path == "/V2/transport/play")
        }
    }

    @Test func taggedResponseIsDecodedAndCommandErrorsPropagate() async throws {
        let socket = FakeGatewaySocket()
        let connection = makeConnection(SocketFactory([socket]))
        defer { await connection.close() }
        let services = await connection.begin { try await $0.mediaServices(room: "Room") }
        let request = try await socket.nextRequest("/V2/services/status")
        socket.inject("""
        {"requestPath":"/V2/services/status","tag":"wrong","data":{"children":[{"id":"wrong","name":"Wrong tag"}]}}
        """)
        socket.inject("""
        {"requestPath":"/V2/media/browse","tag":"\(request.tag!)","data":{"children":[{"id":"wrong","name":"Wrong path"}]}}
        """)
        socket.inject("""
        {"requestPath":"/V2/services/status","tag":"\(request.tag!)","data":{"children":[{"id":"qobuz","name":"Qobuz"}]}}
        """)
        #expect(try await services.value.map(\.name) == ["Qobuz"])

        let command = await connection.begin { try await $0.play(room: "Room") }
        let play = try await socket.nextRequest("/V2/transport/play")
        socket.inject("""
        {"requestPath":"/V2/transport/play","tag":"\(play.tag!)","errorCode":42,"message":"Unavailable"}
        """)
        do {
            try await command.value
            Issue.record("Expected gateway rejection")
        } catch CiGateway.GatewayError.commandFailed(let code, let message) {
            #expect(code == 42 && message == "Unavailable")
        }
    }

    @Test func responseTimeoutAndCancellationLeaveConnectionUsable() async throws {
        let socket = FakeGatewaySocket()
        let sleeper = ManualSleeper()
        let connection = makeConnection(SocketFactory([socket]), sleeper: sleeper)
        defer { await connection.close() }
        let services = await connection.begin { try await $0.mediaServices(room: "Room") }
        _ = try await socket.nextRequest("/V2/services/status")
        let timeout = try await sleeper.nextSleep(for: .seconds(5))
        timeout.release.send(())
        do {
            _ = try await services.value
            Issue.record("Expected response timeout")
        } catch CiGateway.GatewayError.timedOut(let path) {
            #expect(path == "/V2/services/status")
        }
        let cancelled = await connection.begin { try await $0.play(room: "Room") }
        let old = try await socket.nextRequest("/V2/transport/play")
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        try socket.acknowledge(old) // Late replies must not resume a continuation twice.
        let next = await connection.begin { try await $0.pause(room: "Room") }
        try socket.acknowledge(try await socket.nextRequest("/V2/transport/pause"))
        try await next.value
    }

    @Test func sendFailurePropagates() async throws {
        let socket = FakeGatewaySocket()
        socket.failSends(to: "/V2/transport/play")
        let connection = makeConnection(SocketFactory([socket]))
        defer { await connection.close() }
        await #expect(throws: SocketTestError.sendFailed) { try await connection.play(room: "Room") }
    }

    @Test func volumeCoalescingSendsLatestAndMuteHasIndependentLane() async throws {
        let socket = FakeGatewaySocket()
        let connection = makeConnection(SocketFactory([socket]))
        defer { await connection.close() }
        let first = await connection.begin { try await $0.setVolume(10, room: "Room", group: false) }
        let initial = try await socket.nextRequest("/V2/volume/set_vol")
        let superseded = await connection.begin { try await $0.setVolume(20, room: "Room", group: false) }
        let latest = await connection.begin { try await $0.setVolume(30, room: "Room", group: false) }
        await #expect(throws: CancellationError.self) { try await superseded.value }
        let mute = await connection.begin { try await $0.setMuted(true, room: "Room", group: false) }
        let muteRequest = try await socket.nextRequest("/V2/volume/set_mute")
        #expect(muteRequest.mute == true)
        try socket.acknowledge(muteRequest)
        try await mute.value
        try socket.acknowledge(initial)
        try await first.value
        let final = try await socket.nextRequest("/V2/volume/set_vol")
        #expect(final.volume == 30)
        try socket.acknowledge(final)
        try await latest.value
        #expect(socket.requests.filter { $0.requestPath == "/V2/volume/set_vol" }.map(\.volume) == [10, 30])
    }

    @Test func cancelledQueuedVolumeIsNotSentAndTimeoutReleasesLane() async throws {
        let socket = FakeGatewaySocket()
        let sleeper = ManualSleeper()
        let connection = makeConnection(SocketFactory([socket]), sleeper: sleeper)
        defer { await connection.close() }
        let first = await connection.begin { try await $0.setVolume(10, room: "Room", group: false) }
        _ = try await socket.nextRequest("/V2/volume/set_vol")
        let queued = await connection.begin { try await $0.setVolume(20, room: "Room", group: false) }
        queued.cancel()
        await #expect(throws: CancellationError.self) { try await queued.value }
        let latest = await connection.begin { try await $0.setVolume(30, room: "Room", group: false) }
        let timeout = try await sleeper.nextSleep(for: .seconds(2))
        timeout.release.send(())
        do {
            try await first.value
            Issue.record("Expected volume timeout")
        } catch CiGateway.GatewayError.timedOut(let path) {
            #expect(path == "/V2/volume/set_vol")
        }
        let final = try await socket.nextRequest("/V2/volume/set_vol")
        #expect(final.volume == 30)
        try socket.acknowledge(final)
        try await latest.value
        #expect(socket.requests.filter { $0.requestPath == "/V2/volume/set_vol" }.map(\.volume) == [10, 30])
    }

    @Test func dropFlushesPendingWorkAndReconnectsWithBackoffAndSubscriptions() async throws {
        let socket = FakeGatewaySocket()
        let failedRetry = FakeGatewaySocket()
        failedRetry.failSends(to: "/session/create")
        let recovered = FakeGatewaySocket(session: "session-2")
        let factory = SocketFactory([socket, failedRetry, recovered])
        let sleeper = ManualSleeper()
        let connection = makeConnection(factory, sleeper: sleeper)
        defer { await connection.close() }
        let probe = NowPlayingProbe(connection.nowPlayingEvents(room: "Room", updateInterval: 1))
        defer { probe.task.cancel() }
        _ = try await socket.nextRequest("/V2/playlist/subscribe")
        socket.inject(#"{"requestPath":"/V2/volume/status","data":{"volume":44}}"#)
        socket.inject(#"{"requestPath":"/V2/transport/status","data":{"transport_state":"play"}}"#)
        _ = try await probe.next { $0.roomState?.volume == 44 && $0.playback?.transportState == .play }

        let command = await connection.begin { try await $0.setVolume(45, room: "Room", group: false) }
        _ = try await socket.nextRequest("/V2/volume/set_vol")
        let queued = await connection.begin { try await $0.setVolume(46, room: "Room", group: false) }
        let response = await connection.begin { try await $0.mediaServices(room: "Room") }
        _ = try await socket.nextRequest("/V2/services/status")
        socket.drop()
        await #expect(throws: SocketTestError.disconnected) { try await command.value }
        await #expect(throws: SocketTestError.disconnected) { try await queued.value }
        await #expect(throws: SocketTestError.disconnected) { try await response.value }
        let firstDelay = try await sleeper.nextSleep(for: .milliseconds(500))
        #expect(factory.count == 1)
        firstDelay.release.send(())
        let nextDelay = try await sleeper.nextSleep(for: .seconds(1))
        #expect(factory.count == 2)
        nextDelay.release.send(())
        _ = try await recovered.nextRequest("/V2/playlist/subscribe")
        let snapshot = try await probe.next { $0.session == "session-2" }
        #expect(snapshot.roomState?.volume == 44)
        #expect(snapshot.playback?.transportState == .play)
        #expect(factory.count == 3)
        #expect(Set(recovered.requests.filter { $0.tag?.hasPrefix("subscription-") == true }.map(\.requestPath))
            == Set(CiGateway.nowPlayingSubscriptions.map(\.requestPath)))
        let next = await connection.begin { try await $0.setVolume(47, room: "Room", group: false) }
        try recovered.acknowledge(try await recovered.nextRequest("/V2/volume/set_vol"))
        try await next.value
    }

    @Test func concurrentStreamsShareSubscriptionEvenIfOneIsCancelled() async throws {
        let socket = FakeGatewaySocket()
        let gate = socket.holdSends(to: "/V2/transport/status")
        let factory = SocketFactory([socket])
        let connection = makeConnection(factory)
        defer { await connection.close() }
        let first = NowPlayingProbe(connection.nowPlayingEvents(room: "Room", updateInterval: 1))
        defer { first.task.cancel() }
        _ = try await socket.nextRequest("/V2/transport/status")
        let second = NowPlayingProbe(connection.nowPlayingEvents(room: "Room", updateInterval: 1))
        defer { second.task.cancel() }
        first.task.cancel()
        gate.send(())
        _ = try await socket.nextRequest("/V2/playlist/subscribe")
        _ = try await second.next { $0.session == "session-1" }
        socket.inject(#"{"requestPath":"/V2/volume/status","data":{"volume":33}}"#)
        _ = try await second.next { $0.roomState?.volume == 33 }
        #expect(factory.count == 1)
        #expect(socket.requests.filter { $0.tag?.hasPrefix("subscription-") == true }.count == 5)
    }

    @Test func muteCoalescingAlsoSendsOnlyTheLatestQueuedValue() async throws {
        let socket = FakeGatewaySocket()
        let connection = makeConnection(SocketFactory([socket]))
        defer { await connection.close() }
        let first = await connection.begin { try await $0.setMuted(true, room: "Room", group: false) }
        let initial = try await socket.nextRequest("/V2/volume/set_mute")
        let superseded = await connection.begin { try await $0.setMuted(true, room: "Room", group: false) }
        let latest = await connection.begin { try await $0.setMuted(false, room: "Room", group: false) }
        await #expect(throws: CancellationError.self) { try await superseded.value }
        try socket.acknowledge(initial)
        try await first.value
        let final = try await socket.nextRequest("/V2/volume/set_mute")
        #expect(final.mute == false)
        try socket.acknowledge(final)
        try await latest.value
        #expect(socket.requests.filter { $0.requestPath == "/V2/volume/set_mute" }.count == 2)
    }

    @Test(arguments: [false, true])
    func closeOrRoomChangeClearsPreviousSnapshot(explicitClose: Bool) async throws {
        let socket = FakeGatewaySocket()
        let recovered = FakeGatewaySocket(session: "session-2", room: explicitClose ? "Room" : "Other Room")
        let sleeper = ManualSleeper()
        let connection = makeConnection(SocketFactory([socket, recovered]), sleeper: sleeper)
        defer { await connection.close() }
        let probe = NowPlayingProbe(connection.nowPlayingEvents(room: "Room", updateInterval: 1))
        defer { probe.task.cancel() }
        _ = try await socket.nextRequest("/V2/playlist/subscribe")
        socket.inject(#"{"requestPath":"/V2/volume/status","data":{"volume":44}}"#)
        _ = try await probe.next { $0.roomState?.volume == 44 }

        let nextProbe: NowPlayingProbe
        if explicitClose {
            await connection.close()
            nextProbe = NowPlayingProbe(connection.nowPlayingEvents(room: "Room", updateInterval: 1))
        } else {
            socket.drop()
            let delay = try await sleeper.nextSleep(for: .milliseconds(500))
            delay.release.send(())
            nextProbe = probe
        }
        defer { nextProbe.task.cancel() }
        _ = try await recovered.nextRequest("/V2/playlist/subscribe")
        let snapshot = try await nextProbe.next { $0.session == "session-2" }
        #expect(snapshot.roomState == nil)
        #expect(snapshot.room == recovered.room)
    }

    @Test func reconnectBackoffIsCappedAndCloseCancelsScheduledRetry() async throws {
        let socket = FakeGatewaySocket()
        let failing = (0..<7).map { _ in
            let socket = FakeGatewaySocket()
            socket.failSends(to: "/session/create")
            return socket
        }
        let factory = SocketFactory([socket] + failing)
        let sleeper = ManualSleeper()
        let connection = makeConnection(factory, sleeper: sleeper)
        defer { await connection.close() }
        let probe = NowPlayingProbe(connection.nowPlayingEvents(room: "Room", updateInterval: 1))
        defer { probe.task.cancel() }
        _ = try await socket.nextRequest("/V2/playlist/subscribe")
        _ = try await probe.next { $0.session == "session-1" }
        socket.drop()
        for delay: Duration in [.milliseconds(500), .seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(10)] {
            let sleep = try await sleeper.nextSleep(for: delay)
            sleep.release.send(())
        }
        let capped = try await sleeper.nextSleep(for: .seconds(10))
        await connection.close()
        let cancelled = try await withDeadline { try await capped.cancelled.next() }
        #expect(cancelled)
        capped.release.send(())
        #expect(factory.count == 7)
        #expect(failing.prefix(6).allSatisfy { $0.isCancelled })
    }
}

private final class NowPlayingProbe: Sendable {
    let values = TestMailbox<CiGateway.NowPlaying>()
    let task: Task<Void, Never>

    init(_ stream: AsyncThrowingStream<CiGateway.NowPlaying, Error>) {
        let values = values
        task = Task {
            do {
                for try await value in stream { values.send(value) }
            } catch {
                values.fail(error)
            }
        }
    }

    func next(where predicate: @escaping @Sendable (CiGateway.NowPlaying) -> Bool) async throws -> CiGateway.NowPlaying {
        try await withDeadline {
            while true {
                let value = try await self.values.next()
                if predicate(value) { return value }
            }
        }
    }
}
