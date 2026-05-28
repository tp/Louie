//
//  RealtimeVoiceToolRunner.swift
//  Louie
//

import Foundation
import Linn
import OSLog
import Sentry

@MainActor
struct RealtimeVoiceToolRunner {
    private let dispatcher: HeyLouieToolDispatcher
    private static let logger = Logger(subsystem: "Louie", category: "RealtimeVoiceToolRunner")

    init(state: HeyLouieFakeState, linn: Linn?, mediaIDs: HeyLouieMediaIdMap?) {
        dispatcher = HeyLouieToolDispatcher(state: state, linn: linn, mediaIDs: mediaIDs)
    }

    func runToolCall(
        id _: String,
        name: String,
        inputJSON: Data,
        env: VoiceAgentEnvironment,
        parentSpan: (any Span)?,
    ) async throws -> (content: String, isError: Bool) {
        if name == "ask_user" {
            return try await runAskUser(inputJSON: inputJSON, env: env)
        }

        env.publishState(.runningLocalTool(LocalToolActivity(
            name: name,
            summary: Self.summary(for: name, inputJSON: inputJSON),
        )))
        let span = parentSpan?.startChild(operation: "tool.execute_local", description: name)
        defer { span?.finish() }

        do {
            let content = try await dispatcher.call(name: name, inputJSON: inputJSON)
            return (content, false)
        } catch {
            span?.setData(value: String(describing: error), key: "error")
            Self.logger.warning("Tool \(name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return (error.localizedDescription, true)
        }
    }

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

    private func runAskUser(inputJSON: Data, env: VoiceAgentEnvironment) async throws -> (content: String, isError: Bool) {
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
            return (String(data: payload, encoding: .utf8) ?? "{}", false)
        } catch is AskUserDismissed {
            return (
                "User dismissed the disambiguation without choosing. Do NOT retry "
                    + "the action or fall back to a default — end the turn with a brief "
                    + "acknowledgement like 'OK, never mind.'",
                true,
            )
        } catch {
            Self.logger.warning("ask_user failed: \(error.localizedDescription, privacy: .public)")
            return (error.localizedDescription, true)
        }
    }

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
