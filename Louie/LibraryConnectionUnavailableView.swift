import Linn
import SwiftUI

struct LibraryConnectionUnavailableView: View {
    var linn: Linn

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: "wifi.slash")
        } description: {
            Text("The library needs a connection to Linn. It will be available again after reconnecting.")
        }
        .frame(maxWidth: .infinity, minHeight: 240)
        .padding()
    }

    private var title: String {
        switch linn.connectionState {
        case .serverUnreachable: "Home Server Unavailable"
        case .idle, .connecting: "Connecting to Linn"
        default: "Linn Unavailable"
        }
    }
}
