import Foundation
import LinnCiGateway
import Observation
import OSLog

public protocol LinnGateway: Sendable {
    func nowPlayingUpdates(
        room: String?,
        updateInterval: Int
    ) async -> AsyncThrowingStream<CiGateway.NowPlaying, Error>

    func play(room: String) async throws
    func pause(room: String) async throws
    func previous(room: String) async throws
    func next(room: String) async throws
    func selectPlaylistItem(at index: Int, room: String) async throws
    func setVolume(_ volume: Int, room: String, group: Bool) async throws
    func setMuted(_ isMuted: Bool, room: String, group: Bool) async throws
}

public extension LinnGateway {
    func setVolume(_ volume: Int, room: String) async throws {
        try await setVolume(volume, room: room, group: true)
    }

    func setMuted(_ isMuted: Bool, room: String) async throws {
        try await setMuted(isMuted, room: room, group: true)
    }
}

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

    public enum SongTransitionDirection: Sendable, Equatable {
        case forward
        case backward
    }

    public struct Song: Sendable, Equatable, Identifiable {
        public var id: String
        public var title: String
        public var artist: String?
        public var album: String?
        public var duration: Int?
        public var artworkURL: URL?
        public var queueIndex: Int?

        public init(
            id: String,
            title: String,
            artist: String? = nil,
            album: String? = nil,
            duration: Int? = nil,
            artworkURL: URL? = nil,
            queueIndex: Int? = nil
        ) {
            self.id = id
            self.title = title
            self.artist = artist
            self.album = album
            self.duration = duration
            self.artworkURL = artworkURL
            self.queueIndex = queueIndex
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

    public struct Playlist: Sendable, Equatable {
        public var songs: [Song]
        public var currentIndex: Int?
        public var total: Int?

        public init(songs: [Song] = [], currentIndex: Int? = nil, total: Int? = nil) {
            self.songs = songs
            self.currentIndex = currentIndex
            self.total = total
        }
    }

    public let room: String
    public let maximumVolume: Int
    public private(set) var connectionState: ConnectionState = .idle
    public private(set) var currentSong: Song?
    public private(set) var playlist = Playlist()
    public private(set) var playState: PlayState?
    public private(set) var volume: Int?
    public private(set) var isMuted: Bool?
    public private(set) var timeline: Timeline?
    public private(set) var lastErrorMessage: String?
    public private(set) var songTransitionDirection: SongTransitionDirection = .forward

    public var previousSongs: [Song] {
        guard let currentIndex = playlist.currentIndex else {
            return []
        }

        return playlist.songs
            .filter { ($0.queueIndex ?? currentIndex) < currentIndex }
            .sorted { ($0.queueIndex ?? 0) > ($1.queueIndex ?? 0) }
    }

    public var upcomingSongs: [Song] {
        guard let currentIndex = playlist.currentIndex else {
            return []
        }

        return playlist.songs
            .filter { ($0.queueIndex ?? currentIndex) > currentIndex }
            .sorted { ($0.queueIndex ?? 0) < ($1.queueIndex ?? 0) }
    }

    public var hasPrevious: Bool {
        guard let currentIndex = playlist.currentIndex else {
            return false
        }
        return currentIndex > 0
    }

    public var hasNext: Bool {
        guard let currentIndex = playlist.currentIndex, let total = playlist.total else {
            return false
        }
        return currentIndex + 1 < total
    }

    private var ciGateway: (any LinnGateway)?
    private var configurationLoadAttempted = false
    private var playlistContentRevision: Int?
    private var playlistSongsByIndex: [Int: Song] = [:]
    private var optimisticTransition: OptimisticTransition?
    private var optimisticPlayState: OptimisticPlayState?
    private var playlistSelectionQueue = PlaylistSelectionQueue()
    private static let logger = Logger(subsystem: "Louie.Linn", category: "Linn")

    @ObservationIgnored private var updatesTask: Task<Void, Never>?
    @ObservationIgnored private var controlTask: Task<Void, Never>?
    @ObservationIgnored private var playlistSelectionTask: Task<Void, Never>?
    @ObservationIgnored private var playlistSelectionTimeoutTask: Task<Void, Never>?

    private struct OptimisticTransition {
        var targetQueueIndex: Int
        var expiresAt: Date
    }

    private struct OptimisticPlayState {
        var targetState: PlayState
        var previousState: PlayState?
        var expiresAt: Date
    }

    private struct PlaylistSelectionJob: Sendable, Equatable {
        enum Kind: Sendable, Equatable {
            case skip
            case queueItem
        }

        var targetIndex: Int
        var kind: Kind
    }

    private struct PlaylistSelectionQueue: Sendable, Equatable {
        var inFlight: PlaylistSelectionJob?
        var pending: PlaylistSelectionJob?

        mutating func enqueue(_ job: PlaylistSelectionJob) -> PlaylistSelectionJob? {
            guard let inFlight else {
                inFlight = job
                return job
            }

            pending = job.targetIndex == inFlight.targetIndex ? nil : job
            return nil
        }

        mutating func confirm(targetIndex: Int) -> (confirmed: Bool, next: PlaylistSelectionJob?) {
            guard inFlight?.targetIndex == targetIndex else {
                return (false, nil)
            }

            inFlight = nil
            return (true, dequeuePending())
        }

        mutating func fail(targetIndex: Int) -> (failed: Bool, next: PlaylistSelectionJob?) {
            guard inFlight?.targetIndex == targetIndex else {
                return (false, nil)
            }

            inFlight = nil
            return (true, dequeuePending())
        }

        private mutating func dequeuePending() -> PlaylistSelectionJob? {
            guard let pending else {
                return nil
            }

            self.pending = nil
            inFlight = pending
            return pending
        }
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
        gateway: any LinnGateway,
        room: String = "Linn",
        maximumVolume: Int = 70
    ) {
        self.room = room
        self.maximumVolume = maximumVolume
        ciGateway = gateway
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
            previousSongs: [Song] = [],
            playState: PlayState? = nil,
            volume: Int? = nil,
            isMuted: Bool? = nil,
            timeline: Timeline? = nil,
            songTransitionDirection: SongTransitionDirection = .forward,
            hasPrevious: Bool = false,
            hasNext: Bool = false,
            lastErrorMessage: String? = nil
        ) {
            self.room = room
            self.maximumVolume = maximumVolume
            self.connectionState = connectionState
            self.currentSong = currentSong
            installMockPlaylist(previousSongs: previousSongs, currentSong: currentSong)
            self.playState = playState
            self.volume = volume
            self.isMuted = isMuted
            self.timeline = timeline
            self.songTransitionDirection = songTransitionDirection
            self.lastErrorMessage = lastErrorMessage
            ciGateway = nil
            configurationLoadAttempted = true
            setQueueAvailability(hasPrevious: hasPrevious, hasNext: hasNext)
        }
    #endif

    deinit {
        updatesTask?.cancel()
        controlTask?.cancel()
        playlistSelectionTask?.cancel()
        playlistSelectionTimeoutTask?.cancel()
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
                let updates = await ciGateway.nowPlayingUpdates(room: requestedRoom, updateInterval: 1)
                for try await update in updates {
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
        guard hasPrevious, let currentIndex = playlist.currentIndex else {
            return
        }

        selectQueueIndex(currentIndex - 1, kind: .skip)
    }

    public func next() {
        guard hasNext, let currentIndex = playlist.currentIndex else {
            return
        }

        selectQueueIndex(currentIndex + 1, kind: .skip)
    }

    public func play(_ song: Song) {
        guard let targetQueueIndex = song.queueIndex else {
            return
        }

        selectQueueIndex(targetQueueIndex, optimisticSong: song, kind: .queueItem)
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
        playlist.total = update.queue?.length ?? playlist.total
        if let playlist = update.playlist {
            if let contentRevision = playlist.contentRevision, contentRevision != playlistContentRevision {
                playlistSongsByIndex = [:]
                playlistContentRevision = contentRevision
            }

            for item in playlist.items {
                playlistSongsByIndex[item.index] = Song(item)
            }
        }

        if !suppressNowPlayingFields {
            updateSongTransitionDirection(incomingQueueIndex: update.queue?.index)
            var incomingCurrentSong = Song(update.currentItem)
            if let incomingQueueIndex = update.queue?.index {
                incomingCurrentSong?.queueIndex = incomingQueueIndex
            }
            currentSong = incomingCurrentSong
            if let incomingQueueIndex = update.queue?.index, let incomingCurrentSong {
                playlistSongsByIndex[incomingQueueIndex] = incomingCurrentSong
            }
            playlist.currentIndex = update.queue?.index
            timeline = Timeline(update.timeline)
        }

        reconcilePlaylistSelectionConfirmation(incomingQueueIndex: update.queue?.index)
        updatePlaylistSongs()
        volume = update.roomState?.volume.map { min($0, maximumVolume) }
        isMuted = update.roomState?.isMuted
    }

    private func selectQueueIndex(
        _ targetQueueIndex: Int,
        optimisticSong: Song? = nil,
        kind: PlaylistSelectionJob.Kind
    ) {
        if targetQueueIndex < 0 {
            return
        }
        if let total = playlist.total, targetQueueIndex >= total {
            return
        }

        optimisticallySelectQueueIndex(targetQueueIndex, song: optimisticSong ?? playlistSongsByIndex[targetQueueIndex])
        enqueuePlaylistSelection(PlaylistSelectionJob(targetIndex: targetQueueIndex, kind: kind))
    }

    private func optimisticallySelectQueueIndex(_ targetQueueIndex: Int, song: Song?) {
        updateSongTransitionDirection(incomingQueueIndex: targetQueueIndex)
        optimisticTransition = OptimisticTransition(
            targetQueueIndex: targetQueueIndex,
            expiresAt: Date().addingTimeInterval(4)
        )

        guard var selectedSong = song else {
            currentSong = nil
            playlist.currentIndex = targetQueueIndex
            timeline = nil
            updatePlaylistSongs()
            return
        }

        selectedSong.queueIndex = targetQueueIndex
        playlistSongsByIndex[targetQueueIndex] = selectedSong
        currentSong = selectedSong
        playlist.currentIndex = targetQueueIndex
        timeline = nil
        updatePlaylistSongs()
    }

    private func enqueuePlaylistSelection(_ job: PlaylistSelectionJob) {
        lastErrorMessage = nil

        guard ciGateway != nil else {
            return
        }

        if let jobToSend = playlistSelectionQueue.enqueue(job) {
            sendPlaylistSelection(jobToSend)
        }
    }

    private func sendPlaylistSelection(_ job: PlaylistSelectionJob) {
        guard let ciGateway else {
            return
        }

        playlistSelectionTimeoutTask?.cancel()
        playlistSelectionTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            self?.playlistSelectionTimedOut(job)
        }

        playlistSelectionTask = Task { [ciGateway, room] in
            do {
                try await ciGateway.selectPlaylistItem(at: job.targetIndex, room: room)
            } catch is CancellationError {
            } catch {
                let failure = playlistSelectionQueue.fail(targetIndex: job.targetIndex)
                if failure.failed {
                    playlistSelectionTimeoutTask?.cancel()
                    lastErrorMessage = String(describing: error)
                }
                if let nextJob = failure.next {
                    sendPlaylistSelection(nextJob)
                }
            }
        }
    }

    private func reconcilePlaylistSelectionConfirmation(incomingQueueIndex: Int?) {
        guard let incomingQueueIndex else {
            return
        }

        let confirmation = playlistSelectionQueue.confirm(targetIndex: incomingQueueIndex)
        if confirmation.confirmed {
            playlistSelectionTimeoutTask?.cancel()
        }
        if let nextJob = confirmation.next {
            sendPlaylistSelection(nextJob)
        }
    }

    private func playlistSelectionTimedOut(_ job: PlaylistSelectionJob) {
        let failure = playlistSelectionQueue.fail(targetIndex: job.targetIndex)
        if let nextJob = failure.next {
            sendPlaylistSelection(nextJob)
        }
    }

    private func updateSongTransitionDirection(incomingQueueIndex: Int?) {
        guard let currentIndex = playlist.currentIndex, let incomingQueueIndex, currentIndex != incomingQueueIndex else {
            return
        }

        songTransitionDirection = incomingQueueIndex > currentIndex ? .forward : .backward
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

    private func updatePlaylistSongs() {
        playlist.songs = playlistSongsByIndex
            .sorted { $0.key < $1.key }
            .map(\.value)
    }

    private func performControl(
        optimisticState: PlayState? = nil,
        operation: @escaping (any LinnGateway, String) async throws -> Void
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
        private func installMockPlaylist(previousSongs: [Song], currentSong: Song?) {
            playlistSongsByIndex = [:]

            for (index, song) in previousSongs.reversed().enumerated() {
                var indexedSong = song
                indexedSong.queueIndex = index
                playlistSongsByIndex[index] = indexedSong
            }

            if var currentSong {
                let currentIndex = previousSongs.count
                currentSong.queueIndex = currentIndex
                self.currentSong = currentSong
                playlistSongsByIndex[currentIndex] = currentSong
                playlist.currentIndex = currentIndex
                playlist.total = currentIndex + 1
            }

            updatePlaylistSongs()
        }

        /// Preview/mock-only adapter from button availability flags to the internal queue shape.
        ///
        /// Production state comes from `CiGateway.NowPlaying.Queue`, where `hasPrevious`
        /// and `hasNext` are derived from the playlist current index and total. The debug mock
        /// initializer accepts direct booleans because previews usually care about the
        /// visible button states, not a realistic queue position.
        private func setQueueAvailability(hasPrevious: Bool, hasNext: Bool) {
            var currentIndex = playlist.currentIndex
            var total = playlist.total

            switch (hasPrevious, hasNext) {
            case (true, true):
                currentIndex = currentIndex ?? 1
                total = max(total ?? 0, (currentIndex ?? 1) + 2)
            case (true, false):
                currentIndex = currentIndex ?? 1
                total = max(total ?? 0, (currentIndex ?? 1) + 1)
            case (false, true):
                currentIndex = currentIndex ?? 0
                total = max(total ?? 0, (currentIndex ?? 0) + 2)
            case (false, false):
                if playlist.songs.isEmpty {
                    currentIndex = nil
                    total = nil
                } else {
                    currentIndex = currentIndex ?? 0
                    total = total ?? playlist.songs.count
                }
            }

            playlist.currentIndex = currentIndex
            playlist.total = total
        }
    #endif
}

extension CiGateway: LinnGateway {
    public func nowPlayingUpdates(
        room: String?,
        updateInterval: Int
    ) async -> AsyncThrowingStream<NowPlaying, Error> {
        nowPlayingEvents(room: room, updateInterval: updateInterval)
    }
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
            artworkURL: item.artworkURL,
            queueIndex: item.index
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
