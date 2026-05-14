//
//  PlayerBar.swift
//  Louie
//
//  Created by Timm Preetz on 12.05.26.
//

import Linn
import SwiftUI

public struct PlayerBar: View {
    var state: Linn

    @State var isExpanded = true

    public var body: some View {
        HStack {
            HStack(spacing: 6) {
                currentSong
                    .contentShape(Rectangle())
                    .padding(.leading, 35)
                    .padding(.vertical, 10)
                    .padding(.trailing, 35)

                if isExpanded {
                    Spacer()

                    controls.padding(.trailing, 20)
                }
            }

            .glassEffect(.regular.interactive(), in: Capsule())
            .contentShape(Capsule())
            .onTapGesture {
                isExpanded.toggle()
            }

            if !isExpanded {
                Spacer()
            }
        }
        .animation(.snappy(duration: 0.250), value: isExpanded)
    }

    @ViewBuilder
    var currentSong: some View {
        HStack {
            AsyncImage(url: state.currentSong?.artworkURL) { image in
                image.resizable()
            } placeholder: {
                Color.gray
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .frame(width: 40, height: 40)

            ZStack(alignment: .leading) {
                if let song = state.currentSong {
                    VStack(alignment: .leading) {
                        Text(song.title)
                            .font(.caption.bold())
                            .lineLimit(1)
                            .animatedTextChange(id: song.title, limitFrame: isExpanded)

                        if let artist = song.artist {
                            Text(artist)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .animatedTextChange(id: artist, limitFrame: isExpanded)
                        }
                    }
                    .clipped()
                } else {
                    VStack(alignment: .leading) {
                        Text(statusTitle)
                            .font(.caption.bold())
                            .lineLimit(1)
                            .animatedTextChange(id: statusTitle, limitFrame: isExpanded)

                        if let statusSubtitle {
                            Text(statusSubtitle)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .animatedTextChange(id: statusSubtitle, limitFrame: isExpanded)
                        }
                    }
                    .clipped()
                }
            }
        }
    }

    @ViewBuilder
    var controls: some View {
        HStack {
            Button("Previous", systemImage: "backward.fill") {
                state.previous()
            }.disabled(!state.hasPrevious)

            Group {
                if let playState = state.playState {
                    switch playState {
                    case .playing, .paused, .stopped:
                        let symbolName = playState == .playing ? "pause.fill" : "play.fill"
                        Button {
                            state.playPause()

                        } label: {
                            Image(systemName: symbolName)
                        }
                        .buttonStyle(.plain)
                        .contentTransition(.symbolEffect(.replace))
                        .transition(.opacity.combined(with: .scale(scale: 0.85)))

                    case .loading, .buffering:
                        ProgressView().controlSize(.small)
                            .transition(.opacity.combined(with: .scale(scale: 0.85)))
                    }
                } else {
                    Color.clear
                }
            }
            .frame(width: 24, height: 24)

            Button("Next", systemImage: "forward.fill") {
                state.next()
            }

            .disabled(!state.hasNext)
        }
        .tint(.primary)
        .labelStyle(.iconOnly)
        .onTapGesture {
            // ignored; taps on disabled buttons should not collapse the bar
        }
    }

    private var statusTitle: String {
        switch state.connectionState {
        case .idle:
            "No song"
        case .connecting:
            "Connecting"
        case .connected:
            "No song"
        case .failed:
            "Linn unavailable"
        }
    }

    private var statusSubtitle: String? {
        if let message = state.lastErrorMessage {
            return message
        }

        switch state.connectionState {
        case .idle:
            return nil
        case .connecting:
            return "Waiting for gateway"
        case .connected:
            return "No now playing info"
        case let .failed(message):
            return message
        }
    }
}

extension View {
    func animatedTextChange(id: some Hashable, limitFrame: Bool) -> some View {
        self
            .id(id)
            .transition(
                .asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading) // no opacity here, else it disappears right away
                )
            )
            .animation(.snappy(duration: 0.35), value: id)
            .frame(maxWidth: limitFrame ? 300 : nil, alignment: .leading)
    }
}

// MARK: - Previews

#if DEBUG
    private struct PlayerBarHarness: View {
        var linn: Linn

        var body: some View {
            ZStack(alignment: .bottom) {
                background

                PlayerBar(
                    state: linn
                )
                .padding(.bottom, 50)
                .padding(.horizontal, 50)
            }
            .task {
                linn.start()
            }
            .onDisappear {
                linn.stop()
            }
        }

        @ViewBuilder
        private var background: some View {
            LinearGradient(
                colors: [
                    Color.blue.opacity(0.18),
                    Color.purple.opacity(0.12),
                    Color.gray.opacity(0.08),
                    Color.white,
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
        }
    }

    #Preview("Empty") {
        PlayerBarHarness(linn: Linn(mockRoom: "Main Room"))
    }

    #Preview("Playing") {
        PlayerBarHarness(
            linn: Linn(
                mockRoom: "Main Room",
                currentSong: Linn.Song(
                    id: "chainsmoking",
                    title: "Chainsmoking",
                    artist: "Jacob Banks",
                    artworkURL: URL(string: "https://static.qobuz.com/images/covers/mb/x1/brogg6xqdx1mb_230.jpg")
                ),
                playState: .playing,
                hasNext: true
            )
        )
    }

    #Preview("Interactive Demo") {
        PlayerBarHarness(
            linn: Linn(gateway: DemoLinnGateway())
        )
    }

#endif
