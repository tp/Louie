//
//  LibraryItemDetailView.swift
//  Louie
//
//  Created by Timm Preetz on 15.05.26.
//

import Linn
import SwiftUI

/// Detail surface for browsable library items such as albums, playlists, and folders.
struct LibraryItemDetailView: View {
    var linn: Linn
    var route: LibraryItemRoute

    @State private var state = LibraryItemDetailState()

    private var item: Linn.LibraryItem {
        route.item
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                content
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .bottomPlayerBarClearance()
        .navigationTitle(route.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Enqueue", systemImage: "text.badge.plus") {
                    linn.play(item, placement: .last)
                }

                Button("Play", systemImage: "play.fill") {
                    linn.play(item, placement: .replace)
                }
            }
        }
        .task(id: route.id) {
            await loadItems()
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 18) {
            AlbumArtwork(url: route.artworkURL)
                .frame(width: 128, height: 128)

            VStack(alignment: .leading, spacing: 8) {
                Text(route.title)
                    .font(.title2.weight(.semibold))
                    .lineLimit(3)

                if let subtitle = route.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var content: some View {
        if state.isLoading {
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 160)
        } else if let errorMessage = state.errorMessage {
            ContentUnavailableView {
                Label("Unable to Load", systemImage: "exclamationmark.triangle")
            } description: {
                Text(errorMessage)
            }
            .frame(maxWidth: .infinity, minHeight: 240)
        } else if state.items.isEmpty {
            ContentUnavailableView {
                Label("No Items", systemImage: "music.note.list")
            }
            .frame(maxWidth: .infinity, minHeight: 240)
        } else {
            LazyVStack(spacing: 8) {
                ForEach(state.items) { child in
                    LibraryItemListRow(item: child) {
                        linn.play(child, placement: .replace)
                    }
                }
            }
        }
    }

    private func loadItems() async {
        state.beginLoading()

        do {
            let page = try await linn.browse(item)
            try Task.checkCancellation()
            state.finish(items: page.items)
        } catch is CancellationError {
        } catch {
            state.fail(message: String(describing: error))
        }
    }
}

private struct LibraryItemDetailState: Equatable {
    var items: [Linn.LibraryItem] = []
    var isLoading = false
    var errorMessage: String?

    mutating func beginLoading() {
        isLoading = true
        errorMessage = nil
    }

    mutating func finish(items: [Linn.LibraryItem]) {
        self.items = items
        isLoading = false
        errorMessage = nil
    }

    mutating func fail(message: String) {
        items = []
        isLoading = false
        errorMessage = message
    }
}

private struct LibraryItemListRow: View {
    var item: Linn.LibraryItem
    var play: () -> Void

    var body: some View {
        Button(action: play) {
            HStack(spacing: 12) {
                AlbumArtwork(url: item.artworkURL)
                    .frame(width: 48, height: 48)

                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineLimit(2)

                    if let subtitle = item.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)

                Image(systemName: "play.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                    .background(.quaternary, in: Circle())
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}

#if DEBUG
    #Preview {
        NavigationStack {
            LibraryItemDetailView(
                linn: Linn(gateway: DemoLinnGateway()),
                route: LibraryItemRoute(
                    Linn.LibraryItem(
                        id: "qobuz-favourite-albums",
                        kind: "md.container.qobuz.album",
                        title: "Albums",
                        subtitle: "Qobuz",
                        artworkURL: URL(string: "https://static.qobuz.com/images/covers/kc/95/gvcirtodd95kc_230.jpg"),
                    ),
                ),
            )
        }
    }
#endif
