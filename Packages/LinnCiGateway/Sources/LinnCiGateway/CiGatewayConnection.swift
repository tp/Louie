import Foundation
import OSLog

/// Tracks in-flight tagged requests on the websocket so that incoming envelopes
/// can be matched back to their continuations. One registry per result shape
/// (`Void` for fire-and-ack commands, `Data` for request/response pairs).
struct PendingRegistry<Value: Sendable> {
    struct Entry {
        var requestPath: String
        var continuation: CheckedContinuation<Value, Error>
        var timeoutTask: Task<Void, Never>
    }

    let logLabel: String
    let failureMessage: String
    private var entries: [String: Entry] = [:]

    init(logLabel: String, failureMessage: String) {
        self.logLabel = logLabel
        self.failureMessage = failureMessage
    }

    mutating func add(tag: String, entry: Entry) {
        entries[tag] = entry
    }

    mutating func complete(for envelope: CiGateway.GatewayEnvelope, value: @autoclosure () -> Value) -> Bool {
        guard let tag = envelope.tag, let entry = entries[tag] else {
            return false
        }
        guard envelope.requestPath == nil || entry.requestPath == envelope.requestPath else {
            return false
        }

        entry.timeoutTask.cancel()
        entries.removeValue(forKey: tag)
        let label = logLabel
        let failureMessage = failureMessage
        CiGateway.logger.debug("Matched \(label, privacy: .public) \(tag, privacy: .public) for \(entry.requestPath, privacy: .public)")
        if let errorCode = envelope.errorCode {
            entry.continuation.resume(
                throwing: CiGateway.GatewayError.commandFailed(
                    code: errorCode,
                    message: envelope.message ?? failureMessage
                )
            )
        } else {
            entry.continuation.resume(returning: value())
        }
        return true
    }

    mutating func timeOut(tag: String, requestPath: String) {
        guard let entry = entries.removeValue(forKey: tag) else {
            return
        }
        let label = logLabel
        CiGateway.logger.debug("\(label, privacy: .public) \(tag, privacy: .public) for \(requestPath, privacy: .public) timed out")
        entry.continuation.resume(throwing: CiGateway.GatewayError.timedOut(requestPath))
    }

    mutating func fail(tag: String, throwing error: Error) {
        guard let entry = entries.removeValue(forKey: tag) else {
            return
        }
        entry.timeoutTask.cancel()
        entry.continuation.resume(throwing: error)
    }

    mutating func cancel(tag: String) {
        fail(tag: tag, throwing: CancellationError())
    }

    mutating func finishAll(throwing error: Error) {
        for tag in Array(entries.keys) {
            fail(tag: tag, throwing: error)
        }
    }
}

actor CiGatewayConnection {
    private enum CoalescingLane: Hashable {
        case volume
        case mute
    }

    private enum CoalescedCommand: Sendable {
        case volume(room: String, group: Bool, value: Int)
        case mute(room: String, group: Bool, value: Bool)
    }

    private struct QueuedCoalescedCommand {
        var id: UUID
        var command: CoalescedCommand
        var continuation: CheckedContinuation<Void, Error>
    }

    private let webSocketURL: URL
    private let userAgent: String
    private let sessionTimeout: Int
    private let urlSession: URLSession

    private var socket: URLSessionWebSocketTask?
    private var session: String?
    private var resolvedRoom: String?
    private var receiveTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var isStarting = false

    private var streamID: UUID?
    private var continuation: AsyncThrowingStream<CiGateway.NowPlaying, Error>.Continuation?
    private var current: CiGateway.NowPlaying?
    private var streamPreferredRoom: String?
    private var streamUpdateInterval: Int?
    private var subscribedRoom: String?
    private var subscriptionUpdateInterval: Int?

    private var pendingCommands = PendingRegistry<Void>(logLabel: "command", failureMessage: "Gateway command failed")
    private var pendingResponses = PendingRegistry<Data>(logLabel: "response", failureMessage: "Gateway request failed")
    private var nextTagIndex = 0
    private var coalescingInFlight: Set<CoalescingLane> = []
    private var queuedCoalescedCommands: [CoalescingLane: QueuedCoalescedCommand] = [:]

    init(
        webSocketURL: URL,
        userAgent: String,
        sessionTimeout: Int,
        urlSession: URLSession
    ) {
        self.webSocketURL = webSocketURL
        self.userAgent = userAgent
        self.sessionTimeout = sessionTimeout
        self.urlSession = urlSession
    }

    nonisolated func nowPlayingEvents(
        room: String?,
        updateInterval: Int
    ) -> AsyncThrowingStream<CiGateway.NowPlaying, Error> {
        let id = UUID()
        return AsyncThrowingStream { continuation in
            let attachTask = Task {
                await self.attachNowPlayingStream(
                    id: id,
                    continuation: continuation,
                    preferredRoom: room,
                    updateInterval: updateInterval
                )
            }

            continuation.onTermination = { _ in
                attachTask.cancel()
                Task {
                    await self.detachNowPlayingStream(id: id)
                }
            }
        }
    }

    func play(room: String) async throws {
        try await sendPlayStateCommand(room: room, action: .play)
    }

    func pause(room: String) async throws {
        try await sendPlayStateCommand(room: room, action: .pause)
    }

    func previous(room: String) async throws {
        try await sendPlayStateCommand(room: room, skipTrack: -1)
    }

    func next(room: String) async throws {
        try await sendPlayStateCommand(room: room, skipTrack: 1)
    }

    func selectPlaylistItem(at index: Int, room: String) async throws {
        try await sendCommand(room: room, requestPath: "/V2/playlist/select") { session, tag in
            V2PlaylistSelectPostRequest(tag: tag, session: session, room: room, index: index)
        }
    }

    func setVolume(_ volume: Int, room: String, group: Bool) async throws {
        try await sendCoalesced(.volume(room: room, group: group, value: volume), lane: .volume)
    }

    func setMuted(_ isMuted: Bool, room: String, group: Bool) async throws {
        try await sendCoalesced(.mute(room: room, group: group, value: isMuted), lane: .mute)
    }

    func mediaServices(room: String) async throws -> [CiGateway.MediaService] {
        let response: V2ServicesStatusResponse = try await sendRequest(
            room: room,
            requestPath: "/V2/services/status"
        ) { session, tag in
            V2ServicesStatusGetRequest(tag: tag, session: session, room: room, update: 0)
        }

        return response.data?.children?.compactMap(CiGateway.MediaService.init) ?? []
    }

    func browse(mediaID: String, index: Int, count: Int, browseType: String) async throws -> CiGateway.MediaPage {
        let response: MediaBrowseResponse = try await sendRequest(
            preferredRoom: resolvedRoom,
            requestPath: "/V2/media/browse"
        ) { session, tag in
            V2MediaBrowseGetRequest(
                tag: tag,
                session: session,
                mediaId: mediaID,
                index: index,
                count: count,
                browseType: browseType
            )
        }

        return CiGateway.MediaPage(response.data)
    }

    func search(
        serviceID: String,
        query: String,
        type: CiGateway.MediaSearchType,
        index: Int,
        count: Int
    ) async throws -> CiGateway.MediaPage {
        let response: MediaBrowseResponse = try await sendRequest(
            preferredRoom: resolvedRoom,
            requestPath: "/V2/services/search"
        ) { session, tag in
            V2ServicesSearchGetRequest(
                tag: tag,
                session: session,
                mediaId: serviceID,
                searchArg: query,
                searchType: type.rawValue,
                index: index,
                count: count
            )
        }

        return CiGateway.MediaPage(response.data)
    }

    func select(mediaID: String, room: String, queue: CiGateway.QueuePlacement) async throws {
        try await sendCommand(room: room, requestPath: "/V2/media/select") { session, tag in
            V2MediaSelectPostRequest(
                tag: tag,
                session: session,
                room: room,
                mediaId: mediaID,
                queue: queue.rawValue
            )
        }
    }

    func setFavourite(mediaID: String, isFavourite: Bool) async throws {
        try await sendSessionCommand(requestPath: "/V2/media/favourite") { session, tag in
            V2MediaFavouritePostRequest(
                tag: tag,
                session: session,
                mediaId: mediaID,
                favourite: isFavourite
            )
        }
    }

    func close() {
        receiveTask?.cancel()
        receiveTask = nil
        socket?.cancel(with: .goingAway, reason: nil)
        reconnectTask?.cancel()
        reconnectTask = nil
        socket = nil
        session = nil
        resolvedRoom = nil
        subscribedRoom = nil
        subscriptionUpdateInterval = nil
        continuation?.finish()
        continuation = nil
        streamID = nil
        streamPreferredRoom = nil
        streamUpdateInterval = nil
        pendingCommands.finishAll(throwing: CancellationError())
        pendingResponses.finishAll(throwing: CancellationError())
        finishQueuedCoalescedCommands(throwing: CancellationError())
    }

    private func attachNowPlayingStream(
        id: UUID,
        continuation: AsyncThrowingStream<CiGateway.NowPlaying, Error>.Continuation,
        preferredRoom: String?,
        updateInterval: Int
    ) async {
        guard !Task.isCancelled else {
            return
        }

        streamID = id
        self.continuation = continuation
        streamPreferredRoom = preferredRoom
        streamUpdateInterval = updateInterval

        do {
            try await ensureConnected(preferredRoom: preferredRoom, updateInterval: updateInterval, subscribe: true)
            if let current {
                continuation.yield(current)
            }
        } catch {
            finishNowPlayingStream(id: id, throwing: error)
        }
    }

    private func detachNowPlayingStream(id: UUID) {
        guard streamID == id else {
            return
        }
        reconnectTask?.cancel()
        reconnectTask = nil
        continuation = nil
        streamID = nil
        streamPreferredRoom = nil
        streamUpdateInterval = nil
    }

    private func finishNowPlayingStream(id: UUID?, throwing error: Error? = nil) {
        guard id == nil || streamID == id else {
            return
        }

        if let error {
            continuation?.finish(throwing: error)
        } else {
            continuation?.finish()
        }
        continuation = nil
        streamID = nil
        streamPreferredRoom = nil
        streamUpdateInterval = nil
    }

    private func ensureConnected(
        preferredRoom: String?,
        updateInterval: Int?,
        subscribe: Bool
    ) async throws {
        while isStarting {
            try await Task.sleep(for: .milliseconds(50))
            if socket != nil, session != nil {
                break
            }
        }

        if socket == nil || session == nil {
            try await openConnection(preferredRoom: preferredRoom)
        }

        if subscribe, let updateInterval {
            try await subscribeToNowPlaying(preferredRoom: preferredRoom, updateInterval: updateInterval)
        }
    }

    private func openConnection(preferredRoom: String?) async throws {
        isStarting = true
        defer {
            isStarting = false
        }

        let webSocketURL = webSocketURL
        let socket = urlSession.webSocketTask(with: webSocketURL)
        CiGateway.logger.info("Opening websocket \(webSocketURL.absoluteString, privacy: .public)")
        socket.resume()

        do {
            CiGateway.logger.info("Creating gateway session")
            let session = try await CiGateway.createSession(on: socket, timeout: sessionTimeout, userAgent: userAgent)
            CiGateway.logger.info("Gateway session created \(session, privacy: .public)")

            let room = try await CiGateway.resolveRoom(preferredRoom: preferredRoom, session: session, timeout: sessionTimeout, on: socket)
            CiGateway.logger.info("Using Linn room \(room, privacy: .public)")

            self.socket = socket
            self.session = session
            resolvedRoom = room
            current = CiGateway.NowPlaying(room: room, session: session)
            startReceiveLoop(socket: socket)
        } catch {
            socket.cancel(with: .goingAway, reason: nil)
            throw error
        }
    }

    private func startReceiveLoop(socket: URLSessionWebSocketTask) {
        receiveTask?.cancel()
        receiveTask = Task {
            do {
                while !Task.isCancelled {
                    let message = try await CiGateway.receiveText(from: socket)
                    handleMessage(message)
                }
            } catch is CancellationError {
            } catch {
                handleReceiveFailure(error, from: socket)
            }
        }
    }

    private func subscribeToNowPlaying(preferredRoom: String?, updateInterval: Int) async throws {
        guard let socket, let session else {
            throw CiGateway.GatewayError.missingSession
        }

        let room = resolvedRoom ?? preferredRoom.flatMap { $0.isEmpty ? nil : $0 }
        guard let room else {
            throw CiGateway.GatewayError.noRoomsAvailable
        }

        if subscribedRoom == room, subscriptionUpdateInterval == updateInterval {
            return
        }

        for subscription in CiGateway.nowPlayingSubscriptions {
            try await subscription.send(room: room, session: session, updateInterval: updateInterval, on: socket)
        }

        subscribedRoom = room
        subscriptionUpdateInterval = updateInterval
        CiGateway.logger.info("Subscribed to now-playing updates for \(room, privacy: .public)")
    }

    private func handleMessage(_ message: String) {
        let data = Data(message.utf8)
        do {
            let envelope = try JSONDecoder().decode(CiGateway.GatewayEnvelope.self, from: data)
            if pendingResponses.complete(for: envelope, value: data) {
                return
            }
            if pendingCommands.complete(for: envelope, value: ()) {
                return
            }

            guard let update = try CiGateway.decodeNowPlayingUpdate(from: message) else {
                return
            }

            if current == nil {
                let room = resolvedRoom ?? ""
                let session = session ?? ""
                current = CiGateway.NowPlaying(room: room, session: session)
            }
            current?.merge(update)
            if let current {
                continuation?.yield(current)
            }
        } catch {
            CiGateway.logger.warning("Failed to handle gateway websocket message: \(String(describing: error), privacy: .public)")
        }
    }

    private func handleReceiveFailure(_ error: Error, from failedSocket: URLSessionWebSocketTask) {
        guard socket === failedSocket else {
            return
        }

        CiGateway.logger.warning("Gateway websocket receive loop failed: \(String(describing: error), privacy: .public)")
        tearDownDroppedConnection()
        pendingCommands.finishAll(throwing: error)
        pendingResponses.finishAll(throwing: error)
        finishQueuedCoalescedCommands(throwing: error)

        if continuation != nil {
            startReconnectLoop()
        }
    }

    private func tearDownDroppedConnection() {
        receiveTask = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        session = nil
        resolvedRoom = nil
        subscribedRoom = nil
        subscriptionUpdateInterval = nil
    }

    private func startReconnectLoop() {
        guard reconnectTask == nil else {
            return
        }

        reconnectTask = Task {
            var delay = Duration.milliseconds(500)
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: delay)
                    try await self.reconnectNowPlayingStream()
                    return
                } catch is CancellationError {
                    return
                } catch {
                    CiGateway.logger.warning("Gateway websocket reconnect failed: \(String(describing: error), privacy: .public)")
                    delay = min(delay * 2, .seconds(10))
                }
            }
        }
    }

    private func reconnectNowPlayingStream() async throws {
        guard let continuation, let updateInterval = streamUpdateInterval else {
            reconnectTask = nil
            return
        }

        try await ensureConnected(preferredRoom: streamPreferredRoom, updateInterval: updateInterval, subscribe: true)
        reconnectTask = nil

        if let current {
            continuation.yield(current)
        }
        CiGateway.logger.info("Gateway websocket reconnected")
    }

    private func sendPlayStateCommand(
        room: String,
        action: CiGateway.PlayStateAction? = nil,
        skipTrack: Int? = nil
    ) async throws {
        if let action {
            let requestPath = action == .play ? "/V2/transport/play" : "/V2/transport/pause"
            try await sendCommand(room: room, requestPath: requestPath) { session, tag in
                V2TransportPlayPostRequest(tag: tag, session: session, room: room)
            }
        } else {
            try await sendCommand(room: room, requestPath: "/V2/transport/skip_track") { session, tag in
                V2TransportSkipTrackPostRequest(tag: tag, session: session, room: room, skipTrack: skipTrack)
            }
        }
    }

    private func sendCoalesced(_ command: CoalescedCommand, lane: CoalescingLane) async throws {
        if coalescingInFlight.contains(lane) {
            let id = UUID()
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    if let queued = queuedCoalescedCommands[lane] {
                        CiGateway.logger.debug("Replacing queued \(String(describing: lane), privacy: .public) gateway command")
                        queued.continuation.resume(throwing: CancellationError())
                    }
                    queuedCoalescedCommands[lane] = QueuedCoalescedCommand(
                        id: id,
                        command: command,
                        continuation: continuation
                    )
                }
            } onCancel: {
                Task {
                    await self.cancelQueuedCoalescedCommand(id: id, lane: lane)
                }
            }
        }

        coalescingInFlight.insert(lane)
        do {
            try await send(command)
            finishCoalescedLane(lane)
        } catch {
            finishCoalescedLane(lane)
            throw error
        }
    }

    private func send(_ command: CoalescedCommand) async throws {
        switch command {
        case let .volume(room, group, value):
            try await sendCommand(room: room, requestPath: "/V2/volume/set_vol") { session, tag in
                V2VolumeSetVolPostRequest(
                    tag: tag,
                    session: session,
                    room: room,
                    volume: value,
                    group: group
                )
            }
        case let .mute(room, group, value):
            try await sendCommand(room: room, requestPath: "/V2/volume/set_mute") { session, tag in
                V2VolumeSetMutePostRequest(
                    tag: tag,
                    session: session,
                    room: room,
                    mute: value,
                    group: group
                )
            }
        }
    }

    private func finishCoalescedLane(_ lane: CoalescingLane) {
        coalescingInFlight.remove(lane)
        guard let queued = queuedCoalescedCommands.removeValue(forKey: lane) else {
            return
        }

        coalescingInFlight.insert(lane)
        Task {
            await self.runQueuedCoalescedCommand(queued, lane: lane)
        }
    }

    private func runQueuedCoalescedCommand(_ queued: QueuedCoalescedCommand, lane: CoalescingLane) async {
        do {
            try await send(queued.command)
            queued.continuation.resume()
            finishCoalescedLane(lane)
        } catch {
            queued.continuation.resume(throwing: error)
            finishCoalescedLane(lane)
        }
    }

    private func cancelQueuedCoalescedCommand(id: UUID, lane: CoalescingLane) {
        guard queuedCoalescedCommands[lane]?.id == id else {
            return
        }

        let queued = queuedCoalescedCommands.removeValue(forKey: lane)
        queued?.continuation.resume(throwing: CancellationError())
    }

    private func sendCommand<Command: Encodable & Sendable>(
        room: String,
        requestPath: String,
        build: (String, String) -> Command
    ) async throws {
        try await ensureConnected(preferredRoom: room, updateInterval: nil, subscribe: false)
        guard let socket, let session else {
            throw CiGateway.GatewayError.missingSession
        }

        let tag = nextCommandTag()
        try await sendCommandAwaitingAck(
            build(session, tag),
            requestPath: requestPath,
            tag: tag,
            socket: socket
        )
    }

    private func sendSessionCommand<Command: Encodable & Sendable>(
        requestPath: String,
        build: (String, String) -> Command
    ) async throws {
        try await ensureConnected(preferredRoom: resolvedRoom, updateInterval: nil, subscribe: false)
        guard let socket, let session else {
            throw CiGateway.GatewayError.missingSession
        }

        let tag = nextCommandTag()
        try await sendCommandAwaitingAck(
            build(session, tag),
            requestPath: requestPath,
            tag: tag,
            socket: socket
        )
    }

    private func sendRequest<Response: Decodable & Sendable, Command: Encodable & Sendable>(
        room: String,
        requestPath: String,
        build: (String, String) -> Command
    ) async throws -> Response {
        try await sendRequest(preferredRoom: room, requestPath: requestPath, build: build)
    }

    private func sendRequest<Response: Decodable & Sendable, Command: Encodable & Sendable>(
        preferredRoom: String?,
        requestPath: String,
        build: (String, String) -> Command
    ) async throws -> Response {
        try await ensureConnected(preferredRoom: preferredRoom, updateInterval: nil, subscribe: false)
        guard let socket, let session else {
            throw CiGateway.GatewayError.missingSession
        }

        let tag = nextCommandTag()
        let data = try await sendCommandAwaitingResponse(
            build(session, tag),
            requestPath: requestPath,
            tag: tag,
            socket: socket
        )
        return try JSONDecoder().decode(Response.self, from: data)
    }

    private func sendCommandAwaitingAck<Command: Encodable & Sendable>(
        _ command: Command,
        requestPath: String,
        tag: String,
        socket: URLSessionWebSocketTask
    ) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let timeoutTask = Task {
                    try? await Task.sleep(for: .seconds(2))
                    self.pendingCommands.timeOut(tag: tag, requestPath: requestPath)
                }
                pendingCommands.add(
                    tag: tag,
                    entry: .init(requestPath: requestPath, continuation: continuation, timeoutTask: timeoutTask)
                )

                Task {
                    do {
                        CiGateway.logger.debug("Sending command \(tag, privacy: .public) for \(requestPath, privacy: .public)")
                        try await CiGateway.send(command, requestPath: requestPath, on: socket)
                    } catch {
                        self.pendingCommands.fail(tag: tag, throwing: error)
                    }
                }
            }
        } onCancel: {
            Task {
                await self.cancelPendingCommand(tag: tag)
            }
        }
    }

    private func cancelPendingCommand(tag: String) {
        pendingCommands.cancel(tag: tag)
    }

    private func sendCommandAwaitingResponse<Command: Encodable & Sendable>(
        _ command: Command,
        requestPath: String,
        tag: String,
        socket: URLSessionWebSocketTask
    ) async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let timeoutTask = Task {
                    try? await Task.sleep(for: .seconds(5))
                    self.pendingResponses.timeOut(tag: tag, requestPath: requestPath)
                }
                pendingResponses.add(
                    tag: tag,
                    entry: .init(requestPath: requestPath, continuation: continuation, timeoutTask: timeoutTask)
                )

                Task {
                    do {
                        CiGateway.logger.debug("Sending request \(tag, privacy: .public) for \(requestPath, privacy: .public)")
                        try await CiGateway.send(command, requestPath: requestPath, on: socket)
                    } catch {
                        self.pendingResponses.fail(tag: tag, throwing: error)
                    }
                }
            }
        } onCancel: {
            Task {
                await self.cancelPendingResponse(tag: tag)
            }
        }
    }

    private func cancelPendingResponse(tag: String) {
        pendingResponses.cancel(tag: tag)
    }

    private func nextCommandTag() -> String {
        nextTagIndex += 1
        return "command-\(nextTagIndex)"
    }

    private func finishQueuedCoalescedCommands(throwing error: Error) {
        let queuedCommands = queuedCoalescedCommands.values
        queuedCoalescedCommands.removeAll()
        coalescingInFlight.removeAll()
        for queued in queuedCommands {
            queued.continuation.resume(throwing: error)
        }
    }
}
