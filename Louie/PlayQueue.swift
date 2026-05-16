//
//  PlayQueue.swift
//  Louie
//
//  Created by Timm Preetz on 14.05.26.
//

import Linn
import SwiftUI

public struct PlayQueue: View {
    var linn: Linn

    @State private var shouldScrollToCurrentOnOpen = true
    @State private var shouldScrollToCurrentAfterSelection = false

    public var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(linn.playlist.songs) { song in
                        Button {
                            shouldScrollToCurrentAfterSelection = true
                            linn.play(song)
                            scrollToSong(song, with: proxy)
                        } label: {
                            QueueListTile(
                                song: song,
                                isCurrent: song.queueIndex == linn.playlist.currentIndex,
                                isPending: song.queueIndex == linn.pendingQueueIndex,
                            )
                        }
                        .id(queueRowID(for: song))
                        .buttonStyle(.plain)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .padding(.vertical, 8)
                .animation(.snappy(duration: 0.35), value: linn.playlist.songs.map(\.id))
            }
            .contentMargins(.horizontal, 20, for: .scrollContent)
            .bottomPlayerBarClearance()
            .onAppear {
                scrollToCurrentIfNeeded(with: proxy, animated: false)
            }
            .onChange(of: linn.playlist.songs.map(\.id)) {
                scrollToCurrentIfNeeded(with: proxy, animated: true)
            }
            .onChange(of: linn.playlist.currentIndex) {
                guard shouldScrollToCurrentAfterSelection else {
                    return
                }

                shouldScrollToCurrentAfterSelection = false
                scrollToCurrentIfNeeded(with: proxy, animated: true, force: true)
            }
        }
        .navigationTitle("Queue")
        .navigationBarTitleDisplayMode(.large)
    }

    private func scrollToSong(_ song: Linn.Song, with proxy: ScrollViewProxy) {
        let id = queueRowID(for: song)
        Task { @MainActor in
            await Task.yield()
            withAnimation(.snappy(duration: 0.35)) {
                proxy.scrollTo(id, anchor: .top)
            }
        }
    }

    private func scrollToCurrentIfNeeded(with proxy: ScrollViewProxy, animated: Bool, force: Bool = false) {
        guard
            force || shouldScrollToCurrentOnOpen || shouldScrollToCurrentAfterSelection,
            let currentIndex = linn.playlist.currentIndex,
            linn.playlist.songs.contains(where: { $0.queueIndex == currentIndex })
        else {
            return
        }

        shouldScrollToCurrentOnOpen = false
        let scroll = {
            proxy.scrollTo(currentIndex, anchor: .top)
        }

        if animated {
            withAnimation(.snappy(duration: 0.35), scroll)
        } else {
            scroll()
        }
    }

    private func queueRowID(for song: Linn.Song) -> Int {
        song.queueIndex ?? song.id.hashValue
    }
}

public struct QueueListTile: View {
    var song: Linn.Song
    var isCurrent = false
    var isPending = false

    public var body: some View {
        HStack(spacing: 12) {
            AlbumArtwork(url: song.artworkURL)
                .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 3) {
                Text(song.title)
                    .font(.body)
                    .lineLimit(1)

                Text(song.artist ?? "")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            ZStack {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tint)
                    .opacity(isCurrent ? 1 : 0)

                ProgressView()
                    .controlSize(.small)
                    .opacity(isPending && !isCurrent ? 1 : 0)
            }
            .frame(width: 24, height: 24)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(.regularMaterial),
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(.tint.opacity(isCurrent || isPending ? 0.45 : 0), lineWidth: 1)
        }
    }
}

#if DEBUG
    private struct PlayQueuePreview: View {
        @State private var linn = Linn(gateway: DemoLinnGateway())

        var body: some View {
            PlayQueue(linn: linn)
                .task {
                    linn.start()
                }
                .onDisappear {
                    linn.stop()
                }
        }
    }

    #Preview {
        PlayQueuePreview()
    }
#endif
