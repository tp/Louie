//
//  AlbumArtwork.swift
//  Louie
//
//  Created by Timm Preetz on 15.05.26.
//

import SwiftUI

/// Square image view for the album's artwork, with loading fallback.
struct AlbumArtwork: View {
  let url: URL?

  var body: some View {
    Rectangle()
      .fill(
        LinearGradient(
          colors: [
            Color.gray.opacity(0.18),
            Color.gray.opacity(0.08),
          ],
          startPoint: .topLeading,
          endPoint: .bottomTrailing
        )
      )
      .aspectRatio(1, contentMode: .fill)
      .overlay {
        AsyncImage(url: url) { image in
          if usesBlurredFill {
            ZStack {
              image.resizable()
                .scaledToFill()
                .blur(radius: 8)
                .saturation(1.15)
                .overlay(Color.black.opacity(0.18))

              image.resizable()
                .scaledToFit()
                .aspectRatio(1, contentMode: .fit)
                .scaleEffect(0.9)
            }
          } else {
            image.resizable()
              .scaledToFill()
          }
        } placeholder: {
          Color.clear
        }
      }
      .clipShape(RoundedRectangle(cornerRadius: 6))
  }

  private var usesBlurredFill: Bool {
    url?.absoluteString.contains("_rectangle.") == true
  }
}

private struct ArtworkPlaceholder: View {
  @State private var isActive = false

  var body: some View {
    LinearGradient(
      colors: [
        Color.gray.opacity(0.16),
        Color.gray.opacity(0.08),

      ],
      startPoint: .topLeading,
      endPoint: .bottomTrailing
    )
    .opacity(isActive ? 0.65 : 1.0)
    .animation(
      .easeInOut(duration: 1.2).repeatForever(autoreverses: true),
      value: isActive
    )
    .onAppear {
      isActive = true
    }
  }
}

#if DEBUG
  private struct AlbumArtworkPreview: View {
    let url: URL?

    var body: some View {
      AlbumArtwork(url: url)
        .frame(width: 200, height: 200)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .padding()
    }
  }

  #Preview("None") {
    AlbumArtworkPreview(url: nil)
  }

  #Preview("Square") {
    AlbumArtworkPreview(
      url: URL(string: "https://static.qobuz.com/images/covers/6b/az/trrcz9pvaaz6b_230.jpg"))
  }

  #Preview("Rectangular (Playlist)") {
    AlbumArtworkPreview(
      url: URL(
        string:
          "https://static.qobuz.com/images/playlists/1285072_2bc9b2d5023757d1a8b10db915efd367_rectangle.jpg"
      ))
  }

  #Preview("Placeholder") {
    ArtworkPlaceholder()
  }

#endif
