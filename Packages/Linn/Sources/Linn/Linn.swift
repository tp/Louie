import Foundation
import LinnCiGateway
import Observation
import OSLog

@Observable
@MainActor
public final class Linn {
    public enum ConnectionState: Sendable, Equatable {
        case idle
        case connecting
        case connected
        case failed(String)
    }

    public enum PlayState: Sendable, Equatable {
        case stopped
        case playing
        case paused
        case loading
        case buffering
    }

    public struct Song: Sendable, Equatable, Identifiable {
        public var id: String
        public var title: String
        public var artist: String?
        public var album: String?
        public var duration: Int?
        public var artworkURL: URL?

        public init(
            id: String,
            title: String,
            artist: String? = nil,
            album: String? = nil,
            duration: Int? = nil,
            artworkURL: URL? = nil
        ) {
            self.id = id
            self.title = title
            self.artist = artist
            self.album = album
            self.duration = duration
            self.artworkURL = artworkURL
        }
    }

    public struct Timeline: Sendable, Equatable {
        public var position: Int?
        public var duration: Int?
        public var progress: Double?

        public init(position: Int? = nil, duration: Int? = nil, progress: Double? = nil) {
            self.position = position
            self.duration = duration
            self.progress = progress
        }
    }

    public let room: String
    public let maximumVolume: Int
    public private(set) var connectionState: ConnectionState = .idle
    public private(set) var currentSong: Song?
    public private(set) var upcomingSongs: [Song] = []
    public private(set) var playState: PlayState?
    public private(set) var volume: Int?
    public private(set) var isMuted: Bool?
    public private(set) var timeline: Timeline?
    public private(set) var lastErrorMessage: String?

    public var hasPrevious: Bool {
        guard let queueIndex else {
            return false
        }
        return queueIndex > 0
    }

    public var hasNext: Bool {
        guard let queueIndex, let queueLength else {
            return false
        }
        return queueIndex + 1 < queueLength
    }

    private var ciGateway: CiGateway?
    private var configurationLoadAttempted = false
    private var queueIndex: Int?
    private var queueLength: Int?
    private var playlistSongs: [Int: Song] = [:]
    private var optimisticTransition: OptimisticTransition?
    private var optimisticPlayState: OptimisticPlayState?
    private static let logger = Logger(subsystem: "Louie.Linn", category: "Linn")

    @ObservationIgnored private var updatesTask: Task<Void, Never>?
    @ObservationIgnored private var controlTask: Task<Void, Never>?

    private struct OptimisticTransition {
        var targetQueueIndex: Int
        var expiresAt: Date
    }

    private struct OptimisticPlayState {
        var targetState: PlayState
        var previousState: PlayState?
        var expiresAt: Date
    }

    public init(
        configuration: Configuration,
        room: String = "Linn",
        maximumVolume: Int = 70
    ) {
        self.room = room
        self.maximumVolume = maximumVolume
        ciGateway = CiGateway(webSocketURL: configuration.ciGatewayWebSocketURL)
        configurationLoadAttempted = true
    }

    public init(
        room: String = "Linn",
        maximumVolume: Int = 70
    ) {
        self.room = room
        self.maximumVolume = maximumVolume
        ciGateway = nil
    }

    #if DEBUG
        public init(
            mockRoom room: String = "Main Room",
            maximumVolume: Int = 70,
            connectionState: ConnectionState = .connected,
            currentSong: Song? = nil,
            playState: PlayState? = nil,
            volume: Int? = nil,
            isMuted: Bool? = nil,
            timeline: Timeline? = nil,
            hasPrevious: Bool = false,
            hasNext: Bool = false,
            lastErrorMessage: String? = nil
        ) {
            self.room = room
            self.maximumVolume = maximumVolume
            self.connectionState = connectionState
            self.currentSong = currentSong
            self.playState = playState
            self.volume = volume
            self.isMuted = isMuted
            self.timeline = timeline
            self.lastErrorMessage = lastErrorMessage
            ciGateway = nil
            configurationLoadAttempted = true
            setQueueAvailability(hasPrevious: hasPrevious, hasNext: hasNext)
        }
    #endif

    deinit {
        updatesTask?.cancel()
        controlTask?.cancel()
    }

    public func start() {
        if ciGateway == nil, !configurationLoadAttempted {
            configurationLoadAttempted = true
            do {
                let configuration = try Configuration.local()
                Self.logger.info("Loaded Linn gateway websocket URL \(configuration.ciGatewayWebSocketURL.absoluteString, privacy: .public)")
                ciGateway = CiGateway(webSocketURL: configuration.ciGatewayWebSocketURL)
            } catch {
                let message = String(describing: error)
                Self.logger.error("Failed to load Linn configuration: \(message, privacy: .public)")
                lastErrorMessage = message
                connectionState = .failed(message)
                return
            }
        }

        guard let ciGateway else {
            if case .failed = connectionState {
                return
            }
            connectionState = .connected
            return
        }

        updatesTask?.cancel()
        connectionState = .connecting
        lastErrorMessage = nil
        let requestedRoom = room
        Self.logger.info("Starting Linn now-playing updates for requested room \(requestedRoom, privacy: .public)")

        updatesTask = Task { [weak self] in
            guard let self else {
                return
            }

            do {
                for try await update in ciGateway.nowPlayingEvents(room: requestedRoom) {
                    apply(update)
                    connectionState = .connected
                }
            } catch is CancellationError {
                Self.logger.info("Linn now-playing update task cancelled")
                connectionState = .idle
            } catch {
                let message = String(describing: error)
                Self.logger.error("Linn now-playing update task failed: \(message, privacy: .public)")
                lastErrorMessage = message
                connectionState = .failed(message)
            }
        }
    }

    public func stop() {
        updatesTask?.cancel()
        updatesTask = nil
        guard ciGateway != nil else {
            return
        }
        connectionState = .idle
    }

    public func play() {
        performControl(optimisticState: .playing) { ciGateway, room in
            try await ciGateway.play(room: room)
        }
    }

    public func pause() {
        performControl(optimisticState: .paused) { ciGateway, room in
            try await ciGateway.pause(room: room)
        }
    }

    public func playPause() {
        if playState == .playing {
            pause()
        } else {
            play()
        }
    }

    public func previous() {
        guard hasPrevious else {
            return
        }
        performControl { ciGateway, room in
            try await ciGateway.previous(room: room)
        }
    }

    public func next() {
        guard hasNext else {
            return
        }
        optimisticallyAdvanceToNextSong()
        performControl { ciGateway, room in
            try await ciGateway.next(room: room)
        }
    }

    public func setVolume(_ volume: Int) {
        let clampedVolume = max(0, min(maximumVolume, volume))
        self.volume = clampedVolume
        performControl { ciGateway, room in
            try await ciGateway.setVolume(clampedVolume, room: room)
        }
    }

    public func setMuted(_ isMuted: Bool) {
        self.isMuted = isMuted
        performControl { ciGateway, room in
            try await ciGateway.setMuted(isMuted, room: room)
        }
    }

    private func apply(_ update: CiGateway.NowPlaying) {
        let suppressNowPlayingFields = shouldSuppressNowPlayingFields(incomingQueueIndex: update.queue?.index)

        playState = reconciledPlayState(incoming: PlayState(update.playback))
        queueLength = update.queue?.length ?? queueLength
        if let playlist = update.playlist {
            playlistSongs = Dictionary(
                uniqueKeysWithValues: playlist.items.compactMap { item in
                    Song(item).map { (item.index, $0) }
                }
            )
        }

        if !suppressNowPlayingFields {
            currentSong = Song(update.currentItem)
            queueIndex = update.queue?.index
            timeline = Timeline(update.timeline)
        }

        updateUpcomingSongs()
        volume = update.roomState?.volume.map { min($0, maximumVolume) }
        isMuted = update.roomState?.isMuted
    }

    private func optimisticallyAdvanceToNextSong() {
        guard let queueIndex else {
            timeline = nil
            return
        }

        let targetQueueIndex = queueIndex + 1
        optimisticTransition = OptimisticTransition(
            targetQueueIndex: targetQueueIndex,
            expiresAt: Date().addingTimeInterval(4)
        )

        guard let nextSong = playlistSongs[targetQueueIndex] else {
            currentSong = nil
            self.queueIndex = targetQueueIndex
            timeline = nil
            updateUpcomingSongs()
            return
        }

        currentSong = nextSong
        self.queueIndex = targetQueueIndex
        timeline = nil
        updateUpcomingSongs()
    }

    private func shouldSuppressNowPlayingFields(incomingQueueIndex: Int?) -> Bool {
        guard let optimisticTransition else {
            return false
        }

        if Date() >= optimisticTransition.expiresAt {
            self.optimisticTransition = nil
            return false
        }

        if incomingQueueIndex == optimisticTransition.targetQueueIndex {
            self.optimisticTransition = nil
            return false
        }

        return true
    }

    private func reconciledPlayState(incoming: PlayState?) -> PlayState? {
        guard let optimisticPlayState else {
            return incoming
        }

        if Date() >= optimisticPlayState.expiresAt {
            self.optimisticPlayState = nil
            return incoming
        }

        if incoming == optimisticPlayState.targetState {
            self.optimisticPlayState = nil
            return incoming
        }

        return optimisticPlayState.targetState
    }

    private func updateUpcomingSongs() {
        guard let queueIndex else {
            upcomingSongs = []
            return
        }

        upcomingSongs = playlistSongs
            .filter { index, _ in index > queueIndex }
            .sorted { $0.key < $1.key }
            .map(\.value)
    }

    private func performControl(
        optimisticState: PlayState? = nil,
        operation: @escaping (CiGateway, String) async throws -> Void
    ) {
        let previousPlayState = playState
        if let optimisticState {
            optimisticPlayState = OptimisticPlayState(
                targetState: optimisticState,
                previousState: previousPlayState,
                expiresAt: Date().addingTimeInterval(4)
            )
            playState = optimisticState
        }
        lastErrorMessage = nil

        guard let ciGateway else {
            return
        }

        controlTask?.cancel()
        controlTask = Task { [ciGateway, room] in
            do {
                try await operation(ciGateway, room)
            } catch is CancellationError {
            } catch {
                if let optimisticState, self.optimisticPlayState?.targetState == optimisticState {
                    playState = self.optimisticPlayState?.previousState
                    self.optimisticPlayState = nil
                }
                lastErrorMessage = String(describing: error)
            }
        }
    }

    #if DEBUG
        /// Preview/mock-only adapter from button availability flags to the internal queue shape.
        ///
        /// Production state comes from `CiGateway.NowPlaying.Queue`, where `hasPrevious`
        /// and `hasNext` are derived from `queueIndex` and `queueLength`. The debug mock
        /// initializer accepts direct booleans because previews usually care about the
        /// visible button states, not a realistic queue position.
        private func setQueueAvailability(hasPrevious: Bool, hasNext: Bool) {
            switch (hasPrevious, hasNext) {
            case (true, true):
                queueIndex = 1
                queueLength = 3
            case (true, false):
                queueIndex = 1
                queueLength = 2
            case (false, true):
                queueIndex = 0
                queueLength = 2
            case (false, false):
                queueIndex = nil
                queueLength = nil
            }
        }
    #endif
}

public extension Linn.PlayState {
    init?(_ playback: CiGateway.NowPlaying.Playback?) {
        guard let transportState = playback?.transportState else {
            return nil
        }

        switch transportState {
        case .play:
            self = .playing
        case .pause:
            self = .paused
        case .stop:
            self = .stopped
        case .buffering, .waiting:
            self = .buffering
        case .unknown:
            self = .stopped
        }
    }
}

public extension Linn.Song {
    init?(_ item: CiGateway.NowPlaying.CurrentItem?) {
        guard let item else {
            return nil
        }

        let title = item.track?.title ?? item.displayName
        guard let title, !title.isEmpty else {
            return nil
        }

        self.init(
            id: item.id,
            title: title,
            artist: item.track?.artist,
            album: item.track?.album,
            artworkURL: item.artworkURL
        )
    }

    init?(_ item: CiGateway.NowPlaying.PlaylistItem) {
        let title = item.displayName
        guard let title, !title.isEmpty else {
            return nil
        }

        self.init(
            id: "playlist-\(item.index)",
            title: title,
            artist: item.artist,
            album: item.album,
            duration: item.duration,
            artworkURL: item.artworkURL
        )
    }
}

public extension Linn.Timeline {
    init?(_ timeline: CiGateway.NowPlaying.Timeline?) {
        guard let timeline else {
            return nil
        }
        self.init(
            position: timeline.position,
            duration: timeline.duration,
            progress: timeline.progress
        )
    }
}

public extension Linn {
    struct Configuration: Sendable {
        public var ciGatewayWebSocketURL: URL

        public init(ciGatewayWebSocketURL: URL) {
            self.ciGatewayWebSocketURL = ciGatewayWebSocketURL
        }

        public static func local(
            fileURL: URL? = nil,
            environment: [String: String] = ProcessInfo.processInfo.environment,
            currentDirectoryURL: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        ) throws -> Self {
            let values = try DotEnv.load(fileURL: fileURL, currentDirectoryURL: currentDirectoryURL)
            let urlString = environment["LINN_CI_GATEWAY_WS_URL"] ?? values["LINN_CI_GATEWAY_WS_URL"]

            guard let urlString, !urlString.isEmpty else {
                throw ConfigurationError.missingValue("LINN_CI_GATEWAY_WS_URL")
            }
            guard let url = URL(string: urlString) else {
                throw ConfigurationError.invalidURL(urlString)
            }

            return Self(ciGatewayWebSocketURL: url)
        }
    }

    enum ConfigurationError: Error, Sendable {
        case missingValue(String)
        case invalidURL(String)
    }
}

private enum DotEnv {
    static func load(fileURL: URL?, currentDirectoryURL: URL) throws -> [String: String] {
        let url = try fileURL ?? discover(from: currentDirectoryURL)
        guard let url else {
            return [:]
        }

        let contents = try String(contentsOf: url, encoding: .utf8)
        return parse(contents)
    }

    private static func discover(from currentDirectoryURL: URL) throws -> URL? {
        let fileManager = FileManager.default
        let candidates = [
            Bundle.main.url(forResource: ".env", withExtension: nil),
            Bundle.main.bundleURL.appendingPathComponent(".env"),
            currentDirectoryURL.appendingPathComponent(".env"),
            currentDirectoryURL.appendingPathComponent("Louie/.env"),
            currentDirectoryURL.appendingPathComponent("Packages/Linn/.env"),
        ].compactMap(\.self)

        return candidates.first { fileManager.fileExists(atPath: $0.path) }
    }

    private static func parse(_ contents: String) -> [String: String] {
        contents
            .split(whereSeparator: \.isNewline)
            .reduce(into: [:]) { values, line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else {
                    return
                }
                let parts = trimmed.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2 else {
                    return
                }

                let key = parts[0].trimmingCharacters(in: .whitespaces)
                let value = parts[1].trimmingCharacters(in: .whitespaces)
                values[key] = unquote(value)
            }
    }

    private static func unquote(_ value: String) -> String {
        guard value.count >= 2 else {
            return value
        }

        if value.first == "\"", value.last == "\"" {
            return String(value.dropFirst().dropLast())
        }
        if value.first == "'", value.last == "'" {
            return String(value.dropFirst().dropLast())
        }
        return value
    }
}
