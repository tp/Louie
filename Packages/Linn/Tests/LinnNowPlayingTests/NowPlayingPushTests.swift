import Foundation
@testable import Linn
@testable import LinnNowPlaying
import Testing

@Test @MainActor
func rustPushFixtureDecodesWithFrameworkDateStrategies() throws {
    let url = try #require(Bundle.module.url(forResource: "push-attributes", withExtension: "json", subdirectory: "Fixtures"))
    let data = try Data(contentsOf: url)
    for strategy: JSONDecoder.DateDecodingStrategy in [.deferredToDate, .iso8601, .secondsSince1970] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = strategy
        let attributes = try decoder.decode(LinnSessionAttributes.self, from: data)
        #expect(attributes.id == "http://louie-pi.local:50051|Linn")
        #expect(attributes.installationID == "test-install")
        #expect(attributes.timestamp == Date(timeIntervalSince1970: 100))
        #expect(attributes.playback.state == .playing)
        #expect(attributes.playback.timeline?.seekableRange == 0...180)
        #expect(attributes.playback.timeline?.sampledAtSeconds == 100)
        #expect(attributes.hasContent)
        #expect(try JSONDecoder().decode(LinnSessionAttributes.self, from: JSONEncoder().encode(attributes)) == attributes)
    }
}

private actor PushGateway: NowPlayingPushGateway {
    private(set) var attempts: [Data] = []
    var failFirst: Bool
    var suspendFirst: Bool
    init(failFirst: Bool = false, suspendFirst: Bool = false) {
        self.failFirst = failFirst
        self.suspendFirst = suspendFirst
    }
    func registerNowPlayingToken(_ registration: NowPlayingTokenRegistration) async throws {
        attempts.append(registration.token)
        if attempts.count == 1 {
            if suspendFirst { try await Task.sleep(for: .seconds(60)) }
            if failFirst { throw URLError(.notConnectedToInternet) }
        }
    }
    func removeNowPlayingToken(_ registration: NowPlayingTokenRegistration) async throws {}
}

@Test @MainActor
func tokenRegistrationRetriesAfterHomeServerOutage() async throws {
    let gateway = PushGateway(failFirst: true)
    let registrar = NowPlayingTokenRegistrar(gateway: gateway, installationID: "test", environment: .sandbox,
        serverURL: URL(string: "http://louie-pi.local:50051")!, sleep: { _ in try await Task.sleep(for: .milliseconds(1)) })
    registrar.submit(Data([1]))
    for _ in 0..<100 {
        if await gateway.attempts.count == 2 { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(await gateway.attempts == [Data([1]), Data([1])])
}

@Test @MainActor
func tokenRotationCancelsRegistrationForTheOldToken() async throws {
    let gateway = PushGateway(suspendFirst: true)
    let registrar = NowPlayingTokenRegistrar(gateway: gateway, installationID: "test", environment: .production,
        serverURL: URL(string: "http://louie-pi.local:50051")!)
    registrar.submit(Data([1]))
    for _ in 0..<100 {
        if await gateway.attempts.count == 1 { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    registrar.submit(Data([2]))
    for _ in 0..<100 {
        if await gateway.attempts.count == 2 { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(await gateway.attempts == [Data([1]), Data([2])])
}

@Test @MainActor
func serverClockAnchorSurvivesNetworkDelayAndLocalNetworkLoss() {
    let linn = Linn(mockRoom: "Linn")
    let model = LinnMediaSession(attributes: .init(linn: linn, serverURL: URL(string: "http://louie-pi.local:50051")!,
        installationID: "test", pushEnvironment: "sandbox"))
    var snapshot = Linn.Snapshot()
    snapshot.playState = .playing
    snapshot.currentSong = .init(id: "song", title: "Song")
    snapshot.timeline = .init(position: 20, sampledAtSeconds: 100)
    model.receive(snapshot)
    #expect(model.attributes.timestamp == Date(timeIntervalSince1970: 100))
    for connection: Linn.ConnectionState in [.idle, .connecting, .serverUnreachable] {
        model.receive(Linn.Snapshot(connectionState: connection))
        #expect(model.attributes.hasContent)
    }
    model.receive(Linn.Snapshot(connectionState: .linnUnavailable(nil)))
    #expect(!model.attributes.hasContent)
}

@Test @MainActor
func predictedResumeUsesPublicationTimeForAppAndExtension() throws {
    var frame = Louie_Linn_V1_StateSnapshot()
    frame.connectionStatus = .connected
    frame.publishedAt.seconds = 700
    frame.nowPlaying.transportState = .playing
    frame.nowPlaying.currentItem.id = "song"
    frame.nowPlaying.currentItem.track.title = "Song"
    frame.nowPlaying.timeline.positionSeconds = 42
    frame.nowPlaying.timeline.durationSeconds = 900
    frame.nowPlaying.timeline.positionSampledAt.seconds = 100
    frame.pending.transport = true
    let mapped = PiLinnMapping.nowPlaying(frame)
    #expect(mapped.timeline?.sampledAtSeconds == 700)
    let linn = Linn(mockRoom: "Linn", currentSong: mapped.currentSong, playState: .playing, timeline: mapped.timeline)
    let attributes = LinnSessionAttributes(linn: linn, serverURL: URL(string: "http://louie-pi.local:50051")!)
    #expect(attributes.timestamp.timeIntervalSince1970 == 700)
    let model = LinnMediaSession(attributes: attributes)
    model.receive(mapped)
    let position = try #require(model.attributes.playback.timeline?.position)
    #expect(Double(position) + 701 - model.attributes.timestamp.timeIntervalSince1970 == 43)
    frame.pending.transport = false
    #expect(PiLinnMapping.nowPlaying(frame).timeline?.sampledAtSeconds == 100)
    frame.pending.transport = true
    frame.clearPublishedAt()
    #expect(PiLinnMapping.nowPlaying(frame).timeline?.sampledAtSeconds == nil)
}
