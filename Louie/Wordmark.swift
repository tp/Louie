//
//  Wordmark.swift
//  Louie
//

import SwiftUI

/// Cropped viewport over the current PDF asset.
///
/// The source PDF contains extra whitespace below the letters. Until the asset is
/// recut, this view presents a shorter aspect ratio and shifts the source upward
/// so the visible box hugs the actual wordmark more closely.
struct WordmarkViewport: View {
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
