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
    @State private var shouldScrollToTopAfterSelection = false

    public var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Color.clear
                    .frame(height: 0)
                    .id(QueueScrollAnchor.top)

                LazyVStack(spacing: 8) {
                    ForEach(linn.upcomingSongs) { song in
                        Button {
                            shouldScrollToTopAfterSelection = true
                            linn.play(song)
                        } label: {
                            QueueListTile(song: song)
                        }
                        .buttonStyle(.plain)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .animation(.snappy(duration: 0.35), value: linn.upcomingSongs.map(\.id))
            }
            .onChange(of: linn.upcomingSongs.map(\.id)) {
                guard shouldScrollToTopAfterSelection else {
                    return
                }

                shouldScrollToTopAfterSelection = false
                withAnimation(.snappy(duration: 0.35)) {
                    proxy.scrollTo(QueueScrollAnchor.top, anchor: .top)
                }
            }
        }
        .navigationTitle("Queue")
    }
}

private enum QueueScrollAnchor {
    case top
}

public struct QueueListTile: View {
    var song: Linn.Song

    public var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: song.artworkURL) { image in
                image.resizable()
            } placeholder: {
                Color.gray
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
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
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(.regularMaterial)
        )
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
                .safeAreaInset(edge: .bottom) {
                    PlayerBar(state: linn)
                        .padding(.horizontal, 50)
                        .padding(.bottom, 8)
                }
        }
    }

    #Preview {
        PlayQueuePreview()
    }
#endif
