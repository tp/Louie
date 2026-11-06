import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2TransportServices
import SwiftProtobuf

private actor WatchAttempt {
    private var receivedSnapshot = false

    func markSnapshotReceived() { receivedSnapshot = true }
    func hasReceivedSnapshot() -> Bool { receivedSnapshot }
}

/// One long-lived HTTP/2 connection to the Raspberry Pi. The Pi alone talks to Linn.
actor PiLinnGateway: LinnGateway {
    private typealias Transport = HTTP2ClientTransport.TransportServices
    private typealias Client = Louie_Linn_V1_Linn.Client<Transport>
    typealias Watch = @Sendable (@escaping @Sendable (Louie_Linn_V1_StateSnapshot) async -> Void) async throws -> Void
    typealias Sleep = @Sendable (Int) async throws -> Void
    private static let commandOptions: CallOptions = {
        var options = CallOptions.defaults
        options.timeout = .seconds(8)
        return options
    }()

    private let serverURL: URL
    private var grpcClient: GRPCClient<Transport>?
    private var connectionTask: Task<Void, Never>?

    init(serverURL: URL) {
        self.serverURL = serverURL
    }

    deinit {
        connectionTask?.cancel()
    }

    private func service() throws -> Client {
        if let grpcClient {
            return Client(wrapping: grpcClient)
        }
        guard serverURL.scheme == "http", let host = serverURL.host(), let port = serverURL.port else {
            throw PiLinnError.invalidServerURL
        }
        let config = Transport.Config.defaults { config in
            config.connection.keepalive = .init(time: .seconds(20), timeout: .seconds(10), allowWithoutCalls: true)
            config.backoff.max = .seconds(5)
            config.resolverBackoff.max = .seconds(5)
        }
        let transport = try Transport(target: .dns(host: host, port: port), transportSecurity: .plaintext, config: config)
        let grpcClient = GRPCClient(transport: transport)
        self.grpcClient = grpcClient
        connectionTask = Task {
            try? await grpcClient.runConnections()
        }
        return Client(wrapping: grpcClient)
    }

    static func isTerminalStreamError(_ code: RPCError.Code) -> Bool {
        switch code {
        case .unimplemented, .unauthenticated, .permissionDenied, .invalidArgument, .failedPrecondition:
            true
        default:
            false
        }
    }

    static func isSuperseded(_ error: RPCError) -> Bool {
        error.code == .cancelled && PiLinnRPCError(error).reason == .superseded
    }

    func nowPlayingUpdates(room _: String?, updateInterval _: Int) async -> AsyncThrowingStream<Linn.Snapshot, Error> {
        // The server currently owns one Linn room and controls its update rate.
        updates(watch: { [self] receive in
            let client = try await service()
            _ = try await client.watchState(Google_Protobuf_Empty()) { response in
                for try await snapshot in response.messages {
                    guard !Task.isCancelled else { break }
                    await receive(snapshot)
                }
            }
        }, sleep: { seconds in
            try await Task.sleep(for: .seconds(seconds))
        })
    }

    func updates(watch: @escaping Watch, sleep: @escaping Sleep) -> AsyncThrowingStream<Linn.Snapshot, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var retrySeconds = 1
                while !Task.isCancelled {
                    let attempt = WatchAttempt()
                    do {
                        try await watch { snapshot in
                            guard !Task.isCancelled else { return }
                            await attempt.markSnapshotReceived()
                            continuation.yield(PiLinnMapping.nowPlaying(snapshot))
                        }
                        guard !Task.isCancelled else { break }
                        continuation.yield(Linn.Snapshot(connectionState: .serverUnreachable))
                    } catch is CancellationError {
                        break
                    } catch let error as PiLinnError {
                        continuation.finish(throwing: error)
                        return
                    } catch let error as RPCError {
                        guard !Task.isCancelled else { break }
                        if Self.isTerminalStreamError(error.code) {
                            continuation.finish(throwing: PiLinnRPCError(error))
                            return
                        }
                        continuation.yield(Linn.Snapshot(connectionState: .serverUnreachable))
                    } catch {
                        // A Pi restart or network transition closes WatchState. Resume
                        // from its next complete snapshot on the same gRPC client.
                        guard !Task.isCancelled else { break }
                        continuation.yield(Linn.Snapshot(connectionState: .serverUnreachable))
                    }
                    if await attempt.hasReceivedSnapshot() { retrySeconds = 1 }
                    do {
                        try await sleep(retrySeconds)
                    } catch {
                        break
                    }
                    retrySeconds = min(retrySeconds * 2, 8)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func play(room: String) async throws {
        _ = try await remapCancellation { try await service().play(Google_Protobuf_Empty(), options: Self.commandOptions) }
    }

    func pause(room: String) async throws {
        _ = try await remapCancellation { try await service().pause(Google_Protobuf_Empty(), options: Self.commandOptions) }
    }

    func previous(room: String) async throws {
        _ = try await remapCancellation { try await service().previous(Google_Protobuf_Empty(), options: Self.commandOptions) }
    }

    func next(room: String) async throws {
        _ = try await remapCancellation { try await service().next(Google_Protobuf_Empty(), options: Self.commandOptions) }
    }

    func selectPlaylistItem(at index: Int, room: String) async throws {
        var request = Louie_Linn_V1_SelectPlaylistItemRequest()
        request.index = Int32(clamping: index)
        _ = try await remapCancellation { try await service().selectPlaylistItem(request, options: Self.commandOptions) }
    }

    func setVolume(_ volume: Int, room: String, group: Bool) async throws {
        var request = Louie_Linn_V1_SetVolumeRequest()
        request.volume = Int32(clamping: volume)
        request.scope = group ? .group : .room
        _ = try await remapCancellation { try await service().setVolume(request, options: Self.commandOptions) }
    }

    func setMuted(_ isMuted: Bool, room: String, group: Bool) async throws {
        var request = Louie_Linn_V1_SetMutedRequest()
        request.isMuted = isMuted
        request.scope = group ? .group : .room
        _ = try await remapCancellation { try await service().setMuted(request, options: Self.commandOptions) }
    }

    func mediaServices(room: String) async throws -> [Linn.LibraryService] {
        let response = try await remapCancellation { try await service().listMediaServices(Google_Protobuf_Empty(), options: Self.commandOptions) }
        return response.services.map { Linn.LibraryService(id: $0.id, name: $0.name) }
    }

    func browseMedia(mediaID: String, index: Int, count: Int, browseType: String) async throws -> Linn.LibraryPage {
        var request = Louie_Linn_V1_BrowseMediaRequest()
        request.mediaID = mediaID
        request.index = Int32(clamping: index)
        request.count = Int32(clamping: count)
        request.browseType = browseType
        return PiLinnMapping.mediaPage(try await remapCancellation { try await service().browseMedia(request, options: Self.commandOptions) })
    }

    func searchMedia(serviceID: String, query: String, type: Linn.SearchType, index: Int, count: Int) async throws -> Linn.LibraryPage {
        var request = Louie_Linn_V1_SearchMediaRequest()
        request.serviceID = serviceID
        request.query = query
        request.type = switch type {
        case .albums: .albums
        case .artists: .artists
        case .tracks: .tracks
        case .playlists: .playlists
        case .composers: .composers
        case .stations: .stations
        }
        request.index = Int32(clamping: index)
        request.count = Int32(clamping: count)
        return PiLinnMapping.mediaPage(try await remapCancellation { try await service().searchMedia(request, options: Self.commandOptions) })
    }

    func selectMedia(mediaID: String, room: String, queue: Linn.QueuePlacement) async throws {
        try await selectMedia(mediaID: mediaID, room: room, queue: queue, preview: nil)
    }

    func selectMedia(mediaID: String, room: String, queue: Linn.QueuePlacement, preview: Linn.LibraryItem?) async throws {
        var request = Louie_Linn_V1_SelectMediaRequest()
        request.mediaID = mediaID
        request.queue = switch queue {
        case .now: .now
        case .next: .next
        case .last: .last
        case .replace: .replace
        }
        if let preview {
            request.preview = PiLinnMapping.preview(preview)
        }
        _ = try await remapCancellation { try await service().selectMedia(request, options: Self.commandOptions) }
    }

    func setMediaFavourite(mediaID: String, isFavourite: Bool) async throws {
        var request = Louie_Linn_V1_SetMediaFavouriteRequest()
        request.mediaID = mediaID
        request.isFavourite = isFavourite
        _ = try await remapCancellation { try await service().setMediaFavourite(request, options: Self.commandOptions) }
    }

    private func remapCancellation<Value>(_ operation: () async throws -> Value) async throws -> Value {
        do {
            return try await operation()
        } catch let error as RPCError {
            if error.code == .cancelled && (Task.isCancelled || Self.isSuperseded(error)) {
                throw CancellationError()
            }
            throw PiLinnRPCError(error)
        }
    }
}

private enum PiLinnError: Error, LocalizedError {
    case invalidServerURL

    var errorDescription: String? {
        switch self {
        case .invalidServerURL: "Invalid Louie Home Server address"
        }
    }
}

/// Keep the gRPC status available to callers while presenting stable, useful copy.
struct PiLinnRPCError: Error, LocalizedError {
    enum Reason: String {
        case linnDisconnected = "linn-disconnected"
        case linnStandby = "linn-standby"
        case linnRejected = "linn-rejected"
        case sourceNotSeekable = "source-not-seekable"
        case gatewayUnavailable = "gateway-unavailable"
        case superseded
    }

    let code: RPCError.Code
    let message: String
    let reason: Reason?

    init(code: RPCError.Code, message: String, reason: Reason? = nil) {
        self.code = code
        self.message = message
        self.reason = reason
    }

    init(_ error: RPCError) {
        var reasons = error.metadata[stringValues: "louie-error-reason"].makeIterator()
        self.init(
            code: error.code,
            message: error.message,
            reason: reasons.next().flatMap(Reason.init(rawValue:))
        )
    }

    var errorDescription: String? {
        switch code {
        case .unavailable: "Can't reach Louie Home Server."
        case .deadlineExceeded: "The Linn request timed out."
        case .failedPrecondition:
            switch reason {
            case .linnDisconnected, .gatewayUnavailable: "Louie Home Server can't reach Linn."
            case .linnStandby: "Linn is off. Turn it on to control playback."
            case .sourceNotSeekable: "This source doesn't support seeking."
            case .linnRejected: "Linn rejected the request."
            case .superseded: "The request was superseded."
            case nil: "Linn can't perform this action right now."
            }
        case .invalidArgument: "This request isn't valid."
        case .unauthenticated, .permissionDenied: "Louie Home Server rejected access."
        case .unimplemented: "Louie Home Server needs an update."
        case .resourceExhausted: "Louie Home Server is busy. Try again."
        case .internalError: "Louie Home Server had an internal error."
        case .cancelled: "The request was cancelled."
        default: "Louie Home Server request failed (\(code))."
        }
    }
}

enum PiLinnMapping {
    static func nowPlaying(_ snapshot: Louie_Linn_V1_StateSnapshot) -> Linn.Snapshot {
        let error = snapshot.hasConnectionError ? snapshot.connectionError : nil
        let connection: Linn.ConnectionState = switch snapshot.connectionStatus {
        case .connected: .connected
        case .disconnected: .linnUnavailable(error)
        default: error.map { .linnUnavailable($0) } ?? .connecting
        }
        var result = Linn.Snapshot(connectionState: connection)
        result.pending.queueIndex = snapshot.pending.queueIndex
        result.pending.queueTotal = snapshot.pending.queueTotal
        result.pending.currentItem = snapshot.pending.currentItem
        result.pending.volume = snapshot.pending.volume
        result.pending.mute = snapshot.pending.mute
        let state = snapshot.nowPlaying
        result.isStandby = state.isStandby
        if state.hasTransportState {
            result.playState = switch state.transportState {
            case .playing: .playing
            case .paused: .paused
            case .buffering, .waiting: .buffering
            default: .stopped
            }
        }
        let playlist = state.playlist
        result.playlist = .init(
            songs: playlist.items.compactMap { item in
                guard item.hasDisplayName, !item.displayName.isEmpty else { return nil }
                return Linn.Song(
                    id: "playlist-\(item.index)",
                    title: item.displayName,
                    artist: item.hasArtist ? item.artist : nil,
                    album: item.hasAlbum ? item.album : nil,
                    duration: item.hasDurationSeconds ? Int(item.durationSeconds) : nil,
                    artworkURL: item.hasArtworkURL ? URL(string: item.artworkURL) : nil,
                    queueIndex: Int(item.index)
                )
            },
            currentIndex: playlist.hasCurrentIndex ? Int(playlist.currentIndex) : nil,
            total: playlist.hasTotal ? Int(playlist.total) : nil
        )
        if state.hasCurrentItem {
            let item = state.currentItem
            let title = item.track.hasTitle ? item.track.title : item.displayName
            if !title.isEmpty {
                result.currentSong = .init(
                    id: item.id,
                    title: title,
                    artist: item.track.hasArtist ? item.track.artist : nil,
                    album: item.track.hasAlbum ? item.track.album : nil,
                    artworkURL: item.hasArtworkURL ? URL(string: item.artworkURL) : nil,
                    queueIndex: result.playlist.currentIndex
                )
            }
        }
        if state.hasTimeline {
            let timeline = state.timeline
            let position = timeline.hasPositionSeconds ? Int(timeline.positionSeconds) : nil
            let duration = timeline.hasDurationSeconds ? Int(timeline.durationSeconds) : nil
            let progress: Double? = if let position, let duration, duration > 0 {
                Double(position) / Double(duration)
            } else {
                nil
            }
            result.timeline = .init(
                position: position,
                duration: duration,
                progress: progress
            )
        }
        let volume = state.roomVolume
        result.volume = volume.hasVolume ? Int(volume.volume) : nil
        result.isMuted = volume.hasIsMuted ? volume.isMuted : nil
        result.maximumVolume = volume.maximumVolume > 0 ? Int(volume.maximumVolume) : nil
        return result
    }

    static func mediaPage(_ page: Louie_Linn_V1_MediaPage) -> Linn.LibraryPage {
        .init(
            id: page.hasID ? page.id : nil,
            contentRevision: page.hasContentRevision ? Int(exactly: page.contentRevision) : nil,
            index: Int(page.index),
            count: Int(page.count),
            total: page.hasTotal ? Int(page.total) : nil,
            items: page.children.map(mediaItem)
        )
    }

    private static func mediaItem(_ item: Louie_Linn_V1_MediaItem) -> Linn.LibraryItem {
        let fallbackKind: String = switch item.type {
        case .track: "md.track"
        case .album: "md.album"
        case .artist: "md.artist"
        case .playlist: "md.playlist"
        case .station: "md.station"
        case .container where item.provider == .qobuz: "md.qobuz.container"
        case .container: "md.container"
        default: item.isContainer ? "md.container" : "md.other"
        }
        let title = item.hasTitle ? item.title : (item.hasName ? item.name : item.id)
        let subtitle = item.artists.isEmpty ? (item.hasAlbum ? item.album : nil) : item.artists.joined(separator: ", ")
        return .init(
            id: item.id,
            kind: item.hasLinnClass ? item.linnClass : fallbackKind,
            title: title.isEmpty ? item.id : title,
            subtitle: subtitle,
            album: item.hasAlbum ? item.album : nil,
            artists: item.artists,
            artworkURL: item.hasArtworkURL ? URL(string: item.artworkURL) : nil,
            duration: item.hasDurationSeconds ? Int(item.durationSeconds) : nil,
            containedKinds: item.containedClasses,
            childCount: item.hasChildCount ? Int(item.childCount) : nil,
            isFavourite: item.hasIsFavourite ? item.isFavourite : nil,
            canFavourite: item.canFavourite && item.hasIsFavourite
        )
    }

    static func preview(_ item: Linn.LibraryItem) -> Louie_Linn_V1_MediaItem {
        var preview = Louie_Linn_V1_MediaItem()
        preview.id = item.id
        preview.type = if item.kind.contains("container") { .container }
            else if item.kind.contains("track") { .track }
            else if item.kind.contains("album") { .album }
            else if item.kind.contains("artist") { .artist }
            else if item.kind.contains("playlist") { .playlist }
            else if item.kind.contains("station") { .station }
            else { .container }
        preview.provider = item.kind.contains("qobuz") ? .qobuz : .other
        preview.linnClass = item.kind
        preview.containedClasses = item.containedKinds
        preview.isContainer = item.isContainer
        preview.canFavourite = item.canFavourite
        preview.title = item.title
        if let album = item.album { preview.album = album }
        preview.artists = item.artists
        if let artworkURL = item.artworkURL { preview.artworkURL = artworkURL.absoluteString }
        if let duration = item.duration { preview.durationSeconds = Int32(clamping: duration) }
        if let childCount = item.childCount { preview.childCount = Int32(clamping: childCount) }
        if let isFavourite = item.isFavourite { preview.isFavourite = isFavourite }
        return preview
    }
}
