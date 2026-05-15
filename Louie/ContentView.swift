//
//  ContentView.swift
//  Louie
//
//  Created by Timm Preetz on 12.05.26.
//

import Linn
import SwiftUI

struct ContentView: View {
    @State private var linn = Linn()

    var body: some View {
        ContentViewBody(linn: linn)
    }
}

private struct ContentViewBody: View {
    var linn: Linn

    @State private var selectedSection: AppSection? = .home
    @State private var libraryPath: [LibraryRoute] = []

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedSection) {
                NavigationLink(value: AppSection.home) {
                    Label(AppSection.home.title, systemImage: AppSection.home.systemImage)
                }

                Section("Music") {
                    NavigationLink(value: AppSection.library) {
                        Label(AppSection.library.title, systemImage: AppSection.library.systemImage)
                    }

                    queueLink
                }
            }
            .navigationTitle("Louie")
        } detail: {
            detailContent
                .playerBarOverlay(linn: linn)
        }
        .task {
            linn.start()
        }
        .onDisappear {
            linn.stop()
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        switch selectedSection ?? .home {
        case .home:
            NavigationStack {
                HomeView(linn: linn)
            }
        case .library:
            NavigationStack(path: $libraryPath) {
                LibraryBrowser(linn: linn)
                    .navigationDestination(for: LibraryRoute.self) { route in
                        switch route {
                        case let .item(itemRoute):
                            LibraryItemDetailView(linn: linn, route: itemRoute)
                        }
                    }
            }
        case .queue:
            NavigationStack {
                PlayQueue(linn: linn)
            }
        }
    }

    @ViewBuilder
    private var queueLink: some View {
        NavigationLink(value: AppSection.queue) {
            Label(AppSection.queue.title, systemImage: AppSection.queue.systemImage)
        }
        .badge(linn.upcomingSongs.count)
    }
}

#if DEBUG
    private struct ContentViewPreview: View {
        @State private var linn = Linn(gateway: DemoLinnGateway())

        var body: some View {
            ContentViewBody(linn: linn)
        }
    }

    #Preview {
        ContentViewPreview()
    }
#endif
