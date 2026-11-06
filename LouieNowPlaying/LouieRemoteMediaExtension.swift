import ExtensionFoundation
import LinnNowPlaying
import NowPlaying

@main
nonisolated struct LouieRemoteMediaExtension: RemoteMediaSessionExtension {
    @MainActor var configuration: RemoteMediaSessionExtensionConfiguration<Self> {
        RemoteMediaSessionExtensionConfiguration(extension: self)
    }

    @MainActor func session(_ attributes: LinnSessionAttributes) async throws -> LinnMediaSession {
        let session = LinnMediaSession(attributes: attributes)
        session.startMonitoring()
        return session
    }
}
