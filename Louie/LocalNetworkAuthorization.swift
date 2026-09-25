//
//  LocalNetworkAuthorization.swift
//  Louie
//
//  iOS has no query API for the local-network permission, so this uses the
//  standard probe: publish a Bonjour service and browse for it. The browse
//  only discovers our own service once the user has granted access, and a
//  denial surfaces as a DNS policy error on the browser. Starting the probe
//  is also what deliberately triggers the system prompt, which lets the
//  connection gate hold the UI until the user has answered instead of
//  racing the first websocket connect against the dialog.
//

#if os(iOS)
    import dnssd
    import Foundation
    import Network
    import OSLog
    import Synchronization

    enum LocalNetworkAuthorization {
        private static let serviceType = "_louie._tcp"
        private static let logger = Logger(subsystem: "Louie", category: "LocalNetworkAuthorization")

        /// Resolves once the user has answered the permission prompt: `true`
        /// when the probe can see itself on the network, `false` on denial or
        /// when nothing resolves within `timeout` (e.g. permission previously
        /// denied — no prompt appears, the browser just stays waiting).
        static func request(timeout: Duration = .seconds(60)) async -> Bool {
            let listener: NWListener
            do {
                listener = try NWListener(using: .tcp)
            } catch {
                // Can't probe at all — don't hold the app hostage; the real
                // connection attempt will surface its own error.
                logger.error("Local network probe listener failed to init: \(String(describing: error), privacy: .public)")
                return true
            }
            listener.service = NWListener.Service(name: "louie-\(UUID().uuidString.prefix(8))", type: serviceType)
            listener.newConnectionHandler = { connection in
                connection.cancel()
            }

            let browser = NWBrowser(for: .bonjour(type: serviceType, domain: nil), using: .tcp)
            let queue = DispatchQueue(label: "louie.local-network-probe")
            let resumed = Mutex(false)

            return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                let finish: @Sendable (Bool) -> Void = { granted in
                    let shouldResume = resumed.withLock { done -> Bool in
                        if done {
                            return false
                        }
                        done = true
                        return true
                    }
                    guard shouldResume else {
                        return
                    }
                    browser.cancel()
                    listener.cancel()
                    continuation.resume(returning: granted)
                }

                browser.stateUpdateHandler = { state in
                    switch state {
                    case let .waiting(error):
                        if case .dns(DNSServiceErrorType(kDNSServiceErr_PolicyDenied)) = error {
                            logger.info("Local network access denied by policy")
                            finish(false)
                        }
                    case let .failed(error):
                        logger.error("Local network probe browser failed: \(String(describing: error), privacy: .public)")
                        finish(true)
                    default:
                        break
                    }
                }
                browser.browseResultsChangedHandler = { results, _ in
                    if !results.isEmpty {
                        finish(true)
                    }
                }
                listener.stateUpdateHandler = { state in
                    if case let .failed(error) = state {
                        logger.error("Local network probe listener failed: \(String(describing: error), privacy: .public)")
                        finish(true)
                    }
                }

                browser.start(queue: queue)
                listener.start(queue: queue)
                queue.asyncAfter(deadline: .now() + .seconds(Int(timeout.components.seconds))) {
                    logger.info("Local network probe timed out without a grant")
                    finish(false)
                }
            }
        }
    }
#endif
