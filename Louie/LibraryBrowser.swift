//
//  LibraryBrowser.swift
//  Louie
//
//  Created by Timm Preetz on 14.05.26.
//

import Linn
import SwiftUI

struct LibraryBrowser: View {
    var linn: Linn

    @State private var searchText = ""
    @FocusState private var searchFocused: Bool

    private var isShowingSearch: Bool {
        searchFocused
            || !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ScrollView(.vertical) {
            if isShowingSearch {
                searchContent
            } else {
                libraryStateContent
            }
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .contentMargins(.vertical, 16, for: .scrollContent)
        .bottomPlayerBarClearance()
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always))
        .searchFocused($searchFocused)
        .refreshable {
            linn.refreshLibrary()
        }
        .navigationTitle("Library")
        .navigationBarTitleDisplayMode(.large)
    }

    @ViewBuilder
    private var libraryStateContent: some View {
        switch linn.library.availability {
        case .unavailable:
            unavailableLibraryContent(
                title: "Library Unavailable",
                description: "Connect to the Linn gateway to load your media library.",
            )
        case .loading:
            ProgressView("Loading Library")
                .frame(maxWidth: .infinity, minHeight: 320)
        case .available:
            if hasLibraryContent {
                libraryContent
            } else {
                unavailableLibraryContent(
                    title: "Library Empty",
                    description: "The gateway did not return any library sections.",
                )
            }
        case let .failed(message):
            unavailableLibraryContent(
                title: "Library Unavailable",
                description: message,
            )
        }
    }

    private var hasLibraryContent: Bool {
        linn.library.qobuz.favouriteAlbums != nil
            || linn.library.qobuz.favouriteArtists != nil
            || linn.library.qobuz.favouritePlaylists != nil
            || linn.library.qobuz.myPlaylists != nil
            || !linn.library.qobuz.browseSections.isEmpty
    }

    private var libraryContent: some View {
        LazyVStack(alignment: .leading, spacing: 28) {
            if let albums = linn.library.qobuz.favouriteAlbums {
                mediaSection(albums)
            }

            if let artists = linn.library.qobuz.favouriteArtists {
                mediaSection(artists)
            }

            if let playlists = linn.library.qobuz.favouritePlaylists {
                mediaSection(playlists)
            }

            if let myPlaylists = linn.library.qobuz.myPlaylists {
                mediaSection(myPlaylists)
            }

            ForEach(linn.library.qobuz.browseSections) { section in
                mediaSection(section)
            }
        }
        .scrollTargetLayout()
    }

    private var searchContent: some View {
        LibrarySearchView(linn: linn, query: searchText)
    }

    private func unavailableLibraryContent(title: String, description: String) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: "books.vertical")
        } description: {
            Text(description)
        } actions: {
            Button("Retry", systemImage: "arrow.clockwise") {
                linn.refreshLibrary()
            }
        }
        .frame(maxWidth: .infinity, minHeight: 320)
        .padding(.horizontal, 24)
    }

    private func mediaSection(_ section: Linn.LibrarySection) -> some View {
        Section {
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(section.items) { item in
                        NavigationLink(value: AppDetailRoute.library(.item(LibraryItemRoute(item)))) {
                            LibraryMediaTile(item: item)
                                .containerRelativeFrame(.horizontal, count: 11, span: 2, spacing: 12)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollClipDisabled()
            .contentMargins(.horizontal, 16, for: .scrollContent)
        } header: {
            Text(section.title)
                .font(.headline)
                .padding(.horizontal, 16)
        }
    }
}

private struct LibraryMediaTile: View {
    var item: Linn.LibraryItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AlbumArtwork(url: item.artworkURL)

            Text(item.title)
                .font(.caption)
                .foregroundStyle(.primary)
                .lineLimit(2)

            if let subtitle = item.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

#if DEBUG
    private struct LibraryBrowserPreview: View {
        @State private var linn = Linn(gateway: DemoLinnGateway())

        var body: some View {
            NavigationStack {
                LibraryBrowser(linn: linn)
                    .task {
                        linn.start()
                    }
                    .onDisappear {
                        linn.stop()
                    }
            }
        }
    }

    #Preview {
        LibraryBrowserPreview()
    }
#endif
