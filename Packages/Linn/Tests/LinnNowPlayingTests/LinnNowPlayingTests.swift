import Foundation
import Linn
@testable import LinnNowPlaying
import NowPlaying
import Observation
import Testing

@Test @MainActor
func snapshotPreservesMetadataAndElapsedAnchorAcrossVolumeChanges() throws {
    let linn = Linn(mockRoom: "Main Room", currentSong: .init(id: "song", title: "Title", artist: "Artist", album: "Album", duration: 180), playState: .playing)
    let url = URL(string: "http://louie-pi.local:50051")!
    let initial = LinnSessionAttributes(linn: linn, serverURL: url, now: Date(timeIntervalSince1970: 100))
    linn.setVolume(30)
    let update = LinnSessionAttributes(linn: linn, serverURL: url, previous: initial, now: Date(timeIntervalSince1970: 105))
    #expect(update.timestamp == initial.timestamp)
    let decoded = try JSONDecoder().decode(LinnSessionAttributes.self, from: JSONEncoder().encode(update))
    #expect(decoded == update)
    let model = LinnMediaSession(attributes: update)
    let content = try #require(model.content as? MusicContent)
    #expect(content.songTitle == "Title")
    #expect(content.artistName == "Artist")
    #expect(model.playbackSnapshot == MediaPlaybackSnapshot(state: .playing(), timestamp: update.timestamp))
}

@Test(arguments: [Double.nan, Double.infinity, -Double.infinity])
func rejectsNonFiniteSeekPositions(position: Double) {
    #expect(throws: Linn.SeekError.invalidPosition) {
        try Linn.Timeline(seekableRange: 10...100).seekPosition(for: position)
    }
}

@Test
func clampsSeekPositionsAndRejectsUnseekableSources() throws {
    let timeline = Linn.Timeline(seekableRange: 10...100)
    #expect(try timeline.seekPosition(for: -1) == 10)
    #expect(try timeline.seekPosition(for: 500) == 100)
    #expect(try timeline.seekPosition(for: 45.9) == 45)
    #expect(throws: Linn.SeekError.unavailable) { try Linn.Timeline().seekPosition(for: 30) }
}

@Test @MainActor
func commandsRouteToTheRoomAndPropagateFailures() async throws {
    let gateway = RecordingGateway()
    let linn = Linn(mockRoom: "Main Room", currentSong: .init(id: "song", title: "Title"),
                    previousSongs: [.init(id: "previous", title: "Previous")], playState: .playing,
                    timeline: .init(position: 20, duration: 100, seekableRange: 0...100),
                    hasPrevious: true, hasNext: true)
    let attributes = LinnSessionAttributes(linn: linn, serverURL: URL(string: "http://louie-pi.local:50051")!)
    let model = LinnMediaSession(attributes: attributes, gateway: gateway)
    try await model.perform(.togglePlayPause)
    try await model.perform(.play)
    try await model.perform(.previous)
    try await model.perform(.next)
    try await model.perform(.seek(120))
    #expect(await gateway.calls == ["pause:Main Room", "play:Main Room", "previous:Main Room", "next:Main Room", "seek:100:Main Room"])
    await gateway.setFailure()
    await #expect(throws: RecordingGateway.Failure.offline) { try await model.perform(.pause) }
}

@Test @MainActor
func unavailableCommandsNeverReachGateway() async {
    let gateway = RecordingGateway()
    let linn = Linn(mockRoom: "Main Room", currentSong: .init(id: "radio", title: "Radio"), playState: .playing)
    let model = LinnMediaSession(attributes: .init(linn: linn, serverURL: URL(string: "http://louie-pi.local:50051")!), gateway: gateway)
    await #expect(throws: LinnMediaSession.CommandError.unavailable) { try await model.perform(.next) }
    await #expect(throws: LinnMediaSession.CommandError.unavailable) { try await model.perform(.previous) }
    await #expect(throws: Linn.SeekError.unavailable) { try await model.perform(.seek(10)) }
    #expect(await gateway.calls.isEmpty)
}

@Test @MainActor
func stoppedSessionHasNoPublishableContentAndUpdatesPlaybackState() {
    let linn = Linn(mockRoom: "Main Room", currentSong: .init(id: "song", title: "Title"), playState: .paused)
    var attributes = LinnSessionAttributes(linn: linn, serverURL: URL(string: "http://louie-pi.local:50051")!)
    #expect(attributes.hasContent)
    let model = LinnMediaSession(attributes: attributes)
    attributes.playback.state = .stopped
    model.update(attributes)
    #expect(!attributes.hasContent)
    #expect(model.playbackSnapshot == MediaPlaybackSnapshot(state: .stopped, timestamp: attributes.timestamp))
    attributes.playback.state = .buffering
    model.update(attributes)
    #expect(model.playbackSnapshot == MediaPlaybackSnapshot(state: .buffering, timestamp: attributes.timestamp))
}

private actor RecordingGateway: LinnGateway {
    enum Failure: Error { case offline, unexpectedCall }
    private(set) var calls: [String] = []
    private var fails = false
    func setFailure() { fails = true }
    private func record(_ command: String) throws {
        if fails { throw Failure.offline }
        calls.append(command)
    }
    func wake(room: String) async throws { throw Failure.unexpectedCall }
    func play(room: String) async throws { try record("play:\(room)") }
    func pause(room: String) async throws { try record("pause:\(room)") }
    func previous(room: String) async throws { try record("previous:\(room)") }
    func next(room: String) async throws { try record("next:\(room)") }
    func seek(to position: Int, room: String) async throws { try record("seek:\(position):\(room)") }
    func nowPlayingUpdates(room: String?, updateInterval: Int) async -> AsyncThrowingStream<Linn.Snapshot, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func selectPlaylistItem(at index: Int, room: String) async throws { throw Failure.unexpectedCall }
    func setVolume(_ volume: Int, room: String, group: Bool) async throws { try record("volume:\(volume):\(room):\(group)") }
    func setMuted(_ isMuted: Bool, room: String, group: Bool) async throws { throw Failure.unexpectedCall }
    func mediaServices(room: String) async throws -> [Linn.LibraryService] { throw Failure.unexpectedCall }
    func browseMedia(mediaID: String, index: Int, count: Int, browseType: String) async throws -> Linn.LibraryPage { throw Failure.unexpectedCall }
    func searchMedia(serviceID: String, query: String, type: Linn.SearchType, index: Int, count: Int) async throws -> Linn.LibraryPage { throw Failure.unexpectedCall }
    func selectMedia(mediaID: String, room: String, queue: Linn.QueuePlacement) async throws { throw Failure.unexpectedCall }
    func setMediaFavourite(mediaID: String, isFavourite: Bool) async throws { throw Failure.unexpectedCall }
}

@Test @MainActor
func liveGatewayUpdatesAreObservableAndDisableTheRadioScrubber() async throws {
    let linn = Linn(mockRoom: "Main Room", currentSong: .init(id: "song", title: "Old Song"), playState: .playing,
                    timeline: .init(position: 10, duration: 180, seekableRange: 0...180))
    let model = LinnMediaSession(attributes: .init(linn: linn, serverURL: URL(string: "http://louie-pi.local:50051")!))
    var snapshots = Observations { model.attributes }.makeAsyncIterator()
    let initial = try #require(await snapshots.next())
    #expect(initial.playback.timeline?.seekableRange == 0...180)

    var update = Linn.Snapshot()
    update.currentSong = .init(id: "radio", title: "Live Radio")
    update.playState = .paused
    update.timeline = .init(position: 0)
    update.playlist = .init()
    model.receive(update)

    let changed = try #require(await snapshots.next())
    #expect(changed.playback.song?.title == "Live Radio")
    #expect(changed.playback.state == .paused)
    #expect(changed.playback.timeline?.seekableRange == nil)
    #expect(!changed.hasPrevious && !changed.hasNext)
    #expect(changed.timestamp >= initial.timestamp)
}

@Test @MainActor
func completeServerSnapshotsClearOldFieldsAndPreserveVolumeOnlyAnchor() async throws {
    let linn = Linn(mockRoom: "Main Room", currentSong: .init(id: "song", title: "Title"), playState: .playing)
    let model = LinnMediaSession(attributes: .init(linn: linn, serverURL: URL(string: "http://louie-pi.local:50051")!))
    var update = Linn.Snapshot()
    update.currentSong = linn.currentSong
    update.playState = .playing
    update.timeline = .init(position: 20, duration: 100, seekableRange: 0...100)
    update.playlist = .init(currentIndex: 1, total: 3)
    model.receive(update)
    let anchor = model.attributes.timestamp
    update.volume = 12
    model.receive(update)
    #expect(model.attributes.timestamp == anchor)
    #expect(model.attributes.hasPrevious && model.attributes.hasNext)
    model.receive(Linn.Snapshot())
    #expect(model.attributes.playback.song == nil)
    #expect(model.attributes.playback.timeline == nil)
    #expect(model.attributes.volume == nil)
    #expect(!model.attributes.hasPrevious && !model.attributes.hasNext)
    #expect(model.content == nil)
}

@Test @MainActor
func unavailableAndStandbySnapshotsDisableSystemControlsUntilRecovery() async throws {
    let gateway = RecordingGateway()
    let linn = Linn(mockRoom: "Main Room", currentSong: .init(id: "song", title: "Title"), playState: .playing)
    let model = LinnMediaSession(attributes: .init(linn: linn, serverURL: URL(string: "http://louie-pi.local:50051")!), gateway: gateway)
    for status: Linn.ConnectionState in [.connected, .serverUnreachable, .linnUnavailable(nil)] {
        var update = Linn.Snapshot(connectionState: status)
        update.isStandby = status == .connected
        update.currentSong = linn.currentSong
        update.playState = .playing
        update.volume = 20
        model.receive(update)
        #expect(model.content == nil)
        #expect(model.commands.isEmpty)
        #expect(model.playbackSnapshot == MediaPlaybackSnapshot(state: .stopped, timestamp: model.attributes.timestamp))
        await #expect(throws: LinnMediaSession.CommandError.unavailable) { try await model.perform(.play) }
        await #expect(throws: LinnMediaSession.CommandError.unavailable) { try await model.setVolume(0.2) }
    }
    #expect(await gateway.calls.isEmpty)
    var recovered = Linn.Snapshot()
    recovered.currentSong = linn.currentSong
    recovered.playState = .paused
    model.receive(recovered)
    #expect(model.content != nil)
    try await model.perform(.play)
    #expect(await gateway.calls == ["play:Main Room"])
}

@Test @MainActor
func speakerVolumeUsesRoomScopeAndLatestServerLimit() async throws {
    let gateway = RecordingGateway()
    let linn = Linn(mockRoom: "Main Room", currentSong: .init(id: "song", title: "Title"), playState: .playing)
    let model = LinnMediaSession(attributes: .init(linn: linn, serverURL: URL(string: "http://louie-pi.local:50051")!), gateway: gateway)
    try await model.setVolume(1)
    var update = Linn.Snapshot()
    update.maximumVolume = 45
    model.receive(update)
    try await model.setVolume(1)
    try await model.setVolume(-1)
    await #expect(throws: LinnMediaSession.CommandError.unavailable) { try await model.setVolume(.nan) }
    #expect(await gateway.calls == ["volume:70:Main Room:false", "volume:45:Main Room:false", "volume:0:Main Room:false"])
}

@Test @MainActor
func pendingUnknownSongKeepsSessionUntilResolutionOrExpiry() {
    let linn = Linn(mockRoom: "Main Room", currentSong: .init(id: "old", title: "Old Song"), playState: .playing)
    let model = LinnMediaSession(attributes: .init(linn: linn, serverURL: URL(string: "http://louie-pi.local:50051")!))
    let previous = model.attributes
    var pending = Linn.Snapshot()
    pending.playState = .playing
    pending.pending.currentItem = true
    pending.pending.queueIndex = true
    model.receive(pending)
    #expect(model.attributes == previous)
    #expect(model.content != nil)
    pending.currentSong = .init(id: "next", title: "Next Song")
    pending.pending.currentItem = false
    model.receive(pending)
    #expect(model.attributes.playback.song?.title == "Next Song")
    pending.currentSong = nil
    model.receive(pending)
    #expect(model.content == nil)
}

@Test @MainActor
func pendingUnknownSongDoesNotHideStopStandbyOrDisconnection() {
    let linn = Linn(mockRoom: "Main Room", currentSong: .init(id: "old", title: "Old Song"), playState: .playing)
    let initial = LinnSessionAttributes(linn: linn, serverURL: URL(string: "http://louie-pi.local:50051")!)
    var pending = Linn.Snapshot()
    pending.playState = .playing
    pending.pending.currentItem = true
    for reason in 0..<3 {
        let model = LinnMediaSession(attributes: initial)
        var update = pending
        if reason == 0 { update.playState = .stopped }
        if reason == 1 { update.isStandby = true }
        if reason == 2 { update.connectionState = .linnUnavailable(nil) }
        model.receive(update)
        #expect(model.content == nil)
    }
}

@Test @MainActor
func systemVolumeUsesTheEffectiveLimitInBothDirections() async throws {
    let gateway = RecordingGateway()
    let linn = Linn(mockRoom: "Main Room", currentSong: .init(id: "song", title: "Title"), playState: .playing)
    let model = LinnMediaSession(attributes: .init(linn: linn, serverURL: URL(string: "http://louie-pi.local:50051")!), gateway: gateway)
    try await model.setVolume(0.5)
    var update = Linn.Snapshot()
    update.volume = 35
    update.maximumVolume = 70
    model.receive(update)
    #expect(model.normalizedVolume == 0.5)
    update.volume = 15
    update.maximumVolume = 30
    model.receive(update)
    #expect(model.normalizedVolume == 0.5)
    try await model.setVolume(0.5)
    #expect(await gateway.calls == ["volume:35:Main Room:false", "volume:15:Main Room:false"])
}
