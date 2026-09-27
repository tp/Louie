import Foundation

/// The connection owns the socket's lifetime. Receives must unblock when the
/// socket is cancelled, including while opening a session or discovering rooms.
protocol GatewaySocket: AnyObject, Sendable {
    func resume()
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
    func send(_ message: URLSessionWebSocketTask.Message) async throws
    func receive() async throws -> URLSessionWebSocketTask.Message
}

extension URLSessionWebSocketTask: GatewaySocket {}

/// Production deadlines, with a sleep function tests can advance explicitly.
struct GatewayTiming: Sendable {
    var commandTimeout: Duration = .seconds(2)
    var responseTimeout: Duration = .seconds(5)
    var reconnectDelay: Duration = .milliseconds(500)
    var maximumReconnectDelay: Duration = .seconds(10)
    var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
}
