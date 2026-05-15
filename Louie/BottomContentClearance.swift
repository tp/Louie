//
//  BottomContentClearance.swift
//  Louie
//
//  Created by Timm Preetz on 15.05.26.
//

import Linn
import SwiftUI

private struct BottomContentClearanceKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    var bottomContentClearance: CGFloat {
        get { self[BottomContentClearanceKey.self] }
        set { self[BottomContentClearanceKey.self] = newValue }
    }
}

extension View {
    /// Overlays the `PlayerBar` on this view and publishes its measured height
    /// via the `bottomContentClearance` environment value so scroll content
    /// inside can offset itself with `bottomPlayerBarClearance()`.
    func playerBarOverlay(linn: Linn) -> some View {
        modifier(PlayerBarOverlayModifier(linn: linn))
    }

    /// Reserves bottom scroll-content space equal to the current
    /// `bottomContentClearance` so content scrolls clear of the player bar.
    func bottomPlayerBarClearance() -> some View {
        modifier(BottomPlayerBarClearanceModifier())
    }
}

private struct PlayerBarOverlayModifier: ViewModifier {
    let linn: Linn
    @State private var playerBarHeight: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .environment(\.bottomContentClearance, playerBarHeight)
            .overlay(alignment: .bottom) {
                PlayerBar(state: linn)
                    .padding(.horizontal, 50)
                    .padding(.bottom, 8)
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.size.height
                    } action: { height in
                        playerBarHeight = height
                    }
            }
    }
}

private struct BottomPlayerBarClearanceModifier: ViewModifier {
    @Environment(\.bottomContentClearance) private var bottomContentClearance

    func body(content: Content) -> some View {
        content
            .contentMargins(.bottom, bottomContentClearance, for: .scrollContent)
    }
}
