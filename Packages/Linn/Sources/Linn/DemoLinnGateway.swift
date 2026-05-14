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
        private var subscriptions: [UUID: Subscription] = [:]

        public init() {
            self.init(
                songs: Self.defaultSongs,
                currentIndex: 0,
                transportState: .pause,
                position: 61,
                volume: 32,
                isMuted: false
            )
        }

        public init(
            songs: [Linn.Song],
            currentIndex: Int = 0,
            playState: Linn.PlayState = .paused,
            position: Int = 0,
            volume: Int = 32,
            isMuted: Bool = false
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
                isMuted: isMuted
            )
        }

        private init(
            songs: [DemoSong],
            currentIndex: Int,
            transportState: CiGateway.NowPlaying.TransportState,
            position: Int,
            volume: Int,
            isMuted: Bool
        ) {
            self.songs = songs
            self.currentIndex = min(max(0, currentIndex), songs.count - 1)
            self.transportState = transportState
            self.position = position
            self.volume = volume
            self.isMuted = isMuted
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

            currentIndex -= 1
            position = 0
            transportState = .buffering
            yieldSnapshot()
            try await Task.sleep(for: .milliseconds(350))
            transportState = .play
            yieldSnapshot()
        }

        public func next(room _: String) async throws {
            guard currentIndex + 1 < songs.count else {
                return
            }

            currentIndex += 1
            position = 0
            transportState = .buffering
            yieldSnapshot()
            try await Task.sleep(for: .milliseconds(350))
            transportState = .play
            yieldSnapshot()
        }

        public func selectPlaylistItem(at index: Int, room _: String) async throws {
            guard songs.indices.contains(index) else {
                return
            }

            currentIndex = index
            position = 0
            transportState = .buffering
            yieldSnapshot()
            try await Task.sleep(for: .milliseconds(350))
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
            CiGateway.NowPlaying.Playlist(
                items: songs.enumerated().map { index, song in
                    CiGateway.NowPlaying.PlaylistItem(
                        index: index,
                        displayName: song.title,
                        album: song.album,
                        artist: song.artist,
                        duration: song.duration,
                        artworkURL: song.artworkURL
                    )
                },
                total: songs.count,
                contentRevision: 1
            )
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
        ]
    }
#endif
