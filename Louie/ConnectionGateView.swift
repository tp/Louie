//
//  ConnectionGateView.swift
//  Louie
//
//  Holds the app until a gateway connection is actually established, driven
//  by Linn's own connection state — no separate permission probe. On first
//  launch the initial connect triggers the iOS local-network prompt; while
//  the user decides, connects fail and this view keeps retrying, so a grant
//  is picked up automatically and the app appears. The address (hostname
//  preferred, IP works too) is stored locally via GatewaySettings.
//

import Linn
import SwiftUI

struct ConnectionGateView: View {
    @State private var settings = GatewaySettings()
    @State private var linn: Linn?
    @State private var hasConnected = false
    @State private var isShowingHelp = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if let linn, hasConnected {
                ContentView(linn: linn)
            } else {
                onboarding
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(white: 0.97).ignoresSafeArea())
            }
        }
        .onAppear {
            if linn == nil, settings.configuration != nil {
                connect()
            }
        }
        .onChange(of: linn?.connectionState) { _, state in
            if state == .connected {
                hasConnected = true
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            // Coming back from Settings or the permission prompt: retry now
            // instead of waiting out the backoff sleep.
            guard newPhase == .active, !hasConnected, let linn else {
                return
            }
            if case .failed = linn.connectionState {
                linn.start()
            }
        }
        .task(id: linn != nil) {
            guard let linn else {
                return
            }
            linn.start()
            while !Task.isCancelled, !hasConnected {
                try? await Task.sleep(for: .seconds(3))
                if case .failed = linn.connectionState {
                    linn.start()
                }
            }
        }
        .sheet(isPresented: $isShowingHelp) {
            LinnAPIHelpView()
        }
    }

    private func connect() {
        guard let configuration = settings.configuration else {
            return
        }
        linn = Linn(configuration: configuration)
    }

    private func changeAddress() {
        linn?.stop()
        linn = nil
    }

    // MARK: - Screens

    private var onboarding: some View {
        VStack(spacing: 28) {
            header

            if linn == nil {
                addressCard
            } else {
                connectingCard
            }

            helpLink
        }
        .padding(28)
        .frame(maxWidth: 440)
    }

    private var header: some View {
        VStack(spacing: 10) {
            WordmarkViewport(width: 180)
                .frame(width: 152, alignment: .center)

            Text("Connect to Linn DSM")
                .font(.title2.weight(.semibold))

            Text("Louie talks to your Linn system over its CI Gateway API on your home network.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var addressCard: some View {
        VStack(spacing: 16) {
            VStack(spacing: 0) {
                TextField("Address, e.g. 192.168.1.50", text: $settings.host)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    #if os(iOS)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                    #endif
                    .padding(14)

                Divider()

                LabeledContent("Port") {
                    TextField("Port", value: $settings.port, format: .number.grouping(.never))
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.trailing)
                        #if os(iOS)
                            .keyboardType(.numberPad)
                        #endif
                }
                .padding(14)
            }
            .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 12))

            Text("The IP address (or hostname) of the Linn DSM running the CI Gateway. If you use an IP, give the device a DHCP reservation in your router so it doesn't move. Stored only on this device.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                connect()
            } label: {
                Text("Connect")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(settings.configuration == nil)
        }
    }

    private var connectingCard: some View {
        VStack(spacing: 16) {
            if let message = failureMessage {
                Label("Can't reach \(displayAddress) yet", systemImage: "wifi.exclamationmark")
                    .font(.headline)

                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .multilineTextAlignment(.center)

                Text("If the system asked about finding devices on your local network, allow it — Louie retries automatically. Also make sure the Linn API is enabled and the address is right.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                ProgressView()
                    .controlSize(.large)

                Text("Connecting to \(displayAddress)…")
                    .font(.headline)

                Text("If the system asks about finding devices on your local network, allow it — that's how Louie reaches your Linn.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 12) {
                if failureMessage != nil {
                    Button("Try Again") {
                        linn?.start()
                    }
                    .buttonStyle(.borderedProminent)

                    #if os(iOS)
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                    #endif
                }

                Button("Change Address") {
                    changeAddress()
                }
            }
        }
    }

    private var helpLink: some View {
        Button {
            isShowingHelp = true
        } label: {
            Label("How do I enable the Linn API?", systemImage: "questionmark.circle")
                .font(.footnote)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tint)
    }

    private var displayAddress: String {
        let trimmedHost = settings.host.trimmingCharacters(in: .whitespaces)
        return trimmedHost.isEmpty ? "the gateway" : trimmedHost
    }

    private var failureMessage: String? {
        if case let .failed(message) = linn?.connectionState {
            return message
        }
        return nil
    }
}

#if DEBUG
    #Preview("Gate") {
        ConnectionGateView()
    }
#endif
