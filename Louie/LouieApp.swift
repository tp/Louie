//
//  LouieApp.swift
//  Louie
//
//  Created by Timm Preetz on 12.05.26.
//

import Nuke
import Sentry
import SwiftData
import SwiftUI

@main
struct LouieApp: App {
    init() {
        SentrySDK.start { options in
            options.dsn = ProcessInfo.processInfo.environment["SENTRY_DSN"]
                ?? HeyLouieDotEnv.value(forKey: "SENTRY_DSN")
                ?? ""
            options.environment = "development"
            options.tracesSampleRate = 1.0
            options.sendDefaultPii = true
            options.enableNetworkTracking = true
            // Match localhost (LAN dev) + Modal (deployed backend). Without
            // this, the URLSession integration won't propagate trace headers.
            // The actual sentry-trace header on the WS upgrade is injected
            // manually in HeyLouieWebSocketAgent — WS upgrades are not
            // reliably covered by URLSession auto-instrumentation.
            options.tracePropagationTargets = [
                "localhost",
                "127.0.0.1",
                "modal.run",
            ]
        }

        ImagePipeline.shared = ImagePipeline(
            configuration: .withDataCache(
                name: "xyz.timm.preetz.Louie.ArtworkDataCache",
                sizeLimit: 150 * 1024 * 1024,
            ),
        )
    }

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Item.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(sharedModelContainer)
    }
}
