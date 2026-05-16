//
//  LibrarySearchContent.swift
//  Louie
//
//  Created by Timm Preetz on 15.05.26.
//

import Linn
import SwiftUI

struct LibrarySearchView: View {
    var linn: Linn
    var query: String

    @State private var state = LibrarySearchState()

    var body: some View {
        LibrarySearchContent(
            state: state,
            searchType: $state.type,
            enqueue: { item in
                linn.play(item, placement: .last)
            },
            play: { item in
                linn.play(item, placement: .replace)
            },
        )
        .task(id: searchTaskID) {
            await search()
        }
    }

    private var searchTaskID: String {
        "\(state.type.rawValue):\(query)"
    }

    private func search() async {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            state.reset()
            return
        }
        let searchType = state.type

        do {
            try await Task.sleep(for: .milliseconds(350))
            try Task.checkCancellation()
            state.beginLoading()
            let page = try await linn.searchLibrary(query: trimmedQuery, type: searchType)
            try Task.checkCancellation()
            state.finish(query: trimmedQuery, results: page.items)
        } catch is CancellationError {
        } catch {
            state.fail(query: trimmedQuery, message: String(describing: error))
        }
    }
}

struct LibrarySearchState: Equatable {
    var type: Linn.SearchType = .albums
    var results: [Linn.LibraryItem] = []
    var searchedQuery = ""
    var isLoading = false
    var errorMessage: String?

    mutating func reset() {
        results = []
        searchedQuery = ""
        isLoading = false
        errorMessage = nil
    }

    mutating func beginLoading() {
        isLoading = true
        errorMessage = nil
    }

    mutating func finish(query: String, results: [Linn.LibraryItem]) {
        searchedQuery = query
        self.results = results
        isLoading = false
        errorMessage = nil
    }

    mutating func fail(query: String, message: String) {
        searchedQuery = query
        results = []
        isLoading = false
        errorMessage = message
    }
}

struct LibrarySearchContent: View {
    @Binding var searchType: Linn.SearchType
    var state: LibrarySearchState
    var enqueue: (Linn.LibraryItem) -> Void
    var play: (Linn.LibraryItem) -> Void

    init(
        state: LibrarySearchState,
        searchType: Binding<Linn.SearchType>,
        enqueue: @escaping (Linn.LibraryItem) -> Void,
        play: @escaping (Linn.LibraryItem) -> Void,
    ) {
        self.state = state
        _searchType = searchType
        self.enqueue = enqueue
        self.play = play
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 16) {
            Picker("Search Type", selection: $searchType) {
                ForEach(Linn.SearchType.allCases) { type in
                    Text(type.rawValue.capitalized).tag(type)
                }
            }
            .pickerStyle(.menu)
            .padding(.horizontal, 16)

            if state.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else if let errorMessage = state.errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
            } else if !state.searchedQuery.isEmpty, state.results.isEmpty {
                noSearchResults
            } else {
                ForEach(state.results) { item in
                    LibrarySearchResultRow(item: item) {
                        enqueue(item)
                    } play: {
                        play(item)
                    }
                }
            }
        }
    }

    private var noSearchResults: some View {
        ContentUnavailableView {
            Label("No Results", systemImage: "magnifyingglass")
        } description: {
            Text("No \(searchType.rawValue) found for \"\(state.searchedQuery)\".")
        }
        .frame(maxWidth: .infinity, minHeight: 320)
        .padding(.horizontal, 24)
    }
}

struct LibrarySearchResultRow: View {
    var item: Linn.LibraryItem
    var enqueue: () -> Void
    var play: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            NavigationLink(value: AppDetailRoute.library(.item(LibraryItemRoute(item)))) {
                HStack(spacing: 12) {
                    AlbumArtwork(url: item.artworkURL)
                        .frame(width: 56, height: 56)

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
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            HStack(spacing: 8) {
                Button("Enqueue", systemImage: "text.badge.plus", action: enqueue)
                Button("Play", systemImage: "play.fill", action: play)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }
}

#if DEBUG
    private struct LibrarySearchContentPreview: View {
        @State private var state = LibrarySearchState(
            type: .albums,
            results: results,
            searchedQuery: "Billie",
        )

        var body: some View {
            ScrollView {
                LibrarySearchContent(
                    state: state,
                    searchType: $state.type,
                    enqueue: { _ in },
                    play: { _ in },
                )
            }
            .contentMargins(.vertical, 16, for: .scrollContent)
            .navigationDestination(for: AppDetailRoute.self) { route in
                switch route {
                case .home, .queue:
                    EmptyView()
                case let .library(libraryRoute):
                    switch libraryRoute {
                    case let .item(itemRoute):
                        LibraryItemDetailView(linn: Linn(gateway: DemoLinnGateway()), route: itemRoute)
                    }
                }
            }
        }

        private static let results: [Linn.LibraryItem] = [
            Linn.LibraryItem(
                id: "qobuz-album-hit-me-hard-and-soft",
                kind: "md.album.qobuz",
                title: "HIT ME HARD AND SOFT",
                subtitle: "Billie Eilish",
                artworkURL: URL(string: "https://static.qobuz.com/images/covers/kc/95/gvcirtodd95kc_230.jpg"),
            ),
            Linn.LibraryItem(
                id: "qobuz-album-when-we-all-fall-asleep",
                kind: "md.album.qobuz",
                title: "WHEN WE ALL FALL ASLEEP, WHERE DO WE GO?",
                subtitle: "Billie Eilish",
                artworkURL: URL(string: "https://static.qobuz.com/images/covers/gc/eh/wo456u01fehgc_230.jpg"),
            ),
            Linn.LibraryItem(
                id: "qobuz-album-no-time-to-die",
                kind: "md.album.qobuz",
                title: "No Time To Die",
                subtitle: "Billie Eilish",
                artworkURL: URL(string: "https://static.qobuz.com/images/covers/na/po/lmnt8s7cipona_230.jpg"),
            ),
        ]
    }

    #Preview("Search Results") {
        NavigationStack {
            LibrarySearchContentPreview()
                .navigationTitle("Library")
        }
    }

    #Preview("Search Loading") {
        NavigationStack {
            ScrollView {
                LibrarySearchContent(
                    state: LibrarySearchState(isLoading: true),
                    searchType: .constant(.albums),
                    enqueue: { _ in },
                    play: { _ in },
                )
            }
            .contentMargins(.vertical, 16, for: .scrollContent)
            .navigationTitle("Library")
        }
    }

    #Preview("Search Empty") {
        NavigationStack {
            ScrollView {
                LibrarySearchContent(
                    state: LibrarySearchState(searchedQuery: "zzzz"),
                    searchType: .constant(.albums),
                    enqueue: { _ in },
                    play: { _ in },
                )
            }
            .contentMargins(.vertical, 16, for: .scrollContent)
            .navigationTitle("Library")
        }
    }
#endif
