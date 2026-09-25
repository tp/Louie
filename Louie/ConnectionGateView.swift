//
//  ConnectionGateView.swift
//  Louie
//
//  Holds the app until it can actually reach the gateway: an address is
//  known and (on iOS) local-network permission has been answered. Only then
//  is `Linn` created and started, so the first websocket connect doesn't
//  race the system permission prompt and fail into an error state.
//

import Linn
import SwiftUI

struct ConnectionGateView: View {
    @State private var settings = GatewaySettings()
    @State private var linn: Linn?
    @State private var phase: Phase = .initial
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL

    private enum Phase {
        case initial
        case requestingPermission
        case permissionDenied
        case needsAddress
    }

    var body: some View {
        Group {
            if let linn {
                ContentView(linn: linn)
            } else {
                switch phase {
                case .initial, .requestingPermission:
                    requestingPermission
                case .permissionDenied:
                    permissionDenied
                case .needsAddress:
                    addressForm
                }
            }
        }
        .task {
            await establish()
        }
        .onChange(of: scenePhase) { _, newPhase in
            // Returning from Settings after flipping the toggle.
            guard newPhase == .active, linn == nil, phase == .permissionDenied else {
                return
            }
            Task {
                await establish()
            }
        }
    }

    private func establish() async {
        guard linn == nil else {
            return
        }
        guard settings.configuration != nil else {
            phase = .needsAddress
            return
        }

        #if os(iOS)
            phase = .requestingPermission
            guard await LocalNetworkAuthorization.request() else {
                phase = .permissionDenied
                return
            }
        #endif

        guard let configuration = settings.configuration else {
            phase = .needsAddress
            return
        }
        linn = Linn(configuration: configuration)
    }

    private var requestingPermission: some View {
        VStack(spacing: 14) {
            ProgressView()
            Text("Connecting to your network")
                .font(.headline)
            Text("If iOS asks, allow Louie to find devices on your local network — that's how it reaches your Linn system.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: 420)
        .padding(32)
    }

    private var permissionDenied: some View {
        ContentUnavailableView {
            Label("Local Network Access Needed", systemImage: "wifi.exclamationmark")
        } description: {
            Text("Louie can't reach your Linn system without local network access. Enable it in Settings, then come back here.")
        } actions: {
            #if os(iOS)
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        openURL(url)
                    }
                }
                .buttonStyle(.borderedProminent)
            #endif
            Button("Try Again") {
                Task {
                    await establish()
                }
            }
        }
    }

    private var addressForm: some View {
        Form {
            Section {
                TextField("192.168.1.50", text: $settings.host)
                    .autocorrectionDisabled()
                    #if os(iOS)
                        .keyboardType(.numbersAndPunctuation)
                        .textInputAutocapitalization(.never)
                    #endif
                TextField("Port", value: $settings.port, format: .number.grouping(.never))
            } header: {
                Text("Linn Gateway Address")
            } footer: {
                Text("The IP address or hostname of your CI gateway. Give it a fixed IP (a DHCP reservation in your router) so it doesn't move — Louie stores this address only on this device.")
            }

            Button("Connect") {
                Task {
                    await establish()
                }
            }
            .disabled(settings.configuration == nil)
        }
        .formStyle(.grouped)
        .frame(maxWidth: 560)
        .navigationTitle("Connect to Louie")
    }
}

#if DEBUG
    #Preview("Gate") {
        ConnectionGateView()
    }
#endif
