//
//  HomeView.swift
//  Louie
//
//  Created by Timm Preetz on 15.05.26.
//

import Linn
import SwiftUI

private let homeContentMaxWidth: CGFloat = 720
private let homeContentHorizontalPadding: CGFloat = 20

struct HomeView: View {
    var linn: Linn

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    // iPad (regular size class) has a much smaller system bar than iPhone, so
    // the wordmark header doesn't need to reserve as much top padding.
    private var expandedHeight: CGFloat {
        horizontalSizeClass == .regular ? 130 : 176
    }

    private var collapsedStatusBarBuffer: CGFloat {
        horizontalSizeClass == .regular ? 24 : 50
    }

    var body: some View {
        ScrollView {
            HStack {
                WordmarkViewport(width: 200)

                Spacer()
            }
            .visualEffect { effect, geometry in
                let currentHeight = geometry.size.height
                let scrollOffset = geometry.frame(in: .scrollView).minY
                let positiveOffset = max(0, scrollOffset)
                let stretchResistance: CGFloat = 0.45
                let newHeight = currentHeight + positiveOffset * stretchResistance
                let scaleFactor = newHeight / currentHeight

                return effect.scaleEffect(
                    x: scaleFactor,
                    y: scaleFactor,
                    anchor: .bottomLeading,
                )
            }
            .homeContentColumn()

            VStack(alignment: .leading, spacing: 28) {
                nowPlaying

                if !linn.upcomingSongs.isEmpty {
                    upcoming
                }
            }
            .homeContentColumn()
            .padding(.vertical, 24)
        }
        .bottomPlayerBarClearance()
    }

    private var nowPlaying: some View {
        VStack(alignment: .leading, spacing: 24) {
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
        switch linn.connectionState {
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

private enum WordmarkHeaderMetrics {
    static let collapsedHeight: CGFloat = 82
    static let maxPullGrowth: CGFloat = 14
    static let expandedWidth: CGFloat = 280
    static let collapsedWidth: CGFloat = 190
}

/// Cropped viewport over the current PDF asset.
///
/// The source PDF contains extra whitespace below the letters. Until the asset is
/// recut, this view presents a shorter aspect ratio and shifts the source upward
/// so the visible box hugs the actual wordmark more closely.
private struct WordmarkViewport: View {
    var width: CGFloat

    private let sourceAspectRatio: CGFloat = 595 / 420
    private let visibleAspectRatio: CGFloat = 2.85
    private let verticalCropOffsetRatio: CGFloat = 0.09
    // Shifts the source image left so the wordmark's leading edge lines up with
    // the surrounding content column instead of sitting in the asset's left
    // whitespace.
    private let horizontalCropOffsetRatio: CGFloat = 0.05

    var body: some View {
        let sourceHeight = width / sourceAspectRatio
        let visibleHeight = width / visibleAspectRatio

        Image("Louie Wordmark")
            .resizable()
            .renderingMode(.template)
            .foregroundStyle(.primary)
            .scaledToFit()
            .frame(width: width, height: sourceHeight, alignment: .topLeading)
            .offset(
                x: -width * horizontalCropOffsetRatio,
                y: -width * verticalCropOffsetRatio,
            )
            .frame(width: width, height: visibleHeight, alignment: .topLeading)
            .clipped()
    }
}

private extension View {
    func homeContentColumn() -> some View {
        // Two-stage layout: the inner frame is leading-aligned so small content
        // (e.g. the wordmark) hugs the column's leading edge instead of
        // centering inside it. The outer `.frame(maxWidth: .infinity)` then
        // centers the column itself in its parent — a no-op on iPhone (the cap
        // never kicks in), and on iPad it pulls the column off the leading
        // edge into the middle of the canvas.
        frame(maxWidth: homeContentMaxWidth, alignment: .leading)
            .padding(.horizontal, homeContentHorizontalPadding)
            .frame(maxWidth: .infinity)
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
