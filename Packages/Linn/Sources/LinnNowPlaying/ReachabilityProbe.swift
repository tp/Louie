import Foundation
import Network
import Synchronization

/// Diagnostic only: opens a plain TCP connection to the Home Server and reports what
/// Network.framework says about the path, including why iOS refuses it (for example
/// `localNetworkDenied`). It sends no data and cancels the connection afterwards.
enum ReachabilityProbe {
    static func describe(_ url: URL, timeout: Duration = .seconds(5)) async -> String {
        guard let host = url.host(), let rawPort = url.port, let port = NWEndpoint.Port(rawValue: UInt16(clamping: rawPort)) else {
            return "invalid server URL"
        }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
        let queue = DispatchQueue(label: "xyz.preetz.Louie.ReachabilityProbe")
        let outcome = await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            let once = Once(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    once.finish("ready, path \(describe(connection.currentPath))")
                case let .waiting(error):
                    once.finish("waiting (\(error)), path \(describe(connection.currentPath))")
                case let .failed(error):
                    once.finish("failed (\(error)), path \(describe(connection.currentPath))")
                default:
                    break
                }
            }
            connection.start(queue: queue)
            let milliseconds = Int(timeout.components.seconds * 1000)
            queue.asyncAfter(deadline: .now() + .milliseconds(milliseconds)) {
                once.finish("no answer after \(milliseconds) ms, path \(describe(connection.currentPath))")
            }
        }
        connection.cancel()
        return outcome
    }

    private static func describe(_ path: NWPath?) -> String {
        guard let path else { return "unknown" }
        let interfaces = path.availableInterfaces.map { "\($0.name)(\($0.type))" }.joined(separator: ",")
        return "status=\(path.status) unsatisfiedReason=\(path.unsatisfiedReason) interfaces=[\(interfaces)]"
    }

    private final class Once: Sendable {
        private let continuation: Mutex<CheckedContinuation<String, Never>?>

        init(_ continuation: CheckedContinuation<String, Never>) {
            self.continuation = Mutex(continuation)
        }

        func finish(_ value: String) {
            continuation.withLock { pending in
                pending?.resume(returning: value)
                pending = nil
            }
        }
    }
}
