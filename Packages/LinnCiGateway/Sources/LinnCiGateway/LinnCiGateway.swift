import Foundation
import OSLog

public final class CiGateway: Sendable {
    public struct NowPlaying: Sendable, Equatable {
        public var context: Context
        public var playback: Playback?
        public var queue: Queue?
        public var currentItem: CurrentItem?
        public var playlist: Playlist?
        public var timeline: Timeline?
        public var roomState: RoomState?

        public init(room: String, session: String) {
            context = Context(room: room, session: session)
        }

        public var room: String {
            context.room
        }

        public var session: String {
            context.session
        }

        public struct Context: Sendable, Equatable {
            public var room: String
            public var session: String

            public init(room: String, session: String) {
                self.room = room
                self.session = session
            }
        }

        public enum TransportState: String, Sendable, Equatable {
            case stop
            case play
            case pause
            case buffering
            case waiting
            case unknown
        }

        public struct Playback: Sendable, Equatable {
            public var transportState: TransportState?

            public init(
                transportState: TransportState? = nil
            ) {
                self.transportState = transportState
            }
        }

        public struct Queue: Sendable, Equatable {
            public var index: Int?
            public var length: Int?

            public init(index: Int? = nil, length: Int? = nil) {
                self.index = index
                self.length = length
            }
        }

        public struct RoomState: Sendable, Equatable {
            public var volume: Int?
            public var isMuted: Bool?

            public init(volume: Int? = nil, isMuted: Bool? = nil) {
                self.volume = volume
                self.isMuted = isMuted
            }
        }

        public struct Playlist: Sendable, Equatable {
            public var items: [PlaylistItem]
            public var total: Int?
            public var contentRevision: Int?

            public init(items: [PlaylistItem] = [], total: Int? = nil, contentRevision: Int? = nil) {
                self.items = items
                self.total = total
                self.contentRevision = contentRevision
            }
        }

        public struct PlaylistItem: Sendable, Equatable, Identifiable {
            public var index: Int
            public var displayName: String?
            public var album: String?
            public var artist: String?
            public var duration: Int?
            public var artworkURL: URL?

            public init(
                index: Int,
                displayName: String? = nil,
                album: String? = nil,
                artist: String? = nil,
                duration: Int? = nil,
                artworkURL: URL? = nil
            ) {
                self.index = index
                self.displayName = displayName
                self.album = album
                self.artist = artist
                self.duration = duration
                self.artworkURL = artworkURL
            }

            public var id: Int {
                index
            }
        }

        public struct CurrentItem: Sendable, Equatable, Identifiable {
            public var id: String
            public var kind: String
            public var displayName: String?
            public var artworkURL: URL?
            public var track: Track?

            public init(
                id: String,
                kind: String,
                displayName: String? = nil,
                artworkURL: URL? = nil,
                track: Track? = nil
            ) {
                self.id = id
                self.kind = kind
                self.displayName = displayName
                self.artworkURL = artworkURL
                self.track = track
            }
        }

        public struct Track: Sendable, Equatable {
            public var title: String?
            public var album: String?
            public var artist: String?

            public init(title: String? = nil, album: String? = nil, artist: String? = nil) {
                self.title = title
                self.album = album
                self.artist = artist
            }
        }

        public struct Timeline: Sendable, Equatable {
            public var position: Int?
            public var duration: Int?
            public var seekableRange: SeekableRange?

            public init(position: Int? = nil, duration: Int? = nil, seekableRange: SeekableRange? = nil) {
                self.position = position
                self.duration = duration
                self.seekableRange = seekableRange
            }

            public var progress: Double? {
                guard let position, let duration, duration > 0 else {
                    return nil
                }
                return Double(position) / Double(duration)
            }
        }

        public struct SeekableRange: Sendable, Equatable {
            public var lowerBound: Int?
            public var upperBound: Int?

            public init(lowerBound: Int? = nil, upperBound: Int? = nil) {
                self.lowerBound = lowerBound
                self.upperBound = upperBound
            }
        }
    }

    public enum GatewayError: Error, Sendable {
        case nonTextMessage
        case missingSession
        case noRoomsAvailable
        case invalidURL(String)
        case timedOut(String)
    }

    public let webSocketURL: URL
    public let userAgent: String
    public let sessionTimeout: Int

    private let connection: CiGatewayConnection
    fileprivate static let logger = Logger(subsystem: "Louie.LinnCiGateway", category: "CiGateway")

    public init(
        webSocketURL: URL,
        userAgent: String = "Louie/1.0",
        sessionTimeout: Int = 10000,
        urlSession: URLSession = .shared
    ) {
        self.webSocketURL = webSocketURL
        self.userAgent = userAgent
        self.sessionTimeout = sessionTimeout
        connection = CiGatewayConnection(
            webSocketURL: webSocketURL,
            userAgent: userAgent,
            sessionTimeout: sessionTimeout,
            urlSession: urlSession
        )
    }

    deinit {
        let connection = connection
        Task {
            await connection.close()
        }
    }

    public convenience init(
        host: String,
        port: Int = 8088,
        path: String = "/ws",
        userAgent: String = "Louie/1.0",
        sessionTimeout: Int = 10000
    ) throws {
        let urlString = "ws://\(host):\(port)\(path)"
        guard let url = URL(string: urlString) else {
            throw GatewayError.invalidURL(urlString)
        }
        self.init(webSocketURL: url, userAgent: userAgent, sessionTimeout: sessionTimeout)
    }

    public func nowPlayingEvents(
        room: String? = nil,
        updateInterval: Int = 1
    ) -> AsyncThrowingStream<NowPlaying, Error> {
        connection.nowPlayingEvents(room: room, updateInterval: updateInterval)
    }

    public func play(room: String) async throws {
        try await connection.play(room: room)
    }

    public func pause(room: String) async throws {
        try await connection.pause(room: room)
    }

    public func previous(room: String) async throws {
        try await connection.previous(room: room)
    }

    public func next(room: String) async throws {
        try await connection.next(room: room)
    }

    public func selectPlaylistItem(at index: Int, room: String) async throws {
        try await connection.selectPlaylistItem(at: index, room: room)
    }

    public func setVolume(_ volume: Int, room: String, group: Bool = true) async throws {
        try await connection.setVolume(max(0, min(100, volume)), room: room, group: group)
    }

    public func setMuted(_ isMuted: Bool, room: String, group: Bool = true) async throws {
        try await connection.setMuted(isMuted, room: room, group: group)
    }
}

private extension CiGateway {
    struct SessionCreateRequest: Encodable {
        var requestPath = "/session/create"
        var timeout: Int
        var userAgent: String
    }

    struct SubscriptionRequest: Encodable {
        var requestPath: String
        var tag: String
        var room: String
        var session: String
        var update: Int
        var filter: [String]?
    }

    struct TopologyRequest: Encodable {
        var requestPath = "/house/topology"
        var session: String
        var filter = ["$.rooms[*].id", "$.rooms[*].name"]
    }

    struct GatewayEnvelope: Decodable {
        var requestPath: String?
        var tag: String?
    }

    enum NowPlayingUpdate {
        case playState(
            room: String?,
            session: String?,
            playback: NowPlaying.Playback?,
            queue: NowPlaying.Queue?,
            currentItem: NowPlaying.CurrentItem?,
            timeline: NowPlaying.Timeline?
        )
        case position(
            room: String?,
            session: String?,
            timeline: NowPlaying.Timeline
        )
        case roomState(
            room: String?,
            session: String?,
            roomState: NowPlaying.RoomState
        )
        case playlist(
            room: String?,
            session: String?,
            playlist: NowPlaying.Playlist
        )
    }

    enum PlayStateAction: String, Encodable {
        case play
        case pause
    }

    struct RoomPlayStateCommand: Encodable {
        var requestPath = "/room/play_state/set"
        var tag: String
        var room: String
        var session: String
        var action: PlayStateAction?
        var skipTrack: Int?

        enum CodingKeys: String, CodingKey {
            case requestPath
            case tag
            case room
            case session
            case action
            case skipTrack = "skip_track"
        }
    }

    struct RoomStateCommand: Encodable {
        var requestPath = "/room/state/set"
        var tag: String
        var room: String
        var session: String
        var group: Bool?
        var mute: Bool?
        var volume: Int?
    }

    struct PlaylistSelectCommand: Encodable {
        var requestPath = "/V2/playlist/select"
        var tag: String
        var room: String
        var session: String
        var index: Int
    }

    struct PlaylistSubscriptionRequest: Encodable {
        var requestPath = "/V2/playlist/subscribe"
        var tag: String
        var room: String
        var session: String
        var index = 0
        var count = 100
        var concise = false
    }

    struct MetadataResponse<Metadata: Decodable>: Decodable {
        var data: MetadataData?

        struct MetadataData: Decodable {
            var metadata: Metadata?
        }
    }

    static func createSession(on socket: URLSessionWebSocketTask, timeout: Int, userAgent: String) async throws -> String {
        try await send(SessionCreateRequest(timeout: timeout, userAgent: userAgent), on: socket)

        while !Task.isCancelled {
            let message = try await receiveText(from: socket, timeout: .milliseconds(timeout), context: "session create")
            let envelope = try JSONDecoder().decode(GatewayEnvelope.self, from: Data(message.utf8))
            guard envelope.requestPath == "/session/create" else {
                continue
            }

            let response = try JSONDecoder().decode(SessionResponse.self, from: Data(message.utf8))
            guard let session = response.session else {
                throw GatewayError.missingSession
            }
            return session
        }

        throw GatewayError.missingSession
    }

    static func resolveRoom(
        preferredRoom: String?,
        session: String,
        timeout: Int,
        on socket: URLSessionWebSocketTask
    ) async throws -> String {
        logger.info("Requesting Linn house topology")
        try await send(TopologyRequest(session: session), on: socket)

        while !Task.isCancelled {
            let message = try await receiveText(from: socket, timeout: .milliseconds(timeout), context: "house topology")
            let envelope = try JSONDecoder().decode(GatewayEnvelope.self, from: Data(message.utf8))
            guard envelope.requestPath == "/house/topology" else {
                continue
            }

            let response = try JSONDecoder().decode(HouseTopologyResponse.self, from: Data(message.utf8))
            guard let rooms = response.data?.rooms, !rooms.isEmpty else {
                throw GatewayError.noRoomsAvailable
            }

            let roomNames = rooms.map { $0.name ?? $0.id ?? "<unnamed>" }.joined(separator: ", ")
            Self.logger.info("Received Linn rooms: \(roomNames, privacy: .public)")

            if let preferredRoom, !preferredRoom.isEmpty {
                if let matchingRoom = rooms.first(where: { $0.name == preferredRoom || $0.id == preferredRoom }) {
                    return matchingRoom.name ?? matchingRoom.id ?? preferredRoom
                }

                let availableRooms = rooms.compactMap(\.name).joined(separator: ", ")
                Self.logger.warning("Requested Linn room \(preferredRoom, privacy: .public) was not found. Available rooms: \(availableRooms, privacy: .public)")
            }

            guard let room = rooms.first?.name ?? rooms.first?.id else {
                throw GatewayError.noRoomsAvailable
            }

            return room
        }

        throw GatewayError.noRoomsAvailable
    }

    static func subscribeToPlayState(
        room: String,
        session: String,
        updateInterval: Int,
        on socket: URLSessionWebSocketTask
    ) async throws {
        try await send(
            SubscriptionRequest(
                requestPath: "/room/play_state",
                tag: "subscription-play-state",
                room: room,
                session: session,
                update: updateInterval,
                filter: nil
            ),
            on: socket
        )
        logger.debug("Sent /room/play_state subscription for \(room, privacy: .public)")
    }

    static func subscribeToPosition(
        room: String,
        session: String,
        updateInterval: Int,
        on socket: URLSessionWebSocketTask
    ) async throws {
        try await send(
            SubscriptionRequest(
                requestPath: "/room/play_state/position",
                tag: "subscription-position",
                room: room,
                session: session,
                update: updateInterval,
                filter: nil
            ),
            on: socket
        )
        logger.debug("Sent /room/play_state/position subscription for \(room, privacy: .public)")
    }

    static func subscribeToRoomState(
        room: String,
        session: String,
        updateInterval: Int,
        on socket: URLSessionWebSocketTask
    ) async throws {
        try await send(
            SubscriptionRequest(
                requestPath: "/room/state",
                tag: "subscription-room-state",
                room: room,
                session: session,
                update: updateInterval,
                filter: ["$.mute", "$.volume"]
            ),
            on: socket
        )
        logger.debug("Sent /room/state subscription for \(room, privacy: .public)")
    }

    static func subscribeToPlaylist(
        room: String,
        session: String,
        on socket: URLSessionWebSocketTask
    ) async throws {
        try await send(
            PlaylistSubscriptionRequest(tag: "subscription-playlist", room: room, session: session),
            on: socket
        )
        logger.debug("Sent /V2/playlist/subscribe for \(room, privacy: .public)")
    }

    static func send<T: Encodable>(_ value: T, on socket: URLSessionWebSocketTask) async throws {
        let data = try JSONEncoder().encode(value)
        let text = String(decoding: data, as: UTF8.self)
        Self.logger.debug("Sending websocket message \(text, privacy: .public)")
        try await socket.send(.string(text))
    }

    static func receiveText(from socket: URLSessionWebSocketTask) async throws -> String {
        switch try await socket.receive() {
        case let .string(text):
            Self.logger.debug("Received websocket message \(text, privacy: .public)")
            return text
        case let .data(data):
            guard let text = String(data: data, encoding: .utf8) else {
                throw GatewayError.nonTextMessage
            }
            Self.logger.debug("Received websocket data message \(text, privacy: .public)")
            return text
        @unknown default:
            throw GatewayError.nonTextMessage
        }
    }

    static func receiveText(
        from socket: URLSessionWebSocketTask,
        timeout: Duration,
        context: String
    ) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                try await receiveText(from: socket)
            }

            group.addTask {
                try await Task.sleep(for: timeout)
                throw GatewayError.timedOut(context)
            }

            guard let text = try await group.next() else {
                throw GatewayError.timedOut(context)
            }

            group.cancelAll()
            return text
        }
    }

    static func decodeNowPlayingUpdate(from message: String) throws -> NowPlayingUpdate? {
        let data = Data(message.utf8)
        let decoder = JSONDecoder()
        let envelope = try decoder.decode(GatewayEnvelope.self, from: data)

        switch envelope.requestPath {
        case "/room/play_state":
            let response = try decoder.decode(RoomPlayStateResponse.self, from: data)
            guard let playState = response.data else {
                return nil
            }

            let trackMetadata: ItemMetaDataTrack?
            do {
                trackMetadata = try decoder.decode(MetadataResponse<ItemMetaDataTrack>.self, from: data).data?.metadata
            } catch {
                Self.logger.warning("Failed to decode Linn track metadata: \(String(describing: error), privacy: .public)")
                trackMetadata = nil
            }

            let duration = trackMetadata?.duration ?? playState.details?.duration
            return .playState(
                room: response.room,
                session: response.session,
                playback: NowPlaying.Playback(playState: playState),
                queue: NowPlaying.Queue(playState: playState),
                currentItem: NowPlaying.CurrentItem(metadata: playState.metadata, trackMetadata: trackMetadata),
                timeline: NowPlaying.Timeline(playState: playState, duration: duration)
            )

        case "/room/play_state/position":
            let response = try decoder.decode(RoomPlayStatePositionResponse.self, from: data)
            guard let position = response.data else {
                return nil
            }

            return .position(
                room: response.room,
                session: response.session,
                timeline: NowPlaying.Timeline(position: position)
            )

        case "/room/state":
            let response = try decoder.decode(RoomStateResponse.self, from: data)
            guard let state = response.data else {
                return nil
            }

            return .roomState(
                room: response.room,
                session: response.session,
                roomState: NowPlaying.RoomState(volume: state.volume, isMuted: state.mute)
            )

        case "/V2/playlist/subscribe":
            let response = try decoder.decode(V2PlaylistSubscribeResponse.self, from: data)
            guard let playlist = NowPlaying.Playlist(response: response) else {
                return nil
            }

            return .playlist(
                room: response.room,
                session: response.session,
                playlist: playlist
            )

        default:
            return nil
        }
    }
}

private actor CiGatewayConnection {
    private struct PendingCommand {
        var requestPath: String
        var continuation: CheckedContinuation<Void, Error>
        var timeoutTask: Task<Void, Never>
    }

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

    private var pendingCommands: [String: PendingCommand] = [:]
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
            CiGateway.PlaylistSelectCommand(tag: tag, room: room, session: session, index: index)
        }
    }

    func setVolume(_ volume: Int, room: String, group: Bool) async throws {
        try await sendCoalesced(.volume(room: room, group: group, value: volume), lane: .volume)
    }

    func setMuted(_ isMuted: Bool, room: String, group: Bool) async throws {
        try await sendCoalesced(.mute(room: room, group: group, value: isMuted), lane: .mute)
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
        finishPendingCommands(throwing: CancellationError())
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
            if socket != nil {
                break
            }
        }

        if socket == nil {
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

        try await CiGateway.subscribeToPlayState(room: room, session: session, updateInterval: updateInterval, on: socket)
        try await CiGateway.subscribeToPosition(room: room, session: session, updateInterval: updateInterval, on: socket)
        try await CiGateway.subscribeToRoomState(room: room, session: session, updateInterval: updateInterval, on: socket)
        try await CiGateway.subscribeToPlaylist(room: room, session: session, on: socket)

        subscribedRoom = room
        subscriptionUpdateInterval = updateInterval
        CiGateway.logger.info("Subscribed to now-playing updates for \(room, privacy: .public)")
    }

    private func handleMessage(_ message: String) {
        let data = Data(message.utf8)
        do {
            let envelope = try JSONDecoder().decode(CiGateway.GatewayEnvelope.self, from: data)
            if completePendingCommand(for: envelope) {
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

    private func completePendingCommand(for envelope: CiGateway.GatewayEnvelope) -> Bool {
        guard
            let tag = envelope.tag,
            let pending = pendingCommands[tag],
            pending.requestPath == envelope.requestPath
        else {
            return false
        }

        pending.timeoutTask.cancel()
        pendingCommands.removeValue(forKey: tag)
        CiGateway.logger.debug("Matched command ACK \(tag, privacy: .public) for \(pending.requestPath, privacy: .public)")
        pending.continuation.resume()
        return true
    }

    private func handleReceiveFailure(_ error: Error, from failedSocket: URLSessionWebSocketTask) {
        guard socket === failedSocket else {
            return
        }

        CiGateway.logger.warning("Gateway websocket receive loop failed: \(String(describing: error), privacy: .public)")
        tearDownDroppedConnection()
        finishPendingCommands(throwing: error)
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
        try await sendCommand(room: room, requestPath: "/room/play_state/set") { session, tag in
            CiGateway.RoomPlayStateCommand(
                tag: tag,
                room: room,
                session: session,
                action: action,
                skipTrack: skipTrack
            )
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
            try await sendCommand(room: room, requestPath: "/room/state/set") { session, tag in
                CiGateway.RoomStateCommand(
                    tag: tag,
                    room: room,
                    session: session,
                    group: group,
                    mute: nil,
                    volume: value
                )
            }
        case let .mute(room, group, value):
            try await sendCommand(room: room, requestPath: "/room/state/set") { session, tag in
                CiGateway.RoomStateCommand(
                    tag: tag,
                    room: room,
                    session: session,
                    group: group,
                    mute: value,
                    volume: nil
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
                    self.timeOutPendingCommand(tag: tag, requestPath: requestPath)
                }
                pendingCommands[tag] = PendingCommand(
                    requestPath: requestPath,
                    continuation: continuation,
                    timeoutTask: timeoutTask
                )

                Task {
                    do {
                        CiGateway.logger.debug("Sending command \(tag, privacy: .public) for \(requestPath, privacy: .public)")
                        try await CiGateway.send(command, on: socket)
                    } catch {
                        self.failPendingCommand(tag: tag, throwing: error)
                    }
                }
            }
        } onCancel: {
            Task {
                await self.cancelPendingCommand(tag: tag)
            }
        }
    }

    private func nextCommandTag() -> String {
        nextTagIndex += 1
        return "command-\(nextTagIndex)"
    }

    private func timeOutPendingCommand(tag: String, requestPath: String) {
        guard let pending = pendingCommands.removeValue(forKey: tag) else {
            return
        }

        CiGateway.logger.debug("Command \(tag, privacy: .public) for \(requestPath, privacy: .public) timed out")
        pending.continuation.resume(throwing: CiGateway.GatewayError.timedOut(requestPath))
    }

    private func failPendingCommand(tag: String, throwing error: Error) {
        guard let pending = pendingCommands.removeValue(forKey: tag) else {
            return
        }

        pending.timeoutTask.cancel()
        pending.continuation.resume(throwing: error)
    }

    private func cancelPendingCommand(tag: String) {
        failPendingCommand(tag: tag, throwing: CancellationError())
    }

    private func finishPendingCommands(throwing error: Error) {
        for tag in Array(pendingCommands.keys) {
            failPendingCommand(tag: tag, throwing: error)
        }
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

private extension CiGateway.NowPlaying.TransportState {
    init(_ transportState: RoomPlayState.TransportState) {
        switch transportState {
        case .stop:
            self = .stop
        case .play:
            self = .play
        case .pause:
            self = .pause
        case .buffering:
            self = .buffering
        case .waiting:
            self = .waiting
        case .unknown:
            self = .unknown
        }
    }
}

private extension CiGateway.NowPlaying.Playback {
    init?(playState: RoomPlayState) {
        guard let transportState = playState.transportState.map(CiGateway.NowPlaying.TransportState.init) else {
            return nil
        }

        self.init(transportState: transportState)
    }
}

private extension CiGateway.NowPlaying.Queue {
    init?(playState: RoomPlayState) {
        guard playState.queueIndex != nil || playState.queueLength != nil else {
            return nil
        }

        self.init(index: playState.queueIndex, length: playState.queueLength)
    }
}

private extension CiGateway.NowPlaying.Playlist {
    init?(response: V2PlaylistSubscribeResponse) {
        guard let data = response.data else {
            return nil
        }

        let items = data.children?
            .compactMap { key, metadata -> CiGateway.NowPlaying.PlaylistItem? in
                guard let index = Int(key) else {
                    return nil
                }
                return CiGateway.NowPlaying.PlaylistItem(index: index, metadata: metadata)
            }
            .sorted { $0.index < $1.index } ?? []

        self.init(items: items, total: data.total, contentRevision: data.contentRevision)
    }
}

private extension CiGateway.NowPlaying.PlaylistItem {
    init(index: Int, metadata: V2PlaylistItemMetadata) {
        self.init(
            index: index,
            displayName: metadata.name,
            album: metadata.album,
            artist: metadata.artist?.joined(separator: ", "),
            duration: metadata.duration,
            artworkURL: metadata.artUri.flatMap(URL.init(string:))
        )
    }
}

private extension CiGateway.NowPlaying.CurrentItem {
    init?(metadata: ItemMetaData?, trackMetadata: ItemMetaDataTrack?) {
        guard let metadata else {
            return nil
        }

        self.init(
            id: metadata.id,
            kind: metadata._class,
            displayName: metadata.name,
            artworkURL: metadata.artUri.flatMap(URL.init(string:)),
            track: CiGateway.NowPlaying.Track(trackMetadata: trackMetadata)
        )
    }
}

private extension CiGateway.NowPlaying.Track {
    init?(trackMetadata: ItemMetaDataTrack?) {
        guard
            let trackMetadata,
            trackMetadata.title != nil || trackMetadata.album != nil || trackMetadata.artist != nil
        else {
            return nil
        }

        self.init(
            title: trackMetadata.title,
            album: trackMetadata.album,
            artist: trackMetadata.artist?.joined(separator: ", ")
        )
    }
}

private extension CiGateway.NowPlaying.Timeline {
    init?(playState: RoomPlayState, duration: Int?) {
        let seekableRange = CiGateway.NowPlaying.SeekableRange(
            lowerBound: playState.positionMin,
            upperBound: playState.positionMax
        )
        let hasSeekableRange = seekableRange.lowerBound != nil || seekableRange.upperBound != nil
        guard playState.position != nil || duration != nil || hasSeekableRange else {
            return nil
        }

        self.init(
            position: playState.position,
            duration: duration,
            seekableRange: hasSeekableRange ? seekableRange : nil
        )
    }

    init(position: RoomPlayStatePositionResponseData) {
        let seekableRange = CiGateway.NowPlaying.SeekableRange(
            lowerBound: position.positionMin,
            upperBound: position.positionMax
        )
        let hasSeekableRange = seekableRange.lowerBound != nil || seekableRange.upperBound != nil
        self.init(
            position: position.position,
            seekableRange: hasSeekableRange ? seekableRange : nil
        )
    }

    mutating func mergePosition(_ update: CiGateway.NowPlaying.Timeline) {
        if let position = update.position {
            self.position = position
        }
        if update.seekableRange != nil {
            seekableRange = update.seekableRange
        }
    }
}

private extension CiGateway.NowPlaying {
    mutating func merge(_ update: CiGateway.NowPlayingUpdate) {
        switch update {
        case let .playState(room, session, playback, queue, currentItem, timeline):
            mergeContext(room: room, session: session)
            self.playback = playback
            self.queue = queue
            self.currentItem = currentItem
            self.timeline = timeline

        case let .position(room, session, timeline):
            mergeContext(room: room, session: session)
            if self.timeline == nil {
                self.timeline = timeline
            } else {
                self.timeline?.mergePosition(timeline)
            }

        case let .roomState(room, session, roomState):
            mergeContext(room: room, session: session)
            self.roomState = roomState

        case let .playlist(room, session, playlist):
            mergeContext(room: room, session: session)
            self.playlist = playlist
        }
    }

    mutating func mergeContext(room: String?, session: String?) {
        if let room {
            context.room = room
        }
        if let session {
            context.session = session
        }
    }
}
