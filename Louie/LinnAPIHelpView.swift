//
//  LinnAPIHelpView.swift
//  Louie
//
//  Setup help for Linn's CI ("Custom Installation") Gateway API — it is not
//  enabled out of the box, and the first-run experience is finicky enough
//  that the connect screen links here. Steps follow LinnDocs (CI-Gateway).
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
                    Text("Louie uses Linn's CI Gateway — a websocket API that runs on the DSM itself. It's off by default, so a one-time setup is needed. One gateway controls every Linn player in the house.")
                        .foregroundStyle(.secondary)

                    step(1, "Open Manage Systems", "Sign in with your Linn account and select the DS/DSM that should run the gateway.")
                    step(2, "Turn on the CI Gateway", "On the device's Advanced tab, switch CI Gateway on. If the option is missing, update the firmware first (Davaar 100 or later).")
                    step(3, "Reboot the device", "Power-cycle the DSM when prompted. The gateway comes up about 3 minutes after the restart — don't worry if it's not reachable right away.")
                    step(4, "Check it's running", "Open http://<address>:4100 in a browser on the same network. That's the gateway's configuration page; Louie itself connects on port 8088.")
                    step(5, "Connect Louie", "Enter the device's address here, and allow local network access when the system asks — Louie keeps retrying while the prompt is up.")

                    VStack(alignment: .leading, spacing: 10) {
                        Link(destination: manageSystemsURL) {
                            Label("Open Linn Manage Systems", systemImage: "arrow.up.right.square")
                        }
                        Link(destination: docsURL) {
                            Label("CI Gateway documentation", systemImage: "book")
                        }
                    }
                    .font(.callout)

                    Text("No DSM with recent firmware? Kazoo Server on a PC, Mac, or NAS can provide the same Gateway API — it listens on port 4100 instead.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(24)
                .frame(maxWidth: 560, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Enable the Linn API")
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
