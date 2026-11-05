import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2TransportServices
import LinnCiGateway
import SwiftProtobuf

/// One long-lived HTTP/2 connection to the Raspberry Pi. The Pi alone talks to Linn.
actor PiLinnGateway: LinnGateway {
    private typealias Transport = HTTP2ClientTransport.TransportServices
    private typealias Client = Louie_Linn_V1_Linn.Client<Transport>

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
        let transport = try Transport(target: .dns(host: host, port: port), transportSecurity: .plaintext)
        let grpcClient = GRPCClient(transport: transport)
        self.grpcClient = grpcClient
        connectionTask = Task {
            try? await grpcClient.runConnections()
        }
        return Client(wrapping: grpcClient)
    }

    func nowPlayingUpdates(room: String?, updateInterval: Int) async -> AsyncThrowingStream<CiGateway.NowPlaying, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let client = try service()
                    try await client.watchState(Google_Protobuf_Empty()) { response in
                        for try await snapshot in response.messages {
                            switch snapshot.connectionStatus {
                            case .connecting, .unspecified:
                                continue
                            case .disconnected:
                                throw PiLinnError.gatewayDisconnected(
                                    snapshot.hasConnectionError ? snapshot.connectionError : nil
                                )
                            case .connected:
                                break
                            default:
                                continue
                            }
                            continuation.yield(PiLinnMapping.nowPlaying(snapshot))
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func play(room: String) async throws {
        _ = try await service().play(Google_Protobuf_Empty())
    }

    func pause(room: String) async throws {
        _ = try await service().pause(Google_Protobuf_Empty())
    }

    func previous(room: String) async throws {
        _ = try await service().previous(Google_Protobuf_Empty())
    }

    func next(room: String) async throws {
        _ = try await service().next(Google_Protobuf_Empty())
    }

    func selectPlaylistItem(at index: Int, room: String) async throws {
        var request = Louie_Linn_V1_SelectPlaylistItemRequest()
        request.index = Int32(clamping: index)
        _ = try await service().selectPlaylistItem(request)
    }

    func setVolume(_ volume: Int, room: String, group: Bool) async throws {
        var request = Louie_Linn_V1_SetVolumeRequest()
        request.volume = Int32(clamping: volume)
        request.scope = group ? .group : .room
        _ = try await service().setVolume(request)
    }

    func setMuted(_ isMuted: Bool, room: String, group: Bool) async throws {
        var request = Louie_Linn_V1_SetMutedRequest()
        request.isMuted = isMuted
        request.scope = group ? .group : .room
        _ = try await service().setMuted(request)
    }

    func mediaServices(room: String) async throws -> [CiGateway.MediaService] {
        let response = try await service().listMediaServices(Google_Protobuf_Empty())
        return response.services.map { CiGateway.MediaService(id: $0.id, name: $0.name) }
    }

    func browseMedia(mediaID: String, index: Int, count: Int, browseType: String) async throws -> CiGateway.MediaPage {
        var request = Louie_Linn_V1_BrowseMediaRequest()
        request.mediaID = mediaID
        request.index = Int32(clamping: index)
        request.count = Int32(clamping: count)
        request.browseType = browseType
        return PiLinnMapping.mediaPage(try await service().browseMedia(request))
    }

    func searchMedia(serviceID: String, query: String, type: CiGateway.MediaSearchType, index: Int, count: Int) async throws -> CiGateway.MediaPage {
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
        return PiLinnMapping.mediaPage(try await service().searchMedia(request))
    }

    func selectMedia(mediaID: String, room: String, queue: CiGateway.QueuePlacement) async throws {
        try await selectMedia(mediaID: mediaID, room: room, queue: queue, preview: nil)
    }

    func selectMedia(mediaID: String, room: String, queue: CiGateway.QueuePlacement, preview: CiGateway.MediaItem?) async throws {
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
        _ = try await service().selectMedia(request)
    }

    func setMediaFavourite(mediaID: String, isFavourite: Bool) async throws {
        var request = Louie_Linn_V1_SetMediaFavouriteRequest()
        request.mediaID = mediaID
        request.isFavourite = isFavourite
        _ = try await service().setMediaFavourite(request)
    }
}

private enum PiLinnError: Error, LocalizedError {
    case invalidServerURL
    case gatewayDisconnected(String?)

    var errorDescription: String? {
        switch self {
        case .invalidServerURL: "Invalid Louie Pi address"
        case let .gatewayDisconnected(message): message ?? "The Pi is reconnecting to Linn"
        }
    }
}

enum PiLinnMapping {
    static func nowPlaying(_ snapshot: Louie_Linn_V1_StateSnapshot) -> CiGateway.NowPlaying {
        var result = CiGateway.NowPlaying(room: snapshot.room, session: snapshot.nowPlayingSessionID)
        guard snapshot.hasNowPlaying else { return result }
        let state = snapshot.nowPlaying
        if state.hasTransportState {
            let transport: CiGateway.NowPlaying.TransportState = switch state.transportState {
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
                isMuted: volume.hasIsMuted ? volume.isMuted : nil
            )
        }
        return result
    }

    static func mediaPage(_ page: Louie_Linn_V1_MediaPage) -> CiGateway.MediaPage {
        .init(
            id: page.hasID ? page.id : nil,
            contentRevision: page.hasContentRevision ? Int(exactly: page.contentRevision) : nil,
            index: Int(page.index),
            count: Int(page.count),
            total: page.hasTotal ? Int(page.total) : nil,
            children: page.children.map(mediaItem)
        )
    }

    private static func mediaItem(_ item: Louie_Linn_V1_MediaItem) -> CiGateway.MediaItem {
        let kind: String = switch item.type {
        case .track: "md.track"
        case .album: "md.album"
        case .artist: "md.artist"
        case .playlist: "md.playlist"
        case .station: "md.station"
        case .container where item.provider == .qobuz: "md.qobuz.container"
        case .container: "md.container"
        default: item.isContainer ? "md.container" : "md.other"
        }
        return .init(
            id: item.id,
            kind: kind,
            name: item.hasName ? item.name : nil,
            title: item.hasTitle ? item.title : nil,
            album: item.hasAlbum ? item.album : nil,
            artists: item.artists,
            artworkURL: item.hasArtworkURL ? URL(string: item.artworkURL) : nil,
            duration: item.hasDurationSeconds ? Int(item.durationSeconds) : nil,
            childCount: item.hasChildCount ? Int(item.childCount) : nil,
            isFavourite: item.hasIsFavourite ? item.isFavourite : nil,
            disabledActions: item.canFavourite ? [] : ["favourite"]
        )
    }

    static func preview(_ item: CiGateway.MediaItem) -> Louie_Linn_V1_MediaItem {
        var preview = Louie_Linn_V1_MediaItem()
        preview.id = item.id
        preview.type = if item.kind.contains("track") { .track }
            else if item.kind.contains("album") { .album }
            else if item.kind.contains("artist") { .artist }
            else if item.kind.contains("playlist") { .playlist }
            else if item.kind.contains("station") { .station }
            else { .container }
        preview.provider = item.kind.contains("qobuz") ? .qobuz : .other
        preview.isContainer = item.isContainer
        preview.canFavourite = item.canFavourite
        if let title = item.title { preview.title = title }
        if let album = item.album { preview.album = album }
        preview.artists = item.artists
        if let artworkURL = item.artworkURL { preview.artworkURL = artworkURL.absoluteString }
        if let duration = item.duration { preview.durationSeconds = Int32(clamping: duration) }
        if let childCount = item.childCount { preview.childCount = Int32(clamping: childCount) }
        if let isFavourite = item.isFavourite { preview.isFavourite = isFavourite }
        return preview
    }
}
