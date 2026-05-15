//
//  HomeView.swift
//  Louie
//
//  Created by Timm Preetz on 15.05.26.
//

import Linn
import SwiftUI

struct HomeView: View {
    var linn: Linn

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                nowPlaying

                if !linn.upcomingSongs.isEmpty {
                    upcoming
                }
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 24)
        }
        .bottomPlayerBarClearance()
        .navigationTitle("Home")
        .navigationBarTitleDisplayMode(.large)
    }

    private var nowPlaying: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(greeting)
                .font(.largeTitle.bold())

            HStack(alignment: .center, spacing: 16) {
                AlbumArtwork(url: linn.currentSong?.artworkURL)
                    .frame(width: 96, height: 96)

                VStack(alignment: .leading, spacing: 8) {
                    Text(linn.currentSong?.title ?? statusTitle)
                        .font(.title3.weight(.semibold))
                        .lineLimit(2)

                    if let subtitle = linn.currentSong?.artist ?? statusSubtitle {
                        Text(subtitle)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }

                    playbackControls
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(16)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var playbackControls: some View {
        HStack(spacing: 12) {
            Button("Previous", systemImage: "backward.fill") {
                linn.previous()
            }
            .disabled(!linn.hasPrevious)

            Button(playPauseTitle, systemImage: playPauseSystemImage) {
                linn.playPause()
            }
            .disabled(linn.playState == nil)

            Button("Next", systemImage: "forward.fill") {
                linn.next()
            }
            .disabled(!linn.hasNext)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.bordered)
    }

    private var upcoming: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Up Next")
                .font(.headline)

            ForEach(Array(linn.upcomingSongs.prefix(3))) { song in
                QueueListTile(song: song)
            }
        }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        return switch hour {
        case 5 ..< 12:
            "Good Morning"
        case 12 ..< 18:
            "Good Afternoon"
        default:
            "Good Evening"
        }
    }

    private var playPauseTitle: String {
        linn.playState == .playing ? "Pause" : "Play"
    }

    private var playPauseSystemImage: String {
        linn.playState == .playing ? "pause.fill" : "play.fill"
    }

    private var statusTitle: String {
        return switch linn.connectionState {
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
        if let message = linn.lastErrorMessage {
            return message
        }

        return switch linn.connectionState {
        case .idle:
            nil
        case .connecting:
            "Waiting for gateway"
        case .connected:
            "No now playing info"
        case let .failed(message):
            message
        }
    }
}

#if DEBUG
    private struct HomeViewPreview: View {
        @State private var linn = Linn(gateway: DemoLinnGateway())

        var body: some View {
            NavigationStack {
                HomeView(linn: linn)
            }
            .task {
                linn.start()
            }
            .onDisappear {
                linn.stop()
            }
        }
    }

    #Preview {
        HomeViewPreview()
    }
#endif
