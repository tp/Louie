//
//  RealtimeVoiceController.swift
//  Louie
//

import Foundation
import Linn
import OSLog
import Sentry

enum RealtimeVoiceError: LocalizedError {
    case unexpectedClose
    case backend(String)

    var errorDescription: String? {
        switch self {
        case .unexpectedClose: "Realtime voice connection closed."
        case let .backend(message): message
        }
    }
}

@MainActor
@Observable
final class RealtimeVoiceController {
    private(set) var state: VoiceAgentState = .idle

    let fake = HeyLouieFakeState()

    private let linn: Linn?
    private let mediaIDs: HeyLouieMediaIdMap?
    private var sessionTask: Task<Void, Never>?
    private var client: RealtimeVoiceControlClient?
    private var transport: WebRTCRealtimeVoiceTransport?
    private var askUserContinuation: CheckedContinuation<AskUserChoice?, Never>?
    private var sessionTransaction: (any Span)?

    private static let logger = Logger(subsystem: "Louie", category: "RealtimeVoiceController")
    private static let startupAudioBackfillEnabled = true

    init(linn: Linn? = nil) {
        let resolved = HeyLouieFeatureFlags.useLinnForMusic ? linn : nil
        self.linn = resolved
        mediaIDs = resolved == nil ? nil : HeyLouieMediaIdMap()
    }

    func handle(_ event: VoiceAgentEvent) {
        switch event {
        case .tap:
            switch state {
            case .idle, .showingResponse, .failed:
                startSession()
            case .connecting, .listening, .speaking, .recording, .thinking, .runningLocalTool, .askingUser:
                cancelEverything()
                state = .idle
            }
        case let .answerChoice(choice):
            resumeAskUser(choice)
        case .dismissAskUser:
            resumeAskUser(nil)
        case .cancel:
            cancelEverything()
            state = .idle
        }
    }

    private func startSession() {
        cancelEverything()
        state = .listening

        let tx = SentrySDK.startTransaction(
            name: "voice session",
            operation: "app.voice_session",
            bindToScope: true,
        )
        tx.setData(value: "louie", key: "gen_ai.agent.name")
        sessionTransaction = tx

        let transport = WebRTCRealtimeVoiceTransport(
            startupAudioBackfillEnabled: Self.startupAudioBackfillEnabled
        )
        self.transport = transport

        sessionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await runSession(transport: transport)
        }
    }

    private func runSession(transport: WebRTCRealtimeVoiceTransport) async {
        var headers: [String: String] = [:]
        if let span = SentrySDK.span {
            headers["sentry-trace"] = span.toTraceHeader().value()
        }

        let client = RealtimeVoiceControlClient(headers: headers)
        self.client = client
        client.open()

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
                if Task.isCancelled { throw CancellationError() }
                guard let picked else { throw AskUserDismissed() }
                return picked
            },
        )

        do {
            if Self.startupAudioBackfillEnabled {
                let startupCaptureSpan = sessionTransaction?.startChild(
                    operation: "audio.startup_capture",
                    description: "Start local microphone capture for Realtime backfill",
                )
                do {
                    try await transport.startStartupAudioCapture()
                    startupCaptureSpan?.finish()
                } catch is CancellationError {
                    startupCaptureSpan?.finish(status: .cancelled)
                    throw CancellationError()
                } catch {
                    startupCaptureSpan?.finish(status: .internalError)
                    throw error
                }
            }

            let prepareOfferSpan = sessionTransaction?.startChild(
                operation: "webrtc.prepare_offer",
                description: "Configure audio and create local SDP offer",
            )
            let offer: String
            do {
                offer = try await transport.startAndCreateOffer()
                prepareOfferSpan?.finish()
            } catch is CancellationError {
                prepareOfferSpan?.finish(status: .cancelled)
                throw CancellationError()
            } catch {
                prepareOfferSpan?.finish(status: .internalError)
                throw error
            }
            try Task.checkCancellation()
            // Time from sending the offer until the backend returns the SDP
            // answer — the round-trip that sets up the OpenAI realtime session
            // (and pays any cold-start cost). Finished when the answer arrives.
            let awaitAnswerSpan = sessionTransaction?.startChild(
                operation: "backend.await_answer",
                description: "Await SDP answer (backend + OpenAI realtime session setup)",
            )
            try await client.sendHello(
                sessionId: UUID().uuidString,
                sdpOffer: offer,
                tools: HeyLouieSchemas.all,
            )

            let runner = RealtimeVoiceToolRunner(state: fake, linn: linn, mediaIDs: mediaIDs)
            var didApplyAnswer = false
            var didReceiveDone = false

            for try await message in client.messages() {
                try Task.checkCancellation()
                switch message {
                case let .sdpAnswer(sdp, callId):
                    awaitAnswerSpan?.finish()
                    let applyAnswerSpan = sessionTransaction?.startChild(
                        operation: "webrtc.apply_answer",
                        description: "Apply remote SDP answer",
                    )
                    do {
                        try await transport.applyAnswer(sdp)
                        applyAnswerSpan?.finish()
                    } catch is CancellationError {
                        applyAnswerSpan?.finish(status: .cancelled)
                        throw CancellationError()
                    } catch {
                        applyAnswerSpan?.finish(status: .internalError)
                        throw error
                    }
                    let iceConnectSpan = sessionTransaction?.startChild(
                        operation: "webrtc.ice_connect",
                        description: "Await ICE/DTLS connection (audio return channel live)",
                    )
                    do {
                        try await transport.waitUntilConnected()
                        iceConnectSpan?.finish()
                    } catch is CancellationError {
                        iceConnectSpan?.finish(status: .cancelled)
                        throw CancellationError()
                    } catch {
                        iceConnectSpan?.finish(status: .internalError)
                        throw error
                    }
                    if Self.startupAudioBackfillEnabled {
                        let backfillSpan = sessionTransaction?.startChild(
                            operation: "audio.startup_backfill",
                            description: "Send buffered startup audio over Realtime data channel",
                        )
                        do {
                            try await transport.finishStartupAudioBackfillAndEnableLiveMicrophone()
                            backfillSpan?.finish()
                        } catch is CancellationError {
                            backfillSpan?.finish(status: .cancelled)
                            throw CancellationError()
                        } catch {
                            backfillSpan?.finish(status: .internalError)
                            throw error
                        }
                    }
                    didApplyAnswer = true
                    if let callId {
                        sessionTransaction?.setData(value: callId, key: "openai.realtime.call_id")
                    }
                    state = .listening
                case let .toolCall(id, name, inputJSON):
                    if !didApplyAnswer {
                        throw RealtimeVoiceError.backend("Received tool_call before sdp_answer.")
                    }
                    let result = try await runner.runToolCall(
                        id: id,
                        name: name,
                        inputJSON: inputJSON,
                        env: env,
                        parentSpan: sessionTransaction,
                    )
                    try await client.sendToolResult(
                        id: id,
                        content: result.content,
                        isError: result.isError,
                    )
                    state = .listening
                case .done:
                    didReceiveDone = true
                    client.close()
                    self.client = nil
                    state = .idle
                    await transport.finishAfterServerDone()
                    self.transport = nil
                case let .error(message):
                    throw RealtimeVoiceError.backend(message)
                }
            }

            if didReceiveDone {
                finishSession(status: .ok)
            } else if !Task.isCancelled {
                throw RealtimeVoiceError.unexpectedClose
            }
        } catch is CancellationError {
            finishSession(status: .cancelled)
        } catch {
            if !Task.isCancelled {
                state = .failed(error.localizedDescription)
            }
            finishSession(status: .internalError, error: error)
            Self.logger.warning("Realtime voice session failed: \(error.localizedDescription, privacy: .public)")
        }

        closeSessionResources()
    }

    private func resumeAskUser(_ choice: AskUserChoice?) {
        guard let continuation = askUserContinuation else { return }
        askUserContinuation = nil
        continuation.resume(returning: choice)
    }

    private func cancelEverything() {
        sessionTask?.cancel()
        sessionTask = nil
        if let continuation = askUserContinuation {
            askUserContinuation = nil
            continuation.resume(returning: nil)
        }
        if client != nil {
            Task { @MainActor [client] in
                try? await client?.sendCancel()
            }
        }
        closeSessionResources()
        finishSession(status: .cancelled)
    }

    private func closeSessionResources() {
        transport?.close()
        transport = nil
        client?.close()
        client = nil
    }

    private func finishSession(status: SentrySpanStatus, error: Error? = nil) {
        guard let tx = sessionTransaction else { return }
        sessionTransaction = nil
        if let error {
            tx.setData(value: String(describing: error), key: "error")
        }
        tx.finish(status: status)
    }
}
