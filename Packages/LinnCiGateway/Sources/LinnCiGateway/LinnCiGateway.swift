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
            public var isCurrent: Bool

            public init(
                index: Int,
                displayName: String? = nil,
                album: String? = nil,
                artist: String? = nil,
                duration: Int? = nil,
                artworkURL: URL? = nil,
                isCurrent: Bool = false
            ) {
                self.index = index
                self.displayName = displayName
                self.album = album
                self.artist = artist
                self.duration = duration
                self.artworkURL = artworkURL
                self.isCurrent = isCurrent
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

    public struct MediaService: Sendable, Equatable, Identifiable {
        public var id: String
        public var name: String
        public var kind: String?

        public init(id: String, name: String, kind: String? = nil) {
            self.id = id
            self.name = name
            self.kind = kind
        }
    }

    public struct MediaItem: Sendable, Equatable, Identifiable {
        public var id: String
        public var kind: String
        public var name: String?
        public var title: String?
        public var album: String?
        public var artists: [String]
        public var artworkURL: URL?
        public var duration: Int?
        public var containedKinds: [String]
        public var childCount: Int?
        public var isFavourite: Bool?
        public var disabledActions: [String]
        public var albumID: String?
        public var artistID: String?

        public init(
            id: String,
            kind: String,
            name: String? = nil,
            title: String? = nil,
            album: String? = nil,
            artists: [String] = [],
            artworkURL: URL? = nil,
            duration: Int? = nil,
            containedKinds: [String] = [],
            childCount: Int? = nil,
            isFavourite: Bool? = nil,
            disabledActions: [String] = [],
            albumID: String? = nil,
            artistID: String? = nil
        ) {
            self.id = id
            self.kind = kind
            self.name = name
            self.title = title
            self.album = album
            self.artists = artists
            self.artworkURL = artworkURL
            self.duration = duration
            self.containedKinds = containedKinds
            self.childCount = childCount
            self.isFavourite = isFavourite
            self.disabledActions = disabledActions
            self.albumID = albumID
            self.artistID = artistID
        }

        public var displayTitle: String? {
            title ?? name
        }

        public var canFavourite: Bool {
            isFavourite != nil && !disabledActions.contains("favourite")
        }

        public var isContainer: Bool {
            kind.contains("container")
                || kind.contains("album")
                || kind.contains("playlist")
                || kind.hasPrefix("md.qobuz")
                || childCount != nil
                || !containedKinds.isEmpty
        }
    }

    public struct MediaPage: Sendable, Equatable {
        public var id: String?
        public var contentRevision: Int?
        public var index: Int
        public var count: Int
        public var total: Int?
        public var alpha: [Int?]?
        public var children: [MediaItem]

        public init(
            id: String? = nil,
            contentRevision: Int? = nil,
            index: Int = 0,
            count: Int = 0,
            total: Int? = nil,
            alpha: [Int?]? = nil,
            children: [MediaItem] = []
        ) {
            self.id = id
            self.contentRevision = contentRevision
            self.index = index
            self.count = count
            self.total = total
            self.alpha = alpha
            self.children = children
        }
    }

    public enum MediaSearchType: String, Sendable, Equatable, CaseIterable {
        case albums
        case artists
        case tracks
        case playlists
        case composers
        case stations
    }

    public enum QueuePlacement: String, Sendable, Equatable, CaseIterable {
        case now
        case next
        case last
        case replace
    }

    public enum GatewayError: Error, Sendable {
        case nonTextMessage
        case missingSession
        case noRoomsAvailable
        case invalidURL(String)
        case timedOut(String)
        case commandFailed(code: Int, message: String)
    }

    public let webSocketURL: URL
    public let userAgent: String
    public let sessionTimeout: Int

    private let connection: CiGatewayConnection
    static let logger = Logger(subsystem: "Louie.LinnCiGateway", category: "CiGateway")

    /// Request paths whose full payload is suppressed from the verbose websocket
    /// send/receive logs. These fire on a tight subscription cadence and drown
    /// out the rarer interactions we actually want to see. Higher-level logs
    /// (subscription setup, command dispatch, matched responses) are unaffected.
    static let noisyRequestPaths: Set<String> = [
        "/V2/seek/status",
    ]

    static func isNoisyPayload(_ text: String) -> Bool {
        noisyRequestPaths.contains { path in
            text.contains("\"requestPath\":\"\(path)\"")
        }
    }

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

    public func mediaServices(room: String) async throws -> [MediaService] {
        try await connection.mediaServices(room: room)
    }

    public func qobuzService(room: String) async throws -> MediaService? {
        try await mediaServices(room: room).first { $0.name.localizedCaseInsensitiveCompare("Qobuz") == .orderedSame }
    }

    public func browse(
        mediaID: String,
        index: Int = 0,
        count: Int = 50,
        browseType: String = ""
    ) async throws -> MediaPage {
        try await connection.browse(mediaID: mediaID, index: index, count: count, browseType: browseType)
    }

    public func search(
        serviceID: String,
        query: String,
        type: MediaSearchType,
        index: Int = 0,
        count: Int = 25
    ) async throws -> MediaPage {
        try await connection.search(serviceID: serviceID, query: query, type: type, index: index, count: count)
    }

    public func select(mediaID: String, room: String, queue: QueuePlacement = .replace) async throws {
        try await connection.select(mediaID: mediaID, room: room, queue: queue)
    }

    public func setFavourite(mediaID: String, isFavourite: Bool) async throws {
        try await connection.setFavourite(mediaID: mediaID, isFavourite: isFavourite)
    }
}

extension CiGateway {
    struct WebSocketRequest<Body: Encodable>: Encodable {
        var requestPath: String
        var body: Body

        enum CodingKeys: String, CodingKey {
            case requestPath
        }

        func encode(to encoder: Encoder) throws {
            try body.encode(to: encoder)
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(requestPath, forKey: .requestPath)
        }
    }

    struct GatewayEnvelope: Decodable {
        var requestPath: String?
        var tag: String?
        var errorCode: Int?
        var message: String?
    }

    enum NowPlayingUpdate {
        case transport(
            room: String?,
            session: String?,
            playback: NowPlaying.Playback
        )
        case seek(
            room: String?,
            session: String?,
            timeline: NowPlaying.Timeline
        )
        case metadata(
            room: String?,
            session: String?,
            currentItem: NowPlaying.CurrentItem?
        )
        case volume(
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

    /// Pairs the send-side (build the subscribe request) and receive-side (decode
    /// an incoming envelope at the same requestPath) of a now-playing subscription
    /// so that adding a new one is a single declaration rather than two edits.
    struct Subscription: Sendable {
        let tag: String
        let requestPath: String
        private let _send: @Sendable (_ room: String, _ session: String, _ updateInterval: Int, _ socket: URLSessionWebSocketTask) async throws -> Void
        private let _decode: @Sendable (_ data: Data, _ decoder: JSONDecoder) throws -> NowPlayingUpdate?

        init<Request: Encodable & Sendable, Response: Decodable & Sendable>(
            tag: String,
            requestPath: String,
            buildRequest: @escaping @Sendable (_ room: String, _ session: String, _ updateInterval: Int) -> Request,
            decode: @escaping @Sendable (Response) -> NowPlayingUpdate?
        ) {
            self.tag = tag
            self.requestPath = requestPath
            let path = requestPath
            _send = { room, session, interval, socket in
                try await CiGateway.send(buildRequest(room, session, interval), requestPath: path, on: socket)
            }
            _decode = { data, decoder in
                let response = try decoder.decode(Response.self, from: data)
                return decode(response)
            }
        }

        func send(room: String, session: String, updateInterval: Int, on socket: URLSessionWebSocketTask) async throws {
            try await _send(room, session, updateInterval, socket)
            CiGateway.logger.debug("Sent \(self.requestPath, privacy: .public) subscription for \(room, privacy: .public)")
        }

        func decode(from data: Data, using decoder: JSONDecoder) throws -> NowPlayingUpdate? {
            try _decode(data, decoder)
        }
    }

    /// Subscriptions opened on the shared websocket once a session+room are known.
    /// The play-state and metadata endpoints share the generic V2TransportStatusGetRequest
    /// shape but live at different paths — that's intentional (the gateway accepts
    /// a generic subscribe-status request at multiple endpoints).
    static let nowPlayingSubscriptions: [Subscription] = [
        Subscription(
            tag: "subscription-play-state",
            requestPath: "/V2/transport/status",
            buildRequest: { room, session, interval in
                V2TransportStatusGetRequest(tag: "subscription-play-state", session: session, room: room, update: interval)
            },
            decode: { (response: V2TransportStatusResponse) -> NowPlayingUpdate? in
                guard let playback = NowPlaying.Playback(response: response) else { return nil }
                return .transport(room: response.room, session: response.session, playback: playback)
            }
        ),
        Subscription(
            tag: "subscription-position",
            requestPath: "/V2/seek/status",
            buildRequest: { room, session, interval in
                V2TransportStatusGetRequest(tag: "subscription-position", session: session, room: room, update: interval)
            },
            decode: { (response: V2SeekStatusResponse) -> NowPlayingUpdate? in
                guard let timeline = NowPlaying.Timeline(response: response) else { return nil }
                return .seek(room: response.room, session: response.session, timeline: timeline)
            }
        ),
        Subscription(
            tag: "subscription-room-state",
            requestPath: "/V2/volume/status",
            buildRequest: { room, session, interval in
                V2VolumeStatusGetRequest(tag: "subscription-room-state", session: session, room: room, update: interval)
            },
            decode: { (response: V2VolumeStatusResponse) -> NowPlayingUpdate? in
                guard let roomState = NowPlaying.RoomState(response: response) else { return nil }
                return .volume(room: response.room, session: response.session, roomState: roomState)
            }
        ),
        Subscription(
            tag: "subscription-metadata",
            requestPath: "/V2/metadata/status",
            buildRequest: { room, session, interval in
                V2TransportStatusGetRequest(tag: "subscription-metadata", session: session, room: room, update: interval)
            },
            decode: { (response: V2MetadataStatusResponse) -> NowPlayingUpdate? in
                guard response.metadata != nil else { return nil }
                return .metadata(room: response.room, session: response.session, currentItem: NowPlaying.CurrentItem(response: response))
            }
        ),
        Subscription(
            tag: "subscription-playlist",
            requestPath: "/V2/playlist/subscribe",
            buildRequest: { room, session, _ in
                V2PlaylistSubscribeGetRequest(tag: "subscription-playlist", session: session, room: room, index: 0, count: 100, concise: false)
            },
            decode: { (response: V2PlaylistSubscribeResponse) -> NowPlayingUpdate? in
                guard let playlist = NowPlaying.Playlist(response: response) else { return nil }
                return .playlist(room: response.room, session: response.session, playlist: playlist)
            }
        ),
    ]

    static func createSession(on socket: URLSessionWebSocketTask, timeout: Int, userAgent: String) async throws -> String {
        try await send(
            WebSocketRequest(
                requestPath: "/session/create",
                body: SessionCreatePostRequest(userAgent: userAgent, timeout: timeout)
            ),
            on: socket
        )

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
        logger.info("Requesting Linn V2 topology status")
        try await send(
            V2TopologyStatusGetRequest(tag: "topology-status", session: session),
            requestPath: "/V2/topology/status",
            on: socket
        )

        while !Task.isCancelled {
            let message = try await receiveText(from: socket, timeout: .milliseconds(timeout), context: "house topology")
            let envelope = try JSONDecoder().decode(GatewayEnvelope.self, from: Data(message.utf8))
            guard envelope.requestPath == "/V2/topology/status" else {
                continue
            }

            let response = try JSONDecoder().decode(V2TopologyStatusResponse.self, from: Data(message.utf8))
            guard let rooms = response.data?.rooms, !rooms.isEmpty else {
                throw GatewayError.noRoomsAvailable
            }

            let roomNames = rooms.map { $0.name ?? $0.udn ?? "<unnamed>" }.joined(separator: ", ")
            Self.logger.info("Received Linn rooms: \(roomNames, privacy: .public)")

            if let preferredRoom, !preferredRoom.isEmpty {
                if let matchingRoom = rooms.first(where: { $0.name == preferredRoom || $0.udn == preferredRoom }) {
                    return matchingRoom.name ?? matchingRoom.udn ?? preferredRoom
                }

                let availableRooms = rooms.compactMap(\.name).joined(separator: ", ")
                Self.logger.warning("Requested Linn room \(preferredRoom, privacy: .public) was not found. Available rooms: \(availableRooms, privacy: .public)")
            }

            guard let room = rooms.first?.name ?? rooms.first?.udn else {
                throw GatewayError.noRoomsAvailable
            }

            return room
        }

        throw GatewayError.noRoomsAvailable
    }

    static func send<T: Encodable>(_ value: T, requestPath: String, on socket: URLSessionWebSocketTask) async throws {
        try await send(WebSocketRequest(requestPath: requestPath, body: value), on: socket)
    }

    static func send<T: Encodable>(_ value: T, on socket: URLSessionWebSocketTask) async throws {
        let data = try JSONEncoder().encode(value)
        let text = String(decoding: data, as: UTF8.self)
        if !isNoisyPayload(text) {
            Self.logger.debug("Sending websocket message \(text, privacy: .public)")
        }
        try await socket.send(.string(text))
    }

    static func receiveText(from socket: URLSessionWebSocketTask) async throws -> String {
        switch try await socket.receive() {
        case let .string(text):
            if !isNoisyPayload(text) {
                Self.logger.debug("Received websocket message \(text, privacy: .public)")
            }
            return text
        case let .data(data):
            guard let text = String(data: data, encoding: .utf8) else {
                throw GatewayError.nonTextMessage
            }
            if !isNoisyPayload(text) {
                Self.logger.debug("Received websocket data message \(text, privacy: .public)")
            }
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

        guard let path = envelope.requestPath,
              let subscription = nowPlayingSubscriptions.first(where: { $0.requestPath == path }) else {
            return nil
        }

        return try subscription.decode(from: data, using: decoder)
    }
}
