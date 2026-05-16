//
//  LouieApp.swift
//  Louie
//
//  Created by Timm Preetz on 12.05.26.
//

import Nuke
import SwiftData
import SwiftUI

@main
struct LouieApp: App {
    init() {
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
