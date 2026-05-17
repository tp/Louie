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
                        Odometer(value: remainingQueueCount)
                            .foregroundStyle(.secondary)
                    }
                }

                .tag(AppSection.queue)
            }
        }
    }
}

private struct RollingBadge: View {
    let count: Int

    var body: some View {
        Text("\(count)")
            .monospacedDigit()
            .contentTransition(.numericText(value: Double(count)))
            .animation(.snappy(), value: count)
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

                Button("1000") {
                    count = 1000
                }

                Button("12345") {
                    count = 12345
                }
            }
        }
    }

    #Preview("RollingBadge comparison") {
        @Previewable @State var count = 11

        VStack(alignment: .trailing, spacing: 20) {
            HStack {
                Spacer()
                Text("\(count)")
                    .monospacedDigit()
                    .font(.system(size: 90, weight: .bold, design: .rounded))
                    .contentTransition(.numericText())
                    .animation(.snappy(), value: count)
            }

            HStack {
                Spacer()
                RollingBadge(count: count)
                    .font(.system(size: 90, weight: .bold, design: .rounded))
            }

            HStack {
                Spacer()
                Odometer(value: count)
                    .font(.system(size: 90, weight: .bold, design: .rounded))
            }

            Button("0") {
                count = 0
            }

            HStack {
                Button("-1") {
                    count = count - 1
                }

                Button("+1") {
                    count = count + 1
                }
            }

            HStack {
                Button("-5") {
                    count = count - 5
                }
                Button("+5") {
                    count = count + 5
                }
            }

            HStack {
                Button("-25") {
                    count = count - 25
                }
                Button("+25") {
                    count = count + 25
                }
            }

            Button("100") {
                count = 100
            }

            Button("1000") {
                count = 1000
            }

            Button("12345") {
                count = 12345
            }
        }
        .frame(width: 350)
    }

#endif
