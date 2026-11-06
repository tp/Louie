#if DEBUG
    import Foundation

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

            init?(_ item: Linn.LibraryItem) {
                let title = item.title
                guard !title.isEmpty else {
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
            var continuation: AsyncThrowingStream<Linn.Snapshot, Error>.Continuation
        }

        private var songs: [DemoSong]
        private var currentIndex: Int
        private var transportState: Linn.PlayState
        private var position: Int
        private var volume: Int
        private var isMuted: Bool
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
                transportState: .paused,
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
                transportState: playState,
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
            transportState: Linn.PlayState,
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
            self.playlistSelectionObservationDelay = playlistSelectionObservationDelay
            self.mediaSelectionObservationDelay = mediaSelectionObservationDelay
        }

        public func nowPlayingUpdates(
            room: String?,
            updateInterval _: Int
        ) async -> AsyncThrowingStream<Linn.Snapshot, Error> {
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

        public func wake(room _: String) async throws {}

        public func play(room _: String) async throws {
            transportState = .buffering
            yieldSnapshot()
            try await Task.sleep(for: .milliseconds(350))
            transportState = .playing
            yieldSnapshot()
        }

        public func pause(room _: String) async throws {
            try await Task.sleep(for: .milliseconds(150))
            transportState = .paused
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
            transportState = .playing
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

        public func mediaServices(room _: String) async throws -> [Linn.LibraryService] {
            [
                Linn.LibraryService(id: "service-qobuz", name: "Qobuz", kind: "md.service"),
            ]
        }

        public func browseMedia(
            mediaID: String,
            index: Int,
            count: Int,
            browseType _: String
        ) async throws -> Linn.LibraryPage {
            let children = Self.mediaChildren(for: mediaID)
            let slice = Array(children.dropFirst(index).prefix(count))
            return Linn.LibraryPage(
                id: mediaID,
                contentRevision: 1,
                index: index,
                count: slice.count,
                total: children.count,
                items: slice
            )
        }

        public func searchMedia(
            serviceID _: String,
            query: String,
            type _: Linn.SearchType,
            index: Int,
            count: Int
        ) async throws -> Linn.LibraryPage {
            let matches = Self.demoLibraryAlbums.filter {
                $0.title.localizedCaseInsensitiveContains(query)
                    || $0.artists.joined(separator: " ").localizedCaseInsensitiveContains(query)
            }
            let slice = Array(matches.dropFirst(index).prefix(count))
            return Linn.LibraryPage(
                id: "qobuz-search",
                contentRevision: 1,
                index: index,
                count: slice.count,
                total: matches.count,
                items: slice
            )
        }

        public func selectMedia(mediaID: String, room _: String, queue: Linn.QueuePlacement) async throws {
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
            transportState = .playing
            yieldSnapshot()
        }

        public func setMediaFavourite(mediaID _: String, isFavourite _: Bool) async throws {}

        private func addSubscription(
            id: UUID,
            room: String,
            continuation: AsyncThrowingStream<Linn.Snapshot, Error>.Continuation
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

        private func snapshot(room _: String) -> Linn.Snapshot {
            let song = songs[currentIndex]
            var snapshot = Linn.Snapshot()
            snapshot.playState = transportState
            snapshot.currentSong = appSong(song, index: currentIndex)
            snapshot.playlist = .init(
                songs: songs.enumerated().map { appSong($0.element, index: $0.offset) },
                currentIndex: currentIndex,
                total: songs.count
            )
            snapshot.pending.queueIndex = pendingSelectionIndex != nil
            snapshot.timeline = .init(
                position: position,
                duration: song.duration,
                progress: song.duration > 0 ? Double(position) / Double(song.duration) : nil
            )
            snapshot.volume = volume
            snapshot.isMuted = isMuted
            return snapshot
        }

        private func countOnlySnapshot(room: String, queueLength: Int) -> Linn.Snapshot {
            var snapshot = snapshot(room: room)
            snapshot.playlist.total = queueLength
            snapshot.pending.queueTotal = true
            return snapshot
        }

        private func appSong(_ song: DemoSong, index: Int) -> Linn.Song {
            .init(
                id: song.id,
                title: song.title,
                artist: song.artist,
                album: song.album,
                duration: song.duration,
                artworkURL: song.artworkURL,
                queueIndex: index
            )
        }

        private func queueMutation(
            placing selectedSongs: [DemoSong],
            queue: Linn.QueuePlacement
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

        private static func queueSongs(for mediaID: String) -> [DemoSong] {
            if let directTrack = queueableMediaItems.first(where: { $0.id == mediaID }) {
                return DemoSong(directTrack).map { [$0] } ?? []
            }

            return mediaChildren(for: mediaID)
                .flatMap(queueableTracks(in:))
                .compactMap(DemoSong.init)
        }

        private static func queueableTracks(in item: Linn.LibraryItem) -> [Linn.LibraryItem] {
            if isTrack(item) {
                return [item]
            }

            return mediaChildren(for: item.id).filter(isTrack)
        }

        private static var queueableMediaItems: [Linn.LibraryItem] {
            hitMeHardAndSoftTracks
                + demoPlaylistTracks
                + demoLibraryAlbums.flatMap { demoTracks(for: $0.id) }
        }

        private static func isTrack(_ item: Linn.LibraryItem) -> Bool {
            item.kind.localizedCaseInsensitiveContains("track")
        }

        private static func mediaChildren(for mediaID: String) -> [Linn.LibraryItem] {
            switch mediaID {
            case "service-qobuz":
                [
                    Linn.LibraryItem(id: "qobuz-discover", kind: "md.qobuz.discover", title: "Discover"),
                    Linn.LibraryItem(id: "qobuz-genres", kind: "md.qobuz.genres", title: "Genres"),
                    Linn.LibraryItem(id: "qobuz-myqobuz", kind: "md.qobuz.myqobuz", title: "My Qobuz"),
                ]
            case "qobuz-myqobuz":
                [
                    Linn.LibraryItem(id: "qobuz-favourites", kind: "md.container", title: "Favourites"),
                    Linn.LibraryItem(id: "qobuz-my-playlists", kind: "md.container.qobuz.playlist", title: "My Playlists"),
                    Linn.LibraryItem(id: "qobuz-purchased", kind: "md.container", title: "Purchased"),
                ]
            case "qobuz-favourites":
                [
                    Linn.LibraryItem(id: "qobuz-favourite-albums", kind: "md.container.qobuz.album", title: "Albums"),
                    Linn.LibraryItem(id: "qobuz-favourite-artists", kind: "md.container", title: "Artist"),
                    Linn.LibraryItem(id: "qobuz-favourite-playlists", kind: "md.container", title: "Playlists"),
                    Linn.LibraryItem(id: "qobuz-favourite-tracks", kind: "md.container", title: "Tracks"),
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
                    Linn.LibraryItem(id: "qobuz-new-releases", kind: "md.container.qobuz.album", title: "New Releases"),
                    Linn.LibraryItem(id: "qobuz-discover-playlists", kind: "md.container.qobuz.playlist", title: "Qobuz Playlists"),
                    Linn.LibraryItem(id: "qobuz-most-streamed", kind: "md.container.qobuz.album", title: "Most Streamed"),
                ]
            case "qobuz-genres":
                [
                    Linn.LibraryItem(id: "qobuz-genre-jazz", kind: "md.container.qobuz.genre", title: "Jazz"),
                    Linn.LibraryItem(id: "qobuz-genre-electronic", kind: "md.container.qobuz.genre", title: "Electronic"),
                    Linn.LibraryItem(id: "qobuz-genre-classical", kind: "md.container.qobuz.genre", title: "Classical"),
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

        private static let demoLibraryAlbums: [Linn.LibraryItem] = [
            Linn.LibraryItem(
                id: "qobuz-album-happy-christmas",
                kind: "md.album.qobuz",
                title: "Happy Christmas",
                subtitle: "Frank Sinatra",
                album: "Happy Christmas",
                artists: ["Frank Sinatra"],
                artworkURL: URL(string: "https://static.qobuz.com/images/covers/25/04/3610152050425_230.jpg"),
                containedKinds: ["md.track.qobuz"],
                childCount: 50,
                isFavourite: true,
                canFavourite: true
            ),
            Linn.LibraryItem(
                id: "qobuz-album-shostakovich-quartets",
                kind: "md.album.qobuz",
                title: "Shostakovich: Complete String Quartets, Vol. 2, Nos. 6-12",
                subtitle: "Cuarteto Casals",
                album: "Shostakovich: Complete String Quartets, Vol. 2, Nos. 6-12",
                artists: ["Cuarteto Casals"],
                artworkURL: URL(string: "https://static.qobuz.com/images/covers/ob/zn/wozp8tpq0znob_230.jpg"),
                containedKinds: ["md.track.qobuz"],
                childCount: 30,
                isFavourite: true,
                canFavourite: true
            ),
            Linn.LibraryItem(
                id: "qobuz-album-hit-me-hard-and-soft",
                kind: "md.album.qobuz",
                title: "HIT ME HARD AND SOFT",
                subtitle: "Billie Eilish",
                album: "HIT ME HARD AND SOFT",
                artists: ["Billie Eilish"],
                artworkURL: URL(string: "https://static.qobuz.com/images/covers/kc/95/gvcirtodd95kc_230.jpg"),
                containedKinds: ["md.track.qobuz"],
                childCount: 10,
                isFavourite: true,
                canFavourite: true
            ),
            Linn.LibraryItem(
                id: "qobuz-album-birth-of-the-blue",
                kind: "md.album.qobuz",
                title: "Birth of the Blue",
                subtitle: "Miles Davis",
                album: "Birth of the Blue",
                artists: ["Miles Davis"],
                artworkURL: URL(string: "https://static.qobuz.com/images/covers/fa/90/ld7wpvuga90fa_230.jpg"),
                containedKinds: ["md.track.qobuz"],
                childCount: 4,
                isFavourite: true,
                canFavourite: true
            ),
            Linn.LibraryItem(
                id: "qobuz-album-chopin-nocturnes",
                kind: "md.album.qobuz",
                title: "Chopin: The Complete Nocturnes",
                subtitle: "Tom Hicks",
                album: "Chopin: The Complete Nocturnes",
                artists: ["Tom Hicks"],
                artworkURL: URL(string: "https://static.qobuz.com/images/covers/yc/ag/nuuxf36hoagyc_230.jpg"),
                containedKinds: ["md.track.qobuz"],
                childCount: 21,
                isFavourite: true,
                canFavourite: true
            ),
            Linn.LibraryItem(
                id: "qobuz-album-abbey-road",
                kind: "md.album.qobuz",
                title: "Abbey Road",
                subtitle: "The Beatles",
                album: "Abbey Road",
                artists: ["The Beatles"],
                artworkURL: URL(string: "https://static.qobuz.com/images/covers/6b/az/trrcz9pvaaz6b_230.jpg"),
                containedKinds: ["md.track.qobuz"],
                childCount: 40,
                isFavourite: true,
                canFavourite: true
            ),
            Linn.LibraryItem(
                id: "qobuz-album-opus",
                kind: "md.album.qobuz",
                title: "Opus",
                subtitle: "Ryuichi Sakamoto",
                album: "Opus",
                artists: ["Ryuichi Sakamoto"],
                artworkURL: URL(string: "https://static.qobuz.com/images/covers/vc/kx/z9mpg2fc7kxvc_230.jpg"),
                containedKinds: ["md.track.qobuz"],
                childCount: 20,
                isFavourite: true,
                canFavourite: true
            ),
            Linn.LibraryItem(
                id: "qobuz-album-the-old-country",
                kind: "md.album.qobuz",
                title: "The Old Country",
                subtitle: "Keith Jarrett",
                album: "The Old Country",
                artists: ["Keith Jarrett"],
                artworkURL: URL(string: "https://static.qobuz.com/images/covers/4a/4y/rfwy0akjr4y4a_230.jpg"),
                containedKinds: ["md.track.qobuz"],
                childCount: 8,
                isFavourite: true,
                canFavourite: true
            ),
        ]

        private static let demoLibraryArtists: [Linn.LibraryItem] = [
            Linn.LibraryItem(
                id: "qobuz-artist-qrion",
                kind: "md.artist.qobuz",
                title: "Qrion",
                subtitle: "Qrion",
                artists: ["Qrion"],
                artworkURL: URL(string: "https://static.qobuz.com/images/artists/covers/small/afd716d782ba6b056d5a311b0bed0573.jpg"),
                isFavourite: true,
                canFavourite: true
            ),
        ]

        private static let demoLibraryPlaylists: [Linn.LibraryItem] = [
            Linn.LibraryItem(
                id: "qobuz-playlist-willkommen",
                kind: "md.playlist.qobuz",
                title: "Willkommen bei Qobuz",
                artworkURL: URL(string: "https://static.qobuz.com/images/playlists/1285072_2bc9b2d5023757d1a8b10db915efd367_rectangle.jpg"),
                containedKinds: ["md.track.qobuz"],
                childCount: 125
            ),
            Linn.LibraryItem(
                id: "qobuz-playlist-true-sound-covers",
                kind: "md.playlist.qobuz",
                title: "True Sound Covers",
                artworkURL: URL(string: "https://static.qobuz.com/images/covers/13/05/0093624980513_300.jpg"),
                containedKinds: ["md.track.qobuz"],
                childCount: 50
            ),
            Linn.LibraryItem(
                id: "qobuz-playlist-grammy-winners-2021",
                kind: "md.playlist.qobuz",
                title: "2021 Grammy Winners",
                artworkURL: URL(string: "https://static.qobuz.com/images/playlists/5863588_f5111fc6839f22be2f91948ca16dfc71_rectangle.jpg"),
                containedKinds: ["md.track.qobuz"],
                childCount: 58,
                isFavourite: true,
                canFavourite: true
            ),
        ]

        private static let hitMeHardAndSoftTracks: [Linn.LibraryItem] = [
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

        private static let demoPlaylistTracks: [Linn.LibraryItem] = [
            demoTrack(id: "qobuz-playlist-track-chainsmoking", title: "Chainsmoking", album: "Preview Queue", artist: "Jacob Banks", duration: 197),
            demoTrack(id: "qobuz-playlist-track-green-light", title: "Green Light", album: "Melodrama", artist: "Lorde", duration: 234),
            demoTrack(id: "qobuz-playlist-track-supercut", title: "Supercut", album: "Melodrama", artist: "Lorde", duration: 278),
            demoTrack(id: "qobuz-playlist-track-bad-guy", title: "bad guy", album: "WHEN WE ALL FALL ASLEEP, WHERE DO WE GO?", artist: "Billie Eilish", duration: 194),
            demoTrack(id: "qobuz-playlist-track-time", title: "Time", album: "The Old Country", artist: "Keith Jarrett", duration: 298),
        ]

        private static func demoTracks(for albumID: String) -> [Linn.LibraryItem] {
            guard let album = demoLibraryAlbums.first(where: { $0.id == albumID }) else {
                return []
            }

            let title = album.title
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
        ) -> Linn.LibraryItem {
            Linn.LibraryItem(
                id: id,
                kind: "md.track.qobuz",
                title: title,
                subtitle: artist,
                album: album,
                artists: [artist],
                artworkURL: artworkURL,
                duration: duration
            )
        }
    }
#endif
