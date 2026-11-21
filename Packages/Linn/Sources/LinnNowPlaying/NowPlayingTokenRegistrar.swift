import Foundation
import Linn
import OSLog

/// One latest-token retry task per source. Rotation cancels work for the old token.
@MainActor
final class NowPlayingTokenRegistrar {
    private let gateway: any NowPlayingPushGateway
    private let installationID: String
    private let environment: NowPlayingPushEnvironment
    private let serverURL: URL
    private let sleep: @Sendable (Duration) async throws -> Void
    private var registrationTask: Task<Void, Never>?

    init(gateway: any NowPlayingPushGateway, installationID: String, environment: NowPlayingPushEnvironment,
         serverURL: URL, sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.gateway = gateway
        self.installationID = installationID
        self.environment = environment
        self.serverURL = serverURL
        self.sleep = sleep
    }

    deinit { registrationTask?.cancel() }

    func observe(current: Data?, updates: AsyncStream<Data>, sessionID: String = "") async {
        defer { registrationTask?.cancel() }
        if let current { submit(current, sessionID: sessionID) }
        for await token in updates {
            if Task.isCancelled { break }
            submit(token, sessionID: sessionID)
        }
    }

    func submit(_ token: Data, sessionID: String = "") {
        guard !token.isEmpty else { return }
        registrationTask?.cancel()
        let registration = NowPlayingTokenRegistration(installationID: installationID, token: token,
            sessionID: sessionID, serverURL: serverURL, environment: environment)
        registrationTask = Task { [gateway, sleep] in
            var delay = 1
            var reportedFailure = false
            while !Task.isCancelled {
                do {
                    try await gateway.registerNowPlayingToken(registration)
                    return
                } catch is CancellationError { return }
                catch {
                    if !reportedFailure {
                        // Do not log errors: transport diagnostics can include sensitive data.
                        Logger(subsystem: "xyz.preetz.Louie", category: "NowPlaying")
                            .notice("Now Playing token registration pending; retrying when Home Server is available/configured")
                        reportedFailure = true
                    }
                }
                do { try await sleep(.seconds(delay)) } catch { return }
                delay = min(delay * 2, 60)
            }
        }
    }
}

struct NowPlayingPushIdentity {
    let installationID: String
    let environment: NowPlayingPushEnvironment

    @MainActor
    static func load(bundle: Bundle = .main, defaults: UserDefaults = .standard) -> Self? {
        // Match the signing profile. TestFlight is production, even on a beta OS.
        let configured = bundle.object(forInfoDictionaryKey: "LouieAPNSEnvironment") as? String
        let environment: NowPlayingPushEnvironment
        switch configured {
        case "development", "sandbox": environment = .sandbox
        case "production": environment = .production
        default: return nil
        }
        let key = "louie.nowPlaying.installationID"
        let installation = defaults.string(forKey: key) ?? UUID().uuidString
        defaults.set(installation, forKey: key)
        return Self(installationID: installation, environment: environment)
    }
}
