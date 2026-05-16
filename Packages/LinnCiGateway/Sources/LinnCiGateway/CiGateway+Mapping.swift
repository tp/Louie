import Foundation

extension CiGateway.MediaService {
    init?(_ service: V2ServicesStatusItem) {
        guard let id = service.id, let name = service.name else {
            return nil
        }

        self.init(id: id, name: name, kind: service._class)
    }
}

extension CiGateway.MediaPage {
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

extension CiGateway.MediaItem {
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

extension CiGateway.NowPlaying.TransportState {
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

extension CiGateway.NowPlaying.Playback {
    init?(response: V2TransportStatusResponse) {
        guard let transportState = response.data?.transportState.map(CiGateway.NowPlaying.TransportState.init) else {
            return nil
        }

        self.init(transportState: transportState)
    }
}

extension CiGateway.NowPlaying.Queue {
    init?(playlist: CiGateway.NowPlaying.Playlist) {
        let selectedIndex = playlist.items.first { $0.isCurrent }?.index
        guard selectedIndex != nil || playlist.total != nil else {
            return nil
        }

        self.init(index: selectedIndex, length: playlist.total)
    }
}

extension CiGateway.NowPlaying.RoomState {
    init?(response: V2VolumeStatusResponse) {
        guard let data = response.data, data.volume != nil || data.mute != nil else {
            return nil
        }

        self.init(volume: data.volume, isMuted: data.mute)
    }
}

extension CiGateway.NowPlaying.Playlist {
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

extension CiGateway.NowPlaying.PlaylistItem {
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

extension CiGateway.NowPlaying.CurrentItem {
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

extension CiGateway.NowPlaying.Track {
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

extension CiGateway.NowPlaying.Timeline {
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

extension CiGateway.NowPlaying {
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
