import Foundation
@testable import LinnCiGateway
import Synchronization

enum SocketTestError: Error, Equatable {
    case disconnected
    case sendFailed
    case deadline
}

/// A cancellation-aware mailbox. Tests synchronize on actual sends and sleeps,
/// rather than assuming a task has run after an arbitrary wall-clock delay.
final class TestMailbox<Value: Sendable>: Sendable {
    private struct Waiter {
        var id: UUID
        var continuation: CheckedContinuation<Value, Error>
    }

    private struct State {
        var values: [Value] = []
        var waiters: [Waiter] = []
        var failure: (any Error)?
    }

    private let state = Mutex(State())

    func send(_ value: Value) {
        let waiter = state.withLock { state -> Waiter? in
            guard state.failure == nil else { return nil }
            if !state.waiters.isEmpty { return state.waiters.removeFirst() }
            state.values.append(value)
            return nil
        }
        waiter?.continuation.resume(returning: value)
    }

    func fail(_ error: any Error) {
        let waiters = state.withLock { state in
            state.failure = error
            state.values = []
            let waiters = state.waiters
            state.waiters = []
            return waiters
        }
        for waiter in waiters { waiter.continuation.resume(throwing: error) }
    }

    func next() async throws -> Value {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let result: Result<Value, Error>? = state.withLock { state in
                    if Task.isCancelled { return .failure(CancellationError()) }
                    if let failure = state.failure { return .failure(failure) }
                    if !state.values.isEmpty { return .success(state.values.removeFirst()) }
                    state.waiters.append(Waiter(id: id, continuation: continuation))
                    return nil
                }
                if let result { continuation.resume(with: result) }
            }
        } onCancel: {
            let waiter = self.state.withLock { state -> Waiter? in
                guard let index = state.waiters.firstIndex(where: { $0.id == id }) else { return nil }
                return state.waiters.remove(at: index)
            }
            waiter?.continuation.resume(throwing: CancellationError())
        }
    }
}

final class FakeGatewaySocket: GatewaySocket {
    struct Request: Decodable, Sendable {
        var requestPath: String
        var tag: String?
        var session: String?
        var volume: Int?
        var mute: Bool?
    }

    private struct State {
        var resumed = false
        var cancelled = false
        var requests: [Request] = []
        var failingPaths: Set<String> = []
        var gates: [String: TestMailbox<Void>] = [:]
    }

    private let state = Mutex(State())
    private let incoming = TestMailbox<URLSessionWebSocketTask.Message>()
    let sent = TestMailbox<Request>()
    let session: String
    let room: String
    let automaticHandshake: Bool

    init(session: String = "session-1", room: String = "Room", automaticHandshake: Bool = true) {
        self.session = session
        self.room = room
        self.automaticHandshake = automaticHandshake
    }

    var requests: [Request] { state.withLock { $0.requests } }
    var isCancelled: Bool { state.withLock { $0.cancelled } }

    func resume() { state.withLock { $0.resumed = true } }

    func cancel(with _: URLSessionWebSocketTask.CloseCode, reason _: Data?) {
        state.withLock { $0.cancelled = true }
        incoming.fail(CancellationError())
    }

    func failSends(to path: String) { state.withLock { _ = $0.failingPaths.insert(path) } }

    func holdSends(to path: String) -> TestMailbox<Void> {
        let gate = TestMailbox<Void>()
        state.withLock { $0.gates[path] = gate }
        return gate
    }
    func drop() { incoming.fail(SocketTestError.disconnected) }
    func inject(_ json: String) { incoming.send(.string(json)) }

    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        try Task.checkCancellation()
        guard case let .string(json) = message else { throw SocketTestError.sendFailed }
        let request = try JSONDecoder().decode(Request.self, from: Data(json.utf8))
        try state.withLock { state in
            guard state.resumed, !state.cancelled else { throw SocketTestError.disconnected }
            state.requests.append(request)
            if state.failingPaths.contains(request.requestPath) { throw SocketTestError.sendFailed }
        }
        sent.send(request)
        if let gate = state.withLock({ $0.gates[request.requestPath] }) {
            try await gate.next()
        }
        if automaticHandshake {
            if request.requestPath == "/session/create" {
                inject("{\"requestPath\":\"/session/create\",\"session\":\"\(session)\"}")
            } else if request.requestPath == "/V2/topology/status" {
                inject("{\"requestPath\":\"/V2/topology/status\",\"data\":{\"rooms\":[{\"name\":\"\(room)\"}]}}")
            }
        }
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        try await incoming.next()
    }

    func nextRequest(_ path: String) async throws -> Request {
        try await withDeadline {
            while true {
                let request = try await self.sent.next()
                if request.requestPath == path { return request }
            }
        }
    }

    func acknowledge(_ request: Request) throws {
        let object = ["requestPath": request.requestPath, "tag": request.tag ?? ""]
        inject(String(decoding: try JSONEncoder().encode(object), as: UTF8.self))
    }
}

final class SocketFactory: Sendable {
    private struct State {
        var sockets: [FakeGatewaySocket]
        var count = 0
    }
    private let state: Mutex<State>

    init(_ sockets: [FakeGatewaySocket]) { state = Mutex(State(sockets: sockets)) }
    var count: Int { state.withLock { $0.count } }

    func make(_: URL) -> any GatewaySocket {
        state.withLock { state in
            state.count += 1
            guard !state.sockets.isEmpty else {
                let socket = FakeGatewaySocket(automaticHandshake: false)
                socket.drop()
                return socket
            }
            return state.sockets.removeFirst()
        }
    }
}

final class ManualSleeper: Sendable {
    struct Sleep: Sendable {
        var duration: Duration
        var release: TestMailbox<Void>
        var cancelled: TestMailbox<Bool>
    }
    let scheduled = TestMailbox<Sleep>()

    func sleep(for duration: Duration) async throws {
        let release = TestMailbox<Void>()
        let cancelled = TestMailbox<Bool>()
        scheduled.send(Sleep(duration: duration, release: release, cancelled: cancelled))
        do {
            try await release.next()
            cancelled.send(false)
        } catch {
            cancelled.send(error is CancellationError)
            throw error
        }
    }

    func nextSleep(for duration: Duration) async throws -> Sleep {
        try await withDeadline {
            while true {
                let sleep = try await self.scheduled.next()
                if sleep.duration == duration { return sleep }
            }
        }
    }

    var timing: GatewayTiming { GatewayTiming(sleep: { try await self.sleep(for: $0) }) }
}

func withDeadline<Value: Sendable>(
    _ operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
    try await withThrowingTaskGroup(of: Value.self) { group in
        defer { group.cancelAll() }
        group.addTask(operation: operation)
        group.addTask {
            try await Task.sleep(for: .seconds(3))
            throw SocketTestError.deadline
        }
        return try await group.next()!
    }
}

func makeConnection(_ factory: SocketFactory, sleeper: ManualSleeper = ManualSleeper()) -> CiGatewayConnection {
    CiGatewayConnection(
        webSocketURL: URL(string: "ws://test.invalid")!,
        userAgent: "Tests",
        sessionTimeout: 10000,
        timing: sleeper.timing,
        makeSocket: { factory.make($0) }
    )
}

extension CiGatewayConnection {
    /// Start on the connection's actor and run up to the first suspension, so
    /// tests know queued commands are registered before submitting a replacement.
    func begin<Value: Sendable>(
        _ operation: @escaping @Sendable (isolated CiGatewayConnection) async throws -> Value
    ) -> Task<Value, Error> {
        Task.immediate { try await operation(self) }
    }
}
