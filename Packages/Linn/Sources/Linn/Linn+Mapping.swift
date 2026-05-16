import Foundation
import LinnCiGateway

extension CiGateway: LinnGateway {
    public func nowPlayingUpdates(
        room: String?,
        updateInterval: Int
    ) async -> AsyncThrowingStream<NowPlaying, Error> {
        nowPlayingEvents(room: room, updateInterval: updateInterval)
    }

    public func browseMedia(mediaID: String, index: Int, count: Int, browseType: String) async throws -> MediaPage {
        try await browse(mediaID: mediaID, index: index, count: count, browseType: browseType)
    }

    public func searchMedia(serviceID: String, query: String, type: MediaSearchType, index: Int, count: Int) async throws -> MediaPage {
        try await search(serviceID: serviceID, query: query, type: type, index: index, count: count)
    }

    public func selectMedia(mediaID: String, room: String, queue: QueuePlacement) async throws {
        try await select(mediaID: mediaID, room: room, queue: queue)
    }

    public func setMediaFavourite(mediaID: String, isFavourite: Bool) async throws {
        try await setFavourite(mediaID: mediaID, isFavourite: isFavourite)
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

public extension Linn.LibraryService {
    init(_ service: CiGateway.MediaService) {
        self.init(id: service.id, name: service.name, kind: service.kind)
    }
}

public extension Linn.LibraryPage {
    init(_ page: CiGateway.MediaPage) {
        self.init(
            id: page.id,
            contentRevision: page.contentRevision,
            index: page.index,
            count: page.count,
            total: page.total,
            items: page.children.map(Linn.LibraryItem.init)
        )
    }
}

public extension Linn.LibraryItem {
    init(_ item: CiGateway.MediaItem) {
        let title = item.displayTitle?.isEmpty == false ? item.displayTitle! : item.id
        let subtitle = item.artists.isEmpty ? item.album : item.artists.joined(separator: ", ")
        self.init(
            id: item.id,
            kind: item.kind,
            title: title,
            subtitle: subtitle,
            album: item.album,
            artists: item.artists,
            artworkURL: item.artworkURL,
            duration: item.duration,
            containedKinds: item.containedKinds,
            childCount: item.childCount,
            isFavourite: item.isFavourite,
            canFavourite: item.canFavourite
        )
    }
}

public extension CiGateway.MediaSearchType {
    init(_ type: Linn.SearchType) {
        switch type {
        case .albums:
            self = .albums
        case .artists:
            self = .artists
        case .tracks:
            self = .tracks
        case .playlists:
            self = .playlists
        case .composers:
            self = .composers
        case .stations:
            self = .stations
        }
    }
}

public extension CiGateway.QueuePlacement {
    init(_ placement: Linn.QueuePlacement) {
        switch placement {
        case .now:
            self = .now
        case .next:
            self = .next
        case .last:
            self = .last
        case .replace:
            self = .replace
        }
    }
}
