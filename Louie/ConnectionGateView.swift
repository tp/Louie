//
//  ConnectionGateView.swift
//  Louie
//
//  Holds the app until a gateway connection is actually established, driven
//  by Linn's own connection state — no separate permission probe. On first
//  launch the initial connect triggers the iOS local-network prompt; while
//  the user decides, connects fail and this view keeps retrying, so a grant
//  is picked up automatically and the app appears.
//
//  With a known address the gate is a quiet splash — wordmark + spinner,
//  crossfading into the loaded app on success. The detailed card
//  (troubleshooting copy and actions) appears only when connecting exceeds
//  a grace period; transient failures during the permission prompt stay
//  silent while the retry loop works.
//

import Linn
import SwiftUI

struct ConnectionGateView: View {
    @State private var settings = GatewaySettings()
    @State private var linn: Linn?
    @State private var hasConnected = false
    /// Detailed connecting card (error copy + actions) instead of the splash.
    @State private var isExpanded = false
    @State private var isShowingHelp = false
    @State private var revealPhase: GateRevealPhase = .showingSplash
    @Environment(\.scenePhase) private var scenePhase

    private enum GateRevealPhase {
        case showingSplash
        case hidingSplashContent
        case done

        var showsOverlay: Bool {
            self != .done
        }

        var showsSplashContent: Bool {
            self == .showingSplash
        }
    }

    var body: some View {
        Group {
            // ContentView mounts as soon as Linn exists, not on connect: the
            // window chrome (titlebar, toolbar, sidebar toggle) belongs to
            // its NavigationSplitView, and installing it later grows the safe
            // area and pushes everything down mid-reveal. The splash is an
            // overlay of ContentView — same geometry, drawn above it — so
            // the crossfade only ever unveils content, never moves it.
            if let linn {
                ContentView(linn: linn)
                    // A closed window releases its connection. This stays on
                    // the branch, capturing this instance: the Group's
                    // modifiers apply to each branch, and the address screen
                    // disappearing as Linn is created would stop the new one.
                    .onDisappear {
                        linn.stop()
                    }
                    .overlay {
                        if revealPhase.showsOverlay {
                            gateOverlay
                                .transition(.opacity)
                        }
                    }
            } else {
                gateOverlay
            }
        }
        .onAppear {
            if linn == nil, settings.configuration != nil {
                connect()
            }
        }
        .onChange(of: linn?.connectionState) { _, state in
            guard state == .connected, !hasConnected else {
                return
            }
            hasConnected = true
            // Let the app render its first frame beneath the splash, then
            // reveal it in two quick steps: the wordmark fades over the
            // still-solid backdrop first, then the backdrop fades away — so
            // the wordmark is never semi-transparent over app content.
            Task {
                do {
                    try await Task.sleep(for: .milliseconds(200))
                } catch {
                    return
                }
                withAnimation(.easeOut(duration: 0.18)) {
                    revealPhase = .hidingSplashContent
                }
                do {
                    try await Task.sleep(for: .milliseconds(180))
                } catch {
                    return
                }
                withAnimation(.easeInOut(duration: 0.3)) {
                    revealPhase = .done
                }
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

            // Escalate from splash to the detailed card only when connecting
            // takes suspiciously long (permission prompt pending, device
            // booting, wrong address). Transient failures stay silent — the
            // retry loop below keeps working behind the splash.
            let escalation = Task {
                do {
                    try await Task.sleep(for: .seconds(6))
                } catch {
                    return
                }
                if !hasConnected {
                    withAnimation(.snappy) {
                        isExpanded = true
                    }
                }
            }
            defer {
                escalation.cancel()
            }

            while !Task.isCancelled, !hasConnected {
                do {
                    try await Task.sleep(for: .seconds(3))
                } catch {
                    // Cancelled — Change Address swapped `linn` out (or the
                    // view is going away). A swallowed `try?` would fall
                    // through once and restart the Linn we just stopped.
                    return
                }
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
        isExpanded = false
        revealPhase = .showingSplash
    }

    // MARK: - Overlay

    private var gateOverlay: some View {
        ZStack {
            Color(white: 0.97)
                .ignoresSafeArea()

            Group {
                if linn == nil {
                    VStack(spacing: 28) {
                        header
                        addressCard
                        helpLink
                    }
                    .padding(28)
                    .frame(maxWidth: 440)
                } else if isExpanded {
                    VStack(spacing: 28) {
                        header
                        connectingCard
                        helpLink
                    }
                    .padding(28)
                    .frame(maxWidth: 440)
                } else {
                    // Splash: wordmark + spinner, nothing else.
                    VStack(spacing: 36) {
                        WordmarkViewport(width: 180)
                            .frame(width: 152)

                        ProgressView()
                            .controlSize(.large)
                            .opacity(hasConnected ? 0 : 1)
                            .animation(.easeOut(duration: 0.15), value: hasConnected)
                    }
                    .offset(y: -24)
                }
            }
            // Fades ahead of the backdrop during the reveal, so the wordmark
            // (or card) is gone before any app content shows through.
            .opacity(revealPhase.showsSplashContent ? 1 : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Pieces

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

                Text("Still connecting to \(displayAddress)…")
                    .font(.headline)

                Text("If the system asks about finding devices on your local network, allow it — that's how Louie reaches your Linn. After enabling the CI Gateway, the device takes a few minutes to come up.")
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
