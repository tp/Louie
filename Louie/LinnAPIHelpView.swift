//
//  LinnAPIHelpView.swift
//  Louie
//
//  Setup help for the Raspberry Pi server and its Linn CI Gateway connection.
//

import SwiftUI

struct LinnAPIHelpView: View {
    @Environment(\.dismiss) private var dismiss

    private let manageSystemsURL = URL(string: "https://www.linn.co.uk/account/music-systems")!
    private let docsURL = URL(string: "https://docs.linn.co.uk/wiki/index.php/CI-Gateway")!

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Louie Home Server keeps the connection to Linn's CI Gateway. Your devices connect to the home server on the local network.")
                        .foregroundStyle(.secondary)

                    step(1, "Open Manage Systems", "Sign in with your Linn account and select the DS/DSM that should run the gateway.")
                    step(2, "Turn on the CI Gateway", "On the device's Advanced tab, switch CI Gateway on. If the option is missing, update the firmware first (Davaar 100 or later).")
                    step(3, "Reboot the device", "Power-cycle the DSM when prompted. The gateway comes up about 3 minutes after the restart — don't worry if it's not reachable right away.")
                    step(4, "Check Louie Home Server", "SSH to your home server and run systemctl --user status louie.service. Louie connects on port 50051.")
                    step(5, "Connect Louie", "Use your home server's hostname or reserved IP address, and allow local network access when asked.")

                    VStack(alignment: .leading, spacing: 10) {
                        Link(destination: manageSystemsURL) {
                            Label("Open Linn Manage Systems", systemImage: "arrow.up.right.square")
                        }
                        Link(destination: docsURL) {
                            Label("CI Gateway documentation", systemImage: "book")
                        }
                    }
                    .font(.callout)

                    Text("The Linn CI Gateway must be enabled on the DSM for Louie Home Server to observe playback.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(24)
                .frame(maxWidth: 560, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Connect to Louie Home Server")
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        #if os(macOS)
            .frame(minWidth: 500, minHeight: 520)
        #endif
    }

    private func step(_ number: Int, _ title: String, _ body: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(number)")
                .font(.subheadline.weight(.semibold))
                .frame(width: 26, height: 26)
                .background(.tint.quaternary, in: Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(body)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

#if DEBUG
    #Preview {
        LinnAPIHelpView()
    }
#endif
