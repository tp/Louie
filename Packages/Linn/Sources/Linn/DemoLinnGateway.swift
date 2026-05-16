#if DEBUG
    import Foundation
    import LinnCiGateway

    public actor DemoLinnGateway: LinnGateway {
        private struct DemoSong: Sendable {
            var id: String
            var title: String
            var artist: String
            var album: String
            var duration: Int
            var artworkURL: URL?

            init(
                id: String,
                title: String,
                artist: String,
                album: String,
                duration: Int,
                artworkURL: URL?
            ) {
                self.id = id
                self.title = title
                self.artist = artist
                self.album = album
                self.duration = duration
                self.artworkURL = artworkURL
            }

            init?(_ item: CiGateway.MediaItem) {
                let title = item.displayTitle ?? item.title ?? item.name
                guard let title, !title.isEmpty else {
                    return nil
                }

                self.init(
                    id: item.id,
                    title: title,
                    artist: item.artists.first ?? "Unknown Artist",
                    album: item.album ?? title,
                    duration: item.duration ?? 210,
                    artworkURL: item.artworkURL
                )
            }
        }

        private struct Subscription {
            var room: String
            var continuation: AsyncThrowingStream<CiGateway.NowPlaying, Error>.Continuation
        }

        private var songs: [DemoSong]
        private var currentIndex: Int
        private var transportState: CiGateway.NowPlaying.TransportState
        private var position: Int
        private var volume: Int
        private var isMuted: Bool
        private var playlistContentRevision: Int
        private var pendingSelectionIndex: Int?
        private var mediaSelectionGeneration = 0
        private let playlistSelectionObservationDelay: Duration
        private let mediaSelectionObservationDelay: Duration
        private var subscriptions: [UUID: Subscription] = [:]

        public init(
            playlistSelectionObservationDelay: Duration = .milliseconds(350),
            mediaSelectionObservationDelay: Duration = .seconds(1)
        ) {
            self.init(
                songs: Self.defaultSongs,
                currentIndex: 0,
                transportState: .pause,
                position: 61,
                volume: 32,
                isMuted: false,
                playlistSelectionObservationDelay: playlistSelectionObservationDelay,
                mediaSelectionObservationDelay: mediaSelectionObservationDelay
            )
        }

        public init(
            songs: [Linn.Song],
            currentIndex: Int = 0,
            playState: Linn.PlayState = .paused,
            position: Int = 0,
            volume: Int = 32,
            isMuted: Bool = false,
            playlistSelectionObservationDelay: Duration = .milliseconds(350),
            mediaSelectionObservationDelay: Duration = .seconds(1)
        ) {
            let demoSongs = songs.enumerated().map { _, song in
                DemoSong(
                    id: song.id,
                    title: song.title,
                    artist: song.artist ?? "Unknown Artist",
                    album: song.album ?? "Preview Queue",
                    duration: song.duration ?? 210,
                    artworkURL: song.artworkURL
                )
            }

            self.init(
                songs: demoSongs.isEmpty ? Self.defaultSongs : demoSongs,
                currentIndex: currentIndex,
                transportState: Self.transportState(for: playState),
                position: position,
                volume: volume,
                isMuted: isMuted,
                playlistSelectionObservationDelay: playlistSelectionObservationDelay,
                mediaSelectionObservationDelay: mediaSelectionObservationDelay
            )
        }

        private init(
            songs: [DemoSong],
            currentIndex: Int,
            transportState: CiGateway.NowPlaying.TransportState,
            position: Int,
            volume: Int,
            isMuted: Bool,
            playlistSelectionObservationDelay: Duration,
            mediaSelectionObservationDelay: Duration
        ) {
            self.songs = songs
            self.currentIndex = min(max(0, currentIndex), songs.count - 1)
            self.transportState = transportState
            self.position = position
            self.volume = volume
            self.isMuted = isMuted
            playlistContentRevision = 1
            self.playlistSelectionObservationDelay = playlistSelectionObservationDelay
            self.mediaSelectionObservationDelay = mediaSelectionObservationDelay
        }

        public func nowPlayingUpdates(
            room: String?,
            updateInterval _: Int
        ) async -> AsyncThrowingStream<CiGateway.NowPlaying, Error> {
            AsyncThrowingStream { continuation in
                let id = UUID()
                Task {
                    addSubscription(
                        id: id,
                        room: room ?? "Linn",
                        continuation: continuation
                    )
                }

                continuation.onTermination = { _ in
                    Task {
                        await self.removeSubscription(id: id)
                    }
                }
            }
        }

        public func play(room _: String) async throws {
            transportState = .buffering
            yieldSnapshot()
            try await Task.sleep(for: .milliseconds(350))
            transportState = .play
            yieldSnapshot()
        }

        public func pause(room _: String) async throws {
            try await Task.sleep(for: .milliseconds(150))
            transportState = .pause
            yieldSnapshot()
        }

        public func previous(room _: String) async throws {
            guard currentIndex > 0 else {
                return
            }

            try await selectPlaylistItem(at: currentIndex - 1)
        }

        public func next(room _: String) async throws {
            guard currentIndex + 1 < songs.count else {
                return
            }

            try await selectPlaylistItem(at: currentIndex + 1)
        }

        public func selectPlaylistItem(at index: Int, room _: String) async throws {
            try await selectPlaylistItem(at: index)
        }

        private func selectPlaylistItem(at index: Int) async throws {
            guard songs.indices.contains(index) else {
                return
            }

            pendingSelectionIndex = index
            transportState = .buffering
            yieldSnapshot()
            try await Task.sleep(for: playlistSelectionObservationDelay)
            currentIndex = index
            position = 0
            pendingSelectionIndex = nil
            transportState = .play
            yieldSnapshot()
        }

        public func setVolume(_ volume: Int, room _: String, group _: Bool) async throws {
            self.volume = max(0, min(100, volume))
            yieldSnapshot()
        }

        public func setMuted(_ isMuted: Bool, room _: String, group _: Bool) async throws {
            self.isMuted = isMuted
            yieldSnapshot()
        }

        public func mediaServices(room _: String) async throws -> [CiGateway.MediaService] {
            [
                CiGateway.MediaService(id: "service-qobuz", name: "Qobuz", kind: "md.service"),
            ]
        }

        public func browseMedia(
            mediaID: String,
            index: Int,
            count: Int,
            browseType _: String
        ) async throws -> CiGateway.MediaPage {
            let children = Self.mediaChildren(for: mediaID)
            let slice = Array(children.dropFirst(index).prefix(count))
            return CiGateway.MediaPage(
                id: mediaID,
                contentRevision: 1,
                index: index,
                count: slice.count,
                total: children.count,
                children: slice
            )
        }

        public func searchMedia(
            serviceID _: String,
            query: String,
            type _: CiGateway.MediaSearchType,
            index: Int,
            count: Int
        ) async throws -> CiGateway.MediaPage {
            let matches = Self.demoLibraryAlbums.filter {
                ($0.displayTitle ?? "").localizedCaseInsensitiveContains(query)
                    || $0.artists.joined(separator: " ").localizedCaseInsensitiveContains(query)
            }
            let slice = Array(matches.dropFirst(index).prefix(count))
            return CiGateway.MediaPage(
                id: "qobuz-search",
                contentRevision: 1,
                index: index,
                count: slice.count,
                total: matches.count,
                children: slice
            )
        }

        public func selectMedia(mediaID: String, room _: String, queue: CiGateway.QueuePlacement) async throws {
            let selectedSongs = Self.queueSongs(for: mediaID)
            guard !selectedSongs.isEmpty else {
                return
            }

            let mutation = queueMutation(placing: selectedSongs, queue: queue)
            mediaSelectionGeneration += 1
            let generation = mediaSelectionGeneration
            yieldCountOnlySnapshot(queueLength: mutation.songs.count)

            try await Task.sleep(for: mediaSelectionObservationDelay)
            guard generation == mediaSelectionGeneration else {
                return
            }

            songs = mutation.songs
            currentIndex = mutation.currentIndex
            pendingSelectionIndex = nil
            position = 0
            transportState = .play
            playlistContentRevision += 1
            yieldSnapshot()
        }

        public func setMediaFavourite(mediaID _: String, isFavourite _: Bool) async throws {}

        private func addSubscription(
            id: UUID,
            room: String,
            continuation: AsyncThrowingStream<CiGateway.NowPlaying, Error>.Continuation
        ) {
            subscriptions[id] = Subscription(room: room, continuation: continuation)
            continuation.yield(snapshot(room: room))
        }

        private func removeSubscription(id: UUID) {
            subscriptions[id] = nil
        }

        private func yieldSnapshot() {
            for subscription in subscriptions.values {
                subscription.continuation.yield(snapshot(room: subscription.room))
            }
        }

        private func yieldCountOnlySnapshot(queueLength: Int) {
            for subscription in subscriptions.values {
                subscription.continuation.yield(countOnlySnapshot(room: subscription.room, queueLength: queueLength))
            }
        }

        private func snapshot(room: String) -> CiGateway.NowPlaying {
            let song = songs[currentIndex]
            var nowPlaying = CiGateway.NowPlaying(room: room, session: "preview-session")
            nowPlaying.playback = CiGateway.NowPlaying.Playback(transportState: transportState)
            nowPlaying.queue = CiGateway.NowPlaying.Queue(index: currentIndex, length: songs.count)
            nowPlaying.currentItem = currentItem(song)
            nowPlaying.playlist = playlist
            nowPlaying.timeline = CiGateway.NowPlaying.Timeline(
                position: position,
                duration: song.duration,
                seekableRange: CiGateway.NowPlaying.SeekableRange(lowerBound: 0, upperBound: song.duration)
            )
            nowPlaying.roomState = CiGateway.NowPlaying.RoomState(volume: volume, isMuted: isMuted)
            return nowPlaying
        }

        private func countOnlySnapshot(room: String, queueLength: Int) -> CiGateway.NowPlaying {
            let song = songs[currentIndex]
            var nowPlaying = CiGateway.NowPlaying(room: room, session: "preview-session")
            nowPlaying.playback = CiGateway.NowPlaying.Playback(transportState: transportState)
            nowPlaying.queue = CiGateway.NowPlaying.Queue(index: currentIndex, length: queueLength)
            nowPlaying.currentItem = currentItem(song)
            nowPlaying.playlist = CiGateway.NowPlaying.Playlist(items: [], total: queueLength)
            nowPlaying.timeline = CiGateway.NowPlaying.Timeline(
                position: position,
                duration: song.duration,
                seekableRange: CiGateway.NowPlaying.SeekableRange(lowerBound: 0, upperBound: song.duration)
            )
            nowPlaying.roomState = CiGateway.NowPlaying.RoomState(volume: volume, isMuted: isMuted)
            return nowPlaying
        }

        private func currentItem(_ song: DemoSong) -> CiGateway.NowPlaying.CurrentItem {
            CiGateway.NowPlaying.CurrentItem(
                id: song.id,
                kind: "md.track.preview",
                displayName: song.title,
                artworkURL: song.artworkURL,
                track: CiGateway.NowPlaying.Track(
                    title: song.title,
                    album: song.album,
                    artist: song.artist
                )
            )
        }

        private var playlist: CiGateway.NowPlaying.Playlist {
            let selectedIndex = pendingSelectionIndex ?? currentIndex
            return CiGateway.NowPlaying.Playlist(
                items: songs.enumerated().map { index, song in
                    CiGateway.NowPlaying.PlaylistItem(
                        index: index,
                        displayName: song.title,
                        album: song.album,
                        artist: song.artist,
                        duration: song.duration,
                        artworkURL: song.artworkURL,
                        isCurrent: index == selectedIndex
                    )
                },
                total: songs.count,
                contentRevision: playlistContentRevision
            )
        }

        private func queueMutation(
            placing selectedSongs: [DemoSong],
            queue: CiGateway.QueuePlacement
        ) -> (songs: [DemoSong], currentIndex: Int) {
            switch queue {
            case .replace:
                return (selectedSongs, 0)
            case .last:
                return (songs + selectedSongs, currentIndex)
            case .next:
                var queuedSongs = songs
                let insertionIndex = min(currentIndex + 1, queuedSongs.count)
                queuedSongs.insert(contentsOf: selectedSongs, at: insertionIndex)
                return (queuedSongs, currentIndex)
            case .now:
                var queuedSongs = songs
                let insertionIndex = min(currentIndex + 1, queuedSongs.count)
                queuedSongs.insert(contentsOf: selectedSongs, at: insertionIndex)
                return (queuedSongs, insertionIndex)
            }
        }

        private static func transportState(for playState: Linn.PlayState) -> CiGateway.NowPlaying.TransportState {
            switch playState {
            case .stopped:
                .stop
            case .playing:
                .play
            case .paused:
                .pause
            case .loading, .buffering:
                .buffering
            }
        }

        private static func queueSongs(for mediaID: String) -> [DemoSong] {
            if let directTrack = queueableMediaItems.first(where: { $0.id == mediaID }) {
                return DemoSong(directTrack).map { [$0] } ?? []
            }

            return mediaChildren(for: mediaID)
                .flatMap(queueableTracks(in:))
                .compactMap(DemoSong.init)
        }

        private static func queueableTracks(in item: CiGateway.MediaItem) -> [CiGateway.MediaItem] {
            if isTrack(item) {
                return [item]
            }

            return mediaChildren(for: item.id).filter(isTrack)
        }

        private static var queueableMediaItems: [CiGateway.MediaItem] {
            hitMeHardAndSoftTracks
                + demoPlaylistTracks
                + demoLibraryAlbums.flatMap { demoTracks(for: $0.id) }
        }

        private static func isTrack(_ item: CiGateway.MediaItem) -> Bool {
            item.kind.localizedCaseInsensitiveContains("track")
        }

        private static func mediaChildren(for mediaID: String) -> [CiGateway.MediaItem] {
            switch mediaID {
            case "service-qobuz":
                [
                    CiGateway.MediaItem(id: "qobuz-discover", kind: "md.qobuz.discover", name: "Discover"),
                    CiGateway.MediaItem(id: "qobuz-genres", kind: "md.qobuz.genres", name: "Genres"),
                    CiGateway.MediaItem(id: "qobuz-myqobuz", kind: "md.qobuz.myqobuz", name: "My Qobuz"),
                ]
            case "qobuz-myqobuz":
                [
                    CiGateway.MediaItem(id: "qobuz-favourites", kind: "md.container", name: "Favourites"),
                    CiGateway.MediaItem(id: "qobuz-my-playlists", kind: "md.container.qobuz.playlist", name: "My Playlists"),
                    CiGateway.MediaItem(id: "qobuz-purchased", kind: "md.container", name: "Purchased"),
                ]
            case "qobuz-favourites":
                [
                    CiGateway.MediaItem(id: "qobuz-favourite-albums", kind: "md.container.qobuz.album", name: "Albums"),
                    CiGateway.MediaItem(id: "qobuz-favourite-artists", kind: "md.container", name: "Artist"),
                    CiGateway.MediaItem(id: "qobuz-favourite-playlists", kind: "md.container", name: "Playlists"),
                    CiGateway.MediaItem(id: "qobuz-favourite-tracks", kind: "md.container", name: "Tracks"),
                ]
            case "qobuz-favourite-albums":
                demoLibraryAlbums
            case "qobuz-favourite-artists":
                demoLibraryArtists
            case "qobuz-favourite-playlists", "qobuz-my-playlists":
                demoLibraryPlaylists
            case "qobuz-purchased":
                Array(demoLibraryAlbums.reversed())
            case "qobuz-discover":
                [
                    CiGateway.MediaItem(id: "qobuz-new-releases", kind: "md.container.qobuz.album", name: "New Releases"),
                    CiGateway.MediaItem(id: "qobuz-discover-playlists", kind: "md.container.qobuz.playlist", name: "Qobuz Playlists"),
                    CiGateway.MediaItem(id: "qobuz-most-streamed", kind: "md.container.qobuz.album", name: "Most Streamed"),
                ]
            case "qobuz-genres":
                [
                    CiGateway.MediaItem(id: "qobuz-genre-jazz", kind: "md.container.qobuz.genre", name: "Jazz"),
                    CiGateway.MediaItem(id: "qobuz-genre-electronic", kind: "md.container.qobuz.genre", name: "Electronic"),
                    CiGateway.MediaItem(id: "qobuz-genre-classical", kind: "md.container.qobuz.genre", name: "Classical"),
                ]
            case "qobuz-album-hit-me-hard-and-soft":
                hitMeHardAndSoftTracks
            case "qobuz-album-happy-christmas",
                 "qobuz-album-shostakovich-quartets",
                 "qobuz-album-birth-of-the-blue",
                 "qobuz-album-chopin-nocturnes",
                 "qobuz-album-abbey-road",
                 "qobuz-album-opus",
                 "qobuz-album-the-old-country":
                demoTracks(for: mediaID)
            case "qobuz-playlist-willkommen",
                 "qobuz-playlist-true-sound-covers",
                 "qobuz-playlist-grammy-winners-2021":
                demoPlaylistTracks
            default:
                []
            }
        }

        private static let defaultSongs: [DemoSong] = [
            DemoSong(
                id: "preview-green-light",
                title: "Green Light",
                artist: "Lorde",
                album: "Melodrama",
                duration: 233,
                artworkURL: URL(string: "https://static.qobuz.com/images/covers/64/77/0060255747764_230.jpg")
            ),
            DemoSong(
                id: "preview-sober",
                title: "Sober",
                artist: "Lorde",
                album: "Melodrama",
                duration: 196,
                artworkURL: URL(string: "https://static.qobuz.com/images/covers/64/77/0060255747764_230.jpg")
            ),
            DemoSong(
                id: "preview-homemade-dynamite",
                title: "Homemade Dynamite",
                artist: "Lorde",
                album: "Melodrama",
                duration: 189,
                artworkURL: URL(string: "https://static.qobuz.com/images/covers/64/77/0060255747764_230.jpg")
            ),
            DemoSong(
                id: "preview-the-louvre",
                title: "The Louvre",
                artist: "Lorde",
                album: "Melodrama",
                duration: 272,
                artworkURL: URL(string: "https://static.qobuz.com/images/covers/64/77/0060255747764_230.jpg")
            ),
            DemoSong(
                id: "preview-liability",
                title: "Liability",
                artist: "Lorde",
                album: "Melodrama",
                duration: 171,
                artworkURL: URL(string: "https://static.qobuz.com/images/covers/64/77/0060255747764_230.jpg")
            ),
            DemoSong(
                id: "preview-hard-feelings-loveless",
                title: "Hard Feelings/Loveless",
                artist: "Lorde",
                album: "Melodrama",
                duration: 367,
                artworkURL: URL(string: "https://static.qobuz.com/images/covers/64/77/0060255747764_230.jpg")
            ),
            DemoSong(
                id: "preview-sober-ii-melodrama",
                title: "Sober II (Melodrama)",
                artist: "Lorde",
                album: "Melodrama",
                duration: 178,
                artworkURL: URL(string: "https://static.qobuz.com/images/covers/64/77/0060255747764_230.jpg")
            ),
            DemoSong(
                id: "preview-writer-in-the-dark",
                title: "Writer in the Dark",
                artist: "Lorde",
                album: "Melodrama",
                duration: 216,
                artworkURL: URL(string: "https://static.qobuz.com/images/covers/64/77/0060255747764_230.jpg")
            ),
            DemoSong(
                id: "preview-supercut",
                title: "Supercut",
                artist: "Lorde",
                album: "Melodrama",
                duration: 278,
                artworkURL: URL(string: "https://static.qobuz.com/images/covers/64/77/0060255747764_230.jpg")
            ),
            DemoSong(
                id: "preview-liability-reprise",
                title: "Liability (Reprise)",
                artist: "Lorde",
                album: "Melodrama",
                duration: 136,
                artworkURL: URL(string: "https://static.qobuz.com/images/covers/64/77/0060255747764_230.jpg")
            ),
            DemoSong(
                id: "preview-skinny",
                title: "SKINNY",
                artist: "Billie Eilish",
                album: "HIT ME HARD AND SOFT",
                duration: 219,
                artworkURL: URL(string: "https://static.qobuz.com/images/covers/kc/95/gvcirtodd95kc_230.jpg")
            ),
            DemoSong(
                id: "preview-lunch",
                title: "LUNCH",
                artist: "Billie Eilish",
                album: "HIT ME HARD AND SOFT",
                duration: 180,
                artworkURL: URL(string: "https://static.qobuz.com/images/covers/kc/95/gvcirtodd95kc_230.jpg")
            ),
            DemoSong(
                id: "preview-chihiro",
                title: "CHIHIRO",
                artist: "Billie Eilish",
                album: "HIT ME HARD AND SOFT",
                duration: 303,
                artworkURL: URL(string: "https://static.qobuz.com/images/covers/kc/95/gvcirtodd95kc_230.jpg")
            ),
            DemoSong(
                id: "preview-birds-of-a-feather",
                title: "BIRDS OF A FEATHER",
                artist: "Billie Eilish",
                album: "HIT ME HARD AND SOFT",
                duration: 210,
                artworkURL: URL(string: "https://static.qobuz.com/images/covers/kc/95/gvcirtodd95kc_230.jpg")
            ),
            DemoSong(
                id: "preview-wildflower",
                title: "WILDFLOWER",
                artist: "Billie Eilish",
                album: "HIT ME HARD AND SOFT",
                duration: 261,
                artworkURL: URL(string: "https://static.qobuz.com/images/covers/kc/95/gvcirtodd95kc_230.jpg")
            ),
        ]

        private static let demoLibraryAlbums: [CiGateway.MediaItem] = [
            CiGateway.MediaItem(
                id: "qobuz-album-happy-christmas",
                kind: "md.album.qobuz",
                name: "Happy Christmas",
                album: "Happy Christmas",
                artists: ["Frank Sinatra"],
                artworkURL: URL(string: "https://static.qobuz.com/images/covers/25/04/3610152050425_230.jpg"),
                containedKinds: ["md.track.qobuz"],
                childCount: 50,
                isFavourite: true
            ),
            CiGateway.MediaItem(
                id: "qobuz-album-shostakovich-quartets",
                kind: "md.album.qobuz",
                name: "Shostakovich: Complete String Quartets, Vol. 2, Nos. 6-12",
                album: "Shostakovich: Complete String Quartets, Vol. 2, Nos. 6-12",
                artists: ["Cuarteto Casals"],
                artworkURL: URL(string: "https://static.qobuz.com/images/covers/ob/zn/wozp8tpq0znob_230.jpg"),
                containedKinds: ["md.track.qobuz"],
                childCount: 30,
                isFavourite: true
            ),
            CiGateway.MediaItem(
                id: "qobuz-album-hit-me-hard-and-soft",
                kind: "md.album.qobuz",
                name: "HIT ME HARD AND SOFT",
                album: "HIT ME HARD AND SOFT",
                artists: ["Billie Eilish"],
                artworkURL: URL(string: "https://static.qobuz.com/images/covers/kc/95/gvcirtodd95kc_230.jpg"),
                containedKinds: ["md.track.qobuz"],
                childCount: 10,
                isFavourite: true
            ),
            CiGateway.MediaItem(
                id: "qobuz-album-birth-of-the-blue",
                kind: "md.album.qobuz",
                name: "Birth of the Blue",
                album: "Birth of the Blue",
                artists: ["Miles Davis"],
                artworkURL: URL(string: "https://static.qobuz.com/images/covers/fa/90/ld7wpvuga90fa_230.jpg"),
                containedKinds: ["md.track.qobuz"],
                childCount: 4,
                isFavourite: true
            ),
            CiGateway.MediaItem(
                id: "qobuz-album-chopin-nocturnes",
                kind: "md.album.qobuz",
                name: "Chopin: The Complete Nocturnes",
                album: "Chopin: The Complete Nocturnes",
                artists: ["Tom Hicks"],
                artworkURL: URL(string: "https://static.qobuz.com/images/covers/yc/ag/nuuxf36hoagyc_230.jpg"),
                containedKinds: ["md.track.qobuz"],
                childCount: 21,
                isFavourite: true
            ),
            CiGateway.MediaItem(
                id: "qobuz-album-abbey-road",
                kind: "md.album.qobuz",
                name: "Abbey Road",
                album: "Abbey Road",
                artists: ["The Beatles"],
                artworkURL: URL(string: "https://static.qobuz.com/images/covers/6b/az/trrcz9pvaaz6b_230.jpg"),
                containedKinds: ["md.track.qobuz"],
                childCount: 40,
                isFavourite: true
            ),
            CiGateway.MediaItem(
                id: "qobuz-album-opus",
                kind: "md.album.qobuz",
                name: "Opus",
                album: "Opus",
                artists: ["Ryuichi Sakamoto"],
                artworkURL: URL(string: "https://static.qobuz.com/images/covers/vc/kx/z9mpg2fc7kxvc_230.jpg"),
                containedKinds: ["md.track.qobuz"],
                childCount: 20,
                isFavourite: true
            ),
            CiGateway.MediaItem(
                id: "qobuz-album-the-old-country",
                kind: "md.album.qobuz",
                name: "The Old Country",
                album: "The Old Country",
                artists: ["Keith Jarrett"],
                artworkURL: URL(string: "https://static.qobuz.com/images/covers/4a/4y/rfwy0akjr4y4a_230.jpg"),
                containedKinds: ["md.track.qobuz"],
                childCount: 8,
                isFavourite: true
            ),
        ]

        private static let demoLibraryArtists: [CiGateway.MediaItem] = [
            CiGateway.MediaItem(
                id: "qobuz-artist-qrion",
                kind: "md.artist.qobuz",
                name: "Qrion",
                artists: ["Qrion"],
                artworkURL: URL(string: "https://static.qobuz.com/images/artists/covers/small/afd716d782ba6b056d5a311b0bed0573.jpg"),
                isFavourite: true
            ),
        ]

        private static let demoLibraryPlaylists: [CiGateway.MediaItem] = [
            CiGateway.MediaItem(
                id: "qobuz-playlist-willkommen",
                kind: "md.playlist.qobuz",
                name: "Willkommen bei Qobuz",
                artworkURL: URL(string: "https://static.qobuz.com/images/playlists/1285072_2bc9b2d5023757d1a8b10db915efd367_rectangle.jpg"),
                containedKinds: ["md.track.qobuz"],
                childCount: 125
            ),
            CiGateway.MediaItem(
                id: "qobuz-playlist-true-sound-covers",
                kind: "md.playlist.qobuz",
                name: "True Sound Covers",
                artworkURL: URL(string: "https://static.qobuz.com/images/covers/13/05/0093624980513_300.jpg"),
                containedKinds: ["md.track.qobuz"],
                childCount: 50
            ),
            CiGateway.MediaItem(
                id: "qobuz-playlist-grammy-winners-2021",
                kind: "md.playlist.qobuz",
                name: "2021 Grammy Winners",
                artworkURL: URL(string: "https://static.qobuz.com/images/playlists/5863588_f5111fc6839f22be2f91948ca16dfc71_rectangle.jpg"),
                containedKinds: ["md.track.qobuz"],
                childCount: 58,
                isFavourite: true
            ),
        ]

        private static let hitMeHardAndSoftTracks: [CiGateway.MediaItem] = [
            demoTrack(id: "qobuz-track-skinny", title: "SKINNY", album: "HIT ME HARD AND SOFT", artist: "Billie Eilish", duration: 219),
            demoTrack(id: "qobuz-track-lunch", title: "LUNCH", album: "HIT ME HARD AND SOFT", artist: "Billie Eilish", duration: 180),
            demoTrack(id: "qobuz-track-chihiro", title: "CHIHIRO", album: "HIT ME HARD AND SOFT", artist: "Billie Eilish", duration: 303),
            demoTrack(id: "qobuz-track-birds-of-a-feather", title: "BIRDS OF A FEATHER", album: "HIT ME HARD AND SOFT", artist: "Billie Eilish", duration: 210),
            demoTrack(id: "qobuz-track-wildflower", title: "WILDFLOWER", album: "HIT ME HARD AND SOFT", artist: "Billie Eilish", duration: 261),
            demoTrack(id: "qobuz-track-the-greatest", title: "THE GREATEST", album: "HIT ME HARD AND SOFT", artist: "Billie Eilish", duration: 293),
            demoTrack(id: "qobuz-track-lamour-de-ma-vie", title: "L'AMOUR DE MA VIE", album: "HIT ME HARD AND SOFT", artist: "Billie Eilish", duration: 333),
            demoTrack(id: "qobuz-track-the-diner", title: "THE DINER", album: "HIT ME HARD AND SOFT", artist: "Billie Eilish", duration: 186),
            demoTrack(id: "qobuz-track-bittersuite", title: "BITTERSUITE", album: "HIT ME HARD AND SOFT", artist: "Billie Eilish", duration: 298),
            demoTrack(id: "qobuz-track-blue", title: "BLUE", album: "HIT ME HARD AND SOFT", artist: "Billie Eilish", duration: 343),
        ]

        private static let demoPlaylistTracks: [CiGateway.MediaItem] = [
            demoTrack(id: "qobuz-playlist-track-chainsmoking", title: "Chainsmoking", album: "Preview Queue", artist: "Jacob Banks", duration: 197),
            demoTrack(id: "qobuz-playlist-track-green-light", title: "Green Light", album: "Melodrama", artist: "Lorde", duration: 234),
            demoTrack(id: "qobuz-playlist-track-supercut", title: "Supercut", album: "Melodrama", artist: "Lorde", duration: 278),
            demoTrack(id: "qobuz-playlist-track-bad-guy", title: "bad guy", album: "WHEN WE ALL FALL ASLEEP, WHERE DO WE GO?", artist: "Billie Eilish", duration: 194),
            demoTrack(id: "qobuz-playlist-track-time", title: "Time", album: "The Old Country", artist: "Keith Jarrett", duration: 298),
        ]

        private static func demoTracks(for albumID: String) -> [CiGateway.MediaItem] {
            guard let album = demoLibraryAlbums.first(where: { $0.id == albumID }) else {
                return []
            }

            let title = album.displayTitle ?? albumID
            let artist = album.artists.first ?? "Qobuz"
            return (1 ... min(album.childCount ?? 6, 8)).map { index in
                demoTrack(
                    id: "\(albumID)-track-\(index)",
                    title: "Track \(index)",
                    album: title,
                    artist: artist,
                    duration: 180 + index * 11,
                    artworkURL: album.artworkURL
                )
            }
        }

        private static func demoTrack(
            id: String,
            title: String,
            album: String,
            artist: String,
            duration: Int,
            artworkURL: URL? = URL(string: "https://static.qobuz.com/images/covers/kc/95/gvcirtodd95kc_230.jpg")
        ) -> CiGateway.MediaItem {
            CiGateway.MediaItem(
                id: id,
                kind: "md.track.qobuz",
                title: title,
                album: album,
                artists: [artist],
                artworkURL: artworkURL,
                duration: duration
            )
        }
    }
#endif
