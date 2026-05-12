//
//  PlayerBar.swift
//  Louie
//
//  Created by Timm Preetz on 12.05.26.
//

import SwiftUI

public struct PlayerBar: View {
    var state: PlayerState

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
            AsyncImage(url: state.currentSong?.artwork) { image in
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

                        Text(song.artist)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .animatedTextChange(id: song.artist, limitFrame: isExpanded)
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
                    if playState == .paused || playState == .playing {
                        let symbolName = playState == .playing ? "pause.fill" : "play.fill"

                        Button {
                            state.playPause()

                        } label: {
                            Image(systemName: symbolName)
                        }
                        .buttonStyle(.plain)
                        .contentTransition(.symbolEffect(.replace))
                        .transition(.opacity.combined(with: .scale(scale: 0.85)))

                    } else {
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
}

extension View {
    func animatedTextChange(id: some Hashable, limitFrame: Bool) -> some View {
        self
            .id(id)
            .transition(
                .asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading), // no opacity here, else it disappears right away
                ),
            )
            .animation(.snappy(duration: 0.35), value: id)
            .frame(maxWidth: limitFrame ? 300 : nil, alignment: .leading)
    }
}

// MARK: - Previews

#if DEBUG
    extension PlayerState {
        static func empty() -> PlayerState {
            PlayerState()
        }

        static func playing() -> PlayerState {
            let state = PlayerState()
            state.currentSong = Song(title: "Chainsmoking", artist: "Jacob Banks", artwork: URL(string: "https://static.qobuz.com/images/covers/mb/x1/brogg6xqdx1mb_230.jpg"))
            state.hasNext = true
            state.playState = .playing
            return state
        }
    }

    private struct PlayerBarHarness: View {
        var playerState: PlayerState

        var body: some View {
            ZStack(alignment: .bottom) {
                background

                PlayerBar(
                    state: playerState,
                )
                .padding(.bottom, 50)
                .padding(.horizontal, 50)
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
                endPoint: .bottomTrailing,
            )
            .ignoresSafeArea()
        }
    }

    #Preview("Empty") {
        PlayerBarHarness(playerState: .empty())
    }

    #Preview("Playing") {
        PlayerBarHarness(playerState: .playing())
    }

#endif
