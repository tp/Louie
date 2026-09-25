//
//  RealtimeVoiceControlClient.swift
//  Louie
//

import Foundation
import OSLog

nonisolated enum RealtimeVoiceControlInbound: Sendable, Equatable {
    case sdpAnswer(sdp: String, callId: String?)
    case toolCall(id: String, name: String, inputJSON: Data)
    case done
    case error(String)

    var isTerminal: Bool {
        switch self {
        case .sdpAnswer, .toolCall: false
        case .done, .error: true
        }
    }
}

nonisolated enum RealtimeVoiceControlClientError: LocalizedError, Equatable {
    case decode(String)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case let .decode(detail): "decode: \(detail)"
        case let .transport(detail): "transport: \(detail)"
        }
    }
}

@MainActor
final class RealtimeVoiceControlClient {
    nonisolated static let logger = Logger(subsystem: "Louie", category: "RealtimeVoiceControlClient")

    nonisolated static var defaultURL: URL {
        agentVoiceURL(from: HeyLouieClient.defaultURL)
    }

    private let session: URLSession
    private let task: URLSessionWebSocketTask

    init(url: URL = RealtimeVoiceControlClient.defaultURL, headers: [String: String] = [:]) {
        let session = URLSession(configuration: .default)
        self.session = session
        var request = URLRequest(url: url)
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        task = session.webSocketTask(with: request)
        Self.logger.info("Opening realtime voice socket to \(url.absoluteString, privacy: .public)")
    }

    func open() {
        task.resume()
    }

    func close() {
        task.cancel(with: .normalClosure, reason: nil)
        session.invalidateAndCancel()
    }

    func sendHello(sessionId: String, sdpOffer: String, tools: [[String: Any]]) async throws {
        try await sendJSON([
            "type": "hello",
            "session_id": sessionId,
            "sdp_offer": sdpOffer,
            "tools": tools,
        ])
    }

    func sendToolResult(id: String, content: String, isError: Bool) async throws {
        try await sendJSON([
            "type": "tool_result",
            "tool_use_id": id,
            "content": content,
            "is_error": isError,
        ])
    }

    func sendCancel() async throws {
        try await sendJSON(["type": "cancel"])
    }

    private func sendJSON(_ payload: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        guard let text = String(data: data, encoding: .utf8) else {
            throw RealtimeVoiceControlClientError.transport("non-utf8 payload")
        }
        Self.logger.debug("→ \(text, privacy: .public)")
        try await task.send(.string(text))
    }

    func messages() -> AsyncThrowingStream<RealtimeVoiceControlInbound, Error> {
        let task = task
        return AsyncThrowingStream { continuation in
            let pump = Task.detached {
                do {
                    while !Task.isCancelled {
                        let message = try await task.receive()
                        let raw: String
                        switch message {
                        case let .string(text):
                            raw = text
                        case let .data(data):
                            raw = String(data: data, encoding: .utf8) ?? ""
                        @unknown default:
                            continue
                        }

                        Self.logger.debug("← \(raw, privacy: .public)")
                        let inbound = try Self.decode(raw)
                        continuation.yield(inbound)
                        if inbound.isTerminal {
                            continuation.finish()
                            return
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in pump.cancel() }
        }
    }

    nonisolated static func agentVoiceURL(from url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        let path = components.path
        if path == "/agent" {
            components.path = "/agent-voice"
        } else if path.hasSuffix("/agent") {
            components.path = String(path.dropLast("/agent".count)) + "/agent-voice"
        } else if path.hasSuffix("/") {
            components.path = path + "agent-voice"
        } else {
            components.path = path + "/agent-voice"
        }
        return components.url ?? url
    }

    nonisolated static func decode(_ raw: String) throws -> RealtimeVoiceControlInbound {
        guard let data = raw.data(using: .utf8),
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String
        else {
            throw RealtimeVoiceControlClientError.decode("bad json: \(raw)")
        }

        switch type {
        case "sdp_answer":
            guard let sdp = obj["sdp"] as? String else {
                throw RealtimeVoiceControlClientError.decode("bad sdp_answer: \(obj)")
            }
            return .sdpAnswer(sdp: sdp, callId: obj["call_id"] as? String)
        case "tool_call":
            guard let id = obj["tool_use_id"] as? String,
                  let name = obj["name"] as? String,
                  let input = obj["input"] as? [String: Any]
            else {
                throw RealtimeVoiceControlClientError.decode("bad tool_call: \(obj)")
            }
            let inputJSON = try JSONSerialization.data(withJSONObject: input, options: [.sortedKeys])
            return .toolCall(id: id, name: name, inputJSON: inputJSON)
        case "done":
            return .done
        case "error":
            return .error((obj["message"] as? String) ?? "unknown")
        default:
            throw RealtimeVoiceControlClientError.decode("unknown type: \(type)")
        }
    }
}
