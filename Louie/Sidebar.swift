//
//  Sidebar.swift
//  Louie
//
//  Created by Timm Preetz on 16.05.26.
//

import SwiftUI

struct Sidebar: View {
    var remainingQueueCount: Int
    @Binding var selectedSection: AppSection?

    var body: some View {
        // Note on modifier order: `.tag` must be the OUTERMOST modifier on each
        // row. If another row modifier (e.g. `.badge`) wraps `.tag`, the
        // `List(selection:)` binding requires two taps to switch to that row —
        // the first tap clears the prior selection without committing the new
        // one. Keep `.tag` last on every row, even rows without other modifiers,
        // so this stays consistent if a `.badge` (or similar) is added later.
        List(selection: $selectedSection) {
            Label(AppSection.home.title, systemImage: AppSection.home.systemImage)
                .tag(AppSection.home)

            Section("Music") {
                Label(AppSection.library.title, systemImage: AppSection.library.systemImage)
                    .tag(AppSection.library)

                HStack {
                    Label(AppSection.queue.title, systemImage: AppSection.queue.systemImage)

                    Spacer()

                    if remainingQueueCount > 0 {
                        RollingBadge(count: remainingQueueCount)
                            .foregroundStyle(.secondary)
                    }
                }

                .tag(AppSection.queue)
            }
        }
        .navigationTitle("Louie")
    }
}

private struct RollingBadge: View {
    let count: Int

    var body: some View {
        Text("\(count)")

            .monospacedDigit()
            .contentTransition(.numericText())
            .animation(.snappy, value: count)
    }
}

#if DEBUG

    #Preview("Sidebar") {
        @Previewable @State var count = 15
        @Previewable @State var section: AppSection? = AppSection.home

        NavigationSplitView {
            Sidebar(remainingQueueCount: count, selectedSection: $section)
        } detail: {
            HStack(spacing: 20) {
                Button("0") {
                    count = 0
                }

                Button("+") {
                    count = count + 1
                }

                Button("-") {
                    count = count - 1
                }

                Button("100") {
                    count = 100
                }
            }
        }
    }
#endif
