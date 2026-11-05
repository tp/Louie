//
//  GatewaySettings.swift
//  Louie
//
//  The Raspberry Pi server's local address. Kept separate from the former
//  direct Linn CI Gateway setting so old DSM addresses are not reused.
//

import Foundation
import Linn
import Observation

@MainActor
@Observable
final class GatewaySettings {
    private static let hostKey = "pi.host"
    private static let portKey = "pi.port"

    var host: String {
        didSet {
            UserDefaults.standard.set(host, forKey: Self.hostKey)
        }
    }

    var port: Int {
        didSet {
            UserDefaults.standard.set(port, forKey: Self.portKey)
        }
    }

    init() {
        let fallback = try? Linn.Configuration.local()
        host = UserDefaults.standard.string(forKey: Self.hostKey)
            ?? fallback?.serverURL.host()
            ?? "louie-pi.local"
        let storedPort = UserDefaults.standard.integer(forKey: Self.portKey)
        port = storedPort == 0 ? fallback?.serverURL.port ?? 50051 : storedPort
    }

    /// The stored address wins over the developer `LOUIE_SERVER_URL` fallback.
    var configuration: Linn.Configuration? {
        let trimmedHost = host.trimmingCharacters(in: .whitespaces)
        if !trimmedHost.isEmpty,
           let url = URL(string: "http://\(trimmedHost):\(port)"),
           url.host() != nil {
            return Linn.Configuration(serverURL: url)
        }
        return try? Linn.Configuration.local()
    }
}
