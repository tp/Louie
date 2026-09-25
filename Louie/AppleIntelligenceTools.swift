//
//  AppleIntelligenceTools.swift
//  Louie
//
//  Bridges the Hey-Louie tool catalog to Apple's on-device Foundation Models.
//  Each `Tool` conformer mirrors one entry in `HeyLouieSchemas.all`: the
//  `@Generable Arguments` struct and its `@Guide` descriptions stand in for
//  the JSON Schema the backend receives, and `call(arguments:)` re-encodes the
//  model's structured arguments into the exact JSON the shared
//  `HeyLouieToolDispatcher` already knows how to execute. Keeping the dispatcher
//  as the single execution path means the on-device "siri mode" mutates the
//  same `HeyLouieFakeState` and returns the same result shapes as the WebSocket
//  and realtime modes — only the inference engine differs.
//
//  `ask_user` is intentionally omitted: the first cut is single-turn (one
//  request → one spoken response) with no mid-turn disambiguation. Adding it
//  later is straightforward — a tool whose `call` awaits `env.askUser` via the
//  controller's existing popover.
//

import Foundation
import FoundationModels
import OSLog
import Sentry

/// Main-actor execution context shared by every on-device tool for one turn.
///
/// Tools are `Sendable` value types (the `Tool` protocol requires it), so they
/// can't touch the `@MainActor` dispatcher directly. They encode their typed
/// arguments to JSON `Data` (Sendable) in their `nonisolated` `call`, then hop
/// here to run them. This object also owns the `gen_ai.execute_tool` Sentry
/// span and drives the `runningLocalTool` UI state.
@MainActor
final class AppleIntelligenceToolContext {
    private let dispatcher: HeyLouieToolDispatcher
    private let publishState: @MainActor (VoiceAgentState) -> Void
    /// Suspends until the user taps a choice in the disambiguation popover.
    /// Throws `AskUserDismissed` on soft-dismiss, `CancellationError` on a hard
    /// cancel — same contract the controller gives every `VoiceAgent`.
    private let askUserHandler: @MainActor (AskUserPrompt) async throws -> AskUserChoice
    /// `gen_ai.invoke_agent` span; tool spans hang off it (siblings of the
    /// `gen_ai.chat` span) to match Sentry's AI-Agents hierarchy.
    private let parentSpan: (any Span)?

    private static let logger = Logger(subsystem: "Louie", category: "AppleIntelligenceTools")

    init(
        dispatcher: HeyLouieToolDispatcher,
        publishState: @escaping @MainActor (VoiceAgentState) -> Void,
        askUser: @escaping @MainActor (AskUserPrompt) async throws -> AskUserChoice,
        parentSpan: (any Span)?,
    ) {
        self.dispatcher = dispatcher
        self.publishState = publishState
        askUserHandler = askUser
        self.parentSpan = parentSpan
    }

    /// Runs one tool call against the shared dispatcher. Never throws: a failed
    /// tool returns its error text so the model can recover and narrate
    /// gracefully (mirrors `HeyLouieWebSocketAgent.dispatchSafely`).
    func execute(name: String, argumentsJSON: Data, summary: String) async -> String {
        publishState(.runningLocalTool(LocalToolActivity(name: name, summary: summary)))

        let argumentsText = jsonString(argumentsJSON)
        // Mirror the gen_ai.execute_tool span locally so every tool call shows
        // in the console too, not just in Sentry.
        Self.logger.info("tool call → \(name, privacy: .public) args=\(argumentsText, privacy: .public)")

        let span = parentSpan?.startChild(
            operation: "gen_ai.execute_tool",
            description: "execute_tool \(name)",
        )
        span?.setData(value: "execute_tool", key: "gen_ai.operation.name")
        span?.setData(value: name, key: "gen_ai.tool.name")
        span?.setData(value: argumentsText, key: "gen_ai.tool.call.arguments")
        defer { span?.finish() }

        do {
            let result = try await dispatcher.call(name: name, inputJSON: argumentsJSON)
            span?.setData(value: result, key: "gen_ai.tool.call.result")
            Self.logger.info("tool result ← \(name, privacy: .public) \(result, privacy: .public)")
            publishState(.thinking)
            return result
        } catch {
            let message = error.localizedDescription
            Self.logger.warning("tool failed ← \(name, privacy: .public) \(message, privacy: .public)")
            span?.setData(value: message, key: "gen_ai.tool.call.result")
            span?.setData(value: true, key: "gen_ai.tool.is_error")
            // Surface the error to the model rather than aborting the turn.
            publishState(.thinking)
            return message
        }
    }

    /// Suspends the turn on the tap-to-choose popover and returns the picked
    /// `{id, label}` as JSON. On soft-dismiss, returns a recovery instruction
    /// (mirrors `HeyLouieWebSocketAgent.runAskUser`) so the model ends politely
    /// instead of guessing. A hard cancel propagates as `CancellationError`.
    func askUser(question: String, choices: [AskUserChoice]) async throws -> String {
        let argumentsText = jsonString(question: question, choices: choices)
        Self.logger.info("tool call → ask_user args=\(argumentsText, privacy: .public)")

        let span = parentSpan?.startChild(
            operation: "gen_ai.execute_tool",
            description: "execute_tool ask_user",
        )
        span?.setData(value: "execute_tool", key: "gen_ai.operation.name")
        span?.setData(value: "ask_user", key: "gen_ai.tool.name")
        span?.setData(value: argumentsText, key: "gen_ai.tool.call.arguments")
        defer { span?.finish() }

        guard !choices.isEmpty else {
            let message = "ask_user requires at least one choice"
            span?.setData(value: message, key: "gen_ai.tool.call.result")
            span?.setData(value: true, key: "gen_ai.tool.is_error")
            return message
        }

        do {
            let picked = try await askUserHandler(AskUserPrompt(question: question, choices: choices))
            publishState(.thinking) // dismiss the popover promptly after the tap
            let result = jsonString(object: ["id": picked.id, "label": picked.label])
            span?.setData(value: result, key: "gen_ai.tool.call.result")
            Self.logger.info("tool result ← ask_user \(result, privacy: .public)")
            return result
        } catch is AskUserDismissed {
            publishState(.thinking)
            let message = "User dismissed the disambiguation without choosing. Do NOT retry "
                + "or fall back to a default — end the turn with a brief acknowledgement "
                + "like 'OK, never mind.'"
            span?.setData(value: message, key: "gen_ai.tool.call.result")
            span?.setData(value: true, key: "gen_ai.tool.is_error")
            Self.logger.info("tool result ← ask_user dismissed")
            return message
        }
        // CancellationError intentionally propagates: a hard cancel tears the
        // whole turn down rather than letting the model narrate.
    }

    private func jsonString(_ data: Data) -> String {
        String(data: data, encoding: .utf8) ?? "{}"
    }

    private func jsonString(object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return "{}" }
        return jsonString(data)
    }

    private func jsonString(question: String, choices: [AskUserChoice]) -> String {
        jsonString(object: [
            "question": question,
            "choices": choices.map { ["id": $0.id, "label": $0.label] },
        ])
    }
}

/// Builds the on-device tool set for one turn, all sharing `context`.
enum AppleIntelligenceTools {
    static func all(context: AppleIntelligenceToolContext) -> [any Tool] {
        [
            SearchMusicTool(context: context),
            PlayMusicTool(context: context),
            ControlLightsTool(context: context),
            SetClimateTool(context: context),
            QueryStateTool(context: context),
            AskUserTool(context: context),
        ]
    }
}

// MARK: - search_music

struct SearchMusicTool: Tool {
    let context: AppleIntelligenceToolContext

    let name = "search_music"
    let description = """
    Find a playable music id for a user's request before calling play_music. \
    Use this for any phrase that names a genre, artist, album, song, or playlist \
    (e.g. 'jazz', 'Queen', 'Thriller', 'something ambient'). Returns a JSON array \
    of hits, each shaped {id, type, title}. The `id` is opaque — pass it verbatim \
    to play_music. If the array is empty, tell the user you couldn't find it; do \
    not invent ids. If multiple hits come back, pick the one whose type and title \
    clearly match what the user said.
    """

    @Generable
    struct Arguments {
        @Guide(description: "The user's phrasing, lightly normalized. E.g. 'jazz', 'Thriller', 'Queen'.")
        var query: String
        @Guide(description: "Optional filter, one of: artist, album, genre, playlist, track. Omit when the user was vague.")
        var type: String?
    }

    func call(arguments: Arguments) async throws -> String {
        var object: [String: Any] = ["query": arguments.query]
        if let type = arguments.type { object["type"] = type }
        let data = try JSONSerialization.data(withJSONObject: object)
        return await context.execute(
            name: name,
            argumentsJSON: data,
            summary: "Searching for '\(arguments.query)'",
        )
    }
}

// MARK: - play_music

struct PlayMusicTool: Tool {
    let context: AppleIntelligenceToolContext

    let name = "play_music"
    let description = """
    Start playback of a specific item. The `id` argument MUST be a value returned \
    from a prior search_music call in this turn — do not synthesize ids, do not pass \
    raw queries like 'jazz'. If you don't have an id yet, call search_music first.
    """

    @Generable
    struct Arguments {
        @Guide(description: "An opaque id from search_music, shaped like '$id:<type>:<slug>'.")
        var id: String
    }

    func call(arguments: Arguments) async throws -> String {
        let data = try JSONSerialization.data(withJSONObject: ["id": arguments.id])
        return await context.execute(
            name: name,
            argumentsJSON: data,
            summary: "Playing \(arguments.id)",
        )
    }
}

// MARK: - control_lights

struct ControlLightsTool: Tool {
    let context: AppleIntelligenceToolContext

    let name = "control_lights"
    let description = """
    Turn a room's lights on or off, set brightness, or both. At least one of `on` \
    or `brightness` is required. Passing brightness > 0 without `on` is treated as \
    'turn it on at that level'. Available rooms: living_room, kitchen, bedroom.
    """

    @Generable
    struct Arguments {
        @Guide(description: "The room whose lights to control, one of: living_room, kitchen, bedroom.")
        var room: String
        @Guide(description: "True to turn on, false to turn off. Optional.")
        var on: Bool?
        @Guide(description: "Brightness percentage, 0-100. Optional.")
        var brightness: Int?
    }

    func call(arguments: Arguments) async throws -> String {
        var object: [String: Any] = ["room": arguments.room]
        if let on = arguments.on { object["on"] = on }
        if let brightness = arguments.brightness { object["brightness"] = brightness }
        let data = try JSONSerialization.data(withJSONObject: object)
        return await context.execute(
            name: name,
            argumentsJSON: data,
            summary: "Lights in \(arguments.room)",
        )
    }
}

// MARK: - set_climate

struct SetClimateTool: Tool {
    let context: AppleIntelligenceToolContext

    let name = "set_climate"
    let description = """
    Set a room's target temperature in degrees Celsius. Assume Celsius unless the \
    user explicitly says Fahrenheit (in which case convert before calling). \
    Reasonable range is 5-35°C.
    """

    @Generable
    struct Arguments {
        @Guide(description: "The room whose climate to set, one of: living_room, kitchen, bedroom.")
        var room: String
        @Guide(description: "Target temperature in Celsius, between 5 and 35.")
        var targetC: Double
    }

    func call(arguments: Arguments) async throws -> String {
        // Snake-case key (`target_c`) matches the dispatcher's decoder.
        let data = try JSONSerialization.data(withJSONObject: [
            "room": arguments.room,
            "target_c": arguments.targetC,
        ])
        return await context.execute(
            name: name,
            argumentsJSON: data,
            summary: "Climate in \(arguments.room) → \(arguments.targetC)°C",
        )
    }
}

// MARK: - query_state

struct QueryStateTool: Tool {
    let context: AppleIntelligenceToolContext

    let name = "query_state"
    let description = """
    Read the current state of the house. Use this before answering questions like \
    'what's playing?', 'is the kitchen light on?', 'what's the bedroom set to?'. \
    Returns a JSON snapshot. Prefer the narrowest subsystem for the question; use \
    'all' only when the user asked for a broad status.
    """

    @Generable
    struct Arguments {
        @Guide(description: "Which subsystem to read, one of: music, lights, climate, all. Default 'all'.")
        var subsystem: String?
    }

    func call(arguments: Arguments) async throws -> String {
        var object: [String: Any] = [:]
        if let subsystem = arguments.subsystem { object["subsystem"] = subsystem }
        let data = try JSONSerialization.data(withJSONObject: object)
        return await context.execute(
            name: name,
            argumentsJSON: data,
            summary: "Reading state",
        )
    }
}

// MARK: - ask_user

/// Tap-to-choose disambiguation. Unlike the other tools this one doesn't go
/// through the dispatcher — it drives the controller's existing popover via
/// `context.askUser`, suspending the turn until the user picks (or dismisses).
/// Description mirrors `HeyLouieSchemas`' `ask_user` (the backend contract).
struct AskUserTool: Tool {
    let context: AppleIntelligenceToolContext

    let name = "ask_user"
    let description = """
    Ask the user to disambiguate between concrete options when their request is \
    genuinely ambiguous AND picking the wrong default would noticeably annoy them. \
    The user sees a tap popover with the choices you provide; the result is the \
    picked {id, label}. USE SPARINGLY — prefer confident action with a one-sentence \
    narration over asking. Never ask about which room or what temperature; pick a \
    sensible default and say what you did. Only call this when (a) two or more \
    plausible interpretations exist (e.g. 'play Thriller' → song or album?) AND \
    (b) no prior tool result already resolves the ambiguity. The `id` strings you \
    supply MUST be tokens you can act on next — typically search_music hit ids.
    """

    @Generable
    struct Arguments {
        @Guide(description: "Short, spoken-aloud-friendly question. No markdown, no preamble like 'sure!'. Examples: 'The song or the album?', 'Which Coldplay album?'.")
        var question: String
        @Guide(description: "2 to 5 distinct options the user can tap.")
        var choices: [Choice]
    }

    @Generable
    struct Choice {
        @Guide(description: "Opaque token to act on after the tap — typically a search_music hit id.")
        var id: String
        @Guide(description: "Short human-facing label, 1-4 words.")
        var label: String
    }

    func call(arguments: Arguments) async throws -> String {
        // Build the Sendable AskUserChoice list here (nonisolated) so the
        // @Generable Arguments never crosses to the main actor.
        let choices = arguments.choices.map { AskUserChoice(id: $0.id, label: $0.label) }
        return try await context.askUser(question: arguments.question, choices: choices)
    }
}
