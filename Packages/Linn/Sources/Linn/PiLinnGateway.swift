import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2TransportServices
import SwiftProtobuf

/// One long-lived HTTP/2 connection to the Raspberry Pi. The Pi alone talks to Linn.
actor PiLinnGateway: LinnGateway {
    private typealias Transport = HTTP2ClientTransport.TransportServices
    private typealias Client = Louie_Linn_V1_Linn.Client<Transport>
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

    func nowPlayingUpdates(room: String?, updateInterval: Int) async -> AsyncThrowingStream<LinnGatewayData.NowPlaying, Error> {
        // The server currently owns one Linn room and controls its update rate.
        AsyncThrowingStream { continuation in
            let task = Task {
                var retrySeconds = 1
                while !Task.isCancelled {
                    do {
                        let client = try service()
                        let receivedSnapshot = try await client.watchState(Google_Protobuf_Empty()) { response in
                            var receivedSnapshot = false
                            do {
                                for try await snapshot in response.messages {
                                    guard !Task.isCancelled else { break }
                                    receivedSnapshot = true
                                    switch snapshot.connectionStatus {
                                    case .connected:
                                        continuation.yield(PiLinnMapping.nowPlaying(snapshot))
                                    case .connecting, .disconnected, .unspecified:
                                        // Linn can drop while the home server stays available.
                                        // Keep the stream alive for its next connected snapshot.
                                        continuation.yield(PiLinnMapping.connectionUpdate(snapshot))
                                    default:
                                        continue
                                    }
                                }
                            } catch is CancellationError {
                                throw CancellationError()
                            } catch let error as RPCError where error.code == .cancelled && Task.isCancelled {
                                throw CancellationError()
                            } catch {
                                // A new WatchState starts with a full snapshot.
                            }
                            return receivedSnapshot
                        }
                        if receivedSnapshot { retrySeconds = 1 }
                        guard !Task.isCancelled else { break }
                        var update = LinnGatewayData.NowPlaying(room: room ?? "Linn", session: "")
                        update.connectionStatus = .serverUnreachable
                        continuation.yield(update)
                    } catch is CancellationError {
                        break
                    } catch let error as PiLinnError {
                        continuation.finish(throwing: error)
                        return
                    } catch {
                        // A Pi restart or network transition closes WatchState. Resume
                        // from its next complete snapshot on the same gRPC client.
                        guard !Task.isCancelled else { break }
                        var update = LinnGatewayData.NowPlaying(room: room ?? "Linn", session: "")
                        update.connectionStatus = .serverUnreachable
                        continuation.yield(update)
                    }
                    do {
                        try await Task.sleep(for: .seconds(retrySeconds))
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
            if error.code == .cancelled && (Task.isCancelled || error.message.contains("superseded")) {
                throw CancellationError()
            }
            throw PiLinnRPCError(code: error.code, message: error.message)
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
    let code: RPCError.Code
    let message: String

    var errorDescription: String? {
        switch code {
        case .unavailable: "Can't reach Louie Home Server."
        case .deadlineExceeded: "The Linn request timed out."
        case .failedPrecondition:
            message == "Linn gateway is disconnected"
                ? "Louie Home Server can't reach Linn."
                : message.isEmpty ? "Linn can't perform this action right now." : message
        case .invalidArgument: "This request isn't valid."
        case .unauthenticated, .permissionDenied: "Louie Home Server rejected access."
        case .cancelled: "The request was cancelled."
        default: "Louie Home Server request failed (\(code))."
        }
    }
}

enum PiLinnMapping {
    static func connectionUpdate(_ snapshot: Louie_Linn_V1_StateSnapshot) -> LinnGatewayData.NowPlaying {
        var update = LinnGatewayData.NowPlaying(room: snapshot.room, session: snapshot.nowPlayingSessionID)
        update.connectionStatus = snapshot.connectionStatus == .disconnected ? .disconnected : .connecting
        update.connectionError = snapshot.hasConnectionError ? snapshot.connectionError : nil
        return update
    }

    static func nowPlaying(_ snapshot: Louie_Linn_V1_StateSnapshot) -> LinnGatewayData.NowPlaying {
        var result = LinnGatewayData.NowPlaying(room: snapshot.room, session: snapshot.nowPlayingSessionID)
        if snapshot.hasPending {
            result.pending = .init(
                playback: snapshot.pending.playback,
                transport: snapshot.pending.transport,
                queue: snapshot.pending.queue,
                queueIndex: snapshot.pending.queueIndex,
                queueTotal: snapshot.pending.queueTotal,
                currentItem: snapshot.pending.currentItem,
                timeline: snapshot.pending.timeline,
                volume: snapshot.pending.volume,
                mute: snapshot.pending.mute
            )
        }
        guard snapshot.hasNowPlaying else { return result }
        let state = snapshot.nowPlaying
        if state.hasTransportState {
            let transport: LinnGatewayData.NowPlaying.TransportState = switch state.transportState {
            case .playing: .play
            case .paused: .pause
            case .stopped: .stop
            case .buffering: .buffering
            case .waiting: .waiting
            default: .unknown
            }
            result.playback = .init(transportState: transport)
        }
        if state.hasCurrentItem {
            let item = state.currentItem
            result.currentItem = .init(
                id: item.id,
                kind: "track",
                displayName: item.hasDisplayName ? item.displayName : nil,
                artworkURL: item.hasArtworkURL ? URL(string: item.artworkURL) : nil,
                track: item.hasTrack ? .init(
                    title: item.track.hasTitle ? item.track.title : nil,
                    album: item.track.hasAlbum ? item.track.album : nil,
                    artist: item.track.hasArtist ? item.track.artist : nil
                ) : nil
            )
        }
        if state.hasPlaylist {
            let playlist = state.playlist
            result.queue = .init(
                index: playlist.hasCurrentIndex ? Int(playlist.currentIndex) : nil,
                length: playlist.hasTotal ? Int(playlist.total) : nil
            )
            result.playlist = .init(
                items: playlist.items.map { item in
                    .init(
                        index: Int(item.index),
                        displayName: item.hasDisplayName ? item.displayName : nil,
                        album: item.hasAlbum ? item.album : nil,
                        artist: item.hasArtist ? item.artist : nil,
                        duration: item.hasDurationSeconds ? Int(item.durationSeconds) : nil,
                        artworkURL: item.hasArtworkURL ? URL(string: item.artworkURL) : nil,
                        isCurrent: item.isCurrent
                    )
                },
                total: playlist.hasTotal ? Int(playlist.total) : nil,
                contentRevision: playlist.hasContentRevision ? Int(exactly: playlist.contentRevision) : nil
            )
        }
        if state.hasTimeline {
            let timeline = state.timeline
            result.timeline = .init(
                position: timeline.hasPositionSeconds ? Int(timeline.positionSeconds) : nil,
                duration: timeline.hasDurationSeconds ? Int(timeline.durationSeconds) : nil,
                seekableRange: timeline.hasIsSeekable && timeline.isSeekable
                    ? .init(
                        lowerBound: timeline.hasSeekLowerBoundSeconds ? Int(timeline.seekLowerBoundSeconds) : nil,
                        upperBound: timeline.hasSeekUpperBoundSeconds ? Int(timeline.seekUpperBoundSeconds) : nil
                    ) : nil
            )
        }
        if state.hasRoomVolume {
            let volume = state.roomVolume
            result.roomState = .init(
                volume: volume.hasVolume ? Int(volume.volume) : nil,
                isMuted: volume.hasIsMuted ? volume.isMuted : nil,
                maximumVolume: volume.maximumVolume > 0 ? Int(volume.maximumVolume) : nil
            )
        }
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
            canFavourite: item.canFavourite
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
