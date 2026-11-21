import Foundation
import GRPCCore
import Testing
@testable import Linn

@Test func rpcCodesDriveFriendlyMessagesWithoutLosingTheirIdentity() {
    let unreachable = PiLinnRPCError(code: .unavailable, message: "transport closed")
    #expect(unreachable.code == .unavailable)
    #expect(unreachable.errorDescription == "Can't reach Louie Home Server.")

    let linnDisconnected = PiLinnRPCError(code: .failedPrecondition, message: "Linn gateway is disconnected")
    #expect(linnDisconnected.errorDescription == "Linn can't perform this action right now.")

    let rejected = PiLinnRPCError(code: .failedPrecondition, message: "Linn is in standby")
    #expect(rejected.code == .failedPrecondition)
    #expect(rejected.errorDescription == linnDisconnected.errorDescription)

    let withReason = PiLinnRPCError(RPCError(
        code: .failedPrecondition,
        message: "device is offline",
        metadata: ["louie-error-reason": "linn-disconnected"]
    ))
    #expect(withReason.reason == .linnDisconnected)
    #expect(withReason.errorDescription == "Louie Home Server can't reach Linn.")
    let standby = PiLinnRPCError(RPCError(code: .failedPrecondition, message: "standby", metadata: ["louie-error-reason": "linn-standby"]))
    #expect(standby.reason == .linnStandby)
    #expect(standby.errorDescription == "Linn is off. Turn it on to control playback.")
    #expect(PiLinnRPCError(code: .failedPrecondition, message: "", reason: .sourceNotSeekable).errorDescription == "This source doesn't support seeking.")
    #expect(PiLinnRPCError(code: .failedPrecondition, message: "", reason: .linnRejected).errorDescription == "Linn rejected the request.")
}

@Test func transientStreamCodesRetryAndConfigurationCodesStop() {
    let transientCodes: [RPCError.Code] = [.unavailable, .deadlineExceeded, .unknown, .internalError, .cancelled]
    for code in transientCodes {
        #expect(!PiLinnGateway.isTerminalStreamError(code))
    }
    let terminalCodes: [RPCError.Code] = [.unimplemented, .unauthenticated, .permissionDenied, .invalidArgument, .failedPrecondition]
    for code in terminalCodes {
        #expect(PiLinnGateway.isTerminalStreamError(code))
    }
}

@Test func supersededCancellationUsesReasonCode() {
    let superseded = RPCError(
        code: .cancelled,
        message: "wording may change",
        metadata: ["louie-error-reason": "superseded"]
    )
    #expect(PiLinnGateway.isSuperseded(superseded))
    #expect(!PiLinnGateway.isSuperseded(RPCError(code: .cancelled, message: "superseded by a newer value")))
}

private actor ScriptedWatch {
    private var attempts = 0

    func run(_ receive: @escaping @Sendable (Louie_Linn_V1_StateSnapshot) async -> Void) async throws {
        attempts += 1
        if attempts > 3 {
            throw RPCError(code: .unimplemented, message: "incompatible server")
        }
        var snapshot = Louie_Linn_V1_StateSnapshot()
        snapshot.room = "Linn"
        snapshot.connectionStatus = .connected
        await receive(snapshot)
        throw RPCError(code: .unavailable, message: "stream dropped")
    }
}

private actor RetryDelays {
    private var values: [Int] = []

    func record(_ seconds: Int) { values.append(seconds) }
    func recorded() -> [Int] { values }
}

@Test func watchRetriesAfterSnapshotsAndReportsEveryDrop() async {
    let gateway = PiLinnGateway(serverURL: URL(string: "http://louie-pi.local:50051")!)
    let scripted = ScriptedWatch()
    let delays = RetryDelays()
    let updates = await gateway.updates(
        watch: { receive in try await scripted.run(receive) },
        sleep: { seconds in await delays.record(seconds) }
    )
    var statuses: [Linn.ConnectionState] = []
    var terminalCode: RPCError.Code?
    do {
        for try await update in updates {
            statuses.append(update.connectionState)
        }
    } catch let error as PiLinnRPCError {
        terminalCode = error.code
    } catch {
        Issue.record("Unexpected stream error: \(error)")
    }
    #expect(statuses == [.connected, .serverUnreachable, .connected, .serverUnreachable, .connected, .serverUnreachable])
    #expect(await delays.recorded() == [1, 1, 1])
    #expect(terminalCode == .unimplemented)
}

@Test func piSnapshotRetainsPlaybackQueueAndVolume() {
    var snapshot = Louie_Linn_V1_StateSnapshot()
    snapshot.room = "Linn"
    snapshot.nowPlayingSessionID = "session-1"
    var state = Louie_Linn_V1_NowPlayingState()
    state.isStandby = true
    state.transportState = .playing
    var item = Louie_Linn_V1_CurrentItem()
    item.id = "track-1"
    item.displayName = "A Song"
    state.currentItem = item
    var playlist = Louie_Linn_V1_Playlist()
    playlist.currentIndex = 1
    playlist.total = 3
    state.playlist = playlist
    var volume = Louie_Linn_V1_RoomVolume()
    volume.volume = 42
    volume.isMuted = false
    volume.maximumVolume = 45
    state.roomVolume = volume
    snapshot.nowPlaying = state

    let update = PiLinnMapping.nowPlaying(snapshot)
    #expect(update.isStandby == true)
    #expect(update.playState == .playing)
    #expect(update.currentSong?.title == "A Song")
    #expect(update.playlist.currentIndex == 1)
    #expect(update.playlist.total == 3)
    #expect(update.volume == 42)
    #expect(update.isMuted == false)
    #expect(update.maximumVolume == 45)
}

@Test func piQobuzFolderKeepsLibraryNavigation() {
    var folder = Louie_Linn_V1_MediaItem()
    folder.id = "qobuz-my"
    folder.name = "My Qobuz"
    folder.type = .container
    folder.provider = .qobuz
    folder.isContainer = true
    folder.linnClass = "md.container.qobuz.album"
    folder.containedClasses = ["md.album.qobuz"]
    var page = Louie_Linn_V1_MediaPage()
    page.children = [folder]

    let mapped = PiLinnMapping.mediaPage(page)
    let libraryItem = mapped.items[0]
    #expect(libraryItem.kind == "md.container.qobuz.album")
    #expect(libraryItem.containedKinds == ["md.album.qobuz"])
    #expect(libraryItem.isContainer)
    #expect(libraryItem.title == "My Qobuz")
}

@Test func favouriteActionRequiresKnownFavouriteState() {
    var item = Louie_Linn_V1_MediaItem()
    item.id = "album"
    item.canFavourite = true
    var page = Louie_Linn_V1_MediaPage()
    page.children = [item]

    #expect(!PiLinnMapping.mediaPage(page).items[0].canFavourite)
    page.children[0].isFavourite = false
    #expect(PiLinnMapping.mediaPage(page).items[0].canFavourite)
}

@Test func piSnapshotCarriesServerPredictionsWithoutCallingThemObserved() {
    var snapshot = Louie_Linn_V1_StateSnapshot()
    snapshot.room = "Linn"
    var pending = Louie_Linn_V1_PendingState()
    pending.queue = true
    pending.queueIndex = true
    pending.currentItem = true
    pending.transport = true
    pending.volume = true
    snapshot.pending = pending

    let update = PiLinnMapping.nowPlaying(snapshot)
    #expect(update.pending.queueIndex)
    #expect(update.pending.currentItem)
    #expect(update.pending.volume)
}

@Test func snapshotMapsDomainValuesAndPreservesOptionalPresence() {
    var snapshot = Louie_Linn_V1_StateSnapshot()
    snapshot.connectionStatus = .connected
    snapshot.nowPlaying.transportState = .waiting
    snapshot.nowPlaying.playlist.currentIndex = 0
    snapshot.nowPlaying.playlist.total = 1
    var row = Louie_Linn_V1_PlaylistItem()
    row.index = 0
    row.displayName = "Queue title"
    row.artist = "Artist"
    row.album = "Album"
    row.durationSeconds = 180
    row.artworkURL = "https://example.com/cover.jpg"
    snapshot.nowPlaying.playlist.items = [row]
    snapshot.nowPlaying.currentItem.id = "track"
    snapshot.nowPlaying.currentItem.displayName = "Fallback"
    snapshot.nowPlaying.currentItem.track.title = "Track title"
    snapshot.nowPlaying.currentItem.track.artist = "Artist"
    snapshot.nowPlaying.timeline.positionSeconds = 0
    snapshot.nowPlaying.timeline.durationSeconds = 180
    snapshot.nowPlaying.roomVolume.volume = 0
    snapshot.nowPlaying.roomVolume.isMuted = false
    let mapped = PiLinnMapping.nowPlaying(snapshot)
    #expect(mapped.connectionState == .connected)
    #expect(!mapped.isStandby) // Older servers omit this field.
    #expect(mapped.playState == .buffering)
    #expect(mapped.currentSong?.title == "Track title")
    #expect(mapped.currentSong?.queueIndex == 0)
    #expect(mapped.playlist.songs == [Linn.Song(
        id: "playlist-0", title: "Queue title", artist: "Artist", album: "Album",
        duration: 180, artworkURL: URL(string: "https://example.com/cover.jpg"), queueIndex: 0
    )])
    #expect(mapped.timeline == .init(position: 0, duration: 180, progress: 0))
    #expect(mapped.volume == 0)
    #expect(mapped.isMuted == false)

    snapshot.nowPlaying.timeline.durationSeconds = 0
    #expect(PiLinnMapping.nowPlaying(snapshot).timeline?.progress == nil)
    snapshot.clearNowPlaying()
    let empty = PiLinnMapping.nowPlaying(snapshot)
    #expect(empty.currentSong == nil)
    #expect(empty.playState == nil)
    #expect(empty.playlist == .init())
    #expect(empty.timeline == nil)
    #expect(empty.volume == nil)
    #expect(empty.isMuted == nil)
}

@Test func snapshotConnectionStateDistinguishesLinnFromServerAvailability() {
    var snapshot = Louie_Linn_V1_StateSnapshot()
    #expect(PiLinnMapping.nowPlaying(snapshot).connectionState == .connecting)
    snapshot.connectionStatus = .disconnected
    #expect(PiLinnMapping.nowPlaying(snapshot).connectionState == .linnUnavailable(nil))
    snapshot.connectionError = "Room unavailable"
    #expect(PiLinnMapping.nowPlaying(snapshot).connectionState == .linnUnavailable("Room unavailable"))
    snapshot.connectionStatus = .connecting
    #expect(PiLinnMapping.nowPlaying(snapshot).connectionState == .linnUnavailable("Room unavailable"))
    snapshot.connectionStatus = .connected
    #expect(PiLinnMapping.nowPlaying(snapshot).connectionState == .connected)
}

@Test func serverSeekabilityControlsScrubbingAndClearsOldRanges() {
    var snapshot = Louie_Linn_V1_StateSnapshot()
    snapshot.connectionStatus = .connected
    snapshot.nowPlaying.timeline.positionSeconds = 20
    snapshot.nowPlaying.timeline.durationSeconds = 180
    snapshot.nowPlaying.timeline.isSeekable = true
    snapshot.nowPlaying.timeline.seekLowerBoundSeconds = 10
    snapshot.nowPlaying.timeline.seekUpperBoundSeconds = 150
    #expect(PiLinnMapping.nowPlaying(snapshot).timeline?.seekableRange == 10...150)
    snapshot.nowPlaying.timeline.isSeekable = false
    #expect(PiLinnMapping.nowPlaying(snapshot).timeline?.seekableRange == nil)
    snapshot.nowPlaying.timeline.isSeekable = true
    snapshot.nowPlaying.timeline.seekUpperBoundSeconds = 5
    #expect(PiLinnMapping.nowPlaying(snapshot).timeline?.seekableRange == nil)
    snapshot.nowPlaying.timeline.clearSeekUpperBoundSeconds()
    #expect(PiLinnMapping.nowPlaying(snapshot).timeline?.seekableRange == nil)
    snapshot.nowPlaying.clearTimeline()
    #expect(PiLinnMapping.nowPlaying(snapshot).timeline == nil)
}
