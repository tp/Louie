import Foundation

public extension Linn.PlayState {
    init?(_ playback: LinnGatewayData.NowPlaying.Playback?) {
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
    init?(_ item: LinnGatewayData.NowPlaying.CurrentItem?) {
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

    init?(_ item: LinnGatewayData.NowPlaying.PlaylistItem) {
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
    init?(_ timeline: LinnGatewayData.NowPlaying.Timeline?) {
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
    init(_ service: LinnGatewayData.MediaService) {
        self.init(id: service.id, name: service.name, kind: service.kind)
    }
}

public extension Linn.LibraryPage {
    init(_ page: LinnGatewayData.MediaPage) {
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
    init(_ item: LinnGatewayData.MediaItem) {
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
