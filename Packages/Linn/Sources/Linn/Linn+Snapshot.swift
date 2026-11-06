public extension Linn {
    /// Complete app state from Louie Home Server (or the preview gateway).
    /// Songs, playlists and timelines are already mapped into app domain values.
    struct Snapshot: Sendable, Equatable {
        public var connectionState: ConnectionState = .connected
        public var isStandby = false
        public var playState: PlayState?
        public var currentSong: Song?
        public var playlist = Playlist()
        public var timeline: Timeline?
        public var volume: Int?
        public var isMuted: Bool?
        public var maximumVolume: Int?
        public var pending = Pending()

        public init(connectionState: ConnectionState = .connected) {
            self.connectionState = connectionState
        }

        /// Only the prediction flags used for local control feedback and animation.
        public struct Pending: Sendable, Equatable {
            public var queueIndex = false
            public var queueTotal = false
            public var currentItem = false
            public var volume = false
            public var mute = false

            public init() {}
        }
    }
}
