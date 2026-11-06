import Linn
import SwiftUI

struct LinnPowerButton: View {
    var linn: Linn

    var body: some View {
        Button(action: linn.turnOn) {
            if linn.isWaking {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Turning on…")
                }
            } else {
                Label("Turn on Linn", systemImage: "power")
            }
        }
        .buttonStyle(.bordered)
        .disabled(!linn.canWake)
    }
}
