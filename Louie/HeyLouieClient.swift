//
//  HeyLouieClient.swift
//  Louie
//
//  Thin WebSocket client for one Hey-Louie agent turn. Opens, exchanges
//  frames, closes. Inbound messages arrive as a Sendable `HeyLouieInbound`
//  stream; tool_call inputs are forwarded as raw JSON `Data` so the
//  dispatcher can decode straight into typed `Decodable` structs without
//  shuttling `[String: Any]` across actor boundaries.
//

import Foundation
import OSLog

// `nonisolated` because the target sets `SWIFT_DEFAULT_ACTOR_ISOLATION =
// MainActor`, and this type is yielded from the detached pump task in
// `HeyLouieClient.messages()`. Without it, `isTerminal` would inherit
// main-actor isolation and the pump couldn't read it.
nonisolated enum HeyLouieInbound: Sendable {
    case toolCall(id: String, name: String, inputJSON: Data)
    case finalText(String)
    case cancelled
    case error(String)

    var isTerminal: Bool {
        switch self {
        case .toolCall: false
        case .finalText, .cancelled, .error: true
        }
    }
}

/// Single-key reader for the bundled `.env` file. Mirrors the discover
/// path in `Linn.Configuration` (which uses an equivalent private parser).
/// Reused by `LouieApp` for `SENTRY_DSN`; if a fourth reader appears,
/// promote `Linn`'s `DotEnv` to a shared public type rather than copying.
nonisolated enum HeyLouieDotEnv {
    static func value(forKey key: String) -> String? {
        let candidates = [
            Bundle.main.url(forResource: ".env", withExtension: nil),
            Bundle.main.bundleURL.appendingPathComponent(".env"),
        ].compactMap(\.self)
        let fileManager = FileManager.default
        guard let url = candidates.first(where: { fileManager.fileExists(atPath: $0.path) }),
              let contents = try? String(contentsOf: url, encoding: .utf8)
        else {
            return nil
        }
        for line in contents.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            let parts = trimmed.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let k = parts[0].trimmingCharacters(in: .whitespaces)
            guard k == key else { continue }
            return unquote(parts[1].trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    private static func unquote(_ value: String) -> String {
        guard value.count >= 2 else { return value }
        if value.first == "\"", value.last == "\"" {
            return String(value.dropFirst().dropLast())
        }
        if value.first == "'", value.last == "'" {
            return String(value.dropFirst().dropLast())
        }
        return value
    }
}

// `nonisolated` because the detached pump throws this from off-main.
nonisolated enum HeyLouieClientError: LocalizedError {
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
final class HeyLouieClient {
    /// Resolution order:
    ///   1. `UserDefaults["HeyLouieBackendURL"]` — per-device runtime override.
    ///   2. `HEY_LOUIE_BACKEND_URL` from `ProcessInfo` (Xcode scheme env).
    ///   3. `HEY_LOUIE_BACKEND_URL` from a bundled `.env` (LAN dev default).
    ///   4. `ws://localhost:8000/agent`.
    ///
    /// `.env` discovery mirrors `Linn.Configuration.local()` — the file
    /// must be added to the Louie target as a bundle resource.
    nonisolated static let defaultURL: URL = {
        let candidates = [
            UserDefaults.standard.string(forKey: "HeyLouieBackendURL"),
            ProcessInfo.processInfo.environment["HEY_LOUIE_BACKEND_URL"],
            HeyLouieDotEnv.value(forKey: "HEY_LOUIE_BACKEND_URL"),
        ]
        for raw in candidates {
            if let raw, !raw.isEmpty, let url = URL(string: raw) {
                return url
            }
        }
        return URL(string: "ws://localhost:8000/agent")!
    }()

    nonisolated static let logger = Logger(subsystem: "Louie", category: "HeyLouieClient")

    private let session: URLSession
    private let task: URLSessionWebSocketTask

    /// `headers` are applied to the WebSocket upgrade request — used by
    /// the agent layer to inject `sentry-trace` so the backend can continue
    /// the trace started on the iPad. Keep this client Sentry-agnostic:
    /// the caller is responsible for computing the header value.
    init(url: URL = HeyLouieClient.defaultURL, headers: [String: String] = [:]) {
        let session = URLSession(configuration: .default)
        self.session = session
        var request = URLRequest(url: url)
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        task = session.webSocketTask(with: request)
        Self.logger.info("Opening agent socket to \(url.absoluteString, privacy: .public)")
    }

    func open() {
        task.resume()
    }

    func close() {
        task.cancel(with: .normalClosure, reason: nil)
        session.invalidateAndCancel()
    }

    // MARK: Outbound

    func sendHello(sessionId: String, tools: [[String: Any]]) async throws {
        try await sendJSON([
            "type": "hello",
            "session_id": sessionId,
            "tools": tools,
        ])
    }

    func sendUtterance(_ text: String) async throws {
        try await sendJSON([
            "type": "utterance",
            "text": text,
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
            throw HeyLouieClientError.transport("non-utf8 payload")
        }
        Self.logger.debug("→ \(text, privacy: .public)")
        try await task.send(.string(text))
    }

    // MARK: Inbound

    /// Stream of decoded inbound frames. Finishes after the first terminal
    /// frame (`final_text` / `cancelled` / `error`) or on socket error. Runs
    /// the pump on a detached task to avoid hopping to the main actor for
    /// every `receive()`.
    func messages() -> AsyncThrowingStream<HeyLouieInbound, Error> {
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

    private nonisolated static func decode(_ raw: String) throws -> HeyLouieInbound {
        guard let data = raw.data(using: .utf8),
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String
        else {
            throw HeyLouieClientError.decode("bad json: \(raw)")
        }
        switch type {
        case "tool_call":
            guard let id = obj["tool_use_id"] as? String,
                  let name = obj["name"] as? String,
                  let input = obj["input"] as? [String: Any]
            else {
                throw HeyLouieClientError.decode("bad tool_call: \(obj)")
            }
            let inputJSON = try JSONSerialization.data(
                withJSONObject: input,
                options: [.sortedKeys],
            )
            return .toolCall(id: id, name: name, inputJSON: inputJSON)
        case "final_text":
            return .finalText((obj["text"] as? String) ?? "")
        case "cancelled":
            return .cancelled
        case "error":
            return .error((obj["message"] as? String) ?? "unknown")
        default:
            throw HeyLouieClientError.decode("unknown type: \(type)")
        }
    }
}
