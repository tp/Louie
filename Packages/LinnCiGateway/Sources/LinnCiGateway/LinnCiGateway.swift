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

private extension CiGateway {
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

    static func subscribeToPlayState(
        room: String,
        session: String,
        updateInterval: Int,
        on socket: URLSessionWebSocketTask
    ) async throws {
        try await send(
            V2TransportStatusGetRequest(
                tag: "subscription-play-state",
                session: session,
                room: room,
                update: updateInterval
            ),
            requestPath: "/V2/transport/status",
            on: socket
        )
        logger.debug("Sent /V2/transport/status subscription for \(room, privacy: .public)")
    }

    static func subscribeToPosition(
        room: String,
        session: String,
        updateInterval: Int,
        on socket: URLSessionWebSocketTask
    ) async throws {
        try await send(
            V2TransportStatusGetRequest(
                tag: "subscription-position",
                session: session,
                room: room,
                update: updateInterval
            ),
            requestPath: "/V2/seek/status",
            on: socket
        )
        logger.debug("Sent /V2/seek/status subscription for \(room, privacy: .public)")
    }

    static func subscribeToRoomState(
        room: String,
        session: String,
        updateInterval: Int,
        on socket: URLSessionWebSocketTask
    ) async throws {
        try await send(
            V2VolumeStatusGetRequest(
                tag: "subscription-room-state",
                session: session,
                room: room,
                update: updateInterval,
                group: true
            ),
            requestPath: "/V2/volume/status",
            on: socket
        )
        logger.debug("Sent /V2/volume/status subscription for \(room, privacy: .public)")
    }

    static func subscribeToMetadata(
        room: String,
        session: String,
        updateInterval: Int,
        on socket: URLSessionWebSocketTask
    ) async throws {
        try await send(
            V2TransportStatusGetRequest(
                tag: "subscription-metadata",
                session: session,
                room: room,
                update: updateInterval
            ),
            requestPath: "/V2/metadata/status",
            on: socket
        )
        logger.debug("Sent /V2/metadata/status subscription for \(room, privacy: .public)")
    }

    static func subscribeToPlaylist(
        room: String,
        session: String,
        on socket: URLSessionWebSocketTask
    ) async throws {
        try await send(
            V2PlaylistSubscribeGetRequest(
                tag: "subscription-playlist",
                session: session,
                room: room,
                index: 0,
                count: 100,
                concise: false
            ),
            requestPath: "/V2/playlist/subscribe",
            on: socket
        )
        logger.debug("Sent /V2/playlist/subscribe for \(room, privacy: .public)")
    }

    static func send<T: Encodable>(_ value: T, requestPath: String, on socket: URLSessionWebSocketTask) async throws {
        try await send(WebSocketRequest(requestPath: requestPath, body: value), on: socket)
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
        case "/V2/transport/status":
            let response = try decoder.decode(V2TransportStatusResponse.self, from: data)
            guard let playback = NowPlaying.Playback(response: response) else {
                return nil
            }

            return .transport(
                room: response.room,
                session: response.session,
                playback: playback
            )

        case "/V2/seek/status":
            let response = try decoder.decode(V2SeekStatusResponse.self, from: data)
            guard let timeline = NowPlaying.Timeline(response: response) else {
                return nil
            }

            return .seek(
                room: response.room,
                session: response.session,
                timeline: timeline
            )

        case "/V2/metadata/status":
            let response = try decoder.decode(V2MetadataStatusResponse.self, from: data)
            guard response.metadata != nil else {
                return nil
            }

            return .metadata(
                room: response.room,
                session: response.session,
                currentItem: NowPlaying.CurrentItem(response: response)
            )

        case "/V2/volume/status":
            let response = try decoder.decode(V2VolumeStatusResponse.self, from: data)
            guard let roomState = NowPlaying.RoomState(response: response) else {
                return nil
            }

            return .volume(
                room: response.room,
                session: response.session,
                roomState: roomState
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

    private struct PendingResponse {
        var requestPath: String
        var continuation: CheckedContinuation<Data, Error>
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
    private var pendingResponses: [String: PendingResponse] = [:]
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
        finishPendingCommands(throwing: CancellationError())
        finishPendingResponses(throwing: CancellationError())
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

        try await CiGateway.subscribeToPlayState(room: room, session: session, updateInterval: updateInterval, on: socket)
        try await CiGateway.subscribeToPosition(room: room, session: session, updateInterval: updateInterval, on: socket)
        try await CiGateway.subscribeToRoomState(room: room, session: session, updateInterval: updateInterval, on: socket)
        try await CiGateway.subscribeToMetadata(room: room, session: session, updateInterval: updateInterval, on: socket)
        try await CiGateway.subscribeToPlaylist(room: room, session: session, on: socket)

        subscribedRoom = room
        subscriptionUpdateInterval = updateInterval
        CiGateway.logger.info("Subscribed to now-playing updates for \(room, privacy: .public)")
    }

    private func handleMessage(_ message: String) {
        let data = Data(message.utf8)
        do {
            let envelope = try JSONDecoder().decode(CiGateway.GatewayEnvelope.self, from: data)
            if completePendingResponse(for: envelope, data: data) {
                return
            }
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
        guard let tag = envelope.tag, let pending = pendingCommands[tag] else {
            return false
        }

        guard envelope.requestPath == nil || pending.requestPath == envelope.requestPath else {
            return false
        }

        pending.timeoutTask.cancel()
        pendingCommands.removeValue(forKey: tag)
        CiGateway.logger.debug("Matched command ACK \(tag, privacy: .public) for \(pending.requestPath, privacy: .public)")
        if let errorCode = envelope.errorCode {
            pending.continuation.resume(
                throwing: CiGateway.GatewayError.commandFailed(
                    code: errorCode,
                    message: envelope.message ?? "Gateway command failed"
                )
            )
        } else {
            pending.continuation.resume()
        }
        return true
    }

    private func completePendingResponse(for envelope: CiGateway.GatewayEnvelope, data: Data) -> Bool {
        guard let tag = envelope.tag, let pending = pendingResponses[tag] else {
            return false
        }

        guard envelope.requestPath == nil || pending.requestPath == envelope.requestPath else {
            return false
        }

        pending.timeoutTask.cancel()
        pendingResponses.removeValue(forKey: tag)
        CiGateway.logger.debug("Matched response \(tag, privacy: .public) for \(pending.requestPath, privacy: .public)")
        if let errorCode = envelope.errorCode {
            pending.continuation.resume(
                throwing: CiGateway.GatewayError.commandFailed(
                    code: errorCode,
                    message: envelope.message ?? "Gateway request failed"
                )
            )
        } else {
            pending.continuation.resume(returning: data)
        }
        return true
    }

    private func handleReceiveFailure(_ error: Error, from failedSocket: URLSessionWebSocketTask) {
        guard socket === failedSocket else {
            return
        }

        CiGateway.logger.warning("Gateway websocket receive loop failed: \(String(describing: error), privacy: .public)")
        tearDownDroppedConnection()
        finishPendingCommands(throwing: error)
        finishPendingResponses(throwing: error)
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
                        try await CiGateway.send(command, requestPath: requestPath, on: socket)
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
                    self.timeOutPendingResponse(tag: tag, requestPath: requestPath)
                }
                pendingResponses[tag] = PendingResponse(
                    requestPath: requestPath,
                    continuation: continuation,
                    timeoutTask: timeoutTask
                )

                Task {
                    do {
                        CiGateway.logger.debug("Sending request \(tag, privacy: .public) for \(requestPath, privacy: .public)")
                        try await CiGateway.send(command, requestPath: requestPath, on: socket)
                    } catch {
                        self.failPendingResponse(tag: tag, throwing: error)
                    }
                }
            }
        } onCancel: {
            Task {
                await self.cancelPendingResponse(tag: tag)
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

    private func timeOutPendingResponse(tag: String, requestPath: String) {
        guard let pending = pendingResponses.removeValue(forKey: tag) else {
            return
        }

        CiGateway.logger.debug("Request \(tag, privacy: .public) for \(requestPath, privacy: .public) timed out")
        pending.continuation.resume(throwing: CiGateway.GatewayError.timedOut(requestPath))
    }

    private func failPendingCommand(tag: String, throwing error: Error) {
        guard let pending = pendingCommands.removeValue(forKey: tag) else {
            return
        }

        pending.timeoutTask.cancel()
        pending.continuation.resume(throwing: error)
    }

    private func failPendingResponse(tag: String, throwing error: Error) {
        guard let pending = pendingResponses.removeValue(forKey: tag) else {
            return
        }

        pending.timeoutTask.cancel()
        pending.continuation.resume(throwing: error)
    }

    private func cancelPendingCommand(tag: String) {
        failPendingCommand(tag: tag, throwing: CancellationError())
    }

    private func cancelPendingResponse(tag: String) {
        failPendingResponse(tag: tag, throwing: CancellationError())
    }

    private func finishPendingCommands(throwing error: Error) {
        for tag in Array(pendingCommands.keys) {
            failPendingCommand(tag: tag, throwing: error)
        }
    }

    private func finishPendingResponses(throwing error: Error) {
        for tag in Array(pendingResponses.keys) {
            failPendingResponse(tag: tag, throwing: error)
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

private extension CiGateway.MediaService {
    init?(_ service: V2ServicesStatusItem) {
        guard let id = service.id, let name = service.name else {
            return nil
        }

        self.init(id: id, name: name, kind: service._class)
    }
}

private extension CiGateway.MediaPage {
    init(_ data: MediaBrowseData?) {
        self.init(
            id: data?.id,
            contentRevision: data?.contentRevision,
            index: data?.index ?? 0,
            count: data?.count ?? data?.children?.count ?? 0,
            total: data?.total,
            alpha: data?.alpha,
            children: data?.children?.map(CiGateway.MediaItem.init) ?? []
        )
    }
}

private extension CiGateway.MediaItem {
    init(_ metadata: ItemMetaData) {
        self.init(
            id: metadata.id,
            kind: metadata._class,
            name: metadata.name,
            title: metadata.title,
            album: metadata.album,
            artists: metadata.artist ?? [],
            artworkURL: metadata.artUri.flatMap(URL.init(string:)),
            duration: metadata.duration,
            containedKinds: metadata.containedClasses ?? [],
            childCount: metadata.count,
            isFavourite: metadata.isFavourite,
            disabledActions: metadata.disabledActions ?? [],
            albumID: metadata.albumId,
            artistID: metadata.artistId
        )
    }
}

private extension CiGateway.NowPlaying.TransportState {
    init(_ transportState: String) {
        switch transportState.lowercased() {
        case "stop", "stopped":
            self = .stop
        case "play", "playing":
            self = .play
        case "pause", "paused":
            self = .pause
        case "buffering":
            self = .buffering
        case "waiting":
            self = .waiting
        default:
            self = .unknown
        }
    }
}

private extension CiGateway.NowPlaying.Playback {
    init?(response: V2TransportStatusResponse) {
        guard let transportState = response.data?.transportState.map(CiGateway.NowPlaying.TransportState.init) else {
            return nil
        }

        self.init(transportState: transportState)
    }
}

private extension CiGateway.NowPlaying.Queue {
    init?(playlist: CiGateway.NowPlaying.Playlist) {
        let selectedIndex = playlist.items.first { $0.isCurrent }?.index
        guard selectedIndex != nil || playlist.total != nil else {
            return nil
        }

        self.init(index: selectedIndex, length: playlist.total)
    }
}

private extension CiGateway.NowPlaying.RoomState {
    init?(response: V2VolumeStatusResponse) {
        guard let data = response.data, data.volume != nil || data.mute != nil else {
            return nil
        }

        self.init(volume: data.volume, isMuted: data.mute)
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
            artworkURL: metadata.artUri.flatMap(URL.init(string:)),
            isCurrent: metadata.playing == true || metadata.selected == true
        )
    }
}

private extension CiGateway.NowPlaying.CurrentItem {
    init?(response: V2MetadataStatusResponse) {
        guard let metadata = response.metadata else {
            return nil
        }

        let id = metadata.artUri ?? metadata.line1 ?? response.room ?? "current"
        self.init(
            id: id,
            kind: "metadata",
            displayName: metadata.line1,
            artworkURL: metadata.artUri.flatMap(URL.init(string:)),
            track: CiGateway.NowPlaying.Track(metadata: metadata)
        )
    }
}

private extension CiGateway.NowPlaying.Track {
    init?(metadata: V2MetadataStatusData?) {
        guard
            let metadata,
            metadata.line1 != nil || metadata.line2 != nil || metadata.line3 != nil
        else {
            return nil
        }

        self.init(
            title: metadata.line1,
            album: metadata.line3,
            artist: metadata.line2
        )
    }
}

private extension CiGateway.NowPlaying.Timeline {
    init?(response: V2SeekStatusResponse) {
        guard let seek = response.data, seek.elapsed != nil || seek.duration != nil || seek.seekable != nil else {
            return nil
        }

        let seekableRange = seek.seekable == true
            ? CiGateway.NowPlaying.SeekableRange(lowerBound: 0, upperBound: seek.duration)
            : nil
        self.init(
            position: seek.elapsed,
            duration: seek.duration,
            seekableRange: seekableRange
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
        case let .transport(room, session, playback):
            mergeContext(room: room, session: session)
            self.playback = playback

        case let .seek(room, session, timeline):
            mergeContext(room: room, session: session)
            if self.timeline == nil {
                self.timeline = timeline
            } else {
                self.timeline?.mergePosition(timeline)
            }

        case let .metadata(room, session, currentItem):
            mergeContext(room: room, session: session)
            self.currentItem = currentItem

        case let .volume(room, session, roomState):
            mergeContext(room: room, session: session)
            self.roomState = roomState

        case let .playlist(room, session, playlist):
            mergeContext(room: room, session: session)
            self.playlist = playlist
            if let queue = CiGateway.NowPlaying.Queue(playlist: playlist) {
                self.queue = queue
            }
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
