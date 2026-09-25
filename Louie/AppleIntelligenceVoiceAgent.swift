//
//  AppleIntelligenceVoiceAgent.swift
//  Louie
//
//  `VoiceAgent` that runs one push-to-talk turn entirely on-device using
//  Apple's Foundation Models ("siri mode"). Plugs into the same
//  `VoiceAgentController` as the legacy WebSocket agent — the controller still
//  owns capture (Apple STT), TTS (AVSpeechSynthesizer), and the `voice turn`
//  Sentry transaction — so this type only contributes the "thinking" step:
//  a `LanguageModelSession` with locally-authored instructions and the Swift
//  tools in `AppleIntelligenceTools`, which mutate the same `HeyLouieFakeState`
//  as the other modes.
//
//  First cut is single-turn (one request → one spoken response), so `ask_user`
//  is not exposed. The framework auto-runs the tool-call loop inside
//  `respond(to:)`; each tool opens its own `gen_ai.execute_tool` span.
//

import Foundation
import FoundationModels
import Linn
import OSLog
import Sentry

enum AppleIntelligenceAgentError: LocalizedError {
    case modelUnavailable(SystemLanguageModel.Availability)

    var errorDescription: String? {
        switch self {
        case let .modelUnavailable(availability):
            switch availability {
            case .available:
                // Unreachable — we only build this case for the unavailable path.
                "Apple Intelligence is unavailable."
            case let .unavailable(reason):
                switch reason {
                case .deviceNotEligible:
                    "This device doesn't support Apple Intelligence."
                case .appleIntelligenceNotEnabled:
                    "Turn on Apple Intelligence in Settings to use on-device voice."
                case .modelNotReady:
                    "The on-device model is still downloading. Try again shortly."
                @unknown default:
                    "Apple Intelligence is unavailable right now."
                }
            }
        }
    }
}

@MainActor
final class AppleIntelligenceVoiceAgent: VoiceAgent {
    /// Fake state the tools mutate. Exposed read-only-ish to the debug view;
    /// survives across turns for the lifetime of this agent (parity with
    /// `HeyLouieWebSocketAgent.fake`).
    let fake = HeyLouieFakeState()

    private let linn: Linn?
    private let mediaIDs: HeyLouieMediaIdMap?

    /// Reported on the gen_ai spans. Foundation Models doesn't expose a public
    /// model identifier string, so this is a stable label for the dashboards.
    private static let modelName = "apple-on-device"

    private static let logger = Logger(subsystem: "Louie", category: "AppleIntelligenceVoiceAgent")

    /// Locally-authored system prompt. The app has no backend prompt to port
    /// in this mode, so the persona + tool rules live here, distilled from the
    /// load-bearing descriptions in `HeyLouieSchemas`.
    private static let instructions = """
    You are Louie, a calm, concise voice assistant for a home with music, lights, \
    and climate. Your replies are spoken aloud: one short sentence, no markdown, \
    lists, or emoji.

    Use the tools to act, then say plainly what you did — or, just as plainly, what \
    you could NOT do. Honesty is the top priority: never claim a success you didn't \
    achieve, never invent data, and never silently substitute something the user \
    didn't ask for.

    Music:
    - ALWAYS call search_music before play_music.
    - An id is an opaque string from a search_music result. Pass it to play_music \
      ONLY if that exact string appeared in a search_music result. Never invent, \
      guess, or reshape an id, and never pass a raw query or a made-up identifier.
    - If search_music returns an empty list, tell the user you couldn't find it and \
      STOP. Do not call play_music.
    - If search_music returns several hits and the user's words clearly pick one, \
      use it (e.g. "the Thriller album" → the album hit; "play Queen" → the artist \
      hit). But if two or more hits are genuinely plausible and the user was NOT \
      specific (e.g. "play Thriller" could be the song or the album), call ask_user \
      with those hits as the choices instead of guessing — use the search_music hit \
      ids as the choice ids, then play_music the one the user picks.

    Lights & climate: pick a sensible default instead of asking (e.g. a reasonable \
    brightness or temperature) and state what you set. Never use ask_user for which \
    room or what temperature. Rooms are: living_room, kitchen, bedroom. \
    Temperatures are in Celsius.

    State questions like "what's playing?" or "is the kitchen light on?": call \
    query_state first, then answer from its result only.

    If any tool returns an error, or you cannot complete the request, say so in one \
    honest sentence (e.g. "Sorry, I couldn't find the Beatles."). Do not retry with \
    invented data.

    This is a single spoken exchange. The only question you may pose is a \
    tap-to-choose ask_user for genuine ambiguity (above) — never ask the user to \
    repeat or clarify by voice. Then give one final spoken confirmation.
    """

    init(linn: Linn? = nil) {
        let resolved = HeyLouieFeatureFlags.useLinnForMusic ? linn : nil
        self.linn = resolved
        mediaIDs = resolved == nil ? nil : HeyLouieMediaIdMap()
    }

    /// Warms the on-device model off the critical path (call from a `.task`
    /// before the first turn). Best-effort: silently no-ops if unavailable.
    func prewarm() {
        let availability = SystemLanguageModel.default.availability
        guard case .available = availability else {
            // Surface the reason at startup so it's obvious in the logs why
            // siri mode will fall back (e.g. A15 iPad mini → deviceNotEligible).
            Self.logger.warning(
                "On-device model unavailable; siri mode will show a fallback: \(String(describing: availability), privacy: .public)",
            )
            return
        }
        let session = LanguageModelSession(model: .default) { Self.instructions }
        session.prewarm()
        Self.logger.info("On-device model prewarmed.")
    }

    func handle(utterance: String, in env: VoiceAgentEnvironment) async throws -> String {
        let model = SystemLanguageModel.default
        guard case .available = model.availability else {
            Self.logger.warning(
                "Rejecting turn — on-device model unavailable: \(String(describing: model.availability), privacy: .public)",
            )
            throw AppleIntelligenceAgentError.modelUnavailable(model.availability)
        }

        // Parent for the AI-Agents span tree is the active `voice turn`
        // transaction bound to scope by VoiceAgentController.
        let invokeSpan = SentrySDK.span?.startChild(
            operation: "gen_ai.invoke_agent",
            description: "invoke_agent louie",
        )
        invokeSpan?.setData(value: "invoke_agent", key: "gen_ai.operation.name")
        invokeSpan?.setData(value: "louie", key: "gen_ai.agent.name")
        invokeSpan?.setData(value: Self.modelName, key: "gen_ai.request.model")
        invokeSpan?.setData(value: "apple", key: "gen_ai.system")
        invokeSpan?.setData(value: Self.instructions, key: "gen_ai.system_instructions")
        invokeSpan?.setData(value: utterance, key: "gen_ai.input.messages")
        defer { invokeSpan?.finish() }

        let dispatcher = HeyLouieToolDispatcher(state: fake, linn: linn, mediaIDs: mediaIDs)
        let context = AppleIntelligenceToolContext(
            dispatcher: dispatcher,
            publishState: env.publishState,
            askUser: env.askUser,
            parentSpan: invokeSpan,
        )
        let session = LanguageModelSession(
            model: model,
            tools: AppleIntelligenceTools.all(context: context),
        ) {
            Self.instructions
        }

        env.publishState(.thinking)
        Self.logger.info("turn → utterance=\(utterance, privacy: .public)")

        let chatSpan = invokeSpan?.startChild(
            operation: "gen_ai.chat",
            description: "chat \(Self.modelName)",
        )
        chatSpan?.setData(value: "chat", key: "gen_ai.operation.name")
        chatSpan?.setData(value: Self.modelName, key: "gen_ai.request.model")
        chatSpan?.setData(value: Self.modelName, key: "gen_ai.response.model")
        chatSpan?.setData(value: "apple", key: "gen_ai.system")
        chatSpan?.setData(value: utterance, key: "gen_ai.input.messages")

        do {
            try Task.checkCancellation()
            let response = try await session.respond(to: utterance)
            try Task.checkCancellation()
            chatSpan?.setData(value: response.content, key: "gen_ai.output.messages")
            chatSpan?.finish()
            invokeSpan?.setData(value: response.content, key: "gen_ai.output.messages")
            Self.logger.info("turn ← response=\(response.content, privacy: .public)")
            return response.content
        } catch is CancellationError {
            chatSpan?.finish(status: .cancelled)
            throw CancellationError()
        } catch {
            // A hard cancel during an ask_user tap surfaces here wrapped in the
            // framework's tool-call error; treat any cancelled-task failure as a
            // clean cancel so the controller doesn't flash a .failed banner.
            if Task.isCancelled {
                chatSpan?.finish(status: .cancelled)
                throw CancellationError()
            }
            Self.logger.error("On-device generation failed: \(error.localizedDescription, privacy: .public)")
            chatSpan?.setData(value: String(describing: error), key: "error")
            chatSpan?.finish(status: .internalError)
            throw error
        }
    }
}
