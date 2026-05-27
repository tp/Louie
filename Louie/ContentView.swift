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

    @State private var leadingInset = 0.0
    @State private var playBarHeight = 0.0
    // The concrete agent is held alongside the controller so the debug
    // view can read its `fake` state — `VoiceAgentController.agent` is
    // typed as `any VoiceAgent` and doesn't expose the fake state.
    @State private var heyLouie: HeyLouieWebSocketAgent
    @State private var voiceAgent: VoiceAgentController

    init(linn: Linn) {
        self.linn = linn
        let agent = HeyLouieWebSocketAgent(linn: linn)
        _heyLouie = State(initialValue: agent)
        _voiceAgent = State(initialValue: VoiceAgentController(
            agent: agent,
            capture: LiveVoiceCapture(),
        ))
    }

    @State private var selectedSection: AppSection? = .home
    // Only store `.home(...)` routes here. The outer `AppDetailRoute` wrapper
    // keeps the split-view detail stack's path element type stable.
    @State private var homePath: [AppDetailRoute] = []
    // Only store `.library(...)` routes here. Do not use raw `LibraryRoute`
    // arrays in this split-view detail stack.
    @State private var libraryPath: [AppDetailRoute] = []
    // Only store `.queue(...)` routes here. The shared outer route type avoids
    // `AnyNavigationPath.Error.comparisonTypeMismatch` when switching sections.
    @State private var queuePath: [AppDetailRoute] = []

    var body: some View {
        NavigationSplitView {
            Sidebar(
                remainingQueueCount: linn.remainingQueueCount,
                selectedSection: $selectedSection,
            )
        } detail: {
            ZStack {
                detailContent
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.safeAreaInsets.leading
                    } action: { leadingInset in
                        self.leadingInset = leadingInset
                    }
            }
        }

        .task {
            linn.start()
        }
        .onDisappear {
            linn.stop()
        }
        .environment(\.bottomContentClearance, playBarHeight)
        .safeAreaInset(edge: .bottom) {
          HStack(alignment: .bottom) {
                PlayerBar(state: linn)
                    .padding(.top, 10)
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.size.height
                    } action: { height in
                        playBarHeight = height
                    }
                    .animation(.smooth(duration: 0.25), value: leadingInset)

                VoiceAgentOverlay(
                    state: voiceAgent.state,
                    onEvent: voiceAgent.handle,
                    onTouchDown: voiceAgent.noteTouchDown,
                )
            }
            .padding(.leading, leadingInset)
            .padding(.horizontal)
        }
    }

    private var activeSection: AppSection {
        selectedSection ?? .home
    }

    @ViewBuilder
    private var detailContent: some View {
        switch activeSection {
        case .home:
            NavigationStack(path: sectionPathBinding(.home, path: $homePath)) {
                HomeView(linn: linn)
                    .appDetailNavigationDestinations(linn: linn)
            }
        case .library:
            NavigationStack(path: sectionPathBinding(.library, path: $libraryPath)) {
                LibraryBrowser(linn: linn)
                    .appDetailNavigationDestinations(linn: linn)
            }
        case .queue:
            NavigationStack(path: sectionPathBinding(.queue, path: $queuePath)) {
                PlayQueue(linn: linn)
                    .appDetailNavigationDestinations(linn: linn)
            }
        #if DEBUG
            case .debug:
                NavigationStack {
                    HeyLouieDebugView(state: heyLouie.fake)
                }
        #endif
        }
    }

    private func sectionPathBinding(
        _ section: AppSection,
        path: Binding<[AppDetailRoute]>,
    ) -> Binding<[AppDetailRoute]> {
        Binding {
            path.wrappedValue
        } set: { newPath in
            // When a section stack is removed from the split-view detail column,
            // SwiftUI may write `[]` back through its path binding. Ignore that
            // inactive teardown write so each section keeps its navigation state.
            if activeSection != section, newPath.isEmpty {
                return
            }

            path.wrappedValue = newPath
        }
    }
}

private extension View {
    func appDetailNavigationDestinations(linn: Linn)
        -> some View
    {
        navigationDestination(for: AppDetailRoute.self) { route in
            switch route {
            case .home, .queue:
                EmptyView()
            case let .library(libraryRoute):
                switch libraryRoute {
                case let .item(itemRoute):
                    LibraryItemDetailView(linn: linn, route: itemRoute)
                }
            }
        }
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
