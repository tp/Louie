import Foundation

package enum NowPlayingPushEnvironment: String, Sendable {
    case sandbox, production

    var proto: Louie_Linn_V1_APNsEnvironment {
        self == .sandbox ? .sandbox : .production
    }
}

package struct NowPlayingTokenRegistration: Sendable, Equatable {
    package var installationID: String
    package var token: Data
    package var sessionID: String
    package var serverURL: URL
    package var environment: NowPlayingPushEnvironment

    package init(installationID: String, token: Data, sessionID: String, serverURL: URL, environment: NowPlayingPushEnvironment) {
        self.installationID = installationID
        self.token = token
        self.sessionID = sessionID
        self.serverURL = serverURL
        self.environment = environment
    }

    var kind: Louie_Linn_V1_NowPlayingTokenKind { sessionID.isEmpty ? .pushToStart : .sessionUpdate }
}

package protocol NowPlayingPushGateway: Sendable {
    func registerNowPlayingToken(_ registration: NowPlayingTokenRegistration) async throws
    func removeNowPlayingToken(_ registration: NowPlayingTokenRegistration) async throws
}

extension Linn.Configuration {
    package func makePushGateway() -> any NowPlayingPushGateway {
        PiLinnGateway(serverURL: serverURL)
    }
}
