import LinnCiGateway
import Testing
@testable import Linn

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
}

@Test func piQobuzFolderKeepsLibraryNavigation() {
    var folder = Louie_Linn_V1_MediaItem()
    folder.id = "qobuz-my"
    folder.name = "My Qobuz"
    folder.type = .container
    folder.provider = .qobuz
    folder.isContainer = true
    var page = Louie_Linn_V1_MediaPage()
    page.children = [folder]

    let mapped = PiLinnMapping.mediaPage(page)
    let libraryItem = Linn.LibraryItem(mapped.children[0])
    #expect(libraryItem.kind.hasPrefix("md.qobuz"))
    #expect(libraryItem.isContainer)
    #expect(libraryItem.title == "My Qobuz")
}
