//
//  VoiceAgent.swift
//  Louie
//
//  Placeholder UI for the server-driven voice agent described in PLAN.md.
//  The state machine here mirrors the protocol surface (recording, tool
//  dispatch, ask-user, final text) so the real backend can later drive these
//  same views without UI changes.
//

import SwiftUI

// MARK: - State model

/// Visible state of the voice agent UI.
///
/// Each case carries exactly what the views need to render — no implicit
/// knowledge. Maps to the iPad-facing messages in PLAN.md:
///
/// - `recording` corresponds to local STT while push-to-talk is held.
/// - `thinking` covers the gap between `utterance` and the first backend
///   reply (`tool_call`, `ask_user`, or `final_text`).
/// - `runningLocalTool` corresponds to a `tool_call` with `local=true`
///   currently executing on the device.
/// - `askingUser` corresponds to a backend-issued `ask_user`.
/// - `showingResponse` corresponds to `final_text`.
/// - `failed` is a client-side capture or recognition failure.
enum VoiceAgentState: Equatable {
    case idle
    case recording
    case thinking
    case runningLocalTool(LocalToolActivity)
    case askingUser(AskUserPrompt)
    case showingResponse(String)
    case failed(String)
}

extension VoiceAgentState {
    /// True while the agent is busy on the server's behalf — the button acts
    /// as a "tap to cancel" affordance in these states.
    var isWaitingOnAgent: Bool {
        switch self {
        case .thinking, .runningLocalTool, .askingUser:
            true
        case .idle, .recording, .showingResponse, .failed:
            false
        }
    }
}

struct LocalToolActivity: Equatable {
    /// Tool identifier, e.g. `play_music`.
    var name: String
    /// Human-readable summary of what the tool is doing right now.
    var summary: String
}

struct AskUserChoice: Equatable, Hashable, Identifiable, Sendable {
    var id: String
    var label: String
}

struct AskUserPrompt: Equatable, Identifiable {
    var id = UUID()
    var question: String
    var choices: [AskUserChoice]
}

/// User-originated events the overlay forwards to its controller.
enum VoiceAgentEvent: Sendable {
    case startRecording
    case stopRecording
    /// User tapped one of the ask-user choices.
    case answerChoice(AskUserChoice)
    /// Popover dismissed without a pick (Cancel button or outside-tap). The
    /// agent resumes with `AskUserDismissed` so the turn can continue with a
    /// `tool_result(is_error=true)` rather than aborting.
    case dismissAskUser
    /// Hard cancel — fired by the FAB while waiting on the agent. Returns
    /// the agent to `.idle` and tears the whole turn down.
    case cancel
}

/// Thrown from `VoiceAgentEnvironment.askUser` when the user dismissed the
/// popover without picking. Distinct from `CancellationError` so the agent
/// can recover (send `tool_result(is_error: true)`) instead of aborting.
struct AskUserDismissed: Error {}

// MARK: - Agent protocol

/// What the controller exposes to a `VoiceAgent` while it processes an
/// utterance: push intermediate state, ask the user a question.
///
/// `askUser` throws `CancellationError` if the user cancels the prompt, so
/// agents can simply `try` it and let cancellation propagate.
@MainActor
struct VoiceAgentEnvironment {
    let publishState: @MainActor (VoiceAgentState) -> Void
    /// Suspends until the user picks one of the choices. Throws
    /// `AskUserDismissed` if the user dismissed the popover, or
    /// `CancellationError` if the whole turn was cancelled.
    let askUser: @MainActor (AskUserPrompt) async throws -> AskUserChoice
}

/// Anything that can act on a transcript. The controller is generic over
/// this so the dummy implementations live alongside the real
/// (WebSocket-backed) one without UI changes.
///
/// Implementations should:
/// - Call `env.publishState(_:)` to surface `runningLocalTool` /
///   `thinking` updates.
/// - Use `try await env.askUser(_:)` to block on a popover answer.
/// - Return the final response text (the controller publishes
///   `.showingResponse` and feeds the text into TTS).
/// - Throw `CancellationError` to abort without leaving a `.failed` banner.
@MainActor
protocol VoiceAgent: AnyObject {
    func handle(utterance: String, in env: VoiceAgentEnvironment) async throws -> String
}

/// Trivial agent: replies with the same text the user spoke. Mirrors the
/// "press to talk, hear it read back" smoke test before any backend lands.
@MainActor
final class EchoVoiceAgent: VoiceAgent {
    func handle(utterance: String, in _: VoiceAgentEnvironment) async throws -> String {
        utterance
    }
}

/// Scripted agent: pretends to look up the utterance, asks the user to
/// disambiguate, and reports a final response. Exercises every UI state.
@MainActor
final class ScriptedVoiceAgent: VoiceAgent {
    func handle(utterance: String, in env: VoiceAgentEnvironment) async throws -> String {
        env.publishState(.runningLocalTool(LocalToolActivity(
            name: "play_music",
            summary: "Looking up “\(utterance)”",
        )))
        try await Task.sleep(for: .seconds(1.5))

        let picked = try await env.askUser(AskUserPrompt(
            question: "Two matches for “\(utterance)”. Which one?",
            choices: [
                AskUserChoice(id: "first", label: "First match"),
                AskUserChoice(id: "second", label: "Second match"),
            ],
        ))

        let choice = picked.label.lowercased()

        env.publishState(.thinking)
        try await Task.sleep(for: .seconds(1))

        return "Playing the \(choice) of “\(utterance)”."
    }
}

// MARK: - Controller

/// Owns the audio capture + state machine. Delegates the "what to do with
/// the transcript" decision to an injected `VoiceAgent`.
///
/// State transitions for `recording → thinking` happen synchronously inside
/// `handle(_:)` so the UI always reflects the user's last action even if
/// capture setup hasn't finished yet (e.g., the permission prompt is
/// pending). The async harvest runs separately and produces either a
/// transcript (handed to the agent) or a `.failed` state.
@MainActor
@Observable
final class VoiceAgentController {
    private(set) var state: VoiceAgentState = .idle

    /// Swap in a different agent at runtime. Used by the interactive
    /// preview to toggle between Echo and Scripted; production code sets it
    /// once at init.
    var agent: any VoiceAgent

    private let capture: any VoiceCapture
    private var setupTask: Task<Void, Error>?
    private var harvestTask: Task<Void, Never>?
    /// Resumes with the picked choice, or `nil` if the user dismissed the
    /// popover. Turn-level cancellation tears down the harvest task instead.
    private var askUserContinuation: CheckedContinuation<AskUserChoice?, Never>?

    init(agent: any VoiceAgent, capture: any VoiceCapture) {
        self.agent = agent
        self.capture = capture
    }

    func handle(_ event: VoiceAgentEvent) {
        switch event {
        case .startRecording:
            switch state {
            case .idle, .showingResponse, .failed:
                beginRecording()
            case .recording, .thinking, .runningLocalTool, .askingUser:
                // Already busy — ignore stray press-downs.
                break
            }
        case .stopRecording:
            if case .recording = state {
                finishRecording()
            }
        case let .answerChoice(choice):
            resumeAskUser(choice)
        case .dismissAskUser:
            // Soft dismiss: resume the continuation with nil so the agent
            // throws AskUserDismissed and recovers the turn. The state will
            // be republished by the agent's next env.publishState call.
            resumeAskUser(nil)
        case .cancel:
            cancelEverything()
            state = .idle
        }
    }

    private func beginRecording() {
        cancelEverything()
        state = .recording

        setupTask = Task { @MainActor [capture] in
            try await capture.startRecording()
        }
    }

    private func finishRecording() {
        let setup = setupTask
        setupTask = nil

        // Flip the UI immediately so the user sees the agent take over the
        // moment they release. The async work below either completes with a
        // transcript or surfaces an error.
        state = .thinking

        harvestTask = Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                try await setup?.value
            } catch is CancellationError {
                return
            } catch {
                if !Task.isCancelled {
                    state = .failed(error.localizedDescription)
                }
                return
            }

            if Task.isCancelled { return }

            let transcript: String
            do {
                transcript = try await capture.stopRecording()
            } catch is CancellationError {
                return
            } catch {
                if !Task.isCancelled {
                    state = .failed(error.localizedDescription)
                }
                return
            }

            if Task.isCancelled { return }

            await runAgent(transcript: transcript)
        }
    }

    private func runAgent(transcript: String) async {
        let env = VoiceAgentEnvironment(
            publishState: { [weak self] state in
                self?.state = state
            },
            askUser: { [weak self] prompt in
                guard let self else { throw CancellationError() }
                state = .askingUser(prompt)
                let picked: AskUserChoice? = await withCheckedContinuation { c in
                    self.askUserContinuation = c
                }
                // Both soft-dismiss and hard-cancel resume the continuation
                // with nil. Check Task.isCancelled to tell them apart: hard
                // cancel cancels the harvest task; soft dismiss does not.
                if Task.isCancelled { throw CancellationError() }
                guard let picked else { throw AskUserDismissed() }
                return picked
            },
        )

        do {
            let response = try await agent.handle(utterance: transcript, in: env)
            if Task.isCancelled { return }
            state = .showingResponse(response)
            capture.speak(response)
        } catch is CancellationError {
            return
        } catch {
            if !Task.isCancelled {
                state = .failed(error.localizedDescription)
            }
        }
    }

    private func resumeAskUser(_ choice: AskUserChoice?) {
        guard let continuation = askUserContinuation else { return }
        askUserContinuation = nil
        continuation.resume(returning: choice)
    }

    private func cancelEverything() {
        setupTask?.cancel()
        setupTask = nil
        harvestTask?.cancel()
        harvestTask = nil
        if let continuation = askUserContinuation {
            askUserContinuation = nil
            continuation.resume(returning: nil)
        }
        capture.cancel()
    }
}

// MARK: - Overlay

/// Pure, state-driven overlay. Owns no agent state of its own so previews can
/// render every case by passing a `state` directly.
struct VoiceAgentOverlay: View {
    var state: VoiceAgentState
    var onEvent: (VoiceAgentEvent) -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: 10) {
            VoiceAgentStatusBanner(state: state)

            VoiceAgentButton(
                state: state,
                onPressChange: { isPressed in
                    onEvent(isPressed ? .startRecording : .stopRecording)
                },
                onCancel: { onEvent(.cancel) },
            )
            .popover(isPresented: askUserBinding, arrowEdge: .bottom) {
                askUserPopover
            }
        }
        .animation(.snappy(duration: 0.25), value: state)
    }

    private var askUserBinding: Binding<Bool> {
        Binding(
            get: {
                if case .askingUser = state { return true }
                return false
            },
            set: { isPresented in
                if !isPresented {
                    // Outside-tap is a soft dismiss; the agent recovers with
                    // a tool_result(is_error=true). Use .cancel only on the
                    // FAB to tear down the whole turn.
                    onEvent(.dismissAskUser)
                }
            },
        )
    }

    @ViewBuilder
    private var askUserPopover: some View {
        if case let .askingUser(prompt) = state {
            AskUserPopover(prompt: prompt, onEvent: onEvent)
        }
    }
}

// MARK: - Status banner

private struct VoiceAgentStatusBanner: View {
    var state: VoiceAgentState

    var body: some View {
        Group {
            if let line = statusLine {
                Text(line.text)
                    .font(.caption)
                    .foregroundStyle(line.tint)
                    .multilineTextAlignment(.trailing)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .frame(maxWidth: 320, alignment: .trailing)
                    .fixedSize(horizontal: false, vertical: true)
                    .glassEffect(.regular, in: Capsule(style: .continuous))
                    .transition(
                        .move(edge: .bottom)
                            .combined(with: .opacity)
                            .combined(with: .scale(scale: 0.9, anchor: .bottomTrailing)),
                    )
            }
        }
    }

    private struct Line {
        var text: String
        var tint: Color
    }

    private var statusLine: Line? {
        switch state {
        case .idle, .askingUser:
            nil
        case .recording:
            Line(text: "Listening…", tint: .primary)
        case .thinking:
            Line(text: "Thinking…", tint: .primary)
        case let .runningLocalTool(activity):
            Line(text: "\(activity.name) · \(activity.summary)", tint: .primary)
        case let .showingResponse(text):
            Line(text: text, tint: .primary)
        case let .failed(message):
            Line(text: message, tint: .red)
        }
    }
}

// MARK: - Floating push-to-talk / cancel button

private struct VoiceAgentButton: View {
    var state: VoiceAgentState
    /// Fires `true` on touch-down and `false` on release while the button is
    /// acting as push-to-talk. The controller decides whether the event is
    /// actionable in the current state.
    var onPressChange: (Bool) -> Void
    /// Fires on tap while the agent is busy (thinking / running tool /
    /// asking user). Same handler used by the ask-user popover's Cancel.
    var onCancel: () -> Void

    @GestureState private var isPressed = false

    var body: some View {
        ZStack {
            buttonContent
        }
        .frame(width: 56, height: 56)
        .glassEffect(.regular.interactive(), in: Circle())
        .overlay {
            ringOverlay
        }
        .scaleEffect(isPressed ? 0.92 : 1.0)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .updating($isPressed) { _, isPressedState, _ in
                    isPressedState = true
                },
        )
        .onChange(of: isPressed) { _, newValue in
            handlePressChange(isDown: newValue)
        }
        .animation(.snappy(duration: 0.15), value: isPressed)
        .animation(.snappy(duration: 0.25), value: state)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(accessibilityHint)
    }

    @ViewBuilder
    private var buttonContent: some View {
        switch state {
        case .idle, .showingResponse, .failed:
            Image(systemName: "mic.fill")
                .font(.title2)
                .foregroundStyle(.primary)
                .transition(.scale.combined(with: .opacity))
        case .recording:
            Image(systemName: "waveform")
                .font(.title2)
                .foregroundStyle(.red)
                .symbolEffect(.variableColor.iterative, options: .repeating)
                .transition(.scale.combined(with: .opacity))
        case .thinking, .runningLocalTool, .askingUser:
            Image(systemName: "waveform")
                .font(.title2)
                .foregroundStyle(.secondary)
                .symbolEffect(.variableColor.iterative, options: .repeating)
                .transition(.scale.combined(with: .opacity))
        }
    }

    @ViewBuilder
    private var ringOverlay: some View {
        switch state {
        case .recording:
            Circle()
                .strokeBorder(.red.opacity(0.6), lineWidth: 2)
                .transition(.opacity)
        case .thinking, .runningLocalTool, .askingUser:
            LoadingRing()
                .transition(.opacity)
        case .idle, .showingResponse, .failed:
            EmptyView()
        }
    }

    private func handlePressChange(isDown: Bool) {
        if state.isWaitingOnAgent {
            // Tap (touch-up) cancels the running agent.
            if !isDown {
                onCancel()
            }
        } else {
            onPressChange(isDown)
        }
    }

    private var accessibilityLabel: String {
        switch state {
        case .idle, .showingResponse, .failed:
            "Push to talk"
        case .recording:
            "Listening, release to send"
        case .thinking:
            "Thinking, tap to cancel"
        case let .runningLocalTool(activity):
            "Running \(activity.name), tap to cancel"
        case .askingUser:
            "Waiting for your answer, tap to cancel"
        }
    }

    private var accessibilityHint: String {
        state.isWaitingOnAgent ? "Tap to cancel." : "Press and hold to talk."
    }
}

/// A continuously-rotating arc, used as the "agent is working" indicator
/// around the floating button.
private struct LoadingRing: View {
    @State private var rotation: Double = 0

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.28)
            .stroke(
                .secondary.opacity(0.7),
                style: StrokeStyle(lineWidth: 2, lineCap: .round),
            )
            .rotationEffect(.degrees(rotation))
            .onAppear {
                withAnimation(.linear(duration: 1.0).repeatForever(autoreverses: false)) {
                    rotation = 360
                }
            }
    }
}

// MARK: - Ask-user popover

private struct AskUserPopover: View {
    var prompt: AskUserPrompt
    var onEvent: (VoiceAgentEvent) -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text(prompt.question)
                .font(.callout)
                .multilineTextAlignment(.center)

            VStack(spacing: 10) {
                ForEach(Array(prompt.choices.enumerated()), id: \.element.id) { index, choice in
                    AskUserChoiceButton(
                        label: choice.label,
                        prominent: index == 0,
                    ) {
                        onEvent(.answerChoice(choice))
                    }
                }

                Button("Cancel", role: .cancel) {
                    onEvent(.dismissAskUser)
                }
                .buttonStyle(.borderless)
                .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
        }
        .padding(20)
        .frame(width: 260)
        .presentationCompactAdaptation(.popover)
    }
}

private struct AskUserChoiceButton: View {
    var label: String
    var prominent: Bool
    var action: () -> Void

    var body: some View {
        if prominent {
            Button(action: action) {
                Text(label).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        } else {
            Button(action: action) {
                Text(label).frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
    }
}

// MARK: - Previews

#if DEBUG
    private struct VoiceAgentPreviewHarness: View {
        var state: VoiceAgentState

        var body: some View {
            ZStack {
                LinearGradient(
                    colors: [
                        .blue.opacity(0.18),
                        .purple.opacity(0.12),
                        .gray.opacity(0.08),
                        .white,
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing,
                )
                .ignoresSafeArea()

                VoiceAgentOverlay(state: state, onEvent: { _ in })
                    .padding(.trailing, 24)
                    .padding(.bottom, 90)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
        }
    }

    #Preview("Idle") {
        VoiceAgentPreviewHarness(state: .idle)
    }

    #Preview("Recording") {
        VoiceAgentPreviewHarness(state: .recording)
    }

    #Preview("Thinking") {
        VoiceAgentPreviewHarness(state: .thinking)
    }

    #Preview("Running tool") {
        VoiceAgentPreviewHarness(
            state: .runningLocalTool(LocalToolActivity(
                name: "play_music",
                summary: "Searching library for 'Chainsmoking'",
            )),
        )
    }

    #Preview("Ask user") {
        VoiceAgentPreviewHarness(
            state: .askingUser(AskUserPrompt(
                question: "Two songs match 'Chainsmoking'. Which one?",
                choices: [
                    AskUserChoice(id: "jacob-banks", label: "Jacob Banks"),
                    AskUserChoice(id: "sirius", label: "Sirius"),
                ],
            )),
        )
    }

    #Preview("Showing response") {
        VoiceAgentPreviewHarness(
            state: .showingResponse(
                "Playing 'Chainsmoking' by Jacob Banks in the living room.",
            ),
        )
    }

    #Preview("Failed") {
        VoiceAgentPreviewHarness(
            state: .failed("Microphone access was denied. Enable it in Settings to use voice."),
        )
    }

    private struct VoiceAgentInteractivePreview: View {
        @State private var controller = VoiceAgentController(
            agent: EchoVoiceAgent(),
            capture: PreviewVoiceCapture(),
        )
        @State private var useScripted = false

        var body: some View {
            ZStack {
                LinearGradient(
                    colors: [
                        .blue.opacity(0.18),
                        .purple.opacity(0.12),
                        .gray.opacity(0.08),
                        .white,
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing,
                )
                .ignoresSafeArea()

                VStack(spacing: 16) {
                    Text("Push and hold the mic to talk. Tap once while the agent is working to cancel.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    Toggle("Scripted agent (tool + ask-user)", isOn: $useScripted)
                        .onChange(of: useScripted) { _, scripted in
                            controller.agent = scripted ? ScriptedVoiceAgent() : EchoVoiceAgent()
                        }
                }
                .padding()
                .frame(maxWidth: 320)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16))
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, 40)

                VoiceAgentOverlay(state: controller.state, onEvent: controller.handle)
                    .padding(.trailing, 24)
                    .padding(.bottom, 90)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
        }
    }

    #Preview("Interactive") {
        VoiceAgentInteractivePreview()
    }
#endif
