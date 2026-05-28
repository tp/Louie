//
//  VoiceAgent.swift
//  Louie
//
//  Placeholder UI for the server-driven voice agent described in PLAN.md.
//  The state machine here mirrors the protocol surface (recording, tool
//  dispatch, ask-user, final text) so the real backend can later drive these
//  same views without UI changes.
//

import Sentry
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
    case connecting
    case listening
    case speaking
    case recording
    case thinking
    case runningLocalTool(LocalToolActivity)
    case askingUser(AskUserPrompt)
    case showingResponse(String)
    case failed(String)
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

/// User-originated events the overlay forwards to its controller. One
/// `.tap` event covers the whole button gesture surface; the controller's
/// state machine decides whether the tap starts listening, ends listening
/// early, or cancels the in-flight turn.
enum VoiceAgentEvent: Sendable {
    case tap
    /// User tapped one of the ask-user choices.
    case answerChoice(AskUserChoice)
    /// Popover dismissed without a pick (Cancel button or outside-tap). The
    /// agent resumes with `AskUserDismissed` so the turn can continue with a
    /// `tool_result(is_error=true)` rather than aborting.
    case dismissAskUser
    /// Hard cancel — fired by the ask-user popover's Cancel button. Returns
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
/// Tap-driven flow: a single `.tap` event starts listening from idle,
/// force-ends an in-progress recording, or cancels a busy turn. The
/// capture's `startRecording(onEvent:)` returns the final transcript when
/// VAD or the user signals end-of-speech; the controller hands that off
/// to the agent and surfaces the response via TTS.
@MainActor
@Observable
final class VoiceAgentController {
    private(set) var state: VoiceAgentState = .idle

    /// Swap in a different agent at runtime. Used by the interactive
    /// preview to toggle between Echo and Scripted; production code sets it
    /// once at init.
    var agent: any VoiceAgent

    let capture: any VoiceCapture
    let synth: any VoiceSynthesizer
    private var listenTask: Task<Void, Never>?
    /// Resumes with the picked choice, or `nil` if the user dismissed the
    /// popover. Turn-level cancellation tears down the listen task instead.
    private var askUserContinuation: CheckedContinuation<AskUserChoice?, Never>?

    /// Sentry transaction for one voice turn. Spans tap-to-listen through
    /// TTS-finish so the trace captures the full user-perceived latency.
    /// Bound to the SDK scope so child spans (and the `sentry-trace`
    /// header in HeyLouieWebSocketAgent) attach to it.
    private var turnTransaction: (any Span)?
    /// Child span around the SpeechAnalyzer wait — kept as a property so
    /// the finish/error path can close it without threading it through
    /// every continuation.
    private var sttSpan: (any Span)?

    /// Per-turn latency trace: tap → recording → mic_hot → speech_started
    /// → speech_ended → transcript. Reset on each accepted tap.
    private let voiceLog = TimedLogger(label: "VOICE", category: "VoiceAgentController")

    init(agent: any VoiceAgent, capture: any VoiceCapture, synth: any VoiceSynthesizer) {
        self.agent = agent
        self.capture = capture
        self.synth = synth
    }

    func handle(_ event: VoiceAgentEvent) {
        switch event {
        case .tap:
            switch state {
            case .idle, .showingResponse, .failed:
                startListening()
            case .recording:
                // Manual VAD override — capture finalizes and the awaiting
                // startRecording returns shortly with the partial transcript.
                voiceLog.event("manual_stop")
                capture.stopRecording()
            case .connecting, .listening, .speaking, .thinking, .runningLocalTool, .askingUser:
                // Tap-to-cancel while the agent is busy.
                cancelEverything()
                state = .idle
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

    private func startListening() {
        cancelEverything()
        state = .recording

        voiceLog.reset()
        voiceLog.event("tap")
        voiceLog.event("recording_state")

        // Open the Sentry transaction here — tap marks the start of
        // user-perceived latency. `bindToScope: true` makes this the active
        // span so HeyLouieWebSocketAgent can pick it up to build the
        // `sentry-trace` header for the WS upgrade.
        let tx = SentrySDK.startTransaction(
            name: "voice turn",
            operation: "app.voice_turn",
            bindToScope: true,
        )
        tx.setData(value: "louie", key: "gen_ai.agent.name")
        turnTransaction = tx
        sttSpan = tx.startChild(operation: "stt", description: "SpeechAnalyzer")

        listenTask = Task { @MainActor [weak self] in
            guard let self else { return }

            let transcript: String
            do {
                transcript = try await capture.startRecording { [weak self] event in
                    guard let self else { return }
                    switch event {
                    case .micHot:
                        voiceLog.event("mic_hot")
                    case .speechStarted:
                        voiceLog.event("speech_started")
                    case .speechEnded:
                        voiceLog.event("speech_ended")
                        // Flip UI as soon as VAD says we're done — final
                        // drain of the transcriber still takes a moment.
                        if case .recording = state {
                            state = .thinking
                        }
                    }
                }
            } catch is CancellationError {
                finishTurn(status: .cancelled)
                return
            } catch {
                if !Task.isCancelled {
                    state = .failed(error.localizedDescription)
                }
                finishTurn(status: .internalError, error: error)
                return
            }

            if Task.isCancelled {
                finishTurn(status: .cancelled)
                return
            }

            voiceLog.event("transcript", detail: transcript)
            // Guarantee `.thinking` even if speechEnded never fired (e.g.
            // empty transcript that returned via timeout).
            if case .recording = state {
                state = .thinking
            }
            sttSpan?.setData(value: transcript, key: "stt.transcript")
            sttSpan?.finish()
            sttSpan = nil

            await runAgent(transcript: transcript)
        }
    }

    /// Closes the active turn transaction with `status` and clears it. STT
    /// span (if still open) is finished first so it doesn't outlive its
    /// parent. Safe to call repeatedly; subsequent calls are no-ops.
    private func finishTurn(status: SentrySpanStatus, error: Error? = nil) {
        if let stt = sttSpan {
            stt.finish(status: status)
            sttSpan = nil
        }
        guard let tx = turnTransaction else { return }
        turnTransaction = nil
        if let error {
            tx.setData(value: String(describing: error), key: "error")
        }
        tx.finish(status: status)
    }

    private func runAgent(transcript: String) async {
        turnTransaction?.setData(value: transcript, key: "gen_ai.prompt")

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
            if Task.isCancelled {
                finishTurn(status: .cancelled)
                return
            }
            turnTransaction?.setData(value: response, key: "gen_ai.response.text")
            state = .showingResponse(response)

            let ttsSpan = turnTransaction?.startChild(
                operation: "tts",
                description: "AVSpeechSynthesizer",
            )
            ttsSpan?.setData(value: response, key: "tts.text")
            await synth.speak(response)
            ttsSpan?.finish()

            finishTurn(status: Task.isCancelled ? .cancelled : .ok)
        } catch is CancellationError {
            finishTurn(status: .cancelled)
        } catch {
            if !Task.isCancelled {
                state = .failed(error.localizedDescription)
            }
            finishTurn(status: .internalError, error: error)
        }
    }

    private func resumeAskUser(_ choice: AskUserChoice?) {
        guard let continuation = askUserContinuation else { return }
        askUserContinuation = nil
        continuation.resume(returning: choice)
    }

    private func cancelEverything() {
        listenTask?.cancel()
        listenTask = nil
        if let continuation = askUserContinuation {
            askUserContinuation = nil
            continuation.resume(returning: nil)
        }
        capture.cancel()
        synth.cancel()
        // Finish the active turn transaction here rather than letting the
        // cancelled listen task do it: the task's cleanup runs after a yield
        // point, by which time a new turn may have replaced `turnTransaction`,
        // and the old task would finish the wrong span.
        finishTurn(status: .cancelled)
    }
}

// MARK: - Overlay

/// Pure, state-driven overlay. Owns no agent state of its own so previews can
/// render every case by passing a `state` directly.
struct VoiceAgentOverlay: View {
    var state: VoiceAgentState
    var onEvent: (VoiceAgentEvent) -> Void

    var body: some View {
        // Button is the only layout-contributing element so the parent
        // (player-bar HStack in ContentView's safeAreaInset) doesn't grow
        // when the status banner appears. Banner floats above as an overlay.
        VoiceAgentButton(
            state: state,
            onTap: { onEvent(.tap) },
        )
        .popover(isPresented: askUserBinding, arrowEdge: .bottom) {
            askUserPopover
        }
        .overlay(alignment: .bottomTrailing) {
            VoiceAgentStatusBanner(state: state)
                .fixedSize() // opt out of the 56pt button width proposal
                .padding(.bottom, 66) // button (56) + spacing (10)
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
        case .connecting:
            Line(text: "Connecting…", tint: .primary)
        case .listening:
            Line(text: "Listening…", tint: .primary)
        case .speaking:
            Line(text: "Speaking…", tint: .primary)
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
    /// Fires on every tap. The controller's state machine decides whether
    /// the tap starts listening, ends recording early, or cancels.
    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            ZStack {
                buttonContent
            }
            .frame(width: 56, height: 56)
            .glassEffect(.regular.interactive(), in: Circle())
            .overlay {
                ringOverlay
            }
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
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
        case .recording, .listening:
            Image(systemName: "waveform")
                .font(.title2)
                .foregroundStyle(.red)
                .symbolEffect(.variableColor.iterative, options: .repeating)
                .transition(.scale.combined(with: .opacity))
        case .connecting, .speaking, .thinking, .runningLocalTool, .askingUser:
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
        case .recording, .listening:
            Circle()
                .strokeBorder(.red.opacity(0.6), lineWidth: 2)
                .transition(.opacity)
        case .connecting, .speaking, .thinking, .runningLocalTool, .askingUser:
            LoadingRing()
                .transition(.opacity)
        case .idle, .showingResponse, .failed:
            EmptyView()
        }
    }

    private var accessibilityLabel: String {
        switch state {
        case .idle, .showingResponse, .failed:
            "Tap to talk"
        case .connecting:
            "Connecting, tap to cancel"
        case .listening:
            "Listening, tap to hang up"
        case .speaking:
            "Speaking, tap to hang up"
        case .recording:
            "Listening, tap to send now"
        case .thinking:
            "Thinking, tap to cancel"
        case let .runningLocalTool(activity):
            "Running \(activity.name), tap to cancel"
        case .askingUser:
            "Waiting for your answer, tap to cancel"
        }
    }

    private var accessibilityHint: String {
        switch state {
        case .idle, .showingResponse, .failed:
            "Tap to start. The system listens until you stop speaking."
        case .connecting:
            "Tap to cancel the connection."
        case .listening, .speaking:
            "Tap to end the voice session."
        case .recording:
            "Tap to stop listening immediately."
        case .thinking, .runningLocalTool, .askingUser:
            "Tap to cancel."
        }
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
        @State private var controller: VoiceAgentController = {
            let voice = PreviewVoice()
            return VoiceAgentController(
                agent: EchoVoiceAgent(),
                capture: voice,
                synth: voice,
            )
        }()

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
                    Text("Tap the mic to start. The system listens until you stop speaking. Tap again to send now or cancel.")
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
