import Foundation
import Linn
import LinnCiGateway
@testable import LinnNowPlaying
import NowPlaying
import Observation
import Testing

@Test @MainActor
func snapshotPreservesMetadataAndElapsedAnchorAcrossVolumeChanges() throws {
    let linn = Linn(currentSong: .init(id: "song", title: "Title", artist: "Artist", album: "Album", duration: 180), playState: .playing)
    let url = URL(string: "ws://linn.local:8088")!
    let initial = LinnSessionAttributes(linn: linn, gatewayURL: url, now: Date(timeIntervalSince1970: 100))
    linn.setVolume(30)
    let update = LinnSessionAttributes(linn: linn, gatewayURL: url, previous: initial, now: Date(timeIntervalSince1970: 105))
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
    let linn = Linn(currentSong: .init(id: "song", title: "Title"),
                    previousSongs: [.init(id: "previous", title: "Previous")], playState: .playing,
                    timeline: .init(position: 20, duration: 100, seekableRange: 0...100),
                    hasPrevious: true, hasNext: true)
    let attributes = LinnSessionAttributes(linn: linn, gatewayURL: URL(string: "ws://linn.local:8088")!)
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
    let linn = Linn(currentSong: .init(id: "radio", title: "Radio"), playState: .playing)
    let model = LinnMediaSession(attributes: .init(linn: linn, gatewayURL: URL(string: "ws://linn.local:8088")!), gateway: gateway)
    await #expect(throws: LinnMediaSession.CommandError.unavailable) { try await model.perform(.next) }
    await #expect(throws: LinnMediaSession.CommandError.unavailable) { try await model.perform(.previous) }
    await #expect(throws: Linn.SeekError.unavailable) { try await model.perform(.seek(10)) }
    #expect(await gateway.calls.isEmpty)
}

@Test @MainActor
func stoppedSessionHasNoPublishableContentAndUpdatesPlaybackState() {
    let linn = Linn(currentSong: .init(id: "song", title: "Title"), playState: .paused)
    var attributes = LinnSessionAttributes(linn: linn, gatewayURL: URL(string: "ws://linn.local:8088")!)
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
    func play(room: String) async throws { try record("play:\(room)") }
    func pause(room: String) async throws { try record("pause:\(room)") }
    func previous(room: String) async throws { try record("previous:\(room)") }
    func next(room: String) async throws { try record("next:\(room)") }
    func seek(to position: Int, room: String) async throws { try record("seek:\(position):\(room)") }
    func nowPlayingUpdates(room: String?, updateInterval: Int) async -> AsyncThrowingStream<CiGateway.NowPlaying, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func selectPlaylistItem(at index: Int, room: String) async throws { throw Failure.unexpectedCall }
    func setVolume(_ volume: Int, room: String, group: Bool) async throws { throw Failure.unexpectedCall }
    func setMuted(_ isMuted: Bool, room: String, group: Bool) async throws { throw Failure.unexpectedCall }
    func mediaServices(room: String) async throws -> [CiGateway.MediaService] { throw Failure.unexpectedCall }
    func browseMedia(mediaID: String, index: Int, count: Int, browseType: String) async throws -> CiGateway.MediaPage { throw Failure.unexpectedCall }
    func searchMedia(serviceID: String, query: String, type: CiGateway.MediaSearchType, index: Int, count: Int) async throws -> CiGateway.MediaPage { throw Failure.unexpectedCall }
    func selectMedia(mediaID: String, room: String, queue: CiGateway.QueuePlacement) async throws { throw Failure.unexpectedCall }
    func setMediaFavourite(mediaID: String, isFavourite: Bool) async throws { throw Failure.unexpectedCall }
}

@Test @MainActor
func liveGatewayUpdatesAreObservableAndDisableTheRadioScrubber() async throws {
    let linn = Linn(currentSong: .init(id: "song", title: "Old Song"), playState: .playing,
                    timeline: .init(position: 10, duration: 180, seekableRange: 0...180))
    let model = LinnMediaSession(attributes: .init(linn: linn, gatewayURL: URL(string: "ws://linn.local:8088")!))
    var snapshots = Observations { model.attributes }.makeAsyncIterator()
    let initial = try #require(await snapshots.next())
    #expect(initial.playback.timeline?.seekableRange == 0...180)

    var update = CiGateway.NowPlaying(room: "Main Room", session: "s.01")
    update.currentItem = .init(id: "radio", kind: "station", displayName: "Live Radio")
    update.playback = .init(transportState: .pause)
    update.timeline = .init(position: 0, isSeekable: false)
    update.queue = .init()
    model.receive(update)

    let changed = try #require(await snapshots.next())
    #expect(changed.playback.song?.title == "Live Radio")
    #expect(changed.playback.state == .paused)
    #expect(changed.playback.timeline?.seekableRange == nil)
    #expect(!changed.hasPrevious && !changed.hasNext)
    #expect(changed.timestamp >= initial.timestamp)
}
