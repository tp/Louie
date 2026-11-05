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
        room: "Linn",
        watch: { receive in try await scripted.run(receive) },
        sleep: { seconds in await delays.record(seconds) }
    )
    var statuses: [LinnGatewayData.NowPlaying.ConnectionStatus] = []
    var terminalCode: RPCError.Code?
    do {
        for try await update in updates {
            statuses.append(update.connectionStatus)
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
    #expect(update.room == "Linn")
    #expect(update.session == "session-1")
    #expect(update.playback?.transportState == .play)
    #expect(update.currentItem?.displayName == "A Song")
    #expect(update.queue?.index == 1)
    #expect(update.queue?.length == 3)
    #expect(update.roomState?.volume == 42)
    #expect(update.roomState?.isMuted == false)
    #expect(update.roomState?.maximumVolume == 45)
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
    #expect(update.pending.queue)
    #expect(update.pending.queueIndex)
    #expect(update.pending.currentItem)
    #expect(update.pending.transport)
    #expect(update.pending.volume)
    #expect(!update.pending.playback)
}
