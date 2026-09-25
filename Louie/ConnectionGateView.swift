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
//  With a known address the gate is a quiet splash (wordmark + spinner);
//  the detailed card with troubleshooting only appears when a connection
//  attempt fails or takes suspiciously long. On success the splash wordmark
//  flies into the Home header's wordmark (frame published via
//  WordmarkFramePreferenceKey) before the overlay dissolves.
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
    /// Live global frame of Home's wordmark, once the app has laid out beneath.
    @State private var homeWordmarkFrame: CGRect?
    /// Frame captured at flight start. The live frame drifts while the split
    /// view settles its entrance layout; flying at a moving target redirects
    /// mid-flight and lands beside the real wordmark.
    @State private var flightTargetGlobal: CGRect?
    /// Debounce for "the frame has stopped moving".
    @State private var stabilizeTask: Task<Void, Never>?
    /// Wordmark handoff animation is running (splash → Home position).
    @State private var isFlying = false
    /// Splash background, faded out separately after the wordmark lands.
    @State private var backgroundOpacity = 1.0
    /// Overlay fully dismissed; the app stands alone.
    @State private var overlayDone = false
    @Environment(\.scenePhase) private var scenePhase

    private let splashWordmarkWidth: CGFloat = 180
    private let homeWordmarkWidth: CGFloat = 200

    var body: some View {
        ZStack {
            if let linn, hasConnected {
                ContentView(linn: linn)
                    .onPreferenceChange(WordmarkFramePreferenceKey.self) { frame in
                        homeWordmarkFrame = frame
                        scheduleHandoffWhenStable()
                    }
            }

            if !overlayDone {
                gateOverlay
                    .transition(.opacity)
            }
        }
        .onAppear {
            if linn == nil, settings.configuration != nil {
                connect()
            }
        }
        .onChange(of: linn?.connectionState) { _, state in
            if state == .connected, !hasConnected {
                hasConnected = true
                scheduleHandoffWhenStable()
            }
            if case .failed = state {
                withAnimation(.snappy) {
                    isExpanded = true
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

            // Escalate from splash to the detailed card if connecting takes
            // suspiciously long (permission prompt pending, device booting).
            let escalation = Task {
                do {
                    try await Task.sleep(for: .seconds(5))
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
                    // view is going away). A swallowed `try?` here would fall
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
        stabilizeTask?.cancel()
    }

    /// Kick off the wordmark handoff once Home's wordmark frame has stopped
    /// moving. Every preference change reschedules the debounce, so the task
    /// only fires after 200ms of a stable layout — then the frame is captured
    /// as a constant for the whole flight. Falls back to a plain fade when
    /// the expanded card is showing or Home never reports a frame.
    private func scheduleHandoffWhenStable() {
        guard hasConnected, !isFlying, !overlayDone else {
            return
        }

        if isExpanded {
            withAnimation(.easeOut(duration: 0.3)) {
                overlayDone = true
            }
            return
        }

        stabilizeTask?.cancel()
        stabilizeTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(200))
            } catch {
                return
            }
            guard !isFlying, !overlayDone else {
                return
            }
            if let frame = homeWordmarkFrame {
                beginFlight(to: frame)
                return
            }
            // No frame yet — give Home a little longer; its first report
            // reschedules this task anyway, so reaching the timeout means
            // no frame is coming (different landing view, odd layout).
            do {
                try await Task.sleep(for: .milliseconds(700))
            } catch {
                return
            }
            if !isFlying, !overlayDone {
                withAnimation(.easeOut(duration: 0.3)) {
                    overlayDone = true
                }
            }
        }
    }

    private func beginFlight(to globalFrame: CGRect) {
        flightTargetGlobal = globalFrame
        withAnimation(.smooth(duration: 0.55)) {
            isFlying = true
        } completion: {
            // Fade only the background: the landed wordmark sits pixel-exact
            // on Home's, so the final overlay removal happens without any
            // animation — no second wordmark, no early background reveal.
            withAnimation(.easeOut(duration: 0.22)) {
                backgroundOpacity = 0
            } completion: {
                overlayDone = true
            }
        }
    }

    // MARK: - Overlay

    private var gateOverlay: some View {
        GeometryReader { proxy in
            let localOrigin = proxy.frame(in: .global).origin

            ZStack {
                Color(white: 0.97)
                    .ignoresSafeArea()
                    .opacity(backgroundOpacity)

                if linn == nil {
                    VStack(spacing: 28) {
                        header
                        addressCard
                        helpLink
                    }
                    .padding(28)
                    .frame(maxWidth: 440)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if isExpanded {
                    VStack(spacing: 28) {
                        header
                        connectingCard
                        helpLink
                    }
                    .padding(28)
                    .frame(maxWidth: 440)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    // Splash: wordmark + spinner, nothing else. The wordmark
                    // doubles as the handoff animation subject.
                    let width = proxy.size.width
                    let height = proxy.size.height
                    let restingCenter = CGPoint(x: width / 2, y: height * 0.42)
                    // Fly to the frame captured at flight start, never the
                    // live one — the entrance layout can still be settling.
                    let target = flightTargetGlobal.map { frame in
                        CGRect(
                            x: frame.minX - localOrigin.x,
                            y: frame.minY - localOrigin.y,
                            width: frame.width,
                            height: frame.height
                        )
                    }
                    let flying = isFlying && target != nil
                    let wordmarkWidth = flying ? (target?.width ?? homeWordmarkWidth) : splashWordmarkWidth
                    let center = flying
                        ? CGPoint(x: target!.midX, y: target!.midY)
                        : restingCenter

                    WordmarkViewport(width: wordmarkWidth)
                        .position(center)

                    ProgressView()
                        .controlSize(.large)
                        .position(x: width / 2, y: restingCenter.y + 90)
                        .opacity(hasConnected ? 0 : 1)
                        .animation(.easeOut(duration: 0.15), value: hasConnected)
                }
            }
        }
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
