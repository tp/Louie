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
    /// Reserves bottom scroll-content space equal to the current
    /// `bottomContentClearance` so content scrolls clear of the player bar.
    func bottomPlayerBarClearance() -> some View {
        modifier(BottomPlayerBarClearanceModifier())
    }
}

private struct BottomPlayerBarClearanceModifier: ViewModifier {
    @Environment(\.bottomContentClearance) private var bottomContentClearance

    func body(content: Content) -> some View {
        content
            .contentMargins(.bottom, bottomContentClearance, for: .scrollContent)
    }
}
