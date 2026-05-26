//
//  HeyLouieWebSocketAgent.swift
//  Louie
//
//  `VoiceAgent` that drives one push-to-talk turn over a WebSocket to the
//  Hey-Louie backend. Opens a fresh socket per turn, sends `hello` with
//  this iPad's tool catalog, dispatches `tool_call` frames against
//  `HeyLouieToolDispatcher`, and returns `final_text` for the controller
//  to speak. The owning controller handles capture, TTS, state publishing
//  on `.showingResponse`, and Task-cancellation propagation.
//

import Foundation
import Linn
import OSLog
import Sentry

enum HeyLouieAgentError: LocalizedError {
    case backend(String)
    case unexpectedClose

    var errorDescription: String? {
        switch self {
        case let .backend(message): message
        case .unexpectedClose: "Agent connection closed without a response."
        }
    }
}

/// In-code feature flags for the voice agent's local tool implementations.
/// Compile-time toggles, not user-facing settings — flip a value, rebuild.
enum HeyLouieFeatureFlags {
    /// When true, `search_music` queries the real Qobuz library via Linn
    /// and `play_music` starts playback on the configured Linn room.
    /// When false, both fall back to the in-memory `HeyLouieCatalog` and
    /// the iPad-local `HeyLouieFakeState`. Useful for testing the agent
    /// loop without a network or speaker.
    static let useLinnForMusic = true
}

@MainActor
final class HeyLouieWebSocketAgent: VoiceAgent {
    /// Fake state the dispatcher mutates. Exposed read-only-ish to the
    /// debug view; survives across turns for the lifetime of this agent.
    let fake = HeyLouieFakeState()

    private let linn: Linn?
    private let mediaIDs: HeyLouieMediaIdMap?

    init(linn: Linn? = nil) {
        let resolved = HeyLouieFeatureFlags.useLinnForMusic ? linn : nil
        self.linn = resolved
        mediaIDs = resolved == nil ? nil : HeyLouieMediaIdMap()
    }

    private static let logger = Logger(subsystem: "Louie", category: "HeyLouieWebSocketAgent")

    func handle(utterance: String, in env: VoiceAgentEnvironment) async throws -> String {
        // Manually propagate the active Sentry trace onto the WS upgrade
        // request. URLSession auto-instrumentation isn't reliable for
        // WebSocket upgrades across SDK versions, so we set the header
        // ourselves. `baggage` is omitted (we sample at 1.0 on both sides,
        // so cross-service sampling continuity isn't needed yet).
        var headers: [String: String] = [:]
        if let span = SentrySDK.span {
            headers["sentry-trace"] = span.toTraceHeader().value()
        }
        let client = HeyLouieClient(headers: headers)
        client.open()

        do {
            let response = try await runTurn(utterance: utterance, client: client, env: env)
            client.close()
            return response
        } catch is CancellationError {
            try? await client.sendCancel()
            client.close()
            throw CancellationError()
        } catch {
            client.close()
            throw error
        }
    }

    private func runTurn(
        utterance: String,
        client: HeyLouieClient,
        env: VoiceAgentEnvironment,
    ) async throws -> String {
        try await client.sendHello(
            sessionId: UUID().uuidString,
            tools: HeyLouieSchemas.all,
        )
        try await client.sendUtterance(utterance)

        let dispatcher = HeyLouieToolDispatcher(state: fake, linn: linn, mediaIDs: mediaIDs)

        for try await message in client.messages() {
            try Task.checkCancellation()
            switch message {
            case let .toolCall(id, name, inputJSON) where name == "ask_user":
                let (content, isError) = try await runAskUser(inputJSON: inputJSON, env: env)
                try await client.sendToolResult(id: id, content: content, isError: isError)
                env.publishState(.thinking)
            case let .toolCall(id, name, inputJSON):
                env.publishState(.runningLocalTool(LocalToolActivity(
                    name: name,
                    summary: Self.summary(for: name, inputJSON: inputJSON),
                )))
                let (content, isError) = await dispatchSafely(name: name, inputJSON: inputJSON, with: dispatcher)
                try await client.sendToolResult(id: id, content: content, isError: isError)
                env.publishState(.thinking)
            case let .finalText(text):
                return text
            case .cancelled:
                throw CancellationError()
            case let .error(message):
                throw HeyLouieAgentError.backend(message)
            }
        }

        throw HeyLouieAgentError.unexpectedClose
    }

    private func dispatchSafely(
        name: String,
        inputJSON: Data,
        with dispatcher: HeyLouieToolDispatcher,
    ) async -> (content: String, isError: Bool) {
        do {
            let content = try await dispatcher.call(name: name, inputJSON: inputJSON)
            return (content, false)
        } catch {
            Self.logger.warning("Tool \(name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return (error.localizedDescription, true)
        }
    }

    // MARK: - ask_user

    private struct AskUserInputChoice: Decodable {
        let id: String
        let label: String
    }

    private struct AskUserInput: Decodable {
        let question: String
        let choices: [AskUserInputChoice]
    }

    private struct AskUserResult: Encodable {
        let id: String
        let label: String
    }

    /// Suspends until the user picks a choice. On pick returns JSON
    /// `{id, label}`. On soft dismiss returns `is_error=true` so the model
    /// can recover with a graceful narration. CancellationError rethrows so
    /// the outer `handle()` can send `cancel` on the socket and tear down.
    private func runAskUser(
        inputJSON: Data,
        env: VoiceAgentEnvironment,
    ) async throws -> (content: String, isError: Bool) {
        do {
            let input = try JSONDecoder().decode(AskUserInput.self, from: inputJSON)
            guard !input.choices.isEmpty else {
                return ("ask_user requires at least one choice", true)
            }
            let prompt = AskUserPrompt(
                question: input.question,
                choices: input.choices.map { AskUserChoice(id: $0.id, label: $0.label) },
            )
            let picked = try await env.askUser(prompt)
            let payload = try JSONEncoder().encode(AskUserResult(id: picked.id, label: picked.label))
            let content = String(data: payload, encoding: .utf8) ?? "{}"
            return (content, false)
        } catch is AskUserDismissed {
            return ("user dismissed the popover", true)
        } catch {
            Self.logger.warning("ask_user failed: \(error.localizedDescription, privacy: .public)")
            return (error.localizedDescription, true)
        }
    }

    /// Human-readable one-liner for the `runningLocalTool` status banner.
    /// Decodes only the fields needed to render; failures fall back to a
    /// generic label rather than throwing.
    private static func summary(for tool: String, inputJSON: Data) -> String {
        guard let obj = try? JSONSerialization.jsonObject(with: inputJSON) as? [String: Any] else {
            return tool
        }
        switch tool {
        case "search_music":
            let query = obj["query"] as? String ?? ""
            return "Searching for '\(query)'"
        case "play_music":
            let id = obj["id"] as? String ?? ""
            return "Playing \(id)"
        case "control_lights":
            let room = obj["room"] as? String ?? "?"
            return "Lights in \(room)"
        case "set_climate":
            let room = obj["room"] as? String ?? "?"
            let target = obj["target_c"] ?? "?"
            return "Climate in \(room) → \(target)°C"
        case "query_state":
            return "Reading state"
        default:
            return tool
        }
    }
}
