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

    private let urlSession: URLSession
    private static let logger = Logger(subsystem: "Louie.LinnCiGateway", category: "CiGateway")

    public init(
        webSocketURL: URL,
        userAgent: String = "Louie/1.0",
        sessionTimeout: Int = 10000,
        urlSession: URLSession = .shared
    ) {
        self.webSocketURL = webSocketURL
        self.userAgent = userAgent
        self.sessionTimeout = sessionTimeout
        self.urlSession = urlSession
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
        let webSocketURL = webSocketURL
        let userAgent = userAgent
        let sessionTimeout = sessionTimeout
        let urlSession = urlSession

        return AsyncThrowingStream { continuation in
            let socket = urlSession.webSocketTask(with: webSocketURL)
            let task = Task {
                do {
                    Self.logger.info("Opening websocket \(webSocketURL.absoluteString, privacy: .public)")
                    socket.resume()

                    Self.logger.info("Creating gateway session")
                    let session = try await Self.createSession(on: socket, timeout: sessionTimeout, userAgent: userAgent)
                    Self.logger.info("Gateway session created \(session, privacy: .public)")

                    let room = try await Self.resolveRoom(preferredRoom: room, session: session, timeout: sessionTimeout, on: socket)
                    Self.logger.info("Using Linn room \(room, privacy: .public)")

                    try await Self.subscribeToPlayState(room: room, session: session, updateInterval: updateInterval, on: socket)
                    try await Self.subscribeToPosition(room: room, session: session, updateInterval: updateInterval, on: socket)
                    try await Self.subscribeToRoomState(room: room, session: session, updateInterval: updateInterval, on: socket)
                    try await Self.subscribeToPlaylist(room: room, session: session, on: socket)
                    Self.logger.info("Subscribed to now-playing updates for \(room, privacy: .public)")

                    var current = NowPlaying(room: room, session: session)
                    continuation.yield(current)

                    while !Task.isCancelled {
                        let message = try await Self.receiveText(from: socket)
                        guard let update = try Self.decodeNowPlayingUpdate(from: message) else {
                            continue
                        }
                        current.merge(update)
                        continuation.yield(current)
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }

                socket.cancel(with: .goingAway, reason: nil)
            }

            continuation.onTermination = { _ in
                task.cancel()
                socket.cancel(with: .goingAway, reason: nil)
            }
        }
    }

    public func play(room: String) async throws {
        try await sendRoomPlayStateCommand(room: room, action: .play)
    }

    public func pause(room: String) async throws {
        try await sendRoomPlayStateCommand(room: room, action: .pause)
    }

    public func previous(room: String) async throws {
        try await sendRoomPlayStateCommand(room: room, skipTrack: -1)
    }

    public func next(room: String) async throws {
        try await sendRoomPlayStateCommand(room: room, skipTrack: 1)
    }

    public func selectPlaylistItem(at index: Int, room: String) async throws {
        try await sendPlaylistSelectCommand(room: room, index: index)
    }

    public func setVolume(_ volume: Int, room: String, group: Bool = true) async throws {
        try await sendRoomStateCommand(room: room, group: group, volume: max(0, min(100, volume)))
    }

    public func setMuted(_ isMuted: Bool, room: String, group: Bool = true) async throws {
        try await sendRoomStateCommand(room: room, group: group, mute: isMuted)
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
        var room: String
        var session: String
        var action: PlayStateAction?
        var skipTrack: Int?

        enum CodingKeys: String, CodingKey {
            case requestPath
            case room
            case session
            case action
            case skipTrack = "skip_track"
        }
    }

    struct RoomStateCommand: Encodable {
        var requestPath = "/room/state/set"
        var room: String
        var session: String
        var group: Bool?
        var mute: Bool?
        var volume: Int?
    }

    struct PlaylistSelectCommand: Encodable {
        var requestPath = "/V2/playlist/select"
        var room: String
        var session: String
        var index: Int
    }

    struct PlaylistSubscriptionRequest: Encodable {
        var requestPath = "/V2/playlist/subscribe"
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
            PlaylistSubscriptionRequest(room: room, session: session),
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

    func sendRoomPlayStateCommand(
        room: String,
        action: PlayStateAction? = nil,
        skipTrack: Int? = nil
    ) async throws {
        try await sendCommand(
            requestPath: "/room/play_state/set",
            build: { session in
                RoomPlayStateCommand(
                    room: room,
                    session: session,
                    action: action,
                    skipTrack: skipTrack
                )
            }
        )
    }

    func sendRoomStateCommand(
        room: String,
        group: Bool?,
        mute: Bool? = nil,
        volume: Int? = nil
    ) async throws {
        try await sendCommand(
            requestPath: "/room/state/set",
            build: { session in
                RoomStateCommand(
                    room: room,
                    session: session,
                    group: group,
                    mute: mute,
                    volume: volume
                )
            }
        )
    }

    func sendPlaylistSelectCommand(room: String, index: Int) async throws {
        try await sendCommand(
            requestPath: "/V2/playlist/select",
            build: { session in
                PlaylistSelectCommand(
                    room: room,
                    session: session,
                    index: index
                )
            }
        )
    }

    func sendCommand<Command: Encodable>(
        requestPath: String,
        build: (String) -> Command
    ) async throws {
        let socket = urlSession.webSocketTask(with: webSocketURL)
        socket.resume()
        defer {
            socket.cancel(with: .goingAway, reason: nil)
        }

        let session = try await Self.createSession(on: socket, timeout: sessionTimeout, userAgent: userAgent)
        try await Self.send(build(session), on: socket)

        while !Task.isCancelled {
            let message = try await Self.receiveText(from: socket)
            let envelope = try JSONDecoder().decode(GatewayEnvelope.self, from: Data(message.utf8))
            guard envelope.requestPath == requestPath else {
                continue
            }
            return
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
